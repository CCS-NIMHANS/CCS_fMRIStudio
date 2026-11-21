# 5. Building & Releasing (macOS, Windows, Linux)

## Local Development Prerequisites

- **Rust toolchain**: `rustc` + `cargo` (tested on `1.95.0`)
- **Flutter SDK**: `3.41.x` stable (`macos`, `windows`, or `linux` desktop enabled)
- **Python sidecar**: `uv` + `dcm2niix` (for DICOM conversion & ANTsPy preprocessing)
- **Optional (when changing Rust FFI signatures)**: `flutter_rust_bridge_codegen` (`2.13.0`)

---

## Local Build & Test Commands

```bash
# 1. Run Rust unit & release tests and compile libccs_fmri_core + bench_denoise
cargo test --release --locked --manifest-path rust/Cargo.toml
cargo build --release --locked --manifest-path rust/Cargo.toml

# 2. Regenerate FFI bindings if rust/src/api.rs changed
flutter_rust_bridge_codegen generate

# 3. Verify Flutter static analysis & widget tests
flutter pub get
flutter analyze
flutter test

# 4. Build desktop release bundle (example: macOS)
flutter build macos --release
```

### Bundling the Rust Engine into the Desktop App

| OS | Native FFI Library Destination | CLI Binary Destination |
| :--- | :--- | :--- |
| **macOS** | `ccs_fmri_studio.app/Contents/Frameworks/libccs_fmri_core.dylib` | `ccs_fmri_studio.app/Contents/MacOS/bench_denoise` |
| **Windows** | `build\windows\x64\runner\Release\ccs_fmri_core.dll` | `build\windows\x64\runner\Release\bench_denoise.exe` |
| **Linux** | `build/linux/x64/release/bundle/lib/libccs_fmri_core.so` | `build/linux/x64/release/bundle/bench_denoise` |

---

## Automated 3-OS GitHub Actions Release Pipeline

`.github/workflows/build.yml` automates cross-platform validation, compilation, and GitHub Release publishing on `v*` tag pushes, manual `workflow_dispatch`, or commits to `main` containing `[build desktop]`:

1. **`validate-release`**: Checks version alignment between `pubspec.yaml` and `rust/Cargo.toml`, and extracts release notes via `scripts/release_notes.sh`.
2. **`build-macos` (`macos-15`)**: Runs `cargo test --release --locked`, builds `libccs_fmri_core.dylib` & `bench_denoise`, runs `flutter analyze` & `flutter test`, builds `flutter build macos --release`, embeds binaries, ad-hoc signs (`codesign --force --deep --sign -`), and archives `CCSfMRIStudio-macos.zip`.
3. **`build-windows` (`windows-2022`)**: Runs `cargo test --release --locked`, builds `ccs_fmri_core.dll` & `bench_denoise.exe`, runs `flutter analyze` & `flutter test`, builds `flutter build windows --release`, copies native binaries beside `ccs_fmri_studio.exe`, and archives `CCSfMRIStudio-windows-x64.zip`.
4. **`build-linux` (`ubuntu-22.04`)**: Installs GTK3/Ninja/Clang dependencies, runs `cargo test --release --locked`, builds `libccs_fmri_core.so` & `bench_denoise`, runs `flutter analyze` & `flutter test`, builds `flutter build linux --release`, embeds `libccs_fmri_core.so` into `bundle/lib/`, and archives `CCSfMRIStudio-linux-x64.tar.gz`.
5. **`release`**: Aggregates all three OS archives, generates `SHA256SUMS.txt`, and creates/updates the GitHub Release.
