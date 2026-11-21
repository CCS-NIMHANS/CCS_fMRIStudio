use anyhow::{bail, Result};
use ndarray::{Array2, ArrayView3, ArrayView4, Axis};
use rayon::prelude::*;
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct LesionParcellationResult {
    pub roi_ids: Vec<i32>,
    pub timeseries: Array2<f64>,
    pub percent_damage: Vec<f64>,
    pub surviving_voxels: Vec<usize>,
    pub excluded_mask: Vec<bool>,
    pub total_lesion_volume_ml: f64,
}

/// Extracts mean BOLD timeseries `(T, N_rois)` for every positive integer label in `atlas`.
pub fn extract_roi_timeseries(
    bold: ArrayView4<'_, f32>,
    atlas: ArrayView3<'_, i32>,
) -> Result<(Vec<i32>, Array2<f64>)> {
    let res = extract_roi_timeseries_lesion_aware(bold, atlas, None, [1.0, 1.0, 1.0], 100.0)?;
    Ok((res.roi_ids, res.timeseries))
}

/// Extracts mean BOLD timeseries excluding voxels inside `lesion_mask` and flagging any ROI
/// with `percent_damage > max_damage_pct` (or zero surviving voxels) as `NaN`.
pub fn extract_roi_timeseries_lesion_aware(
    bold: ArrayView4<'_, f32>,
    atlas: ArrayView3<'_, i32>,
    lesion_mask: Option<ArrayView3<'_, u8>>,
    voxel_sizes: [f32; 3],
    max_damage_pct: f64,
) -> Result<LesionParcellationResult> {
    let bshape = bold.shape();
    let ashape = atlas.shape();
    if bshape[0] != ashape[0] || bshape[1] != ashape[1] || bshape[2] != ashape[2] {
        bail!(
            "Spatial shape mismatch: BOLD {:?} vs Atlas {:?}",
            &bshape[..3],
            ashape
        );
    }
    if let Some(lm) = lesion_mask {
        if lm.shape() != ashape {
            bail!(
                "Spatial shape mismatch: LesionMask {:?} vs Atlas {:?}",
                lm.shape(),
                ashape
            );
        }
    }

    let (nx, ny, nz, nt) = (bshape[0], bshape[1], bshape[2], bshape[3]);
    let mut total_counts: BTreeMap<i32, usize> = BTreeMap::new();
    let mut surviving_coords: BTreeMap<i32, Vec<[usize; 3]>> = BTreeMap::new();
    let mut lesion_voxels = 0_usize;

    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                let damaged = lesion_mask.is_some_and(|lm| lm[[x, y, z]] > 0);
                if damaged {
                    lesion_voxels += 1;
                }
                let lbl = atlas[[x, y, z]];
                if lbl > 0 {
                    *total_counts.entry(lbl).or_insert(0) += 1;
                    let coords = surviving_coords.entry(lbl).or_default();
                    if !damaged {
                        coords.push([x, y, z]);
                    }
                }
            }
        }
    }

    if total_counts.is_empty() {
        bail!("Atlas contains no positive parcel labels");
    }

    let roi_ids: Vec<i32> = total_counts.keys().copied().collect();
    let n_rois = roi_ids.len();
    let mut percent_damage = Vec::with_capacity(n_rois);
    let mut surviving_voxels = Vec::with_capacity(n_rois);
    let mut excluded_mask = Vec::with_capacity(n_rois);
    let mut coord_lists = Vec::with_capacity(n_rois);

    for &id in &roi_ids {
        let tot = total_counts[&id];
        let coords = surviving_coords.remove(&id).unwrap_or_default();
        let surv = coords.len();
        let dmg = 100.0 * ((tot - surv) as f64) / (tot as f64);
        let excluded = surv == 0 || dmg > max_damage_pct;
        percent_damage.push(dmg);
        surviving_voxels.push(surv);
        excluded_mask.push(excluded);
        coord_lists.push(if excluded { Vec::new() } else { coords });
    }

    let rows: Vec<Vec<f64>> = (0..nt)
        .into_par_iter()
        .map(|t| {
            let vol = bold.index_axis(Axis(3), t);
            let mut row = vec![f64::NAN; n_rois];
            for (r_idx, coords) in coord_lists.iter().enumerate() {
                if excluded_mask[r_idx] {
                    continue;
                }
                let mut sum = 0.0_f64;
                let mut count = 0_usize;
                for &[x, y, z] in coords {
                    let val = vol[[x, y, z]];
                    if val.is_finite() {
                        sum += val as f64;
                        count += 1;
                    }
                }
                row[r_idx] = if count > 0 { sum / (count as f64) } else { f64::NAN };
            }
            row
        })
        .collect();

    let mut out = Array2::<f64>::from_elem((nt, n_rois), f64::NAN);
    for (t, row) in rows.into_iter().enumerate() {
        for (r, val) in row.into_iter().enumerate() {
            out[[t, r]] = val;
        }
    }

    let voxel_vol_mm3 =
        (voxel_sizes[0].abs() * voxel_sizes[1].abs() * voxel_sizes[2].abs()).max(1e-6) as f64;
    let total_lesion_volume_ml = (lesion_voxels as f64) * voxel_vol_mm3 / 1000.0;

    Ok(LesionParcellationResult {
        roi_ids,
        timeseries: out,
        percent_damage,
        surviving_voxels,
        excluded_mask,
        total_lesion_volume_ml,
    })
}
