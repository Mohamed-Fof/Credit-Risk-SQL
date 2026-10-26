"""
Alimente la base risk_analytics_db à partir des données RÉELLES du projet de scoring de crédit.

Réel     : caractéristiques des 32 409 emprunteurs et prêts, défaut observé,
           prédictions des trois modèles (grille de score, logistique, XGBoost) et explications SHAP.
Simulé   : le fichier source ne contient ni noms, ni dates, ni durées, ni détail des paiements.
           Ces éléments sont simulés de façon COHÉRENTE avec le défaut réel : un prêt qui a fait
           défaut cesse de payer (plus de 90 jours de retard à la date de référence), un prêt sain paie.
           Les noms sont fictifs (Faker) ; aucune donnée personnelle réelle.

Usage    : python python/charger_donnees.py          (depuis le dossier du projet)
Connexion: variable d'environnement DATABASE_URL, par défaut postgresql://localhost/risk_analytics_db
           (ne jamais écrire un mot de passe dans le code : export DATABASE_URL=postgresql://user:mdp@hote/base)
Outils   : Faker (noms fictifs), Pandas (préparation), SQLAlchemy (connexion et transaction),
           psycopg 3 (pilote PostgreSQL, utilisé par SQLAlchemy pour le COPY).
"""
import csv
import io
import os
import time
import unicodedata

import numpy as np
import pandas as pd
from faker import Faker
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://localhost/risk_analytics_db")
DATE_REFERENCE = pd.Timestamp("2026-09-30")   # « aujourd'hui » figé : les résultats sont reproductibles
GRAINE = 2026
MEDIANE_TAUX = 11.0                            # médiane d'apprentissage du projet R (imputation)

rng = np.random.default_rng(GRAINE)
Faker.seed(GRAINE)
fake = Faker("fr_FR")
debut = time.time()


def etape(message):
    print(f"[{time.time() - debut:5.1f} s] {message}")


# -----------------------------------------------------------------------------
# 1. Lecture et nettoyage : exactement les règles du projet R (32 409 prêts)
# -----------------------------------------------------------------------------
brut = pd.read_csv("donnees/credit_risk_dataset.csv")
brut.insert(0, "id_source", np.arange(1, len(brut) + 1))          # numéro de ligne du fichier
colonnes = [c for c in brut.columns if c != "id_source"]
df = brut.drop_duplicates(subset=colonnes, keep="first")
df = df[df.person_age <= 100]
df = df[df.person_emp_length.isna() | (df.person_emp_length <= df.person_age - 14)].reset_index(drop=True)
assert len(df) == 32409, len(df)
n = len(df)
etape(f"{n} prêts après nettoyage")

LOGEMENT = {"RENT": "locataire", "OWN": "proprietaire", "MORTGAGE": "credit_immobilier", "OTHER": "autre"}
MOTIF = {"EDUCATION": "etudes", "MEDICAL": "sante", "VENTURE": "creation_entreprise", "PERSONAL": "personnel",
         "HOMEIMPROVEMENT": "travaux", "DEBTCONSOLIDATION": "regroupement_dettes"}
defaut = df.loan_status.to_numpy()

# -----------------------------------------------------------------------------
# 2. Dates et durées (simulées). Un prêt en défaut doit avoir assez d'échéances échues
#    pour cumuler plus de 90 jours de retard à la date de référence.
# -----------------------------------------------------------------------------
def dates_uniformes(debut, fin, taille):
    jours = (pd.Timestamp(fin) - pd.Timestamp(debut)).days
    return pd.Timestamp(debut) + pd.to_timedelta(rng.integers(0, jours + 1, taille), unit="D")

date_demande = np.where(defaut == 1,
                        dates_uniformes("2022-01-01", "2025-10-31", n),
                        dates_uniformes("2022-01-01", "2026-06-30", n))
date_demande = pd.to_datetime(date_demande)
date_decision = date_demande + pd.to_timedelta(rng.integers(0, 11, n), unit="D")
premiere_echeance = date_decision + pd.DateOffset(months=1)

montant = df.loan_amnt.to_numpy().astype(float)
duree = np.select([montant < 5000, montant < 15000],
                  [rng.choice([12, 24], n), rng.choice([24, 36, 48], n)],
                  rng.choice([36, 48, 60], n))
taux = df.loan_int_rate.to_numpy()
taux_impute = np.isnan(taux)
taux = np.where(taux_impute, MEDIANE_TAUX, taux)

# -----------------------------------------------------------------------------
# 3. Clients
# -----------------------------------------------------------------------------
def sans_accent(texte):
    return unicodedata.normalize("NFKD", texte).encode("ascii", "ignore").decode().lower()

noms = [fake.name() for _ in range(n)]
emails = [f"{sans_accent(nom).replace(' ', '.').replace(chr(39), '')}.{i}@exemple.fr"
          for nom, i in zip(noms, df.id_source)]
clients = pd.DataFrame({
    "client_id": df.id_source,
    "nom_complet": noms,
    "email": emails,
    "age": df.person_age,
    "revenu_annuel": df.person_income.astype(float),
    "statut_logement": df.person_home_ownership.map(LOGEMENT),
    "anciennete_emploi": df.person_emp_length,
    "anciennete_credit": df.cb_person_cred_hist_length,
    "defaut_anterieur": df.cb_person_default_on_file.eq("Y"),
    "date_inscription": (date_demande - pd.to_timedelta(rng.integers(0, 1500, n), unit="D")).date,
})

# -----------------------------------------------------------------------------
# 4. Demandes de prêt (toutes accordées : le fichier source ne contient que des prêts octroyés)
# -----------------------------------------------------------------------------
prets = pd.DataFrame({
    "pret_id": df.id_source,
    "client_id": df.id_source,
    "montant_demande": montant,
    "duree_mois": duree,
    "taux_interet": taux,
    "taux_impute": taux_impute,
    "motif_pret": df.loan_intent.map(MOTIF),
    "note_risque": df.loan_grade,
    "date_demande": date_demande.date,
    "date_decision": date_decision.date,
    "date_premiere_echeance": premiere_echeance.date,
    "statut_dossier": "accorde",
    "statut_pret": "sain",          # recalculé à partir des paiements au chapitre 3
})

# -----------------------------------------------------------------------------
# 5. Échéancier à mensualités constantes : M = C × r / (1 − (1 + r)^−n), r = taux annuel / 12
# -----------------------------------------------------------------------------
idx = np.repeat(np.arange(n), duree)                         # une ligne par mensualité
num = np.concatenate([np.arange(1, d + 1) for d in duree])
r = taux[idx] / 1200
C = montant[idx]
nn = duree[idx]
mensualite = np.round(C * r / (1 - (1 + r) ** -nn), 2)
crd_avant = C * (1 + r) ** (num - 1) - mensualite * ((1 + r) ** (num - 1) - 1) / r
interets = np.round(crd_avant * r, 2)
capital = np.round(mensualite - interets, 2)
# Arrondis au centime : la dernière échéance rembourse exactement le capital restant,
# pour que la somme des parts de capital soit égale au montant prêté, au centime près.
derniere = num == nn
cumul_avant = pd.Series(capital).groupby(idx).cumsum().to_numpy() - capital
capital = np.where(derniere, np.round(C - cumul_avant, 2), capital)
montant_du = np.round(capital + interets, 2)
crd_apres = np.round(C - (cumul_avant + capital), 2)
# décalage mois par mois (vectorisé) : même jour du mois que la première échéance, borné à la fin du mois
base = pd.to_datetime(premiere_echeance.to_numpy()[idx])
mois = (base.year * 12 + base.month - 1) + (num - 1)
annee, mois_num = mois // 12, mois % 12 + 1
fin_mois = pd.to_datetime(dict(year=annee, month=mois_num, day=1)) + pd.offsets.MonthEnd(0)
jour = np.minimum(base.day, fin_mois.dt.day)
date_echeance = pd.to_datetime(dict(year=annee, month=mois_num, day=jour))
etape(f"{len(idx)} mensualités calculées")

# -----------------------------------------------------------------------------
# 6. Paiements jusqu'à la date de référence, cohérents avec le défaut réel
# -----------------------------------------------------------------------------
echue = (date_echeance <= DATE_REFERENCE).to_numpy()
nb_echues = np.bincount(idx, weights=echue, minlength=n).astype(int)
# Prêt en défaut : il paie k échéances puis s'arrête, en laissant au moins 5 échéances impayées.
dernier_paye = np.where(defaut == 1,
                        rng.integers(1, np.maximum(nb_echues - 4, 2)),
                        np.iinfo(np.int32).max)
paye = echue & (num <= dernier_paye[idx])
# Retards ponctuels : 88 % des paiements à l'heure (jusqu'à 3 jours d'avance), 10 % de 1 à 20 jours
# de retard, 2 % de 31 à 75 jours (incidents temporaires, régularisés ensuite : jamais 90 jours).
tirage = rng.random(len(idx))
decalage = np.select([tirage < 0.88, tirage < 0.98],
                     [-rng.integers(0, 4, len(idx)), rng.integers(1, 21, len(idx))],
                     rng.integers(31, 76, len(idx)))
date_paiement = date_echeance + pd.to_timedelta(decalage, unit="D")
paye &= (date_paiement <= DATE_REFERENCE).to_numpy()        # un paiement futur n'a pas encore eu lieu
# 25 % des prêts en défaut ont réglé une partie de leur première échéance impayée.
premiere_impayee = (defaut[idx] == 1) & (num == dernier_paye[idx] + 1) & echue
partiel = premiere_impayee & (rng.random(len(idx)) < 0.25)
montant_paye = np.where(paye, montant_du, np.where(partiel, np.round(montant_du * rng.uniform(0.3, 0.7, len(idx)), 2), 0.0))

echeancier = pd.DataFrame({
    "pret_id": df.id_source.to_numpy()[idx],
    "num_echeance": num,
    "date_echeance": date_echeance.dt.date,
    "montant_du": montant_du,
    "part_capital": capital,
    "part_interets": interets,
    "capital_restant_du": crd_apres,
    "montant_paye": montant_paye,
    "date_paiement": np.where(paye, date_paiement.dt.date, None),
})
etape(f"paiements simulés : {int(paye.sum())} mensualités payées, {int((echue & ~paye).sum())} impayées échues")

# -----------------------------------------------------------------------------
# 7. Prédictions des trois modèles (réelles, issues du projet R) et registre des échantillons
# -----------------------------------------------------------------------------
scores = pd.read_csv("donnees/predictions_modeles.csv")
shap = pd.read_csv("donnees/shap_xgboost.csv")
base_pred = df[["id_source"]].merge(scores, left_on="id_source", right_on="id_pret").merge(shap, on="id_pret")
MODELES = [  # version, colonne de probabilité, seuil (projet R), date d'entraînement, champion
    ("grille_score_v1", "pd_grille", 0.240, "2026-04-20 10:00", False),
    ("logistique_v1", "pd_logistique", 0.235, "2026-04-20 10:00", False),
    ("xgboost_monotone_v2", "pd_xgboost", 0.255, "2026-09-15 16:00", True),
]
morceaux = []
for version, colonne, seuil, date_pred, champion in MODELES:
    p = base_pred[colonne].round(6)
    morceaux.append(pd.DataFrame({
        "pret_id": base_pred.id_pret, "version_modele": version, "est_champion": champion,
        "probabilite_defaut": p, "seuil_decision": seuil,
        "decision": np.where(p >= seuil, "refuser", "accorder"), "date_prediction": date_pred,
    }))
predictions = pd.concat(morceaux, ignore_index=True).merge(
    base_pred[["id_pret", "points_grille", "shap_top_feature", "shap_top_valeur"]].rename(columns={"id_pret": "pret_id"}),
    on="pret_id")
# Points : seulement pour la grille ; explication SHAP : seulement pour le modèle champion (XGBoost).
predictions["score_points"] = predictions.points_grille.round().astype("Int64").where(
    predictions.version_modele.eq("grille_score_v1"))
for col in ("shap_top_feature", "shap_top_valeur"):
    predictions[col] = predictions[col].where(predictions.est_champion)
predictions = predictions.drop(columns="points_grille")
echantillons = pd.read_csv("donnees/echantillon.csv").rename(columns={"id_pret": "pret_id"})

# Vérité terrain, pour contrôler la simulation (elle ne fait pas partie de la base)
df[["id_source", "loan_status"]].rename(columns={"id_source": "pret_id", "loan_status": "defaut_reel"}) \
    .to_csv("donnees/verite_defauts.csv", index=False)

# -----------------------------------------------------------------------------
# 8. Chargement : DataFrame.to_sql (Pandas + SQLAlchemy) avec la méthode COPY de PostgreSQL.
#    Par défaut, to_sql envoie des INSERT : plusieurs minutes pour 1,1 million d'échéances.
#    COPY les envoie en un seul flux : environ 10 secondes.
# -----------------------------------------------------------------------------
def methode_copy(table, conn, colonnes, lignes):
    """Méthode d'insertion pour to_sql : envoie les lignes avec COPY au lieu d'INSERT."""
    tampon = io.StringIO()
    csv.writer(tampon).writerows(lignes)               # une valeur manquante devient un champ vide
    tampon.seek(0)
    curseur = conn.connection.driver_connection.cursor()   # la connexion psycopg sous SQLAlchemy
    with curseur.copy(f"COPY {table.name} ({', '.join(colonnes)}) FROM STDIN WITH (FORMAT csv, NULL '')") as copie:
        copie.write(tampon.read())


def charger(conn, table, frame):
    frame.to_sql(table, conn, if_exists="append", index=False, method=methode_copy, chunksize=200_000)
    etape(f"{table} : {len(frame)} lignes")


# postgresql://… désigne le pilote psycopg2 pour SQLAlchemy : on précise psycopg (version 3)
moteur = create_engine(make_url(DATABASE_URL).set(drivername="postgresql+psycopg"))
with moteur.begin() as conn:                         # une seule transaction : tout ou rien
    conn.execute(text("TRUNCATE predictions_scoring_ml, echantillons_modele, echeancier_remboursements, "
                      "demandes_pret, clients RESTART IDENTITY CASCADE"))
    charger(conn, "clients", clients)
    charger(conn, "demandes_pret", prets)
    charger(conn, "echeancier_remboursements", echeancier)
    charger(conn, "predictions_scoring_ml", predictions)
    charger(conn, "echantillons_modele", echantillons)
    # Les identifiants ont été fournis explicitement : on recale les compteurs automatiques,
    # sinon le prochain client créé recevrait l'identifiant 1… déjà pris.
    for table, colonne in (("clients", "client_id"), ("demandes_pret", "pret_id")):
        conn.execute(text(f"SELECT setval(pg_get_serial_sequence('{table}', '{colonne}'), (SELECT max({colonne}) FROM {table}))"))
with moteur.connect() as conn:                       # ANALYZE : statistiques à jour pour l'optimiseur
    conn.execute(text("ANALYZE"))
    conn.commit()
etape("chargement terminé")
