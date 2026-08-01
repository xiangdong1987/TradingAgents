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
}
