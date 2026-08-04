// app/lib/logic/policy.dart
/// 仓位管理参数与分层判定（客户端只读，用于展示与越界高亮）。
///
/// 真正的闸门在后端 `assistant/policy.py` —— 这里是同一套缺省值的镜像，用来在
/// 没有 `meta/policy` 文档时也能画出分层条。**改阈值请改 Firestore 的
/// `meta/policy`**（两端都读它），代码缺省只是兜底；改缺省要两边一起改。
library;

import '../models/models.dart';
import 'portfolio_math.dart' show isEurListing, isIsin, summarize;

const layerDefensive = 'defensive';
const layerCore = 'core';
const layerSatellite = 'satellite';
const allLayers = [layerDefensive, layerCore, layerSatellite];

/// 目标区间 [下限, 上限]，单位百分比。
class Band {
  const Band(this.lo, this.hi);
  final double lo;
  final double hi;

  bool contains(double pct) => pct >= lo && pct <= hi;
}

class PolicyConfig {
  const PolicyConfig({
    this.cashFloorPct = 5,
    this.maxSingleStockPct = 8,
    this.maxSingleFundPct = 25,
    this.maxSatellitePct = 15,
    this.maxUsdExposurePct = 25,
    this.maxSingleIssuerPct = 40,
    this.bands = const {
      layerDefensive: Band(60, 85),
      layerCore: Band(10, 25),
      layerSatellite: Band(0, 15),
    },
    this.layerMap = const {},
    this.holdToMaturity = const {},
    this.usdLookthrough = const {},
  });

  final double cashFloorPct;
  final double maxSingleStockPct;
  final double maxSingleFundPct;
  final double maxSatellitePct;
  final double maxUsdExposurePct;
  final double maxSingleIssuerPct;
  final Map<String, Band> bands;
  final Map<String, String> layerMap;
  final Set<String> holdToMaturity;
  final Map<String, double> usdLookthrough;

  static double _d(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;

  factory PolicyConfig.fromMap(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return const PolicyConfig();
    const def = PolicyConfig();
    final bands = <String, Band>{...def.bands};
    for (final e in ((m['layers'] as Map?) ?? const {}).entries) {
      final pair = e.value;
      if (pair is List && pair.length >= 2) {
        bands[e.key as String] = Band(_d(pair[0], 0), _d(pair[1], 100));
      }
    }
    return PolicyConfig(
      cashFloorPct: _d(m['cashFloorPct'], def.cashFloorPct),
      maxSingleStockPct: _d(m['maxSingleStockPct'], def.maxSingleStockPct),
      maxSingleFundPct: _d(m['maxSingleFundPct'], def.maxSingleFundPct),
      maxSatellitePct: _d(m['maxSatellitePct'], def.maxSatellitePct),
      maxUsdExposurePct: _d(m['maxUsdExposurePct'], def.maxUsdExposurePct),
      maxSingleIssuerPct: _d(m['maxSingleIssuerPct'], def.maxSingleIssuerPct),
      bands: bands,
      layerMap: {
        for (final e in ((m['layerMap'] as Map?) ?? const {}).entries)
          e.key as String: '${e.value}',
      },
      holdToMaturity: {
        for (final t in ((m['holdToMaturity'] as List?) ?? const [])) '$t',
      },
      usdLookthrough: {
        for (final e in ((m['usdLookthrough'] as Map?) ?? const {}).entries)
          e.key as String: _d(e.value, 0),
      },
    );
  }

  /// 单一标的上限：个股走 stock、其余走 fund。
  double singleCapFor(String layer) =>
      layer == layerSatellite ? maxSingleStockPct : maxSingleFundPct;

  /// 分层判定与后端 `policy.layer_of` 同序：持仓字段 → layerMap → ISIN→防守 → 卫星。
  String layerOf(String ticker, [Position? position]) {
    final own = position?.layer;
    if (own != null && allLayers.contains(own)) return own;
    final mapped = layerMap[ticker];
    if (mapped != null && allLayers.contains(mapped)) return mapped;
    return isIsin(ticker) ? layerDefensive : layerSatellite;
  }

  bool isHoldToMaturity(String ticker, [Position? position]) =>
      position?.holdToMaturity ?? holdToMaturity.contains(ticker);

  /// 底层美元资产占比（%）：欧元计价的美股宽基靠 usdLookthrough 补。
  double usdPctOf(String ticker) =>
      usdLookthrough[ticker] ?? (isEurListing(ticker) ? 0 : 100);
}

/// 一层的实况：占比、目标区间、是否越界。
class LayerStat {
  const LayerStat({
    required this.layer,
    required this.valueEur,
    required this.pct,
    required this.band,
  });
  final String layer;
  final double valueEur;
  final double pct;
  final Band band;

  bool get overCap => pct > band.hi;
  bool get underFloor => pct < band.lo;
  bool get breached => overCap || underFloor;
}

/// 分层实况 + 现金占比 + 美元敞口（经济口径）。权重分母含现金，与总市值同口径。
class LayerBreakdown {
  const LayerBreakdown({
    required this.layers,
    required this.cashPct,
    required this.usdPct,
    required this.config,
  });
  final List<LayerStat> layers;   // 按 allLayers 顺序
  final double cashPct;
  final double usdPct;
  final PolicyConfig config;

  bool get cashBelowFloor => cashPct < config.cashFloorPct;
  bool get usdOverCap => usdPct > config.maxUsdExposurePct;

  LayerStat? statOf(String layer) =>
      layers.where((l) => l.layer == layer).firstOrNull;
}

/// 分层占比。汇率缺失导致某笔无法折算时返回 null（与 [summarize] 同一保守口径）。
LayerBreakdown? layerBreakdown(
  List<Position> positions,
  PortfolioMeta meta,
  Map<String, TickerQuote> quotes,
  PolicyConfig config,
) {
  final s = summarize(positions, meta, quotes);
  final total = s.totalEur;
  if (total == null || total <= 0) return null;

  final rate = quotes['EURUSD=X']?.close;
  double? toEur(String ticker, double native) => isEurListing(ticker)
      ? native
      : ((rate == null || rate == 0) ? null : native / rate);

  final byLayer = <String, double>{for (final l in allLayers) l: 0.0};
  var usdEur = 0.0;
  for (final p in positions) {
    final price = quotes[p.ticker]?.close ?? p.avgCost;
    final v = toEur(p.ticker, p.shares * price);
    if (v == null) return null;
    byLayer[config.layerOf(p.ticker, p)] =
        (byLayer[config.layerOf(p.ticker, p)] ?? 0) + v;
    usdEur += v * config.usdPctOf(p.ticker) / 100;
  }

  return LayerBreakdown(
    layers: [
      for (final l in allLayers)
        LayerStat(
          layer: l,
          valueEur: byLayer[l]!,
          pct: byLayer[l]! / total * 100,
          band: config.bands[l] ?? const Band(0, 100),
        ),
    ],
    cashPct: (s.cashEur ?? 0) / total * 100,
    usdPct: usdEur / total * 100,
    config: config,
  );
}
