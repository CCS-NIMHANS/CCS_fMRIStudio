"""Benchmark & numerical parity verification: Rust core engine vs. nilearn."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd
from nilearn import image, maskers, signal


def _peak_rss_mb_self() -> float:
    import resource

    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return ru / (1024.0 * 1024.0) if sys.platform == "darwin" else ru / 1024.0


def run_nilearn_end_to_end(
    bold_path: Path,
    atlas_path: Path,
    wm_mask_path: Path,
    csf_mask_path: Path,
    confounds_path: Path,
    tr_sec: float,
    low_hz: float,
    high_hz: float,
    fd_threshold: float,
) -> dict:
    t_total = time.perf_counter()

    t0 = time.perf_counter()
    bold_img = nib.load(str(bold_path))
    atlas_img = nib.load(str(atlas_path))
    wm_img = nib.load(str(wm_mask_path))
    csf_img = nib.load(str(csf_mask_path))
    conf_df = pd.read_csv(confounds_path, sep="\t")
    load_ms = (time.perf_counter() - t0) * 1000.0

    t1 = time.perf_counter()
    masker = maskers.NiftiLabelsMasker(
        labels_img=atlas_img, standardize=None, detrend=False
    )
    raw_ts = masker.fit_transform(bold_img)
    parcellation_ms = (time.perf_counter() - t1) * 1000.0

    t2 = time.perf_counter()
    wm_comp = image.high_variance_confounds(bold_img, mask_img=wm_img, n_confounds=5)
    csf_comp = image.high_variance_confounds(bold_img, mask_img=csf_img, n_confounds=5)
    motion_cols = [
        c for c in conf_df.columns if c not in ("framewise_displacement", "ants_fd")
    ]
    conf_all = np.hstack([conf_df[motion_cols].to_numpy(dtype=np.float64), wm_comp, csf_comp])
    sample_mask = conf_df["framewise_displacement"].to_numpy() <= fd_threshold
    acompcor_ms = (time.perf_counter() - t2) * 1000.0

    t3 = time.perf_counter()
    clean_ts = signal.clean(
        raw_ts,
        detrend=True,
        standardize="zscore_sample",
        sample_mask=sample_mask if np.any(~sample_mask) else None,
        confounds=conf_all,
        filter="butterworth",
        high_pass=low_hz,
        low_pass=high_hz,
        t_r=tr_sec,
    )
    denoise_ms = (time.perf_counter() - t3) * 1000.0

    t4 = time.perf_counter()
    fc = np.corrcoef(clean_ts, rowvar=False)
    fc_ms = (time.perf_counter() - t4) * 1000.0

    tri = fc[np.triu_indices_from(fc, k=1)]
    return {
        "engine": f"nilearn ({bold_path.name})",
        "n_timepoints": int(raw_ts.shape[0]),
        "n_rois": int(raw_ts.shape[1]),
        "n_kept_frames": int(clean_ts.shape[0]),
        "load_ms": round(load_ms, 2),
        "parcellation_ms": round(parcellation_ms, 2),
        "acompcor_ms": round(acompcor_ms, 2),
        "denoise_ms": round(denoise_ms, 2),
        "fc_ms": round(fc_ms, 2),
        "total_ms": round((time.perf_counter() - t_total) * 1000.0, 2),
        "mean_abs_fc": float(np.nanmean(np.abs(tri))),
        "peak_rss_mb": round(_peak_rss_mb_self(), 2),
    }


def run_nilearn_isolated(
    preproc_dir: Path,
    bold_path: Path,
    tr_sec: float,
    low_hz: float = 0.008,
    high_hz: float = 0.09,
    fd_threshold: float = 0.5,
) -> dict:
    cmd = [
        sys.executable,
        "-m",
        "ccs_fmri_sidecar.benchmark_vs_nilearn",
        "--preproc-dir",
        str(preproc_dir),
        "--bench-bin",
        "unused",
        "--single-nilearn",
        str(bold_path),
        "--tr",
        str(tr_sec),
        "--low-hz",
        str(low_hz),
        "--high-hz",
        str(high_hz),
        "--fd-threshold",
        str(fd_threshold),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


def run_rust_bench(
    bench_bin: Path,
    bold_path: Path,
    atlas_path: Path,
    wm_mask_path: Path,
    csf_mask_path: Path,
    confounds_path: Path,
    tr_sec: float,
    low_hz: float,
    high_hz: float,
    fd_threshold: float,
    out_ts_csv: Path | None = None,
    out_conf_csv: Path | None = None,
) -> dict:
    base_cmd = [
        str(bench_bin),
        "--bold",
        str(bold_path),
        "--atlas",
        str(atlas_path),
        "--confounds",
        str(confounds_path),
        "--wm-mask",
        str(wm_mask_path),
        "--csf-mask",
        str(csf_mask_path),
        "--tr",
        str(tr_sec),
        "--low-hz",
        str(low_hz),
        "--high-hz",
        str(high_hz),
        "--fd-threshold",
        str(fd_threshold),
    ]
    if out_ts_csv is not None:
        base_cmd.extend(["--out-ts-csv", str(out_ts_csv)])
    if out_conf_csv is not None:
        base_cmd.extend(["--out-confounds-csv", str(out_conf_csv)])

    if sys.platform == "darwin" and Path("/usr/bin/time").exists():
        cmd = ["/usr/bin/time", "-l", *base_cmd]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        res = json.loads(proc.stdout)
        m = re.search(r"(\d+)\s+maximum resident set size", proc.stderr)
        if m:
            res["peak_rss_mb"] = round(int(m.group(1)) / (1024.0 * 1024.0), 2)
        return res

    proc = subprocess.run(base_cmd, capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


def _aggregate_trials(trials: list[dict]) -> dict:
    keys = [
        "load_ms",
        "parcellation_ms",
        "acompcor_ms",
        "denoise_ms",
        "fc_ms",
        "total_ms",
        "peak_rss_mb",
    ]
    agg = dict(trials[0])
    agg["repeats"] = len(trials)
    agg["trials"] = trials
    for k in keys:
        vals = [float(t[k]) for t in trials if k in t]
        if vals:
            agg[k] = round(statistics.median(vals), 2)
            agg[f"{k}_min"] = round(min(vals), 2)
            agg[f"{k}_max"] = round(max(vals), 2)
    return agg


def _roi_correlations(a: np.ndarray, b: np.ndarray) -> dict:
    corrs = []
    for j in range(a.shape[1]):
        ca = a[:, j]
        cb = b[:, j]
        if np.std(ca) > 1e-10 and np.std(cb) > 1e-10:
            corrs.append(float(np.corrcoef(ca, cb)[0, 1]))
    arr = np.asarray(corrs, dtype=np.float64)
    return {
        "n_rois_compared": int(len(arr)),
        "mean_r": float(np.mean(arr)),
        "median_r": float(np.median(arr)),
        "min_r": float(np.min(arr)),
        "max_r": float(np.max(arr)),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark Rust vs nilearn on preprocessed BOLD.")
    parser.add_argument("--preproc-dir", required=True, type=Path)
    parser.add_argument("--bench-bin", required=True, type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--out-json", type=Path, default=None)
    parser.add_argument("--single-nilearn", type=Path, default=None)
    parser.add_argument("--tr", type=float, default=2.0)
    parser.add_argument("--low-hz", type=float, default=0.008)
    parser.add_argument("--high-hz", type=float, default=0.09)
    parser.add_argument("--fd-threshold", type=float, default=0.5)
    args = parser.parse_args()

    pdir = args.preproc_dir
    atlas = pdir / "schaefer400_mni.nii.gz"
    wm = pdir / "wm_mask_mni.nii.gz"
    csf = pdir / "csf_mask_mni.nii.gz"
    conf = pdir / "confounds.tsv"

    if args.single_nilearn is not None:
        res = run_nilearn_end_to_end(
            args.single_nilearn,
            atlas,
            wm,
            csf,
            conf,
            args.tr,
            args.low_hz,
            args.high_hz,
            args.fd_threshold,
        )
        print(json.dumps(res))
        return

    report_meta = json.loads((pdir / "preprocess_report.json").read_text(encoding="utf-8"))
    tr_sec = float(report_meta["tr_sec"])
    bold_gz = pdir / "bold_mni.nii.gz"
    bold_nii = pdir / "bold_mni.nii"

    print(f"Running {args.repeats} repeated trials per engine...", flush=True)
    rust_nii_trials = [
        run_rust_bench(args.bench_bin, bold_nii, atlas, wm, csf, conf, tr_sec, 0.008, 0.09, 0.5)
        for _ in range(args.repeats)
    ]
    rust_gz_trials = [
        run_rust_bench(args.bench_bin, bold_gz, atlas, wm, csf, conf, tr_sec, 0.008, 0.09, 0.5)
        for _ in range(args.repeats)
    ]
    nil_nii_trials = [
        run_nilearn_isolated(pdir, bold_nii, tr_sec, 0.008, 0.09, 0.5)
        for _ in range(args.repeats)
    ]
    nil_gz_trials = [
        run_nilearn_isolated(pdir, bold_gz, tr_sec, 0.008, 0.09, 0.5)
        for _ in range(args.repeats)
    ]

    rust_nii = _aggregate_trials(rust_nii_trials)
    rust_gz = _aggregate_trials(rust_gz_trials)
    nil_nii = _aggregate_trials(nil_nii_trials)
    nil_gz = _aggregate_trials(nil_gz_trials)

    # Numerical parity checks using identical raw ROI timeseries & confounds matrix:
    with tempfile.TemporaryDirectory(prefix="ccs_parity_") as tmp:
        tmp_path = Path(tmp)
        ts_cosine_csv = tmp_path / "rust_cosine.csv"
        conf_csv = tmp_path / "rust_conf.csv"
        run_rust_bench(
            args.bench_bin,
            bold_nii,
            atlas,
            wm,
            csf,
            conf,
            tr_sec,
            0.008,
            0.0,
            0.0,
            out_ts_csv=ts_cosine_csv,
            out_conf_csv=conf_csv,
        )
        rust_cosine_ts = pd.read_csv(ts_cosine_csv).to_numpy(dtype=np.float64)
        rust_conf = pd.read_csv(conf_csv).to_numpy(dtype=np.float64)

        raw_ts = maskers.NiftiLabelsMasker(
            labels_img=nib.load(str(atlas)), standardize=None, detrend=False
        ).fit_transform(nib.load(str(bold_nii)))

        nil_cosine_ts = signal.clean(
            raw_ts,
            detrend=True,
            standardize="zscore_sample",
            confounds=rust_conf,
            filter="cosine",
            high_pass=0.008,
            low_pass=None,
            t_r=tr_sec,
        )
        cosine_parity = _roi_correlations(rust_cosine_ts, nil_cosine_ts)

        ts_bp_csv = tmp_path / "rust_bandpass.csv"
        run_rust_bench(
            args.bench_bin,
            bold_nii,
            atlas,
            wm,
            csf,
            conf,
            tr_sec,
            0.008,
            0.09,
            0.0,
            out_ts_csv=ts_bp_csv,
        )
        rust_bp_ts = pd.read_csv(ts_bp_csv).to_numpy(dtype=np.float64)
        nil_butter_ts = signal.clean(
            raw_ts,
            detrend=True,
            standardize="zscore_sample",
            confounds=rust_conf,
            filter="butterworth",
            high_pass=0.008,
            low_pass=0.09,
            t_r=tr_sec,
        )
        bandpass_parity = _roi_correlations(rust_bp_ts, nil_butter_ts)

    summary = {
        "repeats": args.repeats,
        "rust_mmap_nii": rust_nii,
        "rust_nii_gz": rust_gz,
        "nilearn_nii": nil_nii,
        "nilearn_nii_gz": nil_gz,
        "speedups": {
            "total_nii_mmap_vs_nilearn_median": round(
                nil_nii["total_ms"] / rust_nii["total_ms"], 2
            ),
            "total_niigz_vs_nilearn_median": round(
                nil_gz["total_ms"] / rust_gz["total_ms"], 2
            ),
            "parcellation_mmap_vs_nilearn_median": round(
                nil_nii["parcellation_ms"] / rust_nii["parcellation_ms"], 2
            ),
            "acompcor_mmap_vs_nilearn_median": round(
                nil_nii["acompcor_ms"] / rust_nii["acompcor_ms"], 2
            ),
            "denoise_vs_nilearn_butterworth_median": round(
                nil_nii["denoise_ms"] / rust_nii["denoise_ms"], 2
            ),
            "ram_reduction_nii_mmap_vs_nilearn": round(
                nil_nii["peak_rss_mb"] / rust_nii["peak_rss_mb"], 2
            ),
        },
        "parity": {
            "rust_dct_highpass_vs_nilearn_cosine": cosine_parity,
            "rust_dct_bandpass_vs_nilearn_butterworth": bandpass_parity,
        },
    }

    if args.out_json:
        args.out_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in summary.items() if k != "trials"}, indent=2))


if __name__ == "__main__":
    main()
