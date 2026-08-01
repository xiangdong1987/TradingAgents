import 'package:flutter/material.dart';

import 'stream_error.dart';

/// Shared `StreamBuilder<List<T>>` branching so loading/error states are
/// never mistaken for "no records": a missing composite index or a dropped
/// connection used to render the same empty-state text as a genuinely empty
/// collection, hiding failures indefinitely (see history_tab.dart findings).
///
/// - error -> [StreamError] with retry.
/// - waiting with no data yet -> spinner.
/// - empty list -> [emptyText].
/// - otherwise -> [itemBuilder].
class SnapshotList<T> extends StatelessWidget {
  const SnapshotList({
    super.key,
    required this.stream,
    required this.itemBuilder,
    required this.emptyText,
    required this.onRetry,
  });

  final Stream<List<T>> stream;
  final Widget Function(BuildContext context, List<T> items) itemBuilder;
  final String emptyText;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<T>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return StreamError(error: snapshot.error!, onRetry: onRetry);
        }
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data ?? const [];
        if (items.isEmpty) return Center(child: Text(emptyText));
        return itemBuilder(context, items);
      },
    );
  }
}
