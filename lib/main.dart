import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:ccs_fmri_studio/src/rust/frb_generated.dart';
import 'package:ccs_fmri_studio/src/rust_loader.dart';
import 'package:ccs_fmri_studio/src/session_state.dart';
import 'package:ccs_fmri_studio/src/update_checker.dart';
import 'package:ccs_fmri_studio/widgets/batch_panel.dart';
import 'package:ccs_fmri_studio/widgets/lesion_editor_panel.dart';
import 'package:ccs_fmri_studio/widgets/path_picker_field.dart';
import 'package:ccs_fmri_studio/widgets/results_dashboard.dart';

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
  static const List<(String key, String label)> _preprocStages = [
    ('load_inputs', 'Load T1w & 4D BOLD'),
    ('t1_n4_bias_correction', 'N4 Bias Correction'),
    ('t1_atropos_segmentation', 'Atropos Tissue WM/CSF'),
    ('t1_to_mni', 'Nonlinear MNI Warp'),
    ('bold_motion_correction', '4D Motion Correction'),
    ('mean_bold_to_t1_rigid', 'BOLD -> T1w Align'),
    ('warp_4d_and_masks_to_mni', 'Warp 4D BOLD to MNI'),
    ('align_schaefer400_atlas', 'Schaefer-400 Atlas'),
  ];

  final FmriSessionState _session = FmriSessionState();
  int _stepIndex = 0;

  // Step 1 controllers
  final _t1DicomCtrl = TextEditingController();
  final _boldDicomCtrl = TextEditingController();
  final _dicomOutCtrl = TextEditingController();
  final _inspectNiftiCtrl = TextEditingController();

  // Step 2 controllers & live stage state
  final _rawT1Ctrl = TextEditingController();
  final _rawBoldCtrl = TextEditingController();
  final _preprocOutCtrl = TextEditingController();
  final _preprocLesionCtrl = TextEditingController();
  final _customTemplateCtrl = TextEditingController();
  String _templateId = 'mni152_adult';
  String _transform = 'SyNQuick';
  String _lesionMode = 'none';
  final Map<String, String> _stageDurations = {};

  // Step 4 controllers
  final _boldMniCtrl = TextEditingController();
  final _atlasCtrl = TextEditingController();
  final _labelsCtrl = TextEditingController();
  final _wmCtrl = TextEditingController();
  final _csfCtrl = TextEditingController();
  final _confoundsCtrl = TextEditingController();
  final _lesionMaskCtrl = TextEditingController();
  bool _useLesionMask = false;

  rust_api.EngineInfo? _engineInfo;
  String? _engineError;
  bool _checkingUpdates = false;

  // Live progress banner & elapsed timer
  bool _busy = false;
  double? _taskProgress; // null = indeterminate, 0..1 = determinate
  String _taskStageLabel = '';
  int _elapsedSeconds = 0;
  Timer? _taskTimer;

  String _statusMessage =
      'Open a patient folder (raw DICOM, NIfTI, or preprocessed outputs) to begin.';
  final List<String> _sidecarLog = [];
  FolderScanResult? _lastScan;

  rust_api.NiftiHeaderSummary? _headerSummary;
  rust_api.LesionPipelineSummary? _pipelineSummary;
  ui.Image? _sliceImage;
  ui.Image? _fcImage;
  ui.Image? _partialImage;
  ui.Image? _gcmiImage;
  ui.Image? _teImage;
  ui.Image? _teNetImage;
  ui.Image? _rawCarpetImage;
  ui.Image? _carpetImage;
  String _plane = 'axial';
  int _sliceIndex = 47;
  int _maxSlice = 94;
  int _timepoint = 0;
  int _maxTimepoint = 0;
  final double _lowHz = 0.008;
  double _highHz = 0.09;
  double _fdThresholdMm = 0.5;
  double _maxDamagePct = 50.0;
  String _censorMode = 'interpolate';

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

    sync(_t1DicomCtrl, _session.t1DicomDir);
    sync(_boldDicomCtrl, _session.boldDicomDir);
    sync(_dicomOutCtrl, _session.dicomOutDir);
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
    if (_session.lesionMaskPath.isNotEmpty) {
      _useLesionMask = true;
    }
    if (_inspectNiftiCtrl.text.isEmpty) {
      final candidate = _session.boldMniPath.isNotEmpty
          ? _session.boldMniPath
          : _session.rawBoldPath;
      if (candidate.isNotEmpty) _inspectNiftiCtrl.text = candidate;
    }
  }

  void _startActivity(String label, {double? progress}) {
    _taskTimer?.cancel();
    setState(() {
      _busy = true;
      _taskStageLabel = label;
      _taskProgress = progress;
      _elapsedSeconds = 0;
    });
    _taskTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });
  }

  void _stopActivity() {
    _taskTimer?.cancel();
    _taskTimer = null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _taskProgress = null;
    });
  }

  static String _formatElapsed(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<ui.Image> _decodeRgba(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  void dispose() {
    _taskTimer?.cancel();
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
    _fcImage?.dispose();
    _partialImage?.dispose();
    _gcmiImage?.dispose();
    _teImage?.dispose();
    _teNetImage?.dispose();
    _rawCarpetImage?.dispose();
    _carpetImage?.dispose();
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

  Future<void> _openPatientFolder({bool jumpToDenoise = false}) async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Open Patient / MRI Folder (DICOM, NIfTI, or Preprocessed)',
    );
    if (folder == null || folder.isEmpty) return;
    final scan = _session.scanFolder(folder);
    final name = FmriSessionState.basename(scan.rootFolder);
    setState(() {
      _lastScan = scan;
      _useLesionMask = _session.lesionMaskPath.isNotEmpty;
      switch (scan.kind) {
        case DetectedDatasetKind.preprocessed:
          _statusMessage =
              'Loaded preprocessed MNI outputs from "$name" (${scan.detectedLabels.length} files). Ready for Step 4 (Denoise).';
          if (jumpToDenoise) _stepIndex = 3;
        case DetectedDatasetKind.rawNifti:
          _statusMessage =
              'Loaded raw NIfTI scans from "$name". Click "Continue to Step 2: Preprocess".';
        case DetectedDatasetKind.rawDicom:
          _statusMessage =
              'Detected ${scan.dicomSeries.length} scanner DICOM series in "$name". Click "Convert DICOMs to NIfTI & Continue".';
        case DetectedDatasetKind.empty:
          _statusMessage =
              'No MRI files found in "$name". Choose a folder with .IMA/.dcm series folders or .nii/.nii.gz files.';
      }
    });
    if (_session.boldMniPath.isNotEmpty) {
      await _inspectAndRender(_session.boldMniPath);
    } else if (_session.rawBoldPath.isNotEmpty) {
      await _inspectAndRender(_session.rawBoldPath);
    }
  }

  Future<void> _openSingleFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open NIfTI Volume (.nii / .nii.gz) or DICOM File',
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    if (FmriSessionState.isDicomFile(path)) {
      final scan = _session.handlePickedFile(path);
      setState(() {
        _lastScan = scan;
        _statusMessage =
            scan.notice ??
            'Detected scanner DICOM files; scanned parent folder for series.';
      });
      return;
    }
    if (FmriSessionState.isNiftiFile(path)) {
      final scan = _session.handlePickedFile(path);
      setState(() {
        _lastScan = scan;
        _inspectNiftiCtrl.text = path;
      });
      await _inspectAndRender(path);
      return;
    }
    setState(() {
      _statusMessage =
          'Unsupported file "${FmriSessionState.basename(path)}". Pick a .nii / .nii.gz file, or click "Open Patient Folder".';
    });
  }

  Future<void> _runDicomConvert({bool autoAdvance = false}) async {
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
    _sidecarLog.clear();
    _statusMessage = 'Converting scanner DICOMs to BIDS NIfTI with dcm2niix…';
    _startActivity('Converting scanner DICOMs with dcm2niix…');
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
        final scan = _session.scanFolder(outDir);
        setState(() {
          _lastScan = scan;
          _preprocOutCtrl.text =
              '${Directory(outDir).parent.path}${Platform.pathSeparator}preproc';
          _statusMessage =
              'DICOM conversion succeeded! Ready for Step 2 (Preprocess).';
          if (autoAdvance) _stepIndex = 1;
        });
      } else {
        setState(
          () => _statusMessage = 'DICOM conversion failed (exit $code). See log.',
        );
      }
    } finally {
      _stopActivity();
    }
  }

  void _handlePreprocLogLine(String line) {
    _sidecarLog.add(line);
    final m = RegExp(
      r'^\[preproc\]\s+([A-Za-z0-9_]+):\s*([0-9.]+s)',
    ).firstMatch(line.trim());
    if (m == null) return;
    final rawKey = m.group(1)!;
    final dur = m.group(2)!;
    for (final (stageKey, _) in _preprocStages) {
      if (rawKey == stageKey || rawKey.startsWith(stageKey)) {
        _stageDurations[stageKey] = dur;
        break;
      }
    }
    final completed = _stageDurations.length;
    _taskProgress = completed / _preprocStages.length;
    if (completed < _preprocStages.length) {
      _taskStageLabel =
          'ANTsPy Preprocessing ($completed/${_preprocStages.length}): ${_preprocStages[completed].$2}…';
    } else {
      _taskStageLabel = 'ANTsPy Preprocessing complete!';
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
    _sidecarLog.clear();
    _stageDurations.clear();
    _statusMessage = 'Running ANTsPy preprocessing ($_templateId, $_lesionMode)…';
    _startActivity(
      'ANTsPy Preprocessing (0/8): ${_preprocStages.first.$2}…',
      progress: 0.04,
    );

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
          setState(() => _handlePreprocLogLine(line));
        },
      );
      if (code == 0) {
        final scan = _session.scanFolder(outDir);
        setState(() {
          _lastScan = scan;
          _taskProgress = 1.0;
          _statusMessage =
              'ANTsPy preprocessing complete! Outputs loaded into Step 4 (Denoise).';
        });
        if (_session.boldMniPath.isNotEmpty) {
          await _inspectAndRender(_session.boldMniPath);
        }
      } else {
        setState(
          () => _statusMessage = 'Preprocessing failed (exit $code). See Technical Log.',
        );
      }
    } finally {
      _stopActivity();
    }
  }

  Future<void> _inspectAndRender([String? explicitPath]) async {
    final path = (explicitPath ?? _boldMniCtrl.text).trim();
    if (path.isEmpty) {
      setState(
        () => _statusMessage = 'Select a NIfTI file or click Open Folder first.',
      );
      return;
    }
    if (FmriSessionState.isDicomFile(path)) {
      final scan = _session.handlePickedFile(path);
      setState(() {
        _lastScan = scan;
        _stepIndex = 0;
        _statusMessage =
            scan.notice ??
            'Scanner DICOM files must be converted to NIfTI in Step 1 first.';
      });
      return;
    }
    _startActivity('Inspecting NIfTI header & rendering slice…');
    try {
      final hdr = await rust_api.inspectNifti(path: path);
      final maxS = _maxSliceForPlane(hdr, _plane);
      final clampedSlice = _sliceIndex.clamp(0, maxS);
      final maxT = hdr.dims.length >= 4 && hdr.dims[3] > 0
          ? hdr.dims[3] - 1
          : 0;
      final clampedTp = _timepoint.clamp(0, maxT);
      final lesionPath = _lesionMaskCtrl.text.trim();
      final activeLesion =
          (_useLesionMask && lesionPath.isNotEmpty) ? lesionPath : null;
      final slice = await rust_api.renderSliceWithLesionRgba(
        path: path,
        lesionMaskPath: activeLesion,
        plane: _plane,
        sliceIndex: clampedSlice,
        timepoint: clampedTp,
        overlayAlpha: 0.40,
      );
      final decoded = await _decodeRgba(slice.rgba, slice.width, slice.height);
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
            'Loaded ${FmriSessionState.basename(path)} (${hdr.dims.join(" × ")}, TR=${hdr.trSec.toStringAsFixed(2)}s)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      _stopActivity();
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
            'Load a preprocessed folder (BOLD MNI + Atlas) first.',
      );
      return;
    }
    final outDir = _session.resultsDir.isNotEmpty
        ? _session.resultsDir
        : '${File(boldPath).parent.path}${Platform.pathSeparator}results';

    _startActivity(
      'Running Rust parcellation, aCompCor, simultaneous denoising & FC export…',
    );
    try {
      final lesionPath = _lesionMaskCtrl.text.trim();
      final activeLesion =
          (_useLesionMask && lesionPath.isNotEmpty) ? lesionPath : null;
      final labelsPath = _labelsCtrl.text.trim();
      final summary = await rust_api.runLesionAwarePipeline(
        boldPath: boldPath,
        atlasPath: atlasPath,
        lesionMaskPath: activeLesion,
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
        censorMode: _censorMode,
        outDir: outDir,
      );

      Future<ui.Image?> tryDecode(Uint8List rgba, int w, int h) async {
        if (w <= 0 || h <= 0 || rgba.isEmpty) return null;
        return _decodeRgba(rgba, w, h);
      }

      final fcImg = await tryDecode(
        summary.fcPreviewRgba,
        summary.fcPreviewSize,
        summary.fcPreviewSize,
      );
      final partialImg = await tryDecode(
        summary.partialPreviewRgba,
        summary.fcPreviewSize,
        summary.fcPreviewSize,
      );
      final gcmiImg = await tryDecode(
        summary.gcmiPreviewRgba,
        summary.fcPreviewSize,
        summary.fcPreviewSize,
      );
      final teImg = await tryDecode(
        summary.tePreviewRgba,
        summary.fcPreviewSize,
        summary.fcPreviewSize,
      );
      final teNetImg = await tryDecode(
        summary.teNetPreviewRgba,
        summary.fcPreviewSize,
        summary.fcPreviewSize,
      );
      final rawCarpetImg = await tryDecode(
        summary.rawCarpetRgba,
        summary.carpetWidth,
        summary.carpetHeight,
      );
      final carpetImg = await tryDecode(
        summary.carpetRgba,
        summary.carpetWidth,
        summary.carpetHeight,
      );
      if (!mounted) {
        fcImg?.dispose();
        partialImg?.dispose();
        gcmiImg?.dispose();
        teImg?.dispose();
        teNetImg?.dispose();
        rawCarpetImg?.dispose();
        carpetImg?.dispose();
        return;
      }
      setState(() {
        _pipelineSummary = summary;
        _session.resultsDir = summary.exportedDir ?? outDir;
        _fcImage?.dispose();
        _fcImage = fcImg;
        _partialImage?.dispose();
        _partialImage = partialImg;
        _gcmiImage?.dispose();
        _gcmiImage = gcmiImg;
        _teImage?.dispose();
        _teImage = teImg;
        _teNetImage?.dispose();
        _teNetImage = teNetImg;
        _rawCarpetImage?.dispose();
        _rawCarpetImage = rawCarpetImg;
        _carpetImage?.dispose();
        _carpetImage = carpetImg;
        _stepIndex = 4;
        _statusMessage =
            'Completed ${summary.nIntactRois}/${summary.nRois} intact ROIs in ${summary.totalMs.toStringAsFixed(1)} ms — saved results to ${FmriSessionState.basename(_session.resultsDir)}/.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Pipeline error: $e');
    } finally {
      _stopActivity();
    }
  }

  Future<void> _openDirectoryInOs(String dirPath) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [dirPath]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dirPath]);
      } else {
        await Process.run('xdg-open', [dirPath]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open folder: $e')));
    }
  }

  Future<void> _saveReportAs() async {
    final exportDir = _pipelineSummary?.exportedDir;
    if (exportDir == null) return;
    final src = File('$exportDir${Platform.pathSeparator}clinical_report.md');
    if (!src.existsSync()) return;
    final dest = await FilePicker.saveFile(
      dialogTitle: 'Save Clinical Report As',
      fileName: 'clinical_report.md',
    );
    if (dest == null || dest.isEmpty) return;
    await src.copy(dest);
    if (!mounted) return;
    setState(() => _statusMessage = 'Saved report to $dest');
  }

  void _resetSession() {
    _session.reset();
    _t1DicomCtrl.clear();
    _boldDicomCtrl.clear();
    _dicomOutCtrl.clear();
    _inspectNiftiCtrl.clear();
    _rawT1Ctrl.clear();
    _rawBoldCtrl.clear();
    _preprocOutCtrl.clear();
    _preprocLesionCtrl.clear();
    _customTemplateCtrl.clear();
    _boldMniCtrl.clear();
    _atlasCtrl.clear();
    _labelsCtrl.clear();
    _wmCtrl.clear();
    _csfCtrl.clear();
    _confoundsCtrl.clear();
    _lesionMaskCtrl.clear();
    _sidecarLog.clear();
    _stageDurations.clear();
    setState(() {
      _useLesionMask = false;
      _lastScan = null;
      _headerSummary = null;
      _pipelineSummary = null;
      _sliceImage?.dispose();
      _sliceImage = null;
      _fcImage?.dispose();
      _fcImage = null;
      _partialImage?.dispose();
      _partialImage = null;
      _gcmiImage?.dispose();
      _gcmiImage = null;
      _teImage?.dispose();
      _teImage = null;
      _teNetImage?.dispose();
      _teNetImage = null;
      _rawCarpetImage?.dispose();
      _rawCarpetImage = null;
      _carpetImage?.dispose();
      _carpetImage = null;
      _stepIndex = 0;
      _statusMessage =
          'Session cleared. Open a new patient folder (raw DICOM, NIfTI, or preprocessed outputs).';
    });
  }

  Future<void> _loadBatchSubject(String folder) async {
    final scan = _session.scanFolder(folder);
    final name = FmriSessionState.basename(scan.rootFolder);
    setState(() {
      _lastScan = scan;
      _useLesionMask = _session.lesionMaskPath.isNotEmpty;
      if (scan.kind == DetectedDatasetKind.preprocessed &&
          _session.boldMniPath.isNotEmpty) {
        _stepIndex = 3;
        _statusMessage = 'Loaded batch subject "$name" into Step 4 (Denoise).';
      } else {
        _stepIndex = 0;
        _statusMessage = 'Loaded batch subject "$name" into Step 1 (Import).';
      }
    });
    if (_session.boldMniPath.isNotEmpty) {
      await _inspectAndRender(_session.boldMniPath);
    } else if (_session.rawBoldPath.isNotEmpty) {
      await _inspectAndRender(_session.rawBoldPath);
    }
  }

  Widget _stepIcon(IconData icon, bool ready) {
    if (!ready) return Icon(icon);
    return Badge(
      backgroundColor: const Color(0xFF10B981),
      smallSize: 8,
      child: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final step1Ready =
        _session.rawBoldPath.isNotEmpty ||
        _session.boldMniPath.isNotEmpty ||
        (_lastScan?.dicomSeries.isNotEmpty ?? false);
    final step2Ready = _session.boldMniPath.isNotEmpty;
    final step3Ready = _session.lesionMaskPath.isNotEmpty;
    final step4Ready = _pipelineSummary != null;
    final step5Ready = _pipelineSummary != null;

    final completedCore =
        (step1Ready ? 1 : 0) +
        (step2Ready ? 1 : 0) +
        (step4Ready ? 1 : 0) +
        (step5Ready ? 1 : 0);
    final overallProgress = completedCore / 4.0;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('CCS fMRI Studio'),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : () => _openPatientFolder(),
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
          _buildWholePipelineBar(
            stepStates: [step1Ready, step2Ready, step3Ready, step4Ready, step5Ready],
            overallProgress: overallProgress,
          ),
          if (_busy) _buildLiveActivityBanner(),
          Expanded(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _stepIndex,
                  backgroundColor: const Color(0xFF111827),
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (idx) =>
                      setState(() => _stepIndex = idx),
                  destinations: [
                    NavigationRailDestination(
                      icon: _stepIcon(
                        Icons.drive_folder_upload_outlined,
                        step1Ready,
                      ),
                      selectedIcon: _stepIcon(
                        Icons.drive_folder_upload,
                        step1Ready,
                      ),
                      label: const Text('1. Import'),
                    ),
                    NavigationRailDestination(
                      icon: _stepIcon(Icons.auto_awesome_outlined, step2Ready),
                      selectedIcon: _stepIcon(Icons.auto_awesome, step2Ready),
                      label: const Text('2. Preprocess'),
                    ),
                    NavigationRailDestination(
                      icon: _stepIcon(Icons.brush_outlined, step3Ready),
                      selectedIcon: _stepIcon(Icons.brush, step3Ready),
                      label: const Text('3. Lesion'),
                    ),
                    NavigationRailDestination(
                      icon: _stepIcon(Icons.tune_outlined, step4Ready),
                      selectedIcon: _stepIcon(Icons.tune, step4Ready),
                      label: const Text('4. Denoise'),
                    ),
                    NavigationRailDestination(
                      icon: _stepIcon(Icons.insights_outlined, step5Ready),
                      selectedIcon: _stepIcon(Icons.insights, step5Ready),
                      label: const Text('5. Results'),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.library_books_outlined),
                      selectedIcon: Icon(Icons.library_books),
                      label: Text('6. Batch'),
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
                      _buildStep5Results(context),
                      BatchPanel(
                        session: _session,
                        templateId: _templateId,
                        transform: _transform,
                        lesionMode: _lesionMode,
                        lowHz: _lowHz,
                        highHz: _highHz,
                        fdThresholdMm: _fdThresholdMm,
                        maxDamagePct: _maxDamagePct,
                        onOpenFolder: _openDirectoryInOs,
                        onInspectSubject: _loadBatchSubject,
                      ),
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

  Widget _buildWholePipelineBar({
    required List<bool> stepStates,
    required double overallProgress,
  }) {
    const labels = [
      '1. Import',
      '2. Preprocess',
      '3. Lesion (Opt)',
      '4. Denoise',
      '5. Results',
    ];
    final pct = (overallProgress * 100).round();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF162033),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Pipeline Progress',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(width: 12),
              for (var i = 0; i < labels.length; i++) ...[
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => setState(() => _stepIndex = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _stepIndex == i
                            ? const Color(0xFF0D9488).withValues(alpha: 0.28)
                            : (stepStates[i]
                                ? const Color(0xFF059669).withValues(alpha: 0.16)
                                : const Color(0xFF0F172A)),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _stepIndex == i
                              ? const Color(0xFF2DD4BF)
                              : (stepStates[i]
                                  ? const Color(0xFF10B981)
                                  : Colors.white12),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            stepStates[i]
                                ? Icons.check_circle
                                : (_stepIndex == i
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked),
                            size: 14,
                            color: stepStates[i]
                                ? const Color(0xFF10B981)
                                : (_stepIndex == i
                                    ? const Color(0xFF2DD4BF)
                                    : const Color(0xFF64748B)),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              labels[i],
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: _stepIndex == i
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: _stepIndex == i || stepStates[i]
                                    ? Colors.white
                                    : const Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (i < labels.length - 1)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: Color(0xFF475569),
                    ),
                  ),
              ],
              const SizedBox(width: 12),
              Text(
                '$pct%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2DD4BF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: overallProgress,
              minHeight: 4,
              backgroundColor: const Color(0xFF0F172A),
              color: const Color(0xFF2DD4BF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveActivityBanner() {
    final pctLabel = _taskProgress != null
        ? ' (${(_taskProgress! * 100).round()}%)'
        : '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0F292E),
        border: Border(bottom: BorderSide(color: Color(0xFF14B8A6))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$_taskStageLabel$pctLabel',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF99F6E4),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Chip(
                backgroundColor: const Color(0xFF0F172A),
                visualDensity: VisualDensity.compact,
                label: Text(
                  'Elapsed: ${_formatElapsed(_elapsedSeconds)}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Color(0xFF2DD4BF),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _taskProgress,
              minHeight: 5,
              backgroundColor: const Color(0xFF0F172A),
              color: const Color(0xFF2DD4BF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep1Import(BuildContext context) {
    final scan = _lastScan;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCard(
            title: 'Open Your MRI Scan',
            subtitle:
                'Choose any patient folder — raw scanner DICOMs (.IMA / .dcm), BIDS folders, raw NIfTI (.nii / .nii.gz), or already-preprocessed outputs. CCS fMRI Studio automatically detects what is inside and prepares the next step.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: Icon(Icons.medical_information_outlined, size: 16),
                      label: Text('Scanner DICOMs (.IMA / .dcm)'),
                    ),
                    Chip(
                      avatar: Icon(Icons.layers_outlined, size: 16),
                      label: Text('Raw NIfTI / BIDS'),
                    ),
                    Chip(
                      avatar: Icon(Icons.check_circle_outline, size: 16),
                      label: Text('Preprocessed Outputs'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _openPatientFolder(),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Open Patient Folder'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _openSingleFile,
                      icon: const Icon(Icons.insert_drive_file_outlined),
                      label: const Text('Open Single NIfTI File'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (scan != null) ...[
            const SizedBox(height: 16),
            _buildDetectedScanCard(scan),
          ],
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFF1E293B),
            child: ExpansionTile(
              title: const Text(
                'Advanced: Manual DICOM Folders & NIfTI Header Inspector',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Expand only if you want to specify custom T1w/BOLD DICOM directories or inspect a NIfTI header directly.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                PathPickerField(
                  controller: _inspectNiftiCtrl,
                  label: 'NIfTI Volume Path (.nii / .nii.gz)',
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
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Dims: ${_headerSummary!.dims.join(" × ")} | '
                      'Voxel: ${_headerSummary!.voxelSizes.map((v) => v.toStringAsFixed(2)).join(" × ")} mm | '
                      'TR: ${_headerSummary!.trSec.toStringAsFixed(2)} s | '
                      'Datatype code: ${_headerSummary!.datatypeCode}',
                    ),
                  ),
                ],
                const Divider(height: 28, color: Colors.white12),
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
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _runDicomConvert(),
                    icon: const Icon(Icons.transform),
                    label: const Text('Convert DICOMs to NIfTI'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectedScanCard(FolderScanResult scan) {
    final folderName = FmriSessionState.basename(scan.rootFolder);
    final (badgeLabel, badgeColor) = switch (scan.kind) {
      DetectedDatasetKind.preprocessed => (
        'Preprocessed MNI Ready',
        const Color(0xFF059669),
      ),
      DetectedDatasetKind.rawNifti => (
        'Raw NIfTI Scans Found',
        const Color(0xFF0284C7),
      ),
      DetectedDatasetKind.rawDicom => (
        'Raw Scanner DICOMs Found',
        const Color(0xFF0D9488),
      ),
      DetectedDatasetKind.empty => ('No MRI Files Found', const Color(0xFFB45309)),
    };

    String? validSeriesValue(String current, List<DicomSeriesInfo> list) {
      for (final s in list) {
        if (s.path == current) return current;
      }
      return null;
    }

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text(
                  'Detected Scan: $folderName',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Chip(
                  backgroundColor: badgeColor.withValues(alpha: 0.25),
                  side: BorderSide(color: badgeColor),
                  label: Text(badgeLabel),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              scan.rootFolder,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            if (scan.notice != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2DD4BF)),
                ),
                child: Text(
                  scan.notice!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF99F6E4),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (scan.kind == DetectedDatasetKind.rawDicom) ...[
              Text(
                'Found ${scan.dicomSeries.length} DICOM series. Confirm T1w & BOLD series below, then convert them to NIfTI in one click:',
                style: const TextStyle(color: Color(0xFFCBD5E1)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: validSeriesValue(
                        _t1DicomCtrl.text,
                        scan.dicomSeries,
                      ),
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'T1w Anatomical Series',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: scan.dicomSeries
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.path,
                              child: Text(
                                s.displayLabel,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() {
                            _t1DicomCtrl.text = v;
                            _session.t1DicomDir = v;
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: validSeriesValue(
                        _boldDicomCtrl.text,
                        scan.dicomSeries,
                      ),
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '4D BOLD fMRI Series',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: scan.dicomSeries
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.path,
                              child: Text(
                                s.displayLabel,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() {
                            _boldDicomCtrl.text = v;
                            _session.boldDicomDir = v;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runDicomConvert(autoAdvance: true),
                    icon: const Icon(Icons.transform),
                    label: const Text('Convert DICOMs to NIfTI & Continue →'),
                  ),
                  Text(
                    'Saves to: ${FmriSessionState.basename(_dicomOutCtrl.text)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
              if (_sidecarLog.isNotEmpty)
                ExpansionTile(
                  title: const Text('Conversion Log'),
                  children: [_buildLogBox()],
                ),
            ] else if (scan.kind == DetectedDatasetKind.rawNifti) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_session.rawT1Path.isNotEmpty)
                    Chip(
                      avatar: const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Color(0xFF2DD4BF),
                      ),
                      label: Text(
                        'T1w: ${FmriSessionState.basename(_session.rawT1Path)}',
                      ),
                    ),
                  if (_session.rawBoldPath.isNotEmpty)
                    Chip(
                      avatar: const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Color(0xFF2DD4BF),
                      ),
                      label: Text(
                        'BOLD: ${FmriSessionState.basename(_session.rawBoldPath)}',
                      ),
                    ),
                  if (_session.flairPath.isNotEmpty)
                    Chip(
                      avatar: const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Color(0xFF2DD4BF),
                      ),
                      label: Text(
                        'FLAIR: ${FmriSessionState.basename(_session.flairPath)}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => setState(() => _stepIndex = 1),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Continue to Step 2: Preprocess →'),
                ),
              ),
            ] else if (scan.kind == DetectedDatasetKind.preprocessed) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: scan.detectedLabels
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
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _stepIndex = 2),
                    icon: const Icon(Icons.brush),
                    label: const Text('Optional: Lesion Editor (Step 3)'),
                  ),
                  FilledButton.icon(
                    onPressed: () => setState(() => _stepIndex = 3),
                    icon: const Icon(Icons.tune),
                    label: const Text('Denoise & View Brain (Step 4) →'),
                  ),
                ],
              ),
            ] else ...[
              const Text(
                'No DICOM series (.IMA / .dcm) or NIfTI files (.nii / .nii.gz) were found inside this folder (or its immediate subfolders).\n'
                'Tip: Select a patient folder such as Patient_01/pre containing scanner series folders (e.g. HEAD_T1_MPRAGE..., HEAD_EP2D_RS_FMRI...) or a NIfTI/preproc folder.',
                style: TextStyle(color: Color(0xFFFDE68A)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStep2Preprocess(BuildContext context) {
    final completedCount = _stageDurations.length;
    final showStageCard =
        (_busy && _taskStageLabel.startsWith('ANTsPy')) ||
        _stageDurations.isNotEmpty ||
        _sidecarLog.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCard(
            title: 'Step 2: ANTsPy Spatial Normalization & Motion Correction',
            subtitle:
                'Align T1w and 4D BOLD scans into standard MNI brain space (~2 min). Choose Cost Function Masking or Enantiomorphic Healing for lesion scans.',
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
                      label: const Text('Optional: Lesion Editor (Step 3)'),
                    ),
                    if (_session.boldMniPath.isNotEmpty)
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => _stepIndex = 3),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Skip to Step 4: Denoise →'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (showStageCard) ...[
            const SizedBox(height: 16),
            _buildCard(
              title:
                  'Live Preprocessing Stage Visualization ($completedCount/${_preprocStages.length} complete)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: completedCount / _preprocStages.length,
                      minHeight: 8,
                      backgroundColor: const Color(0xFF0F172A),
                      color: const Color(0xFF2DD4BF),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var i = 0; i < _preprocStages.length; i++)
                        _buildStageTile(
                          index: i,
                          keyName: _preprocStages[i].$1,
                          label: _preprocStages[i].$2,
                          activeIndex: _busy ? completedCount : -1,
                        ),
                    ],
                  ),
                  if (_session.boldMniPath.isNotEmpty &&
                      !_busy &&
                      completedCount == _preprocStages.length) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF052E16),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF10B981)),
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          const Text(
                            'Preprocessing finished cleanly! All MNI derivatives are loaded.',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFA7F3D0),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: () => setState(() => _stepIndex = 3),
                            icon: const Icon(Icons.arrow_forward),
                            label: const Text(
                              'Continue to Step 4: Denoise & Connectivity →',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_sidecarLog.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ExpansionTile(
                      title: Text(
                        'Technical Log (${_sidecarLog.length} lines)',
                        style: const TextStyle(fontSize: 13.5),
                      ),
                      children: [_buildLogBox()],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStageTile({
    required int index,
    required String keyName,
    required String label,
    required int activeIndex,
  }) {
    final dur = _stageDurations[keyName];
    final isDone = dur != null;
    final isActive = !isDone && index == activeIndex;
    return Container(
      width: 245,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDone
            ? const Color(0xFF052E16).withValues(alpha: 0.7)
            : (isActive
                ? const Color(0xFF0F292E)
                : const Color(0xFF0F172A)),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDone
              ? const Color(0xFF10B981)
              : (isActive ? const Color(0xFF2DD4BF) : Colors.white12),
        ),
      ),
      child: Row(
        children: [
          if (isDone)
            const Icon(Icons.check_circle, size: 18, color: Color(0xFF10B981))
          else if (isActive)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(
              Icons.radio_button_unchecked,
              size: 16,
              color: Color(0xFF475569),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isDone || isActive
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: isDone || isActive
                        ? Colors.white
                        : const Color(0xFF94A3B8),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  isDone
                      ? 'Completed in $dur'
                      : (isActive ? 'Running…' : 'Pending'),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDone
                        ? const Color(0xFF6EE7B7)
                        : (isActive
                            ? const Color(0xFF2DD4BF)
                            : const Color(0xFF64748B)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep4Denoise(BuildContext context) {
    final hasLesionFile = _lesionMaskCtrl.text.trim().isNotEmpty;
    final lesionActive = _useLesionMask && hasLesionFile;
    final largeLesionWarning =
        _pipelineSummary != null && _pipelineSummary!.lesionVolumeMl > 400;

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
                    title: 'Step 4A: Preprocessed Inputs & Lesion Mode',
                    subtitle:
                        'Verify your MNI-space inputs below, then click Run Denoising to compute connectivity biomarkers.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _inputStatusChip(
                              'BOLD MNI',
                              _boldMniCtrl.text.trim(),
                              required: true,
                            ),
                            _inputStatusChip(
                              'Atlas',
                              _atlasCtrl.text.trim(),
                              required: true,
                            ),
                            _inputStatusChip('WM Mask', _wmCtrl.text.trim()),
                            _inputStatusChip('CSF Mask', _csfCtrl.text.trim()),
                            _inputStatusChip(
                              'Confounds',
                              _confoundsCtrl.text.trim(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: lesionActive
                                  ? const Color(0xFFF59E0B)
                                  : Colors.white12,
                            ),
                          ),
                          child: SwitchListTile(
                            dense: true,
                            value: lesionActive,
                            onChanged: hasLesionFile
                                ? (val) {
                                    setState(() => _useLesionMask = val);
                                    if (_boldMniCtrl.text.trim().isNotEmpty) {
                                      _inspectAndRender();
                                    }
                                  }
                                : null,
                            title: const Text(
                              'Apply Lesion Mask (Exclude Damaged ROIs)',
                              style: TextStyle(fontSize: 13.5),
                            ),
                            subtitle: Text(
                              hasLesionFile
                                  ? (lesionActive
                                      ? 'Active: ${FmriSessionState.basename(_lesionMaskCtrl.text.trim())}'
                                      : 'Disabled — analyzing all 400 atlas ROIs')
                                  : 'No lesion mask loaded (create one in Step 3 for TBI/stroke)',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                        ),
                        if (largeLesionWarning) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF451A03),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFF59E0B)),
                            ),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                Text(
                                  'Mask covers ${_pipelineSummary!.lesionVolumeMl.toStringAsFixed(0)} mL and excluded ${_pipelineSummary!.nExcludedRois} ROIs.',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFFFDE68A),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    setState(() => _useLesionMask = false);
                                    _runPipeline();
                                  },
                                  child: const Text('Re-Run Without Mask'),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text(
                            'Edit Individual Input Paths',
                            style: TextStyle(fontSize: 13.5),
                          ),
                          children: [
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _openPatientFolder(
                                        jumpToDenoise: true,
                                      ),
                                icon: const Icon(Icons.folder_open),
                                label: const Text('Auto-Load Preprocessed Folder'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            PathPickerField(
                              controller: _boldMniCtrl,
                              label:
                                  '4D BOLD MNI (.nii preferred for mmap / .nii.gz)',
                              onPicked: (p) {
                                _session.boldMniPath = p;
                                _inspectAndRender(p);
                              },
                            ),
                            const SizedBox(height: 10),
                            PathPickerField(
                              controller: _atlasCtrl,
                              label:
                                  'Atlas NIfTI (e.g., schaefer400_mni.nii.gz)',
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
                              onPicked: (p) {
                                _session.lesionMaskPath = p;
                                setState(() => _useLesionMask = true);
                              },
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
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildCard(
                    title: 'Step 4B: Denoising Parameters & Run',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSliderRow(
                          title: 'Bandpass Low-Pass Cutoff',
                          valueLabel:
                              '${_lowHz.toStringAsFixed(3)}–${_highHz.toStringAsFixed(2)} Hz',
                          slider: Slider(
                            value: _highHz,
                            min: 0.05,
                            max: 0.20,
                            divisions: 15,
                            label: '${_highHz.toStringAsFixed(2)} Hz',
                            onChanged: (v) => setState(() => _highHz = v),
                          ),
                        ),
                        _buildSliderRow(
                          title: 'Motion Scrubbing (FD Threshold)',
                          valueLabel: '${_fdThresholdMm.toStringAsFixed(2)} mm',
                          slider: Slider(
                            value: _fdThresholdMm,
                            min: 0.2,
                            max: 2.0,
                            divisions: 18,
                            label: '${_fdThresholdMm.toStringAsFixed(1)} mm',
                            onChanged: (v) =>
                                setState(() => _fdThresholdMm = v),
                          ),
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          initialValue: _censorMode,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Motion Scrubbing Mode',
                            helperText:
                                'Linear Interpolate prevents flat-zero segments and low-DOF artifacts on high-motion scans.',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'interpolate',
                              child: Text('Linear Interpolate (CONN Default)'),
                            ),
                            DropdownMenuItem(
                              value: 'spike',
                              child: Text('Spike Regressors (Zero-Out)'),
                            ),
                            DropdownMenuItem(
                              value: 'none',
                              child: Text('No Scrubbing'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _censorMode = v);
                          },
                        ),
                        const SizedBox(height: 10),
                        _buildSliderRow(
                          title: 'Max ROI Lesion Damage Exclusion',
                          valueLabel: lesionActive
                              ? '${_maxDamagePct.round()}%'
                              : 'Inactive',
                          slider: Slider(
                            value: _maxDamagePct,
                            min: 10,
                            max: 100,
                            divisions: 18,
                            label: '${_maxDamagePct.round()}%',
                            onChanged: lesionActive
                                ? (v) => setState(() => _maxDamagePct = v)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _busy ? null : _runPipeline,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text(
                            'Run Denoising & Generate Results →',
                          ),
                        ),
                        if (_pipelineSummary != null) ...[
                          if (_pipelineSummary!.dofRemaining < 50 ||
                              _pipelineSummary!.pctScrubbed > 20.0) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF451A03),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFF59E0B),
                                ),
                              ),
                              child: Text(
                                'Motion/DOF QC Notice: ${_pipelineSummary!.pctScrubbed.toStringAsFixed(1)}% volumes flagged '
                                '(mode: ${_pipelineSummary!.censorMode}) • Effective DOF remaining: '
                                '${_pipelineSummary!.dofRemaining} / ${_pipelineSummary!.nTimepoints} '
                                '(${_pipelineSummary!.nRegressors} regressors).',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFFDE68A),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: () => setState(() => _stepIndex = 4),
                            icon: const Icon(Icons.insights),
                            label: const Text(
                              'View Matrix, Carpet Plot & Export (Step 5) →',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: _buildCard(
              title: 'Zero-Copy Brain Slice Viewport',
              subtitle: _headerSummary != null
                  ? 'Volume: ${_headerSummary!.dims.join(" × ")} | TR: ${_headerSummary!.trSec.toStringAsFixed(2)}s'
                  : 'Inspect slices and lesion overlay before denoising.',
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
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B1120),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: _sliceImage != null
                          ? SizedBox.expand(
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: RawImage(
                                  image: _sliceImage,
                                  filterQuality: FilterQuality.none,
                                ),
                              ),
                            )
                          : const Center(
                              child: Text(
                                'Load a preprocessed folder or NIfTI file\n'
                                'to inspect full-size brain slices at 60/120 FPS.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF94A3B8)),
                              ),
                            ),
                    ),
                  ),
                  if (_headerSummary != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            'Slice: $_sliceIndex / $_maxSlice',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
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
                          SizedBox(
                            width: 90,
                            child: Text(
                              'Vol t: $_timepoint / $_maxTimepoint',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
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

  Widget _buildStep5Results(BuildContext context) {
    final s = _pipelineSummary;
    if (s == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            color: const Color(0xFF1E293B),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.insights,
                    size: 52,
                    color: Color(0xFF2DD4BF),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Step 5: Results & Biomarkers Dashboard',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Run Denoising & Biomarkers in Step 4 to visualize your 400×400 Functional Connectivity matrix, ROI Timeseries Carpet Plot, and exported CSV/JSON/Markdown reports.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: () => setState(() => _stepIndex = 3),
                    icon: const Icon(Icons.tune),
                    label: const Text('Go to Step 4: Denoise & Compute →'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ResultsDashboard(
      summary: s,
      fdThresholdMm: _fdThresholdMm,
      lowHz: _lowHz,
      highHz: _highHz,
      fcImage: _fcImage,
      partialImage: _partialImage,
      gcmiImage: _gcmiImage,
      teImage: _teImage,
      teNetImage: _teNetImage,
      rawCarpetImage: _rawCarpetImage,
      cleanCarpetImage: _carpetImage,
      boldMniPath: _boldMniCtrl.text.trim(),
      labelsJsonPath: _labelsCtrl.text.trim(),
      initialBatchCsvPath: _session.lastBatchSummaryCsvPath,
      onRunSidecarModule: (module, args, onLog) =>
          _session.runSidecarModule(module: module, args: args, onLog: onLog),
      onGoStep4: () => setState(() => _stepIndex = 3),
      onOpenResultsFolder: _openDirectoryInOs,
      onSaveReportAs: _saveReportAs,
      onResetSession: _resetSession,
    );
  }

  Widget _inputStatusChip(String label, String path, {bool required = false}) {
    final present = path.isNotEmpty;
    return Chip(
      avatar: Icon(
        present
            ? Icons.check_circle
            : (required ? Icons.error_outline : Icons.remove_circle_outline),
        size: 16,
        color: present
            ? const Color(0xFF10B981)
            : (required ? const Color(0xFFF59E0B) : const Color(0xFF64748B)),
      ),
      label: Text(
        present ? '$label: ${FmriSessionState.basename(path)}' : '$label: None',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildSliderRow({
    required String title,
    required String valueLabel,
    required Widget slider,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 13)),
            Text(
              valueLabel,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2DD4BF),
              ),
            ),
          ],
        ),
        slider,
      ],
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
    String? subtitle,
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
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
              ),
            ],
            const SizedBox(height: 12),
            if (expandChild) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}
