use crate::connectivity::{
    compute_homotopic_and_laterality, compute_nan_safe_graph_metrics, detect_schaefer_hemispheres,
    lesion_network_mapping, static_fc_pearson,
};
use crate::denoise::{
    compute_acompcor_filtered, load_confounds_tsv, load_confounds_with_fd,
    simultaneous_denoise_with_mode, CensorMode,
};
use crate::dynamics::{compute_sliding_dynamics_opt, one_way_anova_by_group, welch_psd};
use crate::graph_theory::compute_full_graph_theory;
use crate::info_theory::{
    compute_fc_histogram, compute_gcmi_matrix, compute_partial_correlation_ledoit_wolf,
    compute_transfer_entropy_matrix_masked,
};
use crate::lesion::{
    apply_spherical_brush, compute_hemispheric_asymmetry, dilate_mask_3d, fill_holes_3d,
    magic_wand_3d, remove_small_islands_3d, render_ortho_slice_with_lesion_rgba, save_mask_u8_nifti,
    subtract_lesion_from_mask, summarize_lesion, LesionSummary,
};
use crate::nifti_io::{
    inspect_nifti_header, load_atlas_i32, load_bold_volume, load_mask_u8,
    render_ortho_slice_rgba, OrthoPlane,
};
use crate::parcellation::{extract_roi_timeseries, extract_roi_timeseries_lesion_aware};
use anyhow::{bail, Context, Result};
use ndarray::{concatenate, Array2, Array3, ArrayView2, Axis};
use std::collections::BTreeMap;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::sync::{OnceLock, RwLock};
use std::time::Instant;

struct CachedSession {
    raw_ts: Array2<f64>,
    clean_ts: Array2<f64>,
    /// Nuisance-regressed + high-pass-only series (no low-pass) used for timescale/complexity
    /// dynamics, so ACW/LZC/SampEn are not dictated by the 0.09 Hz low-pass edge.
    clean_ts_hp: Array2<f64>,
    tr_sec: f64,
    #[allow(dead_code)]
    bandpass_low_hz: f64,
    #[allow(dead_code)]
    bandpass_high_hz: f64,
    roi_labels: Vec<String>,
    network_names: Vec<String>,
    roi_network_indices: Vec<usize>,
    fc_pearson: Array2<f64>,
    fc_partial: Array2<f64>,
    fc_gcmi: Array2<f64>,
    fc_te: Array2<f64>,
    fd_trace: Vec<f32>,
    scrubbed_indices: Vec<u32>,
}

static SESSION_CACHE: OnceLock<RwLock<Option<CachedSession>>> = OnceLock::new();

fn session_lock() -> &'static RwLock<Option<CachedSession>> {
    SESSION_CACHE.get_or_init(|| RwLock::new(None))
}

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

pub struct LesionSummaryDto {
    pub voxel_count: u64,
    pub volume_ml: f64,
    pub left_voxels: u64,
    pub right_voxels: u64,
    pub dominant_hemisphere: String,
}

pub struct LesionPipelineSummary {
    pub n_timepoints: u32,
    pub n_rois: u32,
    pub n_intact_rois: u32,
    pub n_excluded_rois: u32,
    pub tr_sec: f64,
    pub used_mmap: bool,
    pub lesion_volume_ml: f64,
    pub dominant_hemisphere: String,
    pub global_efficiency: f64,
    pub mean_node_strength: f64,
    pub mean_homotopic_fc: f64,
    pub laterality_index: f64,
    pub lesion_seed_mean_abs_r: f64,
    pub mean_abs_fc: f64,
    pub total_ms: f64,
    pub fc_preview_rgba: Vec<u8>,
    pub fc_preview_size: u32,
    pub carpet_rgba: Vec<u8>,
    pub carpet_width: u32,
    pub carpet_height: u32,
    pub exported_dir: Option<String>,
    // v0.2.0 CONN QC
    pub raw_fc_hist: Vec<f32>,
    pub clean_fc_hist: Vec<f32>,
    pub raw_fc_mean: f64,
    pub raw_fc_sd: f64,
    pub clean_fc_mean: f64,
    pub clean_fc_sd: f64,
    pub mean_fd_mm: f64,
    pub pct_scrubbed: f64,
    pub fd_trace: Vec<f32>,
    pub scrubbed_indices: Vec<u32>,
    pub raw_carpet_rgba: Vec<u8>,
    // v0.2.0 ROI & Network metadata
    pub roi_labels: Vec<String>,
    pub network_names: Vec<String>,
    pub roi_network_indices: Vec<u32>,
    // v0.2.0 Nilearn Partial FC, GCMI & Directed Transfer Entropy
    pub mean_abs_partial_fc: f64,
    pub mean_gcmi_bits: f64,
    pub mean_te_bits: f64,
    pub partial_preview_rgba: Vec<u8>,
    pub gcmi_preview_rgba: Vec<u8>,
    pub te_preview_rgba: Vec<u8>,
    pub net_pearson_flat: Vec<f32>,
    pub net_partial_flat: Vec<f32>,
    pub net_gcmi_flat: Vec<f32>,
    pub net_te_flat: Vec<f32>,
    // v0.4.0 Scrubbing DOF & Net Directional Transfer Entropy
    pub censor_mode: String,
    pub n_regressors: u32,
    pub dof_remaining: u32,
    pub te_net_preview_rgba: Vec<u8>,
    pub net_te_asym_flat: Vec<f32>,
    pub net_te_out_minus_in: Vec<f32>,
}

pub struct RoiTraceDto {
    pub roi_index: u32,
    pub label: String,
    pub network: String,
    pub is_intact: bool,
    pub variance_removed_pct: f64,
    pub raw_z: Vec<f32>,
    pub clean_z: Vec<f32>,
    pub psd_freqs: Vec<f32>,
    pub raw_psd: Vec<f32>,
    pub clean_psd: Vec<f32>,
}

pub struct PairwiseCouplingDto {
    pub roi_a: u32,
    pub roi_b: u32,
    pub label_a: String,
    pub label_b: String,
    pub pearson_r: f64,
    pub partial_r: f64,
    pub gcmi_bits: f64,
    pub te_a_to_b: f64,
    pub te_b_to_a: f64,
}

pub struct RoiTimeseriesDetailDto {
    pub tr_sec: f64,
    pub fd_trace: Vec<f32>,
    pub scrubbed_indices: Vec<u32>,
    pub traces: Vec<RoiTraceDto>,
    pub pairwise: Option<PairwiseCouplingDto>,
}

pub struct RoiHubDto {
    pub roi_index: u32,
    pub label: String,
    pub network: String,
    pub score: f64,
}

pub struct NetworkDynamicsDto {
    pub network_name: String,
    pub n_intact_rois: u32,
    pub acw0_mean: f64,
    pub acw0_sd: f64,
    pub acw50_mean: f64,
    pub acw50_sd: f64,
    pub auc_rect_mean: f64,
    pub auc_trap_mean: f64,
    pub lzc_mean: f64,
    pub lzc_sd: f64,
    pub sampen_mean: f64,
    pub sampen_sd: f64,
    pub med_f_mean: f64,
    pub se_mean: f64,
    pub ple_mean: f64,
    pub ple_sd: f64,
}

pub struct DynamicsSummaryDto {
    pub n_intact_rois: u32,
    pub low_hz: f64,
    pub high_hz: f64,
    pub window_len: u32,
    pub step: u32,
    pub acw0_mean: f64,
    pub acw50_mean: f64,
    pub auc_rect_mean: f64,
    pub auc_trap_mean: f64,
    pub lzc_mean: f64,
    pub sampen_mean: f64,
    pub med_f_mean: f64,
    pub se_mean: f64,
    pub ple_mean: f64,
    pub networks: Vec<NetworkDynamicsDto>,
    pub exported_csv_path: Option<String>,
    pub anova_f_acw0: f64,
    pub anova_p_acw0: f64,
    pub anova_f_lzc: f64,
    pub anova_p_lzc: f64,
    pub anova_f_sampen: f64,
    pub anova_p_sampen: f64,
    pub anova_f_ple: f64,
    pub anova_p_ple: f64,
}

pub struct NodalGraphDto {
    pub roi_index: u32,
    pub label: String,
    pub network: String,
    pub degree: u32,
    pub strength: f64,
    pub clustering: f64,
    pub local_efficiency: f64,
    pub betweenness: f64,
    pub participation_coeff: f64,
    pub within_module_z: f64,
}

pub struct DensitySweepDto {
    pub density: f64,
    pub global_efficiency: f64,
    pub clustering_coeff: f64,
    pub small_worldness: f64,
    pub modularity_q: f64,
}

pub struct GraphTheorySummaryDto {
    pub metric: String,
    pub density: f64,
    pub weighted: bool,
    pub n_intact_nodes: u32,
    pub n_excluded_nodes: u32,
    pub n_edges: u32,
    pub global_efficiency: f64,
    pub mean_local_efficiency: f64,
    pub clustering_coeff: f64,
    pub char_path_length: f64,
    pub small_worldness: f64,
    pub modularity_q: f64,
    pub assortativity: f64,
    pub nodal: Vec<NodalGraphDto>,
    pub sweep: Vec<DensitySweepDto>,
    pub exported_csv_path: Option<String>,
    pub exported_json_path: Option<String>,
}

fn to_lesion_dto(s: LesionSummary) -> LesionSummaryDto {
    LesionSummaryDto {
        voxel_count: s.voxel_count as u64,
        volume_ml: s.volume_ml,
        left_voxels: s.left_voxels as u64,
        right_voxels: s.right_voxels as u64,
        dominant_hemisphere: s.dominant_hemisphere,
    }
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

pub fn render_slice_with_lesion_rgba(
    path: String,
    lesion_mask_path: Option<String>,
    plane: String,
    slice_index: u32,
    timepoint: u32,
    overlay_alpha: f32,
) -> Result<SliceRgba> {
    let ortho_plane = OrthoPlane::parse(&plane)?;
    let vol = load_bold_volume(Path::new(&path))?;
    let lesion = match lesion_mask_path {
        Some(p) if !p.trim().is_empty() && Path::new(&p).exists() => {
            Some(load_mask_u8(Path::new(&p))?)
        }
        _ => None,
    };
    let rendered = render_ortho_slice_with_lesion_rgba(
        vol.view(),
        lesion.as_ref().map(|m| m.view()),
        ortho_plane,
        slice_index as usize,
        timepoint as usize,
        overlay_alpha,
    )?;
    Ok(SliceRgba {
        width: rendered.width as u32,
        height: rendered.height as u32,
        rgba: rendered.rgba,
        min_val: rendered.min_val,
        max_val: rendered.max_val,
    })
}

pub fn auto_segment_lesion_asymmetry(
    t1_path: String,
    flair_path: Option<String>,
    z_threshold: f32,
    out_mask_path: String,
) -> Result<LesionSummaryDto> {
    let t1_p = Path::new(&t1_path);
    let t1_vol = load_bold_volume(t1_p)?;
    let hdr = t1_vol.header().clone();
    let t1_3d = t1_vol.view().index_axis(Axis(3), 0).to_owned();

    let flair_3d = match flair_path {
        Some(fp) if !fp.trim().is_empty() => {
            let fv = load_bold_volume(Path::new(&fp))?;
            Some(fv.view().index_axis(Axis(3), 0).to_owned())
        }
        _ => None,
    };

    let (_z_map, mask, summary) = compute_hemispheric_asymmetry(
        t1_3d.view(),
        flair_3d.as_ref().map(|f| f.view()),
        hdr.voxel_sizes,
        Some(hdr.affine),
        z_threshold,
    )?;
    save_mask_u8_nifti(mask.view(), t1_p, Path::new(&out_mask_path))?;
    Ok(to_lesion_dto(summary))
}

fn load_or_init_mask(mask_path: &Path, ref_nifti_path: &Path) -> Result<(Array3<u8>, [f32; 3], [[f32; 4]; 4])> {
    let hdr = inspect_nifti_header(ref_nifti_path)?;
    let mask = if mask_path.exists() {
        load_mask_u8(mask_path)?
    } else {
        Array3::<u8>::zeros((hdr.dims[0], hdr.dims[1], hdr.dims[2]))
    };
    Ok((mask, hdr.voxel_sizes, hdr.affine))
}

pub fn edit_lesion_mask_magic_wand(
    t1_path: String,
    mask_path: String,
    seed_x: u32,
    seed_y: u32,
    seed_z: u32,
    tolerance: f32,
    out_mask_path: String,
) -> Result<LesionSummaryDto> {
    let ref_p = Path::new(&t1_path);
    let vol = load_bold_volume(ref_p)?;
    let vol_view = vol.view();
    let vol3 = vol_view.index_axis(Axis(3), 0);
    let (mut mask, voxel_sizes, affine) = load_or_init_mask(Path::new(&mask_path), ref_p)?;
    magic_wand_3d(
        vol3,
        &mut mask,
        [seed_x as usize, seed_y as usize, seed_z as usize],
        tolerance,
    )?;
    save_mask_u8_nifti(mask.view(), ref_p, Path::new(&out_mask_path))?;
    Ok(to_lesion_dto(summarize_lesion(
        mask.view(),
        voxel_sizes,
        Some(affine),
    )))
}

pub fn edit_lesion_mask_brush(
    mask_path: String,
    ref_nifti_path: String,
    cx: u32,
    cy: u32,
    cz: u32,
    radius_voxels: f32,
    erase: bool,
    slice_plane_only: Option<String>,
    out_mask_path: String,
) -> Result<LesionSummaryDto> {
    let ref_p = Path::new(&ref_nifti_path);
    let (mut mask, voxel_sizes, affine) = load_or_init_mask(Path::new(&mask_path), ref_p)?;
    let plane_opt = slice_plane_only
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(OrthoPlane::parse)
        .transpose()?;
    apply_spherical_brush(
        &mut mask,
        [cx as usize, cy as usize, cz as usize],
        radius_voxels,
        erase,
        plane_opt,
    )?;
    save_mask_u8_nifti(mask.view(), ref_p, Path::new(&out_mask_path))?;
    Ok(to_lesion_dto(summarize_lesion(
        mask.view(),
        voxel_sizes,
        Some(affine),
    )))
}

pub fn morphology_lesion_mask(
    mask_path: String,
    ref_nifti_path: String,
    operation: String,
    param: u32,
    out_mask_path: String,
) -> Result<LesionSummaryDto> {
    let ref_p = Path::new(&ref_nifti_path);
    let hdr = inspect_nifti_header(ref_p)?;
    let mask = load_mask_u8(Path::new(&mask_path))?;
    let updated = match operation.to_ascii_lowercase().as_str() {
        "fill_holes" => fill_holes_3d(mask.view()),
        "remove_islands" => remove_small_islands_3d(mask.view(), (param as usize).max(1)),
        "dilate" => dilate_mask_3d(mask.view(), param as usize),
        other => bail!("Unsupported morphology op '{other}' (expected fill_holes, remove_islands, dilate)"),
    };
    save_mask_u8_nifti(updated.view(), ref_p, Path::new(&out_mask_path))?;
    Ok(to_lesion_dto(summarize_lesion(
        updated.view(),
        hdr.voxel_sizes,
        Some(hdr.affine),
    )))
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
        confound_blocks.push(compute_acompcor_filtered(vol.view(), wm_mask.view(), 5, tr_sec, (low_hz > 0.0).then_some(low_hz))?);
    }
    if let Some(csf_p) = csf_mask_path {
        let csf_mask = load_mask_u8(Path::new(&csf_p))?;
        confound_blocks.push(compute_acompcor_filtered(vol.view(), csf_mask.view(), 5, tr_sec, (low_hz > 0.0).then_some(low_hz))?);
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
    let den = simultaneous_denoise_with_mode(
        raw_ts.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        high_opt,
        &scrub_indices,
        CensorMode::Interpolate,
        true,
    )?;
    let clean_kept = den.kept_ts();
    let denoise_ms = t3.elapsed().as_secs_f64() * 1000.0;

    let t4 = Instant::now();
    let fc = static_fc_pearson(clean_kept.view())?;
    let fc_ms = t4.elapsed().as_secs_f64() * 1000.0;

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
        mean_abs_fc: mean_off_diag(fc.view(), true),
    })
}

fn lerp_u8(a: u8, b: u8, t: f64) -> u8 {
    let v = (a as f64) + ((b as f64) - (a as f64)) * t.clamp(0.0, 1.0);
    v.round().clamp(0.0, 255.0) as u8
}

/// Renders a signed `[-1, 1]` connectivity matrix (`blue -> white -> crimson`, dark slate for NaN).
pub(crate) fn render_fc_matrix_rgba(fc: ArrayView2<'_, f64>) -> (u32, Vec<u8>) {
    let n = fc.nrows().min(fc.ncols());
    let mut rgba = Vec::with_capacity(n * n * 4);
    for i in 0..n {
        for j in 0..n {
            let val = fc[[i, j]];
            if !val.is_finite() {
                rgba.extend_from_slice(&[30, 41, 59, 255]);
            } else if val >= 0.0 {
                let t = val.clamp(0.0, 1.0);
                rgba.push(lerp_u8(248, 220, t));
                rgba.push(lerp_u8(250, 38, t));
                rgba.push(lerp_u8(252, 38, t));
                rgba.push(255);
            } else {
                let t = (-val).clamp(0.0, 1.0);
                rgba.push(lerp_u8(248, 29, t));
                rgba.push(lerp_u8(250, 78, t));
                rgba.push(lerp_u8(252, 216, t));
                rgba.push(255);
            }
        }
    }
    (n as u32, rgba)
}

/// Renders a non-negative `[0, cap]` information-theoretic matrix (white -> amber -> crimson, dark slate for NaN).
pub(crate) fn render_nonneg_matrix_rgba(mat: ArrayView2<'_, f64>) -> Vec<u8> {
    let n = mat.nrows().min(mat.ncols());
    let mut vals: Vec<f64> = Vec::with_capacity(n * n);
    for i in 0..n {
        for j in 0..n {
            if i != j && mat[[i, j]].is_finite() {
                vals.push(mat[[i, j]].max(0.0));
            }
        }
    }
    let scale = if vals.is_empty() {
        0.1
    } else {
        vals.sort_by(|a, b| a.total_cmp(b));
        let p98 = vals[((vals.len() as f64) * 0.98).floor().clamp(0.0, (vals.len() - 1) as f64) as usize];
        p98.max(0.05)
    };

    let mut rgba = Vec::with_capacity(n * n * 4);
    for i in 0..n {
        for j in 0..n {
            let val = mat[[i, j]];
            if !val.is_finite() {
                rgba.extend_from_slice(&[30, 41, 59, 255]);
            } else {
                let t = (val.max(0.0) / scale).clamp(0.0, 1.0);
                if t < 0.5 {
                    let u = t * 2.0;
                    rgba.push(lerp_u8(248, 245, u));
                    rgba.push(lerp_u8(250, 158, u));
                    rgba.push(lerp_u8(252, 11, u));
                    rgba.push(255);
                } else {
                    let u = (t - 0.5) * 2.0;
                    rgba.push(lerp_u8(245, 220, u));
                    rgba.push(lerp_u8(158, 38, u));
                    rgba.push(lerp_u8(11, 38, u));
                    rgba.push(255);
                }
            }
        }
    }
    rgba
}

/// Renders ROI timeseries `(n_timepoints, n_rois)` into a z-scored carpet plot.
pub(crate) fn render_carpet_rgba(ts: ArrayView2<'_, f64>) -> (u32, u32, Vec<u8>) {
    let (nt, n_rois) = ts.dim();
    let mut rgba = vec![0u8; nt * n_rois * 4];
    for r in 0..n_rois {
        let mut sum = 0.0_f64;
        let mut count = 0_usize;
        let mut has_nan = false;
        for t in 0..nt {
            let v = ts[[t, r]];
            if v.is_finite() {
                sum += v;
                count += 1;
            } else {
                has_nan = true;
            }
        }
        if has_nan || count < 2 {
            for t in 0..nt {
                let idx = (r * nt + t) * 4;
                rgba[idx] = 51;
                rgba[idx + 1] = 35;
                rgba[idx + 2] = 40;
                rgba[idx + 3] = 255;
            }
            continue;
        }
        let mean = sum / (count as f64);
        let var: f64 = (0..nt)
            .map(|t| {
                let d = ts[[t, r]] - mean;
                d * d
            })
            .sum::<f64>()
            / (count as f64);
        let std_dev = var.sqrt().max(1e-9);
        for t in 0..nt {
            let z = ((ts[[t, r]] - mean) / std_dev).clamp(-2.5, 2.5);
            let u = (z + 2.5) / 5.0;
            let idx = (r * nt + t) * 4;
            rgba[idx] = lerp_u8(15, 248, u);
            rgba[idx + 1] = lerp_u8(23, 250, u);
            rgba[idx + 2] = lerp_u8(42, 252, u);
            rgba[idx + 3] = 255;
        }
    }
    (nt as u32, n_rois as u32, rgba)
}

fn write_matrix_csv(path: &Path, mat: ArrayView2<'_, f64>) -> Result<()> {
    let f = std::fs::File::create(path)?;
    let mut w = BufWriter::new(f);
    let (nr, nc) = mat.dim();
    for i in 0..nr {
        for j in 0..nc {
            if j > 0 {
                w.write_all(b",")?;
            }
            let v = mat[[i, j]];
            if v.is_finite() {
                write!(w, "{v:.5}")?;
            } else {
                w.write_all(b"NaN")?;
            }
        }
        w.write_all(b"\n")?;
    }
    w.flush()?;
    Ok(())
}

pub(crate) fn export_lesion_pipeline_outputs(
    out_dir: &Path,
    fc_pearson: ArrayView2<'_, f64>,
    fc_partial: Option<ArrayView2<'_, f64>>,
    fc_gcmi: Option<ArrayView2<'_, f64>>,
    fc_te: Option<ArrayView2<'_, f64>>,
    clean_ts: ArrayView2<'_, f64>,
    summary_json: &serde_json::Value,
    report_md: &str,
) -> Result<()> {
    std::fs::create_dir_all(out_dir)
        .with_context(|| format!("Failed to create export folder {}", out_dir.display()))?;
    write_matrix_csv(&out_dir.join("fc_matrix.csv"), fc_pearson)?;
    if let Some(p) = fc_partial {
        write_matrix_csv(&out_dir.join("partial_fc_matrix.csv"), p)?;
    }
    if let Some(g) = fc_gcmi {
        write_matrix_csv(&out_dir.join("gcmi_matrix.csv"), g)?;
    }
    if let Some(te) = fc_te {
        write_matrix_csv(&out_dir.join("te_matrix.csv"), te)?;
    }
    write_matrix_csv(&out_dir.join("denoised_timeseries.csv"), clean_ts)?;
    std::fs::write(
        out_dir.join("biomarkers_summary.json"),
        serde_json::to_string_pretty(summary_json)?,
    )?;
    std::fs::write(out_dir.join("clinical_report.md"), report_md)?;
    Ok(())
}

fn mean_off_diag(mat: ArrayView2<'_, f64>, take_abs: bool) -> f64 {
    let (nr, nc) = mat.dim();
    let mut sum = 0.0_f64;
    let mut count = 0_usize;
    for i in 0..nr {
        for j in 0..nc {
            if i == j {
                continue;
            }
            let v = mat[[i, j]];
            if v.is_finite() {
                sum += if take_abs { v.abs() } else { v };
                count += 1;
            }
        }
    }
    if count > 0 { sum / (count as f64) } else { 0.0 }
}

fn extract_network_name(label: &str) -> String {
    let parts: Vec<&str> = label.split('_').collect();
    if parts.len() >= 3 && (parts[1] == "LH" || parts[1] == "RH") {
        format!("{}_{}", parts[1], parts[2])
    } else if parts.len() >= 2 && (parts[0] == "LH" || parts[0] == "RH") {
        format!("{}_{}", parts[0], parts[1])
    } else {
        "All_ROIs".to_string()
    }
}

fn build_roi_and_network_metadata(
    roi_ids: &[i32],
    labels_json_path: Option<&str>,
) -> (Vec<String>, Vec<String>, Vec<usize>) {
    let all_labels: Option<Vec<String>> = labels_json_path.and_then(|p| {
        if Path::new(p).exists() {
            std::fs::read_to_string(p)
                .ok()
                .and_then(|txt| serde_json::from_str(&txt).ok())
        } else {
            None
        }
    });

    let mut roi_labels = Vec::with_capacity(roi_ids.len());
    for (idx, &id) in roi_ids.iter().enumerate() {
        let lbl = all_labels
            .as_ref()
            .and_then(|vec| vec.get(id as usize).cloned())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("ROI_{:03}", idx + 1));
        roi_labels.push(lbl);
    }

    let mut net_map: BTreeMap<String, usize> = BTreeMap::new();
    let mut raw_nets = Vec::with_capacity(roi_labels.len());
    for lbl in &roi_labels {
        let net = extract_network_name(lbl);
        let len = net_map.len();
        net_map.entry(net.clone()).or_insert(len);
        raw_nets.push(net);
    }
    let network_names: Vec<String> = net_map.keys().cloned().collect();
    let net_lookup: BTreeMap<String, usize> = network_names
        .iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect();
    let roi_network_indices: Vec<usize> = raw_nets.iter().map(|n| net_lookup[n]).collect();

    (roi_labels, network_names, roi_network_indices)
}

fn aggregate_network_matrix(
    mat: ArrayView2<'_, f64>,
    roi_net_idx: &[usize],
    k: usize,
) -> Vec<f32> {
    if k == 0 {
        return Vec::new();
    }
    let mut sums = vec![0.0_f64; k * k];
    let mut counts = vec![0_usize; k * k];
    let n = roi_net_idx.len().min(mat.nrows()).min(mat.ncols());
    for i in 0..n {
        let ci = roi_net_idx[i];
        for j in 0..n {
            if i == j {
                continue;
            }
            let v = mat[[i, j]];
            if v.is_finite() {
                let cj = roi_net_idx[j];
                sums[ci * k + cj] += v;
                counts[ci * k + cj] += 1;
            }
        }
    }
    sums.into_iter()
        .zip(counts)
        .map(|(s, c)| if c > 0 { (s / c as f64) as f32 } else { 0.0 })
        .collect()
}

pub(crate) fn compute_te_net_asymmetry_matrix(te: ArrayView2<'_, f64>) -> Array2<f64> {
    let n = te.nrows().min(te.ncols());
    let mut asym = Array2::<f64>::from_elem((n, n), f64::NAN);
    for i in 0..n {
        if !te[[i, i]].is_finite() {
            continue;
        }
        asym[[i, i]] = 0.0;
        for j in (i + 1)..n {
            let ij = te[[i, j]];
            let ji = te[[j, i]];
            if ij.is_finite() && ji.is_finite() {
                let d = ij - ji;
                asym[[i, j]] = d;
                asym[[j, i]] = -d;
            }
        }
    }
    asym
}

pub(crate) fn render_diverging_matrix_rgba(mat: ArrayView2<'_, f64>) -> Vec<u8> {
    let n = mat.nrows().min(mat.ncols());
    let mut abs_vals: Vec<f64> = Vec::with_capacity(n * n);
    for i in 0..n {
        for j in 0..n {
            if i != j && mat[[i, j]].is_finite() {
                abs_vals.push(mat[[i, j]].abs());
            }
        }
    }
    let scale = if abs_vals.is_empty() {
        0.02
    } else {
        abs_vals.sort_by(|a, b| a.total_cmp(b));
        let idx = ((abs_vals.len() as f64) * 0.98)
            .floor()
            .clamp(0.0, (abs_vals.len() - 1) as f64) as usize;
        abs_vals[idx].max(1e-4)
    };

    let mut rgba = Vec::with_capacity(n * n * 4);
    for i in 0..n {
        for j in 0..n {
            let val = mat[[i, j]];
            if !val.is_finite() {
                rgba.extend_from_slice(&[30, 41, 59, 255]);
            } else if val >= 0.0 {
                let t = (val / scale).clamp(0.0, 1.0);
                rgba.push(lerp_u8(248, 220, t));
                rgba.push(lerp_u8(250, 38, t));
                rgba.push(lerp_u8(252, 38, t));
                rgba.push(255);
            } else {
                let t = ((-val) / scale).clamp(0.0, 1.0);
                rgba.push(lerp_u8(248, 29, t));
                rgba.push(lerp_u8(250, 78, t));
                rgba.push(lerp_u8(252, 216, t));
                rgba.push(255);
            }
        }
    }
    rgba
}

pub(crate) fn compute_net_te_out_minus_in(net_te_flat: &[f32], k: usize) -> Vec<f32> {
    if k < 2 || net_te_flat.len() < k * k {
        return vec![0.0; k];
    }
    (0..k)
        .map(|i| {
            let mut sum = 0.0_f64;
            let mut cnt = 0_usize;
            for j in 0..k {
                if i != j {
                    let out_v = net_te_flat[i * k + j] as f64;
                    let in_v = net_te_flat[j * k + i] as f64;
                    if out_v.is_finite() && in_v.is_finite() {
                        sum += out_v - in_v;
                        cnt += 1;
                    }
                }
            }
            if cnt > 0 { (sum / cnt as f64) as f32 } else { 0.0 }
        })
        .collect()
}

pub fn run_lesion_aware_pipeline(
    bold_path: String,
    atlas_path: String,
    lesion_mask_path: Option<String>,
    atlas_labels_json_path: Option<String>,
    wm_mask_path: Option<String>,
    csf_mask_path: Option<String>,
    confounds_tsv_path: Option<String>,
    low_hz: f64,
    high_hz: f64,
    fd_threshold_mm: f64,
    max_damage_pct: f64,
    lesion_dilate_voxels: u32,
    censor_mode: Option<String>,
    out_dir: Option<String>,
) -> Result<LesionPipelineSummary> {
    let t_total = Instant::now();
    let vol = load_bold_volume(Path::new(&bold_path))?;
    let hdr = vol.header().clone();
    let tr_sec = hdr.tr_sec;
    let atlas = load_atlas_i32(Path::new(&atlas_path))?;
    let lesion_mask = match lesion_mask_path {
        Some(p) if !p.trim().is_empty() => Some(load_mask_u8(Path::new(&p))?),
        _ => None,
    };

    let parc = extract_roi_timeseries_lesion_aware(
        vol.view(),
        atlas.view(),
        lesion_mask.as_ref().map(|m| m.view()),
        hdr.voxel_sizes,
        max_damage_pct,
    )?;
    let (nt, n_rois) = parc.timeseries.dim();

    let mut confound_blocks: Vec<Array2<f64>> = Vec::new();
    let mut scrub_indices: Vec<usize> = Vec::new();
    let mut fd_trace: Vec<f32> = vec![0.0; nt];
    if let Some(conf_path) = confounds_tsv_path {
        if !conf_path.trim().is_empty() {
            let (motion_mat, fd_spikes, fds) =
                load_confounds_with_fd(Path::new(&conf_path), nt, fd_threshold_mm)?;
            if motion_mat.ncols() > 0 {
                confound_blocks.push(motion_mat);
            }
            scrub_indices = fd_spikes;
            fd_trace = fds;
        }
    }

    if let Some(wm_p) = wm_mask_path {
        if !wm_p.trim().is_empty() {
            let raw_wm = load_mask_u8(Path::new(&wm_p))?;
            let safe_wm = match &lesion_mask {
                Some(lm) => subtract_lesion_from_mask(raw_wm.view(), lm.view(), lesion_dilate_voxels as usize)?,
                None => raw_wm,
            };
            if safe_wm.iter().any(|&v| v > 0) {
                confound_blocks.push(compute_acompcor_filtered(vol.view(), safe_wm.view(), 5, tr_sec, (low_hz > 0.0).then_some(low_hz))?);
            }
        }
    }
    if let Some(csf_p) = csf_mask_path {
        if !csf_p.trim().is_empty() {
            let raw_csf = load_mask_u8(Path::new(&csf_p))?;
            let safe_csf = match &lesion_mask {
                Some(lm) => subtract_lesion_from_mask(raw_csf.view(), lm.view(), lesion_dilate_voxels as usize)?,
                None => raw_csf,
            };
            if safe_csf.iter().any(|&v| v > 0) {
                confound_blocks.push(compute_acompcor_filtered(vol.view(), safe_csf.view(), 5, tr_sec, (low_hz > 0.0).then_some(low_hz))?);
            }
        }
    }

    let combined_conf = if confound_blocks.is_empty() {
        None
    } else {
        let views: Vec<_> = confound_blocks.iter().map(|b| b.view()).collect();
        Some(concatenate(Axis(1), &views)?)
    };
    if let Some(c) = &combined_conf {
        if !c.iter().all(|v| v.is_finite()) {
            bail!("Confound matrix contains non-finite values; check confounds.tsv and the WM/CSF masks");
        }
    }

    // Raw FC & raw carpet before denoising (CONN QC baseline).
    let raw_fc = static_fc_pearson(parc.timeseries.view())?;
    let (raw_fc_hist, raw_fc_mean, raw_fc_sd) = compute_fc_histogram(raw_fc.view(), 41);
    let (_, _, raw_carpet_rgba) = render_carpet_rgba(parc.timeseries.view());

    let low_opt = if low_hz > 0.0 { Some(low_hz) } else { None };
    let high_opt = if high_hz > 0.0 { Some(high_hz) } else { None };
    let mode_enum = CensorMode::from_str_opt(censor_mode.as_deref());
    let denoise_res = simultaneous_denoise_with_mode(
        parc.timeseries.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        high_opt,
        &scrub_indices,
        mode_enum,
        true,
    )?;
    let kept_rows = denoise_res.kept_rows.clone();
    let clean_kept = denoise_res.kept_ts();
    let clean_ts = denoise_res.clean_ts;
    let n_regressors = denoise_res.n_regressors as u32;
    let dof_remaining = denoise_res.dof_remaining as u32;
    let n_kept = kept_rows.len();
    let censor_mode_label = mode_enum.as_str().to_string();
    let mut valid_frames = vec![false; nt];
    for &r in &kept_rows {
        valid_frames[r] = true;
    }

    // Same nuisance model but high-pass only, for timescale/complexity dynamics. Censored frames are
    // linearly interpolated here (never zero-filled spike residuals) so autocorrelation-based
    // measures see a continuous series.
    let clean_ts_hp = simultaneous_denoise_with_mode(
        parc.timeseries.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        None,
        &scrub_indices,
        if mode_enum == CensorMode::None { CensorMode::None } else { CensorMode::Interpolate },
        true,
    )?
    .clean_ts;

    // All statistics use retained (uncensored) frames only (Power et al., 2014).
    let fc = static_fc_pearson(clean_kept.view())?;
    let (clean_fc_hist, clean_fc_mean, clean_fc_sd) = compute_fc_histogram(fc.view(), 41);
    let fc_partial = compute_partial_correlation_ledoit_wolf(clean_kept.view())?;
    let fc_gcmi = compute_gcmi_matrix(clean_kept.view());
    let fc_te = compute_transfer_entropy_matrix_masked(clean_ts.view(), 1, Some(&valid_frames));
    let n_intact_rois_now = (0..n_rois)
        .filter(|&c| clean_kept.column(c).iter().all(|v| v.is_finite()))
        .count();
    let dof_warning = if (dof_remaining as usize) < 30 {
        format!("CRITICAL: only {dof_remaining} residual degrees of freedom; FC estimates are unreliable. Widen the band (e.g. high_hz=0.1-0.15), use fewer confounds, or a coarser atlas.")
    } else if (dof_remaining as usize) < n_intact_rois_now {
        format!("WARNING: {dof_remaining} residual DOF < {n_intact_rois_now} ROIs; partial correlation and multivariate measures are rank-deficient (shrinkage-dominated).")
    } else {
        String::new()
    };

    let graph = compute_nan_safe_graph_metrics(fc.view(), 0.0, None)?;

    let lesion_summary = lesion_mask.as_ref().map(|lm| {
        summarize_lesion(lm.view(), hdr.voxel_sizes, Some(hdr.affine))
    });
    let dominant_hemi = lesion_summary
        .as_ref()
        .map_or_else(|| "None".to_string(), |s| s.dominant_hemisphere.clone());

    let (roi_labels, network_names, roi_network_indices) =
        build_roi_and_network_metadata(&parc.roi_ids, atlas_labels_json_path.as_deref());

    let (mean_homotopic_fc, laterality_index) = if roi_labels.len() == n_rois {
        let (lh, rh) = detect_schaefer_hemispheres(&roi_labels);
        if !lh.is_empty() && !rh.is_empty() {
            let hl = compute_homotopic_and_laterality(fc.view(), &lh, &rh, &dominant_hemi);
            (hl.mean_homotopic_fc, hl.laterality_index)
        } else {
            (0.0, 0.0)
        }
    } else {
        (0.0, 0.0)
    };

    let lesion_seed_mean_abs_r = if let Some(lm) = &lesion_mask {
        let seed_r = lesion_network_mapping(vol.view(), lm.view(), clean_ts.view())?;
        let finite: Vec<f64> = seed_r.into_iter().filter(|v| v.is_finite()).collect();
        if finite.is_empty() {
            0.0
        } else {
            finite.iter().map(|v| v.abs()).sum::<f64>() / (finite.len() as f64)
        }
    } else {
        0.0
    };

    let mean_abs_fc = mean_off_diag(fc.view(), true);
    let mean_abs_partial_fc = mean_off_diag(fc_partial.view(), true);
    let mean_gcmi_bits = mean_off_diag(fc_gcmi.view(), false);
    let mean_te_bits = mean_off_diag(fc_te.view(), false);
    let mean_fd_mm = if fd_trace.is_empty() {
        0.0
    } else {
        fd_trace.iter().map(|&v| v as f64).sum::<f64>() / (fd_trace.len() as f64)
    };
    let pct_scrubbed = if nt > 0 {
        (scrub_indices.len() as f64) * 100.0 / (nt as f64)
    } else {
        0.0
    };

    let k = network_names.len();
    let net_pearson_flat = aggregate_network_matrix(fc.view(), &roi_network_indices, k);
    let net_partial_flat = aggregate_network_matrix(fc_partial.view(), &roi_network_indices, k);
    let net_gcmi_flat = aggregate_network_matrix(fc_gcmi.view(), &roi_network_indices, k);
    let net_te_flat = aggregate_network_matrix(fc_te.view(), &roi_network_indices, k);

    let te_asym = compute_te_net_asymmetry_matrix(fc_te.view());
    let te_net_preview_rgba = render_diverging_matrix_rgba(te_asym.view());
    let net_te_asym_flat = aggregate_network_matrix(te_asym.view(), &roi_network_indices, k);
    let net_te_out_minus_in = compute_net_te_out_minus_in(&net_te_flat, k);

    let (fc_preview_size, fc_preview_rgba) = render_fc_matrix_rgba(fc.view());
    let (_, partial_preview_rgba) = render_fc_matrix_rgba(fc_partial.view());
    let gcmi_preview_rgba = render_nonneg_matrix_rgba(fc_gcmi.view());
    let te_preview_rgba = render_nonneg_matrix_rgba(fc_te.view());
    let (carpet_width, carpet_height, carpet_rgba) = render_carpet_rgba(clean_ts.view());

    let scrubbed_u32: Vec<u32> = scrub_indices.iter().map(|&i| i as u32).collect();
    let total_ms = t_total.elapsed().as_secs_f64() * 1000.0;

    let exported_dir = match out_dir {
        Some(ref dir) if !dir.trim().is_empty() => {
            let summary_json = serde_json::json!({
                "bold_path": bold_path,
                "atlas_path": atlas_path,
                "n_timepoints": nt,
                "n_rois": n_rois,
                "n_intact_rois": graph.n_intact_nodes,
                "n_excluded_rois": graph.n_excluded_nodes,
                "tr_sec": tr_sec,
                "used_mmap": hdr.used_mmap,
                "low_hz": low_hz,
                "high_hz": high_hz,
                "fd_threshold_mm": fd_threshold_mm,
                "mean_fd_mm": mean_fd_mm,
                "pct_scrubbed": pct_scrubbed,
                "censor_mode": censor_mode_label,
                "n_regressors": n_regressors,
                "dof_remaining": dof_remaining,
                "n_frames_retained": n_kept,
                "n_frames_censored": nt - n_kept,
                "dof_warning": dof_warning,
                "statistics_use_retained_frames_only": true,
                "raw_fc_mean": raw_fc_mean,
                "raw_fc_sd": raw_fc_sd,
                "clean_fc_mean": clean_fc_mean,
                "clean_fc_sd": clean_fc_sd,
                "max_damage_pct": max_damage_pct,
                "lesion_volume_ml": parc.total_lesion_volume_ml,
                "dominant_hemisphere": dominant_hemi,
                "global_efficiency": graph.global_efficiency,
                "mean_node_strength": graph.mean_node_strength,
                "mean_homotopic_fc": mean_homotopic_fc,
                "laterality_index": laterality_index,
                "lesion_seed_mean_abs_r": lesion_seed_mean_abs_r,
                "mean_abs_fc": mean_abs_fc,
                "mean_abs_partial_fc": mean_abs_partial_fc,
                "mean_gcmi_bits": mean_gcmi_bits,
                "mean_te_bits": mean_te_bits,
                "total_ms": total_ms,
            });
            let dof_warning_md = if dof_warning.is_empty() { "OK".to_string() } else { dof_warning.clone() };
            let report_md = format!(
                "# CCS fMRI Studio — Clinical & Connectivity Report\n\n\
                | Metric | Value |\n\
                | :--- | :--- |\n\
                | **4D BOLD Input** | `{bold_path}` |\n\
                | **Timepoints / TR** | {nt} volumes @ {tr_sec:.2} s |\n\
                | **Intact / Total ROIs** | {}/{} (Excluded: {}) |\n\
                | **CONN QC (Raw FC -> Clean FC)** | {raw_fc_mean:.3} ± {raw_fc_sd:.3} → {clean_fc_mean:.3} ± {clean_fc_sd:.3} |\n\
                | **Mean FD / Scrubbed** | {mean_fd_mm:.3} mm / {pct_scrubbed:.1}% ({censor_mode_label}; {n_kept}/{nt} frames retained; residual DOF: {dof_remaining}) |\n\
                | **DOF check** | {dof_warning_md} |\n\
                | **Lesion Volume** | {:.2} mL ({dominant_hemi}) |\n\
                | **Mean \\|Pearson FC\\|** | {mean_abs_fc:.4} |\n\
                | **Mean \\|Partial FC\\| (Ledoit-Wolf)** | {mean_abs_partial_fc:.4} |\n\
                | **Mean GCMI** | {mean_gcmi_bits:.4} bits |\n\
                | **Mean Transfer Entropy** | {mean_te_bits:.4} bits |\n\
                | **Global Efficiency** | {:.4} |\n\
                | **Mean Node Strength** | {:.2} |\n\
                | **Homotopic FC** | {mean_homotopic_fc:.4} |\n\
                | **Laterality Index** | {laterality_index:.4} |\n\
                | **Lesion-Seed Mean \\|r\\|** | {lesion_seed_mean_abs_r:.4} |\n\
                | **Rust Processing Time** | {total_ms:.1} ms (mmap: {}) |\n\n\
                Generated files: `fc_matrix.csv`, `partial_fc_matrix.csv`, `gcmi_matrix.csv`, `te_matrix.csv`, `denoised_timeseries.csv` (all frames), `raw_timeseries.csv` (before denoising), `censor_mask.csv` (1 = retained), `confounds_used.csv`, `biomarkers_summary.json`, `clinical_report.md`. All statistics use retained frames only.\n",
                graph.n_intact_nodes,
                n_rois,
                graph.n_excluded_nodes,
                parc.total_lesion_volume_ml,
                graph.global_efficiency,
                graph.mean_node_strength,
                hdr.used_mmap,
            );
            export_lesion_pipeline_outputs(
                Path::new(dir.trim()),
                fc.view(),
                Some(fc_partial.view()),
                Some(fc_gcmi.view()),
                Some(fc_te.view()),
                clean_ts.view(),
                &summary_json,
                &report_md,
            )?;
            // Raw (pre-denoising) ROI series, for before/after denoising figures.
            write_matrix_csv(&Path::new(dir.trim()).join("raw_timeseries.csv"), parc.timeseries.view())?;
            write_matrix_csv(&Path::new(dir.trim()).join("censor_mask.csv"), {
                let mut m = Array2::<f64>::zeros((nt, 1));
                for &r in &kept_rows {
                    m[[r, 0]] = 1.0;
                }
                m
            }.view())?;
            match &combined_conf {
                Some(c) => write_matrix_csv(&Path::new(dir.trim()).join("confounds_used.csv"), c.view())?,
                None => write_matrix_csv(&Path::new(dir.trim()).join("confounds_used.csv"), Array2::<f64>::zeros((nt, 0)).view())?,
            }
            Some(dir.trim().to_string())
        }
        _ => None,
    };

    // Save session in Rust memory for sub-millisecond interactive UI queries.
    {
        let mut guard = session_lock()
            .write()
            .map_err(|_| anyhow::anyhow!("Session cache write lock poisoned"))?;
        *guard = Some(CachedSession {
            raw_ts: parc.timeseries,
            clean_ts,
            clean_ts_hp,
            tr_sec,
            bandpass_low_hz: low_hz,
            bandpass_high_hz: high_hz,
            roi_labels: roi_labels.clone(),
            network_names: network_names.clone(),
            roi_network_indices: roi_network_indices.clone(),
            fc_pearson: fc,
            fc_partial,
            fc_gcmi,
            fc_te,
            fd_trace: fd_trace.clone(),
            scrubbed_indices: scrubbed_u32.clone(),
        });
    }

    Ok(LesionPipelineSummary {
        n_timepoints: nt as u32,
        n_rois: n_rois as u32,
        n_intact_rois: graph.n_intact_nodes as u32,
        n_excluded_rois: graph.n_excluded_nodes as u32,
        tr_sec,
        used_mmap: hdr.used_mmap,
        lesion_volume_ml: parc.total_lesion_volume_ml,
        dominant_hemisphere: dominant_hemi,
        global_efficiency: graph.global_efficiency,
        mean_node_strength: graph.mean_node_strength,
        mean_homotopic_fc,
        laterality_index,
        lesion_seed_mean_abs_r,
        mean_abs_fc,
        total_ms,
        fc_preview_rgba,
        fc_preview_size,
        carpet_rgba,
        carpet_width,
        carpet_height,
        exported_dir,
        raw_fc_hist,
        clean_fc_hist,
        raw_fc_mean,
        raw_fc_sd,
        clean_fc_mean,
        clean_fc_sd,
        mean_fd_mm,
        pct_scrubbed,
        fd_trace,
        scrubbed_indices: scrubbed_u32,
        raw_carpet_rgba,
        roi_labels,
        network_names,
        roi_network_indices: roi_network_indices.into_iter().map(|i| i as u32).collect(),
        mean_abs_partial_fc,
        mean_gcmi_bits,
        mean_te_bits,
        partial_preview_rgba,
        gcmi_preview_rgba,
        te_preview_rgba,
        net_pearson_flat,
        net_partial_flat,
        net_gcmi_flat,
        net_te_flat,
        censor_mode: censor_mode_label,
        n_regressors,
        dof_remaining,
        te_net_preview_rgba,
        net_te_asym_flat,
        net_te_out_minus_in,
    })
}

fn zscore_f32(vals: &[f64]) -> Vec<f32> {
    let n = vals.len();
    if n == 0 || vals.iter().any(|v| !v.is_finite()) {
        return vec![0.0; n];
    }
    let mean = vals.iter().sum::<f64>() / (n as f64);
    let var = vals.iter().map(|&v| (v - mean) * (v - mean)).sum::<f64>() / (n as f64);
    let sd = var.sqrt().max(1e-9);
    vals.iter().map(|&v| ((v - mean) / sd) as f32).collect()
}

fn robust_zscore_f32(vals: &[f64]) -> Vec<f32> {
    let n = vals.len();
    if n == 0 || vals.iter().any(|v| !v.is_finite()) {
        return vec![0.0; n];
    }
    let mut sorted = vals.to_vec();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let med = if n % 2 == 1 {
        sorted[n / 2]
    } else {
        0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    };
    let mut abs_dev: Vec<f64> = vals.iter().map(|&v| (v - med).abs()).collect();
    abs_dev.sort_by(|a, b| a.total_cmp(b));
    let mad = if n % 2 == 1 {
        abs_dev[n / 2]
    } else {
        0.5 * (abs_dev[n / 2 - 1] + abs_dev[n / 2])
    };
    let sigma = (1.4826 * mad).max(0.0);
    if sigma > 1e-6 {
        return vals
            .iter()
            .map(|&v| (((v - med) / sigma).clamp(-6.0, 6.0)) as f32)
            .collect();
    }
    zscore_f32(vals)
}

pub fn get_roi_timeseries_detail(roi_indices: Vec<u32>) -> Result<RoiTimeseriesDetailDto> {
    let guard = session_lock()
        .read()
        .map_err(|_| anyhow::anyhow!("Session cache read lock poisoned"))?;
    let sess = guard
        .as_ref()
        .context("Run denoising in Step 4 first to populate session timeseries")?;

    let (nt, n_rois) = sess.clean_ts.dim();
    let fs = if sess.tr_sec > 0.0 { 1.0 / sess.tr_sec } else { 0.5 };
    let nperseg = (nt / 2).max(16).min(nt);

    let mut traces = Vec::new();
    let mut valid_indices = Vec::new();
    for raw_idx in roi_indices {
        let r = raw_idx as usize;
        if r >= n_rois {
            continue;
        }
        valid_indices.push(r);
        let raw_col: Vec<f64> = (0..nt).map(|t| sess.raw_ts[[t, r]]).collect();
        let clean_col: Vec<f64> = (0..nt).map(|t| sess.clean_ts[[t, r]]).collect();
        let is_intact = clean_col.iter().all(|v| v.is_finite());

        let variance_removed_pct = if is_intact && raw_col.iter().all(|v| v.is_finite()) {
            let raw_mean = raw_col.iter().sum::<f64>() / (nt as f64);
            let clean_mean = clean_col.iter().sum::<f64>() / (nt as f64);
            let raw_var = raw_col.iter().map(|&v| (v - raw_mean).powi(2)).sum::<f64>();
            // Measure fraction of linear energy removed by projecting clean onto demeaned raw.
            let proj_num: f64 = raw_col
                .iter()
                .zip(clean_col.iter())
                .map(|(&rw, &cl)| (rw - raw_mean) * (cl - clean_mean))
                .sum();
            let clean_var = clean_col.iter().map(|&v| (v - clean_mean).powi(2)).sum::<f64>();
            if raw_var > 1e-12 && clean_var > 1e-12 {
                let r2 = ((proj_num * proj_num) / (raw_var * clean_var)).clamp(0.0, 1.0);
                ((1.0 - r2) * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            }
        } else {
            0.0
        };

        let raw_z = robust_zscore_f32(&raw_col);
        let clean_z = zscore_f32(&clean_col);
        let raw_std_z = zscore_f32(&raw_col);
        let raw_centered_f64: Vec<f64> = raw_std_z.iter().map(|&v| v as f64).collect();
        let clean_centered_f64: Vec<f64> = clean_z.iter().map(|&v| v as f64).collect();
        let (freqs, r_psd) = welch_psd(&raw_centered_f64, fs, nperseg);
        let (_, c_psd) = welch_psd(&clean_centered_f64, fs, nperseg);

        let net_name = sess
            .roi_network_indices
            .get(r)
            .and_then(|&ni| sess.network_names.get(ni))
            .cloned()
            .unwrap_or_else(|| "Other".to_string());

        traces.push(RoiTraceDto {
            roi_index: raw_idx,
            label: sess
                .roi_labels
                .get(r)
                .cloned()
                .unwrap_or_else(|| format!("ROI_{:03}", r + 1)),
            network: net_name,
            is_intact,
            variance_removed_pct,
            raw_z,
            clean_z,
            psd_freqs: freqs.into_iter().map(|f| f as f32).collect(),
            raw_psd: r_psd.into_iter().map(|p| p as f32).collect(),
            clean_psd: c_psd.into_iter().map(|p| p as f32).collect(),
        });
    }

    let pairwise = if valid_indices.len() >= 2 {
        let a = valid_indices[0];
        let b = valid_indices[1];
        Some(PairwiseCouplingDto {
            roi_a: a as u32,
            roi_b: b as u32,
            label_a: sess.roi_labels[a].clone(),
            label_b: sess.roi_labels[b].clone(),
            pearson_r: sess.fc_pearson[[a, b]],
            partial_r: sess.fc_partial[[a, b]],
            gcmi_bits: sess.fc_gcmi[[a, b]],
            te_a_to_b: sess.fc_te[[a, b]],
            te_b_to_a: sess.fc_te[[b, a]],
        })
    } else {
        None
    };

    Ok(RoiTimeseriesDetailDto {
        tr_sec: sess.tr_sec,
        fd_trace: sess.fd_trace.clone(),
        scrubbed_indices: sess.scrubbed_indices.clone(),
        traces,
        pairwise,
    })
}

pub fn get_top_hubs(metric: String, top_k: u32) -> Result<Vec<RoiHubDto>> {
    let guard = session_lock()
        .read()
        .map_err(|_| anyhow::anyhow!("Session cache read lock poisoned"))?;
    let sess = guard
        .as_ref()
        .context("Run denoising in Step 4 first")?;

    let n = sess.roi_labels.len();
    let mode = metric.to_ascii_lowercase();
    let mut hubs = Vec::with_capacity(n);

    for i in 0..n {
        let mut sum = 0.0_f64;
        let mut count = 0_usize;
        for j in 0..n {
            if i == j {
                continue;
            }
            let val = match mode.as_str() {
                "partial" => sess.fc_partial[[i, j]].abs(),
                "gcmi" => sess.fc_gcmi[[i, j]],
                "te_out" => sess.fc_te[[i, j]],
                "te_in" => sess.fc_te[[j, i]],
                _ => sess.fc_pearson[[i, j]].abs(),
            };
            if val.is_finite() {
                sum += val;
                count += 1;
            }
        }
        if count > 0 {
            let net_name = sess
                .roi_network_indices
                .get(i)
                .and_then(|&ni| sess.network_names.get(ni))
                .cloned()
                .unwrap_or_else(|| "Other".to_string());
            hubs.push(RoiHubDto {
                roi_index: i as u32,
                label: sess.roi_labels[i].clone(),
                network: net_name,
                score: sum / (count as f64),
            });
        }
    }

    hubs.sort_by(|a, b| b.score.total_cmp(&a.score));
    hubs.truncate((top_k as usize).max(1));
    Ok(hubs)
}

pub fn compute_cached_dynamics(
    window_len: u32,
    step: u32,
    low_hz: f64,
    high_hz: f64,
    out_dir: Option<String>,
) -> Result<DynamicsSummaryDto> {
    let guard = session_lock()
        .read()
        .map_err(|_| anyhow::anyhow!("Session cache read lock poisoned"))?;
    let sess = guard
        .as_ref()
        .context("Run denoising in Step 4 before computing dynamics")?;

    // Time-domain metrics (ACW, LZC, SampEn) are computed on the nuisance-cleaned, high-pass-only
    // series; spectral metrics are restricted to [low_hz, high_hz] inside calc_window_metrics.
    let skip_bandpass = true;
    let rows = compute_sliding_dynamics_opt(
        sess.clean_ts_hp.view(),
        sess.tr_sec,
        (window_len as usize).max(16),
        (step as usize).max(1),
        low_hz,
        high_hz,
        skip_bandpass,
    )?;

    fn avg(vals: &[f64]) -> (f64, f64) {
        let fin: Vec<f64> = vals.iter().copied().filter(|v| v.is_finite()).collect();
        if fin.is_empty() {
            return (0.0, 0.0);
        }
        let m = fin.iter().sum::<f64>() / (fin.len() as f64);
        let var = fin.iter().map(|&v| (v - m) * (v - m)).sum::<f64>() / (fin.len() as f64);
        (m, var.sqrt())
    }

    let intact_rows: Vec<_> = rows.iter().filter(|r| r.is_intact).collect();
    let (acw0_m, _) = avg(&intact_rows.iter().map(|r| r.acw0_mean).collect::<Vec<_>>());
    let (acw50_m, _) = avg(&intact_rows.iter().map(|r| r.acw50_mean).collect::<Vec<_>>());
    let (aucr_m, _) = avg(&intact_rows.iter().map(|r| r.auc_rect_mean).collect::<Vec<_>>());
    let (auct_m, _) = avg(&intact_rows.iter().map(|r| r.auc_trap_mean).collect::<Vec<_>>());
    let (lzc_m, _) = avg(&intact_rows.iter().map(|r| r.lzc_mean).collect::<Vec<_>>());
    let (sampen_m, _) = avg(&intact_rows.iter().map(|r| r.sampen_mean).collect::<Vec<_>>());
    let (medf_m, _) = avg(&intact_rows.iter().map(|r| r.med_f_mean).collect::<Vec<_>>());
    let (se_m, _) = avg(&intact_rows.iter().map(|r| r.se_mean).collect::<Vec<_>>());
    let (ple_m, _) = avg(&intact_rows.iter().map(|r| r.ple_mean).collect::<Vec<_>>());

    let intact_groups: Vec<usize> = intact_rows
        .iter()
        .map(|r| *sess.roi_network_indices.get(r.roi_index).unwrap_or(&0))
        .collect();
    let (anova_f_acw0, anova_p_acw0) = one_way_anova_by_group(
        &intact_rows.iter().map(|r| r.acw0_mean).collect::<Vec<_>>(),
        &intact_groups,
    );
    let (anova_f_lzc, anova_p_lzc) = one_way_anova_by_group(
        &intact_rows.iter().map(|r| r.lzc_mean).collect::<Vec<_>>(),
        &intact_groups,
    );
    let (anova_f_sampen, anova_p_sampen) = one_way_anova_by_group(
        &intact_rows.iter().map(|r| r.sampen_mean).collect::<Vec<_>>(),
        &intact_groups,
    );
    let (anova_f_ple, anova_p_ple) = one_way_anova_by_group(
        &intact_rows.iter().map(|r| r.ple_mean).collect::<Vec<_>>(),
        &intact_groups,
    );

    let mut net_summaries = Vec::with_capacity(sess.network_names.len());
    for (net_idx, net_name) in sess.network_names.iter().enumerate() {
        let nr: Vec<_> = intact_rows
            .iter()
            .copied()
            .filter(|r| sess.roi_network_indices.get(r.roi_index) == Some(&net_idx))
            .collect();
        let (a0m, a0s) = avg(&nr.iter().map(|r| r.acw0_mean).collect::<Vec<_>>());
        let (a50m, a50s) = avg(&nr.iter().map(|r| r.acw50_mean).collect::<Vec<_>>());
        let (rm, _) = avg(&nr.iter().map(|r| r.auc_rect_mean).collect::<Vec<_>>());
        let (tm, _) = avg(&nr.iter().map(|r| r.auc_trap_mean).collect::<Vec<_>>());
        let (lm, ls) = avg(&nr.iter().map(|r| r.lzc_mean).collect::<Vec<_>>());
        let (sm, ss) = avg(&nr.iter().map(|r| r.sampen_mean).collect::<Vec<_>>());
        let (mfm, _) = avg(&nr.iter().map(|r| r.med_f_mean).collect::<Vec<_>>());
        let (sem, _) = avg(&nr.iter().map(|r| r.se_mean).collect::<Vec<_>>());
        let (pm, ps) = avg(&nr.iter().map(|r| r.ple_mean).collect::<Vec<_>>());

        net_summaries.push(NetworkDynamicsDto {
            network_name: net_name.clone(),
            n_intact_rois: nr.len() as u32,
            acw0_mean: a0m,
            acw0_sd: a0s,
            acw50_mean: a50m,
            acw50_sd: a50s,
            auc_rect_mean: rm,
            auc_trap_mean: tm,
            lzc_mean: lm,
            lzc_sd: ls,
            sampen_mean: sm,
            sampen_sd: ss,
            med_f_mean: mfm,
            se_mean: sem,
            ple_mean: pm,
            ple_sd: ps,
        });
    }

    let exported_csv_path = match out_dir {
        Some(ref dir) if !dir.trim().is_empty() => {
            let p = Path::new(dir.trim());
            std::fs::create_dir_all(p)?;
            let csv_path = p.join("roi_dynamics.csv");
            let f = std::fs::File::create(&csv_path)?;
            let mut w = BufWriter::new(f);
            writeln!(
                w,
                "roi_index,label,network,intact,acw0,acw50,auc_rect,auc_trap,lzc,sampen,med_f,se,ple,acw0_std,acw50_std,lzc_std,sampen_std,ple_std"
            )?;
            for r in &rows {
                let lbl = sess.roi_labels.get(r.roi_index).map_or("", String::as_str);
                let net = sess
                    .roi_network_indices
                    .get(r.roi_index)
                    .and_then(|&ni| sess.network_names.get(ni))
                    .map_or("Other", String::as_str);
                writeln!(
                    w,
                    "{},{},{},{},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5},{:.5}",
                    r.roi_index,
                    lbl,
                    net,
                    r.is_intact,
                    r.acw0_mean,
                    r.acw50_mean,
                    r.auc_rect_mean,
                    r.auc_trap_mean,
                    r.lzc_mean,
                    r.sampen_mean,
                    r.med_f_mean,
                    r.se_mean,
                    r.ple_mean,
                    r.acw0_std,
                    r.acw50_std,
                    r.lzc_std,
                    r.sampen_std,
                    r.ple_std,
                )?;
            }
            w.flush()?;
            Some(csv_path.display().to_string())
        }
        _ => None,
    };

    Ok(DynamicsSummaryDto {
        n_intact_rois: intact_rows.len() as u32,
        low_hz,
        high_hz,
        window_len,
        step,
        acw0_mean: acw0_m,
        acw50_mean: acw50_m,
        auc_rect_mean: aucr_m,
        auc_trap_mean: auct_m,
        lzc_mean: lzc_m,
        sampen_mean: sampen_m,
        med_f_mean: medf_m,
        se_mean: se_m,
        ple_mean: ple_m,
        networks: net_summaries,
        exported_csv_path,
        anova_f_acw0,
        anova_p_acw0,
        anova_f_lzc,
        anova_p_lzc,
        anova_f_sampen,
        anova_p_sampen,
        anova_f_ple,
        anova_p_ple,
    })
}

pub fn compute_graph_theory(
    metric: String,
    density: f64,
    weighted: bool,
    export_dir: Option<String>,
) -> Result<GraphTheorySummaryDto> {
    let guard = session_lock()
        .read()
        .map_err(|_| anyhow::anyhow!("Session cache read lock poisoned"))?;
    let sess = guard
        .as_ref()
        .context("Run denoising in Step 4 before computing Graph Theory metrics")?;

    let mode = metric.trim().to_ascii_lowercase();
    let mat_view = match mode.as_str() {
        "partial" => sess.fc_partial.view(),
        "gcmi" => sess.fc_gcmi.view(),
        "te" | "te_out" => sess.fc_te.view(),
        _ => sess.fc_pearson.view(),
    };

    let res = compute_full_graph_theory(mat_view, &sess.roi_network_indices, density, weighted)?;

    let nodal: Vec<NodalGraphDto> = res
        .nodal
        .into_iter()
        .map(|nr| {
            let net_name = sess
                .roi_network_indices
                .get(nr.roi_index)
                .and_then(|&ni| sess.network_names.get(ni))
                .cloned()
                .unwrap_or_else(|| "Other".to_string());
            NodalGraphDto {
                roi_index: nr.roi_index as u32,
                label: sess
                    .roi_labels
                    .get(nr.roi_index)
                    .cloned()
                    .unwrap_or_else(|| format!("ROI_{:03}", nr.roi_index + 1)),
                network: net_name,
                degree: nr.degree as u32,
                strength: nr.strength,
                clustering: nr.clustering,
                local_efficiency: nr.local_efficiency,
                betweenness: nr.betweenness,
                participation_coeff: nr.participation_coeff,
                within_module_z: nr.within_module_z,
            }
        })
        .collect();

    let sweep: Vec<DensitySweepDto> = res
        .sweep
        .into_iter()
        .map(|sp| DensitySweepDto {
            density: sp.density,
            global_efficiency: sp.global_efficiency,
            clustering_coeff: sp.clustering_coeff,
            small_worldness: sp.small_worldness,
            modularity_q: sp.modularity_q,
        })
        .collect();

    let (exported_csv_path, exported_json_path) = match export_dir {
        Some(ref dir) if !dir.trim().is_empty() => {
            let p = Path::new(dir.trim());
            std::fs::create_dir_all(p)?;
            let csv_path = p.join("graph_metrics_nodal.csv");
            let json_path = p.join("graph_metrics_global.json");

            let f = std::fs::File::create(&csv_path)?;
            let mut w = BufWriter::new(f);
            writeln!(
                w,
                "roi_index,label,network,degree,strength,clustering,local_efficiency,betweenness,participation_coeff,within_module_z"
            )?;
            for nr in &nodal {
                writeln!(
                    w,
                    "{},{},{},{},{:.5},{:.5},{:.5},{:.6},{:.5},{:.5}",
                    nr.roi_index,
                    nr.label,
                    nr.network,
                    nr.degree,
                    nr.strength,
                    nr.clustering,
                    nr.local_efficiency,
                    nr.betweenness,
                    nr.participation_coeff,
                    nr.within_module_z,
                )?;
            }
            w.flush()?;

            let global_json = serde_json::json!({
                "metric": mode,
                "density": res.density,
                "weighted": res.weighted,
                "n_intact_nodes": res.n_intact_nodes,
                "n_excluded_nodes": res.n_excluded_nodes,
                "n_edges": res.n_edges,
                "global_efficiency": res.global_efficiency,
                "mean_local_efficiency": res.mean_local_efficiency,
                "clustering_coeff": res.clustering_coeff,
                "char_path_length": res.char_path_length,
                "small_worldness": res.small_worldness,
                "modularity_q": res.modularity_q,
                "assortativity": res.assortativity,
                "sweep": sweep.iter().map(|s| serde_json::json!({
                    "density": s.density,
                    "global_efficiency": s.global_efficiency,
                    "clustering_coeff": s.clustering_coeff,
                    "small_worldness": s.small_worldness,
                    "modularity_q": s.modularity_q,
                })).collect::<Vec<_>>(),
            });
            std::fs::write(&json_path, serde_json::to_string_pretty(&global_json)?)?;
            (
                Some(csv_path.display().to_string()),
                Some(json_path.display().to_string()),
            )
        }
        _ => (None, None),
    };

    Ok(GraphTheorySummaryDto {
        metric: mode,
        density: res.density,
        weighted: res.weighted,
        n_intact_nodes: res.n_intact_nodes as u32,
        n_excluded_nodes: res.n_excluded_nodes as u32,
        n_edges: res.n_edges as u32,
        global_efficiency: res.global_efficiency,
        mean_local_efficiency: res.mean_local_efficiency,
        clustering_coeff: res.clustering_coeff,
        char_path_length: res.char_path_length,
        small_worldness: res.small_worldness,
        modularity_q: res.modularity_q,
        assortativity: res.assortativity,
        nodal,
        sweep,
        exported_csv_path,
        exported_json_path,
    })
}

