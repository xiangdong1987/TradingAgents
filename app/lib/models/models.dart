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
  const Position({required this.ticker, required this.shares, required this.avgCost,
      required this.updatedAt, this.openedAt, this.layer, this.holdToMaturity});
  final String ticker;
  final double shares;
  final double avgCost;
  final DateTime updatedAt;
  /// 建仓日（YYYY-MM-DD，可选）。分红只从这天起算——runner 用它当下限。
  final String? openedAt;
  /// 仓位分层（defensive|core|satellite）。为空时由 PolicyConfig 推断。
  final String? layer;
  /// 持有到期（BTP 之类）。影响 riskBase=liquid 的分母。
  final bool? holdToMaturity;

  factory Position.fromDoc(String id, Map<String, dynamic> d) => Position(
        ticker: _s(d['ticker'], id),
        shares: _d(d['shares']),
        avgCost: _d(d['avgCost']),
        updatedAt: _t(d['updatedAt']),
        openedAt: d['openedAt'] as String?,
        layer: d['layer'] as String?,
        holdToMaturity: d['holdToMaturity'] as bool?,
      );
}

/// 一笔成交。`realizedPnl` 只有卖出才有，按卖出当时的持仓成本算，
/// 单位是**标的计价货币**（US=USD、.MI=EUR）——汇总时才折 EUR。
class Trade {
  const Trade({required this.id, required this.ticker, required this.side,
      required this.shares, required this.price, required this.date,
      this.realizedPnl, this.taxAmount, this.avgCostAtTrade, this.suggestionId});
  final String id;
  final String ticker;
  final String side; // buy | sell
  final double shares;
  final double price;
  final String date; // YYYY-MM-DD
  final double? realizedPnl;
  final double? taxAmount;      // 卖出的资本利得税（原币，亏损为 0）
  final double? avgCostAtTrade;
  final String? suggestionId;

  bool get isSell => side == 'sell';
  double get amount => shares * price;

  /// 税后已实现盈亏（原币）。没有税额记录时等于税前。
  double? get realizedNet =>
      realizedPnl == null ? null : realizedPnl! - (taxAmount ?? 0);

  factory Trade.fromDoc(String id, Map<String, dynamic> d) => Trade(
        id: id,
        ticker: _s(d['ticker']),
        side: _s(d['side'], 'buy'),
        shares: _d(d['shares']),
        price: _d(d['price']),
        date: _s(d['date']),
        realizedPnl: _dOrNull(d['realizedPnl']),
        taxAmount: _dOrNull(d['taxAmount']),
        avgCostAtTrade: _dOrNull(d['avgCostAtTrade']),
        suggestionId: d['suggestionId'] as String?,
      );
}

/// 一笔分红 / 债券利息。金额单位是**标的计价货币**（US=USD、.MI 与 IT-ISIN=EUR）。
/// `source`: auto = runner 按 yfinance 每股分红 × 当前持股估算（税前毛额）；
/// manual = 用户按券商实际到账手录（ISIN 单券付息只能走这条）。
class Income {
  const Income({required this.id, required this.ticker, required this.date,
      required this.amount, this.taxAmount = 0, this.taxPct,
      this.perShare, this.shares, this.source = 'manual',
      this.creditedCash = false, this.note});
  final String id;
  final String ticker;
  final String date; // YYYY-MM-DD
  final double amount;          // 税前毛额
  final double taxAmount;       // 预扣税（原币）
  final double? taxPct;
  final double? perShare;
  final double? shares;
  final String source;
  final bool creditedCash;      // 入账时是否已加进现金（手录默认加，自动不加）
  final String? note;

  bool get isAuto => source == 'auto';

  /// 税后到手金额（原币）。
  double get net => amount - taxAmount;

  factory Income.fromDoc(String id, Map<String, dynamic> d) => Income(
        id: id,
        ticker: _s(d['ticker']),
        date: _s(d['date']),
        amount: _d(d['amount']),
        taxAmount: _d(d['taxAmount']),
        taxPct: _dOrNull(d['taxPct']),
        perShare: _dOrNull(d['perShare']),
        shares: _dOrNull(d['shares']),
        source: _s(d['source'], 'manual'),
        creditedCash: d['creditedCash'] == true,
        note: d['note'] as String?,
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
  const Brief({required this.date, required this.markdownZh, this.markdownEn = '',
      required this.tickers, required this.createdAt, required this.quotes});
  final String date; // doc id, YYYY-MM-DD
  final String markdownZh;
  final String markdownEn;
  final List<String> tickers;
  final DateTime createdAt;
  final Map<String, TickerQuote> quotes;

  /// 目标语言缺失时兜底另一语言，永不空白（旧文档无 markdownEn）。
  String markdownFor(String lang) => lang == 'en'
      ? (markdownEn.isNotEmpty ? markdownEn : markdownZh)
      : (markdownZh.isNotEmpty ? markdownZh : markdownEn);

  factory Brief.fromDoc(String id, Map<String, dynamic> d) => Brief(
        date: _s(d['date'], id),
        markdownZh: _s(d['markdownZh']),
        markdownEn: _s(d['markdownEn']),
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
      required this.decision, required this.sections, this.sectionsZh = const {},
      required this.createdAt});
  final String id;
  final String ticker;
  final String tradeDate;
  final String decision;
  final Map<String, String> sections;     // 引擎英文原文
  final Map<String, String> sectionsZh;   // translate job 按需写入的中文译文
  final DateTime createdAt;

  String section(String key) => sections[key] ?? '';

  /// zh 模式优先译文，没有译文回落英文原文；en 模式恒为原文。
  String sectionFor(String key, String lang) {
    if (lang == 'zh' && (sectionsZh[key] ?? '').isNotEmpty) return sectionsZh[key]!;
    return sections[key] ?? '';
  }

  static final _cjk = RegExp(r'[一-鿿]');

  /// zh 模式下该段是否还缺译文（用于显示「翻译此段」按钮）。
  /// 原文本身已是中文的历史分析不需要翻译。
  bool needsTranslation(String key, String lang) {
    if (lang != 'zh') return false;
    final src = sections[key] ?? '';
    if (src.isEmpty || (sectionsZh[key] ?? '').isNotEmpty) return false;
    final sample = src.length > 400 ? src.substring(0, 400) : src;
    return _cjk.allMatches(sample).length < 20;
  }

  static Map<String, String> _strMap(Object? m) => Map<String, String>.from(
      (m as Map? ?? const {}).map((k, v) => MapEntry(k as String, (v as String?) ?? '')));

  factory Analysis.fromDoc(String id, Map<String, dynamic> d) => Analysis(
        id: id,
        ticker: _s(d['ticker']),
        tradeDate: _s(d['tradeDate']),
        decision: _s(d['decision']),
        sections: _strMap(d['sections']),
        sectionsZh: _strMap(d['sectionsZh']),
        createdAt: _t(d['createdAt']),
      );
}

class Suggestion {
  const Suggestion({required this.id, required this.ticker, required this.action,
      required this.targetWeightPct, required this.rationale, this.rationaleEn = '',
      required this.analysisId,
      required this.status, required this.createdAt, required this.outcomePct,
      required this.resolvedAt, required this.reviewedAt, this.source = '',
      this.meta = const {}});
  final String id;
  final String ticker;
  final String action; // buy|add|trim|sell|hold
  final double? targetWeightPct;
  final String rationale;
  final String rationaleEn;
  final String analysisId;
  final String status; // pending|accepted|dismissed
  final DateTime createdAt;
  final double? outcomePct;
  final DateTime? resolvedAt;
  final DateTime? reviewedAt;
  final String source; // '' = 深度分析引擎；策略名（如 turtle）= 规则策略产出
  /// 执行细节与 Policy 判定：shares/stop/entry/n/trigger/system、
  /// blocked+blockedBy+fundingCandidates、clampedFrom+clampedBy、targetClampedFrom。
  final Map<String, dynamic> meta;

  double? get shares => _dOrNull(meta['shares']);
  double? get stop => _dOrNull(meta['stop']);
  bool get isBlocked => meta['blocked'] == true;
  String? get blockedBy => meta['blockedBy'] as String?;
  double? get clampedFrom => _dOrNull(meta['clampedFrom']);
  String? get clampedBy => meta['clampedBy'] as String?;
  List<String> get fundingCandidates => [
        for (final c in (meta['fundingCandidates'] as List? ?? const [])) '$c',
      ];

  bool get isPending => status == 'pending';

  /// 目标语言缺失时兜底另一语言（旧建议无 rationaleEn）。
  String rationaleFor(String lang) => lang == 'en'
      ? (rationaleEn.isNotEmpty ? rationaleEn : rationale)
      : (rationale.isNotEmpty ? rationale : rationaleEn);

  /// 策略来源；空串（引擎建议）返回 null 表示不显示 chip。展示名由 UI 层 l10n 决定。
  String? get sourceLabel => switch (source) {
        '' => null,
        _ => source,
      };

  factory Suggestion.fromDoc(String id, Map<String, dynamic> d) => Suggestion(
        id: id,
        ticker: _s(d['ticker']),
        action: _s(d['action']),
        targetWeightPct: _dOrNull(d['targetWeightPct']),
        rationale: _s(d['rationale']),
        rationaleEn: _s(d['rationaleEn']),
        analysisId: _s(d['analysisId']),
        status: _s(d['status'], 'pending'),
        createdAt: _t(d['createdAt']),
        outcomePct: _dOrNull(d['outcomePct']),
        resolvedAt: _tOrNull(d['resolvedAt']),
        reviewedAt: _tOrNull(d['reviewedAt']),
        source: _s(d['source']),
        meta: Map<String, dynamic>.from((d['meta'] as Map?) ?? const {}),
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
      this.answerEn, required this.status, required this.createdAt});
  final String id;
  final String question;
  final String? answer;
  final String? answerEn;
  final String status; // pending | answered | failed
  final DateTime createdAt;

  /// 目标语言缺失时兜底另一语言（旧回答无 answerEn）。
  String? answerFor(String lang) => lang == 'en'
      ? ((answerEn ?? '').isNotEmpty ? answerEn : answer)
      : ((answer ?? '').isNotEmpty ? answer : answerEn);

  factory ChatMessage.fromDoc(String id, Map<String, dynamic> d) => ChatMessage(
      id: id,
      question: _s(d['question']),
      answer: d['answer'] as String?,
      answerEn: d['answerEn'] as String?,
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

