# 1. Architecture & Hybrid Engine

**CCS fMRI Studio** mirrors the hybrid philosophy of **CCS EEG Studio** by separating interactive visualization and linear-algebra-heavy timeseries processing from battle-tested spatial registration and statistical modeling.

---

## Three-Layer Architecture

```mermaid
flowchart TB
  subgraph UI["Flutter / Dart Desktop UI (lib/)"]
    U1["NIfTI Header &amp; Sidecar Inspector"]
    U2["Zero-Copy RGBA Slice Viewport (ui.decodeImageFromPixels)"]
    U3["Rust Denoise &amp; FC Pipeline Controls"]
  end

  subgraph RUST["Native Rust Core Engine (rust/src/)"]
    R1["nifti_io.rs: memmap2 (.nii) &amp; nifti crate (.nii.gz)"]
    R2["parcellation.rs: Rayon-parallel ROI averaging"]
    R3["denoise.rs: faer thin SVD aCompCor &amp; DCT projection"]
    R4["connectivity.rs: Pearson FC &amp; sliding-window dFC"]
  end

  subgraph PY["Embedded uv Python Sidecar (python_sidecar/)"]
    P1["dicom_convert.py: dcm2niix DICOM -> NIfTI + BIDS JSON"]
    P2["preprocess.py: ANTsPy N4, Atropos, SyNQuick, Motion Correction"]
    P3["nilearn / scikit-learn / statsmodels Analytical Parity &amp; Stats"]
  end

  UI -- "flutter_rust_bridge v2 (FFI)" --> RUST
  RUST <-- "Subprocess CLI / Filesystem Artifacts" --> PY
```

---

## Why Hybrid Rust + ANTsPy Instead of Wrapping FSL / AFNI / fMRIPrep?

| Requirement | FSL / AFNI / Docker fMRIPrep | CCS_fMRIStudio Hybrid Engine |
| :--- | :--- | :--- |
| **Windows Support** | Requires WSL2 or Docker Desktop | Native `ccs_fmri_core.dll` + native `antspyx` wheels |
| **macOS Apple Silicon** | Rosetta / Docker overhead; 2–4 hr/subject | Native `arm64` C++/ITK wheels + Rust SIMD (~1.7 min/subject) |
| **Zero-Code UX** | CLI scripts, environment paths, licensing | Single desktop app bundle + relocatable `uv` environment |
| **24 GB Laptop RAM** | High container + Python array duplication | Zero-copy `memmap2` `.nii` mapping (`float32` on disk) |

---

## Key Memory Safeguards for 24 GB Laptops

1. **Zero-Copy Memory-Mapped `.nii` I/O (`rust/src/nifti_io.rs`)**:
   When loading an uncompressed native-endian `float32` `.nii` volume with trivial scaling (`scl_slope` 0 or 1, `scl_inter` 0) and 4-byte-aligned `vox_offset`, `BoldVolume::MmapF32` maps the file directly via `memmap2::Mmap` and builds a Fortran-order (`[X, Y, Z, T]`) `ArrayView4<f32>` with **zero heap allocation**.
2. **Column-Major Slicing Efficiency**:
   Because NIfTI stores 4D volumes in Fortran order (`[X, Y, Z, T]`), every 3D brain volume at timepoint `t` is contiguous in memory, enabling lock-free Rayon parallelism across timepoints and instant single-slice extraction for the Flutter viewport.
3. **Double-Precision Only on Compact Matrices**:
   4D brain volumes always remain in `float32`. Only compact 2D `(T × N_rois)` or `(T × V_mask)` matrices are promoted to `f64` for `faer::Mat::thin_svd()`.
4. **Bundled FFI Resolution (`lib/src/rust_loader.dart`)**:
   `openBundledRustLibrary()` automatically resolves `libccs_fmri_core.dylib` (`Contents/Frameworks/` on macOS), `ccs_fmri_core.dll` (next to `.exe` on Windows), `libccs_fmri_core.so` (`lib/` on Linux), and `rust/target/{release,debug}` during local development.
