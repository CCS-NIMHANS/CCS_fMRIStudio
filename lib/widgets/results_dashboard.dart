import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ccs_fmri_studio/src/rust/api.dart' as rust_api;
import 'package:flutter/material.dart';

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
    required this.rawCarpetImage,
    required this.cleanCarpetImage,
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
  final ui.Image? rawCarpetImage;
  final ui.Image? cleanCarpetImage;
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
    _tabCtrl = TabController(length: 5, vsync: this);
    _tabCtrl.addListener(() {
      if (_tabCtrl.index == 3 && _dynamics == null && !_loadingDynamics) {
        _loadDynamics();
      }
    });
    _initDefaults();
  }

  @override
  void didUpdateWidget(covariant ResultsDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary != widget.summary) {
      _dynamics = null;
      _roiDetail = null;
      _hubs = [];
      _initDefaults();
    }
  }

  void _initDefaults() {
    _dynWindowLen = math.min(130, math.max(24, widget.summary.nTimepoints ~/ 2));
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
                'FD > ${widget.fdThresholdMm.toStringAsFixed(2)} mm censored',
                s.pctScrubbed > 20 ? const Color(0xFFEF4444) : const Color(0xFF10B981),
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
      'te_out' => (
        'Transfer Entropy (Directed i → j, bits)',
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
                  ? 'Exported full per-ROI dynamics table to: ${d.exportedCsvPath}'
                  : 'Select any metric to compare functional networks.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                    height: 260,
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
  // TAB 5: SUMMARY & EXPORT
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
    required this.signed,
    required this.colorForNetwork,
  });

  final List<String> networks;
  final List<double> flatMatrix;
  final double density;
  final bool directed;
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
        final mag = signed ? val.abs() : math.max(0.0, val);
        if (mag > 0) edges.add((i, j, val, mag));
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
      final color = (signed && rawVal < 0)
          ? const Color(0xFF38BDF8).withValues(alpha: 0.35 + 0.55 * norm)
          : (directed
              ? const Color(0xFFA78BFA).withValues(alpha: 0.35 + 0.55 * norm)
              : const Color(0xFFF43F5E).withValues(alpha: 0.35 + 0.55 * norm));

      final ctrl = Offset.lerp(center, Offset.lerp(p1, p2, 0.5)!, 0.25)!;
      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, p2.dx, p2.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 1.0 + 3.2 * norm
          ..style = PaintingStyle.stroke,
      );

      if (directed) {
        final dir = p2 - ctrl;
        final len = dir.distance;
        if (len > 4) {
          final ux = dir.dx / len;
          final uy = dir.dy / len;
          final tip = Offset(p2.dx - ux * 11, p2.dy - uy * 11);
          final left = Offset(tip.dx - ux * 7 + uy * 4, tip.dy - uy * 7 - ux * 4);
          final right = Offset(tip.dx - ux * 7 - uy * 4, tip.dy - uy * 7 + ux * 4);
          final arrow = Path()
            ..moveTo(tip.dx, tip.dy)
            ..lineTo(left.dx, left.dy)
            ..lineTo(right.dx, right.dy)
            ..close();
          canvas.drawPath(arrow, Paint()..color = color);
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
      old.networks != networks;
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

    const padL = 42.0;
    const padR = 16.0;
    const padT = 18.0;
    const padB = 38.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 20 || plotH <= 20) return;

    final vals = networks.map(_extract).toList();
    final maxY = vals
        .map((v) => v.$1 + v.$2)
        .fold<double>(1e-4, math.max) *
        1.15;

    final colW = plotW / networks.length;
    final barW = math.max(8.0, colW * 0.56);

    for (var i = 0; i < networks.length; i++) {
      final (m, sd) = vals[i];
      final cx = padL + colW * (i + 0.5);
      final h = (m / maxY).clamp(0.0, 1.0) * plotH;
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
        final errTop = padT + plotH - ((m + sd) / maxY).clamp(0.0, 1.0) * plotH;
        final errBot = padT + plotH - ((m - sd) / maxY).clamp(0.0, 1.0) * plotH;
        final whisker = Paint()
          ..color = Colors.white70
          ..strokeWidth = 1.4;
        canvas.drawLine(Offset(cx, errTop), Offset(cx, errBot), whisker);
        canvas.drawLine(Offset(cx - 4, errTop), Offset(cx + 4, errTop), whisker);
      }

      _drawText(
        canvas,
        networks[i].networkName,
        Offset(cx - colW * 0.45, padT + plotH + 6),
      );
    }
    _drawText(canvas, maxY.toStringAsFixed(2), const Offset(4, padT));
    _drawText(canvas, '0', Offset(18, padT + plotH - 10));
  }

  @override
  bool shouldRepaint(covariant _NetworkDynamicsPainter old) =>
      old.networks != networks || old.metric != metric;
}

void _drawText(Canvas canvas, String text, Offset offset) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
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
