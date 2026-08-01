// app/lib/ui/chat_page.dart
/// IM 式问答页：提问结合当前持仓由 runner 回答（chat job 队列）。
/// 新消息在底部，输入框钉在底部；回答实时推送。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
                      '问点什么吧——回答会结合你的实时持仓、现金与最近的深度分析结论。\n\n例：可口可乐和 Intesa 哪个更适合买入？',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: grey),
                    ),
                  ),
                )
              // chatsProvider 按 createdAt 降序 → reverse 列表天然新消息在底部
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: chats.length,
                  itemBuilder: (context, i) {
                    final c = chats[i];
                    return Column(
                      children: [
                        _Bubble.right(child: Text(c.question)),
                        switch (c.status) {
                          'answered' =>
                            _Bubble.left(child: MarkdownBody(data: c.answer ?? '')),
                          'failed' => _Bubble.left(
                              child: Text('回答失败，请重新提问',
                                  style: TextStyle(color: pnlColor(-1)))),
                          _ => _Bubble.left(
                              child: Text('分析中…', style: TextStyle(color: grey))),
                        },
                      ],
                    );
                  },
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
                    decoration: const InputDecoration(
                      hintText: '结合持仓问点什么…',
                      border: OutlineInputBorder(),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.child, required this.alignRight});

  const _Bubble.right({required Widget child})
      : this(child: child, alignRight: true);
  const _Bubble.left({required Widget child})
      : this(child: child, alignRight: false);

  final Widget child;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: alignRight ? scheme.primaryContainer : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(alignRight ? 14 : 4),
            bottomRight: Radius.circular(alignRight ? 4 : 14),
          ),
        ),
        child: child,
      ),
    );
  }
}
