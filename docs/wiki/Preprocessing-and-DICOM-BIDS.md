# 2. Preprocessing & DICOM / BIDS Ingestion

The Python sidecar (`python_sidecar/src/ccs_fmri_sidecar/`) converts clinical DICOM directories into BIDS-compliant NIfTI volumes and runs a fast, reproducible ANTsPy structural + functional preprocessing workflow.

---

## Stage 1: DICOM to NIfTI + BIDS JSON (`dicom_convert.py`)

Siemens mosaic `.IMA` files pack all axial slices of a single fMRI volume into a 2D mosaic image with CSA slice-timing headers. `dicom_convert.py` invokes `dcm2niix -z y -b y` into isolated per-modality staging directories and automatically selects:
- **3D T1w anatomical** (`t1w.nii.gz` + `t1w.json`)
- **4D BOLD timeseries** (`bold.nii.gz` + `bold.json`) with verified `RepetitionTime` (`TR`) and `SliceTiming` arrays.

```bash
cd python_sidecar
uv run python -m ccs_fmri_sidecar.dicom_convert \
  --t1-dicom /path/to/T1_DICOM_DIR \
  --bold-dicom /path/to/BOLD_DICOM_DIR \
  --out ../data_test_output/subject/raw
```

---

## Stage 2: ANTsPy Preprocessing (`preprocess.py`)

```mermaid
flowchart TD
  T1["Raw T1w"] --> N4["1. N4 bias correction"]
  N4 --> BET["2. Brain extraction<br/>head-to-head SyN to MNI152NLin6Asym,<br/>back-projected template brain mask, N4 in mask"]
  BET --> SEG["3. Atropos 3-class on winsorised brain<br/>WM P&gt;0.9 eroded, ventricular CSF P&gt;0.9"]
  BET --> MNIREG["4. Brain-to-brain SyNQuick to MNI152NLin6Asym"]
  BOLD["Raw 4D BOLD"] --> STC["5. Slice-timing correction (Fourier, mid-TR)"]
  STC --> MOCO["6. Per-volume rigid registration to mean BOLD<br/>quality-checked, parallel; FD -> confounds.tsv"]
  STC --> COREG["7. BOLD reference -> T1w brain (rigid)"]
  MOCO --> WARP["8. One interpolation per volume:<br/>normalisation ∘ coregistration ∘ motion -> 2 mm MNI152NLin6Asym"]
  COREG --> WARP
  MNIREG --> WARP
  SEG --> MASKWARP["WM / CSF / GM / brain masks -> MNI"]
  MNIREG --> MASKWARP
  WARP --> SCH["9. Schaefer-400 in native FSL MNI152 2 mm grid + parcel EPI coverage"]
  WARP --> QC["10. qc_report.html + preprocess_report.json QC block"]
```

> **v0.5.0 note:** versions ≤ 0.4.1 registered the whole-head T1w to a skull-stripped template and built aCompCor masks
> from a whole-head segmentation; their outputs should be regenerated. See `CHANGELOG.md`.

### Confounds Schema (`confounds.tsv`)

Each row corresponds to one fMRI volume (`0..T-1`), with columns:
- **6 Rigid-Body Parameters**: `trans_x`, `trans_y`, `trans_z` (mm, extracted from ITK `AffineTransform` translations) and `rot_x`, `rot_y`, `rot_z` (radians, SVD-projected orthonormal rotation matrix converted via `scipy.spatial.transform.Rotation.as_euler('xyz')`).
- **6 Temporal Derivatives**: `trans_{x,y,z}_derivative1`, `rot_{x,y,z}_derivative1` (`0` at `t=0`, backward difference `x[t] - x[t-1]` for `t >= 1`).
- **Motion Summary**:
  - `framewise_displacement`: Power et al. (2012) FD on a 50 mm radius sphere:
    $$\text{FD}_t = |\Delta t_x| + |\Delta t_y| + |\Delta t_z| + 50 \left(|\Delta r_x| + |\Delta r_y| + |\Delta r_z|\right)$$
  - `ants_fd`: duplicate of `framewise_displacement` kept for backward compatibility (not used as a regressor).

### Real-World Run on `Patient_01/pre` (Apple Silicon, 24 GB RAM)

- **Raw Inputs**: T1w `176 × 256 × 256` (`1.0 mm` iso), BOLD `64 × 64 × 40 × 450` (`3.44 × 3.44 × 4.25 mm`, `TR = 2.0 s`).
- **MNI Outputs**: `bold_mni.nii` / `bold_mni.nii.gz` (`99 × 117 × 95 × 450`), `400` Schaefer ROIs, `6,450` WM mask voxels, `40,457` CSF mask voxels.
- **Total Wall-Clock Time**: **101.93 s** (`1.70 min`), Peak RSS: **7,226.97 MB**.
