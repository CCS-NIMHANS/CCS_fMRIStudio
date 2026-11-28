"""Per-subject visual QC report (fMRIPrep-style "glass box") for CCS_fMRIStudio preprocessing.

Writes a single self-contained `qc_report.html` (figures embedded as PNG) with:
  * run summary, QC metrics and warnings,
  * T1w -> MNI alignment (template brain outline + template edges),
  * aCompCor WM / CSF masks,
  * mean BOLD -> MNI alignment,
  * head motion (6 parameters), FD and DVARS,
  * carpet plot (GM / WM / CSF voxels) with FD,
  * per-parcel EPI coverage,
  * an auto-generated methods paragraph with software versions and references.
"""

from __future__ import annotations

import base64
import html
import io
import platform
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from scipy import ndimage  # noqa: E402


def _png(fig) -> str:
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=110, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return base64.b64encode(buf.getvalue()).decode()


def _slices(vol: np.ndarray, n: int = 7) -> list[int]:
    nz = vol.shape[2]
    return list(np.linspace(int(nz * 0.2), int(nz * 0.8), n).astype(int))


def _mosaic(base: np.ndarray, outline: np.ndarray | None = None, overlays: list | None = None, title: str = "",
            edges: np.ndarray | None = None) -> str:
    zs = _slices(base)
    fig, axes = plt.subplots(1, len(zs), figsize=(2.0 * len(zs), 2.4))
    vmax = np.percentile(base[base > 0], 99) if np.any(base > 0) else 1
    for ax, z in zip(axes, zs):
        ax.imshow(np.rot90(base[:, :, z]), cmap="gray", vmin=0, vmax=vmax)
        if edges is not None:
            ax.contour(np.rot90(edges[:, :, z]).astype(float), [0.5], colors="magenta", linewidths=0.4)
        if outline is not None:
            ax.contour(np.rot90(outline[:, :, z]).astype(float), [0.5], colors="gold", linewidths=0.7)
        for ov, cmap in overlays or []:
            sl = np.rot90(ov[:, :, z])
            ax.imshow(np.ma.masked_where(~sl, sl), cmap=cmap, alpha=0.7, interpolation="none")
        ax.set_title(f"z={z}", fontsize=7)
        ax.axis("off")
    fig.suptitle(title, fontsize=9)
    return _png(fig)


def _template_edges(tpl: np.ndarray, brain: np.ndarray) -> np.ndarray:
    t = ndimage.gaussian_filter(tpl.astype(float), 1.0)
    g = np.sqrt(sum(ndimage.sobel(t, axis=a) ** 2 for a in range(3)))
    thr = np.percentile(g[brain], 90)
    return (g > thr) & brain


def write_qc_report(out_dir: Path, report: dict, t1_mni: np.ndarray, tpl: np.ndarray, tpl_brain: np.ndarray,
                    brain_mni: np.ndarray, wm_mni: np.ndarray, csf_mni: np.ndarray, gm_mni: np.ndarray,
                    bold_arr: np.ndarray, confounds: pd.DataFrame, coverage: pd.DataFrame, versions: dict) -> Path:
    edges = _template_edges(tpl, tpl_brain)
    figs: list[tuple[str, str, str]] = []
    figs.append(("Spatial normalisation (T1w → MNI152NLin6Asym)",
                 _mosaic(t1_mni, tpl_brain, title="T1w in MNI space; gold = template brain outline, magenta = template edges",
                         edges=edges),
                 "Subject anatomy should fill the gold outline, with magenta template edges following sulci, ventricles "
                 "and the cortical boundary. Skull or scalp inside the outline indicates failed brain extraction."))
    figs.append(("aCompCor tissue masks",
                 _mosaic(t1_mni, brain_mni, [(wm_mni, "winter"), (csf_mni, "autumn")],
                         "blue = WM mask, red = CSF mask (eroded, used for aCompCor)"),
                 "WM must sit in deep white matter and CSF in the ventricles; neither may touch grey matter or the scalp."))
    mean_bold = bold_arr.mean(axis=-1)
    figs.append(("Functional alignment (mean BOLD → MNI)",
                 _mosaic(mean_bold, tpl_brain, title="mean BOLD in MNI; gold = template brain outline", edges=edges),
                 "Signal dropout (orbitofrontal/temporal poles) is expected; global shifts or scaling are not."))

    # motion / FD / DVARS
    fd = confounds["framewise_displacement"].to_numpy()
    vox = bold_arr[brain_mni]
    dv = np.r_[0, np.sqrt(np.mean(np.diff(vox, axis=1) ** 2, axis=0))]
    dv = dv / (np.median(dv[1:]) + 1e-12)
    fig, ax = plt.subplots(3, 1, figsize=(10, 4.6), sharex=True)
    for c in ("trans_x", "trans_y", "trans_z"):
        ax[0].plot(confounds[c], lw=0.7, label=c)
    ax[0].set_ylabel("mm"); ax[0].legend(fontsize=6, ncol=3, frameon=False)
    for c in ("rot_x", "rot_y", "rot_z"):
        ax[1].plot(np.degrees(confounds[c]), lw=0.7, label=c)
    ax[1].set_ylabel("deg"); ax[1].legend(fontsize=6, ncol=3, frameon=False)
    ax[2].plot(fd, c="k", lw=0.7, label="FD (mm)"); ax[2].axhline(0.5, c="r", ls=":", lw=0.7)
    ax2 = ax[2].twinx(); ax2.plot(dv, c="tab:blue", lw=0.5, alpha=0.7); ax2.set_ylabel("rel. DVARS", color="tab:blue")
    ax[2].set_ylabel("FD (mm)"); ax[2].set_xlabel("volume")
    figs.append(("Head motion", _png(fig),
                 f"Mean FD {fd.mean():.3f} mm, max {fd.max():.2f} mm, {int((fd > 0.5).sum())} volumes with FD > 0.5 mm "
                 f"(red line). FD–DVARS r = {np.corrcoef(fd[1:], dv[1:])[0, 1]:.2f}."))

    # carpet plot
    rng = np.random.default_rng(0)
    rows, bounds = [], []
    for msk in (gm_mni & brain_mni, wm_mni, csf_mni):
        idx = np.argwhere(msk)
        if len(idx) > 1500:
            idx = idx[rng.choice(len(idx), 1500, replace=False)]
        ts = bold_arr[idx[:, 0], idx[:, 1], idx[:, 2], :].astype(np.float64)
        ts = ts - ts.mean(1, keepdims=True)
        t = np.arange(ts.shape[1])
        ts = ts - np.outer(ts @ (t - t.mean()) / ((t - t.mean()) ** 2).sum(), t - t.mean())
        ts /= ts.std(1, keepdims=True) + 1e-9
        rows.append(ts); bounds.append(len(ts))
    carpet = np.vstack(rows)
    fig, ax = plt.subplots(2, 1, figsize=(10, 4.4), gridspec_kw=dict(height_ratios=[1, 4]), sharex=True)
    ax[0].plot(fd, c="k", lw=0.7); ax[0].axhline(0.5, c="r", ls=":", lw=0.7); ax[0].set_ylabel("FD")
    ax[1].imshow(carpet, aspect="auto", cmap="gray", vmin=-2, vmax=2, interpolation="none")
    for b in np.cumsum(bounds)[:-1]:
        ax[1].axhline(b, c="orange", lw=0.8)
    ax[1].set_yticks(np.cumsum(bounds) - np.array(bounds) / 2); ax[1].set_yticklabels(["GM", "WM", "CSF"])
    ax[1].set_xlabel("volume")
    figs.append(("Carpet plot (minimally preprocessed BOLD)", _png(fig),
                 "Vertical bands spanning all tissue classes at high-FD volumes indicate motion artefacts that "
                 "denoising must remove."))

    fig, ax = plt.subplots(figsize=(6, 2.2))
    ax.hist(coverage["epi_coverage"], bins=40, color="#00798c")
    ax.axvline(0.5, c="r", ls=":"); ax.set_xlabel("fraction of parcel inside EPI signal mask"); ax.set_ylabel("parcels")
    low = coverage[coverage["epi_coverage"] < 0.5]
    figs.append(("Schaefer-400 parcel EPI coverage", _png(fig),
                 f"{len(low)} parcel(s) with < 50 % coverage" + (": " + ", ".join(low["label"].astype(str).head(12)) if len(low) else ".")))

    qc = report["qc"]
    stc = qc["slice_timing"]
    methods = (
        f"Preprocessing was performed with CCS fMRI Studio {report['pipeline_version']} (ANTsPy {versions.get('antspy')}, "
        f"nilearn {versions.get('nilearn')}, Python {platform.python_version()}). The T1w image was corrected for intensity "
        "non-uniformity (N4; Tustison et al., 2010) and skull-stripped by nonlinear (SyN) registration of the whole-head image "
        "to the MNI152NLin6Asym template and back-projection of the template brain mask. Brain tissue was segmented into CSF, "
        "GM and WM with Atropos (Avants et al., 2011) on the skull-stripped, intensity-winsorised image. The brain-extracted "
        "T1w was normalised to MNI152NLin6Asym (antsRegistrationSyNQuick; Avants et al., 2008). "
        + (f"BOLD slice-timing was corrected to the mid-acquisition time ({stc.get('reference_time_s', 0):.2f} s) by Fourier "
           "phase shifting. " if stc.get("applied") else "No slice-timing correction was applied. ")
        + "Head motion was estimated by rigid registration of every volume to the mean BOLD image with per-volume quality "
        "control; framewise displacement was computed after Power et al. (2012). The BOLD reference was rigidly co-registered "
        "to the skull-stripped T1w, and motion, co-registration and normalisation transforms were composed and applied in a "
        "single interpolation step onto the 2 mm MNI152NLin6Asym grid. Eroded WM and ventricular CSF masks were projected to "
        "MNI space for aCompCor (Behzadi et al., 2007). The Schaefer-400 7-network atlas (Schaefer et al., 2018) was used in "
        "its native FSL MNI152 2 mm space."
    )
    rows_html = "".join(f"<tr><th>{html.escape(str(k))}</th><td>{html.escape(str(v))}</td></tr>" for k, v in [
        ("BOLD", report["bold_input"]), ("T1w", report["t1_input"]), ("TR (s)", report["tr_sec"]),
        ("volumes", report["bold_raw_shape"][-1]), ("output space", report["output_space"]),
        ("T1w–template r (brain)", f"{qc['t1w_mni_vs_template_r_in_brain']:.3f}"),
        ("brain-mask Dice vs template", f"{qc['brain_mask_dice_vs_template']:.3f}"),
        ("tissue volumes (mL)", {k: round(v) for k, v in qc["t1_tissue_volumes_ml"].items()}),
        ("WM / CSF aCompCor voxels", f"{qc['wm_mask_voxels_mni']} / {qc['csf_mask_voxels_mni']}"),
        ("slice timing", stc), ("motion estimation", qc.get("motion_estimation")),
        ("mean / max FD (mm)", f"{report['mean_fd_mm']:.3f} / {report['max_fd_mm']:.2f}"),
        ("runtime (s)", report["total_seconds"]),
    ])
    warn = "".join(f"<li>{html.escape(w)}</li>" for w in report.get("warnings", [])) or "<li>none</li>"
    sections = "".join(
        f"<h2>{html.escape(t)}</h2><img src='data:image/png;base64,{b}'/><p class='cap'>{html.escape(c)}</p>"
        for t, b, c in figs)
    doc = f"""<!doctype html><html><head><meta charset='utf-8'><title>CCS fMRI Studio QC</title>
<style>body{{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:1150px;margin:1.5em auto;color:#222}}
table{{border-collapse:collapse;font-size:13px}}th,td{{border:1px solid #ddd;padding:3px 8px;text-align:left;vertical-align:top}}
th{{background:#f4f4f4;width:240px}}img{{max-width:100%}}.cap{{color:#555;font-size:13px}}h2{{border-bottom:1px solid #ddd;padding-bottom:3px}}
.warn{{background:#fff4e5;border-left:4px solid #f0a020;padding:4px 12px}}</style></head><body>
<h1>CCS fMRI Studio preprocessing QC</h1><table>{rows_html}</table>
<div class='warn'><b>Warnings</b><ul>{warn}</ul></div>{sections}
<h2>Methods (auto-generated)</h2><p>{html.escape(methods)}</p>
<p class='cap'>References: Avants et al. 2008 Med Image Anal 12:26; Avants et al. 2011 Neuroinformatics 9:381; Behzadi et al. 2007
NeuroImage 37:90; Power et al. 2012 NeuroImage 59:2142; Schaefer et al. 2018 Cereb Cortex 28:3095; Tustison et al. 2010 IEEE TMI 29:1310.</p>
</body></html>"""
    path = out_dir / "qc_report.html"
    path.write_text(doc, encoding="utf-8")
    return path
