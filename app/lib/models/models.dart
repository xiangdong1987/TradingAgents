// app/lib/models/models.dart
/// Firestore document models. Field names mirror spec §3 (camelCase).
/// All numbers arrive as int OR double from Firestore — parse via _d().
library;

import 'package:cloud_firestore/cloud_firestore.dart';

double _d(Object? v, [double fallback = 0]) =>
    v == null ? fallback : (v as num).toDouble();

double? _dOrNull(Object? v) => v == null ? null : (v as num).toDouble();

String _s(Object? v, [String fallback = '']) => (v as String?) ?? fallback;

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

class TickerQuote {
  const TickerQuote({required this.close, required this.pctChange});
  final double close;
  final double pctChange;

  factory TickerQuote.fromMap(Map<String, dynamic> d) =>
      TickerQuote(close: _d(d['close']), pctChange: _d(d['pctChange']));
}

class Brief {
  const Brief({required this.date, required this.markdownZh, required this.tickers, required this.createdAt,
      required this.quotes});
  final String date; // doc id, YYYY-MM-DD
  final String markdownZh;
  final List<String> tickers;
  final DateTime createdAt;
  final Map<String, TickerQuote> quotes;

  factory Brief.fromDoc(String id, Map<String, dynamic> d) => Brief(
        date: _s(d['date'], id),
        markdownZh: _s(d['markdownZh']),
        tickers: List<String>.from(d['tickers'] as List? ?? const []),
        createdAt: _t(d['createdAt']),
        quotes: {
          for (final e in ((d['quotes'] as Map?) ?? const {}).entries)
            e.key as String:
                TickerQuote.fromMap(Map<String, dynamic>.from(e.value as Map)),
        },
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
      required this.status, required this.createdAt, required this.outcomePct,
      required this.resolvedAt, required this.reviewedAt, this.source = ''});
  final String id;
  final String ticker;
  final String action; // buy|add|trim|sell|hold
  final double? targetWeightPct;
  final String rationale;
  final String analysisId;
  final String status; // pending|accepted|dismissed
  final DateTime createdAt;
  final double? outcomePct;
  final DateTime? resolvedAt;
  final DateTime? reviewedAt;
  final String source; // '' = 深度分析引擎；策略名（如 turtle）= 规则策略产出

  bool get isPending => status == 'pending';

  /// 策略来源的展示名；空串（引擎建议）返回 null 表示不显示 chip。
  String? get sourceLabel => switch (source) {
        '' => null,
        'turtle' => '🐢 海龟',
        _ => source,
      };

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
        resolvedAt: _tOrNull(d['resolvedAt']),
        reviewedAt: _tOrNull(d['reviewedAt']),
        source: _s(d['source']),
      );
}

class Job {
  const Job({required this.id, required this.type, required this.ticker, required this.status,
      required this.requestedBy, required this.error, required this.analysisId, required this.createdAt,
      required this.finishedAt, this.startedAt});
  final String id;
  final String type; // daily_brief|deep_analysis
  final String? ticker;
  final String status; // queued|running|done|failed
  final String requestedBy;
  final String? error;
  final String? analysisId;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

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
        startedAt: _tOrNull(d['startedAt']),
        finishedAt: _tOrNull(d['finishedAt']),
      );
}

class CalendarEvent {
  const CalendarEvent({required this.ticker, required this.type, required this.date});
  final String ticker;
  final String type; // earnings | exDividend | dividendPay
  final String date; // YYYY-MM-DD

  String get typeLabel => switch (type) {
        'earnings' => '财报',
        'exDividend' => '除息',
        'dividendPay' => '派息',
        _ => type,
      };

  factory CalendarEvent.fromMap(Map<String, dynamic> d) => CalendarEvent(
      ticker: _s(d['ticker']), type: _s(d['type']), date: _s(d['date']));
}

class ChatMessage {
  const ChatMessage({required this.id, required this.question, this.answer,
      required this.status, required this.createdAt});
  final String id;
  final String question;
  final String? answer;
  final String status; // pending | answered | failed
  final DateTime createdAt;

  factory ChatMessage.fromDoc(String id, Map<String, dynamic> d) => ChatMessage(
      id: id,
      question: _s(d['question']),
      answer: d['answer'] as String?,
      status: _s(d['status'], 'pending'),
      createdAt: _t(d['createdAt']));
}

class RunnerStatus {
  const RunnerStatus({required this.lastSeenAt, required this.mode,
      required this.intervalSeconds});
  final DateTime? lastSeenAt;
  final String mode; // watch | once
  final int intervalSeconds;

  /// 在线判定：最后心跳距今 < max(2×间隔, 5 分钟)。
  bool aliveAt(DateTime now) {
    if (lastSeenAt == null) return false;
    final grace = Duration(
        seconds: intervalSeconds > 0 ? intervalSeconds * 2 + 60 : 300);
    return now.toUtc().difference(lastSeenAt!) < grace;
  }

  factory RunnerStatus.fromMap(Map<String, dynamic>? d) => RunnerStatus(
      lastSeenAt: _tOrNull(d?['lastSeenAt']),
      mode: _s(d?['mode'], 'once'),
      intervalSeconds: (d?['intervalSeconds'] as num?)?.toInt() ?? 0);
}

