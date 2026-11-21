use crate::nifti_io::{OrthoPlane, RenderedSlice};
use anyhow::{bail, Context, Result};
use ndarray::{Array3, ArrayView3, ArrayView4, Axis};
use nifti::writer::WriterOptions;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LesionSummary {
    pub voxel_count: usize,
    pub volume_ml: f64,
    pub left_voxels: usize,
    pub right_voxels: usize,
    pub dominant_hemisphere: String,
}

fn is_left_hemisphere(
    x: usize,
    y: usize,
    z: usize,
    nx: usize,
    affine: Option<[[f32; 4]; 4]>,
) -> bool {
    if let Some(a) = affine {
        let wx = a[0][0] * (x as f32) + a[0][1] * (y as f32) + a[0][2] * (z as f32) + a[0][3];
        wx < 0.0
    } else {
        x < nx / 2
    }
}

pub fn summarize_lesion(
    mask: ArrayView3<'_, u8>,
    voxel_sizes: [f32; 3],
    affine: Option<[[f32; 4]; 4]>,
) -> LesionSummary {
    let shape = mask.shape();
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    let mut voxel_count = 0_usize;
    let mut left_voxels = 0_usize;
    let mut right_voxels = 0_usize;

    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                if mask[[x, y, z]] > 0 {
                    voxel_count += 1;
                    if is_left_hemisphere(x, y, z, nx, affine) {
                        left_voxels += 1;
                    } else {
                        right_voxels += 1;
                    }
                }
            }
        }
    }

    let voxel_vol_mm3 =
        (voxel_sizes[0].abs() * voxel_sizes[1].abs() * voxel_sizes[2].abs()).max(1e-6) as f64;
    let volume_ml = (voxel_count as f64) * voxel_vol_mm3 / 1000.0;

    let dominant_hemisphere = if voxel_count == 0 {
        "None".to_string()
    } else {
        let left_frac = (left_voxels as f64) / (voxel_count as f64);
        if left_frac > 0.75 {
            "Left".to_string()
        } else if left_frac < 0.25 {
            "Right".to_string()
        } else {
            "Bilateral".to_string()
        }
    };

    LesionSummary {
        voxel_count,
        volume_ml,
        left_voxels,
        right_voxels,
        dominant_hemisphere,
    }
}

fn robust_median_mad(values: &mut [f32]) -> (f32, f32) {
    if values.is_empty() {
        return (0.0, 1.0);
    }
    values.sort_by(|a, b| a.total_cmp(b));
    let med = values[values.len() / 2];
    let mut devs: Vec<f32> = values.iter().map(|v| (v - med).abs()).collect();
    devs.sort_by(|a, b| a.total_cmp(b));
    let mad = (devs[devs.len() / 2] * 1.4826).max(1e-5);
    (med, mad)
}

/// Computes an asymmetry z-score map (`contra - ipsi` on T1w + optional `ipsi - contra` on FLAIR)
/// and produces an initial binary lesion mask thresholded at `z >= z_threshold` (with island cleanup).
pub fn compute_hemispheric_asymmetry(
    t1: ArrayView3<'_, f32>,
    flair: Option<ArrayView3<'_, f32>>,
    voxel_sizes: [f32; 3],
    affine: Option<[[f32; 4]; 4]>,
    z_threshold: f32,
) -> Result<(Array3<f32>, Array3<u8>, LesionSummary)> {
    let shape = t1.shape();
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    if nx < 4 || ny < 2 || nz < 2 {
        bail!("Volume too small for hemispheric asymmetry: {:?}", shape);
    }
    if let Some(fl) = flair {
        if fl.shape() != shape {
            bail!("FLAIR shape {:?} does not match T1w shape {:?}", fl.shape(), shape);
        }
    }

    let mut t1_diffs = Vec::new();
    let mut fg_mask = Array3::<u8>::zeros((nx, ny, nz));
    let mut raw_t1_score = Array3::<f32>::zeros((nx, ny, nz));

    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                let mx = nx - 1 - x;
                let ipsi = t1[[x, y, z]];
                let contra = t1[[mx, y, z]];
                if ipsi.is_finite() && contra.is_finite() && ipsi > 0.0 && contra > 0.0 {
                    let diff = contra - ipsi; // positive when ipsi is hypointense (stroke cavity)
                    raw_t1_score[[x, y, z]] = diff;
                    fg_mask[[x, y, z]] = 1;
                    t1_diffs.push(diff);
                }
            }
        }
    }
    let (t1_med, t1_mad) = robust_median_mad(&mut t1_diffs);

    let mut raw_flair_score = Array3::<f32>::zeros((nx, ny, nz));
    let mut has_flair = false;
    let (mut fl_med, mut fl_mad) = (0.0_f32, 1.0_f32);
    if let Some(fl) = flair {
        let mut fl_diffs = Vec::new();
        for z in 0..nz {
            for y in 0..ny {
                for x in 0..nx {
                    if fg_mask[[x, y, z]] > 0 {
                        let mx = nx - 1 - x;
                        let ipsi = fl[[x, y, z]];
                        let contra = fl[[mx, y, z]];
                        if ipsi.is_finite() && contra.is_finite() {
                            let diff = ipsi - contra; // positive when ipsi FLAIR is hyperintense
                            raw_flair_score[[x, y, z]] = diff;
                            fl_diffs.push(diff);
                        }
                    }
                }
            }
        }
        (fl_med, fl_mad) = robust_median_mad(&mut fl_diffs);
        has_flair = !fl_diffs.is_empty();
    }

    let mut z_map = Array3::<f32>::zeros((nx, ny, nz));
    let mut binary = Array3::<u8>::zeros((nx, ny, nz));
    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                if fg_mask[[x, y, z]] > 0 {
                    let z_t1 = (raw_t1_score[[x, y, z]] - t1_med) / t1_mad;
                    let score = if has_flair {
                        let z_fl = (raw_flair_score[[x, y, z]] - fl_med) / fl_mad;
                        0.5 * (z_t1 + z_fl)
                    } else {
                        z_t1
                    };
                    z_map[[x, y, z]] = score;
                    if score >= z_threshold {
                        binary[[x, y, z]] = 1;
                    }
                }
            }
        }
    }

    let cleaned = remove_small_islands_3d(binary.view(), 10);
    let summary = summarize_lesion(cleaned.view(), voxel_sizes, affine);
    Ok((z_map, cleaned, summary))
}

/// 6-connected 3D region-growing "Magic Wand" from `seed` within `|val - seed_val| <= tolerance`.
pub fn magic_wand_3d(
    vol: ArrayView3<'_, f32>,
    mask: &mut Array3<u8>,
    seed: [usize; 3],
    tolerance: f32,
) -> Result<usize> {
    let shape = vol.shape();
    if mask.shape() != shape {
        bail!("Mask shape {:?} does not match volume shape {:?}", mask.shape(), shape);
    }
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    let [sx, sy, sz] = seed;
    if sx >= nx || sy >= ny || sz >= nz {
        bail!("Seed {:?} out of bounds {:?}", seed, shape);
    }
    let seed_val = vol[[sx, sy, sz]];
    if !seed_val.is_finite() {
        bail!("Seed voxel intensity is non-finite");
    }

    let tol = tolerance.abs();
    let mut visited = Array3::<u8>::zeros((nx, ny, nz));
    let mut queue = VecDeque::new();
    visited[[sx, sy, sz]] = 1;
    queue.push_back([sx, sy, sz]);

    let mut added = 0_usize;
    while let Some([x, y, z]) = queue.pop_front() {
        let v = vol[[x, y, z]];
        if !v.is_finite() || (v - seed_val).abs() > tol {
            continue;
        }
        if mask[[x, y, z]] == 0 {
            mask[[x, y, z]] = 1;
            added += 1;
        }

        let neighbors = [
            (x.checked_sub(1), Some(y), Some(z)),
            (if x + 1 < nx { Some(x + 1) } else { None }, Some(y), Some(z)),
            (Some(x), y.checked_sub(1), Some(z)),
            (Some(x), if y + 1 < ny { Some(y + 1) } else { None }, Some(z)),
            (Some(x), Some(y), z.checked_sub(1)),
            (Some(x), Some(y), if z + 1 < nz { Some(z + 1) } else { None }),
        ];
        for (ox, oy, oz) in neighbors {
            if let (Some(nx_i), Some(ny_i), Some(nz_i)) = (ox, oy, oz) {
                if visited[[nx_i, ny_i, nz_i]] == 0 {
                    visited[[nx_i, ny_i, nz_i]] = 1;
                    queue.push_back([nx_i, ny_i, nz_i]);
                }
            }
        }
    }

    Ok(added)
}

/// Applies a 3D spherical (or 2D in-plane if `slice_plane_only` is `Some`) paint/erase brush.
pub fn apply_spherical_brush(
    mask: &mut Array3<u8>,
    center: [usize; 3],
    radius_voxels: f32,
    erase: bool,
    slice_plane_only: Option<OrthoPlane>,
) -> Result<usize> {
    let shape = mask.shape();
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    let [cx, cy, cz] = center;
    if cx >= nx || cy >= ny || cz >= nz {
        bail!("Brush center {:?} out of bounds {:?}", center, shape);
    }

    let r = radius_voxels.max(0.0);
    let r_ceil = r.ceil() as isize;
    let r_sq = r * r;
    let target = if erase { 0_u8 } else { 1_u8 };
    let mut modified = 0_usize;

    let (dx_range, dy_range, dz_range) = match slice_plane_only {
        Some(OrthoPlane::Axial) => (-r_ceil..=r_ceil, -r_ceil..=r_ceil, 0..=0),
        Some(OrthoPlane::Coronal) => (-r_ceil..=r_ceil, 0..=0, -r_ceil..=r_ceil),
        Some(OrthoPlane::Sagittal) => (0..=0, -r_ceil..=r_ceil, -r_ceil..=r_ceil),
        None => (-r_ceil..=r_ceil, -r_ceil..=r_ceil, -r_ceil..=r_ceil),
    };

    for dz in dz_range {
        let z = cz as isize + dz;
        if z < 0 || z >= nz as isize {
            continue;
        }
        for dy in dy_range.clone() {
            let y = cy as isize + dy;
            if y < 0 || y >= ny as isize {
                continue;
            }
            for dx in dx_range.clone() {
                let x = cx as isize + dx;
                if x < 0 || x >= nx as isize {
                    continue;
                }
                let dist_sq = (dx * dx + dy * dy + dz * dz) as f32;
                if dist_sq <= r_sq {
                    let (ux, uy, uz) = (x as usize, y as usize, z as usize);
                    if mask[[ux, uy, uz]] != target {
                        mask[[ux, uy, uz]] = target;
                        modified += 1;
                    }
                }
            }
        }
    }

    Ok(modified)
}

/// Fills interior holes inside a 3D binary mask via exterior 6-connected flood-fill.
pub fn fill_holes_3d(mask: ArrayView3<'_, u8>) -> Array3<u8> {
    let shape = mask.shape();
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    let mut exterior = Array3::<u8>::zeros((nx, ny, nz));
    let mut queue = VecDeque::new();

    let mut try_seed = |x: usize, y: usize, z: usize| {
        if mask[[x, y, z]] == 0 && exterior[[x, y, z]] == 0 {
            exterior[[x, y, z]] = 1;
            queue.push_back([x, y, z]);
        }
    };

    for z in 0..nz {
        for y in 0..ny {
            try_seed(0, y, z);
            try_seed(nx - 1, y, z);
        }
        for x in 0..nx {
            try_seed(x, 0, z);
            try_seed(x, ny - 1, z);
        }
    }
    for y in 0..ny {
        for x in 0..nx {
            try_seed(x, y, 0);
            try_seed(x, y, nz - 1);
        }
    }

    while let Some([x, y, z]) = queue.pop_front() {
        let neighbors = [
            (x.checked_sub(1), Some(y), Some(z)),
            (if x + 1 < nx { Some(x + 1) } else { None }, Some(y), Some(z)),
            (Some(x), y.checked_sub(1), Some(z)),
            (Some(x), if y + 1 < ny { Some(y + 1) } else { None }, Some(z)),
            (Some(x), Some(y), z.checked_sub(1)),
            (Some(x), Some(y), if z + 1 < nz { Some(z + 1) } else { None }),
        ];
        for (ox, oy, oz) in neighbors {
            if let (Some(nx_i), Some(ny_i), Some(nz_i)) = (ox, oy, oz) {
                if mask[[nx_i, ny_i, nz_i]] == 0 && exterior[[nx_i, ny_i, nz_i]] == 0 {
                    exterior[[nx_i, ny_i, nz_i]] = 1;
                    queue.push_back([nx_i, ny_i, nz_i]);
                }
            }
        }
    }

    let mut out = Array3::<u8>::zeros((nx, ny, nz));
    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                out[[x, y, z]] = if exterior[[x, y, z]] == 0 { 1 } else { 0 };
            }
        }
    }
    out
}

/// Removes 6-connected foreground islands smaller than `min_voxels`.
pub fn remove_small_islands_3d(mask: ArrayView3<'_, u8>, min_voxels: usize) -> Array3<u8> {
    let shape = mask.shape();
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    let mut visited = Array3::<u8>::zeros((nx, ny, nz));
    let mut out = Array3::<u8>::zeros((nx, ny, nz));
    let mut queue = VecDeque::new();

    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                if mask[[x, y, z]] == 0 || visited[[x, y, z]] > 0 {
                    continue;
                }
                let mut component = Vec::new();
                visited[[x, y, z]] = 1;
                queue.push_back([x, y, z]);
                while let Some([cx, cy, cz]) = queue.pop_front() {
                    component.push([cx, cy, cz]);
                    let neighbors = [
                        (cx.checked_sub(1), Some(cy), Some(cz)),
                        (if cx + 1 < nx { Some(cx + 1) } else { None }, Some(cy), Some(cz)),
                        (Some(cx), cy.checked_sub(1), Some(cz)),
                        (Some(cx), if cy + 1 < ny { Some(cy + 1) } else { None }, Some(cz)),
                        (Some(cx), Some(cy), cz.checked_sub(1)),
                        (Some(cx), Some(cy), if cz + 1 < nz { Some(cz + 1) } else { None }),
                    ];
                    for (ox, oy, oz) in neighbors {
                        if let (Some(nx_i), Some(ny_i), Some(nz_i)) = (ox, oy, oz) {
                            if mask[[nx_i, ny_i, nz_i]] > 0 && visited[[nx_i, ny_i, nz_i]] == 0 {
                                visited[[nx_i, ny_i, nz_i]] = 1;
                                queue.push_back([nx_i, ny_i, nz_i]);
                            }
                        }
                    }
                }
                if component.len() >= min_voxels {
                    for [vx, vy, vz] in component {
                        out[[vx, vy, vz]] = 1;
                    }
                }
            }
        }
    }

    out
}

/// Applies 3D spherical binary dilation with radius in voxels.
pub fn dilate_mask_3d(mask: ArrayView3<'_, u8>, radius_voxels: usize) -> Array3<u8> {
    if radius_voxels == 0 {
        return mask.to_owned();
    }
    let shape = mask.shape();
    let (nx, ny, nz) = (shape[0], shape[1], shape[2]);
    let r = radius_voxels as isize;
    let r_sq = r * r;
    let mut offsets = Vec::new();
    for dz in -r..=r {
        for dy in -r..=r {
            for dx in -r..=r {
                if dx * dx + dy * dy + dz * dz <= r_sq {
                    offsets.push([dx, dy, dz]);
                }
            }
        }
    }

    let mut out = mask.to_owned();
    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                if mask[[x, y, z]] > 0 {
                    for &[dx, dy, dz] in &offsets {
                        let px = x as isize + dx;
                        let py = y as isize + dy;
                        let pz = z as isize + dz;
                        if px >= 0
                            && px < nx as isize
                            && py >= 0
                            && py < ny as isize
                            && pz >= 0
                            && pz < nz as isize
                        {
                            out[[px as usize, py as usize, pz as usize]] = 1;
                        }
                    }
                }
            }
        }
    }
    out
}

/// Subtracts the (optionally dilated) lesion mask from a tissue mask (WM/CSF) to protect aCompCor.
pub fn subtract_lesion_from_mask(
    tissue_mask: ArrayView3<'_, u8>,
    lesion_mask: ArrayView3<'_, u8>,
    dilate_radius: usize,
) -> Result<Array3<u8>> {
    if tissue_mask.shape() != lesion_mask.shape() {
        bail!(
            "Mask shape mismatch: tissue {:?} vs lesion {:?}",
            tissue_mask.shape(),
            lesion_mask.shape()
        );
    }
    let dilated = dilate_mask_3d(lesion_mask, dilate_radius);
    let shape = tissue_mask.shape();
    let mut out = tissue_mask.to_owned();
    for z in 0..shape[2] {
        for y in 0..shape[1] {
            for x in 0..shape[0] {
                if dilated[[x, y, z]] > 0 {
                    out[[x, y, z]] = 0;
                }
            }
        }
    }
    Ok(out)
}

/// Renders an orthogonal slice with an optional semi-transparent red (`#EF4444`) lesion overlay.
pub fn render_ortho_slice_with_lesion_rgba(
    vol: ArrayView4<'_, f32>,
    lesion: Option<ArrayView3<'_, u8>>,
    plane: OrthoPlane,
    slice_idx: usize,
    timepoint: usize,
    overlay_alpha: f32,
) -> Result<RenderedSlice> {
    let shape = vol.shape();
    let (nx, ny, nz, nt) = (shape[0], shape[1], shape[2], shape[3]);
    if timepoint >= nt {
        bail!("timepoint {timepoint} out of range (0..{nt})");
    }
    if let Some(lm) = lesion {
        if lm.shape() != &shape[..3] {
            bail!(
                "Lesion mask shape {:?} does not match volume spatial shape {:?}",
                lm.shape(),
                &shape[..3]
            );
        }
    }

    let vol3 = vol.index_axis(Axis(3), timepoint);
    let (width, height, values, mask_vals): (usize, usize, Vec<f32>, Vec<u8>) = match plane {
        OrthoPlane::Axial => {
            if slice_idx >= nz {
                bail!("axial slice {slice_idx} out of range (0..{nz})");
            }
            let mut vals = Vec::with_capacity(nx * ny);
            let mut mvals = Vec::with_capacity(nx * ny);
            for y in (0..ny).rev() {
                for x in 0..nx {
                    vals.push(vol3[[x, y, slice_idx]]);
                    mvals.push(lesion.map_or(0, |m| m[[x, y, slice_idx]]));
                }
            }
            (nx, ny, vals, mvals)
        }
        OrthoPlane::Coronal => {
            if slice_idx >= ny {
                bail!("coronal slice {slice_idx} out of range (0..{ny})");
            }
            let mut vals = Vec::with_capacity(nx * nz);
            let mut mvals = Vec::with_capacity(nx * nz);
            for z in (0..nz).rev() {
                for x in 0..nx {
                    vals.push(vol3[[x, slice_idx, z]]);
                    mvals.push(lesion.map_or(0, |m| m[[x, slice_idx, z]]));
                }
            }
            (nx, nz, vals, mvals)
        }
        OrthoPlane::Sagittal => {
            if slice_idx >= nx {
                bail!("sagittal slice {slice_idx} out of range (0..{nx})");
            }
            let mut vals = Vec::with_capacity(ny * nz);
            let mut mvals = Vec::with_capacity(ny * nz);
            for z in (0..nz).rev() {
                for y in 0..ny {
                    vals.push(vol3[[slice_idx, y, z]]);
                    mvals.push(lesion.map_or(0, |m| m[[slice_idx, y, z]]));
                }
            }
            (ny, nz, vals, mvals)
        }
    };

    let mut finite_pos: Vec<f32> = values
        .iter()
        .copied()
        .filter(|v| v.is_finite() && *v > 0.0)
        .collect();
    if finite_pos.is_empty() {
        finite_pos = values.iter().copied().filter(|v| v.is_finite()).collect();
    }
    let (p_low, p_high) = if finite_pos.is_empty() {
        (0.0_f32, 1.0_f32)
    } else {
        finite_pos.sort_by(|a, b| a.total_cmp(b));
        let lo_idx = ((finite_pos.len() - 1) as f64 * 0.02).round() as usize;
        let hi_idx = ((finite_pos.len() - 1) as f64 * 0.98).round() as usize;
        let lo = finite_pos[lo_idx];
        let hi = finite_pos[hi_idx];
        if (hi - lo).abs() < 1e-8 {
            (lo, lo + 1.0)
        } else {
            (lo, hi)
        }
    };

    let alpha = overlay_alpha.clamp(0.0, 1.0);
    let scale = 255.0 / (p_high - p_low);
    let mut rgba = Vec::with_capacity(width * height * 4);
    for (idx, v) in values.into_iter().enumerate() {
        let base = if v.is_finite() {
            ((v - p_low) * scale).clamp(0.0, 255.0)
        } else {
            0.0
        };
        if mask_vals[idx] > 0 && alpha > 0.0 {
            let r = (base * (1.0 - alpha) + 239.0 * alpha).clamp(0.0, 255.0).round() as u8;
            let g = (base * (1.0 - alpha) + 68.0 * alpha).clamp(0.0, 255.0).round() as u8;
            let b = (base * (1.0 - alpha) + 68.0 * alpha).clamp(0.0, 255.0).round() as u8;
            rgba.extend_from_slice(&[r, g, b, 255]);
        } else {
            let g = base.round() as u8;
            rgba.extend_from_slice(&[g, g, g, 255]);
        }
    }

    Ok(RenderedSlice {
        width,
        height,
        rgba,
        min_val: p_low,
        max_val: p_high,
    })
}

/// Saves a binary `u8` 3D lesion mask using spatial header metadata from `ref_nifti_path`.
pub fn save_mask_u8_nifti(
    mask: ArrayView3<'_, u8>,
    ref_nifti_path: &Path,
    out_path: &Path,
) -> Result<()> {
    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    WriterOptions::new(out_path)
        .reference_file(&ref_nifti_path)
        .write_nifti(&mask)
        .with_context(|| format!("Failed to write mask NIfTI to {}", out_path.display()))?;
    Ok(())
}
