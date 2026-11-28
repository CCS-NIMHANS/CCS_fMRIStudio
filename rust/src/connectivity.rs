use anyhow::{bail, Result};
use ndarray::{s, Array2, ArrayView2, ArrayView3, ArrayView4, Axis};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::BinaryHeap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphMetrics {
    pub n_intact_nodes: usize,
    pub n_excluded_nodes: usize,
    pub global_efficiency: f64,
    pub mean_node_strength: f64,
    pub modularity_q: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomotopicLateralityMetrics {
    pub n_homotopic_pairs: usize,
    pub mean_homotopic_fc: f64,
    pub mean_intra_lh_fc: f64,
    pub mean_intra_rh_fc: f64,
    pub laterality_index: f64,
}

#[derive(Copy, Clone, PartialEq)]
struct OrdState {
    dist: f64,
    node: usize,
}

impl Eq for OrdState {}

impl Ord for OrdState {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .dist
            .partial_cmp(&self.dist)
            .unwrap_or(Ordering::Equal)
            .then_with(|| self.node.cmp(&other.node))
    }
}

impl PartialOrd for OrdState {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Computes Pearson correlation matrix `(N_rois, N_rois)` across timepoints `(T, N_rois)`.
/// Columns containing `NaN` or non-finite values propagate `NaN` across their row and column.
pub fn static_fc_pearson(ts: ArrayView2<'_, f64>) -> Result<Array2<f64>> {
    let (nt, n_rois) = ts.dim();
    if nt < 2 {
        bail!("Need at least 2 timepoints to compute correlation, got {nt}");
    }
    if n_rois == 0 {
        bail!("Empty ROI matrix");
    }

    let mut z = Array2::<f64>::zeros((nt, n_rois));
    let mut is_nan_roi = vec![false; n_rois];
    let mut is_const_roi = vec![false; n_rois];

    for j in 0..n_rois {
        let col = ts.column(j);
        if !col.iter().all(|v| v.is_finite()) {
            is_nan_roi[j] = true;
            continue;
        }
        let mean = col.sum() / (nt as f64);
        let mut ss = 0.0_f64;
        for i in 0..nt {
            let d = col[i] - mean;
            z[[i, j]] = d;
            ss += d * d;
        }
        let norm = ss.sqrt();
        if norm > 1e-12 {
            for i in 0..nt {
                z[[i, j]] /= norm;
            }
        } else {
            is_const_roi[j] = true;
            for i in 0..nt {
                z[[i, j]] = 0.0;
            }
        }
    }

    let mut corr = z.t().dot(&z);
    for i in 0..n_rois {
        for j in 0..n_rois {
            if is_nan_roi[i] || is_nan_roi[j] {
                corr[[i, j]] = f64::NAN;
            } else if i == j {
                corr[[i, j]] = 1.0;
            } else if is_const_roi[i] || is_const_roi[j] {
                corr[[i, j]] = 0.0;
            } else {
                corr[[i, j]] = corr[[i, j]].clamp(-1.0, 1.0);
            }
        }
    }
    Ok(corr)
}

/// Computes sliding-window dynamic functional connectivity matrices.
pub fn sliding_window_fc(
    ts: ArrayView2<'_, f64>,
    window_len: usize,
    step: usize,
) -> Result<Vec<Array2<f64>>> {
    let nt = ts.nrows();
    if window_len < 3 || window_len > nt {
        bail!("Invalid window_len={window_len} for {nt} timepoints");
    }
    if step == 0 {
        bail!("step must be >= 1");
    }
    let mut windows = Vec::new();
    let mut start = 0;
    while start + window_len <= nt {
        let slice = ts.slice(s![start..start + window_len, ..]);
        windows.push(static_fc_pearson(slice)?);
        start += step;
    }
    Ok(windows)
}

/// Computes graph metrics over an adjacency matrix containing `NaN` excluded nodes
/// by restricting computation to the intact node subgraph.
pub fn compute_nan_safe_graph_metrics(
    fc: ArrayView2<'_, f64>,
    edge_threshold: f64,
    community_labels: Option<&[usize]>,
) -> Result<GraphMetrics> {
    let (n, m) = fc.dim();
    if n != m || n == 0 {
        bail!("Expected non-empty square FC matrix, got ({n}, {m})");
    }
    if let Some(labels) = community_labels {
        if labels.len() != n {
            bail!(
                "community_labels length ({}) != FC dimension ({n})",
                labels.len()
            );
        }
    }

    let intact_nodes: Vec<usize> = (0..n).filter(|&i| fc[[i, i]].is_finite()).collect();
    let n_intact = intact_nodes.len();
    let n_excluded = n - n_intact;
    if n_intact < 2 {
        return Ok(GraphMetrics {
            n_intact_nodes: n_intact,
            n_excluded_nodes: n_excluded,
            global_efficiency: 0.0,
            mean_node_strength: 0.0,
            modularity_q: None,
        });
    }

    let mut adj = vec![Vec::<(usize, f64)>::new(); n_intact];
    let mut strengths = vec![0.0_f64; n_intact];
    let mut total_w2 = 0.0_f64;

    for ui in 0..n_intact {
        let u = intact_nodes[ui];
        for vi in (ui + 1)..n_intact {
            let v = intact_nodes[vi];
            let w = fc[[u, v]];
            if w.is_finite() && w > edge_threshold {
                adj[ui].push((vi, w));
                adj[vi].push((ui, w));
                strengths[ui] += w;
                strengths[vi] += w;
                total_w2 += 2.0 * w;
            }
        }
    }

    let mean_node_strength = strengths.iter().sum::<f64>() / (n_intact as f64);

    // Weighted global efficiency via all-pairs Dijkstra with length = 1 / w.
    let mut eff_sum = 0.0_f64;
    for src in 0..n_intact {
        let mut dist = vec![f64::INFINITY; n_intact];
        let mut heap = BinaryHeap::new();
        dist[src] = 0.0;
        heap.push(OrdState {
            dist: 0.0,
            node: src,
        });

        while let Some(OrdState { dist: d, node: u }) = heap.pop() {
            if d > dist[u] {
                continue;
            }
            for &(v, w) in &adj[u] {
                let nd = d + (1.0 / w);
                if nd < dist[v] {
                    dist[v] = nd;
                    heap.push(OrdState { dist: nd, node: v });
                }
            }
        }

        for (dst, &d) in dist.iter().enumerate() {
            if dst != src && d.is_finite() && d > 0.0 {
                eff_sum += 1.0 / d;
            }
        }
    }
    let global_efficiency = eff_sum / ((n_intact * (n_intact - 1)) as f64);

    let modularity_q = if let Some(labels) = community_labels {
        if total_w2 > 1e-12 {
            // Newman weighted modularity for a fixed partition; null term over all
            // same-community pairs (not only connected ones).
            let n_comm = labels.iter().copied().max().map_or(0, |m| m + 1);
            let mut w_in = vec![0.0_f64; n_comm];
            let mut s_c = vec![0.0_f64; n_comm];
            for ui in 0..n_intact {
                let cu = labels[intact_nodes[ui]];
                s_c[cu] += strengths[ui];
                for &(vi, w) in &adj[ui] {
                    if labels[intact_nodes[vi]] == cu {
                        w_in[cu] += w;
                    }
                }
            }
            Some(
                (0..n_comm)
                    .map(|c| w_in[c] - s_c[c] * s_c[c] / total_w2)
                    .sum::<f64>()
                    / total_w2,
            )
        } else {
            Some(0.0)
        }
    } else {
        None
    };

    Ok(GraphMetrics {
        n_intact_nodes: n_intact,
        n_excluded_nodes: n_excluded,
        global_efficiency,
        mean_node_strength,
        modularity_q,
    })
}

/// Computes Lesion Network Mapping: Pearson correlation between the mean lesion-seed BOLD
/// timeseries and each ROI timeseries (`NaN` for excluded/constant ROIs).
pub fn lesion_network_mapping(
    bold: ArrayView4<'_, f32>,
    lesion_mask: ArrayView3<'_, u8>,
    roi_ts: ArrayView2<'_, f64>,
) -> Result<Vec<f64>> {
    let bshape = bold.shape();
    if lesion_mask.shape() != &bshape[..3] {
        bail!(
            "Lesion mask shape {:?} != BOLD spatial shape {:?}",
            lesion_mask.shape(),
            &bshape[..3]
        );
    }
    let nt = bshape[3];
    if roi_ts.nrows() != nt {
        bail!(
            "ROI timeseries rows ({}) != BOLD timepoints ({nt})",
            roi_ts.nrows()
        );
    }

    let mut coords = Vec::new();
    for z in 0..bshape[2] {
        for y in 0..bshape[1] {
            for x in 0..bshape[0] {
                if lesion_mask[[x, y, z]] > 0 {
                    coords.push([x, y, z]);
                }
            }
        }
    }
    if coords.is_empty() {
        return Ok(vec![f64::NAN; roi_ts.ncols()]);
    }

    let mut seed = vec![0.0_f64; nt];
    for t in 0..nt {
        let vol = bold.index_axis(Axis(3), t);
        let mut sum = 0.0_f64;
        let mut count = 0_usize;
        for &[x, y, z] in &coords {
            let v = vol[[x, y, z]];
            if v.is_finite() {
                sum += v as f64;
                count += 1;
            }
        }
        seed[t] = if count > 0 { sum / (count as f64) } else { 0.0 };
    }

    let seed_mean = seed.iter().sum::<f64>() / (nt as f64);
    let mut seed_ss = 0.0_f64;
    for v in &mut seed {
        *v -= seed_mean;
        seed_ss += *v * *v;
    }
    let seed_norm = seed_ss.sqrt();
    if seed_norm <= 1e-12 {
        return Ok(vec![f64::NAN; roi_ts.ncols()]);
    }

    let mut out = Vec::with_capacity(roi_ts.ncols());
    for c in 0..roi_ts.ncols() {
        let col = roi_ts.column(c);
        if !col.iter().all(|v| v.is_finite()) {
            out.push(f64::NAN);
            continue;
        }
        let m = col.sum() / (nt as f64);
        let mut ss = 0.0_f64;
        let mut dot = 0.0_f64;
        for t in 0..nt {
            let d = col[t] - m;
            ss += d * d;
            dot += d * seed[t];
        }
        let norm = ss.sqrt();
        if norm > 1e-12 {
            out.push((dot / (norm * seed_norm)).clamp(-1.0, 1.0));
        } else {
            out.push(0.0);
        }
    }

    Ok(out)
}

/// Pairs LH and RH Schaefer-style labels by stripping `_LH_` / `_RH_` hemisphere markers.
pub fn detect_schaefer_hemispheres(labels: &[String]) -> (Vec<usize>, Vec<usize>) {
    let mut lh_all = Vec::new();
    let mut rh_map = std::collections::HashMap::new();
    for (idx, lbl) in labels.iter().enumerate() {
        if lbl.contains("_RH_") {
            rh_map.insert(lbl.replace("_RH_", "_HEMI_"), idx);
        } else if lbl.contains("_LH_") {
            lh_all.push((lbl.replace("_LH_", "_HEMI_"), idx));
        }
    }
    let mut lh_paired = Vec::new();
    let mut rh_paired = Vec::new();
    for (key, l_idx) in lh_all {
        if let Some(&r_idx) = rh_map.get(&key) {
            lh_paired.push(l_idx);
            rh_paired.push(r_idx);
        }
    }
    (lh_paired, rh_paired)
}

fn mean_intra_fc(fc: ArrayView2<'_, f64>, indices: &[usize]) -> f64 {
    let mut sum = 0.0_f64;
    let mut count = 0_usize;
    for a in 0..indices.len() {
        for b in (a + 1)..indices.len() {
            let v = fc[[indices[a], indices[b]]];
            if v.is_finite() {
                sum += v;
                count += 1;
            }
        }
    }
    if count > 0 { sum / (count as f64) } else { 0.0 }
}

/// Computes homotopic inter-hemispheric connectivity and lesioned vs. intact laterality index.
pub fn compute_homotopic_and_laterality(
    fc: ArrayView2<'_, f64>,
    lh_indices: &[usize],
    rh_indices: &[usize],
    lesioned_hemisphere: &str,
) -> HomotopicLateralityMetrics {
    let mut h_sum = 0.0_f64;
    let mut h_count = 0_usize;
    for (&l, &r) in lh_indices.iter().zip(rh_indices.iter()) {
        if l < fc.nrows() && r < fc.ncols() {
            let v = fc[[l, r]];
            if v.is_finite() {
                h_sum += v;
                h_count += 1;
            }
        }
    }
    let mean_homotopic_fc = if h_count > 0 { h_sum / (h_count as f64) } else { 0.0 };
    let mean_intra_lh_fc = mean_intra_fc(fc, lh_indices);
    let mean_intra_rh_fc = mean_intra_fc(fc, rh_indices);

    let laterality_index = match lesioned_hemisphere {
        "Left" => {
            let denom = mean_intra_rh_fc.abs() + mean_intra_lh_fc.abs();
            if denom > 1e-12 { (mean_intra_rh_fc - mean_intra_lh_fc) / denom } else { 0.0 }
        }
        "Right" => {
            let denom = mean_intra_lh_fc.abs() + mean_intra_rh_fc.abs();
            if denom > 1e-12 { (mean_intra_lh_fc - mean_intra_rh_fc) / denom } else { 0.0 }
        }
        _ => 0.0,
    };

    HomotopicLateralityMetrics {
        n_homotopic_pairs: h_count,
        mean_homotopic_fc,
        mean_intra_lh_fc,
        mean_intra_rh_fc,
        laterality_index,
    }
}
