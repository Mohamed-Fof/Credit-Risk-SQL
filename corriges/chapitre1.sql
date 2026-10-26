-- =============================================================================
-- Chapitre 1 — Modélisation, DDL et contraintes : corrigés
-- Prérequis : sql/01_schema.sql exécuté, données chargées (python/charger_donnees.py)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exercice guidé 1 — Ouvrir un nouveau dossier de prêt complet, en une transaction
-- Client, prêt, score et échéancier sont créés ensemble : si une étape échoue, rien n'est enregistré.
-- -----------------------------------------------------------------------------
BEGIN;

WITH nouveau_client AS (
    INSERT INTO clients (nom_complet, email, age, revenu_annuel, statut_logement,
                         anciennete_emploi, anciennete_credit, defaut_anterieur, date_inscription)
    VALUES ('Awa Koné', 'awa.kone@exemple.fr', 29, 42000, 'locataire', 4, 6, false, DATE '2026-09-15')
    RETURNING client_id
),
nouveau_pret AS (
    INSERT INTO demandes_pret (client_id, montant_demande, duree_mois, taux_interet, motif_pret, note_risque,
                               date_demande, date_decision, date_premiere_echeance, statut_dossier, statut_pret)
    SELECT client_id, 12000, 36, 9.5, 'etudes', 'B',
           DATE '2026-09-20', DATE '2026-09-25', DATE '2026-10-25', 'accorde', 'sain'
    FROM nouveau_client
    RETURNING pret_id, montant_demande AS c, duree_mois AS n, taux_interet / 1200 AS r, date_premiere_echeance
),
-- Le score du modèle champion qui a justifié la décision (PD 11,8 % < seuil 25,5 % : accordé).
-- Une CTE qui modifie des données s'exécute même si personne ne la lit ensuite.
score AS (
    INSERT INTO predictions_scoring_ml (pret_id, version_modele, est_champion, probabilite_defaut,
                                        seuil_decision, decision, shap_top_feature, shap_top_valeur, date_prediction)
    SELECT pret_id, 'xgboost_monotone_v2', true, 0.118, 0.255, 'accorder', 'taux_effort', 0.912,
           TIMESTAMP '2026-09-24 14:30'
    FROM nouveau_pret
),
-- Mensualité constante : M = C × r / (1 − (1 + r)^−n)
mensualites AS (
    SELECT p.pret_id, p.c, p.r, p.n, k AS num_echeance,
           (p.date_premiere_echeance + (k - 1) * INTERVAL '1 month')::DATE AS date_echeance,
           round(p.c * p.r / (1 - (1 + p.r) ^ (-p.n)), 2)                    AS mensualite
    FROM nouveau_pret p
    CROSS JOIN generate_series(1, p.n) AS k                   -- une ligne par mensualité
),
-- Capital restant dû après k mensualités : CRD(k) = C(1 + r)^k − M((1 + r)^k − 1) / r, arrondi au centime.
-- La part de capital est la DIFFÉRENCE de deux CRD arrondis : le CRD baisse exactement de la part de capital.
calcul AS (
    SELECT pret_id, num_echeance, date_echeance, mensualite, r, n,
           round(c * (1 + r) ^ (num_echeance - 1) - mensualite * ((1 + r) ^ (num_echeance - 1) - 1) / r, 2) AS crd_avant,
           round(c * (1 + r) ^ num_echeance       - mensualite * ((1 + r) ^ num_echeance - 1) / r, 2)       AS crd_apres
    FROM mensualites
)
INSERT INTO echeancier_remboursements (pret_id, num_echeance, date_echeance, montant_du,
                                       part_capital, part_interets, capital_restant_du)
SELECT pret_id, num_echeance, date_echeance,
       -- la dernière échéance solde exactement le capital restant
       CASE WHEN num_echeance = n THEN crd_avant + round(crd_avant * r, 2) ELSE mensualite END,
       CASE WHEN num_echeance = n THEN crd_avant ELSE crd_avant - crd_apres END,
       CASE WHEN num_echeance = n THEN round(crd_avant * r, 2) ELSE mensualite - (crd_avant - crd_apres) END,
       CASE WHEN num_echeance = n THEN 0 ELSE crd_apres END
FROM calcul;

COMMIT;

-- Vérification : 36 mensualités, capital total = 12 000 €, coût total du crédit
-- (la mensualité se lit sur l'échéance 1 : la dernière est ajustée de quelques centimes)
SELECT p.pret_id, count(*) AS nb_echeances, sum(e.part_capital) AS capital_rembourse,
       sum(e.part_interets) AS cout_du_credit,
       max(e.montant_du) FILTER (WHERE e.num_echeance = 1) AS mensualite,
       max(e.montant_du) FILTER (WHERE e.num_echeance = p.duree_mois) AS derniere_echeance
FROM demandes_pret p JOIN echeancier_remboursements e USING (pret_id)
WHERE p.client_id = (SELECT client_id FROM clients WHERE email = 'awa.kone@exemple.fr')
GROUP BY p.pret_id;

-- -----------------------------------------------------------------------------
-- Exercice guidé 2 — Les contraintes refusent les données incohérentes
-- (chaque instruction doit échouer ; dans DBeaver, exécute-les une par une)
-- -----------------------------------------------------------------------------
-- a) Un client de 15 ans : violation de CHECK (age BETWEEN 18 AND 100)
-- INSERT INTO clients (nom_complet, email, age, revenu_annuel, statut_logement, anciennete_credit, defaut_anterieur, date_inscription)
-- VALUES ('Test', 'test@exemple.fr', 15, 20000, 'locataire', 0, false, CURRENT_DATE);
-- b) Payer plus que le montant dû : violation de paiement_borne
--    (sur une échéance future, encore impayée : sinon c'est date_si_solde qui se déclenche en premier)
-- UPDATE echeancier_remboursements SET montant_paye = montant_du + 1
-- WHERE echeance_id = (SELECT min(echeance_id) FROM echeancier_remboursements
--                      WHERE montant_paye = 0 AND date_echeance > DATE '2026-09-30');
-- c) Supprimer un client qui a des prêts : refusé grâce à ON DELETE RESTRICT
-- DELETE FROM clients WHERE client_id = 2;

-- -----------------------------------------------------------------------------
-- Exercice à faire seul 1 — Les deux tables du chapitre 3
-- -----------------------------------------------------------------------------
-- 1. Journal d'audit : chaque changement de statut d'un prêt, avec la date et l'ancien statut.
CREATE TABLE IF NOT EXISTS journal_statuts (
    journal_id      BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pret_id         BIGINT       NOT NULL REFERENCES demandes_pret (pret_id) ON DELETE RESTRICT,
    ancien_statut   VARCHAR(12),
    nouveau_statut  VARCHAR(12)  NOT NULL,
    jours_retard    INTEGER      CHECK (jours_retard >= 0),
    date_effet      DATE         NOT NULL,
    enregistre_le   TIMESTAMP    NOT NULL DEFAULT now(),
    enregistre_par  TEXT         NOT NULL DEFAULT session_user,   -- l'utilisateur connecté (voir chapitre 3, sécurité)
    CONSTRAINT statut_change CHECK (ancien_statut IS DISTINCT FROM nouveau_statut)
);
CREATE INDEX IF NOT EXISTS idx_journal_pret ON journal_statuts (pret_id);

-- 2. Provisions mensuelles : une photographie du risque de chaque prêt à chaque arrêté.
CREATE TABLE IF NOT EXISTS provisions_mensuelles (
    date_arrete   DATE          NOT NULL,
    pret_id       BIGINT        NOT NULL REFERENCES demandes_pret (pret_id) ON DELETE RESTRICT,
    jours_retard  INTEGER       NOT NULL CHECK (jours_retard >= 0),
    stage_ifrs9   SMALLINT      NOT NULL CHECK (stage_ifrs9 IN (1, 2, 3)),
    ead           NUMERIC(12,2) NOT NULL CHECK (ead >= 0),
    pd_utilisee   NUMERIC(7,6)  NOT NULL CHECK (pd_utilisee BETWEEN 0 AND 1),
    lgd           NUMERIC(4,3)  NOT NULL CHECK (lgd BETWEEN 0 AND 1),
    ecl           NUMERIC(12,2) NOT NULL CHECK (ecl >= 0),
    PRIMARY KEY (date_arrete, pret_id)       -- un prêt, une ligne par arrêté
);

-- -----------------------------------------------------------------------------
-- Exercice à faire seul 2 — Contrôles qualité de l'échéancier (attendu : 0 partout)
-- Les contraintes vérifient chaque LIGNE ; ces règles portent sur un prêt ENTIER : il faut les contrôler par requête.
-- -----------------------------------------------------------------------------
-- a) Règles par prêt : capital remboursé = montant prêté, une échéance par mois de 1 à n, CRD final nul
WITH par_pret AS (
    SELECT p.pret_id, p.montant_demande, p.duree_mois,
           sum(e.part_capital)                                                      AS capital_total,
           count(*)                                                                 AS nb_echeances,
           max(e.num_echeance)                                                      AS dernier_numero,
           max(e.capital_restant_du) FILTER (WHERE e.num_echeance = p.duree_mois)   AS crd_final,
           count(*) FILTER (WHERE e.montant_du <> e.part_capital + e.part_interets) AS montants_faux
    FROM demandes_pret p
    JOIN echeancier_remboursements e USING (pret_id)
    WHERE p.statut_dossier = 'accorde'
    GROUP BY p.pret_id
)
SELECT count(*)                                                                         AS prets_controles,
       count(*) FILTER (WHERE capital_total <> montant_demande)                           AS capital_different,
       count(*) FILTER (WHERE nb_echeances <> duree_mois OR dernier_numero <> duree_mois) AS echeances_manquantes,
       count(*) FILTER (WHERE crd_final IS DISTINCT FROM 0)                               AS crd_final_non_nul,
       sum(montants_faux)                                                                 AS montants_faux
FROM par_pret;

-- b) Règles entre deux échéances successives (auto-jointure : la table jointe à elle-même)
--    Le CRD baisse exactement de la part de capital, et deux échéances sont espacées d'un mois.
SELECT count(*) FILTER (WHERE suiv.capital_restant_du <> prec.capital_restant_du - suiv.part_capital) AS ruptures_crd,
       count(*) FILTER (WHERE suiv.date_echeance - prec.date_echeance NOT BETWEEN 28 AND 31)          AS ecarts_non_mensuels
FROM echeancier_remboursements prec
JOIN echeancier_remboursements suiv
  ON suiv.pret_id = prec.pret_id AND suiv.num_echeance = prec.num_echeance + 1;

-- c) Aucun paiement avant l'octroi du prêt
SELECT count(*) AS paiements_avant_octroi
FROM echeancier_remboursements e
JOIN demandes_pret p USING (pret_id)
WHERE e.date_paiement < p.date_decision;
