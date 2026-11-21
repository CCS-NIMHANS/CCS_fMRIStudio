import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _repoOwner = 'CCS-NIMHANS';
const _repoName = 'CCS_fMRIStudio';

enum UpdatePlatform { macOS, windows, linux }

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
    this.sha256Digest,
  });

  final String name;
  final String downloadUrl;
  final int sizeBytes;
  final String? sha256Digest;
}

class UpdateInfo {
  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.releaseNotes,
    required this.releaseUrl,
    required this.asset,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseNotes;
  final String releaseUrl;
  final ReleaseAsset? asset;
}

class UpdateChecker {
  static int compareVersions(String first, String second) {
    List<int> parts(String value) {
      final match = RegExp(r'\d+(?:\.\d+){0,3}').firstMatch(value);
      return (match?.group(0) ?? '0')
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList();
    }

    final a = parts(first);
    final b = parts(second);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static UpdatePlatform get currentPlatform {
    if (Platform.isMacOS) return UpdatePlatform.macOS;
    if (Platform.isWindows) return UpdatePlatform.windows;
    return UpdatePlatform.linux;
  }

  static ReleaseAsset? findAsset(
    List<dynamic> assets, {
    UpdatePlatform? platform,
  }) {
    final target = platform ?? currentPlatform;
    ReleaseAsset? fallback;
    for (final raw in assets) {
      if (raw is! Map<String, dynamic>) continue;
      final originalName = raw['name'] as String? ?? '';
      final name = originalName.toLowerCase();
      final url = raw['browser_download_url'] as String? ?? '';
      if (url.isEmpty) continue;
      final asset = ReleaseAsset(
        name: originalName,
        downloadUrl: url,
        sizeBytes: (raw['size'] as num?)?.toInt() ?? 0,
        sha256Digest: raw['digest'] as String?,
      );
      switch (target) {
        case UpdatePlatform.macOS:
          if (name == 'ccsfmristudio-macos.zip') return asset;
          if (name.endsWith('.zip') && name.contains('mac')) fallback ??= asset;
        case UpdatePlatform.windows:
          if (name == 'ccsfmristudio-windows-x64.zip') return asset;
          if (name.endsWith('.exe') ||
              (name.endsWith('.zip') && name.contains('win'))) {
            fallback ??= asset;
          }
        case UpdatePlatform.linux:
          if (name == 'ccsfmristudio-linux-x64.tar.gz') return asset;
          if (name.contains('linux') &&
              (name.endsWith('.tar.gz') || name.endsWith('.deb') || name.endsWith('.rpm'))) {
            fallback ??= asset;
          }
      }
    }
    return fallback;
  }

  static Future<UpdateInfo> check() async {
    final package = await PackageInfo.fromPlatform();
    final currentVersion = package.version;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(
        Uri.https('api.github.com', '/repos/$_repoOwner/$_repoName/releases', {
          'per_page': '30',
        }),
      );
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'CCS-fMRIStudio-Updater')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned HTTP ${response.statusCode}',
          uri: request.uri,
        );
      }
      final releases = jsonDecode(body) as List<dynamic>;
      final candidates =
          releases.whereType<Map<String, dynamic>>().where((release) {
            final tag = release['tag_name'] as String? ?? '';
            return release['draft'] != true &&
                RegExp(r'^v?\d+\.\d+\.\d+').hasMatch(tag);
          }).toList()..sort(
            (a, b) => compareVersions(
              b['tag_name'] as String? ?? '',
              a['tag_name'] as String? ?? '',
            ),
          );
      if (candidates.isEmpty) {
        throw const FormatException(
          'No versioned CCS fMRI Studio release was found.',
        );
      }
      final latest = candidates.first;
      final tag = latest['tag_name'] as String? ?? '';
      final latestVersion = tag.startsWith('v') ? tag.substring(1) : tag;
      return UpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        hasUpdate: compareVersions(latestVersion, currentVersion) > 0,
        releaseNotes: (latest['body'] as String?)?.trim().isNotEmpty == true
            ? (latest['body'] as String).trim()
            : 'No release notes were provided.',
        releaseUrl: latest['html_url'] as String? ?? '',
        asset: findAsset(latest['assets'] as List<dynamic>? ?? const []),
      );
    } on SocketException catch (error) {
      throw HttpException('Could not connect to GitHub: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static Future<File> download(
    ReleaseAsset asset,
    void Function(double progress, int received, int total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(asset.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'CCS-fMRIStudio-Updater');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Download returned HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : asset.sizeBytes;
      final safeName = asset.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final file = File(
        '${(await Directory.systemTemp.createTemp('ccs-fmri-update-$pid-')).path}${Platform.pathSeparator}$safeName',
      );
      if (file.existsSync()) file.deleteSync();
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(
            total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0,
            received,
            total,
          );
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (total > 0 && received != total) {
        file.deleteSync();
        throw const FormatException('The downloaded update is incomplete.');
      }

      String? expected = asset.sha256Digest?.replaceFirst('sha256:', '');
      if (expected == null) {
        final uri = Uri.parse(asset.downloadUrl).replace(
          path: Uri.parse(
            asset.downloadUrl,
          ).path.replaceFirst(RegExp(r'[^/]+$'), 'SHA256SUMS.txt'),
        );
        final checksumRequest = await client.getUrl(uri);
        final checksumResp = await checksumRequest.close();
        if (checksumResp.statusCode != 200) {
          throw const FormatException('Release checksum file is unavailable.');
        }
        final lines = await checksumResp.transform(utf8.decoder).join();
        for (final line in lines.split('\n')) {
          final fields = line.trim().split(RegExp(r'\s+'));
          if (fields.length == 2 &&
              fields[1].replaceFirst('*', '') == asset.name) {
            expected = fields[0];
          }
        }
      }
      if (expected == null ||
          expected.length != 64 ||
          (await sha256.bind(file.openRead()).first).toString() !=
              expected.toLowerCase()) {
        await file.delete();
        throw const FormatException(
          'The update checksum did not match; download rejected.',
        );
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String _status = '';
  File? _downloaded;

  String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _downloadAndInstall() async {
    final asset = widget.info.asset;
    if (asset == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _status = 'Downloading ${asset.name}…';
    });
    try {
      final file = await UpdateChecker.download(asset, (
        progress,
        received,
        total,
      ) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _status = total > 0
              ? '${_megabytes(received)} / ${_megabytes(total)} MB'
              : '${_megabytes(received)} MB downloaded';
        });
      });
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = file;
        _status = 'Verified SHA-256 checksum.';
      });
      await _launchInstaller(file);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = 'Update failed: $error';
      });
    }
  }

  String? _currentMacApp() {
    var directory = File(Platform.resolvedExecutable).parent;
    while (directory.path != directory.parent.path) {
      if (directory.path.endsWith('.app')) return directory.path;
      directory = directory.parent;
    }
    return null;
  }

  Future<void> _launchInstaller(File file) async {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', file.path]);
      if (mounted) {
        setState(
          () => _status =
              'Downloaded & verified ${file.path}. Extract and replace to finish updating.',
        );
      }
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [file.parent.path]);
      if (mounted) {
        setState(
          () => _status =
              'Downloaded & verified ${file.path}. Extract the archive to replace the bundle.',
        );
      }
      return;
    }
    await _installMacUpdate(file);
  }

  Future<void> _installMacUpdate(File archive) async {
    final currentApp = _currentMacApp();
    if (currentApp == null) {
      await Process.run('open', ['-R', archive.path]);
      if (mounted) {
        setState(
          () => _status =
              'Archive revealed in Finder; development mode cannot replace itself.',
        );
      }
      return;
    }
    final staging = await Directory.systemTemp.createTemp('ccs_fmri_update_');
    final extract = await Process.run('ditto', [
      '-x',
      '-k',
      archive.path,
      staging.path,
    ]);
    if (extract.exitCode != 0) {
      throw ProcessException(
        'ditto',
        const [],
        extract.stderr.toString(),
        extract.exitCode,
      );
    }
    final applications = staging
        .listSync(recursive: true, followLinks: false)
        .whereType<Directory>()
        .where((entry) => entry.path.endsWith('.app'))
        .toList();
    if (applications.isEmpty) {
      throw const FormatException(
        'The update archive contains no macOS application.',
      );
    }
    final newApp = applications.first.path;
    final verification = await Process.run('codesign', [
      '--verify',
      '--deep',
      '--strict',
      newApp,
    ]);
    if (verification.exitCode != 0) {
      throw const FormatException(
        'The downloaded macOS application failed signature verification.',
      );
    }
    if (mounted) setState(() => _status = 'Installing and restarting…');
    final helper = File(
      '${staging.path}${Platform.pathSeparator}install_update.sh',
    );
    await helper.writeAsString(r'''#!/bin/bash
PID="$1"
TARGET="$2"
NEW_APP="$3"
STAGING="$4"
ARCHIVE="$5"
BACKUP="${TARGET}.update-backup"

while kill -0 "$PID" 2>/dev/null; do sleep 0.25; done
rm -rf "$BACKUP"
if ! mv "$TARGET" "$BACKUP"; then
  open -R "$NEW_APP"
  exit 1
fi
if ditto "$NEW_APP" "$TARGET"; then
  xattr -rd com.apple.quarantine "$TARGET" 2>/dev/null || true
  open "$TARGET"
  rm -rf "$BACKUP" "$STAGING"
  rm -f "$ARCHIVE"
else
  rm -rf "$TARGET"
  mv "$BACKUP" "$TARGET"
  open -R "$NEW_APP"
fi
''');
    await Process.run('chmod', ['+x', helper.path]);
    await Process.start('/bin/bash', [
      helper.path,
      pid.toString(),
      currentApp,
      newApp,
      staging.path,
      archive.path,
    ], mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final updateColor = info.hasUpdate
        ? const Color(0xFF3B82F6)
        : const Color(0xFF22C55E);
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            info.hasUpdate ? Icons.system_update_alt : Icons.verified_outlined,
            color: updateColor,
          ),
          const SizedBox(width: 10),
          Text(info.hasUpdate ? 'CCS fMRI Studio update' : 'You are up to date'),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installed: ${info.currentVersion}   •   Latest: ${info.latestVersion}',
            ),
            if (info.hasUpdate) ...[
              const SizedBox(height: 14),
              const Text(
                'Release notes',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Container(
                height: 220,
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: Text(
                      info.releaseNotes,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (info.asset == null)
                const Text(
                  'This release has no package for the current operating system.',
                )
              else
                Text(
                  '${info.asset!.name} • ${_megabytes(info.asset!.sizeBytes)} MB',
                ),
              if (_downloading) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                ),
              ],
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_status, style: const TextStyle(fontSize: 12)),
              ],
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text('No newer versioned release is available.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (info.hasUpdate && info.asset != null && !_downloading)
          FilledButton.icon(
            onPressed: _downloaded == null
                ? _downloadAndInstall
                : () => _launchInstaller(_downloaded!),
            icon: Icon(_downloaded == null ? Icons.download : Icons.launch),
            label: Text(
              _downloaded == null ? 'Download & update' : 'Open package',
            ),
          ),
      ],
    );
  }
}
