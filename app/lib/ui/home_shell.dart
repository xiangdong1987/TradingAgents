import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'chat_page.dart';
import 'history_tab.dart';
import 'portfolio_tab.dart';
import 'today_tab.dart';
import 'watch_tab.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  final _tabs = const [
    TodayTab(),
    WatchTab(),
    PortfolioTab(),
    ChatPage(),
    HistoryTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('理财助手'),
        actions: [
          IconButton(
            key: const Key('refreshQuotes'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新行情',
            onPressed: () async {
              await ref.read(repoProvider).enqueueQuotesRefresh();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('已请求刷新行情，处理完成后自动更新')));
              }
            },
          ),
          IconButton(
            key: const Key('logoutButton'),
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(firebaseAuthProvider).signOut(),
          ),
        ],
      ),
      body: _tabs[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.star_outline), label: '自选'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: '持仓'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: '问答'),
          NavigationDestination(icon: Icon(Icons.history), label: '历史'),
        ],
      ),
    );
  }
}
