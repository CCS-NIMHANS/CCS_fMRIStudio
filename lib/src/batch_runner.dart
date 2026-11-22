import 'dart:convert';
import 'dart:io';

import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:ccs_fmri_studio/src/session_state.dart';

enum BatchItemStatus { pending, running, done, skipped, failed }

class BatchSubjectItem {
  BatchSubjectItem({
    required this.id,
    required this.folderPath,
    required this.subjectLabel,
    required this.sessionLabel,
    required this.detectedKind,
    this.selected = true,
    this.t1DicomDir = '',
    this.boldDicomDir = '',
    this.rawT1Path = '',
    this.rawBoldPath = '',
    this.boldMniPath = '',
    this.atlasPath = '',
    this.labelsJsonPath = '',
    this.wmMaskPath = '',
    this.csfMaskPath = '',
    this.confoundsPath = '',
    this.lesionMaskPath = '',
    this.resultsDir = '',
  });

  final String id;
  final String folderPath;
  final String subjectLabel;
  final String sessionLabel;
  bool selected;
  DetectedDatasetKind detectedKind;

  String t1DicomDir;
  String boldDicomDir;
  String rawT1Path;
  String rawBoldPath;
  String boldMniPath;
  String atlasPath;
  String labelsJsonPath;
  String wmMaskPath;
  String csfMaskPath;
  String confoundsPath;
  String lesionMaskPath;
  String resultsDir;

  BatchItemStatus status = BatchItemStatus.pending;
  String statusDetail = 'Ready';
  String? errorMessage;

  // Metrics populated after Rust pipeline + dynamics
  int nIntactRois = 0;
  int nRois = 0;
  double meanFdMm = 0.0;
  double pctScrubbed = 0.0;
  double rawFcMean = 0.0;
  double cleanFcMean = 0.0;
  double meanAbsFc = 0.0;
  double meanAbsPartialFc = 0.0;
  double meanGcmiBits = 0.0;
  double meanTeBits = 0.0;
  double globalEfficiency = 0.0;
  double meanHomotopicFc = 0.0;
  double lesionVolumeMl = 0.0;
  double acw0Mean = 0.0;
  double acw50Mean = 0.0;
  double lzcMean = 0.0;
  double sampenMean = 0.0;
  double pleMean = 0.0;
  double totalMs = 0.0;

  Map<String, dynamic> toJsonMap() => {
    'id': id,
    'subject': subjectLabel,
    'session': sessionLabel,
    'folder_path': folderPath,
    'status': status.name,
    'detected_kind': detectedKind.name,
    'bold_mni_path': boldMniPath,
    'atlas_path': atlasPath,
    'results_dir': resultsDir,
    'n_intact_rois': nIntactRois,
    'n_rois': nRois,
    'mean_fd_mm': meanFdMm,
    'pct_scrubbed': pctScrubbed,
    'raw_fc_mean': rawFcMean,
    'clean_fc_mean': cleanFcMean,
    'mean_abs_fc': meanAbsFc,
    'mean_abs_partial_fc': meanAbsPartialFc,
    'mean_gcmi_bits': meanGcmiBits,
    'mean_te_bits': meanTeBits,
    'global_efficiency': globalEfficiency,
    'mean_homotopic_fc': meanHomotopicFc,
    'lesion_volume_ml': lesionVolumeMl,
    'acw0_mean': acw0Mean,
    'acw50_mean': acw50Mean,
    'lzc_mean': lzcMean,
    'sampen_mean': sampenMean,
    'ple_mean': pleMean,
    'total_ms': totalMs,
    if (errorMessage != null) 'error': errorMessage,
  };
}

class BatchRunConfig {
  const BatchRunConfig({
    this.runDicomConvert = true,
    this.runPreprocess = true,
    this.skipExistingPreproc = true,
    this.runDenoiseAndFc = true,
    this.runDynamics = true,
    this.applyLesionMaskIfPresent = false,
    this.templateId = 'mni152_adult',
    this.transform = 'SyNQuick',
    this.lesionMode = 'none',
    this.lowHz = 0.008,
    this.highHz = 0.09,
    this.fdThresholdMm = 0.5,
    this.maxDamagePct = 50.0,
    this.dynWindowLen = 60,
    this.dynStep = 5,
    required this.batchOutDir,
  });

  final bool runDicomConvert;
  final bool runPreprocess;
  final bool skipExistingPreproc;
  final bool runDenoiseAndFc;
  final bool runDynamics;
  final bool applyLesionMaskIfPresent;
  final String templateId;
  final String transform;
  final String lesionMode;
  final double lowHz;
  final double highHz;
  final double fdThresholdMm;
  final double maxDamagePct;
  final int dynWindowLen;
  final int dynStep;
  final String batchOutDir;
}

class BatchDiscovery {
  static const Set<String> _ignoredDirs = {
    'results',
    'batch_results',
    'logs',
    '__pycache__',
    'derivatives',
  };

  /// Recursively discovers all subject/session units inside a study folder.
  static List<BatchSubjectItem> discoverStudyFolder(String rootFolder) {
    final root = Directory(rootFolder);
    if (!root.existsSync()) return const [];

    final discoveredPaths = <String>[];
    final seen = <String>{};

    void walk(Directory dir, int depth) {
      if (depth > 3) return;
      final name = FmriSessionState.basename(dir.path);
      if (name.startsWith('.') ||
          name.endsWith('.app') ||
          _ignoredDirs.contains(name.toLowerCase())) {
        return;
      }

      if (_isSubjectUnit(dir, allowDirectFiles: depth > 0 || !_hasSubdirs(dir))) {
        final norm = dir.path;
        if (seen.add(norm)) discoveredPaths.add(norm);
        return;
      }

      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      final subDirs = entries.whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final sub in subDirs) {
        walk(sub, depth + 1);
      }
    }

    walk(root, 0);

    return discoveredPaths
        .map((p) => _itemFromFolder(p, studyRoot: root.path))
        .where((it) => it.detectedKind != DetectedDatasetKind.empty)
        .toList();
  }

  static BatchSubjectItem fromSingleFolder(String folderPath) =>
      _itemFromFolder(folderPath);

  static BatchSubjectItem fromPickedFile(String filePath) {
    final s = FmriSessionState();
    final scan = s.handlePickedFile(filePath);
    final item = _populateItemFromState(
      folderPath: scan.rootFolder,
      s: s,
      kind: scan.kind,
      studyRoot: null,
    );
    if (FmriSessionState.isNiftiFile(filePath)) {
      final lower = FmriSessionState.basename(filePath).toLowerCase();
      if (lower.contains('mni') ||
          (item.boldMniPath.isEmpty && item.detectedKind == DetectedDatasetKind.preprocessed)) {
        item.boldMniPath = filePath;
        item.detectedKind = DetectedDatasetKind.preprocessed;
      } else if (item.rawBoldPath.isEmpty && !lower.contains('t1')) {
        item.rawBoldPath = filePath;
        if (item.detectedKind == DetectedDatasetKind.empty) {
          item.detectedKind = DetectedDatasetKind.rawNifti;
        }
      }
    }
    return item;
  }

  static BatchSubjectItem _itemFromFolder(String folderPath, {String? studyRoot}) {
    final s = FmriSessionState();
    final scan = s.scanFolder(folderPath);
    return _populateItemFromState(
      folderPath: scan.rootFolder,
      s: s,
      kind: scan.kind,
      studyRoot: studyRoot,
    );
  }

  static BatchSubjectItem _populateItemFromState({
    required String folderPath,
    required FmriSessionState s,
    required DetectedDatasetKind kind,
    String? studyRoot,
  }) {
    var subj = FmriSessionState.basename(folderPath);
    var ses = '';
    var id = subj;

    if (studyRoot != null && folderPath.startsWith(studyRoot)) {
      var rel = folderPath.substring(studyRoot.length);
      rel = rel.replaceFirst(RegExp(r'^[/\\]+'), '');
      if (rel.isNotEmpty) {
        final parts = rel.split(RegExp(r'[/\\]+'));
        if (parts.length == 1) {
          subj = parts[0];
          id = subj;
        } else {
          subj = parts[0];
          ses = parts.sublist(1).join('_');
          id = '${subj}_$ses';
        }
      }
    }

    return BatchSubjectItem(
      id: id,
      folderPath: folderPath,
      subjectLabel: subj,
      sessionLabel: ses,
      detectedKind: kind,
      t1DicomDir: s.t1DicomDir,
      boldDicomDir: s.boldDicomDir,
      rawT1Path: s.rawT1Path,
      rawBoldPath: s.rawBoldPath,
      boldMniPath: s.boldMniPath,
      atlasPath: s.atlasPath,
      labelsJsonPath: s.labelsJsonPath,
      wmMaskPath: s.wmMaskPath,
      csfMaskPath: s.csfMaskPath,
      confoundsPath: s.confoundsPath,
      lesionMaskPath: s.lesionMaskPath,
      resultsDir: s.resultsDir,
    );
  }

  static bool _hasSubdirs(Directory dir) {
    try {
      return dir.listSync(followLinks: false).any(
        (e) => e is Directory && !FmriSessionState.basename(e.path).startsWith('.'),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _isSubjectUnit(Directory dir, {required bool allowDirectFiles}) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return false;
    }

    var hasPreproc = false;
    var hasRawNifti = false;
    var hasAnat = false;
    var hasFunc = false;
    var hasDicomSeriesSubdir = false;
    var hasDirectNifti = false;
    var hasDirectDicom = false;

    for (final e in entries) {
      final name = FmriSessionState.basename(e.path);
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        final lower = name.toLowerCase();
        if (lower == 'preproc' && _dirHasNifti(e)) hasPreproc = true;
        if (lower == 'raw_nifti' && _dirHasNifti(e)) hasRawNifti = true;
        if (lower == 'anat' && _dirHasNifti(e)) hasAnat = true;
        if (lower == 'func' && _dirHasNifti(e)) hasFunc = true;
        if (_dirHasDicom(e)) hasDicomSeriesSubdir = true;
      } else if (e is File && allowDirectFiles) {
        if (FmriSessionState.isNiftiFile(name)) hasDirectNifti = true;
        if (FmriSessionState.isDicomFile(name)) hasDirectDicom = true;
      }
    }

    return hasPreproc ||
        hasRawNifti ||
        hasAnat ||
        hasFunc ||
        hasDicomSeriesSubdir ||
        hasDirectNifti ||
        hasDirectDicom;
  }

  static bool _dirHasNifti(Directory dir) {
    try {
      return dir.listSync(followLinks: false).any(
        (e) => e is File && FmriSessionState.isNiftiFile(e.path),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _dirHasDicom(Directory dir) {
    try {
      return dir.listSync(followLinks: false).any(
        (e) => e is File && FmriSessionState.isDicomFile(e.path),
      );
    } catch (_) {
      return false;
    }
  }
}

class BatchRunner {
  static Future<void> runBatch({
    required List<BatchSubjectItem> items,
    required BatchRunConfig config,
    required FmriSessionState sidecarRunner,
    required bool Function() isCancelled,
    required void Function(int currentIdx, int totalSelected, String stageLabel)
    onProgress,
  }) async {
    final selected = items.where((it) => it.selected).toList();
    if (selected.isEmpty) return;

    for (var i = 0; i < selected.length; i++) {
      if (isCancelled()) break;
      final item = selected[i];
      item.status = BatchItemStatus.running;
      item.errorMessage = null;
      item.statusDetail = 'Starting…';
      onProgress(i + 1, selected.length, '${item.id}: starting…');

      try {
        // 1. DICOM -> NIfTI
        if (config.runDicomConvert &&
            item.boldMniPath.isEmpty &&
            item.rawBoldPath.isEmpty &&
            item.t1DicomDir.isNotEmpty &&
            item.boldDicomDir.isNotEmpty) {
          item.statusDetail = 'Converting DICOMs (dcm2niix)…';
          onProgress(
            i + 1,
            selected.length,
            '${item.id}: converting DICOMs with dcm2niix…',
          );
          final outDir =
              '${item.folderPath}${Platform.pathSeparator}raw_nifti';
          final code = await sidecarRunner.runSidecarModule(
            module: 'ccs_fmri_sidecar.dicom_convert',
            args: [
              '--t1-dicom',
              item.t1DicomDir,
              '--bold-dicom',
              item.boldDicomDir,
              '--out',
              outDir,
            ],
            onLog: (_) {},
          );
          if (code != 0) {
            throw Exception('dcm2niix failed with exit code $code');
          }
          _refreshItemPaths(item, item.folderPath);
        }

        if (isCancelled()) break;

        // 2. ANTsPy Preprocessing
        final needsPreproc =
            item.boldMniPath.isEmpty || !config.skipExistingPreproc;
        if (config.runPreprocess &&
            needsPreproc &&
            item.rawT1Path.isNotEmpty &&
            item.rawBoldPath.isNotEmpty) {
          item.statusDetail = 'ANTsPy preprocessing (~2 min)…';
          onProgress(
            i + 1,
            selected.length,
            '${item.id}: ANTsPy spatial normalization…',
          );
          final preprocOut =
              '${item.folderPath}${Platform.pathSeparator}preproc';
          final args = <String>[
            '--t1',
            item.rawT1Path,
            '--bold',
            item.rawBoldPath,
            '--out',
            preprocOut,
            '--transform',
            config.transform,
            '--template',
            config.templateId,
            '--lesion-mode',
            config.lesionMode,
          ];
          if (config.applyLesionMaskIfPresent && item.lesionMaskPath.isNotEmpty) {
            args.addAll(['--lesion-mask', item.lesionMaskPath]);
          }
          final code = await sidecarRunner.runSidecarModule(
            module: 'ccs_fmri_sidecar.preprocess',
            args: args,
            onLog: (_) {},
          );
          if (code != 0) {
            throw Exception('ANTsPy preprocess failed with exit code $code');
          }
          _refreshItemPaths(item, item.folderPath);
        }

        if (isCancelled()) break;

        // 3. Rust Denoising, FC, Partial, GCMI, TE
        if (config.runDenoiseAndFc) {
          if (item.boldMniPath.isEmpty || item.atlasPath.isEmpty) {
            item.status = BatchItemStatus.skipped;
            item.statusDetail = 'Missing BOLD MNI or Schaefer Atlas';
            onProgress(i + 1, selected.length, '${item.id}: skipped');
            await exportBatchSummary(items, config.batchOutDir);
            continue;
          }

          item.statusDetail = 'Rust Denoising, Partial FC, GCMI & TE…';
          onProgress(
            i + 1,
            selected.length,
            '${item.id}: running Rust connectivity pipeline…',
          );
          final resDir = item.resultsDir.isNotEmpty
              ? item.resultsDir
              : '${File(item.boldMniPath).parent.path}${Platform.pathSeparator}results';

          final lesionOpt =
              (config.applyLesionMaskIfPresent && item.lesionMaskPath.isNotEmpty)
              ? item.lesionMaskPath
              : null;

          final summary = await rust_api.runLesionAwarePipeline(
            boldPath: item.boldMniPath,
            atlasPath: item.atlasPath,
            lesionMaskPath: lesionOpt,
            atlasLabelsJsonPath:
                item.labelsJsonPath.isEmpty ? null : item.labelsJsonPath,
            wmMaskPath: item.wmMaskPath.isEmpty ? null : item.wmMaskPath,
            csfMaskPath: item.csfMaskPath.isEmpty ? null : item.csfMaskPath,
            confoundsTsvPath:
                item.confoundsPath.isEmpty ? null : item.confoundsPath,
            lowHz: config.lowHz,
            highHz: config.highHz,
            fdThresholdMm: config.fdThresholdMm,
            maxDamagePct: config.maxDamagePct,
            lesionDilateVoxels: 1,
            censorMode: 'interpolate',
            outDir: resDir,
          );

          item.resultsDir = summary.exportedDir ?? resDir;
          item.nIntactRois = summary.nIntactRois;
          item.nRois = summary.nRois;
          item.meanFdMm = summary.meanFdMm;
          item.pctScrubbed = summary.pctScrubbed;
          item.rawFcMean = summary.rawFcMean;
          item.cleanFcMean = summary.cleanFcMean;
          item.meanAbsFc = summary.meanAbsFc;
          item.meanAbsPartialFc = summary.meanAbsPartialFc;
          item.meanGcmiBits = summary.meanGcmiBits;
          item.meanTeBits = summary.meanTeBits;
          item.globalEfficiency = summary.globalEfficiency;
          item.meanHomotopicFc = summary.meanHomotopicFc;
          item.lesionVolumeMl = summary.lesionVolumeMl;
          item.totalMs = summary.totalMs;

          // 4. Sliding-Window Timeseries Dynamics
          if (config.runDynamics) {
            item.statusDetail = 'Computing ACW / LZC / SampEn / PLE dynamics…';
            onProgress(
              i + 1,
              selected.length,
              '${item.id}: computing timeseries dynamics…',
            );
            final dyn = await rust_api.computeCachedDynamics(
              windowLen: config.dynWindowLen,
              step: config.dynStep,
              lowHz: config.lowHz,
              highHz: config.highHz,
              outDir: item.resultsDir,
            );
            item.acw0Mean = dyn.acw0Mean;
            item.acw50Mean = dyn.acw50Mean;
            item.lzcMean = dyn.lzcMean;
            item.sampenMean = dyn.sampenMean;
            item.pleMean = dyn.pleMean;
          }
        }

        item.status = BatchItemStatus.done;
        item.statusDetail = config.runDenoiseAndFc
            ? '${item.nIntactRois}/${item.nRois} ROIs • |FC|=${item.meanAbsFc.toStringAsFixed(3)} • GCMI=${item.meanGcmiBits.toStringAsFixed(3)}'
            : 'Preprocessed';
      } catch (e) {
        item.status = BatchItemStatus.failed;
        item.errorMessage = e.toString();
        item.statusDetail = 'Failed: $e';
      }

      onProgress(i + 1, selected.length, '${item.id}: ${item.status.name}');
      await exportBatchSummary(items, config.batchOutDir);
    }
  }

  static void _refreshItemPaths(BatchSubjectItem item, String folderPath) {
    final s = FmriSessionState();
    final scan = s.scanFolder(folderPath);
    item.detectedKind = scan.kind;
    if (s.rawT1Path.isNotEmpty) item.rawT1Path = s.rawT1Path;
    if (s.rawBoldPath.isNotEmpty) item.rawBoldPath = s.rawBoldPath;
    if (s.boldMniPath.isNotEmpty) item.boldMniPath = s.boldMniPath;
    if (s.atlasPath.isNotEmpty) item.atlasPath = s.atlasPath;
    if (s.labelsJsonPath.isNotEmpty) item.labelsJsonPath = s.labelsJsonPath;
    if (s.wmMaskPath.isNotEmpty) item.wmMaskPath = s.wmMaskPath;
    if (s.csfMaskPath.isNotEmpty) item.csfMaskPath = s.csfMaskPath;
    if (s.confoundsPath.isNotEmpty) item.confoundsPath = s.confoundsPath;
    if (s.lesionMaskPath.isNotEmpty) item.lesionMaskPath = s.lesionMaskPath;
    if (s.resultsDir.isNotEmpty) item.resultsDir = s.resultsDir;
  }

  static Future<void> exportBatchSummary(
    List<BatchSubjectItem> items,
    String batchOutDir,
  ) async {
    if (batchOutDir.trim().isEmpty) return;
    final dir = Directory(batchOutDir.trim());
    dir.createSync(recursive: true);

    final csvBuf = StringBuffer()
      ..writeln(
        'id,subject,session,status,n_intact_rois,n_rois,mean_fd_mm,pct_scrubbed,raw_fc_mean,clean_fc_mean,mean_abs_fc,mean_abs_partial_fc,mean_gcmi_bits,mean_te_bits,global_efficiency,mean_homotopic_fc,lesion_volume_ml,acw0_mean,acw50_mean,lzc_mean,sampen_mean,ple_mean,total_ms,results_dir,folder_path',
      );
    for (final it in items) {
      csvBuf.writeln(
        '${_csvCell(it.id)},${_csvCell(it.subjectLabel)},${_csvCell(it.sessionLabel)},${it.status.name},'
        '${it.nIntactRois},${it.nRois},${it.meanFdMm.toStringAsFixed(4)},${it.pctScrubbed.toStringAsFixed(2)},'
        '${it.rawFcMean.toStringAsFixed(5)},${it.cleanFcMean.toStringAsFixed(5)},'
        '${it.meanAbsFc.toStringAsFixed(5)},${it.meanAbsPartialFc.toStringAsFixed(5)},'
        '${it.meanGcmiBits.toStringAsFixed(5)},${it.meanTeBits.toStringAsFixed(5)},'
        '${it.globalEfficiency.toStringAsFixed(5)},${it.meanHomotopicFc.toStringAsFixed(5)},'
        '${it.lesionVolumeMl.toStringAsFixed(3)},${it.acw0Mean.toStringAsFixed(4)},'
        '${it.acw50Mean.toStringAsFixed(4)},${it.lzcMean.toStringAsFixed(4)},'
        '${it.sampenMean.toStringAsFixed(4)},${it.pleMean.toStringAsFixed(4)},'
        '${it.totalMs.toStringAsFixed(2)},${_csvCell(it.resultsDir)},${_csvCell(it.folderPath)}',
      );
    }
    File('${dir.path}${Platform.pathSeparator}batch_summary.csv')
        .writeAsStringSync(csvBuf.toString(), flush: true);

    final jsonList = items.map((e) => e.toJsonMap()).toList();
    File('${dir.path}${Platform.pathSeparator}batch_summary.json')
        .writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(jsonList),
          flush: true,
        );
  }

  static String _csvCell(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }
}
