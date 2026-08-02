import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../../providers.dart';

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
            if (s.targetWeightPct != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(t.targetWeight(s.targetWeightPct!.toStringAsFixed(1))),
              ),
            const SizedBox(height: 8),
            Text(s.rationaleFor(ref.watch(langProvider))),
            const SizedBox(height: 8),
            Row(
              children: [
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
