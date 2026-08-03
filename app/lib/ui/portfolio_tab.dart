// app/lib/ui/portfolio_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../logic/portfolio_math.dart';
import '../models/models.dart';
import '../providers.dart';
import 'trades_page.dart';
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
    final trades = ref.watch(tradesProvider).value ?? const <Trade>[];
    final realized = realizedPnlEur(trades, quotes);
    final conc = concentration(positions, meta, quotes);
    final weights = {for (final s in conc?.stats ?? const []) s.ticker: s.weightPct};

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
                        const SizedBox(width: 24),
                        _OverviewColumn(
                            label: t.realizedPnl,
                            value: realized == null
                                ? const Text('—')
                                : MoneyText(realized, size: 15, prefix: '€',
                                    color: realized == 0 ? null : pnlColor(realized))),
                        const SizedBox(width: 24),
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
          if (conc != null) _ConcentrationCard(conc: conc),
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
                  [
                    t.positionSubtitle(
                        p.shares.toStringAsFixed(0), p.avgCost.toStringAsFixed(2)),
                    if (weights[p.ticker] case final w?)
                      '${w.toStringAsFixed(1)}%',
                  ].join(' · '),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                trailing: _positionTrailing(t, p, quotes[p.ticker]),
                onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _PositionDialog(existing: p)),
              ),
          ListTile(
            key: const Key('tradeHistoryEntry'),
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(t.tradeHistory),
            subtitle: trades.isEmpty ? null : Text('${trades.length}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TradesPage())),
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

/// 集中度卡：一条按权重降序的堆叠色带（末段灰色为现金）+ 一行关键比例。
/// 用来一眼看出「有没有押太重在某一只上」，对接仓位管理方案的单票/分层上限。
class _ConcentrationCard extends ConsumerWidget {
  const _ConcentrationCard({required this.conc});
  final Concentration conc;

  static const _palette = [
    Color(0xFF34C759), Color(0xFF0A84FF), Color(0xFFFF9F0A),
    Color(0xFFBF5AF2), Color(0xFF5AC8FA), Color(0xFFFF375F),
    Color(0xFFFFD60A), Color(0xFF64D2FF),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.concentration, style: TextStyle(fontSize: 12, color: grey)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(
                  // 无子节点的 ColoredBox 按最小约束取尺寸，Row 默认给的高度
                  // 约束是松的（0~8）→ 会得到 0 高、整条色带不可见。stretch
                  // 把高度约束改成紧的，色带才画得出来。
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, s) in conc.stats.indexed)
                      Expanded(
                        flex: (s.weightPct * 100).round().clamp(1, 1 << 30),
                        child: ColoredBox(color: _palette[i % _palette.length]),
                      ),
                    if (conc.cashPct > 0)
                      Expanded(
                        flex: (conc.cashPct * 100).round().clamp(1, 1 << 30),
                        child: ColoredBox(color: grey.withValues(alpha: 0.35)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                t.concentrationDetail(
                    conc.topPct.toStringAsFixed(1),
                    conc.top3Pct.toStringAsFixed(1),
                    conc.cashPct.toStringAsFixed(1)),
                maxLines: 1,
                style: TextStyle(fontSize: 12, color: grey),
              ),
            ),
          ],
        ),
      ),
    );
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
        if (!isNew)
          FilledButton.tonal(
            key: const Key('posSell'),
            onPressed: () {
              final p = widget.existing!;
              Navigator.of(context).pop();          // 关掉编辑框再开卖出框
              showDialog<void>(
                  context: context, builder: (_) => _SellDialog(position: p));
            },
            child: Text(t.sell),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(key: const Key('posSave'), onPressed: _save, child: Text(t.save)),
      ],
    );
  }
}

/// 卖出对话框：股数缺省全部、价格缺省当前行情、日期缺省今天。
/// 提交走 `repo.applyTrade`——记流水 + 改持仓 + 加回现金，一次原子写。
class _SellDialog extends ConsumerStatefulWidget {
  const _SellDialog({required this.position});
  final Position position;

  @override
  ConsumerState<_SellDialog> createState() => _SellDialogState();
}

class _SellDialogState extends ConsumerState<_SellDialog> {
  late final _shares = TextEditingController(text: _fmtPrefill(widget.position.shares));
  late final TextEditingController _price = TextEditingController();
  late final _date = TextEditingController(
      text: DateTime.now().toIso8601String().substring(0, 10));
  var _prefilledPrice = false;

  @override
  void dispose() {
    _shares.dispose();
    _price.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final shares = double.tryParse(_shares.text);
    final price = double.tryParse(_price.text);
    final date = _date.text.trim();
    if (shares == null || shares <= 0 || price == null || price <= 0 || date.isEmpty) {
      return;
    }
    final t = ref.read(l10nProvider);
    await ref.read(repoProvider).applyTrade(
        ticker: widget.position.ticker, side: 'sell', shares: shares,
        price: price, date: date);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.tradeRecorded)));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final quote = quotes[widget.position.ticker];
    if (!_prefilledPrice && quote != null) {
      _price.text = quote.close.toStringAsFixed(2);
      _prefilledPrice = true;
    }
    final prefix = currencyPrefix(widget.position.ticker);
    return AlertDialog(
      title: Text(t.sellTitle(widget.position.ticker)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.heldShares(_fmtPrefill(widget.position.shares)),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          TextField(
            key: const Key('sellShares'),
            controller: _shares,
            decoration: InputDecoration(
              labelText: t.shares,
              suffixIcon: TextButton(
                key: const Key('sellAll'),
                onPressed: () =>
                    _shares.text = _fmtPrefill(widget.position.shares),
                child: Text(t.sellAll),
              ),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('sellPrice'),
            controller: _price,
            decoration: InputDecoration(labelText: '${t.priceLabel} ($prefix)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('sellDate'),
            controller: _date,
            decoration: InputDecoration(labelText: t.tradeDate),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
            key: const Key('sellConfirm'), onPressed: _submit, child: Text(t.sell)),
      ],
    );
  }
}
