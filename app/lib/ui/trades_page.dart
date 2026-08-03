// app/lib/ui/trades_page.dart
/// 交易流水：从持仓页进入，按日期倒序列出每一笔买卖。
/// 卖出行右侧显示这笔的已实现盈亏（标的原币），买入行显示成交额。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import 'widgets/pnl.dart';

class TradesPage extends ConsumerWidget {
  const TradesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final trades = ref.watch(tradesProvider).value ?? const <Trade>[];
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: Text(t.tradeHistory)),
      body: trades.isEmpty
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
              itemCount: trades.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final tr = trades[i];
                final prefix = currencyPrefix(tr.ticker);
                final sideColor = tr.isSell ? pnlColor(-1) : pnlColor(1);
                return ListTile(
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
                  subtitle: Text(
                    [
                      t.positionSubtitle(
                          formatMoney(tr.shares).replaceAll(RegExp(r'\.00$'), ''),
                          tr.price.toStringAsFixed(2)),
                      tr.date,
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
                              fontSize: 13,
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
