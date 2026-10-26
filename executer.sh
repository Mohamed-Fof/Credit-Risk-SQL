#!/bin/sh
# Reconstruit toute la base de zéro : schéma, chargement des données, puis les trois chapitres.
# Usage : ./executer.sh                       (base risk_analytics_db)
#         BASE=autre_base ./executer.sh       (une autre base, déjà créée avec createdb)
# Attention : le schéma commence par supprimer les tables existantes.
set -e
cd "$(dirname "$0")"                       # les chemins des scripts sont relatifs au projet
BASE="${BASE:-risk_analytics_db}"
export DATABASE_URL="${DATABASE_URL:-postgresql://localhost/$BASE}"

psql -X -q -d "$BASE" -v ON_ERROR_STOP=1 -f sql/01_schema.sql
"${PYTHON:-python3}" python/charger_donnees.py
for f in corriges/chapitre1.sql corriges/chapitre2.sql corriges/chapitre3.sql; do
    echo "== $f"
    psql -X -d "$BASE" -v ON_ERROR_STOP=1 -f "$f" > /dev/null
done
echo "Base $BASE reconstruite."
