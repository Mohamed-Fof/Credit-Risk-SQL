# Système SQL de risque de crédit — Risk Analytics & MLOps

Backend **PostgreSQL** qui suit **32 409 prêts réels** de la demande jusqu'au remboursement ou au défaut :
retards de paiement (DPD), provisions **IFRS 9**, registre des prédictions de trois modèles de Machine Learning,
et **détection automatique du défaut** par triggers et procédures stockées.

Il prolonge mon projet de scoring [Credit-Risk](https://github.com/Mohamed-Fof/Credit-Risk), qui avait sélectionné un
XGBoost à contraintes de monotonie (AUC 0,92). Ici, le modèle n'est plus une fin en soi : la base conserve chacune de
ses prédictions, applique les règles de gestion du risque et mesure sa performance dans le temps.

## Résultats clés

- **Détection du défaut automatisée et validée** : 7 088 prêts passés en défaut par la base, exactement les 7 088 défauts
  réels du jeu de données, **0 désaccord**.
- **Provisions IFRS 9** : 25,6 M€ au 30/09/2026, soit 19,1 % de l'exposition, dont 96,5 % en stage 3 ;
  clôture mensuelle rejouable sur 12 mois.
- **Monitoring des modèles en SQL** : AUC calculée par la statistique de Mann-Whitney, 0,923 pour le XGBoost champion
  contre 0,876 pour la régression logistique, sur l'échantillon de test uniquement.
- **Volume et performance** : 1,3 million de lignes chargées en ~13 s (`COPY`) ; retard d'un prêt calculé en 0,3 ms
  grâce à un index partiel (114 ms sans index).

## Ce que montre le projet

| Domaine | Mise en œuvre |
|---|---|
| Modélisation | schéma normalisé, `NUMERIC` pour l'argent, contraintes `CHECK` nommées (y compris entre colonnes), `ON DELETE RESTRICT`, index partiel |
| Ingestion | Python (Faker, Pandas, SQLAlchemy) : `DataFrame.to_sql` avec une méthode `COPY`, une seule transaction |
| SQL analytique | vues, CTE, `FILTER`, fonctions de fenêtre (`NTILE`, `RANK`, `LAG`, `LEAD`, cumuls, moyennes mobiles), `ROLLUP` |
| Indicateurs du risque | DPD, PAR30 / PAR90, ECL par stage, déciles et courbe de gains, AUC / Gini, matrice de transition, analyse par génération |
| Automatisation | fonctions PL/pgSQL, trigger `BEFORE` de protection, trigger `AFTER` par instruction avec tables de transition, journal d'audit, alertes `LISTEN / NOTIFY`, procédures avec verrou `FOR UPDATE`, upsert idempotent |
| Sécurité | rôles en moindre privilège, procédure `SECURITY DEFINER` à `search_path` figé |

## Architecture

| Table | Contenu |
|---|---|
| `clients` | les emprunteurs (noms fictifs) |
| `demandes_pret` | dossiers de crédit, décision et statut de remboursement |
| `echeancier_remboursements` | une ligne par mensualité (1,1 million) et le suivi des paiements |
| `predictions_scoring_ml` | registre versionné des prédictions : grille de score, logistique, XGBoost (champion) avec explication SHAP |
| `echantillons_modele` | découpage apprentissage / test du projet de scoring |
| `parametres_risque` | LGD, seuils de 30 et 90 jours, date de référence |
| `journal_statuts`, `provisions_mensuelles` | audit des changements de statut, provisions de fin de mois |

Le modèle relationnel complet et le dictionnaire de données sont dans le [guide du projet](docs/cours_risk_analytics.pdf) (partie 3).

## Données

- **Réelles** : les prêts du [Credit Risk Dataset](https://www.kaggle.com/datasets/laotse/credit-risk-dataset)
  (32 409 après nettoyage, 21,9 % de défauts) et les sorties de mes modèles R (probabilités de défaut, valeurs SHAP,
  échantillons).
- **Simulées**, de façon cohérente avec le défaut réel : noms et e-mails (Faker), dates, durées et paiements. Un prêt
  qui a fait défaut cesse de payer ; un prêt sain rembourse, avec des retards ponctuels.

## Lancer le projet

Prérequis : PostgreSQL 15 ou plus, Python 3.10 ou plus.

```bash
createdb risk_analytics_db
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./executer.sh          # schéma, chargement des données, puis les trois chapitres
```

La connexion se règle par la variable d'environnement `DATABASE_URL` (par défaut `postgresql://localhost/risk_analytics_db`).

## Structure du dépôt

```
sql/01_schema.sql        schéma : tables, contraintes, index
python/charger_donnees.py   chargement des données (Faker, Pandas, SQLAlchemy, COPY)
corriges/chapitre1.sql   modélisation : ouverture d'un dossier en une transaction, contrôles qualité
corriges/chapitre2.sql   SQL analytique : DPD, PAR, provisions IFRS 9, déciles, AUC, transitions, générations
corriges/chapitre3.sql   automatisation : fonctions, triggers, procédures, clôture mensuelle, rôles
docs/                    guide du projet (PDF de 103 pages et sources LaTeX)
donnees/                 jeu de données et sorties des modèles
executer.sh              reconstruction complète de la base
```

## Auteur

**Mohamed Fofana** — Master 1 Mathématiques Appliquées, Statistique (Université Clermont Auvergne)
[Portfolio](https://mohamed-fof.github.io) · [LinkedIn](https://www.linkedin.com/in/mohamed-fofana-05720a28b/)
