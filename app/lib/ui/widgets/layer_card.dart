// app/lib/ui/widgets/layer_card.dart
/// 仓位分层的展示件：[LayerCard]（各层实际占比 vs 目标区间 + 现金/美元敞口）
/// 与 [PositionSubtitle]（持仓行的股数·成本·权重·层·持有到期）。
/// 阈值与分层判定都来自 `logic/policy.dart`，这里只负责画。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/policy.dart';
import '../../models/models.dart';
import '../../providers.dart';
import 'pnl.dart';

/// 分层卡：每层一条「目标区间 + 实际占比」的横条，越界染红并标注原因。
/// 目标区间画成浅色底带，实际值是实心条 —— 一眼看出偏在哪边、偏多少。
class LayerCard extends ConsumerWidget {
  const LayerCard({super.key, required this.breakdown});
  final LayerBreakdown breakdown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final cfg = breakdown.config;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.layers, style: TextStyle(fontSize: 12, color: grey)),
            const SizedBox(height: 10),
            for (final l in breakdown.layers) ...[
              _LayerRow(stat: l),
              const SizedBox(height: 10),
            ],
            // 现金与美元敞口不是「层」，但同属纪律，附在下面一行
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _MiniFlag(
                  label: t.cash,
                  value: '${breakdown.cashPct.toStringAsFixed(1)}%',
                  hint: '≥ ${cfg.cashFloorPct.toStringAsFixed(0)}%',
                  bad: breakdown.cashBelowFloor,
                ),
                _MiniFlag(
                  label: t.usdExposure,
                  value: '${breakdown.usdPct.toStringAsFixed(1)}%',
                  hint: t.capLabel(cfg.maxUsdExposurePct.toStringAsFixed(0)),
                  bad: breakdown.usdOverCap,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一层：名称 + 占比 + 目标区间标签，下面一条带目标区间底带的进度条。
class _LayerRow extends ConsumerWidget {
  const _LayerRow({required this.stat});
  final LayerStat stat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    final grey = scheme.onSurfaceVariant;
    final bad = stat.breached;
    final color = bad ? pnlColor(-1) : pnlColor(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(t.layerName(stat.layer),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Text('${stat.pct.toStringAsFixed(1)}%',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: color)),
            const Spacer(),
            Text(
              [
                t.bandLabel(stat.band.lo.toStringAsFixed(0),
                    stat.band.hi.toStringAsFixed(0)),
                if (stat.overCap) t.overCapTag,
                if (stat.underFloor) t.underFloorTag,
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: bad ? color : grey),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 刻度到 100%：目标区间是浅底带，实际占比是实心条
        LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          double x(double pct) => (pct.clamp(0, 100)) / 100 * w;
          return SizedBox(
            height: 8,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Positioned(
                  left: x(stat.band.lo),
                  width: (x(stat.band.hi) - x(stat.band.lo)).clamp(2, w),
                  top: 0, bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: grey.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Positioned(
                  left: 0, top: 2, bottom: 2,
                  width: x(stat.pct).clamp(2, w),
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// 现金 / 美元敞口这类单值纪律的小标记。
class _MiniFlag extends StatelessWidget {
  const _MiniFlag({required this.label, required this.value,
      required this.hint, required this.bad});
  final String label;
  final String value;
  final String hint;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: TextStyle(fontSize: 12, color: grey)),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: bad ? pnlColor(-1) : null)),
        Text(' ($hint)', style: TextStyle(fontSize: 11, color: grey)),
      ],
    );
  }
}

/// 持仓行副标题：股数 · 成本 · 权重（超单票上限时染红）· 分层 · 持有到期。
class PositionSubtitle extends ConsumerWidget {
  const PositionSubtitle(
      {super.key, required this.position, required this.weightPct,
      required this.policy});
  final Position position;
  final double? weightPct;
  final PolicyConfig policy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final layer = policy.layerOf(position.ticker, position);
    final over = weightPct != null && weightPct! > policy.singleCapFor(layer);
    return Row(
      children: [
        Flexible(
          child: Text(
            t.positionSubtitle(position.shares.toStringAsFixed(0),
                position.avgCost.toStringAsFixed(2)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: grey),
          ),
        ),
        if (weightPct != null) ...[
          Text(' · ', style: TextStyle(color: grey)),
          Text('${weightPct!.toStringAsFixed(1)}%',
              style: TextStyle(
                  color: over ? pnlColor(-1) : grey,
                  fontWeight: over ? FontWeight.w700 : null)),
        ],
        Text(' · ${t.layerName(layer)}',
            style: TextStyle(color: grey, fontSize: 12)),
        if (policy.isHoldToMaturity(position.ticker, position))
          Text(' · ${t.holdToMaturity}',
              style: TextStyle(color: grey, fontSize: 12)),
      ],
    );
  }
}
