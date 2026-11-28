"""ANTsPy-based single-subject fMRI preprocessing CLI for CCS_fMRIStudio (v0.5.0).

Pipeline (each step validated; the run aborts with a clear error instead of writing bad outputs):
 1. T1w N4 bias-field correction.
 2. Template-based brain extraction: whole-head T1w -> whole-head MNI152NLin6Asym (SyN),
    template brain mask warped back to native space (antsBrainExtraction-style), N4 refined
    inside the mask.
 3. Tissue segmentation on the *skull-stripped* T1w (Atropos 3-class K-means, MRF smoothing);
    classes ordered by mean intensity (CSF < GM < WM); posteriors thresholded and eroded to
    build conservative WM / CSF masks for aCompCor (lesion-protected when a lesion mask is given).
 4. Brain-to-brain T1w -> template registration (SyNQuick / SyN; CFM or enantiomorphic for lesions).
 5. BOLD slice-timing correction (Fourier phase shift to the mid-TR reference) when
    `SliceTiming` is available in the BIDS sidecar.
 6. BOLD rigid head-motion estimation (sequentially initialised rigid registration to the mean
    reference); every per-volume transform is checked; 6 motion parameters + derivatives + Power FD
    written to confounds.tsv.
 7. BOLD reference -> skull-stripped T1w rigid coregistration.
 8. **Single-interpolation** resampling: for every volume the motion, coregistration and
    normalisation transforms are composed and applied once onto the 2 mm template grid.
 9. Schaefer-400 (7 networks) atlas in its native FSL MNI152 (NLin6Asym) 2 mm space; per-parcel
    EPI coverage is reported.
10. QC block (template correlation, brain-mask Dice, mask volumes, coverage, seeds, warnings).
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import shutil
import sys
import tempfile
import time
from pathlib import Path

import ants
import nibabel as nib
import numpy as np
import pandas as pd
import psutil
from nilearn import datasets, image
from scipy import ndimage
from scipy.spatial.transform import Rotation

from ccs_fmri_sidecar.qc_report import write_qc_report
from ccs_fmri_sidecar.templates import resolve_template
from ccs_fmri_sidecar.tf_templates import DEFAULT_SPACE, standard_space_files

PIPELINE_VERSION = "0.5.0"


class PreprocessingError(RuntimeError):
    """Raised when a preprocessing step produces invalid output."""


def _peak_rss_mb() -> float:
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":
        return ru / (1024.0 * 1024.0)
    return ru / 1024.0


def _current_rss_mb() -> float:
    return psutil.Process(os.getpid()).memory_info().rss / (1024.0 * 1024.0)


def _sidecar_json(bold_path: Path) -> dict:
    stem = bold_path.name
    if stem.endswith(".nii.gz"):
        json_path = bold_path.with_name(stem[:-7] + ".json")
    elif stem.endswith(".nii"):
        json_path = bold_path.with_name(stem[:-4] + ".json")
    else:
        return {}
    if json_path.exists():
        return json.loads(json_path.read_text(encoding="utf-8"))
    return {}


def _read_validated(path: Path, warnings: list[str]) -> ants.ANTsImage:
    """Read a NIfTI with ANTs and verify the voxel data against nibabel.

    On cloud-synced folders (Google Drive / OneDrive / iCloud "online-only" files) ITK's gzip reader
    was observed to return silently zero-filled volumes while the file was still being fetched,
    which then looked like 50-300 mm "head motion" (and corrupted v0.4.1 confounds). nibabel raises
    on truncated data, so its array is used as the reference.
    """
    img = ants.image_read(str(path), pixeltype="float")
    ref = np.asanyarray(nib.load(str(path)).dataobj).astype(np.float32)
    arr = img.numpy()
    if arr.shape != ref.shape:
        raise PreprocessingError(f"Shape mismatch reading {path}: ANTs {arr.shape} vs nibabel {ref.shape}")
    if not np.array_equal(arr, ref):
        img2 = ants.image_read(str(path), pixeltype="float")  # file is fully materialised now
        if np.array_equal(img2.numpy(), ref):
            img = img2
        else:
            img = img.new_image_like(np.ascontiguousarray(ref)).clone()
        warnings.append(f"ITK read of {Path(path).name} returned incomplete data (cloud-synced file?); "
                        "re-read and verified against nibabel.")
    return img


def _detect_tr(meta: dict, bold_ants: ants.ANTsImage) -> float:
    if "RepetitionTime" in meta and float(meta["RepetitionTime"]) > 0:
        return float(meta["RepetitionTime"])
    if len(bold_ants.spacing) >= 4 and bold_ants.spacing[3] > 0:
        return float(bold_ants.spacing[3])
    return 2.0


def _set_seed(seed: int, deterministic: bool) -> None:
    """Fix ANTs' metric-sampling seed (reproducible registrations)."""
    ants.config._random_seed = int(seed)  # noqa: SLF001 - documented global in ants.config
    ants.config._deterministic = True  # noqa: SLF001
    np.random.seed(seed)
    if deterministic:
        os.environ["ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS"] = "1"


def _check_disk(out_dir: Path, needed_bytes: int) -> None:
    free = shutil.disk_usage(out_dir).free
    if free < needed_bytes:
        raise PreprocessingError(
            f"Not enough free disk space in {out_dir}: {free / 1e9:.1f} GB free, "
            f"~{needed_bytes / 1e9:.1f} GB needed. ANTs writes temporary transforms per volume and "
            "fails silently when the disk fills up; free space and re-run."
        )


def _largest_component(mask: np.ndarray) -> np.ndarray:
    lab, n = ndimage.label(mask)
    if n <= 1:
        return mask
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    return lab == (int(np.argmax(sizes)) + 1)


def _apply(fixed, moving, tx, interp="linear", invert=None, imagetype=0):
    return ants.apply_transforms(
        fixed=fixed, moving=moving, transformlist=tx, interpolator=interp,
        whichtoinvert=invert, imagetype=imagetype,
    )


def _inverse_tx(reg: dict) -> tuple[list[str], list[bool]]:
    inv = list(reg["invtransforms"])
    flags = [p.endswith(".mat") for p in inv]
    return inv, flags


def _brain_extract(t1_n4: ants.ANTsImage, tpl_head: ants.ANTsImage, tpl_mask: ants.ANTsImage) -> ants.ANTsImage:
    """antsBrainExtraction-style: head-to-head SyN, warp template brain mask to native space."""
    reg = ants.registration(fixed=tpl_head, moving=t1_n4, type_of_transform="antsRegistrationSyNQuick[s]")
    inv, flags = _inverse_tx(reg)
    prob = _apply(t1_n4, tpl_mask, inv, "linear", flags)
    m = prob.numpy() > 0.5
    m = ndimage.binary_closing(m, iterations=2)
    m = ndimage.binary_fill_holes(_largest_component(m))
    vol_ml = m.sum() * np.prod(t1_n4.spacing) / 1000.0
    if vol_ml < 600:  # < 600 mL is implausible for adults
        raise PreprocessingError(f"Brain extraction failed (mask volume {vol_ml:.0f} mL).")
    return t1_n4.new_image_like(m.astype(np.float32))


def _slice_timing_correct(bold: ants.ANTsImage, slice_times: list[float], tr: float) -> tuple[ants.ANTsImage, dict]:
    """Fourier phase-shift slice-timing correction to the mid-TR reference (as fMRIPrep/3dTshift)."""
    arr = bold.numpy().astype(np.float64)
    nz, nt = arr.shape[2], arr.shape[3]
    st = np.asarray(slice_times, dtype=np.float64)
    if st.size != nz or nt < 4 or np.any(st < 0) or np.any(st >= tr + 1e-6):
        return bold, {"applied": False, "reason": f"SliceTiming length {st.size} != {nz} slices or out of range"}
    t_ref = 0.5 * (st.min() + st.max())
    freqs = np.fft.rfftfreq(2 * nt)  # cycles / sample, padded to avoid wrap-around
    for z in range(nz):
        shift = (t_ref - st[z]) / tr  # samples; value at n*TR + t_ref = x(n + shift)
        if abs(shift) < 1e-9:
            continue
        sl = arr[:, :, z, :]
        mu = sl.mean(axis=-1, keepdims=True)
        x = sl - mu
        x = np.concatenate([x, x[..., ::-1]], axis=-1)  # mirror padding
        spec = np.fft.rfft(x, axis=-1) * np.exp(2j * np.pi * freqs * shift)
        arr[:, :, z, :] = np.fft.irfft(spec, n=2 * nt, axis=-1)[..., :nt] + mu
    arr32 = np.ascontiguousarray(arr, dtype=np.float32)
    out = bold.new_image_like(arr32).clone()
    return out, {"applied": True, "reference_time_s": float(t_ref), "n_slices": int(nz), "_array": arr32}


def _motion_params(tx_files: list[str]) -> tuple[np.ndarray, np.ndarray]:
    tx = ants.read_transform(tx_files[0])
    params = np.asarray(tx.parameters, dtype=np.float64)
    if len(params) >= 12:
        rot_mat = params[:9].reshape(3, 3)
        u, _, vt = np.linalg.svd(rot_mat)
        r_ortho = u @ vt
        if np.linalg.det(r_ortho) < 0:
            u[:, -1] *= -1
            r_ortho = u @ vt
        return Rotation.from_matrix(r_ortho).as_euler("xyz", degrees=False), params[9:12]
    if len(params) == 6:
        return params[:3], params[3:6]
    raise PreprocessingError(f"Unexpected motion transform with {len(params)} parameters")


# Intra-run motion is small, so a fine 2-level pyramid is used first: at 4x shrink a 3x3x4 mm EPI
# (80x80x35) and its mask collapse to a few hundred voxels and ITK intermittently diverged
# ("No valid points were found during metric evaluation").
_MOCO_ATTEMPTS = [
    dict(aff_metric="meansquares", aff_sampling=32, aff_random_sampling_rate=0.5,
         aff_iterations=(100, 50), aff_shrink_factors=(2, 1), aff_smoothing_sigmas=(1, 0)),
    dict(aff_metric="meansquares", aff_sampling=32, aff_random_sampling_rate=1.0,
         aff_iterations=(100, 50), aff_shrink_factors=(2, 1), aff_smoothing_sigmas=(1, 0)),
    dict(aff_metric="mattes", aff_sampling=32, aff_random_sampling_rate=1.0,
         aff_iterations=(100, 50, 25), aff_shrink_factors=(4, 2, 1), aff_smoothing_sigmas=(2, 1, 0)),
    dict(aff_metric="meansquares", aff_sampling=32, aff_random_sampling_rate=1.0,
         aff_iterations=(200,), aff_shrink_factors=(1,), aff_smoothing_sigmas=(0,)),
]


def _geom(img: ants.ANTsImage) -> dict:
    return {"origin": tuple(img.origin), "spacing": tuple(img.spacing), "direction": np.asarray(img.direction)}


def _from_np(arr: np.ndarray, g: dict) -> ants.ANTsImage:
    return ants.from_numpy(np.array(arr, dtype=np.float32, copy=True), origin=g["origin"], spacing=g["spacing"],
                           direction=g["direction"]).clone()


def _worker_init(seed: int, threads: int) -> None:
    os.environ["ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS"] = str(threads)
    _set_seed(seed, False)


def _moco_chunk(job: tuple) -> list[tuple[int, list[str], float, int]]:
    """Register a chunk of volumes to the reference (runs in a worker process)."""
    ks, vols, ref_arr, g3, work = job
    ref = _from_np(ref_arr, g3)
    mask = ants.get_mask(ref)
    m = mask.numpy() > 0
    ref_v = ref.numpy()[m]

    def score(img: ants.ANTsImage) -> float:
        v = img.numpy()[m]
        return float(np.corrcoef(v, ref_v)[0, 1]) if v.std() > 0 else -1.0

    out = []
    for k, arr in zip(ks, vols):
        vol = _from_np(arr, g3)
        base = score(vol)
        best, n_retry = None, 0
        # Identity start for every attempt: ANTsPy does not fold an `initial_transform` into the
        # returned transform, so chaining neighbours' transforms silently corrupts the estimates.
        # Two rounds over the attempt list: ITK occasionally diverges ("No valid points were
        # found during metric evaluation") non-deterministically; a fresh attempt then succeeds.
        for i, opt in enumerate(_MOCO_ATTEMPTS * 2):
            reg = ants.registration(fixed=ref, moving=vol, type_of_transform="Rigid", mask=mask,
                                    outprefix=str(Path(work) / f"moco_{k:05d}_a{i}_"), **opt)
            q = score(reg["warpedmovout"])
            rot, trans = _motion_params(reg["fwdtransforms"])
            plausible = np.abs(trans).max() < 20 and np.abs(rot).max() < np.radians(15)
            if os.environ.get("CCS_MOCO_DEBUG") and not plausible:
                print(f"[moco-debug] base={base:.3f} vol_std={float(arr.std()):.1f} vol_mean={float(arr.mean()):.1f} "
                      f"ref_std={float(ref_arr.std()):.1f} img_std={float(vol.numpy().std()):.1f} "
                      f"warped_std={float(reg['warpedmovout'].numpy().std()):.1f} vol={k} attempt={i} q={q:.3f} trans={np.round(trans, 2)} "
                      f"rot_deg={np.round(np.degrees(rot), 2)} tx={reg['fwdtransforms']}", flush=True)
            if best is None or (plausible and q > best[0]):
                best = (q if plausible else -1.0, reg["fwdtransforms"])
            if plausible and q >= base - 0.002:
                break
            n_retry += 1
        out.append((k, best[1], best[0], n_retry))
    return out


def _resample_chunk(job: tuple) -> list[tuple[int, np.ndarray]]:
    """Apply composed (normalisation o coregistration o motion) transforms to a chunk of volumes."""
    ks, vols, g3, grid_path, static_tx, motion = job
    grid = ants.image_read(grid_path, pixeltype="float")
    return [(k, ants.apply_transforms(fixed=grid, moving=_from_np(arr, g3), transformlist=list(static_tx) + list(mk),
                                      interpolator="linear").numpy().astype(np.float32))
            for k, arr, mk in zip(ks, vols, motion)]


def _n_workers() -> int:
    env = os.environ.get("CCS_PREPROC_WORKERS")
    if env:
        return max(1, int(env))
    return max(1, min(8, (os.cpu_count() or 2) // 2))


def _run_parallel(fn, jobs: list, seed: int) -> list:
    """Run chunk jobs in *fresh* spawned worker processes (one chunk per process).

    ANTs/ITK state degrades after roughly 80-100 registrations inside one Python process: every
    subsequent registration fails with "No valid points were found during metric evaluation".
    (This is what silently corrupted the motion parameters from volume ~55 onward in v0.4.1.)
    Recycling the worker after each chunk of <= 24 volumes avoids it.
    """
    import multiprocessing as mp
    from concurrent.futures import ProcessPoolExecutor
    nw = _n_workers()
    threads = max(1, (os.cpu_count() or 2) // nw)
    with ProcessPoolExecutor(max_workers=nw, mp_context=mp.get_context("spawn"), initializer=_worker_init,
                             initargs=(seed, threads), max_tasks_per_child=1) as ex:
        return [r for res in ex.map(fn, jobs) for r in res]


def _chunks(n: int, nw: int, max_size: int = 24) -> list[list[int]]:
    size = max(1, min(max_size, int(np.ceil(n / (nw * 3)))))
    return [list(range(i, min(n, i + size))) for i in range(0, n, size)]


def _check_volumes(arr4: np.ndarray) -> None:
    """Abort if any volume is implausible (e.g. corrupted in memory or truncated on disk)."""
    means = arr4.reshape(-1, arr4.shape[-1]).mean(0)
    med = float(np.median(means))
    bad = np.where((means < 0.5 * med) | (means > 2.0 * med) | ~np.isfinite(means))[0]
    if bad.size:
        raise PreprocessingError(f"{bad.size} BOLD volume(s) have implausible mean intensity (first: {bad[:10].tolist()}).")


def _estimate_motion(bold: ants.ANTsImage, ref: ants.ANTsImage, work: Path, seed: int = 42,
                     bold_np: np.ndarray | None = None) -> tuple[list[list[str]], dict]:
    """Rigid head-motion estimation with per-volume quality control (parallel over volumes).

    Each volume is registered to the mean reference (3-level pyramid). The fit is accepted only if
    the resampled volume correlates with the reference inside the brain mask at least as well as the
    *unregistered* volume does (minus a small tolerance) and the displacement is plausible; otherwise
    the volume is re-registered with alternative settings (dense sampling, then Mattes MI) and the
    best-scoring plausible attempt is kept. ANTs' generic `motion_correction` diverged on 5-35 % of
    runs in our validation data (40-140 mm "motion"), silently in v0.4.1.
    """
    n = int(bold.shape[3])
    # Work from a Python-owned copy of the data: numpy views of ANTs image buffers were observed
    # to return corrupted volumes (mean ~0) for some frames inside the full pipeline.
    arr4 = bold_np if bold_np is not None else np.array(bold.numpy(), dtype=np.float32, copy=True)
    _check_volumes(arr4)
    g3 = _geom(ants.slice_image(bold, axis=3, idx=0))
    ref_arr = np.array(ref.numpy(), dtype=np.float32, copy=True)
    jobs = [(ks, [arr4[..., k] for k in ks], ref_arr, g3, str(work)) for ks in _chunks(n, _n_workers())]
    res = {r[0]: r for r in _run_parallel(_moco_chunk, jobs, seed)}
    for _ in range(2):  # re-run any failed volumes in fresh processes
        bad = [k for k, r in res.items() if r[2] < 0]
        if not bad:
            break
        jobs = [(ks, [arr4[..., k] for k in ks], ref_arr, g3, str(work)) for ks in
                [bad[i:i + 8] for i in range(0, len(bad), 8)]]
        for r in _run_parallel(_moco_chunk, jobs, seed):
            if r[2] >= 0:
                res[r[0]] = (r[0], r[1], r[2], res[r[0]][3] + r[3])
    res = [res[k] for k in sorted(res)]
    tx = [r[1] for r in res]
    quality = np.array([r[2] for r in res])
    failed = [int(r[0]) for r in res if r[2] < 0]
    if failed:
        raise PreprocessingError(
            f"Rigid motion estimation failed QC for {len(failed)} volume(s) {failed[:10]} after 8 attempts each "
            "(no plausible registration). Inspect these volumes for artefacts or extreme motion."
        )
    return tx, {"n_retries": int(sum(r[3] for r in res)), "min_quality_r": float(quality.min()),
                "median_quality_r": float(np.median(quality)), "workers": _n_workers()}


def _confounds_from_motion(motion_tx: list[list[str]], ants_fd: np.ndarray | None) -> pd.DataFrame:
    n_tp = len(motion_tx)
    trans = np.zeros((n_tp, 3))
    rot = np.zeros((n_tp, 3))
    for t, tx_files in enumerate(motion_tx):
        rot[t], trans[t] = _motion_params(tx_files)
    if not (np.all(np.isfinite(trans)) and np.all(np.isfinite(rot))):
        raise PreprocessingError("Non-finite motion parameters")
    if np.abs(trans).max() > 25.0 or np.abs(rot).max() > 0.5:
        raise PreprocessingError(
            f"Implausible head motion (max |trans| {np.abs(trans).max():.1f} mm, max |rot| "
            f"{np.degrees(np.abs(rot).max()):.1f} deg): motion correction probably failed."
        )
    d_trans = np.vstack([np.zeros((1, 3)), np.diff(trans, axis=0)])
    d_rot = np.vstack([np.zeros((1, 3)), np.diff(rot, axis=0)])
    power_fd = np.sum(np.abs(d_trans), axis=1) + 50.0 * np.sum(np.abs(d_rot), axis=1)
    return pd.DataFrame({
        "trans_x": trans[:, 0], "trans_y": trans[:, 1], "trans_z": trans[:, 2],
        "rot_x": rot[:, 0], "rot_y": rot[:, 1], "rot_z": rot[:, 2],
        "trans_x_derivative1": d_trans[:, 0], "trans_y_derivative1": d_trans[:, 1],
        "trans_z_derivative1": d_trans[:, 2], "rot_x_derivative1": d_rot[:, 0],
        "rot_y_derivative1": d_rot[:, 1], "rot_z_derivative1": d_rot[:, 2],
        "framewise_displacement": power_fd,
        # kept for backward compatibility with v0.4.x readers (ignored as a regressor by the Rust core)
        "ants_fd": power_fd if ants_fd is None else np.asarray(ants_fd, dtype=np.float64),
    })


def _dilate_binary_ants(mask: ants.ANTsImage, radius_vox: int) -> ants.ANTsImage:
    arr = mask.numpy() > 0.5
    if radius_vox > 0:
        arr = ndimage.binary_dilation(arr, iterations=radius_vox)
    return mask.new_image_like(arr.astype(np.float32))


def _erode_to_min(mask: np.ndarray, iterations: int, min_voxels: int) -> np.ndarray:
    for it in range(iterations, -1, -1):
        m = ndimage.binary_erosion(mask, iterations=it) if it > 0 else mask
        if m.sum() >= min_voxels:
            return m
    return mask


def run_preprocessing(
    t1_path: Path,
    bold_path: Path,
    out_dir: Path,
    transform: str = "SyNQuick",
    template_id: str = "mni152_adult",
    custom_template: Path | None = None,
    lesion_mask_path: Path | None = None,
    lesion_mode: str = "none",
    lesion_dilate: int = 1,
    seed: int = 42,
    deterministic: bool = False,
    slice_timing: bool = True,
    write_gz: bool = False,
) -> dict:
    t_start = time.perf_counter()
    out_dir.mkdir(parents=True, exist_ok=True)
    _set_seed(seed, deterministic)
    stages: list[dict] = []
    warnings: list[str] = []

    def log_stage(name: str, t0: float) -> None:
        dt = time.perf_counter() - t0
        entry = {"stage": name, "seconds": round(dt, 3), "rss_mb": round(_current_rss_mb(), 2),
                 "peak_rss_mb": round(_peak_rss_mb(), 2)}
        stages.append(entry)
        print(f"[preproc] {name}: {dt:.2f}s | RSS={entry['rss_mb']:.1f} MB (peak={entry['peak_rss_mb']:.1f} MB)", flush=True)

    # ---- 1. Inputs -------------------------------------------------------------------------
    t0 = time.perf_counter()
    t1 = _read_validated(t1_path, warnings)
    bold = _read_validated(bold_path, warnings)
    meta = _sidecar_json(bold_path)
    tr_sec = _detect_tr(meta, bold)
    n_vols = int(bold.shape[3])
    std = standard_space_files(DEFAULT_SPACE)
    tpl_head1 = ants.image_read(str(std["t1w_1mm"]), pixeltype="float")
    tpl_mask1 = ants.image_read(str(std["brain_mask_1mm"]), pixeltype="float")
    tpl_head2 = ants.image_read(str(std["t1w_2mm"]), pixeltype="float")
    tpl_mask2 = ants.image_read(str(std["brain_mask_2mm"]), pixeltype="float")
    out_grid = tpl_head2  # 2 mm MNI152NLin6Asym grid (91 x 109 x 91), Schaefer native grid
    # disk check: float32 output (.nii + .nii.gz) + per-volume temp transforms + headroom
    _check_disk(out_dir, int((2.2 if write_gz else 1.2) * n_vols * np.prod(out_grid.shape) * 4) + 2 * 10**9)

    lesion_img = lesion_dilated = None
    if lesion_mask_path is not None:
        lesion_img = ants.image_read(str(lesion_mask_path), pixeltype="float")
        lesion_img = lesion_img.new_image_like((lesion_img.numpy() > 0.5).astype(np.float32))
        lesion_dilated = _dilate_binary_ants(lesion_img, lesion_dilate)
        if lesion_mode == "none":
            lesion_mode = "cfm"
    log_stage("load_inputs", t0)

    # ---- 2. N4 + brain extraction ----------------------------------------------------------
    t0 = time.perf_counter()
    t1_n4 = ants.n4_bias_field_correction(t1)
    brain_mask = _brain_extract(t1_n4, tpl_head1, tpl_mask1)
    t1_n4 = ants.n4_bias_field_correction(t1, mask=brain_mask)
    t1_brain = t1_n4 * brain_mask
    ants.image_write(t1_n4, str(out_dir / "t1w_n4.nii.gz"))
    ants.image_write(brain_mask, str(out_dir / "t1w_brain_mask.nii.gz"))
    log_stage("t1_n4_and_brain_extraction", t0)

    # ---- 3. Tissue segmentation on the skull-stripped brain --------------------------------
    t0 = time.perf_counter()
    seg_mask = brain_mask
    if lesion_dilated is not None:
        seg_mask = brain_mask.new_image_like(
            ((brain_mask.numpy() > 0.5) & (lesion_dilated.numpy() < 0.5)).astype(np.float32))
    # Winsorise intensities inside the brain (0.5-99.5 %) so a few very bright voxels (vessels,
    # residual fat) cannot capture a whole K-means class.
    in_brain = t1_n4.numpy()[seg_mask.numpy() > 0.5]
    lo, hi = np.percentile(in_brain, [0.5, 99.5])
    t1_seg = t1_n4.new_image_like(np.clip(t1_n4.numpy(), lo, hi).astype(np.float32))
    atropos = ants.atropos(a=t1_seg, m="[0.1,1x1x1]", c="[5,0]", i="Kmeans[3]", x=seg_mask)
    seg = atropos["segmentation"].numpy()
    t1_arr = t1_n4.numpy()
    means = {c: float(t1_arr[seg == c].mean()) for c in (1, 2, 3) if np.any(seg == c)}
    order = sorted(means, key=means.get)  # CSF < GM < WM on T1w
    if len(order) != 3:
        raise PreprocessingError("Atropos did not return 3 tissue classes")
    post = {name: atropos["probabilityimages"][cls - 1].numpy() for name, cls in zip(("CSF", "GM", "WM"), order)}
    non_lesion = (lesion_dilated.numpy() < 0.5) if lesion_dilated is not None else np.ones(seg.shape, bool)
    vox_ml = float(np.prod(t1_n4.spacing)) / 1000.0
    wm_t1 = _erode_to_min((post["WM"] > 0.9) & non_lesion, 2, 2000)
    inner = ndimage.binary_erosion(brain_mask.numpy() > 0.5, iterations=5)  # avoid extra-cerebral CSF / vessels
    csf_t1 = _erode_to_min((post["CSF"] > 0.9) & inner & non_lesion, 1, 300)
    gm_t1 = (post["GM"] > 0.5) & non_lesion
    tissue_ml = {k: float((post[k] > 0.5).sum() * vox_ml) for k in post}
    for k, v in post.items():
        ants.image_write(t1_n4.new_image_like(v.astype(np.float32)), str(out_dir / f"t1w_label-{k}_probseg.nii.gz"))
    if tissue_ml["WM"] < 150 or tissue_ml["GM"] < 200:
        raise PreprocessingError(f"Tissue segmentation failed (volumes mL: {tissue_ml})")
    if not (300 < tissue_ml["WM"] < 900 and 350 < tissue_ml["GM"] < 1100):
        warnings.append(f"Unusual tissue volumes (mL): {tissue_ml}")
    log_stage("t1_atropos_segmentation", t0)

    # ---- 4. T1w brain -> template brain -----------------------------------------------------
    t0 = time.perf_counter()
    if template_id == "mni152_adult" and custom_template is None:
        tpl_brain = tpl_head1 * tpl_mask1
        template_meta = {"template_id": template_id, "space": DEFAULT_SPACE, "source": str(std["t1w_1mm"])}
    else:
        template_path, template_meta = resolve_template(template_id=template_id, custom_template_path=custom_template,
                                                        out_cache_dir=out_dir / "templates")
        tpl_custom = ants.image_read(str(template_path), pixeltype="float")
        tpl_brain = tpl_custom * ants.resample_image_to_target(tpl_mask1, tpl_custom, interp_type="nearestNeighbor")
    ants_tx = "antsRegistrationSyNQuick[s]" if transform == "SyNQuick" else transform

    if lesion_img is not None and lesion_mode == "enantiomorphic":
        rig = ants.registration(fixed=tpl_brain, moving=t1_brain, type_of_transform="Rigid")
        t1_aligned = rig["warpedmovout"].numpy()
        les_al = _apply(tpl_brain, lesion_dilated, rig["fwdtransforms"], "nearestNeighbor").numpy() > 0.5
        healed = np.where(les_al, np.flip(t1_aligned, axis=0), t1_aligned)
        healed_img = rig["warpedmovout"].new_image_like(healed.astype(np.float32))
        ants.image_write(healed_img, str(out_dir / "t1w_enantiomorphic_healed.nii.gz"))
        reg = ants.registration(fixed=tpl_brain, moving=healed_img, type_of_transform=ants_tx)
        t1_to_mni_fwd = reg["fwdtransforms"] + rig["fwdtransforms"]
    elif lesion_img is not None and lesion_mode == "cfm":
        inv_lesion = t1_n4.new_image_like(
            ((lesion_dilated.numpy() < 0.5) & (brain_mask.numpy() > 0.5)).astype(np.float32))
        reg = ants.registration(fixed=tpl_brain, moving=t1_brain, type_of_transform=ants_tx,
                                moving_mask=inv_lesion, mask_all_stages=True)
        t1_to_mni_fwd = reg["fwdtransforms"]
    else:
        reg = ants.registration(fixed=tpl_brain, moving=t1_brain, type_of_transform=ants_tx)
        t1_to_mni_fwd = reg["fwdtransforms"]
    t1_mni = _apply(out_grid, t1_n4, t1_to_mni_fwd, "linear")
    ants.image_write(t1_mni, str(out_dir / "t1w_mni.nii.gz"))
    log_stage(f"t1_to_mni_{transform}_{lesion_mode}", t0)

    # ---- 5. Slice-timing correction ---------------------------------------------------------
    t0 = time.perf_counter()
    stc_info: dict = {"applied": False, "reason": "disabled"}
    bold_np = None
    if slice_timing and meta.get("SliceTiming"):
        bold, stc_info = _slice_timing_correct(bold, meta["SliceTiming"], tr_sec)
        bold_np = stc_info.pop("_array", None)
    elif slice_timing:
        stc_info = {"applied": False, "reason": "no SliceTiming in BIDS sidecar"}
    if not stc_info.get("applied"):
        warnings.append(f"Slice-timing correction not applied: {stc_info.get('reason')}")
    if bold_np is None:
        bold_np = np.array(bold.numpy(), dtype=np.float32, copy=True)
    log_stage("bold_slice_timing", t0)

    # ---- 6. Head-motion estimation (transforms kept for single-shot resampling) -------------
    t0 = time.perf_counter()
    work = Path(tempfile.mkdtemp(prefix="ccs_moco_", dir=str(out_dir)))
    try:
        bold_ref = _from_np(bold_np.mean(axis=-1), _geom(ants.slice_image(bold, axis=3, idx=0)))
        motion_tx, moco_qc = _estimate_motion(bold, bold_ref, work, seed, bold_np)
        if moco_qc["n_retries"]:
            warnings.append(f"Motion estimation: {moco_qc['n_retries']} re-registration attempt(s) after QC failure")
        bad = [k for k, tx in enumerate(motion_tx)
               if not tx or not all(Path(p).exists() and Path(p).stat().st_size > 0 for p in tx)]
        if bad:
            raise PreprocessingError(
                f"Motion correction produced no valid transform for {len(bad)} volume(s) (first: {bad[:5]}). "
                "This usually means the disk filled up or the volume is empty."
            )
        confounds_df = _confounds_from_motion(motion_tx, None)
        confounds_df.to_csv(out_dir / "confounds.tsv", sep="\t", index=False)
        log_stage("bold_motion_estimation", t0)

        # ---- 7. BOLD reference -> T1w brain (rigid) ----------------------------------------
        t0 = time.perf_counter()
        moco_mean = bold_ref
        epi_mask = ants.get_mask(moco_mean)
        coreg = ants.registration(fixed=t1_brain, moving=moco_mean * epi_mask,
                                  type_of_transform="antsRegistrationSyNQuick[r]", mask=brain_mask)
        bold_to_t1 = coreg["fwdtransforms"]
        log_stage("boldref_to_t1_rigid", t0)

        # ---- 8. Single-interpolation resampling --------------------------------------------
        t0 = time.perf_counter()
        # Pre-compose coregistration + normalisation into one displacement field on the output
        # grid, then add the per-volume rigid motion transform: one resampling per volume.
        vol0 = ants.slice_image(bold, axis=3, idx=0)
        composed = ants.apply_transforms(fixed=out_grid, moving=vol0,
                                         transformlist=list(t1_to_mni_fwd) + list(bold_to_t1),
                                         compose=str(work / "boldref2mni_"))
        static_tx = [composed] if isinstance(composed, str) and Path(composed).exists() \
            else list(t1_to_mni_fwd) + list(bold_to_t1)
        arr4 = bold_np
        g3 = _geom(ants.slice_image(bold, axis=3, idx=0))
        jobs = [(ks, [arr4[..., k] for k in ks], g3, str(std["t1w_2mm"]), static_tx, [motion_tx[k] for k in ks])
                for ks in _chunks(n_vols, _n_workers())]
        res = sorted(_run_parallel(_resample_chunk, jobs, seed), key=lambda r: r[0])
        vols = [r[1] for r in res]
        del arr4, jobs
        bold_arr = np.stack(vols, axis=-1)
        del vols
    finally:
        shutil.rmtree(work, ignore_errors=True)
    affine = nib.load(str(std["t1w_2mm"])).affine
    hdr = nib.Nifti1Header()
    hdr.set_xyzt_units("mm", "sec")
    hdr.set_data_dtype(np.float32)
    bold_img = nib.Nifti1Image(bold_arr, affine, hdr)
    bold_img.header["pixdim"][4] = tr_sec
    nib.save(bold_img, str(out_dir / "bold_mni.nii"))
    if write_gz:  # optional archive copy; the Rust core memory-maps the uncompressed .nii
        nib.save(bold_img, str(out_dir / "bold_mni.nii.gz"))
    log_stage("single_interpolation_resampling", t0)

    # ---- masks in template space --------------------------------------------------------------
    t0 = time.perf_counter()

    def to_mni(arr_bool: np.ndarray) -> np.ndarray:
        img = t1_n4.new_image_like(arr_bool.astype(np.float32))
        return _apply(out_grid, img, t1_to_mni_fwd, "linear").numpy() > 0.5

    wm_mni = to_mni(wm_t1)
    csf_mni = to_mni(csf_t1)
    gm_mni = to_mni(gm_t1)
    brain_mni = to_mni(brain_mask.numpy() > 0.5)
    for arr, name in [(wm_mni, "wm_mask_mni"), (csf_mni, "csf_mask_mni"), (gm_mni, "gm_mask_mni"),
                      (brain_mni, "brain_mask_mni")]:
        nib.save(nib.Nifti1Image(arr.astype(np.uint8), affine), str(out_dir / f"{name}.nii.gz"))
    lesion_mni_path, lesion_mni_voxels = None, 0
    if lesion_img is not None:
        les = _apply(out_grid, lesion_img, t1_to_mni_fwd, "nearestNeighbor").numpy() > 0.5
        lesion_mni_voxels = int(les.sum())
        lesion_mni_path = out_dir / "lesion_mask_mni.nii.gz"
        nib.save(nib.Nifti1Image(les.astype(np.uint8), affine), str(lesion_mni_path))
    for nm, arr, mn in [("WM", wm_mni, 200), ("CSF", csf_mni, 20)]:
        if arr.sum() < mn:
            raise PreprocessingError(f"{nm} aCompCor mask has only {int(arr.sum())} voxels in MNI space")
    log_stage("masks_to_mni", t0)

    # ---- 9. Atlas (native FSL MNI152 2 mm) + coverage -----------------------------------------
    t0 = time.perf_counter()
    schaefer = datasets.fetch_atlas_schaefer_2018(n_rois=400, resolution_mm=2, verbose=0)
    atlas_img = nib.load(schaefer.maps)
    if atlas_img.shape[:3] != bold_arr.shape[:3] or not np.allclose(atlas_img.affine, affine, atol=1e-3):
        atlas_img = image.resample_to_img(atlas_img, nib.Nifti1Image(bold_arr[..., 0], affine),
                                          interpolation="nearest", force_resample=True, copy_header=True)
    atlas_i32 = np.rint(atlas_img.get_fdata()).astype(np.int32)
    nib.save(nib.Nifti1Image(atlas_i32, affine), str(out_dir / "schaefer400_mni.nii.gz"))
    labels = [lb.decode() if isinstance(lb, bytes) else str(lb) for lb in schaefer.labels]
    (out_dir / "schaefer400_labels.json").write_text(json.dumps(labels, indent=2), encoding="utf-8")
    names = [lb for lb in labels if lb.lower() != "background"]
    mean_bold = bold_arr.mean(axis=-1)
    thr = 0.2 * np.percentile(mean_bold[brain_mni], 98)
    epi_cov_mask = brain_mni & (mean_bold > thr)
    ids = np.unique(atlas_i32[atlas_i32 > 0])
    cov = np.array([epi_cov_mask[atlas_i32 == i].mean() for i in ids])
    pd.DataFrame({"roi_id": ids, "label": [names[i - 1] if i - 1 < len(names) else str(i) for i in ids],
                  "epi_coverage": cov}).to_csv(out_dir / "parcel_coverage.csv", index=False)
    if (cov < 0.5).sum() > 0:
        warnings.append(f"{int((cov < 0.5).sum())} parcels have <50% EPI coverage (see parcel_coverage.csv)")
    log_stage("atlas_and_coverage", t0)

    # ---- 10. QC ---------------------------------------------------------------------------------
    tpl2 = tpl_head2.numpy()
    bm2 = tpl_mask2.numpy() > 0.5
    t1m = t1_mni.numpy()
    qc = {
        "t1w_mni_vs_template_r_in_brain": float(np.corrcoef(t1m[bm2], tpl2[bm2])[0, 1]),
        "brain_mask_dice_vs_template": float(2 * (brain_mni & bm2).sum() / (brain_mni.sum() + bm2.sum())),
        "t1_tissue_volumes_ml": tissue_ml,
        "brain_volume_ml": float((brain_mask.numpy() > 0.5).sum() * vox_ml),
        "wm_mask_voxels_mni": int(wm_mni.sum()),
        "csf_mask_voxels_mni": int(csf_mni.sum()),
        "wm_mask_frac_in_template_brain": float((wm_mni & bm2).sum() / max(wm_mni.sum(), 1)),
        "csf_mask_frac_in_subject_brain": float((csf_mni & brain_mni).sum() / max(csf_mni.sum(), 1)),
        "parcels_lt50pct_epi_coverage": int((cov < 0.5).sum()),
        "slice_timing": stc_info,
        "motion_estimation": moco_qc,
        "random_seed": seed,
        "deterministic_single_thread": deterministic,
    }
    if qc["t1w_mni_vs_template_r_in_brain"] < 0.6:
        warnings.append(f"Low T1w-template similarity (r={qc['t1w_mni_vs_template_r_in_brain']:.2f}); inspect registration.")
    if qc["brain_mask_dice_vs_template"] < 0.9:
        warnings.append(f"Brain-mask Dice vs template {qc['brain_mask_dice_vs_template']:.2f} < 0.90; inspect brain extraction.")

    fd = confounds_df["framewise_displacement"].to_numpy()
    report = {
        "pipeline_version": PIPELINE_VERSION,
        "t1_input": str(t1_path), "bold_input": str(bold_path),
        "transform": transform, "template_id": template_id, "template_meta": template_meta,
        "output_space": f"{DEFAULT_SPACE}_res-2",
        "lesion_mode": lesion_mode if lesion_img is not None else "none",
        "lesion_mask_input": str(lesion_mask_path) if lesion_mask_path else None,
        "lesion_mni_voxels": lesion_mni_voxels,
        "tr_sec": tr_sec, "t1_shape": list(t1.shape), "bold_raw_shape": list(bold.shape),
        "bold_mni_shape": list(bold_arr.shape),
        "wm_mask_voxels": int(wm_mni.sum()), "csf_mask_voxels": int(csf_mni.sum()),
        "schaefer_unique_labels": int(len(ids)),
        "mean_fd_mm": float(fd.mean()), "max_fd_mm": float(fd.max()),
        "n_fd_gt_0p5": int((fd > 0.5).sum()),
        "interpolations": "single (motion + coregistration + normalisation composed per volume)",
        "qc": qc, "warnings": warnings,
        "total_seconds": round(time.perf_counter() - t_start, 3),
        "peak_rss_mb": round(_peak_rss_mb(), 2), "stages": stages,
        "outputs": {
            "bold_mni_gz": str(out_dir / "bold_mni.nii.gz") if write_gz else None, "bold_mni_nii": str(out_dir / "bold_mni.nii"),
            "wm_mask_mni": str(out_dir / "wm_mask_mni.nii.gz"), "csf_mask_mni": str(out_dir / "csf_mask_mni.nii.gz"),
            "gm_mask_mni": str(out_dir / "gm_mask_mni.nii.gz"), "brain_mask_mni": str(out_dir / "brain_mask_mni.nii.gz"),
            "lesion_mask_mni": str(lesion_mni_path) if lesion_mni_path else None,
            "confounds_tsv": str(out_dir / "confounds.tsv"),
            "schaefer400_mni": str(out_dir / "schaefer400_mni.nii.gz"),
            "schaefer400_labels": str(out_dir / "schaefer400_labels.json"),
            "parcel_coverage": str(out_dir / "parcel_coverage.csv"),
        },
    }
    try:
        import nilearn
        cov_df = pd.read_csv(out_dir / "parcel_coverage.csv")
        qc_path = write_qc_report(out_dir, report, t1m, tpl2, bm2, brain_mni, wm_mni, csf_mni, gm_mni, bold_arr,
                                  confounds_df, cov_df, {"antspy": ants.__version__, "nilearn": nilearn.__version__})
        report["outputs"]["qc_report_html"] = str(qc_path)
    except Exception as exc:  # QC rendering must never invalidate a finished run
        warnings.append(f"QC report could not be written: {exc}")
    (out_dir / "preprocess_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    for w in warnings:
        print(f"[preproc][WARNING] {w}", flush=True)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="ANTsPy fMRI preprocessing CLI.")
    parser.add_argument("--t1", required=True, type=Path)
    parser.add_argument("--bold", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--transform", default="SyNQuick", choices=["SyNQuick", "SyN"])
    parser.add_argument("--template", default="mni152_adult",
                        choices=["mni152_adult", "older_adult_stroke", "pediatric_nihpd", "acute_ct_stroke"])
    parser.add_argument("--custom-template", type=Path, default=None)
    parser.add_argument("--lesion-mask", type=Path, default=None)
    parser.add_argument("--lesion-mode", default="none", choices=["none", "cfm", "enantiomorphic"])
    parser.add_argument("--lesion-dilate", type=int, default=1)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--deterministic", action="store_true",
                        help="Single-threaded ANTs for bit-identical re-runs (slower).")
    parser.add_argument("--no-slice-timing", action="store_true")
    parser.add_argument("--write-gz", action="store_true", help="Also write a gzipped copy of bold_mni (slow).")
    args = parser.parse_args()
    try:
        report = run_preprocessing(
            args.t1, args.bold, args.out, transform=args.transform, template_id=args.template,
            custom_template=args.custom_template, lesion_mask_path=args.lesion_mask,
            lesion_mode=args.lesion_mode, lesion_dilate=args.lesion_dilate, seed=args.seed,
            deterministic=args.deterministic, slice_timing=not args.no_slice_timing, write_gz=args.write_gz,
        )
    except PreprocessingError as exc:
        print(f"[preproc][ERROR] {exc}", file=sys.stderr, flush=True)
        sys.exit(2)
    print(json.dumps({k: report[k] for k in ("pipeline_version", "total_seconds", "qc", "warnings")}, indent=2))


if __name__ == "__main__":
    main()
