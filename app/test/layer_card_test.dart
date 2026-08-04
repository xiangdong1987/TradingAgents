import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/logic/policy.dart';
import 'package:wealth_assistant/models/models.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/widgets/layer_card.dart';

/// 手机最窄常见宽度（iPhone SE）到 375（iPhone 13 mini）都要不溢出，中英都算。
const widths = [320.0, 375.0];

Future<Widget> _host(String lang, Widget child) async {
  final db = FakeFirebaseFirestore();
  await db.collection('meta').doc('settings').set({'lang': lang});
  return ProviderScope(
    overrides: [firestoreProvider.overrideWithValue(db)],
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, double w, Widget app) async {
  tester.view.physicalSize = Size(w, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

LayerBreakdown _breakdown(PolicyConfig cfg) => LayerBreakdown(
      layers: const [
        LayerStat(layer: layerDefensive, valueEur: 47671, pct: 64.3, band: Band(60, 85)),
        LayerStat(layer: layerCore, valueEur: 3180, pct: 4.3, band: Band(10, 25)),
        LayerStat(layer: layerSatellite, valueEur: 12641, pct: 17.1, band: Band(0, 15)),
      ],
      cashPct: 14.3,
      usdPct: 16.2,
      config: cfg,
    );

void main() {
  for (final lang in ['zh', 'en']) {
    for (final w in widths) {
      testWidgets('layer card fits at ${w.toInt()}px ($lang)', (tester) async {
        await _pumpAt(tester, w,
            await _host(lang, LayerCard(breakdown: _breakdown(const PolicyConfig()))));
        expect(tester.takeException(), isNull);
      });

      // 最长的一行：ISIN 长标的 + 六位成本 + 越界权重 + 层 + 持有到期
      testWidgets('position subtitle fits at ${w.toInt()}px ($lang)', (tester) async {
        await _pumpAt(
            tester,
            w,
            await _host(
                lang,
                PositionSubtitle(
                  position: Position(
                      ticker: 'IT0005696320',
                      shares: 1,
                      avgCost: 45000,
                      updatedAt: DateTime.utc(2026, 8, 1),
                      layer: layerDefensive,
                      holdToMaturity: true),
                  weightPct: 60.7,
                  policy: const PolicyConfig(),
                )));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
