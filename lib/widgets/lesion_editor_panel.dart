import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;

class LesionEditorPanel extends StatefulWidget {
  const LesionEditorPanel({super.key});

  @override
  State<LesionEditorPanel> createState() => _LesionEditorPanelState();
}

class _LesionEditorPanelState extends State<LesionEditorPanel> {
  final _t1Controller = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/t1w_mni.nii.gz',
  );
  final _flairController = TextEditingController();
  final _maskController = TextEditingController(
    text: 'data_test_output/patient01_pre/lesion_test/edited_lesion.nii',
  );

  String _toolMode = 'wand'; // 'navigate', 'wand', 'brush', 'erase'
  double _zThreshold = 2.5;
  double _wandTolerance = 35.0;
  double _brushRadius = 2.0;
  double _overlayAlpha = 0.40;

  List<int> _dims = [99, 117, 95];
  int _cx = 49;
  int _cy = 58;
  int _cz = 47;

  ui.Image? _axialImg;
  ui.Image? _coronalImg;
  ui.Image? _sagittalImg;
  rust_api.LesionSummaryDto? _lesionSummary;
  String _status = 'Load a T1w volume to auto-segment or manually polish a 3D lesion mask.';
  bool _busy = false;

  @override
  void dispose() {
    _t1Controller.dispose();
    _flairController.dispose();
    _maskController.dispose();
    _axialImg?.dispose();
    _coronalImg?.dispose();
    _sagittalImg?.dispose();
    super.dispose();
  }

  Future<ui.Image> _decodeSlice(rust_api.SliceRgba slice) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      slice.rgba,
      slice.width,
      slice.height,
      ui.PixelFormat.rgba8888,
      c.complete,
    );
    return c.future;
  }

  Future<void> _loadAndRefreshOrtho() async {
    setState(() {
      _busy = true;
      _status = 'Inspecting T1w & rendering synchronized orthogonal slices...';
    });
    try {
      final t1Path = _t1Controller.text.trim();
      final hdr = await rust_api.inspectNifti(path: t1Path);
      final nx = hdr.dims.isNotEmpty ? hdr.dims[0] : 99;
      final ny = hdr.dims.length > 1 ? hdr.dims[1] : 117;
      final nz = hdr.dims.length > 2 ? hdr.dims[2] : 95;
      _dims = [nx, ny, nz];
      _cx = _cx.clamp(0, nx - 1);
      _cy = _cy.clamp(0, ny - 1);
      _cz = _cz.clamp(0, nz - 1);
      await _refreshSlices();
      if (!mounted) return;
      setState(() {
        _status = 'Ortho views ready ($nx x $ny x $nz). Tool: $_toolMode.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshSlices() async {
    final t1Path = _t1Controller.text.trim();
    final maskPath = _maskController.text.trim();
    final slices = await Future.wait([
      rust_api.renderSliceWithLesionRgba(
        path: t1Path,
        lesionMaskPath: maskPath,
        plane: 'axial',
        sliceIndex: _cz,
        timepoint: 0,
        overlayAlpha: _overlayAlpha,
      ),
      rust_api.renderSliceWithLesionRgba(
        path: t1Path,
        lesionMaskPath: maskPath,
        plane: 'coronal',
        sliceIndex: _cy,
        timepoint: 0,
        overlayAlpha: _overlayAlpha,
      ),
      rust_api.renderSliceWithLesionRgba(
        path: t1Path,
        lesionMaskPath: maskPath,
        plane: 'sagittal',
        sliceIndex: _cx,
        timepoint: 0,
        overlayAlpha: _overlayAlpha,
      ),
    ]);
    final imgs = await Future.wait(slices.map(_decodeSlice));
    if (!mounted) {
      for (final img in imgs) {
        img.dispose();
      }
      return;
    }
    setState(() {
      _axialImg?.dispose();
      _coronalImg?.dispose();
      _sagittalImg?.dispose();
      _axialImg = imgs[0];
      _coronalImg = imgs[1];
      _sagittalImg = imgs[2];
    });
  }

  Future<void> _autoSegment() async {
    setState(() {
      _busy = true;
      _status = 'Computing hemispheric asymmetry lesion segmentation...';
    });
    try {
      final flair = _flairController.text.trim();
      final summary = await rust_api.autoSegmentLesionAsymmetry(
        t1Path: _t1Controller.text.trim(),
        flairPath: flair.isEmpty ? null : flair,
        zThreshold: _zThreshold,
        outMaskPath: _maskController.text.trim(),
      );
      await _loadAndRefreshOrtho();
      if (!mounted) return;
      setState(() {
        _lesionSummary = summary;
        _status =
            'Auto-segmented ${summary.voxelCount} voxels (${summary.volumeMl.toStringAsFixed(2)} mL, ${summary.dominantHemisphere}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Auto-segmentation error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyMorphology(String op, int param, String label) async {
    setState(() {
      _busy = true;
      _status = 'Applying morphological $label...';
    });
    try {
      final maskPath = _maskController.text.trim();
      final summary = await rust_api.morphologyLesionMask(
        maskPath: maskPath,
        refNiftiPath: _t1Controller.text.trim(),
        operation: op,
        param: param,
        outMaskPath: maskPath,
      );
      await _refreshSlices();
      if (!mounted) return;
      setState(() {
        _lesionSummary = summary;
        _status =
            '$label complete: ${summary.voxelCount} voxels (${summary.volumeMl.toStringAsFixed(2)} mL).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Morphology error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onViewportTap(
    String plane,
    Offset localPos,
    Size boxSize,
    ui.Image img,
  ) async {
    if (_busy) return;
    final imgAspect = img.width / img.height;
    final boxAspect = boxSize.width / boxSize.height;
    double drawW;
    double drawH;
    double offX = 0;
    double offY = 0;
    if (boxAspect > imgAspect) {
      drawH = boxSize.height;
      drawW = drawH * imgAspect;
      offX = (boxSize.width - drawW) * 0.5;
    } else {
      drawW = boxSize.width;
      drawH = drawW / imgAspect;
      offY = (boxSize.height - drawH) * 0.5;
    }
    final normX = ((localPos.dx - offX) / drawW).clamp(0.0, 0.9999);
    final normY = ((localPos.dy - offY) / drawH).clamp(0.0, 0.9999);
    final px = (normX * img.width).floor();
    final py = (normY * img.height).floor();

    int vx = _cx;
    int vy = _cy;
    int vz = _cz;
    // Match Rust render_ortho_slice_with_lesion_rgba flipped row convention.
    switch (plane) {
      case 'axial':
        vx = px.clamp(0, _dims[0] - 1);
        vy = (_dims[1] - 1 - py).clamp(0, _dims[1] - 1);
      case 'coronal':
        vx = px.clamp(0, _dims[0] - 1);
        vz = (_dims[2] - 1 - py).clamp(0, _dims[2] - 1);
      case 'sagittal':
        vy = px.clamp(0, _dims[1] - 1);
        vz = (_dims[2] - 1 - py).clamp(0, _dims[2] - 1);
    }

    setState(() {
      _cx = vx;
      _cy = vy;
      _cz = vz;
    });

    if (_toolMode == 'navigate') {
      await _refreshSlices();
      setState(() => _status = 'Crosshair -> ($vx, $vy, $vz)');
      return;
    }

    setState(() => _busy = true);
    try {
      final maskPath = _maskController.text.trim();
      final t1Path = _t1Controller.text.trim();
      late final rust_api.LesionSummaryDto summary;
      if (_toolMode == 'wand') {
        summary = await rust_api.editLesionMaskMagicWand(
          t1Path: t1Path,
          maskPath: maskPath,
          seedX: vx,
          seedY: vy,
          seedZ: vz,
          tolerance: _wandTolerance,
          outMaskPath: maskPath,
        );
      } else {
        summary = await rust_api.editLesionMaskBrush(
          maskPath: maskPath,
          refNiftiPath: t1Path,
          cx: vx,
          cy: vy,
          cz: vz,
          radiusVoxels: _brushRadius,
          erase: _toolMode == 'erase',
          slicePlaneOnly: null,
          outMaskPath: maskPath,
        );
      }
      await _refreshSlices();
      if (!mounted) return;
      setState(() {
        _lesionSummary = summary;
        _status =
            'Applied $_toolMode at ($vx, $vy, $vz): ${summary.voxelCount} voxels (${summary.volumeMl.toStringAsFixed(2)} mL, ${summary.dominantHemisphere}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Mask edit error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildViewport(String title, String plane, ui.Image? img) {
    return Expanded(
      child: Card(
        color: const Color(0xFF0B1120),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (img == null) {
                      return const Center(
                        child: Text(
                          'No slice loaded',
                          style: TextStyle(color: Color(0xFF64748B)),
                        ),
                      );
                    }
                    return GestureDetector(
                      onTapDown: (d) => _onViewportTap(
                        plane,
                        d.localPosition,
                        constraints.biggest,
                        img,
                      ),
                      child: SizedBox.expand(
                        child: RawImage(
                          image: img,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.none,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 390,
            child: SingleChildScrollView(
              child: Card(
                color: const Color(0xFF1E293B),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'TBI / Stroke Lesion Mask Editor',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _t1Controller,
                        decoration: const InputDecoration(
                          labelText: 'T1w Volume (.nii / .nii.gz)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _flairController,
                        decoration: const InputDecoration(
                          labelText: 'Optional FLAIR / T2w Volume',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _maskController,
                        decoration: const InputDecoration(
                          labelText: 'Output / Editable Lesion Mask (.nii)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _loadAndRefreshOrtho,
                              icon: const Icon(Icons.layers),
                              label: const Text('Load Views'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _autoSegment,
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text('Auto-Segment'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text('Asymmetry Z-Threshold: ${_zThreshold.toStringAsFixed(1)}'),
                      Slider(
                        value: _zThreshold,
                        min: 1.5,
                        max: 4.5,
                        divisions: 30,
                        onChanged: (v) => setState(() => _zThreshold = v),
                      ),
                      const Divider(),
                      const Text(
                        'Interactive Brush & Magic Wand Tool',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'navigate', label: Text('Cross')),
                          ButtonSegment(value: 'wand', label: Text('Wand')),
                          ButtonSegment(value: 'brush', label: Text('Brush')),
                          ButtonSegment(value: 'erase', label: Text('Erase')),
                        ],
                        selected: {_toolMode},
                        onSelectionChanged: (s) => setState(() => _toolMode = s.first),
                      ),
                      const SizedBox(height: 8),
                      Text('Magic Wand Tolerance: ${_wandTolerance.toStringAsFixed(0)}'),
                      Slider(
                        value: _wandTolerance,
                        min: 5,
                        max: 250,
                        onChanged: (v) => setState(() => _wandTolerance = v),
                      ),
                      Text('3D Brush Radius (vox): ${_brushRadius.toStringAsFixed(1)}'),
                      Slider(
                        value: _brushRadius,
                        min: 1.0,
                        max: 6.0,
                        divisions: 10,
                        onChanged: (v) => setState(() => _brushRadius = v),
                      ),
                      Text('Overlay Alpha: ${(_overlayAlpha * 100).round()}%'),
                      Slider(
                        value: _overlayAlpha,
                        min: 0.0,
                        max: 0.9,
                        onChanged: (v) => setState(() => _overlayAlpha = v),
                        onChangeEnd: (_) {
                          if (!_busy && _axialImg != null) _refreshSlices();
                        },
                      ),
                      const Divider(),
                      const Text(
                        'Morphological Cleanup',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _applyMorphology('fill_holes', 0, 'Fill Holes'),
                            child: const Text('Fill Holes'),
                          ),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _applyMorphology(
                                    'remove_islands', 10, 'Remove Islands (<10)'),
                            child: const Text('Remove Islands <10'),
                          ),
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _applyMorphology('dilate', 1, 'Dilate Rim (+1 vox)'),
                            child: const Text('Dilate +1 Vox'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_lesionSummary != null)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Voxels: ${_lesionSummary!.voxelCount} | '
                            'Volume: ${_lesionSummary!.volumeMl.toStringAsFixed(2)} mL\n'
                            'Hemisphere: ${_lesionSummary!.dominantHemisphere} '
                            '(L=${_lesionSummary!.leftVoxels}, R=${_lesionSummary!.rightVoxels})',
                            style: const TextStyle(color: Color(0xFF2DD4BF)),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(_status, style: const TextStyle(color: Color(0xFF94A3B8))),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _buildViewport('Axial (Z=$_cz)', 'axial', _axialImg),
                      _buildViewport('Coronal (Y=$_cy)', 'coronal', _coronalImg),
                      _buildViewport('Sagittal (X=$_cx)', 'sagittal', _sagittalImg),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: const Color(0xFF1E293B),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Text('Z: $_cz'),
                        Expanded(
                          child: Slider(
                            value: _cz.toDouble().clamp(0, (_dims[2] - 1).toDouble()),
                            min: 0,
                            max: (_dims[2] - 1).toDouble().clamp(1, 512),
                            onChanged: (v) => setState(() => _cz = v.round()),
                            onChangeEnd: (_) {
                              if (_axialImg != null) _refreshSlices();
                            },
                          ),
                        ),
                        Text('Y: $_cy'),
                        Expanded(
                          child: Slider(
                            value: _cy.toDouble().clamp(0, (_dims[1] - 1).toDouble()),
                            min: 0,
                            max: (_dims[1] - 1).toDouble().clamp(1, 512),
                            onChanged: (v) => setState(() => _cy = v.round()),
                            onChangeEnd: (_) {
                              if (_coronalImg != null) _refreshSlices();
                            },
                          ),
                        ),
                        Text('X: $_cx'),
                        Expanded(
                          child: Slider(
                            value: _cx.toDouble().clamp(0, (_dims[0] - 1).toDouble()),
                            min: 0,
                            max: (_dims[0] - 1).toDouble().clamp(1, 512),
                            onChanged: (v) => setState(() => _cx = v.round()),
                            onChangeEnd: (_) {
                              if (_sagittalImg != null) _refreshSlices();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
