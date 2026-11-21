import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:ccs_fmri_studio/src/rust/frb_generated.dart';
import 'package:ccs_fmri_studio/src/rust_loader.dart';
import 'package:ccs_fmri_studio/widgets/lesion_editor_panel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final lib = openBundledRustLibrary();
    await RustLib.init(externalLibrary: lib);
  } catch (_) {
    // Allow UI launch even if the native dylib is not yet present on PATH.
  }
  runApp(const CcsFmriStudioApp());
}

class CcsFmriStudioApp extends StatelessWidget {
  const CcsFmriStudioApp({super.key, this.enableRustProbe = true});

  final bool enableRustProbe;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CCS_fMRIStudio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2DD4BF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
      ),
      home: FmriWorkspacePage(enableRustProbe: enableRustProbe),
    );
  }
}

class FmriWorkspacePage extends StatefulWidget {
  const FmriWorkspacePage({super.key, this.enableRustProbe = true});

  final bool enableRustProbe;

  @override
  State<FmriWorkspacePage> createState() => _FmriWorkspacePageState();
}

class _FmriWorkspacePageState extends State<FmriWorkspacePage> {
  final _niftiPathController = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/bold_mni.nii',
  );
  final _atlasPathController = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/schaefer400_mni.nii.gz',
  );
  final _labelsPathController = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/schaefer400_labels.json',
  );
  final _wmPathController = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/wm_mask_mni.nii.gz',
  );
  final _csfPathController = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/csf_mask_mni.nii.gz',
  );
  final _confoundsPathController = TextEditingController(
    text: 'data_test_output/patient01_pre/preproc/confounds.tsv',
  );
  final _lesionMaskPathController = TextEditingController();

  rust_api.EngineInfo? _engineInfo;
  String? _engineError;
  rust_api.NiftiHeaderSummary? _headerSummary;
  rust_api.LesionPipelineSummary? _pipelineSummary;
  ui.Image? _sliceImage;
  String _plane = 'axial';
  int _sliceIndex = 47;
  int _timepoint = 0;
  double _maxDamagePct = 50.0;
  String? _actionStatus;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.enableRustProbe) {
      _probeEngine();
    }
  }

  @override
  void dispose() {
    _niftiPathController.dispose();
    _atlasPathController.dispose();
    _labelsPathController.dispose();
    _wmPathController.dispose();
    _csfPathController.dispose();
    _confoundsPathController.dispose();
    _lesionMaskPathController.dispose();
    _sliceImage?.dispose();
    super.dispose();
  }

  Future<void> _probeEngine() async {
    try {
      final info = await rust_api.engineInfo();
      if (!mounted) return;
      setState(() {
        _engineInfo = info;
        _engineError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _engineError = e.toString();
      });
    }
  }

  Future<void> _inspectAndRender() async {
    setState(() {
      _busy = true;
      _actionStatus = 'Inspecting NIfTI header & rendering slice...';
    });
    try {
      final path = _niftiPathController.text.trim();
      final hdr = await rust_api.inspectNifti(path: path);
      final clampedSlice = _clampSliceForPlane(hdr, _plane, _sliceIndex);
      final clampedTp = hdr.dims.length >= 4 && hdr.dims[3] > 0
          ? _timepoint.clamp(0, hdr.dims[3] - 1)
          : 0;
      final lesionPath = _lesionMaskPathController.text.trim();
      final slice = await rust_api.renderSliceWithLesionRgba(
        path: path,
        lesionMaskPath: lesionPath.isEmpty ? null : lesionPath,
        plane: _plane,
        sliceIndex: clampedSlice,
        timepoint: clampedTp,
        overlayAlpha: 0.40,
      );
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        slice.rgba,
        slice.width,
        slice.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final decoded = await completer.future;
      if (!mounted) {
        decoded.dispose();
        return;
      }
      setState(() {
        _headerSummary = hdr;
        _sliceIndex = clampedSlice;
        _timepoint = clampedTp;
        _sliceImage?.dispose();
        _sliceImage = decoded;
        _actionStatus =
            'Rendered $_plane slice $clampedSlice (t=$clampedTp, ${slice.width}x${slice.height})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _actionStatus = 'Error: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  int _clampSliceForPlane(
    rust_api.NiftiHeaderSummary hdr,
    String plane,
    int current,
  ) {
    final idx = switch (plane) {
      'sagittal' => 0,
      'coronal' => 1,
      _ => 2,
    };
    final maxDim = idx < hdr.dims.length && hdr.dims[idx] > 0
        ? hdr.dims[idx] - 1
        : 0;
    return current.clamp(0, maxDim);
  }

  Future<void> _runPipeline() async {
    setState(() {
      _busy = true;
      _actionStatus = 'Running lesion-aware Rust parcellation + simultaneous denoising...';
    });
    try {
      final lesionPath = _lesionMaskPathController.text.trim();
      final labelsPath = _labelsPathController.text.trim();
      final summary = await rust_api.runLesionAwarePipeline(
        boldPath: _niftiPathController.text.trim(),
        atlasPath: _atlasPathController.text.trim(),
        lesionMaskPath: lesionPath.isEmpty ? null : lesionPath,
        atlasLabelsJsonPath: labelsPath.isEmpty ? null : labelsPath,
        wmMaskPath: _wmPathController.text.trim().isEmpty
            ? null
            : _wmPathController.text.trim(),
        csfMaskPath: _csfPathController.text.trim().isEmpty
            ? null
            : _csfPathController.text.trim(),
        confoundsTsvPath: _confoundsPathController.text.trim().isEmpty
            ? null
            : _confoundsPathController.text.trim(),
        lowHz: 0.008,
        highHz: 0.09,
        fdThresholdMm: 0.5,
        maxDamagePct: _maxDamagePct,
        lesionDilateVoxels: 1,
      );
      if (!mounted) return;
      setState(() {
        _pipelineSummary = summary;
        _actionStatus =
            'Completed ${summary.nIntactRois}/${summary.nRois} intact ROIs in ${summary.totalMs.toStringAsFixed(1)} ms';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _actionStatus = 'Pipeline error: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('CCS_fMRIStudio — Hybrid Rust + ANTsPy Workbench'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.analytics), text: 'Denoising & Connectivity'),
              Tab(icon: Icon(Icons.brush), text: 'TBI / Stroke Lesion Editor'),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Chip(
                  avatar: Icon(
                    _engineInfo != null ? Icons.bolt : Icons.memory,
                    size: 16,
                    color: _engineInfo != null
                        ? const Color(0xFF2DD4BF)
                        : Colors.amber,
                  ),
                  label: Text(
                    _engineInfo != null
                        ? 'Rust v${_engineInfo!.version} (${_engineInfo!.simdThreads} threads)'
                        : (_engineError != null
                            ? 'Rust FFI Standby'
                            : 'Hybrid Architecture'),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _buildDenoiseTab(context),
            const LesionEditorPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildDenoiseTab(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCard(
                    title: '1. NIfTI Volume & Header Inspector',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _niftiPathController,
                          decoration: const InputDecoration(
                            labelText: '4D BOLD NIfTI Path (.nii / .nii.gz)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            DropdownButton<String>(
                              value: _plane,
                              items: const [
                                DropdownMenuItem(
                                  value: 'axial',
                                  child: Text('Axial (Z)'),
                                ),
                                DropdownMenuItem(
                                  value: 'coronal',
                                  child: Text('Coronal (Y)'),
                                ),
                                DropdownMenuItem(
                                  value: 'sagittal',
                                  child: Text('Sagittal (X)'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v != null) setState(() => _plane = v);
                              },
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy ? null : _inspectAndRender,
                                icon: const Icon(Icons.visibility),
                                label: const Text('Inspect & Render Slice'),
                              ),
                            ),
                          ],
                        ),
                        if (_headerSummary != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Dims: ${_headerSummary!.dims.join(" x ")} | '
                            'Voxel: ${_headerSummary!.voxelSizes.map((v) => v.toStringAsFixed(2)).join(" x ")} mm | '
                            'TR: ${_headerSummary!.trSec.toStringAsFixed(2)} s',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildCard(
                    title: '2. Lesion-Aware Rust Denoising & Connectivity',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _atlasPathController,
                          decoration: const InputDecoration(
                            labelText: 'Atlas NIfTI Path (Schaefer-400 MNI)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _labelsPathController,
                          decoration: const InputDecoration(
                            labelText: 'Atlas Labels JSON (Homotopic Pairing)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _lesionMaskPathController,
                          decoration: const InputDecoration(
                            labelText: 'Optional Normalized Lesion Mask (.nii/.nii.gz)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _wmPathController,
                          decoration: const InputDecoration(
                            labelText: 'WM Mask Path (aCompCor)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _csfPathController,
                          decoration: const InputDecoration(
                            labelText: 'CSF Mask Path (aCompCor)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _confoundsPathController,
                          decoration: const InputDecoration(
                            labelText: 'Confounds TSV Path (Motion + FD)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text('Max ROI % Damage Threshold: ${_maxDamagePct.toStringAsFixed(0)}%'),
                        Slider(
                          value: _maxDamagePct,
                          min: 10,
                          max: 100,
                          divisions: 18,
                          onChanged: (v) => setState(() => _maxDamagePct = v),
                        ),
                        const SizedBox(height: 6),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runPipeline,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Run Lesion-Aware Denoising & Biomarkers'),
                        ),
                        if (_pipelineSummary != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Intact ROIs: ${_pipelineSummary!.nIntactRois}/${_pipelineSummary!.nRois} '
                            '(Excluded: ${_pipelineSummary!.nExcludedRois}) | '
                            'mmap: ${_pipelineSummary!.usedMmap}\n'
                            'Lesion: ${_pipelineSummary!.lesionVolumeMl.toStringAsFixed(2)} mL '
                            '(${_pipelineSummary!.dominantHemisphere}) | '
                            'Time: ${_pipelineSummary!.totalMs.toStringAsFixed(1)} ms\n'
                            'Global Efficiency: ${_pipelineSummary!.globalEfficiency.toStringAsFixed(4)} | '
                            'Mean Strength: ${_pipelineSummary!.meanNodeStrength.toStringAsFixed(2)}\n'
                            'Homotopic FC: ${_pipelineSummary!.meanHomotopicFc.toStringAsFixed(4)} | '
                            'Laterality: ${_pipelineSummary!.lateralityIndex.toStringAsFixed(4)} | '
                            'Seed |r|: ${_pipelineSummary!.lesionSeedMeanAbsR.toStringAsFixed(4)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_actionStatus != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _actionStatus!,
                      style: const TextStyle(color: Color(0xFF94A3B8)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: _buildCard(
              title: 'Zero-Copy RGBA Slice Viewport',
              child: Center(
                child: _sliceImage != null
                    ? RawImage(
                        image: _sliceImage,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.none,
                      )
                    : const Text(
                        'Load a 3D/4D NIfTI volume to inspect header\n'
                        'and render zero-copy RGBA slices from Rust.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF94A3B8)),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required String title, required Widget child}) {
    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
