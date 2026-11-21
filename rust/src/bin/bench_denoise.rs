use anyhow::Result;
use ccs_fmri_core::connectivity::static_fc_pearson;
use ccs_fmri_core::denoise::{compute_acompcor, load_confounds_tsv, simultaneous_denoise};
use ccs_fmri_core::nifti_io::{load_atlas_i32, load_bold_volume, load_mask_u8};
use ccs_fmri_core::parcellation::extract_roi_timeseries;
use clap::Parser;
use ndarray::{concatenate, Array2, Axis};
use serde::Serialize;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::Instant;

#[derive(Parser, Debug)]
#[command(name = "bench_denoise", about = "CCS_fMRIStudio Rust parcellation + denoising benchmark")]
struct Args {
    #[arg(long)]
    bold: PathBuf,
    #[arg(long)]
    atlas: PathBuf,
    #[arg(long)]
    confounds: Option<PathBuf>,
    #[arg(long)]
    wm_mask: Option<PathBuf>,
    #[arg(long)]
    csf_mask: Option<PathBuf>,
    #[arg(long)]
    tr: Option<f64>,
    #[arg(long, default_value_t = 0.008)]
    low_hz: f64,
    #[arg(long, default_value_t = 0.09)]
    high_hz: f64,
    #[arg(long, default_value_t = 0.5)]
    fd_threshold: f64,
    #[arg(long, default_value_t = 5)]
    acompcor_comps: usize,
    #[arg(long, default_value_t = true)]
    zscore: bool,
    #[arg(long)]
    out_json: Option<PathBuf>,
    #[arg(long)]
    out_ts_csv: Option<PathBuf>,
    #[arg(long)]
    out_confounds_csv: Option<PathBuf>,
}

#[derive(Serialize)]
struct BenchReport {
    bold_path: String,
    shape: [usize; 4],
    tr_sec: f64,
    used_mmap: bool,
    n_rois: usize,
    n_confound_cols: usize,
    n_scrubbed_frames: usize,
    low_hz: f64,
    high_hz: f64,
    load_ms: f64,
    parcellation_ms: f64,
    acompcor_ms: f64,
    denoise_ms: f64,
    fc_ms: f64,
    total_ms: f64,
    mean_abs_fc: f64,
}

fn write_csv(path: &PathBuf, header: &[String], mat: &Array2<f64>) -> Result<()> {
    let file = File::create(path)?;
    let mut w = BufWriter::new(file);
    writeln!(w, "{}", header.join(","))?;
    for r in 0..mat.nrows() {
        for c in 0..mat.ncols() {
            if c > 0 {
                write!(w, ",")?;
            }
            write!(w, "{:.10}", mat[[r, c]])?;
        }
        writeln!(w)?;
    }
    w.flush()?;
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();
    let t_total = Instant::now();

    let t0 = Instant::now();
    let vol = load_bold_volume(&args.bold)?;
    let hdr = vol.header().clone();
    let tr_sec = args.tr.unwrap_or(hdr.tr_sec);
    let atlas = load_atlas_i32(&args.atlas)?;
    let wm_mask = args.wm_mask.as_deref().map(load_mask_u8).transpose()?;
    let csf_mask = args.csf_mask.as_deref().map(load_mask_u8).transpose()?;
    let load_ms = t0.elapsed().as_secs_f64() * 1000.0;

    let t1 = Instant::now();
    let (roi_ids, raw_ts) = extract_roi_timeseries(vol.view(), atlas.view())?;
    let parcellation_ms = t1.elapsed().as_secs_f64() * 1000.0;
    let (nt, n_rois) = raw_ts.dim();

    let t2 = Instant::now();
    let mut conf_blocks: Vec<Array2<f64>> = Vec::new();
    let mut scrub_indices = Vec::new();
    if let Some(conf_path) = &args.confounds {
        let (motion, spikes) = load_confounds_tsv(conf_path, nt, args.fd_threshold)?;
        if motion.ncols() > 0 {
            conf_blocks.push(motion);
        }
        scrub_indices = spikes;
    }
    if let Some(wm) = &wm_mask {
        if args.acompcor_comps > 0 {
            conf_blocks.push(compute_acompcor(vol.view(), wm.view(), args.acompcor_comps)?);
        }
    }
    if let Some(csf) = &csf_mask {
        if args.acompcor_comps > 0 {
            conf_blocks.push(compute_acompcor(vol.view(), csf.view(), args.acompcor_comps)?);
        }
    }
    let acompcor_ms = t2.elapsed().as_secs_f64() * 1000.0;

    let combined_conf = if conf_blocks.is_empty() {
        None
    } else {
        let views: Vec<_> = conf_blocks.iter().map(|b| b.view()).collect();
        Some(concatenate(Axis(1), &views)?)
    };

    if let (Some(conf_out), Some(conf_mat)) = (&args.out_confounds_csv, &combined_conf) {
        let hdr_cols: Vec<String> = (0..conf_mat.ncols()).map(|i| format!("conf_{i}")).collect();
        write_csv(conf_out, &hdr_cols, conf_mat)?;
    }

    let t3 = Instant::now();
    let low_opt = if args.low_hz > 0.0 { Some(args.low_hz) } else { None };
    let high_opt = if args.high_hz > 0.0 { Some(args.high_hz) } else { None };
    let clean_ts = simultaneous_denoise(
        raw_ts.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        high_opt,
        &scrub_indices,
        args.zscore,
    )?;
    let denoise_ms = t3.elapsed().as_secs_f64() * 1000.0;

    let t4 = Instant::now();
    let fc = static_fc_pearson(clean_ts.view())?;
    let fc_ms = t4.elapsed().as_secs_f64() * 1000.0;

    if let Some(ts_out) = &args.out_ts_csv {
        let hdr_cols: Vec<String> = roi_ids.iter().map(|id| format!("roi_{id}")).collect();
        write_csv(ts_out, &hdr_cols, &clean_ts)?;
    }

    let mut abs_sum = 0.0_f64;
    let mut off_diag = 0_usize;
    for i in 0..n_rois {
        for j in (i + 1)..n_rois {
            abs_sum += fc[[i, j]].abs();
            off_diag += 1;
        }
    }
    let mean_abs_fc = if off_diag > 0 { abs_sum / (off_diag as f64) } else { 0.0 };

    let report = BenchReport {
        bold_path: args.bold.display().to_string(),
        shape: hdr.dims,
        tr_sec,
        used_mmap: hdr.used_mmap,
        n_rois,
        n_confound_cols: combined_conf.as_ref().map_or(0, |c| c.ncols()),
        n_scrubbed_frames: scrub_indices.len(),
        low_hz: args.low_hz,
        high_hz: args.high_hz,
        load_ms,
        parcellation_ms,
        acompcor_ms,
        denoise_ms,
        fc_ms,
        total_ms: t_total.elapsed().as_secs_f64() * 1000.0,
        mean_abs_fc,
    };

    let json_text = serde_json::to_string_pretty(&report)?;
    if let Some(out_json) = &args.out_json {
        std::fs::write(out_json, &json_text)?;
    }
    println!("{json_text}");
    Ok(())
}
