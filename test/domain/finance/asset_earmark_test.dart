import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('AssetEarmark Domain Invariant Tests', () {
    final now = DateTime(2026, 10, 3, 15, 0);

    test('Valid earmarks across multiple goals and accounts', () {
      final earmark1 = AssetEarmark(
        id: 'emk_1',
        goalId: 'goal_car',
        assetAccountId: 'ast_bank_hdfc',
        earmarkedAmount: Money.fromRupees(50000),
        createdAt: now,
        updatedAt: now,
      );

      final earmark2 = AssetEarmark(
        id: 'emk_2',
        goalId: 'goal_vacation',
        assetAccountId: 'ast_bank_hdfc',
        earmarkedAmount: Money.fromRupees(20000),
        createdAt: now,
        updatedAt: now,
      );

      final earmark3 = AssetEarmark(
        id: 'emk_3',
        goalId: 'goal_emergency',
        assetAccountId: 'ast_bank_sbi',
        earmarkedAmount: Money.fromRupees(100000),
        createdAt: now,
        updatedAt: now,
      );

      expect(earmark1.goalId, 'goal_car');
      expect(earmark2.goalId, 'goal_vacation');
      expect(earmark3.assetAccountId, 'ast_bank_sbi');
      expect(earmark1.earmarkedAmount, Money.fromRupees(50000));
    });

    test('Zero amount earmark is rejected at construction', () {
      expect(
        () => AssetEarmark(
          id: 'emk_zero',
          goalId: 'goal_car',
          assetAccountId: 'ast_bank',
          earmarkedAmount: Money.zero,
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Negative amount earmark is rejected at construction', () {
      expect(
        () => AssetEarmark(
          id: 'emk_neg',
          goalId: 'goal_car',
          assetAccountId: 'ast_bank',
          earmarkedAmount: Money.fromRupees(-1000),
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Empty goalId or assetAccountId is rejected', () {
      expect(
        () => AssetEarmark(
          id: 'emk_bad',
          goalId: '',
          assetAccountId: 'ast_bank',
          earmarkedAmount: Money.fromRupees(100),
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );

      expect(
        () => AssetEarmark(
          id: 'emk_bad',
          goalId: 'goal_1',
          assetAccountId: '  ',
          earmarkedAmount: Money.fromRupees(100),
          createdAt: now,
          updatedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('Earmark does NOT create ledger postings (Architectural Invariant)', () {
      final earmark = AssetEarmark(
        id: 'emk_pure',
        goalId: 'goal_home',
        assetAccountId: 'ast_bank',
        earmarkedAmount: Money.fromRupees(500000),
        createdAt: now,
        updatedAt: now,
      );

      // Verifying that an AssetEarmark entity has no posting relationships
      expect(earmark, isNot(isA<EconomicEvent>()));
      expect(earmark, isNot(isA<Posting>()));
    });
  });
}
