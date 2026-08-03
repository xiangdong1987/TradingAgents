import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/logic/tax.dart';

void main() {
  group('defaultIncomeTaxPct', () {
    test('italian listings pay only the 26% substitute tax', () {
      expect(defaultIncomeTaxPct('ENEL.MI'), taxPctIt);
      expect(defaultIncomeTaxPct('IT0005696320'), 26.0);
    });
    test('US dividends stack 15% withholding with the italian 26%', () {
      // 1 − 0.85 × 0.74 = 37.1%
      expect(defaultIncomeTaxPct('MSFT'), 37.1);
      expect(taxPctUsTotal, 37.1);
      expect(taxPctUsWithholding, 15.0);
    });
  });

  group('defaultSellTax', () {
    test('gains are taxed at 26%', () {
      expect(defaultSellTax(100), closeTo(26, 0.001));
    });
    test('losses are not taxed', () {
      expect(defaultSellTax(-100), 0);
      expect(defaultSellTax(0), 0);
    });
  });
}
