import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

class StreamError extends ConsumerWidget {
  const StreamError({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.loadFailed(error), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: onRetry, child: Text(t.retry)),
      ]),
    );
  }
}
