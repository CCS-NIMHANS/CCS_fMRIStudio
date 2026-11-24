# Code Signing Policy

This policy documents how official binary releases of **CCS fMRI Studio** (`https://github.com/CCS-NIMHANS/CCS_fMRIStudio`) are built, verified, and code-signed for distribution under the **MIT License** ([LICENSE](LICENSE)).

## Attribution

> Free code signing provided by SignPath.io, certificate by SignPath Foundation.

## Platform Signing Overview

| Platform | Signing Authority / Mechanism | Scope |
| :--- | :--- | :--- |
| **Windows** (`ccs_fmri_studio.exe`, `bench_denoise.exe`, `ccs_fmri_core.dll`, bundled `.dll`s inside `CCSfMRIStudio-windows-x64.zip`) | **SignPath Foundation** (`SignPath.io` open-source Authenticode EV certificate) | Eliminates Windows 11 Smart App Control blocks and Microsoft Defender SmartScreen warnings |
| **macOS** (`ccs_fmri_studio.app` inside `.zip` & `.dmg`) | **Apple Developer ID Application** (Team `Y445J7MR4Q` — Arun Sasidharan) + **Hardened Runtime** + **Apple Notarization** & stapling | Eliminates macOS Gatekeeper quarantine warnings without requiring terminal commands |
| **Linux** (`.tar.gz`) | GitHub Release `SHA256SUMS.txt` checksums verified in CI | Reproducible release bundle |

## Build Environment & Trust Model

- **GitHub-Hosted CI Runners Only:** All signed release binaries are built exclusively from source in this public GitHub repository (`CCS-NIMHANS/CCS_fMRIStudio`) on GitHub-hosted runners (`windows-2022`, `macos-15`, `ubuntu-22.04`).
- **Branch & Tag Controls:** Production release signing runs only on protected release tags (`v*`) pushed from `main` (or explicit maintainer `workflow_dispatch`), never from pull requests or fork workflows.
- **No Unreviewed External Code in Signed Artifacts:** External pull requests cannot access repository secrets or trigger signing workflows and must be reviewed and merged by a repository maintainer before any release tag is cut.

## Team Roles

| Role | Responsibility | Members |
| :--- | :--- | :--- |
| **Committers & Reviewers** | Author source code, review pull requests, run automated test suites (`cargo test`, `flutter test`), and maintain dependency hygiene | CCS-NIMHANS maintainers led by **Dr. Arun Sasidharan** (`@arunsasidharan84`, Centre for Consciousness Studies, Department of Neurophysiology, NIMHANS) |
| **Approvers** | Approve release tags (`v*`), verify release notes and checksums, and approve SignPath signing requests when required | Repository administrators of `CCS-NIMHANS/CCS_fMRIStudio` |
| **Contributors** | External community contributors submitting issues or pull requests (no direct commit or signing access) | Open-source contributors via pull requests |

## Privacy Policy

CCS fMRI Studio is an offline desktop neuroimaging and fMRI preprocessing/connectivity analysis application. It processes NIfTI/DICOM images, BIDS datasets, and statistical outputs strictly **locally on the user's machine**, does **not** collect telemetry or analytics, and does **not** transfer any data to external networked systems.
