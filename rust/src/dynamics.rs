use crate::denoise::simultaneous_denoise;
use anyhow::Result;
use ndarray::ArrayView2;
use rayon::prelude::*;
use std::f64::consts::PI;

#[derive(Clone, Debug)]
pub struct WindowDynamics {
    pub acw0: f64,
    pub acw50: f64,
    pub auc_rect: f64,
    pub auc_trap: f64,
    pub lzc: f64,
    pub sampen: f64,
    pub med_f: f64,
    pub se: f64,
    pub ple: f64,
}

#[derive(Clone, Debug)]
pub struct RoiDynamicsRow {
    pub roi_index: usize,
    pub is_intact: bool,
    pub acw0_mean: f64,
    pub acw50_mean: f64,
    pub auc_rect_mean: f64,
    pub auc_trap_mean: f64,
    pub lzc_mean: f64,
    pub sampen_mean: f64,
    pub med_f_mean: f64,
    pub se_mean: f64,
    pub ple_mean: f64,
    pub acw0_std: f64,
    pub acw50_std: f64,
    pub lzc_std: f64,
    pub sampen_std: f64,
    pub ple_std: f64,
}

/// Computes normalized sample autocorrelation at lags `0..n-1`.
pub fn compute_acf(ts: &[f64]) -> Vec<f64> {
    let n = ts.len();
    if n == 0 {
        return Vec::new();
    }
    let mean = ts.iter().sum::<f64>() / (n as f64);
    let centered: Vec<f64> = ts.iter().map(|&v| v - mean).collect();
    let var0: f64 = centered.iter().map(|&v| v * v).sum();
    if var0 <= 1e-15 {
        return vec![0.0; n];
    }
    let mut out = Vec::with_capacity(n);
    out.push(1.0);
    for lag in 1..n {
        let mut cov = 0.0_f64;
        for t in 0..(n - lag) {
            cov += centered[t] * centered[t + lag];
        }
        out.push(cov / var0);
    }
    out
}

/// Normalized Lempel-Ziv complexity on median-binarized sequence (Kaspar & Schuster 1987, matching antropy).
pub fn lempel_ziv_normalized(ts: &[f64]) -> f64 {
    let n = ts.len();
    if n < 2 {
        return f64::NAN;
    }
    let mut sorted = ts.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let median = if n % 2 == 1 {
        sorted[n / 2]
    } else {
        0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    };
    let seq: Vec<u8> = ts.iter().map(|&v| u8::from(v > median)).collect();

    let mut i = 0_usize;
    let mut k = 1_usize;
    let mut l = 1_usize;
    let mut k_max = 1_usize;
    let mut c = 1_usize;
    loop {
        if i + k - 1 < n && l + k - 1 < n && seq[i + k - 1] == seq[l + k - 1] {
            k += 1;
            if l + k > n {
                c += 1;
                break;
            }
        } else {
            if k > k_max {
                k_max = k;
            }
            i += 1;
            if i == l {
                c += 1;
                l += k_max;
                if l + 1 > n {
                    break;
                }
                i = 0;
                k = 1;
                k_max = 1;
            } else {
                k = 1;
            }
        }
    }

    let nf = n as f64;
    let b = nf / nf.log2();
    (c as f64) / b.max(1e-12)
}

/// Sample Entropy (m = 2, Chebyshev distance tolerance r = r_factor * population SD).
pub fn sample_entropy_m2(ts: &[f64], r_factor: f64) -> f64 {
    let n = ts.len();
    let m = 2_usize;
    if n <= m + 2 {
        return f64::NAN;
    }
    let mean = ts.iter().sum::<f64>() / (n as f64);
    let var = ts.iter().map(|&v| (v - mean) * (v - mean)).sum::<f64>() / (n as f64);
    let tol = r_factor * var.sqrt();
    if tol <= 1e-12 || !tol.is_finite() {
        return f64::NAN;
    }

    let limit = n - m;
    let mut count_m = 0_usize;
    let mut count_m1 = 0_usize;
    for i in 0..limit {
        for j in (i + 1)..limit {
            if (ts[i] - ts[j]).abs() <= tol && (ts[i + 1] - ts[j + 1]).abs() <= tol {
                count_m += 1;
                if (ts[i + 2] - ts[j + 2]).abs() <= tol {
                    count_m1 += 1;
                }
            }
        }
    }

    if count_m == 0 || count_m1 == 0 {
        f64::NAN
    } else {
        -((count_m1 as f64) / (count_m as f64)).ln()
    }
}

/// One-sided Welch PSD using Hann window and 50% overlap (matching scipy.signal.welch).
pub fn welch_psd(ts: &[f64], fs: f64, nperseg: usize) -> (Vec<f64>, Vec<f64>) {
    let n = ts.len();
    let nperseg = nperseg.min(n).max(4);
    let step = (nperseg / 2).max(1);

    let hann: Vec<f64> = (0..nperseg)
        .map(|i| {
            if nperseg > 1 {
                0.5 * (1.0 - (2.0 * PI * (i as f64) / (nperseg as f64)).cos())
            } else {
                1.0
            }
        })
        .collect();
    let win_energy: f64 = hann.iter().map(|w| w * w).sum();
    let scale = 1.0 / (fs * win_energy.max(1e-12));
    let n_freqs = nperseg / 2 + 1;

    let mut starts = Vec::new();
    let mut s = 0_usize;
    while s + nperseg <= n {
        starts.push(s);
        s += step;
    }
    if starts.is_empty() {
        starts.push(0);
    }

    let mut accum = vec![0.0_f64; n_freqs];
    for &start in &starts {
        let seg = &ts[start..(start + nperseg)];
        let seg_mean = seg.iter().sum::<f64>() / (nperseg as f64);
        let windowed: Vec<f64> = seg
            .iter()
            .zip(hann.iter())
            .map(|(&x, &w)| (x - seg_mean) * w)
            .collect();

        for (k, acc_slot) in accum.iter_mut().enumerate() {
            let mut re = 0.0_f64;
            let mut im = 0.0_f64;
            let angle_step = -2.0 * PI * (k as f64) / (nperseg as f64);
            for (t_idx, &wval) in windowed.iter().enumerate() {
                let ang = angle_step * (t_idx as f64);
                re += wval * ang.cos();
                im += wval * ang.sin();
            }
            let mut p = (re * re + im * im) * scale;
            if k > 0 && !(nperseg.is_multiple_of(2) && k == n_freqs - 1) {
                p *= 2.0;
            }
            *acc_slot += p;
        }
    }

    let n_segs = starts.len() as f64;
    let freqs: Vec<f64> = (0..n_freqs)
        .map(|k| (k as f64) * fs / (nperseg as f64))
        .collect();
    for p in &mut accum {
        *p /= n_segs;
    }
    (freqs, accum)
}

/// Computes all 9 metrics from `fMRIAnalysis.py` (`calc_metrics`) on a single window.
pub fn calc_window_metrics(
    ts: &[f64],
    tr: f64,
    low_hz: f64,
    high_hz: f64,
    win_nperseg: usize,
) -> WindowDynamics {
    let n = ts.len();
    let a = compute_acf(ts);
    let idx_50 = a.iter().position(|&v| v <= 0.5);
    let idx_0 = a.iter().position(|&v| v <= 0.0);

    let acw50 = idx_50.map_or(f64::NAN, |i| (i as f64) * tr);
    let acw0 = idx_0.map_or(f64::NAN, |i| (i as f64) * tr);

    let (auc_rect, auc_trap) = match idx_0 {
        Some(i0) if i0 > 0 && i0 < a.len() => {
            let rect: f64 = a[..i0].iter().sum::<f64>() * tr;
            let trap: f64 = (0..i0).map(|k| 0.5 * (a[k] + a[k + 1])).sum::<f64>() * tr;
            (rect, trap)
        }
        _ => (f64::NAN, f64::NAN),
    };

    let lzc = lempel_ziv_normalized(ts);
    let sampen = sample_entropy_m2(ts, 0.2);

    let fs = if tr > 0.0 { 1.0 / tr } else { 0.5 };
    let (freqs, power) = welch_psd(ts, fs, win_nperseg.min(n));
    let mut band_f = Vec::new();
    let mut band_p = Vec::new();
    for (&f, &p) in freqs.iter().zip(power.iter()) {
        if f >= low_hz && f <= high_hz {
            band_f.push(f);
            band_p.push(p);
        }
    }

    let total_p: f64 = band_p.iter().sum();
    let med_f = if band_p.is_empty() || total_p <= 0.0 {
        f64::NAN
    } else {
        let half = 0.5 * total_p;
        let mut run = 0.0_f64;
        let mut found = band_f[0];
        for (&f, &p) in band_f.iter().zip(band_p.iter()) {
            run += p;
            if run >= half {
                found = f;
                break;
            }
        }
        found
    };

    let se = if band_p.len() <= 1 || total_p <= 0.0 {
        f64::NAN
    } else {
        let mut h = 0.0_f64;
        for &p in &band_p {
            let pn = p / total_p;
            if pn > 0.0 {
                h -= pn * pn.log2();
            }
        }
        h / (band_p.len() as f64).log2()
    };

    let log_pairs: Vec<(f64, f64)> = band_f
        .iter()
        .zip(band_p.iter())
        .filter(|(&f, &p)| f > 0.0 && p > 0.0)
        .map(|(&f, &p)| (f.log10(), p.log10()))
        .collect();
    let ple = if log_pairs.len() >= 2 {
        let m = log_pairs.len() as f64;
        let mx = log_pairs.iter().map(|&(x, _)| x).sum::<f64>() / m;
        let my = log_pairs.iter().map(|&(_, y)| y).sum::<f64>() / m;
        let num: f64 = log_pairs.iter().map(|&(x, y)| (x - mx) * (y - my)).sum();
        let den: f64 = log_pairs.iter().map(|&(x, _)| (x - mx) * (x - mx)).sum();
        if den > 1e-15 {
            -(num / den)
        } else {
            f64::NAN
        }
    } else {
        f64::NAN
    };

    WindowDynamics {
        acw0,
        acw50,
        auc_rect,
        auc_trap,
        lzc,
        sampen,
        med_f,
        se,
        ple,
    }
}

fn finite_mean_std(vals: &[f64]) -> (f64, f64) {
    let finite: Vec<f64> = vals.iter().copied().filter(|v| v.is_finite()).collect();
    if finite.is_empty() {
        return (f64::NAN, f64::NAN);
    }
    let m = finite.iter().sum::<f64>() / (finite.len() as f64);
    let var = finite.iter().map(|&v| (v - m) * (v - m)).sum::<f64>() / (finite.len() as f64);
    (m, var.sqrt())
}

fn zscore_slice(s: &[f64]) -> Option<Vec<f64>> {
    let n = s.len();
    if n < 4 {
        return None;
    }
    let mean = s.iter().sum::<f64>() / (n as f64);
    let var = s.iter().map(|&v| (v - mean) * (v - mean)).sum::<f64>() / (n as f64);
    let sd = var.sqrt();
    if sd < 1e-6 || !sd.is_finite() {
        return None;
    }
    Some(s.iter().map(|&v| (v - mean) / sd).collect())
}

/// Computes sliding-window complexity & timescale dynamics across all ROIs (Rayon parallel).
pub fn compute_sliding_dynamics(
    clean_ts: ArrayView2<'_, f64>,
    tr_sec: f64,
    window_len: usize,
    step: usize,
    low_hz: f64,
    high_hz: f64,
) -> Result<Vec<RoiDynamicsRow>> {
    let (nt, n_rois) = clean_ts.dim();
    let filtered = simultaneous_denoise(
        clean_ts,
        None,
        tr_sec,
        Some(low_hz),
        Some(high_hz),
        &[],
        true,
    )?;

    let eff_win = window_len.min(nt).max(16.min(nt));
    let eff_step = step.max(1);
    let nperseg = (eff_win / 2).max(16).min(eff_win);

    let rows: Vec<RoiDynamicsRow> = (0..n_rois)
        .into_par_iter()
        .map(|roi| {
            let col: Vec<f64> = (0..nt).map(|t| filtered[[t, roi]]).collect();
            if col.iter().any(|v| !v.is_finite()) {
                return RoiDynamicsRow {
                    roi_index: roi,
                    is_intact: false,
                    acw0_mean: f64::NAN,
                    acw50_mean: f64::NAN,
                    auc_rect_mean: f64::NAN,
                    auc_trap_mean: f64::NAN,
                    lzc_mean: f64::NAN,
                    sampen_mean: f64::NAN,
                    med_f_mean: f64::NAN,
                    se_mean: f64::NAN,
                    ple_mean: f64::NAN,
                    acw0_std: f64::NAN,
                    acw50_std: f64::NAN,
                    lzc_std: f64::NAN,
                    sampen_std: f64::NAN,
                    ple_std: f64::NAN,
                };
            }

            let mut win_metrics = Vec::new();
            let mut start = 0_usize;
            while start + eff_win <= nt {
                if let Some(zw) = zscore_slice(&col[start..(start + eff_win)]) {
                    win_metrics.push(calc_window_metrics(&zw, tr_sec, low_hz, high_hz, nperseg));
                }
                start += eff_step;
            }
            if win_metrics.is_empty() {
                if let Some(zw) = zscore_slice(&col) {
                    win_metrics.push(calc_window_metrics(&zw, tr_sec, low_hz, high_hz, nperseg));
                }
            }

            if win_metrics.is_empty() {
                return RoiDynamicsRow {
                    roi_index: roi,
                    is_intact: false,
                    acw0_mean: f64::NAN,
                    acw50_mean: f64::NAN,
                    auc_rect_mean: f64::NAN,
                    auc_trap_mean: f64::NAN,
                    lzc_mean: f64::NAN,
                    sampen_mean: f64::NAN,
                    med_f_mean: f64::NAN,
                    se_mean: f64::NAN,
                    ple_mean: f64::NAN,
                    acw0_std: f64::NAN,
                    acw50_std: f64::NAN,
                    lzc_std: f64::NAN,
                    sampen_std: f64::NAN,
                    ple_std: f64::NAN,
                };
            }

            let (acw0_m, acw0_s) = finite_mean_std(&win_metrics.iter().map(|m| m.acw0).collect::<Vec<_>>());
            let (acw50_m, acw50_s) = finite_mean_std(&win_metrics.iter().map(|m| m.acw50).collect::<Vec<_>>());
            let (aucr_m, _) = finite_mean_std(&win_metrics.iter().map(|m| m.auc_rect).collect::<Vec<_>>());
            let (auct_m, _) = finite_mean_std(&win_metrics.iter().map(|m| m.auc_trap).collect::<Vec<_>>());
            let (lzc_m, lzc_s) = finite_mean_std(&win_metrics.iter().map(|m| m.lzc).collect::<Vec<_>>());
            let (se_samp_m, se_samp_s) = finite_mean_std(&win_metrics.iter().map(|m| m.sampen).collect::<Vec<_>>());
            let (medf_m, _) = finite_mean_std(&win_metrics.iter().map(|m| m.med_f).collect::<Vec<_>>());
            let (spec_se_m, _) = finite_mean_std(&win_metrics.iter().map(|m| m.se).collect::<Vec<_>>());
            let (ple_m, ple_s) = finite_mean_std(&win_metrics.iter().map(|m| m.ple).collect::<Vec<_>>());

            RoiDynamicsRow {
                roi_index: roi,
                is_intact: true,
                acw0_mean: acw0_m,
                acw50_mean: acw50_m,
                auc_rect_mean: aucr_m,
                auc_trap_mean: auct_m,
                lzc_mean: lzc_m,
                sampen_mean: se_samp_m,
                med_f_mean: medf_m,
                se_mean: spec_se_m,
                ple_mean: ple_m,
                acw0_std: acw0_s,
                acw50_std: acw50_s,
                lzc_std: lzc_s,
                sampen_std: se_samp_s,
                ple_std: ple_s,
            }
        })
        .collect();

    Ok(rows)
}
