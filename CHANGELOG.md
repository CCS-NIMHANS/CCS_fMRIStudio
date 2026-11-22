# Changelog

All notable changes to **CCS_fMRIStudio** are documented in this file.

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
