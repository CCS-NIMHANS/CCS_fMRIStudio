//! Apply the app's Rust denoising + dynamics engine to an arbitrary ROI time-series CSV.
//! Usage: denoise_csv <ts.csv> <conf.csv|-> <scrub.txt|-> <tr> <low_hz> <high_hz> <mode> <out_prefix> [dyn_window]
use anyhow::Result;
use ccs_fmri_core::denoise::{simultaneous_denoise_with_mode, CensorMode};
use ccs_fmri_core::dynamics::compute_sliding_dynamics_opt;
use ndarray::Array2;
use std::io::Write;

fn read_csv(p: &str) -> Result<Array2<f64>> {
    let txt = std::fs::read_to_string(p)?;
    let rows: Vec<Vec<f64>> = txt.lines().filter(|l| !l.trim().is_empty())
        .map(|l| l.split(',').map(|v| v.trim().parse::<f64>().unwrap_or(f64::NAN)).collect()).collect();
    let (n, m) = (rows.len(), rows.first().map_or(0, |r| r.len()));
    Ok(Array2::from_shape_fn((n, m), |(i, j)| rows[i][j]))
}
fn write_csv(p: &str, a: &Array2<f64>) -> Result<()> {
    let mut w = std::io::BufWriter::new(std::fs::File::create(p)?);
    for r in a.rows() { writeln!(w, "{}", r.iter().map(|v| format!("{v:.8e}")).collect::<Vec<_>>().join(","))?; }
    Ok(())
}
fn main() -> Result<()> {
    let a: Vec<String> = std::env::args().collect();
    let ts = read_csv(&a[1])?;
    let conf = if a[2] == "-" { None } else { Some(read_csv(&a[2])?) };
    let scrub: Vec<usize> = if a[3] == "-" { vec![] } else {
        std::fs::read_to_string(&a[3])?.lines().filter_map(|l| l.trim().parse().ok()).collect() };
    let tr: f64 = a[4].parse()?; let lo: f64 = a[5].parse()?; let hi: f64 = a[6].parse()?;
    let mode = CensorMode::from_str_opt(Some(&a[7]));
    let r = simultaneous_denoise_with_mode(ts.view(), conf.as_ref().map(|c| c.view()), tr,
        (lo > 0.0).then_some(lo), (hi > 0.0).then_some(hi), &scrub, mode, true)?;
    write_csv(&format!("{}_clean.csv", a[8]), &r.clean_ts)?;
    std::fs::write(format!("{}_kept.txt", a[8]), r.kept_rows.iter().map(|k| k.to_string()).collect::<Vec<_>>().join("\n"))?;
    std::fs::write(format!("{}_dof.txt", a[8]), r.dof_remaining.to_string())?;
    if let Some(w) = a.get(9) {
        let win: usize = w.parse()?;
        // as the app GUI: nuisance + high-pass only, censored frames interpolated
        let hp = simultaneous_denoise_with_mode(ts.view(), conf.as_ref().map(|c| c.view()), tr,
            (lo > 0.0).then_some(lo), None, &scrub, if mode == CensorMode::None { CensorMode::None } else { CensorMode::Interpolate }, true)?;
        write_csv(&format!("{}_hp.csv", a[8]), &hp.clean_ts)?;
        let rows = compute_sliding_dynamics_opt(hp.clean_ts.view(), tr, win, win, lo.max(0.0), if hi > 0.0 { hi } else { 0.5 / tr }, true)?;
        let mut out = Array2::<f64>::zeros((rows.len(), 4));
        for (i, row) in rows.iter().enumerate() { out[[i, 0]] = row.acw0_mean; out[[i, 1]] = row.acw50_mean; out[[i, 2]] = row.lzc_mean; out[[i, 3]] = row.ple_mean; }
        write_csv(&format!("{}_dyn.csv", a[8]), &out)?;
    }
    Ok(())
}
