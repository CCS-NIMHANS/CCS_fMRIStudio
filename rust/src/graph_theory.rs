use anyhow::{bail, Result};
use ndarray::ArrayView2;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BinaryHeap};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodalGraphMetric {
    pub roi_index: usize,
    pub degree: usize,
    pub strength: f64,
    pub clustering: f64,
    pub local_efficiency: f64,
    pub betweenness: f64,
    pub participation_coeff: f64,
    pub within_module_z: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DensitySweepPoint {
    pub density: f64,
    pub global_efficiency: f64,
    pub clustering_coeff: f64,
    pub small_worldness: f64,
    pub modularity_q: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphTheoryResult {
    pub n_intact_nodes: usize,
    pub n_excluded_nodes: usize,
    pub n_edges: usize,
    pub density: f64,
    pub weighted: bool,
    pub global_efficiency: f64,
    pub mean_local_efficiency: f64,
    pub clustering_coeff: f64,
    pub char_path_length: f64,
    pub small_worldness: f64,
    pub modularity_q: f64,
    pub assortativity: f64,
    pub nodal: Vec<NodalGraphMetric>,
    pub sweep: Vec<DensitySweepPoint>,
}

#[derive(Copy, Clone, PartialEq)]
struct OrdDist {
    dist: f64,
    node: usize,
}

impl Eq for OrdDist {}

impl Ord for OrdDist {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .dist
            .total_cmp(&self.dist)
            .then_with(|| self.node.cmp(&other.node))
    }
}

impl PartialOrd for OrdDist {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

struct SplitMix64(u64);

impl SplitMix64 {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn next_usize(&mut self, bound: usize) -> usize {
        if bound <= 1 {
            return 0;
        }
        (self.next_u64() % (bound as u64)) as usize
    }
}

fn build_thresholded_subgraph(
    mat: ArrayView2<'_, f64>,
    communities: &[usize],
    density: f64,
    weighted: bool,
) -> Result<(Vec<usize>, Vec<usize>, Vec<(usize, usize, f64)>, f64)> {
    let (n, m) = mat.dim();
    if n != m || n < 2 {
        bail!("Expected square connectivity matrix of size >= 2, got ({n}, {m})");
    }
    if communities.len() != n {
        bail!("communities length ({}) != matrix dimension ({n})", communities.len());
    }

    let intact_nodes: Vec<usize> = (0..n).filter(|&i| mat[[i, i]].is_finite()).collect();
    let p = intact_nodes.len();
    if p < 2 {
        return Ok((intact_nodes, Vec::new(), Vec::new(), 1.0));
    }
    let intact_comm: Vec<usize> = intact_nodes.iter().map(|&u| communities[u]).collect();

    let mut pairs: Vec<(usize, usize, f64)> = Vec::with_capacity(p * (p - 1) / 2);
    for ui in 0..p {
        let u = intact_nodes[ui];
        for vi in (ui + 1)..p {
            let v = intact_nodes[vi];
            let a = mat[[u, v]];
            let b = mat[[v, u]];
            let sym = if a.is_finite() && b.is_finite() {
                0.5 * (a + b)
            } else if a.is_finite() {
                a
            } else if b.is_finite() {
                b
            } else {
                0.0
            };
            // Positive-weight network (Rubinov & Sporns, 2011): negative correlations are not
            // edges. Using |r| would turn anticorrelations into strong positive links.
            if sym.is_finite() && sym > 1e-12 {
                pairs.push((ui, vi, sym));
            }
        }
    }

    pairs.sort_by(|a, b| {
        b.2.total_cmp(&a.2)
            .then_with(|| a.0.cmp(&b.0))
            .then_with(|| a.1.cmp(&b.1))
    });

    let total_possible = p * (p - 1) / 2;
    let d_clamped = density.clamp(0.01, 1.0);
    let keep = ((total_possible as f64) * d_clamped)
        .round()
        .clamp(1.0, pairs.len() as f64) as usize;
    pairs.truncate(keep.min(pairs.len()));

    let max_w = pairs
        .iter()
        .map(|e| e.2)
        .fold(0.0_f64, f64::max)
        .max(1e-12);

    if !weighted {
        for e in &mut pairs {
            e.2 = 1.0;
        }
        return Ok((intact_nodes, intact_comm, pairs, 1.0));
    }

    Ok((intact_nodes, intact_comm, pairs, max_w))
}

fn build_adj_and_matrix(
    p: usize,
    edges: &[(usize, usize, f64)],
    max_w: f64,
) -> (Vec<Vec<(usize, f64, f64)>>, Vec<f64>) {
    // Stores (neighbor, raw_w, norm_w in (0, 1]) and dense p x p normalized weights.
    let mut adj = vec![Vec::<(usize, f64, f64)>::new(); p];
    let mut w_norm_mat = vec![0.0_f64; p * p];
    let inv_max = 1.0 / max_w.max(1e-12);
    for &(u, v, raw_w) in edges {
        let nw = (raw_w * inv_max).clamp(1e-9, 1.0);
        adj[u].push((v, raw_w, nw));
        adj[v].push((u, raw_w, nw));
        w_norm_mat[u * p + v] = nw;
        w_norm_mat[v * p + u] = nw;
    }
    (adj, w_norm_mat)
}

fn clustering_and_eff_fast(p: usize, edges: &[(usize, usize, f64)], max_w: f64) -> (f64, f64, f64) {
    if p < 2 || edges.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let (adj, w_norm_mat) = build_adj_and_matrix(p, edges, max_w);

    // Clustering coefficient per node
    let clust_sum: f64 = (0..p)
        .into_par_iter()
        .map(|u| {
            let nbrs = &adj[u];
            let k = nbrs.len();
            if k < 2 {
                return 0.0;
            }
            let mut tri = 0.0_f64;
            for a_idx in 0..k {
                let (v, _, w_uv) = nbrs[a_idx];
                for b_idx in (a_idx + 1)..k {
                    let (w, _, w_uw) = nbrs[b_idx];
                    let w_vw = w_norm_mat[v * p + w];
                    if w_vw > 0.0 {
                        tri += (w_uv * w_uw * w_vw).cbrt();
                    }
                }
            }
            (2.0 * tri) / ((k * (k - 1)) as f64)
        })
        .sum();
    let mean_c = clust_sum / (p as f64);

    // All-pairs Dijkstra for E_glob & L
    let stats: (f64, f64, usize) = (0..p)
        .into_par_iter()
        .map(|src| {
            let mut dist = vec![f64::INFINITY; p];
            let mut heap = BinaryHeap::new();
            dist[src] = 0.0;
            heap.push(OrdDist { dist: 0.0, node: src });
            while let Some(OrdDist { dist: d, node: u }) = heap.pop() {
                if d > dist[u] {
                    continue;
                }
                for &(v, _, nw) in &adj[u] {
                    let nd = d + (1.0 / nw);
                    if nd < dist[v] {
                        dist[v] = nd;
                        heap.push(OrdDist { dist: nd, node: v });
                    }
                }
            }
            let mut eff = 0.0_f64;
            let mut d_sum = 0.0_f64;
            let mut d_cnt = 0_usize;
            for (dst, &d) in dist.iter().enumerate() {
                if dst != src && d.is_finite() && d > 0.0 {
                    eff += 1.0 / d;
                    d_sum += d;
                    d_cnt += 1;
                }
            }
            (eff, d_sum, d_cnt)
        })
        .reduce(|| (0.0, 0.0, 0), |a, b| (a.0 + b.0, a.1 + b.1, a.2 + b.2));

    let e_glob = stats.0 / ((p * (p - 1)) as f64);
    let char_l = if stats.2 > 0 {
        stats.1 / (stats.2 as f64)
    } else {
        f64::INFINITY
    };
    (e_glob, mean_c, char_l)
}

fn generate_null_edges(
    p: usize,
    edges: &[(usize, usize, f64)],
    seed: u64,
) -> Vec<(usize, usize, f64)> {
    let m = edges.len();
    if p < 4 || m < 2 {
        return edges.to_vec();
    }
    let mut rng = SplitMix64(seed);
    let mut edge_list: Vec<(usize, usize, f64)> = edges.to_vec();
    let mut has_edge = vec![false; p * p];
    for &(u, v, _) in &edge_list {
        has_edge[u * p + v] = true;
        has_edge[v * p + u] = true;
    }

    let mut swapped = 0_usize;
    let target_swaps = m * 4;
    for _ in 0..(target_swaps * 4) {
        if swapped >= target_swaps {
            break;
        }
        let idx1 = rng.next_usize(m);
        let idx2 = rng.next_usize(m);
        if idx1 == idx2 {
            continue;
        }
        let (a, b, w1) = edge_list[idx1];
        let (c, d, w2) = edge_list[idx2];
        if a == c || a == d || b == c || b == d {
            continue;
        }
        // Try a-d and c-b
        if !has_edge[a * p + d] && !has_edge[c * p + b] {
            has_edge[a * p + b] = false;
            has_edge[b * p + a] = false;
            has_edge[c * p + d] = false;
            has_edge[d * p + c] = false;
            has_edge[a * p + d] = true;
            has_edge[d * p + a] = true;
            has_edge[c * p + b] = true;
            has_edge[b * p + c] = true;
            edge_list[idx1] = (a, d, w1);
            edge_list[idx2] = (c, b, w2);
            swapped += 1;
        }
    }

    // Fallback Erdos-Renyi random placement if graph is too dense/star-like for degree-preserving swaps
    if swapped < (m / 4).max(1) {
        has_edge.fill(false);
        let mut weights: Vec<f64> = edges.iter().map(|e| e.2).collect();
        let mut out = Vec::with_capacity(m);
        let mut attempts = 0_usize;
        while out.len() < m && attempts < m * 20 + 64 {
            attempts += 1;
            let u = rng.next_usize(p);
            let v = rng.next_usize(p);
            if u == v || has_edge[u * p + v] {
                continue;
            }
            has_edge[u * p + v] = true;
            has_edge[v * p + u] = true;
            let w = weights.pop().unwrap_or(1.0);
            out.push((u.min(v), u.max(v), w));
        }
        return out;
    }

    edge_list
}

fn compute_small_worldness(
    p: usize,
    edges: &[(usize, usize, f64)],
    max_w: f64,
    c_obs: f64,
    l_obs: f64,
    n_null: usize,
) -> f64 {
    if p < 4 || edges.is_empty() || !l_obs.is_finite() || l_obs <= 0.0 {
        return 1.0;
    }
    let mut c_rands = Vec::with_capacity(n_null);
    let mut l_rands = Vec::with_capacity(n_null);
    for s in 0..n_null {
        let null_edges = generate_null_edges(p, edges, 0xA5A5_1337_0000_0001_u64 + (s as u64) * 7919);
        let (_, c_r, l_r) = clustering_and_eff_fast(p, &null_edges, max_w);
        if c_r.is_finite() && c_r > 0.0 && l_r.is_finite() && l_r > 0.0 {
            c_rands.push(c_r);
            l_rands.push(l_r);
        }
    }
    if c_rands.is_empty() || l_rands.is_empty() {
        return 1.0;
    }
    let c_rand = c_rands.iter().sum::<f64>() / (c_rands.len() as f64);
    let l_rand = l_rands.iter().sum::<f64>() / (l_rands.len() as f64);
    let gamma = c_obs / c_rand.max(1e-9);
    let lambda = (l_obs / l_rand.max(1e-9)).max(1e-9);
    gamma / lambda
}

fn compute_modularity_q(
    p: usize,
    adj: &[Vec<(usize, f64, f64)>],
    strengths: &[f64],
    comm: &[usize],
) -> f64 {
    // Newman (2006) weighted modularity for a *given* partition:
    // Q = (1/2m) * sum_c [ W_in(c) - S_c^2 / 2m ], with W_in(c) = sum_{i,j in c} A_ij (both
    // directions) and S_c = sum_{i in c} k_i. The null term covers *all* same-community pairs.
    let total_w2: f64 = strengths.iter().sum();
    if total_w2 <= 1e-12 || p < 2 {
        return 0.0;
    }
    let n_comm = comm.iter().copied().max().map_or(0, |m| m + 1);
    let mut w_in = vec![0.0_f64; n_comm];
    let mut s_c = vec![0.0_f64; n_comm];
    for ui in 0..p {
        let cu = comm[ui];
        s_c[cu] += strengths[ui];
        for &(vi, raw_w, _) in &adj[ui] {
            if comm[vi] == cu {
                w_in[cu] += raw_w;
            }
        }
    }
    (0..n_comm)
        .map(|c| w_in[c] - s_c[c] * s_c[c] / total_w2)
        .sum::<f64>()
        / total_w2
}

fn compute_assortativity(edges: &[(usize, usize, f64)], degrees: &[usize]) -> f64 {
    if edges.is_empty() {
        return 0.0;
    }
    let mf = edges.len() as f64;
    let mut sum_prod = 0.0_f64;
    let mut sum_half = 0.0_f64;
    let mut sum_sq_half = 0.0_f64;
    for &(u, v, _) in edges {
        let ku = degrees[u] as f64;
        let kv = degrees[v] as f64;
        sum_prod += ku * kv;
        sum_half += 0.5 * (ku + kv);
        sum_sq_half += 0.5 * (ku * ku + kv * kv);
    }
    let term = (sum_half / mf).powi(2);
    let num = (sum_prod / mf) - term;
    let den = (sum_sq_half / mf) - term;
    if den.abs() <= 1e-12 {
        0.0
    } else {
        (num / den).clamp(-1.0, 1.0)
    }
}

/// Computes comprehensive pure-Rust Graph Theory metrics (Global, Nodal, and Density Sweep)
/// over an adjacency matrix with NaN-safe handling for lesioned/excluded ROIs.
pub(crate) fn compute_full_graph_theory(
    mat: ArrayView2<'_, f64>,
    communities: &[usize],
    density: f64,
    weighted: bool,
) -> Result<GraphTheoryResult> {
    let n_total = mat.nrows();
    let (intact_nodes, intact_comm, edges, max_w) =
        build_thresholded_subgraph(mat, communities, density, weighted)?;
    let p = intact_nodes.len();
    let n_excluded = n_total.saturating_sub(p);

    if p < 2 || edges.is_empty() {
        return Ok(GraphTheoryResult {
            n_intact_nodes: p,
            n_excluded_nodes: n_excluded,
            n_edges: edges.len(),
            density,
            weighted,
            global_efficiency: 0.0,
            mean_local_efficiency: 0.0,
            clustering_coeff: 0.0,
            char_path_length: 0.0,
            small_worldness: 1.0,
            modularity_q: 0.0,
            assortativity: 0.0,
            nodal: Vec::new(),
            sweep: Vec::new(),
        });
    }

    let (adj, w_norm_mat) = build_adj_and_matrix(p, &edges, max_w);
    let degrees: Vec<usize> = adj.iter().map(|nbrs| nbrs.len()).collect();
    let strengths: Vec<f64> = adj
        .iter()
        .map(|nbrs| nbrs.iter().map(|e| e.1).sum::<f64>())
        .collect();

    // Nodal clustering coefficient & local efficiency (Rayon parallel over nodes)
    let clust_and_loc_eff: Vec<(f64, f64)> = (0..p)
        .into_par_iter()
        .map(|u| {
            let nbrs = &adj[u];
            let k = nbrs.len();
            if k < 2 {
                return (0.0, 0.0);
            }
            let mut tri = 0.0_f64;
            for a_idx in 0..k {
                let (v, _, w_uv) = nbrs[a_idx];
                for b_idx in (a_idx + 1)..k {
                    let (w, _, w_uw) = nbrs[b_idx];
                    let w_vw = w_norm_mat[v * p + w];
                    if w_vw > 0.0 {
                        tri += (w_uv * w_uw * w_vw).cbrt();
                    }
                }
            }
            let c_i = (2.0 * tri) / ((k * (k - 1)) as f64);

            // Local efficiency on neighbor subgraph N_u (size k)
            let mut loc_eff_sum = 0.0_f64;
            for src_idx in 0..k {
                let mut dist = vec![f64::INFINITY; k];
                let mut heap = BinaryHeap::new();
                dist[src_idx] = 0.0;
                heap.push(OrdDist { dist: 0.0, node: src_idx });
                while let Some(OrdDist { dist: d, node: a }) = heap.pop() {
                    if d > dist[a] {
                        continue;
                    }
                    let u_a = nbrs[a].0;
                    for b in 0..k {
                        if a == b {
                            continue;
                        }
                        let w_ab = w_norm_mat[u_a * p + nbrs[b].0];
                        if w_ab > 0.0 {
                            let nd = d + (1.0 / w_ab);
                            if nd < dist[b] {
                                dist[b] = nd;
                                heap.push(OrdDist { dist: nd, node: b });
                            }
                        }
                    }
                }
                for dst_idx in 0..k {
                    if dst_idx != src_idx && dist[dst_idx].is_finite() && dist[dst_idx] > 0.0 {
                        loc_eff_sum += 1.0 / dist[dst_idx];
                    }
                }
            }
            let loc_eff = loc_eff_sum / ((k * (k - 1)) as f64);
            (c_i, loc_eff)
        })
        .collect();

    // Brandes' shortest-path betweenness centrality + global efficiency + path length
    let brandes_res: (Vec<f64>, f64, f64, usize) = (0..p)
        .into_par_iter()
        .map(|s| {
            let mut stack = Vec::with_capacity(p);
            let mut pred = vec![Vec::<usize>::new(); p];
            let mut sigma = vec![0.0_f64; p];
            let mut dist = vec![f64::INFINITY; p];
            sigma[s] = 1.0;
            dist[s] = 0.0;

            let mut heap = BinaryHeap::new();
            heap.push(OrdDist { dist: 0.0, node: s });
            let mut popped = vec![false; p];

            while let Some(OrdDist { dist: d, node: v }) = heap.pop() {
                if popped[v] || d > dist[v] + 1e-12 {
                    continue;
                }
                popped[v] = true;
                stack.push(v);
                for &(w, _, nw) in &adj[v] {
                    let alt = d + (1.0 / nw);
                    if alt + 1e-12 < dist[w] {
                        dist[w] = alt;
                        sigma[w] = sigma[v];
                        pred[w].clear();
                        pred[w].push(v);
                        heap.push(OrdDist { dist: alt, node: w });
                    } else if (alt - dist[w]).abs() <= 1e-12 {
                        sigma[w] += sigma[v];
                        pred[w].push(v);
                    }
                }
            }

            let mut delta = vec![0.0_f64; p];
            let mut bc_local = vec![0.0_f64; p];
            while let Some(w) = stack.pop() {
                for &v in &pred[w] {
                    if sigma[w] > 0.0 {
                        delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w]);
                    }
                }
                if w != s {
                    bc_local[w] += delta[w];
                }
            }

            let mut eff = 0.0_f64;
            let mut d_sum = 0.0_f64;
            let mut d_cnt = 0_usize;
            for (dst, &d) in dist.iter().enumerate() {
                if dst != s && d.is_finite() && d > 0.0 {
                    eff += 1.0 / d;
                    d_sum += d;
                    d_cnt += 1;
                }
            }
            (bc_local, eff, d_sum, d_cnt)
        })
        .reduce(
            || (vec![0.0; p], 0.0, 0.0, 0),
            |mut acc, item| {
                for i in 0..p {
                    acc.0[i] += item.0[i];
                }
                acc.1 += item.1;
                acc.2 += item.2;
                acc.3 += item.3;
                acc
            },
        );

    let global_efficiency = brandes_res.1 / ((p * (p - 1)) as f64);
    let char_path_length = if brandes_res.3 > 0 {
        brandes_res.2 / (brandes_res.3 as f64)
    } else {
        0.0
    };
    let bc_norm = if p > 2 {
        ((p - 1) * (p - 2)) as f64
    } else {
        1.0
    };

    let clustering_coeff =
        clust_and_loc_eff.iter().map(|x| x.0).sum::<f64>() / (p as f64);
    let mean_local_efficiency =
        clust_and_loc_eff.iter().map(|x| x.1).sum::<f64>() / (p as f64);

    let modularity_q = compute_modularity_q(p, &adj, &strengths, &intact_comm);
    let assortativity = compute_assortativity(&edges, &degrees);
    let small_worldness = if p <= 400 {
        compute_small_worldness(p, &edges, max_w, clustering_coeff, char_path_length, 5)
    } else {
        1.0
    };

    // Participation Coefficient P_i and Within-Module Degree z_i
    let mut intra_w = vec![0.0_f64; p];
    let mut part_coeff = vec![0.0_f64; p];
    let mut comm_members: BTreeMap<usize, Vec<f64>> = BTreeMap::new();

    for u in 0..p {
        let cu = intact_comm[u];
        let mut by_comm: BTreeMap<usize, f64> = BTreeMap::new();
        let mut tot = 0.0_f64;
        for &(v, raw_w, _) in &adj[u] {
            let weight = if weighted { raw_w } else { 1.0 };
            tot += weight;
            *by_comm.entry(intact_comm[v]).or_insert(0.0) += weight;
        }
        let k_in = *by_comm.get(&cu).unwrap_or(&0.0);
        intra_w[u] = k_in;
        comm_members.entry(cu).or_default().push(k_in);

        if tot > 1e-12 {
            let sum_sq: f64 = by_comm.values().map(|&km| (km / tot).powi(2)).sum();
            part_coeff[u] = (1.0 - sum_sq).clamp(0.0, 1.0);
        }
    }

    let mut comm_stats: BTreeMap<usize, (f64, f64)> = BTreeMap::new();
    for (c, vals) in comm_members {
        let m = vals.iter().sum::<f64>() / (vals.len() as f64);
        let var = vals.iter().map(|&v| (v - m).powi(2)).sum::<f64>() / (vals.len() as f64);
        comm_stats.insert(c, (m, var.sqrt()));
    }

    let mut nodal = Vec::with_capacity(p);
    for u in 0..p {
        let (mu, sd) = comm_stats[&intact_comm[u]];
        let z_i = if sd > 1e-12 { (intra_w[u] - mu) / sd } else { 0.0 };
        nodal.push(NodalGraphMetric {
            roi_index: intact_nodes[u],
            degree: degrees[u],
            strength: strengths[u],
            clustering: clust_and_loc_eff[u].0,
            local_efficiency: clust_and_loc_eff[u].1,
            betweenness: brandes_res.0[u] / bc_norm,
            participation_coeff: part_coeff[u],
            within_module_z: z_i,
        });
    }

    // Density sweep curve across 5%..40%
    let sweep_densities = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40];
    let mut sweep = Vec::with_capacity(sweep_densities.len());
    for sd in sweep_densities {
        if let Ok((_, s_comm, s_edges, s_max_w)) =
            build_thresholded_subgraph(mat, communities, sd, weighted)
        {
            if s_edges.is_empty() {
                continue;
            }
            let (e_g, c_c, l_c) = clustering_and_eff_fast(p, &s_edges, s_max_w);
            let (s_adj, _) = build_adj_and_matrix(p, &s_edges, s_max_w);
            let s_str: Vec<f64> = s_adj
                .iter()
                .map(|nbrs| nbrs.iter().map(|e| e.1).sum::<f64>())
                .collect();
            let q_c = compute_modularity_q(p, &s_adj, &s_str, &s_comm);
            let sw = compute_small_worldness(p, &s_edges, s_max_w, c_c, l_c, 3);
            sweep.push(DensitySweepPoint {
                density: sd,
                global_efficiency: e_g,
                clustering_coeff: c_c,
                small_worldness: sw,
                modularity_q: q_c,
            });
        }
    }

    Ok(GraphTheoryResult {
        n_intact_nodes: p,
        n_excluded_nodes: n_excluded,
        n_edges: edges.len(),
        density,
        weighted,
        global_efficiency,
        mean_local_efficiency,
        clustering_coeff,
        char_path_length,
        small_worldness,
        modularity_q,
        assortativity,
        nodal,
        sweep,
    })
}
