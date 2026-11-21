import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_fmri_studio/main.dart';

void main() {
  testWidgets('CCS_fMRIStudio workbench and lesion editor tabs render cleanly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CcsFmriStudioApp(enableRustProbe: false));

    expect(
      find.text('CCS_fMRIStudio — Hybrid Rust + ANTsPy Workbench'),
      findsOneWidget,
    );
    expect(find.text('1. NIfTI Volume & Header Inspector'), findsOneWidget);
    expect(
      find.text('2. Lesion-Aware Rust Denoising & Connectivity'),
      findsOneWidget,
    );
    expect(find.text('Zero-Copy RGBA Slice Viewport'), findsOneWidget);

    await tester.tap(find.text('TBI / Stroke Lesion Editor'));
    await tester.pumpAndSettle();

    expect(find.text('TBI / Stroke Lesion Mask Editor'), findsOneWidget);
    expect(find.text('Auto-Segment'), findsOneWidget);
    expect(find.text('Fill Holes'), findsOneWidget);
  });
}
