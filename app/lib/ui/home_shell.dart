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
    final t = ref.watch(l10nProvider);
    final lang = ref.watch(langProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.appTitle),
        actions: [
          // 语言切换：按钮显示将要切去的语言
          TextButton(
            key: const Key('langToggle'),
            onPressed: () =>
                ref.read(repoProvider).setLang(lang == 'zh' ? 'en' : 'zh'),
            child: Text(lang == 'zh' ? 'EN' : '中',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            key: const Key('refreshQuotes'),
            icon: const Icon(Icons.refresh),
            tooltip: t.refreshQuotes,
            onPressed: () async {
              await ref.read(repoProvider).enqueueQuotesRefresh();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.quoteRefreshRequested)));
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
        destinations: [
          NavigationDestination(icon: const Icon(Icons.today), label: t.tabToday),
          NavigationDestination(icon: const Icon(Icons.star_outline), label: t.tabWatch),
          NavigationDestination(
              icon: const Icon(Icons.pie_chart_outline), label: t.tabPortfolio),
          NavigationDestination(
              icon: const Icon(Icons.chat_bubble_outline), label: t.tabChat),
          NavigationDestination(icon: const Icon(Icons.history), label: t.tabHistory),
        ],
      ),
    );
  }
}
