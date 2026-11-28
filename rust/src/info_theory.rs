use anyhow::{bail, Result};
use faer::linalg::solvers::DenseSolveCore;
use faer::{Mat, Side};
use ndarray::{Array2, ArrayView2};
use rayon::prelude::*;

/// Inverse standard normal CDF (Acklam's rational approximation, error < 1.15e-9).
pub(crate) fn probit(p: f64) -> f64 {
    let p = p.clamp(1e-12, 1.0 - 1e-12);
    const A: [f64; 6] = [
        -3.969683028665376e+01,
        2.209460984245205e+02,
        -2.759285104469687e+02,
        1.383577518672690e+02,
        -3.066479806614716e+01,
        2.506628277459239e+00,
    ];
    const B: [f64; 5] = [
        -5.447609879822406e+01,
        1.615858368580409e+02,
        -1.556989798598866e+02,
        6.680131188771972e+01,
        -1.328068155288572e+01,
    ];
    const C: [f64; 6] = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e+00,
        -2.549732539343734e+00,
        4.374664141464968e+00,
        2.938163982698783e+00,
    ];
    const D: [f64; 4] = [
        7.784695709041462e-03,
        3.224671290700398e-01,
        2.445134137142996e+00,
        3.754408661907416e+00,
    ];
    const P_LOW: f64 = 0.02425;
    const P_HIGH: f64 = 1.0 - P_LOW;

    if p < P_LOW {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if p <= P_HIGH {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - p).ln()).sqrt();
        -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    }
}

/// Gaussian-copula normalization (Ince et al. 2017): average-tie empirical CDF -> standard normal.
pub fn copnorm(x: &[f64]) -> Vec<f64> {
    let n = x.len();
    if n == 0 {
        return Vec::new();
    }
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by(|&a, &b| x[a].total_cmp(&x[b]));

    let mut out = vec![0.0_f64; n];
    let denom = (n as f64) + 1.0;
    let mut i = 0_usize;
    while i < n {
        let mut j = i + 1;
        while j < n && (x[order[j]] - x[order[i]]).abs() == 0.0 {
            j += 1;
        }
        let avg_rank = 0.5 * ((i + j - 1) as f64);
        let z = probit((avg_rank + 1.0) / denom);
        for k in i..j {
            out[order[k]] = z;
        }
        i = j;
    }
    out
}

fn standardize_unit_norm(v: &[f64]) -> Option<Vec<f64>> {
    let n = v.len();
    if n < 2 {
        return None;
    }
    let mean = v.iter().sum::<f64>() / (n as f64);
    let mut out = Vec::with_capacity(n);
    let mut ss = 0.0_f64;
    for &val in v {
        let d = val - mean;
        out.push(d);
        ss += d * d;
    }
    let norm = ss.sqrt();
    if norm <= 1e-12 || !norm.is_finite() {
        return None;
    }
    for x in &mut out {
        *x /= norm;
    }
    Some(out)
}

#[inline]
fn dot(a: &[f64], b: &[f64]) -> f64 {
    let mut s = 0.0_f64;
    for (&x, &y) in a.iter().zip(b.iter()) {
        s += x * y;
    }
    s
}

/// Undirected Gaussian-Copula Mutual Information (GCMI, bits) matching Ince et al. (2017) & CCS_EEGStudio.
pub fn compute_gcmi_matrix(ts: ArrayView2<'_, f64>) -> Array2<f64> {
    let (nt, n_rois) = ts.dim();
    let mut intact = vec![false; n_rois];
    let mut norms: Vec<Option<Vec<f64>>> = vec![None; n_rois];

    norms.par_iter_mut().enumerate().for_each(|(r, slot)| {
        let col: Vec<f64> = (0..nt).map(|t| ts[[t, r]]).collect();
        if col.iter().all(|v| v.is_finite()) {
            let cn = copnorm(&col);
            *slot = standardize_unit_norm(&cn);
        }
    });
    for (r, slot) in norms.iter().enumerate() {
        intact[r] = slot.is_some();
    }

    let rows: Vec<Vec<f64>> = (0..n_rois)
        .into_par_iter()
        .map(|i| {
            let mut row = vec![f64::NAN; n_rois];
            if !intact[i] {
                return row;
            }
            let zi = norms[i].as_ref().unwrap();
            row[i] = 0.0;
            for j in 0..n_rois {
                if i == j || !intact[j] {
                    continue;
                }
                let zj = norms[j].as_ref().unwrap();
                let r = dot(zi, zj).clamp(-0.999999999999, 0.999999999999);
                let mi = -0.5 * (1.0 - r * r).max(1e-12).log2();
                row[j] = if mi.is_finite() && mi >= 0.0 { mi } else { 0.0 };
            }
            row
        })
        .collect();

    let mut out = Array2::<f64>::from_elem((n_rois, n_rois), f64::NAN);
    for (i, row) in rows.into_iter().enumerate() {
        for (j, v) in row.into_iter().enumerate() {
            out[[i, j]] = v;
        }
    }
    out
}

/// Directed Gaussian-Copula Transfer Entropy `TE(i -> j) = I(X_{t-lag}; Y_t | Y_{t-lag})` in bits.
pub fn compute_transfer_entropy_matrix(ts: ArrayView2<'_, f64>, lag: usize) -> Array2<f64> {
    compute_transfer_entropy_matrix_masked(ts, lag, None)
}

/// Gaussian-copula TE using only sample pairs `(t - lag, t)` where both frames are retained
/// (`valid[t] && valid[t - lag]`), so FD-censored (interpolated) frames never enter the estimate.
pub fn compute_transfer_entropy_matrix_masked(
    ts: ArrayView2<'_, f64>,
    lag: usize,
    valid: Option<&[bool]>,
) -> Array2<f64> {
    let (nt_full, n_rois) = ts.dim();
    let lag = lag.max(1);
    if nt_full <= lag + 4 {
        return Array2::from_elem((n_rois, n_rois), f64::NAN);
    }
    let pair_t: Vec<usize> = (lag..nt_full)
        .filter(|&t| valid.map_or(true, |v| v[t] && v[t - lag]))
        .collect();
    if pair_t.len() < 5 {
        return Array2::from_elem((n_rois, n_rois), f64::NAN);
    }
    let nt = pair_t.len() + lag; // so that `nt - lag` == number of usable pairs below

    let mut intact = vec![false; n_rois];
    let mut curr_norms: Vec<Option<Vec<f64>>> = vec![None; n_rois];
    let mut past_norms: Vec<Option<Vec<f64>>> = vec![None; n_rois];

    curr_norms
        .par_iter_mut()
        .zip(past_norms.par_iter_mut())
        .enumerate()
        .for_each(|(r, (c_slot, p_slot))| {
            let col: Vec<f64> = (0..nt_full).map(|t| ts[[t, r]]).collect();
            if col.iter().all(|v| v.is_finite()) {
                let curr: Vec<f64> = pair_t.iter().map(|&t| col[t]).collect();
                let past: Vec<f64> = pair_t.iter().map(|&t| col[t - lag]).collect();
                debug_assert_eq!(curr.len(), nt - lag);
                let cn_curr = copnorm(&curr);
                let cn_past = copnorm(&past);
                *c_slot = standardize_unit_norm(&cn_curr);
                *p_slot = standardize_unit_norm(&cn_past);
            }
        });

    for r in 0..n_rois {
        intact[r] = curr_norms[r].is_some() && past_norms[r].is_some();
    }

    // Target auto-correlation a_j = corr(Y_t, Y_{t-lag}).
    let auto_corr: Vec<f64> = (0..n_rois)
        .map(|j| {
            if intact[j] {
                dot(curr_norms[j].as_ref().unwrap(), past_norms[j].as_ref().unwrap())
                    .clamp(-0.999999, 0.999999)
            } else {
                0.0
            }
        })
        .collect();

    // Row i is source (X_{t-lag}), Column j is target (Y_t | Y_{t-lag}).
    let rows: Vec<Vec<f64>> = (0..n_rois)
        .into_par_iter()
        .map(|i| {
            let mut row = vec![f64::NAN; n_rois];
            if !intact[i] {
                return row;
            }
            let xi_past = past_norms[i].as_ref().unwrap();
            row[i] = 0.0;
            for j in 0..n_rois {
                if i == j || !intact[j] {
                    continue;
                }
                let yj_curr = curr_norms[j].as_ref().unwrap();
                let yj_past = past_norms[j].as_ref().unwrap();
                let a = auto_corr[j];
                let b = dot(yj_curr, xi_past).clamp(-0.999999, 0.999999);
                let c = dot(yj_past, xi_past).clamp(-0.999999, 0.999999);

                let num = (1.0 - a * a) * (1.0 - c * c);
                let den = (1.0 + 2.0 * a * b * c - a * a - b * b - c * c).max(1e-12);
                let te = 0.5 * (num / den).max(1.0).log2();
                row[j] = if te.is_finite() { te.max(0.0) } else { 0.0 };
            }
            row
        })
        .collect();

    let mut out = Array2::<f64>::from_elem((n_rois, n_rois), f64::NAN);
    for (i, row) in rows.into_iter().enumerate() {
        for (j, v) in row.into_iter().enumerate() {
            out[[i, j]] = v;
        }
    }
    out
}

/// Nilearn-style analytical Ledoit-Wolf shrinkage partial correlation (precision matrix inversion via Cholesky).
pub fn compute_partial_correlation_ledoit_wolf(ts: ArrayView2<'_, f64>) -> Result<Array2<f64>> {
    let (nt, n_rois) = ts.dim();
    if nt < 4 || n_rois == 0 {
        bail!("Need at least 4 timepoints and 1 ROI for partial correlation");
    }

    let mut intact_ids = Vec::new();
    let mut std_cols: Vec<Vec<f64>> = Vec::new();
    for r in 0..n_rois {
        let col: Vec<f64> = (0..nt).map(|t| ts[[t, r]]).collect();
        if col.iter().any(|v| !v.is_finite()) {
            continue;
        }
        let mean = col.iter().sum::<f64>() / (nt as f64);
        let centered: Vec<f64> = col.into_iter().map(|v| v - mean).collect();
        let var = centered.iter().map(|v| v * v).sum::<f64>() / (nt as f64);
        let sd = var.sqrt();
        if sd > 1e-12 && sd.is_finite() {
            intact_ids.push(r);
            std_cols.push(centered.into_iter().map(|v| v / sd).collect());
        }
    }

    let p = intact_ids.len();
    let mut out = Array2::<f64>::from_elem((n_rois, n_rois), f64::NAN);
    if p == 0 {
        return Ok(out);
    }
    if p == 1 {
        let r0 = intact_ids[0];
        out[[r0, r0]] = 1.0;
        return Ok(out);
    }

    // Sample covariance S = (1 / nt) X^T X (symmetric p x p).
    let inv_nt = 1.0 / (nt as f64);
    let mut s = Array2::<f64>::zeros((p, p));
    let s_rows: Vec<Vec<f64>> = (0..p)
        .into_par_iter()
        .map(|i| {
            let mut row = vec![0.0_f64; p];
            for j in 0..=i {
                row[j] = dot(&std_cols[i], &std_cols[j]) * inv_nt;
            }
            row
        })
        .collect();
    for i in 0..p {
        for j in 0..=i {
            let v = s_rows[i][j];
            s[[i, j]] = v;
            s[[j, i]] = v;
        }
    }

    // Ledoit-Wolf shrinkage intensity toward scaled identity mu * I.
    let mu = (0..p).map(|i| s[[i, i]]).sum::<f64>() / (p as f64);
    let mut frob_s2 = 0.0_f64;
    let mut delta2 = 0.0_f64;
    for i in 0..p {
        for j in 0..p {
            let sij = s[[i, j]];
            frob_s2 += sij * sij;
            let diff = if i == j { sij - mu } else { sij };
            delta2 += diff * diff;
        }
    }

    let mut x_norm4_sum = 0.0_f64;
    for t in 0..nt {
        let row_norm2: f64 = std_cols.iter().map(|c| c[t] * c[t]).sum();
        x_norm4_sum += row_norm2 * row_norm2;
    }
    let beta2 = (x_norm4_sum * inv_nt * inv_nt - frob_s2 * inv_nt).max(0.0);
    let mut alpha = if delta2 > 1e-15 {
        (beta2 / delta2).clamp(0.0, 1.0)
    } else {
        1.0
    };
    if p >= nt {
        alpha = alpha.max(1e-3);
    }

    let inv = invert_spd_with_fallback(&s, mu, alpha)?;
    for ii in 0..p {
        let ri = intact_ids[ii];
        let pii = inv[(ii, ii)].max(1e-15);
        out[[ri, ri]] = 1.0;
        for jj in (ii + 1)..p {
            let rj = intact_ids[jj];
            let pjj = inv[(jj, jj)].max(1e-15);
            let val = (-inv[(ii, jj)] / (pii * pjj).sqrt()).clamp(-1.0, 1.0);
            out[[ri, rj]] = val;
            out[[rj, ri]] = val;
        }
    }

    Ok(out)
}

fn invert_spd_with_fallback(s: &Array2<f64>, mu: f64, alpha: f64) -> Result<Mat<f64>> {
    let p = s.nrows();
    for ridge in [0.0, 1e-4, 1e-3, 1e-2] {
        let a_eff = alpha.max(ridge);
        let shrunk = Mat::<f64>::from_fn(p, p, |i, j| {
            let base = (1.0 - a_eff) * s[[i, j]];
            if i == j {
                base + a_eff * mu.max(1e-6)
            } else {
                base
            }
        });
        if let Ok(llt) = shrunk.llt(Side::Lower) {
            return Ok(llt.inverse());
        }
    }
    bail!("Ledoit-Wolf precision matrix inversion failed even with fallback ridge")
}

/// Computes normalized probability density histogram over `[-1, 1]` + mean & SD for finite off-diagonal pairs.
pub fn compute_fc_histogram(fc: ArrayView2<'_, f64>, n_bins: usize) -> (Vec<f32>, f64, f64) {
    let n = fc.nrows().min(fc.ncols());
    let n_bins = n_bins.max(3);
    let mut bins = vec![0usize; n_bins];
    let mut sum = 0.0_f64;
    let mut sum2 = 0.0_f64;
    let mut count = 0_usize;

    for i in 0..n {
        for j in (i + 1)..n {
            let v = fc[[i, j]];
            if v.is_finite() {
                let c = v.clamp(-1.0, 1.0);
                let idx = (((c + 1.0) * 0.5) * (n_bins as f64))
                    .floor()
                    .clamp(0.0, (n_bins - 1) as f64) as usize;
                bins[idx] += 1;
                sum += c;
                sum2 += c * c;
                count += 1;
            }
        }
    }

    if count == 0 {
        return (vec![0.0; n_bins], 0.0, 0.0);
    }
    let cf = count as f64;
    let mean = sum / cf;
    let var = (sum2 / cf - mean * mean).max(0.0);
    let density: Vec<f32> = bins.into_iter().map(|b| (b as f64 / cf) as f32).collect();
    (density, mean, var.sqrt())
}
