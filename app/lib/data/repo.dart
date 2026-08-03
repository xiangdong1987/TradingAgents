import 'package:cloud_firestore/cloud_firestore.dart';

import '../logic/tax.dart';
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

  /// 最近的成交流水（新到旧）。
  Stream<List<Trade>> trades({int limit = 200}) => _db
      .collection('trades')
      .orderBy('date', descending: true)
      .limit(limit)
      .snapshots()
      .map((q) => [for (final d in q.docs) Trade.fromDoc(d.id, d.data())]);

  /// 分红 / 利息流水（新到旧）。
  Stream<List<Income>> income({int limit = 200}) => _db
      .collection('income')
      .orderBy('date', descending: true)
      .limit(limit)
      .snapshots()
      .map((q) => [for (final d in q.docs) Income.fromDoc(d.id, d.data())]);

  /// 手工补录分红/利息（ISIN 单券付息只能走这条：Yahoo 没有单券数据）。
  /// 默认同时加进现金——手录代表钱已到账，是用户主动的记账动作；
  /// runner 自动抓的那批不动现金，避免与券商对账重复计入。
  Future<void> addIncome({
    required String ticker, required double amount, required String date,
    double? taxAmount, String? note, bool creditCash = true,
  }) async {
    final tax = taxAmount ?? amount * defaultIncomeTaxPct(ticker) / 100;
    final batch = _db.batch();
    batch.set(_db.collection('income').doc(), {
      'ticker': ticker, 'amount': amount, 'taxAmount': tax, 'date': date,
      'source': 'manual', 'creditedCash': creditCash,
      if (note != null && note.isNotEmpty) 'note': note,
      'createdAt': utcNowIso(),
    });
    if (creditCash) {
      final meta = await _db.collection('meta').doc('portfolio').get();
      final cash = (meta.data()?['cash'] as num?)?.toDouble() ?? 0.0;
      batch.set(_db.collection('meta').doc('portfolio'),
          {'cash': cash + amount}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  /// 记一笔成交并**同步更新持仓与现金**（一次 WriteBatch，要么全成要么全不成）。
  ///
  /// - 买入：股数累加、成本价按加权平均重算、现金扣减成交额；
  /// - 卖出：股数递减（清零则删除持仓文档）、成本价不变、现金加回成交额，
  ///   并按卖出当时的成本价记下这笔的已实现盈亏（标的原币）。
  ///
  /// 卖出股数超过持仓时按持仓全额处理（避免负股数）。`suggestionId` 非空时
  /// 顺带把那条建议标记为已采纳。
  Future<void> applyTrade({
    required String ticker, required String side, required double shares,
    required double price, required String date, String? suggestionId,
  }) async {
    final posRef = _db.collection('positions').doc(ticker);
    final snap = await posRef.get();
    final held = snap.exists ? (snap.data()?['shares'] as num?)?.toDouble() ?? 0.0 : 0.0;
    final avgCost = snap.exists ? (snap.data()?['avgCost'] as num?)?.toDouble() ?? 0.0 : 0.0;

    final isSell = side == 'sell';
    final qty = isSell ? (shares > held ? held : shares) : shares;
    if (qty <= 0) return;

    final meta = await _db.collection('meta').doc('portfolio').get();
    final cash = (meta.data()?['cash'] as num?)?.toDouble() ?? 0.0;
    final amount = qty * price;

    final batch = _db.batch();
    final trade = <String, dynamic>{
      'ticker': ticker, 'side': side, 'shares': qty, 'price': price,
      'date': date, 'createdAt': utcNowIso(),
    };
    if (suggestionId != null) trade['suggestionId'] = suggestionId;

    if (isSell) {
      final pnl = (price - avgCost) * qty;
      trade['realizedPnl'] = pnl;
      trade['taxAmount'] = defaultSellTax(pnl);   // 盈利按 26% 计，亏损为 0
      trade['avgCostAtTrade'] = avgCost;
      final left = held - qty;
      if (left <= 0) {
        batch.delete(posRef);
      } else {
        batch.set(posRef, {
          'ticker': ticker, 'shares': left, 'avgCost': avgCost,
          'updatedAt': utcNowIso(),
        }, SetOptions(merge: true));
      }
    } else {
      final newShares = held + qty;
      // 加权平均成本：老持仓成本额 + 本次成交额，摊到新股数上
      final newAvg = (held * avgCost + amount) / newShares;
      batch.set(posRef, {
        'ticker': ticker, 'shares': newShares, 'avgCost': newAvg,
        'updatedAt': utcNowIso(),
      }, SetOptions(merge: true));
    }

    batch.set(_db.collection('trades').doc(), trade);
    batch.set(_db.collection('meta').doc('portfolio'),
        {'cash': isSell ? cash + amount : cash - amount}, SetOptions(merge: true));
    if (suggestionId != null) {
      batch.update(_db.collection('suggestions').doc(suggestionId),
          {'status': 'accepted', 'resolvedAt': utcNowIso()});
    }
    await batch.commit();

    // 买入的新标的顺带进自选（与 setPosition 同一习惯）。
    if (!isSell) {
      final watch = await _db.collection('watchlist').doc(ticker).get();
      if (!watch.exists) await addWatch(ticker);
    }
  }

  Future<void> setPosition({
    required String ticker, required double shares, required double avgCost,
    String? openedAt,
  }) async {
    // merge 写：别把 runner/其他字段（如 openedAt）冲掉
    await _db.collection('positions').doc(ticker).set({
      'ticker': ticker, 'shares': shares, 'avgCost': avgCost,
      if (openedAt != null && openedAt.isNotEmpty) 'openedAt': openedAt,
      'updatedAt': utcNowIso(),
    }, SetOptions(merge: true));
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


  /// meta/settings（当前只有 lang: zh|en），三端实时同步。
  Stream<Map<String, dynamic>> settings() => _db
      .collection('meta')
      .doc('settings')
      .snapshots()
      .map((s) => s.data() ?? const {});

  Future<void> setLang(String lang) => _db
      .collection('meta')
      .doc('settings')
      .set({'lang': lang}, SetOptions(merge: true));

  /// 按需翻译深度分析的某些段落（写一条 translate job，runner 消费后
  /// 增量写回 analyses/{id}.sectionsZh，Firestore 流自动刷新 UI）。
  Future<String> enqueueTranslate(String analysisId, List<String> sections) async {
    final ref = await _db.collection('jobs').add({
      'type': 'translate', 'analysisId': analysisId, 'sections': sections,
      'status': 'queued', 'requestedBy': 'user', 'createdAt': utcNowIso(),
    });
    return ref.id;
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

  // --- 流水的编辑与删除 -------------------------------------------------
  //
  // 改一笔历史成交要把它对持仓和现金的影响一起改掉，否则统计就和记录脱节。
  // 做法是「按差额回滚」：先算出这笔原来做了什么，再算新的该做什么，只写差。
  // 股数与现金是精确可逆的；**成本价的加权平均只有在这笔是最近一次买入时才
  // 精确可逆**，中间夹了别的买入时是近似——所以删改久远的买入后，成本价建议
  // 自己核一下（编辑持仓可以直接改）。

  /// 删除一笔成交，并把它对持仓/现金的影响撤回。
  Future<void> deleteTrade(String id) async {
    final snap = await _db.collection('trades').doc(id).get();
    final d = snap.data();
    if (d == null) return;
    await _reverseTrade(d);
    await _db.collection('trades').doc(id).delete();
  }

  /// 改一笔成交：先撤回旧影响，再按新值重记（同一标的、同方向）。
  Future<void> updateTrade(String id, {
    required double shares, required double price, required String date,
  }) async {
    final snap = await _db.collection('trades').doc(id).get();
    final d = snap.data();
    if (d == null || shares <= 0 || price <= 0) return;
    final ticker = (d['ticker'] as String?) ?? '';
    final side = (d['side'] as String?) ?? 'buy';
    await _reverseTrade(d);
    await _db.collection('trades').doc(id).delete();
    await applyTrade(ticker: ticker, side: side, shares: shares,
        price: price, date: date,
        suggestionId: d['suggestionId'] as String?);
  }

  /// 撤回一笔成交对持仓与现金的影响（不删 trade 文档本身）。
  Future<void> _reverseTrade(Map<String, dynamic> d) async {
    final ticker = (d['ticker'] as String?) ?? '';
    if (ticker.isEmpty) return;
    final qty = (d['shares'] as num?)?.toDouble() ?? 0;
    final price = (d['price'] as num?)?.toDouble() ?? 0;
    final isSell = d['side'] == 'sell';
    final amount = qty * price;

    final posRef = _db.collection('positions').doc(ticker);
    final posSnap = await posRef.get();
    final held = (posSnap.data()?['shares'] as num?)?.toDouble() ?? 0;
    final avgCost = (posSnap.data()?['avgCost'] as num?)?.toDouble() ?? 0;
    final meta = await _db.collection('meta').doc('portfolio').get();
    final cash = (meta.data()?['cash'] as num?)?.toDouble() ?? 0;

    final batch = _db.batch();
    if (isSell) {
      // 撤回卖出：股数加回、现金扣回，成本价用当时记下的那个
      final restoredAvg = (d['avgCostAtTrade'] as num?)?.toDouble() ??
          (avgCost > 0 ? avgCost : price);
      batch.set(posRef, {
        'ticker': ticker, 'shares': held + qty, 'avgCost': restoredAvg,
        'updatedAt': utcNowIso(),
      }, SetOptions(merge: true));
      batch.set(_db.collection('meta').doc('portfolio'),
          {'cash': cash - amount}, SetOptions(merge: true));
    } else {
      // 撤回买入：股数减回、现金加回，成本价按加权平均反解
      final left = held - qty;
      if (left <= 0) {
        batch.delete(posRef);
      } else {
        final restoredAvg = (held * avgCost - amount) / left;
        batch.set(posRef, {
          'ticker': ticker, 'shares': left,
          'avgCost': restoredAvg > 0 ? restoredAvg : avgCost,
          'updatedAt': utcNowIso(),
        }, SetOptions(merge: true));
      }
      batch.set(_db.collection('meta').doc('portfolio'),
          {'cash': cash + amount}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  /// 改一笔分红/利息。只有当初计入过现金的记录才按差额调整现金。
  Future<void> updateIncome(String id, {
    required double amount, required double taxAmount, required String date,
    String? note,
  }) async {
    final ref = _db.collection('income').doc(id);
    final snap = await ref.get();
    final d = snap.data();
    if (d == null) return;
    final oldAmount = (d['amount'] as num?)?.toDouble() ?? 0;
    final credited = d['creditedCash'] == true;

    final batch = _db.batch();
    batch.set(ref, {
      'amount': amount, 'taxAmount': taxAmount, 'date': date,
      'note': note ?? '', 'updatedAt': utcNowIso(),
    }, SetOptions(merge: true));
    if (credited && amount != oldAmount) {
      final meta = await _db.collection('meta').doc('portfolio').get();
      final cash = (meta.data()?['cash'] as num?)?.toDouble() ?? 0;
      batch.set(_db.collection('meta').doc('portfolio'),
          {'cash': cash + (amount - oldAmount)}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  /// 删除一笔分红/利息；当初计入过现金的话把钱扣回去。
  Future<void> deleteIncome(String id) async {
    final ref = _db.collection('income').doc(id);
    final snap = await ref.get();
    final d = snap.data();
    if (d == null) return;
    final batch = _db.batch();
    if (d['creditedCash'] == true) {
      final amount = (d['amount'] as num?)?.toDouble() ?? 0;
      final meta = await _db.collection('meta').doc('portfolio').get();
      final cash = (meta.data()?['cash'] as num?)?.toDouble() ?? 0;
      batch.set(_db.collection('meta').doc('portfolio'),
          {'cash': cash - amount}, SetOptions(merge: true));
    }
    batch.delete(ref);
    await batch.commit();
  }
}
