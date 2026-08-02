// app/lib/ui/chat_page.dart
/// IM 式问答页：提问结合当前持仓由 runner 回答（chat job 队列）。
/// 新消息在底部，输入框钉在底部；回答实时推送。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../models/models.dart';
import '../providers.dart';
import 'widgets/pnl.dart' show pnlColor;

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _q = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _q.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(repoProvider).askQuestion(text);
      _q.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    final lang = ref.watch(langProvider);
    final chats = ref.watch(chatsProvider).value ?? const <ChatMessage>[];
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;

    return Column(
      children: [
        Expanded(
          child: chats.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      t.chatEmptyHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: grey),
                    ),
                  ),
                )
              // chatsProvider 按 createdAt 降序 → reverse 列表天然新消息在底部
              : SelectionArea(
                  child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: chats.length,
                  itemBuilder: (context, i) {
                    final c = chats[i];
                    return Column(
                      children: [
                        _Bubble.right(copyText: c.question, child: Text(c.question)),
                        switch (c.status) {
                          'answered' => _Bubble.left(
                              copyText: c.answerFor(lang),
                              child: MarkdownBody(
                                  data: c.answerFor(lang) ?? '',
                                  styleSheet: _chatMarkdown(context))),
                          'failed' => _Bubble.left(
                              child: Text(t.chatFailed,
                                  style: TextStyle(color: pnlColor(-1)))),
                          _ => _Bubble.left(
                              child: Text(t.analyzingEllipsis,
                                  style: TextStyle(color: grey))),
                        },
                      ],
                    );
                  },
                ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('askField'),
                    controller: _q,
                    decoration: InputDecoration(
                      hintText: t.chatInputHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  key: const Key('askSend'),
                  icon: const Icon(Icons.send),
                  onPressed: _sending ? null : _send,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 气泡内 Markdown 紧凑样式：标题降为正文级加粗，分隔线细化，间距收紧。
MarkdownStyleSheet _chatMarkdown(BuildContext context) {
  final theme = Theme.of(context);
  final body = theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
  TextStyle h(double size) =>
      body.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.4);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body.copyWith(height: 1.5),
    h1: h(17),
    h2: h(16),
    h3: h(15),
    h4: h(14),
    h5: h(14),
    h6: h(14),
    listBullet: body,
    blockSpacing: 8,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5)),
    ),
  );
}

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.child, required this.alignRight, this.copyText});

  const _Bubble.right({required Widget child, String? copyText})
      : this(child: child, alignRight: true, copyText: copyText);
  const _Bubble.left({required Widget child, String? copyText})
      : this(child: child, alignRight: false, copyText: copyText);

  final Widget child;
  final bool alignRight;
  final String? copyText;

  Future<void> _copy(BuildContext context, L10n t) async {
    final text = copyText;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.copied)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _copy(context, t),
        child: Container(
          // 宽屏（web/桌面）上限 640，避免整行铺开难以阅读
          constraints: BoxConstraints(
              maxWidth:
                  math.min(MediaQuery.of(context).size.width * 0.82, 640)),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color:
                alignRight ? scheme.primaryContainer : const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(alignRight ? 14 : 4),
              bottomRight: Radius.circular(alignRight ? 4 : 14),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
