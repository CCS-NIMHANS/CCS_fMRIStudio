import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:ccs_fmri_studio/src/rust/frb_generated.dart';
import 'package:ccs_fmri_studio/src/rust_loader.dart';
import 'package:ccs_fmri_studio/src/session_state.dart';
import 'package:ccs_fmri_studio/src/update_checker.dart';
import 'package:ccs_fmri_studio/widgets/lesion_editor_panel.dart';
import 'package:ccs_fmri_studio/widgets/path_picker_field.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    FilePicker.skipEntitlementsChecks();
  }
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
      title: 'CCS fMRI Studio',
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
  final FmriSessionState _session = FmriSessionState();
  int _stepIndex = 0;

  // Step 1 controllers
  final _t1DicomCtrl = TextEditingController();
  final _boldDicomCtrl = TextEditingController();
  final _dicomOutCtrl = TextEditingController();
  final _inspectNiftiCtrl = TextEditingController();

  // Step 2 controllers
  final _rawT1Ctrl = TextEditingController();
  final _rawBoldCtrl = TextEditingController();
  final _preprocOutCtrl = TextEditingController();
  final _preprocLesionCtrl = TextEditingController();
  final _customTemplateCtrl = TextEditingController();
  String _templateId = 'mni152_adult';
  String _transform = 'SyNQuick';
  String _lesionMode = 'none';

  // Step 4 controllers
  final _boldMniCtrl = TextEditingController();
  final _atlasCtrl = TextEditingController();
  final _labelsCtrl = TextEditingController();
  final _wmCtrl = TextEditingController();
  final _csfCtrl = TextEditingController();
  final _confoundsCtrl = TextEditingController();
  final _lesionMaskCtrl = TextEditingController();

  rust_api.EngineInfo? _engineInfo;
  String? _engineError;
  bool _checkingUpdates = false;
  bool _busy = false;
  String _statusMessage =
      'Start in Step 1: open a preprocessed folder, pick NIfTI files, or convert DICOMs.';
  final List<String> _sidecarLog = [];
  List<String> _detectedItems = [];

  rust_api.NiftiHeaderSummary? _headerSummary;
  rust_api.LesionPipelineSummary? _pipelineSummary;
  ui.Image? _sliceImage;
  String _plane = 'axial';
  int _sliceIndex = 47;
  int _maxSlice = 94;
  int _timepoint = 0;
  int _maxTimepoint = 0;
  final double _lowHz = 0.008;
  double _highHz = 0.09;
  double _fdThresholdMm = 0.5;
  double _maxDamagePct = 50.0;

  @override
  void initState() {
    super.initState();
    _session.addListener(_syncControllersFromSession);
    if (widget.enableRustProbe) {
      _probeEngine();
    }
  }

  void _syncControllersFromSession() {
    void sync(TextEditingController ctrl, String value) {
      if (value.isNotEmpty && ctrl.text != value) {
        ctrl.text = value;
      }
    }

    sync(_rawT1Ctrl, _session.rawT1Path);
    sync(_rawBoldCtrl, _session.rawBoldPath);
    sync(_preprocOutCtrl, _session.preprocOutDir);
    sync(_preprocLesionCtrl, _session.lesionMaskPath);
    sync(_boldMniCtrl, _session.boldMniPath);
    sync(_atlasCtrl, _session.atlasPath);
    sync(_labelsCtrl, _session.labelsJsonPath);
    sync(_wmCtrl, _session.wmMaskPath);
    sync(_csfCtrl, _session.csfMaskPath);
    sync(_confoundsCtrl, _session.confoundsPath);
    sync(_lesionMaskCtrl, _session.lesionMaskPath);
    if (_inspectNiftiCtrl.text.isEmpty) {
      final candidate = _session.boldMniPath.isNotEmpty
          ? _session.boldMniPath
          : _session.rawBoldPath;
      if (candidate.isNotEmpty) _inspectNiftiCtrl.text = candidate;
    }
  }

  @override
  void dispose() {
    _session.removeListener(_syncControllersFromSession);
    _session.dispose();
    _t1DicomCtrl.dispose();
    _boldDicomCtrl.dispose();
    _dicomOutCtrl.dispose();
    _inspectNiftiCtrl.dispose();
    _rawT1Ctrl.dispose();
    _rawBoldCtrl.dispose();
    _preprocOutCtrl.dispose();
    _preprocLesionCtrl.dispose();
    _customTemplateCtrl.dispose();
    _boldMniCtrl.dispose();
    _atlasCtrl.dispose();
    _labelsCtrl.dispose();
    _wmCtrl.dispose();
    _csfCtrl.dispose();
    _confoundsCtrl.dispose();
    _lesionMaskCtrl.dispose();
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
      setState(() => _engineError = e.toString());
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);
    try {
      final info = await UpdateChecker.check();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AppUpdateDialog(info: info),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update check failed: $e')));
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  Future<void> _openPreprocessedFolder({bool jumpToDenoise = false}) async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Subject Folder (Raw or Preprocessed)',
    );
    if (folder == null || folder.isEmpty) return;
    final found = _session.autoPopulateFromFolder(folder);
    setState(() {
      _detectedItems = found;
      if (found.isEmpty) {
        _statusMessage =
            'No standard NIfTI outputs found in $folder. You can still Browse individual files.';
      } else {
        _statusMessage =
            'Loaded ${found.length} files from $folder: ${found.join(', ')}';
        if (jumpToDenoise && _session.boldMniPath.isNotEmpty) {
          _stepIndex = 3;
        }
      }
    });
    if (_session.boldMniPath.isNotEmpty) {
      await _inspectAndRender(_session.boldMniPath);
    } else if (_session.rawBoldPath.isNotEmpty) {
      await _inspectAndRender(_session.rawBoldPath);
    }
  }

  Future<void> _runDicomConvert() async {
    final t1Dir = _t1DicomCtrl.text.trim();
    final boldDir = _boldDicomCtrl.text.trim();
    var outDir = _dicomOutCtrl.text.trim();
    if (t1Dir.isEmpty || boldDir.isEmpty) {
      setState(
        () => _statusMessage = 'Select both T1w and BOLD DICOM folders first.',
      );
      return;
    }
    if (outDir.isEmpty) {
      outDir = '${Directory(t1Dir).parent.path}${Platform.pathSeparator}raw_nifti';
      _dicomOutCtrl.text = outDir;
    }
    setState(() {
      _busy = true;
      _sidecarLog.clear();
      _statusMessage = 'Converting DICOMs with dcm2niix…';
    });
    try {
      final code = await _session.runSidecarModule(
        module: 'ccs_fmri_sidecar.dicom_convert',
        args: ['--t1-dicom', t1Dir, '--bold-dicom', boldDir, '--out', outDir],
        onLog: (line) {
          if (!mounted) return;
          setState(() => _sidecarLog.add(line));
        },
      );
      if (code == 0) {
        final found = _session.autoPopulateFromFolder(outDir);
        setState(() {
          _detectedItems = found;
          _preprocOutCtrl.text =
              '${Directory(outDir).parent.path}${Platform.pathSeparator}preproc';
          _statusMessage =
              'DICOM conversion succeeded. Ready for Step 2 (Preprocess).';
        });
      } else {
        setState(
          () => _statusMessage = 'DICOM conversion failed (exit $code). See log.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runPreprocessing() async {
    final t1Path = _rawT1Ctrl.text.trim();
    final boldPath = _rawBoldCtrl.text.trim();
    var outDir = _preprocOutCtrl.text.trim();
    if (t1Path.isEmpty || boldPath.isEmpty) {
      setState(
        () => _statusMessage = 'Select Raw T1w and Raw 4D BOLD NIfTI files first.',
      );
      return;
    }
    if (outDir.isEmpty) {
      outDir = '${File(boldPath).parent.path}${Platform.pathSeparator}preproc';
      _preprocOutCtrl.text = outDir;
    }
    setState(() {
      _busy = true;
      _sidecarLog.clear();
      _statusMessage = 'Running ANTsPy preprocessing ($_templateId, $_lesionMode)…';
    });
    final args = <String>[
      '--t1',
      t1Path,
      '--bold',
      boldPath,
      '--out',
      outDir,
      '--transform',
      _transform,
      '--template',
      _templateId,
      '--lesion-mode',
      _lesionMode,
    ];
    if (_customTemplateCtrl.text.trim().isNotEmpty) {
      args.addAll(['--custom-template', _customTemplateCtrl.text.trim()]);
    }
    if (_preprocLesionCtrl.text.trim().isNotEmpty) {
      args.addAll(['--lesion-mask', _preprocLesionCtrl.text.trim()]);
    }

    try {
      final code = await _session.runSidecarModule(
        module: 'ccs_fmri_sidecar.preprocess',
        args: args,
        onLog: (line) {
          if (!mounted) return;
          setState(() => _sidecarLog.add(line));
        },
      );
      if (code == 0) {
        final found = _session.autoPopulateFromFolder(outDir);
        setState(() {
          _detectedItems = found;
          _statusMessage =
              'ANTsPy preprocessing complete! Outputs auto-loaded into Steps 3 & 4.';
        });
      } else {
        setState(
          () => _statusMessage = 'Preprocessing failed (exit $code). See log.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspectAndRender([String? explicitPath]) async {
    final path = (explicitPath ?? _boldMniCtrl.text).trim();
    if (path.isEmpty) {
      setState(
        () => _statusMessage = 'Select a NIfTI file via Browse or Open Folder first.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = 'Inspecting header & rendering slice…';
    });
    try {
      final hdr = await rust_api.inspectNifti(path: path);
      final maxS = _maxSliceForPlane(hdr, _plane);
      final clampedSlice = _sliceIndex.clamp(0, maxS);
      final maxT = hdr.dims.length >= 4 && hdr.dims[3] > 0
          ? hdr.dims[3] - 1
          : 0;
      final clampedTp = _timepoint.clamp(0, maxT);
      final lesionPath = _lesionMaskCtrl.text.trim();
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
        _maxSlice = maxS;
        _sliceIndex = clampedSlice;
        _maxTimepoint = maxT;
        _timepoint = clampedTp;
        _sliceImage?.dispose();
        _sliceImage = decoded;
        _statusMessage =
            'Loaded $path (${hdr.dims.join(" × ")}, TR=${hdr.trSec.toStringAsFixed(2)}s)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _maxSliceForPlane(rust_api.NiftiHeaderSummary hdr, String plane) {
    final idx = switch (plane) {
      'sagittal' => 0,
      'coronal' => 1,
      _ => 2,
    };
    return idx < hdr.dims.length && hdr.dims[idx] > 0 ? hdr.dims[idx] - 1 : 0;
  }

  Future<void> _runPipeline() async {
    final boldPath = _boldMniCtrl.text.trim();
    final atlasPath = _atlasCtrl.text.trim();
    if (boldPath.isEmpty || atlasPath.isEmpty) {
      setState(
        () => _statusMessage =
            'Select a 4D BOLD NIfTI and Atlas NIfTI (or click Open Folder) first.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage =
          'Running lesion-aware Rust parcellation + simultaneous denoising…';
    });
    try {
      final lesionPath = _lesionMaskCtrl.text.trim();
      final labelsPath = _labelsCtrl.text.trim();
      final summary = await rust_api.runLesionAwarePipeline(
        boldPath: boldPath,
        atlasPath: atlasPath,
        lesionMaskPath: lesionPath.isEmpty ? null : lesionPath,
        atlasLabelsJsonPath: labelsPath.isEmpty ? null : labelsPath,
        wmMaskPath: _wmCtrl.text.trim().isEmpty ? null : _wmCtrl.text.trim(),
        csfMaskPath: _csfCtrl.text.trim().isEmpty ? null : _csfCtrl.text.trim(),
        confoundsTsvPath:
            _confoundsCtrl.text.trim().isEmpty ? null : _confoundsCtrl.text.trim(),
        lowHz: _lowHz,
        highHz: _highHz,
        fdThresholdMm: _fdThresholdMm,
        maxDamagePct: _maxDamagePct,
        lesionDilateVoxels: 1,
      );
      if (!mounted) return;
      setState(() {
        _pipelineSummary = summary;
        _statusMessage =
            'Completed ${summary.nIntactRois}/${summary.nRois} intact ROIs in ${summary.totalMs.toStringAsFixed(1)} ms';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Pipeline error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('CCS fMRI Studio'),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : () => _openPreprocessedFolder(jumpToDenoise: false),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Folder'),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: _checkingUpdates ? null : _checkForUpdates,
            icon: _checkingUpdates
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt),
            label: Text(_checkingUpdates ? 'Checking…' : 'Updates'),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 16),
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
                    : (_engineError != null ? 'Rust Standby' : 'Hybrid Engine'),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _stepIndex,
                  backgroundColor: const Color(0xFF111827),
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (idx) =>
                      setState(() => _stepIndex = idx),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.drive_folder_upload_outlined),
                      selectedIcon: Icon(Icons.drive_folder_upload),
                      label: Text('1. Import'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.auto_awesome_outlined),
                      selectedIcon: Icon(Icons.auto_awesome),
                      label: Text('2. Preprocess'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.brush_outlined),
                      selectedIcon: Icon(Icons.brush),
                      label: Text('3. Lesion'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.analytics_outlined),
                      selectedIcon: Icon(Icons.analytics),
                      label: Text('4. Denoise'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1, color: Colors.white12),
                Expanded(
                  child: IndexedStack(
                    index: _stepIndex,
                    children: [
                      _buildStep1Import(context),
                      _buildStep2Preprocess(context),
                      LesionEditorPanel(session: _session),
                      _buildStep4Denoise(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1E293B),
            child: Text(
              _statusMessage,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFFCBD5E1)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep1Import(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCard(
            title: 'Quick Start: Open Subject / Preprocessed Folder',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select a folder containing converted (`t1w`, `bold`) or preprocessed (`bold_mni`, `schaefer400_mni`, `wm_mask_mni`, `csf_mask_mni`, `confounds.tsv`, `lesion_mask_mni`) files to auto-fill every downstream step.',
                  style: TextStyle(color: Color(0xFF94A3B8)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _openPreprocessedFolder(jumpToDenoise: false),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse Subject Folder'),
                    ),
                    if (_session.boldMniPath.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _stepIndex = 3),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Go to Step 4: Denoise & FC'),
                      ),
                    if (_session.rawT1Path.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _stepIndex = 1),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Go to Step 2: Preprocess'),
                      ),
                  ],
                ),
                if (_detectedItems.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _detectedItems
                        .map(
                          (item) => Chip(
                            avatar: const Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Color(0xFF2DD4BF),
                            ),
                            label: Text(item),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildCard(
            title: 'Inspect Any NIfTI File Header (.nii / .nii.gz)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PathPickerField(
                  controller: _inspectNiftiCtrl,
                  label: 'NIfTI Volume Path',
                  hint: 'Browse any 3D T1w or 4D BOLD NIfTI file',
                  onPicked: (p) => _inspectAndRender(p),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _inspectAndRender(_inspectNiftiCtrl.text),
                    icon: const Icon(Icons.info_outline),
                    label: const Text('Inspect Header'),
                  ),
                ),
                if (_headerSummary != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Dims: ${_headerSummary!.dims.join(" × ")} | '
                    'Voxel: ${_headerSummary!.voxelSizes.map((v) => v.toStringAsFixed(2)).join(" × ")} mm | '
                    'TR: ${_headerSummary!.trSec.toStringAsFixed(2)} s | '
                    'Datatype code: ${_headerSummary!.datatypeCode}',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildCard(
            title: 'Convert Raw DICOM Folders (dcm2niix)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PathPickerField(
                  controller: _t1DicomCtrl,
                  label: 'T1w DICOM Folder',
                  mode: PickerMode.pickDirectory,
                ),
                const SizedBox(height: 10),
                PathPickerField(
                  controller: _boldDicomCtrl,
                  label: '4D BOLD DICOM Folder',
                  mode: PickerMode.pickDirectory,
                ),
                const SizedBox(height: 10),
                PathPickerField(
                  controller: _dicomOutCtrl,
                  label: 'Output NIfTI Folder (optional)',
                  hint: 'Defaults to <parent>/raw_nifti',
                  mode: PickerMode.pickDirectory,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _runDicomConvert,
                    icon: const Icon(Icons.transform),
                    label: const Text('Convert DICOMs to NIfTI'),
                  ),
                ),
                if (_sidecarLog.isNotEmpty) _buildLogBox(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2Preprocess(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _buildCard(
        title: 'Step 2: ANTsPy Spatial Normalization & Motion Correction',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PathPickerField(
              controller: _rawT1Ctrl,
              label: 'Raw T1w NIfTI (.nii / .nii.gz)',
              onPicked: (p) {
                _session.rawT1Path = p;
                _session.notifyChanged();
              },
            ),
            const SizedBox(height: 10),
            PathPickerField(
              controller: _rawBoldCtrl,
              label: 'Raw 4D BOLD NIfTI (.nii / .nii.gz)',
              onPicked: (p) {
                _session.rawBoldPath = p;
                _session.notifyChanged();
              },
            ),
            const SizedBox(height: 10),
            PathPickerField(
              controller: _preprocOutCtrl,
              label: 'Preprocessing Output Folder',
              hint: 'Defaults to <BOLD dir>/preproc',
              mode: PickerMode.pickDirectory,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _templateId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Clinical Template Cohort',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'mni152_adult',
                        child: Text(
                          'Adult TBI / MNI152NLin2009cAsym (2mm)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'older_adult_stroke',
                        child: Text(
                          'Older Stroke (Rorden Clinical Toolbox)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'pediatric_nihpd',
                        child: Text(
                          'Pediatric TBI / Stroke (NIHPD)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'acute_ct_stroke',
                        child: Text(
                          'CT-Only Acute Stroke',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _templateId = v);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _transform,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'ANTs Registration',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'SyNQuick',
                        child: Text(
                          'SyNQuick (~2 min)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'SyN',
                        child: Text(
                          'Full SyN (Higher Precision)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _transform = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PathPickerField(
              controller: _customTemplateCtrl,
              label: 'Optional Custom Template NIfTI (overrides bundled)',
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _lesionMode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Lesion-Safe Strategy',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text(
                          'None (Healthy Brain)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'cfm',
                        child: Text(
                          'Cost Function Masking (Bilateral TBI)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'enantiomorphic',
                        child: Text(
                          'Enantiomorphic Healing (Unilateral Stroke)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _lesionMode = v);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: PathPickerField(
                    controller: _preprocLesionCtrl,
                    label: 'Optional Native T1w Lesion Mask',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _runPreprocessing,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run ANTsPy Preprocessing'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _stepIndex = 2),
                  icon: const Icon(Icons.brush),
                  label: const Text('Next: Lesion Editor'),
                ),
              ],
            ),
            if (_sidecarLog.isNotEmpty) _buildLogBox(),
          ],
        ),
      ),
    );
  }

  Widget _buildStep4Denoise(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              child: _buildCard(
                title: 'Step 4: Lesion-Aware Rust Denoising & Connectivity',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _openPreprocessedFolder(jumpToDenoise: true),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Auto-Load Preprocessed Folder'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    PathPickerField(
                      controller: _boldMniCtrl,
                      label: '4D BOLD MNI (.nii preferred for mmap / .nii.gz)',
                      onPicked: (p) {
                        _session.boldMniPath = p;
                        _inspectAndRender(p);
                      },
                    ),
                    const SizedBox(height: 10),
                    PathPickerField(
                      controller: _atlasCtrl,
                      label: 'Atlas NIfTI (e.g., schaefer400_mni.nii.gz)',
                      onPicked: (p) => _session.atlasPath = p,
                    ),
                    const SizedBox(height: 10),
                    PathPickerField(
                      controller: _labelsCtrl,
                      label: 'Atlas Labels JSON (Homotopic Pairing)',
                      onPicked: (p) => _session.labelsJsonPath = p,
                    ),
                    const SizedBox(height: 10),
                    PathPickerField(
                      controller: _lesionMaskCtrl,
                      label: 'Optional Normalized Lesion Mask',
                      onPicked: (p) => _session.lesionMaskPath = p,
                    ),
                    const SizedBox(height: 10),
                    PathPickerField(
                      controller: _wmCtrl,
                      label: 'WM Mask (aCompCor)',
                      onPicked: (p) => _session.wmMaskPath = p,
                    ),
                    const SizedBox(height: 10),
                    PathPickerField(
                      controller: _csfCtrl,
                      label: 'CSF Mask (aCompCor)',
                      onPicked: (p) => _session.csfMaskPath = p,
                    ),
                    const SizedBox(height: 10),
                    PathPickerField(
                      controller: _confoundsCtrl,
                      label: 'Confounds TSV (Motion + FD)',
                      onPicked: (p) => _session.confoundsPath = p,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Bandpass: ${_lowHz.toStringAsFixed(3)}–${_highHz.toStringAsFixed(2)} Hz | '
                      'FD Scrub: ${_fdThresholdMm.toStringAsFixed(2)} mm | '
                      'Max ROI Damage: ${_maxDamagePct.toStringAsFixed(0)}%',
                    ),
                    Slider(
                      value: _maxDamagePct,
                      min: 10,
                      max: 100,
                      divisions: 18,
                      label: 'Max Damage ${_maxDamagePct.round()}%',
                      onChanged: (v) => setState(() => _maxDamagePct = v),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _fdThresholdMm,
                            min: 0.2,
                            max: 2.0,
                            divisions: 18,
                            label: 'FD ${_fdThresholdMm.toStringAsFixed(1)}mm',
                            onChanged: (v) =>
                                setState(() => _fdThresholdMm = v),
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: _highHz,
                            min: 0.05,
                            max: 0.20,
                            divisions: 15,
                            label: 'LP ${_highHz.toStringAsFixed(2)}Hz',
                            onChanged: (v) => setState(() => _highHz = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _runPipeline,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text(
                        'Run Lesion-Aware Denoising & Biomarkers',
                      ),
                    ),
                    if (_pipelineSummary != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Intact ROIs: ${_pipelineSummary!.nIntactRois}/${_pipelineSummary!.nRois} '
                          '(Excluded: ${_pipelineSummary!.nExcludedRois}) | '
                          'mmap: ${_pipelineSummary!.usedMmap} | '
                          'Total: ${_pipelineSummary!.totalMs.toStringAsFixed(1)} ms\n'
                          'Lesion: ${_pipelineSummary!.lesionVolumeMl.toStringAsFixed(2)} mL '
                          '(${_pipelineSummary!.dominantHemisphere}) | '
                          'Mean |FC|: ${_pipelineSummary!.meanAbsFc.toStringAsFixed(4)}\n'
                          'Global Efficiency: ${_pipelineSummary!.globalEfficiency.toStringAsFixed(4)} | '
                          'Node Strength: ${_pipelineSummary!.meanNodeStrength.toStringAsFixed(2)}\n'
                          'Homotopic FC: ${_pipelineSummary!.meanHomotopicFc.toStringAsFixed(4)} | '
                          'Laterality Index: ${_pipelineSummary!.lateralityIndex.toStringAsFixed(4)} | '
                          'Seed |r|: ${_pipelineSummary!.lesionSeedMeanAbsR.toStringAsFixed(4)}',
                          style: const TextStyle(color: Color(0xFF2DD4BF)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: _buildCard(
              title: 'Zero-Copy RGBA Slice Viewport',
              expandChild: true,
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
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
                          if (v != null) {
                            setState(() => _plane = v);
                            if (_boldMniCtrl.text.trim().isNotEmpty) {
                              _inspectAndRender();
                            }
                          }
                        },
                      ),
                      FilledButton.tonalIcon(
                        onPressed:
                            _busy ? null : () => _inspectAndRender(),
                        icon: const Icon(Icons.visibility),
                        label: const Text('Render Slice'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Center(
                      child: _sliceImage != null
                          ? RawImage(
                              image: _sliceImage,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.none,
                            )
                          : const Text(
                              'Browse a 3D/4D NIfTI volume or open a subject folder\n'
                              'to inspect slices with 60/120 FPS Rust RGBA rendering.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Color(0xFF94A3B8)),
                            ),
                    ),
                  ),
                  if (_headerSummary != null) ...[
                    Row(
                      children: [
                        Text('Slice: $_sliceIndex'),
                        Expanded(
                          child: Slider(
                            value: _sliceIndex.toDouble().clamp(
                              0,
                              _maxSlice.toDouble(),
                            ),
                            min: 0,
                            max: _maxSlice.toDouble().clamp(1, 512),
                            onChanged: (v) =>
                                setState(() => _sliceIndex = v.round()),
                            onChangeEnd: (_) => _inspectAndRender(),
                          ),
                        ),
                      ],
                    ),
                    if (_maxTimepoint > 0)
                      Row(
                        children: [
                          Text('Vol t: $_timepoint'),
                          Expanded(
                            child: Slider(
                              value: _timepoint.toDouble().clamp(
                                0,
                                _maxTimepoint.toDouble(),
                              ),
                              min: 0,
                              max: _maxTimepoint.toDouble(),
                              onChanged: (v) =>
                                  setState(() => _timepoint = v.round()),
                              onChangeEnd: (_) => _inspectAndRender(),
                            ),
                          ),
                        ],
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogBox() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      height: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: ListView.builder(
        itemCount: _sidecarLog.length,
        itemBuilder: (context, idx) => Text(
          _sidecarLog[idx],
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
        ),
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required Widget child,
    bool expandChild = false,
  }) {
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
            if (expandChild) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}
