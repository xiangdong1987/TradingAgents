import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';

String utcNowIso() =>
    DateTime.now().toUtc().toIso8601String().replaceFirst('Z', '+00:00');

/// Read-side repository over Firestore. Write operations land in plan 3.
///
/// Note: `pendingSuggestions()` uses a composite index on (status, createdAt).
/// When the method is first called on real Firestore, if the index doesn't exist,
/// the console will show an error link to auto-create it. The test suite uses
/// fake_cloud_firestore which does not require indexes.
class WealthRepo {
  WealthRepo(this._db);
  final FirebaseFirestore _db;

  Stream<Brief?> latestBrief() => _db
      .collection('briefs')
      .orderBy(FieldPath.documentId, descending: true)
      .limit(1)
      .snapshots()
      .map((q) => q.docs.isEmpty ? null : Brief.fromDoc(q.docs.first.id, q.docs.first.data()));

  Stream<List<Suggestion>> pendingSuggestions() => _db
      .collection('suggestions')
      .where('status', isEqualTo: 'pending')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((q) => [for (final d in q.docs) Suggestion.fromDoc(d.id, d.data())]);

  Stream<List<WatchItem>> watchlist() => _db
      .collection('watchlist')
      .orderBy('ticker')
      .snapshots()
      .map((q) => [for (final d in q.docs) WatchItem.fromDoc(d.id, d.data())]);

  Stream<List<Position>> positions() => _db
      .collection('positions')
      .orderBy('ticker')
      .snapshots()
      .map((q) => [for (final d in q.docs) Position.fromDoc(d.id, d.data())]);

  Stream<PortfolioMeta> portfolioMeta() => _db
      .collection('meta')
      .doc('portfolio')
      .snapshots()
      .map((s) => PortfolioMeta.fromMap(s.data()));

  Stream<List<Job>> activeJobs() => _db
      .collection('jobs')
      .where('status', whereIn: ['queued', 'running'])
      .snapshots()
      .map((q) => [for (final d in q.docs) Job.fromDoc(d.id, d.data())]);

  // --- writes (plan 3) ---
  Future<void> resolveSuggestion(String id, {required bool accepted}) =>
      _db.collection('suggestions').doc(id).update({
        'status': accepted ? 'accepted' : 'dismissed',
        'resolvedAt': utcNowIso(),
      });

  Future<void> addTrade({
    required String ticker, required String side, required double shares,
    required double price, required String date, String? suggestionId,
  }) async {
    final data = {
      'ticker': ticker, 'side': side, 'shares': shares, 'price': price,
      'date': date,
    };
    if (suggestionId case var s?) {
      data['suggestionId'] = s;
    }
    await _db.collection('trades').add(data);
  }

  /// Records a trade and marks its originating suggestion accepted atomically:
  /// either both writes land or neither does (avoids a trade doc with no
  /// matching accepted suggestion if the app crashes mid-write).
  Future<void> acceptWithTrade({
    required String suggestionId, required String ticker, required String side,
    required double shares, required double price, required String date,
  }) async {
    final batch = _db.batch();
    batch.set(_db.collection('trades').doc(), {
      'ticker': ticker, 'side': side, 'shares': shares, 'price': price,
      'date': date, 'suggestionId': suggestionId,
    });
    batch.update(_db.collection('suggestions').doc(suggestionId), {
      'status': 'accepted', 'resolvedAt': utcNowIso(),
    });
    await batch.commit();
  }

  Future<void> setPosition({
    required String ticker, required double shares, required double avgCost,
  }) async {
    await _db.collection('positions').doc(ticker).set({
      'ticker': ticker, 'shares': shares, 'avgCost': avgCost,
      'updatedAt': utcNowIso(),
    });
    // 持仓自动加入自选（已在自选里则不动，保留其 deepFreq 设置）。
    final watch = await _db.collection('watchlist').doc(ticker).get();
    if (!watch.exists) await addWatch(ticker);
  }

  Future<void> deletePosition(String ticker) =>
      _db.collection('positions').doc(ticker).delete();

  Future<void> setCash(double cash, {String currency = 'EUR'}) => _db
      .collection('meta')
      .doc('portfolio')
      .set({'cash': cash, 'currency': currency}, SetOptions(merge: true));

  Future<void> addWatch(String ticker, {String deepFreq = 'manual'}) =>
      _db.collection('watchlist').doc(ticker).set({
        'ticker': ticker, 'note': '', 'deepFreq': deepFreq,
        'addedAt': utcNowIso(),
      });

  Future<void> removeWatch(String ticker) =>
      _db.collection('watchlist').doc(ticker).delete();

  Future<void> setDeepFreq(String ticker, String deepFreq) =>
      _db.collection('watchlist').doc(ticker).update({'deepFreq': deepFreq});



  /// 最近的问答（新到旧）。
  Stream<List<ChatMessage>> chats({int limit = 10}) => _db
      .collection('chats')
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((q) => [for (final d in q.docs) ChatMessage.fromDoc(d.id, d.data())]);

  /// 提问：chats 文档 + chat job 原子入队，runner 结合持仓生成回答。
  Future<String> askQuestion(String question) async {
    final chatRef = _db.collection('chats').doc();
    final batch = _db.batch();
    batch.set(chatRef, {
      'question': question, 'status': 'pending', 'createdAt': utcNowIso(),
    });
    batch.set(_db.collection('jobs').doc(), {
      'type': 'chat', 'chatId': chatRef.id, 'status': 'queued',
      'requestedBy': 'user', 'createdAt': utcNowIso(),
    });
    await batch.commit();
    return chatRef.id;
  }


  /// runner 心跳（meta/runner）：App 据此显示在线/离线。
  Stream<RunnerStatus> runnerStatus() => _db
      .collection('meta')
      .doc('runner')
      .snapshots()
      .map((s) => RunnerStatus.fromMap(s.data()));

  /// meta/calendar 里的财报/分红日程（runner 每日刷新）。
  Stream<List<CalendarEvent>> calendarEvents() => _db
      .collection('meta')
      .doc('calendar')
      .snapshots()
      .map((s) => [
            for (final e in (s.data()?['events'] as List? ?? const []))
              CalendarEvent.fromMap(Map<String, dynamic>.from(e as Map)),
          ]);

  /// 请求 runner 强制刷新全部行情（写一条 refresh_quotes job）。
  Future<String> enqueueQuotesRefresh() async {
    final ref = await _db.collection('jobs').add({
      'type': 'refresh_quotes', 'status': 'queued',
      'requestedBy': 'user', 'createdAt': utcNowIso(),
    });
    return ref.id;
  }

  /// 手动触发一次策略扫描（写一条 strategy_scan job，runner 消费）。
  /// 点名的策略无视 meta/strategies 的 enabled 配置。
  Future<String> enqueueStrategyScan({String strategy = 'turtle', String? scope}) async {
    final data = <String, dynamic>{
      'type': 'strategy_scan', 'strategy': strategy, 'status': 'queued',
      'requestedBy': 'user', 'createdAt': utcNowIso(),
    };
    if (scope != null) data['scope'] = scope;
    final ref = await _db.collection('jobs').add(data);
    return ref.id;
  }

  Future<String> enqueueDeepAnalysis(String ticker) async {
    final ref = await _db.collection('jobs').add({
      'type': 'deep_analysis', 'ticker': ticker, 'status': 'queued',
      'requestedBy': 'user', 'createdAt': utcNowIso(),
    });
    return ref.id;
  }

  // --- reads (plan 3) ---
  Stream<List<Analysis>> analysesForTicker(String ticker) => _db
      .collection('analyses')
      .where('ticker', isEqualTo: ticker)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((q) => [for (final d in q.docs) Analysis.fromDoc(d.id, d.data())]);

  Stream<List<Analysis>> recentAnalyses({int limit = 50}) => _db
      .collection('analyses')
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((q) => [for (final d in q.docs) Analysis.fromDoc(d.id, d.data())]);

  Stream<List<Suggestion>> allSuggestions({int limit = 100}) => _db
      .collection('suggestions')
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((q) => [for (final d in q.docs) Suggestion.fromDoc(d.id, d.data())]);
}
