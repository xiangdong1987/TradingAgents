import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/repo.dart';
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
