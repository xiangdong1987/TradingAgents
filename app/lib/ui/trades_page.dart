// app/lib/ui/trades_page.dart
/// 流水：从持仓页进入，按日期倒序列出买卖成交与分红/利息。
/// 卖出行右侧显示这笔的已实现盈亏（标的原币），买入行显示成交额，
/// 分红行显示到账金额（runner 自动抓的标「自动估算」，税前毛额）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../models/models.dart';
import '../providers.dart';
import 'widgets/pnl.dart';

class TradesPage extends ConsumerWidget {
  const TradesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final trades = ref.watch(tradesProvider).value ?? const <Trade>[];
    final incomes = ref.watch(incomeProvider).value ?? const <Income>[];
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    // 成交与分红混排成一条时间线（各自流已按日期倒序，合并后再排一次）
    final rows = <(String, Object)>[
      for (final t in trades) (t.date, t),
      for (final i in incomes) (i.date, i),
    ]..sort((a, b) => b.$1.compareTo(a.$1));

    return Scaffold(
      appBar: AppBar(title: Text(t.tradeHistory)),
      body: rows.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long_outlined, size: 48, color: grey),
                    const SizedBox(height: 8),
                    Text(t.noTrades, style: TextStyle(color: grey)),
                  ],
                ),
              ),
            )
          : ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final entry = rows[i].$2;
                if (entry is Income) return _incomeTile(context, t, grey, entry);
                final tr = entry as Trade;
                final prefix = currencyPrefix(tr.ticker);
                final sideColor = tr.isSell ? pnlColor(-1) : pnlColor(1);
                return ListTile(
                  onTap: () => showDialog<void>(
                      context: context, builder: (_) => _TradeEditDialog(trade: tr)),
                  leading: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: sideColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(tr.isSell ? t.sell : t.buy,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: sideColor)),
                  ),
                  title: Text(tr.ticker,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  // 税后金额放副标题（可换行），trailing 只留成交额 + 盈亏：
                  // 三者挤在 trailing 一列时，英文「After tax」会把行顶出屏幕。
                  subtitle: Text(
                    [
                      t.positionSubtitle(
                          formatMoney(tr.shares).replaceAll(RegExp(r'\.00$'), ''),
                          tr.price.toStringAsFixed(2)),
                      tr.date,
                      if (tr.realizedPnl != null && (tr.taxAmount ?? 0) > 0)
                        '${t.afterTax} $prefix${formatMoney(tr.realizedNet!)}',
                      if (tr.suggestionId != null) t.fromSuggestion,
                    ].join(' · '),
                    style: TextStyle(color: grey, fontSize: 12),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      MoneyText(tr.amount, size: 15, prefix: prefix, color: grey),
                      if (tr.realizedPnl case final pnl?) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${pnl >= 0 ? '+' : ''}$prefix${formatMoney(pnl)}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: pnlColor(pnl)),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// 分红/利息行：左侧「分红」标签，右侧到账金额；自动抓取的标注来源。
Widget _incomeTile(BuildContext context, L10n t, Color grey, Income inc) {
  final prefix = currencyPrefix(inc.ticker);
  const color = Color(0xFF0A84FF);   // 蓝色区别于买(绿)/卖(红)
  return ListTile(
    onTap: () => showDialog<void>(
        context: context, builder: (_) => _IncomeEditDialog(income: inc)),
    leading: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(t.incomeLabel,
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w800, color: color)),
    ),
    title: Text(inc.ticker,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
    subtitle: Text(
      [
        inc.date,
        if (inc.perShare case final ps?) '$prefix${ps.toStringAsFixed(4)}/股',
        if (inc.isAuto) t.autoEstimate,
        if ((inc.note ?? '').isNotEmpty) inc.note!,
      ].join(' · '),
      style: TextStyle(color: grey, fontSize: 12),
    ),
    trailing: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('+$prefix${formatMoney(inc.amount)}',
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: color)),
        if (inc.taxAmount > 0)
          Text('${t.afterTax} $prefix${formatMoney(inc.net)}',
              style: TextStyle(fontSize: 11, color: grey)),
      ],
    ),
  );
}

/// 成交编辑：改股数/价格/日期，或删除。两者都会按差额回滚持仓与现金。
class _TradeEditDialog extends ConsumerStatefulWidget {
  const _TradeEditDialog({required this.trade});
  final Trade trade;

  @override
  ConsumerState<_TradeEditDialog> createState() => _TradeEditDialogState();
}

class _TradeEditDialogState extends ConsumerState<_TradeEditDialog> {
  late final _shares = TextEditingController(text: _num(widget.trade.shares));
  late final _price =
      TextEditingController(text: widget.trade.price.toStringAsFixed(2));
  late final _date = TextEditingController(text: widget.trade.date);

  @override
  void dispose() {
    _shares.dispose();
    _price.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final shares = double.tryParse(_shares.text);
    final price = double.tryParse(_price.text);
    if (shares == null || shares <= 0 || price == null || price <= 0) return;
    final t = ref.read(l10nProvider);
    await ref.read(repoProvider).updateTrade(widget.trade.id,
        shares: shares, price: price, date: _date.text.trim());
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.entryUpdated)));
  }

  Future<void> _delete() async {
    final t = ref.read(l10nProvider);
    final ok = await _confirmDelete(context, t);
    if (ok != true || !mounted) return;
    await ref.read(repoProvider).deleteTrade(widget.trade.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.entryDeleted)));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final tr = widget.trade;
    return AlertDialog(
      title: Text('${tr.isSell ? t.sell : t.buy} ${tr.ticker}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('editShares'),
            controller: _shares,
            decoration: InputDecoration(labelText: t.shares),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('editPrice'),
            controller: _price,
            decoration: InputDecoration(
                labelText: '${t.priceLabel} (${currencyPrefix(tr.ticker)})'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('editDate'),
            controller: _date,
            decoration: InputDecoration(labelText: t.tradeDate),
          ),
        ],
      ),
      actions: [
        TextButton(
            key: const Key('editDelete'), onPressed: _delete, child: Text(t.delete)),
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
            key: const Key('editSave'), onPressed: _save, child: Text(t.save)),
      ],
    );
  }
}

/// 分红编辑：改金额/税额/日期/备注，或删除。当初计入现金的记录会同步调整现金。
class _IncomeEditDialog extends ConsumerStatefulWidget {
  const _IncomeEditDialog({required this.income});
  final Income income;

  @override
  ConsumerState<_IncomeEditDialog> createState() => _IncomeEditDialogState();
}

class _IncomeEditDialogState extends ConsumerState<_IncomeEditDialog> {
  late final _amount =
      TextEditingController(text: widget.income.amount.toStringAsFixed(2));
  late final _tax =
      TextEditingController(text: widget.income.taxAmount.toStringAsFixed(2));
  late final _date = TextEditingController(text: widget.income.date);
  late final _note = TextEditingController(text: widget.income.note ?? '');

  @override
  void dispose() {
    _amount.dispose();
    _tax.dispose();
    _date.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text);
    final tax = double.tryParse(_tax.text) ?? 0;
    if (amount == null || amount <= 0) return;
    final t = ref.read(l10nProvider);
    await ref.read(repoProvider).updateIncome(widget.income.id,
        amount: amount, taxAmount: tax, date: _date.text.trim(),
        note: _note.text.trim());
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.entryUpdated)));
  }

  Future<void> _delete() async {
    final t = ref.read(l10nProvider);
    final ok = await _confirmDelete(context, t);
    if (ok != true || !mounted) return;
    await ref.read(repoProvider).deleteIncome(widget.income.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(t.entryDeleted)));
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final prefix = currencyPrefix(widget.income.ticker);
    return AlertDialog(
      title: Text('${t.incomeLabel} ${widget.income.ticker}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('editIncomeAmount'),
            controller: _amount,
            decoration:
                InputDecoration(labelText: '${t.preTax} ($prefix)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('editIncomeTax'),
            controller: _tax,
            decoration: InputDecoration(labelText: '${t.taxAmount} ($prefix)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          TextField(
            key: const Key('editIncomeDate'),
            controller: _date,
            decoration: InputDecoration(labelText: t.tradeDate),
          ),
          TextField(
            key: const Key('editIncomeNote'),
            controller: _note,
            decoration: InputDecoration(labelText: t.incomeNote),
          ),
        ],
      ),
      actions: [
        TextButton(
            key: const Key('editIncomeDelete'),
            onPressed: _delete,
            child: Text(t.delete)),
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
            key: const Key('editIncomeSave'), onPressed: _save, child: Text(t.save)),
      ],
    );
  }
}

Future<bool?> _confirmDelete(BuildContext context, L10n t) => showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.deleteTradeTitle),
        content: Text(t.deleteTradeBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false), child: Text(t.cancel)),
          TextButton(
              key: const Key('confirmDelete'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.delete)),
        ],
      ),
    );

/// 整数股数不带小数点显示（10.5 保留、11.0 显示 11）。
String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
