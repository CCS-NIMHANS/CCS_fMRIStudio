use anyhow::{bail, Result};
use ndarray::{Array2, ArrayView3, ArrayView4, Axis};
use rayon::prelude::*;
use std::collections::BTreeMap;

/// Extracts mean BOLD timeseries `(T, N_rois)` for every positive integer label in `atlas`.
///
/// Returns `(sorted_roi_ids, timeseries)` where `timeseries` has shape `(n_timepoints, n_rois)`.
pub fn extract_roi_timeseries(
    bold: ArrayView4<'_, f32>,
    atlas: ArrayView3<'_, i32>,
) -> Result<(Vec<i32>, Array2<f64>)> {
    let bshape = bold.shape();
    let ashape = atlas.shape();
    if bshape[0] != ashape[0] || bshape[1] != ashape[1] || bshape[2] != ashape[2] {
        bail!(
            "Spatial shape mismatch: BOLD {:?} vs Atlas {:?}",
            &bshape[..3],
            ashape
        );
    }

    let nx = bshape[0];
    let ny = bshape[1];
    let nz = bshape[2];
    let nt = bshape[3];

    let mut label_coords: BTreeMap<i32, Vec<[usize; 3]>> = BTreeMap::new();
    for z in 0..nz {
        for y in 0..ny {
            for x in 0..nx {
                let lbl = atlas[[x, y, z]];
                if lbl > 0 {
                    label_coords.entry(lbl).or_default().push([x, y, z]);
                }
            }
        }
    }

    if label_coords.is_empty() {
        bail!("Atlas contains no positive parcel labels");
    }

    let roi_ids: Vec<i32> = label_coords.keys().copied().collect();
    let coord_lists: Vec<Vec<[usize; 3]>> = label_coords.into_values().collect();
    let n_rois = roi_ids.len();

    let rows: Vec<Vec<f64>> = (0..nt)
        .into_par_iter()
        .map(|t| {
            let vol = bold.index_axis(Axis(3), t);
            let mut row = vec![0.0_f64; n_rois];
            for (r_idx, coords) in coord_lists.iter().enumerate() {
                let mut sum = 0.0_f64;
                let mut count = 0_usize;
                for &[x, y, z] in coords {
                    let val = vol[[x, y, z]];
                    if val.is_finite() {
                        sum += val as f64;
                        count += 1;
                    }
                }
                row[r_idx] = if count > 0 { sum / (count as f64) } else { 0.0 };
            }
            row
        })
        .collect();

    let mut out = Array2::<f64>::zeros((nt, n_rois));
    for (t, row) in rows.into_iter().enumerate() {
        for (r, val) in row.into_iter().enumerate() {
            out[[t, r]] = val;
        }
    }

    Ok((roi_ids, out))
}
