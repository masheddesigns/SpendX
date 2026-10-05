import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('CanonicalEventRepository Tests', () {
    late Database db;
    late CanonicalEventRepository repo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await TablesV24.createAllV24(db);
      await TablesV24.installTriggers(db);
      await TablesV24.seedSystemAccounts(db);

      // Create test accounts
      final now = DateTime.now().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_bank',
        'account_type': 'asset',
        'subtype': 'bank',
        'name': 'HDFC Bank',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_groceries',
        'account_type': 'expense',
        'subtype': 'groceries',
        'name': 'Groceries',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_salary',
        'account_type': 'income',
        'subtype': 'salary',
        'name': 'Salary',
        'created_at': now,
        'updated_at': now,
      });

      repo = CanonicalEventRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('Draft -> Posted lifecycle succeeds when balanced', () async {
      final now = DateTime.now();
      final event = EconomicEvent(
        id: 'evt_1',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: now,
        description: 'Supermarket shopping',
        metadata: const {'notes': 'Weekly veggies'},
        createdAt: now,
      );

      final postings = [
        Posting(
          id: 'post_1',
          economicEventId: 'evt_1',
          accountId: 'acc_groceries',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(250000), // ₹2500.00
          createdAt: now,
        ),
        Posting(
          id: 'post_2',
          economicEventId: 'evt_1',
          accountId: 'acc_bank',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(250000),
          createdAt: now,
        ),
      ];

      // 1. Create draft
      await repo.createDraftEvent(event, postings: postings);
      final draft = await repo.getEvent('evt_1');
      expect(draft, isNotNull);
      expect(draft!.lifecycleStatus, EventLifecycle.draft);

      // 2. Post draft
      await repo.postEvent('evt_1');
      final posted = await repo.getEvent('evt_1');
      expect(posted!.lifecycleStatus, EventLifecycle.posted);
    });

    test('postEvent rejects unbalanced draft with AccountingInvariantException', () async {
      final now = DateTime.now();
      final event = EconomicEvent(
        id: 'evt_unbalanced',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: now,
        description: 'Unbalanced purchase',
        createdAt: now,
      );

      final postings = [
        Posting(
          id: 'post_u1',
          economicEventId: 'evt_unbalanced',
          accountId: 'acc_groceries',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(50000),
          createdAt: now,
        ),
        Posting(
          id: 'post_u2',
          economicEventId: 'evt_unbalanced',
          accountId: 'acc_bank',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(40000), // Unbalanced by 10000
          createdAt: now,
        ),
      ];

      await repo.createDraftEvent(event, postings: postings);

      expect(
        () => repo.postEvent('evt_unbalanced'),
        throwsA(isA<AccountingInvariantException>()),
      );

      final draft = await repo.getEvent('evt_unbalanced');
      expect(draft!.lifecycleStatus, EventLifecycle.draft);
    });

    test('createAndPostEvent commits atomically and rolls back on failure', () async {
      final now = DateTime.now();
      final goodPostings = [
        Posting(
          id: 'post_ag1',
          economicEventId: 'evt_atomic_good',
          accountId: 'acc_bank',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(10000000), // ₹1,00,000.00
          createdAt: now,
        ),
        Posting(
          id: 'post_ag2',
          economicEventId: 'evt_atomic_good',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(10000000),
          createdAt: now,
        ),
      ];

      final event = EconomicEvent(
        id: 'evt_atomic_good',
        canonicalType: CanonicalEventType.income,
        lifecycleStatus: EventLifecycle.posted,
        occurredAt: now,
        description: 'Monthly Salary',
        postings: goodPostings,
        createdAt: now,
      );

      await repo.createAndPostEvent(event, postings: goodPostings);
      final saved = await repo.getEvent('evt_atomic_good');
      expect(saved, isNotNull);
      expect(saved!.lifecycleStatus, EventLifecycle.posted);

      // Now attempt invalid atomic post (only 1 posting)
      final badPostings = [
        Posting(
          id: 'post_bad1',
          economicEventId: 'evt_atomic_bad',
          accountId: 'acc_bank',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(1000),
          createdAt: now,
        ),
      ];

      final badEvent = EconomicEvent(
        id: 'evt_atomic_bad',
        canonicalType: CanonicalEventType.income,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: now,
        description: 'Bad event',
        createdAt: now,
      );

      expect(
        () => repo.createAndPostEvent(badEvent, postings: badPostings),
        throwsA(isA<AccountingInvariantException>()),
      );

      // Ensure rollback: evt_atomic_bad was not saved as draft
      final rolledBack = await repo.getEvent('evt_atomic_bad');
      expect(rolledBack, isNull);
    });

    test('SQLite native triggers strictly prevent mutation on posted records', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_imm1',
          economicEventId: 'evt_immutable',
          accountId: 'acc_groceries',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000),
          createdAt: now,
        ),
        Posting(
          id: 'p_imm2',
          economicEventId: 'evt_immutable',
          accountId: 'acc_bank',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000),
          createdAt: now,
        ),
      ];

      final event = EconomicEvent(
        id: 'evt_immutable',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.posted,
        occurredAt: now,
        description: 'Locked Expense',
        postings: postings,
        createdAt: now,
      );

      await repo.createAndPostEvent(event, postings: postings);

      // 1. Direct update on posting must fail via SQLite trigger
      expect(
        () => db.update(
          TablesV24.postings,
          {'amount_minor_units': 9999},
          where: 'id = ?',
          whereArgs: ['p_imm1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // 2. Direct insert on postings of posted event must fail via trigger
      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'p_illegal_extra',
          'economic_event_id': 'evt_immutable',
          'account_id': 'acc_bank',
          'sequence_number': 3,
          'direction': 'credit',
          'amount_minor_units': 500,
          'currency': 'INR',
          'created_at': now.toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );

      // 3. Direct delete of posting of posted event must fail via trigger
      expect(
        () => db.delete(
          TablesV24.postings,
          where: 'id = ?',
          whereArgs: ['p_imm1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // 4. Direct delete of posted event must fail via trigger
      expect(
        () => db.delete(
          TablesV24.economicEvents,
          where: 'id = ?',
          whereArgs: ['evt_immutable'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Querying events, postings, and evidence', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'post_q1',
          economicEventId: 'evt_query',
          accountId: 'acc_groceries',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(150000),
          createdAt: now,
        ),
        Posting(
          id: 'post_q2',
          economicEventId: 'evt_query',
          accountId: 'acc_bank',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(150000),
          createdAt: now,
        ),
      ];

      final evidence = [
        Evidence(
          id: 'ev_1',
          sourceType: 'sms',
          extractedAmount: Money.fromMinorUnits(150000),
          sourceTimestamp: now,
          bodyFingerprint: 'fake_sha_query',
          sourceIdentifier: 'HDFCBK',
          createdAt: now,
        ),
      ];

      final event = EconomicEvent(
        id: 'evt_query',
        canonicalType: CanonicalEventType.expense,
        lifecycleStatus: EventLifecycle.posted,
        occurredAt: now,
        description: 'Dining Out',
        postings: postings,
        createdAt: now,
      );

      await repo.createAndPostEvent(
        event,
        postings: postings,
        evidence: evidence,
      );

      final fetchedPostings = await repo.getPostingsForAccount('acc_bank');
      expect(fetchedPostings.length, 1);
      expect(fetchedPostings.first.amount.minorUnits, 150000);

      final fetchedEvidence = await repo.getEvidenceForEvent('evt_query');
      expect(fetchedEvidence.length, 1);
      expect(fetchedEvidence.first.sourceIdentifier, 'HDFCBK');

      final postedList = await repo.listPostedEvents();
      expect(postedList.any((e) => e.id == 'evt_query'), isTrue);
    });
  });
}
