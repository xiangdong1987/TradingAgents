// app/lib/ui/widgets/pnl.dart
/// Shared Apple-Stocks-style pnl presentation: color/label rules plus the
/// [PnlPill] and [MoneyText] widgets. Every +/- percentage or money display
/// in the app routes through here so formatting stays consistent.
library;

import 'package:flutter/material.dart';

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

/// Bold tabular-figure money text: `value.toStringAsFixed(2)`.
class MoneyText extends StatelessWidget {
  const MoneyText(this.value, {super.key, this.size = 17.0, this.weight = FontWeight.w700, this.color});

  final double value;
  final double size;
  final FontWeight weight;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      value.toStringAsFixed(2),
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
