#!/usr/bin/env python3
"""
plot_wrf_domains.py
--------------------
Visualise les domaines WRF (d01 et d02) avec :
  - Topographie ETOPO1 (téléchargée automatiquement via cartopy)
  - Frontières des pays et côtes
  - Grille lat/lon
  - Informations des domaines tirées de la namelist

Usage :
    python plot_wrf_domains.py --namelist /data/wrf/20260624/00/namelist.input \
                               --wps     /data/wps/20260624/00/namelist.wps \
                               --outdir  /data/figures
    # ou sans arguments (valeurs lues depuis ce script) :
    python plot_wrf_domains.py
"""

import argparse
import os
import re
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.ticker as mticker
import cartopy.crs as ccrs
import cartopy.feature as cfeature



# ── Valeurs par défaut (issues de la namelist) ────────────────────────────────
DEFAULTS = {
    # Projection
    "map_proj":  "mercator",
    "ref_lat":   -21.24088,
    "ref_lon":   -175.14985,
    "truelat1":  -21.2409,
    "truelat2":  -21.2409,
    "stand_lon": -175.14985,
    # d01
    "e_we_d01":  231,
    "e_sn_d01":  231,
    "dx_d01":    12000,   # m
    # d02
    "e_we_d02":  236,
    "e_sn_d02":  236,
    "dx_d02":    2400,    # m
    "i_parent_start": 93,
    "j_parent_start": 93,
    "parent_grid_ratio": 5,
}


# ── Parseurs namelist ─────────────────────────────────────────────────────────

def _first_val(text, key):
    """Retourne la première valeur numérique d'un paramètre namelist."""
    m = re.search(rf"{key}\s*=\s*([^\s,/]+)", text, re.IGNORECASE)
    return m.group(1).strip() if m else None


def parse_namelist_input(path):
    """Lit e_we, e_sn, dx, i/j_parent_start depuis namelist.input."""
    cfg = {}
    try:
        txt = Path(path).read_text()
        for k, dest, cast in [
            ("e_we",           "e_we_list", None),
            ("e_sn",           "e_sn_list", None),
            ("dx",             "dx_list",   None),
            ("i_parent_start", "i_ps_list", None),
            ("j_parent_start", "j_ps_list", None),
            ("parent_grid_ratio", "ratio_list", None),
        ]:
            m = re.search(rf"{k}\s*=\s*([^\n/]+)", txt, re.IGNORECASE)
            if m:
                vals = [v.strip().rstrip(",") for v in m.group(1).split(",") if v.strip()]
                cfg[dest] = [int(float(v)) for v in vals if v]

        if "e_we_list" in cfg and len(cfg["e_we_list"]) >= 2:
            cfg["e_we_d01"] = cfg["e_we_list"][0]
            cfg["e_we_d02"] = cfg["e_we_list"][1]
        if "e_sn_list" in cfg and len(cfg["e_sn_list"]) >= 2:
            cfg["e_sn_d01"] = cfg["e_sn_list"][0]
            cfg["e_sn_d02"] = cfg["e_sn_list"][1]
        if "dx_list" in cfg and len(cfg["dx_list"]) >= 2:
            cfg["dx_d01"] = cfg["dx_list"][0]
            cfg["dx_d02"] = cfg["dx_list"][1]
        if "i_ps_list" in cfg and len(cfg["i_ps_list"]) >= 2:
            cfg["i_parent_start"] = cfg["i_ps_list"][1]
        if "j_ps_list" in cfg and len(cfg["j_ps_list"]) >= 2:
            cfg["j_parent_start"] = cfg["j_ps_list"][1]
        if "ratio_list" in cfg and len(cfg["ratio_list"]) >= 2:
            cfg["parent_grid_ratio"] = cfg["ratio_list"][1]
    except Exception as e:
        print(f"⚠ namelist.input non lu ({e}), valeurs par défaut utilisées")
    return cfg


def parse_namelist_wps(path):
    """Lit ref_lat, ref_lon, map_proj, truelat1/2, stand_lon depuis namelist.wps."""
    cfg = {}
    try:
        txt = Path(path).read_text()
        for k, cast in [
            ("map_proj",  str),
            ("ref_lat",   float),
            ("ref_lon",   float),
            ("truelat1",  float),
            ("truelat2",  float),
            ("stand_lon", float),
        ]:
            v = _first_val(txt, k)
            if v:
                cfg[k] = cast(v.strip("'\""))
    except Exception as e:
        print(f"⚠ namelist.wps non lu ({e}), valeurs par défaut utilisées")
    return cfg


# ── Calcul des coins des domaines ─────────────────────────────────────────────

def domain_corners(cfg):
    """
    Calcule les coins (lat/lon) de d01 et d02.
    Retourne (d01, d02) où chacun est un dict avec
    west, east, south, north, center_lat, center_lon.
    """
    import math

    ref_lat  = cfg["ref_lat"]
    ref_lon  = cfg["ref_lon"]
    dx1      = cfg["dx_d01"]   # m
    dx2      = cfg["dx_d02"]   # m
    e_we1    = cfg["e_we_d01"]
    e_sn1    = cfg["e_sn_d01"]
    e_we2    = cfg["e_we_d02"]
    e_sn2    = cfg["e_sn_d02"]
    i_start  = cfg["i_parent_start"]
    j_start  = cfg["j_parent_start"]

    cos_lat        = math.cos(math.radians(ref_lat))
    m_per_deg_lon  = 111320.0 * cos_lat
    m_per_deg_lat  = 111000.0

    # D01 — centré sur ref_lat/ref_lon
    half_w1 = (e_we1 - 1) * dx1 / 2.0
    half_h1 = (e_sn1 - 1) * dx1 / 2.0
    d01 = {
        "west":       ref_lon - half_w1 / m_per_deg_lon,
        "east":       ref_lon + half_w1 / m_per_deg_lon,
        "south":      ref_lat - half_h1 / m_per_deg_lat,
        "north":      ref_lat + half_h1 / m_per_deg_lat,
        "center_lat": ref_lat,
        "center_lon": ref_lon,
        "dx_km":      dx1 / 1000.0,
        "e_we":       e_we1,
        "e_sn":       e_sn1,
    }

    # D02 — positionné par i/j_parent_start dans d01
    d01_sw_lon = d01["west"]
    d01_sw_lat = d01["south"]
    off_x = (i_start - 1) * dx1
    off_y = (j_start - 1) * dx1
    d02_w = d01_sw_lon + off_x / m_per_deg_lon
    d02_s = d01_sw_lat + off_y / m_per_deg_lat
    d02_e = d02_w + (e_we2 - 1) * dx2 / m_per_deg_lon
    d02_n = d02_s + (e_sn2 - 1) * dx2 / m_per_deg_lat
    d02 = {
        "west":       d02_w,
        "east":       d02_e,
        "south":      d02_s,
        "north":      d02_n,
        "center_lat": (d02_s + d02_n) / 2,
        "center_lon": (d02_w + d02_e) / 2,
        "dx_km":      dx2 / 1000.0,
        "e_we":       e_we2,
        "e_sn":       e_sn2,
    }
    return d01, d02


# ── Figure principale ─────────────────────────────────────────────────────────

def plot_domains(d01, d02, cfg, outpath):
    """Génère la figure PNG avec topographie, frontières et domaines."""

    stand_lon = cfg.get("stand_lon", cfg["ref_lon"])

    # Projection cartopy pour l'affichage (PlateCarree pour Mercator WRF)
    proj = ccrs.PlateCarree(central_longitude=stand_lon)
    data_crs = ccrs.PlateCarree()

    fig = plt.figure(figsize=(14, 10), dpi=150)
    ax = fig.add_subplot(1, 1, 1, projection=proj)

    # ── Étendue de la carte (d01 + marge 5°) ──────────────────────────────────
    margin = 3.0
    extent = [
        d01["west"]  - margin,
        d01["east"]  + margin,
        d01["south"] - margin,
        d01["north"] + margin,
    ]
    ax.set_extent(extent, crs=data_crs)

    # ── Topographie ETOPO (stock image Cartopy) ───────────────────────────────
    try:
        ax.stock_img()
    except Exception:
        ax.set_facecolor("#a8d8ea")

    # ── Features géographiques ────────────────────────────────────────────────
    ax.add_feature(cfeature.OCEAN.with_scale("50m"),
                   facecolor="#c6e2f5", zorder=1)
    ax.add_feature(cfeature.LAND.with_scale("50m"),
                   facecolor="#e8dcc8", zorder=2)
    ax.add_feature(cfeature.COASTLINE.with_scale("50m"),
                   linewidth=0.7, edgecolor="#555555", zorder=3)
    ax.add_feature(cfeature.BORDERS.with_scale("50m"),
                   linewidth=0.5, edgecolor="#888888",
                   linestyle="--", zorder=3)
    ax.add_feature(cfeature.LAKES.with_scale("50m"),
                   facecolor="#c6e2f5", edgecolor="#555555",
                   linewidth=0.4, zorder=3)

    # ── Domaine d01 ───────────────────────────────────────────────────────────
    d01_rect = mpatches.Rectangle(
        xy=(d01["west"], d01["south"]),
        width=d01["east"]  - d01["west"],
        height=d01["north"] - d01["south"],
        linewidth=2.2,
        edgecolor="#1565C0",
        facecolor="#1565C0",
        alpha=0.08,
        linestyle="--",
        transform=data_crs,
        zorder=5,
    )
    ax.add_patch(d01_rect)

    # Contour solide d01
    d01_outline = mpatches.Rectangle(
        xy=(d01["west"], d01["south"]),
        width=d01["east"]  - d01["west"],
        height=d01["north"] - d01["south"],
        linewidth=2.2,
        edgecolor="#1565C0",
        facecolor="none",
        linestyle="--",
        transform=data_crs,
        zorder=6,
    )
    ax.add_patch(d01_outline)

    # Label d01
    ax.text(
        d01["west"] + 0.5, d01["north"] - 1.5,
        f"d01  {d01['e_we']}×{d01['e_sn']} pts  Δx={d01['dx_km']:.0f} km",
        transform=data_crs, fontsize=10, fontweight="bold",
        color="#1565C0", va="top", ha="left",
        bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="#1565C0",
                  alpha=0.85, linewidth=1),
        zorder=8,
    )

    # ── Domaine d02 ───────────────────────────────────────────────────────────
    d02_fill = mpatches.Rectangle(
        xy=(d02["west"], d02["south"]),
        width=d02["east"]  - d02["west"],
        height=d02["north"] - d02["south"],
        linewidth=2.5,
        edgecolor="#2E7D32",
        facecolor="#2E7D32",
        alpha=0.12,
        transform=data_crs,
        zorder=7,
    )
    ax.add_patch(d02_fill)

    d02_outline = mpatches.Rectangle(
        xy=(d02["west"], d02["south"]),
        width=d02["east"]  - d02["west"],
        height=d02["north"] - d02["south"],
        linewidth=2.5,
        edgecolor="#2E7D32",
        facecolor="none",
        transform=data_crs,
        zorder=8,
    )
    ax.add_patch(d02_outline)

    # Label d02
    ax.text(
        d02["east"] + 0.3, d02["north"],
        f"d02  {d02['e_we']}×{d02['e_sn']} pts  Δx={d02['dx_km']:.1f} km",
        transform=data_crs, fontsize=9, fontweight="bold",
        color="#2E7D32", va="top", ha="left",
        bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="#2E7D32",
                  alpha=0.85, linewidth=1),
        zorder=9,
    )

    # ── Point central ─────────────────────────────────────────────────────────
    ax.plot(
        cfg["ref_lon"], cfg["ref_lat"],
        marker="+", markersize=12, markeredgewidth=2,
        color="#E65100", transform=data_crs, zorder=10,
    )
    ax.text(
        cfg["ref_lon"] + 0.3, cfg["ref_lat"] - 0.6,
        f"({cfg['ref_lat']:.2f}°, {cfg['ref_lon']:.2f}°)",
        transform=data_crs, fontsize=8, color="#E65100",
        bbox=dict(boxstyle="round,pad=0.2", fc="white", alpha=0.7),
        zorder=10,
    )

    # ── Grille lat/lon ────────────────────────────────────────────────────────
    # draw_labels=True cause un bug shapely avec cartopy 0.25 hors méridien 0°
    # Grille sans labels, ajoutés manuellement ensuite
    gl = ax.gridlines(
        crs=data_crs, draw_labels=False,
        linewidth=0.5, color="gray", alpha=0.5, linestyle=":",
    )
    gl.xlocator = mticker.MultipleLocator(5)
    gl.ylocator = mticker.MultipleLocator(5)

    # Labels lon/lat manuels
    lon_ticks = np.arange(int(extent[0] / 5) * 5, int(extent[1] / 5) * 5 + 6, 5)
    lat_ticks = np.arange(int(extent[2] / 5) * 5, int(extent[3] / 5) * 5 + 6, 5)
    for lon in lon_ticks:
        if extent[0] <= lon <= extent[1]:
            label = f"{abs(lon):.0f}\u00b0{'E' if lon >= 0 else 'W'}"
            ax.text(lon, extent[2] - 0.6, label, transform=data_crs,
                    fontsize=8, ha="center", va="top", color="#555555")
    for lat in lat_ticks:
        if extent[2] <= lat <= extent[3]:
            label = f"{abs(lat):.0f}\u00b0{'N' if lat >= 0 else 'S'}"
            ax.text(extent[0] - 0.4, lat, label, transform=data_crs,
                    fontsize=8, ha="right", va="center", color="#555555")

    # ── Titre et métadonnées ──────────────────────────────────────────────────
    proj_name = cfg.get("map_proj", "mercator").capitalize()
    ax.set_title(
        f"Domaines WRF — Projection {proj_name}\n"
        f"Centre : {cfg['ref_lat']:.4f}°N, {cfg['ref_lon']:.4f}°E  |  "
        f"truelat1={cfg.get('truelat1', cfg['ref_lat']):.2f}°  "
        f"stand_lon={stand_lon:.2f}°",
        fontsize=11, pad=10,
    )

    # ── Légende ───────────────────────────────────────────────────────────────
    legend_handles = [
        mpatches.Patch(facecolor="#1565C0", alpha=0.3,
                       edgecolor="#1565C0", linestyle="--",
                       label=f"d01 — {d01['e_we']}×{d01['e_sn']} pts, "
                             f"Δx={d01['dx_km']:.0f} km, "
                             f"{(d01['e_we']-1)*d01['dx_km']:.0f}×"
                             f"{(d01['e_sn']-1)*d01['dx_km']:.0f} km²"),
        mpatches.Patch(facecolor="#2E7D32", alpha=0.3,
                       edgecolor="#2E7D32",
                       label=f"d02 — {d02['e_we']}×{d02['e_sn']} pts, "
                             f"Δx={d02['dx_km']:.1f} km, "
                             f"{(d02['e_we']-1)*d02['dx_km']:.0f}×"
                             f"{(d02['e_sn']-1)*d02['dx_km']:.0f} km²"),
        plt.Line2D([0], [0], marker="+", color="#E65100",
                   markersize=10, markeredgewidth=2, linewidth=0,
                   label="Centre de référence"),
    ]
    ax.legend(
        handles=legend_handles,
        loc="lower left", fontsize=9,
        framealpha=0.9, edgecolor="#cccccc",
    )

    plt.tight_layout()
    fig.savefig(outpath, dpi=150, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close(fig)
    print(f"✅ Figure sauvegardée : {outpath}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Visualisation domaines WRF")
    parser.add_argument("--namelist", default=None,
                        help="Chemin vers namelist.input")
    parser.add_argument("--wps",     default=None,
                        help="Chemin vers namelist.wps")
    parser.add_argument("--outdir",  default="/data/figures",
                        help="Dossier de sortie")
    parser.add_argument("--outfile", default="wrf_domains.png",
                        help="Nom du fichier PNG")
    args = parser.parse_args()

    # Construire la config : défauts → namelist.input → namelist.wps
    cfg = dict(DEFAULTS)

    if args.namelist and Path(args.namelist).exists():
        cfg.update(parse_namelist_input(args.namelist))
    else:
        print("ℹ namelist.input non fourni, valeurs par défaut utilisées")

    if args.wps and Path(args.wps).exists():
        cfg.update(parse_namelist_wps(args.wps))
    else:
        print("ℹ namelist.wps non fourni, valeurs par défaut utilisées")

    d01, d02 = domain_corners(cfg)

    print(f"D01 : W={d01['west']:.2f}  E={d01['east']:.2f}  "
          f"S={d01['south']:.2f}  N={d01['north']:.2f}")
    print(f"D02 : W={d02['west']:.2f}  E={d02['east']:.2f}  "
          f"S={d02['south']:.2f}  N={d02['north']:.2f}")

    Path(args.outdir).mkdir(parents=True, exist_ok=True)
    outpath = Path(args.outdir) / args.outfile

    plot_domains(d01, d02, cfg, outpath)


if __name__ == "__main__":
    main()
