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

  test('acceptWithTrade writes the trade and flips suggestion status in one batch', () async {
    final ref = await db.collection('suggestions').add({
      'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a',
      'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await repo.acceptWithTrade(
        suggestionId: ref.id, ticker: 'NVDA', side: 'sell', shares: 3, price: 200.5,
        date: '2026-08-01');
    final trades = (await db.collection('trades').get()).docs;
    expect(trades.single.data(), {
      'ticker': 'NVDA', 'side': 'sell', 'shares': 3.0, 'price': 200.5,
      'date': '2026-08-01', 'suggestionId': ref.id,
    });
    final suggestion = (await db.collection('suggestions').doc(ref.id).get()).data()!;
    expect(suggestion['status'], 'accepted');
    expect(suggestion['resolvedAt'], endsWith('+00:00'));
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


  test('enqueueQuotesRefresh writes a refresh_quotes user job', () async {
    final jid = await repo.enqueueQuotesRefresh();
    final doc = (await db.collection('jobs').doc(jid).get()).data()!;
    expect(doc['type'], 'refresh_quotes');
    expect(doc['status'], 'queued');
    expect(doc['requestedBy'], 'user');
    expect(doc['createdAt'], endsWith('+00:00'));
  });

  test('setPosition auto-adds ticker to watchlist, preserving existing', () async {
    await repo.setPosition(ticker: 'ENEL.MI', shares: 100, avgCost: 9.0);
    final watch = (await db.collection('watchlist').doc('ENEL.MI').get()).data()!;
    expect(watch['deepFreq'], 'manual');                 // 新建默认 manual

    await db.collection('watchlist').doc('NVDA').set({
      'ticker': 'NVDA', 'note': '', 'deepFreq': 'weekly', 'addedAt': 'x'});
    await repo.setPosition(ticker: 'NVDA', shares: 10, avgCost: 150);
    final kept = (await db.collection('watchlist').doc('NVDA').get()).data()!;
    expect(kept['deepFreq'], 'weekly');                  // 已有的不被覆盖
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

  group('applyTrade', () {
    Future<void> seed({double shares = 100, double avgCost = 10, double cash = 5000}) async {
      await db.collection('positions').doc('ENEL.MI').set({
        'ticker': 'ENEL.MI', 'shares': shares, 'avgCost': avgCost,
        'updatedAt': '2026-08-01T00:00:00+00:00',
      });
      await db.collection('meta').doc('portfolio').set({'cash': cash, 'currency': 'EUR'});
    }

    test('buy adds shares, re-weights cost and debits cash', () async {
      await seed();  // 100 股 @ €10
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'buy', shares: 100,
          price: 12, date: '2026-08-03');
      final pos = (await db.collection('positions').doc('ENEL.MI').get()).data()!;
      expect(pos['shares'], 200);
      expect(pos['avgCost'], 11);            // (100*10 + 100*12) / 200
      final cash = (await db.collection('meta').doc('portfolio').get()).data()!['cash'];
      expect(cash, 5000 - 1200);
      final tr = (await db.collection('trades').get()).docs.single.data();
      expect(tr['side'], 'buy');
      expect(tr['realizedPnl'], isNull);     // 买入不产生已实现盈亏
    });

    test('buy of a new ticker also joins the watchlist', () async {
      await db.collection('meta').doc('portfolio').set({'cash': 5000, 'currency': 'EUR'});
      await repo.applyTrade(ticker: 'KO', side: 'buy', shares: 10,
          price: 80, date: '2026-08-03');
      expect((await db.collection('watchlist').doc('KO').get()).exists, isTrue);
      expect((await db.collection('positions').doc('KO').get()).data()!['avgCost'], 80);
    });

    test('partial sell keeps cost, credits cash and records realized pnl', () async {
      await seed();  // 100 股 @ €10
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'sell', shares: 40,
          price: 15, date: '2026-08-03');
      final pos = (await db.collection('positions').doc('ENEL.MI').get()).data()!;
      expect(pos['shares'], 60);
      expect(pos['avgCost'], 10);            // 成本价不因卖出改变
      final cash = (await db.collection('meta').doc('portfolio').get()).data()!['cash'];
      expect(cash, 5000 + 600);
      final tr = (await db.collection('trades').get()).docs.single.data();
      expect(tr['realizedPnl'], 200);        // (15-10) * 40
      expect(tr['avgCostAtTrade'], 10);
    });

    test('selling everything deletes the position', () async {
      await seed();
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'sell', shares: 100,
          price: 15, date: '2026-08-03');
      expect((await db.collection('positions').doc('ENEL.MI').get()).exists, isFalse);
      final cash = (await db.collection('meta').doc('portfolio').get()).data()!['cash'];
      expect(cash, 5000 + 1500);
    });

    test('selling more than held is clamped to the held quantity', () async {
      await seed(shares: 30);
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'sell', shares: 999,
          price: 15, date: '2026-08-03');
      final tr = (await db.collection('trades').get()).docs.single.data();
      expect(tr['shares'], 30);              // 不会写出负股数
      expect(tr['realizedPnl'], 150);        // (15-10) * 30
      expect((await db.collection('positions').doc('ENEL.MI').get()).exists, isFalse);
    });

    test('a sell with no position is a no-op', () async {
      await db.collection('meta').doc('portfolio').set({'cash': 5000, 'currency': 'EUR'});
      await repo.applyTrade(ticker: 'NOPE', side: 'sell', shares: 10,
          price: 15, date: '2026-08-03');
      expect((await db.collection('trades').get()).docs, isEmpty);
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 5000);
    });

    test('suggestionId flips the suggestion to accepted', () async {
      await seed();
      final sug = await db.collection('suggestions').add({
        'ticker': 'ENEL.MI', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a',
        'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
      });
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'sell', shares: 10,
          price: 15, date: '2026-08-03', suggestionId: sug.id);
      expect((await db.collection('suggestions').doc(sug.id).get()).data()!['status'],
          'accepted');
      expect((await db.collection('trades').get()).docs.single.data()['suggestionId'],
          sug.id);
    });

    test('trades stream returns newest first', () async {
      await seed();
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'sell', shares: 1,
          price: 11, date: '2026-08-01');
      await repo.applyTrade(ticker: 'ENEL.MI', side: 'sell', shares: 1,
          price: 12, date: '2026-08-03');
      final list = await repo.trades().first;
      expect(list.map((t) => t.date), ['2026-08-03', '2026-08-01']);
      expect(list.first.isSell, isTrue);
      expect(list.first.amount, 12);
    });
  });

  group('addIncome', () {
    test('records income and credits cash by default', () async {
      await db.collection('meta').doc('portfolio').set({'cash': 100.0, 'currency': 'EUR'});
      await repo.addIncome(ticker: 'IT0005696320', amount: 450.0,
          date: '2026-08-01', note: '半年付息');
      final row = (await db.collection('income').get()).docs.single.data();
      expect(row['ticker'], 'IT0005696320');
      expect(row['amount'], 450.0);
      expect(row['source'], 'manual');
      expect(row['note'], '半年付息');
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 550.0);
    });

    test('creditCash false leaves cash alone', () async {
      await db.collection('meta').doc('portfolio').set({'cash': 100.0, 'currency': 'EUR'});
      await repo.addIncome(ticker: 'KO', amount: 5.0, date: '2026-08-01',
          creditCash: false);
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 100.0);
      expect((await db.collection('income').get()).docs, hasLength(1));
    });

    test('income stream returns newest first', () async {
      await repo.addIncome(ticker: 'KO', amount: 1, date: '2026-07-01', creditCash: false);
      await repo.addIncome(ticker: 'KO', amount: 2, date: '2026-08-01', creditCash: false);
      final list = await repo.income().first;
      expect(list.map((i) => i.date), ['2026-08-01', '2026-07-01']);
      expect(list.first.isAuto, isFalse);
    });
  });
}
