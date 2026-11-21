import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

/// Resolves and opens the native `ccs_fmri_core` shared library from either
/// a packaged desktop bundle (macOS/Windows/Linux) or local development paths.
ExternalLibrary? openBundledRustLibrary() {
  final libName = switch (Platform.operatingSystem) {
    'macos' => 'libccs_fmri_core.dylib',
    'windows' => 'ccs_fmri_core.dll',
    'linux' => 'libccs_fmri_core.so',
    _ => null,
  };
  if (libName == null) return null;

  final exeDir = File(Platform.resolvedExecutable).parent;
  final candidates = <String>[
    if (Platform.isMacOS) '${exeDir.path}/../Frameworks/$libName',
    if (Platform.isLinux) '${exeDir.path}/lib/$libName',
    '${exeDir.path}/$libName',
    'rust/target/release/$libName',
    'rust/target/debug/$libName',
  ];

  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return ExternalLibrary.open(file.absolute.path);
    }
  }
  return null;
}
