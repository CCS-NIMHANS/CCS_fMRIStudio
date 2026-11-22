import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

enum DetectedDatasetKind { preprocessed, rawNifti, rawDicom, empty }

class DicomSeriesInfo {
  const DicomSeriesInfo({
    required this.path,
    required this.name,
    required this.fileCount,
    required this.guessedRole,
  });

  final String path;
  final String name;
  final int fileCount;
  final String guessedRole; // 'bold', 't1w', 'flair', 'other'

  String get displayLabel => '$name ($fileCount files)';
}

class FolderScanResult {
  const FolderScanResult({
    required this.rootFolder,
    required this.kind,
    required this.detectedLabels,
    required this.dicomSeries,
    this.selectedT1DicomDir,
    this.selectedBoldDicomDir,
    this.selectedFlairDicomDir,
    this.notice,
  });

  final String rootFolder;
  final DetectedDatasetKind kind;
  final List<String> detectedLabels;
  final List<DicomSeriesInfo> dicomSeries;
  final String? selectedT1DicomDir;
  final String? selectedBoldDicomDir;
  final String? selectedFlairDicomDir;
  final String? notice;

  FolderScanResult copyWith({String? notice}) => FolderScanResult(
        rootFolder: rootFolder,
        kind: kind,
        detectedLabels: detectedLabels,
        dicomSeries: dicomSeries,
        selectedT1DicomDir: selectedT1DicomDir,
        selectedBoldDicomDir: selectedBoldDicomDir,
        selectedFlairDicomDir: selectedFlairDicomDir,
        notice: notice ?? this.notice,
      );
}

class FmriSessionState extends ChangeNotifier {
  static const String bundleVersion = '0.3.0';

  static const List<String> _bundledAssets = [
    'assets/templates/registry.json',
    'python_sidecar/pyproject.toml',
    'python_sidecar/README.md',
    'python_sidecar/uv.lock',
    'python_sidecar/src/ccs_fmri_sidecar/__init__.py',
    'python_sidecar/src/ccs_fmri_sidecar/dicom_convert.py',
    'python_sidecar/src/ccs_fmri_sidecar/preprocess.py',
    'python_sidecar/src/ccs_fmri_sidecar/lesion_segment.py',
    'python_sidecar/src/ccs_fmri_sidecar/templates.py',
    'python_sidecar/src/ccs_fmri_sidecar/group_lmm.py',
    'python_sidecar/src/ccs_fmri_sidecar/benchmark_vs_nilearn.py',
  ];

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
  String resultsDir = '';

  String? sidecarDirOverride;
  FolderScanResult? lastScan;

  void reset() {
    t1DicomDir = '';
    boldDicomDir = '';
    dicomOutDir = '';
    rawT1Path = '';
    rawBoldPath = '';
    flairPath = '';
    preprocOutDir = '';
    t1MniPath = '';
    boldMniPath = '';
    atlasPath = '';
    labelsJsonPath = '';
    wmMaskPath = '';
    csfMaskPath = '';
    confoundsPath = '';
    lesionMaskPath = '';
    resultsDir = '';
    lastScan = null;
    notifyListeners();
  }

  static bool isNiftiFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.nii') || lower.endsWith('.nii.gz');
  }

  static bool isDicomFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.ima') ||
        lower.endsWith('.dcm') ||
        lower.endsWith('.dicom');
  }

  static String basename(String path) {
    final trimmed = path.replaceFirst(RegExp(r'[/\\]+$'), '');
    final idx = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
  }

  static String guessDicomRole(String folderName) {
    final lower = folderName.toLowerCase();
    if (RegExp(r'(fmri|bold|ep2d|rs_?fmri|rest|func|epi)').hasMatch(lower)) {
      return 'bold';
    }
    if (RegExp(r'(flair|t2w|t2_)').hasMatch(lower)) {
      return 'flair';
    }
    if (RegExp(r'(mprage|t1w|t1_|_t1|bravo|spgr|anat)').hasMatch(lower)) {
      return 't1w';
    }
    return 'other';
  }

  /// Smart recursive scanner that auto-detects preprocessed MNI outputs,
  /// raw NIfTI / BIDS files, or scanner DICOM series (e.g. `.IMA` / `.dcm`).
  FolderScanResult scanFolder(String folderPath, {String? notice}) {
    final rootDir = Directory(folderPath);
    if (!rootDir.existsSync()) {
      final empty = FolderScanResult(
        rootFolder: folderPath,
        kind: DetectedDatasetKind.empty,
        detectedLabels: const [],
        dicomSeries: const [],
        notice: notice,
      );
      lastScan = empty;
      notifyListeners();
      return empty;
    }

    final candidateDirs = _collectCandidateDirs(rootDir, maxDepth: 2);
    final foundLabels = <String>[];

    String? pickExact(List<String> names) {
      for (final d in candidateDirs) {
        for (final name in names) {
          final f = File('${d.path}${Platform.pathSeparator}$name');
          if (f.existsSync()) return f.path;
        }
      }
      return null;
    }

    String? pickByPattern(
      RegExp pattern, {
      bool excludeMni = false,
      bool excludeDerived = false,
    }) {
      for (final d in candidateDirs) {
        List<FileSystemEntity> entries;
        try {
          entries = d.listSync(followLinks: false);
        } catch (_) {
          continue;
        }
        final matches = <String>[];
        for (final e in entries) {
          if (e is! File) continue;
          final name = basename(e.path);
          if (name.startsWith('.')) continue;
          final lower = name.toLowerCase();
          if (!isNiftiFile(lower)) continue;
          if (excludeMni && lower.contains('mni')) continue;
          if (excludeDerived &&
              (lower.contains('_n4') ||
                  lower.contains('mask') ||
                  lower.contains('schaefer') ||
                  lower.contains('lesion'))) {
            continue;
          }
          if (pattern.hasMatch(lower)) matches.add(e.path);
        }
        if (matches.isNotEmpty) {
          matches.sort();
          return matches.first;
        }
      }
      return null;
    }

    // 1. Preprocessed MNI outputs
    final boldMni = pickExact(['bold_mni.nii', 'bold_mni.nii.gz']) ??
        pickByPattern(RegExp(r'(bold|func|fmri|rest).*mni'));
    if (boldMni != null) {
      boldMniPath = boldMni;
      foundLabels.add('bold_mni');
    }
    final t1Mni = pickExact(['t1w_mni.nii.gz', 't1w_mni.nii', 't1w_n4.nii.gz']) ??
        pickByPattern(RegExp(r'(t1w?|mprage).*mni'));
    if (t1Mni != null) {
      t1MniPath = t1Mni;
      foundLabels.add('t1w_mni');
    }
    final atlas = pickExact(['schaefer400_mni.nii.gz', 'schaefer400_mni.nii']);
    if (atlas != null) {
      atlasPath = atlas;
      foundLabels.add('schaefer400_mni');
    }
    final labels = pickExact(['schaefer400_labels.json']);
    if (labels != null) {
      labelsJsonPath = labels;
      foundLabels.add('schaefer400_labels.json');
    }
    final wm = pickExact(['wm_mask_mni.nii.gz', 'wm_mask_mni.nii']);
    if (wm != null) {
      wmMaskPath = wm;
      foundLabels.add('wm_mask_mni');
    }
    final csf = pickExact(['csf_mask_mni.nii.gz', 'csf_mask_mni.nii']);
    if (csf != null) {
      csfMaskPath = csf;
      foundLabels.add('csf_mask_mni');
    }
    final conf = pickExact(['confounds.tsv']);
    if (conf != null) {
      confoundsPath = conf;
      foundLabels.add('confounds.tsv');
    }
    final lesion = pickExact([
      'lesion_mask_mni.nii.gz',
      'lesion_mask_mni.nii',
      'lesion_mask.nii.gz',
      'lesion_mask.nii',
    ]);
    if (lesion != null) {
      lesionMaskPath = lesion;
      foundLabels.add('lesion_mask');
    }

    // 2. Raw / converted NIfTI files (BIDS or flat folder)
    final rawT1 = pickExact(['t1w.nii.gz', 't1w.nii']) ??
        pickByPattern(
          RegExp(r'(t1w|mprage|_t1\b)'),
          excludeMni: true,
          excludeDerived: true,
        );
    if (rawT1 != null) {
      rawT1Path = rawT1;
      foundLabels.add('t1w');
    }
    final rawBold = pickExact(['bold.nii.gz', 'bold.nii']) ??
        pickByPattern(
          RegExp(r'(bold|fmri|rest|ep2d)'),
          excludeMni: true,
          excludeDerived: true,
        );
    if (rawBold != null) {
      rawBoldPath = rawBold;
      foundLabels.add('bold');
    }
    final flair = pickExact(['flair.nii.gz', 'flair.nii']) ??
        pickByPattern(RegExp(r'flair'), excludeMni: true);
    if (flair != null) {
      flairPath = flair;
      foundLabels.add('flair');
    }

    // 3. Raw scanner DICOM series (.IMA / .dcm / .dicom)
    final dicomSeries = <DicomSeriesInfo>[];
    for (final d in candidateDirs) {
      final count = _countDicomFiles(d);
      if (count > 0) {
        final name = basename(d.path);
        dicomSeries.add(
          DicomSeriesInfo(
            path: d.path,
            name: name,
            fileCount: count,
            guessedRole: guessDicomRole(name),
          ),
        );
      }
    }
    dicomSeries.sort((a, b) {
      const order = {'bold': 0, 't1w': 1, 'flair': 2, 'other': 3};
      final ra = order[a.guessedRole] ?? 3;
      final rb = order[b.guessedRole] ?? 3;
      if (ra != rb) return ra.compareTo(rb);
      return b.fileCount.compareTo(a.fileCount);
    });

    final selectedBold = _pickBestBoldSeries(dicomSeries);
    final selectedT1 = _pickBestT1Series(dicomSeries);
    final selectedFlair =
        dicomSeries.where((s) => s.guessedRole == 'flair').firstOrNull?.path;

    if (selectedT1 != null) {
      t1DicomDir = selectedT1;
      foundLabels.add('T1w DICOM');
    }
    if (selectedBold != null) {
      boldDicomDir = selectedBold;
      foundLabels.add('BOLD DICOM');
    }

    final DetectedDatasetKind kind;
    if (boldMni != null) {
      kind = DetectedDatasetKind.preprocessed;
      preprocOutDir = File(boldMni).parent.path;
      resultsDir = '$preprocOutDir${Platform.pathSeparator}results';
    } else if (rawT1 != null || rawBold != null) {
      kind = DetectedDatasetKind.rawNifti;
      final rawParent = Directory(
        '${rootDir.path}${Platform.pathSeparator}raw_nifti',
      );
      if (rawParent.existsSync()) {
        dicomOutDir = rawParent.path;
      }
      preprocOutDir = '${rootDir.path}${Platform.pathSeparator}preproc';
      resultsDir = '$preprocOutDir${Platform.pathSeparator}results';
    } else if (dicomSeries.isNotEmpty) {
      kind = DetectedDatasetKind.rawDicom;
      dicomOutDir = '${rootDir.path}${Platform.pathSeparator}raw_nifti';
      preprocOutDir = '${rootDir.path}${Platform.pathSeparator}preproc';
      resultsDir = '$preprocOutDir${Platform.pathSeparator}results';
    } else {
      kind = DetectedDatasetKind.empty;
    }

    final result = FolderScanResult(
      rootFolder: rootDir.path,
      kind: kind,
      detectedLabels: foundLabels,
      dicomSeries: dicomSeries,
      selectedT1DicomDir: selectedT1,
      selectedBoldDicomDir: selectedBold,
      selectedFlairDicomDir: selectedFlair,
      notice: notice,
    );
    lastScan = result;
    notifyListeners();
    return result;
  }

  /// Handles picking a single file from the UI:
  /// - If `.IMA`/`.dcm`, automatically scans the owning patient/series folder
  ///   so the user isn't hit with a NIfTI error.
  /// - If `.nii`/`.nii.gz`, scans its folder and ensures the file is populated.
  FolderScanResult handlePickedFile(String filePath) {
    final file = File(filePath);
    final parent = file.parent;
    if (isDicomFile(filePath)) {
      final grandParent = parent.parent;
      final useGrandParent = _looksLikePatientDicomRoot(grandParent);
      final targetDir = useGrandParent ? grandParent.path : parent.path;
      final res = scanFolder(
        targetDir,
        notice:
            'Detected scanner DICOM (${basename(filePath)}). Scanned folder "${basename(targetDir)}" and found the series below for dcm2niix conversion.',
      );
      return res;
    }

    final res = scanFolder(parent.path);
    if (isNiftiFile(filePath)) {
      final lower = basename(filePath).toLowerCase();
      if (lower.contains('mni') ||
          (!lower.contains('t1') && !lower.contains('flair') && boldMniPath.isEmpty && rawBoldPath.isEmpty)) {
        if (lower.contains('mni') || boldMniPath.isEmpty && res.kind == DetectedDatasetKind.preprocessed) {
          boldMniPath = filePath;
        } else if (rawBoldPath.isEmpty) {
          rawBoldPath = filePath;
        }
      } else if (lower.contains('t1') || lower.contains('mprage')) {
        if (rawT1Path.isEmpty) rawT1Path = filePath;
      } else if (lower.contains('flair')) {
        if (flairPath.isEmpty) flairPath = filePath;
      }
      notifyListeners();
    }
    return res;
  }

  /// Backwards-compatible wrapper used by earlier callers and step transitions.
  List<String> autoPopulateFromFolder(String folderPath) =>
      scanFolder(folderPath).detectedLabels;

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
          File('${d.path}${Platform.pathSeparator}pyproject.toml')
              .existsSync()) {
        return d.absolute.path;
      }
    }
    return null;
  }

  /// Ensures `python_sidecar/` and `assets/templates/` exist on disk by
  /// extracting bundled Flutter assets into Application Support when running
  /// inside a packaged `.app` / `.exe` / Linux release bundle.
  Future<String?> ensureSidecarProjectDir() async {
    final existing = findSidecarProjectDir();
    if (existing != null) return existing;

    final supportRoot = _appSupportBaseDir();
    if (supportRoot == null) return null;
    final baseDir = Directory(
      '${supportRoot.path}${Platform.pathSeparator}CCS_fMRIStudio',
    );
    final marker = File(
      '${baseDir.path}${Platform.pathSeparator}.bundle_version',
    );
    final sidecarDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}python_sidecar',
    );
    if (marker.existsSync() &&
        marker.readAsStringSync().trim() == bundleVersion &&
        sidecarDir.existsSync()) {
      return sidecarDir.path;
    }

    try {
      for (final assetPath in _bundledAssets) {
        final data = await rootBundle.load(assetPath);
        final outPath =
            '${baseDir.path}${Platform.pathSeparator}${assetPath.replaceAll('/', Platform.pathSeparator)}';
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      marker.writeAsStringSync(bundleVersion, flush: true);
      return sidecarDir.path;
    } catch (_) {
      return null;
    }
  }

  static Directory? _appSupportBaseDir() {
    final env = Platform.environment;
    if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home == null || home.isEmpty) return null;
      return Directory('$home/Library/Application Support');
    }
    if (Platform.isWindows) {
      final appData = env['LOCALAPPDATA'] ?? env['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return Directory(appData);
    }
    final xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return Directory(xdg);
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    return Directory('$home/.local/share');
  }

  static String? findUvExecutable() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final candidates = <String>[
      if (home.isNotEmpty && !Platform.isWindows) '$home/.local/bin/uv',
      if (home.isNotEmpty && !Platform.isWindows) '$home/.cargo/bin/uv',
      if (home.isNotEmpty && Platform.isWindows)
        '$home\\.local\\bin\\uv.exe',
      if (Platform.isMacOS) '/opt/homebrew/bin/uv',
      if (!Platform.isWindows) '/usr/local/bin/uv',
      if (Platform.isWindows) 'uv.exe',
      'uv',
    ];
    for (final c in candidates) {
      if (c == 'uv' || c == 'uv.exe') return c;
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
    final sidecarDir = await ensureSidecarProjectDir();
    if (sidecarDir == null) {
      onLog(
        'Error: Could not locate or extract python_sidecar/. Check bundled assets.',
      );
      return -1;
    }
    final uvBin = findUvExecutable();
    if (uvBin == null) {
      onLog(
        'Error: `uv` binary not found. Install uv from https://docs.astral.sh/uv/ or add it to PATH.',
      );
      return -1;
    }

    final home = Platform.environment['HOME'] ?? '';
    final pathEnv = Platform.environment['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    final extraParts = <String>[
      if (home.isNotEmpty && !Platform.isWindows) '$home/.local/bin',
      if (Platform.isMacOS) '/opt/homebrew/bin',
      if (!Platform.isWindows) '/usr/local/bin',
      if (pathEnv.isNotEmpty) pathEnv,
    ];

    final proc = await Process.start(
      uvBin,
      ['run', '--directory', sidecarDir, 'python', '-m', module, ...args],
      environment: {'PATH': extraParts.join(sep)},
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

  static List<Directory> _collectCandidateDirs(
    Directory root, {
    required int maxDepth,
  }) {
    final out = <Directory>[root];
    void walk(Directory dir, int depth) {
      if (depth >= maxDepth) return;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      final subDirs = <Directory>[];
      for (final e in entries) {
        if (e is Directory) {
          final name = basename(e.path);
          if (name.startsWith('.') || name.endsWith('.app')) continue;
          subDirs.add(e);
        }
      }
      subDirs.sort((a, b) {
        // Prioritize standard output subdirectories first.
        const prio = ['preproc', 'raw_nifti', 'anat', 'func'];
        final ia = prio.indexOf(basename(a.path).toLowerCase());
        final ib = prio.indexOf(basename(b.path).toLowerCase());
        if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
        if (ia >= 0) return -1;
        if (ib >= 0) return 1;
        return a.path.compareTo(b.path);
      });
      for (final sub in subDirs) {
        out.add(sub);
        walk(sub, depth + 1);
      }
    }

    walk(root, 0);
    return out;
  }

  static int _countDicomFiles(Directory dir) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return 0;
    }
    var count = 0;
    for (final e in entries) {
      if (e is File && isDicomFile(e.path)) count++;
    }
    return count;
  }

  static bool _looksLikePatientDicomRoot(Directory dir) {
    if (!dir.existsSync()) return false;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return false;
    }
    var seriesDirs = 0;
    var subDirCount = 0;
    for (final e in entries) {
      if (e is Directory) {
        final name = basename(e.path);
        if (name.startsWith('.')) continue;
        subDirCount++;
        if (subDirCount > 30) return false;
        if (_countDicomFiles(e) > 0) seriesDirs++;
      }
    }
    return seriesDirs >= 2;
  }

  static String? _pickBestBoldSeries(List<DicomSeriesInfo> series) {
    final bolds = series.where((s) => s.guessedRole == 'bold').toList();
    if (bolds.isEmpty) return null;
    bolds.sort((a, b) => b.fileCount.compareTo(a.fileCount));
    return bolds.first.path;
  }

  static String? _pickBestT1Series(List<DicomSeriesInfo> series) {
    final t1s = series.where((s) => s.guessedRole == 't1w').toList();
    if (t1s.isEmpty) return null;
    int score(DicomSeriesInfo s) {
      final lower = s.name.toLowerCase();
      var val = s.fileCount;
      if (lower.contains('iso')) val += 1000;
      if (lower.contains('sag') || lower.contains('3d')) val += 500;
      return val;
    }

    t1s.sort((a, b) => score(b).compareTo(score(a)));
    return t1s.first.path;
  }
}
