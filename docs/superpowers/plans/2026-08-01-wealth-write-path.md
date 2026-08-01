# 理财助手写路径与全 tab 实施计划（计划三）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 App 的全部写路径与剩余三个 tab：建议采纳/忽略（可选录成交）、自选管理 + 手动深度分析、持仓/现金编辑、历史归档与分析详情；启用 **Flutter Web** 目标供本地开发（`flutter run -d chrome`，不必开客户端）；日报文档增加结构化行情字段供自选/持仓 tab 显示。

**Architecture:** 沿用计划二的分层：models → WealthRepo → Riverpod providers → UI。写操作全部收敛在 `WealthRepo`（时间戳统一 `+00:00` 后缀 UTC ISO，与 Python 后端 `utc_now_iso()` 完全同格式）。行情展示不引实时行情源——复用每日 brief 新增的 `quotes` 字段（唯一的 Python 侧改动在 `assistant/daily_brief.py`）。

**Tech Stack:** 与计划二一致；无新增依赖。

**对应 spec:** `docs/superpowers/specs/2026-08-01-wealth-assistant-design.md` §5（自选/持仓/历史 + 建议闭环）、§3（trades/suggestions 字段）。计划二最终 review 的 backlog（stream 错误重试、登出、Timestamp 容错、spec §3 reviewedAt 文档）并入本计划 Task 8。

## Global Constraints

- Python 侧只允许改 `assistant/daily_brief.py` + `tests/test_assistant_daily_brief.py` + `firebase/firestore.indexes.json` + spec 文档；`tradingagents/` 与其余 `assistant/` 模块不动；全量 `pytest tests/ -q` 保持绿（用 `.venv/bin/python -m pytest`）
- Flutter 侧每任务结束 `cd app && flutter analyze`（0 issue）+ `flutter test`（全绿，含既有 22 个）
- 所有 App 写入的时间戳用 `repo.dart` 的 `utcNowIso()`（`DateTime.now().toUtc().toIso8601String().replaceFirst('Z', '+00:00')`）——与后端字符串格式逐字节一致，保证 Firestore 字符串排序/比较跨端成立
- Firestore 字段 camelCase 与 spec §3 一致；App 侧新建 job **不带 `date` 字段**（执行器会按美东当日兜底，客户端时钟不可信）
- 测试不联网：fake_cloud_firestore / firebase_auth_mocks / FakeLLM
- 代码块 API 校准原则同计划二：以 analyzer/编译器为准做最小适配，测试断言不变
- 提交信息 conventional commits；每任务一个 commit

## 现有接口速查（已落地，勿改名）

```dart
// models.dart: WatchItem/Position/PortfolioMeta/Brief/Analysis/Suggestion/Job
//   帮助函数 _d/_dOrNull/_s/_t/_tOrNull；Suggestion.isPending；Job.isActive/isFailed
// repo.dart: WealthRepo(FirebaseFirestore) — latestBrief/pendingSuggestions/watchlist/
//   positions/portfolioMeta/activeJobs（全部 Stream）
// providers.dart: firebaseAuthProvider/firestoreProvider/repoProvider/authStateProvider
// today_tab.dart 内部定义了 latestBriefProvider/pendingSuggestionsProvider/activeJobsProvider
//   （Task 5 会把这三个 provider 迁到 providers.dart 供各 tab 复用）
// home_shell.dart: NavigationBar 4 tab，第 0 个是 TodayTab，1/2/3 目前是占位 Center
```

Python 侧 `generate_daily_brief(store, llm, today, *, fetch_quote, fetch_news)` 现写入 `{date, markdownZh, tickers, createdAt}`。

---

### Task 1: 启用 Flutter Web 目标

**Files:**
- Create: `app/web/`（flutter create 生成）
- Modify: `app/lib/firebase_options.dart`（flutterfire 重新生成，新增 web 段）
- Modify: `app/README.md`（运行方式加 web）

**Interfaces:**
- Produces: `flutter run -d chrome` 可用的本地开发模式

- [ ] **Step 1: 添加 web 平台（app/ 下执行）**

```bash
cd app && flutter create . --platforms=web --org com.wealthassistant --project-name wealth_assistant
```

- [ ] **Step 2: 重新生成 FlutterFire 配置（三平台一起，非交互）**

```bash
flutterfire configure --project=wealth-assistant-5141d --platforms=android,macos,web --yes
```

会在 Firebase 项目里注册 web 应用并重写 `lib/firebase_options.dart`（android/macos 段应保持等价）。

- [ ] **Step 3: README 补运行方式**

`app/README.md` 「快速开始」运行命令改为：

```bash
flutter run -d chrome     # 本地开发推荐：浏览器直接跑，无需模拟器/桌面构建
flutter run               # Android 模拟器 / macOS 桌面
```

- [ ] **Step 4: 验证 + 提交**

```bash
cd app && flutter analyze && flutter test && flutter build web
git add -A ../app && git commit -m "feat(app): enable flutter web target for local development"
```

（`flutter build web` 成功即算通过；浏览器人工验收在 Task 9。）

---

### Task 2: 日报结构化行情字段（跨栈：Python 写，Dart 读）

**Files:**
- Modify: `assistant/daily_brief.py`
- Modify: `tests/test_assistant_daily_brief.py`
- Modify: `app/lib/models/models.dart`（Brief 增加 quotes；新增 TickerQuote）
- Modify: `app/test/models_test.dart`

**Interfaces:**
- Produces（Python 写入 brief 文档新增字段，行情获取失败的 ticker 不出现在 map 中）:

```
briefs/{date}.quotes: { "<TICKER>": { "close": <double>, "pctChange": <double> } }
```

- Produces（Dart）: `class TickerQuote { final double close; final double pctChange; }`；`Brief.quotes: Map<String, TickerQuote>`（缺字段时空 map）。Task 5/6 依赖 `brief.quotes[ticker]`。

- [ ] **Step 1: Python 失败测试（追加到 tests/test_assistant_daily_brief.py）**

```python
def test_brief_stores_structured_quotes():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n")
    saved = store.get_brief("2026-08-01")
    assert saved["quotes"]["NVDA"] == {"close": 110.0, "pctChange": 10.0}
    assert saved["quotes"]["AAPL"] == {"close": 110.0, "pctChange": 10.0}


def test_failed_quote_ticker_absent_from_quotes_map():
    def flaky_quote(ticker, **kw):
        if ticker == "NVDA":
            raise QuoteUnavailable("nope")
        return ok_quote(ticker)

    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=flaky_quote, fetch_news=lambda t, s, e: "n")
    saved = store.get_brief("2026-08-01")
    assert "NVDA" not in saved["quotes"]
    assert saved["quotes"]["AAPL"]["close"] == 110.0
```

- [ ] **Step 2: 跑测试确认失败**

Run: `.venv/bin/python -m pytest tests/test_assistant_daily_brief.py -q`
Expected: 2 新测试 FAIL（KeyError: 'quotes'）

- [ ] **Step 3: Python 实现**

`assistant/daily_brief.py` 的 ticker 循环里已有 `q`（成功时为 dict、失败为 None）。在循环外建 `quotes_map: dict = {}`，成功分支加：

```python
            quotes_map[t] = {"close": q["close"], "pctChange": q["pctChange"]}
```

`store.save_brief(...)` 的文档追加一项 `"quotes": quotes_map,`。

- [ ] **Step 4: Python 测试通过 + 全量回归**

Run: `.venv/bin/python -m pytest tests/test_assistant_daily_brief.py -q`（全绿）
Run: `.venv/bin/python -m pytest tests/ -q`（全量不破坏）

- [ ] **Step 5: Dart 失败测试（追加到 app/test/models_test.dart）**

```dart
  test('Brief parses quotes map and defaults to empty', () {
    final b = Brief.fromDoc('2026-08-01', {
      'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['NVDA'],
      'createdAt': '2026-08-01T10:00:00+00:00',
      'quotes': {'NVDA': {'close': 110, 'pctChange': 2.93}},
    });
    expect(b.quotes['NVDA']!.close, 110.0);
    expect(b.quotes['NVDA']!.pctChange, 2.93);
    final old = Brief.fromDoc('2026-07-31', {
      'date': '2026-07-31', 'markdownZh': 'x', 'tickers': [],
      'createdAt': '2026-07-31T10:00:00+00:00',
    });
    expect(old.quotes, isEmpty);
  });
```

- [ ] **Step 6: Dart 实现（models.dart）**

```dart
class TickerQuote {
  const TickerQuote({required this.close, required this.pctChange});
  final double close;
  final double pctChange;

  factory TickerQuote.fromMap(Map<String, dynamic> d) =>
      TickerQuote(close: _d(d['close']), pctChange: _d(d['pctChange']));
}
```

`Brief` 增加字段 `final Map<String, TickerQuote> quotes;`（构造函数 required），`fromDoc` 里：

```dart
        quotes: {
          for (final e in ((d['quotes'] as Map?) ?? const {}).entries)
            e.key as String:
                TickerQuote.fromMap(Map<String, dynamic>.from(e.value as Map)),
        },
```

- [ ] **Step 7: Dart 测试通过 + 提交**

Run: `cd app && flutter test && flutter analyze`

```bash
git add assistant/daily_brief.py tests/test_assistant_daily_brief.py app/lib/models/models.dart app/test/models_test.dart
git commit -m "feat(assistant,app): add structured quotes to daily brief"
```

---

### Task 3: WealthRepo 写方法、新查询与索引

**Files:**
- Modify: `app/lib/data/repo.dart`
- Modify: `app/test/repo_test.dart`
- Modify: `firebase/firestore.indexes.json`（analyses 复合索引）

**Interfaces:**
- Produces（Task 4-7 依赖，签名固定）:

```dart
String utcNowIso();  // 顶层函数：+00:00 后缀，与后端格式一致

class WealthRepo {
  // 写
  Future<void> resolveSuggestion(String id, {required bool accepted});
      // status = accepted?"accepted":"dismissed"; resolvedAt = utcNowIso()
  Future<void> addTrade({required String ticker, required String side,
      required double shares, required double price, required String date,
      String? suggestionId});                       // trades/ 新文档
  Future<void> setPosition({required String ticker, required double shares,
      required double avgCost});                    // positions/{ticker} set + updatedAt
  Future<void> deletePosition(String ticker);
  Future<void> setCash(double cash);                // meta/portfolio merge {cash, currency:"USD"}
  Future<void> addWatch(String ticker, {String deepFreq = 'manual'});
      // watchlist/{ticker} set {ticker, note:"", deepFreq, addedAt}
  Future<void> removeWatch(String ticker);
  Future<void> setDeepFreq(String ticker, String deepFreq);   // update 单字段
  Future<String> enqueueDeepAnalysis(String ticker);
      // jobs 新文档 {type:"deep_analysis", ticker, status:"queued",
      //  requestedBy:"user", createdAt}；返回 id；不带 date 字段
  // 读
  Stream<List<Analysis>> analysesForTicker(String ticker);   // where ticker== orderBy createdAt desc
  Stream<List<Analysis>> recentAnalyses({int limit = 50});   // orderBy createdAt desc
  Stream<List<Suggestion>> allSuggestions({int limit = 100});// orderBy createdAt desc
}
```

- [ ] **Step 1: 失败测试（追加到 app/test/repo_test.dart）**

```dart
  test('resolveSuggestion sets status and resolvedAt', () async {
    final ref = await db.collection('suggestions').add({
      'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a',
      'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await repo.resolveSuggestion(ref.id, accepted: true);
    final doc = (await db.collection('suggestions').doc(ref.id).get()).data()!;
    expect(doc['status'], 'accepted');
    expect(doc['resolvedAt'], endsWith('+00:00'));
    await repo.resolveSuggestion(ref.id, accepted: false);
    expect((await db.collection('suggestions').doc(ref.id).get()).data()!['status'], 'dismissed');
  });

  test('addTrade writes a trade doc linked to suggestion', () async {
    await repo.addTrade(ticker: 'NVDA', side: 'sell', shares: 3, price: 200.5,
        date: '2026-08-01', suggestionId: 's1');
    final docs = (await db.collection('trades').get()).docs;
    expect(docs.single.data(), {
      'ticker': 'NVDA', 'side': 'sell', 'shares': 3.0, 'price': 200.5,
      'date': '2026-08-01', 'suggestionId': 's1',
    });
  });

  test('setPosition/deletePosition/setCash roundtrip', () async {
    await repo.setPosition(ticker: 'NVDA', shares: 10, avgCost: 150);
    var doc = (await db.collection('positions').doc('NVDA').get()).data()!;
    expect(doc['shares'], 10.0);
    expect(doc['updatedAt'], endsWith('+00:00'));
    await repo.setCash(8888.0);
    expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 8888.0);
    await repo.deletePosition('NVDA');
    expect((await db.collection('positions').doc('NVDA').get()).exists, isFalse);
  });

  test('watchlist add/remove/setDeepFreq', () async {
    await repo.addWatch('NVDA', deepFreq: 'weekly');
    var doc = (await db.collection('watchlist').doc('NVDA').get()).data()!;
    expect(doc['deepFreq'], 'weekly');
    expect(doc['addedAt'], endsWith('+00:00'));
    await repo.setDeepFreq('NVDA', 'manual');
    expect((await db.collection('watchlist').doc('NVDA').get()).data()!['deepFreq'], 'manual');
    await repo.removeWatch('NVDA');
    expect((await db.collection('watchlist').doc('NVDA').get()).exists, isFalse);
  });

  test('enqueueDeepAnalysis writes user job without date field', () async {
    final jid = await repo.enqueueDeepAnalysis('NVDA');
    final doc = (await db.collection('jobs').doc(jid).get()).data()!;
    expect(doc['type'], 'deep_analysis');
    expect(doc['ticker'], 'NVDA');
    expect(doc['status'], 'queued');
    expect(doc['requestedBy'], 'user');
    expect(doc.containsKey('date'), isFalse);
  });

  test('analysesForTicker filters and sorts desc; recentAnalyses sorts desc', () async {
    for (final (t, ts) in [('NVDA', '2026-07-01'), ('AAPL', '2026-07-02'), ('NVDA', '2026-07-03')]) {
      await db.collection('analyses').add({
        'ticker': t, 'tradeDate': ts, 'decision': 'HOLD', 'sections': {},
        'createdAt': '${ts}T00:00:00+00:00',
      });
    }
    final nvda = await repo.analysesForTicker('NVDA').first;
    expect(nvda.map((a) => a.tradeDate), ['2026-07-03', '2026-07-01']);
    final recent = await repo.recentAnalyses().first;
    expect(recent.first.tradeDate, '2026-07-03');
    expect(recent.length, 3);
  });

  test('allSuggestions returns newest first regardless of status', () async {
    for (final (t, st, ts) in [('A', 'accepted', '01'), ('B', 'pending', '02'), ('C', 'dismissed', '03')]) {
      await db.collection('suggestions').add({
        'ticker': t, 'action': 'buy', 'rationale': 'r', 'analysisId': 'x',
        'status': st, 'createdAt': '2026-08-${ts}T00:00:00+00:00',
      });
    }
    final all = await repo.allSuggestions().first;
    expect(all.map((s) => s.ticker), ['C', 'B', 'A']);
  });
```

- [ ] **Step 2: 跑测试确认失败** → `cd app && flutter test test/repo_test.dart`（新方法不存在，编译失败）

- [ ] **Step 3: 实现（repo.dart 追加）**

```dart
String utcNowIso() =>
    DateTime.now().toUtc().toIso8601String().replaceFirst('Z', '+00:00');
```

类内追加：

```dart
  // --- writes (plan 3) ---
  Future<void> resolveSuggestion(String id, {required bool accepted}) =>
      _db.collection('suggestions').doc(id).update({
        'status': accepted ? 'accepted' : 'dismissed',
        'resolvedAt': utcNowIso(),
      });

  Future<void> addTrade({
    required String ticker, required String side, required double shares,
    required double price, required String date, String? suggestionId,
  }) =>
      _db.collection('trades').add({
        'ticker': ticker, 'side': side, 'shares': shares, 'price': price,
        'date': date, if (suggestionId != null) 'suggestionId': suggestionId,
      });

  Future<void> setPosition({
    required String ticker, required double shares, required double avgCost,
  }) =>
      _db.collection('positions').doc(ticker).set({
        'ticker': ticker, 'shares': shares, 'avgCost': avgCost,
        'updatedAt': utcNowIso(),
      });

  Future<void> deletePosition(String ticker) =>
      _db.collection('positions').doc(ticker).delete();

  Future<void> setCash(double cash) => _db
      .collection('meta')
      .doc('portfolio')
      .set({'cash': cash, 'currency': 'USD'}, SetOptions(merge: true));

  Future<void> addWatch(String ticker, {String deepFreq = 'manual'}) =>
      _db.collection('watchlist').doc(ticker).set({
        'ticker': ticker, 'note': '', 'deepFreq': deepFreq,
        'addedAt': utcNowIso(),
      });

  Future<void> removeWatch(String ticker) =>
      _db.collection('watchlist').doc(ticker).delete();

  Future<void> setDeepFreq(String ticker, String deepFreq) =>
      _db.collection('watchlist').doc(ticker).update({'deepFreq': deepFreq});

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
```

- [ ] **Step 4: 索引文件追加（firebase/firestore.indexes.json 的 indexes 数组）**

```json
    {
      "collectionGroup": "analyses",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "ticker", "order": "ASCENDING" },
        { "fieldPath": "createdAt", "order": "DESCENDING" },
        { "fieldPath": "__name__", "order": "DESCENDING" }
      ]
    }
```

（部署由 Task 9 前置步骤执行 `firebase deploy --only firestore`。）

- [ ] **Step 5: 测试通过 + 提交**

Run: `cd app && flutter test && flutter analyze`

```bash
git add app/lib/data/repo.dart app/test/repo_test.dart firebase/firestore.indexes.json
git commit -m "feat(app): add write methods and history queries to repo"
```

---

### Task 4: 建议卡片交互（采纳/忽略 + 可选录成交）

**Files:**
- Modify: `app/lib/ui/widgets/suggestion_card.dart`
- Modify: `app/lib/ui/today_tab.dart`（传回调）
- Test: `app/test/suggestion_actions_test.dart`（新建）

**Interfaces:**
- Consumes: `repoProvider`（resolveSuggestion/addTrade）
- Produces: `SuggestionCard({required Suggestion suggestion, VoidCallback? onAccept, VoidCallback? onDismiss})`——按钮 enabled；今日 tab 里 onAccept 弹 `_AcceptDialog`（可选 shares/price，两个提交按钮），onDismiss 直接 dismissed + SnackBar

行为规格：

- [忽略] → `resolveSuggestion(id, accepted: false)`，SnackBar「已忽略」
- [采纳] → dialog：说明文案 + `shares`（Key `tradeShares`）、`price`（Key `tradePrice`）两个数字输入 + 按钮 [仅标记采纳]（Key `acceptOnly`）与 [记录成交并采纳]（Key `acceptWithTrade`）
  - 仅标记：`resolveSuggestion(id, accepted: true)`
  - 记录成交：两字段合法（>0 数字）时 `addTrade(ticker, side, shares, price, date: 今天 YYYY-MM-DD, suggestionId: id)` + `resolveSuggestion`；side 由 action 映射（buy/add→"buy"，trim/sell→"sell"，hold→"hold" 不该出现，按 "buy" 兜底）；非法输入禁用提交
- 卡片在建议 status 变化后自然从 pending 流里消失（stream 驱动，无需手动移除）

- [ ] **Step 1: 失败测试（app/test/suggestion_actions_test.dart，完整新文件）**

```dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/today_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: TodayTab())),
    );

Future<String> _seedPending(FakeFirebaseFirestore db) async {
  final ref = await db.collection('suggestions').add({
    'ticker': 'NVDA', 'action': 'trim', 'targetWeightPct': 15,
    'rationale': '估值过高', 'analysisId': 'a1',
    'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
  });
  return ref.id;
}

void main() {
  testWidgets('dismiss updates status and card disappears', (tester) async {
    final db = FakeFirebaseFirestore();
    final id = await _seedPending(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('忽略'));
    await tester.pumpAndSettle();
    final doc = (await db.collection('suggestions').doc(id).get()).data()!;
    expect(doc['status'], 'dismissed');
    expect(doc['resolvedAt'], endsWith('+00:00'));
    expect(find.text('NVDA · TRIM'), findsNothing);   // pending 流里消失
  });

  testWidgets('accept-only marks accepted without trade', (tester) async {
    final db = FakeFirebaseFirestore();
    final id = await _seedPending(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采纳'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('acceptOnly')));
    await tester.pumpAndSettle();
    expect((await db.collection('suggestions').doc(id).get()).data()!['status'], 'accepted');
    expect((await db.collection('trades').get()).docs, isEmpty);
  });

  testWidgets('accept with trade records linked trade doc', (tester) async {
    final db = FakeFirebaseFirestore();
    final id = await _seedPending(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采纳'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tradeShares')), '3');
    await tester.enterText(find.byKey(const Key('tradePrice')), '200.5');
    await tester.tap(find.byKey(const Key('acceptWithTrade')));
    await tester.pumpAndSettle();
    final trade = (await db.collection('trades').get()).docs.single.data();
    expect(trade['ticker'], 'NVDA');
    expect(trade['side'], 'sell');           // trim → sell
    expect(trade['shares'], 3.0);
    expect(trade['price'], 200.5);
    expect(trade['suggestionId'], id);
    expect((await db.collection('suggestions').doc(id).get()).data()!['status'], 'accepted');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**（按钮当前 disabled，tap 无效果 → 断言失败）

- [ ] **Step 3: 实现**

`suggestion_card.dart`：构造加 `this.onAccept, this.onDismiss`（`VoidCallback?`），两个按钮 `onPressed: onAccept / onDismiss`，移除 Tooltip 占位。

`today_tab.dart` 建议列表处：

```dart
              for (final s in value)
                SuggestionCard(
                  suggestion: s,
                  onDismiss: () async {
                    await ref.read(repoProvider).resolveSuggestion(s.id, accepted: false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('已忽略')));
                    }
                  },
                  onAccept: () => showDialog<void>(
                    context: context,
                    builder: (_) => _AcceptDialog(suggestion: s, ref: ref),
                  ),
                ),
```

`_AcceptDialog`（today_tab.dart 内私有 StatefulWidget，完整实现）：

```dart
class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.suggestion, required this.ref});
  final Suggestion suggestion;
  final WidgetRef ref;

  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  final _shares = TextEditingController();
  final _price = TextEditingController();

  @override
  void dispose() {
    _shares.dispose();
    _price.dispose();
    super.dispose();
  }

  String get _side => switch (widget.suggestion.action) {
        'sell' || 'trim' => 'sell',
        _ => 'buy',
      };

  Future<void> _accept({required bool withTrade}) async {
    final repo = widget.ref.read(repoProvider);
    if (withTrade) {
      final shares = double.tryParse(_shares.text);
      final price = double.tryParse(_price.text);
      if (shares == null || shares <= 0 || price == null || price <= 0) return;
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      await repo.addTrade(
          ticker: widget.suggestion.ticker, side: _side, shares: shares,
          price: price, date: today, suggestionId: widget.suggestion.id);
    }
    await repo.resolveSuggestion(widget.suggestion.id, accepted: true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    return AlertDialog(
      title: Text('采纳建议：${s.ticker} ${s.action.toUpperCase()}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('可顺手记录实际成交（可选）：'),
          TextField(key: const Key('tradeShares'), controller: _shares,
              decoration: const InputDecoration(labelText: '股数'),
              keyboardType: TextInputType.number),
          TextField(key: const Key('tradePrice'), controller: _price,
              decoration: const InputDecoration(labelText: '成交价'),
              keyboardType: TextInputType.number),
        ],
      ),
      actions: [
        TextButton(key: const Key('acceptOnly'),
            onPressed: () => _accept(withTrade: false), child: const Text('仅标记采纳')),
        FilledButton(key: const Key('acceptWithTrade'),
            onPressed: () => _accept(withTrade: true), child: const Text('记录成交并采纳')),
      ],
    );
  }
}
```

（import 需补 `../models/models.dart` 已有、`providers.dart` 已有。）

- [ ] **Step 4: 测试通过 + 提交**

Run: `cd app && flutter test && flutter analyze`

```bash
git add app/lib/ui app/test/suggestion_actions_test.dart
git commit -m "feat(app): wire accept/dismiss suggestion actions with optional trade"
```

---

### Task 5: 自选 tab

**Files:**
- Create: `app/lib/ui/watch_tab.dart`
- Modify: `app/lib/providers.dart`（把 today_tab 的三个 StreamProvider 迁入，另加 watchlistProvider）
- Modify: `app/lib/ui/today_tab.dart`（改用迁移后的 provider）
- Modify: `app/lib/ui/home_shell.dart`（tab1 → WatchTab）
- Test: `app/test/watch_tab_test.dart`

**Interfaces:**
- Consumes: `repoProvider`（watchlist/addWatch/removeWatch/setDeepFreq/enqueueDeepAnalysis）、`latestBriefProvider`（行情）、`activeJobsProvider`（job 状态）
- Produces（providers.dart 迁移后，全 App 共用）:

```dart
final latestBriefProvider = StreamProvider<Brief?>(...);
final pendingSuggestionsProvider = StreamProvider<List<Suggestion>>(...);
final activeJobsProvider = StreamProvider<List<Job>>(...);
final watchlistProvider = StreamProvider<List<WatchItem>>((ref) => ref.watch(repoProvider).watchlist());
```

行为规格：

- 列表行：ticker + deepFreq 标签（点击在 weekly/manual 间切换）+ 行情（`brief.quotes[ticker]` 有则显示「$close  ±pct%」，无则「—」）+ [分析] 按钮
- [分析] → `enqueueDeepAnalysis(ticker)` + SnackBar「已排队」；该股已有 active job 时按钮替换为状态 chip（排队中/分析中）
- FAB「＋」→ dialog 输入 ticker（自动大写，Key `watchTicker`）+ deepFreq 选择，确认（Key `watchAdd`）写入
- 行左滑（Dismissible）删除，SnackBar 确认
- 空态文案「自选列表为空，点右下角添加」

- [ ] **Step 1: 失败测试（app/test/watch_tab_test.dart，完整新文件）**

```dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/watch_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: WatchTab())),
    );

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('watchlist').doc('NVDA').set({
    'ticker': 'NVDA', 'note': '', 'deepFreq': 'weekly',
    'addedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('briefs').doc('2026-08-01').set({
    'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['NVDA'],
    'createdAt': '2026-08-01T00:00:00+00:00',
    'quotes': {'NVDA': {'close': 200.75, 'pctChange': 2.93}},
  });
}

void main() {
  testWidgets('renders watch item with quote from latest brief', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('NVDA'), findsOneWidget);
    expect(find.textContaining('200.75'), findsOneWidget);
    expect(find.textContaining('2.93'), findsOneWidget);
    expect(find.text('weekly'), findsOneWidget);
  });

  testWidgets('analyze button enqueues a user job', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析'));
    await tester.pumpAndSettle();
    final job = (await db.collection('jobs').get()).docs.single.data();
    expect(job['type'], 'deep_analysis');
    expect(job['ticker'], 'NVDA');
    expect(job['requestedBy'], 'user');
  });

  testWidgets('active job replaces analyze button with status chip', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await db.collection('jobs').add({
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'running',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('分析'), findsNothing);
    expect(find.text('分析中'), findsOneWidget);
  });

  testWidgets('add dialog writes watch doc uppercased', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('自选列表为空'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('watchTicker')), 'aapl');
    await tester.tap(find.byKey(const Key('watchAdd')));
    await tester.pumpAndSettle();
    final doc = (await db.collection('watchlist').doc('AAPL').get()).data()!;
    expect(doc['ticker'], 'AAPL');
    expect(doc['deepFreq'], 'manual');
  });

  testWidgets('deepFreq label toggles on tap', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('weekly'));
    await tester.pumpAndSettle();
    expect((await db.collection('watchlist').doc('NVDA').get()).data()!['deepFreq'], 'manual');
  });
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败（watch_tab.dart 不存在）

- [ ] **Step 3: 实现**

providers.dart 迁移（today_tab.dart 顶部三个 provider 剪切到 providers.dart，today_tab 改 import；models import 加入 providers.dart）+ 新增 `watchlistProvider`。

```dart
// app/lib/ui/watch_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';

class WatchTab extends ConsumerWidget {
  const WatchTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watch = ref.watch(watchlistProvider);
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final jobs = ref.watch(activeJobsProvider).value ?? const <Job>[];
    final activeTickers = {for (final j in jobs) if (j.ticker != null) j.ticker!: j.status};

    return Scaffold(
      body: watch.when(
        data: (items) => items.isEmpty
            ? const Center(child: Text('自选列表为空，点右下角添加'))
            : ListView(
                children: [
                  for (final w in items)
                    Dismissible(
                      key: ValueKey(w.ticker),
                      direction: DismissDirection.endToStart,
                      background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white)),
                      onDismissed: (_) async {
                        await ref.read(repoProvider).removeWatch(w.ticker);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已删除 ${w.ticker}')));
                        }
                      },
                      child: ListTile(
                        title: Text(w.ticker),
                        subtitle: Text(_quoteLine(quotes[w.ticker])),
                        leading: ActionChip(
                          label: Text(w.deepFreq),
                          onPressed: () => ref.read(repoProvider).setDeepFreq(
                              w.ticker, w.deepFreq == 'weekly' ? 'manual' : 'weekly'),
                        ),
                        trailing: activeTickers.containsKey(w.ticker)
                            ? Chip(label: Text(
                                activeTickers[w.ticker] == 'queued' ? '排队中' : '分析中'))
                            : TextButton(
                                onPressed: () async {
                                  await ref.read(repoProvider).enqueueDeepAnalysis(w.ticker);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('${w.ticker} 已排队')));
                                  }
                                },
                                child: const Text('分析')),
                      ),
                    ),
                ],
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('自选加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => _AddWatchDialog(ref: ref)),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _quoteLine(TickerQuote? q) => q == null
      ? '—'
      : '\$${q.close.toStringAsFixed(2)}  ${q.pctChange >= 0 ? '+' : ''}${q.pctChange.toStringAsFixed(2)}%';
}

class _AddWatchDialog extends StatefulWidget {
  const _AddWatchDialog({required this.ref});
  final WidgetRef ref;

  @override
  State<_AddWatchDialog> createState() => _AddWatchDialogState();
}

class _AddWatchDialogState extends State<_AddWatchDialog> {
  final _ticker = TextEditingController();
  String _deepFreq = 'manual';

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自选'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(key: const Key('watchTicker'), controller: _ticker,
              decoration: const InputDecoration(labelText: '代码（如 NVDA）'),
              textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'manual', label: Text('手动分析')),
              ButtonSegment(value: 'weekly', label: Text('每周分析')),
            ],
            selected: {_deepFreq},
            onSelectionChanged: (s) => setState(() => _deepFreq = s.first),
          ),
        ],
      ),
      actions: [
        FilledButton(
          key: const Key('watchAdd'),
          onPressed: () async {
            final t = _ticker.text.trim().toUpperCase();
            if (t.isEmpty) return;
            await widget.ref.read(repoProvider).addWatch(t, deepFreq: _deepFreq);
            if (mounted) Navigator.of(context).pop();
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}
```

home_shell.dart tab1 → `WatchTab()`。

- [ ] **Step 4: 测试通过（含既有 today/auth 测试因 provider 迁移不回归）+ 提交**

Run: `cd app && flutter test && flutter analyze`

```bash
git add app/lib app/test/watch_tab_test.dart
git commit -m "feat(app): watchlist tab with quotes, deep-analysis trigger, and management"
```

---

### Task 6: 持仓 tab

**Files:**
- Create: `app/lib/ui/portfolio_tab.dart`
- Modify: `app/lib/providers.dart`（加 positionsProvider/portfolioMetaProvider）
- Modify: `app/lib/ui/home_shell.dart`（tab2 → PortfolioTab）
- Test: `app/test/portfolio_tab_test.dart`

**Interfaces:**
- Consumes: `repoProvider`（positions/portfolioMeta/setPosition/deletePosition/setCash）、`latestBriefProvider`（现价）
- Produces:

```dart
final positionsProvider = StreamProvider<List<Position>>((ref) => ref.watch(repoProvider).positions());
final portfolioMetaProvider = StreamProvider<PortfolioMeta>((ref) => ref.watch(repoProvider).portfolioMeta());
```

行为规格：

- 顶部概览卡：现金（点击→编辑 dialog，Key `cashField`/`cashSave`）、总市值 = 现金 + Σ(股数×现价或成本价兜底)、总浮动盈亏 %（无任何现价时显示「—」）
- 持仓行：ticker、`股数 @ 成本`、现价与该股盈亏 %（`brief.quotes` 缺失时「现价 —」）；点击行 → 编辑 dialog（预填，Key `posShares`/`posAvgCost`/`posSave`，含删除按钮 Key `posDelete`）
- FAB「＋」→ 同一编辑 dialog 空白版（Key `posTicker` 可输入）
- 空态「暂无持仓」

- [ ] **Step 1: 失败测试（app/test/portfolio_tab_test.dart，完整新文件）**

```dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/portfolio_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: PortfolioTab())),
    );

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('positions').doc('NVDA').set({
    'ticker': 'NVDA', 'shares': 10, 'avgCost': 150.0,
    'updatedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('meta').doc('portfolio').set({'cash': 5000.0, 'currency': 'USD'});
  await db.collection('briefs').doc('2026-08-01').set({
    'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['NVDA'],
    'createdAt': '2026-08-01T00:00:00+00:00',
    'quotes': {'NVDA': {'close': 200.75, 'pctChange': 2.93}},
  });
}

void main() {
  testWidgets('overview shows cash, market value and pnl from quotes', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('5000.00'), findsOneWidget);      // 现金
    expect(find.textContaining('7007.50'), findsOneWidget);      // 5000 + 10*200.75
    expect(find.textContaining('33.83'), findsOneWidget);        // (200.75-150)/150
    expect(find.textContaining('NVDA'), findsWidgets);
  });

  testWidgets('edit cash via dialog', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cashCard')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cashField')), '8888');
    await tester.tap(find.byKey(const Key('cashSave')));
    await tester.pumpAndSettle();
    expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 8888.0);
  });

  testWidgets('add position via FAB dialog', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('暂无持仓'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('posTicker')), 'aapl');
    await tester.enterText(find.byKey(const Key('posShares')), '5');
    await tester.enterText(find.byKey(const Key('posAvgCost')), '180.5');
    await tester.tap(find.byKey(const Key('posSave')));
    await tester.pumpAndSettle();
    final doc = (await db.collection('positions').doc('AAPL').get()).data()!;
    expect(doc['shares'], 5.0);
    expect(doc['avgCost'], 180.5);
  });

  testWidgets('edit and delete existing position', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('NVDA').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('posShares')), '20');
    await tester.tap(find.byKey(const Key('posSave')));
    await tester.pumpAndSettle();
    expect((await db.collection('positions').doc('NVDA').get()).data()!['shares'], 20.0);
    await tester.tap(find.textContaining('NVDA').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('posDelete')));
    await tester.pumpAndSettle();
    expect((await db.collection('positions').doc('NVDA').get()).exists, isFalse);
  });
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败

- [ ] **Step 3: 实现（portfolio_tab.dart 完整实现，结构如下）**

```dart
// app/lib/ui/portfolio_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';

class PortfolioTab extends ConsumerWidget {
  const PortfolioTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions = ref.watch(positionsProvider).value ?? const <Position>[];
    final meta = ref.watch(portfolioMetaProvider).value ??
        const PortfolioMeta(cash: 0, currency: 'USD');
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};

    double priceOf(Position p) => quotes[p.ticker]?.close ?? p.avgCost;
    final stockValue =
        positions.fold<double>(0, (sum, p) => sum + p.shares * priceOf(p));
    final total = meta.cash + stockValue;
    final cost = positions.fold<double>(0, (s, p) => s + p.shares * p.avgCost);
    final hasQuote = positions.any((p) => quotes.containsKey(p.ticker));
    final pnlPct = (cost > 0 && hasQuote) ? (stockValue - cost) / cost * 100 : null;

    return Scaffold(
      body: ListView(
        children: [
          Card(
            key: const Key('cashCard'),
            margin: const EdgeInsets.all(16),
            child: InkWell(
              onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => _CashDialog(ref: ref, current: meta.cash)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('现金 ${meta.cash.toStringAsFixed(2)} ${meta.currency}'),
                    Text('总市值 ${total.toStringAsFixed(2)}'),
                    Text('浮动盈亏 ${pnlPct == null ? '—' : '${pnlPct >= 0 ? '+' : ''}${pnlPct.toStringAsFixed(2)}%'}'),
                  ],
                ),
              ),
            ),
          ),
          if (positions.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无持仓')))
          else
            for (final p in positions)
              ListTile(
                title: Text(p.ticker),
                subtitle: Text(
                    '${p.shares.toStringAsFixed(0)} 股 @ ${p.avgCost.toStringAsFixed(2)}'),
                trailing: Text(_pnlLine(p, quotes[p.ticker])),
                onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _PositionDialog(ref: ref, existing: p)),
              ),
          const SizedBox(height: 80),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => _PositionDialog(ref: ref)),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _pnlLine(Position p, TickerQuote? q) {
    if (q == null) return '现价 —';
    final pnl = (q.close - p.avgCost) / p.avgCost * 100;
    return '${q.close.toStringAsFixed(2)}  ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}%';
  }
}

class _CashDialog extends StatefulWidget { /* cashField/cashSave，double.tryParse 校验，
  repo.setCash 后 pop —— 按 Task 4 dialog 模式实现 */ }

class _PositionDialog extends StatefulWidget { /* existing==null 时显示 posTicker 输入，
  否则 ticker 只读；posShares/posAvgCost 预填；posSave → setPosition(大写 ticker)；
  existing!=null 时显示 posDelete → deletePosition + pop —— 按 Task 4 dialog 模式实现，
  两个 controller 均 dispose */ }
```

（两个 dialog 类体按注释规格完整写出——模式与 Task 4 `_AcceptDialog` 一致：StatefulWidget + TextEditingController + dispose + 校验非法输入直接 return。）

- [ ] **Step 4: 测试通过 + 提交**

```bash
git add app/lib app/test/portfolio_tab_test.dart
git commit -m "feat(app): portfolio tab with cash and position management"
```

---

### Task 7: 历史 tab + 分析详情页

**Files:**
- Create: `app/lib/ui/history_tab.dart`
- Create: `app/lib/ui/analysis_detail_page.dart`
- Modify: `app/lib/ui/home_shell.dart`（tab3 → HistoryTab）
- Modify: `app/lib/ui/watch_tab.dart`（行 onTap → 进入该股分析列表页）
- Test: `app/test/history_tab_test.dart`

**Interfaces:**
- Consumes: `repoProvider`（recentAnalyses/allSuggestions/analysesForTicker）
- Produces: `AnalysisDetailPage({required Analysis analysis})`（13 节 ExpansionTile + MarkdownBody，空节隐藏）；`TickerAnalysesPage({required String ticker})`（watch_tab 跳转用）

行为规格：

- HistoryTab 顶部 SegmentedButton 切「分析」/「建议」两个列表
- 分析列表行：`{ticker} · {decision}` + tradeDate → 点击进 AnalysisDetailPage
- 建议列表行：`{ticker} · {action}` + status chip（pending/accepted/dismissed 中文标签）+ `outcomePct` 有值时显示「复盘 ±x.x%」
- AnalysisDetailPage：AppBar 标题 `{ticker} {tradeDate}`，decision 卡片 + 13 节中非空的 ExpansionTile（节名中文映射：market→市场技术面、sentiment→情绪、news→新闻、fundamentals→基本面、bull→多方观点、bear→空方观点、researchManager→研究主管结论、traderPlan→交易员计划、riskAggressive→激进风控、riskConservative→保守风控、riskNeutral→中性风控、portfolioDecision→组合经理决定、finalDecision→最终决策）
- TickerAnalysesPage：`analysesForTicker` 列表复用同一行组件 → AnalysisDetailPage

- [ ] **Step 1: 失败测试（app/test/history_tab_test.dart，完整新文件）**

```dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/history_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: HistoryTab())),
    );

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('analyses').add({
    'ticker': 'NVDA', 'tradeDate': '2026-08-01', 'decision': 'SELL',
    'sections': {'market': '# 技术面\n均线走弱', 'bull': '', 'finalDecision': '减仓'},
    'createdAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('suggestions').add({
    'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a',
    'status': 'accepted', 'createdAt': '2026-07-10T00:00:00+00:00',
    'outcomePct': -4.2,
  });
}

void main() {
  testWidgets('analyses segment lists analysis and opens detail', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('NVDA · SELL'), findsOneWidget);
    await tester.tap(find.text('NVDA · SELL'));
    await tester.pumpAndSettle();
    expect(find.text('NVDA 2026-08-01'), findsOneWidget);   // 详情页 AppBar
    expect(find.text('市场技术面'), findsOneWidget);          // 非空节
    expect(find.text('多方观点'), findsNothing);              // 空节隐藏
    await tester.tap(find.text('市场技术面'));
    await tester.pumpAndSettle();
    expect(find.textContaining('均线走弱'), findsOneWidget);  // markdown 展开
  });

  testWidgets('suggestions segment shows status and outcome', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('建议'));
    await tester.pumpAndSettle();
    expect(find.text('NVDA · TRIM'), findsOneWidget);
    expect(find.text('已采纳'), findsOneWidget);
    expect(find.textContaining('-4.2'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败

- [ ] **Step 3: 实现**

`history_tab.dart`：ConsumerStatefulWidget 持 `_segment`（'analyses'|'suggestions'），SegmentedButton 切换；两个列表分别 watch `StreamProvider.autoDispose` 包装的 `recentAnalyses()`/`allSuggestions()`（直接 `ref.watch(repoProvider)` 后 StreamBuilder 亦可——实现取一种，测试只断言渲染结果）。分析行 `ListTile(title: Text('${a.ticker} · ${a.decision}'), subtitle: Text(a.tradeDate), onTap: → AnalysisDetailPage)`。建议行 status 中文映射 {pending: 待处理, accepted: 已采纳, dismissed: 已忽略}，outcomePct 非空显示 `复盘 ${outcomePct}%`。

`analysis_detail_page.dart`：

```dart
const _sectionTitles = <String, String>{
  'market': '市场技术面', 'sentiment': '情绪', 'news': '新闻',
  'fundamentals': '基本面', 'bull': '多方观点', 'bear': '空方观点',
  'researchManager': '研究主管结论', 'traderPlan': '交易员计划',
  'riskAggressive': '激进风控', 'riskConservative': '保守风控',
  'riskNeutral': '中性风控', 'portfolioDecision': '组合经理决定',
  'finalDecision': '最终决策',
};
```

Scaffold(AppBar title `'${a.ticker} ${a.tradeDate}'`) + ListView：decision Card + `for entry in _sectionTitles.entries where a.section(key).isNotEmpty` → `ExpansionTile(title: Text(中文名), children: [Padding(MarkdownBody(data: a.section(key)))])`。

`TickerAnalysesPage`（放 history_tab.dart 或单独文件均可）：AppBar `'$ticker 历史分析'` + 复用分析行组件，数据 `analysesForTicker(ticker)`。watch_tab 的 ListTile `onTap: Navigator.push(TickerAnalysesPage(ticker: w.ticker))`。

- [ ] **Step 4: 测试通过 + 提交**

```bash
git add app/lib app/test/history_tab_test.dart
git commit -m "feat(app): history tab with analysis detail and suggestion archive"
```

---

### Task 8: 体验加固（登出、错误重试、Timestamp 容错、spec 文档）

**Files:**
- Modify: `app/lib/ui/home_shell.dart`（AppBar + 登出）
- Create: `app/lib/ui/widgets/stream_error.dart`
- Modify: `app/lib/ui/today_tab.dart` / `watch_tab.dart`（error 分支换 StreamError）
- Modify: `app/lib/models/models.dart`（`_t`/`_tOrNull` 容忍 Firestore Timestamp）
- Modify: `docs/superpowers/specs/2026-08-01-wealth-assistant-design.md`（§3 suggestions 补 reviewedAt；briefs 补 quotes）
- Test: `app/test/models_test.dart`、`app/test/auth_test.dart`（追加）

**Interfaces:**
- Produces: `StreamError({required Object error, required VoidCallback onRetry})`——错误文案 + [重试] 按钮；调用方 `onRetry: () => ref.invalidate(xxxProvider)`

- [ ] **Step 1: 失败测试**

`models_test.dart` 追加：

```dart
  test('_t and _tOrNull tolerate Firestore Timestamp values', () {
    final ts = Timestamp.fromDate(DateTime.utc(2026, 8, 1, 10));
    final j = Job.fromDoc('j', {
      'type': 'daily_brief', 'status': 'done', 'requestedBy': 'user',
      'createdAt': ts, 'finishedAt': ts,
    });
    expect(j.createdAt, DateTime.utc(2026, 8, 1, 10));
    expect(j.finishedAt, DateTime.utc(2026, 8, 1, 10));
  });
```

（import `package:cloud_firestore/cloud_firestore.dart` 加入测试文件。）

`auth_test.dart` 追加：

```dart
  testWidgets('logout button signs out back to LoginPage', (tester) async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1'));
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logoutButton')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

models.dart：文件顶部 `import 'package:cloud_firestore/cloud_firestore.dart';`，两个帮助函数改为：

```dart
DateTime _t(Object? v) {
  if (v == null) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  if (v is Timestamp) return v.toDate().toUtc();
  return DateTime.parse(v as String).toUtc();
}

DateTime? _tOrNull(Object? v) {
  if (v == null) return null;
  if (v is Timestamp) return v.toDate().toUtc();
  return DateTime.parse(v as String).toUtc();
}
```

home_shell.dart：`Scaffold` 加 `appBar: AppBar(title: const Text('理财助手'), actions: [IconButton(key: const Key('logoutButton'), icon: const Icon(Icons.logout), onPressed: () => ref.read(firebaseAuthProvider).signOut())])`——HomeShell 需改为 ConsumerStatefulWidget。

stream_error.dart：

```dart
import 'package:flutter/material.dart';

class StreamError extends StatelessWidget {
  const StreamError({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('加载失败：$error', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ]),
      );
}
```

today_tab（brief 的 error 分支）与 watch_tab（watch 的 error 分支）替换为 `StreamError(error: e, onRetry: () => ref.invalidate(latestBriefProvider))`（各自对应 provider）。

spec §3：suggestions 行补 `reviewedAt?`；briefs 行补 `quotes: {TICKER: {close, pctChange}}`。

- [ ] **Step 4: 测试通过 + 提交**

```bash
git add app docs/superpowers/specs/2026-08-01-wealth-assistant-design.md
git commit -m "feat(app): sign-out, stream retry affordance, timestamp tolerance"
```

---

### Task 9: Web + Android 验收（人工检查点，控制器主持）

**Files:** 无（发现问题按修复提交）

- [ ] **Step 1: 控制器前置——部署新索引**

```bash
firebase deploy --only firestore --project wealth-assistant-5141d
```

等 analyses 索引 READY（复用计划二的轮询脚本）。

- [ ] **Step 2: Web 模式跑通**

```bash
cd app && flutter run -d chrome
```

验收清单（控制器截图自查 + 用户过目）：

1. 浏览器登录 → 4 tab
2. 自选：添加一只股（如 AAPL, manual）→ 列表出现；点「分析」→ jobs 出现 queued 文档（Firestore 控制台确认）；行情列显示日报 quotes（若当日 brief 无 quotes 字段，先手动跑一次 runner 生成新日报）
3. 持仓：改现金、加/改/删一条持仓 → Firestore 数据正确、概览数字正确
4. 今日：construct 一条 pending suggestion（可复用早前深度分析 job 的产物或手工造）→ 忽略/采纳（含录成交）走通，trades 出现关联文档
5. 历史：分析列表 → 详情 13 节渲染；建议归档显示状态
6. 登出 → 回登录页
- [ ] **Step 3: Android 抽查**

模拟器装新版，重复清单 2/4 两项。

- [ ] **Step 4: 记录验收**

```bash
git commit --allow-empty -m "chore(app): web and android acceptance passed for write path"
```

---

## Self-Review 记录

- **Spec 覆盖**：§5 四 tab 全部完成（今日交互 Task 4、自选 Task 5、持仓 Task 6、历史 Task 7）；建议闭环含 trade 关联（§3 trades.suggestionId）✓；手动深度分析写 jobs ✓（不带 date，执行器 ET 兜底——与计划一修正一致）；计划二 backlog 全消化（Task 8）；Web 本地模式为用户新增需求，落在 Task 1。
- **占位符扫描**：Task 6 两个 dialog 与 Task 7 列表实现以「模式 + 规格」给出（模式代码在 Task 4 完整呈现，规格逐字段列明，测试代码完整）——执行者有完整的行为契约与参照实现；其余任务代码完整。无 TBD。
- **类型一致性**：`utcNowIso()`（repo.dart 顶层）与后端 `utc_now_iso()` 格式一致；`TickerQuote`/`Brief.quotes` 在 Task 2 定义、Task 5/6 消费；`resolveSuggestion/addTrade/enqueueDeepAnalysis` 签名在 Task 3 定义、Task 4/5 消费一致；provider 迁移（Task 5）后 today_tab/watch_tab/portfolio_tab 引用同一组 provider。
- **索引**：新增查询中仅 `analysesForTicker`（where+orderBy）需复合索引，已在 Task 3 落文件、Task 9 部署；`recentAnalyses`/`allSuggestions` 单字段 orderBy 走自动索引。
