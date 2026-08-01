import 'package:flutter/material.dart';

import '../../models/models.dart';

class SuggestionCard extends StatelessWidget {
  const SuggestionCard({super.key, required this.suggestion});
  final Suggestion suggestion;

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
            Text('${s.ticker} · ${s.action.toUpperCase()}',
                style: Theme.of(context).textTheme.titleMedium),
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
                // 占位按钮：写路径在计划三接通
                Tooltip(
                  message: '计划三启用',
                  child: OutlinedButton(onPressed: null, child: const Text('采纳')),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: '计划三启用',
                  child: OutlinedButton(onPressed: null, child: const Text('忽略')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
