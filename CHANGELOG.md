# Changelog

All notable changes to **CCS_fMRIStudio** are documented in this file.

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
