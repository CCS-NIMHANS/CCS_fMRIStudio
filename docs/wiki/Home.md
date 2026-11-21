# CCS fMRI Studio Wiki

A visual, technical guide to **CCS fMRI Studio** — a cross-platform desktop fMRI preprocessing, denoising, parcellation, and EEG-style timeseries/connectivity workbench powered by **Flutter + Rust + an embedded ANTsPy/nilearn Python sidecar** without FSL, AFNI, or Docker dependencies.

---

## End-to-End Workflow Map

```mermaid
flowchart LR
  A["1. Raw DICOM / BIDS Input<br/>Siemens .IMA, .nii, .nii.gz, .json"] --> B["2. DICOM Conversion<br/>dcm2niix -> t1w.nii.gz + bold.nii.gz<br/>RepetitionTime &amp; SliceTiming"]
  B --> C["3. ANTsPy Preprocessing<br/>N4 Bias, Atropos WM/CSF,<br/>SyNQuick MNI152, BOLDRigid MoCo"]
  C --> D["4. Rust Core Engine<br/>memmap2 NIfTI, Schaefer-400,<br/>aCompCor, Simultaneous DCT Denoise"]
  D --> E["5. Connectivity &amp; Inspection<br/>400x400 FC, Sliding-Window dFC,<br/>Zero-Copy Ortho RGBA Slices"]
```

---

## Wiki Guides

| Guide | Topics Covered |
| :--- | :--- |
| [**1. Architecture & Hybrid Engine**](Architecture-and-Hybrid-Engine.md) | Flutter UI, `flutter_rust_bridge` v2 FFI, Rust `memmap2` + `faer` + `rayon` engine, `uv` Python sidecar, and 24 GB RAM safeguards |
| [**2. Preprocessing & DICOM / BIDS**](Preprocessing-and-DICOM-BIDS.md) | `dcm2niix` Siemens `.IMA` conversion, ANTsPy N4 bias correction, Atropos segmentation, `SyNQuick` MNI152, rigid motion correction, and `confounds.tsv` |
| [**3. Rust Denoising & Connectivity**](Rust-Denoising-and-Connectivity.md) | Parallel Schaefer parcellation, CONN-style WM/CSF aCompCor, simultaneous orthogonalized DCT bandpass + scrubbing projection, static/dynamic FC, and RGBA slice rendering |
| [**4. Benchmarks & Validation**](Benchmarks-and-Validation.md) | Verified 3-trial `Patient_01/pre` timings, `13.66x` end-to-end / `157.91x` parcellation speedups, `1.83x` peak RSS reduction, and `r > 0.99999999999` parity vs. `nilearn` |
| [**5. Building & Releasing (3 OSes)**](Building-and-Releasing.md) | Local macOS/Linux/Windows compilation, `flutter_rust_bridge_codegen`, GitHub Actions 3-OS release pipeline, and SHA-256 verification |

---

## Supported Inputs & Outputs

| Category | Formats / Outputs |
| :--- | :--- |
| **Raw Inputs** | Siemens `.IMA` / DICOM folders (`dcm2niix`), 3D/4D `.nii` and `.nii.gz`, BIDS `.json` sidecars (`RepetitionTime`, `SliceTiming`) |
| **Preprocessed Artifacts** | `bold_mni.nii` (uncompressed float32 for zero-copy `memmap2`), `bold_mni.nii.gz`, `t1w_mni.nii.gz`, `wm_mask_mni.nii.gz`, `csf_mask_mni.nii.gz`, `schaefer400_mni.nii.gz`, `confounds.tsv`, `preprocess_report.json` |
| **Rust Engine Outputs** | ROI denoised timeseries `.csv`, orthogonalized confounds `.csv`, benchmark JSON reports, and live RGBA slice pixel buffers |

---

## Companion CCS Studio Projects

- [**CCS EEG Studio**](https://github.com/CCS-NIMHANS/CCS_EEGStudio) — Native-speed EEG preprocessing, ERP/ERSP/rERP, source imaging, and microstate workbench.
- [**CCS Sleep Studio**](https://github.com/CCS-NIMHANS/CCS_SleepStudio) · [**CCS Mobile Studio**](https://github.com/CCS-NIMHANS/CCS_MobileStudio) · [**CCS PPG Studio**](https://github.com/CCS-NIMHANS/CCS_PPGStudio)
