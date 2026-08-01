import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Markdown 渲染 import 按 Task 1 选定的包调整：
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/models.dart';
import '../providers.dart';
import 'widgets/suggestion_card.dart';

final latestBriefProvider = StreamProvider<Brief?>((ref) => ref.watch(repoProvider).latestBrief());
final pendingSuggestionsProvider =
    StreamProvider<List<Suggestion>>((ref) => ref.watch(repoProvider).pendingSuggestions());
final activeJobsProvider = StreamProvider<List<Job>>((ref) => ref.watch(repoProvider).activeJobs());

class TodayTab extends ConsumerWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brief = ref.watch(latestBriefProvider);
    final suggestions = ref.watch(pendingSuggestionsProvider);
    final jobs = ref.watch(activeJobsProvider);

    return ListView(
      children: [
        for (final job in jobs.value ?? const <Job>[])
          MaterialBanner(
            content: Text(job.type == 'deep_analysis'
                ? '${job.ticker} 深度分析中（${job.status == "queued" ? "排队" : "分析中"}）'
                : '日报生成中'),
            // 用静态图标而非不确定态 CircularProgressIndicator：后者的 ticker 永不停止，
            // 会导致 job 处于 running 状态时 widget 测试里的 pumpAndSettle 永远等不到静止而超时。
            leading: const Icon(Icons.sync, size: 20),
            actions: const [SizedBox.shrink()],
          ),
        brief.when(
          data: (b) => b == null
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('还没有日报。runner 会在交易日收盘后生成第一份。',
                      textAlign: TextAlign.center),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.date, style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      MarkdownBody(data: b.markdownZh),
                    ],
                  ),
                ),
          loading: () => const Padding(
              padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('日报加载失败: $e')),
        ),
        ...switch (suggestions) {
          AsyncData(:final value) when value.isNotEmpty => [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('待处理建议', style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final s in value) SuggestionCard(suggestion: s),
            ],
          _ => const <Widget>[],
        },
        const SizedBox(height: 24),
      ],
    );
  }
}
