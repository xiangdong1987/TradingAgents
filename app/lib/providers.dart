import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/repo.dart';
import 'l10n.dart';
import 'models/models.dart';

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);
final repoProvider = Provider<WealthRepo>((ref) => WealthRepo(ref.watch(firestoreProvider)));
final authStateProvider = StreamProvider<User?>((ref) => ref.watch(firebaseAuthProvider).authStateChanges());

final latestBriefProvider = StreamProvider<Brief?>((ref) => ref.watch(repoProvider).latestBrief());
final pendingSuggestionsProvider =
    StreamProvider<List<Suggestion>>((ref) => ref.watch(repoProvider).pendingSuggestions());
final activeJobsProvider = StreamProvider<List<Job>>((ref) => ref.watch(repoProvider).activeJobs());
final watchlistProvider = StreamProvider<List<WatchItem>>((ref) => ref.watch(repoProvider).watchlist());
final positionsProvider = StreamProvider<List<Position>>((ref) => ref.watch(repoProvider).positions());
final portfolioMetaProvider =
    StreamProvider<PortfolioMeta>((ref) => ref.watch(repoProvider).portfolioMeta());
final tradesProvider = StreamProvider<List<Trade>>((ref) => ref.watch(repoProvider).trades());
final calendarEventsProvider =
    StreamProvider<List<CalendarEvent>>((ref) => ref.watch(repoProvider).calendarEvents());
final chatsProvider =
    StreamProvider<List<ChatMessage>>((ref) => ref.watch(repoProvider).chats());
final runnerStatusProvider =
    StreamProvider<RunnerStatus>((ref) => ref.watch(repoProvider).runnerStatus());

final settingsProvider =
    StreamProvider<Map<String, dynamic>>((ref) => ref.watch(repoProvider).settings());

/// 当前语言：meta/settings.lang，未设置缺省中文（单用户，母语中文）。
final langProvider = Provider<String>((ref) {
  final lang = ref.watch(settingsProvider).value?['lang'];
  return lang == 'en' ? 'en' : 'zh';
});

final l10nProvider =
    Provider<L10n>((ref) => ref.watch(langProvider) == 'en' ? l10nEn : l10nZh);

