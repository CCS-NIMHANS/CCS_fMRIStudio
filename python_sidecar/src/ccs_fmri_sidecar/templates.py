"""Clinical and age-appropriate stereotaxic brain template registry & resolver."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import nibabel as nib
import numpy as np
from nilearn import datasets, image

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_TEMPLATES_DIR = REPO_ROOT / "assets" / "templates"


def load_registry(templates_dir: Path = DEFAULT_TEMPLATES_DIR) -> dict:
    reg_path = templates_dir / "registry.json"
    return json.loads(reg_path.read_text(encoding="utf-8"))


def _ensure_mni_stereotaxic_grid(img: nib.Nifti1Image, mni_ref: nib.Nifti1Image) -> nib.Nifti1Image:
    """Resamples a custom/clinical template onto the exact MNI152 2mm bounding box if needed."""
    if img.shape[:3] == mni_ref.shape[:3] and np.allclose(img.affine, mni_ref.affine, atol=1e-2):
        return img
    return image.resample_to_img(
        img, mni_ref, interpolation="continuous", force_resample=True, copy_header=True
    )


def resolve_template(
    template_id: str = "mni152_adult",
    custom_template_path: Path | None = None,
    templates_dir: Path = DEFAULT_TEMPLATES_DIR,
    out_cache_dir: Path | None = None,
) -> tuple[Path, dict]:
    """Resolve and validate a clinical brain template in MNI152 2mm stereotaxic coordinates."""
    registry = load_registry(templates_dir)
    templates = registry["templates"]
    if template_id not in templates:
        raise ValueError(
            f"Unknown template_id '{template_id}'. Available: {list(templates.keys())}"
        )
    meta = dict(templates[template_id])
    meta["template_id"] = template_id

    mni_ref = datasets.load_mni152_template(resolution=2)
    target_dir = out_cache_dir or templates_dir
    target_dir.mkdir(parents=True, exist_ok=True)

    if custom_template_path is not None:
        if not custom_template_path.exists():
            raise FileNotFoundError(f"Custom template not found: {custom_template_path}")
        loaded = nib.load(str(custom_template_path))
        aligned = _ensure_mni_stereotaxic_grid(loaded, mni_ref)
        out_path = target_dir / f"{template_id}_mni_aligned.nii.gz"
        nib.save(aligned, str(out_path))
        meta["resolved_path"] = str(out_path)
        meta["source"] = str(custom_template_path)
        return out_path, meta

    bundled = templates_dir / meta["bundled_filename"]
    if bundled.exists():
        loaded = nib.load(str(bundled))
        aligned = _ensure_mni_stereotaxic_grid(loaded, mni_ref)
        if aligned is not loaded:
            out_path = target_dir / f"{template_id}_mni_aligned.nii.gz"
            nib.save(aligned, str(out_path))
        else:
            out_path = bundled
        meta["resolved_path"] = str(out_path)
        meta["source"] = "bundled"
        return out_path, meta

    if meta.get("auto_fetch") == "nilearn_mni152_2mm":
        out_path = target_dir / meta["bundled_filename"]
        nib.save(mni_ref, str(out_path))
        meta["resolved_path"] = str(out_path)
        meta["source"] = "nilearn_mni152_2mm"
        return out_path, meta

    raise FileNotFoundError(
        f"Clinical template '{template_id}' ({meta['display_name']}) is not bundled at "
        f"{bundled}. Download or provide a local MNI-aligned NIfTI via --custom-template."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Inspect or resolve clinical brain templates.")
    parser.add_argument("--list", action="store_true", help="List available clinical templates.")
    parser.add_argument("--template", default="mni152_adult")
    parser.add_argument("--custom-template", type=Path, default=None)
    args = parser.parse_args()

    if args.list:
        reg = load_registry()
        for tid, info in reg["templates"].items():
            bundled = (DEFAULT_TEMPLATES_DIR / info["bundled_filename"]).exists()
            info_out = {
                "template_id": tid,
                "cohort": info["cohort"],
                "display_name": info["display_name"],
                "recommended_lesion_mode": info["recommended_lesion_mode"],
                "available_locally": bundled or (info.get("auto_fetch") is not None),
            }
            print(json.dumps(info_out))
        return

    path, meta = resolve_template(args.template, args.custom_template)
    print(json.dumps({"path": str(path), "meta": meta}, indent=2))


if __name__ == "__main__":
    main()
