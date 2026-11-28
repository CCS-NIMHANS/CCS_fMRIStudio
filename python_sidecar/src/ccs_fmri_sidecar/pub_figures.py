"""Publication-ready figures from CCS fMRI Studio outputs (same style as the v0.5.0 validation report).

Single subject (one results folder from Step 4/5):
    python -m ccs_fmri_sidecar.pub_figures --mode subject --results-dir <exported results> \
        [--bold-mni <preproc>/bold_mni.nii] [--labels-json <preproc>/schaefer400_labels.json] [--out-dir <dir>]

Group / session / condition contrast (batch_summary.csv from the Batch tab):
    python -m ccs_fmri_sidecar.pub_figures --mode group --batch-csv batch_summary.csv \
        --group-col session --group-a pre --group-b post [--paired] [--out-dir <dir>]

Every figure is written as 300-dpi PNG and as SVG (editable vector) plus a `figures_manifest.json`.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

NETS = ["Vis", "SomMot", "DorsAttn", "SalVentAttn", "Limbic", "Cont", "Default"]
C_APP, C_B, C_GREY = "#00798c", "#edae49", "#30343f"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 8, "axes.titlesize": 8.5, "axes.labelsize": 8,
                     "axes.spines.top": False, "axes.spines.right": False, "savefig.dpi": 300, "svg.fonttype": "none"})


# ----------------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------------
def _save(fig, out: Path, name: str, manifest: list, caption: str) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for ext in ("png", "svg"):
        fig.savefig(out / f"{name}.{ext}", bbox_inches="tight")
    plt.close(fig)
    manifest.append({"figure": name, "png": str(out / f"{name}.png"), "svg": str(out / f"{name}.svg"), "caption": caption})


def _panel(ax, letter: str) -> None:
    ax.text(-0.14, 1.07, letter, transform=ax.transAxes, fontsize=11, fontweight="bold", va="bottom")


def _read(path: Path) -> np.ndarray:
    return np.loadtxt(path, delimiter=",", ndmin=2)


def _networks(labels_json: Path | None, n: int) -> np.ndarray:
    if labels_json and labels_json.exists():
        labels = [l for l in json.loads(labels_json.read_text()) if str(l).lower() != "background"]
        if len(labels) == n:
            out = []
            for l in labels:
                parts = str(l).split("_")
                out.append(parts[2] if len(parts) > 2 and parts[2] in NETS else "Other")
            return np.array(out)
    return np.array(["Other"] * n)


def _network_matrix(fc: np.ndarray, net: np.ndarray) -> np.ndarray:
    z = np.arctanh(np.clip(fc, -0.999999, 0.999999))
    np.fill_diagonal(z, np.nan)
    m = np.full((7, 7), np.nan)
    for i, a in enumerate(NETS):
        for j, b in enumerate(NETS):
            if (net == a).any() and (net == b).any():
                m[i, j] = np.nanmean(z[np.ix_(net == a, net == b)])
    return m


def _netimshow(ax, m, title, vmax=None, cmap="RdBu_r"):
    vmax = vmax or np.nanmax(np.abs(m)) or 1.0
    im = ax.imshow(m, cmap=cmap, vmin=-vmax, vmax=vmax)
    ax.set_xticks(range(7)); ax.set_yticks(range(7))
    ax.set_xticklabels(NETS, rotation=90, fontsize=6); ax.set_yticklabels(NETS, fontsize=6)
    ax.set_title(title, fontsize=7.5)
    plt.colorbar(im, ax=ax, fraction=0.046, pad=0.03)


def _acw0(x: np.ndarray, tr: float) -> float:
    x = x - x.mean()
    n = len(x)
    f = np.fft.rfft(x, 2 * n)
    ac = np.fft.irfft(f * np.conj(f))[:n]
    if ac[0] <= 0:
        return np.nan
    idx = np.where(ac / ac[0] <= 0)[0]
    return float(idx[0] * tr) if idx.size else np.nan


# ----------------------------------------------------------------------------------------------
# single subject
# ----------------------------------------------------------------------------------------------
def subject_figures(results_dir: Path, out: Path, bold_mni: Path | None, labels_json: Path | None) -> list:
    man: list = []
    summ = json.loads((results_dir / "biomarkers_summary.json").read_text()) if (results_dir / "biomarkers_summary.json").exists() else {}
    tr = float(summ.get("tr_sec", 2.0))
    pre = bold_mni.parent if bold_mni else None
    if labels_json is None and pre and (pre / "schaefer400_labels.json").exists():
        labels_json = pre / "schaefer400_labels.json"
    clean = _read(results_dir / "denoised_timeseries.csv")
    n = clean.shape[1]
    net = _networks(labels_json, n)
    order = np.argsort(np.array([NETS.index(x) if x in NETS else 99 for x in net]), kind="stable")
    keep = np.ones(clean.shape[0], bool)
    if (results_dir / "censor_mask.csv").exists():
        keep = _read(results_dir / "censor_mask.csv").ravel() > 0.5
    raw = _read(results_dir / "raw_timeseries.csv") if (results_dir / "raw_timeseries.csv").exists() else None
    fd = None
    if pre and (pre / "confounds.tsv").exists():
        conf = pd.read_csv(pre / "confounds.tsv", sep="\t")
        fd = conf["framewise_displacement"].to_numpy()

    # S1 anatomy / tissue masks
    if pre and (pre / "t1w_mni.nii.gz").exists():
        import nibabel as nib
        t1 = nib.load(pre / "t1w_mni.nii.gz").get_fdata()
        bm = nib.load(pre / "brain_mask_mni.nii.gz").get_fdata() > 0 if (pre / "brain_mask_mni.nii.gz").exists() else None
        wm = nib.load(pre / "wm_mask_mni.nii.gz").get_fdata() > 0 if (pre / "wm_mask_mni.nii.gz").exists() else None
        csf = nib.load(pre / "csf_mask_mni.nii.gz").get_fdata() > 0 if (pre / "csf_mask_mni.nii.gz").exists() else None
        fig, ax = plt.subplots(1, 3, figsize=(7.2, 2.6))
        sx, sy, sz = (np.array(t1.shape) * np.array([0.33, 0.55, 0.5])).astype(int)
        for a, sl in zip(ax, [lambda v: np.rot90(v[:, :, sz]), lambda v: np.rot90(v[:, sy, :]), lambda v: np.rot90(v[sx, :, :])]):
            a.imshow(sl(t1), cmap="gray")
            if bm is not None:
                a.contour(sl(bm).astype(float), [.5], colors="gold", linewidths=.6)
            for m, cm in ((wm, "winter"), (csf, "autumn")):
                if m is not None:
                    a.imshow(np.ma.masked_where(~sl(m), sl(m)), cmap=cm, alpha=.7, interpolation="none")
            a.set_xticks([]); a.set_yticks([]); [s.set_visible(False) for s in a.spines.values()]
        fig.suptitle("T1w in MNI space · gold = brain mask · blue/red = WM/CSF aCompCor masks", fontsize=8)
        _save(fig, out, "S1_anatomy_and_tissue_masks", man, "Spatial normalisation and aCompCor tissue masks.")

    # S2 motion
    if fd is not None:
        fig, ax = plt.subplots(3, 1, figsize=(7.2, 3.8), sharex=True)
        for c in ("trans_x", "trans_y", "trans_z"):
            ax[0].plot(conf[c], lw=.7, label=c)
        for c in ("rot_x", "rot_y", "rot_z"):
            ax[1].plot(np.degrees(conf[c]), lw=.7, label=c)
        ax[0].set_ylabel("mm"); ax[1].set_ylabel("deg")
        ax[0].legend(frameon=False, fontsize=6, ncol=3); ax[1].legend(frameon=False, fontsize=6, ncol=3)
        ax[2].plot(fd, c="k", lw=.7); ax[2].axhline(summ.get("fd_threshold_mm", 0.5), c="r", ls=":", lw=.7)
        cens = np.where(~keep)[0] if len(keep) == len(fd) else []
        ax[2].scatter(cens, fd[cens], c="r", s=6, zorder=3, label=f"censored ({len(cens)})")
        ax[2].set_ylabel("FD (mm)"); ax[2].set_xlabel("volume"); ax[2].legend(frameon=False, fontsize=6)
        _save(fig, out, "S2_head_motion", man, "Rigid-body motion parameters and framewise displacement with censored frames.")

    # S3 before / after denoising
    fig = plt.figure(figsize=(7.2, 5.2)); gs = fig.add_gridspec(3, 2, height_ratios=[.35, 1.2, 1.0], hspace=.45)
    cl = clean.copy(); cl[~keep] = np.nan
    panels = [(raw, "before denoising"), (cl, "after denoising (censored = blank)")]
    for k, (dat, ttl) in enumerate(panels):
        if dat is None:
            continue
        if k == 0:
            dat = (dat - dat.mean(0)) / (dat.std(0) + 1e-12)
        a0 = fig.add_subplot(gs[0, k])
        if fd is not None:
            a0.plot(fd, c="k", lw=.5); a0.axhline(summ.get("fd_threshold_mm", 0.5), c="r", ls=":", lw=.5)
        a0.set_xticks([]); a0.set_ylabel("FD", fontsize=6); a0.set_title(ttl, fontsize=7.5)
        a1 = fig.add_subplot(gs[1, k])
        a1.imshow(dat[:, order].T, aspect="auto", cmap="gray", vmin=-2, vmax=2, interpolation="none")
        a1.set_yticks([]); a1.set_xlabel("volume"); a1.set_ylabel("ROIs (Yeo-7 order)" if k == 0 else "")
    a2 = fig.add_subplot(gs[2, :])
    iu = np.triu_indices(n, 1)
    if raw is not None:
        a2.hist(np.corrcoef(raw.T)[iu], bins=80, histtype="step", color=C_GREY, density=True, label="before")
    a2.hist(np.corrcoef(clean[keep].T)[iu], bins=80, histtype="step", color=C_APP, density=True, label="after")
    a2.set_xlabel("ROI–ROI r"); a2.legend(frameon=False, fontsize=6); a2.set_title("FC distribution", fontsize=7.5)
    _save(fig, out, "S3_before_after_denoising", man, "ROI carpet plots and FC distribution before and after denoising.")

    # S4 connectome
    fc = _read(results_dir / "fc_matrix.csv")
    fig, ax = plt.subplots(1, 2, figsize=(7.2, 3.3), gridspec_kw=dict(width_ratios=[1.25, 1]))
    im = ax[0].imshow(fc[np.ix_(order, order)], cmap="RdBu_r", vmin=-.6, vmax=.6, interpolation="none")
    bounds = np.cumsum([np.sum(net == x) for x in NETS])
    for b in bounds[:-1]:
        ax[0].axhline(b - .5, c="k", lw=.3); ax[0].axvline(b - .5, c="k", lw=.3)
    ax[0].set_xticks([]); ax[0].set_yticks([]); ax[0].set_title(f"{n}×{n} FC (Yeo-7 order)")
    plt.colorbar(im, ax=ax[0], fraction=0.046, pad=0.03)
    _netimshow(ax[1], _network_matrix(fc, net), "Network FC (mean Fisher z)", vmax=0.6)
    _panel(ax[0], "A"); _panel(ax[1], "B")
    _save(fig, out, "S4_connectome", man, "ROI-level and network-level functional connectivity.")

    # S5 dynamics (ACW-0 per network)
    dyn_p = results_dir / "roi_dynamics.csv"
    if dyn_p.exists():
        dd = pd.read_csv(dyn_p)
        dd["net7"] = dd["network"].astype(str).str.split("_").str[-1]
        acw = dd.groupby("net7")["acw0"].agg(["mean", "sem"]).reindex(NETS)
    else:
        vals = np.array([_acw0(clean[keep, j], tr) for j in range(n)])
        acw = pd.DataFrame({"mean": [np.nanmean(vals[net == x]) for x in NETS],
                            "sem": [np.nanstd(vals[net == x]) / max(1, np.sqrt((net == x).sum())) for x in NETS]}, index=NETS)
    fig, ax = plt.subplots(figsize=(3.6, 2.6))
    ax.bar(range(7), acw["mean"], yerr=acw["sem"], color=C_APP, capsize=2)
    ax.set_xticks(range(7)); ax.set_xticklabels(NETS, rotation=45, ha="right"); ax.set_ylabel("ACW-0 (s)")
    ax.set_title("Intrinsic timescale by network")
    _save(fig, out, "S5_timescales_by_network", man, "Autocorrelation window (ACW-0) by Yeo-7 network (mean ± SEM over ROIs).")

    # S6 seed map (if computed in the Stats tab)
    sz_p = results_dir / "nilearn_stats" / "seed_zmap.nii.gz"
    if sz_p.exists():
        from nilearn import plotting
        sj = json.loads((results_dir / "nilearn_stats" / "seed_glm_summary.json").read_text())
        fig = plt.figure(figsize=(7.2, 2.4))
        plotting.plot_glass_brain(str(sz_p), threshold=sj.get("threshold_z") or 3.1, display_mode="lzry", plot_abs=False,
                                  cmap="cold_hot", colorbar=True, figure=fig,
                                  title=f"{sj.get('seed_label', 'seed')}: {sj.get('n_sig_voxels', 0):,} voxels, DOF {sj.get('residual_dof', '?')}")
        _save(fig, out, "S6_seed_map", man, "Seed-to-voxel correlation map (FDR-thresholded, DOF-based z).")
    return man


# ----------------------------------------------------------------------------------------------
# group / session / condition contrast
# ----------------------------------------------------------------------------------------------
def _dof(results_dir: Path) -> float:
    p = results_dir / "biomarkers_summary.json"
    try:
        return float(json.loads(p.read_text()).get("dof_remaining", np.inf))
    except Exception:
        return np.inf


def group_figures(batch_csv: Path, out: Path, group_col: str, ga: str, gb: str, paired: bool, min_dof: float = 30) -> list:
    man: list = []
    df = pd.read_csv(batch_csv)
    if "status" in df.columns:
        df = df[~df["status"].astype(str).str.lower().isin(["failed", "error", "cancelled", "skipped", "pending", "queued"])]
    df = df[df["results_dir"].astype(str).map(lambda p: (Path(p) / "fc_matrix.csv").exists())]
    low = df["results_dir"].astype(str).map(lambda p: _dof(Path(p)) < min_dof)
    excluded = df[low]
    df = df[~low]
    if len(excluded):
        print(f"[pub_figures] excluded {len(excluded)} run(s) with residual DOF < {min_dof}: "
              f"{list(excluded.get('id', excluded.index).astype(str))}", flush=True)
    a, b = df[df[group_col].astype(str) == ga], df[df[group_col].astype(str) == gb]
    if len(a) == 0 or len(b) == 0:
        raise SystemExit(f"No rows for {group_col} = {ga!r} and/or {gb!r}")

    def load(rows):
        out_ = []
        for _, r in rows.iterrows():
            d = Path(str(r["results_dir"]))
            fc = _read(d / "fc_matrix.csv")
            labels = None
            for cand in (d.parent / "schaefer400_labels.json", d.parent.parent / "schaefer400_labels.json"):
                if cand.exists():
                    labels = cand; break
            out_.append((str(r.get("subject", r.get("id", ""))), fc, _networks(labels, fc.shape[0]), d))
        return out_

    A, B = load(a), load(b)
    net = A[0][2]
    nm_a = np.nanmean([_network_matrix(fc, nt) for _, fc, nt, _ in A], axis=0)
    nm_b = np.nanmean([_network_matrix(fc, nt) for _, fc, nt, _ in B], axis=0)

    def within_between(m):
        return np.nanmean(np.diag(m)), np.nanmean(m[~np.eye(7, dtype=bool)])

    # G1 network FC change + within/between per subject
    fig, ax = plt.subplots(1, 4, figsize=(11.0, 2.9), gridspec_kw=dict(width_ratios=[1, 1, 1, 1.1], wspace=0.75))
    _netimshow(ax[0], nm_a, f"{ga}: network FC", vmax=0.5)
    _netimshow(ax[1], nm_b, f"{gb}: network FC", vmax=0.5)
    _netimshow(ax[2], nm_b - nm_a, f"Δ {gb} − {ga}", vmax=max(0.05, np.nanmax(np.abs(nm_b - nm_a))))
    wa = [within_between(_network_matrix(fc, nt)) for _, fc, nt, _ in A]
    wb = [within_between(_network_matrix(fc, nt)) for _, fc, nt, _ in B]
    for k, (lab, col) in enumerate([("within", C_APP), ("between", C_B)]):
        va, vb = np.array([x[k] for x in wa]), np.array([x[k] for x in wb])
        if paired and len(va) == len(vb):
            for p, q in zip(va, vb):
                ax[3].plot([k * 2.5, k * 2.5 + 1], [p, q], c=col, lw=.7, alpha=.7)
        ax[3].scatter(np.full(len(va), k * 2.5), va, facecolors="white", edgecolors=col, s=14)
        ax[3].scatter(np.full(len(vb), k * 2.5 + 1), vb, c=col, s=14)
    ax[3].set_xticks([0, 1, 2.5, 3.5]); ax[3].set_xticklabels([f"within\n{ga}", f"within\n{gb}", f"between\n{ga}", f"between\n{gb}"], fontsize=6)
    ax[3].set_ylabel("mean FC (z)"); ax[3].set_title("Network integration / segregation")
    for x, l in zip(ax, "ABCD"):
        _panel(x, l)
    _save(fig, out, "G1_network_fc_contrast", man, f"Network-level FC for {ga} and {gb}, their difference, and within/between-network FC per subject.")

    # G2 edge-wise difference
    iu = np.triu_indices(A[0][1].shape[0], 1)
    za = np.array([np.arctanh(np.clip(fc[iu], -.999, .999)) for _, fc, _, _ in A])
    zb = np.array([np.arctanh(np.clip(fc[iu], -.999, .999)) for _, fc, _, _ in B])
    fig, ax = plt.subplots(1, 2, figsize=(7.2, 2.8))
    ax[0].hist(za.ravel(), bins=80, histtype="step", density=True, color=C_GREY, label=ga)
    ax[0].hist(zb.ravel(), bins=80, histtype="step", density=True, color=C_APP, label=gb)
    ax[0].set_xlabel("edge FC (z)"); ax[0].legend(frameon=False, fontsize=6); ax[0].set_title("FC distribution by group")
    ma, mb = za.mean(0), zb.mean(0); sel = np.random.default_rng(0).choice(len(ma), min(8000, len(ma)), replace=False)
    ax[1].scatter(ma[sel], mb[sel], s=1, alpha=.3, c=C_APP); lim = [min(ma.min(), mb.min()), max(ma.max(), mb.max())]
    ax[1].plot(lim, lim, "k:", lw=.6); ax[1].set_xlabel(f"mean edge FC, {ga}"); ax[1].set_ylabel(f"mean edge FC, {gb}")
    ax[1].set_title(f"Edge-wise similarity r = {np.corrcoef(ma, mb)[0, 1]:.2f}")
    _panel(ax[0], "A"); _panel(ax[1], "B")
    _save(fig, out, "G2_edgewise_fc", man, "Edge-wise FC distribution and group-mean edge similarity.")

    # G3 scalar metrics per group
    metrics = [m for m in ("mean_fd_mm", "pct_scrubbed", "mean_abs_fc", "global_efficiency", "acw0_mean", "lzc_mean", "ple_mean")
               if m in df.columns]
    fig, ax = plt.subplots(1, len(metrics), figsize=(1.25 * len(metrics) + 0.6, 2.4))
    ax = np.atleast_1d(ax)
    for x, m in zip(ax, metrics):
        va, vb = a[m].astype(float).to_numpy(), b[m].astype(float).to_numpy()
        if paired and len(va) == len(vb):
            for p, q in zip(va, vb):
                x.plot([0, 1], [p, q], c="#bbbbbb", lw=.6)
        x.scatter(np.zeros(len(va)), va, c=C_GREY, s=12); x.scatter(np.ones(len(vb)), vb, c=C_APP, s=12)
        x.set_xticks([0, 1]); x.set_xticklabels([ga, gb], fontsize=6); x.set_title(m.replace("_", " "), fontsize=7)
    _save(fig, out, "G3_summary_metrics", man, "Per-subject summary metrics (motion, connectivity, graph, dynamics) by group.")

    # G4 timescale change by network (if roi_dynamics.csv exists)
    def acw_by_net(rows):
        vals = []
        for _, _, _, d in rows:
            p = d / "roi_dynamics.csv"
            if p.exists():
                dd = pd.read_csv(p); dd["net7"] = dd["network"].astype(str).str.split("_").str[-1]
                vals.append(dd.groupby("net7")["acw0"].mean().reindex(NETS).to_numpy())
        return np.array(vals)
    va, vb = acw_by_net(A), acw_by_net(B)
    if len(va) and len(vb):
        fig, ax = plt.subplots(figsize=(4.2, 2.6))
        ax.bar(np.arange(7) - .2, np.nanmean(va, 0), .4, color=C_GREY, label=ga)
        ax.bar(np.arange(7) + .2, np.nanmean(vb, 0), .4, color=C_APP, label=gb)
        ax.set_xticks(range(7)); ax.set_xticklabels(NETS, rotation=45, ha="right"); ax.set_ylabel("ACW-0 (s)")
        ax.legend(frameon=False, fontsize=6); ax.set_title("Intrinsic timescales by network")
        _save(fig, out, "G4_timescales_by_network", man, "ACW-0 by network and group (requires Dynamics in the batch).")
    (out / "group_inclusion.json").write_text(json.dumps({
        "group_col": group_col, "group_a": ga, "group_b": gb, "n_a": len(a), "n_b": len(b), "min_dof": min_dof,
        "excluded_low_dof": list(excluded.get("id", excluded.index).astype(str))}, indent=2), encoding="utf-8")
    return man


def main() -> None:
    ap = argparse.ArgumentParser(description="Publication-ready figures from CCS fMRI Studio outputs.")
    ap.add_argument("--mode", choices=["subject", "group"], required=True)
    ap.add_argument("--results-dir", type=Path)
    ap.add_argument("--bold-mni", type=Path, default=None)
    ap.add_argument("--labels-json", type=Path, default=None)
    ap.add_argument("--batch-csv", type=Path)
    ap.add_argument("--group-col", default="session")
    ap.add_argument("--group-a", default="pre")
    ap.add_argument("--group-b", default="post")
    ap.add_argument("--paired", action="store_true")
    ap.add_argument("--min-dof", type=float, default=30, help="Exclude runs with fewer residual DOF (group mode).")
    ap.add_argument("--out-dir", type=Path, default=None)
    args = ap.parse_args()
    if args.mode == "subject":
        if args.results_dir is None:
            raise SystemExit("--results-dir is required")
        out = args.out_dir or args.results_dir / "publication_figures"
        man = subject_figures(args.results_dir, out, args.bold_mni, args.labels_json)
    else:
        if args.batch_csv is None:
            raise SystemExit("--batch-csv is required")
        out = args.out_dir or args.batch_csv.parent / "publication_figures"
        out.mkdir(parents=True, exist_ok=True)
        man = group_figures(args.batch_csv, out, args.group_col, args.group_a, args.group_b, args.paired, args.min_dof)
    (out / "figures_manifest.json").write_text(json.dumps({"out_dir": str(out), "figures": man}, indent=2), encoding="utf-8")
    print(json.dumps({"out_dir": str(out), "n_figures": len(man)}, indent=2))


if __name__ == "__main__":
    main()
