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
