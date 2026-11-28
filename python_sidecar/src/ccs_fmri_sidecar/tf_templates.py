"""Minimal, dependency-free TemplateFlow resolver.

Looks for TemplateFlow files (https://www.templateflow.org) in, in order:
  1. `assets/templates/tpl-<name>/` bundled with the app,
  2. `$TEMPLATEFLOW_HOME/tpl-<name>/` (shared with fMRIPrep / the `templateflow` package),
  3. `~/.cache/templateflow/tpl-<name>/`,
and otherwise downloads the file from the public TemplateFlow S3 bucket into the cache in (3).
Zero-byte placeholder files left by DataLad/TemplateFlow are treated as missing.
"""

from __future__ import annotations

import os
import shutil
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BUNDLED_DIR = REPO_ROOT / "assets" / "templates"
S3_BASE = "https://templateflow.s3.amazonaws.com"

# Default analysis space: FSL MNI152 nonlinear 6th generation (MNI152NLin6Asym), the native
# space of the Schaefer-2018 / Yeo / Harvard-Oxford FSL atlases shipped with nilearn.
DEFAULT_SPACE = "MNI152NLin6Asym"


def _search_dirs(tpl: str) -> list[Path]:
    dirs = [BUNDLED_DIR / f"tpl-{tpl}"]
    env = os.environ.get("TEMPLATEFLOW_HOME")
    if env:
        dirs.append(Path(env) / f"tpl-{tpl}")
    dirs.append(Path.home() / ".cache" / "templateflow" / f"tpl-{tpl}")
    return dirs


def get_template_file(tpl: str, suffix: str, allow_download: bool = True) -> Path:
    """Return a local path to `tpl-<tpl>_<suffix>` (e.g. suffix='res-01_T1w.nii.gz')."""
    fname = f"tpl-{tpl}_{suffix}"
    for d in _search_dirs(tpl):
        p = d / fname
        if p.exists() and p.stat().st_size > 0:
            return p
    if not allow_download:
        raise FileNotFoundError(f"TemplateFlow file {fname} not found locally")
    dest_dir = Path.home() / ".cache" / "templateflow" / f"tpl-{tpl}"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / fname
    tmp = dest.with_suffix(dest.suffix + ".part")
    url = f"{S3_BASE}/tpl-{tpl}/{fname}"
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:  # noqa: S310
        shutil.copyfileobj(r, f)
    if tmp.stat().st_size == 0:
        tmp.unlink()
        raise FileNotFoundError(f"Empty download for {url}")
    tmp.replace(dest)
    return dest


def standard_space_files(tpl: str = DEFAULT_SPACE) -> dict[str, Path]:
    """Head T1w + brain mask at 1 mm (registration) and 2 mm (output grid)."""
    return {
        "t1w_1mm": get_template_file(tpl, "res-01_T1w.nii.gz"),
        "brain_mask_1mm": get_template_file(tpl, "res-01_desc-brain_mask.nii.gz"),
        "t1w_2mm": get_template_file(tpl, "res-02_T1w.nii.gz"),
        "brain_mask_2mm": get_template_file(tpl, "res-02_desc-brain_mask.nii.gz"),
    }
