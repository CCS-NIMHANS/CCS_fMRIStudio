"""ANTsPy-based single-subject fMRI preprocessing CLI for CCS_fMRIStudio.

Steps:
1. T1w N4 bias-field correction & Atropos 3-class segmentation (WM/CSF masks).
2. T1w -> MNI152NLin2009cAsym (2mm) registration (SyNQuick or SyN).
3. 4D BOLD rigid-body motion correction + 6-DOF confounds & Power FD.
4. Mean BOLD -> T1w rigid coregistration.
5. Single-interpolation 4D warp of BOLD to MNI152 2mm + nearest-neighbor warp of WM/CSF masks.
6. Resample Schaefer-400 2mm atlas onto MNI BOLD grid.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import sys
import time
from pathlib import Path

import ants
import nibabel as nib
import numpy as np
import pandas as pd
import psutil
from nilearn import datasets, image
from scipy.spatial.transform import Rotation


def _peak_rss_mb() -> float:
    """Return process peak RSS in megabytes (macOS bytes vs Linux KiB)."""
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":
        return ru / (1024.0 * 1024.0)
    return ru / 1024.0


def _current_rss_mb() -> float:
    return psutil.Process(os.getpid()).memory_info().rss / (1024.0 * 1024.0)


def _detect_tr(bold_path: Path, bold_ants: ants.ANTsImage) -> float:
    stem = bold_path.name
    if stem.endswith(".nii.gz"):
        json_path = bold_path.with_name(stem[:-7] + ".json")
    elif stem.endswith(".nii"):
        json_path = bold_path.with_name(stem[:-4] + ".json")
    else:
        json_path = None

    if json_path and json_path.exists():
        meta = json.loads(json_path.read_text(encoding="utf-8"))
        if "RepetitionTime" in meta and float(meta["RepetitionTime"]) > 0:
            return float(meta["RepetitionTime"])
    if len(bold_ants.spacing) >= 4 and bold_ants.spacing[3] > 0:
        return float(bold_ants.spacing[3])
    return 2.0


def _extract_motion_confounds(
    motion_params: list, ants_fd: np.ndarray
) -> pd.DataFrame:
    """Extract 6 rigid-body parameters from ANTs transforms + Power FD."""
    n_tp = len(motion_params)
    trans = np.zeros((n_tp, 3), dtype=np.float64)
    rot = np.zeros((n_tp, 3), dtype=np.float64)

    for t, tx_files in enumerate(motion_params):
        if tx_files == "NA" or not tx_files:
            continue
        tx = ants.read_transform(tx_files[0])
        params = np.asarray(tx.parameters, dtype=np.float64)
        if len(params) >= 12:
            rot_mat = params[:9].reshape(3, 3)
            # Project onto nearest proper rotation matrix via SVD for numerical safety.
            u, _, vt = np.linalg.svd(rot_mat)
            r_ortho = u @ vt
            if np.linalg.det(r_ortho) < 0:
                u[:, -1] *= -1
                r_ortho = u @ vt
            rot[t] = Rotation.from_matrix(r_ortho).as_euler("xyz", degrees=False)
            trans[t] = params[9:12]
        elif len(params) == 6:
            rot[t] = params[:3]
            trans[t] = params[3:6]

    d_trans = np.vstack([np.zeros((1, 3)), np.diff(trans, axis=0)])
    d_rot = np.vstack([np.zeros((1, 3)), np.diff(rot, axis=0)])
    power_fd = np.sum(np.abs(d_trans), axis=1) + 50.0 * np.sum(np.abs(d_rot), axis=1)

    df = pd.DataFrame(
        {
            "trans_x": trans[:, 0],
            "trans_y": trans[:, 1],
            "trans_z": trans[:, 2],
            "rot_x": rot[:, 0],
            "rot_y": rot[:, 1],
            "rot_z": rot[:, 2],
            "trans_x_derivative1": d_trans[:, 0],
            "trans_y_derivative1": d_trans[:, 1],
            "trans_z_derivative1": d_trans[:, 2],
            "rot_x_derivative1": d_rot[:, 0],
            "rot_y_derivative1": d_rot[:, 1],
            "rot_z_derivative1": d_rot[:, 2],
            "framewise_displacement": power_fd,
            "ants_fd": np.asarray(ants_fd, dtype=np.float64),
        }
    )
    return df


def _erode_with_fallback(mask: ants.ANTsImage, min_voxels: int = 50) -> ants.ANTsImage:
    eroded = ants.morphology(mask, operation="erode", radius=1)
    if int(eroded.numpy().sum()) >= min_voxels:
        return eroded
    return mask


def run_preprocessing(
    t1_path: Path,
    bold_path: Path,
    out_dir: Path,
    transform: str = "SyNQuick",
) -> dict:
    t_start = time.perf_counter()
    out_dir.mkdir(parents=True, exist_ok=True)
    stages: list[dict] = []

    def log_stage(name: str, t0: float) -> None:
        dt = time.perf_counter() - t0
        entry = {
            "stage": name,
            "seconds": round(dt, 3),
            "rss_mb": round(_current_rss_mb(), 2),
            "peak_rss_mb": round(_peak_rss_mb(), 2),
        }
        stages.append(entry)
        print(
            f"[preproc] {name}: {dt:.2f}s | RSS={entry['rss_mb']:.1f} MB "
            f"(peak={entry['peak_rss_mb']:.1f} MB)",
            flush=True,
        )

    # 1. Load inputs as float32
    t0 = time.perf_counter()
    t1 = ants.image_read(str(t1_path), pixeltype="float")
    bold = ants.image_read(str(bold_path), pixeltype="float")
    tr_sec = _detect_tr(bold_path, bold)
    log_stage("load_inputs", t0)

    # 2. T1w N4 bias-field correction
    t0 = time.perf_counter()
    t1_n4 = ants.n4_bias_field_correction(t1)
    ants.image_write(t1_n4, str(out_dir / "t1w_n4.nii.gz"))
    log_stage("t1_n4_bias_correction", t0)

    # 3. T1w tissue segmentation (WM & CSF masks for aCompCor)
    t0 = time.perf_counter()
    brain_mask = ants.get_mask(t1_n4)
    atropos_res = ants.atropos(
        a=t1_n4, m="[0.2,1x1x1]", c="[5,0]", i="Kmeans[3]", x=brain_mask
    )
    seg_arr = atropos_res["segmentation"].numpy()
    t1_arr = t1_n4.numpy()
    class_means = {
        cls: float(t1_arr[seg_arr == cls].mean())
        for cls in (1, 2, 3)
        if np.any(seg_arr == cls)
    }
    csf_cls = min(class_means, key=class_means.get)
    wm_cls = max(class_means, key=class_means.get)
    csf_mask = _erode_with_fallback(
        t1_n4.new_image_like((seg_arr == csf_cls).astype(np.float32))
    )
    wm_mask = _erode_with_fallback(
        t1_n4.new_image_like((seg_arr == wm_cls).astype(np.float32))
    )
    log_stage("t1_atropos_segmentation", t0)

    # 4. T1w -> MNI152 (2mm) registration
    t0 = time.perf_counter()
    mni_nib = datasets.load_mni152_template(resolution=2)
    mni_template_path = out_dir / "mni152_2mm_template.nii.gz"
    nib.save(mni_nib, str(mni_template_path))
    mni = ants.image_read(str(mni_template_path), pixeltype="float")
    ants_tx = "antsRegistrationSyNQuick[s]" if transform == "SyNQuick" else transform
    t1_to_mni = ants.registration(fixed=mni, moving=t1_n4, type_of_transform=ants_tx)
    ants.image_write(t1_to_mni["warpedmovout"], str(out_dir / "t1w_mni.nii.gz"))
    log_stage(f"t1_to_mni_{transform}", t0)

    # 5. 4D BOLD motion correction
    t0 = time.perf_counter()
    moco = ants.motion_correction(bold, type_of_transform="BOLDRigid")
    bold_moco = moco["motion_corrected"]
    confounds_df = _extract_motion_confounds(moco["motion_parameters"], moco["FD"])
    confounds_path = out_dir / "confounds.tsv"
    confounds_df.to_csv(confounds_path, sep="\t", index=False)
    log_stage("bold_motion_correction", t0)

    # 6. Mean BOLD -> T1w rigid coregistration
    t0 = time.perf_counter()
    mean_bold = ants.get_average_of_timeseries(bold_moco)
    bold_to_t1 = ants.registration(
        fixed=t1_n4, moving=mean_bold, type_of_transform="Rigid"
    )
    log_stage("mean_bold_to_t1_rigid", t0)

    # 7. Single-interpolation warp of 4D BOLD & masks to MNI152 2mm
    t0 = time.perf_counter()
    composed_tx = t1_to_mni["fwdtransforms"] + bold_to_t1["fwdtransforms"]
    bold_mni = ants.apply_transforms(
        fixed=mni,
        moving=bold_moco,
        transformlist=composed_tx,
        imagetype=3,
        interpolator="linear",
    )
    # Preserve exact TR in 4D spacing before writing NIfTI files.
    sp = list(bold_mni.spacing)
    if len(sp) >= 4:
        sp[3] = tr_sec
        bold_mni.set_spacing(tuple(sp))

    bold_mni_gz_path = out_dir / "bold_mni.nii.gz"
    bold_mni_nii_path = out_dir / "bold_mni.nii"
    ants.image_write(bold_mni, str(bold_mni_gz_path))
    # Write uncompressed float32 .nii for Rust memmap2 zero-copy I/O benchmark.
    bold_nib = nib.load(str(bold_mni_gz_path))
    bold_f32 = np.asarray(bold_nib.dataobj, dtype=np.float32)
    bold_nib_uncomp = nib.Nifti1Image(bold_f32, bold_nib.affine, bold_nib.header)
    bold_nib_uncomp.set_data_dtype(np.float32)
    nib.save(bold_nib_uncomp, str(bold_mni_nii_path))

    wm_mni = ants.apply_transforms(
        fixed=mni,
        moving=wm_mask,
        transformlist=t1_to_mni["fwdtransforms"],
        interpolator="nearestNeighbor",
    )
    csf_mni = ants.apply_transforms(
        fixed=mni,
        moving=csf_mask,
        transformlist=t1_to_mni["fwdtransforms"],
        interpolator="nearestNeighbor",
    )
    wm_mask_path = out_dir / "wm_mask_mni.nii.gz"
    csf_mask_path = out_dir / "csf_mask_mni.nii.gz"
    nib.save(
        nib.Nifti1Image((wm_mni.numpy() > 0.5).astype(np.uint8), bold_nib.affine),
        str(wm_mask_path),
    )
    nib.save(
        nib.Nifti1Image((csf_mni.numpy() > 0.5).astype(np.uint8), bold_nib.affine),
        str(csf_mask_path),
    )
    log_stage("warp_4d_and_masks_to_mni", t0)

    # 8. Resample Schaefer-400 2mm atlas onto bold_mni grid
    t0 = time.perf_counter()
    schaefer = datasets.fetch_atlas_schaefer_2018(n_rois=400, resolution_mm=2, verbose=0)
    atlas_resampled = image.resample_to_img(
        schaefer.maps,
        nib.Nifti1Image(np.zeros(bold_nib.shape[:3], dtype=np.float32), bold_nib.affine),
        interpolation="nearest",
        force_resample=True,
        copy_header=True,
    )
    atlas_i32 = np.rint(atlas_resampled.get_fdata()).astype(np.int32)
    atlas_path = out_dir / "schaefer400_mni.nii.gz"
    nib.save(nib.Nifti1Image(atlas_i32, bold_nib.affine), str(atlas_path))
    labels_path = out_dir / "schaefer400_labels.json"
    labels_path.write_text(
        json.dumps([str(lbl) for lbl in schaefer.labels], indent=2),
        encoding="utf-8",
    )
    log_stage("align_schaefer400_atlas", t0)

    total_sec = time.perf_counter() - t_start
    report = {
        "t1_input": str(t1_path),
        "bold_input": str(bold_path),
        "transform": transform,
        "tr_sec": tr_sec,
        "t1_shape": list(t1.shape),
        "bold_raw_shape": list(bold.shape),
        "bold_mni_shape": list(bold_mni.shape),
        "wm_mask_voxels": int((wm_mni.numpy() > 0.5).sum()),
        "csf_mask_voxels": int((csf_mni.numpy() > 0.5).sum()),
        "schaefer_unique_labels": int(len(np.unique(atlas_i32)) - 1),
        "mean_fd_mm": float(confounds_df["framewise_displacement"].mean()),
        "max_fd_mm": float(confounds_df["framewise_displacement"].max()),
        "total_seconds": round(total_sec, 3),
        "peak_rss_mb": round(_peak_rss_mb(), 2),
        "stages": stages,
        "outputs": {
            "bold_mni_gz": str(bold_mni_gz_path),
            "bold_mni_nii": str(bold_mni_nii_path),
            "wm_mask_mni": str(wm_mask_path),
            "csf_mask_mni": str(csf_mask_path),
            "confounds_tsv": str(confounds_path),
            "schaefer400_mni": str(atlas_path),
            "schaefer400_labels": str(labels_path),
        },
    }
    (out_dir / "preprocess_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="ANTsPy fMRI preprocessing CLI.")
    parser.add_argument("--t1", required=True, type=Path)
    parser.add_argument("--bold", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--transform", default="SyNQuick", choices=["SyNQuick", "SyN"])
    args = parser.parse_args()

    report = run_preprocessing(args.t1, args.bold, args.out, args.transform)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
