mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
pub mod api;
pub mod connectivity;
pub mod denoise;
pub mod nifti_io;
pub mod parcellation;

#[cfg(test)]
mod tests {
    use crate::connectivity::{sliding_window_fc, static_fc_pearson};
    use crate::denoise::{build_dct_stopband_basis, compute_acompcor, simultaneous_denoise};
    use crate::nifti_io::{render_ortho_slice_rgba, OrthoPlane};
    use crate::parcellation::extract_roi_timeseries;
    use ndarray::{Array2, Array3, Array4};
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
            let drift = (2.0 * PI * 0.002 * sec).cos(); // < 0.008 Hz stopband
            let fast = (2.0 * PI * 0.18 * sec).sin(); // > 0.09 Hz stopband
            let passband = (2.0 * PI * 0.04 * sec).sin(); // 0.04 Hz passband

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

        // Correlation with confounds must be < 1e-10 after projection.
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

        // Stopband DCT basis correlation must be ~0, and signal energy preserved.
        let dct = build_dct_stopband_basis(nt, tr, Some(0.008), Some(0.09));
        assert!(dct.ncols() > 5);
        for d in 0..dct.ncols() {
            let dot: f64 = (0..nt).map(|t| clean[[t, 0]] * dct[[t, d]]).sum();
            assert!(dot.abs() < 1e-9, "stopband leakage on mode {d}: {dot}");
        }

        // Passband 0.04 Hz should remain strongly correlated with clean[:, 0].
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
        assert!(fc[[0, 1]].abs() < 1e-9); // SVD components are orthogonal

        let sw = sliding_window_fc(comps.view(), 10, 5).unwrap();
        assert_eq!(sw.len(), 5);

        let slice = render_ortho_slice_rgba(bold.view(), OrthoPlane::Axial, 2, 5).unwrap();
        assert_eq!(slice.width, 6);
        assert_eq!(slice.height, 6);
        assert_eq!(slice.rgba.len(), 6 * 6 * 4);
    }
}
