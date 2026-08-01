# Flutter 客户端骨架实施计划（理财助手·计划二）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `app/` 新增 Flutter 工程（Android + macOS 目标），完成 Firebase 接线、邮箱密码登录、Firestore 数据模型与仓储层、四 tab 壳，以及"今日"tab 的只读展示（最新日报 Markdown + pending 建议卡片），Android 端可真机验收。

**Architecture:** Flutter 3.x + Riverpod。`models/` 纯 Dart 解析（可单测），`data/repo.dart` 包一层 Firestore 读写（构造注入 `FirebaseFirestore`，测试用 fake_cloud_firestore），UI 通过 Riverpod provider 消费 stream。登录用 firebase_auth 邮箱密码固定账号，AuthGate 按 authStateChanges 分流。交互写操作（采纳/忽略、增删持仓、手动 job）属计划三。

**Tech Stack:** Flutter 3.x、firebase_core、firebase_auth、cloud_firestore、flutter_riverpod、Markdown 渲染包（见 Task 1 说明）、dev: fake_cloud_firestore、firebase_auth_mocks。

**对应 spec:** `docs/superpowers/specs/2026-08-01-wealth-assistant-design.md` §5（页面）、§3（数据模型）、§6（安全）。

## Global Constraints

- 现有 Python 代码（`tradingagents/`、`assistant/`）与现有 `tests/` **一律不动**；本计划只新增 `app/` 目录（及 .gitignore 追加）
- Firestore 集合与字段名与 spec §3 完全一致（camelCase）；日期字符串一律 `YYYY-MM-DD`，时间戳 UTC ISO-8601 字符串（与 runner 写入格式一致，解析用 `DateTime.parse`）
- 所有 Flutter 测试**不联网**：Firestore 用 `fake_cloud_firestore`，Auth 用 `firebase_auth_mocks`；每个任务结束 `flutter analyze`（0 error/warning）+ `flutter test` 全绿
- **代码块 API 校准原则**：本计划的 Dart 代码为规范实现。若某 API 与实际安装的包版本不符（Firebase 系包演进快），以 `flutter analyze`/编译器为准做最小适配，**行为与测试断言不得改变**；测试断言若引用了不存在的 API 才可同步微调，并在报告中说明
- 包版本：用 `flutter pub add <pkg>` 取当前最新稳定版，不手写版本号（pubspec 由命令生成）
- 提交信息 conventional commits；每个任务一个 commit
- Flutter 命令一律在 `app/` 目录下执行

## 依赖与前置

- 计划一已合入分支：Firestore 已有 `watchlist/positions/meta/briefs/analyses/suggestions/jobs` 集合与安全规则（OWNER_UID 锁）
- Firebase 项目已存在，Authentication 已启用邮箱/密码并建好唯一用户（计划一部署时完成）
- **本机需要**：Flutter SDK（`flutter doctor` Android 工具链 + macOS desktop 可用）、Firebase CLI（`npm i -g firebase-tools`）、FlutterFire CLI（`dart pub global activate flutterfire_cli`）。Task 0 先验环境，缺什么向用户报告

---

### Task 0: 环境预检（无提交）

**Files:** 无

**Interfaces:**
- Produces: 环境结论，决定 Task 1/2 能否推进

- [ ] **Step 1: 检查工具链**

```bash
flutter --version && flutter doctor
firebase --version || echo "MISSING: firebase-tools"
flutterfire --version || echo "MISSING: flutterfire_cli"
```

- [ ] **Step 2: 判定**

`flutter doctor` 需要 Android toolchain ✓（macOS desktop 缺失可接受，macOS 验收挪到计划三）。firebase/flutterfire 缺失时**报告 BLOCKED**，把安装命令给用户（安装需要用户环境变量/权限，不要擅自全局安装）：

```bash
npm install -g firebase-tools
dart pub global activate flutterfire_cli
```

---

### Task 1: Flutter 工程创建与依赖

**Files:**
- Create: `app/`（`flutter create` 生成）
- Modify: `app/pubspec.yaml`（依赖追加，经 `flutter pub add`）
- Modify: `.gitignore`（仓库根，追加 Flutter 构建产物段）
- Delete: `app/test/widget_test.dart`（模板测试，Task 3 起有真测试）

**Interfaces:**
- Produces: 可编译的空工程；后续所有任务的宿主

- [ ] **Step 1: 创建工程（仓库根目录执行）**

```bash
flutter create app --platforms=android,macos --org com.wealthassistant --project-name wealth_assistant
```

- [ ] **Step 2: 添加依赖（app/ 下执行）**

```bash
flutter pub add firebase_core firebase_auth cloud_firestore flutter_riverpod intl
flutter pub add dev:fake_cloud_firestore dev:firebase_auth_mocks
```

Markdown 渲染包按此优先级选第一个在 pub.dev 上可用且非 discontinued 的：`flutter_markdown_plus` → `markdown_widget` → `flutter_markdown`。执行 `flutter pub add <选中的包>`，并在报告里说明选了哪个。后续代码里的 `MarkdownBody(data: ...)` 调用点若所选包 API 不同，按其 README 等价替换（渲染一段 Markdown 字符串）。

- [ ] **Step 3: 删除模板测试，写编译占位 main**

`app/test/widget_test.dart` 删除。`app/lib/main.dart` 替换为：

```dart
import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('wealth assistant')))));
}
```

- [ ] **Step 4: 仓库根 .gitignore 追加**

```
# Flutter (app/)
app/.dart_tool/
app/build/
app/.flutter-plugins*
app/android/.gradle/
app/android/local.properties
app/macos/Pods/
```

- [ ] **Step 5: 验证 + 提交**

```bash
cd app && flutter analyze && flutter test || true   # 此时无测试，analyze 必须 0 issue
git add -A app ../.gitignore 2>/dev/null || git add -A app .gitignore
git commit -m "feat(app): scaffold Flutter project for wealth assistant client"
```

（`flutter test` 在无测试文件时报 "No tests were found"，属预期，不算失败。）

---

### Task 2: FlutterFire 接线（需用户在场）

**Files:**
- Create: `app/lib/firebase_options.dart`（flutterfire 生成）
- Modify: `app/android/app/build.gradle.kts`（minSdk）
- Modify: `app/macos/Runner/DebugProfile.entitlements`、`app/macos/Runner/Release.entitlements`（网络权限）
- Modify: `app/lib/main.dart`（Firebase.initializeApp）

**Interfaces:**
- Consumes: 用户的 Firebase 项目（计划一建好）
- Produces: `DefaultFirebaseOptions.currentPlatform`，Task 5+ 的 main.dart 依赖它

- [ ] **Step 1: 登录并生成配置（交互式，告知用户配合浏览器授权）**

```bash
firebase login          # 打开浏览器，用户授权
cd app && flutterfire configure --platforms=android,macos
```

选中用户的 Firebase 项目。生成 `lib/firebase_options.dart`（含 API key——这是客户端公开配置，可入库，安全性由 Firestore 规则保证，不是私钥）。

- [ ] **Step 2: Android minSdk 提升**

`app/android/app/build.gradle.kts` 里 `minSdk = flutter.minSdkVersion` 改为 `minSdk = 23`（firebase_auth 要求 ≥23）。

- [ ] **Step 3: macOS 网络 entitlements**

两个 entitlements 文件的 `<dict>` 内确保包含：

```xml
<key>com.apple.security.network.client</key>
<true/>
```

- [ ] **Step 4: main.dart 初始化 Firebase**

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('wealth assistant')))));
}
```

- [ ] **Step 5: 验证 + 提交**

```bash
cd app && flutter analyze && flutter build apk --debug
git add -A ../app && git commit -m "feat(app): wire FlutterFire config for android and macos"
```

（`flutter build apk --debug` 失败于 Android SDK 缺组件时，把 doctor 输出报给控制器，不要自行改 gradle 仓库源。）

---

### Task 3: 数据模型（纯 Dart + 单测）

**Files:**
- Create: `app/lib/models/models.dart`
- Test: `app/test/models_test.dart`

**Interfaces:**
- Consumes: spec §3 字段
- Produces: `WatchItem, Position, PortfolioMeta, Brief, Analysis, Suggestion, Job`，全部 `fromDoc(String id, Map<String, dynamic> data)` 工厂 + 可选 `toMap()`（仅写路径需要的：本计划无写路径，toMap 只给 Position/WatchItem 备用不实现，遵守 YAGNI——**不写 toMap**）

- [ ] **Step 1: 写失败测试**

```dart
// app/test/models_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/models/models.dart';

void main() {
  test('Brief parses required fields and keeps doc id as date', () {
    final b = Brief.fromDoc('2026-08-01', {
      'date': '2026-08-01',
      'markdownZh': '# 日报',
      'tickers': ['NVDA', 'AAPL'],
      'createdAt': '2026-08-01T10:47:17+00:00',
    });
    expect(b.date, '2026-08-01');
    expect(b.markdownZh, '# 日报');
    expect(b.tickers, ['NVDA', 'AAPL']);
    expect(b.createdAt.isUtc, isTrue);
  });

  test('Suggestion parses with nullable targetWeightPct and outcomePct', () {
    final s = Suggestion.fromDoc('s1', {
      'ticker': 'NVDA',
      'action': 'trim',
      'rationale': '估值过高',
      'analysisId': 'a1',
      'status': 'pending',
      'createdAt': '2026-08-01T00:00:00+00:00',
    });
    expect(s.id, 's1');
    expect(s.targetWeightPct, isNull);
    expect(s.outcomePct, isNull);
    expect(s.isPending, isTrue);
  });

  test('Suggestion targetWeightPct accepts int and double from Firestore', () {
    final a = Suggestion.fromDoc('s1', _sug(target: 15));
    final b = Suggestion.fromDoc('s2', _sug(target: 12.5));
    expect(a.targetWeightPct, 15.0);
    expect(b.targetWeightPct, 12.5);
  });

  test('Position parses numbers robustly', () {
    final p = Position.fromDoc('NVDA', {
      'ticker': 'NVDA', 'shares': 10, 'avgCost': 150, 'updatedAt': '2026-08-01T00:00:00+00:00',
    });
    expect(p.shares, 10.0);
    expect(p.avgCost, 150.0);
  });

  test('Job exposes status helpers and optional fields', () {
    final j = Job.fromDoc('j1', {
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'failed',
      'requestedBy': 'user', 'error': 'boom', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    expect(j.isFailed, isTrue);
    expect(j.error, 'boom');
    expect(j.analysisId, isNull);
  });

  test('Analysis parses sections map with missing keys as empty', () {
    final a = Analysis.fromDoc('a1', {
      'ticker': 'NVDA', 'tradeDate': '2026-08-01', 'decision': 'BUY',
      'sections': {'market': 'm'}, 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    expect(a.sections['market'], 'm');
    expect(a.section('bull'), '');
  });

  test('WatchItem and PortfolioMeta parse with defaults', () {
    final w = WatchItem.fromDoc('NVDA', {'ticker': 'NVDA', 'deepFreq': 'weekly'});
    expect(w.note, '');
    final m = PortfolioMeta.fromMap({'cash': 5000, 'currency': 'USD'});
    expect(m.cash, 5000.0);
    final empty = PortfolioMeta.fromMap(null);
    expect(empty.cash, 0.0);
    expect(empty.currency, 'USD');
  });
}

Map<String, dynamic> _sug({Object? target}) => {
      'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a1',
      'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
      if (target != null) 'targetWeightPct': target,
    };
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd app && flutter test test/models_test.dart`
Expected: 编译失败（models.dart 不存在）

- [ ] **Step 3: 实现**

```dart
// app/lib/models/models.dart
/// Firestore document models. Field names mirror spec §3 (camelCase).
/// All numbers arrive as int OR double from Firestore — parse via _d().
library;

double _d(Object? v, [double fallback = 0]) =>
    v == null ? fallback : (v as num).toDouble();

double? _dOrNull(Object? v) => v == null ? null : (v as num).toDouble();

String _s(Object? v, [String fallback = '']) => (v as String?) ?? fallback;

DateTime _t(Object? v) =>
    v == null ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true) : DateTime.parse(v as String).toUtc();

class WatchItem {
  const WatchItem({required this.ticker, required this.note, required this.deepFreq, required this.addedAt});
  final String ticker;
  final String note;
  final String deepFreq; // "weekly" | "manual"
  final DateTime addedAt;

  factory WatchItem.fromDoc(String id, Map<String, dynamic> d) => WatchItem(
        ticker: _s(d['ticker'], id),
        note: _s(d['note']),
        deepFreq: _s(d['deepFreq'], 'manual'),
        addedAt: _t(d['addedAt']),
      );
}

class Position {
  const Position({required this.ticker, required this.shares, required this.avgCost, required this.updatedAt});
  final String ticker;
  final double shares;
  final double avgCost;
  final DateTime updatedAt;

  factory Position.fromDoc(String id, Map<String, dynamic> d) => Position(
        ticker: _s(d['ticker'], id),
        shares: _d(d['shares']),
        avgCost: _d(d['avgCost']),
        updatedAt: _t(d['updatedAt']),
      );
}

class PortfolioMeta {
  const PortfolioMeta({required this.cash, required this.currency});
  final double cash;
  final String currency;

  factory PortfolioMeta.fromMap(Map<String, dynamic>? d) =>
      PortfolioMeta(cash: _d(d?['cash']), currency: _s(d?['currency'], 'USD'));
}

class Brief {
  const Brief({required this.date, required this.markdownZh, required this.tickers, required this.createdAt});
  final String date; // doc id, YYYY-MM-DD
  final String markdownZh;
  final List<String> tickers;
  final DateTime createdAt;

  factory Brief.fromDoc(String id, Map<String, dynamic> d) => Brief(
        date: _s(d['date'], id),
        markdownZh: _s(d['markdownZh']),
        tickers: List<String>.from(d['tickers'] as List? ?? const []),
        createdAt: _t(d['createdAt']),
      );
}

class Analysis {
  const Analysis({required this.id, required this.ticker, required this.tradeDate,
      required this.decision, required this.sections, required this.createdAt});
  final String id;
  final String ticker;
  final String tradeDate;
  final String decision;
  final Map<String, String> sections;
  final DateTime createdAt;

  String section(String key) => sections[key] ?? '';

  factory Analysis.fromDoc(String id, Map<String, dynamic> d) => Analysis(
        id: id,
        ticker: _s(d['ticker']),
        tradeDate: _s(d['tradeDate']),
        decision: _s(d['decision']),
        sections: Map<String, String>.from(
            (d['sections'] as Map? ?? const {}).map((k, v) => MapEntry(k as String, (v as String?) ?? ''))),
        createdAt: _t(d['createdAt']),
      );
}

class Suggestion {
  const Suggestion({required this.id, required this.ticker, required this.action,
      required this.targetWeightPct, required this.rationale, required this.analysisId,
      required this.status, required this.createdAt, required this.outcomePct});
  final String id;
  final String ticker;
  final String action; // buy|add|trim|sell|hold
  final double? targetWeightPct;
  final String rationale;
  final String analysisId;
  final String status; // pending|accepted|dismissed
  final DateTime createdAt;
  final double? outcomePct;

  bool get isPending => status == 'pending';

  factory Suggestion.fromDoc(String id, Map<String, dynamic> d) => Suggestion(
        id: id,
        ticker: _s(d['ticker']),
        action: _s(d['action']),
        targetWeightPct: _dOrNull(d['targetWeightPct']),
        rationale: _s(d['rationale']),
        analysisId: _s(d['analysisId']),
        status: _s(d['status'], 'pending'),
        createdAt: _t(d['createdAt']),
        outcomePct: _dOrNull(d['outcomePct']),
      );
}

class Job {
  const Job({required this.id, required this.type, required this.ticker, required this.status,
      required this.requestedBy, required this.error, required this.analysisId, required this.createdAt});
  final String id;
  final String type; // daily_brief|deep_analysis
  final String? ticker;
  final String status; // queued|running|done|failed
  final String requestedBy;
  final String? error;
  final String? analysisId;
  final DateTime createdAt;

  bool get isFailed => status == 'failed';
  bool get isActive => status == 'queued' || status == 'running';

  factory Job.fromDoc(String id, Map<String, dynamic> d) => Job(
        id: id,
        type: _s(d['type']),
        ticker: d['ticker'] as String?,
        status: _s(d['status']),
        requestedBy: _s(d['requestedBy']),
        error: d['error'] as String?,
        analysisId: d['analysisId'] as String?,
        createdAt: _t(d['createdAt']),
      );
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd app && flutter test test/models_test.dart` → 7 个测试全绿；`flutter analyze` 0 issue

- [ ] **Step 5: 提交**

```bash
git add app/lib/models/models.dart app/test/models_test.dart
git commit -m "feat(app): add Firestore document models with robust parsing"
```

---

### Task 4: 仓储层 WealthRepo（fake_cloud_firestore 测试）

**Files:**
- Create: `app/lib/data/repo.dart`
- Test: `app/test/repo_test.dart`

**Interfaces:**
- Consumes: Task 3 模型
- Produces（本计划只读方法；写方法属计划三，不实现）：

```dart
class WealthRepo {
  WealthRepo(FirebaseFirestore db);
  Stream<Brief?> latestBrief();                 // briefs 按 doc id 降序取 1
  Stream<List<Suggestion>> pendingSuggestions();// status==pending, createdAt 降序
  Stream<List<WatchItem>> watchlist();          // ticker 升序
  Stream<List<Position>> positions();           // ticker 升序
  Stream<PortfolioMeta> portfolioMeta();        // meta/portfolio，缺文档给默认
  Stream<List<Job>> activeJobs();               // status in [queued, running]
}
```

- [ ] **Step 1: 写失败测试**

```dart
// app/test/repo_test.dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/data/repo.dart';

void main() {
  late FakeFirebaseFirestore db;
  late WealthRepo repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = WealthRepo(db);
  });

  test('latestBrief returns newest by doc id and null when empty', () async {
    expect(await repo.latestBrief().first, isNull);
    await db.collection('briefs').doc('2026-07-31').set({
      'date': '2026-07-31', 'markdownZh': 'old', 'tickers': [], 'createdAt': '2026-07-31T21:00:00+00:00',
    });
    await db.collection('briefs').doc('2026-08-01').set({
      'date': '2026-08-01', 'markdownZh': 'new', 'tickers': ['NVDA'], 'createdAt': '2026-08-01T21:00:00+00:00',
    });
    final b = await repo.latestBrief().first;
    expect(b!.date, '2026-08-01');
    expect(b.markdownZh, 'new');
  });

  test('pendingSuggestions filters status and sorts newest first', () async {
    await db.collection('suggestions').add({
      'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r1', 'analysisId': 'a1',
      'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await db.collection('suggestions').add({
      'ticker': 'AAPL', 'action': 'buy', 'rationale': 'r2', 'analysisId': 'a2',
      'status': 'accepted', 'createdAt': '2026-08-02T00:00:00+00:00',
    });
    await db.collection('suggestions').add({
      'ticker': 'MSFT', 'action': 'add', 'rationale': 'r3', 'analysisId': 'a3',
      'status': 'pending', 'createdAt': '2026-08-03T00:00:00+00:00',
    });
    final list = await repo.pendingSuggestions().first;
    expect(list.map((s) => s.ticker), ['MSFT', 'NVDA']);
  });

  test('portfolioMeta defaults when doc missing', () async {
    final m = await repo.portfolioMeta().first;
    expect(m.cash, 0.0);
    expect(m.currency, 'USD');
  });

  test('activeJobs includes queued and running only', () async {
    for (final (status, ticker) in [('queued', 'A'), ('running', 'B'), ('done', 'C'), ('failed', 'D')]) {
      await db.collection('jobs').add({
        'type': 'deep_analysis', 'ticker': ticker, 'status': status,
        'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
      });
    }
    final jobs = await repo.activeJobs().first;
    expect(jobs.map((j) => j.ticker).toSet(), {'A', 'B'});
  });

  test('watchlist and positions sort by ticker', () async {
    await db.collection('watchlist').doc('NVDA').set({'ticker': 'NVDA', 'deepFreq': 'weekly'});
    await db.collection('watchlist').doc('AAPL').set({'ticker': 'AAPL', 'deepFreq': 'manual'});
    await db.collection('positions').doc('NVDA').set({'ticker': 'NVDA', 'shares': 10, 'avgCost': 150});
    expect((await repo.watchlist().first).map((w) => w.ticker), ['AAPL', 'NVDA']);
    expect((await repo.positions().first).single.avgCost, 150.0);
  });
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败（repo.dart 不存在）

- [ ] **Step 3: 实现**

```dart
// app/lib/data/repo.dart
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';

/// Read-side repository over Firestore. Write operations land in plan 3.
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
}
```

注意：`pendingSuggestions` 的 where+orderBy 组合在真 Firestore 需要复合索引（首次触发时控制台报错含一键建索引链接）——在 `app/lib/data/repo.dart` 顶部 doc comment 注明，并加入 Task 7 验收清单。

- [ ] **Step 4: 跑测试确认通过** → `cd app && flutter test test/repo_test.dart` 5 绿；`flutter analyze` 0 issue

- [ ] **Step 5: 提交**

```bash
git add app/lib/data/repo.dart app/test/repo_test.dart
git commit -m "feat(app): add read-side Firestore repository with streams"
```

---

### Task 5: Riverpod providers + 登录页 + AuthGate

**Files:**
- Create: `app/lib/providers.dart`
- Create: `app/lib/ui/login_page.dart`
- Create: `app/lib/ui/auth_gate.dart`
- Modify: `app/lib/main.dart`
- Test: `app/test/auth_test.dart`

**Interfaces:**
- Consumes: Task 4 `WealthRepo`
- Produces:

```dart
// providers.dart
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);
final repoProvider = Provider<WealthRepo>((ref) => WealthRepo(ref.watch(firestoreProvider)));
final authStateProvider = StreamProvider<User?>((ref) => ref.watch(firebaseAuthProvider).authStateChanges());
```

- [ ] **Step 1: 写失败测试**

```dart
// app/test/auth_test.dart
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/auth_gate.dart';
import 'package:wealth_assistant/ui/login_page.dart';

Widget _app(MockFirebaseAuth auth, FakeFirebaseFirestore db) => ProviderScope(
      overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
        firestoreProvider.overrideWithValue(db),
      ],
      child: const MaterialApp(home: AuthGate()),
    );

void main() {
  testWidgets('signed out shows LoginPage', (tester) async {
    final auth = MockFirebaseAuth(signedIn: false);
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('signed in shows home shell scaffold with 4 tabs', (tester) async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1', email: 'me@x.com'));
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('自选'), findsOneWidget);
    expect(find.text('持仓'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
  });

  testWidgets('login form signs in via FirebaseAuth', (tester) async {
    final auth = MockFirebaseAuth(signedIn: false);
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'me@x.com');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.tap(find.byKey(const Key('signInButton')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsNothing);  // MockFirebaseAuth 登录成功切换到主壳
  });
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败

- [ ] **Step 3: 实现**

```dart
// app/lib/providers.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/repo.dart';

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);
final repoProvider = Provider<WealthRepo>((ref) => WealthRepo(ref.watch(firestoreProvider)));
final authStateProvider = StreamProvider<User?>((ref) => ref.watch(firebaseAuthProvider).authStateChanges());
```

```dart
// app/lib/ui/auth_gate.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'home_shell.dart';
import 'login_page.dart';

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(authStateProvider).when(
          data: (user) => user == null ? const LoginPage() : const HomeShell(),
          loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (e, _) => Scaffold(body: Center(child: Text('认证出错: $e'))),
        );
  }
}
```

```dart
// app/lib/ui/login_page.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(firebaseAuthProvider).signInWithEmailAndPassword(
            email: _email.text.trim(), password: _password.text);
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? '登录失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('理财助手', textAlign: TextAlign.center, style: TextStyle(fontSize: 24)),
                const SizedBox(height: 24),
                TextField(key: const Key('email'), controller: _email,
                    decoration: const InputDecoration(labelText: '邮箱'),
                    keyboardType: TextInputType.emailAddress),
                const SizedBox(height: 12),
                TextField(key: const Key('password'), controller: _password,
                    decoration: const InputDecoration(labelText: '密码'), obscureText: true),
                const SizedBox(height: 24),
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.red))),
                FilledButton(
                  key: const Key('signInButton'),
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

`app/lib/ui/home_shell.dart` 此任务先给最小壳（Task 6 完善），让测试可过：

```dart
// app/lib/ui/home_shell.dart
import 'package:flutter/material.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = [
    Center(child: Text('今日（建设中）')),
    Center(child: Text('自选（建设中）')),
    Center(child: Text('持仓（建设中）')),
    Center(child: Text('历史（建设中）')),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabs[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.star_outline), label: '自选'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: '持仓'),
          NavigationDestination(icon: Icon(Icons.history), label: '历史'),
        ],
      ),
    );
  }
}
```

`app/lib/main.dart` 换成：

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'ui/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ProviderScope(
    child: MaterialApp(title: '理财助手', home: AuthGate()),
  ));
}
```

- [ ] **Step 4: 跑测试确认通过** → `cd app && flutter test` 全绿；`flutter analyze` 0 issue

- [ ] **Step 5: 提交**

```bash
git add app/lib app/test/auth_test.dart
git commit -m "feat(app): add auth gate, login page, and riverpod providers"
```

---

### Task 6: 今日 tab（最新日报 + pending 建议只读卡片）

**Files:**
- Create: `app/lib/ui/today_tab.dart`
- Create: `app/lib/ui/widgets/suggestion_card.dart`
- Modify: `app/lib/ui/home_shell.dart`（第 0 个 tab 换成 TodayTab）
- Test: `app/test/today_tab_test.dart`

**Interfaces:**
- Consumes: `repoProvider`（latestBrief / pendingSuggestions / activeJobs）
- Produces: `TodayTab`、`SuggestionCard`（只读版；[采纳][忽略] 按钮渲染但 onPressed 为 null + 提示"计划三启用"——按钮位先占好，交互属计划三）

- [ ] **Step 1: 写失败测试**

```dart
// app/test/today_tab_test.dart
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

void main() {
  testWidgets('empty state renders hint when no brief exists', (tester) async {
    await tester.pumpWidget(_wrap(FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有日报'), findsOneWidget);
  });

  testWidgets('renders latest brief markdown and pending suggestion cards', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('briefs').doc('2026-08-01').set({
      'date': '2026-08-01', 'markdownZh': '# 投资日报\nNVDA 上涨', 'tickers': ['NVDA'],
      'createdAt': '2026-08-01T21:00:00+00:00',
    });
    await db.collection('suggestions').add({
      'ticker': 'NVDA', 'action': 'trim', 'targetWeightPct': 15,
      'rationale': '估值过高，建议减仓', 'analysisId': 'a1',
      'status': 'pending', 'createdAt': '2026-08-01T22:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('投资日报'), findsOneWidget);   // markdown 渲染
    expect(find.text('NVDA · TRIM'), findsOneWidget);          // 卡片标题
    expect(find.textContaining('估值过高'), findsOneWidget);
    expect(find.textContaining('15'), findsOneWidget);          // 目标仓位
  });

  testWidgets('running job shows status banner', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('jobs').add({
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'running',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('NVDA'), findsWidgets);
    expect(find.textContaining('分析中'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败** → 编译失败

- [ ] **Step 3: 实现**

```dart
// app/lib/ui/widgets/suggestion_card.dart
import 'package:flutter/material.dart';

import '../../models/models.dart';

class SuggestionCard extends StatelessWidget {
  const SuggestionCard({super.key, required this.suggestion});
  final Suggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.ticker} · ${s.action.toUpperCase()}',
                style: Theme.of(context).textTheme.titleMedium),
            if (s.targetWeightPct != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('目标仓位 ${s.targetWeightPct!.toStringAsFixed(1)}%'),
              ),
            const SizedBox(height: 8),
            Text(s.rationale),
            const SizedBox(height: 8),
            Row(
              children: [
                // 占位按钮：写路径在计划三接通
                OutlinedButton(onPressed: null, child: const Text('采纳')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: null, child: const Text('忽略')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

```dart
// app/lib/ui/today_tab.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Markdown 渲染 import 按 Task 1 选定的包调整：
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/models.dart';
import '../providers.dart';
import 'widgets/suggestion_card.dart';

final latestBriefProvider = StreamProvider<Brief?>((ref) => ref.watch(repoProvider).latestBrief());
final pendingSuggestionsProvider =
    StreamProvider<List<Suggestion>>((ref) => ref.watch(repoProvider).pendingSuggestions());
final activeJobsProvider = StreamProvider<List<Job>>((ref) => ref.watch(repoProvider).activeJobs());

class TodayTab extends ConsumerWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brief = ref.watch(latestBriefProvider);
    final suggestions = ref.watch(pendingSuggestionsProvider);
    final jobs = ref.watch(activeJobsProvider);

    return ListView(
      children: [
        for (final job in jobs.valueOrNull ?? const <Job>[])
          MaterialBanner(
            content: Text(job.type == 'deep_analysis'
                ? '${job.ticker} 深度分析中（${job.status == "queued" ? "排队" : "分析中"}）'
                : '日报生成中'),
            leading: const SizedBox(
                height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            actions: const [SizedBox.shrink()],
          ),
        brief.when(
          data: (b) => b == null
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('还没有日报。runner 会在交易日收盘后生成第一份。',
                      textAlign: TextAlign.center),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.date, style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      MarkdownBody(data: b.markdownZh),
                    ],
                  ),
                ),
          loading: () => const Padding(
              padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('日报加载失败: $e')),
        ),
        ...switch (suggestions) {
          AsyncData(:final value) when value.isNotEmpty => [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('待处理建议', style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final s in value) SuggestionCard(suggestion: s),
            ],
          _ => const <Widget>[],
        },
        const SizedBox(height: 24),
      ],
    );
  }
}
```

`home_shell.dart`：`_tabs` 第 0 项换成 `TodayTab()`（import 并把 `_tabs` 从 `static const` 改为 `final`，因 TodayTab 非 const 上下文时按 analyzer 提示处理）。

- [ ] **Step 4: 跑测试确认通过** → `cd app && flutter test` 全绿；`flutter analyze` 0 issue

- [ ] **Step 5: 提交**

```bash
git add app/lib app/test/today_tab_test.dart
git commit -m "feat(app): render latest brief and pending suggestions in today tab"
```

---

### Task 7: Android 真机验收（人工检查点，需用户在场）

**Files:** 无新文件（发现问题按修复提交）

- [ ] **Step 1: 起模拟器或连真机跑**

```bash
cd app && flutter devices && flutter run -d <android-device-id>
```

- [ ] **Step 2: 人工验收清单（和用户一起过）**

1. 登录页出现 → 用 Firebase 控制台建的邮箱/密码登录成功
2. 今日 tab 显示冒烟测试生成的 `briefs/2026-08-01` 日报（中文 Markdown 渲染正常）
3. Firestore 控制台手工把一条 suggestion 的 status 改为 `pending` → App 几秒内出现建议卡片（实时监听生效）
4. 首次打开若控制台/日志报 Firestore 复合索引错误（pendingSuggestions 的 where+orderBy）→ 按报错里的链接一键建索引，等索引就绪后重试
5. 断网 → App 显示缓存数据不崩溃；恢复网络自动刷新

- [ ] **Step 3: 记录验收结果**

问题按修复提交（`fix(app): ...`）；全过后提交验收说明：

```bash
git commit --allow-empty -m "chore(app): android smoke acceptance passed"
```

---

## Self-Review 记录

- **Spec 覆盖**：§5 四 tab 中"今日"本计划完成只读版；自选/持仓/历史的壳已就位、内容与全部写操作（采纳/忽略、增删持仓、手动 job、录 trade）明确划入计划三；§6 安全（email/密码登录 + UID 规则）落在 Task 2/5；§7 测试策略（model 序列化 + 关键 widget 测试）落在 Task 3-6。
- **已知 spec 缺口（计划三要解决，此处记录不实现）**：自选/持仓 tab 需要"现价/涨跌"，但 brief 文档目前只有 markdownZh 没有结构化行情数据——计划三需给 runner 的 brief 文档加 `quotes: {ticker: {close, pctChange}}` 字段（改 `assistant/daily_brief.py` + 测试）。
- **占位符扫描**：无 TBD；Markdown 包名带选择规则（pub.dev 现状执行时才可知，规则明确非占位）；所有代码步骤有完整代码。
- **类型一致性**：`WealthRepo` 六个方法签名与 Task 5/6 provider 用法一致；模型工厂 `fromDoc(String id, Map)` 全体一致；测试断言引用的 Key（email/password/signInButton）与实现一致；`firestoreProvider`/`firebaseAuthProvider` override 点与测试一致。
