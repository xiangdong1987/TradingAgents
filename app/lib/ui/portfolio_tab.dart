// app/lib/ui/portfolio_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';

class PortfolioTab extends ConsumerWidget {
  const PortfolioTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions = ref.watch(positionsProvider).value ?? const <Position>[];
    final meta = ref.watch(portfolioMetaProvider).value ??
        const PortfolioMeta(cash: 0, currency: 'USD');
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};

    double priceOf(Position p) => quotes[p.ticker]?.close ?? p.avgCost;
    final stockValue =
        positions.fold<double>(0, (sum, p) => sum + p.shares * priceOf(p));
    final total = meta.cash + stockValue;
    final cost = positions.fold<double>(0, (s, p) => s + p.shares * p.avgCost);
    // 总浮动盈亏 % 相对持仓投入成本计算（不含现金——现金已单独展示，且现金本身不产生盈亏，
    // 计入分母会人为稀释持仓的真实收益率）。
    final hasQuote = positions.any((p) => quotes.containsKey(p.ticker));
    final pnlPct = (cost > 0 && hasQuote) ? (stockValue - cost) / cost * 100 : null;

    return Scaffold(
      body: ListView(
        children: [
          Card(
            key: const Key('cashCard'),
            margin: const EdgeInsets.all(16),
            child: InkWell(
              onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => _CashDialog(ref: ref, current: meta.cash)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('现金 ${meta.cash.toStringAsFixed(2)} ${meta.currency}'),
                    Text('总市值 ${total.toStringAsFixed(2)}'),
                    Text('浮动盈亏 ${pnlPct == null ? '—' : '${pnlPct >= 0 ? '+' : ''}${pnlPct.toStringAsFixed(2)}%'}'),
                  ],
                ),
              ),
            ),
          ),
          if (positions.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无持仓')))
          else
            for (final p in positions)
              ListTile(
                title: Text(p.ticker),
                subtitle: Text(
                    '${p.shares.toStringAsFixed(0)} 股 @ ${p.avgCost.toStringAsFixed(2)}'),
                trailing: Text(_pnlLine(p, quotes[p.ticker])),
                onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _PositionDialog(ref: ref, existing: p)),
              ),
          const SizedBox(height: 80),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => _PositionDialog(ref: ref)),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _pnlLine(Position p, TickerQuote? q) {
    if (q == null) return '现价 —';
    final pnl = (q.close - p.avgCost) / p.avgCost * 100;
    return '${q.close.toStringAsFixed(2)}  ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}%';
  }
}

class _CashDialog extends StatefulWidget {
  const _CashDialog({required this.ref, required this.current});
  final WidgetRef ref;
  final double current;

  @override
  State<_CashDialog> createState() => _CashDialogState();
}

class _CashDialogState extends State<_CashDialog> {
  late final _cash = TextEditingController(text: widget.current.toStringAsFixed(2));

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cash = double.tryParse(_cash.text);
    if (cash == null || cash < 0) return;
    await widget.ref.read(repoProvider).setCash(cash);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑现金'),
      content: TextField(
        key: const Key('cashField'),
        controller: _cash,
        decoration: const InputDecoration(labelText: '现金'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(key: const Key('cashSave'), onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _PositionDialog extends StatefulWidget {
  const _PositionDialog({required this.ref, this.existing});
  final WidgetRef ref;
  final Position? existing;

  @override
  State<_PositionDialog> createState() => _PositionDialogState();
}

class _PositionDialogState extends State<_PositionDialog> {
  late final _ticker = TextEditingController(text: widget.existing?.ticker ?? '');
  late final _shares =
      TextEditingController(text: widget.existing?.shares.toStringAsFixed(0) ?? '');
  late final _avgCost =
      TextEditingController(text: widget.existing?.avgCost.toStringAsFixed(2) ?? '');

  @override
  void dispose() {
    _ticker.dispose();
    _shares.dispose();
    _avgCost.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ticker = _ticker.text.trim().toUpperCase();
    final shares = double.tryParse(_shares.text);
    final avgCost = double.tryParse(_avgCost.text);
    if (ticker.isEmpty || shares == null || shares <= 0 || avgCost == null || avgCost <= 0) {
      return;
    }
    await widget.ref
        .read(repoProvider)
        .setPosition(ticker: ticker, shares: shares, avgCost: avgCost);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await widget.ref.read(repoProvider).deletePosition(existing.ticker);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text('已删除 ${existing.ticker}')));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? '新增持仓' : '编辑持仓：${widget.existing!.ticker}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isNew)
            TextField(
              key: const Key('posTicker'),
              controller: _ticker,
              decoration: const InputDecoration(labelText: 'Ticker'),
              textCapitalization: TextCapitalization.characters,
            ),
          TextField(
            key: const Key('posShares'),
            controller: _shares,
            decoration: const InputDecoration(labelText: '股数'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('posAvgCost'),
            controller: _avgCost,
            decoration: const InputDecoration(labelText: '成本价'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
      actions: [
        if (!isNew)
          TextButton(
              key: const Key('posDelete'), onPressed: _delete, child: const Text('删除')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(key: const Key('posSave'), onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
