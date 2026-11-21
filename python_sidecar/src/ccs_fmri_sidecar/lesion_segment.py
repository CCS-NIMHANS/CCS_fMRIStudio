"""Automated first-pass lesion segmentation (ONNX U-Net or multi-contrast asymmetry)."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import ants
import nibabel as nib
import numpy as np
from nilearn import datasets
from scipy import ndimage

from ccs_fmri_sidecar.templates import resolve_template


def _robust_z_asymmetry(arr: np.ndarray, fg: np.ndarray, sign: float) -> np.ndarray:
    flipped = np.flip(arr, axis=0)
    both_fg = fg & (flipped > 0)
    diff = sign * (flipped - arr)
    vals = diff[both_fg]
    if vals.size == 0:
        return np.zeros_like(arr, dtype=np.float32)
    med = float(np.median(vals))
    mad = max(float(np.median(np.abs(vals - med))) * 1.4826, 1e-5)
    z = np.zeros_like(arr, dtype=np.float32)
    z[both_fg] = (diff[both_fg] - med) / mad
    return z


def _remove_small_islands(mask: np.ndarray, min_voxels: int = 10) -> np.ndarray:
    labeled, n_comp = ndimage.label(mask > 0)
    if n_comp == 0:
        return np.zeros_like(mask, dtype=np.uint8)
    counts = np.bincount(labeled.ravel())
    keep = counts >= min_voxels
    keep[0] = False
    return keep[labeled].astype(np.uint8)


def _summarize_lesion(mask: np.ndarray, affine: np.ndarray, zooms: tuple[float, ...]) -> dict:
    coords = np.argwhere(mask > 0)
    vox = int(coords.shape[0])
    vox_vol_ml = float(abs(zooms[0] * zooms[1] * zooms[2])) / 1000.0
    vol_ml = vox * vox_vol_ml

    if vox == 0:
        return {
            "voxel_count": 0,
            "volume_ml": 0.0,
            "left_voxels": 0,
            "right_voxels": 0,
            "dominant_hemisphere": "None",
        }
    world_x = (
        affine[0, 0] * coords[:, 0]
        + affine[0, 1] * coords[:, 1]
        + affine[0, 2] * coords[:, 2]
        + affine[0, 3]
    )
    left_vox = int(np.sum(world_x < 0.0))
    right_vox = int(vox - left_vox)
    frac = left_vox / vox
    dom = "Left" if frac > 0.75 else ("Right" if frac < 0.25 else "Bilateral")
    return {
        "voxel_count": vox,
        "volume_ml": round(vol_ml, 4),
        "left_voxels": left_vox,
        "right_voxels": right_vox,
        "dominant_hemisphere": dom,
    }


def _run_onnx_inference(
    onnx_path: Path, t1_arr: np.ndarray, flair_arr: np.ndarray | None
) -> np.ndarray:
    try:
        import onnxruntime as ort
    except ImportError as exc:
        raise RuntimeError(
            "onnxruntime is not installed in python_sidecar. Install `onnxruntime` "
            "or omit --onnx-model to use multi-contrast asymmetry segmentation."
        ) from exc

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    in_meta = sess.get_inputs()[0]
    norm = lambda a: ((a - a.mean()) / max(float(a.std()), 1e-5)).astype(np.float32)
    chans = [norm(t1_arr)]
    if flair_arr is not None and len(in_meta.shape) >= 2 and in_meta.shape[1] == 2:
        chans.append(norm(flair_arr))
    x = np.stack(chans, axis=0)[None, ...]
    out = sess.run(None, {in_meta.name: x})[0]
    prob = np.squeeze(out)
    return (prob >= 0.5).astype(np.uint8)


def segment_lesion(
    t1_path: Path,
    out_dir: Path,
    flair_path: Path | None = None,
    t2_path: Path | None = None,
    onnx_model: Path | None = None,
    z_threshold: float = 2.5,
    min_island_voxels: int = 10,
) -> dict:
    """Segment focal lesion from T1w (+ optional FLAIR/T2w) using ONNX or midline-aligned asymmetry."""
    out_dir.mkdir(parents=True, exist_ok=True)
    t1_ants = ants.image_read(str(t1_path), pixeltype="float")
    t1_n4 = ants.n4_bias_field_correction(t1_ants)

    flair_reg = None
    secondary_path = flair_path or t2_path
    if secondary_path is not None:
        sec_ants = ants.image_read(str(secondary_path), pixeltype="float")
        flair_reg = ants.registration(
            fixed=t1_n4, moving=sec_ants, type_of_transform="Rigid"
        )["warpedmovout"]

    if onnx_model is not None:
        raw_mask = _run_onnx_inference(
            onnx_model, t1_n4.numpy(), flair_reg.numpy() if flair_reg is not None else None
        )
        method = f"onnx:{onnx_model.name}"
        asym_native = np.zeros_like(t1_n4.numpy(), dtype=np.float32)
    else:
        # Affine-align T1w (+ optional FLAIR) to symmetric MNI152 midline before X-flip comparison.
        mni_path, _ = resolve_template("mni152_adult", out_cache_dir=out_dir / "templates")
        mni = ants.image_read(str(mni_path), pixeltype="float")
        mni_bmask_nib = datasets.load_mni152_brain_mask(resolution=2)
        mni_bmask_path = out_dir / "templates" / "mni152_2mm_brain_mask.nii.gz"
        nib.save(mni_bmask_nib, str(mni_bmask_path))
        mni_bmask_arr = (
            ndimage.binary_erosion(nib.load(str(mni_bmask_path)).get_fdata() > 0.5, iterations=1)
        )

        rigid_mid = ants.registration(fixed=mni, moving=t1_n4, type_of_transform="Affine")
        t1_sym = rigid_mid["warpedmovout"]
        t1_sym_smooth = ants.smooth_image(t1_sym, 2.5)
        fg_sym = mni_bmask_arr & (t1_sym.numpy() > 0)
        z_t1 = _robust_z_asymmetry(t1_sym_smooth.numpy(), fg_sym, sign=1.0)

        if flair_reg is not None:
            fl_sym = ants.apply_transforms(
                fixed=mni, moving=flair_reg, transformlist=rigid_mid["fwdtransforms"]
            )
            fl_sym_smooth = ants.smooth_image(fl_sym, 2.5)
            z_fl = _robust_z_asymmetry(fl_sym_smooth.numpy(), fg_sym, sign=-1.0)
            asym_sym = 0.5 * (z_t1 + z_fl)
            method = "multicontrast_midline_asymmetry"
        else:
            asym_sym = z_t1
            method = "t1_midline_asymmetry"

        raw_sym = ((asym_sym >= z_threshold) & fg_sym).astype(np.float32)
        raw_sym_img = t1_sym.new_image_like(raw_sym)
        asym_sym_img = t1_sym.new_image_like(asym_sym.astype(np.float32))

        raw_native = ants.apply_transforms(
            fixed=t1_n4,
            moving=raw_sym_img,
            transformlist=rigid_mid["invtransforms"],
            whichtoinvert=[True],
            interpolator="nearestNeighbor",
        )
        asym_native_img = ants.apply_transforms(
            fixed=t1_n4,
            moving=asym_sym_img,
            transformlist=rigid_mid["invtransforms"],
            whichtoinvert=[True],
            interpolator="linear",
        )
        raw_mask = raw_native.numpy() > 0.5
        asym_native = asym_native_img.numpy()

    clean_mask = _remove_small_islands(raw_mask, min_voxels=min_island_voxels)
    clean_mask = ndimage.binary_fill_holes(clean_mask > 0).astype(np.uint8)

    t1_nib = nib.load(str(t1_path))
    mask_path = out_dir / "lesion_mask.nii.gz"
    asym_path = out_dir / "asymmetry_map.nii.gz"
    nib.save(nib.Nifti1Image(clean_mask, t1_nib.affine), str(mask_path))
    nib.save(nib.Nifti1Image(asym_native.astype(np.float32), t1_nib.affine), str(asym_path))

    summary = _summarize_lesion(clean_mask, t1_nib.affine, t1_nib.header.get_zooms())
    summary["method"] = method
    summary["z_threshold"] = z_threshold
    summary["lesion_mask_path"] = str(mask_path)
    summary["asymmetry_map_path"] = str(asym_path)

    (out_dir / "lesion_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Automated TBI/Stroke lesion segmentation.")
    parser.add_argument("--t1", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--flair", type=Path, default=None)
    parser.add_argument("--t2", type=Path, default=None)
    parser.add_argument("--onnx-model", type=Path, default=None)
    parser.add_argument("--z-threshold", type=float, default=2.5)
    args = parser.parse_args()

    res = segment_lesion(
        args.t1,
        args.out,
        flair_path=args.flair,
        t2_path=args.t2,
        onnx_model=args.onnx_model,
        z_threshold=args.z_threshold,
    )
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
