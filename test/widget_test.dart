import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_fmri_studio/main.dart';
import 'package:ccs_fmri_studio/src/batch_runner.dart';
import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:ccs_fmri_studio/src/session_state.dart';
import 'package:ccs_fmri_studio/src/update_checker.dart';
import 'package:ccs_fmri_studio/widgets/results_dashboard.dart';

void main() {
  testWidgets(
    '5-step pipeline header, labeled Step 4 sliders, and Step 5 dashboard render cleanly',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const CcsFmriStudioApp(enableRustProbe: false));

      expect(find.text('CCS fMRI Studio'), findsOneWidget);
      expect(find.text('Pipeline Progress'), findsOneWidget);
      expect(find.text('Updates'), findsOneWidget);
      expect(find.text('Open Folder'), findsOneWidget);

      expect(find.text('1. Import'), findsWidgets);
      expect(find.text('2. Preprocess'), findsWidgets);
      expect(find.text('3. Lesion (Opt)'), findsOneWidget);
      expect(find.text('4. Denoise'), findsWidgets);
      expect(find.text('5. Results'), findsWidgets);

      expect(find.text('Open Your MRI Scan'), findsOneWidget);
      expect(find.text('Open Patient Folder'), findsOneWidget);
      expect(find.text('Open Single NIfTI File'), findsOneWidget);

      await tester.tap(find.text('2. Preprocess').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Step 2: ANTsPy Spatial Normalization & Motion Correction'),
        findsOneWidget,
      );

      await tester.tap(find.text('3. Lesion'));
      await tester.pumpAndSettle();
      expect(
        find.text('Step 3: TBI / Stroke Lesion Mask Editor'),
        findsOneWidget,
      );

      await tester.tap(find.text('4. Denoise').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Step 4A: Preprocessed Inputs & Lesion Mode'),
        findsOneWidget,
      );
      expect(find.text('Bandpass Low-Pass Cutoff'), findsOneWidget);
      expect(find.text('Motion Scrubbing (FD Threshold)'), findsOneWidget);
      expect(find.text('Max ROI Lesion Damage Exclusion'), findsOneWidget);

      await tester.tap(find.text('5. Results').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Step 5: Results & Biomarkers Dashboard'),
        findsOneWidget,
      );
      expect(find.text('Go to Step 4: Denoise & Compute →'), findsOneWidget);

      await tester.tap(find.text('6. Batch'));
      await tester.pumpAndSettle();
      expect(
        find.text('Step 6: Batch Subject Selection & Pipeline Queue'),
        findsOneWidget,
      );
      expect(find.text('Scan Study Folder'), findsOneWidget);
      expect(find.text('Add Subject Folder'), findsOneWidget);
      expect(find.text('Add NIfTI Files'), findsOneWidget);
    },
  );

  test('FmriSessionState auto-detects DICOM series, .IMA file picks, and preproc folders', () {
    final tmp = Directory.systemTemp.createTempSync('ccs_fmri_scan_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    String p(List<String> parts) => parts.join(Platform.pathSeparator);

    // 1. Simulate Siemens Patient_01/pre DICOM folder structure
    final preDir = Directory(p([tmp.path, 'Patient_01', 'pre']))
      ..createSync(recursive: true);
    final boldDir = Directory(p([preDir.path, 'HEAD_EP2D_RS_FMRI_ADNI3_0023']))
      ..createSync();
    final t1SagIsoDir = Directory(
      p([preDir.path, 'HEAD_T1_MPRAGE_SAG_P2_ISO_NEW_0011']),
    )..createSync();
    final t1CorDir = Directory(p([preDir.path, 'HEAD_T1_MPRAGE_COR_0101']))
      ..createSync();
    final t1TraDir = Directory(p([preDir.path, 'HEAD_T1_MPRAGE_TRA_0100']))
      ..createSync();

    File(p([boldDir.path, 'img_0001.IMA'])).writeAsStringSync('stub');
    File(p([boldDir.path, 'img_0002.IMA'])).writeAsStringSync('stub');
    File(p([t1SagIsoDir.path, 't1_0001.IMA'])).writeAsStringSync('stub');
    File(p([t1CorDir.path, 't1_0001.IMA'])).writeAsStringSync('stub');
    File(p([t1TraDir.path, 't1_0001.IMA'])).writeAsStringSync('stub');

    final session = FmriSessionState();
    final dicomScan = session.scanFolder(preDir.path);
    expect(dicomScan.kind, DetectedDatasetKind.rawDicom);
    expect(dicomScan.dicomSeries.length, 4);
    expect(dicomScan.selectedBoldDicomDir, boldDir.path);
    expect(dicomScan.selectedT1DicomDir, t1SagIsoDir.path);
    expect(session.boldDicomDir, boldDir.path);
    expect(session.t1DicomDir, t1SagIsoDir.path);

    // 2. Picking a single .IMA file automatically promotes to Patient_01/pre DICOM scan
    final sessionFromIma = FmriSessionState();
    final imaScan = sessionFromIma.handlePickedFile(
      p([boldDir.path, 'img_0001.IMA']),
    );
    expect(imaScan.kind, DetectedDatasetKind.rawDicom);
    expect(imaScan.rootFolder, preDir.path);
    expect(imaScan.dicomSeries.length, 4);
    expect(imaScan.notice, isNotNull);

    // 3. Scanning a folder containing preproc/ outputs detects preprocessed MNI files
    final subjRoot = Directory(p([tmp.path, 'SubjectPreproc']))..createSync();
    final preprocDir = Directory(p([subjRoot.path, 'preproc']))..createSync();
    File(p([preprocDir.path, 'bold_mni.nii'])).writeAsStringSync('stub');
    File(p([preprocDir.path, 'schaefer400_mni.nii.gz'])).writeAsStringSync('stub');
    File(p([preprocDir.path, 'confounds.tsv'])).writeAsStringSync('stub');
    File(p([preprocDir.path, 't1w_n4.nii.gz'])).writeAsStringSync('stub');

    final preprocSession = FmriSessionState();
    final preprocScan = preprocSession.scanFolder(subjRoot.path);
    expect(preprocScan.kind, DetectedDatasetKind.preprocessed);
    expect(preprocSession.boldMniPath, p([preprocDir.path, 'bold_mni.nii']));
    expect(
      preprocSession.atlasPath,
      p([preprocDir.path, 'schaefer400_mni.nii.gz']),
    );
    expect(preprocSession.confoundsPath, p([preprocDir.path, 'confounds.tsv']));
    expect(preprocSession.rawT1Path, isEmpty);
  });

  test('UpdateChecker compares versions and matches OS assets', () {
    expect(UpdateChecker.compareVersions('0.1.3', '0.1.2'), greaterThan(0));
    expect(UpdateChecker.compareVersions('0.1.0', '0.1.0'), equals(0));
    expect(UpdateChecker.compareVersions('0.1.0', '0.2.0'), lessThan(0));

    final mockAssets = [
      {
        'name': 'CCSfMRIStudio-macos.zip',
        'browser_download_url': 'https://example.com/mac.zip',
        'size': 100,
      },
      {
        'name': 'CCSfMRIStudio-windows-x64.zip',
        'browser_download_url': 'https://example.com/win.zip',
        'size': 200,
      },
      {
        'name': 'CCSfMRIStudio-linux-x64.tar.gz',
        'browser_download_url': 'https://example.com/linux.tar.gz',
        'size': 300,
      },
    ];
    expect(
      UpdateChecker.findAsset(mockAssets, platform: UpdatePlatform.macOS)?.name,
      'CCSfMRIStudio-macos.zip',
    );
    expect(
      UpdateChecker.findAsset(
        mockAssets,
        platform: UpdatePlatform.windows,
      )?.name,
      'CCSfMRIStudio-windows-x64.zip',
    );
    expect(
      UpdateChecker.findAsset(mockAssets, platform: UpdatePlatform.linux)?.name,
      'CCSfMRIStudio-linux-x64.tar.gz',
    );
  });

  testWidgets('ResultsDashboard renders CONN QC, ROI Explorer, Connectome, Dynamics & Export tabs', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final mockSummary = rust_api.LesionPipelineSummary(
      nTimepoints: 120,
      nRois: 4,
      nIntactRois: 4,
      nExcludedRois: 0,
      trSec: 2.0,
      usedMmap: true,
      lesionVolumeMl: 0.0,
      dominantHemisphere: 'None',
      globalEfficiency: 0.42,
      meanNodeStrength: 1.5,
      meanHomotopicFc: 0.55,
      lateralityIndex: 0.0,
      lesionSeedMeanAbsR: 0.0,
      meanAbsFc: 0.25,
      totalMs: 42.0,
      fcPreviewRgba: Uint8List(4 * 4 * 4),
      fcPreviewSize: 4,
      carpetRgba: Uint8List(120 * 4 * 4),
      carpetWidth: 120,
      carpetHeight: 4,
      exportedDir: '/tmp/ccs_results_test',
      rawFcHist: Float32List.fromList(List.filled(41, 0.02)),
      cleanFcHist: Float32List.fromList(List.filled(41, 0.03)),
      rawFcMean: 0.31,
      rawFcSd: 0.28,
      cleanFcMean: 0.02,
      cleanFcSd: 0.14,
      meanFdMm: 0.12,
      pctScrubbed: 4.2,
      fdTrace: Float32List.fromList(List.filled(120, 0.12)),
      scrubbedIndices: Uint32List.fromList([10, 50]),
      rawCarpetRgba: Uint8List(120 * 4 * 4),
      roiLabels: const [
        '7Networks_LH_Vis_1',
        '7Networks_LH_Default_1',
        '7Networks_RH_Vis_1',
        '7Networks_RH_Default_1',
      ],
      networkNames: const ['LH_Vis', 'LH_Default', 'RH_Vis', 'RH_Default'],
      roiNetworkIndices: Uint32List.fromList([0, 1, 2, 3]),
      meanAbsPartialFc: 0.11,
      meanGcmiBits: 0.08,
      meanTeBits: 0.03,
      partialPreviewRgba: Uint8List(4 * 4 * 4),
      gcmiPreviewRgba: Uint8List(4 * 4 * 4),
      tePreviewRgba: Uint8List(4 * 4 * 4),
      netPearsonFlat: Float32List.fromList(List.filled(16, 0.2)),
      netPartialFlat: Float32List.fromList(List.filled(16, 0.1)),
      netGcmiFlat: Float32List.fromList(List.filled(16, 0.05)),
      netTeFlat: Float32List.fromList(List.filled(16, 0.02)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ResultsDashboard(
            summary: mockSummary,
            fdThresholdMm: 0.5,
            lowHz: 0.008,
            highHz: 0.09,
            fcImage: null,
            partialImage: null,
            gcmiImage: null,
            teImage: null,
            rawCarpetImage: null,
            cleanCarpetImage: null,
            onGoStep4: () {},
            onOpenResultsFolder: (_) {},
            onSaveReportAs: () {},
            onResetSession: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Denoising QC (CONN)'), findsOneWidget);
    expect(find.text('CONN FC Value Distribution (Before vs After Denoising)'), findsOneWidget);
    expect(find.text('Head Motion & Scrubbing (Framewise Displacement)'), findsOneWidget);
    expect(find.text('ROI Timeseries'), findsOneWidget);
    expect(find.text('Connectivity & Connectome'), findsOneWidget);
    expect(find.text('Timeseries Dynamics'), findsOneWidget);
    expect(find.text('Summary & Export'), findsOneWidget);

    await tester.tap(find.text('Connectivity & Connectome'));
    await tester.pumpAndSettle();
    expect(find.text('Pearson FC'), findsOneWidget);
    expect(find.text('Partial (Ledoit-Wolf)'), findsOneWidget);
    expect(find.text('GCMI (bits)'), findsOneWidget);
    expect(find.text('Transfer Entropy (→)'), findsOneWidget);

    await tester.tap(find.text('Summary & Export'));
    await tester.pumpAndSettle();
    expect(find.text('Open Results Folder'), findsOneWidget);
    expect(find.text('Analyze Another Patient'), findsOneWidget);
  });

  test('BatchDiscovery discovers multi-patient DICOM, raw NIfTI & preproc folders and writes batch CSV', () async {
    final tmp = Directory.systemTemp.createTempSync('ccs_fmri_batch_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    String p(List<String> parts) => parts.join(Platform.pathSeparator);

    // Patient_01/pre -> raw DICOM
    final p1Pre = Directory(p([tmp.path, 'Study', 'Patient_01', 'pre']))
      ..createSync(recursive: true);
    final boldDcm = Directory(p([p1Pre.path, 'HEAD_EP2D_RS_FMRI_0023']))
      ..createSync();
    final t1Dcm = Directory(p([p1Pre.path, 'HEAD_T1_MPRAGE_SAG_ISO_0011']))
      ..createSync();
    File(p([boldDcm.path, '0001.IMA'])).writeAsStringSync('stub');
    File(p([t1Dcm.path, '0001.IMA'])).writeAsStringSync('stub');

    // Patient_01/post -> preprocessed MNI
    final p1Post = Directory(p([tmp.path, 'Study', 'Patient_01', 'post', 'preproc']))
      ..createSync(recursive: true);
    File(p([p1Post.path, 'bold_mni.nii'])).writeAsStringSync('stub');
    File(p([p1Post.path, 'schaefer400_mni.nii.gz'])).writeAsStringSync('stub');

    // Patient_02/pre -> raw NIfTI
    final p2Pre = Directory(p([tmp.path, 'Study', 'Patient_02', 'pre', 'raw_nifti']))
      ..createSync(recursive: true);
    File(p([p2Pre.path, 't1w.nii.gz'])).writeAsStringSync('stub');
    File(p([p2Pre.path, 'bold.nii.gz'])).writeAsStringSync('stub');

    final items = BatchDiscovery.discoverStudyFolder(p([tmp.path, 'Study']));
    expect(items.length, 3);
    final byId = {for (final it in items) it.id: it};
    expect(byId['Patient_01_pre']?.detectedKind, DetectedDatasetKind.rawDicom);
    expect(byId['Patient_01_post']?.detectedKind, DetectedDatasetKind.preprocessed);
    expect(byId['Patient_02_pre']?.detectedKind, DetectedDatasetKind.rawNifti);

    final outDir = p([tmp.path, 'Study', 'batch_results']);
    await BatchRunner.exportBatchSummary(items, outDir);
    expect(File(p([outDir, 'batch_summary.csv'])).existsSync(), isTrue);
    expect(File(p([outDir, 'batch_summary.json'])).existsSync(), isTrue);
  });
}
