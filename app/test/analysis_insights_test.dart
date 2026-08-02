import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/logic/analysis_insights.dart';

// 片段取自 Firestore 里真实的 ENEL.MI 深度分析文档（2026-07-31）。
const _portfolioDecision = '''
**Rating**: Underweight

**Executive Summary**: 基于技术面短期动能转弱、基本面存在财务脆弱性以及宏观不确定性，建议将ENEL.MI持仓权重下调至基准以下。

**Investment Thesis**: 综合三位风险分析师的辩论证据……

**Time Horizon**: 1-3个月
''';

const _traderPlan = '''
**Action**: Sell

**Reasoning**: 根据分析师报告和投资计划，ENEL.MI面临显著的财务脆弱性。

**Entry Price**: 10.02

**Stop Loss**: 9.68

**Position Sizing**: 将持仓权重降低30-50%至基准以下

FINAL TRANSACTION PROPOSAL: **SELL**
''';

const _sentiment = '''
**Overall Sentiment:** **Neutral** (Score: 5.0/10)
**Confidence:** Low

## ENEL.MI 情绪分析报告（2026-07-24 至 2026-07-31）
''';

const _market = '''
# ENEL.MI（Enel SpA）技术分析报告

### 2.1 移动平均线体系

| 指标 | 当前值 | 与价格关系 | 信号 |
|------|--------|-----------|------|
| **10 EMA** | €9.88 | 价格略低于均线 | 短期偏弱 |
| **50 SMA** | €9.68 | 价格高于均线 (+1.7%) | 中期看涨 |

## 关键指标汇总表

| 指标 | 当前值 | 信号 | 强度 |
|------|--------|------|------|
| 收盘价 | €9.84 | — | — |
| 10日EMA | €9.88 | 价格低于均线 | 偏空 ⚠️ |
| 50日SMA | €9.68 | 价格高于均线 | 偏多 ✅ |
| 200日SMA | €9.11 | 价格远高于均线 | 强多 ✅✅ |
| RSI | 50.68 | 中性区域 | 中性 ➡️ |
| MACD | 0.046 | 低于信号线 | 偏空 ⚠️ |
| 布林上轨 | €10.04 | 强阻力 | — |
| 布林下轨 | €9.75 | 关键支撑 | — |
| ATR | €0.169 | 中等波动 | 中性 ➡️ |

**最终建议：持有（HOLD）**
''';

const _fundamentals = '''
## 二、核心估值指标分析

| 指标 | 数值 | 分析评估 |
|------|------|----------|
| **市值** | 972.38亿欧元 | 欧洲大型公用事业公司 |
| **市盈率（TTM）** | 25.79倍 | 当前估值偏高 |
| **PEG比率** | 0.9 | 低于1，估值具有吸引力 |
| **股息收益率** | 5.31% | 对收益型投资者极具吸引力 |
''';

const _bull = '''

Bull Analyst: 各位好，我是看多分析师。让我们暂时抛开短期波动的迷雾，直面一个核心事实：**ENEL.MI正站在全球能源范式转换的风暴中心**。

### 一、长期趋势坚如磐石

技术分析报告清晰地展示了多头排列。

Bull Analyst: 第二轮补充观点。
''';

void main() {
  group('kvValue', () {
    test('parses **Key**: value form', () {
      expect(kvValue(_portfolioDecision, ['Rating']), 'Underweight');
      expect(kvValue(_traderPlan, ['Entry Price']), '10.02');
      expect(kvValue(_traderPlan, ['Stop Loss']), '9.68');
      expect(kvValue(_portfolioDecision, ['Time Horizon']), '1-3个月');
    });

    test('parses **Key:** value form and strips bold from value', () {
      expect(kvValue(_sentiment, ['Overall Sentiment']),
          'Neutral (Score: 5.0/10)');
      expect(kvValue(_sentiment, ['Confidence']), 'Low');
    });

    test('first matching key wins, missing key returns null', () {
      expect(kvValue(_traderPlan, ['Recommendation', 'Action']), 'Sell');
      expect(kvValue(_traderPlan, ['Nope']), isNull);
    });
  });

  group('ratingIndex', () {
    test('maps the 5 tiers', () {
      expect(ratingIndex('Sell'), 0);
      expect(ratingIndex('Underweight'), 1);
      expect(ratingIndex('Hold'), 2);
      expect(ratingIndex('Overweight'), 3);
      expect(ratingIndex('Buy'), 4);
    });

    test('tolerates markup, case and chinese', () {
      expect(ratingIndex('**SELL**'), 0);
      expect(ratingIndex('买入'), 4);
      expect(ratingIndex('减持'), 1);
      expect(ratingIndex('gibberish'), isNull);
      expect(ratingIndex(''), isNull);
    });

    test('ratingZh labels', () {
      expect(ratingZh(0), '卖出');
      expect(ratingZh(4), '买入');
    });

    test('ratingLabel is lang-aware: zh 中文档位，en 引擎原词', () {
      expect(ratingLabel(1, 'zh'), '减持');
      expect(ratingLabel(1, 'en'), 'Underweight');
      expect(ratingLabel(4, 'zh'), '买入');
      expect(ratingLabel(4, 'en'), 'Buy');
      expect(ratingLabel(9, 'en'), 'Buy'); // clamp
    });
  });

  group('levelLabel', () {
    test('zh keeps canonical key, en maps to english short label', () {
      expect(levelLabel('现价', 'zh'), '现价');
      expect(levelLabel('现价', 'en'), 'Price');
      expect(levelLabel('入场', 'en'), 'Entry');
      expect(levelLabel('止损', 'en'), 'Stop');
      expect(levelLabel('200日线', 'en'), '200D MA');
    });

    test('unknown label falls through unchanged', () {
      expect(levelLabel('自定义', 'en'), '自定义');
      expect(levelLabel('自定义', 'zh'), '自定义');
    });
  });

  test('sentimentScore parses x/10', () {
    expect(sentimentScore(_sentiment), 5.0);
    expect(sentimentScore('no score here'), isNull);
  });

  group('parseMdTables', () {
    test('parses headers and rows', () {
      final tables = parseMdTables(_market);
      expect(tables.length, 2);
      expect(tables.last.headers, ['指标', '当前值', '信号', '强度']);
      expect(tables.last.rows.first, ['收盘价', '€9.84', '—', '—']);
    });

    test('empty input → empty list', () {
      expect(parseMdTables('plain text\nno tables'), isEmpty);
    });
  });

  group('indicatorSignals', () {
    test('extracts signal rows with tones, skipping — rows', () {
      final rows = indicatorSignals(_market);
      final names = rows.map((r) => r.name).toList();
      expect(names, contains('RSI'));
      expect(names, isNot(contains('收盘价'))); // 无信号行不进 chips
      expect(names, isNot(contains('布林上轨')));
      final rsi = rows.firstWhere((r) => r.name == 'RSI');
      expect(rsi.value, '50.68');
      expect(rsi.tone, Tone.neutral);
      expect(rows.firstWhere((r) => r.name == '10日EMA').tone, Tone.bearish);
      expect(rows.firstWhere((r) => r.name == '200日SMA').tone, Tone.bullish);
    });

    test('tone counts for the stacked bar', () {
      final rows = indicatorSignals(_market);
      expect(rows.where((r) => r.tone == Tone.bullish).length, 2);
      expect(rows.where((r) => r.tone == Tone.bearish).length, 2);
      expect(rows.where((r) => r.tone == Tone.neutral).length, 2);
    });
  });

  test('fundamentalMetrics pulls valuation table', () {
    final rows = fundamentalMetrics(_fundamentals);
    expect(rows.first.label, '市值');
    expect(rows.first.value, '972.38亿欧元');
    expect(rows.first.note, '欧洲大型公用事业公司');
    expect(rows.map((r) => r.label), contains('股息收益率'));
  });

  group('priceLevels', () {
    test('collects levels from market table and trader plan', () {
      final levels = priceLevels(market: _market, traderPlan: _traderPlan);
      final byLabel = {for (final l in levels) l.label: l.value};
      expect(byLabel['现价'], 9.84);
      expect(byLabel['200日线'], 9.11);
      expect(byLabel['布林上轨'], 10.04);
      expect(byLabel['入场'], 10.02);
      expect(byLabel['止损'], 9.68);
    });

    test('missing sections → empty', () {
      expect(priceLevels(market: '', traderPlan: ''), isEmpty);
    });
  });

  test('cleanDebate strips analyst prefixes everywhere', () {
    final cleaned = cleanDebate(_bull);
    expect(cleaned, isNot(contains('Bull Analyst:')));
    expect(cleaned, startsWith('各位好'));
    expect(cleaned, contains('第二轮补充观点'));
  });

  test('excerpt strips markdown noise and truncates at sentence', () {
    final e = excerpt(_bull, maxChars: 60);
    expect(e, isNot(contains('**')));
    expect(e, isNot(contains('#')));
    expect(e.length, lessThanOrEqualTo(80));
    expect(e, contains('各位好'));
  });

  test('excerpt skips table/rule lines', () {
    final e = excerpt(_market, maxChars: 80);
    expect(e, isNot(contains('|')));
    expect(e, contains('技术分析报告'));
  });

  test('toneOf keyword mapping', () {
    expect(toneOf('偏多 ✅'), Tone.bullish);
    expect(toneOf('强阻力，看跌'), Tone.bearish);
    expect(toneOf('中性 ➡️'), Tone.neutral);
    expect(toneOf(''), Tone.neutral);
  });
}
