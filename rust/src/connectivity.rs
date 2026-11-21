use anyhow::{bail, Result};
use ndarray::{s, Array2, ArrayView2};

/// Computes Pearson correlation matrix `(N_rois, N_rois)` across timepoints `(T, N_rois)`.
pub fn static_fc_pearson(ts: ArrayView2<'_, f64>) -> Result<Array2<f64>> {
    let (nt, n_rois) = ts.dim();
    if nt < 2 {
        bail!("Need at least 2 timepoints to compute correlation, got {nt}");
    }
    if n_rois == 0 {
        bail!("Empty ROI matrix");
    }

    let mut z = Array2::<f64>::zeros((nt, n_rois));
    let mut valid_roi = vec![false; n_rois];

    for j in 0..n_rois {
        let col = ts.column(j);
        let mean = col.sum() / (nt as f64);
        let mut ss = 0.0_f64;
        for i in 0..nt {
            let d = col[i] - mean;
            z[[i, j]] = d;
            ss += d * d;
        }
        let norm = ss.sqrt();
        if norm > 1e-12 {
            valid_roi[j] = true;
            for i in 0..nt {
                z[[i, j]] /= norm;
            }
        } else {
            for i in 0..nt {
                z[[i, j]] = 0.0;
            }
        }
    }

    let mut corr = z.t().dot(&z);
    for i in 0..n_rois {
        for j in 0..n_rois {
            if i == j {
                corr[[i, j]] = 1.0;
            } else if !valid_roi[i] || !valid_roi[j] {
                corr[[i, j]] = 0.0;
            } else {
                corr[[i, j]] = corr[[i, j]].clamp(-1.0, 1.0);
            }
        }
    }
    Ok(corr)
}

/// Computes sliding-window dynamic functional connectivity matrices.
pub fn sliding_window_fc(
    ts: ArrayView2<'_, f64>,
    window_len: usize,
    step: usize,
) -> Result<Vec<Array2<f64>>> {
    let nt = ts.nrows();
    if window_len < 3 || window_len > nt {
        bail!("Invalid window_len={window_len} for {nt} timepoints");
    }
    if step == 0 {
        bail!("step must be >= 1");
    }
    let mut windows = Vec::new();
    let mut start = 0;
    while start + window_len <= nt {
        let slice = ts.slice(s![start..start + window_len, ..]);
        windows.push(static_fc_pearson(slice)?);
        start += step;
    }
    Ok(windows)
}
