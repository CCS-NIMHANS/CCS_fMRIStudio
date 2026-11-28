use anyhow::{bail, Context, Result};
use faer::Mat;
use ndarray::{Array2, ArrayView2, ArrayView3, ArrayView4, Axis};
use std::f64::consts::PI;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CensorMode {
    Interpolate,
    Spike,
    None,
}

impl CensorMode {
    pub fn from_str_opt(s: Option<&str>) -> Self {
        // Default: simultaneous nuisance + DCT + spike regression, i.e. the model is fitted on
        // retained frames only, equivalent to AFNI `3dTproject -cenmode KILL`.
        match s.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
            Some("interpolate") => CensorMode::Interpolate,
            Some("none") => CensorMode::None,
            _ => CensorMode::Spike,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            CensorMode::Interpolate => "interpolate",
            CensorMode::Spike => "spike",
            CensorMode::None => "none",
        }
    }
}

#[derive(Clone, Debug)]
pub struct DenoiseResult {
    /// Cleaned series for all `T` frames (censored frames are interpolated / spike-fitted so that
    /// plots stay contiguous). Use [`DenoiseResult::kept_rows`] before computing any statistic.
    pub clean_ts: Array2<f64>,
    pub n_regressors: usize,
    /// Residual degrees of freedom: `n_kept - rank([nuisance, DCT stopband])`
    /// (censored frames are never counted as data; Power et al., 2014).
    pub dof_remaining: usize,
    /// Indices of frames retained for statistics (FD-censored frames removed).
    pub kept_rows: Vec<usize>,
}

impl DenoiseResult {
    /// Returns the cleaned series restricted to retained (uncensored) frames.
    pub fn kept_ts(&self) -> Array2<f64> {
        select_rows(self.clean_ts.view(), &self.kept_rows)
    }
}

/// Copies the given rows of `(T, N)` matrix into a new `(rows.len(), N)` matrix.
pub fn select_rows(mat: ArrayView2<'_, f64>, rows: &[usize]) -> Array2<f64> {
    let mut out = Array2::<f64>::zeros((rows.len(), mat.ncols()));
    for (r_out, &r) in rows.iter().enumerate() {
        out.row_mut(r_out).assign(&mat.row(r));
    }
    out
}

/// Linearly interpolates across contiguous motion-scrubbed timepoints per ROI column
/// (Power et al., 2014), clamping leading/trailing spans to nearest intact boundary.
pub fn linear_interpolate_scrubbed(mat: &mut Array2<f64>, scrub_indices: &[usize]) {
    let (nt, n_cols) = mat.dim();
    if nt < 2 || scrub_indices.is_empty() {
        return;
    }
    let mut is_bad = vec![false; nt];
    let mut any_bad = false;
    for &idx in scrub_indices {
        if idx < nt {
            is_bad[idx] = true;
            any_bad = true;
        }
    }
    if !any_bad {
        return;
    }
    let intact_count = is_bad.iter().filter(|&&b| !b).count();
    if intact_count == 0 {
        return;
    }

    for col in 0..n_cols {
        if mat.column(col).iter().any(|v| !v.is_finite()) {
            continue;
        }
        let mut t = 0_usize;
        while t < nt {
            if !is_bad[t] {
                t += 1;
                continue;
            }
            let start = t;
            while t < nt && is_bad[t] {
                t += 1;
            }
            let end = t - 1;
            if start == 0 {
                let anchor = mat[[end + 1, col]];
                for k in 0..=end {
                    mat[[k, col]] = anchor;
                }
            } else if end + 1 >= nt {
                let anchor = mat[[start - 1, col]];
                for k in start..nt {
                    mat[[k, col]] = anchor;
                }
            } else {
                let left = mat[[start - 1, col]];
                let right = mat[[end + 1, col]];
                let span = ((end + 1) - (start - 1)) as f64;
                for k in start..=end {
                    let frac = (k - (start - 1)) as f64 / span;
                    mat[[k, col]] = left + frac * (right - left);
                }
            }
        }
    }
}

fn detrend_and_standardize_cols(mat: &mut Array2<f64>) -> Vec<usize> {
    let (nt, ncols) = mat.dim();
    let t_mean = (nt as f64 - 1.0) * 0.5;
    let mut t_ss = 0.0_f64;
    for t in 0..nt {
        let dt = t as f64 - t_mean;
        t_ss += dt * dt;
    }

    let mut valid_cols = Vec::with_capacity(ncols);
    for c in 0..ncols {
        let mut sum = 0.0_f64;
        for t in 0..nt {
            sum += mat[[t, c]];
        }
        let mean = sum / (nt as f64);

        let mut cov = 0.0_f64;
        for t in 0..nt {
            cov += (t as f64 - t_mean) * (mat[[t, c]] - mean);
        }
        let slope = if t_ss > 1e-12 { cov / t_ss } else { 0.0 };

        let mut var_sum = 0.0_f64;
        for t in 0..nt {
            let v = (mat[[t, c]] - mean) - slope * (t as f64 - t_mean);
            mat[[t, c]] = v;
            var_sum += v * v;
        }
        let std = (var_sum / ((nt.saturating_sub(1)).max(1) as f64)).sqrt();
        if std > 1e-10 {
            for t in 0..nt {
                mat[[t, c]] /= std;
            }
            valid_cols.push(c);
        }
    }
    valid_cols
}

/// Computes CONN-style aCompCor top-`n_components` PCA components from a 3D ROI mask (WM or CSF).
pub fn compute_acompcor(
    bold: ArrayView4<'_, f32>,
    mask: ArrayView3<'_, u8>,
    n_components: usize,
) -> Result<Array2<f64>> {
    compute_acompcor_filtered(bold, mask, n_components, 0.0, None)
}

/// aCompCor (Behzadi et al., 2007) as implemented in fMRIPrep/nipype: voxel series are
/// high-pass filtered with a DCT basis (`high_pass_hz`, e.g. 0.008 Hz) and linearly detrended
/// *before* variance normalisation and SVD, so slow drifts do not dominate the components.
pub fn compute_acompcor_filtered(
    bold: ArrayView4<'_, f32>,
    mask: ArrayView3<'_, u8>,
    n_components: usize,
    tr_sec: f64,
    high_pass_hz: Option<f64>,
) -> Result<Array2<f64>> {
    let bshape = bold.shape();
    let mshape = mask.shape();
    if bshape[0] != mshape[0] || bshape[1] != mshape[1] || bshape[2] != mshape[2] {
        bail!(
            "Spatial shape mismatch: BOLD {:?} vs Mask {:?}",
            &bshape[..3],
            mshape
        );
    }
    if n_components == 0 {
        return Ok(Array2::zeros((bshape[3], 0)));
    }

    let (nx, ny, nz, nt) = (bshape[0], bshape[1], bshape[2], bshape[3]);
    let mut coords = Vec::new();
    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                if mask[[x, y, z]] > 0 {
                    coords.push([x, y, z]);
                }
            }
        }
    }
    if coords.is_empty() {
        bail!("aCompCor mask contains zero foreground voxels");
    }

    let mut raw = Array2::<f64>::zeros((nt, coords.len()));
    for t in 0..nt {
        let vol = bold.index_axis(Axis(3), t);
        for (v_idx, &[x, y, z]) in coords.iter().enumerate() {
            let val = vol[[x, y, z]];
            raw[[t, v_idx]] = if val.is_finite() { val as f64 } else { 0.0 };
        }
    }

    if let Some(hp) = high_pass_hz {
        if hp > 0.0 && tr_sec > 0.0 {
            let dct = build_dct_stopband_basis(nt, tr_sec, Some(hp), None);
            if dct.ncols() > 0 {
                let mut cols = build_nuisance_columns(nt, None);
                for j in 0..dct.ncols() {
                    cols.push(dct.column(j).to_vec());
                }
                let y = Mat::<f64>::from_fn(nt, raw.ncols(), |r, c| raw[[r, c]]);
                let (resid, _) = project_orthonormal(&cols, nt, &y)?;
                for r in 0..nt {
                    for c in 0..raw.ncols() {
                        raw[[r, c]] = resid[(r, c)];
                    }
                }
            }
        }
    }

    let valid_cols = detrend_and_standardize_cols(&mut raw);
    if valid_cols.is_empty() {
        bail!("aCompCor mask has zero non-constant voxels");
    }

    let comps = top_left_singular_vectors(&raw, &valid_cols, n_components)?;
    Ok(comps)
}

/// Leading left singular vectors of `raw[:, cols]` (T x V). Uses the thin SVD and, if that returns
/// non-finite values (observed for some 729 x 3526 inputs), the SVD of the T x T Gram matrix
/// `X X^T = U S^2 U^T`, which is small and well conditioned for T << V.
fn top_left_singular_vectors(raw: &Array2<f64>, cols: &[usize], n_components: usize) -> Result<Array2<f64>> {
    let nt = raw.nrows();
    let x = Mat::<f64>::from_fn(nt, cols.len(), |r, c| raw[[r, cols[c]]]);
    let extract = |u: faer::MatRef<'_, f64>| -> Array2<f64> {
        let keep = n_components.min(u.ncols());
        Array2::from_shape_fn((nt, keep), |(r, c)| u[(r, c)])
    };
    if let Ok(svd) = x.thin_svd() {
        let comps = extract(svd.U());
        if comps.iter().all(|v| v.is_finite()) {
            return Ok(comps);
        }
    }
    let gram = &x * x.transpose();
    let svd = gram
        .thin_svd()
        .map_err(|e| anyhow::anyhow!("aCompCor Gram SVD failed: {e:?}"))?;
    let comps = extract(svd.U());
    if !comps.iter().all(|v| v.is_finite()) {
        bail!("aCompCor decomposition produced non-finite components");
    }
    Ok(comps)
}

/// Builds DCT-II stopband cosine regressors matching nilearn's `create_cosine_drift` convention:
/// - `k in 1..=floor(2 * N * tr * low_hz)` remove frequencies `<= low_hz` (high-pass)
/// - `k in ceil(2 * N * tr * high_hz)..N` remove frequencies `>= high_hz` (low-pass)
pub fn build_dct_stopband_basis(
    n_timepoints: usize,
    tr_sec: f64,
    low_hz: Option<f64>,
    high_hz: Option<f64>,
) -> Array2<f64> {
    if n_timepoints < 2 || tr_sec <= 0.0 {
        return Array2::zeros((n_timepoints, 0));
    }
    let total_window = 2.0 * (n_timepoints as f64) * tr_sec;
    let nyquist = 0.5 / tr_sec;

    let mut ks = Vec::new();
    if let Some(lo) = low_hz {
        if lo > 0.0 {
            let max_k = (total_window * lo).floor() as usize;
            let max_k = max_k.min(n_timepoints - 1);
            for k in 1..=max_k {
                ks.push(k);
            }
        }
    }
    if let Some(hi) = high_hz {
        if hi > 0.0 && hi < nyquist {
            let min_k = ((total_window * hi).ceil() as usize).max(1);
            let start_k = ks.last().map_or(min_k, |&last| min_k.max(last + 1));
            for k in start_k..n_timepoints {
                ks.push(k);
            }
        }
    }

    let norm = (2.0 / (n_timepoints as f64)).sqrt();
    let mut basis = Array2::<f64>::zeros((n_timepoints, ks.len()));
    for (col_idx, &k) in ks.iter().enumerate() {
        let freq_factor = (PI / (n_timepoints as f64)) * (k as f64);
        for t in 0..n_timepoints {
            basis[[t, col_idx]] = norm * (freq_factor * (t as f64 + 0.5)).cos();
        }
    }
    basis
}

fn build_nuisance_columns(
    nt: usize,
    confounds: Option<ArrayView2<'_, f64>>,
) -> Vec<Vec<f64>> {
    let mut columns: Vec<Vec<f64>> = Vec::new();
    let inv_sqrt_n = 1.0 / (nt as f64).sqrt();
    columns.push(vec![inv_sqrt_n; nt]);

    let t_mean = (nt as f64 - 1.0) * 0.5;
    let mut trend: Vec<f64> = (0..nt).map(|t| t as f64 - t_mean).collect();
    let trend_norm = trend.iter().map(|v| v * v).sum::<f64>().sqrt();
    if trend_norm > 1e-12 {
        for v in &mut trend {
            *v /= trend_norm;
        }
        columns.push(trend);
    }

    if let Some(conf) = confounds {
        for j in 0..conf.ncols() {
            let mut col: Vec<f64> = conf.column(j).to_vec();
            let mean = col.iter().sum::<f64>() / (nt as f64);
            let mut ss = 0.0_f64;
            for v in &mut col {
                *v -= mean;
                ss += *v * *v;
            }
            let norm = ss.sqrt();
            if norm > 1e-12 {
                for v in &mut col {
                    *v /= norm;
                }
                columns.push(col);
            }
        }
    }
    columns
}

fn project_orthonormal(columns: &[Vec<f64>], nt: usize, y_mat: &Mat<f64>) -> Result<(Mat<f64>, usize)> {
    if columns.is_empty() {
        return Ok((y_mat.clone(), 0));
    }
    let p = columns.len();
    let x_mat = Mat::<f64>::from_fn(nt, p, |r, c| columns[c][r]);
    let svd = x_mat
        .thin_svd()
        .map_err(|e| anyhow::anyhow!("Design matrix SVD failed: {e:?}"))?;
    let s = svd.S();
    let u = svd.U();

    let s_max = (0..u.ncols())
        .map(|i| s[i].abs())
        .fold(0.0_f64, f64::max);
    let tol = s_max * 1e-10;
    let keep_cols: Vec<usize> = (0..u.ncols()).filter(|&i| s[i] > tol).collect();
    if keep_cols.is_empty() {
        return Ok((y_mat.clone(), 0));
    }
    let q = Mat::<f64>::from_fn(nt, keep_cols.len(), |r, c| u[(r, keep_cols[c])]);
    let qt_y = q.transpose() * y_mat;
    Ok((y_mat - (&q * &qt_y), keep_cols.len()))
}

fn regress_nuisance_on_intact_and_interpolate(
    y_mat: &Mat<f64>,
    nuis_cols: &[Vec<f64>],
    dct: &Array2<f64>,
    unique_spikes: &[usize],
    nt: usize,
) -> Result<(Mat<f64>, usize)> {
    let mut is_bad = vec![false; nt];
    for &idx in unique_spikes {
        is_bad[idx] = true;
    }
    let good_rows: Vec<usize> = (0..nt).filter(|&t| !is_bad[t]).collect();
    let nuis_p = nuis_cols.len();
    let nv = y_mat.ncols();

    let mut resid = Array2::<f64>::zeros((nt, nv));

    let nuis_rank = if good_rows.len() > nuis_p + 2 && nuis_p > 0 {
        let x_good = Mat::<f64>::from_fn(good_rows.len(), nuis_p, |r, c| nuis_cols[c][good_rows[r]]);
        let y_good = Mat::<f64>::from_fn(good_rows.len(), nv, |r, c| y_mat[(good_rows[r], c)]);
        let svd = x_good
            .thin_svd()
            .map_err(|e| anyhow::anyhow!("Nuisance OLS SVD failed: {e:?}"))?;
        let s = svd.S();
        let u = svd.U();
        let v = svd.V();

        let s_max = (0..u.ncols()).map(|i| s[i].abs()).fold(0.0_f64, f64::max);
        let tol = s_max * 1e-10;
        let keep: Vec<usize> = (0..u.ncols()).filter(|&i| s[i] > tol).collect();

        let y_resid_mat = if keep.is_empty() {
            y_mat.clone()
        } else {
            let k = keep.len();
            let u_k = Mat::<f64>::from_fn(good_rows.len(), k, |r, c| u[(r, keep[c])]);
            let v_k = Mat::<f64>::from_fn(nuis_p, k, |r, c| v[(r, keep[c])]);
            let mut ut_y = u_k.transpose() * &y_good;
            for r in 0..k {
                let inv_s = 1.0 / s[keep[r]];
                for c in 0..nv {
                    ut_y[(r, c)] *= inv_s;
                }
            }
            let beta = &v_k * &ut_y;
            let x_full = Mat::<f64>::from_fn(nt, nuis_p, |r, c| nuis_cols[c][r]);
            y_mat - (&x_full * &beta)
        };
        for r in 0..nt {
            for c in 0..nv {
                resid[[r, c]] = y_resid_mat[(r, c)];
            }
        }
        linear_interpolate_scrubbed(&mut resid, unique_spikes);
        keep.len()
    } else {
        for r in 0..nt {
            for c in 0..nv {
                resid[[r, c]] = y_mat[(r, c)];
            }
        }
        linear_interpolate_scrubbed(&mut resid, unique_spikes);
        let resid_mat = Mat::<f64>::from_fn(nt, nv, |r, c| resid[[r, c]]);
        let (projected, r_rank) = project_orthonormal(nuis_cols, nt, &resid_mat)?;
        for r in 0..nt {
            for c in 0..nv {
                resid[[r, c]] = projected[(r, c)];
            }
        }
        r_rank
    };

    // Remove DC, linear drift & stopband frequencies on the interpolated signal so
    // censoring spikes does not create flat-zero plateaus or ring into bandpass.
    let mut bp_cols = build_nuisance_columns(nt, None);
    for j in 0..dct.ncols() {
        bp_cols.push(dct.column(j).to_vec());
    }
    let resid_mat = Mat::<f64>::from_fn(nt, nv, |r, c| resid[[r, c]]);
    let (clean_mat, _) = project_orthonormal(&bp_cols, nt, &resid_mat)?;
    let n_reg = (nuis_rank + dct.ncols()).min(nt);
    Ok((clean_mat, n_reg))
}

/// Numerical rank of the design matrix (columns) restricted to `rows`.
fn rank_on_rows(columns: &[Vec<f64>], rows: &[usize]) -> Result<usize> {
    if columns.is_empty() || rows.is_empty() {
        return Ok(0);
    }
    let x = Mat::<f64>::from_fn(rows.len(), columns.len(), |r, c| columns[c][rows[r]]);
    let svd = x.thin_svd().map_err(|e| anyhow::anyhow!("Rank SVD failed: {e:?}"))?;
    let sv = svd.S();
    let k = rows.len().min(columns.len());
    let s_max = (0..k).map(|i| sv[i].abs()).fold(0.0_f64, f64::max);
    Ok((0..k).filter(|&i| sv[i].abs() > s_max * 1e-10).count())
}

/// Performs single-step simultaneous nuisance regression + DCT stopband filtering + selectable censoring.
pub fn simultaneous_denoise_with_mode(
    timeseries: ArrayView2<'_, f64>,
    confounds: Option<ArrayView2<'_, f64>>,
    tr_sec: f64,
    low_hz: Option<f64>,
    high_hz: Option<f64>,
    fd_scrub_indices: &[usize],
    censor_mode: CensorMode,
    zscore_output: bool,
) -> Result<DenoiseResult> {
    let (nt, n_rois) = timeseries.dim();
    if nt < 4 {
        bail!("Need at least 4 timepoints for denoising, got {nt}");
    }
    if let Some(conf) = confounds {
        if conf.nrows() != nt {
            bail!(
                "Confounds row count ({}) does not match timeseries timepoints ({nt})",
                conf.nrows()
            );
        }
    }

    let mut unique_spikes: Vec<usize> = fd_scrub_indices.iter().copied().filter(|&i| i < nt).collect();
    unique_spikes.sort_unstable();
    unique_spikes.dedup();
    let kept_rows: Vec<usize> = if censor_mode == CensorMode::None {
        (0..nt).collect()
    } else {
        (0..nt).filter(|t| unique_spikes.binary_search(t).is_err()).collect()
    };
    let n_kept = kept_rows.len();

    let valid_rois: Vec<usize> = (0..n_rois)
        .filter(|&c| timeseries.column(c).iter().all(|v| v.is_finite()))
        .collect();
    if valid_rois.is_empty() {
        return Ok(DenoiseResult {
            clean_ts: Array2::from_elem((nt, n_rois), f64::NAN),
            n_regressors: 0,
            dof_remaining: n_kept,
            kept_rows,
        });
    }

    let dct = build_dct_stopband_basis(nt, tr_sec, low_hz, high_hz);
    let mut columns = build_nuisance_columns(nt, confounds);

    let y_mat = Mat::<f64>::from_fn(nt, valid_rois.len(), |r, c| timeseries[[r, valid_rois[c]]]);

    let (y_clean_mat, n_regressors) = match censor_mode {
        CensorMode::Interpolate if !unique_spikes.is_empty() => {
            regress_nuisance_on_intact_and_interpolate(&y_mat, &columns, &dct, &unique_spikes, nt)?
        }
        CensorMode::Spike => {
            for &idx in &unique_spikes {
                let mut spike = vec![0.0_f64; nt];
                spike[idx] = 1.0;
                columns.push(spike);
            }
            for j in 0..dct.ncols() {
                columns.push(dct.column(j).to_vec());
            }
            project_orthonormal(&columns, nt, &y_mat)?
        }
        _ => {
            for j in 0..dct.ncols() {
                columns.push(dct.column(j).to_vec());
            }
            project_orthonormal(&columns, nt, &y_mat)?
        }
    };

    let mut out = Array2::<f64>::from_elem((nt, n_rois), f64::NAN);
    for (vc_idx, &roi_c) in valid_rois.iter().enumerate() {
        for r in 0..nt {
            out[[r, roi_c]] = y_clean_mat[(r, vc_idx)];
        }
        if zscore_output && n_kept > 1 {
            let mut sum = 0.0_f64;
            for &r in &kept_rows {
                sum += out[[r, roi_c]];
            }
            let mean = sum / (n_kept as f64);
            let mut ss = 0.0_f64;
            for r in 0..nt {
                out[[r, roi_c]] -= mean;
            }
            for &r in &kept_rows {
                ss += out[[r, roi_c]] * out[[r, roi_c]];
            }
            let std = (ss / ((n_kept - 1) as f64)).sqrt();
            if std > 1e-12 {
                for r in 0..nt {
                    out[[r, roi_c]] /= std;
                }
            }
        }
    }

    // Residual DOF = retained frames minus the rank of the (non-spike) design restricted to those
    // frames. For spike regression this equals T - rank([design, spikes]).
    let dof_remaining = if censor_mode == CensorMode::Spike {
        nt.saturating_sub(n_regressors)
    } else {
        let mut design = build_nuisance_columns(nt, confounds);
        for j in 0..dct.ncols() {
            design.push(dct.column(j).to_vec());
        }
        n_kept.saturating_sub(rank_on_rows(&design, &kept_rows)?)
    };
    Ok(DenoiseResult {
        clean_ts: out,
        n_regressors,
        dof_remaining,
        kept_rows,
    })
}

/// Performs single-step simultaneous nuisance regression + DCT stopband filtering + spike scrubbing.
pub fn simultaneous_denoise(
    timeseries: ArrayView2<'_, f64>,
    confounds: Option<ArrayView2<'_, f64>>,
    tr_sec: f64,
    low_hz: Option<f64>,
    high_hz: Option<f64>,
    fd_scrub_indices: &[usize],
    zscore_output: bool,
) -> Result<Array2<f64>> {
    Ok(simultaneous_denoise_with_mode(
        timeseries,
        confounds,
        tr_sec,
        low_hz,
        high_hz,
        fd_scrub_indices,
        CensorMode::Spike,
        zscore_output,
    )?
    .clean_ts)
}

/// Loads BIDS-style confounds TSV, returning regression columns, FD scrub indices, and FD mm trace.
pub fn load_confounds_with_fd(
    path: &Path,
    expected_rows: usize,
    fd_threshold_mm: f64,
) -> Result<(Array2<f64>, Vec<usize>, Vec<f32>)> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read confounds TSV from {}", path.display()))?;
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let header_line = lines.next().context("Empty confounds TSV")?;
    let headers: Vec<&str> = header_line.split('\t').collect();

    let mut reg_cols: Vec<usize> = Vec::new();
    let mut fd_col: Option<usize> = None;
    for (idx, &name) in headers.iter().enumerate() {
        if name == "framewise_displacement" {
            fd_col = Some(idx);
        } else if name != "ants_fd" {
            reg_cols.push(idx);
        }
    }

    let rows: Vec<Vec<f64>> = lines
        .map(|line| {
            line.split('\t')
                .map(|cell| cell.trim().parse::<f64>().unwrap_or(0.0))
                .collect::<Vec<f64>>()
        })
        .collect();

    if rows.len() != expected_rows {
        bail!(
            "Confounds TSV has {} rows, expected {}",
            rows.len(),
            expected_rows
        );
    }

    let mut mat = Array2::<f64>::zeros((rows.len(), reg_cols.len()));
    let mut scrub = Vec::new();
    let mut fd_trace = Vec::with_capacity(rows.len());
    for (r, row) in rows.iter().enumerate() {
        for (c_out, &c_in) in reg_cols.iter().enumerate() {
            mat[[r, c_out]] = *row.get(c_in).unwrap_or(&0.0);
        }
        let fd_val = fd_col.map_or(0.0, |fc| *row.get(fc).unwrap_or(&0.0));
        fd_trace.push(fd_val as f32);
        if fd_col.is_some() && fd_threshold_mm > 0.0 && fd_val > fd_threshold_mm {
            scrub.push(r);
        }
    }

    Ok((mat, scrub, fd_trace))
}

/// Loads BIDS-style confounds TSV (motion + derivatives) and identifies scrubbing frame indices.
pub fn load_confounds_tsv(
    path: &Path,
    expected_rows: usize,
    fd_threshold_mm: f64,
) -> Result<(Array2<f64>, Vec<usize>)> {
    let (mat, scrub, _) = load_confounds_with_fd(path, expected_rows, fd_threshold_mm)?;
    Ok((mat, scrub))
}
