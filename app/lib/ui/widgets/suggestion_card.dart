import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n.dart';
import '../../models/models.dart';
import '../../providers.dart';
import 'pnl.dart' show currencyPrefix, formatShares, pnlColor;

/// 卡片上一行事实 chip：目标仓位 / 建议股数 / 止损价。
List<String> _facts(L10n t, Suggestion s) => [
      if (s.targetWeightPct != null)
        t.targetWeight(s.targetWeightPct!.toStringAsFixed(1)),
      // 被拦住时不显示股数——避免照着一个不该执行的数字下单
      if (!s.isBlocked && s.shares != null)
        t.suggestShares(formatShares(s.shares!)),
      if (s.stop != null)
        t.stopAt('${currencyPrefix(s.ticker)}${s.stop!.toStringAsFixed(2)}'),
    ];

/// blocked / clamped 的醒目条：说明哪道闸、被钳前后多少、腾挪候选。
class _PolicyBanner extends ConsumerWidget {
  const _PolicyBanner({required this.suggestion});
  final Suggestion suggestion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final s = suggestion;
    final blocked = s.isBlocked;
    final color = blocked ? pnlColor(-1) : const Color(0xFFFF9F0A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(blocked ? Icons.block : Icons.compress, size: 14, color: color),
              const SizedBox(width: 6),
              Text(blocked ? t.blockedBadge : t.clampedBadge,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: color)),
              if (!blocked && s.clampedFrom != null) ...[
                const SizedBox(width: 6),
                Text('${formatShares(s.clampedFrom!)} → ${formatShares(s.shares ?? 0)}',
                    style: TextStyle(fontSize: 12, color: color)),
              ],
            ],
          ),
          if (blocked && s.fundingCandidates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(t.fundingHint(s.fundingCandidates.join('、')),
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class SuggestionCard extends ConsumerWidget {
  const SuggestionCard({super.key, required this.suggestion, this.onAccept, this.onDismiss});
  final Suggestion suggestion;
  final VoidCallback? onAccept;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final s = suggestion;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${s.ticker} · ${s.action.toUpperCase()}',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (s.sourceLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    // 已知策略映射到 l10n 展示名，未知策略直接显示原始 source。
                    child: Text(s.source == 'turtle' ? t.turtleSource : s.sourceLabel!,
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            // 执行细节与 Policy 判定：股数/止损/目标仓位挤在一行 chip 里
            if (_facts(t, s).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    for (final f in _facts(t, s))
                      Text(f, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            if (s.isBlocked || s.clampedBy != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _PolicyBanner(suggestion: s),
              ),
            const SizedBox(height: 8),
            Text(s.rationaleFor(ref.watch(langProvider))),
            const SizedBox(height: 8),
            Row(
              children: [
                // 被拦住时采纳按钮降级为次要样式并改文案——不禁用（最终决定权在你）
                if (s.isBlocked)
                  OutlinedButton(onPressed: onAccept, child: Text(t.acceptAnyway))
                else
                  FilledButton(onPressed: onAccept, child: Text(t.accept)),
                const SizedBox(width: 8),
                TextButton(onPressed: onDismiss, child: Text(t.dismiss)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
