use crate::connectivity::static_fc_pearson;
use crate::denoise::{compute_acompcor, load_confounds_tsv, simultaneous_denoise};
use crate::nifti_io::{
    inspect_nifti_header, load_atlas_i32, load_bold_volume, load_mask_u8,
    render_ortho_slice_rgba, OrthoPlane,
};
use crate::parcellation::extract_roi_timeseries;
use anyhow::Result;
use ndarray::{concatenate, Array2, Axis};
use std::path::Path;
use std::time::Instant;

pub struct EngineInfo {
    pub name: String,
    pub version: String,
    pub simd_threads: usize,
}

pub struct NiftiHeaderSummary {
    pub dims: Vec<u32>,
    pub voxel_sizes: Vec<f32>,
    pub tr_sec: f64,
    pub datatype_code: i16,
    pub affine_flat: Vec<f32>,
}

pub struct SliceRgba {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub min_val: f32,
    pub max_val: f32,
}

pub struct DenoisePipelineSummary {
    pub n_timepoints: u32,
    pub n_rois: u32,
    pub tr_sec: f64,
    pub used_mmap: bool,
    pub load_ms: f64,
    pub parcellation_ms: f64,
    pub acompcor_ms: f64,
    pub denoise_ms: f64,
    pub fc_ms: f64,
    pub total_ms: f64,
    pub mean_abs_fc: f64,
}

pub fn engine_info() -> EngineInfo {
    EngineInfo {
        name: "CCS_fMRIStudio Rust Core".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        simd_threads: rayon::current_num_threads(),
    }
}

pub fn inspect_nifti(path: String) -> Result<NiftiHeaderSummary> {
    let hdr = inspect_nifti_header(Path::new(&path))?;
    Ok(NiftiHeaderSummary {
        dims: hdr.dims.into_iter().map(|d| d as u32).collect(),
        voxel_sizes: hdr.voxel_sizes.to_vec(),
        tr_sec: hdr.tr_sec,
        datatype_code: hdr.datatype_code,
        affine_flat: hdr.affine.into_iter().flatten().collect(),
    })
}

pub fn render_slice_rgba(
    path: String,
    plane: String,
    slice_index: u32,
    timepoint: u32,
) -> Result<SliceRgba> {
    let ortho_plane = OrthoPlane::parse(&plane)?;
    let vol = load_bold_volume(Path::new(&path))?;
    let rendered = render_ortho_slice_rgba(
        vol.view(),
        ortho_plane,
        slice_index as usize,
        timepoint as usize,
    )?;
    Ok(SliceRgba {
        width: rendered.width as u32,
        height: rendered.height as u32,
        rgba: rendered.rgba,
        min_val: rendered.min_val,
        max_val: rendered.max_val,
    })
}

pub fn run_roi_denoise_pipeline(
    bold_path: String,
    atlas_path: String,
    wm_mask_path: Option<String>,
    csf_mask_path: Option<String>,
    confounds_tsv_path: Option<String>,
    low_hz: f64,
    high_hz: f64,
    fd_threshold_mm: f64,
) -> Result<DenoisePipelineSummary> {
    let t_total = Instant::now();

    let t0 = Instant::now();
    let vol = load_bold_volume(Path::new(&bold_path))?;
    let tr_sec = vol.header().tr_sec;
    let used_mmap = vol.header().used_mmap;
    let atlas = load_atlas_i32(Path::new(&atlas_path))?;
    let load_ms = t0.elapsed().as_secs_f64() * 1000.0;

    let t1 = Instant::now();
    let (_roi_ids, raw_ts) = extract_roi_timeseries(vol.view(), atlas.view())?;
    let parcellation_ms = t1.elapsed().as_secs_f64() * 1000.0;
    let (nt, n_rois) = raw_ts.dim();

    let t2 = Instant::now();
    let mut confound_blocks: Vec<Array2<f64>> = Vec::new();
    let mut scrub_indices: Vec<usize> = Vec::new();
    if let Some(conf_path) = confounds_tsv_path {
        let (motion_mat, fd_spikes) = load_confounds_tsv(Path::new(&conf_path), nt, fd_threshold_mm)?;
        if motion_mat.ncols() > 0 {
            confound_blocks.push(motion_mat);
        }
        scrub_indices = fd_spikes;
    }
    if let Some(wm_p) = wm_mask_path {
        let wm_mask = load_mask_u8(Path::new(&wm_p))?;
        confound_blocks.push(compute_acompcor(vol.view(), wm_mask.view(), 5)?);
    }
    if let Some(csf_p) = csf_mask_path {
        let csf_mask = load_mask_u8(Path::new(&csf_p))?;
        confound_blocks.push(compute_acompcor(vol.view(), csf_mask.view(), 5)?);
    }
    let acompcor_ms = t2.elapsed().as_secs_f64() * 1000.0;

    let combined_conf = if confound_blocks.is_empty() {
        None
    } else {
        let views: Vec<_> = confound_blocks.iter().map(|b| b.view()).collect();
        Some(concatenate(Axis(1), &views)?)
    };

    let t3 = Instant::now();
    let low_opt = if low_hz > 0.0 { Some(low_hz) } else { None };
    let high_opt = if high_hz > 0.0 { Some(high_hz) } else { None };
    let clean_ts = simultaneous_denoise(
        raw_ts.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        high_opt,
        &scrub_indices,
        true,
    )?;
    let denoise_ms = t3.elapsed().as_secs_f64() * 1000.0;

    let t4 = Instant::now();
    let fc = static_fc_pearson(clean_ts.view())?;
    let fc_ms = t4.elapsed().as_secs_f64() * 1000.0;

    let mut abs_sum = 0.0_f64;
    let mut off_diag = 0_usize;
    for i in 0..n_rois {
        for j in (i + 1)..n_rois {
            abs_sum += fc[[i, j]].abs();
            off_diag += 1;
        }
    }
    let mean_abs_fc = if off_diag > 0 { abs_sum / (off_diag as f64) } else { 0.0 };

    Ok(DenoisePipelineSummary {
        n_timepoints: nt as u32,
        n_rois: n_rois as u32,
        tr_sec,
        used_mmap,
        load_ms,
        parcellation_ms,
        acompcor_ms,
        denoise_ms,
        fc_ms,
        total_ms: t_total.elapsed().as_secs_f64() * 1000.0,
        mean_abs_fc,
    })
}
