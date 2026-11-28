"""Shared loaders and cleaning functions for the CCS fMRI Studio v0.5.0 validation report.

Three ways of turning a (T x 400) Schaefer ROI time series into cleaned data:
  * rust_clean   - the app's own Rust engine (simultaneous nuisance + DCT + spike regression, i.e.
                   AFNI 3dTproject -cenmode KILL), driven through the `denoise_csv` harness binary;
  * nilearn_equiv- nilearn.signal.clean given *the same design* (confounds + identical DCT basis,
                   censored frames removed with sample_mask): tests numerical equivalence;
  * nilearn_std  - nilearn.signal.clean as typically used (Butterworth band-pass, sample_mask):
                   the community-standard connectivity reference.
"""
from __future__ import annotations

import csv
import json
import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd
from nilearn import signal

SCR = Path(os.environ["CCS_SCRATCH"])
VAL = Path(os.environ["CCS_VALDATA"])
DENOISE_BIN = SCR / "harness/target/release/denoise_csv"
NETS = ["Vis", "SomMot", "DorsAttn", "SalVentAttn", "Limbic", "Cont", "Default"]


def schaefer_networks() -> np.ndarray:
    labels = json.loads((SCR / "v5/ds003768_sub-01__rest_run-1/schaefer400_labels.json").read_text())
    labels = [l for l in labels if l.lower() != "background"]
    return np.array([l.split("_")[2] for l in labels])


NET = schaefer_networks()
IU = np.triu_indices(400, 1)
SAME = (NET[:, None] == NET[None])[IU]


# ----------------------------------------------------------------------------------------------
# Run registry
# ----------------------------------------------------------------------------------------------
def app_dir(run: str) -> Path:
    if run.startswith("sub-0") and "_run-" in run and not run.startswith("sub-01"):
        return SCR / "ext/app" / run
    return SCR / "v5" / run


def ref_paths(run: str) -> tuple[Path, Path] | None:
    """(ROI time series .npy or BOLD .nii.gz, confounds .tsv) for runs with fMRIPrep derivatives."""
    if run.startswith("sub-0") and not run.startswith("sub-01"):
        s, r = run.split("_run-")
        return (SCR / f"ext/fp_ts/{s}_task-rest_run-{r}_space-MNI152NLin6Asym_res-2_desc-preproc_bold_schaefer400.npy",
                SCR / f"ext/fp_out/{s}/func/{s}_task-rest_run-{r}_desc-confounds_timeseries.tsv")
    if run == "ds003768_sub-01__rest_run-1":
        return (SCR / "fmriprep/out/sub-01/func/sub-01_task-rest_run-1_space-MNI152NLin6Asym_res-2_desc-preproc_bold.nii.gz",
                SCR / "fmriprep/out/sub-01/func/sub-01_task-rest_run-1_desc-confounds_timeseries.tsv")
    if run == "ds006110_sub-PC001__ses-01_pre__rest":
        return (SCR / "fmriprep/out/sub-PC001/func/sub-PC001_task-rest_space-MNI152NLin6Asym_res-2_desc-preproc_bold.nii.gz",
                SCR / "fmriprep/out/sub-PC001/func/sub-PC001_task-rest_desc-confounds_timeseries.tsv")
    return None


EXT = [f"sub-{s}_run-{r}" for s in ("02", "03", "04", "05", "06", "07") for r in (1, 2)]
OWN = ["ds003768_sub-01__rest_run-1", "ds003768_sub-01__rest_run-2", "ds003768_sub-01__sleep_run-1",
       "ds003768_sub-01__sleep_run-2", "ds003768_sub-01__sleep_run-3"] + \
      [f"ds006110_sub-PC001__ses-0{i}_{s}__{c}" for i, s in ((1, "pre"), (2, "post"))
       for c in ("rest", "movie", "music", "meditation")]
BOTH = EXT + ["ds003768_sub-01__rest_run-1", "ds006110_sub-PC001__ses-01_pre__rest"]


def read_csv(p: Path) -> np.ndarray:
    return np.loadtxt(p, delimiter=",", ndmin=2)


def load_app(run: str) -> dict:
    d = app_dir(run)
    h = d / "harness"
    rep = json.loads((d / "preprocess_report.json").read_text())
    fd = pd.read_csv(d / "confounds.tsv", sep="\t")["framewise_displacement"].to_numpy()
    return dict(raw=read_csv(h / "raw_ts.csv"), conf=read_csv(h / "confounds_used.csv"), fd=fd,
                scrub=np.where(fd > 0.5)[0], tr=float(rep["tr_sec"]), dir=d)


_ref_cache: dict = {}


def load_ref(run: str) -> dict | None:
    rp = ref_paths(run)
    if rp is None:
        return None
    ts_p, conf_p = rp
    if ts_p.suffix == ".npy":
        raw = np.load(ts_p).astype(np.float64)
    else:
        cache = SCR / "pubcache" / f"{run}_fp_schaefer400.npy"
        if not cache.exists():
            from nilearn import datasets
            from nilearn.maskers import NiftiLabelsMasker
            cache.parent.mkdir(exist_ok=True)
            sch = datasets.fetch_atlas_schaefer_2018(n_rois=400, resolution_mm=2, verbose=0)
            np.save(cache, NiftiLabelsMasker(sch.maps, strategy="mean").fit_transform(str(ts_p)).astype(np.float32))
        raw = np.load(cache).astype(np.float64)
    c = pd.read_csv(conf_p, sep="\t")
    mot = c[["trans_x", "trans_y", "trans_z", "rot_x", "rot_y", "rot_z"]].to_numpy()
    d = np.vstack([np.zeros((1, 6)), np.diff(mot, axis=0)])
    acc = c[[f"w_comp_cor_{i:02d}" for i in range(5)] + [f"c_comp_cor_{i:02d}" for i in range(5)]].to_numpy()
    fd = c["framewise_displacement"].fillna(0).to_numpy()
    tr = 2.1 if "PC001" not in run else 0.91
    return dict(raw=raw, conf=np.hstack([mot, d, mot ** 2, d ** 2, acc]), fd=fd, scrub=np.where(fd > 0.5)[0], tr=tr)


# ----------------------------------------------------------------------------------------------
# Cleaning
# ----------------------------------------------------------------------------------------------
def dct_stopband(nt: int, tr: float, lo: float | None, hi: float | None) -> np.ndarray:
    win = 2.0 * nt * tr
    ks: list[int] = []
    if lo:
        ks += list(range(1, min(int(np.floor(win * lo)), nt - 1) + 1))
    if hi and 0 < hi < 0.5 / tr:
        ks += list(range(max(int(np.ceil(win * hi)), 1, (ks[-1] + 1) if ks else 1), nt))
    t = np.arange(nt) + 0.5
    return np.sqrt(2.0 / nt) * np.cos(np.pi / nt * np.outer(t, np.asarray(ks, float))) if ks else np.zeros((nt, 0))


def rust_clean(raw, conf, scrub, tr, lo=0.008, hi=0.09, mode="spike", dyn_window: int | None = None) -> dict:
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        np.savetxt(td / "ts.csv", raw, delimiter=",")
        cp = "-"
        if conf is not None and conf.size:
            np.savetxt(td / "conf.csv", conf, delimiter=","); cp = str(td / "conf.csv")
        sp = "-"
        if len(scrub):
            (td / "scrub.txt").write_text("\n".join(map(str, scrub))); sp = str(td / "scrub.txt")
        args = [str(DENOISE_BIN), str(td / "ts.csv"), cp, sp, str(tr), str(lo or 0), str(hi or 0), mode, str(td / "o")]
        if dyn_window:
            args.append(str(dyn_window))
        subprocess.run(args, check=True, capture_output=True)
        out = dict(clean=read_csv(td / "o_clean.csv"),
                   kept=np.loadtxt(td / "o_kept.txt", dtype=int, ndmin=1),
                   dof=int((td / "o_dof.txt").read_text()))
        if dyn_window:
            out["hp"] = read_csv(td / "o_hp.csv")
            out["dyn"] = read_csv(td / "o_dyn.csv")
        return out


def nilearn_equiv(raw, conf, scrub, tr, lo=0.008, hi=0.09) -> np.ndarray:
    nt = raw.shape[0]
    keep = np.setdiff1d(np.arange(nt), scrub)
    t = np.arange(nt, dtype=float)
    design = np.column_stack([(t - t.mean()) / t.std(), dct_stopband(nt, tr, lo, hi)])  # trend on the original time axis
    if conf is not None and conf.size:
        design = np.hstack([conf, design])
    return signal.clean(raw, confounds=design, detrend=False, standardize="zscore_sample", sample_mask=keep,
                        filter=False, standardize_confounds=True, t_r=tr)


def nilearn_std(raw, conf, scrub, tr, lo=0.008, hi=0.09) -> np.ndarray:
    nt = raw.shape[0]
    keep = np.setdiff1d(np.arange(nt), scrub)
    return signal.clean(raw, confounds=conf, detrend=True, standardize="zscore_sample", sample_mask=keep,
                        filter="butterworth", low_pass=hi, high_pass=lo, t_r=tr)


def fc(ts: np.ndarray) -> np.ndarray:
    return np.corrcoef(ts.T)


def ztri(m: np.ndarray) -> np.ndarray:
    return np.arctanh(np.clip(m[IU], -0.999999, 0.999999))


def tri_r(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.corrcoef(a[IU], b[IU])[0, 1])


def network_matrix(m: np.ndarray) -> np.ndarray:
    out = np.zeros((7, 7))
    z = np.arctanh(np.clip(m, -0.999999, 0.999999))
    np.fill_diagonal(z, np.nan)
    for i, a in enumerate(NETS):
        for j, b in enumerate(NETS):
            out[i, j] = np.nanmean(z[np.ix_(NET == a, NET == b)])
    return out


def network_contrast(m: np.ndarray) -> float:
    z = ztri(m)
    return float(z[SAME].mean() - z[~SAME].mean())


def acw0(x: np.ndarray, tr: float) -> float:
    """Autocorrelation window (first zero crossing of the ACF), seconds (Honey et al., 2012)."""
    x = x - x.mean()
    n = len(x)
    f = np.fft.rfft(x, 2 * n)
    ac = np.fft.irfft(f * np.conj(f))[:n]
    ac = ac / ac[0]
    idx = np.where(ac <= 0)[0]
    return float(idx[0] * tr) if idx.size else np.nan


def stages_for(run: str, nt: int, tr: float) -> np.ndarray | None:
    """Per-volume sleep stage label ('W', 'N1', 'N2' or '') from the official 30-s scoring."""
    if run.startswith("ds003768_sub-01"):
        f = VAL / "ds003768_sub-01/sub-01-sleep-stage.tsv"; sub_col, ses_col, t_col, st_col = 0, 1, 2, 3
        task = run.split("__")[1].replace("rest_run-", "task-rest_run-").replace("sleep_run-", "task-sleep_run-")
    elif run.startswith("sub-0"):
        s, r = run.split("_run-")
        f = SCR / f"ext/stages/{s}-sleep-stage.tsv"; ses_col, t_col, st_col = 0, 1, 2
        task = f"task-rest_run-{r}"
    else:
        return None
    rows = [x for x in csv.reader(open(f, newline=""), delimiter="\t")][1:]
    lab = {}
    for x in rows:
        if x[ses_col].strip() == task:
            st = x[st_col].strip()
            lab[int(float(x[t_col]))] = {"W": "W", "1": "N1", "2": "N2", "3": "N3"}.get(st, "")
    out = np.array([lab.get(int((k * tr) // 30) * 30, "") for k in range(nt)])
    return out
