#!/usr/bin/env python3
"""
WRF Post-Processing — Version opérationnelle rapide
-----------------------------------------------------
Lit wrfout_d0* (variables natives + diagnostiques wrf-python)
et wrfplev_d0* (variables aux niveaux de pression, déjà interpolées par WRF).
Produit un NetCDF consolidé par domaine et par pas de temps.

Usage:
    python wrf_postproc.py --date 20230601 --cycle 12 \
                           --indir /data/wrf_output \
                           --outdir /data/wrf_output/postproc
"""

import argparse
import glob
import os
from pathlib import Path

import numpy as np
import xarray as xr
from netCDF4 import Dataset
from wrf import getvar, to_np, latlon_coords, extract_times, ALL_TIMES


# ── Variables diagnostiques à calculer depuis wrfout ───────────────────────
DIAG_VARS = [
    "T2",           # Température 2m (K)
    "U10",          # Vent U 10m
    "V10",          # Vent V 10m
    "PSFC",         # Pression de surface
    "RAINNC",       # Pluie non-convective
    "RAINC",        # Pluie convective
    "SWDOWN",       # Rayonnement SW descendant
    "GLW",          # Rayonnement LW descendant
    "HFX",          # Flux de chaleur sensible
    "LH",           # Flux de chaleur latente
    "TSK",          # Température de peau
    "SNOWH",        # Épaisseur de neige
]

DIAG_WRF_PYTHON = [
    "slp",          # Pression au niveau de la mer
    "pw",           # Eau précipitable
    "td2",          # Point de rosée 2m
    "rh2",          # Humidité relative 2m
    "wspd_wdir10",  # Vitesse et direction du vent 10m
    "helicity",     # Hélicité
    "updraft_helicity",  # Hélicité de courant ascendant
]

# Variables dans wrfplev à conserver
PLEV_VARS = ["UU_PL", "VV_PL", "TT_PL", "RH_PL", "GHT_PL", "TD_PL", "S_PL"]


def process_pair(wrfout_file, wrfplev_file, outdir):
    """Traite une paire wrfout + wrfplev et produit un NetCDF consolidé."""
    fname = Path(wrfout_file).name
    domain = "d01" if "_d01_" in fname else "d02"
    date_tag = fname.split(f"{domain}_")[1].replace(":", "-")
    # Supprimer l'extension .nc si présente dans date_tag
    if date_tag.endswith(".nc"):
        date_tag = date_tag[:-3]
    outfile = Path(outdir) / f"diag_{domain}_{date_tag}.nc"

    print(f"  {fname} + plev → {outfile.name}")

    nc = Dataset(wrfout_file)
    times = extract_times(nc, ALL_TIMES)
    nt = len(times)

    # Convertir les temps wrf-python en datetime64 numpy pour xarray
    import pandas as pd
    time_coords = pd.to_datetime([str(t) for t in times])
    lats, lons = latlon_coords(getvar(nc, "T2", timeidx=0))
    lat_np = to_np(lats)
    lon_np = to_np(lons)

    ds_vars = {}

    # ── Variables natives wrfout ──
    for vname in DIAG_VARS:
        try:
            data = np.array([to_np(getvar(nc, vname, timeidx=t)) for t in range(nt)])
            ds_vars[vname] = xr.DataArray(data, dims=["time", "south_north", "west_east"])
        except Exception:
            pass

    # Pluie totale et T2 en Celsius
    if "RAINNC" in ds_vars and "RAINC" in ds_vars:
        ds_vars["RAIN_TOT"] = ds_vars["RAINNC"] + ds_vars["RAINC"]
        ds_vars["RAIN_TOT"].attrs = {"units": "mm", "description": "Total precip"}
    if "T2" in ds_vars:
        ds_vars["T2C"] = ds_vars["T2"] - 273.15
        ds_vars["T2C"].attrs = {"units": "degC", "description": "Temperature 2m"}

    # ── Diagnostiques wrf-python ──
    for vname in DIAG_WRF_PYTHON:
        try:
            data_list = [to_np(getvar(nc, vname, timeidx=t)) for t in range(nt)]
            arr = np.array(data_list)
            if vname == "wspd_wdir10":
                ds_vars["WSPD10"] = xr.DataArray(arr[:, 0], dims=["time", "south_north", "west_east"],
                                                  attrs={"units": "m/s"})
                ds_vars["WDIR10"] = xr.DataArray(arr[:, 1], dims=["time", "south_north", "west_east"],
                                                  attrs={"units": "deg"})
            else:
                ds_vars[vname.upper()] = xr.DataArray(
                    arr if arr.ndim == 3 else arr,
                    dims=["time", "south_north", "west_east"] if arr.ndim == 3
                         else ["time", "bottom_top", "south_north", "west_east"],
                    attrs={"units": ""}
                )
        except Exception:
            pass

    # ── CAPE/CIN ──
    try:
        cape_list, cin_list, lcl_list, lfc_list = [], [], [], []
        for t in range(nt):
            c2d = getvar(nc, "cape_2d", timeidx=t)
            c2d_np = to_np(c2d)
            cape_list.append(c2d_np[0])
            cin_list.append(c2d_np[1])
            lcl_list.append(c2d_np[2])
            lfc_list.append(c2d_np[3])
        for name, data, unit in [
            ("CAPE", cape_list, "J/kg"),
            ("CIN",  cin_list,  "J/kg"),
            ("LCL",  lcl_list,  "m"),
            ("LFC",  lfc_list,  "m"),
        ]:
            ds_vars[name] = xr.DataArray(
                np.array(data), dims=["time", "south_north", "west_east"],
                attrs={"units": unit}
            )
    except Exception as e:
        print(f"    ⚠ CAPE/CIN: {e}")

    nc.close()

    # ── Variables aux niveaux de pression depuis wrfplev ──
    if wrfplev_file and os.path.exists(wrfplev_file):
        try:
            ds_plev = xr.open_dataset(wrfplev_file, engine="netcdf4",
                                       mask_and_scale=False, decode_cf=False)
            for vname in PLEV_VARS:
                if vname in ds_plev:
                    ds_vars[vname] = ds_plev[vname]
            plevs = ds_plev.get("num_plevs", None)
            ds_plev.close()
        except Exception as e:
            print(f"    ⚠ wrfplev: {e}")

    # ── Construire le dataset final ──
    # Copier les attributs WRF nécessaires pour la projection
    wrf_attrs_to_keep = [
        "MAP_PROJ", "CEN_LAT", "CEN_LON", "TRUELAT1", "TRUELAT2",
        "STAND_LON", "DX", "DY", "MOAD_CEN_LAT", "POLE_LAT", "POLE_LON"
    ]
    nc2 = Dataset(wrfout_file)
    proj_attrs = {k: nc2.getncattr(k) for k in wrf_attrs_to_keep
                  if k in nc2.ncattrs()}
    nc2.close()

    ds = xr.Dataset(
        ds_vars,
        coords={
            "time": time_coords,
            "lat":  (["south_north", "west_east"], lat_np),
            "lon":  (["south_north", "west_east"], lon_np),
        },
        attrs={"source": wrfout_file, "created_by": "wrf_postproc.py", **proj_attrs}
    )
    ds.to_netcdf(outfile)
    print(f"    ✅ {outfile.name} — {list(ds_vars.keys())}")
    return outfile


def main():
    parser = argparse.ArgumentParser(description="WRF Post-Processing rapide")
    parser.add_argument("--indir",  default="/data/wrf_output")
    parser.add_argument("--outdir", default="/data/wrf_output/postproc")
    parser.add_argument("--domain", type=int, choices=[1, 2], default=None)
    parser.add_argument("--date",   default=None, help="Date YYYYMMDD")
    parser.add_argument("--cycle",  default=None, help="Cycle 00/06/12/18")
    args = parser.parse_args()

    Path(args.outdir).mkdir(parents=True, exist_ok=True)

    # Pattern de recherche
    dom_pat = f"d0{args.domain}" if args.domain else "d0[12]"
    date_pat = f"*{args.date}*" if args.date else "*"
    wrfout_files = sorted(glob.glob(
        os.path.join(args.indir, f"wrfout_{dom_pat}_{date_pat}")
    ))

    print(f"Fichiers wrfout trouvés : {len(wrfout_files)}")

    for wf in wrfout_files:
        # Trouver le wrfplev correspondant
        plev_file = wf.replace("wrfout_", "wrfplev_")
        if not os.path.exists(plev_file):
            plev_file = None
        process_pair(wf, plev_file, args.outdir)

    print(f"\n✅ Post-traitement terminé → {args.outdir}")


if __name__ == "__main__":
    main()
