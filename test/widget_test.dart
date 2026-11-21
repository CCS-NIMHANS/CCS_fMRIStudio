import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_fmri_studio/main.dart';
import 'package:ccs_fmri_studio/src/update_checker.dart';

void main() {
  testWidgets('Guided 4-step workflow, Browse pickers, and Updates render cleanly', (
    WidgetTester tester,
  ) async {
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

    expect(find.text('Browse Subject Folder'), findsOneWidget);

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
