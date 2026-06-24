#!/bin/bash
# =============================================================================
# WRF Operational Pipeline — Configurable
# =============================================================================
# Usage:
#   ./wrf_pipeline.sh YYYYMMDD HH
# =============================================================================

set -euo pipefail

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║              CONFIGURATION UTILISATEUR — À MODIFIER ICI                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ── Durée de simulation ───────────────────────────────────────────────────────
FORECAST_HOURS=15

# ── Domaine d01 : centre et étendue ──────────────────────────────────────────
REF_LAT=-21.24088                  # latitude centre (degrés N)
REF_LON=-175.14985                 # longitude centre (degrés E, négatif = W)
EXTENT_NS_D01=25.0                 # étendue nord-sud d01 (degrés)
EXTENT_EW_D01=25.0                 # étendue est-ouest d01 (degrés)
DX_D01_KM=12.0                     # résolution spatiale d01 (km)

# ── Domaine d02 : centre et étendue ──────────────────────────────────────────
REF_LAT_D02=-21.24088              # latitude centre d02
REF_LON_D02=-175.14985             # longitude centre d02
EXTENT_NS_D02=5.0                  # étendue nord-sud d02 (degrés)
EXTENT_EW_D02=5.0                  # étendue est-ouest d02 (degrés)
DX_D02_KM=2.4                      # résolution spatiale d02 (km)
# NOTE : DX_D01_KM doit être un multiple entier de DX_D02_KM
#        ex: 12.0/2.4=5 ✅  12.5/3=4.17 ❌  10/2=5 ✅

# ── Projection — sélection automatique selon la zone géographique ─────────────
# La projection est choisie en fonction de la latitude du centre du domaine.
# Vous pouvez forcer une projection en décommentant la ligne correspondante :
#   MAP_PROJ="lambert"    # latitudes moyennes (30°-60°)
#   MAP_PROJ="mercator"   # tropiques (|lat| < 30°)
#   MAP_PROJ="polar"      # polaire (|lat| > 60°)
#   MAP_PROJ="lat-lon"    # grille régulière (tous domaines, moins précis)
MAP_PROJ="auto"           # sélection automatique (recommandé)

# Calcul automatique des paramètres de projection
eval $(python3 - << PYEOF
lat = float(${REF_LAT})
lon = float(${REF_LON})
abs_lat = abs(lat)

if "${MAP_PROJ}" != "auto":
    proj = "${MAP_PROJ}"
elif abs_lat <= 30:
    proj = "mercator"
elif abs_lat <= 60:
    proj = "lambert"
else:
    proj = "polar"

# truelat1, truelat2, stand_lon selon la projection
if proj == "lambert":
    # Parallèles standards symétriques autour du centre
    truelat1 = lat - 15 if lat >= 0 else lat + 15
    truelat2 = lat + 15 if lat >= 0 else lat - 15
    # Clamp entre -89 et 89
    truelat1 = max(-89, min(89, truelat1))
    truelat2 = max(-89, min(89, truelat2))
    stand_lon = lon
elif proj == "mercator":
    # Un seul truelat = latitude du centre
    truelat1 = lat
    truelat2 = lat
    stand_lon = lon
elif proj == "polar":
    truelat1 = 90 if lat > 0 else -90
    truelat2 = 90 if lat > 0 else -90
    stand_lon = lon
else:  # lat-lon
    truelat1 = 0
    truelat2 = 0
    stand_lon = lon

print(f"MAP_PROJ={proj}")
print(f"TRUELAT1={truelat1:.4f}")
print(f"TRUELAT2={truelat2:.4f}")
print(f"STAND_LON={stand_lon:.5f}")
PYEOF
)

# ── Niveaux verticaux ─────────────────────────────────────────────────────────
E_VERT=45

# ── Physique ──────────────────────────────────────────────────────────────────
MP_PHYSICS=3
RA_LW=1
RA_SW=1
RADT=12
SF_SFCLAY=1
SF_SURFACE=2
BL_PBL=1
CU_D01=1
CU_D02=0

# ── Intervalles de sortie (minutes) ──────────────────────────────────────────
HIST_INTERVAL_D01=180
HIST_INTERVAL_D02=60
PLEV_INTERVAL_D01=180
PLEV_INTERVAL_D02=60

# ── Ressources ────────────────────────────────────────────────────────────────
NCPUS=4
MAX_DOM=2

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    FIN DE LA CONFIGURATION UTILISATEUR                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

DATA_ROOT="/data"
WRF_INSTALL="/opt/wrf-intel/WRF"
WPS_INSTALL="/opt/wrf-intel/WPS"
SCRIPTS_DIR="/data/scripts"
PYTHON="/opt/miniforge3/envs/wrf-py/bin/python"

# ── Date et cycle ─────────────────────────────────────────────────────────────
if [ $# -ge 2 ]; then
    DATE="$1"; CYCLE=$(printf "%02d" "$2")
elif [ $# -eq 1 ]; then
    DATE="$1"; HOUR=$(date -u +%H)
    CYCLE=$([ "$HOUR" -lt 12 ] && echo "00" || echo "12")
else
    DATE=$(date -u +%Y%m%d); HOUR=$(date -u +%H)
    CYCLE=$([ "$HOUR" -lt 12 ] && echo "00" || echo "12")
fi

YEAR=${DATE:0:4}; MONTH=${DATE:4:2}; DAY=${DATE:6:2}

# ── Calcul automatique des paramètres de grille (python3 uniquement) ──────────
eval $(python3 - << PYEOF
import math

dx1_km = float(${DX_D01_KM})
dx2_km = float(${DX_D02_KM})

# Vérifier que le ratio est entier
ratio = dx1_km / dx2_km
if abs(ratio - round(ratio)) > 0.01:
    print(f"echo 'ERREUR : dx_d01/dx_d02 = {ratio:.3f} — doit être un entier exactement'")
    print("exit 1")
    exit()
ratio = int(round(ratio))

# dx en mètres — arrondi à l'entier le plus proche
dx1_m = round(dx1_km * 1000)
dx2_m = round(dx2_km * 1000)
# Vérification de cohérence : dx1 = ratio * dx2
if dx1_m != ratio * dx2_m:
    # Ajuster dx2 pour que le ratio soit exact
    dx2_m = dx1_m // ratio
    dx2_km = dx2_m / 1000.0

# Étendue en km → points de grille
ew1 = float(${EXTENT_EW_D01}) * 111.0 / dx1_km
ns1 = float(${EXTENT_NS_D01}) * 111.0 / dx1_km

# Arrondir au nombre impair le plus proche (domaine centré)
def odd(n):
    n = int(n)
    return n if n % 2 == 1 else n + 1

e_we1 = max(odd(ew1), 11)
e_sn1 = max(odd(ns1), 11)

# d02 : (e_we - 1) doit être multiple du ratio
ew2 = float(${EXTENT_EW_D02}) * 111.0 / dx2_km
ns2 = float(${EXTENT_NS_D02}) * 111.0 / dx2_km

def round_to_ratio(n, r):
    n = int(n)
    n = math.ceil(n / r) * r + 1
    return max(n, r + 1)

e_we2 = round_to_ratio(ew2, ratio)
e_sn2 = round_to_ratio(ns2, ratio)

# Position de d02 dans d01
ci = (e_we1 + 1) / 2.0
cj = (e_sn1 + 1) / 2.0
lat_mid = (float(${REF_LAT}) + float(${REF_LAT_D02})) / 2.0
dlon = (float(${REF_LON_D02}) - float(${REF_LON})) * 111.0 * math.cos(math.radians(lat_mid)) / dx1_km
dlat = (float(${REF_LAT_D02}) - float(${REF_LAT})) * 111.0 / dx1_km

i_start = max(2, int(ci + dlon - (e_we2 / ratio) / 2) + 1)
j_start = max(2, int(cj + dlat - (e_sn2 / ratio) / 2) + 1)

i_end = i_start + e_we2 // ratio - 1
j_end = j_start + e_sn2 // ratio - 1

if i_end >= e_we1 or j_end >= e_sn1:
    print(f"echo 'ERREUR : d02 dépasse d01 (i_end={i_end}/{e_we1}, j_end={j_end}/{e_sn1})'")
    print("exit 1")
    exit()

# time_step : diviseur de 3600 proche de 6*dx_km, en dessous du ratio max
# Critère WRF : dt/dx <= 6 s/km pour Lambert à latitudes moyennes
dt_max = int(5.5 * dx1_km)  # marge de sécurité sous 6
for t in range(dt_max, dt_max - 10, -1):
    if t > 0 and 3600 % t == 0:
        dt = t
        break
else:
    dt = dt_max

# Région GFS
# Par défaut : coordonnées [-180, 180]
# Si croisement du méridien 180° (gfs_left > gfs_right) : convertir en [0, 360]
lon_center = float(${REF_LON})
half_ew = float(${EXTENT_EW_D01})/2 + 5

gfs_top = min(90, math.ceil(float(${REF_LAT}) + float(${EXTENT_NS_D01})/2 + 5))
gfs_bot = max(-90, math.floor(float(${REF_LAT}) - float(${EXTENT_NS_D01})/2 - 5))

gfs_left  = math.floor(lon_center - half_ew)
gfs_right = math.ceil(lon_center + half_ew)

# Normaliser en [-180, 180]
if gfs_left < -180: gfs_left += 360
if gfs_right > 180: gfs_right -= 360

# Si gfs_left > gfs_right → croisement du méridien 180°
# → convertir en [0, 360] pour NOMADS
if gfs_left > gfs_right:
    def to_360(lon):
        return int(lon % 360)
    gfs_left  = math.floor((lon_center - half_ew) % 360)
    gfs_right = math.ceil((lon_center + half_ew) % 360)

# Forecasts nécessaires
n_fcst = math.ceil(${FORECAST_HOURS} / 3)
fcst_hours = ' '.join(str(i*3).zfill(3) for i in range(0, n_fcst + 1))

print(f"RATIO={ratio}")
print(f"DX_D01={dx1_m}")
print(f"DX_D02={dx2_m}")
print(f"E_WE_D01={e_we1}")
print(f"E_SN_D01={e_sn1}")
print(f"E_WE_D02={e_we2}")
print(f"E_SN_D02={e_sn2}")
print(f"I_PARENT_START={i_start}")
print(f"J_PARENT_START={j_start}")
print(f"TIME_STEP={dt}")
print(f"GFS_TOPLAT={gfs_top}")
print(f"GFS_BOTTOMLAT={gfs_bot}")
print(f"GFS_LEFTLON={gfs_left}")
print(f"GFS_RIGHTLON={gfs_right}")
print(f"FCST_HOURS='{fcst_hours}'")
PYEOF
)

# ── Répertoires ───────────────────────────────────────────────────────────────
GFS_DIR="${DATA_ROOT}/gfs/${DATE}/${CYCLE}"
WPS_DIR="${DATA_ROOT}/wps/${DATE}/${CYCLE}"
WRF_DIR="${DATA_ROOT}/wrf/${DATE}/${CYCLE}"
WRF_OUT="${DATA_ROOT}/wrf_output/${DATE}/${CYCLE}"
POST_DIR="${DATA_ROOT}/postproc/${DATE}/${CYCLE}"
FIG_DIR="${DATA_ROOT}/figures/${DATE}/${CYCLE}"
LOG_DIR="${DATA_ROOT}/logs/${DATE}/${CYCLE}"

mkdir -p "$GFS_DIR" "$WPS_DIR" "$WRF_DIR" "$WRF_OUT" \
         "$POST_DIR" "$FIG_DIR" "$LOG_DIR"

# ── Nettoyage préventif des répertoires (sauf GFS déjà téléchargé) ───────────
# Évite tout conflit avec des fichiers d'une simulation précédente mal terminée
rm -rf "${WPS_DIR:?}"/*
rm -rf "${WRF_DIR:?}"/*
rm -rf "${WRF_OUT:?}"/*
rm -rf "${POST_DIR:?}"/*
rm -rf "${FIG_DIR:?}"/*
rm -rf "${LOG_DIR:?}"/*
# Note : GFS_DIR non nettoyé — les fichiers GFS sont réutilisables

LOG_FILE="${LOG_DIR}/pipeline.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"; }
die() { log "ERREUR FATALE : $*"; exit 1; }
check_success() { grep -q "$2" "$1" 2>/dev/null && return 0 || return 1; }

# ── Dates de simulation ───────────────────────────────────────────────────────
START_DATE="${YEAR}-${MONTH}-${DAY}_${CYCLE}:00:00"
END_EPOCH=$(date -u -d "${YEAR}-${MONTH}-${DAY}T${CYCLE}:00:00 ${FORECAST_HOURS} hours" +%s)
END_YEAR=$(date -u -d "@$END_EPOCH" +%Y)
END_MONTH=$(date -u -d "@$END_EPOCH" +%m)
END_DAY=$(date -u -d "@$END_EPOCH" +%d)
END_HOUR=$(date -u -d "@$END_EPOCH" +%H)
END_DATE="${END_YEAR}-${END_MONTH}-${END_DAY}_${END_HOUR}:00:00"
RUN_DAYS=$((FORECAST_HOURS / 24))
RUN_HOURS=$((FORECAST_HOURS % 24))

log "============================================================"
log "WRF Pipeline — ${DATE} ${CYCLE}Z"
log "Simulation   : ${START_DATE} → ${END_DATE} (${FORECAST_HOURS}h)"
log "d01          : ${E_WE_D01}x${E_SN_D01} pts, dx=${DX_D01_KM}km (${DX_D01}m)"
log "d02          : ${E_WE_D02}x${E_SN_D02} pts, dx=${DX_D02_KM}km (${DX_D02}m), ratio=1:${RATIO}"
log "i/j_start    : ${I_PARENT_START}, ${J_PARENT_START}"
log "Projection   : ${MAP_PROJ} (truelat1=${TRUELAT1}, truelat2=${TRUELAT2}, stand_lon=${STAND_LON})"
log "time_step    : ${TIME_STEP}s"
log "Région GFS   : ${GFS_BOTTOMLAT}N-${GFS_TOPLAT}N, ${GFS_LEFTLON}E-${GFS_RIGHTLON}E"
log "============================================================"

# ════════════════════════════════════════════════════════════════════════════
# ÉTAPE 1 : Téléchargement GFS NOMADS
# ════════════════════════════════════════════════════════════════════════════
log "ÉTAPE 1/6 : Téléchargement GFS NOMADS"

bash "${SCRIPTS_DIR}/download_gfs_nomads.sh" \
    "${DATE}" "${CYCLE}" "${GFS_DIR}" \
    "${GFS_TOPLAT}" "${GFS_BOTTOMLAT}" "${GFS_LEFTLON}" "${GFS_RIGHTLON}" \
    "${FCST_HOURS}" \
    >> "${LOG_DIR}/download.log" 2>&1 || die "Téléchargement GFS échoué"

N_FILES=$(ls "${GFS_DIR}"/gfs.t*.f* 2>/dev/null | wc -l)
log "  ✅ ${N_FILES} fichiers GFS — $(du -sh ${GFS_DIR} | cut -f1)"

# ════════════════════════════════════════════════════════════════════════════
# ÉTAPE 2 : WPS — geogrid
# ════════════════════════════════════════════════════════════════════════════
log "ÉTAPE 2/6 : WPS — geogrid"

cd "$WPS_DIR"
for f in geogrid.exe ungrib.exe metgrid.exe link_grib.csh geogrid ungrib metgrid util; do
    ln -sf "${WPS_INSTALL}/${f}" . 2>/dev/null || true
done
ln -sf "${WPS_INSTALL}/ungrib/Variable_Tables/Vtable.GFS" Vtable

cat > namelist.wps << EOF
&share
 wrf_core = 'ARW',
 max_dom = ${MAX_DOM},
 start_date = '${START_DATE}', '${START_DATE}',
 end_date   = '${END_DATE}',   '${END_DATE}',
 interval_seconds = 10800,
 io_form_geogrid = 2,
 opt_output_from_geogrid_path = '${WPS_DIR}/',
/
&geogrid
 parent_id         =   1,   1,
 parent_grid_ratio =   1,   ${RATIO},
 i_parent_start    =   1,   ${I_PARENT_START},
 j_parent_start    =   1,   ${J_PARENT_START},
 e_we              = ${E_WE_D01}, ${E_WE_D02},
 e_sn              = ${E_SN_D01}, ${E_SN_D02},
 geog_data_res     = 'default', 'default',
 dx = ${DX_D01},
 dy = ${DX_D01},
 map_proj = '${MAP_PROJ}',
 ref_lat   =  ${REF_LAT},
 ref_lon   =  ${REF_LON},
 truelat1  =  ${TRUELAT1},
 truelat2  =  ${TRUELAT2},
 stand_lon =  ${STAND_LON},
 geog_data_path = '${DATA_ROOT}/geog/WPS_GEOG',
/
&ungrib
 out_format = 'WPS',
 prefix = '${WPS_DIR}/FILE',
/
&metgrid
 fg_name = '${WPS_DIR}/FILE',
 io_form_metgrid = 2,
 opt_output_from_metgrid_path = '${WPS_DIR}/',
/
EOF

./geogrid.exe > "${LOG_DIR}/geogrid.log" 2>&1
check_success "${LOG_DIR}/geogrid.log" \
    "Successful completion of geogrid" || die "geogrid échoué"
log "  ✅ geogrid terminé"

# ════════════════════════════════════════════════════════════════════════════
# ÉTAPE 3 : WPS — ungrib + metgrid
# ════════════════════════════════════════════════════════════════════════════
log "ÉTAPE 3/6 : WPS — ungrib + metgrid"

cd "$WPS_DIR"
rm -f GRIBFILE.* FILE:* PFILE:*
./link_grib.csh "${GFS_DIR}"/gfs.t${CYCLE}z.pgrb2.0p25.f*

./ungrib.exe > "${LOG_DIR}/ungrib.log" 2>&1
check_success "${LOG_DIR}/ungrib.log" \
    "Successful completion of ungrib" || die "ungrib échoué"
log "  ✅ ungrib terminé"

./metgrid.exe > "${LOG_DIR}/metgrid.log" 2>&1
check_success "${LOG_DIR}/metgrid.log" \
    "Successful completion of metgrid" || die "metgrid échoué"
log "  ✅ metgrid terminé"

# ════════════════════════════════════════════════════════════════════════════
# ÉTAPE 4 : WRF — real.exe
# ════════════════════════════════════════════════════════════════════════════
log "ÉTAPE 4/6 : real.exe"

cd "$WRF_DIR"
for f in "${WRF_INSTALL}/main"/*.exe; do ln -sf "$f" . 2>/dev/null || true; done
for f in "${WRF_INSTALL}/run"/*.TBL \
         "${WRF_INSTALL}/run"/*.txt \
         "${WRF_INSTALL}/run"/*.formatted \
         "${WRF_INSTALL}/run"/*.dat \
         "${WRF_INSTALL}/run"/RRTM* \
         "${WRF_INSTALL}/run"/CAM* \
         "${WRF_INSTALL}/run"/MPTABLE.TBL \
         "${WRF_INSTALL}/run"/ozone* \
         "${WRF_INSTALL}/run"/aerosol* \
         "${WRF_INSTALL}/run"/tr* \
         "${WRF_INSTALL}/run"/grib*; do
    [ -e "$f" ] && ln -sf "$f" . 2>/dev/null || true
done

ln -sf "${WPS_DIR}"/met_em.d01.* .
[ "$MAX_DOM" -ge 2 ] && ln -sf "${WPS_DIR}"/met_em.d02.* . || true

FIRST_MET=$(ls "${WPS_DIR}"/met_em.d01.* | head -1)
NUM_METGRID_LEVELS=$(ncdump -h "$FIRST_MET" 2>/dev/null | \
    grep "^\s*num_metgrid_levels\s*=" | head -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')
NUM_METGRID_SOIL=$(ncdump -h "$FIRST_MET" 2>/dev/null | \
    grep "NUM_METGRID_SOIL_LEVELS" | head -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')
NUM_METGRID_LEVELS=${NUM_METGRID_LEVELS:-34}
NUM_METGRID_SOIL=${NUM_METGRID_SOIL:-4}
log "  num_metgrid_levels=${NUM_METGRID_LEVELS}, num_metgrid_soil_levels=${NUM_METGRID_SOIL}"

cat > namelist.input << EOF
 &time_control
 run_days                            = ${RUN_DAYS},
 run_hours                           = ${RUN_HOURS},
 run_minutes                         = 0,
 run_seconds                         = 0,
 start_year                          = ${YEAR}, ${YEAR},
 start_month                         = ${MONTH}, ${MONTH},
 start_day                           = ${DAY},   ${DAY},
 start_hour                          = ${CYCLE}, ${CYCLE},
 start_minute                        = 00,   00,
 start_second                        = 00,   00,
 end_year                            = ${END_YEAR}, ${END_YEAR},
 end_month                           = ${END_MONTH}, ${END_MONTH},
 end_day                             = ${END_DAY},   ${END_DAY},
 end_hour                            = ${END_HOUR},  ${END_HOUR},
 end_minute                          = 00,   00,
 end_second                          = 00,   00,
 interval_seconds                    = 10800,
 input_from_file                     = .true., .true.,
 history_interval                    = ${HIST_INTERVAL_D01}, ${HIST_INTERVAL_D02},
 frames_per_outfile                  = 1,    1,
 restart                             = .false.,
 restart_interval                    = 43200,
 io_form_history                     = 2,
 io_form_restart                     = 2,
 io_form_input                       = 2,
 io_form_boundary                    = 2,
 history_outname                     = '${WRF_OUT}/wrfout_d<domain>_<date>.nc',
 auxhist23_outname                   = '${WRF_OUT}/wrfplev_d<domain>_<date>.nc',
 auxhist23_interval                  = ${PLEV_INTERVAL_D01}, ${PLEV_INTERVAL_D02},
 frames_per_auxhist23                = 1,    1,
 io_form_auxhist23                   = 2,
 /

 &domains
 time_step                           = ${TIME_STEP},
 time_step_fract_num                 = 0,
 time_step_fract_den                 = 1,
 max_dom                             = ${MAX_DOM},
 e_we                                = ${E_WE_D01}, ${E_WE_D02},
 e_sn                                = ${E_SN_D01}, ${E_SN_D02},
 e_vert                              = ${E_VERT},   ${E_VERT},
 p_top_requested                     = 5000,
 num_metgrid_levels                  = ${NUM_METGRID_LEVELS},
 num_metgrid_soil_levels             = ${NUM_METGRID_SOIL},
 dx                                  = ${DX_D01}, ${DX_D02},
 dy                                  = ${DX_D01}, ${DX_D02},
 grid_id                             = 1,  2,
 parent_id                           = 0,  1,
 i_parent_start                      = 1,  ${I_PARENT_START},
 j_parent_start                      = 1,  ${J_PARENT_START},
 parent_grid_ratio                   = 1,  ${RATIO},
 parent_time_step_ratio              = 1,  ${RATIO},
 feedback                            = 1,
 smooth_option                       = 0,
 /

 &physics
 mp_physics                          = ${MP_PHYSICS},  ${MP_PHYSICS},
 ra_lw_physics                       = ${RA_LW},  ${RA_LW},
 ra_sw_physics                       = ${RA_SW},  ${RA_SW},
 radt                                = ${RADT}, ${RADT},
 sf_sfclay_physics                   = ${SF_SFCLAY},  ${SF_SFCLAY},
 sf_surface_physics                  = ${SF_SURFACE},  ${SF_SURFACE},
 bl_pbl_physics                      = ${BL_PBL},  ${BL_PBL},
 bldt                                = 0,  0,
 cu_physics                          = ${CU_D01},  ${CU_D02},
 cudt                                = 5,  0,
 isfflx                              = 1,
 ifsnow                              = 1,
 icloud                              = 1,
 surface_input_source                = 3,
 num_soil_layers                     = 4,
 sf_urban_physics                    = 0,  0,
 /

 &dynamics
 w_damping                           = 0,
 diff_opt                            = 1,  1,
 km_opt                              = 4,  4,
 diff_6th_opt                        = 0,  0,
 diff_6th_factor                     = 0.12, 0.12,
 base_temp                           = 290.,
 damp_opt                            = 3,
 zdamp                               = 5000.,
 dampcoef                            = 0.2,
 khdif                               = 0,  0,
 kvdif                               = 0,  0,
 non_hydrostatic                     = .true., .true.,
 moist_adv_opt                       = 1,  1,
 scalar_adv_opt                      = 1,  1,
 /

 &bdy_control
 spec_bdy_width                      = 5,
 spec_zone                           = 1,
 relax_zone                          = 4,
 specified                           = .true., .false.,
 nested                              = .false., .true.,
 /

 &diags
 p_lev_diags                         = 1,
 num_press_levels                    = 15,
 press_levels                        = 100000., 92500., 85000., 70000., 60000., 50000.,
                                       40000., 30000., 25000., 20000., 15000., 10000.,
                                       7000.,  5000.,  3000.,
 use_tot_or_hyd_p                    = 2,
 /

 &namelist_quilt
 nio_tasks_per_group                 = 0,
 nio_groups                          = 1,
 /
EOF

mpirun -np ${NCPUS} ./real.exe > "${LOG_DIR}/real.log" 2>&1
cp rsl.out.0000   "${LOG_DIR}/rsl_real.out"   2>/dev/null || true
cp rsl.error.0000 "${LOG_DIR}/rsl_real.error" 2>/dev/null || true
check_success "${LOG_DIR}/rsl_real.out" \
    "SUCCESS COMPLETE REAL_EM INIT" || die "real.exe échoué"
log "  ✅ real.exe terminé"

# ════════════════════════════════════════════════════════════════════════════
# ÉTAPE 5 : WRF — wrf.exe avec copie périodique des rsl vers logs/
# ════════════════════════════════════════════════════════════════════════════
log "ÉTAPE 5/6 : wrf.exe"
log "  Suivi depuis l'hôte : ${LOG_DIR}/rsl.out.0000"

# Lancer la copie périodique des rsl en arrière-plan (toutes les 30s)
RSL_WATCHER_PID=""
(
    while true; do
        cp "${WRF_DIR}/rsl.out.0000"   "${LOG_DIR}/rsl.out.0000"   2>/dev/null || true
        cp "${WRF_DIR}/rsl.error.0000" "${LOG_DIR}/rsl.error.0000" 2>/dev/null || true
        sleep 30
    done
) &
RSL_WATCHER_PID=$!

T_START=$(date +%s)
mpirun -np ${NCPUS} ./wrf.exe > "${LOG_DIR}/wrf.log" 2>&1
T_END=$(date +%s)
ELAPSED=$((T_END - T_START))

# Arrêter le watcher
kill $RSL_WATCHER_PID 2>/dev/null || true

# Copie finale des rsl
cp rsl.out.0000   "${LOG_DIR}/rsl_wrf_final.out"   2>/dev/null || true
cp rsl.error.0000 "${LOG_DIR}/rsl_wrf_final.error" 2>/dev/null || true
cp rsl.out.0000   "${LOG_DIR}/rsl.out.0000"         2>/dev/null || true
cp rsl.error.0000 "${LOG_DIR}/rsl.error.0000"       2>/dev/null || true

check_success "${LOG_DIR}/rsl_wrf_final.out" \
    "SUCCESS COMPLETE WRF" || die "wrf.exe échoué"
log "  ✅ wrf.exe terminé en ${ELAPSED}s"

N_WRFOUT=$(ls "${WRF_OUT}"/wrfout_d01_*.nc 2>/dev/null | wc -l)
N_PLEV=$(ls "${WRF_OUT}"/wrfplev_d01_*.nc 2>/dev/null | wc -l)
log "  wrfout d01 : ${N_WRFOUT} | wrfplev d01 : ${N_PLEV}"

# ════════════════════════════════════════════════════════════════════════════
# ÉTAPE 6 : Post-traitement + Visualisation
# ════════════════════════════════════════════════════════════════════════════
log "ÉTAPE 6/6 : Post-traitement + Visualisation"

$PYTHON "${SCRIPTS_DIR}/wrf_postproc.py" \
    --indir "${WRF_OUT}" --outdir "${POST_DIR}" \
    >> "${LOG_DIR}/postproc.log" 2>&1
log "  ✅ Post-traitement terminé"

$PYTHON "${SCRIPTS_DIR}/wrf_viz.py" \
    --indir "${POST_DIR}" --outdir "${FIG_DIR}" \
    >> "${LOG_DIR}/viz.log" 2>&1
log "  ✅ Visualisation terminée"

# ── Nettoyage ─────────────────────────────────────────────────────────────────
rm -f "${WPS_DIR}"/FILE:* "${WPS_DIR}"/PFILE:* "${WPS_DIR}"/GRIBFILE.*

log "============================================================"
log "✅ Pipeline terminé : ${DATE} ${CYCLE}Z"
log "   Sorties : ${WRF_OUT}"
log "   Logs    : ${LOG_DIR}"
log "============================================================"
