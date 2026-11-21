use anyhow::{bail, Context, Result};
use faer::Mat;
use ndarray::{Array2, ArrayView2, ArrayView3, ArrayView4, Axis};
use std::f64::consts::PI;
use std::path::Path;

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

    let valid_cols = detrend_and_standardize_cols(&mut raw);
    if valid_cols.is_empty() {
        bail!("aCompCor mask has zero non-constant voxels");
    }

    let faer_mat = Mat::<f64>::from_fn(nt, valid_cols.len(), |r, c| raw[[r, valid_cols[c]]]);
    let svd = faer_mat
        .thin_svd()
        .map_err(|e| anyhow::anyhow!("aCompCor SVD failed: {e:?}"))?;
    let u = svd.U();
    let keep = n_components.min(u.ncols());

    let mut comps = Array2::<f64>::zeros((nt, keep));
    for r in 0..nt {
        for c in 0..keep {
            comps[[r, c]] = u[(r, c)];
        }
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

/// Performs single-step simultaneous nuisance regression + DCT stopband filtering + scrubbing
/// using an orthonormal SVD basis `Q` (`Y_clean = Y - Q (Q^T Y)`).
pub fn simultaneous_denoise(
    timeseries: ArrayView2<'_, f64>,
    confounds: Option<ArrayView2<'_, f64>>,
    tr_sec: f64,
    low_hz: Option<f64>,
    high_hz: Option<f64>,
    fd_scrub_indices: &[usize],
    zscore_output: bool,
) -> Result<Array2<f64>> {
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

    let dct = build_dct_stopband_basis(nt, tr_sec, low_hz, high_hz);

    // Collect design columns into column-major flat storage.
    let mut columns: Vec<Vec<f64>> = Vec::new();

    // 1. Intercept (constant)
    let inv_sqrt_n = 1.0 / (nt as f64).sqrt();
    columns.push(vec![inv_sqrt_n; nt]);

    // 2. Centered linear trend
    let t_mean = (nt as f64 - 1.0) * 0.5;
    let mut trend: Vec<f64> = (0..nt).map(|t| t as f64 - t_mean).collect();
    let trend_norm = trend.iter().map(|v| v * v).sum::<f64>().sqrt();
    if trend_norm > 1e-12 {
        for v in &mut trend {
            *v /= trend_norm;
        }
        columns.push(trend);
    }

    // 3. Confounds (standardized to unit norm for SVD conditioning)
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

    // 4. Scrubbing spike regressors
    let mut unique_spikes: Vec<usize> = fd_scrub_indices.iter().copied().filter(|&i| i < nt).collect();
    unique_spikes.sort_unstable();
    unique_spikes.dedup();
    for idx in unique_spikes {
        let mut spike = vec![0.0_f64; nt];
        spike[idx] = 1.0;
        columns.push(spike);
    }

    // 5. DCT stopband basis
    for j in 0..dct.ncols() {
        columns.push(dct.column(j).to_vec());
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

    let valid_rois: Vec<usize> = (0..n_rois)
        .filter(|&c| timeseries.column(c).iter().all(|v| v.is_finite()))
        .collect();
    if valid_rois.is_empty() {
        return Ok(Array2::from_elem((nt, n_rois), f64::NAN));
    }

    let y_mat = Mat::<f64>::from_fn(nt, valid_rois.len(), |r, c| timeseries[[r, valid_rois[c]]]);
    let y_clean_mat = if keep_cols.is_empty() {
        y_mat
    } else {
        let q = Mat::<f64>::from_fn(nt, keep_cols.len(), |r, c| u[(r, keep_cols[c])]);
        let qt_y = q.transpose() * &y_mat;
        &y_mat - (&q * &qt_y)
    };

    let mut out = Array2::<f64>::from_elem((nt, n_rois), f64::NAN);
    for (vc_idx, &roi_c) in valid_rois.iter().enumerate() {
        for r in 0..nt {
            out[[r, roi_c]] = y_clean_mat[(r, vc_idx)];
        }
        if zscore_output {
            let mut sum = 0.0_f64;
            for r in 0..nt {
                sum += out[[r, roi_c]];
            }
            let mean = sum / (nt as f64);
            let mut ss = 0.0_f64;
            for r in 0..nt {
                let d = out[[r, roi_c]] - mean;
                out[[r, roi_c]] = d;
                ss += d * d;
            }
            let std = (ss / ((nt - 1) as f64)).sqrt();
            if std > 1e-12 {
                for r in 0..nt {
                    out[[r, roi_c]] /= std;
                }
            }
        }
    }

    Ok(out)
}

/// Loads BIDS-style confounds TSV (motion + derivatives) and identifies scrubbing frame indices.
pub fn load_confounds_tsv(
    path: &Path,
    expected_rows: usize,
    fd_threshold_mm: f64,
) -> Result<(Array2<f64>, Vec<usize>)> {
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
    for (r, row) in rows.iter().enumerate() {
        for (c_out, &c_in) in reg_cols.iter().enumerate() {
            mat[[r, c_out]] = *row.get(c_in).unwrap_or(&0.0);
        }
        if let Some(fc) = fd_col {
            if fd_threshold_mm > 0.0 && *row.get(fc).unwrap_or(&0.0) > fd_threshold_mm {
                scrub.push(r);
            }
        }
    }

    Ok((mat, scrub))
}
