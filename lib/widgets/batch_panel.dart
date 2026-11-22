import 'dart:async';
import 'dart:io';

import 'package:ccs_fmri_studio/src/batch_runner.dart';
import 'package:ccs_fmri_studio/src/session_state.dart';
import 'package:ccs_fmri_studio/widgets/path_picker_field.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class BatchPanel extends StatefulWidget {
  const BatchPanel({
    super.key,
    required this.session,
    required this.templateId,
    required this.transform,
    required this.lesionMode,
    required this.lowHz,
    required this.highHz,
    required this.fdThresholdMm,
    required this.maxDamagePct,
    required this.onOpenFolder,
    required this.onInspectSubject,
  });

  final FmriSessionState session;
  final String templateId;
  final String transform;
  final String lesionMode;
  final double lowHz;
  final double highHz;
  final double fdThresholdMm;
  final double maxDamagePct;
  final ValueChanged<String> onOpenFolder;
  final ValueChanged<String> onInspectSubject;

  @override
  State<BatchPanel> createState() => _BatchPanelState();
}

class _BatchPanelState extends State<BatchPanel> {
  final List<BatchSubjectItem> _items = [];
  final _batchOutCtrl = TextEditingController();

  // Pipeline step toggles
  bool _runDicomConvert = true;
  bool _runPreprocess = true;
  bool _skipExistingPreproc = true;
  bool _runDenoiseAndFc = true;
  bool _runDynamics = true;
  bool _applyLesionMask = false;

  // Queue filters
  String _searchQuery = '';
  String _kindFilter = 'All';

  // Run state
  bool _running = false;
  bool _cancelRequested = false;
  int _doneCount = 0;
  int _totalCount = 0;
  String _currentStage = '';
  int _elapsedSeconds = 0;
  Timer? _timer;
  String? _summaryCsvPath;

  @override
  void dispose() {
    _timer?.cancel();
    _batchOutCtrl.dispose();
    super.dispose();
  }

  static String _formatElapsed(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _addItemsDeduplicated(List<BatchSubjectItem> candidates) {
    final existingFolders = _items.map((e) => e.folderPath).toSet();
    final existingBold =
        _items.where((e) => e.boldMniPath.isNotEmpty).map((e) => e.boldMniPath).toSet();
    var added = 0;
    for (final c in candidates) {
      if (existingFolders.contains(c.folderPath) &&
          (c.boldMniPath.isEmpty || existingBold.contains(c.boldMniPath))) {
        continue;
      }
      _items.add(c);
      existingFolders.add(c.folderPath);
      if (c.boldMniPath.isNotEmpty) existingBold.add(c.boldMniPath);
      added++;
    }
    if (added == 0 && candidates.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No MRI folders (DICOM .IMA/.dcm, NIfTI, or preproc/) found in the selected location.',
          ),
        ),
      );
    }
  }

  Future<void> _scanStudyFolder() async {
    final root = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Study Root Folder (Contains Multiple Patients / Sessions)',
    );
    if (root == null || root.isEmpty) return;
    final found = BatchDiscovery.discoverStudyFolder(root);
    setState(() {
      _addItemsDeduplicated(found);
      if (_batchOutCtrl.text.trim().isEmpty) {
        _batchOutCtrl.text = '$root${Platform.pathSeparator}batch_results';
      }
    });
  }

  Future<void> _addSubjectFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select a Patient or Session Folder to Add',
    );
    if (dir == null || dir.isEmpty) return;
    final item = BatchDiscovery.fromSingleFolder(dir);
    setState(() {
      _addItemsDeduplicated([item]);
      if (_batchOutCtrl.text.trim().isEmpty) {
        _batchOutCtrl.text =
            '${Directory(dir).parent.path}${Platform.pathSeparator}batch_results';
      }
    });
  }

  Future<void> _addMultipleFiles() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: 'Select Multiple NIfTI (.nii / .nii.gz) or DICOM Files',
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return;
    final candidates = <BatchSubjectItem>[];
    for (final pf in res.files) {
      final path = pf.path;
      if (path != null && path.isNotEmpty) {
        candidates.add(BatchDiscovery.fromPickedFile(path));
      }
    }
    setState(() {
      _addItemsDeduplicated(candidates);
      if (_batchOutCtrl.text.trim().isEmpty && candidates.isNotEmpty) {
        _batchOutCtrl.text =
            '${Directory(candidates.first.folderPath).parent.path}${Platform.pathSeparator}batch_results';
      }
    });
  }

  Future<void> _startBatchRun() async {
    final selectedCount = _items.where((i) => i.selected).length;
    if (selectedCount == 0 || _running) return;
    final outDir = _batchOutCtrl.text.trim().isNotEmpty
        ? _batchOutCtrl.text.trim()
        : '${Directory(_items.first.folderPath).parent.path}${Platform.pathSeparator}batch_results';
    _batchOutCtrl.text = outDir;

    for (final it in _items) {
      if (it.selected) {
        it.status = BatchItemStatus.pending;
        it.statusDetail = 'Queued';
        it.errorMessage = null;
      }
    }

    setState(() {
      _running = true;
      _cancelRequested = false;
      _doneCount = 0;
      _totalCount = selectedCount;
      _elapsedSeconds = 0;
      _currentStage = 'Preparing batch ($selectedCount subjects)…';
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });

    try {
      await BatchRunner.runBatch(
        items: _items,
        config: BatchRunConfig(
          runDicomConvert: _runDicomConvert,
          runPreprocess: _runPreprocess,
          skipExistingPreproc: _skipExistingPreproc,
          runDenoiseAndFc: _runDenoiseAndFc,
          runDynamics: _runDynamics,
          applyLesionMaskIfPresent: _applyLesionMask,
          templateId: widget.templateId,
          transform: widget.transform,
          lesionMode: widget.lesionMode,
          lowHz: widget.lowHz,
          highHz: widget.highHz,
          fdThresholdMm: widget.fdThresholdMm,
          maxDamagePct: widget.maxDamagePct,
          batchOutDir: outDir,
        ),
        sidecarRunner: widget.session,
        isCancelled: () => _cancelRequested,
        onProgress: (currentIdx, totalSelected, stageLabel) {
          if (!mounted) return;
          setState(() {
            _doneCount = currentIdx;
            _totalCount = totalSelected;
            _currentStage = stageLabel;
          });
        },
      );
      _summaryCsvPath = '$outDir${Platform.pathSeparator}batch_summary.csv';
    } finally {
      _timer?.cancel();
      _timer = null;
      if (mounted) {
        setState(() {
          _running = false;
          _currentStage = _cancelRequested
              ? 'Batch stopped after current subject.'
              : 'Batch completed ($_doneCount/$_totalCount processed).';
        });
      }
    }
  }

  Future<void> _editSubjectFiles(BatchSubjectItem item) async {
    final rawT1Ctrl = TextEditingController(text: item.rawT1Path);
    final rawBoldCtrl = TextEditingController(text: item.rawBoldPath);
    final boldMniCtrl = TextEditingController(text: item.boldMniPath);
    final atlasCtrl = TextEditingController(text: item.atlasPath);
    final labelsCtrl = TextEditingController(text: item.labelsJsonPath);
    final wmCtrl = TextEditingController(text: item.wmMaskPath);
    final csfCtrl = TextEditingController(text: item.csfMaskPath);
    final confCtrl = TextEditingController(text: item.confoundsPath);
    final lesionCtrl = TextEditingController(text: item.lesionMaskPath);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text('Edit Files: ${item.id}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PathPickerField(controller: boldMniCtrl, label: '4D BOLD MNI (.nii / .nii.gz)'),
                const SizedBox(height: 8),
                PathPickerField(controller: atlasCtrl, label: 'Atlas NIfTI (e.g., schaefer400_mni.nii.gz)'),
                const SizedBox(height: 8),
                PathPickerField(controller: labelsCtrl, label: 'Atlas Labels JSON'),
                const SizedBox(height: 8),
                PathPickerField(controller: wmCtrl, label: 'WM Mask (aCompCor)'),
                const SizedBox(height: 8),
                PathPickerField(controller: csfCtrl, label: 'CSF Mask (aCompCor)'),
                const SizedBox(height: 8),
                PathPickerField(controller: confCtrl, label: 'Confounds TSV'),
                const SizedBox(height: 8),
                PathPickerField(controller: lesionCtrl, label: 'Optional Lesion Mask'),
                const Divider(height: 24, color: Colors.white12),
                PathPickerField(controller: rawT1Ctrl, label: 'Raw T1w NIfTI'),
                const SizedBox(height: 8),
                PathPickerField(controller: rawBoldCtrl, label: 'Raw 4D BOLD NIfTI'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply Changes'),
          ),
        ],
      ),
    );

    if (saved == true) {
      setState(() {
        item.rawT1Path = rawT1Ctrl.text.trim();
        item.rawBoldPath = rawBoldCtrl.text.trim();
        item.boldMniPath = boldMniCtrl.text.trim();
        item.atlasPath = atlasCtrl.text.trim();
        item.labelsJsonPath = labelsCtrl.text.trim();
        item.wmMaskPath = wmCtrl.text.trim();
        item.csfMaskPath = csfCtrl.text.trim();
        item.confoundsPath = confCtrl.text.trim();
        item.lesionMaskPath = lesionCtrl.text.trim();
        if (item.boldMniPath.isNotEmpty) {
          item.detectedKind = DetectedDatasetKind.preprocessed;
        } else if (item.rawT1Path.isNotEmpty || item.rawBoldPath.isNotEmpty) {
          item.detectedKind = DetectedDatasetKind.rawNifti;
        }
      });
    }

    rawT1Ctrl.dispose();
    rawBoldCtrl.dispose();
    boldMniCtrl.dispose();
    atlasCtrl.dispose();
    labelsCtrl.dispose();
    wmCtrl.dispose();
    csfCtrl.dispose();
    confCtrl.dispose();
    lesionCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _items.where((i) => i.selected).length;
    final filtered = _items.where((it) {
      if (_kindFilter == 'Preprocessed' &&
          it.detectedKind != DetectedDatasetKind.preprocessed) {
        return false;
      }
      if (_kindFilter == 'Raw NIfTI' &&
          it.detectedKind != DetectedDatasetKind.rawNifti) {
        return false;
      }
      if (_kindFilter == 'Raw DICOM' &&
          it.detectedKind != DetectedDatasetKind.rawDicom) {
        return false;
      }
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.trim().toLowerCase();
        return it.id.toLowerCase().contains(q) ||
            it.folderPath.toLowerCase().contains(q);
      }
      return true;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            title: 'Step 6: Batch Subject Selection & Pipeline Queue',
            subtitle:
                'Scan a study root folder (auto-discovers BIDS & Patient/Session DICOM, NIfTI, or preproc/ folders), add individual subject folders, or multi-select NIfTI/DICOM files.',
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _running ? null : _scanStudyFolder,
                  icon: const Icon(Icons.account_tree_outlined),
                  label: const Text('Scan Study Folder'),
                ),
                OutlinedButton.icon(
                  onPressed: _running ? null : _addSubjectFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add Subject Folder'),
                ),
                OutlinedButton.icon(
                  onPressed: _running ? null : _addMultipleFiles,
                  icon: const Icon(Icons.note_add_outlined),
                  label: const Text('Add NIfTI Files'),
                ),
                if (_items.isNotEmpty)
                  TextButton.icon(
                    onPressed: _running
                        ? null
                        : () => setState(() {
                            _items.clear();
                            _summaryCsvPath = null;
                          }),
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear Queue'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            title: 'Batch Pipeline Stages & Group Export',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('Convert DICOMs (dcm2niix)'),
                      selected: _runDicomConvert,
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _runDicomConvert = v),
                    ),
                    FilterChip(
                      label: const Text('ANTsPy Preprocess'),
                      selected: _runPreprocess,
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _runPreprocess = v),
                    ),
                    FilterChip(
                      label: const Text('Skip Existing Preproc'),
                      selected: _skipExistingPreproc,
                      onSelected: _running || !_runPreprocess
                          ? null
                          : (v) => setState(() => _skipExistingPreproc = v),
                    ),
                    FilterChip(
                      label: const Text('Denoise + FC / Partial / GCMI / TE'),
                      selected: _runDenoiseAndFc,
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _runDenoiseAndFc = v),
                    ),
                    FilterChip(
                      label: const Text('Timeseries Dynamics'),
                      selected: _runDynamics,
                      onSelected: _running || !_runDenoiseAndFc
                          ? null
                          : (v) => setState(() => _runDynamics = v),
                    ),
                    FilterChip(
                      label: const Text('Apply Lesion Masks'),
                      selected: _applyLesionMask,
                      onSelected: _running
                          ? null
                          : (v) => setState(() => _applyLesionMask = v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                PathPickerField(
                  controller: _batchOutCtrl,
                  label: 'Batch Output Folder (saves batch_summary.csv & .json)',
                  hint: 'Defaults to <studyRoot>/batch_results',
                  mode: PickerMode.pickDirectory,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: (_running || selectedCount == 0)
                          ? null
                          : _startBatchRun,
                      icon: const Icon(Icons.playlist_play),
                      label: Text('Run Batch ($selectedCount Selected)'),
                    ),
                    if (_running)
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _cancelRequested = true),
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(
                          _cancelRequested
                              ? 'Stopping after current…'
                              : 'Stop After Current',
                        ),
                      ),
                    if (_summaryCsvPath != null &&
                        File(_summaryCsvPath!).existsSync())
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            widget.onOpenFolder(_batchOutCtrl.text.trim()),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open Batch Results Folder'),
                      ),
                  ],
                ),
                if (_running || _currentStage.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _currentStage,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF99F6E4),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${_formatElapsed(_elapsedSeconds)} • $_doneCount/$_totalCount',
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Color(0xFF2DD4BF),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _totalCount > 0 ? (_doneCount / _totalCount) : null,
                      minHeight: 6,
                      backgroundColor: const Color(0xFF0F172A),
                      color: const Color(0xFF2DD4BF),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            title: 'Interactive Subject Queue (${_items.length} loaded, $selectedCount selected)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 240,
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: 'Filter subjects…',
                          prefixIcon: Icon(Icons.search, size: 18),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _searchQuery = v),
                      ),
                    ),
                    for (final k in ['All', 'Preprocessed', 'Raw NIfTI', 'Raw DICOM'])
                      ChoiceChip(
                        label: Text(k, style: const TextStyle(fontSize: 12)),
                        selected: _kindFilter == k,
                        onSelected: (_) => setState(() => _kindFilter = k),
                      ),
                    TextButton(
                      onPressed: _running
                          ? null
                          : () => setState(() {
                              for (final it in filtered) {
                                it.selected = true;
                              }
                            }),
                      child: const Text('Select All'),
                    ),
                    TextButton(
                      onPressed: _running
                          ? null
                          : () => setState(() {
                              for (final it in filtered) {
                                it.selected = false;
                              }
                            }),
                      child: const Text('Select None'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (filtered.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: const Text(
                      'No subjects queued yet. Click "Scan Study Folder", "Add Subject Folder", or "Add NIfTI Files" above.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF94A3B8)),
                    ),
                  )
                else
                  for (final it in filtered) _buildSubjectRow(it),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubjectRow(BatchSubjectItem it) {
    final (kindLabel, kindColor) = switch (it.detectedKind) {
      DetectedDatasetKind.preprocessed => ('Preprocessed', const Color(0xFF10B981)),
      DetectedDatasetKind.rawNifti => ('Raw NIfTI', const Color(0xFF38BDF8)),
      DetectedDatasetKind.rawDicom => ('Raw DICOM', const Color(0xFFF59E0B)),
      DetectedDatasetKind.empty => ('Empty', const Color(0xFF64748B)),
    };

    final statusColor = switch (it.status) {
      BatchItemStatus.done => const Color(0xFF10B981),
      BatchItemStatus.running => const Color(0xFF2DD4BF),
      BatchItemStatus.skipped => const Color(0xFFF59E0B),
      BatchItemStatus.failed => const Color(0xFFEF4444),
      BatchItemStatus.pending => const Color(0xFF94A3B8),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: it.status == BatchItemStatus.running
              ? const Color(0xFF2DD4BF)
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: it.selected,
                onChanged: _running
                    ? null
                    : (v) => setState(() => it.selected = v ?? false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          it.id,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: kindColor.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: kindColor),
                          ),
                          child: Text(
                            kindLabel,
                            style: TextStyle(fontSize: 11, color: kindColor),
                          ),
                        ),
                        Text(
                          it.status.name.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      it.folderPath,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      it.statusDetail,
                      style: TextStyle(fontSize: 12, color: statusColor),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit Subject Files',
                onPressed: _running ? null : () => _editSubjectFiles(it),
                icon: const Icon(Icons.edit_note),
              ),
              IconButton(
                tooltip: 'Load in Single-Subject Workflow',
                onPressed: () => widget.onInspectSubject(it.folderPath),
                icon: const Icon(Icons.open_in_new),
              ),
              IconButton(
                tooltip: 'Remove from Batch',
                onPressed: _running
                    ? null
                    : () => setState(() => _items.remove(it)),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          if (it.status == BatchItemStatus.done && it.nRois > 0) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(label: Text('ROIs: ${it.nIntactRois}/${it.nRois}')),
                Chip(label: Text('|FC|: ${it.meanAbsFc.toStringAsFixed(3)}')),
                Chip(label: Text('|Partial|: ${it.meanAbsPartialFc.toStringAsFixed(3)}')),
                Chip(label: Text('GCMI: ${it.meanGcmiBits.toStringAsFixed(3)}b')),
                Chip(label: Text('TE: ${it.meanTeBits.toStringAsFixed(3)}b')),
                Chip(label: Text('Eff: ${it.globalEfficiency.toStringAsFixed(3)}')),
                if (_runDynamics) ...[
                  Chip(label: Text('ACW-50: ${it.acw50Mean.toStringAsFixed(2)}s')),
                  Chip(label: Text('LZC: ${it.lzcMean.toStringAsFixed(3)}')),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
