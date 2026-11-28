//! Review harness: drives CCS_fMRIStudio's own Rust core exactly as the GUI does
//! (run_lesion_aware_pipeline, censor_mode=interpolate) and also dumps intermediates.
use anyhow::Result;
use ccs_fmri_core::api::run_lesion_aware_pipeline;
use ccs_fmri_core::denoise::{compute_acompcor_filtered, load_confounds_with_fd, simultaneous_denoise_with_mode, CensorMode};
use ccs_fmri_core::nifti_io::{load_atlas_i32, load_bold_volume, load_mask_u8};
use ccs_fmri_core::parcellation::extract_roi_timeseries;
use ndarray::{concatenate, Array2, Axis};
use std::io::Write;
use std::path::Path;
use std::time::Instant;

fn write_csv(p: &Path, m: &Array2<f64>) -> Result<()> {
    let mut w = std::io::BufWriter::new(std::fs::File::create(p)?);
    for r in 0..m.nrows() {
        let row: Vec<String> = (0..m.ncols()).map(|c| format!("{:.10e}", m[[r, c]])).collect();
        writeln!(w, "{}", row.join(","))?;
    }
    Ok(())
}

fn main() -> Result<()> {
    let a: Vec<String> = std::env::args().collect();
    let pre = Path::new(&a[1]);
    let out = Path::new(&a[2]);
    std::fs::create_dir_all(out)?;
    let bold = pre.join("bold_mni.nii");
    let atlas_p = pre.join("schaefer400_mni.nii.gz");
    let conf_p = pre.join("confounds.tsv");
    let wm_p = pre.join("wm_mask_mni.nii.gz");
    let csf_p = pre.join("csf_mask_mni.nii.gz");

    // 1) GUI path
    let t = Instant::now();
    let s = run_lesion_aware_pipeline(
        bold.to_string_lossy().into(), atlas_p.to_string_lossy().into(), None,
        Some(pre.join("schaefer400_labels.json").to_string_lossy().into()),
        Some(wm_p.to_string_lossy().into()), Some(csf_p.to_string_lossy().into()),
        Some(conf_p.to_string_lossy().into()), 0.008, 0.09, 0.5, 50.0, 1,
        Some("spike".into()), Some(out.join("gui_results").to_string_lossy().into()),
    )?;
    let gui_ms = t.elapsed().as_secs_f64() * 1e3;

    // 2) Intermediates
    let t0 = Instant::now();
    let vol = load_bold_volume(&bold)?;
    let load_ms = t0.elapsed().as_secs_f64() * 1e3;
    let tr = vol.header().tr_sec;
    let atlas = load_atlas_i32(&atlas_p)?;
    let t1 = Instant::now();
    let (_ids, raw) = extract_roi_timeseries(vol.view(), atlas.view())?;
    let parc_ms = t1.elapsed().as_secs_f64() * 1e3;
    let nt = raw.nrows();
    let (motion, scrub, fd) = load_confounds_with_fd(&conf_p, nt, 0.5)?;
    let t2 = Instant::now();
    let wm = compute_acompcor_filtered(vol.view(), load_mask_u8(&wm_p)?.view(), 5, tr, Some(0.008))?;
    let csf = compute_acompcor_filtered(vol.view(), load_mask_u8(&csf_p)?.view(), 5, tr, Some(0.008))?;
    let acc_ms = t2.elapsed().as_secs_f64() * 1e3;
    let conf = concatenate(Axis(1), &[motion.view(), wm.view(), csf.view()])?;
    write_csv(&out.join("raw_ts.csv"), &raw)?;
    write_csv(&out.join("confounds_used.csv"), &conf)?;
    std::fs::write(out.join("scrub_idx.txt"), scrub.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("\n"))?;
    std::fs::write(out.join("fd.txt"), fd.iter().map(|v| v.to_string()).collect::<Vec<_>>().join("\n"))?;
    for (name, mode) in [("interp", CensorMode::Interpolate), ("spike", CensorMode::Spike), ("nocensor", CensorMode::None)] {
        let t3 = Instant::now();
        let r = simultaneous_denoise_with_mode(raw.view(), Some(conf.view()), tr, Some(0.008), Some(0.09), &scrub, mode, true)?;
        let ms = t3.elapsed().as_secs_f64() * 1e3;
        write_csv(&out.join(format!("clean_{name}.csv")), &r.clean_ts)?;
        std::fs::write(out.join(format!("kept_{name}.txt")), r.kept_rows.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("\n"))?;
        println!("mode={name} n_reg={} dof={} denoise_ms={ms:.2}", r.n_regressors, r.dof_remaining);
    }
    println!("tr={tr} nt={nt} n_scrub={} gui_total_ms={gui_ms:.1} load_ms={load_ms:.1} parc_ms={parc_ms:.1} acompcor_ms={acc_ms:.1} gui_dof={} gui_nreg={}",
        scrub.len(), s.dof_remaining, s.n_regressors);
    Ok(())
}
