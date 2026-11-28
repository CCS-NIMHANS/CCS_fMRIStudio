use anyhow::Result;
use ccs_fmri_core::connectivity::{
    compute_homotopic_and_laterality, compute_nan_safe_graph_metrics, detect_schaefer_hemispheres,
    lesion_network_mapping, static_fc_pearson,
};
use ccs_fmri_core::denoise::{compute_acompcor_filtered, load_confounds_tsv, simultaneous_denoise_with_mode, CensorMode};
use ccs_fmri_core::lesion::{subtract_lesion_from_mask, summarize_lesion};
use ccs_fmri_core::nifti_io::{load_atlas_i32, load_bold_volume, load_mask_u8};
use ccs_fmri_core::parcellation::extract_roi_timeseries_lesion_aware;
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
    lesion_mask: Option<PathBuf>,
    #[arg(long)]
    labels_json: Option<PathBuf>,
    #[arg(long, default_value_t = 50.0)]
    max_damage_pct: f64,
    #[arg(long, default_value_t = 1)]
    lesion_dilate: usize,
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
    /// Disable z-scoring of the cleaned series (z-scoring is on by default).
    #[arg(long, default_value_t = false)]
    no_zscore: bool,
    /// Censoring mode: spike (default; simultaneous, = 3dTproject -cenmode KILL), interpolate or none.
    #[arg(long, default_value = "spike")]
    censor_mode: String,
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
    n_intact_rois: usize,
    n_excluded_rois: usize,
    lesion_volume_ml: f64,
    dominant_hemisphere: String,
    global_efficiency: f64,
    mean_node_strength: f64,
    mean_homotopic_fc: Option<f64>,
    laterality_index: Option<f64>,
    lesion_seed_mean_abs_r: Option<f64>,
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
            let v = mat[[r, c]];
            if v.is_finite() {
                write!(w, "{v:.10}")?;
            } else {
                write!(w, "NaN")?;
            }
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
    let lesion_mask = args.lesion_mask.as_deref().map(load_mask_u8).transpose()?;
    let load_ms = t0.elapsed().as_secs_f64() * 1000.0;

    let t1 = Instant::now();
    let parc = extract_roi_timeseries_lesion_aware(
        vol.view(),
        atlas.view(),
        lesion_mask.as_ref().map(|m| m.view()),
        hdr.voxel_sizes,
        args.max_damage_pct,
    )?;
    let parcellation_ms = t1.elapsed().as_secs_f64() * 1000.0;
    let (nt, n_rois) = parc.timeseries.dim();
    let n_excluded_rois = parc.excluded_mask.iter().filter(|&&e| e).count();

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
            let safe_wm = match &lesion_mask {
                Some(lm) => subtract_lesion_from_mask(wm.view(), lm.view(), args.lesion_dilate)?,
                None => wm.clone(),
            };
            if safe_wm.iter().any(|&v| v > 0) {
                conf_blocks.push(compute_acompcor_filtered(vol.view(), safe_wm.view(), args.acompcor_comps, tr_sec, (args.low_hz > 0.0).then_some(args.low_hz))?);
            }
        }
    }
    if let Some(csf) = &csf_mask {
        if args.acompcor_comps > 0 {
            let safe_csf = match &lesion_mask {
                Some(lm) => subtract_lesion_from_mask(csf.view(), lm.view(), args.lesion_dilate)?,
                None => csf.clone(),
            };
            if safe_csf.iter().any(|&v| v > 0) {
                conf_blocks.push(compute_acompcor_filtered(vol.view(), safe_csf.view(), args.acompcor_comps, tr_sec, (args.low_hz > 0.0).then_some(args.low_hz))?);
            }
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
    let den = simultaneous_denoise_with_mode(
        parc.timeseries.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        high_opt,
        &scrub_indices,
        CensorMode::from_str_opt(Some(&args.censor_mode)),
        !args.no_zscore,
    )?;
    let clean_kept = den.kept_ts();
    let clean_ts = den.clean_ts;
    let denoise_ms = t3.elapsed().as_secs_f64() * 1000.0;

    let t4 = Instant::now();
    let fc = static_fc_pearson(clean_kept.view())?;
    let graph = compute_nan_safe_graph_metrics(fc.view(), 0.0, None)?;
    let fc_ms = t4.elapsed().as_secs_f64() * 1000.0;

    let lesion_summary = lesion_mask
        .as_ref()
        .map(|lm| summarize_lesion(lm.view(), hdr.voxel_sizes, Some(hdr.affine)));
    let dominant_hemisphere = lesion_summary
        .as_ref()
        .map_or_else(|| "None".to_string(), |s| s.dominant_hemisphere.clone());

    let (mean_homotopic_fc, laterality_index) = if let Some(lbl_path) = &args.labels_json {
        let text = std::fs::read_to_string(lbl_path)?;
        let all_labels: Vec<String> = serde_json::from_str(&text)?;
        let parcel_labels: Vec<String> = parc
            .roi_ids
            .iter()
            .filter_map(|&id| all_labels.get(id as usize).cloned())
            .collect();
        if parcel_labels.len() == n_rois {
            let (lh, rh) = detect_schaefer_hemispheres(&parcel_labels);
            let hl = compute_homotopic_and_laterality(fc.view(), &lh, &rh, &dominant_hemisphere);
            (Some(hl.mean_homotopic_fc), Some(hl.laterality_index))
        } else {
            (None, None)
        }
    } else {
        (None, None)
    };

    let lesion_seed_mean_abs_r = if let Some(lm) = &lesion_mask {
        let seed_r = lesion_network_mapping(vol.view(), lm.view(), clean_ts.view())?;
        let finite: Vec<f64> = seed_r.into_iter().filter(|v| v.is_finite()).collect();
        if finite.is_empty() {
            Some(0.0)
        } else {
            Some(finite.iter().map(|v| v.abs()).sum::<f64>() / (finite.len() as f64))
        }
    } else {
        None
    };

    if let Some(ts_out) = &args.out_ts_csv {
        let hdr_cols: Vec<String> = parc.roi_ids.iter().map(|id| format!("roi_{id}")).collect();
        write_csv(ts_out, &hdr_cols, &clean_ts)?;
    }

    let mut abs_sum = 0.0_f64;
    let mut off_diag = 0_usize;
    for i in 0..n_rois {
        for j in (i + 1)..n_rois {
            let v = fc[[i, j]];
            if v.is_finite() {
                abs_sum += v.abs();
                off_diag += 1;
            }
        }
    }
    let mean_abs_fc = if off_diag > 0 { abs_sum / (off_diag as f64) } else { 0.0 };

    let report = BenchReport {
        bold_path: args.bold.display().to_string(),
        shape: hdr.dims,
        tr_sec,
        used_mmap: hdr.used_mmap,
        n_rois,
        n_intact_rois: n_rois - n_excluded_rois,
        n_excluded_rois,
        lesion_volume_ml: parc.total_lesion_volume_ml,
        dominant_hemisphere,
        global_efficiency: graph.global_efficiency,
        mean_node_strength: graph.mean_node_strength,
        mean_homotopic_fc,
        laterality_index,
        lesion_seed_mean_abs_r,
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
