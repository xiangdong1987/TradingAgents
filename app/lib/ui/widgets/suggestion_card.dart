import 'package:flutter/material.dart';

import '../../models/models.dart';

class SuggestionCard extends StatelessWidget {
  const SuggestionCard({super.key, required this.suggestion, this.onAccept, this.onDismiss});
  final Suggestion suggestion;
  final VoidCallback? onAccept;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
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
                    child: Text(s.sourceLabel!, style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            if (s.targetWeightPct != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('目标仓位 ${s.targetWeightPct!.toStringAsFixed(1)}%'),
              ),
            const SizedBox(height: 8),
            Text(s.rationale),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(onPressed: onAccept, child: const Text('采纳')),
                const SizedBox(width: 8),
                TextButton(onPressed: onDismiss, child: const Text('忽略')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
