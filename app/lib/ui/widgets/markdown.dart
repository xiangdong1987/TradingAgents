// app/lib/ui/widgets/markdown.dart
/// LLM 生成内容（日报 / 问答回答）的共用紧凑 Markdown 样式。
///
/// 模型爱用 `#`/`##` 当小节标题，默认样式表把它们渲染成巨大的 H1/H2，在
/// 手机窄屏里标题比正文还抢眼、段距也过松。这里把标题压到正文级加粗、
/// 收紧行距与段距、分隔线改细线，让长报告读起来像一篇排好版的文章。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

MarkdownStyleSheet compactMarkdown(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final body = theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
  // 标题按层级递减，但都停在正文附近，最大不过 17sp。
  TextStyle h(double size) =>
      body.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.35);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body.copyWith(height: 1.5),
    h1: h(17),
    h2: h(16),
    h3: h(15),
    h4: h(14),
    h5: h(14),
    h6: h(14),
    h1Padding: const EdgeInsets.only(top: 8),
    h2Padding: const EdgeInsets.only(top: 8),
    h3Padding: const EdgeInsets.only(top: 6),
    listBullet: body,
    listIndent: 18,
    blockSpacing: 8,
    strong: body.copyWith(fontWeight: FontWeight.w700),
    code: body.copyWith(
        fontFamily: 'monospace', fontSize: 13, backgroundColor: Colors.transparent),
    blockquoteDecoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(6),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
    ),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    tableBorder: TableBorder.all(color: scheme.outlineVariant, width: 0.5),
  );
}
