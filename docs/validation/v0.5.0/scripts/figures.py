"""Publication figures for the CCS fMRI Studio v0.5.0 validation report (v0.5.0 vs gold standards only)."""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
import pandas as pd
from matplotlib.patches import FancyBboxPatch
from nilearn import datasets, image

import common as C

R = Path(__file__).resolve().parents[1]
T, D, FIG = R / "tables", R / "data", R / "figures"
RV = Path(str(R).replace("CCS_fMRIStudio_v0.5.0_Validation_Report", "CCS_fMRIStudio_Revalidation_v0.5.0"))
FIG.mkdir(exist_ok=True)
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 8, "axes.titlesize": 8.5, "axes.labelsize": 8,
                     "axes.spines.top": False, "axes.spines.right": False, "savefig.dpi": 300})
APP, REF, NL = "#00798c", "#30343f", "#edae49"
NETS = C.NETS


def panel(ax, l):
    ax.text(-0.14, 1.07, l, transform=ax.transAxes, fontsize=11, fontweight="bold", va="bottom")


def netimshow(ax, m, title, vmax=0.15):
    im = ax.imshow(m, cmap="RdBu_r", vmin=-vmax, vmax=vmax)
    ax.set_xticks(range(7)); ax.set_yticks(range(7))
    ax.set_xticklabels(NETS, rotation=90, fontsize=6); ax.set_yticklabels(NETS, fontsize=6); ax.set_title(title, fontsize=7.5)
    return im


# ---- Fig 1: validation design ----------------------------------------------------------------
fig, ax = plt.subplots(figsize=(7.2, 3.3)); ax.axis("off"); ax.set_xlim(0, 10); ax.set_ylim(0, 4.6)
boxes = [
    (0.1, 3.2, 3.1, 1.2, "Data", "ds003768 (EEG-fMRI sleep, TR 2.1 s):\n7 subjects, 17 runs, 30-s sleep scoring\nds006110 PsiConnect (MB4, TR 0.91 s):\npre/post psilocybin × 4 conditions", "#eeeeee"),
    (3.45, 3.2, 3.1, 1.2, "Tier 1 — preprocessing", "CCS fMRI Studio (ANTsPy)\nvs fMRIPrep 24.1.1\nDice, template r, FD, mean BOLD", "#d9eef1"),
    (6.8, 3.2, 3.1, 1.2, "Tier 2 — time series / FC engine", "Rust engine vs nilearn 0.14\non identical inputs (app & fMRIPrep)\nROI means, denoising, FC, ACW", "#d9eef1"),
    (0.1, 1.6, 4.8, 1.2, "Tier 3 — end-to-end", "app vs fMRIPrep + nilearn (24P + aCompCor + scrubbing)\nFC agreement, network structure, before/after denoising QC,\nagreement vs test-retest, seed maps", "#fbecd2"),
    (5.1, 1.6, 4.8, 1.2, "Tier 4 — biological concordance", "Sleep: wake vs N1/N2 (FC, BOLD amplitude, ACW)\nPsilocybin: post vs pre per condition (FC, ACW)\nConditions: movie / music / meditation vs rest", "#fbecd2"),
    (2.5, 0.1, 5.0, 1.0, "Planned (Linux server)", "AFNI 3dROIstats / 3dTproject benchmark; ≥ 20 subjects, multi-site;\nfull fMRIPrep on all runs", "#f4f4f4"),
]
for x, y, w, h, t, s, c in boxes:
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.08", fc=c, ec="#777", lw=0.6))
    ax.text(x + w / 2, y + h - 0.2, t, ha="center", va="top", fontsize=7.5, fontweight="bold")
    ax.text(x + w / 2, y + h - 0.45, s, ha="center", va="top", fontsize=6.3)
fig.tight_layout(); fig.savefig(FIG / "Fig1_validation_design.png"); plt.close(fig)

# ---- Fig 2: anatomy app vs fMRIPrep (external sub-04 + PsiConnect) ----------------------------
SCR = C.SCR
cases = [("ds003768 sub-04", SCR / "ext/app/sub-04_run-1", SCR / "ext/fp_out/sub-04/anat/sub-04_space-MNI152NLin6Asym_res-2_desc-preproc_T1w.nii.gz",
          SCR / "ext/fp_out/sub-04/anat/sub-04_space-MNI152NLin6Asym_res-2_desc-brain_mask.nii.gz"),
         ("ds006110 PC001", SCR / "v5/ds006110_sub-PC001__ses-01_pre__rest", SCR / "fmriprep/out/sub-PC001/anat/sub-PC001_space-MNI152NLin6Asym_res-2_desc-preproc_T1w.nii.gz",
          SCR / "fmriprep/out/sub-PC001/anat/sub-PC001_space-MNI152NLin6Asym_res-2_desc-brain_mask.nii.gz")]
fig, ax = plt.subplots(4, 3, figsize=(7.2, 9.2))
for ci, (name, adir, fpt1, fpbm) in enumerate(cases):
    t1a = nib.load(adir / "t1w_mni.nii.gz"); ref = t1a
    a = t1a.get_fdata(); bm = nib.load(adir / "brain_mask_mni.nii.gz").get_fdata() > 0
    wm = nib.load(adir / "wm_mask_mni.nii.gz").get_fdata() > 0; csf = nib.load(adir / "csf_mask_mni.nii.gz").get_fdata() > 0
    f = image.resample_to_img(str(fpt1), ref, force_resample=True, copy_header=True).get_fdata()
    fbm = image.resample_to_img(str(fpbm), ref, interpolation="nearest", force_resample=True, copy_header=True).get_fdata() > 0
    for ri, (img, outline, lab) in enumerate([(a, fbm, "CCS fMRI Studio"), (f, bm, "fMRIPrep 24.1.1")]):
        for j, sl in enumerate([lambda v: np.rot90(v[:, :, 46]), lambda v: np.rot90(v[:, 60, :]), lambda v: np.rot90(v[30, :, :])]):
            axx = ax[ci * 2 + ri, j]
            axx.imshow(sl(img), cmap="gray"); axx.contour(sl(outline).astype(float), [.5], colors="gold", linewidths=.5)
            if ri == 0:
                axx.imshow(np.ma.masked_where(~sl(wm), sl(wm)), cmap="winter", alpha=.6, interpolation="none")
                axx.imshow(np.ma.masked_where(~sl(csf), sl(csf)), cmap="autumn", alpha=.8, interpolation="none")
            axx.set_xticks([]); axx.set_yticks([])
            [s.set_visible(False) for s in axx.spines.values()]
        ax[ci * 2 + ri, 0].set_ylabel(f"{name}\n{lab}", fontsize=7.5, color=APP if ri == 0 else REF)
fig.suptitle("T1w in MNI152NLin6Asym. Gold contour = the *other* pipeline's brain mask; blue/red = app WM/CSF aCompCor masks", fontsize=7.5)
fig.tight_layout(); fig.savefig(FIG / "Fig2_anatomy_app_vs_fmriprep.png"); plt.close(fig)

# ---- Fig 3: preprocessing agreement ---------------------------------------------------------
ea = pd.read_csv(RV / "tables/ext_agreement_per_run.csv")
fig, ax = plt.subplots(1, 4, figsize=(7.2, 2.3))
ax[0].scatter(np.arange(len(ea)), ea.brain_mask_dice_app_vs_fmriprep, c=APP, s=12); ax[0].set_ylim(0.95, 1)
ax[0].set_title("Brain-mask Dice\napp vs fMRIPrep"); ax[0].set_xticks([]); ax[0].set_xlabel("12 runs")
ax[1].scatter(np.arange(len(ea)), ea.meanbold_r_app_vs_fmriprep, c=APP, s=12); ax[1].set_ylim(0, 1)
ax[1].set_title("Mean-BOLD spatial r\napp vs fMRIPrep"); ax[1].set_xticks([]); ax[1].set_xlabel("12 runs")
ax[2].scatter(ea.mean_fd_fmriprep, ea.mean_fd_app, c=APP, s=12); lim = [0, .5]; ax[2].plot(lim, lim, "k:", lw=.6)
ax[2].set_xlabel("mean FD, MCFLIRT/fMRIPrep (mm)"); ax[2].set_ylabel("mean FD, app (mm)"); ax[2].set_title(f"FD (per-volume r = {ea.fd_r.mean():.2f})")
fd_app = pd.read_csv(SCR / "ext/app/sub-07_run-1/confounds.tsv", sep="\t")["framewise_displacement"]
fd_ref = pd.read_csv(SCR / "ext/fp_out/sub-07/func/sub-07_task-rest_run-1_desc-confounds_timeseries.tsv", sep="\t")["framewise_displacement"].fillna(0)
ax[3].plot(fd_ref.values, c=REF, lw=.6, label="fMRIPrep"); ax[3].plot(fd_app.values, c=APP, lw=.6, label="app")
ax[3].axhline(.5, c="r", ls=":", lw=.6); ax[3].set_xlabel("volume"); ax[3].set_ylabel("FD (mm)"); ax[3].legend(frameon=False, fontsize=6)
ax[3].set_title("FD trace, sub-07 run-1")
for a_, l in zip(ax, "ABCD"):
    panel(a_, l)
fig.tight_layout(); fig.savefig(FIG / "Fig3_preprocessing_agreement.png"); plt.close(fig)

# ---- Fig 4: engine parity (tier 2) ------------------------------------------------------------
t2 = pd.read_csv(T / "tier2_engine_vs_nilearn.csv")
a = C.load_app("sub-02_run-1"); r = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"])
ne = C.nilearn_equiv(a["raw"], a["conf"], a["scrub"], a["tr"]); ns = C.nilearn_std(a["raw"], a["conf"], a["scrub"], a["tr"])
rc = r["clean"][r["kept"]]; idx = np.random.default_rng(0).choice(len(C.IU[0]), 8000, replace=False)
pj = json.loads((T / "tier2_parcellation_and_seedmap.json").read_text())
fig, ax = plt.subplots(1, 4, figsize=(7.2, 2.3))
ax[0].bar([0, 1], [pj["rust_parcellation_ms"] / 1000, pj["nilearn_masker_s"]], color=[APP, NL])
ax[0].set_xticks([0, 1]); ax[0].set_xticklabels(["Rust", "nilearn"]); ax[0].set_ylabel("seconds")
ax[0].set_title(f"ROI extraction (400 ROIs)\nmin ROI r = {pj['roi_min_r']:.9f}")
ax[1].scatter(C.fc(ne)[C.IU][idx], C.fc(rc)[C.IU][idx], s=1, c=APP, alpha=.4); ax[1].plot([-1, 1], [-1, 1], "k:", lw=.6)
ax[1].set_xlabel("nilearn, identical design"); ax[1].set_ylabel("Rust engine"); ax[1].set_title("Denoised FC edges\n(simultaneous model)")
ax[2].scatter(C.fc(ns)[C.IU][idx], C.fc(rc)[C.IU][idx], s=1, c=APP, alpha=.4); ax[2].plot([-1, 1], [-1, 1], "k:", lw=.6)
ax[2].set_xlabel("nilearn standard (Butterworth)"); ax[2].set_title(f"vs nilearn default filter\nr = {C.tri_r(C.fc(rc), C.fc(ns)):.2f}")
ok = t2[t2.dof >= 30]
for k, (inp, col) in enumerate([("app preprocessing", APP), ("fMRIPrep preprocessing", REF)]):
    v = ok[ok.input == inp].fc_r_std
    ax[3].scatter(np.full(len(v), k) + np.random.default_rng(k).uniform(-.1, .1, len(v)), v, s=10, c=col)
ax[3].set_xticks([0, 1]); ax[3].set_xticklabels(["app input", "fMRIPrep input"], fontsize=6.5); ax[3].set_ylim(0.6, 1)
ax[3].set_ylabel("FC r, Rust vs nilearn std"); ax[3].set_title("All runs with DOF ≥ 30")
for a_, l in zip(ax, "ABCD"):
    panel(a_, l)
fig.tight_layout(); fig.savefig(FIG / "Fig4_engine_parity_vs_nilearn.png"); plt.close(fig)

# ---- Fig 5: before / after denoising ---------------------------------------------------------
cz = np.load(D / "carpet_sub-07_run-1.npz")
fig = plt.figure(figsize=(7.6, 7.4)); gs = fig.add_gridspec(4, 4, height_ratios=[0.35, 1.2, 0.35, 1.2], hspace=0.5, wspace=0.45)
order = np.argsort(C.NET, kind="stable")
for col, (lab, raw, cl, kept, fdv) in enumerate([("CCS fMRI Studio", cz["app_raw"], cz["app_clean"], cz["app_kept"], cz["app_fd"]),
                                                  ("fMRIPrep + nilearn", cz["ref_raw"], None, cz["ref_keep"], cz["ref_fd"])]):
    if cl is None:
        cl_full = np.full_like(raw, np.nan); cl_full[kept] = cz["ref_clean"]; cl = cl_full
    else:
        cl = cl.copy(); m = np.ones(len(cl), bool); m[kept] = False; cl[m] = np.nan
    rz = (raw - raw.mean(0)) / raw.std(0)
    for k, (dat, ttl) in enumerate([(rz, "before denoising"), (cl, "after denoising (censored = blank)")]):
        a0 = fig.add_subplot(gs[0, col * 2 + k]); a0.plot(fdv, c="k", lw=.5); a0.axhline(.5, c="r", ls=":", lw=.5)
        a0.set_xticks([]); a0.set_ylabel("FD", fontsize=6); a0.set_title(f"{lab}\n{ttl}", fontsize=7)
        a1 = fig.add_subplot(gs[1, col * 2 + k]); a1.imshow(dat[:, order].T, aspect="auto", cmap="gray", vmin=-2, vmax=2, interpolation="none")
        a1.set_xlabel("volume"); a1.set_yticks([]); a1.set_ylabel("400 ROIs (Yeo-7 order)" if col + k == 0 else "")
# FC distributions and QC-FC
ax_h = fig.add_subplot(gs[3, 0:2]); ax_q = fig.add_subplot(gs[3, 2]); ax_d = fig.add_subplot(gs[3, 3])
for p, col, lab in (("app", APP, "app"), ("ref", REF, "fMRIPrep+nilearn")):
    raw_e = np.concatenate([np.load(D / f"fcraw_{p}_{r}.npy")[C.IU] for r in C.BOTH])
    cl_e = np.concatenate([np.load(D / f"fc_{p}_{r}.npy")[C.IU] for r in C.BOTH])
    ax_h.hist(raw_e, bins=80, histtype="step", color=col, ls="--", density=True, label=f"{lab} raw")
    ax_h.hist(cl_e, bins=80, histtype="step", color=col, density=True, label=f"{lab} denoised")
ax_h.set_xlabel("ROI–ROI r (14 runs pooled)"); ax_h.legend(frameon=False, fontsize=5.5); ax_h.set_title("FC distribution before/after", fontsize=7.5)
qq = {k: np.load(D / f"qcfc_{k}.npy") for k in ("app_raw", "app_denoised", "fMRIPrep_raw", "fMRIPrepnilearn_denoised")}
ax_q.boxplot([qq["app_raw"], qq["app_denoised"], qq["fMRIPrep_raw"], qq["fMRIPrepnilearn_denoised"]], showfliers=False,
             tick_labels=["app\nraw", "app\nclean", "fP\nraw", "fP\nclean"])
ax_q.axhline(0, c="k", lw=.5); ax_q.set_title("QC-FC (r: mean FD vs edge)", fontsize=7.5); ax_q.tick_params(labelsize=6)
dist = np.load(D / "edge_distance.npy"); sel = np.random.default_rng(1).choice(len(dist), 4000, replace=False)
for k, col in (("app_denoised", APP), ("fMRIPrepnilearn_denoised", REF)):
    b = np.digitize(dist, np.percentile(dist, np.linspace(0, 100, 11))[1:-1])
    ax_d.plot([dist[b == i].mean() for i in range(10)], [qq[k][b == i].mean() for i in range(10)], "-o", ms=2, c=col)
for k, col in (("app_raw", APP), ("fMRIPrep_raw", REF)):
    b = np.digitize(dist, np.percentile(dist, np.linspace(0, 100, 11))[1:-1])
    ax_d.plot([dist[b == i].mean() for i in range(10)], [qq[k][b == i].mean() for i in range(10)], "--", c=col, lw=.8)
ax_d.set_xlabel("ROI distance (mm)"); ax_d.set_ylabel("mean QC-FC"); ax_d.set_title("Distance dependence\n(dashed = raw)", fontsize=7.5)
fig.savefig(FIG / "Fig5_before_after_denoising.png", bbox_inches="tight"); plt.close(fig)

# ---- Fig 6: end-to-end FC + agreement vs reliability -----------------------------------------
e2e = pd.read_csv(T / "tier3_end_to_end.csv"); trt = pd.read_csv(T / "tier3_agreement_vs_retest.csv")
fig = plt.figure(figsize=(7.2, 4.8)); gs = fig.add_gridspec(2, 4)
for i, run in enumerate(["sub-04_run-1", "ds003768_sub-01__rest_run-1"]):
    fa, fb = np.load(D / f"fc_app_{run}.npy"), np.load(D / f"fc_ref_{run}.npy")
    for j, (m, lab) in enumerate([(fa, "CCS fMRI Studio"), (fb, "fMRIPrep + nilearn")]):
        a_ = fig.add_subplot(gs[i, j]); a_.imshow(m, cmap="RdBu_r", vmin=-.6, vmax=.6, interpolation="none")
        a_.set_xticks([]); a_.set_yticks([]); a_.set_title(f"{lab}\n{run.replace('ds003768_', '')}", fontsize=6.5)
a_ = fig.add_subplot(gs[0, 2]); ok = e2e.dof_app >= 30
a_.scatter(e2e.netcontrast_ref[ok], e2e.netcontrast_app[ok], c=APP, s=12, label="DOF ≥ 30")
a_.scatter(e2e.netcontrast_ref[~ok], e2e.netcontrast_app[~ok], c="#bbbbbb", s=12, label="DOF < 30")
a_.plot([.1, .35], [.1, .35], "k:", lw=.6); a_.set_xlabel("reference"); a_.set_ylabel("app"); a_.set_title("Within−between network z")
a_.legend(frameon=False, fontsize=5.5); panel(a_, "B")
a_ = fig.add_subplot(gs[0, 3])
a_.scatter(e2e.dof_app, e2e.fc_r_app_vs_ref, c=APP, s=12); a_.set_xlabel("app residual DOF"); a_.set_ylabel("FC r app vs ref")
a_.set_title("Agreement vs DOF"); panel(a_, "C")
a_ = fig.add_subplot(gs[1, 2:])
for j, (k, lab, col) in enumerate([("retest_app", "app\nrun1↔run2", APP), ("retest_ref", "fMRIPrep+nilearn\nrun1↔run2", REF),
                                   ("cross_same_run", "app↔ref\nsame run", NL), ("cross_other_run", "app↔ref\nother run", "#aaaaaa")]):
    a_.scatter(np.full(len(trt), j) + np.random.default_rng(j).uniform(-.08, .08, len(trt)), trt[k], c=col, s=14)
    a_.plot([j - .25, j + .25], [trt[k].mean()] * 2, c="k", lw=1)
a_.set_xticks(range(4)); a_.set_xticklabels(["app\nretest", "reference\nretest", "cross-pipeline\nsame run", "cross-pipeline\nother run"], fontsize=6.5)
a_.set_ylabel("FC similarity (r of z-edges)"); a_.set_title("Agreement relative to test-retest (6 external subjects)"); panel(a_, "D")
fig.tight_layout(); fig.savefig(FIG / "Fig6_end_to_end_fc.png"); plt.close(fig)

# ---- Fig 7: sleep concordance ------------------------------------------------------------------
sl = pd.read_csv(T / "bio_sleep_concordance.csv"); inc = sl[sl.included]
fig = plt.figure(figsize=(7.2, 5.4)); gs = fig.add_gridspec(2, 4)
na = np.mean([np.load(D / f"sleep_dnet_{s}_app.npy") for s in inc.subject], axis=0)
nr = np.mean([np.load(D / f"sleep_dnet_{s}_ref.npy") for s in inc.subject], axis=0)
netimshow(fig.add_subplot(gs[0, 0]), na, "CCS fMRI Studio\nΔ network FC (sleep − wake)")
im = netimshow(fig.add_subplot(gs[0, 1]), nr, "fMRIPrep + nilearn\nΔ network FC (sleep − wake)")
a_ = fig.add_subplot(gs[0, 2:])
da = np.mean([np.load(D / f"sleep_dfc_{s}_app.npy") for s in inc.subject], axis=0)
dr = np.mean([np.load(D / f"sleep_dfc_{s}_ref.npy") for s in inc.subject], axis=0)
sel = np.random.default_rng(2).choice(len(da), 8000, replace=False)
a_.scatter(dr[sel], da[sel], s=1, alpha=.3, c=APP); a_.plot([-1, 1], [-1, 1], "k:", lw=.6)
a_.set_xlim(-.8, .8); a_.set_ylim(-.8, .8); a_.set_xlabel("ΔFC reference (z)"); a_.set_ylabel("ΔFC app (z)")
a_.set_title(f"Edge-wise sleep effect, mean of {len(inc)} subjects: r = {np.corrcoef(da, dr)[0, 1]:.2f}"); panel(a_, "B")
for k, (metric, lab) in enumerate([("amp", "BOLD amplitude (% SD)"), ("acw", "ACW-0 (s)")]):
    a_ = fig.add_subplot(gs[1, k * 2:(k + 1) * 2])
    for i, s in inc.reset_index().iterrows():
        for p, col, off in (("app", APP, -.12), ("ref", REF, .12)):
            a_.plot([0 + off, 1 + off], [s[f"{metric}_W_{p}"], s[f"{metric}_S_{p}"]], "-o", c=col, ms=3, lw=.8,
                    label=("app" if p == "app" else "fMRIPrep+nilearn") if i == 0 else None)
    a_.set_xticks([0, 1]); a_.set_xticklabels(["wake", "sleep (N1+N2)"]); a_.set_ylabel(lab); a_.legend(frameon=False, fontsize=6)
    a_.set_title(f"{lab}: per subject"); panel(a_, "CD"[k])
fig.tight_layout(); fig.savefig(FIG / "Fig7_sleep_concordance.png"); plt.close(fig)

# ---- Fig 9: psilocybin ---------------------------------------------------------------------------
ps = pd.read_csv(T / "bio_psilocybin_runs.csv")
ps["cond"] = ps.run.str.split("__").str[-1]; ps["ses"] = np.where(ps.run.str.contains("pre"), "pre", "post")
fig = plt.figure(figsize=(7.8, 6.0)); gs = fig.add_gridspec(2, 4, wspace=0.55, hspace=0.6)
conds = ["rest", "movie", "music", "meditation"]
for k, (metric, lab) in enumerate([("within_net", "within-network FC (z)"), ("between_net", "between-network FC (z)"), ("acw_mean", "mean ACW-0 (s)")]):
    a_ = fig.add_subplot(gs[0, k])
    for e, col, off in (("rust", APP, -.1), ("nilearn", NL, .1)):
        for ci, c in enumerate(conds):
            pre = ps[(ps.cond == c) & (ps.ses == "pre")][f"{metric}_{e}"].values[0]
            post = ps[(ps.cond == c) & (ps.ses == "post")][f"{metric}_{e}"].values[0]
            a_.plot([ci + off, ci + off], [pre, post], c=col, lw=1)
            a_.scatter([ci + off], [pre], c="white", edgecolors=col, s=14, zorder=3)
            a_.scatter([ci + off], [post], c=col, s=14, zorder=3, label=("Rust engine" if e == "rust" else "nilearn") if ci == 0 else None)
    a_.set_xticks(range(4)); a_.set_xticklabels(conds, rotation=30, fontsize=6.5); a_.set_title(f"{lab}\n(open = pre, filled = post)", fontsize=7)
    if k == 0:
        a_.legend(frameon=False, fontsize=6)
    panel(a_, "ABC"[k])
a_ = fig.add_subplot(gs[0, 3]); cc = pd.read_csv(T / "bio_psilocybin_condition_concordance.csv")
cc2 = cc[cc.contrast.str.startswith("post")]
a_.bar(np.arange(4) - .2, cc2.dfc_r, .4, color=APP, label="edge ΔFC"); a_.bar(np.arange(4) + .2, cc2.dacw_r, .4, color=NL, label="ROI ΔACW")
a_.set_xticks(range(4)); a_.set_xticklabels(conds, rotation=30, fontsize=6.5); a_.set_ylim(0, 1); a_.legend(frameon=False, fontsize=6)
a_.set_title("Post−pre concordance\nRust vs nilearn (r)", fontsize=7); panel(a_, "D")
for j, c in enumerate(["rest", "music"]):
    netimshow(fig.add_subplot(gs[1, j * 2]), np.load(D / f"psi_dnet_{c}_rust.npy"), f"Rust engine\nΔFC post−pre, {c}", vmax=.2)
    netimshow(fig.add_subplot(gs[1, j * 2 + 1]), np.load(D / f"psi_dnet_{c}_nilearn.npy"), f"nilearn\nΔFC post−pre, {c}", vmax=.2)
fig.tight_layout(); fig.savefig(FIG / "Fig9_psilocybin_concordance.png"); plt.close(fig)

# ---- Fig 10: naturalistic conditions vs rest -------------------------------------------------------
fig, ax = plt.subplots(2, 3, figsize=(7.2, 5.0))
for j, c in enumerate(["movie", "music", "meditation"]):
    netimshow(ax[0, j], np.load(D / f"cond_dnet_{c}_rust.npy"), f"Rust: {c} − rest (pre)", vmax=.2)
    netimshow(ax[1, j], np.load(D / f"cond_dnet_{c}_nilearn.npy"), f"nilearn: {c} − rest (pre)", vmax=.2)
fig.tight_layout(); fig.savefig(FIG / "Fig10_condition_contrasts.png"); plt.close(fig)

# ---- Fig 11: runtime ---------------------------------------------------------------------------------
tb = pd.read_csv(RV / "tables/timing_benchmark.csv"); tb = tb[tb.version == "v050"].reset_index(drop=True)
st = pd.read_csv(RV / "tables/timing_stages_v050.csv")
fig, ax = plt.subplots(1, 2, figsize=(8.0, 2.6), gridspec_kw=dict(width_ratios=[1, 1.4]))
ax[0].bar(range(len(tb)), tb.wall_s / 60, color=APP, label="CCS fMRI Studio v0.5.0")
ax[0].axhline(60, c=REF, ls="--", lw=.7); ax[0].text(-.4, 57, "fMRIPrep 24.1.1 ≈ 60 min / subject (emulated)", fontsize=6, va="top")
ax[0].set_xticks(range(len(tb))); ax[0].set_xticklabels([f"{n} vols" for n in tb.n_vols]); ax[0].set_yscale("log"); ax[0].set_ylabel("minutes (log)")
ax[0].set_title("Preprocessing wall time (idle 14-core Apple Silicon)"); panel(ax[0], "A")
piv = st.pivot_table(index="stage", columns="run", values="seconds", sort=False)
left = np.zeros(piv.shape[1]); cmap = plt.get_cmap("tab20")
for i, (stg, vals) in enumerate(piv.iterrows()):
    ax[1].barh(range(piv.shape[1]), vals.values, left=left, color=cmap(i), label=stg); left += vals.values
ax[1].set_yticks(range(piv.shape[1])); ax[1].set_yticklabels([f"{n} vols" for n in tb.n_vols], fontsize=6.5); ax[1].set_xlabel("seconds")
ax[1].legend(fontsize=5, frameon=False, loc="upper left", bbox_to_anchor=(1.01, 1)); ax[1].set_title("Stage breakdown"); panel(ax[1], "B")
fig.tight_layout(); fig.savefig(FIG / "Fig11_runtime.png", bbox_inches="tight"); plt.close(fig)
print("figures done")
