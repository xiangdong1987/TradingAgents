// app/lib/ui/ticker_dashboard_page.dart
/// 自选股分析仪表盘：单页可视化最近一次深度分析。
///
/// 自上而下：评级横幅（5 档标尺）→ 交易计划磁贴 → 价位标尺 → 技术信号 →
/// 基本面要点 → 多空对辩 → 结论卡 → 风控视角 → 分析师原文 → 历史评级时间线。
/// 每个区块的数据都来自 `analysis_insights.dart` 的解析器，解析不出就整块隐藏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/analysis_insights.dart';
import '../logic/portfolio_math.dart' show isIsin;
import '../models/models.dart';
import '../providers.dart';
import 'analysis_detail_page.dart';
import 'history_tab.dart' show TickerAnalysesPage;
import 'widgets/pnl.dart';
import 'widgets/stream_error.dart';

const _ratingColors = [
  Color(0xFFFF3B30), // 卖出
  Color(0xFFFF9500), // 减持
  Color(0xFFFFCC00), // 持有
  Color(0xFF9ADB4E), // 增持
  Color(0xFF34C759), // 买入
];

Color _toneColor(Tone t) => switch (t) {
      Tone.bullish => const Color(0xFF34C759),
      Tone.bearish => const Color(0xFFFF3B30),
      Tone.neutral => const Color(0xFF8E8E93),
    };

IconData _toneIcon(Tone t) => switch (t) {
      Tone.bullish => Icons.trending_up,
      Tone.bearish => Icons.trending_down,
      Tone.neutral => Icons.trending_flat,
    };

const _actionZh = {
  'buy': '买入', 'sell': '卖出', 'hold': '持有', 'add': '加仓', 'trim': '减仓',
};

class TickerDashboardPage extends ConsumerStatefulWidget {
  const TickerDashboardPage({super.key, required this.ticker});
  final String ticker;

  @override
  ConsumerState<TickerDashboardPage> createState() => _TickerDashboardPageState();
}

class _TickerDashboardPageState extends ConsumerState<TickerDashboardPage> {
  int _gen = 0; // bump 重建 stream（重试用），同 history_tab 的做法

  @override
  Widget build(BuildContext context) {
    final ticker = widget.ticker;
    return Scaffold(
      appBar: AppBar(
        title: Text(ticker, style: const TextStyle(fontSize: 22)),
        actions: [
          IconButton(
            tooltip: '历史分析列表',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TickerAnalysesPage(ticker: ticker))),
          ),
        ],
      ),
      body: StreamBuilder<List<Analysis>>(
        key: ValueKey(_gen),
        stream: ref.read(repoProvider).analysesForTicker(ticker),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return StreamError(
                error: snapshot.error!, onRetry: () => setState(() => _gen++));
          }
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data ?? const <Analysis>[];
          if (items.isEmpty) return _EmptyState(ticker: ticker);
          return _Dashboard(ticker: ticker, latest: items.first, history: items);
        },
      ),
    );
  }
}

/// 没有任何分析时的引导页；ISIN 债券没有可分析的资料面，仅提示。
class _EmptyState extends ConsumerWidget {
  const _EmptyState({required this.ticker});
  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isIsin(ticker)) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(32),
        child: Text('单只债券暂不支持深度分析', textAlign: TextAlign.center),
      ));
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights, size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text('还没有分析记录'),
          const SizedBox(height: 12),
          _AnalyzeAction(ticker: ticker, label: '立即分析'),
        ],
      ),
    );
  }
}

/// 「重新分析」按钮；该股票已有排队/运行中的 job 时显示状态 chip。
class _AnalyzeAction extends ConsumerWidget {
  const _AnalyzeAction({required this.ticker, required this.label});
  final String ticker;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(activeJobsProvider).value ?? const <Job>[];
    final active = jobs.where((j) => j.ticker == ticker).toList();
    if (active.isNotEmpty) {
      return Chip(
          label: Text(active.first.status == 'queued' ? '排队中' : '分析中'));
    }
    return FilledButton.tonalIcon(
      key: const Key('reanalyze'),
      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
      icon: const Icon(Icons.refresh, size: 18),
      label: Text(label),
      onPressed: () async {
        await ref.read(repoProvider).enqueueDeepAnalysis(ticker);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$ticker 已排队')));
        }
      },
    );
  }
}

class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.ticker, required this.latest, required this.history});
  final String ticker;
  final Analysis latest;
  final List<Analysis> history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quote = ref.watch(latestBriefProvider).value?.quotes[ticker];
    final prefix = currencyPrefix(ticker);
    final a = latest;

    final planTiles = _PlanTiles(analysis: a);
    final levels = priceLevels(
        market: a.section('market'), traderPlan: a.section('traderPlan'));
    final signals = indicatorSignals(a.section('market'));
    final metrics = fundamentalMetrics(a.section('fundamentals'), max: 8);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: [
        _RatingBanner(analysis: a, quote: quote, prefix: prefix),
        if (planTiles.hasContent) planTiles,
        if (levels.length >= 3) _PriceLadderCard(levels: levels, prefix: prefix),
        if (signals.isNotEmpty) _TechSignalsCard(signals: signals),
        if (metrics.isNotEmpty) _FundamentalsCard(metrics: metrics),
        _BullBearRow(analysis: a),
        ..._conclusionCards(a),
        _RiskRow(analysis: a),
        ..._reportCards(a),
        if (history.isNotEmpty) _HistoryStrip(history: history),
      ],
    );
  }

  List<Widget> _conclusionCards(Analysis a) {
    final rm = a.section('researchManager');
    final pm = a.section('portfolioDecision').isNotEmpty
        ? a.section('portfolioDecision')
        : a.section('finalDecision');
    return [
      if (rm.isNotEmpty)
        _ExpandableCard(
          icon: Icons.school_outlined,
          title: '研究主管',
          badge: kvValue(rm, ['Recommendation', 'Rating']),
          excerptText: excerpt(kvValue(rm, ['Rationale']) ?? rm, maxChars: 120),
          fullMd: rm,
        ),
      if (pm.isNotEmpty)
        _ExpandableCard(
          icon: Icons.account_balance_outlined,
          title: '组合经理决定',
          badge: kvValue(pm, ['Rating', 'Recommendation']),
          excerptText:
              excerpt(kvValue(pm, ['Executive Summary']) ?? pm, maxChars: 140),
          fullMd: pm,
        ),
    ];
  }

  List<Widget> _reportCards(Analysis a) {
    const reports = [
      (key: 'market', icon: Icons.candlestick_chart_outlined, title: '技术面原文'),
      (key: 'fundamentals', icon: Icons.assessment_outlined, title: '基本面原文'),
      (key: 'sentiment', icon: Icons.forum_outlined, title: '情绪面原文'),
      (key: 'news', icon: Icons.newspaper_outlined, title: '新闻面原文'),
    ];
    final cards = <Widget>[
      for (final r in reports)
        if (a.section(r.key).isNotEmpty)
          _ExpandableCard(
            icon: r.icon,
            title: r.title,
            excerptText: excerpt(a.section(r.key), maxChars: 60),
            fullMd: a.section(r.key),
            dense: true,
          ),
    ];
    if (cards.isEmpty) return const [];
    return [const _SectionLabel('分析师原文'), ...cards];
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 14, 6, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

// ---------------------------------------------------------------------------
// 评级横幅
// ---------------------------------------------------------------------------

class _RatingBanner extends StatelessWidget {
  const _RatingBanner({required this.analysis, required this.quote, required this.prefix});
  final Analysis analysis;
  final TickerQuote? quote;
  final String prefix;

  String get _relativeDay {
    final d = DateTime.tryParse(analysis.tradeDate);
    if (d == null) return '';
    final days = DateTime.now().difference(d).inDays;
    if (days <= 0) return ' · 今天';
    return ' · $days天前';
  }

  @override
  Widget build(BuildContext context) {
    final idx = ratingIndex(analysis.decision);
    final color = idx == null ? const Color(0xFF8E8E93) : _ratingColors[idx];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(idx == null ? analysis.decision : ratingZh(idx),
                          key: const Key('dashRating'),
                          style: TextStyle(
                              fontSize: 30, fontWeight: FontWeight.w900, color: color)),
                      Text(analysis.decision,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (quote != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      MoneyText(quote!.close, size: 24, prefix: prefix),
                      const SizedBox(height: 4),
                      PnlPill(quote!.pctChange, compact: true),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (idx != null) _RatingScale(activeIndex: idx),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text('分析日 ${analysis.tradeDate}$_relativeDay',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
                _AnalyzeAction(ticker: analysis.ticker, label: '重新分析'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 卖出→买入 5 档色带，当前档加高、加标签粗体。
class _RatingScale extends StatelessWidget {
  const _RatingScale({required this.activeIndex});
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < 5; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: i == activeIndex ? 12 : 6,
                    decoration: BoxDecoration(
                      color: i == activeIndex
                          ? _ratingColors[i]
                          : _ratingColors[i].withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(ratingLabels[i],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: i == activeIndex ? FontWeight.w800 : FontWeight.w400,
                        color: i == activeIndex
                            ? _ratingColors[i]
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 交易计划磁贴 + 情绪条
// ---------------------------------------------------------------------------

class _PlanTiles extends StatelessWidget {
  _PlanTiles({required this.analysis})
      : action = kvValue(analysis.section('traderPlan'), ['Action']),
        entry = kvValue(analysis.section('traderPlan'), ['Entry Price', '入场价']),
        stop = kvValue(analysis.section('traderPlan'), ['Stop Loss', '止损']),
        sizing = kvValue(analysis.section('traderPlan'), ['Position Sizing', '仓位']),
        horizon = kvValue(
            analysis.section('portfolioDecision').isNotEmpty
                ? analysis.section('portfolioDecision')
                : analysis.section('finalDecision'),
            ['Time Horizon']),
        score = sentimentScore(analysis.section('sentiment')),
        confidence = kvValue(analysis.section('sentiment'), ['Confidence']);

  final Analysis analysis;
  final String? action;
  final String? entry;
  final String? stop;
  final String? sizing;
  final String? horizon;
  final double? score;
  final String? confidence;

  bool get hasContent =>
      action != null || entry != null || stop != null || horizon != null || score != null;

  @override
  Widget build(BuildContext context) {
    final actionIdx = action == null ? null : ratingIndex(action!);
    final actionColor = actionIdx == null
        ? Colors.white
        : _ratingColors[actionIdx];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('交易计划', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(
              children: [
                if (action != null)
                  Expanded(
                      child: _StatTile(
                          label: '方向',
                          value: _actionZh[action!.toLowerCase()] ?? action!,
                          valueColor: actionColor)),
                if (entry != null)
                  Expanded(child: _StatTile(label: '入场价', value: entry!)),
                if (stop != null)
                  Expanded(
                      child: _StatTile(
                          label: '止损价',
                          value: stop!,
                          valueColor: const Color(0xFFFF3B30))),
                if (horizon != null)
                  Expanded(child: _StatTile(label: '时间视野', value: horizon!)),
              ],
            ),
            if (sizing != null) ...[
              const SizedBox(height: 10),
              Text('仓位建议：$sizing',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
            if (score != null) ...[
              const SizedBox(height: 12),
              _SentimentBar(score: score!, confidence: confidence),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                maxLines: 1,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ],
      ),
    );
  }
}

const _confidenceZh = {'low': '低', 'medium': '中', 'high': '高'};

class _SentimentBar extends StatelessWidget {
  const _SentimentBar({required this.score, this.confidence});
  final double score; // 0..10
  final String? confidence;

  @override
  Widget build(BuildContext context) {
    final t = (score / 10).clamp(0.0, 1.0);
    final color = score >= 6.5
        ? const Color(0xFF34C759)
        : score <= 3.5
            ? const Color(0xFFFF3B30)
            : const Color(0xFFFFCC00);
    final conf = confidence == null
        ? ''
        : ' · 置信度${_confidenceZh[confidence!.toLowerCase()] ?? confidence}';
    return Row(
      children: [
        Text('市场情绪',
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: t,
              minHeight: 8,
              color: color,
              backgroundColor: const Color(0xFF2C2C2E),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('${score.toStringAsFixed(1)}/10$conf',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 价位标尺
// ---------------------------------------------------------------------------

class _PriceLadderCard extends StatelessWidget {
  const _PriceLadderCard({required this.levels, required this.prefix});
  final List<PriceLevel> levels;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('关键价位', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            SizedBox(
              height: 136,
              width: double.infinity,
              child: CustomPaint(
                painter: _LadderPainter(
                  levels: levels,
                  axisColor: const Color(0xFF3A3A3C),
                  baseTextColor:
                      Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LadderPainter extends CustomPainter {
  _LadderPainter({required this.levels, required this.axisColor, required this.baseTextColor});
  final List<PriceLevel> levels; // 已按价格升序
  final Color axisColor;
  final Color baseTextColor;

  Color _levelColor(String label) => switch (label) {
        '现价' => Colors.white,
        '止损' => const Color(0xFFFF3B30),
        '入场' => const Color(0xFF34C759),
        _ => baseTextColor,
      };

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.length < 2) return;
    final min = levels.first.value;
    final max = levels.last.value;
    final span = max - min;
    if (span <= 0) return;
    final pad = span * 0.07;
    const marginX = 10.0;
    final axisY = size.height * 0.52;
    double x(double v) =>
        marginX + (v - min + pad) / (span + 2 * pad) * (size.width - 2 * marginX);

    canvas.drawLine(Offset(marginX, axisY), Offset(size.width - marginX, axisY),
        Paint()..color = axisColor..strokeWidth = 2);

    // 相邻价位在 4 条车道间轮换（近上/近下/远上/远下），避免标签互相压盖。
    final laneY = [axisY - 34, axisY + 12, axisY - 58, axisY + 36];
    for (var i = 0; i < levels.length; i++) {
      final l = levels[i];
      final isNow = l.label == '现价';
      final color = _levelColor(l.label);
      final px = x(l.value);
      final lane = laneY[i % 4];
      final above = lane < axisY;

      canvas.drawLine(
          Offset(px, axisY),
          Offset(px, above ? lane + 24 : lane - 2),
          Paint()..color = color.withValues(alpha: 0.45)..strokeWidth = 1);
      canvas.drawCircle(
          Offset(px, axisY),
          isNow ? 6 : 4,
          Paint()..color = color);
      if (isNow) {
        canvas.drawCircle(Offset(px, axisY), 9,
            Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
      }

      final tp = TextPainter(
        text: TextSpan(
          text: '${l.label}\n${l.value.toStringAsFixed(2)}',
          style: TextStyle(
              color: color,
              fontSize: 10,
              height: 1.2,
              fontWeight: isNow ? FontWeight.w800 : FontWeight.w500),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      final dx = (px - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(dx, above ? lane : lane));
    }
  }

  @override
  bool shouldRepaint(_LadderPainter old) => old.levels != levels;
}

// ---------------------------------------------------------------------------
// 技术信号
// ---------------------------------------------------------------------------

class _TechSignalsCard extends StatelessWidget {
  const _TechSignalsCard({required this.signals});
  final List<IndicatorSignal> signals;

  @override
  Widget build(BuildContext context) {
    final bulls = signals.where((s) => s.tone == Tone.bullish).length;
    final bears = signals.where((s) => s.tone == Tone.bearish).length;
    final flats = signals.length - bulls - bears;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                    child: Text('技术信号', style: TextStyle(fontWeight: FontWeight.w700))),
                Text('$bulls 多 · $flats 平 · $bears 空',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Row(
                children: [
                  for (final (count, tone) in [
                    (bulls, Tone.bullish),
                    (flats, Tone.neutral),
                    (bears, Tone.bearish)
                  ])
                    if (count > 0)
                      Expanded(
                        flex: count,
                        child: Container(height: 8, color: _toneColor(tone)),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in signals)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _toneColor(s.tone).withValues(alpha: 0.6)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_toneIcon(s.tone), size: 14, color: _toneColor(s.tone)),
                        const SizedBox(width: 4),
                        Text(
                          s.value.isEmpty ? s.name : '${s.name} ${s.value}',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 基本面要点
// ---------------------------------------------------------------------------

class _FundamentalsCard extends StatelessWidget {
  const _FundamentalsCard({required this.metrics});
  final List<LabeledValue> metrics;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('基本面要点', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - 8) / 2;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in metrics)
                      Container(
                        width: w,
                        padding:
                            const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                            const SizedBox(height: 2),
                            Text(m.value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w800)),
                            if (m.note != null)
                              Text(m.note!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 多空对辩 & 风控视角（列卡片，点开底部弹层看全文）
// ---------------------------------------------------------------------------

void _showReportSheet(BuildContext context, String title, String md) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text(title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          MarkdownBody(data: md),
        ],
      ),
    ),
  );
}

class _DebateColumn extends StatelessWidget {
  const _DebateColumn(
      {required this.title, required this.color, required this.icon, required this.md});
  final String title;
  final Color color;
  final IconData icon;
  final String md;

  @override
  Widget build(BuildContext context) {
    final text = cleanDebate(md);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showReportSheet(context, title, text),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 5),
                  Text(title,
                      style: TextStyle(fontWeight: FontWeight.w800, color: color)),
                ],
              ),
              const SizedBox(height: 8),
              Text(excerpt(text, maxChars: 110),
                  style: const TextStyle(fontSize: 12.5, height: 1.5)),
              const SizedBox(height: 6),
              Text('全文 ›',
                  style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BullBearRow extends StatelessWidget {
  const _BullBearRow({required this.analysis});
  final Analysis analysis;

  @override
  Widget build(BuildContext context) {
    final bull = analysis.section('bull');
    final bear = analysis.section('bear');
    if (bull.isEmpty && bear.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bull.isNotEmpty)
            Expanded(
                child: _DebateColumn(
                    title: '多方观点',
                    color: const Color(0xFF34C759),
                    icon: Icons.north_east,
                    md: bull)),
          if (bull.isNotEmpty && bear.isNotEmpty) const SizedBox(width: 8),
          if (bear.isNotEmpty)
            Expanded(
                child: _DebateColumn(
                    title: '空方观点',
                    color: const Color(0xFFFF3B30),
                    icon: Icons.south_east,
                    md: bear)),
        ],
      ),
    );
  }
}

class _RiskRow extends StatelessWidget {
  const _RiskRow({required this.analysis});
  final Analysis analysis;

  @override
  Widget build(BuildContext context) {
    const views = [
      (key: 'riskAggressive', title: '激进', icon: Icons.local_fire_department_outlined,
          color: Color(0xFFFF9500)),
      (key: 'riskNeutral', title: '中性', icon: Icons.balance_outlined,
          color: Color(0xFF8E8E93)),
      (key: 'riskConservative', title: '保守', icon: Icons.shield_outlined,
          color: Color(0xFF64D2FF)),
    ];
    final present =
        views.where((v) => analysis.section(v.key).isNotEmpty).toList();
    if (present.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, v) in present.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _showReportSheet(context, '${v.title}风控视角',
                      cleanDebate(analysis.section(v.key))),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(v.icon, size: 14, color: v.color),
                            const SizedBox(width: 4),
                            Text(v.title,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: v.color)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          excerpt(cleanDebate(analysis.section(v.key)),
                              maxChars: 46),
                          style: const TextStyle(fontSize: 11, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 通用可展开卡片（单列，内联展开全文）
// ---------------------------------------------------------------------------

class _ExpandableCard extends StatefulWidget {
  const _ExpandableCard(
      {required this.icon, required this.title, this.badge, required this.excerptText,
      required this.fullMd, this.dense = false});
  final IconData icon;
  final String title;
  final String? badge;
  final String excerptText;
  final String fullMd;
  final bool dense;

  @override
  State<_ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<_ExpandableCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final badgeIdx = widget.badge == null ? null : ratingIndex(widget.badge!);
    final badgeColor =
        badgeIdx == null ? const Color(0xFF8E8E93) : _ratingColors[badgeIdx];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: EdgeInsets.all(widget.dense ? 12 : 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(widget.icon, size: 17,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(widget.title,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  if (widget.badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                          badgeIdx == null ? widget.badge! : ratingZh(badgeIdx),
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: badgeColor)),
                    ),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 8),
              if (_expanded)
                MarkdownBody(data: widget.fullMd)
              else
                Text(widget.excerptText,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: widget.dense
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : null)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 历史评级时间线
// ---------------------------------------------------------------------------

class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({required this.history});
  final List<Analysis> history; // 新→旧

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('历史评级 · 点开看当次报告'),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: history.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final a = history[i];
              final idx = ratingIndex(a.decision);
              final color =
                  idx == null ? const Color(0xFF8E8E93) : _ratingColors[idx];
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AnalysisDetailPage(analysis: a))),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(a.tradeDate.length >= 10
                            ? a.tradeDate.substring(5) : a.tradeDate,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(8),
                        border: i == 0 ? Border.all(color: color) : null,
                      ),
                      child: Text(idx == null ? a.decision : ratingZh(idx),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: color)),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
