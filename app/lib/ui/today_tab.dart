import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
// Markdown 渲染 import 按 Task 1 选定的包调整：
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../logic/portfolio_math.dart';
import '../models/models.dart';
import '../providers.dart';
import 'widgets/pnl.dart';
import 'widgets/stream_error.dart';
import 'widgets/suggestion_card.dart';

class TodayTab extends ConsumerWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('还没有日报。runner 会在交易日收盘后生成第一份。',
                      textAlign: TextAlign.center),
                )
              : Card(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    key: const Key('briefTile'),
                    title: Text('每日投资日报 · ${b.date}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    leading: const Icon(Icons.article_outlined, size: 18),
                    shape: const Border(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: MarkdownBody(data: b.markdownZh),
                      ),
                    ],
                  ),
                ),
          loading: () => const Padding(
              padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => StreamError(error: e, onRetry: () => ref.invalidate(latestBriefProvider)),
        ),
        ...switch (suggestions) {
          AsyncData(:final value) when value.isNotEmpty => [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('待处理建议', style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final s in value)
                SuggestionCard(
                  suggestion: s,
                  onDismiss: () async {
                    await ref.read(repoProvider).resolveSuggestion(s.id, accepted: false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('已忽略')));
                    }
                  },
                  onAccept: () => showDialog<void>(
                    context: context,
                    builder: (_) => _AcceptDialog(suggestion: s, ref: ref),
                  ),
                ),
            ],
          _ => const <Widget>[],
        },
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Combined market-value / pnl / cash overview, shown above the daily brief.
/// Mirrors [PortfolioTab]'s three-column overview card but with the
/// heavier 22sp/w800 total emphasis and a de-emphasized (gray) cash column
/// called for by this tab's brief.
class _OverviewBar extends StatelessWidget {
  const _OverviewBar({required this.summary});
  final PortfolioSummary summary;

  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _OverviewColumn(
                label: '总市值',
                labelColor: grey,
                value: summary.totalEur == null
                    ? const Text('—')
                    : MoneyText(summary.totalEur!,
                        size: 22, weight: FontWeight.w800, prefix: '€'),
              ),
            ),
            Expanded(
              child: _OverviewColumn(
                label: '浮动盈亏',
                labelColor: grey,
                value: summary.pnlPct == null
                    ? const Text('—')
                    : Text(
                        pnlLabel(summary.pnlPct!),
                        style: TextStyle(
                            color: pnlColor(summary.pnlPct!),
                            fontSize: 20,
                            fontWeight: FontWeight.w800),
                      ),
              ),
            ),
            Expanded(
              child: _OverviewColumn(
                label: '现金',
                labelColor: grey,
                value: summary.cashEur == null
                    ? const Text('—')
                    : MoneyText(summary.cashEur!,
                        size: 20, color: grey, prefix: '€'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewColumn extends StatelessWidget {
  const _OverviewColumn({required this.label, required this.labelColor, required this.value});
  final String label;
  final Color labelColor;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: labelColor)),
        const SizedBox(height: 4),
        value,
      ],
    );
  }
}

class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.suggestion, required this.ref});
  final Suggestion suggestion;
  final WidgetRef ref;

  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  final _shares = TextEditingController();
  final _price = TextEditingController();

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
    final repo = widget.ref.read(repoProvider);
    if (withTrade) {
      final shares = double.tryParse(_shares.text);
      final price = double.tryParse(_price.text);
      if (shares == null || shares <= 0 || price == null || price <= 0) return;
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      // Batched write: trade doc + suggestion status flip land atomically.
      await repo.acceptWithTrade(
          suggestionId: widget.suggestion.id, ticker: widget.suggestion.ticker,
          side: _side, shares: shares, price: price, date: today);
    } else {
      await repo.resolveSuggestion(widget.suggestion.id, accepted: true);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    return AlertDialog(
      title: Text('采纳建议：${s.ticker} ${s.action.toUpperCase()}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('可顺手记录实际成交（可选）：'),
          TextField(key: const Key('tradeShares'), controller: _shares,
              decoration: const InputDecoration(labelText: '股数'),
              keyboardType: TextInputType.number),
          TextField(key: const Key('tradePrice'), controller: _price,
              decoration: const InputDecoration(labelText: '成交价'),
              keyboardType: TextInputType.number),
        ],
      ),
      actions: [
        TextButton(key: const Key('acceptOnly'),
            onPressed: () => _accept(withTrade: false), child: const Text('仅标记采纳')),
        FilledButton(key: const Key('acceptWithTrade'),
            onPressed: () => _accept(withTrade: true), child: const Text('记录成交并采纳')),
      ],
    );
  }
}

/// 财报/分红月历（真实日历组件）：有事件的日期打点，点选看当日明细。
class _AgendaCard extends StatefulWidget {
  const _AgendaCard({required this.events});
  final List<CalendarEvent> events;

  @override
  State<_AgendaCard> createState() => _AgendaCardState();
}

class _AgendaCardState extends State<_AgendaCard> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();

  List<CalendarEvent> _eventsOn(DateTime day) {
    final key = day.toIso8601String().substring(0, 10);
    return [for (final e in widget.events) if (e.date == key) e];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.events.isEmpty) return const SizedBox.shrink();
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final selectedEvents = _eventsOn(_selected);
    const dow = ['一', '二', '三', '四', '五', '六', '日'];

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
                  Text(e.typeLabel, style: TextStyle(fontSize: 12, color: grey)),
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
class _ActiveJobsCard extends StatefulWidget {
  const _ActiveJobsCard({required this.jobs, required this.runner});
  final List<Job> jobs;
  final RunnerStatus? runner;

  @override
  State<_ActiveJobsCard> createState() => _ActiveJobsCardState();
}

class _ActiveJobsCardState extends State<_ActiveJobsCard> {
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

  String _jobLabel(Job j) => switch (j.type) {
        'deep_analysis' => '${j.ticker} 深度分析',
        'refresh_quotes' => '行情刷新',
        'chat' => '问答回复',
        _ => '日报生成',
      };

  String _elapsed(Job j, DateTime now) {
    final from = j.startedAt ?? j.createdAt;
    final mins = now.toUtc().difference(from).inMinutes;
    return mins < 1 ? '刚开始' : '已 $mins 分钟';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final runner = widget.runner;
    final alive = runner?.aliveAt(now) ?? false;
    final jobs = widget.jobs;
    if (jobs.isEmpty && runner == null) return const SizedBox.shrink();

    String runnerText;
    if (alive) {
      runnerText = 'Runner 在线';
    } else if (runner?.lastSeenAt != null) {
      final mins = now.toUtc().difference(runner!.lastSeenAt!).inMinutes;
      runnerText = 'Runner 离线 · 最后活跃 $mins 分钟前';
    } else {
      runnerText = 'Runner 未启动';
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
                  child: Text('任务将等待 runner 启动',
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
                  child: Text(_jobLabel(j),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                Text(j.status == 'queued' ? '排队中' : _elapsed(j, now),
                    style: TextStyle(fontSize: 12, color: grey)),
              ]),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

