"""(a) ROI extraction parity: app Rust parcellation vs nilearn NiftiLabelsMasker on the same BOLD.
(b) Voxel-wise PCC seed map: app (Rust seed + sidecar voxel model) vs fMRIPrep + nilearn reference.
Usage: python -I parcellation_and_seed.py <parity_run_dir> <app_seed_dir> <fmriprep_bold> <fmriprep_confounds> <out_dir>
"""
import json
import sys
import time
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
import pandas as pd
from nilearn import datasets, image, plotting, signal
from nilearn.maskers import NiftiLabelsMasker, NiftiMasker

run_dir, seed_dir, fp_bold, fp_conf, out = map(Path, sys.argv[1:6])
res = {}
# (a) parcellation parity
raw_rust = np.loadtxt(run_dir / "harness/raw_ts.csv", delimiter=",")
t0 = time.perf_counter()
raw_nl = NiftiLabelsMasker(str(run_dir / "schaefer400_mni.nii.gz"), strategy="mean").fit_transform(str(run_dir / "bold_mni.nii"))
res["nilearn_masker_s"] = time.perf_counter() - t0
res["roi_min_r"] = float(min(np.corrcoef(raw_rust[:, j], raw_nl[:, j])[0, 1] for j in range(400)))
res["roi_max_abs_rel_diff"] = float(np.max(np.abs(raw_rust - raw_nl) / np.abs(raw_nl).mean()))
log = (run_dir / "harness.log").read_text()
res["rust_parcellation_ms"] = float(log.split("parc_ms=")[1].split()[0])

# (b) seed map concordance (PCC = 7Networks_LH_Default_pCunPCC_1)
sch = datasets.fetch_atlas_schaefer_2018(n_rois=400, resolution_mm=2, verbose=0)
labels = [l.decode() if isinstance(l, bytes) else str(l) for l in sch.labels]
labels = [l for l in labels if l.lower() != "background"]
pcc = labels.index("7Networks_LH_Default_pCunPCC_1") + 1
c = pd.read_csv(fp_conf, sep="\t")
mot = c[["trans_x", "trans_y", "trans_z", "rot_x", "rot_y", "rot_z"]].to_numpy()
d = np.vstack([np.zeros((1, 6)), np.diff(mot, axis=0)])
conf = np.hstack([mot, d, mot ** 2, d ** 2, c[[f"w_comp_cor_{i:02d}" for i in range(5)] + [f"c_comp_cor_{i:02d}" for i in range(5)]].to_numpy()])
fd = c["framewise_displacement"].fillna(0).to_numpy(); keep = np.where(fd <= 0.5)[0]
mask = image.resample_to_img(str(Path(str(fp_bold).replace("_desc-preproc_bold.nii.gz", "_desc-brain_mask.nii.gz"))),
                             str(fp_bold), interpolation="nearest", force_resample=True, copy_header=True) \
    if Path(str(fp_bold).replace("_desc-preproc_bold.nii.gz", "_desc-brain_mask.nii.gz")).exists() else None
masker = NiftiMasker(mask_img=mask, standardize=None)
X = masker.fit_transform(str(fp_bold))
Xc = signal.clean(X, confounds=conf, detrend=True, standardize="zscore_sample", sample_mask=keep, filter="butterworth",
                  low_pass=0.09, high_pass=0.008, t_r=2.1)
seed_ts = NiftiLabelsMasker(sch.maps, strategy="mean").fit_transform(str(fp_bold))[:, pcc - 1:pcc]
sc = signal.clean(seed_ts, confounds=conf, detrend=True, standardize="zscore_sample", sample_mask=keep, filter="butterworth",
                  low_pass=0.09, high_pass=0.008, t_r=2.1)[:, 0]
r = (sc @ Xc) / (len(sc) - 1)
ref_r_img = masker.inverse_transform(r)
app_z = nib.load(seed_dir / "seed_zmap.nii.gz")
app_sum = json.loads((seed_dir / "seed_glm_summary.json").read_text())
app_r = np.tanh(app_z.get_fdata() / np.sqrt(max(1, app_sum["residual_dof"] - 3)))
ref_r = image.resample_to_img(ref_r_img, app_z, force_resample=True, copy_header=True).get_fdata()
both = (app_r != 0) & (ref_r != 0) & np.isfinite(ref_r)
res["seed_map_spatial_r"] = float(np.corrcoef(app_r[both], ref_r[both])[0, 1])
top = lambda m: m > np.percentile(m[both], 90)
ta, tb = top(app_r) & both, top(ref_r) & both
res["seed_map_top10pct_dice"] = float(2 * (ta & tb).sum() / (ta.sum() + tb.sum()))
res["app_n_fdr_voxels"] = app_sum["n_sig_voxels"]; res["app_residual_dof"] = app_sum["residual_dof"]
json.dump(res, open(out / "tables" / "tier2_parcellation_and_seedmap.json", "w"), indent=1)
print(res)
fig, ax = plt.subplots(2, 1, figsize=(7.2, 4.2))
plotting.plot_stat_map(nib.Nifti1Image(app_r, app_z.affine), display_mode="z", cut_coords=[-6, 12, 30, 48], axes=ax[0],
                       threshold=0.2, vmax=0.8, colorbar=True, title="CCS fMRI Studio v0.5.0 (PCC seed, r)")
plotting.plot_stat_map(image.resample_to_img(ref_r_img, app_z, force_resample=True, copy_header=True), display_mode="z",
                       cut_coords=[-6, 12, 30, 48], axes=ax[1], threshold=0.2, vmax=0.8, colorbar=True,
                       title=f"fMRIPrep + nilearn reference (spatial r = {res['seed_map_spatial_r']:.2f})")
fig.savefig(out / "figures" / "Fig8_seed_map_concordance.png", dpi=300, bbox_inches="tight"); plt.close(fig)
