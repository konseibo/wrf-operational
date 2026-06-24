#!/usr/bin/env python3
"""
WRF Visualization — PNG (matplotlib)
--------------------------------------
Génère des cartes PNG par variable et par pas de temps.
Utilise matplotlib pur (sans cartopy) pour éviter les bugs
shapely/cartopy avec les domaines proches du méridien 180°.

Usage:
    python wrf_viz.py --indir /data/postproc/20260623/00 \
                      --outdir /data/figures/20260623/00 \
                      --domain 2
"""

import argparse
import glob
import os
from pathlib import Path

import numpy as np
import xarray as xr
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import AutoMinorLocator


PANELS = {
    "T2C":      {"title": "Température 2m",          "unit": "°C",    "cmap": "RdBu_r",  "vmin": -10,  "vmax": 35},
    "CAPE":     {"title": "CAPE",                     "unit": "J/kg",  "cmap": "YlOrRd",  "vmin": 0,    "vmax": 3000},
    "CIN":      {"title": "CIN",                      "unit": "J/kg",  "cmap": "Blues_r", "vmin": -300, "vmax": 0},
    "RAIN_TOT": {"title": "Pluie totale",             "unit": "mm",    "cmap": "Blues",   "vmin": 0,    "vmax": 100},
    "WSPD10":   {"title": "Vent 10m",                 "unit": "m/s",   "cmap": "YlOrRd",  "vmin": 0,    "vmax": 25},
    "SLP":      {"title": "Pression niveau mer",      "unit": "hPa",   "cmap": "RdBu_r",  "vmin": 990,  "vmax": 1030},
    "PW":       {"title": "Eau précipitable",         "unit": "kg/m²", "cmap": "YlGnBu",  "vmin": 0,    "vmax": 60},
    "TD2":      {"title": "Point de rosée 2m",        "unit": "°C",    "cmap": "Greens",  "vmin": -20,  "vmax": 30},
    "RH2":      {"title": "Humidité relative 2m",     "unit": "%",     "cmap": "YlGnBu",  "vmin": 0,    "vmax": 100},
    "HELICITY": {"title": "Hélicité",                 "unit": "m²/s²", "cmap": "RdPu",    "vmin": 0,    "vmax": 300},
    "DBZ":      {"title": "Réflectivité radar",       "unit": "dBZ",   "cmap": "jet",     "vmin": -10,  "vmax": 65},
}


def plot_panel(ax, lon_1d, lat_1d, data, cfg, t_str):
    """Dessine un panneau sur un axe matplotlib."""
    cf = ax.contourf(
        lon_1d, lat_1d, data,
        levels=20,
        cmap=cfg["cmap"],
        vmin=cfg["vmin"], vmax=cfg["vmax"],
        extend="both"
    )
    plt.colorbar(cf, ax=ax, orientation="vertical", pad=0.02,
                 shrink=0.92, label=cfg["unit"])
    ax.set_xlabel("Longitude", fontsize=8)
    ax.set_ylabel("Latitude", fontsize=8)
    ax.tick_params(labelsize=7)
    ax.xaxis.set_minor_locator(AutoMinorLocator())
    ax.yaxis.set_minor_locator(AutoMinorLocator())
    ax.grid(True, linewidth=0.3, alpha=0.5, linestyle="--")
    ax.set_title(f"{cfg['title']} — {t_str}", fontsize=9, fontweight="bold")
    return cf


def make_summary_figure(ds, lat_2d, lon_2d, t_idx, t_str, outdir):
    """Figure résumé 2×3 avec les variables principales."""
    vars_to_plot = [v for v in ["T2C", "CAPE", "RAIN_TOT", "WSPD10", "SLP", "DBZ"]
                    if v in ds]
    if not vars_to_plot:
        return None

    ncols = 2
    nrows = (len(vars_to_plot) + 1) // 2
    fig, axes = plt.subplots(nrows, ncols, figsize=(16, 5 * nrows))
    axes = np.array(axes).flatten()

    lon_1d = lon_2d[0, :]
    lat_1d = lat_2d[:, 0]

    for i, vname in enumerate(vars_to_plot):
        cfg = PANELS[vname]
        data = ds[vname].values[t_idx]
        ax = axes[i]
        plot_panel(ax, lon_1d, lat_1d, data, cfg, t_str)

        # Isolignes SLP sur T2C
        if vname == "T2C" and "SLP" in ds:
            slp = ds["SLP"].values[t_idx]
            cs = ax.contour(lon_1d, lat_1d, slp,
                            levels=np.arange(int(slp.min()/4)*4,
                                             int(slp.max()/4)*4+4, 4),
                            colors="black", linewidths=0.6)
            ax.clabel(cs, inline=True, fontsize=6, fmt="%d")

        # Barbes de vent sur WSPD10
        if vname == "WSPD10" and "U10" in ds and "V10" in ds:
            u10 = ds["U10"].values[t_idx]
            v10 = ds["V10"].values[t_idx]
            step = max(1, len(lat_1d) // 20)
            ax.barbs(lon_1d[::step], lat_1d[::step],
                     u10[::step, ::step], v10[::step, ::step],
                     length=5, linewidth=0.5, color="black", alpha=0.7)

    for j in range(len(vars_to_plot), len(axes)):
        axes[j].set_visible(False)

    t_tag = t_str.replace(":", "-").replace(" ", "_")
    fig.suptitle(f"WRF 4.7.1 — {t_str}", fontsize=13, fontweight="bold")
    plt.tight_layout()
    outfile = outdir / f"summary_{t_tag}.png"
    fig.savefig(outfile, dpi=120, bbox_inches="tight")
    plt.close(fig)
    return outfile


def process_file(ncfile, outdir):
    ds = xr.open_dataset(ncfile)
    fname = Path(ncfile).stem
    domain = "d01" if "_d01_" in fname else "d02"

    lat_2d = ds["lat"].values
    lon_2d = ds["lon"].values
    lat_1d = lat_2d[:, 0]
    lon_1d = lon_2d[0, :]
    times = ds["time"].values
    nt = len(times)
    time_strs = [str(t)[:19].replace("T", " ") for t in times]

    fig_outdir = outdir / domain
    fig_outdir.mkdir(parents=True, exist_ok=True)

    for t_idx in range(nt):
        t_str = time_strs[t_idx]
        t_tag = t_str.replace(":", "-").replace(" ", "_")
        print(f"  [{t_idx+1}/{nt}] {t_str}")

        # Figure résumé
        make_summary_figure(ds, lat_2d, lon_2d, t_idx, t_str, fig_outdir)

        # Figures individuelles
        for vname, cfg in PANELS.items():
            if vname not in ds:
                continue
            data = ds[vname].values[t_idx]
            if data.ndim != 2:
                continue

            fig, ax = plt.subplots(1, 1, figsize=(10, 7))
            plot_panel(ax, lon_1d, lat_1d, data, cfg, t_str)

            if vname == "T2C" and "SLP" in ds:
                slp = ds["SLP"].values[t_idx]
                cs = ax.contour(lon_1d, lat_1d, slp,
                                levels=np.arange(int(slp.min()/4)*4,
                                                 int(slp.max()/4)*4+4, 4),
                                colors="black", linewidths=0.6)
                ax.clabel(cs, inline=True, fontsize=7, fmt="%d")

            if vname == "WSPD10" and "U10" in ds and "V10" in ds:
                u10 = ds["U10"].values[t_idx]
                v10 = ds["V10"].values[t_idx]
                step = max(1, len(lat_1d) // 20)
                ax.barbs(lon_1d[::step], lat_1d[::step],
                         u10[::step, ::step], v10[::step, ::step],
                         length=5, linewidth=0.5, color="black", alpha=0.7)

            plt.tight_layout()
            outfile = fig_outdir / f"{vname}_{t_tag}.png"
            fig.savefig(outfile, dpi=120, bbox_inches="tight")
            plt.close(fig)

    print(f"  ✅ {nt} pas de temps → {fig_outdir}")
    ds.close()


def main():
    parser = argparse.ArgumentParser(description="WRF PNG Visualization")
    parser.add_argument("--indir",  default="/data/wrf_output/postproc")
    parser.add_argument("--outdir", default="/data/figures")
    parser.add_argument("--domain", type=int, choices=[1, 2], default=None)
    args = parser.parse_args()

    Path(args.outdir).mkdir(parents=True, exist_ok=True)
    dom = f"d0{args.domain}" if args.domain else "d0[12]"
    files = sorted(glob.glob(os.path.join(args.indir, f"diag_{dom}_*.nc")))

    if not files:
        print(f"Aucun fichier dans : {args.indir}")
        return

    print(f"Fichiers à visualiser : {len(files)}")
    for f in files:
        print(f"\n→ {Path(f).name}")
        process_file(f, Path(args.outdir))

    print(f"\n✅ Figures PNG → {args.outdir}")


if __name__ == "__main__":
    main()
