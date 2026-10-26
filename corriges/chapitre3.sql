-- =============================================================================
-- Chapitre 3 — Automatisation : fonctions, triggers et procédures stockées — corrigés
-- Prérequis : chapitres 1 et 2 exécutés (tables journal_statuts et provisions_mensuelles, vue v_situation_prets)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exercice guidé 1 — Des fonctions pour ne jamais réécrire une règle métier
-- -----------------------------------------------------------------------------
-- a) Lire un paramètre : une erreur explicite vaut mieux qu'un NULL silencieux
CREATE OR REPLACE FUNCTION fn_parametre(p_cle TEXT) RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_valeur NUMERIC;
BEGIN
    SELECT valeur INTO STRICT v_valeur FROM parametres_risque WHERE cle = p_cle;
    RETURN v_valeur;
EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE EXCEPTION 'Paramètre inconnu : %', p_cle;
END $$;

CREATE OR REPLACE FUNCTION fn_date_reference() RETURNS DATE
LANGUAGE sql STABLE AS $$
    SELECT valeur_date FROM parametres_risque WHERE cle = 'date_reference'
$$;

-- b) Le retard d'UN prêt à une date quelconque (passée ou actuelle)
CREATE OR REPLACE FUNCTION fn_jours_retard(p_pret_id BIGINT, p_date DATE) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT coalesce(p_date - min(e.date_echeance), 0)
    FROM echeancier_remboursements e
    WHERE e.pret_id = p_pret_id
      AND e.date_echeance <= p_date
      AND (e.date_paiement IS NULL OR e.date_paiement > p_date)    -- pas encore soldée à cette date
$$;

-- c) La même règle pour TOUT le portefeuille, en une seule requête (version ensembliste).
--    En PL/pgSQL et non en SQL : une fonction SQL est « dépliée » dans la requête qui l'appelle, et un
--    argument comme fn_date_reference() serait alors recalculé pour chacune des 1,1 million de lignes
--    (3,5 s au lieu de 0,2 s). Ici, p_date est évaluée une seule fois.
CREATE OR REPLACE FUNCTION fn_situation_prets(p_date DATE)
RETURNS TABLE (pret_id BIGINT, jours_retard INTEGER, encours NUMERIC, reste_du NUMERIC, mois_restants INTEGER)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT e.pret_id,
           coalesce(p_date - min(e.date_echeance)
                      FILTER (WHERE e.date_echeance <= p_date
                                AND (e.date_paiement IS NULL OR e.date_paiement > p_date)), 0),
           -- capital non remboursé à la date : impayé partiel au prorata, soldé après la date = encore dû
           round(sum(e.part_capital * CASE WHEN e.date_paiement IS NULL THEN 1 - e.montant_paye / e.montant_du
                                           WHEN e.date_paiement > p_date THEN 1
                                           ELSE 0 END), 2),
           sum(e.montant_du - e.montant_paye),
           (count(*) FILTER (WHERE e.date_echeance > p_date))::int
    FROM echeancier_remboursements e
    JOIN demandes_pret d ON d.pret_id = e.pret_id
    WHERE d.statut_dossier = 'accorde' AND d.date_decision <= p_date
    GROUP BY e.pret_id;                    -- colonnes préfixées (e., d.) : pas de conflit avec les noms en sortie
END $$;

-- d) Stage IFRS 9 et PD utilisée pour la provision (la logique de l'exercice guidé 2 du chapitre 2)
CREATE OR REPLACE FUNCTION fn_stage_ifrs9(p_jours_retard INTEGER) RETURNS SMALLINT
LANGUAGE sql STABLE AS $$
    SELECT (CASE WHEN p_jours_retard > fn_parametre('seuil_defaut_jours') THEN 3
                 WHEN p_jours_retard > fn_parametre('seuil_stage2_jours') THEN 2
                 ELSE 1 END)::smallint
$$;

CREATE OR REPLACE FUNCTION fn_pd_ifrs9(p_stage SMALLINT, p_pd_vie NUMERIC, p_mois_restants INTEGER, p_duree INTEGER)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_stage
               WHEN 3 THEN 1
               WHEN 2 THEN 1 - (1 - p_pd_vie) ^ (greatest(p_mois_restants, 1)::numeric / p_duree)
               ELSE        1 - (1 - p_pd_vie) ^ (least(greatest(p_mois_restants, 1), 12)::numeric / p_duree)
           END
$$;

-- Tests : retard d'un prêt en défaut, cohérence des deux versions, cohérence avec la vue du chapitre 2
SELECT fn_jours_retard(3, fn_date_reference()) AS retard_pret_3;

-- 32 410 appels ligne à ligne : 0,25 s, autant que la version ensembliste, grâce à l'index sur pret_id.
-- Sans cet index, chaque appel relirait 1,1 million de lignes : plus de 20 minutes.
SELECT count(*) AS desaccords_fonction_vs_ensembliste          -- attendu : 0
FROM fn_situation_prets(fn_date_reference()) s
WHERE s.jours_retard <> fn_jours_retard(s.pret_id, fn_date_reference());

SELECT count(*) AS desaccords_vue_vs_fonction                  -- attendu : 0
FROM v_situation_prets v
JOIN fn_situation_prets(fn_date_reference()) s USING (pret_id)
WHERE (v.jours_retard, v.encours) IS DISTINCT FROM (s.jours_retard, s.encours);

-- -----------------------------------------------------------------------------
-- Exercice guidé 2 — Trois triggers : protéger, recalculer, tracer
-- -----------------------------------------------------------------------------
-- a) BEFORE UPDATE, par ligne : protège l'échéancier (un BEFORE peut refuser ou compléter la ligne)
CREATE OR REPLACE FUNCTION fn_trg_proteger_echeance() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.pret_id, NEW.num_echeance, NEW.date_echeance, NEW.montant_du,
        NEW.part_capital, NEW.part_interets, NEW.capital_restant_du)
       IS DISTINCT FROM
       (OLD.pret_id, OLD.num_echeance, OLD.date_echeance, OLD.montant_du,
        OLD.part_capital, OLD.part_interets, OLD.capital_restant_du) THEN
        RAISE EXCEPTION 'Échéance % : les termes du contrat ne se modifient pas', OLD.echeance_id
            USING HINT = 'Un changement de contrat passe par un avenant et un nouvel échéancier.';
    END IF;
    IF NEW.montant_paye < OLD.montant_paye THEN
        RAISE EXCEPTION 'Échéance % : un paiement ne s''efface pas (% → %)',
                        OLD.echeance_id, OLD.montant_paye, NEW.montant_paye
            USING HINT = 'Enregistrer une écriture de régularisation.';
    END IF;
    IF NEW.montant_paye = NEW.montant_du AND NEW.date_paiement IS NULL THEN
        NEW.date_paiement := fn_date_reference();      -- échéance soldée : la date est complétée
    END IF;
    RETURN NEW;                                        -- BEFORE : la ligne renvoyée est celle qui sera écrite
END $$;

DROP TRIGGER IF EXISTS trg_proteger_echeance ON echeancier_remboursements;
CREATE TRIGGER trg_proteger_echeance
    BEFORE UPDATE ON echeancier_remboursements
    FOR EACH ROW EXECUTE FUNCTION fn_trg_proteger_echeance();

-- Tests de la protection (chaque instruction doit échouer ; dans DBeaver, exécute-les une par une)
-- UPDATE echeancier_remboursements SET montant_du = 1 WHERE echeance_id = 1;     -- termes du contrat
-- UPDATE echeancier_remboursements SET montant_paye = 0 WHERE echeance_id = 1;   -- paiement effacé

-- b) La règle du statut, écrite UNE fois : utilisée par le trigger et par le traitement de nuit
CREATE OR REPLACE FUNCTION fn_regle_statut(p_statut_actuel VARCHAR, p_jours_retard INTEGER, p_reste_du NUMERIC)
RETURNS VARCHAR LANGUAGE sql STABLE AS $$
    SELECT CASE
               WHEN p_reste_du = 0                                     THEN 'solde'
               -- pas de sortie automatique du défaut : période probatoire et décision humaine
               WHEN p_statut_actuel = 'en_defaut'                      THEN 'en_defaut'
               WHEN p_jours_retard > fn_parametre('seuil_defaut_jours') THEN 'en_defaut'
               WHEN p_jours_retard > 0                                 THEN 'en_retard'
               ELSE                                                         'sain'
           END
$$;

-- c) AFTER UPDATE, par instruction, avec tables de transition : recalcule le statut des prêts payés.
--    Une instruction qui modifie 1 000 échéances déclenche UN seul recalcul, pas 1 000.
CREATE OR REPLACE FUNCTION fn_trg_statut_apres_paiement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    WITH prets_payes AS (
        SELECT DISTINCT n.pret_id
        FROM nouvelles n
        JOIN anciennes a USING (echeance_id)
        WHERE n.montant_paye <> a.montant_paye
    ),
    recalcul AS (
        SELECT d.pret_id,
               fn_regle_statut(d.statut_pret,
                               fn_jours_retard(d.pret_id, fn_date_reference()),
                               (SELECT sum(e.montant_du - e.montant_paye)
                                FROM echeancier_remboursements e WHERE e.pret_id = d.pret_id)) AS statut
        FROM demandes_pret d
        JOIN prets_payes USING (pret_id)
    )
    UPDATE demandes_pret d
    SET statut_pret = r.statut
    FROM recalcul r
    WHERE d.pret_id = r.pret_id
      AND d.statut_pret IS DISTINCT FROM r.statut;      -- n'écrit (et ne journalise) que les vrais changements
    RETURN NULL;                                        -- AFTER : la valeur renvoyée est ignorée
END $$;

DROP TRIGGER IF EXISTS trg_statut_apres_paiement ON echeancier_remboursements;
CREATE TRIGGER trg_statut_apres_paiement
    AFTER UPDATE ON echeancier_remboursements
    REFERENCING OLD TABLE AS anciennes NEW TABLE AS nouvelles
    FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_statut_apres_paiement();

-- d) AFTER UPDATE, par ligne, avec condition WHEN : journal d'audit et alerte en cas de défaut
CREATE OR REPLACE FUNCTION fn_trg_journal_statut() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_retard INTEGER := fn_jours_retard(NEW.pret_id, fn_date_reference());
BEGIN
    INSERT INTO journal_statuts (pret_id, ancien_statut, nouveau_statut, jours_retard, date_effet)
    VALUES (NEW.pret_id, OLD.statut_pret, NEW.statut_pret, v_retard, fn_date_reference());
    IF NEW.statut_pret = 'en_defaut' THEN
        -- alerte : tout programme abonné (LISTEN alertes_defaut) la reçoit quand la transaction est validée
        PERFORM pg_notify('alertes_defaut',
                          json_build_object('pret_id', NEW.pret_id, 'jours_retard', v_retard)::text);
    END IF;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_journal_statut ON demandes_pret;
CREATE TRIGGER trg_journal_statut
    AFTER UPDATE OF statut_pret ON demandes_pret
    FOR EACH ROW
    WHEN (OLD.statut_pret IS DISTINCT FROM NEW.statut_pret)    -- la fonction n'est même pas appelée sinon
    EXECUTE FUNCTION fn_trg_journal_statut();

-- -----------------------------------------------------------------------------
-- Exercice guidé 3 — Deux procédures : l'encaissement d'un paiement et le traitement de nuit
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE enregistrer_paiement(p_pret_id BIGINT, p_montant NUMERIC, p_date DATE DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_date     DATE    := coalesce(p_date, fn_date_reference());
    v_restant  NUMERIC := p_montant;
    v_dossier  VARCHAR;
    v_du_total NUMERIC;
    v_part     NUMERIC;
    ech        RECORD;
BEGIN
    IF p_montant IS NULL OR p_montant <= 0 THEN
        RAISE EXCEPTION 'Montant invalide : %', p_montant;
    END IF;
    -- verrou sur le prêt : deux paiements simultanés du même prêt passent l'un après l'autre
    SELECT statut_dossier INTO v_dossier FROM demandes_pret WHERE pret_id = p_pret_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Prêt % inconnu', p_pret_id;
    ELSIF v_dossier <> 'accorde' THEN
        RAISE EXCEPTION 'Le prêt % n''est pas accordé', p_pret_id;
    END IF;
    SELECT sum(montant_du - montant_paye) INTO v_du_total
    FROM echeancier_remboursements WHERE pret_id = p_pret_id;
    IF p_montant > v_du_total THEN
        RAISE EXCEPTION 'Paiement de % € supérieur au reste dû du prêt % (% €)', p_montant, p_pret_id, v_du_total;
    END IF;

    FOR ech IN
        SELECT echeance_id, montant_du - montant_paye AS manquant
        FROM echeancier_remboursements
        WHERE pret_id = p_pret_id AND montant_paye < montant_du
        ORDER BY num_echeance                          -- la plus ancienne d'abord
    LOOP
        EXIT WHEN v_restant = 0;
        v_part := least(v_restant, ech.manquant);
        UPDATE echeancier_remboursements
        SET montant_paye  = montant_paye + v_part,
            date_paiement = CASE WHEN montant_paye + v_part = montant_du THEN v_date END
        WHERE echeance_id = ech.echeance_id;
        v_restant := v_restant - v_part;
    END LOOP;
    RAISE NOTICE 'Prêt % : % € encaissés le %', p_pret_id, p_montant, v_date;
END $$;

-- Le traitement de nuit : un trigger réagit à un événement ; le passage du temps n'en est pas un.
-- Sans paiement, un retard qui franchit 90 jours ne déclenche rien : il faut un traitement planifié.
CREATE OR REPLACE PROCEDURE actualiser_statuts(p_pret_id BIGINT DEFAULT NULL)   -- NULL = tout le portefeuille
LANGUAGE plpgsql AS $$
DECLARE
    v_nb INTEGER;
BEGIN
    WITH recalcul AS (
        SELECT d.pret_id, fn_regle_statut(d.statut_pret, s.jours_retard, s.reste_du) AS statut
        FROM demandes_pret d
        JOIN fn_situation_prets(fn_date_reference()) s USING (pret_id)
        WHERE p_pret_id IS NULL OR d.pret_id = p_pret_id
    )
    UPDATE demandes_pret d
    SET statut_pret = r.statut
    FROM recalcul r
    WHERE d.pret_id = r.pret_id AND d.statut_pret IS DISTINCT FROM r.statut;
    GET DIAGNOSTICS v_nb = ROW_COUNT;
    RAISE NOTICE '% statut(s) mis à jour au %', v_nb, fn_date_reference();
END $$;

-- Premier passage : tous les prêts chargés sont « sain », le traitement leur donne leur vrai statut
CALL actualiser_statuts();
SELECT statut_pret, count(*) AS nb_prets FROM demandes_pret GROUP BY statut_pret ORDER BY statut_pret;

-- Scénarios (dans une transaction annulée à la fin : la base reste intacte)
BEGIN;
CALL enregistrer_paiement(67, 916.55);     -- 1. prêt en retard de 3 jours : il règle tout son impayé
CALL enregistrer_paiement(61, 300);        -- 2. prêt en retard de 46 jours : paiement partiel
CALL enregistrer_paiement(9, 9422.92);     -- 3. prêt en défaut (21 mois restants) : il règle tous ses impayés
SELECT d.pret_id, d.statut_pret, fn_jours_retard(d.pret_id, fn_date_reference()) AS jours_retard
FROM demandes_pret d WHERE d.pret_id IN (9, 61, 67) ORDER BY d.pret_id;
-- attendu : 9 reste en_defaut malgré 0 jour de retard (période probatoire), 61 reste en_retard, 67 redevient sain
SELECT pret_id, ancien_statut, nouveau_statut, jours_retard, enregistre_par
FROM journal_statuts WHERE enregistre_le = now() ORDER BY journal_id;    -- now() : heure de début de la transaction
-- 4. Un paiement supérieur au reste dû est refusé (décommenter : l'erreur annule la transaction)
-- CALL enregistrer_paiement(32582, 1000000);
ROLLBACK;


-- =============================================================================
-- Exercices à faire seul — corrigés
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exercice seul 1 — Valider l'automatisation contre la réalité, puis faire passer le temps
-- -----------------------------------------------------------------------------
-- a) Les prêts « en_defaut » sont-ils exactement ceux qui ont fait défaut dans les données réelles ?
--    (\copy est une commande de psql ; dans DBeaver : clic droit sur la table > Importer des données)
CREATE TEMP TABLE verite_defauts (pret_id BIGINT PRIMARY KEY, defaut_reel SMALLINT NOT NULL);
\copy verite_defauts FROM 'donnees/verite_defauts.csv' WITH (FORMAT csv, HEADER true)
SELECT count(*) FILTER (WHERE v.defaut_reel = 1)                                   AS defauts_reels,
       count(*) FILTER (WHERE d.statut_pret = 'en_defaut')                         AS defauts_detectes,
       count(*) FILTER (WHERE (d.statut_pret = 'en_defaut') <> (v.defaut_reel = 1)) AS desaccords   -- attendu : 0
FROM demandes_pret d
JOIN verite_defauts v USING (pret_id);

-- b) Le prêt d'Awa Koné (1re échéance le 25/10/2026) : que se passe-t-il au 31/01/2027 sans aucun paiement ?
BEGIN;
UPDATE parametres_risque SET valeur_date = DATE '2027-01-31' WHERE cle = 'date_reference';
SELECT statut_pret AS avant_traitement FROM demandes_pret WHERE pret_id = 32582;      -- « sain » : aucun événement
CALL actualiser_statuts(32582);
SELECT statut_pret AS apres_traitement, fn_jours_retard(32582, fn_date_reference()) AS jours_retard
FROM demandes_pret WHERE pret_id = 32582;                                            -- « en_defaut », 98 jours
SELECT nouveau_statut, date_effet FROM journal_statuts WHERE pret_id = 32582;
ROLLBACK;

-- -----------------------------------------------------------------------------
-- Exercice seul 2 — La clôture mensuelle des provisions, rejouable sans doublon
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE cloture_mensuelle(p_date_arrete DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_nb  INTEGER;
    v_lgd NUMERIC := fn_parametre('lgd');
BEGIN
    IF p_date_arrete > fn_date_reference() THEN
        RAISE EXCEPTION 'Arrêté du % impossible : postérieur à la date de référence (%)',
                        p_date_arrete, fn_date_reference();
    END IF;
    INSERT INTO provisions_mensuelles (date_arrete, pret_id, jours_retard, stage_ifrs9, ead, pd_utilisee, lgd, ecl)
    SELECT p_date_arrete, s.pret_id, s.jours_retard, c.stage, s.encours, c.pd, v_lgd,
           round(c.pd * v_lgd * s.encours, 2)          -- l'ECL se recalcule à partir des colonnes stockées
    FROM fn_situation_prets(p_date_arrete) s
    JOIN demandes_pret d          ON d.pret_id = s.pret_id
    JOIN predictions_scoring_ml ps ON ps.pret_id = s.pret_id AND ps.est_champion
    CROSS JOIN LATERAL (SELECT fn_stage_ifrs9(s.jours_retard) AS stage) st
    CROSS JOIN LATERAL (SELECT st.stage,
                               round(fn_pd_ifrs9(st.stage, ps.probabilite_defaut, s.mois_restants, d.duree_mois), 6) AS pd) c
    WHERE s.encours > 0
    ON CONFLICT (date_arrete, pret_id) DO UPDATE           -- rejouer un arrêté remplace, ne duplique pas
        SET jours_retard = EXCLUDED.jours_retard, stage_ifrs9 = EXCLUDED.stage_ifrs9, ead = EXCLUDED.ead,
            pd_utilisee  = EXCLUDED.pd_utilisee,  lgd = EXCLUDED.lgd, ecl = EXCLUDED.ecl;
    GET DIAGNOSTICS v_nb = ROW_COUNT;
    RAISE NOTICE 'Arrêté du % : % prêts provisionnés', p_date_arrete, v_nb;
END $$;

-- Historique : les 12 derniers arrêtés de fin de mois (un CALL ne s'utilise pas dans un SELECT : bloc DO)
DO $$
DECLARE
    v_mois DATE;
BEGIN
    FOR v_mois IN
        SELECT (d + INTERVAL '1 month - 1 day')::date
        FROM generate_series(DATE '2025-10-01', DATE '2026-09-01', INTERVAL '1 month') AS d
    LOOP
        CALL cloture_mensuelle(v_mois);
    END LOOP;
END $$;

-- Évolution des provisions et dotation nette du mois (ce qui pèse sur le résultat de la banque)
WITH mensuel AS (
    SELECT date_arrete,
           sum(ead)                                     AS ead,
           sum(ecl)                                     AS ecl,
           sum(ecl) FILTER (WHERE stage_ifrs9 = 1)      AS ecl_stage1,
           sum(ecl) FILTER (WHERE stage_ifrs9 = 2)      AS ecl_stage2,
           sum(ecl) FILTER (WHERE stage_ifrs9 = 3)      AS ecl_stage3
    FROM provisions_mensuelles
    GROUP BY date_arrete
)
SELECT date_arrete, ead, ecl, ecl_stage1, ecl_stage2, ecl_stage3,
       ecl - LAG(ecl) OVER (ORDER BY date_arrete)       AS dotation_nette,
       round(100 * ecl / ead, 2)                        AS taux_couverture_pct
FROM mensuel
ORDER BY date_arrete;

-- Contrôle : rejouer le dernier arrêté ne change rien (idempotence)
CALL cloture_mensuelle(DATE '2026-09-30');
SELECT count(*) AS lignes_au_30_09, sum(ecl) AS ecl_au_30_09
FROM provisions_mensuelles WHERE date_arrete = DATE '2026-09-30';

-- -----------------------------------------------------------------------------
-- Exercice seul 3 (bonus) — Sécurité : chacun n'a que les droits dont il a besoin
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'analyste_risque') THEN
        CREATE ROLE analyste_risque NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'application_paiement') THEN
        CREATE ROLE application_paiement NOLOGIN;
    END IF;
END $$;

-- L'analyste lit tout, ne modifie rien
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyste_risque;

-- L'application d'encaissement n'écrit PAS dans les tables : elle appelle la procédure, qui s'exécute
-- avec les droits de son propriétaire (SECURITY DEFINER). search_path figé : sinon, un utilisateur
-- pourrait créer une fausse table ou fonction homonyme et détourner la procédure.
ALTER PROCEDURE enregistrer_paiement(BIGINT, NUMERIC, DATE) SECURITY DEFINER SET search_path = public, pg_temp;
REVOKE ALL ON PROCEDURE enregistrer_paiement(BIGINT, NUMERIC, DATE) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE enregistrer_paiement(BIGINT, NUMERIC, DATE) TO application_paiement;

-- Vérification (transaction annulée)
BEGIN;
SET LOCAL ROLE application_paiement;
CALL enregistrer_paiement(32582, 100);                          -- autorisé : passe par la procédure
DO $$
BEGIN
    UPDATE echeancier_remboursements SET montant_paye = montant_du WHERE pret_id = 32582;
    RAISE NOTICE 'ANOMALIE : écriture directe acceptée';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Écriture directe refusée, comme prévu';
END $$;
ROLLBACK;
