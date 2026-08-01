import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/repo.dart';

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);
final repoProvider = Provider<WealthRepo>((ref) => WealthRepo(ref.watch(firestoreProvider)));
final authStateProvider = StreamProvider<User?>((ref) => ref.watch(firebaseAuthProvider).authStateChanges());
