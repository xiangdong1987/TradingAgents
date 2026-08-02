// app/lib/ui/portfolio_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../logic/portfolio_math.dart';
import '../models/models.dart';
import '../providers.dart';
import 'widgets/pnl.dart';
import 'widgets/ticker_field.dart';

class PortfolioTab extends ConsumerWidget {
  const PortfolioTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final positions = ref.watch(positionsProvider).value ?? const <Position>[];
    final meta = ref.watch(portfolioMetaProvider).value ??
        const PortfolioMeta(cash: 0, currency: 'USD');
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final summary = summarize(positions, meta, quotes);

    return Scaffold(
      body: ListView(
        children: [
          Card(
            key: const Key('cashCard'),
            margin: const EdgeInsets.all(16),
            child: InkWell(
              onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => _CashDialog(
                      current: meta.cash, currency: meta.currency)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.totalValue,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: summary.totalEur == null
                          ? const Text('—',
                              style: TextStyle(
                                  fontSize: 32, fontWeight: FontWeight.w800))
                          : MoneyText(summary.totalEur!,
                              size: 32, weight: FontWeight.w800, prefix: '€'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _OverviewColumn(
                            label: t.pnlFloating,
                            value: summary.pnlPct == null
                                ? const Text('—')
                                : Text(
                                    pnlLabel(summary.pnlPct!),
                                    style: TextStyle(
                                        color: pnlColor(summary.pnlPct!),
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700),
                                  )),
                        const SizedBox(width: 28),
                        _OverviewColumn(
                            label: t.cashTapHint,
                            value: summary.cashEur == null
                                ? const Text('—')
                                : MoneyText(summary.cashEur!, size: 15, prefix: '€')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (positions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pie_chart_outline,
                        size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text(t.noPositions),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () => showDialog<void>(
                          context: context, builder: (_) => const _PositionDialog()),
                      child: Text(t.addFirstPosition),
                    ),
                  ],
                ),
              ),
            )
          else
            for (final p in positions)
              ListTile(
                title: Text(p.ticker,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                subtitle: Text(
                  t.positionSubtitle(
                      p.shares.toStringAsFixed(0), p.avgCost.toStringAsFixed(2)),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                trailing: _positionTrailing(t, p, quotes[p.ticker]),
                onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _PositionDialog(existing: p)),
              ),
          const SizedBox(height: 80),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => const _PositionDialog()),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _positionTrailing(L10n t, Position p, TickerQuote? q) {
    if (q == null) {
      // 无行情源的 ISIN 资产（存单/未上市品种）按成本计入总值
      return Text(isIsin(p.ticker) ? t.atCost : t.noPrice);
    }
    final pnl = (q.close - p.avgCost) / p.avgCost * 100;
    return PriceWithPill(
        price: q.close, pct: pnl, prefix: currencyPrefix(p.ticker));
  }
}

/// Small gray label above a compact value — one cell of the secondary
/// pnl / cash row under the hero total.
class _OverviewColumn extends StatelessWidget {
  const _OverviewColumn({required this.label, required this.value});
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
        const SizedBox(height: 4),
        value,
      ],
    );
  }
}

class _CashDialog extends ConsumerStatefulWidget {
  const _CashDialog({required this.current, this.currency = 'EUR'});
  final String currency;
  final double current;

  @override
  ConsumerState<_CashDialog> createState() => _CashDialogState();
}

class _CashDialogState extends ConsumerState<_CashDialog> {
  late final _cash = TextEditingController(text: widget.current.toStringAsFixed(2));
  late String _currency = widget.currency == 'USD' ? 'USD' : 'EUR';

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cash = double.tryParse(_cash.text);
    if (cash == null || cash < 0) return;
    await ref.read(repoProvider).setCash(cash, currency: _currency);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    return AlertDialog(
      title: Text(t.editCash),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('cashField'),
            controller: _cash,
            decoration: InputDecoration(labelText: t.cash),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'EUR', label: Text('€ EUR')),
              ButtonSegment(value: 'USD', label: Text('\$ USD')),
            ],
            selected: {_currency},
            onSelectionChanged: (s) => setState(() => _currency = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(key: const Key('cashSave'), onPressed: _save, child: Text(t.save)),
      ],
    );
  }
}

class _PositionDialog extends ConsumerStatefulWidget {
  const _PositionDialog({this.existing});
  final Position? existing;

  @override
  ConsumerState<_PositionDialog> createState() => _PositionDialogState();
}

/// Formats a double for prefill without corrupting fractional values:
/// whole numbers print without a decimal point (`10.5` stays `10.5`,
/// `11.0` prints `11`), avoiding `toStringAsFixed(0)`'s silent rounding.
String _fmtPrefill(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

class _PositionDialogState extends ConsumerState<_PositionDialog> {
  late final _ticker = TextEditingController(text: widget.existing?.ticker ?? '');
  late final _shares = TextEditingController(
      text: widget.existing == null ? '' : _fmtPrefill(widget.existing!.shares));
  late final _avgCost = TextEditingController(
      text: widget.existing == null ? '' : _fmtPrefill(widget.existing!.avgCost));

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
    await ref
        .read(repoProvider)
        .setPosition(ticker: ticker, shares: shares, avgCost: avgCost);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final t = ref.read(l10nProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.deletePositionTitle(existing.ticker)),
        content: Text(t.irreversible),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.cancel)),
          TextButton(
              key: const Key('posDeleteConfirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.delete)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(repoProvider).deletePosition(existing.ticker);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.deleted(existing.ticker))));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? t.newPosition : t.editPosition(widget.existing!.ticker)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isNew)
            TickerField(fieldKey: const Key('posTicker'), controller: _ticker),
          TextField(
            key: const Key('posShares'),
            controller: _shares,
            decoration: InputDecoration(labelText: t.shares),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('posAvgCost'),
            controller: _avgCost,
            decoration: InputDecoration(labelText: t.avgCost),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
      actions: [
        if (!isNew)
          TextButton(
              key: const Key('posDelete'), onPressed: _delete, child: Text(t.delete)),
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(key: const Key('posSave'), onPressed: _save, child: Text(t.save)),
      ],
    );
  }
}
