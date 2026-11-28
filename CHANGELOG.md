# Changelog

All notable changes to **CCS_fMRIStudio** are documented in this file.

## [0.5.0] - 2026-11-28

Validity release following an external code review and benchmark against fMRIPrep 24.1.1 + nilearn
(report: [`docs/validation/v0.5.0/REPORT.md`](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/blob/v0.5.0/docs/validation/v0.5.0/REPORT.md) · [PDF](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/blob/v0.5.0/docs/validation/v0.5.0/REPORT.pdf)). Results from v0.4.1 preprocessing should be regenerated.

### Fixed (preprocessing, `python_sidecar/src/ccs_fmri_sidecar/preprocess.py`)
- **Brain extraction added.** v0.4.1 registered the whole-head T1w to a skull-stripped template, compressing the
  head into the template brain (T1w-template r ≈ 0.02–0.10). The T1w is now skull-stripped by head-to-head SyN to
  MNI152NLin6Asym and back-warping the template brain mask; normalisation is brain-to-brain (r ≈ 0.74–0.80,
  brain-mask Dice ≈ 0.99, on par with fMRIPrep).
- **Tissue masks for aCompCor.** Atropos now runs on the skull-stripped, intensity-winsorised brain; WM (P>0.9, eroded)
  and ventricular CSF (P>0.9, ≥5 mm from the brain edge) masks replace the v0.4.1 masks that were mostly grey matter
  ("CSF") and scalp ("WM"), which had turned aCompCor into an undisclosed global-signal regression.
- **Template/atlas space.** Default space is MNI152NLin6Asym (TemplateFlow), the native space of the nilearn
  Schaefer-2018 atlas, so the atlas is no longer applied to a different template (v0.4.1 used nilearn's 2009a
  symmetric template while labelling it MNI152NLin2009cAsym).
- **Slice-timing correction** (Fourier phase shift to mid-TR) when `SliceTiming` is present.
- **True single interpolation:** motion, coregistration and normalisation transforms are composed per volume.
- **Motion estimation rewritten:** per-volume rigid registration to the mean BOLD with quality control (registered
  volume must match the reference at least as well as the unregistered one, displacement must be plausible), up to 8
  attempts with alternative settings in fresh worker processes, and a hard error if any volume still fails. ANTs'
  `motion_correction` (used in v0.4.1) diverged silently on several validation runs.
- **Memory-safety fix:** BOLD data are passed between steps as Python-owned arrays; numpy views of ANTs image buffers
  produced corrupted volumes (mean ≈ 0) after slice-timing correction. A volume-intensity sanity check aborts the run if
  this ever recurs.
- **Speed:** motion estimation and resampling run in parallel worker processes (`CCS_PREPROC_WORKERS` to override);
  the gzipped `bold_mni.nii.gz` copy is now optional (`--write-gz`).
- **Robustness:** disk-space pre-check; implausible motion, failed brain extraction or segmentation abort the run with a
  clear error instead of writing corrupt confounds; fixed ANTs random seed (`--seed`, `--deterministic`).
- **Per-run `qc_report.html`** (fMRIPrep-style): alignment overlays, tissue masks, motion/FD/DVARS, carpet plot, parcel
  coverage and an auto-generated methods paragraph.
- **QC block** in `preprocess_report.json` (template correlation, brain-mask Dice, tissue volumes, mask sizes, per-parcel
  EPI coverage in `parcel_coverage.csv`, warnings).

### Fixed (Rust core)
- FD-censored frames are now **excluded** from FC, partial correlation, GCMI, TE and graph metrics.
- Default censoring model is now `spike`: nuisance + DCT band-pass + one regressor per censored frame fitted
  simultaneously, i.e. the model is fitted on retained frames only (equivalent to AFNI `3dTproject -cenmode KILL`).
  `interpolate` (Power et al. 2014) remains available; both drop censored frames from statistics.
- Residual DOF = retained frames − rank(design on retained frames); DOF warnings in the report.
- aCompCor voxel series are high-passed (DCT) before PCA.
- **Modularity Q formula** fixed in `graph_theory.rs` and `connectivity.rs` (null term over all same-community pairs);
  v0.4.1 over-estimated Q by ~50–60 %. Graph thresholding uses positive correlations only (no |r|).
- Time-series dynamics (ACW, LZC, SampEn, PLE) always use a continuous (censored-frame-interpolated), nuisance-cleaned, high-pass-only series, including when the default `spike` censoring is selected.
- `bench_denoise`: `--censor-mode` (default `spike`, matching the GUI) and `--no-zscore`.
- Exports `censor_mask.csv` and `confounds_used.csv`.
- aCompCor falls back to a Gram-matrix decomposition if the thin SVD returns non-finite values; non-finite
  confound matrices are rejected with an error.
- Inputs are verified against nibabel (ITK silently zero-filled volumes from cloud-synced files still downloading).

### Added
- **Publication figures (`pub_figures.py`; buttons in *Summary & Export* and *Stats → Group*):** report-style 300-dpi PNG + SVG
  figures. Per subject: anatomy and tissue masks, head motion, before/after denoising (carpets, FC distributions),
  connectome (ROI and network level), timescales by network, seed map. Per group/session/condition: network FC per group
  and their difference, within/between-network FC per subject, edge-wise FC, summary metrics, timescales by network.
  Runs below 30 residual DOF are excluded from group figures and listed in `group_inclusion.json`.
- `raw_timeseries.csv` (pre-denoising ROI series) is exported with the results.
- Validation report: [`docs/validation/v0.5.0/REPORT.md`](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/blob/v0.5.0/docs/validation/v0.5.0/REPORT.md) ([PDF](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/blob/v0.5.0/docs/validation/v0.5.0/REPORT.pdf)).

### Fixed (statistics, `nilearn_stats.py`)
- Seed maps: voxels are cleaned with exactly the same model as the seed (same confounds, censoring, DCT band) and
  z = atanh(r)·√(DOF−3) instead of √(T−3) (v0.4.1 inflated z ~2–3×, yielding 38–70 k "significant" voxels per seed).
  Seed maps refuse to run when residual DOF < 10. The anatomical brain mask from preprocessing is used as the voxel mask.

## [0.4.1] - 2026-11-22

### Improved
- **Nilearn Seed-to-Voxel GLM Voxelwise Denoising (`python_sidecar/src/ccs_fmri_sidecar/nilearn_stats.py`, `lib/widgets/results_dashboard.dart`)**:
  - Updated `--mode seed-glm` to accept `--confounds-tsv`, `--low-hz`, `--high-hz`, and `--tr`, regressing motion confounds and applying matching resting-state bandpass filtering inside `NiftiMasker` before whole-brain Fisher-$z$ correlation so cortical and visual seeds achieve much higher spatial sensitivity.
  - Added `/validation_data/` to `.gitignore`.

## [0.4.0] - 2026-11-22

### Added
- **Pure-Rust Graph Theory Engine (`rust/src/graph_theory.rs`, `compute_graph_theory`, `5. Results → Graph Theory`)**:
  - Computes NaN-safe Weighted & Binary network topology across Pearson, Partial, GCMI, or Transfer Entropy matrices with proportional density thresholding (`5%–50%`): **Global Efficiency**, **Local Efficiency**, **Onnela Clustering Coefficient ($C$)**, **Characteristic Path Length ($L$)**, **Maslov-Sneppen Small-Worldness ($\sigma$)**, **Newman Modularity ($Q$)**, **Assortativity ($r$)**, **Brandes Betweenness Centrality**, **Guimerà-Amaral Participation Coefficient ($P_i$)**, and **Within-Module Degree $z$-score ($z_i$)**.
  - Interactive **Density Sweep (5%–40%)** curve, **Hub Classification Scatter Plot ($P_i$ vs $z_i$)**, ranked Top-15 Nodal Hubs table, and automatic `graph_metrics_nodal.csv` + `graph_metrics_global.json` export.
- **Advanced Nilearn Statistical Inference (`python_sidecar/src/ccs_fmri_sidecar/nilearn_stats.py`, `5. Results → Stats (Nilearn)`)**:
  - **Single-Subject Seed-to-Voxel GLM (`--mode seed-glm`)**: Regresses any atlas ROI onto 4D MNI BOLD voxels, computes Fisher-$z$ statistical maps, applies Nilearn BH-FDR / Bonferroni thresholding, extracts MNI cluster tables, and renders dark-theme `plot_glass_brain` and `plot_stat_map` figures inline in Flutter.
  - **Group / Batch Connectivity Statistics (`--mode group`)**: Runs mass-univariate edgewise two-sample/paired $t$-tests with BH-FDR, **Network-Based Statistic (NBS)** permutation cluster tests, Log-Euclidean Tangent-Space cross-validated decoding, and `statsmodels.MixedLM` linear mixed-effects modeling directly on `batch_summary.csv`.
- **Net Directed Transfer Entropy Flow (`compute_te_net_asymmetry_matrix`)**:
  - Added **Net Flow (`TE i→j − TE j→i`)** toggle, non-overlapping mid-arc directional chevron arrowheads at `t = 0.60` in the Circular Connectome, and a diverging **Net Information Flow (`Out-TE − In-TE`)** bar chart separating Net Senders vs Net Receivers.
- **Inter-Network Dynamics One-Way ANOVA (`one_way_anova_by_group`)**:
  - Added exact $F$-statistics and $p$-values across Yeo-7 networks alongside zoomed Y-axis scaling and bar value labels so unimodal-to-transmodal gradients are clearly visible.

### Fixed
- **CONN-Style Linear-Interpolation Motion Censoring (`rust/src/denoise.rs`)**:
  - Replaced default simultaneous spike zero-out with Power et al. (2014) **intact-frame nuisance regression + linear interpolation across scrubbed frames** prior to DCT bandpass filtering (`CensorMode::Interpolate`), eliminating flat-zero censored plateaus, passband ringing, and low-DOF blow-up on high-motion scans while exposing explicit **Effective DOF remaining** and **Motion/DOF QC warnings**.
  - Switched Raw BOLD trace visualization in ROI Explorer to **robust median/MAD scaling** so large single-volume motion spikes no longer squash the visual scale of surviving neural oscillations.
  - Eliminated redundant full-band DCT double-filtering in `compute_sliding_dynamics_opt` when analyzing the primary resting-state band.

## [0.3.0] - 2026-11-22

### Added
- **Interactive Batch Analysis & Multi-Subject Queue (`6. Batch`, `lib/src/batch_runner.dart`, `lib/widgets/batch_panel.dart`)**:
  - **Study Discovery (`BatchDiscovery.discoverStudyFolder`)**: Scans a study root folder (e.g., BIDS `sub-*/ses-*` or `Patient_*/pre|post`) to auto-discover raw DICOM, raw NIfTI, and preprocessed MNI subjects without duplicating subfolders.
  - **Interactive Multi-File & Folder Selection**: Supports **Scan Study Folder**, **Add Subject Folder**, multi-select **Add NIfTI Files**, queue filtering/search, Select All/None checkboxes, per-subject **Edit Files** dialog, and 1-click **Load in Single-Subject Workflow**.
  - **Configurable End-to-End Batch Runner (`BatchRunner`)**: Sequentially runs DICOM conversion (`dcm2niix`), `ANTsPy` preprocessing (`Skip Existing Preproc` option), lesion-aware Rust denoising/FC/Partial/GCMI/TE, and `fMRIAnalysis.py`-inspired dynamics with live elapsed timer, `Stop After Current` cancellation, and incremental `batch_summary.csv` + `batch_summary.json` export.

## [0.2.0] - 2026-11-22

### Added
- **CONN-Style Denoising Quality Control (`rust/src/api.rs`, `lib/widgets/results_dashboard.dart`)**:
  - Added before-vs-after Functional Connectivity value distribution histograms (`rawFcHist` vs `cleanFcHist` + mean/SD summary), Framewise Displacement motion trace (`fdTrace`) with threshold & shaded scrubbed frames, and Raw vs Clean BOLD Carpet Plot comparison.
- **Interactive ROI Timeseries & Spectral Explorer (`get_roi_timeseries_detail`)**:
  - Searchable Schaefer/atlas ROI list with Network (`Vis`, `SomMot`, `DorsAttn`, `SalVentAttn`, `Limbic`, `Cont`, `Default`) and Hemisphere (`LH`/`RH`) filters supporting multi-ROI selection.
  - Overlays z-scored Raw vs Clean BOLD timeseries, Welch Power Spectral Density before vs after bandpass filtering, per-ROI nuisance variance removed `%`, and pairwise Pearson / Partial / GCMI / Transfer Entropy coupling readouts.
- **Advanced Connectivity, GCMI & Directed Transfer Entropy (`rust/src/info_theory.rs`)**:
  - Implemented `nilearn`-style analytical **Ledoit-Wolf Shrinkage Partial Correlation** (`faer` LLT precision matrix inversion), `CCS_EEGStudio`-inspired undirected **Gaussian-Copula Mutual Information (GCMI, bits)**, and directed **Gaussian-Copula Transfer Entropy (`TE i -> j`, bits)**.
  - Added interactive ROI × ROI heatmap explorer (click any cell to jump directly to those ROIs' traces), a multi-community **Circular Connectome** with density slider and directional arrowheads, and a **Top-10 Hub ROIs** chart (`get_top_hubs`).
  - Exported `partial_fc_matrix.csv`, `gcmi_matrix.csv`, and `te_matrix.csv` automatically alongside `fc_matrix.csv`.
- **fMRI Timeseries Dynamics (`rust/src/dynamics.rs`, `compute_cached_dynamics`)**:
  - Ported all 9 sliding-window complexity & intrinsic timescale metrics inspired by `fMRIAnalysis.py` to Rayon-parallel pure Rust: **ACW-0**, **ACW-50**, **ACF AUC (rect & trap)**, **Lempel-Ziv Complexity (LZC)**, **Sample Entropy (`m=2`)**, **Welch Median Frequency**, **Normalized Spectral Entropy**, and **1/f Power-Law Exponent (PLE)**.
  - Added sub-band selector (`Slow-5`, `Slow-4`, `Full Band`), configurable window/step sliders, Yeo-7 network profile chart (`Mean ± SD`), and `roi_dynamics.csv` export.

## [0.1.3] - 2026-11-21

### Added
- **Persistent Whole-Pipeline Progress Header & Live Elapsed Timer (`lib/main.dart`)**:
  - Added a 5-stage top pipeline progress bar (`1. Import` → `2. Preprocess` → `3. Lesion (Opt)` → `4. Denoise` → `5. Results`) showing overall percentage (`0%–100%`) and green checkmarks on completed stages.
  - Added a live Activity Banner during sidecar/Rust execution showing the active stage description, determinate/indeterminate `LinearProgressIndicator`, and a live `MM:SS` elapsed timer.
- **Visual 8-Stage ANTsPy Preprocessing Tracker (Step 2)**:
  - Parses `[preproc]` stage milestones in real time (`load_inputs`, `t1_n4_bias_correction`, `t1_atropos_segmentation`, `t1_to_mni`, `bold_motion_correction`, `mean_bold_to_t1_rigid`, `warp_4d_and_masks_to_mni`, `align_schaefer400_atlas`), displaying per-stage completion tiles with elapsed seconds, overall bar progress, a green completion CTA to Step 4, and a collapsible Technical Log.
- **New Step 5 (`5. Results & Export`) with Rust-Rendered Brain Visualizations (`rust/src/api.rs`, `lib/main.dart`)**:
  - Extended `LesionPipelineSummary` with Rust-rendered RGBA buffers for the **400×400 Functional Connectivity Matrix** (`fcPreviewRgba`, blue–white–crimson diverging scale) and **Denoised ROI Timeseries Carpet Plot** (`carpetRgba`).
  - Automatically exports `fc_matrix.csv`, `denoised_timeseries.csv`, `biomarkers_summary.json`, and `clinical_report.md` into `<preproc>/results/`, surfaced with 4 KPI cards, native **Open Results Folder**, **Save Clinical Report As…**, and **Analyze Another Patient** actions.

### Fixed
- **Step 4 UI Cleanup & Scaled Brain Slice Viewport**:
  - Replaced the 7 stacked raw path inputs with clean short basename chips, an explicit **Apply Lesion Mask** toggle (with large-mask warning + 1-click re-run without mask), collapsible manual path overrides, properly labeled individual sliders, and a full-size `FittedBox` dark-framed slice viewport.
  - Excluded derived `_n4` / `mask` files when auto-detecting `rawT1Path` in `FmriSessionState.scanFolder`.

## [0.1.2] - 2026-11-21

### Added
- **Smart 1-Click Patient Folder Auto-Detection (`lib/src/session_state.dart`)**:
  - `FmriSessionState.scanFolder` recursively inspects up to depth 2 to automatically recognize **raw scanner DICOM series** (`.IMA`, `.dcm`, `.dicom` subfolders such as `HEAD_EP2D_RS_FMRI...` and `HEAD_T1_MPRAGE_SAG_P2_ISO...`), **raw NIfTI / BIDS scans**, or **preprocessed MNI derivatives** (`preproc/bold_mni.nii`, atlases, WM/CSF masks, `confounds.tsv`).
  - Automatically picks the best 3D isotropic T1w series (`SAG`/`ISO` preferred over `COR`/`TRA`) and highest-volume 4D BOLD series for one-click `dcm2niix` conversion.
  - `handlePickedFile` intercepts single `.IMA`/`.dcm` picks and automatically promotes to the owning patient folder's DICOM series list instead of throwing a NIfTI header error.
- **Zero-Jargon Guided Step 1 Onboarding (`lib/main.dart`)**:
  - Replaced cryptic NIfTI filename instructions with a clear **"Open Your MRI Scan"** landing card (`Open Patient Folder` / `Open Single NIfTI File`), dynamic **"Detected Scan"** card with interactive DICOM series dropdowns and a single **"Convert DICOMs to NIfTI & Continue →"** CTA, completion badges in the 4-step sidebar, and a collapsed **"Advanced: Manual DICOM Folders & NIfTI Header Inspector"** section.
- **Self-Contained Bundled Python Sidecar & Templates**:
  - Declared `python_sidecar/` and `assets/templates/` in `pubspec.yaml` and added automatic runtime extraction into Application Support (`ensureSidecarProjectDir`) so DICOM conversion, `ANTsPy` preprocessing, and lesion segmentation work inside standalone packaged desktop apps without a local repo checkout.

## [0.1.1] - 2026-11-21

### Added
- **Interactive Native File & Folder Pickers (`file_picker`)**:
  - Replaced manual text-only fields with clickable `Browse` buttons (`PathPickerField`) supporting native OS file dialogs (macOS/Windows/Linux) for `.nii` / `.nii.gz`, `.json`, `.tsv` inputs, output directories, and save paths.
  - Added 1-click **Open Folder** in the header and Step 1 (**Browse Subject Folder**) with automatic NIfTI/BIDS discovery (`FmriSessionState.autoPopulateFromFolder`) covering `T1w`, `FLAIR`, `BOLD`, `confounds.tsv`, preprocessed `preproc/` derivatives, WM/CSF masks, Schaefer atlas files, and lesion masks.
- **Guided 4-Step Clinical Workflow (`NavigationRail`)**:
  - Replaced the confusing two-tab raw path form with an intuitive step-by-step sidebar: **1. Import** → **2. Preprocess** → **3. Lesion** → **4. Denoise**, passing resolved paths cleanly between steps via shared `FmriSessionState` (no failing developer-machine default relative paths inside packaged `.app` bundles).
  - Added interactive Slice (`Z`/`Y`/`X`) and 4D Timepoint (`T`) sliders to Step 4's Zero-Copy RGBA Slice Viewport.
  - Exposed Python sidecar actions (`dicom_convert`, `preprocess`, `lesion_segment`) directly inside Steps 1–3 via `uv` auto-discovery.
- **In-App GitHub Releases Updater (`lib/src/update_checker.dart`)**:
  - Added **Updates** button in the top bar (plus background release check) with SHA-256 checksum verification (`SHA256SUMS.txt`), macOS `.app` zip download/extract/relaunch flow, and Windows/Linux portable bundle reveal, matching `CCS_EEGStudio`.

### Fixed
- Upgraded `macos/Podfile` deployment target to macOS `12.0` (`platform :osx, '12.0'`) and added `FilePicker.skipEntitlementsChecks()` on macOS so native file dialogs work cleanly in non-sandboxed desktop bundles.

## [0.1.0] - 2026-11-21

### Added
- **Hybrid Architecture Scaffold**: Cross-platform Flutter desktop UI (`macos`, `linux`, `windows`) bridged to a native Rust core (`ccs_fmri_core`) via `flutter_rust_bridge` v2.13.0 alongside a `uv`-managed Python scientific sidecar (`ccs_fmri_sidecar`).
- **Rust NIfTI & Zero-Copy Imaging Core**:
  - `inspect_nifti_header` with BIDS `.json` sidecar `RepetitionTime` auto-detection and `sform`/`qform` affine extraction.
  - Zero-copy `memmap2` `BoldVolume::MmapF32` loader for uncompressed native-endian `f32` `.nii` files and `nifti`-crate `.nii.gz` fallback.
  - Orthogonal slice renderer (`render_ortho_slice_rgba`) producing 2nd–98th percentile normalized RGBA buffers for `RawImage` display.
- **Rust Parcellation, Denoising & Connectivity**:
  - Rayon-parallel Schaefer ROI timeseries extraction (`extract_roi_timeseries`).
  - CONN-style WM/CSF aCompCor PCA via `faer` `thin_svd` (`compute_acompcor`).
  - Simultaneous orthogonalized nuisance regression + DCT-II stopband bandpass + FD scrubbing projection via `faer` SVD (`simultaneous_denoise`).
  - Static Pearson FC (`static_fc_pearson`) and sliding-window dynamic FC (`sliding_window_fc`), plus `bench_denoise` benchmark CLI.
- **Python Scientific Sidecar (`python_sidecar/`)**:
  - `dicom_convert.py`: Siemens mosaic `.IMA` / DICOM to BIDS NIfTI + `.json` sidecar conversion using `dcm2niix`.
  - `preprocess.py`: ANTsPy preprocessing pipeline (N4 bias correction, Atropos 3-class WM/CSF segmentation, `SyNQuick` MNI152 2mm registration, 4D rigid motion correction + Power FD `confounds.tsv`, mean BOLD→T1w rigid coregistration, single-interpolation 4D MNI warp, and Schaefer-400 alignment).
  - `benchmark_vs_nilearn.py`: Multi-trial performance, peak-RAM, and 400-ROI numerical parity validation suite against `nilearn`.
- **Cross-Platform Desktop Releases & Documentation**:
  - Bundled FFI library loader (`lib/src/rust_loader.dart`) for macOS `.app`, Windows `.exe`, and Linux bundles.
  - GitHub Actions 3-OS release pipeline (`.github/workflows/build.yml`), comprehensive `README.md`, and 6-page visual wiki in `docs/wiki/`.
- **TBI & Stroke Clinical Lesion Workflows**:
  - Rust 3D lesion processor (`rust/src/lesion.rs`): hemispheric asymmetry auto-segmentation, 3D Magic Wand flood-fill, spherical brush/eraser, `fill_holes_3d`, `remove_small_islands_3d`, `dilate_mask_3d`, tissue mask lesion subtraction, and 40% red RGBA overlay rendering.
  - Interactive Flutter Lesion Editor (`lib/widgets/lesion_editor_panel.dart`) with synchronized Axial/Coronal/Sagittal viewports and tap-to-segment/paint/erase controls.
  - Lesion-safe `ANTsPy` registration (`cfm` Cost Function Masking & `enantiomorphic` contralesional healing) and 4 clinical cohort templates (`assets/templates/registry.json`, `templates.py`).
  - Lesion-aware Rust parcellation (`>50%` damaged ROIs flagged `NaN`), lesion-excluded WM/CSF aCompCor, NaN-safe denoising, NaN-safe graph efficiency/modularity, lesion-network mapping, homotopic/laterality indices, and `statsmodels` group LMM (`group_lmm.py`) with `total_lesion_volume_ml` and `roi_percent_damage` covariates.
