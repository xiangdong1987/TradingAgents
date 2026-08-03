// app/lib/ui/portfolio_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../logic/portfolio_math.dart';
import '../logic/tax.dart';
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
    final incomes = ref.watch(incomeProvider).value ?? const <Income>[];
    final ret = cumulativeReturn(summary, trades, incomes, quotes);
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
          if (ret != null) _ReturnCard(ret: ret),
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
      // 「+」给三条路：买入记成交（改现金）、录入已有持仓（不动现金）、补录分红
      floatingActionButton: FloatingActionButton(
        key: const Key('addFab'),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          builder: (sheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  key: const Key('fabBuy'),
                  leading: const Icon(Icons.trending_up),
                  title: Text(t.buyTitleNew),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    showDialog<void>(
                        context: context, builder: (_) => const _BuyDialog());
                  },
                ),
                ListTile(
                  key: const Key('fabEnter'),
                  leading: const Icon(Icons.edit_note),
                  title: Text(t.enterExisting),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    showDialog<void>(
                        context: context, builder: (_) => const _PositionDialog());
                  },
                ),
                ListTile(
                  key: const Key('fabIncome'),
                  leading: const Icon(Icons.savings_outlined),
                  title: Text(t.recordIncome),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    showDialog<void>(
                        context: context, builder: (_) => const _IncomeDialog());
                  },
                ),
              ],
            ),
          ),
        ),
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

/// 累计收益卡：一个大数 + 收益率，下面拆成浮动 / 已实现 / 分红三项。
/// 简单加总口径（非年化、非资金加权），分母是当前持仓成本。
class _ReturnCard extends ConsumerWidget {
  const _ReturnCard({required this.ret});
  final ReturnSummary ret;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final total = ret.totalEur;
    final pct = ret.totalPct;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.cumulativeReturn, style: TextStyle(fontSize: 12, color: grey)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  MoneyText(total,
                      size: 24, weight: FontWeight.w800, prefix: '€',
                      color: pnlColor(total)),
                  if (pct != null) ...[
                    const SizedBox(width: 8),
                    Text(pnlLabel(pct),
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: pnlColor(pct))),
                  ],
                ],
              ),
            ),
            if (ret.taxEur > 0) ...[
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '${t.afterTax} €${formatMoney(ret.netEur)}'
                  '${ret.netPct == null ? '' : ' · ${pnlLabel(ret.netPct!)}'}'
                  '   ${t.tax} €${formatMoney(ret.taxEur)}',
                  maxLines: 1,
                  style: TextStyle(fontSize: 12, color: grey),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                _OverviewColumn(
                    label: t.unrealized,
                    value: MoneyText(ret.unrealizedEur, size: 14, prefix: '€',
                        color: pnlColor(ret.unrealizedEur))),
                const SizedBox(width: 24),
                _OverviewColumn(
                    label: t.realized,
                    value: MoneyText(ret.realizedEur, size: 14, prefix: '€',
                        color: ret.realizedEur == 0 ? grey : pnlColor(ret.realizedEur))),
                const SizedBox(width: 24),
                _OverviewColumn(
                    key: const Key('incomeStat'),
                    label: t.incomeLabel,
                    value: MoneyText(ret.incomeEur, size: 14, prefix: '€',
                        color: ret.incomeEur == 0 ? grey : pnlColor(ret.incomeEur))),
              ],
            ),
          ],
        ),
      ),
    );
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
            const SizedBox(height: 10),
            // 图例：色点 + 标的 + 权重，让色带每一段都能对上是哪只
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final (i, s) in conc.stats.indexed)
                  _LegendChip(
                      color: _palette[i % _palette.length],
                      label: s.ticker,
                      pct: s.weightPct),
                if (conc.cashPct > 0)
                  _LegendChip(
                      color: grey.withValues(alpha: 0.35),
                      label: t.cash,
                      pct: conc.cashPct),
              ],
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

/// 集中度图例的一项：色点 + 标的 + 权重。
class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label, required this.pct});
  final Color color;
  final String label;
  final double pct;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text('$label ${pct.toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Small gray label above a compact value — one cell of the secondary
/// pnl / cash row under the hero total.
class _OverviewColumn extends StatelessWidget {
  const _OverviewColumn({super.key, required this.label, required this.value});
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
  late final _openedAt =
      TextEditingController(text: widget.existing?.openedAt ?? '');

  @override
  void dispose() {
    _ticker.dispose();
    _shares.dispose();
    _avgCost.dispose();
    _openedAt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ticker = _ticker.text.trim().toUpperCase();
    final shares = double.tryParse(_shares.text);
    final avgCost = double.tryParse(_avgCost.text);
    if (ticker.isEmpty || shares == null || shares <= 0 || avgCost == null || avgCost <= 0) {
      return;
    }
    await ref.read(repoProvider).setPosition(
        ticker: ticker, shares: shares, avgCost: avgCost,
        openedAt: _openedAt.text.trim());
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
          TextField(
            key: const Key('posOpenedAt'),
            controller: _openedAt,
            decoration: InputDecoration(
                labelText: t.openedAt, helperText: t.openedAtHint,
                helperMaxLines: 2),
          ),
        ],
      ),
      actions: [
        if (!isNew)
          TextButton(
              key: const Key('posDelete'), onPressed: _delete, child: Text(t.delete)),
        if (!isNew)
          FilledButton.tonal(
            key: const Key('posBuy'),
            onPressed: () {
              final p = widget.existing!;
              Navigator.of(context).pop();
              showDialog<void>(
                  context: context, builder: (_) => _BuyDialog(position: p));
            },
            child: Text(t.buy),
          ),
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

/// 买入对话框：新标的走 ticker 输入，加仓则锁定标的、价格缺省当前行情。
/// 提交走 `repo.applyTrade`——记流水 + 加股数（成本价按加权平均重算）+ 扣现金。
class _BuyDialog extends ConsumerStatefulWidget {
  const _BuyDialog({this.position});
  final Position? position;   // null = 买一只新标的

  @override
  ConsumerState<_BuyDialog> createState() => _BuyDialogState();
}

class _BuyDialogState extends ConsumerState<_BuyDialog> {
  final _ticker = TextEditingController();
  final _shares = TextEditingController();
  final _price = TextEditingController();
  late final _date = TextEditingController(
      text: DateTime.now().toIso8601String().substring(0, 10));
  var _prefilledPrice = false;

  @override
  void dispose() {
    _ticker.dispose();
    _shares.dispose();
    _price.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ticker =
        widget.position?.ticker ?? _ticker.text.trim().toUpperCase();
    final shares = double.tryParse(_shares.text);
    final price = double.tryParse(_price.text);
    final date = _date.text.trim();
    if (ticker.isEmpty || shares == null || shares <= 0 || price == null ||
        price <= 0 || date.isEmpty) {
      return;
    }
    final t = ref.read(l10nProvider);
    await ref.read(repoProvider).applyTrade(
        ticker: ticker, side: 'buy', shares: shares, price: price, date: date);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.tradeRecorded)));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final existing = widget.position;
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    if (!_prefilledPrice && existing != null) {
      final q = quotes[existing.ticker];
      if (q != null) {
        _price.text = q.close.toStringAsFixed(2);
        _prefilledPrice = true;
      }
    }
    final prefix = existing == null ? '' : ' (${currencyPrefix(existing.ticker)})';
    return AlertDialog(
      title: Text(existing == null ? t.buyTitleNew : t.buyTitle(existing.ticker)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (existing == null)
            TickerField(fieldKey: const Key('buyTicker'), controller: _ticker)
          else
            Text(t.heldShares(_fmtPrefill(existing.shares)),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          TextField(
            key: const Key('buyShares'),
            controller: _shares,
            decoration: InputDecoration(labelText: t.shares),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('buyPrice'),
            controller: _price,
            decoration: InputDecoration(labelText: '${t.priceLabel}$prefix'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('buyDate'),
            controller: _date,
            decoration: InputDecoration(labelText: t.tradeDate),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
            key: const Key('buyConfirm'), onPressed: _submit, child: Text(t.buy)),
      ],
    );
  }
}

/// 手工补录分红/利息。ISIN 单券付息只能走这条（Yahoo 无单券数据）。
class _IncomeDialog extends ConsumerStatefulWidget {
  const _IncomeDialog();

  @override
  ConsumerState<_IncomeDialog> createState() => _IncomeDialogState();
}

class _IncomeDialogState extends ConsumerState<_IncomeDialog> {
  final _ticker = TextEditingController();
  final _amount = TextEditingController();
  final _tax = TextEditingController();
  final _note = TextEditingController();
  var _taxEdited = false;
  late final _date = TextEditingController(
      text: DateTime.now().toIso8601String().substring(0, 10));
  var _creditCash = true;

  @override
  void dispose() {
    _ticker.dispose();
    _amount.dispose();
    _tax.dispose();
    _note.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ticker = _ticker.text.trim().toUpperCase();
    final amount = double.tryParse(_amount.text);
    final date = _date.text.trim();
    if (ticker.isEmpty || amount == null || amount <= 0 || date.isEmpty) return;
    final t = ref.read(l10nProvider);
    await ref.read(repoProvider).addIncome(
        ticker: ticker, amount: amount, date: date,
        taxAmount: double.tryParse(_tax.text),
        note: _note.text.trim(), creditCash: _creditCash);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.incomeRecorded)));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    return AlertDialog(
      title: Text(t.recordIncome),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TickerField(fieldKey: const Key('incomeTicker'), controller: _ticker),
          TextField(
            key: const Key('incomeAmount'),
            controller: _amount,
            decoration: InputDecoration(labelText: '${t.incomeAmount}（${t.preTax}）'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) {
              // 税额按标的缺省税率预填，可覆盖
              final gross = double.tryParse(v);
              final ticker = _ticker.text.trim().toUpperCase();
              if (gross != null && ticker.isNotEmpty && !_taxEdited) {
                _tax.text = (gross * defaultIncomeTaxPct(ticker) / 100)
                    .toStringAsFixed(2);
              }
            },
          ),
          TextField(
            key: const Key('incomeTax'),
            controller: _tax,
            decoration: InputDecoration(labelText: t.taxAmount),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _taxEdited = true,
          ),
          TextField(
            key: const Key('incomeDate'),
            controller: _date,
            decoration: InputDecoration(labelText: t.tradeDate),
          ),
          TextField(
            key: const Key('incomeNote'),
            controller: _note,
            decoration: InputDecoration(labelText: t.incomeNote),
          ),
          SwitchListTile(
            key: const Key('incomeCreditCash'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.creditCash, style: const TextStyle(fontSize: 14)),
            value: _creditCash,
            onChanged: (v) => setState(() => _creditCash = v),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
            key: const Key('incomeConfirm'), onPressed: _submit, child: Text(t.save)),
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
