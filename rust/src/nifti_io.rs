use anyhow::{bail, Context, Result};
use memmap2::Mmap;
use ndarray::{Array3, Array4, ArrayView4, Axis, Ix4, ShapeBuilder};
use nifti::{IntoNdArray, NiftiHeader, NiftiObject, ReaderOptions};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NiftiHeaderInfo {
    pub dims: [usize; 4],
    pub voxel_sizes: [f32; 3],
    pub tr_sec: f64,
    pub datatype_code: i16,
    pub affine: [[f32; 4]; 4],
    pub used_mmap: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrthoPlane {
    Axial,
    Coronal,
    Sagittal,
}

impl OrthoPlane {
    pub fn parse(s: &str) -> Result<Self> {
        match s.to_ascii_lowercase().as_str() {
            "axial" | "z" => Ok(Self::Axial),
            "coronal" | "y" => Ok(Self::Coronal),
            "sagittal" | "x" => Ok(Self::Sagittal),
            other => bail!("Unknown ortho plane '{other}' (expected axial, coronal, or sagittal)"),
        }
    }
}

pub struct RenderedSlice {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
    pub min_val: f32,
    pub max_val: f32,
}

/// Holds either a zero-copy memory-mapped `f32` NIfTI volume (for uncompressed little-endian `.nii`)
/// or an owned `Array4<f32>` decoded from `.nii.gz` / scaled / non-float datatypes.
pub enum BoldVolume {
    MmapF32 {
        _mmap: Mmap,
        ptr: *const f32,
        shape: [usize; 4],
        header: NiftiHeaderInfo,
    },
    OwnedF32 {
        data: Array4<f32>,
        header: NiftiHeaderInfo,
    },
}

unsafe impl Send for BoldVolume {}
unsafe impl Sync for BoldVolume {}

impl BoldVolume {
    pub fn view(&self) -> ArrayView4<'_, f32> {
        match self {
            BoldVolume::MmapF32 { ptr, shape, .. } => {
                let len = shape[0] * shape[1] * shape[2] * shape[3];
                let slice = unsafe { std::slice::from_raw_parts(*ptr, len) };
                // NIfTI stores voxels in Fortran (column-major) order: [X, Y, Z, T].
                ArrayView4::from_shape((*shape).f(), slice)
                    .expect("validated mmap shape matches slice length")
            }
            BoldVolume::OwnedF32 { data, .. } => data.view(),
        }
    }

    pub fn header(&self) -> &NiftiHeaderInfo {
        match self {
            BoldVolume::MmapF32 { header, .. } | BoldVolume::OwnedF32 { header, .. } => header,
        }
    }
}

fn sidecar_json_path(nifti_path: &Path) -> Option<PathBuf> {
    let name = nifti_path.file_name()?.to_str()?;
    if let Some(stem) = name.strip_suffix(".nii.gz") {
        Some(nifti_path.with_file_name(format!("{stem}.json")))
    } else if let Some(stem) = name.strip_suffix(".nii") {
        Some(nifti_path.with_file_name(format!("{stem}.json")))
    } else {
        None
    }
}

fn read_tr_from_sidecar(nifti_path: &Path) -> Option<f64> {
    let json_path = sidecar_json_path(nifti_path)?;
    let text = std::fs::read_to_string(json_path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    v.get("RepetitionTime")
        .and_then(|x| x.as_f64())
        .filter(|&tr| tr > 0.0)
}

fn extract_affine(hdr: &NiftiHeader) -> [[f32; 4]; 4] {
    if hdr.sform_code > 0 {
        return [
            hdr.srow_x,
            hdr.srow_y,
            hdr.srow_z,
            [0.0, 0.0, 0.0, 1.0],
        ];
    }
    if hdr.qform_code > 0 {
        let b = hdr.quatern_b as f64;
        let c = hdr.quatern_c as f64;
        let d = hdr.quatern_d as f64;
        let a = (1.0 - (b * b + c * c + d * d)).max(0.0).sqrt();
        let qfac = if hdr.pixdim[0] < 0.0 { -1.0 } else { 1.0 };
        let dx = hdr.pixdim[1].abs().max(1e-6) as f64;
        let dy = hdr.pixdim[2].abs().max(1e-6) as f64;
        let dz = (hdr.pixdim[3].abs().max(1e-6) as f64) * qfac;

        let r11 = a * a + b * b - c * c - d * d;
        let r12 = 2.0 * (b * c - a * d);
        let r13 = 2.0 * (b * d + a * c);
        let r21 = 2.0 * (b * c + a * d);
        let r22 = a * a + c * c - b * b - d * d;
        let r23 = 2.0 * (c * d - a * b);
        let r31 = 2.0 * (b * d - a * c);
        let r32 = 2.0 * (c * d + a * b);
        let r33 = a * a + d * d - b * b - c * c;

        return [
            [(r11 * dx) as f32, (r12 * dy) as f32, (r13 * dz) as f32, hdr.quatern_x],
            [(r21 * dx) as f32, (r22 * dy) as f32, (r23 * dz) as f32, hdr.quatern_y],
            [(r31 * dx) as f32, (r32 * dy) as f32, (r33 * dz) as f32, hdr.quatern_z],
            [0.0, 0.0, 0.0, 1.0],
        ];
    }
    [
        [hdr.pixdim[1], 0.0, 0.0, 0.0],
        [0.0, hdr.pixdim[2], 0.0, 0.0],
        [0.0, 0.0, hdr.pixdim[3], 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]
}

pub fn inspect_nifti_header(path: &Path) -> Result<NiftiHeaderInfo> {
    let hdr = NiftiHeader::from_file(path)
        .with_context(|| format!("Failed to read NIfTI header from {}", path.display()))?;
    let ndim = hdr.dim[0].clamp(1, 7) as usize;
    let nx = hdr.dim[1].max(1) as usize;
    let ny = if ndim >= 2 { hdr.dim[2].max(1) as usize } else { 1 };
    let nz = if ndim >= 3 { hdr.dim[3].max(1) as usize } else { 1 };
    let nt = if ndim >= 4 { hdr.dim[4].max(1) as usize } else { 1 };

    let tr_sec = read_tr_from_sidecar(path)
        .or_else(|| {
            let t = hdr.pixdim[4] as f64;
            if t > 0.0 { Some(t) } else { None }
        })
        .unwrap_or(2.0);

    Ok(NiftiHeaderInfo {
        dims: [nx, ny, nz, nt],
        voxel_sizes: [hdr.pixdim[1], hdr.pixdim[2], hdr.pixdim[3]],
        tr_sec,
        datatype_code: hdr.datatype,
        affine: extract_affine(&hdr),
        used_mmap: false,
    })
}

fn can_mmap_f32(path: &Path, hdr: &NiftiHeader) -> bool {
    let is_gz = path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("gz"));
    if is_gz {
        return false;
    }
    let is_nii_single = &hdr.magic == b"n+1\0";
    let is_f32 = hdr.datatype == 16;
    let native_endian = hdr.endianness == nifti::Endianness::native();
    let trivial_scale = (hdr.scl_slope == 0.0 || (hdr.scl_slope - 1.0).abs() < 1e-6)
        && hdr.scl_inter.abs() < 1e-6;
    let offset = hdr.vox_offset as usize;
    let aligned_offset = offset >= 348 && (offset as f32 - hdr.vox_offset).abs() < 1e-3 && offset % 4 == 0;
    is_nii_single && is_f32 && native_endian && trivial_scale && aligned_offset
}

pub fn load_bold_volume(path: &Path) -> Result<BoldVolume> {
    let hdr = NiftiHeader::from_file(path)
        .with_context(|| format!("Failed to read NIfTI header from {}", path.display()))?;
    let mut info = inspect_nifti_header(path)?;
    let [nx, ny, nz, nt] = info.dims;
    let expected_elems = nx
        .checked_mul(ny)
        .and_then(|v| v.checked_mul(nz))
        .and_then(|v| v.checked_mul(nt))
        .context("NIfTI dimensions overflow")?;

    if can_mmap_f32(path, &hdr) {
        let file = File::open(path)?;
        let mmap = unsafe { Mmap::map(&file)? };
        let offset = hdr.vox_offset as usize;
        let needed_bytes = offset + expected_elems * std::mem::size_of::<f32>();
        if mmap.len() >= needed_bytes {
            let ptr = unsafe { mmap.as_ptr().add(offset) };
            if (ptr as usize) % std::mem::align_of::<f32>() == 0 {
                info.used_mmap = true;
                return Ok(BoldVolume::MmapF32 {
                    _mmap: mmap,
                    ptr: ptr as *const f32,
                    shape: [nx, ny, nz, nt],
                    header: info,
                });
            }
        }
    }

    let obj = ReaderOptions::new()
        .fix_header(true)
        .read_file(path)
        .with_context(|| format!("Failed to read NIfTI volume from {}", path.display()))?;
    let dyn_arr = obj
        .into_volume()
        .into_ndarray::<f32>()
        .with_context(|| format!("Failed to decode f32 volume from {}", path.display()))?;
    let shape = dyn_arr.shape().to_vec();
    let arr4 = match shape.len() {
        3 => dyn_arr
            .into_dimensionality::<ndarray::Ix3>()?
            .insert_axis(Axis(3)),
        4 => dyn_arr.into_dimensionality::<Ix4>()?,
        n => bail!("Expected 3D or 4D NIfTI volume, got {n}D ({shape:?})"),
    };
    Ok(BoldVolume::OwnedF32 {
        data: arr4,
        header: info,
    })
}

pub fn load_atlas_i32(path: &Path) -> Result<Array3<i32>> {
    let obj = ReaderOptions::new()
        .fix_header(true)
        .read_file(path)
        .with_context(|| format!("Failed to read atlas from {}", path.display()))?;
    let dyn_arr = obj.into_volume().into_ndarray::<i32>()?;
    let arr3 = match dyn_arr.ndim() {
        3 => dyn_arr.into_dimensionality::<ndarray::Ix3>()?,
        4 if dyn_arr.shape()[3] == 1 => dyn_arr
            .into_dimensionality::<Ix4>()?
            .index_axis_move(Axis(3), 0),
        other => bail!("Expected 3D atlas NIfTI, got {other}D"),
    };
    Ok(arr3)
}

pub fn load_mask_u8(path: &Path) -> Result<Array3<u8>> {
    let obj = ReaderOptions::new()
        .fix_header(true)
        .read_file(path)
        .with_context(|| format!("Failed to read mask from {}", path.display()))?;
    let dyn_arr = obj.into_volume().into_ndarray::<f32>()?;
    let arr3 = match dyn_arr.ndim() {
        3 => dyn_arr.into_dimensionality::<ndarray::Ix3>()?,
        4 if dyn_arr.shape()[3] == 1 => dyn_arr
            .into_dimensionality::<Ix4>()?
            .index_axis_move(Axis(3), 0),
        other => bail!("Expected 3D mask NIfTI, got {other}D"),
    };
    Ok(arr3.mapv(|v| if v > 0.5 { 1 } else { 0 }))
}

pub fn render_ortho_slice_rgba(
    vol: ArrayView4<'_, f32>,
    plane: OrthoPlane,
    slice_idx: usize,
    timepoint: usize,
) -> Result<RenderedSlice> {
    let shape = vol.shape();
    let (nx, ny, nz, nt) = (shape[0], shape[1], shape[2], shape[3]);
    if timepoint >= nt {
        bail!("timepoint {timepoint} out of range (0..{nt})");
    }
    let vol3 = vol.index_axis(Axis(3), timepoint);

    let (width, height, values): (usize, usize, Vec<f32>) = match plane {
        OrthoPlane::Axial => {
            if slice_idx >= nz {
                bail!("axial slice {slice_idx} out of range (0..{nz})");
            }
            let mut vals = Vec::with_capacity(nx * ny);
            // Display superior/anterior up by flipping Y row order.
            for y in (0..ny).rev() {
                for x in 0..nx {
                    vals.push(vol3[[x, y, slice_idx]]);
                }
            }
            (nx, ny, vals)
        }
        OrthoPlane::Coronal => {
            if slice_idx >= ny {
                bail!("coronal slice {slice_idx} out of range (0..{ny})");
            }
            let mut vals = Vec::with_capacity(nx * nz);
            for z in (0..nz).rev() {
                for x in 0..nx {
                    vals.push(vol3[[x, slice_idx, z]]);
                }
            }
            (nx, nz, vals)
        }
        OrthoPlane::Sagittal => {
            if slice_idx >= nx {
                bail!("sagittal slice {slice_idx} out of range (0..{nx})");
            }
            let mut vals = Vec::with_capacity(ny * nz);
            for z in (0..nz).rev() {
                for y in 0..ny {
                    vals.push(vol3[[slice_idx, y, z]]);
                }
            }
            (ny, nz, vals)
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

    let scale = 255.0 / (p_high - p_low);
    let mut rgba = Vec::with_capacity(width * height * 4);
    for v in values {
        let g = if v.is_finite() {
            ((v - p_low) * scale).clamp(0.0, 255.0).round() as u8
        } else {
            0
        };
        rgba.extend_from_slice(&[g, g, g, 255]);
    }

    Ok(RenderedSlice {
        width,
        height,
        rgba,
        min_val: p_low,
        max_val: p_high,
    })
}
