# 3. Rust Denoising, Parcellation & Connectivity

The native Rust engine (`rust/src/`) handles high-throughput 4D array operations, parcellation extraction, CONN-style denoising, connectivity computation, and zero-copy slice rendering.

---

## 1. Parallel Schaefer Parcellation (`parcellation.rs`)

`extract_roi_timeseries(bold, atlas)` builds an index of `[x, y, z]` voxel coordinates per positive parcel label once, then iterates across all `T` volumes in parallel using `rayon`:
- Because NIfTI arrays are Fortran-ordered (`[X, Y, Z, T]`), each 3D volume `bold.index_axis(Axis(3), t)` is contiguous in memory.
- On `99 × 117 × 95 × 450` (`400` Schaefer ROIs), extraction takes **28.20 ms** median on `.nii` (`memmap2`) and **16.94 ms** median once in-memory from `.nii.gz`.

---

## 2. CONN-Style aCompCor (`denoise.rs`)

`compute_acompcor(bold, mask, n_components)` extracts all foreground voxels (`mask > 0`) into a `(T × V_mask)` `f64` matrix:
1. Removes each voxel's mean and linear trend (`detrend_and_standardize_cols`), dropping constant/zero-variance voxels.
2. Computes thin SVD via `faer::Mat::thin_svd()` and retains the top `n_components` (default 5 WM + 5 CSF = 10 aCompCor regressors).

---

## 3. Simultaneous Orthogonalized Denoising (`denoise.rs`)

Applying temporal bandpass filtering and nuisance regression sequentially can re-introduce nuisance variance into filtered frequencies (Hallquist et al., 2013; Lindquist et al., 2019). `simultaneous_denoise` eliminates this pitfall via a single orthogonalized projection matrix:

1. **Combined Design Matrix $X$ (`T × P`)**:
   - Constant intercept ($1 / \sqrt{N}$) + centered linear drift
   - Standardized motion parameters + temporal derivatives + WM/CSF aCompCor components
   - One-hot FD scrubbing spike regressors ($1$ at censored frame $t_i$, $0$ elsewhere) for `FD > threshold`
   - **DCT-II Stopband Basis** (`build_dct_stopband_basis`):
     - High-pass modes ($f_k \le f_{\text{low}}$): $k \in [1, \lfloor 2 N \cdot \text{TR} \cdot f_{\text{low}} \rfloor]$
     - Low-pass modes ($f_k \ge f_{\text{high}}$): $k \in [\lceil 2 N \cdot \text{TR} \cdot f_{\text{high}} \rceil, N - 1]$
     - Basis vectors: $c_k(n) = \sqrt{\frac{2}{N}} \cos\left(\frac{\pi k (n + 0.5)}{N}\right)$
2. **Orthonormal Basis $Q$ via `faer` SVD**:
   Singular vectors of $X$ with $\sigma_i > 10^{-10} \sigma_{\max}$ form an orthonormal basis $Q \in \mathbb{R}^{T \times r}$.
3. **Single-Step Projection**:
   $$Y_{\text{clean}} = Y - Q (Q^T Y)$$
   followed by optional sample z-scoring (`ddof = 1`).

---

## 4. Static & Sliding-Window Connectivity (`connectivity.rs`) & Slice Rendering (`nifti_io.rs`)

- `static_fc_pearson`: Zero-mean, unit-norm columns followed by $Z^T Z$ clamped to $[-1, 1]$ (`2.81 ms` median for 400×400).
- `sliding_window_fc`: Windowed correlation matrices across `(window_len, step)` for dynamic FC workflows.
- `render_ortho_slice_rgba`: Extracts axial, coronal, or sagittal slices at any `(slice_idx, timepoint)`, applies 2nd–98th percentile contrast normalization over finite positive brain voxels, and returns an RGBA8888 `Uint8List` for `ui.decodeImageFromPixels`.
