#!/bin/bash
# =============================================================================
# WRF Cron Launcher — 2 simulations/jour (00Z et 12Z)
# =============================================================================
# Prérequis : utilisateur dans le groupe docker
#   sudo usermod -aG docker $USER && newgrp docker
#
# À ajouter dans crontab (sur l'hôte) :
#   crontab -e
#
#   # Simulation 00Z : lancement à 06h UTC (données GFS disponibles ~4h après)
#   0 6 * * * bash /home/konseibo/ies/data/scripts/wrf_cron.sh 00 >> /home/konseibo/ies/data/logs/cron.log 2>&1
#   # Simulation 12Z : lancement à 18h UTC
#   0 18 * * * bash /home/konseibo/ies/data/scripts/wrf_cron.sh 12 >> /home/konseibo/ies/data/logs/cron.log 2>&1
#
# Lancement manuel :
#   bash ~/ies/data/scripts/wrf_cron.sh 12
#   bash ~/ies/data/scripts/wrf_cron.sh 00 20260623
# =============================================================================

CYCLE="${1:-12}"
DATE="${2:-$(date -u +%Y%m%d)}"
DATA_ROOT="/home/konseibo/ies/data"
SCRIPTS_DIR="${DATA_ROOT}/scripts"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Lancement pipeline ${DATE} ${CYCLE}Z"

docker run --rm \
    -v "${DATA_ROOT}:/data" \
    --ulimit stack=-1 \
    --name "wrf-run-${DATE}-${CYCLE}Z" \
    wrf-intel:4.7.1-slim \
    bash /data/scripts/wrf_pipeline.sh "${DATE}" "${CYCLE}"

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ✅ Pipeline ${DATE} ${CYCLE}Z terminé"
else
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ❌ Pipeline ${DATE} ${CYCLE}Z échoué (code $EXIT_CODE)"
fi
exit $EXIT_CODE
