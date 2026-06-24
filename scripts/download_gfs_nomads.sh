#!/bin/bash
# =============================================================================
# Téléchargement GFS depuis NOMADS avec filtre géographique et variables WRF
# Niveaux et variables validés depuis le fichier .idx réel de NOMADS
# =============================================================================
# Usage:
#   ./download_gfs_nomads.sh YYYYMMDD HH OUTDIR [TOPLAT BOTTOMLAT LEFTLON RIGHTLON] ["000 003 ... 036"]
# =============================================================================

set -euo pipefail

DATE="${1}"
CYCLE="${2}"
OUTDIR="${3:-/data/gfs/${DATE}/${CYCLE}}"
CYCLE=$(printf "%02d" $CYCLE)

# Région géographique (arguments optionnels, sinon valeurs par défaut)
TOPLAT="${4:-72}"
BOTTOMLAT="${5:-28}"
LEFTLON="${6:--110}"
RIGHTLON="${7:--30}"

# Forecasts (argument optionnel, sinon 36h par défaut)
FCST_HOURS="${8:-000 003 006 009 012 015 018 021 024 027 030 033 036}"

mkdir -p "$OUTDIR"

SUBREGION="subregion=&toplat=${TOPLAT}&bottomlat=${BOTTOMLAT}&leftlon=${LEFTLON}&rightlon=${RIGHTLON}"

# ── Variables nécessaires pour WRF (Vtable.GFS) ──────────────────────────────
VARS=""
VARS="${VARS}&var_HGT=on"       # Géopotentiel
VARS="${VARS}&var_TMP=on"       # Température
VARS="${VARS}&var_UGRD=on"      # Vent U
VARS="${VARS}&var_VGRD=on"      # Vent V
VARS="${VARS}&var_RH=on"        # Humidité relative
VARS="${VARS}&var_SPFH=on"      # Humidité spécifique
VARS="${VARS}&var_PRES=on"      # Pression
VARS="${VARS}&var_PRMSL=on"     # Pression réduite au niveau de la mer
VARS="${VARS}&var_MSLET=on"     # Pression MSL (MSLET, non lissée)
VARS="${VARS}&var_TSOIL=on"     # Température du sol
VARS="${VARS}&var_SOILW=on"     # Humidité du sol
VARS="${VARS}&var_WEASD=on"     # Eau équivalente de la neige
VARS="${VARS}&var_SNOD=on"      # Épaisseur de neige
VARS="${VARS}&var_LAND=on"      # Masque terre/mer
VARS="${VARS}&var_ICEC=on"      # Fraction de glace de mer
VARS="${VARS}&var_ICETK=on"     # Épaisseur de glace de mer

# ── Tous les niveaux verticaux GFS ───────────────────────────────────────────
# all_lev=on récupère tous les niveaux disponibles (pression, surface, sol, etc.)
LEVS="all_lev=on"

# ── Base URL NOMADS ───────────────────────────────────────────────────────────
NOMADS_BASE="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
DIR_PATH="%2Fgfs.${DATE}%2F${CYCLE}%2Fatmos"

echo "============================================================"
echo "Téléchargement GFS NOMADS (filtre géographique + variables)"
echo "Date : ${DATE} — Cycle : ${CYCLE}Z"
echo "Région : ${BOTTOMLAT}N-${TOPLAT}N, ${LEFTLON}E-${RIGHTLON}E"
echo "Forecasts : ${FCST_HOURS}"
echo "Sortie : ${OUTDIR}"
echo "============================================================"

TOTAL=$(echo $FCST_HOURS | wc -w)
COUNT=0
ERRORS=0

for FHR in $FCST_HOURS; do
    COUNT=$((COUNT + 1))
    FILE="gfs.t${CYCLE}z.pgrb2.0p25.f${FHR}"
    DEST="${OUTDIR}/${FILE}"

    if [ -f "$DEST" ] && [ $(stat -c%s "$DEST") -gt 100000 ]; then
        echo "[${COUNT}/${TOTAL}] Déjà téléchargé : ${FILE} ($(du -h $DEST | cut -f1))"
        continue
    fi

    URL="${NOMADS_BASE}?file=${FILE}&${LEVS}${VARS}&${SUBREGION}&dir=${DIR_PATH}"

    echo "[${COUNT}/${TOTAL}] Téléchargement : ${FILE}..."

    wget -q --show-progress \
        --timeout=120 --tries=3 \
        -O "${DEST}" \
        "${URL}" 2>&1

    SIZE=$(stat -c%s "${DEST}" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 100000 ]; then
        echo "  ✅ ${FILE} — $(du -h $DEST | cut -f1)"
    else
        echo "  ❌ ERREUR : ${FILE} trop petit (${SIZE} octets)"
        rm -f "${DEST}"
        ERRORS=$((ERRORS + 1))
    fi

    # Pause obligatoire entre requêtes NOMADS (10s recommandé)
    [ $COUNT -lt $TOTAL ] && sleep 10
done

echo "============================================================"
echo "Téléchargement terminé : $((TOTAL - ERRORS))/${TOTAL} fichiers"
[ -d "$OUTDIR" ] && echo "Taille totale : $(du -sh ${OUTDIR} | cut -f1)"
if [ $ERRORS -gt 0 ]; then
    echo "⚠ ${ERRORS} fichier(s) en erreur"
    exit 1
fi
echo "✅ Tous les fichiers téléchargés avec succès"
exit 0
