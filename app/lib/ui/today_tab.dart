import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
// Markdown 渲染 import 按 Task 1 选定的包调整：
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../l10n.dart';
import '../logic/portfolio_math.dart';
import '../models/models.dart';
import '../providers.dart';
import 'widgets/markdown.dart';
import 'widgets/pnl.dart';
import 'widgets/stream_error.dart';
import 'widgets/suggestion_card.dart';

class TodayTab extends ConsumerWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final lang = ref.watch(langProvider);
    final brief = ref.watch(latestBriefProvider);
    final suggestions = ref.watch(pendingSuggestionsProvider);
    final jobs = ref.watch(activeJobsProvider);
    final positions = ref.watch(positionsProvider).value ?? const <Position>[];
    final meta = ref.watch(portfolioMetaProvider).value ??
        const PortfolioMeta(cash: 0, currency: 'USD');
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final summary = summarize(positions, meta, quotes);

    return ListView(
      children: [
        // 1. 任务与 runner 状态卡置顶
        _ActiveJobsCard(
          jobs: jobs.value ?? const <Job>[],
          runner: ref.watch(runnerStatusProvider).value,
        ),
        // 2. 概览一条 + 3. 日历为主体
        _OverviewBar(summary: summary),
        _AgendaCard(events: ref.watch(calendarEventsProvider).value ?? const []),
        // 4. 日报默认收起，点开展阅
        brief.when(
          data: (b) => b == null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(t.noBriefYet, textAlign: TextAlign.center),
                )
              : Card(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    key: const Key('briefTile'),
                    title: Text(t.dailyBriefTitle(b.date),
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    leading: const Icon(Icons.article_outlined, size: 18),
                    shape: const Border(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: MarkdownBody(
                            data: b.markdownFor(lang),
                            styleSheet: compactMarkdown(context)),
                      ),
                    ],
                  ),
                ),
          loading: () => const Padding(
              padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => StreamError(error: e, onRetry: () => ref.invalidate(latestBriefProvider)),
        ),
        // 5. 建议区：头部常显（右侧海龟扫描触发点），有建议时列卡片
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(t.pendingSuggestions,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              const _StrategyScanAction(),
            ],
          ),
        ),
        ...switch (suggestions) {
          AsyncData(:final value) when value.isNotEmpty => [
              for (final s in value)
                SuggestionCard(
                  suggestion: s,
                  onDismiss: () async {
                    await ref.read(repoProvider).resolveSuggestion(s.id, accepted: false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(t.dismissed)));
                    }
                  },
                  onAccept: () => showDialog<void>(
                    context: context,
                    builder: (_) => _AcceptDialog(suggestion: s),
                  ),
                ),
            ],
          AsyncData() => [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(t.noPendingSuggestions,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          _ => const <Widget>[],
        },
        const SizedBox(height: 24),
      ],
    );
  }
}

/// 建议区头部的策略触发点：点一下排一条海龟扫描 job（持仓+自选，
/// 零 LLM 成本）；已有排队/进行中的扫描时变成状态 chip 防重复排队。
class _StrategyScanAction extends ConsumerWidget {
  const _StrategyScanAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final jobs = ref.watch(activeJobsProvider).value ?? const <Job>[];
    final scanning = jobs.any((j) => j.type == 'strategy_scan');
    if (scanning) {
      return Chip(
        visualDensity: VisualDensity.compact,
        label: Text(t.turtleScanning, style: const TextStyle(fontSize: 12)),
        side: BorderSide(color: Theme.of(context).colorScheme.onSurfaceVariant),
        backgroundColor: Colors.transparent,
      );
    }
    return FilledButton.tonal(
      key: const Key('turtleScan'),
      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: () async {
        await ref.read(repoProvider).enqueueStrategyScan();
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t.turtleScanQueued)));
        }
      },
      child: Text(t.turtleScan),
    );
  }
}

/// Apple-Stocks-style hero overview: the EUR total owns a full line in large
/// type (FittedBox so long amounts scale down instead of wrapping on phones),
/// with pnl and cash demoted to a small secondary row underneath.
class _OverviewBar extends ConsumerWidget {
  const _OverviewBar({required this.summary});
  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.totalValue, style: TextStyle(fontSize: 12, color: grey)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: summary.totalEur == null
                  ? const Text('—',
                      style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800))
                  : MoneyText(summary.totalEur!,
                      size: 32, weight: FontWeight.w800, prefix: '€'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _MiniStat(
                  label: t.pnlFloating,
                  value: summary.pnlPct == null
                      ? const Text('—')
                      : Text(
                          pnlLabel(summary.pnlPct!),
                          style: TextStyle(
                              color: pnlColor(summary.pnlPct!),
                              fontSize: 15,
                              fontWeight: FontWeight.w700),
                        ),
                ),
                const SizedBox(width: 28),
                _MiniStat(
                  label: t.cash,
                  value: summary.cashEur == null
                      ? const Text('—')
                      : MoneyText(summary.cashEur!,
                          size: 15, color: grey, prefix: '€'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small gray label above a compact value — one cell of the secondary row.
class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        value,
      ],
    );
  }
}

class _AcceptDialog extends ConsumerStatefulWidget {
  const _AcceptDialog({required this.suggestion});
  final Suggestion suggestion;

  @override
  ConsumerState<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends ConsumerState<_AcceptDialog> {
  // 预填建议股数（被 Policy 钳过的就是钳后的数）；被拦住的建议不填，
  // 逼你自己想清楚要下多少。
  late final _shares = TextEditingController(
      text: (widget.suggestion.isBlocked || widget.suggestion.shares == null)
          ? ''
          : formatShares(widget.suggestion.shares!).replaceAll(',', ''));
  final _price = TextEditingController();
  var _prefilledPrice = false;

  @override
  void dispose() {
    _shares.dispose();
    _price.dispose();
    super.dispose();
  }

  String get _side => switch (widget.suggestion.action) {
        'sell' || 'trim' => 'sell',
        _ => 'buy',
      };

  Future<void> _accept({required bool withTrade}) async {
    final repo = ref.read(repoProvider);
    if (withTrade) {
      final shares = double.tryParse(_shares.text);
      final price = double.tryParse(_price.text);
      if (shares == null || shares <= 0 || price == null || price <= 0) return;
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      // 走 applyTrade：一次 batch 里记流水 + 改持仓 + 改现金 + 把建议标记采纳，
      // 统计与实际持仓不会脱节（早先的 acceptWithTrade 只写流水，已弃用）。
      final landed = await repo.applyTrade(
          ticker: widget.suggestion.ticker, side: _side, shares: shares,
          price: price, date: today, suggestionId: widget.suggestion.id);
      if (!landed && mounted) {
        final t = ref.read(l10nProvider);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.nothingToSell)));
      }
    } else {
      await repo.resolveSuggestion(widget.suggestion.id, accepted: true);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final s = widget.suggestion;
    // 成交价缺省当前行情（建议里带的 entry 是信号价，可能已过时）
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final quote = quotes[s.ticker];
    if (!_prefilledPrice && quote != null) {
      _price.text = quote.close.toStringAsFixed(2);
      _prefilledPrice = true;
    }
    return AlertDialog(
      title: Text(t.acceptTitle(s.ticker, s.action.toUpperCase())),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.recordTradeHint),
          TextField(key: const Key('tradeShares'), controller: _shares,
              decoration: InputDecoration(labelText: t.shares),
              keyboardType: TextInputType.number),
          TextField(key: const Key('tradePrice'), controller: _price,
              decoration: InputDecoration(labelText: t.priceLabel),
              keyboardType: TextInputType.number),
        ],
      ),
      actions: [
        TextButton(key: const Key('acceptOnly'),
            onPressed: () => _accept(withTrade: false), child: Text(t.acceptOnly)),
        FilledButton(key: const Key('acceptWithTrade'),
            onPressed: () => _accept(withTrade: true), child: Text(t.acceptWithTrade)),
      ],
    );
  }
}

/// 财报/分红月历（真实日历组件）：有事件的日期打点，点选看当日明细。
class _AgendaCard extends ConsumerStatefulWidget {
  const _AgendaCard({required this.events});
  final List<CalendarEvent> events;

  @override
  ConsumerState<_AgendaCard> createState() => _AgendaCardState();
}

class _AgendaCardState extends ConsumerState<_AgendaCard> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();

  List<CalendarEvent> _eventsOn(DateTime day) {
    final key = day.toIso8601String().substring(0, 10);
    return [for (final e in widget.events) if (e.date == key) e];
  }

  /// 事件类型展示名走 l10n（模型的 typeLabel getter 保留但 UI 不再使用）。
  String _typeLabel(CalendarEvent e, L10n t) => switch (e.type) {
        'earnings' => t.evEarnings,
        'exDividend' => t.evExDividend,
        'dividendPay' => t.evDividendPay,
        _ => e.type,
      };

  @override
  Widget build(BuildContext context) {
    if (widget.events.isEmpty) return const SizedBox.shrink();
    final t = ref.watch(l10nProvider);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final selectedEvents = _eventsOn(_selected);
    final dow = [t.dowMon, t.dowTue, t.dowWed, t.dowThu, t.dowFri, t.dowSat, t.dowSun];

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          children: [
            TableCalendar<CalendarEvent>(
              locale: null,
              firstDay: DateTime.now().subtract(const Duration(days: 180)),
              lastDay: DateTime.now().add(const Duration(days: 365)),
              focusedDay: _focused,
              selectedDayPredicate: (d) => isSameDay(d, _selected),
              onDaySelected: (sel, foc) =>
                  setState(() { _selected = sel; _focused = foc; }),
              eventLoader: _eventsOn,
              startingDayOfWeek: StartingDayOfWeek.monday,
              availableCalendarFormats: const {CalendarFormat.month: '月'},
              headerStyle: const HeaderStyle(
                  formatButtonVisible: false, titleCentered: true),
              daysOfWeekHeight: 22,
              calendarBuilders: CalendarBuilders(
                dowBuilder: (context, day) => Center(
                  child: Text(dow[day.weekday - 1],
                      style: TextStyle(fontSize: 11, color: grey)),
                ),
              ),
              calendarStyle: CalendarStyle(
                outsideDaysVisible: false,
                todayDecoration: BoxDecoration(
                    color: pnlColor(1).withValues(alpha: 0.25),
                    shape: BoxShape.circle),
                selectedDecoration: BoxDecoration(
                    color: pnlColor(1), shape: BoxShape.circle),
                markerDecoration: BoxDecoration(
                    color: pnlColor(1), shape: BoxShape.circle),
                markersMaxCount: 3,
              ),
            ),
            if (selectedEvents.isNotEmpty) const Divider(height: 8),
            for (final e in selectedEvents)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
                child: Row(children: [
                  Expanded(
                    child: Text(e.ticker,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Text(_typeLabel(e, t), style: TextStyle(fontSize: 12, color: grey)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

/// 任务与 runner 状态卡：显示 watch 进程在线/离线、每个进行中任务的
/// 状态与已运行时长；30 秒自刷新时长与在线判定。
class _ActiveJobsCard extends ConsumerStatefulWidget {
  const _ActiveJobsCard({required this.jobs, required this.runner});
  final List<Job> jobs;
  final RunnerStatus? runner;

  @override
  ConsumerState<_ActiveJobsCard> createState() => _ActiveJobsCardState();
}

class _ActiveJobsCardState extends ConsumerState<_ActiveJobsCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _jobLabel(Job j, L10n t) => switch (j.type) {
        'deep_analysis' => t.jobDeepAnalysis(j.ticker ?? ''),
        'refresh_quotes' => t.jobRefreshQuotes,
        'chat' => t.jobChat,
        'strategy_scan' => t.strategyScan,
        _ => t.jobDailyBrief,
      };

  String _elapsed(Job j, DateTime now, L10n t) {
    final from = j.startedAt ?? j.createdAt;
    final mins = now.toUtc().difference(from).inMinutes;
    return mins < 1 ? t.justStarted : t.jobElapsed(mins);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final now = DateTime.now();
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final runner = widget.runner;
    final alive = runner?.aliveAt(now) ?? false;
    final jobs = widget.jobs;
    if (jobs.isEmpty && runner == null) return const SizedBox.shrink();

    String runnerText;
    if (alive) {
      runnerText = t.runnerOnline;
    } else if (runner?.lastSeenAt != null) {
      final mins = now.toUtc().difference(runner!.lastSeenAt!).inMinutes;
      runnerText = t.runnerOffline(mins);
    } else {
      runnerText = t.runnerNotStarted;
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (jobs.isNotEmpty && alive)
            const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(children: [
              Icon(Icons.circle, size: 9,
                  color: alive ? pnlColor(1) : pnlColor(-1)),
              const SizedBox(width: 6),
              Text(runnerText, style: TextStyle(fontSize: 12, color: grey)),
              if (!alive && jobs.isNotEmpty) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(t.jobWaitsForRunner,
                      style: TextStyle(fontSize: 11, color: pnlColor(-1)),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ]),
          ),
          for (final j in jobs)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Row(children: [
                Icon(j.status == 'queued' ? Icons.schedule : Icons.autorenew,
                    size: 15, color: grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_jobLabel(j, t),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                Text(j.status == 'queued' ? t.jobQueued : _elapsed(j, now, t),
                    style: TextStyle(fontSize: 12, color: grey)),
              ]),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

