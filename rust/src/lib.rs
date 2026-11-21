mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
pub mod api;
pub mod connectivity;
pub mod denoise;
pub mod lesion;
pub mod nifti_io;
pub mod parcellation;

#[cfg(test)]
mod tests {
    use crate::connectivity::{
        compute_homotopic_and_laterality, compute_nan_safe_graph_metrics,
        detect_schaefer_hemispheres, lesion_network_mapping, sliding_window_fc, static_fc_pearson,
    };
    use crate::denoise::{build_dct_stopband_basis, compute_acompcor, simultaneous_denoise};
    use crate::lesion::{
        apply_spherical_brush, compute_hemispheric_asymmetry, dilate_mask_3d, fill_holes_3d,
        magic_wand_3d, remove_small_islands_3d, render_ortho_slice_with_lesion_rgba,
        save_mask_u8_nifti, subtract_lesion_from_mask,
    };
    use crate::nifti_io::{load_mask_u8, render_ortho_slice_rgba, OrthoPlane};
    use crate::parcellation::{extract_roi_timeseries, extract_roi_timeseries_lesion_aware};
    use ndarray::{Array2, Array3, Array4, Axis};
    use nifti::writer::WriterOptions;
    use std::f64::consts::PI;

    #[test]
    fn test_roi_timeseries_extraction() {
        let mut bold = Array4::<f32>::zeros((4, 4, 4, 10));
        let mut atlas = Array3::<i32>::zeros((4, 4, 4));
        atlas[[0, 0, 0]] = 1;
        atlas[[1, 0, 0]] = 1;
        atlas[[2, 2, 2]] = 2;

        for t in 0..10 {
            bold[[0, 0, 0, t]] = (t as f32) * 2.0;
            bold[[1, 0, 0, t]] = (t as f32) * 4.0;
            bold[[2, 2, 2, t]] = 10.0 + (t as f32);
        }

        let (ids, ts) = extract_roi_timeseries(bold.view(), atlas.view()).unwrap();
        assert_eq!(ids, vec![1, 2]);
        assert_eq!(ts.dim(), (10, 2));
        for t in 0..10 {
            assert!((ts[[t, 0]] - (t as f64) * 3.0).abs() < 1e-6);
            assert!((ts[[t, 1]] - (10.0 + t as f64)).abs() < 1e-6);
        }
    }

    #[test]
    fn test_simultaneous_denoise_orthogonalizes_confounds_and_stopband() {
        let nt = 200;
        let tr = 2.0;
        let mut conf = Array2::<f64>::zeros((nt, 2));
        let mut sig = Array2::<f64>::zeros((nt, 2));

        for t in 0..nt {
            let sec = (t as f64) * tr;
            let motion = (2.0 * PI * 0.03 * sec).sin();
            let drift = (2.0 * PI * 0.002 * sec).cos();
            let fast = (2.0 * PI * 0.18 * sec).sin();
            let passband = (2.0 * PI * 0.04 * sec).sin();

            conf[[t, 0]] = motion;
            conf[[t, 1]] = 0.5 * motion + 0.3 * (t as f64 / nt as f64);

            sig[[t, 0]] = 5.0 * motion + 4.0 * drift + 3.0 * fast + passband;
            sig[[t, 1]] = -2.0 * motion + 2.5 * drift + passband;
        }

        let clean = simultaneous_denoise(
            sig.view(),
            Some(conf.view()),
            tr,
            Some(0.008),
            Some(0.09),
            &[],
            false,
        )
        .unwrap();

        for c in 0..2 {
            let mut dot = 0.0;
            let mut n1 = 0.0;
            let mut n2 = 0.0;
            for t in 0..nt {
                dot += clean[[t, 0]] * conf[[t, c]];
                n1 += clean[[t, 0]] * clean[[t, 0]];
                n2 += conf[[t, c]] * conf[[t, c]];
            }
            let r = dot / (n1.sqrt() * n2.sqrt());
            assert!(r.abs() < 1e-10, "residual confound correlation too high: {r}");
        }

        let dct = build_dct_stopband_basis(nt, tr, Some(0.008), Some(0.09));
        assert!(dct.ncols() > 5);
        for d in 0..dct.ncols() {
            let dot: f64 = (0..nt).map(|t| clean[[t, 0]] * dct[[t, d]]).sum();
            assert!(dot.abs() < 1e-9, "stopband leakage on mode {d}: {dot}");
        }

        let mut dot_p = 0.0;
        let mut n_clean = 0.0;
        let mut n_pass = 0.0;
        for t in 0..nt {
            let pass = (2.0 * PI * 0.04 * (t as f64) * tr).sin();
            dot_p += clean[[t, 0]] * pass;
            n_clean += clean[[t, 0]] * clean[[t, 0]];
            n_pass += pass * pass;
        }
        let r_pass = (dot_p / (n_clean.sqrt() * n_pass.sqrt())).abs();
        assert!(r_pass > 0.85, "passband signal attenuated too much: r={r_pass}");
    }

    #[test]
    fn test_acompcor_and_connectivity_and_rgba() {
        let mut bold = Array4::<f32>::zeros((6, 6, 4, 30));
        let mut mask = Array3::<u8>::zeros((6, 6, 4));
        for x in 1..4 {
            for y in 1..4 {
                mask[[x, y, 2]] = 1;
                for t in 0..30 {
                    bold[[x, y, 2, t]] =
                        ((t as f32) * 0.3 + (x as f32) * 0.1).sin() + (y as f32) * 0.05;
                }
            }
        }
        let comps = compute_acompcor(bold.view(), mask.view(), 3).unwrap();
        assert_eq!(comps.dim(), (30, 3));

        let fc = static_fc_pearson(comps.view()).unwrap();
        assert_eq!(fc.dim(), (3, 3));
        assert!((fc[[0, 0]] - 1.0).abs() < 1e-9);
        assert!(fc[[0, 1]].abs() < 1e-9);

        let sw = sliding_window_fc(comps.view(), 10, 5).unwrap();
        assert_eq!(sw.len(), 5);

        let slice = render_ortho_slice_rgba(bold.view(), OrthoPlane::Axial, 2, 5).unwrap();
        assert_eq!(slice.width, 6);
        assert_eq!(slice.height, 6);
        assert_eq!(slice.rgba.len(), 6 * 6 * 4);
    }

    #[test]
    fn test_lesion_asymmetry_magic_wand_brush_and_morphology() {
        let mut t1 = Array3::<f32>::from_elem((16, 16, 16), 100.0);
        // Create hypointense left-side focal lesion cavity (x in 2..6, y in 5..9, z in 5..9).
        for z in 5..9 {
            for y in 5..9 {
                for x in 2..6 {
                    t1[[x, y, z]] = 20.0;
                }
            }
        }

        let (_zmap, auto_mask, summary) =
            compute_hemispheric_asymmetry(t1.view(), None, [2.0, 2.0, 2.0], None, 2.0).unwrap();
        assert!(summary.voxel_count >= 50);
        assert_eq!(summary.dominant_hemisphere, "Left");
        assert_eq!(auto_mask[[3, 6, 6]], 1);

        // Magic wand on blank mask should fill the 4x4x4 = 64 voxel lesion cavity.
        let mut wand_mask = Array3::<u8>::zeros((16, 16, 16));
        let added = magic_wand_3d(t1.view(), &mut wand_mask, [3, 6, 6], 5.0).unwrap();
        assert_eq!(added, 64);

        // Create an interior hole & a small 2-voxel island, then test fill_holes + remove_small_islands.
        wand_mask[[3, 6, 6]] = 0;
        let filled = fill_holes_3d(wand_mask.view());
        assert_eq!(filled[[3, 6, 6]], 1);

        let mut with_island = filled.clone();
        with_island[[14, 14, 14]] = 1;
        with_island[[14, 14, 13]] = 1;
        let cleaned = remove_small_islands_3d(with_island.view(), 10);
        assert_eq!(cleaned[[14, 14, 14]], 0);
        assert_eq!(cleaned[[3, 6, 6]], 1);

        // Brush paint/erase + dilation + tissue subtraction.
        let mut brush_mask = cleaned.clone();
        apply_spherical_brush(&mut brush_mask, [3, 6, 6], 1.0, true, Some(OrthoPlane::Axial)).unwrap();
        assert_eq!(brush_mask[[3, 6, 6]], 0);

        let dilated = dilate_mask_3d(cleaned.view(), 1);
        assert_eq!(dilated[[6, 6, 6]], 1); // 1 voxel rim outside x=2..6

        let wm = Array3::<u8>::from_elem((16, 16, 16), 1);
        let wm_safe = subtract_lesion_from_mask(wm.view(), cleaned.view(), 1).unwrap();
        assert_eq!(wm_safe[[3, 6, 6]], 0);
        assert_eq!(wm_safe[[6, 6, 6]], 0);
        assert_eq!(wm_safe[[12, 12, 12]], 1);

        // Render slice with lesion overlay and verify red dominance on masked pixels.
        let t1_4d = t1.clone().insert_axis(Axis(3));
        let rgba = render_ortho_slice_with_lesion_rgba(
            t1_4d.view(),
            Some(cleaned.view()),
            OrthoPlane::Axial,
            6,
            0,
            0.4,
        )
        .unwrap();
        // Axial flips Y: row = ny - 1 - y = 15 - 6 = 9, col = x = 3.
        let p_idx = (9 * 16 + 3) * 4;
        assert!(rgba.rgba[p_idx] > rgba.rgba[p_idx + 1]);

        // Round-trip save_mask_u8_nifti -> load_mask_u8 preserves exact voxel coordinates.
        let tmp_dir = std::env::temp_dir().join("ccs_fmri_mask_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let ref_path = tmp_dir.join("ref_t1.nii");
        let mask_path = tmp_dir.join("lesion_out.nii");
        WriterOptions::new(&ref_path).write_nifti(&t1).unwrap();
        save_mask_u8_nifti(cleaned.view(), &ref_path, &mask_path).unwrap();
        let reloaded = load_mask_u8(&mask_path).unwrap();
        assert_eq!(reloaded[[3, 6, 6]], 1);
        assert_eq!(reloaded[[14, 14, 14]], 0);
        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn test_lesion_aware_parcellation_nan_safe_denoise_graph_and_homotopic() {
        let nt = 40;
        let mut bold = Array4::<f32>::zeros((6, 4, 4, nt));
        let mut atlas = Array3::<i32>::zeros((6, 4, 4));
        let mut lesion = Array3::<u8>::zeros((6, 4, 4));

        // Parcel 1 (LH_Vis_1): 4 voxels, 3 damaged (75% > 50%) -> excluded as NaN.
        atlas[[0, 0, 0]] = 1;
        atlas[[0, 1, 0]] = 1;
        atlas[[0, 2, 0]] = 1;
        atlas[[0, 3, 0]] = 1;
        lesion[[0, 0, 0]] = 1;
        lesion[[0, 1, 0]] = 1;
        lesion[[0, 2, 0]] = 1;

        // Parcel 2 (LH_Motor_1): 4 voxels, 0% damaged.
        atlas[[1, 0, 0]] = 2;
        atlas[[1, 1, 0]] = 2;
        atlas[[1, 2, 0]] = 2;
        atlas[[1, 3, 0]] = 2;

        // Parcel 3 (RH_Vis_1): 2 voxels, 0% damaged.
        atlas[[4, 0, 0]] = 3;
        atlas[[4, 1, 0]] = 3;

        // Parcel 4 (RH_Motor_1): 2 voxels, 0% damaged.
        atlas[[5, 0, 0]] = 4;
        atlas[[5, 1, 0]] = 4;

        for t in 0..nt {
            let s1 = (2.0 * PI * 0.04 * (t as f64) * 2.0).sin() as f32;
            let s2 = (2.0 * PI * 0.05 * (t as f64) * 2.0).cos() as f32;
            for y in 0..4 {
                bold[[0, y, 0, t]] = 100.0;
                bold[[1, y, 0, t]] = s1 + 0.1 * s2;
            }
            for y in 0..2 {
                bold[[4, y, 0, t]] = s2;
                bold[[5, y, 0, t]] = s1 + 0.15 * s2;
            }
        }

        let parc = extract_roi_timeseries_lesion_aware(
            bold.view(),
            atlas.view(),
            Some(lesion.view()),
            [2.0, 2.0, 2.0],
            50.0,
        )
        .unwrap();
        assert_eq!(parc.roi_ids, vec![1, 2, 3, 4]);
        assert!(parc.excluded_mask[0]);
        assert!(!parc.excluded_mask[1]);
        assert!((parc.percent_damage[0] - 75.0).abs() < 1e-6);
        assert!(parc.timeseries[[0, 0]].is_nan());

        let clean = simultaneous_denoise(
            parc.timeseries.view(),
            None,
            2.0,
            Some(0.008),
            Some(0.09),
            &[],
            true,
        )
        .unwrap();
        assert!(clean[[0, 0]].is_nan());
        assert!(clean[[0, 1]].is_finite());

        let fc = static_fc_pearson(clean.view()).unwrap();
        assert!(fc[[0, 1]].is_nan());
        assert!(fc[[1, 3]].is_finite() && fc[[1, 3]] > 0.9);

        let graph = compute_nan_safe_graph_metrics(fc.view(), 0.0, Some(&[0, 0, 1, 1])).unwrap();
        assert_eq!(graph.n_excluded_nodes, 1);
        assert_eq!(graph.n_intact_nodes, 3);
        assert!(graph.global_efficiency > 0.0 && graph.global_efficiency.is_finite());

        let labels = vec![
            "7Networks_LH_Vis_1".to_string(),
            "7Networks_LH_Motor_1".to_string(),
            "7Networks_RH_Vis_1".to_string(),
            "7Networks_RH_Motor_1".to_string(),
        ];
        let (lh, rh) = detect_schaefer_hemispheres(&labels);
        assert_eq!(lh, vec![0, 1]);
        assert_eq!(rh, vec![2, 3]);
        let hl = compute_homotopic_and_laterality(fc.view(), &lh, &rh, "Left");
        assert_eq!(hl.n_homotopic_pairs, 1); // Only Motor pair is intact on both sides
        assert!(hl.mean_homotopic_fc > 0.9);

        let seed_r = lesion_network_mapping(bold.view(), lesion.view(), clean.view()).unwrap();
        assert!(seed_r[0].is_nan());
    }
}
