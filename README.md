<p align="center">
  <img src="screenshots/ccs_logo.png" width="140" alt="Centre for Consciousness Studies Logo">
</p>

<h1 align="center">CCS fMRI Studio</h1>

<p align="center">
  <b>Cross-platform desktop fMRI preprocessing, native-speed Rust denoising, parcellation, and EEG-style timeseries/connectivity workbench</b>
</p>

<p align="center">
  A Research &amp; Engineering Collaboration of<br>
  <b>Centre for Consciousness Studies (CCS)</b>, Department of Neurophysiology,<br>
  <b>National Institute of Mental Health and Neurosciences (NIMHANS)</b>, Bengaluru, India
</p>

<p align="center">
  <a href="https://github.com/CCS-NIMHANS/CCS_fMRIStudio/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/CCS-NIMHANS/CCS_fMRIStudio?style=for-the-badge&color=2563eb&label=RELEASE"></a>
  <a href="https://github.com/CCS-NIMHANS/CCS_fMRIStudio/actions/workflows/build.yml"><img alt="Desktop build" src="https://img.shields.io/github/actions/workflow/status/CCS-NIMHANS/CCS_fMRIStudio/build.yml?style=for-the-badge&label=BUILD"></a>
  <a href="https://github.com/CCS-NIMHANS/CCS_fMRIStudio/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/CCS-NIMHANS/CCS_fMRIStudio/total?style=for-the-badge&color=16a34a&label=DOWNLOADS"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/LICENSE-MIT-0f766e?style=for-the-badge"></a>
</p>

<p align="center">
  <b>Current version: 0.1.0</b> ·
  <a href="docs/wiki/Home.md"><b>Visual Wiki</b></a> ·
  <a href="CHANGELOG.md"><b>Release Notes</b></a> ·
  <a href="docs/wiki/Benchmarks-and-Validation.md"><b>Benchmarks &amp; Validation</b></a> ·
  <a href="docs/wiki/Building-and-Releasing.md"><b>3-OS Build Guide</b></a> ·
  <a href="https://github.com/CCS-NIMHANS/CCS_fMRIStudio/issues"><b>Report Issue</b></a>
</p>

---

## 📥 Quick Download

| Platform | Package | Direct Download |
| :--- | :--- | :--- |
| **macOS** | Apple Silicon / Universal App ZIP (macOS 12+) | [CCSfMRIStudio-macos.zip](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/releases/latest/download/CCSfMRIStudio-macos.zip) |
| **Windows** | 64-bit Portable Desktop ZIP (Windows 10/11) | [CCSfMRIStudio-windows-x64.zip](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/releases/latest/download/CCSfMRIStudio-windows-x64.zip) |
| **Linux (x86_64)** | Portable Desktop Bundle (`.tar.gz`) | [CCSfMRIStudio-linux-x64.tar.gz](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/releases/latest/download/CCSfMRIStudio-linux-x64.tar.gz) |

> 📦 Checksums (`SHA256SUMS.txt`) and release assets are published on the **[GitHub Releases Page](https://github.com/CCS-NIMHANS/CCS_fMRIStudio/releases/latest)**.

<details>
<summary><b>🍏 macOS Gatekeeper Setup &amp; 🐧 Linux Bundle Launch</b></summary>

**macOS (first launch):**
```sh
xattr -rd com.apple.quarantine ~/Downloads/ccs_fmri_studio.app
mv ~/Downloads/ccs_fmri_studio.app /Applications/
```

**Linux (portable bundle):**
```bash
mkdir -p ~/CCS_fMRIStudio && tar -xzf ~/Downloads/CCSfMRIStudio-linux-x64.tar.gz -C ~/CCS_fMRIStudio
~/CCS_fMRIStudio/ccs_fmri_studio
```

</details>

---

## ✨ What's New in v0.1.0

- **Hybrid Flutter + Rust Core + Embedded Python Sidecar:** Cross-platform desktop UI bridged over zero-copy `flutter_rust_bridge` v2 (`libccs_fmri_core`) alongside a relocatable `uv`-managed Python scientific sidecar (`antspyx`, `nilearn`, `nibabel`, `scikit-learn`, `statsmodels`) — bypassing WSL, Docker, FSL, and AFNI dependencies.
- **Zero-Copy Memory-Mapped NIfTI & 60/120 FPS RGBA Slice Rendering:** Direct `memmap2` Fortran-order mapping for uncompressed native `f32` 4D volumes (`.nii`) plus `.nii.gz` fallback, BIDS `.json` sidecar `RepetitionTime` auto-detection, and 2nd–98th percentile orthogonal RGBA slice rendering.
- **Native-Speed Parcellation, CONN-Style aCompCor & Simultaneous Denoising:** Parallel Rayon Schaefer-400 extraction (`28.20 ms` median), WM/CSF aCompCor PCA via `faer` thin SVD, and single-step orthogonalized DCT-II stopband bandpass + motion + FD scrubbing projection (`r > 0.99999999999` parity vs. `nilearn` cosine filtering).
- **ANTsPy Single-Subject Preprocessing CLI:** Automated DICOM-to-BIDS conversion (`dcm2niix`), N4 bias correction, Atropos 3-class WM/CSF tissue segmentation, `antsRegistrationSyNQuick[s]` MNI152 2 mm registration, 4D rigid motion correction + Power FD `confounds.tsv`, and single-interpolation 4D MNI warp in **101.93 s** (~1.7 min) on a 24 GB MacBook Pro.
- **TBI & Stroke Clinical Lesion Modules:**
  - **Auto-Segment → Manual Polish UI:** Multi-contrast ONNX / midline-aligned hemispheric asymmetry segmentation (`lesion_segment.py` & `rust/src/lesion.rs`) paired with an interactive Flutter 3D mask editor (40% red ortho overlay, 3D Magic Wand flood-fill, spherical brush/eraser, `Fill Holes`, `Remove Islands <10`, `Dilate +1 Vox`).
  - **Lesion-Safe Spatial Normalization & Age-Matched Templates:** `ANTsPy` Cost Function Masking (`--lesion-mode cfm`), Enantiomorphic contralesional healing (`--lesion-mode enantiomorphic`, validated end-to-end on `Patient_01/pre` in **107.13 s**), and MNI-aligned cohort templates (`mni152_adult`, `older_adult_stroke`, `pediatric_nihpd`, `acute_ct_stroke`).
  - **Lesion-Aware Connectivity & LMM Stats:** Subtract dilated lesion from WM/CSF aCompCor masks, exclude `>50%`-damaged Schaefer parcels as `NaN`, compute NaN-safe graph global efficiency / modularity, homotopic FC, laterality indices, lesion-network mapping, and `statsmodels` group LMM (`group_lmm.py`) with `total_lesion_volume_ml` and `roi_percent_damage` covariates.

---

## 🏗️ Hybrid System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                  FLUTTER / DART FRONTEND (UI)                   │
│  • NIfTI Header & BIDS Sidecar Inspector                        │
│  • Zero-Copy RGBA Ortho Slice Viewport (ui.decodeImageFromPixels│
│  • Native Rust Denoising & Functional Connectivity Workbench    │
└───────────────────────────────┬─────────────────────────────────┘
                                │ flutter_rust_bridge v2 (FFI)
┌───────────────────────────────▼─────────────────────────────────┐
│                   RUST CORE ENGINE (rust/)                      │
│  • Zero-copy memmap2 `.nii` loader + `nifti` `.nii.gz` fallback │
│  • Parallel Rayon Schaefer-400 parcellation extraction          │
│  • CONN-style WM/CSF aCompCor & simultaneous DCT bandpass +     │
│    nuisance + FD scrubbing projection via `faer` thin SVD       │
│  • Static Pearson FC & sliding-window dynamic FC                │
└───────────────────────────────┬─────────────────────────────────┘
                                │ uv-managed sidecar (CLI / IPC)
┌───────────────────────────────▼─────────────────────────────────┐
│            EMBEDDED PYTHON SIDECAR (python_sidecar/)            │
│  • Siemens DICOM -> NIfTI + BIDS JSON (`dcm2niix`)              │
│  • ANTsPy (`antspyx`): N4, Atropos, SyNQuick MNI, Rigid MoCo    │
│  • Nilearn / scikit-learn / statsmodels Analytical Parity       │
└─────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Verified Speedup & Parity Benchmarks

Evaluated on clinical 3T resting-state fMRI + T1w DICOM data (`Patient_01/pre`, `99 × 117 × 95 × 450` float32 MNI152 2 mm volume, ~1.98 GB uncompressed, 400 Schaefer ROIs, 22 motion + WM/CSF aCompCor confounds, 98 `FD > 0.5 mm` scrubbing frames, `0.008–0.09 Hz` bandpass, 400×400 FC) over **3 repeated trials** on Apple Silicon (24 GB RAM):

| Pipeline / Metric | Rust `.nii` (`memmap2`) | `nilearn` `.nii` | Rust `.nii.gz` | `nilearn` `.nii.gz` | Speedup (`.nii` `mmap` / `.nii.gz`) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **Load** | 3.32 ms | 2.19 ms | 3,234.20 ms | 2.31 ms | — |
| **Schaefer-400 Parcellation** | **28.20 ms** | 4,453.02 ms | **16.94 ms** | 12,189.47 ms | **157.91×** / **719.57×** |
| **WM + CSF aCompCor (5+5)** | **604.65 ms** | 4,620.74 ms | **622.72 ms** | 14,384.53 ms | **7.64×** / **23.10×** |
| **Simultaneous Denoising** | **32.56 ms** | 51.27 ms | **33.09 ms** | 50.74 ms | **1.57×** / **1.53×** |
| **400×400 Pearson FC** | 2.81 ms | 0.56 ms | 2.89 ms | 0.57 ms | — |
| **Total End-to-End (Median)** | **670.55 ms** | **9,161.38 ms** | **3,883.26 ms** | **26,628.17 ms** | **13.66×** / **6.86×** |
| **Peak RSS Memory** | **2,244.58 MB** | 4,105.03 MB | 4,574.94 MB | 4,119.31 MB | **1.83× less RAM** (`.nii`) |

- **Mathematical Parity (`400` Schaefer ROIs)**:
  - Rust DCT high-pass (`0.008 Hz`) vs. `nilearn.signal.clean(..., filter='cosine')`: **`mean r = 0.99999999999867`**, **`median r = 0.99999999999885`**, **`min r = 0.99999999999476`**.
  - Rust DCT simultaneous bandpass (`0.008–0.09 Hz`) vs. `nilearn` Butterworth: **`mean r = 0.9200`**, **`median r = 0.9230`**.
- **ANTsPy Preprocessing (`SyNQuick`)**: Completed full structural + 450-volume functional pipeline in **101.93 s (1.70 min)** with peak RSS **7,227.0 MB**.

---

## 📖 Visual Wiki Guides

| Guide | Topics Covered |
| :--- | :--- |
| [**Wiki Home**](docs/wiki/Home.md) | End-to-end workflow map, supported formats, and project navigation |
| [**1. Architecture & Hybrid Engine**](docs/wiki/Architecture-and-Hybrid-Engine.md) | Flutter + `flutter_rust_bridge` v2 + `memmap2` + `faer` + `uv` sidecar & 24 GB RAM safeguards |
| [**2. Preprocessing & DICOM / BIDS**](docs/wiki/Preprocessing-and-DICOM-BIDS.md) | `dcm2niix` Siemens `.IMA` conversion, ANTsPy N4/Atropos/SyNQuick/MoCo, and `confounds.tsv` |
| [**3. Rust Denoising & Connectivity**](docs/wiki/Rust-Denoising-and-Connectivity.md) | Schaefer parcellation, aCompCor, simultaneous orthogonalized DCT projection, FC/dFC, RGBA slices |
| [**4. Benchmarks & Validation**](docs/wiki/Benchmarks-and-Validation.md) | Full `Patient_01/pre` preprocessing report, 3-trial min/median/max benchmarks, and parity tests |
| [**5. Building & Releasing (3 OSes)**](docs/wiki/Building-and-Releasing.md) | Local builds, `flutter_rust_bridge_codegen`, and 3-OS GitHub Actions release packaging |
| [**6. TBI & Stroke Lesion Workflows**](docs/wiki/TBI-and-Stroke-Lesion-Workflows.md) | Auto-segmentation, Flutter 3D mask editor, CFM/Enantiomorphic registration, clinical templates & LMM |

---

## 🚀 Building & Testing Locally

**Prerequisites:** Flutter SDK (`3.41.x`), Rust toolchain (`cargo` / `rustc`), `uv`, and `dcm2niix`.

```bash
# 1. Build and test the native Rust core engine
cargo test --release --locked --manifest-path rust/Cargo.toml
cargo build --release --locked --manifest-path rust/Cargo.toml

# 2. Set up the uv Python sidecar
cd python_sidecar && uv sync && cd ..

# 3. Analyze, test, and run the Flutter desktop app
flutter pub get
flutter analyze
flutter test
flutter run -d macos   # or windows / linux
```

<details>
<summary><b>🧪 Running End-to-End Preprocessing & Rust-vs-Nilearn Benchmarks</b></summary>

```bash
cd python_sidecar

# Convert raw T1w + 4D BOLD DICOM folders to NIfTI + BIDS JSON
uv run python -m ccs_fmri_sidecar.dicom_convert \
  --t1-dicom <T1_DICOM_DIR> \
  --bold-dicom <BOLD_DICOM_DIR> \
  --out ../data_test_output/subject/raw

# Preprocess with ANTsPy (N4, Atropos, SyNQuick MNI152 2mm, 4D MoCo)
uv run python -m ccs_fmri_sidecar.preprocess \
  --t1 ../data_test_output/subject/raw/t1w.nii.gz \
  --bold ../data_test_output/subject/raw/bold.nii.gz \
  --out ../data_test_output/subject/preproc \
  --transform SyNQuick

# Benchmark Rust vs. nilearn across 3 repeated trials
uv run python -m ccs_fmri_sidecar.benchmark_vs_nilearn \
  --preproc-dir ../data_test_output/subject/preproc \
  --bench-bin ../rust/target/release/bench_denoise \
  --repeats 3 \
  --out-json ../data_test_output/subject/benchmark_verified.json
```

</details>

---

## 📚 Method References

| Category | App Method | Paper or Reference | Implementation Scope |
| :--- | :--- | :--- | :--- |
| **DICOM / BIDS** | Mosaic CSA & BIDS sidecar extraction | Li et al. (2016), [doi:10.1016/j.jneumeth.2016.03.001](https://doi.org/10.1016/j.jneumeth.2016.03.001) | Automated `dcm2niix` wrapper extracting `RepetitionTime` and `SliceTiming`. |
| **Structural** | N4 Bias Field & Atropos Segmentation | Tustison et al. (2010), [doi:10.1109/TMI.2010.2046908](https://doi.org/10.1109/TMI.2010.2046908); Avants et al. (2011), [doi:10.1007/s12021-011-9109-y](https://doi.org/10.1007/s12021-011-9109-y) | 3-class K-means Atropos WM/CSF segmentation with 1-voxel erosion for aCompCor. |
| **Registration** | SyN Diffeomorphic Normalization | Avants et al. (2008), [doi:10.1016/j.media.2007.06.004](https://doi.org/10.1016/j.media.2007.06.004) | `antsRegistrationSyNQuick[s]` to MNI152NLin2009cAsym (2 mm) + single-interpolation 4D warp. |
| **Motion & QC** | Framewise Displacement (FD) | Power et al. (2012), [doi:10.1016/j.neuroimage.2011.10.018](https://doi.org/10.1016/j.neuroimage.2011.10.018) | 6-DOF Euler/translation extraction from `BOLDRigid`, 50 mm sphere FD, and scrubbing spikes. |
| **Denoising** | aCompCor & Simultaneous Projection | Behzadi et al. (2007), [doi:10.1016/j.neuroimage.2007.04.042](https://doi.org/10.1016/j.neuroimage.2007.04.042); Hallquist et al. (2013), [doi:10.1016/j.neuroimage.2013.05.116](https://doi.org/10.1016/j.neuroimage.2013.05.116); Lindquist et al. (2019), [doi:10.1002/hbm.24528](https://doi.org/10.1002/hbm.24528) | Native Rust `faer` thin SVD orthogonalized regression of confounds, FD spikes, and DCT-II stopband. |
| **Parcellation** | Schaefer 400-Parcel 7-Network Atlas | Schaefer et al. (2018), [doi:10.1093/cercor/bhx179](https://doi.org/10.1093/cercor/bhx179) | MNI152 2 mm nearest-neighbor resampling and parallel Rayon mean ROI extraction. |

---

## 🤝 Acknowledgments, Related Projects & Citation

- **Research Group:** **Centre for Consciousness Studies (CCS)**, Dept. of Neurophysiology, **NIMHANS**, Bengaluru, India.
- **Related Repositories:** [CCS EEG Studio](https://github.com/CCS-NIMHANS/CCS_EEGStudio) · [CCS Sleep Studio](https://github.com/CCS-NIMHANS/CCS_SleepStudio) · [CCS Mobile Studio](https://github.com/CCS-NIMHANS/CCS_MobileStudio) · [CCS PPG Studio](https://github.com/CCS-NIMHANS/CCS_PPGStudio)
- **License:** [MIT License](LICENSE) © 2026 Dr. Arun Sasidharan, Centre for Consciousness Studies, NIMHANS.

```bibtex
@software{Sasidharan2026CCSfMRIStudio,
  author    = {Arun Sasidharan},
  title     = {{CCS fMRI Studio}: Cross-platform desktop fMRI preprocessing, native Rust denoising, and connectivity workbench},
  year      = {2026},
  publisher = {Centre for Consciousness Studies, NIMHANS},
  url       = {https://github.com/CCS-NIMHANS/CCS_fMRIStudio}
}
```
