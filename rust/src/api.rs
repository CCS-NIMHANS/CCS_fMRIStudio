use crate::connectivity::{
    compute_homotopic_and_laterality, compute_nan_safe_graph_metrics, detect_schaefer_hemispheres,
    lesion_network_mapping, static_fc_pearson,
};
use crate::denoise::{compute_acompcor, load_confounds_tsv, simultaneous_denoise};
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
use ndarray::{concatenate, Array2, Array3, Axis};
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
            let v = fc[[i, j]];
            if v.is_finite() {
                abs_sum += v.abs();
                off_diag += 1;
            }
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
    if let Some(conf_path) = confounds_tsv_path {
        let (motion_mat, fd_spikes) = load_confounds_tsv(Path::new(&conf_path), nt, fd_threshold_mm)?;
        if motion_mat.ncols() > 0 {
            confound_blocks.push(motion_mat);
        }
        scrub_indices = fd_spikes;
    }

    if let Some(wm_p) = wm_mask_path {
        let raw_wm = load_mask_u8(Path::new(&wm_p))?;
        let safe_wm = match &lesion_mask {
            Some(lm) => subtract_lesion_from_mask(raw_wm.view(), lm.view(), lesion_dilate_voxels as usize)?,
            None => raw_wm,
        };
        if safe_wm.iter().any(|&v| v > 0) {
            confound_blocks.push(compute_acompcor(vol.view(), safe_wm.view(), 5)?);
        }
    }
    if let Some(csf_p) = csf_mask_path {
        let raw_csf = load_mask_u8(Path::new(&csf_p))?;
        let safe_csf = match &lesion_mask {
            Some(lm) => subtract_lesion_from_mask(raw_csf.view(), lm.view(), lesion_dilate_voxels as usize)?,
            None => raw_csf,
        };
        if safe_csf.iter().any(|&v| v > 0) {
            confound_blocks.push(compute_acompcor(vol.view(), safe_csf.view(), 5)?);
        }
    }

    let combined_conf = if confound_blocks.is_empty() {
        None
    } else {
        let views: Vec<_> = confound_blocks.iter().map(|b| b.view()).collect();
        Some(concatenate(Axis(1), &views)?)
    };

    let low_opt = if low_hz > 0.0 { Some(low_hz) } else { None };
    let high_opt = if high_hz > 0.0 { Some(high_hz) } else { None };
    let clean_ts = simultaneous_denoise(
        parc.timeseries.view(),
        combined_conf.as_ref().map(|c| c.view()),
        tr_sec,
        low_opt,
        high_opt,
        &scrub_indices,
        true,
    )?;

    let fc = static_fc_pearson(clean_ts.view())?;
    let graph = compute_nan_safe_graph_metrics(fc.view(), 0.0, None)?;

    let lesion_summary = lesion_mask.as_ref().map(|lm| {
        summarize_lesion(lm.view(), hdr.voxel_sizes, Some(hdr.affine))
    });
    let dominant_hemi = lesion_summary
        .as_ref()
        .map_or_else(|| "None".to_string(), |s| s.dominant_hemisphere.clone());

    let (mean_homotopic_fc, laterality_index) = if let Some(lbl_path) = atlas_labels_json_path {
        if Path::new(&lbl_path).exists() {
            let text = std::fs::read_to_string(&lbl_path)
                .with_context(|| format!("Failed to read labels JSON {}", lbl_path))?;
            let all_labels: Vec<String> = serde_json::from_str(&text)?;
            let parcel_labels: Vec<String> = parc
                .roi_ids
                .iter()
                .filter_map(|&id| all_labels.get(id as usize).cloned())
                .collect();
            if parcel_labels.len() == n_rois {
                let (lh, rh) = detect_schaefer_hemispheres(&parcel_labels);
                let hl = compute_homotopic_and_laterality(fc.view(), &lh, &rh, &dominant_hemi);
                (hl.mean_homotopic_fc, hl.laterality_index)
            } else {
                (0.0, 0.0)
            }
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
        total_ms: t_total.elapsed().as_secs_f64() * 1000.0,
    })
}
