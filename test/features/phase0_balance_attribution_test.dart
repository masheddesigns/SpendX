import 'package:flutter_test/flutter_test.dart';

import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/services/balance_attribution.dart';
import 'package:spend_x/services/sms_import_service.dart';

BankAccount _account({
  required String id,
  required String name,
  required String bank,
  String type = 'savings',
  String? last4,
}) =>
    BankAccount(
      id: id,
      name: name,
      bank: bank,
      accountType: type,
      last4: last4,
      balance: 0,
    );

CreditCard _card({
  required String id,
  required String name,
  required String bank,
  required String last4,
}) =>
    CreditCard(
      id: id,
      name: name,
      bank: bank,
      last4: last4,
      limitAmount: 100000,
    );

void main() {
  group('Phase 0 balance attribution', () {
    test('bank balance is never routed to the only credit card (HDFC case)',
        () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.bank,
        last4: '1234',
        bankKeyword: 'hdfc',
        accounts: const [],
        cards: [
          _card(id: 'card_hdfc', name: 'HDFC Regalia', bank: 'HDFC', last4: '1234'),
        ],
      );

      expect(result.matched, isFalse,
          reason: 'bank SMS must not mutate a credit card balance');
      expect(result.isCreditCard, isFalse);
      expect(result.ambiguous, isFalse);
      expect(result.canCreate, isTrue,
          reason: 'last4 + issuer is sufficient evidence for a bank account');
    });

    test('a lone account is not matched without identity evidence', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.bank,
        last4: null,
        bankKeyword: null,
        accounts: [
          _account(id: 'acc_1', name: 'Some Savings', bank: 'Some Bank'),
        ],
        cards: const [],
      );

      expect(result.matched, isFalse);
      expect(result.ambiguous, isFalse);
      expect(result.canCreate, isFalse);
    });

    test('a lone card is not matched without issuer or last4', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: null,
        accounts: const [],
        cards: [
          _card(id: 'card_1', name: 'Only Card', bank: 'ICICI', last4: '9999'),
        ],
      );

      expect(result.matched, isFalse);
      expect(result.canCreate, isFalse);
    });

    test('issuer + last4 matches a bank account', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.bank,
        last4: '8434',
        bankKeyword: 'fed',
        accounts: [
          _account(
            id: 'acc_fed',
            name: 'Federal Bank Account (..8434)',
            bank: 'Federal Bank',
            last4: '8434',
          ),
        ],
        cards: const [],
      );

      expect(result.matched, isTrue);
      expect(result.instrumentId, 'acc_fed');
      expect(result.isCreditCard, isFalse);
    });

    test('multiple cards for one issuer are ambiguous, not first-match', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'icici',
        accounts: const [],
        cards: [
          _card(id: 'card_a', name: 'ICICI Amazon', bank: 'ICICI', last4: '1111'),
          _card(id: 'card_b', name: 'ICICI Coral', bank: 'ICICI', last4: '2222'),
        ],
      );

      expect(result.matched, isFalse);
      expect(result.ambiguous, isTrue);
      expect(result.candidateIds, containsAll(['card_a', 'card_b']));
    });

    test('last4 owned by a different issuer is ambiguous', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.bank,
        last4: '1234',
        bankKeyword: 'hdfc',
        accounts: [
          _account(
            id: 'acc_icici',
            name: 'ICICI Account',
            bank: 'ICICI',
            last4: '1234',
          ),
        ],
        cards: const [],
      );

      expect(result.matched, isFalse);
      expect(result.ambiguous, isTrue);
    });

    test('wallet statements match an issuer account stored as savings', () {
      // Jio Payments Bank accounts are sometimes stored as savings and
      // sometimes as wallet. Both are assets, so an issuer match is safe.
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.wallet,
        last4: null,
        bankKeyword: 'jio',
        accounts: [
          _account(
            id: 'acc_jio',
            name: 'Jio Payments Bank Account (..3284)',
            bank: 'Jio Payments Bank',
            last4: '3284',
          ),
        ],
        cards: const [],
      );

      expect(result.matched, isTrue);
      expect(result.instrumentId, 'acc_jio');
      expect(result.isCreditCard, isFalse);
    });

    test('bank statements can resolve a wallet-typed account by last4', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.bank,
        last4: '3284',
        bankKeyword: 'jio',
        accounts: [
          _account(
            id: 'wallet_jio',
            name: 'Jio Wallet',
            bank: 'Jio Payments Bank',
            type: 'wallet',
            last4: '3284',
          ),
        ],
        cards: const [],
      );

      expect(result.matched, isTrue);
      expect(result.instrumentId, 'wallet_jio');
    });

    test('a wallet statement never matches a credit card', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.bank,
        last4: '1234',
        bankKeyword: 'hdfc',
        accounts: const [],
        cards: [
          _card(id: 'card_hdfc', name: 'HDFC Card', bank: 'HDFC', last4: '1234'),
        ],
      );

      expect(result.matched, isFalse);
      expect(result.isCreditCard, isFalse);
    });

    test('wallet statement without identity does not match the only account',
        () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.wallet,
        last4: null,
        bankKeyword: null,
        accounts: [
          _account(
            id: 'wallet_only',
            name: 'Some Wallet',
            bank: 'Some Bank',
            type: 'wallet',
            last4: '3284',
          ),
        ],
        cards: const [],
      );

      expect(result.matched, isFalse);
      expect(result.ambiguous, isFalse);
      expect(result.canCreate, isFalse);
    });

    test('wallet statements match a wallet account for the issuer', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.wallet,
        last4: null,
        bankKeyword: 'jio',
        accounts: [
          _account(
            id: 'wallet_jio',
            name: 'Jio Wallet',
            bank: 'Jio Payments Bank',
            type: 'wallet',
            last4: '3284',
          ),
        ],
        cards: const [],
      );

      expect(result.matched, isTrue);
      expect(result.instrumentId, 'wallet_jio');
    });

    test('card last4 + matching issuer resolves the correct card', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: '5555',
        bankKeyword: 'axis',
        accounts: const [],
        cards: [
          _card(id: 'card_hdfc', name: 'HDFC Card', bank: 'HDFC', last4: '5555'),
          _card(id: 'card_axis', name: 'Axis Card', bank: 'Axis', last4: '5555'),
        ],
      );

      expect(result.matched, isTrue);
      expect(result.instrumentId, 'card_axis');
    });

    test('no-evidence credit-card statement cannot create an instrument', () {
      final result = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: '0000',
        bankKeyword: null,
        accounts: const [],
        cards: const [],
      );

      expect(result.matched, isFalse);
      expect(result.canCreate, isFalse,
          reason: '0000 ghost cards must never be created');
    });
  });
}
