# Changelog

All notable changes to **CCS_fMRIStudio** are documented in this file.

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
