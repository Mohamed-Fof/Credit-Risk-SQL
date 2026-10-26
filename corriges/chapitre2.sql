-- =============================================================================
-- Chapitre 2 — SQL analytique : CTE et fonctions de fenêtre — corrigés
-- Prérequis : chapitre 1 exécuté. « Aujourd'hui » = parametres_risque.date_reference (30/09/2026)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exercice guidé 1 — La situation de chaque prêt à la date d'arrêté
-- a) Une VUE : la règle de calcul du retard est écrite une seule fois, toutes les analyses la réutilisent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_situation_prets AS
WITH arrete AS (
    SELECT max(valeur_date) FILTER (WHERE cle = 'date_reference')  AS date_ref,
           max(valeur)      FILTER (WHERE cle = 'seuil_defaut_jours') AS seuil_defaut
    FROM parametres_risque
),
calcul AS (
    SELECT p.pret_id, p.client_id, p.note_risque, p.motif_pret, p.duree_mois, p.date_decision,
           a.date_ref, a.seuil_defaut,
           -- DPD : jours écoulés depuis la plus ancienne échéance échue et non soldée (0 si tout est à jour)
           coalesce(a.date_ref - min(e.date_echeance)
                      FILTER (WHERE e.date_echeance <= a.date_ref AND e.montant_paye < e.montant_du), 0) AS jours_retard,
           -- encours : capital pas encore remboursé (un paiement partiel couvre capital et intérêts au prorata)
           round(sum(e.part_capital * (1 - e.montant_paye / e.montant_du)), 2)                         AS encours,
           coalesce(sum(e.montant_du - e.montant_paye) FILTER (WHERE e.date_echeance <= a.date_ref), 0) AS impayes,
           count(*) FILTER (WHERE e.date_echeance > a.date_ref)                                        AS mois_restants
    FROM demandes_pret p
    JOIN echeancier_remboursements e USING (pret_id)
    CROSS JOIN arrete a
    WHERE p.statut_dossier = 'accorde' AND p.date_decision <= a.date_ref
    GROUP BY p.pret_id, a.date_ref, a.seuil_defaut    -- p.pret_id est la clé : les autres colonnes de p en dépendent
)
SELECT pret_id, client_id, note_risque, motif_pret, duree_mois, date_decision, date_ref,
       jours_retard, encours, impayes, mois_restants,
       jours_retard > seuil_defaut AS en_defaut       -- « plus de 90 jours » (art. 178 CRR)
FROM calcul;

-- b) Répartition du portefeuille vivant par tranche de retard
WITH tranches AS (
    SELECT encours,
           CASE WHEN jours_retard = 0  THEN '1. À jour'
                WHEN jours_retard <= 30 THEN '2. 1 à 30 jours'
                WHEN jours_retard <= 60 THEN '3. 31 à 60 jours'
                WHEN jours_retard <= 90 THEN '4. 61 à 90 jours'
                ELSE                         '5. Plus de 90 jours' END AS tranche
    FROM v_situation_prets
    WHERE encours > 0                                  -- les prêts soldés ne portent plus de risque
)
SELECT tranche, count(*) AS nb_prets, sum(encours) AS encours,
       -- SUM(SUM(...)) OVER () : le total de toutes les tranches, sans perdre le détail
       round(100 * sum(encours) / sum(sum(encours)) OVER (), 2) AS part_encours_pct
FROM tranches
GROUP BY tranche
ORDER BY tranche;

-- c) Indicateurs de portefeuille à risque : part de l'encours en retard de plus de 30 / 90 jours
SELECT sum(encours)                                                               AS encours_total,
       round(100 * sum(encours) FILTER (WHERE jours_retard > 30) / sum(encours), 2) AS par30_pct,
       round(100 * sum(encours) FILTER (WHERE en_defaut)         / sum(encours), 2) AS par90_pct
FROM v_situation_prets
WHERE encours > 0;

-- -----------------------------------------------------------------------------
-- Exercice guidé 2 — Provisions IFRS 9 : stage, EAD, PD, LGD et perte attendue (ECL)
-- -----------------------------------------------------------------------------
WITH parametres AS (
    SELECT max(valeur) FILTER (WHERE cle = 'lgd')                AS lgd,
           max(valeur) FILTER (WHERE cle = 'seuil_defaut_jours') AS seuil_defaut,
           max(valeur) FILTER (WHERE cle = 'seuil_stage2_jours') AS seuil_stage2
    FROM parametres_risque
),
stages AS (
    SELECT s.pret_id, s.encours AS ead, s.duree_mois,
           greatest(s.mois_restants, 1) AS mois_restants,       -- un prêt échu mais impayé : au moins 1 mois
           ps.probabilite_defaut        AS pd_vie_entiere,
           CASE WHEN s.jours_retard > prm.seuil_defaut THEN 3   -- défaut avéré
                WHEN s.jours_retard > prm.seuil_stage2 THEN 2   -- dégradation significative du risque
                ELSE 1 END AS stage
    FROM v_situation_prets s
    JOIN predictions_scoring_ml ps ON ps.pret_id = s.pret_id AND ps.est_champion
    CROSS JOIN parametres prm
    WHERE s.encours > 0
),
pertes AS (
    -- La PD du modèle porte sur toute la durée du prêt. Avec un risque mensuel constant,
    -- la probabilité de défaut sur m mois vaut 1 − (1 − PD)^(m / durée).
    SELECT st.*,
           CASE stage
               WHEN 3 THEN 1                                                                  -- défaut : PD = 1
               WHEN 2 THEN 1 - (1 - pd_vie_entiere) ^ (mois_restants::numeric / duree_mois)   -- vie restante
               ELSE        1 - (1 - pd_vie_entiere) ^ (least(mois_restants, 12)::numeric / duree_mois)  -- 12 mois
           END AS pd_utilisee
    FROM stages st
)
SELECT coalesce(stage::text, 'Total')                    AS stage_ifrs9,
       count(*)                                           AS nb_prets,
       sum(ead)                                           AS ead,
       round(100 * avg(pd_utilisee), 2)                   AS pd_moyenne_pct,
       round(sum(pd_utilisee * prm.lgd * ead), 2)         AS ecl,
       round(100 * sum(pd_utilisee * prm.lgd * ead) / sum(ead), 2) AS taux_couverture_pct
FROM pertes
CROSS JOIN parametres prm
GROUP BY ROLLUP (stage)                                  -- ROLLUP ajoute la ligne de total
ORDER BY stage;

-- Contrôle qualité : un prêt accordé sans score du modèle champion disparaîtrait du calcul (jointure interne)
SELECT count(*) AS prets_sans_score
FROM v_situation_prets s
WHERE NOT EXISTS (SELECT 1 FROM predictions_scoring_ml ps WHERE ps.pret_id = s.pret_id AND ps.est_champion);

-- -----------------------------------------------------------------------------
-- Exercice guidé 3 — Le modèle classe-t-il bien ? Déciles de risque (NTILE) sur l'échantillon test
-- -----------------------------------------------------------------------------
WITH test AS (
    SELECT ps.probabilite_defaut AS pd, s.en_defaut::int AS defaut
    FROM predictions_scoring_ml ps
    JOIN echantillons_modele em USING (pret_id)
    JOIN v_situation_prets s   USING (pret_id)
    WHERE ps.est_champion AND em.echantillon = 'test'    -- jamais sur l'apprentissage : résultats trop beaux
),
deciles AS (
    SELECT pd, defaut, NTILE(10) OVER (ORDER BY pd DESC) AS decile   -- décile 1 = les 10 % les plus risqués
    FROM test
)
SELECT decile,
       count(*)                     AS nb_prets,
       round(100 * avg(pd), 2)      AS pd_predite_pct,
       round(100 * avg(defaut), 2)  AS taux_defaut_observe_pct,
       sum(defaut)                  AS nb_defauts,
       -- courbe de gains : part cumulée des défauts captés en refusant les déciles 1 à k
       round(100.0 * sum(sum(defaut)) OVER (ORDER BY decile) / sum(sum(defaut)) OVER (), 1) AS defauts_captes_cumules_pct
FROM deciles
GROUP BY decile
ORDER BY decile;

-- -----------------------------------------------------------------------------
-- Exercice guidé 4 — Encaissements mensuels : cumul et moyenne mobile (cadre de fenêtre ROWS)
-- -----------------------------------------------------------------------------
WITH mensuel AS (
    SELECT date_trunc('month', date_paiement)::date AS mois, sum(montant_paye) AS encaisse
    FROM echeancier_remboursements
    WHERE date_paiement >= DATE '2025-10-01'
    GROUP BY 1
)
SELECT mois, encaisse,
       sum(encaisse) OVER (ORDER BY mois)                                           AS cumul_depuis_octobre,
       round(avg(encaisse) OVER (ORDER BY mois ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS moyenne_mobile_3_mois,
       round(100 * (encaisse / LAG(encaisse) OVER (ORDER BY mois) - 1), 1)          AS evolution_pct
FROM mensuel
ORDER BY mois;


-- =============================================================================
-- Exercices à faire seul — corrigés
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exercice seul 1 — Champion contre challengers : AUC, Gini, rappel et taux de refus de chaque modèle
-- AUC = probabilité qu'un prêt en défaut ait une PD plus élevée qu'un prêt sain (statistique de Mann-Whitney) :
--   AUC = (somme des rangs des défauts − n1(n1 + 1)/2) / (n1 × n0)
-- -----------------------------------------------------------------------------
WITH test AS (
    SELECT ps.version_modele, ps.est_champion, ps.probabilite_defaut AS pd, ps.decision, s.en_defaut::int AS defaut
    FROM predictions_scoring_ml ps
    JOIN echantillons_modele em USING (pret_id)
    JOIN v_situation_prets s   USING (pret_id)
    WHERE em.echantillon = 'test'
),
rangs AS (
    -- ex æquo : RANK() donne le premier rang du groupe ; on prend le rang moyen du groupe
    SELECT *, RANK() OVER (PARTITION BY version_modele ORDER BY pd)
              + (count(*) OVER (PARTITION BY version_modele, pd) - 1) / 2.0 AS rang
    FROM test
),
mesures AS (
    SELECT version_modele, est_champion,
           (sum(rang) FILTER (WHERE defaut = 1) - sum(defaut) * (sum(defaut) + 1) / 2.0)
             / (sum(defaut) * sum(1 - defaut))                                          AS auc,
           100.0 * count(*) FILTER (WHERE decision = 'refuser' AND defaut = 1) / sum(defaut) AS rappel_pct,
           100.0 * count(*) FILTER (WHERE decision = 'refuser') / count(*)                AS taux_refus_pct,
           100.0 * count(*) FILTER (WHERE decision = 'accorder' AND defaut = 1)
                 / count(*) FILTER (WHERE decision = 'accorder')                          AS defaut_parmi_accordes_pct
    FROM rangs
    GROUP BY version_modele, est_champion
)
SELECT version_modele, est_champion,
       round(auc, 3)                     AS auc,
       round(2 * auc - 1, 3)             AS gini,
       round(rappel_pct, 1)              AS rappel_pct,
       round(taux_refus_pct, 1)          AS taux_refus_pct,
       round(defaut_parmi_accordes_pct, 1) AS defaut_parmi_accordes_pct
FROM mesures
ORDER BY auc DESC;

-- -----------------------------------------------------------------------------
-- Exercice seul 2 — Matrice de transition (roll rates) entre fins de mois, avec LEAD
-- À une date passée D, une échéance est impayée si elle est échue à D et n'était pas soldée à D.
-- -----------------------------------------------------------------------------
WITH fins_de_mois AS (
    SELECT (d + INTERVAL '1 month - 1 day')::date AS date_arrete
    FROM generate_series(DATE '2025-09-01', DATE '2026-09-01', INTERVAL '1 month') AS d
),
-- Optimisation : ne garder que les échéances qui peuvent être impayées pendant la fenêtre
-- (échues avant la dernière fin de mois, pas encore soldées à la première). Filtrer AVANT de joindre : 7 s → 3 s.
impayes_possibles AS (
    SELECT pret_id, date_echeance, date_paiement
    FROM echeancier_remboursements
    WHERE date_echeance <= (SELECT max(date_arrete) FROM fins_de_mois)
      AND (date_paiement IS NULL OR date_paiement > (SELECT min(date_arrete) FROM fins_de_mois))
),
retards AS (
    SELECT f.date_arrete, p.pret_id,
           (p.date_premiere_echeance + (p.duree_mois - 1) * INTERVAL '1 month')::date AS fin_contrat,
           coalesce(f.date_arrete - min(e.date_echeance), 0)                           AS jours_retard
    FROM fins_de_mois f
    JOIN demandes_pret p ON p.statut_dossier = 'accorde' AND p.date_decision <= f.date_arrete
    -- LEFT JOIN : un prêt sans impayé n'a aucune ligne ici et garde un retard de 0
    LEFT JOIN impayes_possibles e
           ON e.pret_id = p.pret_id
          AND e.date_echeance <= f.date_arrete
          AND (e.date_paiement IS NULL OR e.date_paiement > f.date_arrete)
    GROUP BY f.date_arrete, p.pret_id
),
tranches AS (
    SELECT pret_id, date_arrete,
           CASE WHEN jours_retard = 0  THEN '1. À jour'
                WHEN jours_retard <= 30 THEN '2. 1 à 30 jours'
                WHEN jours_retard <= 60 THEN '3. 31 à 60 jours'
                WHEN jours_retard <= 90 THEN '4. 61 à 90 jours'
                ELSE                         '5. Plus de 90 jours' END AS tranche
    FROM retards
    WHERE jours_retard > 0 OR fin_contrat > date_arrete      -- on écarte les prêts terminés et soldés
),
transitions AS (
    SELECT tranche AS depart,
           LEAD(tranche) OVER (PARTITION BY pret_id ORDER BY date_arrete) AS arrivee   -- tranche le mois suivant
    FROM tranches
)
SELECT depart, count(*) AS nb_prets,
       round(100.0 * count(*) FILTER (WHERE arrivee = '1. À jour')           / count(*), 1) AS vers_a_jour,
       round(100.0 * count(*) FILTER (WHERE arrivee = '2. 1 à 30 jours')     / count(*), 1) AS vers_1_30,
       round(100.0 * count(*) FILTER (WHERE arrivee = '3. 31 à 60 jours')    / count(*), 1) AS vers_31_60,
       round(100.0 * count(*) FILTER (WHERE arrivee = '4. 61 à 90 jours')    / count(*), 1) AS vers_61_90,
       round(100.0 * count(*) FILTER (WHERE arrivee = '5. Plus de 90 jours') / count(*), 1) AS vers_plus_90
FROM transitions
WHERE arrivee IS NOT NULL                                     -- dernier mois observé : pas de mois suivant
GROUP BY depart
ORDER BY depart;

-- -----------------------------------------------------------------------------
-- Exercice seul 3 — Analyse par génération (vintage) : taux de défaut cumulé après 6, 12, 18, 24 mois
-- Date d'entrée en défaut = échéance de la première mensualité restée impayée plus de 90 jours, + 91 jours.
-- -----------------------------------------------------------------------------
WITH arrete AS (
    SELECT max(valeur_date) FILTER (WHERE cle = 'date_reference')     AS date_ref,
           max(valeur)      FILTER (WHERE cle = 'seuil_defaut_jours') AS seuil
    FROM parametres_risque
),
entrees_defaut AS (
    SELECT e.pret_id, min(e.date_echeance) + (a.seuil::int + 1) AS date_defaut
    FROM echeancier_remboursements e
    CROSS JOIN arrete a
    WHERE e.date_echeance <= a.date_ref
      AND coalesce(e.date_paiement, a.date_ref) - e.date_echeance > a.seuil
    GROUP BY e.pret_id, a.seuil
),
prets AS (
    SELECT p.pret_id, date_trunc('quarter', p.date_decision)::date AS generation,
           p.date_decision, d.date_defaut, a.date_ref
    FROM demandes_pret p
    CROSS JOIN arrete a
    LEFT JOIN entrees_defaut d USING (pret_id)
    WHERE p.statut_dossier = 'accorde'
),
courbes AS (
    SELECT g.generation, h.mois,
           count(*)                                                                    AS nb_observes,
           count(*) FILTER (WHERE g.date_defaut <= g.date_decision + h.mois * INTERVAL '1 month') AS nb_defauts
    FROM prets g
    CROSS JOIN (VALUES (6), (12), (18), (24)) AS h (mois)
    -- seuls les prêts déjà observés pendant h mois comptent, sinon les jeunes générations paraissent saines
    WHERE g.date_decision + h.mois * INTERVAL '1 month' <= g.date_ref
    GROUP BY g.generation, h.mois
),
tableau AS (
    SELECT generation,
           max(nb_observes) FILTER (WHERE mois = 6)                                   AS nb_prets,
           round(100.0 * sum(nb_defauts) FILTER (WHERE mois = 6)  / sum(nb_observes) FILTER (WHERE mois = 6), 1)  AS mob_6,
           round(100.0 * sum(nb_defauts) FILTER (WHERE mois = 12) / sum(nb_observes) FILTER (WHERE mois = 12), 1) AS mob_12,
           round(100.0 * sum(nb_defauts) FILTER (WHERE mois = 18) / sum(nb_observes) FILTER (WHERE mois = 18), 1) AS mob_18,
           round(100.0 * sum(nb_defauts) FILTER (WHERE mois = 24) / sum(nb_observes) FILTER (WHERE mois = 24), 1) AS mob_24
    FROM courbes
    GROUP BY generation
)
SELECT *, mob_12 - LAG(mob_12) OVER (ORDER BY generation) AS ecart_mob_12_vs_trimestre_precedent
FROM tableau
ORDER BY generation;

-- -----------------------------------------------------------------------------
-- Exercice seul 4 — a) Les 3 plus grosses expositions en défaut de chaque note de risque (RANK)
-- PostgreSQL n'a pas QUALIFY : on filtre le rang dans une requête englobante.
-- -----------------------------------------------------------------------------
WITH classement AS (
    SELECT s.note_risque, s.pret_id, c.nom_complet, s.encours, s.jours_retard,
           RANK() OVER (PARTITION BY s.note_risque ORDER BY s.encours DESC) AS rang,
           round(100 * s.encours / sum(s.encours) OVER (PARTITION BY s.note_risque), 2) AS part_de_la_note_pct
    FROM v_situation_prets s
    JOIN clients c USING (client_id)
    WHERE s.en_defaut
)
SELECT * FROM classement WHERE rang <= 3 ORDER BY note_risque, rang;

-- b) Signal précoce : prêts encore à jour (≤ 30 jours) dont le retard de paiement augmente
--    sur chacune des trois dernières échéances payées (LAG sur les échéances successives)
WITH delais AS (
    SELECT pret_id, num_echeance,
           date_paiement - date_echeance                                              AS retard,
           LAG(date_paiement - date_echeance, 1) OVER w                               AS retard_precedent,
           LAG(date_paiement - date_echeance, 2) OVER w                               AS retard_avant_precedent,
           ROW_NUMBER() OVER (PARTITION BY pret_id ORDER BY num_echeance DESC)        AS recence
    FROM echeancier_remboursements
    WHERE date_paiement IS NOT NULL
    WINDOW w AS (PARTITION BY pret_id ORDER BY num_echeance)
)
SELECT d.pret_id, s.note_risque, d.retard_avant_precedent, d.retard_precedent, d.retard, s.jours_retard, s.encours
FROM delais d
JOIN v_situation_prets s USING (pret_id)
WHERE d.recence = 1                                            -- la dernière échéance payée
  AND d.retard > d.retard_precedent AND d.retard_precedent > d.retard_avant_precedent
  AND d.retard > 0
  AND s.jours_retard <= 30
  AND s.encours > 0                                            -- piège : sans ce filtre, on surveille des prêts soldés
ORDER BY d.retard DESC, s.encours DESC
LIMIT 20;
