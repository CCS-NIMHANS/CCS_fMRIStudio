import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_fmri_studio/main.dart';
import 'package:ccs_fmri_studio/src/session_state.dart';
import 'package:ccs_fmri_studio/src/update_checker.dart';

void main() {
  testWidgets(
    'Guided 4-step workflow, Open Patient Folder CTA, and Updates render cleanly',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const CcsFmriStudioApp(enableRustProbe: false));

      expect(find.text('CCS fMRI Studio'), findsOneWidget);
      expect(find.text('Updates'), findsOneWidget);
      expect(find.text('Open Folder'), findsOneWidget);

      expect(find.text('1. Import'), findsOneWidget);
      expect(find.text('2. Preprocess'), findsOneWidget);
      expect(find.text('3. Lesion'), findsOneWidget);
      expect(find.text('4. Denoise'), findsOneWidget);

      expect(find.text('Open Your MRI Scan'), findsOneWidget);
      expect(find.text('Open Patient Folder'), findsOneWidget);
      expect(find.text('Open Single NIfTI File'), findsOneWidget);

      await tester.tap(find.text('2. Preprocess'));
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

      await tester.tap(find.text('4. Denoise'));
      await tester.pumpAndSettle();
      expect(
        find.text('Step 4: Lesion-Aware Rust Denoising & Connectivity'),
        findsOneWidget,
      );
    },
  );

  test('FmriSessionState auto-detects DICOM series, .IMA file picks, and preproc folders', () {
    final tmp = Directory.systemTemp.createTempSync('ccs_fmri_scan_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // 1. Simulate Siemens Patient_01/pre DICOM folder structure
    final preDir = Directory('${tmp.path}/Patient_01/pre')..createSync(recursive: true);
    final boldDir = Directory('${preDir.path}/HEAD_EP2D_RS_FMRI_ADNI3_0023')..createSync();
    final t1SagIsoDir = Directory('${preDir.path}/HEAD_T1_MPRAGE_SAG_P2_ISO_NEW_0011')..createSync();
    final t1CorDir = Directory('${preDir.path}/HEAD_T1_MPRAGE_COR_0101')..createSync();
    final t1TraDir = Directory('${preDir.path}/HEAD_T1_MPRAGE_TRA_0100')..createSync();

    File('${boldDir.path}/img_0001.IMA').writeAsStringSync('stub');
    File('${boldDir.path}/img_0002.IMA').writeAsStringSync('stub');
    File('${t1SagIsoDir.path}/t1_0001.IMA').writeAsStringSync('stub');
    File('${t1CorDir.path}/t1_0001.IMA').writeAsStringSync('stub');
    File('${t1TraDir.path}/t1_0001.IMA').writeAsStringSync('stub');

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
    final imaScan = sessionFromIma.handlePickedFile('${boldDir.path}/img_0001.IMA');
    expect(imaScan.kind, DetectedDatasetKind.rawDicom);
    expect(imaScan.rootFolder, preDir.path);
    expect(imaScan.dicomSeries.length, 4);
    expect(imaScan.notice, isNotNull);

    // 3. Scanning a folder containing preproc/ outputs detects preprocessed MNI files
    final subjRoot = Directory('${tmp.path}/SubjectPreproc')..createSync();
    final preprocDir = Directory('${subjRoot.path}/preproc')..createSync();
    File('${preprocDir.path}/bold_mni.nii').writeAsStringSync('stub');
    File('${preprocDir.path}/schaefer400_mni.nii.gz').writeAsStringSync('stub');
    File('${preprocDir.path}/confounds.tsv').writeAsStringSync('stub');

    final preprocSession = FmriSessionState();
    final preprocScan = preprocSession.scanFolder(subjRoot.path);
    expect(preprocScan.kind, DetectedDatasetKind.preprocessed);
    expect(preprocSession.boldMniPath, '${preprocDir.path}/bold_mni.nii');
    expect(preprocSession.atlasPath, '${preprocDir.path}/schaefer400_mni.nii.gz');
    expect(preprocSession.confoundsPath, '${preprocDir.path}/confounds.tsv');
  });

  test('UpdateChecker compares versions and matches OS assets', () {
    expect(UpdateChecker.compareVersions('0.1.1', '0.1.0'), greaterThan(0));
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
}
