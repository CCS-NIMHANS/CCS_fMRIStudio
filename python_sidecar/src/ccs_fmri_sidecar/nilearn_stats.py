"""Advanced Nilearn single-subject GLM & group connectivity statistical inference."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import nibabel as nib  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from nilearn import glm, masking, plotting, reporting  # noqa: E402
from nilearn.connectome import ConnectivityMeasure  # noqa: E402
from nilearn.image import mean_img  # noqa: E402
from nilearn.maskers import NiftiMasker  # noqa: E402
from scipy import sparse, stats  # noqa: E402
from sklearn.linear_model import RidgeClassifier  # noqa: E402
from sklearn.model_selection import StratifiedKFold, cross_val_score  # noqa: E402
import statsmodels.formula.api as smf  # noqa: E402


def _load_roi_label(labels_json: Path | None, roi_index: int, explicit_label: str | None) -> str:
    if explicit_label:
        return explicit_label
    if labels_json is not None and labels_json.exists():
        try:
            labels = json.loads(labels_json.read_text(encoding="utf-8"))
            # Schaefer JSON often has background at index 0 -> ROI i matches index i+1 if len == N+1,
            # or matches Rust roi_labels if 1-based; check bounds safely.
            if 0 <= roi_index < len(labels) and labels[roi_index]:
                return str(labels[roi_index])
        except Exception:
            pass
    return f"ROI_{roi_index + 1:03d}"


def _load_confounds_matrix(confounds_tsv: Path | None, n_tp: int) -> np.ndarray | None:
    if confounds_tsv is None or not confounds_tsv.exists():
        return None
    try:
        df = pd.read_csv(confounds_tsv, sep="\t")
    except Exception:
        return None
    if len(df) != n_tp:
        return None
    cols = [c for c in df.columns if c not in ("framewise_displacement", "ants_fd")]
    if not cols:
        return None
    mat = df[cols].apply(pd.to_numeric, errors="coerce").fillna(0.0).to_numpy(dtype=np.float64)
    # Drop near-constant columns and standardize
    keep = np.std(mat, axis=0) > 1e-10
    if not np.any(keep):
        return None
    mat = mat[:, keep]
    mat = (mat - mat.mean(axis=0, keepdims=True)) / mat.std(axis=0, keepdims=True)
    return mat


def _dct_stopband(nt: int, tr: float, low_hz: float | None, high_hz: float | None) -> np.ndarray:
    """DCT-II stopband basis identical to the Rust `build_dct_stopband_basis`."""
    if nt < 2 or tr <= 0:
        return np.zeros((nt, 0))
    win = 2.0 * nt * tr
    ks: list[int] = []
    if low_hz and low_hz > 0:
        ks += list(range(1, min(int(np.floor(win * low_hz)), nt - 1) + 1))
    if high_hz and 0 < high_hz < 0.5 / tr:
        start = max(int(np.ceil(win * high_hz)), 1, (ks[-1] + 1) if ks else 1)
        ks += list(range(start, nt))
    t = np.arange(nt) + 0.5
    if not ks:
        return np.zeros((nt, 0))
    return np.sqrt(2.0 / nt) * np.cos(np.pi / nt * np.outer(t, np.asarray(ks, float)))


def run_seed_glm(
    bold_mni: Path,
    denoised_ts_csv: Path,
    roi_index: int,
    out_dir: Path,
    labels_json: Path | None = None,
    seed_label: str | None = None,
    alpha: float = 0.05,
    correction: str = "fdr",
    cluster_threshold: int = 10,
    confounds_tsv: Path | None = None,
    low_hz: float | None = None,
    high_hz: float | None = None,
    tr_sec: float | None = None,
) -> dict:
    """Computes whole-brain seed-to-voxel GLM z-map, Nilearn thresholding & Glass Brain PNGs."""
    out_dir.mkdir(parents=True, exist_ok=True)
    ts = np.loadtxt(denoised_ts_csv, delimiter=",", dtype=np.float64)
    if ts.ndim == 1:
        ts = ts[:, None]
    if roi_index < 0 or roi_index >= ts.shape[1]:
        raise SystemExit(f"ROI index {roi_index} out of range [0, {ts.shape[1] - 1}]")

    seed = ts[:, roi_index]
    if not np.all(np.isfinite(seed)):
        raise SystemExit(
            f"Selected ROI #{roi_index} contains NaN (lesion-excluded). Choose an intact ROI."
        )
    seed_std = float(np.std(seed, ddof=1))
    if seed_std <= 1e-12:
        raise SystemExit(f"Selected ROI #{roi_index} has zero variance.")
    seed_z = (seed - float(np.mean(seed))) / seed_std

    bold_img = nib.load(str(bold_mni))
    nt = bold_img.shape[3] if len(bold_img.shape) >= 4 else 1
    if len(seed_z) != nt:
        raise SystemExit(
            f"Seed length ({len(seed_z)}) does not match BOLD volume count ({nt})."
        )

    eff_tr = float(tr_sec) if (tr_sec is not None and tr_sec > 0) else 0.0
    if eff_tr <= 0.0:
        zooms = bold_img.header.get_zooms()
        eff_tr = float(zooms[3]) if len(zooms) >= 4 and zooms[3] > 0 else 2.0
    nyquist = 0.5 / eff_tr
    hp = float(low_hz) if (low_hz is not None and 0.0 < low_hz < nyquist * 0.95) else None
    lp = float(high_hz) if (high_hz is not None and 0.0 < high_hz < nyquist * 0.95) else None
    if hp is not None and lp is not None and hp >= lp:
        hp, lp = None, None

    # ---- Voxel cleaning identical to the Rust GUI pipeline (v0.5.0) -------------------------
    # The Rust core exports `confounds_used.csv` (motion + aCompCor exactly as regressed) and
    # `censor_mask.csv` next to `denoised_timeseries.csv`. Voxels are cleaned with the same model:
    # nuisance OLS fitted on retained frames -> linear interpolation of censored frames -> DCT
    # stopband (+ mean/trend) projection -> censored frames dropped. Because every step is linear,
    # the ROI-mean of the cleaned voxels equals the Rust-cleaned seed, so seed and voxels match.
    res_dir = denoised_ts_csv.parent
    conf_used = res_dir / "confounds_used.csv"
    if conf_used.exists() and conf_used.stat().st_size > 0:
        conf_mat = np.loadtxt(conf_used, delimiter=",", ndmin=2)
        if conf_mat.shape[0] != nt:
            conf_mat = None
    else:
        conf_mat = _load_confounds_matrix(confounds_tsv, nt)
    cm_path = res_dir / "censor_mask.csv"
    keep = np.loadtxt(cm_path, delimiter=",").astype(bool).ravel() if cm_path.exists() else np.ones(nt, bool)
    if keep.size != nt:
        keep = np.ones(nt, bool)

    pre_mask = Path(bold_mni).parent / "brain_mask_mni.nii.gz"
    if pre_mask.exists():
        mask_img = nib.load(str(pre_mask))  # anatomical brain mask from preprocessing (v0.5.0)
    else:
        mask_img = masking.compute_epi_mask(bold_img)
    masker = NiftiMasker(mask_img=mask_img, standardize=None, detrend=False)
    voxel_ts = masker.fit_transform(bold_img).astype(np.float64)  # (T, V)

    summ_p = res_dir / "biomarkers_summary.json"
    censor_mode = "spike"
    if summ_p.exists():
        censor_mode = str(json.loads(summ_p.read_text(encoding="utf-8")).get("censor_mode", "spike"))
    t_idx = np.arange(nt, dtype=np.float64)
    base = np.column_stack([np.ones(nt), (t_idx - t_idx.mean()) / max(t_idx.std(), 1e-12)])
    nuis = base if conf_mat is None or conf_mat.size == 0 else np.column_stack([base, conf_mat])
    dct = _dct_stopband(nt, eff_tr, hp, lp)
    design = np.column_stack([nuis, dct]) if dct.size else nuis
    if censor_mode == "interpolate":
        # Rust interpolate mode: nuisance OLS on retained frames -> linear interpolation of censored
        # frames -> DCT (+ mean/trend) projection -> censored frames dropped.
        beta = np.linalg.lstsq(nuis[keep], voxel_ts[keep], rcond=None)[0]
        resid = voxel_ts - nuis @ beta
        if not keep.all():
            good = np.where(keep)[0]
            for b_ in np.where(~keep)[0]:
                left, right = good[good < b_], good[good > b_]
                if left.size and right.size:
                    lo, hi = left[-1], right[0]
                    w = (b_ - lo) / (hi - lo)
                    resid[b_] = (1 - w) * resid[lo] + w * resid[hi]
                else:
                    resid[b_] = resid[left[-1] if left.size else right[0]]
        proj = np.column_stack([base, dct]) if dct.size else base
        q, _ = np.linalg.qr(proj)
        clean = (resid - q @ (q.T @ resid))[keep]
    else:
        # Default (spike / none): nuisance + DCT stopband fitted simultaneously on retained frames
        # only, identical to the Rust spike mode and to AFNI 3dTproject -cenmode KILL.
        q, _ = np.linalg.qr(design[keep])
        y = voxel_ts[keep]
        clean = y - q @ (q.T @ y)
    seed_k = seed[keep]
    n_keep = int(keep.sum())
    dof = int(n_keep - np.linalg.matrix_rank(design[keep]))

    if dof < 10:
        raise SystemExit(
            f"Seed map not computed: only {dof} residual degrees of freedom after nuisance regression, band-pass "
            f"and censoring ({n_keep} retained frames). Widen the band (e.g. high_hz 0.1-0.15 Hz), reduce confounds or "
            "censor less aggressively."
        )
    seed_z = (seed_k - seed_k.mean()) / max(seed_k.std(ddof=1), 1e-12)
    v_std = clean.std(axis=0, ddof=1)
    valid_v = v_std > 1e-10
    z_vec = np.zeros(clean.shape[1], dtype=np.float64)
    r_vec = np.zeros(clean.shape[1], dtype=np.float64)
    if np.any(valid_v):
        vox_z = (clean[:, valid_v] - clean[:, valid_v].mean(axis=0)) / v_std[valid_v]
        r = np.clip((seed_z @ vox_z) / max(1, n_keep - 1), -0.99999, 0.99999)
        r_vec[valid_v] = r
        # Fisher z scaled by the *residual* degrees of freedom (not the raw frame count):
        # band-pass filtering and nuisance regression leave only `dof` independent samples.
        z_vec[valid_v] = np.arctanh(r) * np.sqrt(max(1.0, float(dof - 3)))

    z_img = masker.inverse_transform(z_vec)
    zmap_path = out_dir / "seed_zmap.nii.gz"
    nib.save(z_img, str(zmap_path))

    height_ctrl = correction.lower()
    if height_ctrl not in ("fdr", "bonferroni", "fpr", "none"):
        height_ctrl = "fdr"
    if height_ctrl == "none":
        height_ctrl = "fpr"

    thresh_img, thresh_val = glm.threshold_stats_img(
        z_img,
        alpha=alpha,
        height_control=height_ctrl,
        cluster_threshold=cluster_threshold,
        two_sided=True,
    )
    thresh_data = np.asarray(thresh_img.dataobj)
    n_sig_voxels = int(np.count_nonzero(np.abs(thresh_data) > 0))
    peak_z = float(np.nanmax(np.abs(np.asarray(z_img.dataobj))))

    clusters_list: list[dict] = []
    if n_sig_voxels > 0 and thresh_val is not None and np.isfinite(thresh_val):
        try:
            tbl = reporting.get_clusters_table(
                z_img,
                stat_threshold=float(thresh_val),
                cluster_threshold=cluster_threshold,
                two_sided=True,
            )
            if tbl is not None and len(tbl) > 0:
                for _, row in tbl.head(15).iterrows():
                    clusters_list.append(
                        {
                            "cluster_id": str(row.get("Cluster ID", "")),
                            "x": float(row.get("X", 0.0)),
                            "y": float(row.get("Y", 0.0)),
                            "z": float(row.get("Z", 0.0)),
                            "peak_stat": float(row.get("Peak Stat", 0.0)),
                            "cluster_size_mm3": float(row.get("Cluster Size (mm3)", 0.0)),
                        }
                    )
        except Exception:
            pass

    label_str = _load_roi_label(labels_json, roi_index, seed_label)
    corr_badge = f"{height_ctrl.upper()} α={alpha:.3g}, k≥{cluster_threshold}"

    glass_png = out_dir / "glass_brain_seed.png"
    ortho_png = out_dir / "stat_map_ortho.png"
    bg_mean = mean_img(bold_img)

    plot_img = thresh_img if n_sig_voxels > 0 else z_img
    plot_thresh = float(thresh_val) if (n_sig_voxels > 0 and np.isfinite(thresh_val)) else 2.5

    disp = plotting.plot_glass_brain(
        plot_img,
        threshold=plot_thresh if n_sig_voxels > 0 else None,
        colorbar=True,
        black_bg=True,
        plot_abs=False,
        cmap="cold_hot",
        title=f"Seed GLM: {label_str} ({corr_badge})",
    )
    disp.savefig(str(glass_png), dpi=150)
    disp.close()

    disp2 = plotting.plot_stat_map(
        plot_img,
        bg_img=bg_mean,
        threshold=plot_thresh if n_sig_voxels > 0 else None,
        colorbar=True,
        black_bg=True,
        cmap="cold_hot",
        display_mode="ortho",
        title=f"Seed Z-Map: {label_str}",
    )
    disp2.savefig(str(ortho_png), dpi=150)
    disp2.close()

    summary = {
        "mode": "seed-glm",
        "statistic": "seed correlation, Fisher z * sqrt(DOF - 3)",
        "n_frames_retained": int(n_keep),
        "residual_dof": int(dof),
        "censor_mode": censor_mode,
        "roi_index": int(roi_index),
        "seed_label": label_str,
        "correction": height_ctrl,
        "alpha": float(alpha),
        "cluster_threshold": int(cluster_threshold),
        "threshold_z": float(thresh_val) if thresh_val is not None and np.isfinite(thresh_val) else None,
        "peak_abs_z": peak_z,
        "n_sig_voxels": n_sig_voxels,
        "n_clusters": len(clusters_list),
        "clusters": clusters_list,
        "glass_brain_png": str(glass_png),
        "stat_map_png": str(ortho_png),
        "seed_zmap_nii": str(zmap_path),
    }
    (out_dir / "seed_glm_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    return summary


def _extract_subject_key(row: pd.Series) -> str:
    if "subject" in row and pd.notna(row["subject"]) and str(row["subject"]).strip():
        return str(row["subject"]).strip()
    raw = str(row.get("id", "") or row.get("results_dir", "")).strip()
    base = raw.replace("\\", "/").strip("/")
    parts = [p for p in base.split("/") if p]
    if len(parts) >= 2 and parts[-1].lower() in ("pre", "post", "baseline", "followup", "ses-01", "ses-02"):
        return parts[-2]
    return re.sub(r"([/_-])(pre|post|baseline|followup|ses-\w+)$", "", base, flags=re.IGNORECASE)


def _infer_group_label(row: pd.Series, group_col: str) -> str:
    if group_col in row and pd.notna(row[group_col]) and str(row[group_col]).strip():
        return str(row[group_col]).strip()
    raw = str(row.get("id", "") or row.get("results_dir", "")).lower()
    for token in ("pre", "post", "control", "patient", "stroke", "tbi", "baseline", "followup"):
        if re.search(rf"(^|[/_\-.]){token}($|[/_\-.])", raw):
            return token
    return "unknown"


def _fast_edgewise_t(
    mat_a: np.ndarray, mat_b: np.ndarray, paired: bool
) -> tuple[np.ndarray, np.ndarray]:
    """Computes nan-aware edgewise t-stats (Group B - Group A) & two-sided p-values over vectorized upper triangle."""
    # mat_a: (Na, E), mat_b: (Nb, E)
    if paired:
        diff = mat_b - mat_a
        valid_n = np.sum(np.isfinite(diff), axis=0)
        mean_d = np.nanmean(diff, axis=0)
        sd_d = np.nanstd(diff, axis=0, ddof=1)
        denom = sd_d / np.sqrt(np.maximum(valid_n, 1))
        with np.errstate(divide="ignore", invalid="ignore"):
            t = np.where((valid_n >= 2) & (denom > 1e-12), mean_d / denom, 0.0)
        df = np.maximum(valid_n - 1, 1)
    else:
        n_a = np.sum(np.isfinite(mat_a), axis=0)
        n_b = np.sum(np.isfinite(mat_b), axis=0)
        m_a = np.nanmean(mat_a, axis=0)
        m_b = np.nanmean(mat_b, axis=0)
        v_a = np.nanvar(mat_a, axis=0, ddof=1)
        v_b = np.nanvar(mat_b, axis=0, ddof=1)
        with np.errstate(divide="ignore", invalid="ignore"):
            s_pool2 = ((n_a - 1) * v_a + (n_b - 1) * v_b) / np.maximum(n_a + n_b - 2, 1)
            se = np.sqrt(s_pool2 * (1.0 / np.maximum(n_a, 1) + 1.0 / np.maximum(n_b, 1)))
            t = np.where((n_a >= 2) & (n_b >= 2) & (se > 1e-12), (m_b - m_a) / se, 0.0)
        df = np.maximum(n_a + n_b - 2, 1)

    p = 2.0 * stats.t.sf(np.abs(t), df=df)
    p = np.where(np.isfinite(p), np.clip(p, 0.0, 1.0), 1.0)
    return t, p


def _nbs_max_component_edges(
    t_vec: np.ndarray, iu: np.ndarray, ju: np.ndarray, n_nodes: int, thresh: float
) -> int:
    mask = np.abs(t_vec) > thresh
    if not np.any(mask):
        return 0
    rows = np.concatenate([iu[mask], ju[mask]])
    cols = np.concatenate([ju[mask], iu[mask]])
    adj = sparse.csr_matrix((np.ones(len(rows), dtype=np.int8), (rows, cols)), shape=(n_nodes, n_nodes))
    n_comp, labels = sparse.csgraph.connected_components(adj, directed=False, return_labels=True)
    # Count edges inside each connected component
    comp_ids = labels[iu[mask]]
    counts = np.bincount(comp_ids, minlength=n_comp)
    return int(np.max(counts)) if len(counts) > 0 else 0


def run_group_stats(
    batch_csv: Path,
    out_dir: Path,
    group_col: str = "session",
    group_a: str = "pre",
    group_b: str = "post",
    paired: bool = False,
    n_perm: int = 500,
    alpha: float = 0.05,
    nbs_thresh: float = 2.5,
) -> dict:
    """Runs Nilearn/SciPy group connectivity analysis (FDR, NBS, Tangent Decoding, LMM)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    df = pd.read_csv(batch_csv)
    if "status" in df.columns:
        df = df[df["status"].astype(str).str.lower() == "done"].copy()
    if len(df) < 2:
        raise SystemExit(f"Need at least 2 completed rows in {batch_csv}, found {len(df)}.")

    df["_group"] = [str(_infer_group_label(row, group_col)) for _, row in df.iterrows()]
    df["_subject"] = [_extract_subject_key(row) for _, row in df.iterrows()]

    df_a = df[df["_group"].str.lower() == group_a.lower()].copy()
    df_b = df[df["_group"].str.lower() == group_b.lower()].copy()
    if len(df_a) == 0 or len(df_b) == 0:
        avail = sorted(df["_group"].unique().tolist())
        raise SystemExit(
            f"Could not find both groups '{group_a}' and '{group_b}' in column '{group_col}'. Available: {avail}"
        )

    if paired:
        common = sorted(set(df_a["_subject"]).intersection(set(df_b["_subject"])))
        if len(common) < 2:
            raise SystemExit(
                f"Paired test requested but only {len(common)} matching subjects found between '{group_a}' and '{group_b}'."
            )
        df_a = df_a.set_index("_subject").loc[common].reset_index()
        df_b = df_b.set_index("_subject").loc[common].reset_index()

    def load_fcs(sub_df: pd.DataFrame) -> list[np.ndarray]:
        mats = []
        for _, row in sub_df.iterrows():
            rdir = Path(str(row["results_dir"]))
            fcp = rdir / "fc_matrix.csv"
            if not fcp.exists():
                raise SystemExit(f"Missing fc_matrix.csv at {fcp}")
            m = np.loadtxt(fcp, delimiter=",", dtype=np.float64)
            np.fill_diagonal(m, 1.0)
            mats.append(m)
        return mats

    fcs_a = load_fcs(df_a)
    fcs_b = load_fcs(df_b)
    n_nodes = fcs_a[0].shape[0]
    iu, ju = np.triu_indices(n_nodes, k=1)

    z_a = np.vstack([np.arctanh(np.clip(m[iu, ju], -0.999, 0.999)) for m in fcs_a])
    z_b = np.vstack([np.arctanh(np.clip(m[iu, ju], -0.999, 0.999)) for m in fcs_b])

    obs_t, obs_p = _fast_edgewise_t(z_a, z_b, paired=paired)
    q_vals = stats.false_discovery_control(obs_p, method="bh")
    sig_fdr_mask = q_vals < alpha
    n_fdr_sig = int(np.sum(sig_fdr_mask))

    mean_diff_vec = np.nanmean(np.stack([m[iu, ju] for m in fcs_b]), axis=0) - np.nanmean(
        np.stack([m[iu, ju] for m in fcs_a]), axis=0
    )

    # Save top edges / all FDR significant edges
    edge_rows = []
    if n_fdr_sig > 0:
        sig_idx = np.where(sig_fdr_mask)[0]
    else:
        sig_idx = np.argsort(obs_p)[: min(50, len(obs_p))]
    for e_i in sig_idx:
        edge_rows.append(
            {
                "roi_i": int(iu[e_i]),
                "roi_j": int(ju[e_i]),
                "delta_fc_b_minus_a": float(mean_diff_vec[e_i]),
                "t_stat": float(obs_t[e_i]),
                "p_uncorr": float(obs_p[e_i]),
                "q_fdr": float(q_vals[e_i]),
                "significant_fdr": bool(q_vals[e_i] < alpha),
            }
        )
    edge_df = pd.DataFrame(edge_rows).sort_values("q_fdr" if edge_rows else "p_uncorr")
    fdr_csv = out_dir / "fdr_significant_edges.csv"
    edge_df.to_csv(fdr_csv, index=False)

    # NBS Permutation test
    obs_nbs_edges = _nbs_max_component_edges(obs_t, iu, ju, n_nodes, nbs_thresh)
    rng = np.random.default_rng(42)
    null_max = np.zeros(max(1, n_perm), dtype=np.int32)
    if obs_nbs_edges > 0 and n_perm > 0:
        if paired:
            diff_mat = z_b - z_a
            n_sub = diff_mat.shape[0]
            for pi in range(n_perm):
                signs = rng.choice([-1.0, 1.0], size=(n_sub, 1))
                p_t, _ = _fast_edgewise_t(np.zeros_like(diff_mat), diff_mat * signs, paired=True)
                null_max[pi] = _nbs_max_component_edges(p_t, iu, ju, n_nodes, nbs_thresh)
        else:
            stacked = np.vstack([z_a, z_b])
            n_a = z_a.shape[0]
            n_tot = stacked.shape[0]
            for pi in range(n_perm):
                perm = rng.permutation(n_tot)
                p_t, _ = _fast_edgewise_t(stacked[perm[:n_a]], stacked[perm[n_a:]], paired=False)
                null_max[pi] = _nbs_max_component_edges(p_t, iu, ju, n_nodes, nbs_thresh)
        nbs_p = float((1.0 + np.sum(null_max >= obs_nbs_edges)) / (n_perm + 1.0))
    else:
        nbs_p = 1.0

    # Nilearn Tangent-Space Decoding (if >= 4 per group)
    tangent_acc = None
    tangent_note = "Skipped: need >= 4 subjects per group for stratified CV decoding."
    if len(fcs_a) >= 4 and len(fcs_b) >= 4:
        try:
            all_mats = fcs_a + fcs_b
            valid_nodes = np.all([np.all(np.isfinite(m), axis=1) for m in all_mats], axis=0)
            keep_idx = np.where(valid_nodes)[0]
            if len(keep_idx) >= 5:
                sub_mats = [m[np.ix_(keep_idx, keep_idx)] + 1e-3 * np.eye(len(keep_idx)) for m in all_mats]
                conn = ConnectivityMeasure(kind="tangent", vectorize=True, discard_diagonal=True)
                # Fit on raw SPD correlation matrices via cov_estimator bypass (pass directly to fit_transform via custom? ConnectivityMeasure expects timeseries, unless kind="tangent" accepts connectomes? Wait: ConnectivityMeasure expects timeseries! We can compute Fréchet-like tangent directly using nilearn.connectome._utils or LogEuclidean!)
                # Log-Euclidean tangent-space projection (exact SPD manifold tangent at identity/mean):
                from scipy.linalg import logm

                mean_spd = np.mean(sub_mats, axis=0)
                evals, evecs = np.linalg.eigh(mean_spd)
                evals = np.clip(evals, 1e-4, None)
                inv_sqrt = (evecs / np.sqrt(evals)) @ evecs.T
                feats = []
                idx_tri = np.triu_indices(len(keep_idx), k=1)
                for m in sub_mats:
                    whitened = inv_sqrt @ m @ inv_sqrt
                    tang = logm(whitened).real
                    feats.append(tang[idx_tri])
                X_tan = np.vstack(feats)
                y_cls = np.array([0] * len(fcs_a) + [1] * len(fcs_b))
                n_splits = min(5, len(fcs_a), len(fcs_b))
                cv = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=42)
                scores = cross_val_score(RidgeClassifier(alpha=1.0), X_tan, y_cls, cv=cv)
                tangent_acc = float(np.mean(scores))
                tangent_note = f"Log-Euclidean Tangent Ridge CV ({n_splits}-fold, {len(keep_idx)} intact ROIs)"
                _ = conn  # keep reference intact
        except Exception as exc:
            tangent_note = f"Tangent decoding unavailable: {exc}"

    # Group LMM on batch scalar metrics
    lmm_rows = []
    for metric in ["mean_abs_fc", "global_efficiency", "mean_homotopic_fc", "mean_gcmi_bits", "mean_te_bits"]:
        if metric not in df.columns:
            continue
        sub = df[df["_group"].str.lower().isin([group_a.lower(), group_b.lower()])].copy()
        sub = sub.dropna(subset=[metric, "_subject"])
        if len(sub) < 4 or sub["_subject"].nunique() < 2:
            continue
        try:
            cov_part = " + mean_fd_mm" if ("mean_fd_mm" in sub.columns and sub["mean_fd_mm"].std() > 1e-9) else ""
            if "lesion_volume_ml" in sub.columns and sub["lesion_volume_ml"].std() > 1e-6:
                cov_part += " + lesion_volume_ml"
            mod = smf.mixedlm(f"{metric} ~ C(_group){cov_part}", data=sub, groups=sub["_subject"])
            fit = mod.fit(reml=True, method="lbfgs")
            term = [t for t in fit.fe_params.index if "_group" in t]
            if term:
                tk = term[0]
                lmm_rows.append(
                    {
                        "metric": metric,
                        "estimate": float(fit.fe_params[tk]),
                        "std_err": float(fit.bse_fe[tk]),
                        "z_value": float(fit.tvalues[tk]),
                        "p_value": float(fit.pvalues[tk]),
                        "n_obs": int(len(sub)),
                    }
                )
        except Exception:
            pass

    # Group Difference + T-stat Heatmap
    diff_mat = np.zeros((n_nodes, n_nodes), dtype=np.float64)
    t_mat = np.zeros((n_nodes, n_nodes), dtype=np.float64)
    diff_mat[iu, ju] = mean_diff_vec
    diff_mat[ju, iu] = mean_diff_vec
    t_mat[iu, ju] = obs_t
    t_mat[ju, iu] = obs_t

    plt.style.use("dark_background")
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.8), facecolor="#0B1120")
    vmax_d = max(0.1, float(np.nanpercentile(np.abs(diff_mat), 98)))
    im0 = axes[0].imshow(diff_mat, cmap="coolwarm", vmin=-vmax_d, vmax=vmax_d)
    axes[0].set_title(f"Mean ΔFC ({group_b} − {group_a})", fontsize=11)
    plt.colorbar(im0, ax=axes[0], fraction=0.046)

    vmax_t = max(2.0, float(np.nanpercentile(np.abs(t_mat), 98)))
    im1 = axes[1].imshow(t_mat, cmap="coolwarm", vmin=-vmax_t, vmax=vmax_t)
    axes[1].set_title(f"Edgewise t-Stat (FDR={n_fdr_sig}, NBS p={nbs_p:.3f})", fontsize=11)
    plt.colorbar(im1, ax=axes[1], fraction=0.046)
    plt.tight_layout()
    diff_png = out_dir / "group_diff_matrix.png"
    fig.savefig(str(diff_png), dpi=150, facecolor="#0B1120")
    plt.close(fig)

    summary = {
        "mode": "group",
        "group_a": group_a,
        "group_b": group_b,
        "n_group_a": int(len(fcs_a)),
        "n_group_b": int(len(fcs_b)),
        "paired": bool(paired),
        "alpha": float(alpha),
        "n_rois": int(n_nodes),
        "n_edges_tested": int(len(obs_t)),
        "n_fdr_sig_edges": n_fdr_sig,
        "nbs_thresh_t": float(nbs_thresh),
        "nbs_max_component_edges": int(obs_nbs_edges),
        "nbs_p_value": float(nbs_p),
        "n_perm": int(n_perm),
        "tangent_decoding_acc": tangent_acc,
        "tangent_note": tangent_note,
        "lmm_results": lmm_rows,
        "group_diff_png": str(diff_png),
        "fdr_edges_csv": str(fdr_csv),
        "top_edges": edge_rows[:15],
    }
    (out_dir / "nilearn_group_stats.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Advanced Nilearn Seed-to-Voxel GLM and Group Connectivity Statistics."
    )
    parser.add_argument("--mode", required=True, choices=["seed-glm", "group"])
    parser.add_argument("--out-dir", required=True, type=Path)

    # Seed GLM args
    parser.add_argument("--bold-mni", type=Path, default=None)
    parser.add_argument("--denoised-ts-csv", type=Path, default=None)
    parser.add_argument("--roi-index", type=int, default=0)
    parser.add_argument("--roi-labels-json", type=Path, default=None)
    parser.add_argument("--seed-label", type=str, default=None)
    parser.add_argument("--correction", default="fdr", choices=["fdr", "bonferroni", "fpr"])
    parser.add_argument("--alpha", type=float, default=0.05)
    parser.add_argument("--cluster-threshold", type=int, default=10)
    parser.add_argument("--confounds-tsv", type=Path, default=None)
    parser.add_argument("--low-hz", type=float, default=None)
    parser.add_argument("--high-hz", type=float, default=None)
    parser.add_argument("--tr", type=float, default=None)

    # Group Stats args
    parser.add_argument("--batch-csv", type=Path, default=None)
    parser.add_argument("--group-col", default="session")
    parser.add_argument("--group-a", default="pre")
    parser.add_argument("--group-b", default="post")
    parser.add_argument("--paired", action="store_true")
    parser.add_argument("--n-perm", type=int, default=500)
    parser.add_argument("--nbs-thresh", type=float, default=2.5)

    args = parser.parse_args()
    if args.mode == "seed-glm":
        if args.bold_mni is None or args.denoised_ts_csv is None:
            raise SystemExit("--mode seed-glm requires --bold-mni and --denoised-ts-csv")
        res = run_seed_glm(
            bold_mni=args.bold_mni,
            denoised_ts_csv=args.denoised_ts_csv,
            roi_index=args.roi_index,
            out_dir=args.out_dir,
            labels_json=args.roi_labels_json,
            seed_label=args.seed_label,
            alpha=args.alpha,
            correction=args.correction,
            cluster_threshold=args.cluster_threshold,
            confounds_tsv=args.confounds_tsv,
            low_hz=args.low_hz,
            high_hz=args.high_hz,
            tr_sec=args.tr,
        )
    else:
        if args.batch_csv is None:
            raise SystemExit("--mode group requires --batch-csv")
        res = run_group_stats(
            batch_csv=args.batch_csv,
            out_dir=args.out_dir,
            group_col=args.group_col,
            group_a=args.group_a,
            group_b=args.group_b,
            paired=args.paired,
            n_perm=args.n_perm,
            alpha=args.alpha,
            nbs_thresh=args.nbs_thresh,
        )
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
