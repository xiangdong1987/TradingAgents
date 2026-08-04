// app/lib/ui/widgets/pnl.dart
/// Shared Apple-Stocks-style pnl presentation: color/label rules plus the
/// [PnlPill] and [MoneyText] widgets. Every +/- percentage or money display
/// in the app routes through here so formatting stays consistent.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../logic/portfolio_math.dart' show isEurListing;

/// 千分位 + 固定两位小数：71390.03 → '71,390.03'。所有金额展示统一走这里。
final _money = NumberFormat('#,##0.00');
String formatMoney(double v) => _money.format(v);

/// 股数：整数不带小数点，带零头保留（1234 → '1,234'，10.5 → '10.5'）。
String formatShares(double v) =>
    v == v.roundToDouble() ? NumberFormat('#,##0').format(v) : v.toString();

/// iOS system green for gains, red for losses (>= 0 counts as a gain).
Color pnlColor(double v) => v >= 0 ? const Color(0xFF34C759) : const Color(0xFFFF3B30);

/// `+2.93%` / `-1.02%` / `+0.00%` — always signed, always 2 decimals.
String pnlLabel(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';

/// Solid rounded pnl pill: white bold tabular-figure text on a [pnlColor]
/// background. Non-compact is sized for list trailing widgets; `compact` is
/// the smaller variant used in history rows.
class PnlPill extends StatelessWidget {
  const PnlPill(this.pct, {super.key, this.compact = false});

  final double pct;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minWidth: compact ? 64 : 84),
      padding: EdgeInsets.symmetric(
        vertical: compact ? 3 : 6,
        horizontal: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: pnlColor(pct),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        pnlLabel(pct),
        textAlign: TextAlign.right,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: compact ? 12 : null,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// `$` for US listings, `€` for Borsa Italiana (`.MI`).
String currencyPrefix(String ticker) => isEurListing(ticker) ? '€' : '\$';

/// Right-aligned price-over-pill stack sized to fit a [ListTile.trailing]
/// slot (which caps children at ~48px): 15sp price + compact pill.
class PriceWithPill extends StatelessWidget {
  const PriceWithPill(
      {super.key, required this.price, required this.pct, this.prefix = ''});

  final double price;
  final double pct;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        MoneyText(price, size: 15, prefix: prefix),
        const SizedBox(height: 2),
        PnlPill(pct, compact: true),
      ],
    );
  }
}

/// Bold tabular-figure money text with thousands separators.
class MoneyText extends StatelessWidget {
  const MoneyText(this.value,
      {super.key, this.size = 17.0, this.weight = FontWeight.w700, this.color,
      this.prefix = ''});

  final double value;
  final double size;
  final FontWeight weight;
  final Color? color;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$prefix${formatMoney(value)}',
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
