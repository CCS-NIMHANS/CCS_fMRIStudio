import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class FmriSessionState extends ChangeNotifier {
  String t1DicomDir = '';
  String boldDicomDir = '';
  String dicomOutDir = '';

  String rawT1Path = '';
  String rawBoldPath = '';
  String flairPath = '';
  String preprocOutDir = '';

  String t1MniPath = '';
  String boldMniPath = '';
  String atlasPath = '';
  String labelsJsonPath = '';
  String wmMaskPath = '';
  String csfMaskPath = '';
  String confoundsPath = '';
  String lesionMaskPath = '';

  String? sidecarDirOverride;

  /// Scans a folder for preprocessed or converted NIfTI/atlas/confound files
  /// and auto-populates every matching step path.
  List<String> autoPopulateFromFolder(String folderPath) {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return const [];
    final found = <String>[];

    String? pickFirst(List<String> names) {
      for (final name in names) {
        final f = File('${dir.path}${Platform.pathSeparator}$name');
        if (f.existsSync()) return f.path;
      }
      return null;
    }

    final rawT1 = pickFirst(['t1w.nii.gz', 't1w.nii']);
    if (rawT1 != null) {
      rawT1Path = rawT1;
      found.add('t1w');
    }
    final rawBold = pickFirst(['bold.nii.gz', 'bold.nii']);
    if (rawBold != null) {
      rawBoldPath = rawBold;
      found.add('bold');
    }

    final boldMni = pickFirst(['bold_mni.nii', 'bold_mni.nii.gz']);
    if (boldMni != null) {
      boldMniPath = boldMni;
      found.add('bold_mni');
    }
    final t1Mni = pickFirst(['t1w_mni.nii.gz', 't1w_mni.nii', 't1w_n4.nii.gz']);
    if (t1Mni != null) {
      t1MniPath = t1Mni;
      found.add('t1w_mni');
    }
    final atlas = pickFirst(['schaefer400_mni.nii.gz', 'schaefer400_mni.nii']);
    if (atlas != null) {
      atlasPath = atlas;
      found.add('schaefer400_mni');
    }
    final labels = pickFirst(['schaefer400_labels.json']);
    if (labels != null) {
      labelsJsonPath = labels;
      found.add('schaefer400_labels.json');
    }
    final wm = pickFirst(['wm_mask_mni.nii.gz', 'wm_mask_mni.nii']);
    if (wm != null) {
      wmMaskPath = wm;
      found.add('wm_mask_mni');
    }
    final csf = pickFirst(['csf_mask_mni.nii.gz', 'csf_mask_mni.nii']);
    if (csf != null) {
      csfMaskPath = csf;
      found.add('csf_mask_mni');
    }
    final conf = pickFirst(['confounds.tsv']);
    if (conf != null) {
      confoundsPath = conf;
      found.add('confounds.tsv');
    }
    final lesion = pickFirst([
      'lesion_mask_mni.nii.gz',
      'lesion_mask_mni.nii',
      'lesion_mask.nii.gz',
      'lesion_mask.nii',
    ]);
    if (lesion != null) {
      lesionMaskPath = lesion;
      found.add('lesion_mask');
    }

    if (found.isNotEmpty) {
      preprocOutDir = dir.path;
      notifyListeners();
    }
    return found;
  }

  void notifyChanged() => notifyListeners();

  /// Resolves the `python_sidecar` directory from local dev or packaged locations.
  String? findSidecarProjectDir() {
    if (sidecarDirOverride != null &&
        Directory(sidecarDirOverride!).existsSync()) {
      return sidecarDirOverride;
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[
      'python_sidecar',
      '${Directory.current.path}${Platform.pathSeparator}python_sidecar',
      '${exeDir.path}${Platform.pathSeparator}python_sidecar',
      if (Platform.isMacOS)
        '${exeDir.path}${Platform.pathSeparator}..${Platform.pathSeparator}Resources${Platform.pathSeparator}python_sidecar',
    ];
    for (final c in candidates) {
      final d = Directory(c);
      if (d.existsSync() &&
          File('${d.path}${Platform.pathSeparator}pyproject.toml').existsSync()) {
        return d.absolute.path;
      }
    }
    return null;
  }

  static String? findUvExecutable() {
    final home = Platform.environment['HOME'] ?? '';
    final candidates = <String>[
      if (home.isNotEmpty) '$home/.local/bin/uv',
      '/opt/homebrew/bin/uv',
      '/usr/local/bin/uv',
      'uv',
    ];
    for (final c in candidates) {
      if (c == 'uv') return c;
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Streams a Python sidecar module via `uv run` and returns the exit code.
  Future<int> runSidecarModule({
    required String module,
    required List<String> args,
    required void Function(String line) onLog,
  }) async {
    final sidecarDir = findSidecarProjectDir();
    if (sidecarDir == null) {
      onLog(
        'Error: python_sidecar/ folder not found next to the app or workspace.',
      );
      return -1;
    }
    final uvBin = findUvExecutable();
    if (uvBin == null) {
      onLog('Error: `uv` binary not found on PATH.');
      return -1;
    }

    final pathEnv = Platform.environment['PATH'] ?? '';
    final extraPath = '/opt/homebrew/bin:/usr/local/bin:$pathEnv';
    final proc = await Process.start(
      uvBin,
      ['run', '--directory', sidecarDir, 'python', '-m', module, ...args],
      environment: {'PATH': extraPath},
    );

    final outDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLog)
        .asFuture<void>();
    final errDone = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLog)
        .asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    return code;
  }
}
