"""DICOM to BIDS-style NIfTI conversion wrapper using dcm2niix."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import nibabel as nib


def _run_dcm2niix(dicom_dir: Path, out_dir: Path, prefix: str) -> list[Path]:
    dcm2niix_bin = shutil.which("dcm2niix")
    if not dcm2niix_bin:
        raise RuntimeError(
            "dcm2niix not found on PATH. Install it (e.g., `brew install dcm2niix`) "
            "or bundle it with the sidecar."
        )
    cmd = [
        dcm2niix_bin,
        "-z",
        "y",
        "-b",
        "y",
        "-f",
        prefix,
        "-o",
        str(out_dir),
        str(dicom_dir),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(
            f"dcm2niix failed (exit {proc.returncode}) on {dicom_dir}:\n"
            f"{proc.stdout}\n{proc.stderr}"
        )
    niftis = sorted(out_dir.glob(f"{prefix}*.nii.gz"))
    if not niftis:
        raise RuntimeError(
            f"dcm2niix produced no .nii.gz output for {dicom_dir}:\n{proc.stdout}"
        )
    return niftis


def _pick_best_nifti(candidates: list[Path], expected_ndim: int) -> Path:
    best_path = None
    best_score = -1
    for path in candidates:
        img = nib.load(str(path))
        ndim = len(img.shape)
        if expected_ndim == 4 and ndim == 4:
            score = int(img.shape[3]) * 100000 + int(img.shape[0] * img.shape[1] * img.shape[2])
        elif expected_ndim == 3 and ndim == 3:
            score = int(img.shape[0] * img.shape[1] * img.shape[2])
        else:
            score = 0
        if score > best_score:
            best_score = score
            best_path = path
    if best_path is None or best_score <= 0:
        shapes = [(p.name, nib.load(str(p)).shape) for p in candidates]
        raise RuntimeError(
            f"No {expected_ndim}D NIfTI found among candidates: {shapes}"
        )
    return best_path


def _move_with_sidecar(src_nii: Path, dst_nii: Path) -> dict:
    dst_nii.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src_nii), str(dst_nii))

    src_json = Path(str(src_nii).replace(".nii.gz", ".json"))
    dst_json = Path(str(dst_nii).replace(".nii.gz", ".json"))
    meta: dict = {}
    if src_json.exists():
        meta = json.loads(src_json.read_text(encoding="utf-8"))
        shutil.move(str(src_json), str(dst_json))

    img = nib.load(str(dst_nii))
    zooms = [float(z) for z in img.header.get_zooms()]
    tr_sec = meta.get("RepetitionTime")
    if tr_sec is None and len(zooms) >= 4 and zooms[3] > 0:
        tr_sec = zooms[3]
    return {
        "nifti": str(dst_nii),
        "json": str(dst_json) if dst_json.exists() else None,
        "shape": [int(s) for s in img.shape],
        "zooms": zooms,
        "tr_sec": float(tr_sec) if tr_sec is not None else None,
        "slice_timing_len": len(meta.get("SliceTiming", [])) if "SliceTiming" in meta else 0,
    }


def convert_subject_dicoms(t1_dir: Path, bold_dir: Path, out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ccs_dcm2niix_") as tmp:
        tmp_path = Path(tmp)
        t1_tmp = tmp_path / "t1"
        bold_tmp = tmp_path / "bold"
        t1_tmp.mkdir()
        bold_tmp.mkdir()

        t1_cands = _run_dcm2niix(t1_dir, t1_tmp, "t1w")
        t1_best = _pick_best_nifti(t1_cands, expected_ndim=3)
        t1_info = _move_with_sidecar(t1_best, out_dir / "t1w.nii.gz")

        bold_cands = _run_dcm2niix(bold_dir, bold_tmp, "bold")
        bold_best = _pick_best_nifti(bold_cands, expected_ndim=4)
        bold_info = _move_with_sidecar(bold_best, out_dir / "bold.nii.gz")

    summary = {"t1w": t1_info, "bold": bold_info}
    (out_dir / "conversion_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert T1w & BOLD DICOM folders to NIfTI.")
    parser.add_argument("--t1-dicom", required=True, type=Path)
    parser.add_argument("--bold-dicom", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    summary = convert_subject_dicoms(args.t1_dicom, args.bold_dicom, args.out)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
