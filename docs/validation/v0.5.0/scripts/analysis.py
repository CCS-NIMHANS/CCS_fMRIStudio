"""All quantitative analyses for the CCS fMRI Studio v0.5.0 validation report.

Writes tables to ../tables and intermediate arrays to ../data (consumed by figures.py).
Environment: CCS_SCRATCH (work area with app + fMRIPrep derivatives), CCS_VALDATA (validation data).
"""
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

import common as C

R = Path(__file__).resolve().parents[1]
T, D = R / "tables", R / "data"
T.mkdir(exist_ok=True); D.mkdir(exist_ok=True)
rng = np.random.default_rng(0)

# ============================================================================================
# 1. Tier 2 - time-series / connectivity engine vs nilearn on identical inputs
# ============================================================================================
rows = []
for run in C.EXT + C.OWN:
    a = C.load_app(run)
    r = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"])
    rc = r["clean"][r["kept"]]
    row = dict(run=run, input="app preprocessing", dof=r["dof"], n_kept=len(r["kept"]))
    if r["dof"] >= 3:
        ne = C.nilearn_equiv(a["raw"], a["conf"], a["scrub"], a["tr"])
        ns = C.nilearn_std(a["raw"], a["conf"], a["scrub"], a["tr"])
        row.update(max_abs_diff_equiv=float(np.abs(rc - ne).max()), fc_r_equiv=C.tri_r(C.fc(rc), C.fc(ne)),
                   fc_r_std=C.tri_r(C.fc(rc), C.fc(ns)))
    rows.append(row)
    b = C.load_ref(run)
    if b is not None:
        r2 = C.rust_clean(b["raw"], b["conf"], b["scrub"], b["tr"])
        rc2 = r2["clean"][r2["kept"]]
        ne2 = C.nilearn_equiv(b["raw"], b["conf"], b["scrub"], b["tr"])
        ns2 = C.nilearn_std(b["raw"], b["conf"], b["scrub"], b["tr"])
        rows.append(dict(run=run, input="fMRIPrep preprocessing", dof=r2["dof"], n_kept=len(r2["kept"]),
                         max_abs_diff_equiv=float(np.abs(rc2 - ne2).max()), fc_r_equiv=C.tri_r(C.fc(rc2), C.fc(ne2)),
                         fc_r_std=C.tri_r(C.fc(rc2), C.fc(ns2))))
    print("tier2", run, flush=True)
t2 = pd.DataFrame(rows); t2.to_csv(T / "tier2_engine_vs_nilearn.csv", index=False)

# ACW engine parity: Rust dynamics vs numpy ACF on the same high-pass series
par = []
for run in ["sub-02_run-1", "ds003768_sub-01__rest_run-2", "ds006110_sub-PC001__ses-01_pre__rest"]:
    a = C.load_app(run)
    win = min(130, max(24, a["raw"].shape[0] // 2))
    r = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"], dyn_window=win)
    hp = r["hp"]
    py = np.array([np.nanmean([C.acw0(hp[s:s + win, j], a["tr"]) for s in range(0, hp.shape[0] - win + 1, win)])
                   for j in range(400)])
    par.append(dict(run=run, window=win, acw0_r=float(np.corrcoef(py, r["dyn"][:, 0])[0, 1]),
                    acw0_max_abs_diff_s=float(np.nanmax(np.abs(py - r["dyn"][:, 0])))))
pd.DataFrame(par).to_csv(T / "tier2_dynamics_parity.csv", index=False)

# ============================================================================================
# 2. Tier 3 - end-to-end app vs fMRIPrep + nilearn (default settings) and denoising QC
# ============================================================================================
e2e, qc_raw_app, qc_cl_app, qc_raw_ref, qc_cl_ref, mfd_app, mfd_ref = [], [], [], [], [], [], []
hist = {}
for run in C.BOTH:
    a, b = C.load_app(run), C.load_ref(run)
    ra = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"])
    ca = ra["clean"][ra["kept"]]
    cb = C.nilearn_std(b["raw"], b["conf"], b["scrub"], b["tr"])
    fa, fb = C.fc(ca), C.fc(cb)
    fa_raw, fb_raw = C.fc(a["raw"]), C.fc(b["raw"])
    e2e.append(dict(run=run, dof_app=ra["dof"], fc_r_app_vs_ref=C.tri_r(fa, fb), fc_r_raw_app_vs_raw_ref=C.tri_r(fa_raw, fb_raw),
                    netcontrast_app=C.network_contrast(fa), netcontrast_ref=C.network_contrast(fb),
                    netmat_r=float(np.corrcoef(C.network_matrix(fa).ravel(), C.network_matrix(fb).ravel())[0, 1]),
                    mean_fc_app=float(fa[C.IU].mean()), mean_fc_ref=float(fb[C.IU].mean()),
                    mean_fc_raw_app=float(fa_raw[C.IU].mean()), mean_fc_raw_ref=float(fb_raw[C.IU].mean())))
    qc_raw_app.append(C.ztri(fa_raw)); qc_cl_app.append(C.ztri(fa)); qc_raw_ref.append(C.ztri(fb_raw)); qc_cl_ref.append(C.ztri(fb))
    mfd_app.append(a["fd"].mean()); mfd_ref.append(b["fd"].mean())
    np.save(D / f"fc_app_{run}.npy", fa.astype(np.float32)); np.save(D / f"fc_ref_{run}.npy", fb.astype(np.float32))
    np.save(D / f"fcraw_app_{run}.npy", fa_raw.astype(np.float32)); np.save(D / f"fcraw_ref_{run}.npy", fb_raw.astype(np.float32))
    if run == "sub-07_run-1":  # representative high-motion run for carpet plots
        np.savez(D / "carpet_sub-07_run-1.npz", app_raw=a["raw"], app_clean=ra["clean"], app_kept=ra["kept"], app_fd=a["fd"],
                 ref_raw=b["raw"], ref_clean=cb, ref_keep=np.setdiff1d(np.arange(len(b["fd"])), b["scrub"]), ref_fd=b["fd"])
    print("e2e", run, flush=True)
pd.DataFrame(e2e).to_csv(T / "tier3_end_to_end.csv", index=False)

# QC-FC: across-run correlation between mean FD and each edge (Ciric et al. 2017), before/after
cent = None
from nilearn import datasets  # noqa: E402
import nibabel as nib  # noqa: E402
atl = nib.load(datasets.fetch_atlas_schaefer_2018(n_rois=400, resolution_mm=2, verbose=0).maps)
A = atl.get_fdata().astype(int)
cent = np.array([np.argwhere(A == i).mean(0) for i in range(1, 401)]) @ atl.affine[:3, :3].T
dist = np.sqrt(((cent[:, None] - cent[None]) ** 2).sum(-1))[C.IU]
qc = []
for name, edges, mfd in [("app raw", qc_raw_app, mfd_app), ("app denoised", qc_cl_app, mfd_app),
                         ("fMRIPrep raw", qc_raw_ref, mfd_ref), ("fMRIPrep+nilearn denoised", qc_cl_ref, mfd_ref)]:
    E = np.array(edges)
    r = np.array([stats.pearsonr(mfd, E[:, k])[0] for k in range(E.shape[1])])
    p = np.array([stats.pearsonr(mfd, E[:, k])[1] for k in range(E.shape[1])])
    np.save(D / f"qcfc_{name.replace(' ', '_').replace('+', '')}.npy", r.astype(np.float32))
    qc.append(dict(pipeline=name, n_runs=len(mfd), median_abs_qcfc=float(np.median(np.abs(r))), pct_edges_p05=float((p < 0.05).mean() * 100),
                   qcfc_distance_rho=float(stats.spearmanr(r, dist)[0])))
pd.DataFrame(qc).to_csv(T / "denoising_qcfc.csv", index=False)
np.save(D / "edge_distance.npy", dist.astype(np.float32))

# Test-retest vs agreement (external subjects)
tr_rows = []
for s in ("02", "03", "04", "05", "06", "07"):
    k1, k2 = f"sub-{s}_run-1", f"sub-{s}_run-2"
    g = lambda p, k: C.ztri(np.load(D / f"fc_{p}_{k}.npy"))
    cr = lambda x, y: float(np.corrcoef(x, y)[0, 1])
    tr_rows.append(dict(subject=f"sub-{s}", retest_app=cr(g("app", k1), g("app", k2)), retest_ref=cr(g("ref", k1), g("ref", k2)),
                        cross_same_run=np.mean([cr(g("app", k), g("ref", k)) for k in (k1, k2)]),
                        cross_other_run=np.mean([cr(g("app", k1), g("ref", k2)), cr(g("app", k2), g("ref", k1))])))
pd.DataFrame(tr_rows).to_csv(T / "tier3_agreement_vs_retest.csv", index=False)

# ============================================================================================
# 3. Biological concordance - sleep stage (ds003768)
#    Settings (both pipelines): nuisance + FD>0.5 censoring + high-pass 0.008 Hz (no low-pass,
#    preserving DOF); stage per volume from the official 30-s scoring; Wake vs Sleep (N1+N2).
# ============================================================================================
def stage_fc(ts_clean, kept, stages, groups):
    out = {}
    for gname, labs in groups.items():
        idx = np.array([k for k in kept if stages[k] in labs])
        out[gname] = (idx, ts_clean[idx] if len(idx) else None)
    return out


def window_acw(hp, stages, labs, tr, win):
    vals = []
    for s0 in range(0, hp.shape[0] - win + 1, win // 2):
        if all(stages[k] in labs for k in range(s0, s0 + win)):
            vals.append([C.acw0(hp[s0:s0 + win, j], tr) for j in range(hp.shape[1])])
    return np.nanmean(np.array(vals), axis=0) if vals else None, len(vals)


def amp(raw, idx, tr):
    from nilearn import signal as sg
    x = sg.clean(raw, detrend=True, standardize=None, high_pass=0.008, t_r=tr, filter="cosine")
    return (x[idx].std(0) / np.abs(raw.mean(0))) * 100  # % signal change SD per ROI


groups = {"W": {"W"}, "S": {"N1", "N2"}}
subj_runs = {f"sub-{s}": [f"sub-{s}_run-1", f"sub-{s}_run-2"] for s in ("02", "03", "04", "05", "06", "07")}
subj_runs["sub-01"] = ["ds003768_sub-01__rest_run-1"]
sleep_rows, sleep_mats = [], {}
for subj, runs in subj_runs.items():
    per = {"app": {"W": [], "S": []}, "ref": {"W": [], "S": []}}
    ampd = {"app": {"W": [], "S": []}, "ref": {"W": [], "S": []}}
    acwd = {"app": {"W": [], "S": []}, "ref": {"W": [], "S": []}}
    for run in runs:
        a, b = C.load_app(run), C.load_ref(run)
        nt = a["raw"].shape[0]
        st = C.stages_for(run, nt, a["tr"])
        ra = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"], lo=0.008, hi=None, dyn_window=28)
        keep_b = np.setdiff1d(np.arange(nt), b["scrub"])
        from nilearn import signal as sg
        cb_full = sg.clean(b["raw"], confounds=b["conf"], detrend=True, standardize="zscore_sample", high_pass=0.008,
                           t_r=b["tr"], filter="butterworth")  # uncensored, for ACW windows
        cb = sg.clean(b["raw"], confounds=b["conf"], detrend=True, standardize="zscore_sample", sample_mask=keep_b,
                      high_pass=0.008, t_r=b["tr"], filter="butterworth")
        cb_on_full = np.full((nt, 400), np.nan); cb_on_full[keep_b] = cb
        for gname, labs in groups.items():
            ia = np.array([k for k in ra["kept"] if st[k] in labs], int)
            ib = np.array([k for k in keep_b if st[k] in labs], int)
            if len(ia):
                per["app"][gname].append(ra["clean"][ia]); ampd["app"][gname].append((len(ia), amp(a["raw"], ia, a["tr"])))
            if len(ib):
                per["ref"][gname].append(cb_on_full[ib]); ampd["ref"][gname].append((len(ib), amp(b["raw"], ib, b["tr"])))
            for pname, hp in (("app", ra["hp"]), ("ref", cb_full)):
                v, n = window_acw(hp, st, labs, a["tr"], 28)
                if v is not None:
                    acwd[pname][gname].append((n, v))
    res = dict(subject=subj)
    ok = True
    for p in ("app", "ref"):
        for g in ("W", "S"):
            n = sum(x.shape[0] for x in per[p][g])
            res[f"n_{p}_{g}"] = n
            ok &= n >= 40
    if ok:
        for p in ("app", "ref"):
            fw = C.fc(np.vstack(per[p]["W"])); fs = C.fc(np.vstack(per[p]["S"]))
            sleep_mats[(subj, p)] = (fw, fs)
            res[f"amp_W_{p}"] = float(np.average([v.mean() for _, v in ampd[p]["W"]], weights=[n for n, _ in ampd[p]["W"]]))
            res[f"amp_S_{p}"] = float(np.average([v.mean() for _, v in ampd[p]["S"]], weights=[n for n, _ in ampd[p]["S"]]))
            if acwd[p]["W"] and acwd[p]["S"]:
                aw = np.average([v for _, v in acwd[p]["W"]], axis=0, weights=[n for n, _ in acwd[p]["W"]])
                as_ = np.average([v for _, v in acwd[p]["S"]], axis=0, weights=[n for n, _ in acwd[p]["S"]])
                res[f"acw_W_{p}"], res[f"acw_S_{p}"] = float(np.nanmean(aw)), float(np.nanmean(as_))
                np.save(D / f"sleep_dacw_{subj}_{p}.npy", (as_ - aw).astype(np.float32))
            np.save(D / f"sleep_dfc_{subj}_{p}.npy", (C.ztri(fs) - C.ztri(fw)).astype(np.float32))
            np.save(D / f"sleep_dnet_{subj}_{p}.npy", (C.network_matrix(fs) - C.network_matrix(fw)).astype(np.float32))
        da, dr = np.load(D / f"sleep_dfc_{subj}_app.npy"), np.load(D / f"sleep_dfc_{subj}_ref.npy")
        res["dfc_r_app_vs_ref"] = float(np.corrcoef(da, dr)[0, 1])
        na, nr = np.load(D / f"sleep_dnet_{subj}_app.npy"), np.load(D / f"sleep_dnet_{subj}_ref.npy")
        res["dnet_r_app_vs_ref"] = float(np.corrcoef(na.ravel(), nr.ravel())[0, 1])
        if (D / f"sleep_dacw_{subj}_app.npy").exists() and (D / f"sleep_dacw_{subj}_ref.npy").exists():
            res["dacw_r_app_vs_ref"] = float(np.corrcoef(np.load(D / f"sleep_dacw_{subj}_app.npy"),
                                                          np.load(D / f"sleep_dacw_{subj}_ref.npy"))[0, 1])
    res["included"] = ok
    sleep_rows.append(res)
    print("sleep", subj, ok, flush=True)
sl = pd.DataFrame(sleep_rows); sl.to_csv(T / "bio_sleep_concordance.csv", index=False)

# sub-01 within-subject, app engine vs nilearn on app preprocessing (all 5 runs incl. sleep runs)
own_rows = []
per = {"rust": {"W": [], "S": []}, "nilearn": {"W": [], "S": []}}
for run in [r for r in C.OWN if r.startswith("ds003768")]:
    a = C.load_app(run); nt = a["raw"].shape[0]; st = C.stages_for(run, nt, a["tr"])
    ra = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"], lo=0.008, hi=None)
    keep = np.setdiff1d(np.arange(nt), a["scrub"])
    from nilearn import signal as sg
    cn = np.full((nt, 400), np.nan)
    cn[keep] = sg.clean(a["raw"], confounds=a["conf"], detrend=True, standardize="zscore_sample", sample_mask=keep,
                        high_pass=0.008, t_r=a["tr"], filter="butterworth")
    for g, labs in groups.items():
        per["rust"][g].append(ra["clean"][[k for k in ra["kept"] if st[k] in labs]])
        per["nilearn"][g].append(cn[[k for k in keep if st[k] in labs]])
for p in per:
    fw, fs = C.fc(np.vstack(per[p]["W"])), C.fc(np.vstack(per[p]["S"]))
    np.save(D / f"sleep_dnet_sub01all_{p}.npy", (C.network_matrix(fs) - C.network_matrix(fw)).astype(np.float32))
    np.save(D / f"sleep_dfc_sub01all_{p}.npy", (C.ztri(fs) - C.ztri(fw)).astype(np.float32))
    own_rows.append(dict(engine=p, n_W=sum(len(x) for x in per[p]["W"]), n_S=sum(len(x) for x in per[p]["S"]),
                         netcontrast_W=C.network_contrast(fw), netcontrast_S=C.network_contrast(fs)))
pd.DataFrame(own_rows).to_csv(T / "bio_sleep_sub01_engines.csv", index=False)

# ============================================================================================
# 4. Biological concordance - psilocybin session and naturalistic condition (ds006110 PsiConnect)
#    Reference: nilearn on identical app-preprocessed ROI data (fMRIPrep derivatives exist only
#    for the pre-session rest run). Same high-pass-only settings.
# ============================================================================================
psi_fc, psi_acw, psi_rows = {}, {}, []
for run in [r for r in C.OWN if r.startswith("ds006110")]:
    a = C.load_app(run); nt = a["raw"].shape[0]
    ra = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"], lo=0.008, hi=None, dyn_window=min(130, nt // 2))
    keep = np.setdiff1d(np.arange(nt), a["scrub"])
    from nilearn import signal as sg
    cn = sg.clean(a["raw"], confounds=a["conf"], detrend=True, standardize="zscore_sample", sample_mask=keep,
                  high_pass=0.008, t_r=a["tr"], filter="butterworth")
    cn_full = sg.clean(a["raw"], confounds=a["conf"], detrend=True, standardize="zscore_sample", high_pass=0.008, t_r=a["tr"], filter="butterworth")
    win = min(130, nt // 2)
    acw_np = np.array([np.nanmean([C.acw0(cn_full[s:s + win, j], a["tr"]) for s in range(0, nt - win + 1, win)]) for j in range(400)])
    psi_fc[(run, "rust")] = C.fc(ra["clean"][ra["kept"]]); psi_fc[(run, "nilearn")] = C.fc(cn)
    psi_acw[(run, "rust")] = ra["dyn"][:, 0]; psi_acw[(run, "nilearn")] = acw_np
    psi_rows.append(dict(run=run, dof=ra["dof"], n_kept=len(ra["kept"]), mean_fd=float(a["fd"].mean()),
                         fc_r_rust_vs_nilearn=C.tri_r(psi_fc[(run, "rust")], psi_fc[(run, "nilearn")]),
                         acw_r_rust_vs_nilearn=float(np.corrcoef(psi_acw[(run, "rust")], acw_np)[0, 1]),
                         within_net_rust=float(np.nanmean(np.diag(C.network_matrix(psi_fc[(run, 'rust')])))),
                         between_net_rust=float(np.nanmean(C.network_matrix(psi_fc[(run, 'rust')])[~np.eye(7, dtype=bool)])),
                         within_net_nilearn=float(np.nanmean(np.diag(C.network_matrix(psi_fc[(run, 'nilearn')])))),
                         between_net_nilearn=float(np.nanmean(C.network_matrix(psi_fc[(run, 'nilearn')])[~np.eye(7, dtype=bool)])),
                         acw_mean_rust=float(np.nanmean(psi_acw[(run, 'rust')])), acw_mean_nilearn=float(np.nanmean(acw_np))))
    print("psi", run, flush=True)
pd.DataFrame(psi_rows).to_csv(T / "bio_psilocybin_runs.csv", index=False)
contr = []
for cond in ("rest", "movie", "music", "meditation"):
    pre, post = f"ds006110_sub-PC001__ses-01_pre__{cond}", f"ds006110_sub-PC001__ses-02_post__{cond}"
    for e in ("rust", "nilearn"):
        d = C.ztri(psi_fc[(post, e)]) - C.ztri(psi_fc[(pre, e)])
        np.save(D / f"psi_dfc_{cond}_{e}.npy", d.astype(np.float32))
        np.save(D / f"psi_dnet_{cond}_{e}.npy", (C.network_matrix(psi_fc[(post, e)]) - C.network_matrix(psi_fc[(pre, e)])).astype(np.float32))
        np.save(D / f"psi_dacw_{cond}_{e}.npy", (psi_acw[(post, e)] - psi_acw[(pre, e)]).astype(np.float32))
    contr.append(dict(contrast=f"post-pre {cond}",
                      dfc_r=float(np.corrcoef(np.load(D / f"psi_dfc_{cond}_rust.npy"), np.load(D / f"psi_dfc_{cond}_nilearn.npy"))[0, 1]),
                      dnet_r=float(np.corrcoef(np.load(D / f"psi_dnet_{cond}_rust.npy").ravel(), np.load(D / f"psi_dnet_{cond}_nilearn.npy").ravel())[0, 1]),
                      dacw_r=float(np.corrcoef(np.load(D / f"psi_dacw_{cond}_rust.npy"), np.load(D / f"psi_dacw_{cond}_nilearn.npy"))[0, 1])))
for cond in ("movie", "music", "meditation"):
    base, c = "ds006110_sub-PC001__ses-01_pre__rest", f"ds006110_sub-PC001__ses-01_pre__{cond}"
    for e in ("rust", "nilearn"):
        np.save(D / f"cond_dnet_{cond}_{e}.npy", (C.network_matrix(psi_fc[(c, e)]) - C.network_matrix(psi_fc[(base, e)])).astype(np.float32))
        np.save(D / f"cond_dfc_{cond}_{e}.npy", (C.ztri(psi_fc[(c, e)]) - C.ztri(psi_fc[(base, e)])).astype(np.float32))
    contr.append(dict(contrast=f"{cond}-rest (pre)",
                      dfc_r=float(np.corrcoef(np.load(D / f"cond_dfc_{cond}_rust.npy"), np.load(D / f"cond_dfc_{cond}_nilearn.npy"))[0, 1]),
                      dnet_r=float(np.corrcoef(np.load(D / f"cond_dnet_{cond}_rust.npy").ravel(), np.load(D / f"cond_dnet_{cond}_nilearn.npy").ravel())[0, 1])))
pd.DataFrame(contr).to_csv(T / "bio_psilocybin_condition_concordance.csv", index=False)

# end-to-end on the one PsiConnect run with fMRIPrep derivatives (pre-session rest), same settings
a, b = C.load_app("ds006110_sub-PC001__ses-01_pre__rest"), C.load_ref("ds006110_sub-PC001__ses-01_pre__rest")
ra = C.rust_clean(a["raw"], a["conf"], a["scrub"], a["tr"], lo=0.008, hi=None)
from nilearn import signal as sg  # noqa: E402
keep_b = np.setdiff1d(np.arange(len(b["fd"])), b["scrub"])
cb = sg.clean(b["raw"], confounds=b["conf"], detrend=True, standardize="zscore_sample", sample_mask=keep_b, high_pass=0.008, t_r=b["tr"], filter="butterworth")
json.dump(dict(fc_r=C.tri_r(C.fc(ra["clean"][ra["kept"]]), C.fc(cb)),
               netmat_r=float(np.corrcoef(C.network_matrix(C.fc(ra["clean"][ra["kept"]])).ravel(), C.network_matrix(C.fc(cb)).ravel())[0, 1])),
          open(T / "bio_psilocybin_pre_rest_end_to_end.json", "w"), indent=1)
print("done")
