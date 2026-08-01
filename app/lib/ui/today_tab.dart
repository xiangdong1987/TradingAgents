import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        _OverviewBar(summary: summary),
        _AgendaCard(events: ref.watch(calendarEventsProvider).value ?? const []),
        _AskCard(ref: ref, chats: ref.watch(chatsProvider).value ?? const []),
        for (final job in jobs.value ?? const <Job>[])
          MaterialBanner(
            content: Text(switch (job.type) {
              'deep_analysis' =>
                '${job.ticker} 深度分析中（${job.status == "queued" ? "排队" : "分析中"}）',
              'refresh_quotes' => '行情刷新中',
              _ => '日报生成中',
            }),
            // 用静态图标而非不确定态 CircularProgressIndicator：后者的 ticker 永不停止，
            // 会导致 job 处于 running 状态时 widget 测试里的 pumpAndSettle 永远等不到静止而超时。
            leading: const Icon(Icons.sync, size: 20),
            actions: const [SizedBox.shrink()],
          ),
        brief.when(
          data: (b) => b == null
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('还没有日报。runner 会在交易日收盘后生成第一份。',
                      textAlign: TextAlign.center),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.date, style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      MarkdownBody(data: b.markdownZh),
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

/// 近期财报/分红日程（数据来自 meta/calendar，runner 每日刷新）。
class _AgendaCard extends StatelessWidget {
  const _AgendaCard({required this.events});
  final List<CalendarEvent> events;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final upcoming =
        events.where((e) => e.date.compareTo(today) >= 0).take(8).toList();
    if (upcoming.isEmpty) return const SizedBox.shrink();
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.calendar_month, size: 16, color: grey),
              const SizedBox(width: 6),
              Text('近期日程', style: TextStyle(fontSize: 12, color: grey)),
            ]),
            const SizedBox(height: 6),
            for (final e in upcoming)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                    width: 52,
                    child: Text('${e.date.substring(5, 7)}/${e.date.substring(8, 10)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ),
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

/// 「问一问」：结合当前持仓向 LLM 提问（经 chat job 队列，watch 模式下约 2 分钟内回答）。
class _AskCard extends StatefulWidget {
  const _AskCard({required this.ref, required this.chats});
  final WidgetRef ref;
  final List<ChatMessage> chats;

  @override
  State<_AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<_AskCard> {
  final _q = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _q.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.ref.read(repoProvider).askQuestion(text);
      _q.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final recent = widget.chats.take(3).toList();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.chat_bubble_outline, size: 16, color: grey),
              const SizedBox(width: 6),
              Text('问一问（结合当前持仓回答）', style: TextStyle(fontSize: 12, color: grey)),
            ]),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('askField'),
                  controller: _q,
                  decoration: const InputDecoration(
                      hintText: '例：可口可乐和 Intesa 哪个更适合买入？'),
                  onSubmitted: (_) => _send(),
                ),
              ),
              IconButton(
                key: const Key('askSend'),
                icon: const Icon(Icons.send),
                onPressed: _sending ? null : _send,
              ),
            ]),
            for (final c in recent) ...[
              const SizedBox(height: 8),
              Text('问：${c.question}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              switch (c.status) {
                'answered' => MarkdownBody(data: c.answer ?? ''),
                'failed' => Text('回答失败，请重试', style: TextStyle(color: pnlColor(-1))),
                _ => Text('分析中…', style: TextStyle(color: grey)),
              },
            ],
          ],
        ),
      ),
    );
  }
}

