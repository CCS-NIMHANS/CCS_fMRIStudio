import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

typedef SidecarModuleRunner = Future<int> Function(
  String module,
  List<String> args,
  void Function(String line) onLog,
);

class ResultsDashboard extends StatefulWidget {
  const ResultsDashboard({
    super.key,
    required this.summary,
    required this.fdThresholdMm,
    required this.lowHz,
    required this.highHz,
    required this.fcImage,
    required this.partialImage,
    required this.gcmiImage,
    required this.teImage,
    this.teNetImage,
    required this.rawCarpetImage,
    required this.cleanCarpetImage,
    this.boldMniPath = '',
    this.labelsJsonPath = '',
    this.confoundsPath = '',
    this.initialBatchCsvPath = '',
    this.onRunSidecarModule,
    required this.onGoStep4,
    required this.onOpenResultsFolder,
    required this.onSaveReportAs,
    required this.onResetSession,
  });

  final rust_api.LesionPipelineSummary summary;
  final double fdThresholdMm;
  final double lowHz;
  final double highHz;
  final ui.Image? fcImage;
  final ui.Image? partialImage;
  final ui.Image? gcmiImage;
  final ui.Image? teImage;
  final ui.Image? teNetImage;
  final ui.Image? rawCarpetImage;
  final ui.Image? cleanCarpetImage;
  final String boldMniPath;
  final String labelsJsonPath;
  final String confoundsPath;
  final String initialBatchCsvPath;
  final SidecarModuleRunner? onRunSidecarModule;
  final VoidCallback onGoStep4;
  final ValueChanged<String> onOpenResultsFolder;
  final VoidCallback onSaveReportAs;
  final VoidCallback onResetSession;

  @override
  State<ResultsDashboard> createState() => _ResultsDashboardState();
}

class _ResultsDashboardState extends State<ResultsDashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  // Tab 1: CONN QC
  String _carpetView = 'both'; // 'raw', 'clean', 'both'

  // Tab 2: Interactive ROI Timeseries
  String _netFilter = 'All';
  String _hemiFilter = 'All';
  String _searchQuery = '';
  final List<int> _selectedRois = [];
  rust_api.RoiTimeseriesDetailDto? _roiDetail;
  bool _loadingRois = false;
  bool _showRawTrace = true;
  bool _showCleanTrace = true;
  bool _showScrubMarkers = true;

  // Tab 3: Connectivity & Connectome
  String _connMetric = 'pearson'; // 'pearson', 'partial', 'gcmi', 'te_out'
  bool _teNetFlow = true;
  double _edgeDensity = 0.20;
  int? _tappedRow;
  int? _tappedCol;
  List<rust_api.RoiHubDto> _hubs = [];
  bool _loadingHubs = false;

  // Tab 4: Timeseries Dynamics (fMRIAnalysis.py)
  String _dynBandKey = 'full';
  late int _dynWindowLen;
  int _dynStep = 5;
  String _dynChartMetric = 'acw0';
  rust_api.DynamicsSummaryDto? _dynamics;
  bool _loadingDynamics = false;
  String? _dynError;

  // Tab 5: Graph Theory (Pure Rust)
  String _graphMetric = 'pearson';
  double _graphDensity = 0.15;
  bool _graphWeighted = true;
  rust_api.GraphTheorySummaryDto? _graphSummary;
  bool _loadingGraph = false;
  String? _graphError;

  // Tab 6: Stats (Nilearn Seed-to-Voxel GLM & Group Connectivity)
  int _glmRoiIndex = 0;
  String _glmCorrection = 'fdr';
  double _glmAlpha = 0.05;
  int _glmClusterThresh = 10;
  bool _runningSeedGlm = false;
  String? _seedGlmError;
  Map<String, dynamic>? _seedGlmSummary;
  int _seedGlmRunSeq = 0;

  late final TextEditingController _groupBatchCsvCtrl;
  late final TextEditingController _groupACtrl;
  late final TextEditingController _groupBCtrl;
  bool _groupPaired = false;
  int _groupNPerm = 250;
  bool _runningGroupStats = false;
  String? _groupStatsError;
  bool _runningPubFigs = false;
  String? _pubFigsMsg;
  String? _pubFigsDir;
  Map<String, dynamic>? _groupStatsSummary;
  int _groupStatsRunSeq = 0;

  static const Map<String, (double, double, String)> _subBands = {
    'full': (0.01, 0.10, 'Full Band (0.01–0.10 Hz)'),
    'slow5a': (0.01, 0.03, 'Slow-5a (0.01–0.03 Hz)'),
    'slow5b': (0.03, 0.05, 'Slow-5b (0.03–0.05 Hz)'),
    'slow4a': (0.05, 0.07, 'Slow-4a (0.05–0.07 Hz)'),
    'slow4b': (0.07, 0.09, 'Slow-4b (0.07–0.09 Hz)'),
  };

  @override
  void initState() {
    super.initState();
    _groupBatchCsvCtrl = TextEditingController(text: widget.initialBatchCsvPath);
    _groupACtrl = TextEditingController(text: 'pre');
    _groupBCtrl = TextEditingController(text: 'post');
    _tabCtrl = TabController(length: 7, vsync: this);
    _tabCtrl.addListener(() {
      if (_tabCtrl.index == 3 && _dynamics == null && !_loadingDynamics) {
        _loadDynamics();
      } else if (_tabCtrl.index == 4 && _graphSummary == null && !_loadingGraph) {
        _loadGraphTheory();
      }
    });
    _initDefaults();
  }

  @override
  void didUpdateWidget(covariant ResultsDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialBatchCsvPath != widget.initialBatchCsvPath &&
        widget.initialBatchCsvPath.isNotEmpty) {
      _groupBatchCsvCtrl.text = widget.initialBatchCsvPath;
    }
    if (oldWidget.summary != widget.summary) {
      _dynamics = null;
      _graphSummary = null;
      _seedGlmSummary = null;
      _roiDetail = null;
      _hubs = [];
      _initDefaults();
    }
  }

  void _initDefaults() {
    _dynWindowLen = math.min(130, math.max(24, widget.summary.nTimepoints ~/ 2));
    _glmRoiIndex = 0;
    _selectedRois.clear();
    if (widget.summary.nRois >= 2) {
      _selectedRois.addAll([0, 1]);
    } else if (widget.summary.nRois == 1) {
      _selectedRois.add(0);
    }
    _loadRoiDetail();
    _loadHubs();
  }

  @override
  void dispose() {
    _groupBatchCsvCtrl.dispose();
    _groupACtrl.dispose();
    _groupBCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRoiDetail() async {
    if (_selectedRois.isEmpty) {
      setState(() => _roiDetail = null);
      return;
    }
    setState(() => _loadingRois = true);
    try {
      final d = await rust_api.getRoiTimeseriesDetail(roiIndices: _selectedRois);
      if (!mounted) return;
      setState(() => _roiDetail = d);
    } catch (_) {
      if (mounted) setState(() => _roiDetail = null);
    } finally {
      if (mounted) setState(() => _loadingRois = false);
    }
  }

  Future<void> _loadHubs() async {
    setState(() => _loadingHubs = true);
    try {
      final hubs = await rust_api.getTopHubs(metric: _connMetric, topK: 10);
      if (!mounted) return;
      setState(() => _hubs = hubs);
    } catch (_) {
      if (mounted) setState(() => _hubs = []);
    } finally {
      if (mounted) setState(() => _loadingHubs = false);
    }
  }

  Future<void> _loadDynamics() async {
    setState(() {
      _loadingDynamics = true;
      _dynError = null;
    });
    try {
      final band = _subBands[_dynBandKey];
      final low = _dynBandKey == 'full' ? widget.lowHz : band!.$1;
      final high = _dynBandKey == 'full' ? widget.highHz : band!.$2;
      final res = await rust_api.computeCachedDynamics(
        windowLen: _dynWindowLen,
        step: _dynStep,
        lowHz: low,
        highHz: high,
        outDir: widget.summary.exportedDir,
      );
      if (!mounted) return;
      setState(() => _dynamics = res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _dynError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingDynamics = false);
    }
  }

  Future<void> _loadGraphTheory() async {
    setState(() {
      _loadingGraph = true;
      _graphError = null;
    });
    try {
      final res = await rust_api.computeGraphTheory(
        metric: _graphMetric,
        density: _graphDensity,
        weighted: _graphWeighted,
        exportDir: widget.summary.exportedDir,
      );
      if (!mounted) return;
      setState(() => _graphSummary = res);
    } catch (e) {
      if (!mounted) return;
      setState(() => _graphError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingGraph = false);
    }
  }

  Future<void> _runSeedGlm() async {
    final runner = widget.onRunSidecarModule;
    final expDir = widget.summary.exportedDir;
    if (runner == null || expDir == null || expDir.isEmpty || widget.boldMniPath.isEmpty) {
      setState(() {
        _seedGlmError =
            'Requires denoised results folder and 4D BOLD MNI volume path (loaded in Step 4).';
      });
      return;
    }
    final tsCsv = '$expDir${Platform.pathSeparator}denoised_timeseries.csv';
    if (!File(tsCsv).existsSync()) {
      setState(() => _seedGlmError = 'Missing $tsCsv');
      return;
    }
    final outDir = '$expDir${Platform.pathSeparator}nilearn_stats';
    final labels = widget.summary.roiLabels;
    final seedLbl = (_glmRoiIndex >= 0 && _glmRoiIndex < labels.length)
        ? labels[_glmRoiIndex]
        : 'ROI_${_glmRoiIndex + 1}';

    setState(() {
      _runningSeedGlm = true;
      _seedGlmError = null;
    });
    final logs = <String>[];
    try {
      final args = <String>[
        '--mode',
        'seed-glm',
        '--bold-mni',
        widget.boldMniPath,
        '--denoised-ts-csv',
        tsCsv,
        '--roi-index',
        '$_glmRoiIndex',
        '--seed-label',
        seedLbl,
        '--correction',
        _glmCorrection,
        '--alpha',
        '$_glmAlpha',
        '--cluster-threshold',
        '$_glmClusterThresh',
        '--low-hz',
        '${widget.lowHz}',
        '--high-hz',
        '${widget.highHz}',
        '--tr',
        '${widget.summary.trSec}',
        '--out-dir',
        outDir,
      ];
      if (widget.confoundsPath.isNotEmpty) {
        args.addAll(['--confounds-tsv', widget.confoundsPath]);
      }
      if (widget.labelsJsonPath.isNotEmpty) {
        args.addAll(['--roi-labels-json', widget.labelsJsonPath]);
      }
      final code = await runner('ccs_fmri_sidecar.nilearn_stats', args, logs.add);
      if (!mounted) return;
      if (code != 0) {
        setState(
          () => _seedGlmError = 'Nilearn GLM exited ($code): ${logs.reversed.take(4).join(' | ')}',
        );
        return;
      }
      final jsonFile = File('$outDir${Platform.pathSeparator}seed_glm_summary.json');
      if (jsonFile.existsSync()) {
        final parsed = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
        setState(() {
          _seedGlmSummary = parsed;
          _seedGlmRunSeq++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _seedGlmError = e.toString());
    } finally {
      if (mounted) setState(() => _runningSeedGlm = false);
    }
  }

  /// Generates report-style, publication-ready figures (300-dpi PNG + SVG) via the sidecar.
  /// [group] = true uses the batch CSV and group A/B selection from the Stats tab.
  Future<void> _runPublicationFigures({required bool group}) async {
    final runner = widget.onRunSidecarModule;
    final expDir = widget.summary.exportedDir;
    if (runner == null) return;
    late final List<String> args;
    late final String outDir;
    if (group) {
      final batchCsv = _groupBatchCsvCtrl.text.trim();
      if (batchCsv.isEmpty || !File(batchCsv).existsSync()) {
        setState(() => _pubFigsMsg = 'Select a batch_summary.csv from the Batch tab first.');
        return;
      }
      outDir = '${File(batchCsv).parent.path}${Platform.pathSeparator}publication_figures';
      args = [
        '--mode', 'group',
        '--batch-csv', batchCsv,
        '--group-a', _groupACtrl.text.trim().isEmpty ? 'pre' : _groupACtrl.text.trim(),
        '--group-b', _groupBCtrl.text.trim().isEmpty ? 'post' : _groupBCtrl.text.trim(),
        if (_groupPaired) '--paired',
        '--out-dir', outDir,
      ];
    } else {
      if (expDir == null || expDir.isEmpty) {
        setState(() => _pubFigsMsg = 'Run denoising with an export folder first.');
        return;
      }
      outDir = '$expDir${Platform.pathSeparator}publication_figures';
      args = [
        '--mode', 'subject',
        '--results-dir', expDir,
        if (widget.boldMniPath.isNotEmpty) ...['--bold-mni', widget.boldMniPath],
        if (widget.labelsJsonPath.isNotEmpty) ...['--labels-json', widget.labelsJsonPath],
        '--out-dir', outDir,
      ];
    }
    setState(() {
      _runningPubFigs = true;
      _pubFigsMsg = null;
    });
    final logs = <String>[];
    try {
      final code = await runner('ccs_fmri_sidecar.pub_figures', args, logs.add);
      if (!mounted) return;
      final manifest = File('$outDir${Platform.pathSeparator}figures_manifest.json');
      if (code == 0 && manifest.existsSync()) {
        final parsed = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        final n = (parsed['figures'] as List).length;
        setState(() {
          _pubFigsDir = outDir;
          _pubFigsMsg = '$n publication figures (300-dpi PNG + SVG) saved to $outDir';
        });
      } else {
        setState(() => _pubFigsMsg = 'Figure generation exited ($code): ${logs.reversed.take(3).join(' | ')}');
      }
    } finally {
      if (mounted) setState(() => _runningPubFigs = false);
    }
  }

  Widget _buildPubFigsControls({required bool group}) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: _runningPubFigs ? null : () => _runPublicationFigures(group: group),
          icon: _runningPubFigs
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.image_outlined),
          label: Text(group ? 'Group Publication Figures' : 'Generate Publication Figures'),
        ),
        if (_pubFigsDir != null)
          OutlinedButton.icon(
            onPressed: () => widget.onOpenResultsFolder(_pubFigsDir!),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Figures Folder'),
          ),
        if (_pubFigsMsg != null)
          Text(_pubFigsMsg!, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
      ],
    );
  }

  Future<void> _runGroupStats() async {
    final runner = widget.onRunSidecarModule;
    final batchCsv = _groupBatchCsvCtrl.text.trim();
    if (runner == null || batchCsv.isEmpty || !File(batchCsv).existsSync()) {
      setState(() {
        _groupStatsError =
            'Select a valid batch_summary.csv produced by the Batch tab (with ≥ 2 subjects per group).';
      });
      return;
    }
    final outDir =
        '${File(batchCsv).parent.path}${Platform.pathSeparator}nilearn_stats';
    setState(() {
      _runningGroupStats = true;
      _groupStatsError = null;
    });
    final logs = <String>[];
    try {
      final args = <String>[
        '--mode',
        'group',
        '--batch-csv',
        batchCsv,
        '--group-a',
        _groupACtrl.text.trim().isEmpty ? 'pre' : _groupACtrl.text.trim(),
        '--group-b',
        _groupBCtrl.text.trim().isEmpty ? 'post' : _groupBCtrl.text.trim(),
        if (_groupPaired) '--paired',
        '--n-perm',
        '$_groupNPerm',
        '--out-dir',
        outDir,
      ];
      final code = await runner('ccs_fmri_sidecar.nilearn_stats', args, logs.add);
      if (!mounted) return;
      if (code != 0) {
        setState(
          () => _groupStatsError =
              'Group Stats exited ($code): ${logs.reversed.take(4).join(' | ')}',
        );
        return;
      }
      final jsonFile =
          File('$outDir${Platform.pathSeparator}nilearn_group_stats.json');
      if (jsonFile.existsSync()) {
        final parsed = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
        setState(() {
          _groupStatsSummary = parsed;
          _groupStatsRunSeq++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _groupStatsError = e.toString());
    } finally {
      if (mounted) setState(() => _runningGroupStats = false);
    }
  }

  static Color _networkColor(String net) {
    final lower = net.toLowerCase();
    if (lower.contains('vis')) return const Color(0xFF8B5CF6);
    if (lower.contains('sommot')) return const Color(0xFF38BDF8);
    if (lower.contains('dorsattn')) return const Color(0xFF10B981);
    if (lower.contains('sal')) return const Color(0xFFF472B6);
    if (lower.contains('limbic')) return const Color(0xFFFACC15);
    if (lower.contains('cont')) return const Color(0xFFF97316);
    if (lower.contains('default')) return const Color(0xFFEF4444);
    return const Color(0xFF2DD4BF);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: const Color(0xFF162033),
          child: TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: const Color(0xFF2DD4BF),
            labelColor: const Color(0xFF2DD4BF),
            unselectedLabelColor: const Color(0xFF94A3B8),
            tabs: const [
              Tab(icon: Icon(Icons.cleaning_services, size: 18), text: 'Denoising QC (CONN)'),
              Tab(icon: Icon(Icons.show_chart, size: 18), text: 'ROI Timeseries'),
              Tab(icon: Icon(Icons.hub, size: 18), text: 'Connectivity & Connectome'),
              Tab(icon: Icon(Icons.waves, size: 18), text: 'Timeseries Dynamics'),
              Tab(icon: Icon(Icons.account_tree, size: 18), text: 'Graph Theory'),
              Tab(icon: Icon(Icons.science, size: 18), text: 'Stats (Nilearn)'),
              Tab(icon: Icon(Icons.summarize, size: 18), text: 'Summary & Export'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildConnQcTab(),
              _buildRoiExplorerTab(),
              _buildConnectomeTab(),
              _buildDynamicsTab(),
              _buildGraphTheoryTab(),
              _buildNilearnStatsTab(),
              _buildSummaryExportTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // TAB 1: CONN-STYLE DENOISING QC
  // ===========================================================================
  Widget _buildConnQcTab() {
    final s = widget.summary;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _kpiBox(
                'Raw FC (Before)',
                '${s.rawFcMean.toStringAsFixed(3)} ± ${s.rawFcSd.toStringAsFixed(3)}',
                'Skewed by motion & CSF/WM drift',
                const Color(0xFFF59E0B),
              ),
              _kpiBox(
                'Clean FC (After)',
                '${s.cleanFcMean.toStringAsFixed(3)} ± ${s.cleanFcSd.toStringAsFixed(3)}',
                'Centered ~0 with tight normal spread',
                const Color(0xFF2DD4BF),
              ),
              _kpiBox(
                'Mean Framewise Disp.',
                '${s.meanFdMm.toStringAsFixed(3)} mm',
                'Power FD across ${s.nTimepoints} volumes',
                const Color(0xFF38BDF8),
              ),
              _kpiBox(
                'Volumes Scrubbed',
                '${s.scrubbedIndices.length} (${s.pctScrubbed.toStringAsFixed(1)}%)',
                'FD > ${widget.fdThresholdMm.toStringAsFixed(2)} mm (${s.censorMode})',
                s.pctScrubbed > 20 ? const Color(0xFFEF4444) : const Color(0xFF10B981),
              ),
              _kpiBox(
                'Effective DOF',
                '${s.dofRemaining} / ${s.nTimepoints}',
                '${s.nRegressors} nuisance + DCT regressors',
                s.dofRemaining < 50 ? const Color(0xFFF59E0B) : const Color(0xFF10B981),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _card(
                  title: 'CONN FC Value Distribution (Before vs After Denoising)',
                  subtitle:
                      'Well-denoised resting-state FC shifts from wide positive global bias (amber) to a centered Gaussian around r ≈ 0 (teal).',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 230,
                        child: CustomPaint(
                          painter: _FcHistogramPainter(
                            rawHist: s.rawFcHist,
                            cleanHist: s.cleanFcHist,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Wrap(
                        spacing: 16,
                        children: [
                          _LegendDot(color: Color(0xFFF59E0B), label: 'Before Denoising (Raw ROI FC)'),
                          _LegendDot(color: Color(0xFF2DD4BF), label: 'After Denoising (aCompCor + Motion + Bandpass)'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _card(
                  title: 'Head Motion & Scrubbing (Framewise Displacement)',
                  subtitle:
                      'Red dashed line = ${widget.fdThresholdMm.toStringAsFixed(2)} mm censor threshold. Shaded frames are projected out in simultaneous SVD regression.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 230,
                        child: CustomPaint(
                          painter: _FdTracePainter(
                            fdTrace: s.fdTrace,
                            thresholdMm: widget.fdThresholdMm,
                            scrubbed: s.scrubbedIndices,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Wrap(
                        spacing: 16,
                        children: [
                          _LegendDot(color: Color(0xFF38BDF8), label: 'Framewise Displacement (mm)'),
                          _LegendDot(color: Color(0xFFEF4444), label: 'Scrubbed Spike Frames'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            title: 'CONN BOLD Carpet Comparison (ROIs × Timepoints)',
            subtitle:
                'Vertical bright/dark bands in Raw BOLD indicate global motion/physiological artifacts; Clean BOLD shows those streaks removed.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'raw', label: Text('Before Denoising (Raw)')),
                    ButtonSegment(value: 'clean', label: Text('After Denoising (Clean)')),
                    ButtonSegment(value: 'both', label: Text('Side-by-Side')),
                  ],
                  selected: {_carpetView},
                  onSelectionChanged: (v) => setState(() => _carpetView = v.first),
                ),
                const SizedBox(height: 12),
                if (_carpetView == 'both')
                  Row(
                    children: [
                      Expanded(child: _carpetBox('Before Denoising (Raw BOLD)', widget.rawCarpetImage)),
                      const SizedBox(width: 12),
                      Expanded(child: _carpetBox('After Denoising (Clean BOLD)', widget.cleanCarpetImage)),
                    ],
                  )
                else if (_carpetView == 'raw')
                  _carpetBox('Before Denoising (Raw BOLD)', widget.rawCarpetImage)
                else
                  _carpetBox('After Denoising (Clean BOLD)', widget.cleanCarpetImage),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _carpetBox(String title, ui.Image? img) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12.5, color: Color(0xFFCBD5E1))),
        const SizedBox(height: 6),
        Container(
          height: 220,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1120),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: img != null
              ? SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.fill,
                    child: RawImage(image: img, filterQuality: FilterQuality.none),
                  ),
                )
              : const Center(child: Text('No carpet preview')),
        ),
      ],
    );
  }

  // ===========================================================================
  // TAB 2: INTERACTIVE ROI TIMESERIES EXPLORER
  // ===========================================================================
  Widget _buildRoiExplorerTab() {
    final s = widget.summary;
    const canonicalNets = [
      'All',
      'Vis',
      'SomMot',
      'DorsAttn',
      'SalVentAttn',
      'Limbic',
      'Cont',
      'Default',
    ];

    final filtered = <int>[];
    final q = _searchQuery.trim().toLowerCase();
    for (var i = 0; i < s.roiLabels.length; i++) {
      final lbl = s.roiLabels[i];
      if (_hemiFilter != 'All' && !lbl.contains('_${_hemiFilter}_') && !lbl.startsWith('${_hemiFilter}_')) {
        continue;
      }
      if (_netFilter != 'All' && !lbl.toLowerCase().contains(_netFilter.toLowerCase())) {
        continue;
      }
      if (q.isNotEmpty && !lbl.toLowerCase().contains(q)) {
        continue;
      }
      filtered.add(i);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 310,
            child: _card(
              title: 'ROI Selector (Select up to 4)',
              expandChild: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search Schaefer ROI…',
                      prefixIcon: Icon(Icons.search, size: 18),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final h in ['All', 'LH', 'RH'])
                        ChoiceChip(
                          label: Text(h, style: const TextStyle(fontSize: 11)),
                          selected: _hemiFilter == h,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _hemiFilter = h),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final n in canonicalNets)
                        ChoiceChip(
                          label: Text(n, style: const TextStyle(fontSize: 10.5)),
                          selected: _netFilter == n,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _netFilter = n),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, pos) {
                          final idx = filtered[pos];
                          final lbl = s.roiLabels[idx];
                          final selectedPos = _selectedRois.indexOf(idx);
                          final isSel = selectedPos >= 0;
                          final netIdx = idx < s.roiNetworkIndices.length ? s.roiNetworkIndices[idx] : 0;
                          final netName = netIdx < s.networkNames.length ? s.networkNames[netIdx] : 'ROI';
                          return ListTile(
                            dense: true,
                            selected: isSel,
                            selectedTileColor: const Color(0xFF0D9488).withValues(alpha: 0.25),
                            leading: CircleAvatar(
                              radius: 10,
                              backgroundColor: _networkColor(netName),
                              child: isSel
                                  ? Text(
                                      '${selectedPos + 1}',
                                      style: const TextStyle(fontSize: 10, color: Colors.black, fontWeight: FontWeight.bold),
                                    )
                                  : null,
                            ),
                            title: Text(
                              lbl,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '#$idx • $netName',
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8)),
                            ),
                            onTap: () {
                              setState(() {
                                if (isSel) {
                                  _selectedRois.remove(idx);
                                } else {
                                  if (_selectedRois.length >= 4) {
                                    _selectedRois.removeAt(0);
                                  }
                                  _selectedRois.add(idx);
                                }
                              });
                              _loadRoiDetail();
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _card(
                    title: 'Raw vs Clean BOLD Timeseries & Variance Removed',
                    subtitle: 'Raw BOLD uses robust median/MAD scaling so high-motion spikes do not squash surviving neural oscillations.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilterChip(
                              label: const Text('Raw BOLD (Amber Dashed)'),
                              selected: _showRawTrace,
                              onSelected: (v) => setState(() => _showRawTrace = v),
                            ),
                            FilterChip(
                              label: const Text('Clean BOLD (Teal Solid)'),
                              selected: _showCleanTrace,
                              onSelected: (v) => setState(() => _showCleanTrace = v),
                            ),
                            FilterChip(
                              label: const Text('Scrubbed Spikes'),
                              selected: _showScrubMarkers,
                              onSelected: (v) => setState(() => _showScrubMarkers = v),
                            ),
                            if (_loadingRois)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                          ],
                        ),
                        if (_roiDetail != null) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              for (var i = 0; i < _roiDetail!.traces.length; i++)
                                Chip(
                                  backgroundColor: const Color(0xFF0F172A),
                                  label: Text(
                                    'ROI ${i + 1}: ${_roiDetail!.traces[i].label} '
                                    '(${_roiDetail!.traces[i].varianceRemovedPct.toStringAsFixed(1)}% nuisance removed)',
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 250,
                            child: CustomPaint(
                              painter: _TimeseriesOverlayPainter(
                                detail: _roiDetail!,
                                showRaw: _showRawTrace,
                                showClean: _showCleanTrace,
                                showScrub: _showScrubMarkers,
                              ),
                            ),
                          ),
                        ] else
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(
                              child: Text('Select one or more ROIs on the left to inspect traces.'),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_roiDetail != null && _roiDetail!.traces.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _card(
                            title: 'Welch Power Spectral Density (Before vs After Bandpass)',
                            subtitle:
                                'Shaded band shows [${widget.lowHz.toStringAsFixed(3)}–${widget.highHz.toStringAsFixed(2)} Hz] resting-state passband.',
                            child: SizedBox(
                              height: 190,
                              child: CustomPaint(
                                painter: _PsdComparisonPainter(
                                  trace: _roiDetail!.traces.first,
                                  lowHz: widget.lowHz,
                                  highHz: widget.highHz,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: _card(
                            title: 'Pairwise ROI Coupling',
                            subtitle: 'Compares first two selected ROIs across 4 measures.',
                            child: _roiDetail!.pairwise == null
                                ? const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text('Select at least 2 ROIs to compute pairwise coupling & directed Transfer Entropy.'),
                                  )
                                : _buildPairwiseCard(_roiDetail!.pairwise!),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPairwiseCard(rust_api.PairwiseCouplingDto p) {
    Widget row(String name, String val, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name, style: const TextStyle(fontSize: 12.5, color: Color(0xFFCBD5E1))),
              Text(val, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1: ${p.labelA}\n2: ${p.labelB}',
          style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
        ),
        const Divider(height: 16, color: Colors.white12),
        row('Pearson Correlation (r)', p.pearsonR.toStringAsFixed(4), const Color(0xFF2DD4BF)),
        row('Partial Corr. (Ledoit-Wolf)', p.partialR.toStringAsFixed(4), const Color(0xFF38BDF8)),
        row('Gaussian-Copula MI (GCMI)', '${p.gcmiBits.toStringAsFixed(4)} bits', const Color(0xFFF59E0B)),
        row('Transfer Entropy (1 → 2)', '${p.teAToB.toStringAsFixed(4)} bits', const Color(0xFFA78BFA)),
        row('Transfer Entropy (2 → 1)', '${p.teBToA.toStringAsFixed(4)} bits', const Color(0xFFF472B6)),
      ],
    );
  }

  // ===========================================================================
  // TAB 3: CONNECTIVITY & CONNECTOME (PEARSON, PARTIAL, GCMI, TE)
  // ===========================================================================
  Widget _buildConnectomeTab() {
    final s = widget.summary;
    final (matrixTitle, img, netFlat, isDirected, isSigned) = switch (_connMetric) {
      'partial' => (
        'Partial Correlation (Ledoit-Wolf)',
        widget.partialImage,
        s.netPartialFlat,
        false,
        true,
      ),
      'gcmi' => (
        'Gaussian-Copula MI (GCMI, bits)',
        widget.gcmiImage,
        s.netGcmiFlat,
        false,
        false,
      ),
      'te_out' => _teNetFlow
          ? (
              'Net Transfer Entropy (TE i→j − TE j→i, bits)',
              widget.teNetImage ?? widget.teImage,
              s.netTeAsymFlat.isNotEmpty ? s.netTeAsymFlat : s.netTeFlat,
              true,
              true,
            )
          : (
              'Raw Transfer Entropy (Directed i → j, bits)',
              widget.teImage,
              s.netTeFlat,
              true,
              false,
            ),
      _ => (
        'Pearson Functional Connectivity (r)',
        widget.fcImage,
        s.netPearsonFlat,
        false,
        true,
      ),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'pearson', label: Text('Pearson FC')),
                  ButtonSegment(value: 'partial', label: Text('Partial (Ledoit-Wolf)')),
                  ButtonSegment(value: 'gcmi', label: Text('GCMI (bits)')),
                  ButtonSegment(value: 'te_out', label: Text('Transfer Entropy (→)')),
                ],
                selected: {_connMetric},
                onSelectionChanged: (v) {
                  setState(() => _connMetric = v.first);
                  _loadHubs();
                },
              ),
              if (_connMetric == 'te_out')
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Net Flow (i→j − j→i)')),
                    ButtonSegment(value: false, label: Text('Raw TE (i→j)')),
                  ],
                  selected: {_teNetFlow},
                  onSelectionChanged: (v) => setState(() => _teNetFlow = v.first),
                ),
              Wrap(
                spacing: 8,
                children: [
                  Chip(label: Text('Mean |Partial|: ${s.meanAbsPartialFc.toStringAsFixed(3)}')),
                  Chip(label: Text('Mean GCMI: ${s.meanGcmiBits.toStringAsFixed(4)} bits')),
                  Chip(label: Text('Mean TE: ${s.meanTeBits.toStringAsFixed(4)} bits')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _card(
                  title: 'ROI × ROI $matrixTitle',
                  subtitle: 'Click anywhere on the matrix to inspect that ROI pair in the ROI Timeseries explorer.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 330,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B1120),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: img != null
                            ? LayoutBuilder(
                                builder: (ctx, box) {
                                  final side = math.min(box.maxWidth, box.maxHeight);
                                  return Center(
                                    child: GestureDetector(
                                      onTapDown: (d) {
                                        final n = s.nRois;
                                        if (n <= 0 || side <= 0) return;
                                        final row = ((d.localPosition.dy / side) * n).floor().clamp(0, n - 1);
                                        final col = ((d.localPosition.dx / side) * n).floor().clamp(0, n - 1);
                                        setState(() {
                                          _tappedRow = row;
                                          _tappedCol = col;
                                        });
                                      },
                                      child: SizedBox(
                                        width: side,
                                        height: side,
                                        child: RawImage(
                                          image: img,
                                          fit: BoxFit.fill,
                                          filterQuality: FilterQuality.none,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              )
                            : const Center(child: Text('No matrix preview')),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(isSigned ? '-1.0' : '0.0', style: const TextStyle(fontSize: 11)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Container(
                              height: 10,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                gradient: LinearGradient(
                                  colors: isSigned
                                      ? const [Color(0xFF1D4ED8), Color(0xFFF8FAFC), Color(0xFFDC2626)]
                                      : const [Color(0xFFF8FAFC), Color(0xFFF59E0B), Color(0xFFDC2626)],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(isSigned ? '+1.0' : 'High', style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                      if (_tappedRow != null && _tappedCol != null && _tappedRow! < s.roiLabels.length && _tappedCol! < s.roiLabels.length) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            Text(
                              'Selected: ${s.roiLabels[_tappedRow!]} ↔ ${s.roiLabels[_tappedCol!]}',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF2DD4BF)),
                            ),
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _selectedRois
                                    ..clear()
                                    ..add(_tappedRow!);
                                  if (_tappedCol != _tappedRow) {
                                    _selectedRois.add(_tappedCol!);
                                  }
                                });
                                _loadRoiDetail();
                                _tabCtrl.animateTo(1);
                              },
                              icon: const Icon(Icons.show_chart, size: 16),
                              label: const Text('Inspect Pair Traces'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _card(
                  title: 'Circular Network Connectome (${s.networkNames.length} Communities)',
                  subtitle: isDirected
                      ? 'Arrowheads show directed information flow i → j above density threshold.'
                      : 'Strongest inter-network edges above the chosen density threshold.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Top Edge Density: ${(_edgeDensity * 100).round()}%',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          Expanded(
                            child: Slider(
                              value: _edgeDensity,
                              min: 0.05,
                              max: 0.50,
                              divisions: 9,
                              onChanged: (v) => setState(() => _edgeDensity = v),
                            ),
                          ),
                        ],
                      ),
                      Container(
                        height: 330,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B1120),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: CustomPaint(
                          painter: _CircularConnectomePainter(
                            networks: s.networkNames,
                            flatMatrix: netFlat,
                            density: _edgeDensity,
                            directed: isDirected,
                            netDirectionalOnly: isDirected && _teNetFlow,
                            signed: isSigned,
                            colorForNetwork: _networkColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_connMetric == 'te_out' && s.netTeOutMinusIn.isNotEmpty) ...[
            const SizedBox(height: 16),
            _card(
              title: 'Net Directed Information Flow (Out-TE − In-TE per Network)',
              subtitle:
                  'Gold bars (right, > 0) identify Net Information Senders; cyan bars (left, < 0) identify Net Information Receivers.',
              child: SizedBox(
                height: math.max(190.0, s.networkNames.length * 22.0),
                child: CustomPaint(
                  painter: _NetTeFlowDivergingPainter(
                    networks: s.networkNames,
                    netFlow: s.netTeOutMinusIn,
                    colorForNetwork: _networkColor,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _card(
            title: 'Top-10 Hub ROIs ($matrixTitle)',
            subtitle: 'Highest average coupling hubs across intact cortical parcels.',
            child: _loadingHubs
                ? const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
                : _buildHubsChart(),
          ),
        ],
      ),
    );
  }

  Widget _buildHubsChart() {
    if (_hubs.isEmpty) {
      return const Text('No hub scores available.');
    }
    final maxScore = _hubs.map((h) => h.score).fold<double>(1e-9, math.max);
    return Column(
      children: [
        for (final h in _hubs)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 240,
                  child: Text(
                    h.label,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (h.score / maxScore).clamp(0.0, 1.0),
                      minHeight: 12,
                      backgroundColor: const Color(0xFF0F172A),
                      color: _networkColor(h.network),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 68,
                  child: Text(
                    h.score.toStringAsFixed(4),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ===========================================================================
  // TAB 4: fMRI TIMESERIES DYNAMICS (fMRIAnalysis.py)
  // ===========================================================================
  Widget _buildDynamicsTab() {
    final s = widget.summary;
    final minWin = math.min(24, s.nTimepoints);
    final maxWin = math.max(minWin, math.min(200, s.nTimepoints));
    final d = _dynamics;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            title: 'Sliding-Window Timeseries Dynamics (ACW, LZC, SampEn, PSD, PLE)',
            subtitle:
                'Pure-Rust Rayon computation of intrinsic timescales & signal complexity across sliding windows.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 250,
                      child: DropdownButtonFormField<String>(
                        initialValue: _dynBandKey,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Frequency Band',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final e in _subBands.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value.$3, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _dynBandKey = v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Window: $_dynWindowLen vols (${(_dynWindowLen * s.trSec).toStringAsFixed(0)}s)',
                              style: const TextStyle(fontSize: 12)),
                          Slider(
                            value: _dynWindowLen.toDouble().clamp(minWin.toDouble(), maxWin.toDouble()),
                            min: minWin.toDouble(),
                            max: maxWin.toDouble(),
                            onChanged: (v) => setState(() => _dynWindowLen = v.round()),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Step: $_dynStep vols', style: const TextStyle(fontSize: 12)),
                          Slider(
                            value: _dynStep.toDouble(),
                            min: 1,
                            max: 15,
                            divisions: 14,
                            onChanged: (v) => setState(() => _dynStep = v.round()),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _loadingDynamics ? null : _loadDynamics,
                      icon: _loadingDynamics
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.waves),
                      label: Text(_loadingDynamics ? 'Computing…' : 'Compute Dynamics'),
                    ),
                  ],
                ),
                if (_dynError != null) ...[
                  const SizedBox(height: 8),
                  Text('Error: $_dynError', style: const TextStyle(color: Color(0xFFFCA5A5))),
                ],
              ],
            ),
          ),
          if (d != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _kpiBox('ACW-0 (s)', d.acw0Mean.toStringAsFixed(2), 'ACF first zero crossing', const Color(0xFF2DD4BF)),
                _kpiBox('ACW-50 (s)', d.acw50Mean.toStringAsFixed(2), 'ACF 50% decay time', const Color(0xFF38BDF8)),
                _kpiBox('AUC Trap (s)', d.aucTrapMean.toStringAsFixed(2), 'Integrated ACF area', const Color(0xFF818CF8)),
                _kpiBox('Lempel-Ziv (LZC)', d.lzcMean.toStringAsFixed(3), 'Binary sequence complexity', const Color(0xFF34D399)),
                _kpiBox('Sample Entropy', d.sampenMean.toStringAsFixed(3), 'm=2, r=0.2·SD', const Color(0xFFA78BFA)),
                _kpiBox('Median Freq (Hz)', d.medFMean.toStringAsFixed(4), 'Welch cumulative half-power', const Color(0xFFF59E0B)),
                _kpiBox('Spectral Entropy', d.seMean.toStringAsFixed(3), 'Normalized Shannon PSD entropy', const Color(0xFFF472B6)),
                _kpiBox('Power-Law β (PLE)', d.pleMean.toStringAsFixed(3), '1/f^β log-log slope', const Color(0xFFEF4444)),
              ],
            ),
            const SizedBox(height: 16),
            _card(
              title: 'Yeo-7 Network Dynamics Profile (Mean ± SD Across Intact ROIs)',
              subtitle: d.exportedCsvPath != null
                  ? 'Zoomed Y-axis highlights inter-network variance • Exported to: ${d.exportedCsvPath}'
                  : 'Zoomed Y-axis highlights inter-network variance across functional networks.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.analytics_outlined, size: 15, color: Color(0xFF2DD4BF)),
                        label: Text(
                          'ANOVA ACW-0: F=${d.anovaFAcw0.toStringAsFixed(2)} (${d.anovaPAcw0 < 0.001 ? "p<0.001" : "p=${d.anovaPAcw0.toStringAsFixed(3)}"})',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      Chip(
                        label: Text(
                          'LZC: F=${d.anovaFLzc.toStringAsFixed(2)} (${d.anovaPLzc < 0.001 ? "p<0.001" : "p=${d.anovaPLzc.toStringAsFixed(3)}"})',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      Chip(
                        label: Text(
                          'SampEn: F=${d.anovaFSampen.toStringAsFixed(2)} (${d.anovaPSampen < 0.001 ? "p<0.001" : "p=${d.anovaPSampen.toStringAsFixed(3)}"})',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      Chip(
                        label: Text(
                          'PLE: F=${d.anovaFPle.toStringAsFixed(2)} (${d.anovaPPle < 0.001 ? "p<0.001" : "p=${d.anovaPPle.toStringAsFixed(3)}"})',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in const [
                        ('acw0', 'ACW-0'),
                        ('acw50', 'ACW-50'),
                        ('auc_trap', 'AUC Trap'),
                        ('lzc', 'LZC'),
                        ('sampen', 'SampEn'),
                        ('med_f', 'Median Freq'),
                        ('se', 'Spectral Ent'),
                        ('ple', 'PLE (1/f β)'),
                      ])
                        ChoiceChip(
                          label: Text(m.$2),
                          selected: _dynChartMetric == m.$1,
                          onSelected: (_) => setState(() => _dynChartMetric = m.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 270,
                    child: CustomPaint(
                      painter: _NetworkDynamicsPainter(
                        networks: d.networks,
                        metric: _dynChartMetric,
                        colorForNetwork: _networkColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 5: GRAPH THEORY ANALYTICS (PURE RUST)
  // ===========================================================================
  Widget _buildGraphTheoryTab() {
    final g = _graphSummary;
    final topNodal = g == null
        ? const <rust_api.NodalGraphDto>[]
        : (g.nodal.toList()
              ..sort((a, b) => b.betweenness.compareTo(a.betweenness)))
            .take(15)
            .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            title: 'Complex Network & Graph Theory (Rayon Parallel Rust)',
            subtitle:
                'Compute NaN-safe weighted or binary topology metrics, Maslov-Sneppen Small-Worldness (σ), and Guimerà-Amaral hub roles across Yeo-7 modules.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 14,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'pearson', label: Text('Pearson')),
                        ButtonSegment(value: 'partial', label: Text('Partial')),
                        ButtonSegment(value: 'gcmi', label: Text('GCMI')),
                        ButtonSegment(value: 'te_out', label: Text('TE')),
                      ],
                      selected: {_graphMetric},
                      onSelectionChanged: (v) {
                        setState(() => _graphMetric = v.first);
                        _loadGraphTheory();
                      },
                    ),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Weighted')),
                        ButtonSegment(value: false, label: Text('Binary')),
                      ],
                      selected: {_graphWeighted},
                      onSelectionChanged: (v) {
                        setState(() => _graphWeighted = v.first);
                        _loadGraphTheory();
                      },
                    ),
                    SizedBox(
                      width: 240,
                      child: Row(
                        children: [
                          Text('Density: ${(_graphDensity * 100).round()}%',
                              style: const TextStyle(fontSize: 12.5)),
                          Expanded(
                            child: Slider(
                              value: _graphDensity,
                              min: 0.05,
                              max: 0.50,
                              divisions: 9,
                              onChanged: (v) => setState(() => _graphDensity = v),
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _loadingGraph ? null : _loadGraphTheory,
                      icon: _loadingGraph
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.account_tree),
                      label: Text(_loadingGraph ? 'Computing…' : 'Compute Graph Metrics'),
                    ),
                  ],
                ),
                if (_graphError != null) ...[
                  const SizedBox(height: 8),
                  Text('Error: $_graphError', style: const TextStyle(color: Color(0xFFFCA5A5))),
                ],
              ],
            ),
          ),
          if (g != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _kpiBox('Global Efficiency (E_glob)', g.globalEfficiency.toStringAsFixed(3), 'Network integration', const Color(0xFF2DD4BF)),
                _kpiBox('Local Efficiency (E_loc)', g.meanLocalEfficiency.toStringAsFixed(3), 'Fault tolerance / segregation', const Color(0xFF38BDF8)),
                _kpiBox('Clustering Coeff (C)', g.clusteringCoeff.toStringAsFixed(3), 'Onnela triangle density', const Color(0xFF34D399)),
                _kpiBox('Path Length (L)', g.charPathLength.toStringAsFixed(2), 'Mean shortest geodesic', const Color(0xFF818CF8)),
                _kpiBox('Small-Worldness (σ)', g.smallWorldness.toStringAsFixed(2), g.smallWorldness > 1.0 ? 'σ > 1 (Small-world)' : 'Sub-threshold / lattice', const Color(0xFFF59E0B)),
                _kpiBox('Modularity (Q)', g.modularityQ.toStringAsFixed(3), 'Yeo-7 community segregation', const Color(0xFFA78BFA)),
                _kpiBox('Assortativity (r)', g.assortativity.toStringAsFixed(3), 'Degree correlation (${g.nEdges} edges)', const Color(0xFFF472B6)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _card(
                    title: 'Proportional Density Sweep (5% – 40%)',
                    subtitle: 'Tracks E_glob (teal), Clustering C (amber), and Modularity Q (purple) across thresholds.',
                    child: SizedBox(
                      height: 260,
                      child: CustomPaint(
                        painter: _DensitySweepPainter(sweep: g.sweep),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _card(
                    title: 'Hub Classification (Participation P_i vs Module z_i)',
                    subtitle: 'Top-right: Connector Hubs (inter-network bridges) • Top-left: Provincial Hubs (intra-network cores).',
                    child: SizedBox(
                      height: 260,
                      child: CustomPaint(
                        painter: _HubScatterPainter(
                          nodal: g.nodal,
                          colorForNetwork: _networkColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _card(
              title: 'Top-15 High-Betweenness Nodal Hubs (${g.metric.toUpperCase()})',
              subtitle: g.exportedCsvPath != null
                  ? 'Exported full table to: ${g.exportedCsvPath}'
                  : 'Ranked by Brandes shortest-path betweenness centrality.',
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 36,
                  columns: const [
                    DataColumn(label: Text('ROI')),
                    DataColumn(label: Text('Network')),
                    DataColumn(label: Text('Deg'), numeric: true),
                    DataColumn(label: Text('Strength'), numeric: true),
                    DataColumn(label: Text('Clust C_i'), numeric: true),
                    DataColumn(label: Text('Betweenness'), numeric: true),
                    DataColumn(label: Text('P_i'), numeric: true),
                    DataColumn(label: Text('z_i'), numeric: true),
                  ],
                  rows: [
                    for (final n in topNodal)
                      DataRow(
                        cells: [
                          DataCell(Text(n.label, style: const TextStyle(fontSize: 12))),
                          DataCell(
                            Text(
                              n.network,
                              style: TextStyle(fontSize: 12, color: _networkColor(n.network)),
                            ),
                          ),
                          DataCell(Text('${n.degree}')),
                          DataCell(Text(n.strength.toStringAsFixed(2))),
                          DataCell(Text(n.clustering.toStringAsFixed(3))),
                          DataCell(Text(n.betweenness.toStringAsFixed(4))),
                          DataCell(Text(n.participationCoeff.toStringAsFixed(3))),
                          DataCell(Text(n.withinModuleZ.toStringAsFixed(2))),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 6: ADVANCED STATISTICAL ANALYSIS (NILEARN + STATSMODELS)
  // ===========================================================================
  Widget _buildNilearnStatsTab() {
    final s = widget.summary;
    final roiCount = s.roiLabels.length;
    final safeRoi = _glmRoiIndex.clamp(0, math.max(0, roiCount - 1)).toInt();
    final glmOut = _seedGlmSummary;
    final grpOut = _groupStatsSummary;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card(
            title: 'Single-Subject Seed-to-Voxel GLM & Nilearn Glass Brain Mapping',
            subtitle:
                'Regresses any atlas ROI seed onto 4D BOLD MNI voxels, computes Fisher-z maps, applies Nilearn FDR / Bonferroni correction, and renders MNI Glass Brain figures.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 280,
                      child: DropdownButtonFormField<int>(
                        initialValue: roiCount > 0 ? safeRoi : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Seed ROI',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (var i = 0; i < roiCount; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text('#$i ${s.roiLabels[i]}', overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _glmRoiIndex = v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _glmCorrection,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Correction',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'fdr',
                            child: Text('BH-FDR (q < α)', overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 'bonferroni',
                            child: Text('Bonferroni (FWER)', overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 'fpr',
                            child: Text('Uncorrected (p < α)', overflow: TextOverflow.ellipsis),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _glmCorrection = v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: DropdownButtonFormField<double>(
                        initialValue: _glmAlpha,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Alpha (α)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 0.05, child: Text('0.05')),
                          DropdownMenuItem(value: 0.01, child: Text('0.01')),
                          DropdownMenuItem(value: 0.001, child: Text('0.001')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _glmAlpha = v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 155,
                      child: DropdownButtonFormField<int>(
                        initialValue: _glmClusterThresh,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Min Cluster',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('0 vox')),
                          DropdownMenuItem(value: 10, child: Text('10 vox')),
                          DropdownMenuItem(value: 20, child: Text('20 vox')),
                          DropdownMenuItem(value: 50, child: Text('50 vox')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _glmClusterThresh = v);
                        },
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _runningSeedGlm ? null : _runSeedGlm,
                      icon: _runningSeedGlm
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.psychology),
                      label: Text(_runningSeedGlm ? 'Running GLM…' : 'Run Nilearn Seed-to-Voxel GLM'),
                    ),
                  ],
                ),
                if (_seedGlmError != null) ...[
                  const SizedBox(height: 10),
                  Text('Error: $_seedGlmError', style: const TextStyle(color: Color(0xFFFCA5A5))),
                ],
                if (glmOut != null) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text('Seed: ${glmOut['seed_label']}')),
                      Chip(label: Text('Threshold |z|: ${(glmOut['threshold_z'] as num?)?.toStringAsFixed(2) ?? "N/A"}')),
                      Chip(label: Text('Peak |z|: ${(glmOut['peak_abs_z'] as num?)?.toStringAsFixed(2) ?? "0"}')),
                      Chip(label: Text('Significant Voxels: ${glmOut['n_sig_voxels']}')),
                      Chip(label: Text('Clusters: ${glmOut['n_clusters']}')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (glmOut['glass_brain_png'] is String &&
                          File(glmOut['glass_brain_png'] as String).existsSync())
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(glmOut['glass_brain_png'] as String),
                              key: ValueKey('glass_$_seedGlmRunSeq'),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      const SizedBox(width: 12),
                      if (glmOut['stat_map_png'] is String &&
                          File(glmOut['stat_map_png'] as String).existsSync())
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(glmOut['stat_map_png'] as String),
                              key: ValueKey('ortho_$_seedGlmRunSeq'),
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (glmOut['clusters'] is List && (glmOut['clusters'] as List).isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 34,
                        dataRowMinHeight: 30,
                        dataRowMaxHeight: 34,
                        columns: const [
                          DataColumn(label: Text('Cluster')),
                          DataColumn(label: Text('MNI (X, Y, Z)')),
                          DataColumn(label: Text('Peak Stat'), numeric: true),
                          DataColumn(label: Text('Volume (mm³)'), numeric: true),
                        ],
                        rows: [
                          for (final c in (glmOut['clusters'] as List).cast<Map<String, dynamic>>())
                            DataRow(
                              cells: [
                                DataCell(Text('${c['cluster_id']}')),
                                DataCell(Text('(${(c['x'] as num).toStringAsFixed(0)}, ${(c['y'] as num).toStringAsFixed(0)}, ${(c['z'] as num).toStringAsFixed(0)})')),
                                DataCell(Text((c['peak_stat'] as num).toStringAsFixed(2))),
                                DataCell(Text((c['cluster_size_mm3'] as num).toStringAsFixed(0))),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            title: 'Group / Batch Statistical Analysis (FDR + NBS + Tangent Decoding + LMM)',
            subtitle:
                'Run mass-univariate edgewise tests (Benjamini-Hochberg FDR), Network-Based Statistic (NBS) permutation clusters, Log-Euclidean Tangent-Space CV decoding, and Mixed-Effects LMM on batch_summary.csv.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _groupBatchCsvCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Batch Summary CSV (batch_summary.csv)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final res = await FilePicker.pickFiles(
                          dialogTitle: 'Select batch_summary.csv',
                          type: FileType.custom,
                          allowedExtensions: ['csv'],
                        );
                        final p = res?.files.single.path;
                        if (p != null && p.isNotEmpty) {
                          setState(() => _groupBatchCsvCtrl.text = p);
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _groupACtrl,
                        decoration: const InputDecoration(
                          labelText: 'Group A (Baseline)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _groupBCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Group B (Compare)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    FilterChip(
                      label: const Text('Paired Within-Subject'),
                      selected: _groupPaired,
                      onSelected: (v) => setState(() => _groupPaired = v),
                    ),
                    SizedBox(
                      width: 185,
                      child: DropdownButtonFormField<int>(
                        initialValue: _groupNPerm,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'NBS Permutations',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 100,
                            child: Text('100 perms', overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 250,
                            child: Text('250 perms', overflow: TextOverflow.ellipsis),
                          ),
                          DropdownMenuItem(
                            value: 500,
                            child: Text('500 perms', overflow: TextOverflow.ellipsis),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _groupNPerm = v);
                        },
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _runningGroupStats ? null : _runGroupStats,
                      icon: _runningGroupStats
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bar_chart),
                      label: Text(_runningGroupStats ? 'Running Group Stats…' : 'Run Nilearn Group Stats'),
                    ),
                  ],
                ),
                if (_groupStatsError != null) ...[
                  const SizedBox(height: 10),
                  Text('Error: $_groupStatsError', style: const TextStyle(color: Color(0xFFFCA5A5))),
                ],
                const SizedBox(height: 10),
                _buildPubFigsControls(group: true),
                if (grpOut != null) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _kpiBox('Sample Sizes', '${grpOut['n_group_a']} vs ${grpOut['n_group_b']}', '${grpOut['group_a']} vs ${grpOut['group_b']}', const Color(0xFF38BDF8)),
                      _kpiBox('FDR Sig. Edges', '${grpOut['n_fdr_sig_edges']}', 'of ${grpOut['n_edges_tested']} edges tested', const Color(0xFF2DD4BF)),
                      _kpiBox('NBS Max Cluster', '${grpOut['nbs_max_component_edges']} edges', 'FWER p = ${(grpOut['nbs_p_value'] as num).toStringAsFixed(3)}', const Color(0xFFA78BFA)),
                      _kpiBox(
                        'Tangent Decoding',
                        grpOut['tangent_decoding_acc'] != null
                            ? '${((grpOut['tangent_decoding_acc'] as num) * 100).toStringAsFixed(1)}%'
                            : 'Skipped',
                        '${grpOut['tangent_note']}',
                        const Color(0xFFF59E0B),
                      ),
                    ],
                  ),
                  if (grpOut['group_diff_png'] is String &&
                      File(grpOut['group_diff_png'] as String).existsSync()) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(grpOut['group_diff_png'] as String),
                        key: ValueKey('grp_$_groupStatsRunSeq'),
                        height: 300,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                  if (grpOut['lmm_results'] is List && (grpOut['lmm_results'] as List).isNotEmpty) ...[
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 34,
                        dataRowMinHeight: 30,
                        dataRowMaxHeight: 34,
                        columns: const [
                          DataColumn(label: Text('Biomarker (MixedLM)')),
                          DataColumn(label: Text('Beta (Est)'), numeric: true),
                          DataColumn(label: Text('SE'), numeric: true),
                          DataColumn(label: Text('z-val'), numeric: true),
                          DataColumn(label: Text('p-val'), numeric: true),
                        ],
                        rows: [
                          for (final r in (grpOut['lmm_results'] as List).cast<Map<String, dynamic>>())
                            DataRow(
                              cells: [
                                DataCell(Text('${r['metric']}')),
                                DataCell(Text((r['estimate'] as num).toStringAsFixed(4))),
                                DataCell(Text((r['std_err'] as num).toStringAsFixed(4))),
                                DataCell(Text((r['z_value'] as num).toStringAsFixed(2))),
                                DataCell(Text((r['p_value'] as num).toStringAsFixed(4))),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 7: SUMMARY & EXPORT
  // ===========================================================================
  Widget _buildSummaryExportTab() {
    final s = widget.summary;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _kpiBox(
                'Intact ROIs',
                '${s.nIntactRois} / ${s.nRois}',
                s.nExcludedRois > 0 ? '${s.nExcludedRois} excluded by mask' : 'All parcels included',
                const Color(0xFF2DD4BF),
              ),
              _kpiBox(
                'Mean |Pearson FC|',
                s.meanAbsFc.toStringAsFixed(3),
                'Global Efficiency: ${s.globalEfficiency.toStringAsFixed(3)}',
                const Color(0xFF38BDF8),
              ),
              _kpiBox(
                'Mean |Partial FC|',
                s.meanAbsPartialFc.toStringAsFixed(3),
                'Ledoit-Wolf direct coupling',
                const Color(0xFF34D399),
              ),
              _kpiBox(
                'GCMI / Transfer Ent.',
                '${s.meanGcmiBits.toStringAsFixed(3)} / ${s.meanTeBits.toStringAsFixed(3)}',
                'Mean info flow (bits)',
                const Color(0xFFA78BFA),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('Node Strength: ${s.meanNodeStrength.toStringAsFixed(2)}')),
              Chip(label: Text('Homotopic FC: ${s.meanHomotopicFc.toStringAsFixed(3)}')),
              Chip(label: Text('Laterality Index: ${s.lateralityIndex.toStringAsFixed(3)}')),
              Chip(label: Text('Lesion Seed |r|: ${s.lesionSeedMeanAbsR.toStringAsFixed(3)}')),
              Chip(label: Text('Lesion: ${s.lesionVolumeMl.toStringAsFixed(1)} mL (${s.dominantHemisphere})')),
              Chip(label: Text('Volumes: ${s.nTimepoints} @ ${s.trSec.toStringAsFixed(2)}s')),
              Chip(label: Text('Rust Engine: ${s.totalMs.toStringAsFixed(1)} ms (mmap: ${s.usedMmap})')),
            ],
          ),
          const SizedBox(height: 16),
          _card(
            title: 'Exported Outputs & What to Do Next',
            subtitle: s.exportedDir != null
                ? 'Automatically saved to: ${s.exportedDir}'
                : 'Ready to inspect and export.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final fname in [
                      'fc_matrix.csv',
                      'partial_fc_matrix.csv',
                      'gcmi_matrix.csv',
                      'te_matrix.csv',
                      'denoised_timeseries.csv',
                      if (_dynamics?.exportedCsvPath != null) 'roi_dynamics.csv',
                      if (_graphSummary?.exportedCsvPath != null) 'graph_metrics_nodal.csv',
                      if (_graphSummary?.exportedJsonPath != null) 'graph_metrics_global.json',
                      if (_seedGlmSummary != null || _groupStatsSummary != null) 'nilearn_stats/',
                      'biomarkers_summary.json',
                      'clinical_report.md',
                    ])
                      Chip(
                        avatar: const Icon(Icons.description_outlined, size: 16, color: Color(0xFF2DD4BF)),
                        label: Text(fname),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (s.exportedDir != null)
                      FilledButton.icon(
                        onPressed: () => widget.onOpenResultsFolder(s.exportedDir!),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open Results Folder'),
                      ),
                    if (s.exportedDir != null)
                      OutlinedButton.icon(
                        onPressed: widget.onSaveReportAs,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('Save Clinical Report As…'),
                      ),
                    OutlinedButton.icon(
                      onPressed: widget.onGoStep4,
                      icon: const Icon(Icons.tune),
                      label: const Text('Adjust Parameters (Step 4)'),
                    ),
                    TextButton.icon(
                      onPressed: widget.onResetSession,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Analyze Another Patient'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildPubFigsControls(group: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kpiBox(String label, String value, String sub, Color color) {
    return Container(
      width: 225,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(fontSize: 11.5, color: Color(0xFFCBD5E1))),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    String? subtitle,
    required Widget child,
    bool expandChild = false,
  }) {
    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8))),
            ],
            const SizedBox(height: 12),
            if (expandChild) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 11.5, color: Color(0xFFCBD5E1))),
      ],
    );
  }
}

// =============================================================================
// CUSTOM PAINTERS FOR SCIENTIFIC VISUALIZATIONS
// =============================================================================

class _FcHistogramPainter extends CustomPainter {
  const _FcHistogramPainter({required this.rawHist, required this.cleanHist});
  final List<double> rawHist;
  final List<double> cleanHist;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    const padL = 16.0;
    const padR = 16.0;
    const padT = 16.0;
    const padB = 26.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 10 || plotH <= 10 || rawHist.isEmpty || cleanHist.isEmpty) return;

    final maxVal = math.max(
      rawHist.fold<double>(1e-4, math.max),
      cleanHist.fold<double>(1e-4, math.max),
    );

    // Zero correlation guide line
    final zeroX = padL + plotW * 0.5;
    canvas.drawLine(
      Offset(zeroX, padT),
      Offset(zeroX, padT + plotH),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1,
    );

    void drawCurve(List<double> hist, Color color) {
      final path = Path();
      final fill = Path()..moveTo(padL, padT + plotH);
      for (var i = 0; i < hist.length; i++) {
        final x = padL + (i / math.max(1, hist.length - 1)) * plotW;
        final y = padT + plotH - (hist[i] / maxVal) * plotH;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        fill.lineTo(x, y);
      }
      fill
        ..lineTo(padL + plotW, padT + plotH)
        ..close();
      canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.20));
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke,
      );
    }

    drawCurve(rawHist, const Color(0xFFF59E0B));
    drawCurve(cleanHist, const Color(0xFF2DD4BF));

    _drawAxisLabels(canvas, size, padL, padT + plotH + 4, ['-1.0', 'r = 0.0', '+1.0']);
  }

  @override
  bool shouldRepaint(covariant _FcHistogramPainter old) =>
      old.rawHist != rawHist || old.cleanHist != cleanHist;
}

class _FdTracePainter extends CustomPainter {
  const _FdTracePainter({
    required this.fdTrace,
    required this.thresholdMm,
    required this.scrubbed,
  });
  final List<double> fdTrace;
  final double thresholdMm;
  final List<int> scrubbed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    const padL = 36.0;
    const padR = 12.0;
    const padT = 14.0;
    const padB = 24.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (fdTrace.isEmpty || plotW <= 10 || plotH <= 10) return;

    final maxFd = math.max(
      thresholdMm * 1.35,
      fdTrace.fold<double>(0.2, math.max),
    );

    // Shaded scrubbed spike vertical bars
    final scrubSet = scrubbed.toSet();
    final colW = math.max(1.5, plotW / fdTrace.length);
    for (final sIdx in scrubSet) {
      if (sIdx < fdTrace.length) {
        final sx = padL + (sIdx / math.max(1, fdTrace.length - 1)) * plotW;
        canvas.drawRect(
          Rect.fromLTWH(sx - colW * 0.5, padT, colW, plotH),
          Paint()..color = const Color(0xFFEF4444).withValues(alpha: 0.28),
        );
      }
    }

    // Threshold line
    final threshY = padT + plotH - (thresholdMm / maxFd) * plotH;
    canvas.drawLine(
      Offset(padL, threshY),
      Offset(padL + plotW, threshY),
      Paint()
        ..color = const Color(0xFFEF4444)
        ..strokeWidth = 1.4,
    );

    // FD polyline
    final path = Path();
    for (var i = 0; i < fdTrace.length; i++) {
      final x = padL + (i / math.max(1, fdTrace.length - 1)) * plotW;
      final y = padT + plotH - (fdTrace[i].clamp(0.0, maxFd) / maxFd) * plotH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF38BDF8)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke,
    );

    _drawText(canvas, maxFd.toStringAsFixed(1), const Offset(4, padT));
    _drawText(canvas, '0.0', Offset(6, padT + plotH - 12));
    _drawAxisLabels(canvas, size, padL, padT + plotH + 4, [
      'Vol 0',
      'Vol ${fdTrace.length ~/ 2}',
      'Vol ${fdTrace.length}',
    ]);
  }

  @override
  bool shouldRepaint(covariant _FdTracePainter old) =>
      old.fdTrace != fdTrace || old.thresholdMm != thresholdMm;
}

class _TimeseriesOverlayPainter extends CustomPainter {
  const _TimeseriesOverlayPainter({
    required this.detail,
    required this.showRaw,
    required this.showClean,
    required this.showScrub,
  });

  final rust_api.RoiTimeseriesDetailDto detail;
  final bool showRaw;
  final bool showClean;
  final bool showScrub;

  static const _palette = [
    Color(0xFF2DD4BF),
    Color(0xFF38BDF8),
    Color(0xFFA78BFA),
    Color(0xFFF472B6),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    final traces = detail.traces;
    if (traces.isEmpty) return;

    const padL = 14.0;
    const padR = 14.0;
    const padT = 12.0;
    const padB = 24.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    final nt = traces.first.cleanZ.length;
    if (nt < 2 || plotW <= 10 || plotH <= 10) return;

    if (showScrub) {
      final colW = math.max(1.5, plotW / nt);
      for (final sIdx in detail.scrubbedIndices) {
        if (sIdx < nt) {
          final sx = padL + (sIdx / (nt - 1)) * plotW;
          canvas.drawRect(
            Rect.fromLTWH(sx - colW * 0.5, padT, colW, plotH),
            Paint()..color = const Color(0xFFEF4444).withValues(alpha: 0.22),
          );
        }
      }
    }

    final lanes = traces.length;
    final laneH = plotH / lanes;

    for (var li = 0; li < lanes; li++) {
      final tr = traces[li];
      final midY = padT + laneH * (li + 0.5);
      final amp = laneH * 0.40;
      canvas.drawLine(
        Offset(padL, midY),
        Offset(padL + plotW, midY),
        Paint()..color = Colors.white10,
      );

      void plotSeries(List<double> vals, Color color, double width) {
        final p = Path();
        for (var t = 0; t < vals.length; t++) {
          final x = padL + (t / math.max(1, vals.length - 1)) * plotW;
          final y = midY - (vals[t].clamp(-3.5, 3.5) / 3.5) * amp;
          if (t == 0) {
            p.moveTo(x, y);
          } else {
            p.lineTo(x, y);
          }
        }
        canvas.drawPath(
          p,
          Paint()
            ..color = color
            ..strokeWidth = width
            ..style = PaintingStyle.stroke,
        );
      }

      if (showRaw) {
        plotSeries(tr.rawZ, const Color(0xFFF59E0B).withValues(alpha: 0.65), 1.1);
      }
      if (showClean) {
        plotSeries(tr.cleanZ, _palette[li % _palette.length], 1.7);
      }
      _drawText(canvas, tr.label, Offset(padL + 4, padT + laneH * li + 2));
    }

    final durSec = (nt * detail.trSec).toStringAsFixed(0);
    _drawAxisLabels(canvas, size, padL, padT + plotH + 4, ['0s', '${durSec}s']);
  }

  @override
  bool shouldRepaint(covariant _TimeseriesOverlayPainter old) =>
      old.detail != detail ||
      old.showRaw != showRaw ||
      old.showClean != showClean ||
      old.showScrub != showScrub;
}

class _PsdComparisonPainter extends CustomPainter {
  const _PsdComparisonPainter({
    required this.trace,
    required this.lowHz,
    required this.highHz,
  });
  final rust_api.RoiTraceDto trace;
  final double lowHz;
  final double highHz;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    final freqs = trace.psdFreqs;
    if (freqs.length < 2) return;

    const padL = 14.0;
    const padR = 14.0;
    const padT = 12.0;
    const padB = 24.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    final fMax = freqs.last.max(0.1);

    // Highlight passband
    final x1 = padL + (lowHz / fMax).clamp(0.0, 1.0) * plotW;
    final x2 = padL + (highHz / fMax).clamp(0.0, 1.0) * plotW;
    canvas.drawRect(
      Rect.fromLTRB(x1, padT, x2, padT + plotH),
      Paint()..color = const Color(0xFF10B981).withValues(alpha: 0.14),
    );

    final maxP = math.max(
      trace.rawPsd.fold<double>(1e-6, math.max),
      trace.cleanPsd.fold<double>(1e-6, math.max),
    );

    void drawPsd(List<double> vals, Color c, double w) {
      final path = Path();
      for (var i = 0; i < vals.length; i++) {
        final x = padL + (freqs[i] / fMax) * plotW;
        final y = padT + plotH - (vals[i] / maxP).clamp(0.0, 1.0) * plotH;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = c
          ..strokeWidth = w
          ..style = PaintingStyle.stroke,
      );
    }

    drawPsd(trace.rawPsd, const Color(0xFFF59E0B), 1.4);
    drawPsd(trace.cleanPsd, const Color(0xFF2DD4BF), 2.0);
    _drawAxisLabels(canvas, size, padL, padT + plotH + 4, [
      '0.0 Hz',
      '${(fMax * 0.5).toStringAsFixed(2)} Hz',
      '${fMax.toStringAsFixed(2)} Hz',
    ]);
  }

  @override
  bool shouldRepaint(covariant _PsdComparisonPainter old) =>
      old.trace != trace || old.lowHz != lowHz || old.highHz != highHz;
}

class _CircularConnectomePainter extends CustomPainter {
  const _CircularConnectomePainter({
    required this.networks,
    required this.flatMatrix,
    required this.density,
    required this.directed,
    this.netDirectionalOnly = false,
    required this.signed,
    required this.colorForNetwork,
  });

  final List<String> networks;
  final List<double> flatMatrix;
  final double density;
  final bool directed;
  final bool netDirectionalOnly;
  final bool signed;
  final Color Function(String) colorForNetwork;

  @override
  void paint(Canvas canvas, Size size) {
    final k = networks.length;
    if (k < 2 || flatMatrix.length < k * k) {
      _drawText(canvas, 'Need atlas labels for community connectome', const Offset(16, 16));
      return;
    }

    final center = Offset(size.width * 0.5, size.height * 0.5);
    final radius = math.min(size.width, size.height) * 0.35;

    final positions = List<Offset>.generate(k, (i) {
      final angle = -math.pi * 0.5 + (2 * math.pi * i) / k;
      return Offset(center.dx + radius * math.cos(angle), center.dy + radius * math.sin(angle));
    });

    final edges = <(int i, int j, double rawVal, double mag)>[];
    for (var i = 0; i < k; i++) {
      final startJ = directed ? 0 : (i + 1);
      for (var j = startJ; j < k; j++) {
        if (i == j) continue;
        final val = flatMatrix[i * k + j];
        if (!val.isFinite) continue;
        if (netDirectionalOnly) {
          // Draw strictly dominant i -> j net flow direction so arcs never overlap.
          if (val > 0) edges.add((i, j, val, val));
        } else {
          final mag = signed ? val.abs() : math.max(0.0, val);
          if (mag > 0) edges.add((i, j, val, mag));
        }
      }
    }
    edges.sort((a, b) => b.$4.compareTo(a.$4));
    final keepCount = math.max(1, (edges.length * density).round()).clamp(0, edges.length);
    final maxMag = edges.isEmpty ? 1.0 : math.max(1e-6, edges.first.$4);

    for (var eIdx = 0; eIdx < keepCount; eIdx++) {
      final (i, j, rawVal, mag) = edges[eIdx];
      final p1 = positions[i];
      final p2 = positions[j];
      final norm = (mag / maxMag).clamp(0.15, 1.0);
      final baseColor = (signed && rawVal < 0 && !directed)
          ? const Color(0xFF38BDF8)
          : (directed ? const Color(0xFFFACC15) : const Color(0xFFF43F5E));
      final color = baseColor.withValues(alpha: 0.38 + 0.55 * norm);

      final ctrl = Offset.lerp(center, Offset.lerp(p1, p2, 0.5)!, 0.25)!;
      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, p2.dx, p2.dy);

      final strokePaint = Paint()
        ..strokeWidth = 1.1 + 3.2 * norm
        ..style = PaintingStyle.stroke;
      if (directed) {
        strokePaint.shader = ui.Gradient.linear(
          p1,
          p2,
          [
            colorForNetwork(networks[i]).withValues(alpha: 0.55 + 0.35 * norm),
            const Color(0xFFFACC15).withValues(alpha: 0.70 + 0.30 * norm),
          ],
        );
      } else {
        strokePaint.color = color;
      }
      canvas.drawPath(path, strokePaint);

      if (directed) {
        // Place high-contrast chevron arrowhead cleanly at t = 0.60 along the quadratic Bezier curve.
        const t = 0.60;
        const mt = 1.0 - t;
        final pos = Offset(
          mt * mt * p1.dx + 2 * mt * t * ctrl.dx + t * t * p2.dx,
          mt * mt * p1.dy + 2 * mt * t * ctrl.dy + t * t * p2.dy,
        );
        final tan = Offset(
          2 * mt * (ctrl.dx - p1.dx) + 2 * t * (p2.dx - ctrl.dx),
          2 * mt * (ctrl.dy - p1.dy) + 2 * t * (p2.dy - ctrl.dy),
        );
        final len = tan.distance;
        if (len > 2) {
          final ux = tan.dx / len;
          final uy = tan.dy / len;
          const headLen = 9.0;
          const headW = 5.5;
          final tip = Offset(pos.dx + ux * (headLen * 0.5), pos.dy + uy * (headLen * 0.5));
          final left = Offset(tip.dx - ux * headLen + uy * headW, tip.dy - uy * headLen - ux * headW);
          final right = Offset(tip.dx - ux * headLen - uy * headW, tip.dy - uy * headLen + ux * headW);
          final arrow = Path()
            ..moveTo(tip.dx, tip.dy)
            ..lineTo(left.dx, left.dy)
            ..lineTo(right.dx, right.dy)
            ..close();
          canvas.drawPath(arrow, Paint()..color = const Color(0xFFFEF08A));
          canvas.drawPath(
            arrow,
            Paint()
              ..color = const Color(0xFF0F172A)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.9,
          );
        }
      }
    }

    for (var i = 0; i < k; i++) {
      final pos = positions[i];
      final c = colorForNetwork(networks[i]);
      canvas.drawCircle(pos, 7, Paint()..color = c);
      canvas.drawCircle(
        pos,
        7,
        Paint()
          ..color = const Color(0xFF0F172A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final angle = -math.pi * 0.5 + (2 * math.pi * i) / k;
      final lblOffset = Offset(
        center.dx + (radius + 26) * math.cos(angle) - 24,
        center.dy + (radius + 26) * math.sin(angle) - 6,
      );
      _drawText(canvas, networks[i], lblOffset);
    }
  }

  @override
  bool shouldRepaint(covariant _CircularConnectomePainter old) =>
      old.flatMatrix != flatMatrix ||
      old.density != density ||
      old.directed != directed ||
      old.netDirectionalOnly != netDirectionalOnly ||
      old.networks != networks;
}

class _NetTeFlowDivergingPainter extends CustomPainter {
  const _NetTeFlowDivergingPainter({
    required this.networks,
    required this.netFlow,
    required this.colorForNetwork,
  });

  final List<String> networks;
  final List<double> netFlow;
  final Color Function(String) colorForNetwork;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    final k = math.min(networks.length, netFlow.length);
    if (k == 0) return;

    const padL = 110.0;
    const padR = 72.0;
    const padT = 16.0;
    const padB = 20.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 20 || plotH <= 20) return;

    final maxAbs = netFlow.take(k).map((v) => v.abs()).fold<double>(1e-5, math.max);
    final midX = padL + plotW * 0.5;
    final rowH = plotH / k;
    final barH = math.max(8.0, rowH * 0.62);

    canvas.drawLine(
      Offset(midX, padT),
      Offset(midX, padT + plotH),
      Paint()..color = Colors.white24,
    );

    for (var i = 0; i < k; i++) {
      final val = netFlow[i];
      final cy = padT + rowH * (i + 0.5);
      final w = (val.abs() / maxAbs).clamp(0.0, 1.0) * (plotW * 0.48);
      final left = val >= 0 ? midX : midX - w;
      final c = val >= 0 ? const Color(0xFFFACC15) : const Color(0xFF38BDF8);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, cy - barH * 0.5, w, barH),
          const Radius.circular(3),
        ),
        Paint()..color = c.withValues(alpha: 0.85),
      );
      _drawText(canvas, networks[i], Offset(8, cy - 6), color: colorForNetwork(networks[i]));
      _drawText(
        canvas,
        val >= 0 ? '+${val.toStringAsFixed(4)}' : val.toStringAsFixed(4),
        Offset(padL + plotW + 6, cy - 6),
        color: c,
      );
    }

    _drawText(canvas, '← Net Receiver', Offset(padL, padT + plotH + 2), color: const Color(0xFF38BDF8));
    _drawText(canvas, 'Net Sender →', Offset(padL + plotW - 70, padT + plotH + 2), color: const Color(0xFFFACC15));
  }

  @override
  bool shouldRepaint(covariant _NetTeFlowDivergingPainter old) =>
      old.netFlow != netFlow || old.networks != networks;
}

class _NetworkDynamicsPainter extends CustomPainter {
  const _NetworkDynamicsPainter({
    required this.networks,
    required this.metric,
    required this.colorForNetwork,
  });

  final List<rust_api.NetworkDynamicsDto> networks;
  final String metric;
  final Color Function(String) colorForNetwork;

  (double, double) _extract(rust_api.NetworkDynamicsDto n) => switch (metric) {
        'acw50' => (n.acw50Mean, n.acw50Sd),
        'auc_trap' => (n.aucTrapMean, 0.0),
        'lzc' => (n.lzcMean, n.lzcSd),
        'sampen' => (n.sampenMean, n.sampenSd),
        'med_f' => (n.medFMean, 0.0),
        'se' => (n.seMean, 0.0),
        'ple' => (n.pleMean, n.pleSd),
        _ => (n.acw0Mean, n.acw0Sd),
      };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    if (networks.isEmpty) return;

    const padL = 48.0;
    const padR = 16.0;
    const padT = 24.0;
    const padB = 38.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 20 || plotH <= 20) return;

    final vals = networks.map(_extract).toList();
    var rawMin = vals.map((v) => v.$1 - v.$2 * 0.5).fold<double>(double.infinity, math.min);
    var rawMax = vals.map((v) => v.$1 + v.$2 * 0.5).fold<double>(double.negativeInfinity, math.max);
    if (!rawMin.isFinite || !rawMax.isFinite) return;
    final span = (rawMax - rawMin).abs();
    final pad = span > 1e-6 ? span * 0.22 : math.max(rawMax.abs() * 0.08, 0.01);
    final minY = math.max(0.0, rawMin - pad);
    final maxY = rawMax + pad;
    final denomY = math.max(1e-6, maxY - minY);

    for (final frac in [0.0, 0.5, 1.0]) {
      final gy = padT + plotH * (1.0 - frac);
      canvas.drawLine(
        Offset(padL, gy),
        Offset(padL + plotW, gy),
        Paint()..color = Colors.white10,
      );
      final tickVal = minY + frac * denomY;
      _drawText(
        canvas,
        tickVal < 1.0 ? tickVal.toStringAsFixed(3) : tickVal.toStringAsFixed(2),
        Offset(4, gy - 6),
      );
    }

    final colW = plotW / networks.length;
    final barW = math.max(8.0, colW * 0.54);

    for (var i = 0; i < networks.length; i++) {
      final (m, sd) = vals[i];
      final cx = padL + colW * (i + 0.5);
      final normM = ((m - minY) / denomY).clamp(0.02, 1.0);
      final h = normM * plotH;
      final topY = padT + plotH - h;
      final c = colorForNetwork(networks[i].networkName);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - barW * 0.5, topY, barW, h),
          const Radius.circular(4),
        ),
        Paint()..color = c.withValues(alpha: 0.85),
      );

      if (sd > 0) {
        final errTop = padT + plotH - (((m + sd) - minY) / denomY).clamp(0.0, 1.0) * plotH;
        final errBot = padT + plotH - (((m - sd) - minY) / denomY).clamp(0.0, 1.0) * plotH;
        final whisker = Paint()
          ..color = Colors.white70
          ..strokeWidth = 1.4;
        canvas.drawLine(Offset(cx, errTop), Offset(cx, errBot), whisker);
        canvas.drawLine(Offset(cx - 4, errTop), Offset(cx + 4, errTop), whisker);
      }

      final valLbl = m < 1.0 ? m.toStringAsFixed(3) : m.toStringAsFixed(2);
      _drawText(
        canvas,
        valLbl,
        Offset(cx - 14, math.max(4.0, topY - 14)),
        color: Colors.white70,
        fontSize: 9.0,
      );

      _drawText(
        canvas,
        networks[i].networkName,
        Offset(cx - colW * 0.45, padT + plotH + 6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkDynamicsPainter old) =>
      old.networks != networks || old.metric != metric;
}

class _DensitySweepPainter extends CustomPainter {
  const _DensitySweepPainter({required this.sweep});
  final List<rust_api.DensitySweepDto> sweep;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    if (sweep.length < 2) return;
    const padL = 38.0;
    const padR = 14.0;
    const padT = 18.0;
    const padB = 28.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 20 || plotH <= 20) return;

    void plotSeries(List<double> ys, Color c) {
      final path = Path();
      for (var i = 0; i < sweep.length; i++) {
        final x = padL + (i / (sweep.length - 1)) * plotW;
        final y = padT + plotH - ys[i].clamp(0.0, 1.0) * plotH;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 3.0, Paint()..color = c);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = c
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );
    }

    plotSeries(sweep.map((s) => s.globalEfficiency).toList(), const Color(0xFF2DD4BF));
    plotSeries(sweep.map((s) => s.clusteringCoeff).toList(), const Color(0xFFF59E0B));
    plotSeries(sweep.map((s) => s.modularityQ).toList(), const Color(0xFFA78BFA));

    _drawText(canvas, '1.0', const Offset(6, padT - 2));
    _drawText(canvas, '0.0', Offset(6, padT + plotH - 8));
    _drawAxisLabels(canvas, size, padL, padT + plotH + 6, [
      '${(sweep.first.density * 100).round()}%',
      'Density',
      '${(sweep.last.density * 100).round()}%',
    ]);
  }

  @override
  bool shouldRepaint(covariant _DensitySweepPainter old) => old.sweep != sweep;
}

class _HubScatterPainter extends CustomPainter {
  const _HubScatterPainter({
    required this.nodal,
    required this.colorForNetwork,
  });

  final List<rust_api.NodalGraphDto> nodal;
  final Color Function(String) colorForNetwork;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = const Color(0xFF0B1120),
    );
    if (nodal.isEmpty) return;

    const padL = 38.0;
    const padR = 16.0;
    const padT = 18.0;
    const padB = 28.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 20 || plotH <= 20) return;

    const minZ = -2.5;
    const maxZ = 3.5;
    // Reference lines: Connector threshold P_i = 0.30, Hub threshold z_i = 1.0
    final refPx = padL + 0.30 * plotW;
    final refZy = padT + plotH - ((1.0 - minZ) / (maxZ - minZ)) * plotH;
    final refPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(refPx, padT), Offset(refPx, padT + plotH), refPaint);
    canvas.drawLine(Offset(padL, refZy), Offset(padL + plotW, refZy), refPaint);

    for (final n in nodal) {
      final px = padL + n.participationCoeff.clamp(0.0, 1.0) * plotW;
      final zy = padT + plotH - ((n.withinModuleZ.clamp(minZ, maxZ) - minZ) / (maxZ - minZ)) * plotH;
      final radius = (2.5 + n.betweenness * 30.0).clamp(2.5, 6.5);
      canvas.drawCircle(
        Offset(px, zy),
        radius,
        Paint()..color = colorForNetwork(n.network).withValues(alpha: 0.78),
      );
    }

    _drawText(canvas, 'Provincial', Offset(padL + 6, padT + 4), color: const Color(0xFF94A3B8), fontSize: 9.5);
    _drawText(canvas, 'Connector Hubs', Offset(padL + plotW - 78, padT + 4), color: const Color(0xFF2DD4BF), fontSize: 9.5);
    _drawAxisLabels(canvas, size, padL, padT + plotH + 6, ['P_i = 0.0', 'Participation P_i', '1.0']);
  }

  @override
  bool shouldRepaint(covariant _HubScatterPainter old) => old.nodal != nodal;
}

void _drawText(
  Canvas canvas,
  String text,
  Offset offset, {
  Color color = const Color(0xFF94A3B8),
  double fontSize = 10,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: fontSize),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, offset);
}

void _drawAxisLabels(
  Canvas canvas,
  Size size,
  double startX,
  double y,
  List<String> labels,
) {
  for (var i = 0; i < labels.length; i++) {
    final tp = TextPainter(
      text: TextSpan(
        text: labels[i],
        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final frac = labels.length == 1 ? 0.0 : i / (labels.length - 1);
    final x = startX + frac * (size.width - startX * 2) - tp.width * frac;
    tp.paint(canvas, Offset(x, y));
  }
}

extension on double {
  double max(double other) => this > other ? this : other;
}
