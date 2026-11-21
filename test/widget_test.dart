import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_fmri_studio/main.dart';

void main() {
  testWidgets('CCS_fMRIStudio workbench renders core panels', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CcsFmriStudioApp(enableRustProbe: false));

    expect(
      find.text('CCS_fMRIStudio — Hybrid Rust + ANTsPy Workbench'),
      findsOneWidget,
    );
    expect(find.text('1. NIfTI Volume & Header Inspector'), findsOneWidget);
    expect(
      find.text('2. Rust Parcellation & Simultaneous Denoising'),
      findsOneWidget,
    );
    expect(find.text('Zero-Copy RGBA Slice Viewport'), findsOneWidget);
  });
}
