// app/test/models_test.dart
import 'package:cloud_firestore/cloud_firestore.dart';
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
    expect(s.resolvedAt, isNull);
    expect(s.reviewedAt, isNull);
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
      'finishedAt': '2026-08-01T10:47:17+00:00',
    });
    expect(j.isFailed, isTrue);
    expect(j.error, 'boom');
    expect(j.analysisId, isNull);
    expect(j.finishedAt, isNotNull);
    expect(j.finishedAt!.isUtc, isTrue);
  });

  test('Job finishedAt is nullable', () {
    final j = Job.fromDoc('j1', {
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'queued',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    expect(j.finishedAt, isNull);
  });

  test('Suggestion parses resolvedAt and reviewedAt as nullable UTC DateTimes', () {
    final s = Suggestion.fromDoc('s1', {
      'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a1',
      'status': 'accepted', 'createdAt': '2026-08-01T00:00:00+00:00',
      'reviewedAt': '2026-08-01T10:47:17+00:00',
      'resolvedAt': '2026-08-01T11:00:00+00:00',
    });
    expect(s.reviewedAt, isNotNull);
    expect(s.reviewedAt!.isUtc, isTrue);
    expect(s.resolvedAt, isNotNull);
    expect(s.resolvedAt!.isUtc, isTrue);
  });

  test('Analysis parses sections map with missing keys as empty', () {
    final a = Analysis.fromDoc('a1', {
      'ticker': 'NVDA', 'tradeDate': '2026-08-01', 'decision': 'BUY',
      'sections': {'market': 'm'}, 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    expect(a.sections['market'], 'm');
    expect(a.section('bull'), '');
  });

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

  test('_t and _tOrNull tolerate Firestore Timestamp values', () {
    final ts = Timestamp.fromDate(DateTime.utc(2026, 8, 1, 10));
    final j = Job.fromDoc('j', {
      'type': 'daily_brief', 'status': 'done', 'requestedBy': 'user',
      'createdAt': ts, 'finishedAt': ts,
    });
    expect(j.createdAt, DateTime.utc(2026, 8, 1, 10));
    expect(j.finishedAt, DateTime.utc(2026, 8, 1, 10));
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

Map<String, dynamic> _sug({Object? target}) {
  final map = <String, dynamic>{
    'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a1',
    'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
  };
  if (target != null) {
    map['targetWeightPct'] = target;
  }
  return map;
}
