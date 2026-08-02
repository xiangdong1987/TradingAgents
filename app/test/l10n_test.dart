// app/test/l10n_test.dart
// L10n zh/en 对齐冒烟：抽代表性 key 断言两个实例都非空且互不相同。
// 不做全量反射——新 key 忘写某一侧时，这里的样本 + analyzer 足以兜住大头。
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/l10n.dart';

void main() {
  test('isZh/code wired correctly', () {
    expect(l10nZh.isZh, isTrue);
    expect(l10nEn.isZh, isFalse);
    expect(l10nZh.code, 'zh');
    expect(l10nEn.code, 'en');
  });

  test('representative keys are non-empty and differ between zh and en', () {
    final samples = <String, (String, String)>{
      'appTitle': (l10nZh.appTitle, l10nEn.appTitle),
      'tabToday': (l10nZh.tabToday, l10nEn.tabToday),
      'secMarket': (l10nZh.secMarket, l10nEn.secMarket),
      'secBull': (l10nZh.secBull, l10nEn.secBull),
      'secResearchManager':
          (l10nZh.secResearchManager, l10nEn.secResearchManager),
      'kpiRating': (l10nZh.kpiRating, l10nEn.kpiRating),
      'keyLevels': (l10nZh.keyLevels, l10nEn.keyLevels),
      'techSignals': (l10nZh.techSignals, l10nEn.techSignals),
      'fundamentalsKey': (l10nZh.fundamentalsKey, l10nEn.fundamentalsKey),
      'analystOriginal': (l10nZh.analystOriginal, l10nEn.analystOriginal),
      'marketOriginal': (l10nZh.marketOriginal, l10nEn.marketOriginal),
      'sentimentOriginal': (l10nZh.sentimentOriginal, l10nEn.sentimentOriginal),
      'historyRatings': (l10nZh.historyRatings, l10nEn.historyRatings),
      'translateSection': (l10nZh.translateSection, l10nEn.translateSection),
      'translationQueued': (l10nZh.translationQueued, l10nEn.translationQueued),
      'fullText': (l10nZh.fullText, l10nEn.fullText),
      'tradePlan': (l10nZh.tradePlan, l10nEn.tradePlan),
      'riskAggressiveShort':
          (l10nZh.riskAggressiveShort, l10nEn.riskAggressiveShort),
    };
    samples.forEach((name, pair) {
      final (zh, en) = pair;
      expect(zh, isNotEmpty, reason: '$name zh 不应为空');
      expect(en, isNotEmpty, reason: '$name en 不应为空');
      expect(zh, isNot(equals(en)), reason: '$name zh/en 不应相同');
    });
  });

  test('parameterized helpers are lang-aware', () {
    expect(l10nZh.decision('Hold'), '决策：Hold');
    expect(l10nEn.decision('Hold'), 'Decision: Hold');
    expect(l10nZh.actionName('sell'), '卖出');
    expect(l10nEn.actionName('sell'), 'Sell');
    expect(l10nZh.actionName('unknown'), 'unknown'); // 认不出原样返回
    expect(l10nZh.confidenceName('Low'), '低');
    expect(l10nEn.confidenceName('Low'), 'Low'); // en 保留引擎原词
    expect(l10nZh.relDaysAgo(3), ' · 3天前');
    expect(l10nEn.relDaysAgo(3), ' · 3d ago');
    expect(l10nZh.riskView(l10nZh.riskAggressiveShort), '激进风控视角');
    expect(l10nEn.riskView(l10nEn.riskAggressiveShort), 'Aggressive risk view');
    expect(l10nZh.debateCount(1, 2, 3), '1 多 · 2 平 · 3 空');
    expect(l10nEn.debateCount(1, 2, 3), '1 bull · 2 flat · 3 bear');
  });
}
