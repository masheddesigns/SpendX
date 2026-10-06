import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import '../core/tables_v24.dart';

/// Exception thrown when a pre-commit accounting or database invariant check fails.
class MigrationVerificationException implements Exception {
  final String message;
  final String checkName;
  final dynamic details;

  MigrationVerificationException({
    required this.message,
    required this.checkName,
    this.details,
  });

  @override
  String toString() =>
      'MigrationVerificationException [$checkName]: $message (details: $details)';
}

/// Result summary of Migration v24 execution.
class MigrationV24Result {
  final bool alreadyMigrated;
  final String? backupPath;
  final int accountsMigrated;
  final int eventsMigrated;
  final int postingsCreated;
  final int openingBalancesReconciled;
  final int evidenceMigrated;
  final int earmarksMigrated;
  final int recurringRulesMigrated;
  final int reviewCandidatesMigrated;
  final bool destructiveDropsExecuted;
  final int sourceTransactionsTotal;
  final int sourceTransactionsMigrated;
  final int sourceTransactionsExcludedByPolicy;
  final int sourceTransactionsQuarantined;
  final int sourceTransactionsReconciled;

  MigrationV24Result({
    this.alreadyMigrated = false,
    this.backupPath,
    this.accountsMigrated = 0,
    this.eventsMigrated = 0,
    this.postingsCreated = 0,
    this.openingBalancesReconciled = 0,
    this.evidenceMigrated = 0,
    this.earmarksMigrated = 0,
    this.recurringRulesMigrated = 0,
    this.reviewCandidatesMigrated = 0,
    this.destructiveDropsExecuted = false,
    this.sourceTransactionsTotal = 0,
    this.sourceTransactionsMigrated = 0,
    this.sourceTransactionsExcludedByPolicy = 0,
    this.sourceTransactionsQuarantined = 0,
    this.sourceTransactionsReconciled = 0,
  });

  @override
  String toString() => 'MigrationV24Result('
      'alreadyMigrated: $alreadyMigrated, '
      'backupPath: $backupPath, '
      'accounts: $accountsMigrated, '
      'events: $eventsMigrated, '
      'postings: $postingsCreated, '
      'openingBalances: $openingBalancesReconciled, '
      'evidence: $evidenceMigrated, '
      'earmarks: $earmarksMigrated, '
      'recurringRules: $recurringRulesMigrated, '
      'reviewCandidates: $reviewCandidatesMigrated, '
      'destructiveDrops: $destructiveDropsExecuted, '
      'sourceTotal: $sourceTransactionsTotal, '
      'sourceMigrated: $sourceTransactionsMigrated, '
      'sourceExcluded: $sourceTransactionsExcludedByPolicy, '
      'sourceQuarantined: $sourceTransactionsQuarantined, '
      'sourceReconciled: $sourceTransactionsReconciled'
      ')';
}

/// Migration Engine for SpendX 2.0 (Migration v24).
///
/// Transitions the physical database to canonical double-entry accounting with
/// 100% mathematical balance parity, deterministic minor-unit rounding,
/// 30-day SMS retention enforcement, and native SQLite trigger validation.
class MigrationV24Service {
  /// Maximum single transaction amount allowed (1 lakh crore = 10^14 paise).
  static const int maxTransactionMinorUnits = 100000000000000;

  /// Obsolete tables approved for physical deletion during C2C destructive cleanup.
  /// Exactly 4 tables: 3 vehicle subsystem tables removed in Milestone A, plus 1 obsolete cache.
  static const List<String> approvedDestructiveDropTables = [
    'fuel_logs',
    'vehicle_reminders',
    'vehicles',
    'bank_balance_snapshots',
  ];

  /// Deterministically converts floating-point rupees to 64-bit integer paise.
  /// Uses nearest-paisa half-even/round policy: (rupees * 100.0).round().
  static int toMinorUnits(num rupees) {
    if (rupees.abs() > 1000000000000.0) {
      throw StateError(
        'Monetary overflow: $rupees exceeds 1 lakh crore upper boundary.',
      );
    }
    return (rupees * 100.0).round();
  }

  /// Computes a deterministic SHA-256 fingerprint for evidence deduplication.
  static String computeSha256(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Creates a cold snapshot backup of the database before acquiring the write lock.
  ///
  /// For in-memory databases (e.g. unit tests), returns `null` without error.
  /// For physical files, verifies that the backup file exists, is non-zero in size,
  /// and is readable.
  static Future<String?> createPreMigrationBackup(Database db) async {
    final dbPath = db.path;
    if (dbPath == inMemoryDatabasePath || dbPath.isEmpty) {
      return null;
    }

    final backupPath = '$dbPath.pre_v24_backup';
    final backupFile = File(backupPath);
    if (await backupFile.exists()) {
      await backupFile.delete();
    }

    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
      await db.execute("VACUUM INTO '$backupPath';");
    } catch (_) {
      // Fallback: file copy after checkpoint if VACUUM INTO is unsupported
      final sourceFile = File(dbPath);
      if (await sourceFile.exists()) {
        await sourceFile.copy(backupPath);
      }
    }

    if (await backupFile.exists()) {
      final size = await backupFile.length();
      if (size > 0) {
        return backupPath;
      }
    }

    throw StateError(
      'Failed to create a valid non-zero pre-migration backup at $backupPath',
    );
  }

  /// Executes Migration v24.
  ///
  /// Parameters:
  /// - [executor]: Database or Transaction executor.
  /// - [allowDestructiveDrops]: Gate for dropping legacy tables. Default is `false` (C2A lock).
  /// - [backupPath]: Path to cold backup if created.
  static Future<MigrationV24Result> migrate(
    DatabaseExecutor executor, {
    bool allowDestructiveDrops = false,
    String? backupPath,
  }) async {
    // 1. Idempotency Check
    final versionResult = await executor.rawQuery('PRAGMA user_version;');
    final currentVersion = versionResult.first.values.first as int;
    if (currentVersion >= 24) {
      return MigrationV24Result(alreadyMigrated: true);
    }

    // 2. Ensure v24 Canonical Schema & Indexes
    await TablesV24.createAllV24(executor);

    // 3. Seed Core System Accounts
    await TablesV24.seedSystemAccounts(executor);

    // Track migration metrics
    int accountsMigrated = 0;
    int eventsMigrated = 0;
    int postingsCreated = 0;
    int openingBalancesReconciled = 0;
    int evidenceMigrated = 0;
    int earmarksMigrated = 0;
    int recurringRulesMigrated = 0;
    int reviewCandidatesMigrated = 0;

    // Helper: check table existence
    Future<bool> tableExists(String name) async {
      final res = await executor.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        [name],
      );
      return res.isNotEmpty;
    }

    // 4. Migrate Accounts
    // 4.1 Bank Accounts -> accounts (asset, liquid_cash)
    if (await tableExists('bank_accounts')) {
      final bankAccounts = await executor.query('bank_accounts');
      for (final ba in bankAccounts) {
        final id = ba['id'] as String;
        final name = ba['name'] as String? ?? 'Bank Account';
        final bank = ba['bank'] as String?;
        final last4 = ba['last4'] as String?;
        final createdAt =
            ba['created_at'] as String? ?? DateTime.now().toIso8601String();
        final updatedAt = ba['updated_at'] as String? ?? createdAt;

        await executor.insert(
          TablesV24.accounts,
          {
            'id': id,
            'account_type': 'asset',
            'subtype': 'liquid_cash',
            'name': name,
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'institution_name': bank,
            'account_number_last4': last4,
            'created_at': createdAt,
            'updated_at': updatedAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        accountsMigrated++;
      }
    }

    // 4.2 Credit Cards -> accounts (liability, credit_card)
    if (await tableExists('credit_cards')) {
      final creditCards = await executor.query('credit_cards');
      for (final cc in creditCards) {
        final id = cc['id'] as String;
        final name = cc['name'] as String? ?? 'Credit Card';
        final bank = cc['bank'] as String?;
        final last4 = cc['last4'] as String?;
        final limit = cc['credit_limit'] as num? ?? cc['limit_amount'] as num?;
        final limitMinor = limit != null ? toMinorUnits(limit) : null;
        final billingDay = cc['billing_day'] as int?;
        final dueDay = cc['due_day'] as int?;
        final createdAt =
            cc['created_at'] as String? ?? DateTime.now().toIso8601String();

        await executor.insert(
          TablesV24.accounts,
          {
            'id': id,
            'account_type': 'liability',
            'subtype': 'credit_card',
            'name': name,
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'institution_name': bank,
            'account_number_last4': last4,
            'credit_limit_minor_units': limitMinor,
            'billing_cycle_day': billingDay,
            'payment_due_day': dueDay,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        accountsMigrated++;
      }
    }

    // 4.3 Loans -> accounts (liability, loan)
    if (await tableExists('loans')) {
      final loans = await executor.query('loans');
      for (final ln in loans) {
        final id = ln['id'] as String;
        final name = ln['name'] as String? ?? 'Loan';
        final bank = ln['bank'] as String?;
        final principal = ln['principal_amount'] as num? ?? ln['total'] as num?;
        final principalMinor =
            principal != null ? toMinorUnits(principal) : null;
        final interestRate = ln['interest_rate'] as num?;
        final interestBasisPoints = interestRate != null
            ? (interestRate * 100.0).round()
            : null;
        final tenureMonths = ln['tenure_months'] as int?;
        final emi = ln['monthly_installment'] as num?;
        final emiMinor = emi != null ? toMinorUnits(emi) : null;
        final startDate = ln['start_date'] as String?;
        final createdAt =
            ln['created_at'] as String? ?? DateTime.now().toIso8601String();

        await executor.insert(
          TablesV24.accounts,
          {
            'id': id,
            'account_type': 'liability',
            'subtype': 'loan',
            'name': name,
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'institution_name': bank,
            'principal_original_minor_units': principalMinor,
            'interest_rate_basis_points': interestBasisPoints,
            'tenure_months': tenureMonths,
            'monthly_installment_minor_units': emiMinor,
            'start_date': startDate,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        accountsMigrated++;
      }
    }

    // 4.4 Categories -> accounts (expense / income, category)
    if (await tableExists('categories')) {
      final categories = await executor.query('categories');
      for (final cat in categories) {
        final id = cat['id'] as String;
        final name = cat['name'] as String? ?? 'Category';
        final type = (cat['type'] as String? ?? 'expense').toLowerCase();
        final color = cat['color'] as String?;
        final icon = cat['icon'] as String?;
        final createdAt = DateTime.now().toIso8601String();

        await executor.insert(
          TablesV24.accounts,
          {
            'id': id,
            'account_type': type == 'income' ? 'income' : 'expense',
            'subtype': 'category',
            'name': name,
            'currency': 'INR',
            'is_active': 1,
            'is_system': 0,
            'color_hex': color,
            'icon_name': icon,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        accountsMigrated++;
      }
    }

    // Load set of existing valid account IDs for foreign key validation
    final existingAccountRows = await executor.rawQuery(
      'SELECT id, account_type FROM ${TablesV24.accounts};',
    );
    final accountMap = {
      for (final r in existingAccountRows)
        r['id'] as String: r['account_type'] as String,
    };

    // Helper: find or default asset account
    String resolveAssetAccount(String? candidateId) {
      if (candidateId != null && accountMap[candidateId] == 'asset') {
        return candidateId;
      }
      final firstAsset = accountMap.entries
          .where((e) => e.value == 'asset')
          .map((e) => e.key)
          .firstOrNull;
      return firstAsset ?? TablesV24.sysSuspenseTransfer;
    }

    // Helper: resolve category account
    String resolveCategoryAccount(String? candidateId, String defaultType) {
      if (candidateId != null &&
          (accountMap[candidateId] == 'expense' ||
              accountMap[candidateId] == 'income')) {
        return candidateId;
      }
      return defaultType == 'income'
          ? TablesV24.sysIncMisc
          : TablesV24.sysExpMisc;
    }

    // Track active movements per account for post-transaction opening balance reconciliation:
    // For asset accounts: balance = debits - credits
    // For liability accounts: balance = credits - debits
    final accountDebits = <String, int>{};
    final accountCredits = <String, int>{};

    void recordPostingImpact(String accId, String direction, int amount) {
      if (direction == 'debit') {
        accountDebits[accId] = (accountDebits[accId] ?? 0) + amount;
      } else {
        accountCredits[accId] = (accountCredits[accId] ?? 0) + amount;
      }
    }

    int sourceTransactionsTotal = 0;
    int sourceTransactionsMigrated = 0;
    int sourceTransactionsExcludedByPolicy = 0;
    int sourceTransactionsQuarantined = 0;

    // 5. Migrate Legacy Transactions
    if (await tableExists('transactions')) {
      final txRows = await executor.query('transactions');
      sourceTransactionsTotal = txRows.length;
      final now = DateTime.now();

      for (final tx in txRows) {
        final id = tx['id'] as String;
        final rawAmount = tx['amount'] as num? ?? 0.0;
        final type = (tx['type'] as String? ?? 'expense').toLowerCase();
        final isDeleted = (tx['is_deleted'] as int? ?? 0) == 1;
        final date =
            tx['date'] as String? ?? DateTime.now().toIso8601String();
        final rawNote = tx['note'] as String? ?? tx['notes'] as String?;
        final externalRef = tx['external_ref'] as String?;
        final rawSource = tx['source'] as String?;
        final categoryId = tx['category_id'] as String?;
        final accountId = tx['account_id'] as String?;
        final relatedEntityId = tx['related_entity_id'] as String?;
        final createdAt =
            tx['created_at'] as String? ?? DateTime.now().toIso8601String();
        final updatedAt = tx['updated_at'] as String? ?? createdAt;

        // HARD STOP A: Soft-deleted legacy rows are EXCLUDED BY POLICY from economic_events.
        // They generate 0 events, 0 postings, and never enter financial calculations.
        if (isDeleted) {
          sourceTransactionsExcludedByPolicy++;
          continue;
        }

        final amountMinor = toMinorUnits(rawAmount);
        if (amountMinor <= 0) {
          // Zero or negative legacy row - quarantined
          sourceTransactionsQuarantined++;
          await executor.insert(
            TablesV24.migrationExceptions,
            {
              'id': 'exc_$id',
              'record_id': id,
              'table_name': 'transactions',
              'error_code': 'ERR_NON_POSITIVE_AMOUNT',
              'raw_payload': jsonEncode(tx),
              'message': 'Legacy transaction with non-positive amount ($rawAmount)',
              'created_at': DateTime.now().toIso8601String(),
            },
          );
          continue;
        }

        String eventType = 'expense';
        String debitAccount = TablesV24.sysExpMisc;
        String creditAccount = TablesV24.sysSuspenseTransfer;
        int? loanPrincipalMinor;
        int? loanInterestMinor;

        switch (type) {
          case 'expense':
            eventType = 'expense';
            debitAccount = resolveCategoryAccount(categoryId, 'expense');
            creditAccount = resolveAssetAccount(accountId);
            break;

          case 'income':
            eventType = 'income';
            debitAccount = resolveAssetAccount(accountId);
            creditAccount = resolveCategoryAccount(categoryId, 'income');
            break;

          case 'transfer':
            eventType = 'transfer';
            creditAccount = resolveAssetAccount(accountId);
            debitAccount = resolveAssetAccount(relatedEntityId);
            break;

          case 'credit_purchase':
          case 'credit_card_purchase':
          case 'purchase':
            eventType = 'credit_purchase';
            debitAccount = resolveCategoryAccount(categoryId, 'expense');
            creditAccount = (accountId != null &&
                    accountMap[accountId] == 'liability')
                ? accountId
                : ((relatedEntityId != null &&
                        accountMap[relatedEntityId] == 'liability')
                    ? relatedEntityId
                    : TablesV24.sysSuspenseCard);
            break;

          case 'credit_payment':
          case 'credit_card_payment':
          case 'liability_settlement':
            // CRITICAL INVARIANT: Card bill payment is Debit Liability, Credit Bank (ZERO Expense)
            eventType = 'liability_settlement';
            creditAccount = resolveAssetAccount(accountId);
            debitAccount = (relatedEntityId != null &&
                    accountMap[relatedEntityId] == 'liability')
                ? relatedEntityId
                : TablesV24.sysSuspenseCard;
            break;

          case 'refund':
            // CRITICAL INVARIANT: Refund is Debit Bank, Credit Contra-Expense (ZERO Income)
            eventType = 'refund';
            debitAccount = resolveAssetAccount(accountId);
            // Matched refund check (FX04)
            String? targetExpenseCat = (categoryId != null &&
                    accountMap[categoryId] == 'expense')
                ? categoryId
                : null;
            if (targetExpenseCat == null && rawNote != null) {
              for (final prev in txRows) {
                final prevRef = prev['external_ref'] as String?;
                final prevId = prev['id'] as String?;
                if ((prevRef != null && rawNote.contains(prevRef)) ||
                    (prevId != null && rawNote.contains(prevId))) {
                  final prevCat = prev['category_id'] as String?;
                  if (prevCat != null && accountMap[prevCat] == 'expense') {
                    targetExpenseCat = prevCat;
                    break;
                  }
                }
              }
            }
            creditAccount = targetExpenseCat ?? TablesV24.sysExpRefunds;
            break;

          case 'loan_disbursement':
            eventType = 'loan_disbursement';
            debitAccount = resolveAssetAccount(accountId);
            creditAccount = (relatedEntityId != null &&
                    accountMap[relatedEntityId] == 'liability')
                ? relatedEntityId
                : TablesV24.sysSuspenseLoan;
            break;

          case 'loan_payment':
          case 'loan_repayment':
            eventType = 'loan_payment';
            debitAccount = (relatedEntityId != null &&
                    accountMap[relatedEntityId] == 'liability')
                ? relatedEntityId
                : TablesV24.sysSuspenseLoan;
            creditAccount = resolveAssetAccount(accountId);

            // FX05: Check for explicit principal/interest split in note
            final splitMatch = RegExp(
              r'Principal:\s*([\d.]+).*Interest:\s*([\d.]+)',
              caseSensitive: false,
            ).firstMatch(rawNote ?? '');
            if (splitMatch != null) {
              final pVal = double.tryParse(splitMatch.group(1)!);
              final iVal = double.tryParse(splitMatch.group(2)!);
              if (pVal != null && iVal != null) {
                final pMin = toMinorUnits(pVal);
                final iMin = toMinorUnits(iVal);
                if (pMin + iMin == amountMinor) {
                  loanPrincipalMinor = pMin;
                  loanInterestMinor = iMin;
                }
              }
            }
            break;

          case 'salary':
          case 'salary_receipt':
            eventType = 'salary_receipt';
            debitAccount = resolveAssetAccount(accountId);
            creditAccount = resolveCategoryAccount(categoryId, 'income');
            break;

          default:
            // Unmapped type: log anomaly and default to expense
            await executor.insert(
              TablesV24.migrationExceptions,
              {
                'id': 'exc_$id',
                'record_id': id,
                'table_name': 'transactions',
                'error_code': 'ERR_UNMAPPED_LEGACY_TYPE',
                'raw_payload': jsonEncode(tx),
                'message': 'Legacy transaction with unmapped type "$type"',
                'created_at': DateTime.now().toIso8601String(),
              },
            );
            eventType = 'expense';
            debitAccount = resolveCategoryAccount(categoryId, 'expense');
            creditAccount = resolveAssetAccount(accountId);
            break;
        }

        // Insert Economic Event as 'draft'
        await executor.insert(
          TablesV24.economicEvents,
          {
            'id': id,
            'event_type': eventType,
            'lifecycle_status': 'draft',
            'timestamp': date,
            'currency': 'INR',
            'description': rawNote ?? '$eventType transaction',
            'category_id': (debitAccount.startsWith('sys_') ||
                    creditAccount.startsWith('sys_'))
                ? null
                : (eventType == 'expense' ? debitAccount : creditAccount),
            'notes': rawNote,
            'created_at': createdAt,
            'updated_at': updatedAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        eventsMigrated++;
        sourceTransactionsMigrated++;

        if (loanPrincipalMinor != null && loanInterestMinor != null) {
          // 3-leg balanced loan repayment posting (FX05)
          // Leg 1: Debit Loan Liability (Principal)
          await executor.insert(
            TablesV24.postings,
            {
              'id': 'pst_${id}_1',
              'economic_event_id': id,
              'account_id': debitAccount,
              'sequence_number': 1,
              'direction': 'debit',
              'amount_minor_units': loanPrincipalMinor,
              'currency': 'INR',
              'created_at': createdAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          recordPostingImpact(debitAccount, 'debit', loanPrincipalMinor);
          postingsCreated++;

          // Leg 2: Debit Interest Expense (Interest)
          await executor.insert(
            TablesV24.postings,
            {
              'id': 'pst_${id}_2',
              'economic_event_id': id,
              'account_id': TablesV24.sysExpInterest,
              'sequence_number': 2,
              'direction': 'debit',
              'amount_minor_units': loanInterestMinor,
              'currency': 'INR',
              'created_at': createdAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          recordPostingImpact(TablesV24.sysExpInterest, 'debit', loanInterestMinor);
          postingsCreated++;

          // Leg 3: Credit Bank Asset (Total amount)
          await executor.insert(
            TablesV24.postings,
            {
              'id': 'pst_${id}_3',
              'economic_event_id': id,
              'account_id': creditAccount,
              'sequence_number': 3,
              'direction': 'credit',
              'amount_minor_units': amountMinor,
              'currency': 'INR',
              'created_at': createdAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          recordPostingImpact(creditAccount, 'credit', amountMinor);
          postingsCreated++;
        } else {
          // Standard 2-leg balanced posting
          final p1Id = 'pst_${id}_1';
          await executor.insert(
            TablesV24.postings,
            {
              'id': p1Id,
              'economic_event_id': id,
              'account_id': debitAccount,
              'sequence_number': 1,
              'direction': 'debit',
              'amount_minor_units': amountMinor,
              'currency': 'INR',
              'created_at': createdAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          recordPostingImpact(debitAccount, 'debit', amountMinor);
          postingsCreated++;

          final p2Id = 'pst_${id}_2';
          await executor.insert(
            TablesV24.postings,
            {
              'id': p2Id,
              'economic_event_id': id,
              'account_id': creditAccount,
              'sequence_number': 2,
              'direction': 'credit',
              'amount_minor_units': amountMinor,
              'currency': 'INR',
              'created_at': createdAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          recordPostingImpact(creditAccount, 'credit', amountMinor);
          postingsCreated++;
        }

        // Ingest Evidence record if externalRef, notes, or sms source exists
        if (externalRef != null || rawSource == 'sms' || rawNote != null) {
          final txDate = DateTime.tryParse(date) ?? now;
          final retentionExpiresAt =
              txDate.add(const Duration(days: 30)).toIso8601String();
          final isPurged =
              now.isAfter(txDate.add(const Duration(days: 30))) ? 1 : 0;
          final bodyHash = computeSha256(externalRef ?? rawNote ?? id);

          await executor.insert(
            TablesV24.evidence,
            {
              'id': 'evi_$id',
              'economic_event_id': id,
              'source_type': rawSource == 'sms' ? 'sms' : 'manual',
              'extracted_amount_minor_units': amountMinor,
              'extracted_timestamp': date,
              'external_reference': externalRef,
              'body_sha256': bodyHash,
              'raw_payload_encrypted': isPurged == 1 ? null : rawNote,
              'retention_expires_at': retentionExpiresAt,
              'is_payload_purged': isPurged,
              'created_at': createdAt,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          evidenceMigrated++;
        }
      }
    }

    // 6. Compute & Seed Opening Balance Reconciliations
    // 6.1 Reconcile Bank Accounts
    if (await tableExists('bank_accounts')) {
      final bankAccounts = await executor.query('bank_accounts');
      for (final ba in bankAccounts) {
        final accountId = ba['id'] as String;
        final rawBal = ba['balance'] as num? ?? 0.0;
        final legacyBalanceMinor = toMinorUnits(rawBal);

        final debits = accountDebits[accountId] ?? 0;
        final credits = accountCredits[accountId] ?? 0;
        final reconstructedBalanceMinor = debits - credits;
        final delta = legacyBalanceMinor - reconstructedBalanceMinor;

        if (delta != 0) {
          final eventId = 'evt_openbal_$accountId';
          final obrId = 'obr_$accountId';
          final absDelta = delta.abs();
          final nowStr = DateTime.now().toIso8601String();

          // Create Opening Balance Economic Event (draft)
          await executor.insert(
            TablesV24.economicEvents,
            {
              'id': eventId,
              'event_type': 'opening_balance',
              'lifecycle_status': 'draft',
              'timestamp': ba['created_at'] as String? ?? nowStr,
              'currency': 'INR',
              'description':
                  'Opening Balance Equity adjustment during SpendX 2.0 migration',
              'created_at': nowStr,
              'updated_at': nowStr,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          eventsMigrated++;

          if (delta > 0) {
            // Asset increased: Debit Asset, Credit Equity:OpeningBalance
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_1',
                'economic_event_id': eventId,
                'account_id': accountId,
                'sequence_number': 1,
                'direction': 'debit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_2',
                'economic_event_id': eventId,
                'account_id': TablesV24.sysEquityOpening,
                'sequence_number': 2,
                'direction': 'credit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            recordPostingImpact(accountId, 'debit', absDelta);
            recordPostingImpact(TablesV24.sysEquityOpening, 'credit', absDelta);
          } else {
            // Asset decreased: Credit Asset, Debit Equity:OpeningBalance
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_1',
                'economic_event_id': eventId,
                'account_id': accountId,
                'sequence_number': 1,
                'direction': 'credit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_2',
                'economic_event_id': eventId,
                'account_id': TablesV24.sysEquityOpening,
                'sequence_number': 2,
                'direction': 'debit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            recordPostingImpact(accountId, 'credit', absDelta);
            recordPostingImpact(TablesV24.sysEquityOpening, 'debit', absDelta);
          }
          postingsCreated += 2;

          // Evidence for Opening Balance Event
          await executor.insert(
            TablesV24.evidence,
            {
              'id': 'evi_$eventId',
              'economic_event_id': eventId,
              'source_type': 'migration_v24_reconciliation',
              'extracted_amount_minor_units': absDelta,
              'extracted_timestamp': nowStr,
              'body_sha256': computeSha256(eventId),
              'is_payload_purged': 1,
              'created_at': nowStr,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          evidenceMigrated++;

          // Record in opening_balance_reconciliations table
          await executor.insert(
            TablesV24.openingBalanceReconciliations,
            {
              'id': obrId,
              'account_id': accountId,
              'legacy_reported_balance_minor_units': legacyBalanceMinor,
              'reconstructed_balance_minor_units': reconstructedBalanceMinor,
              'adjustment_delta_minor_units': delta,
              'reconciliation_reason':
                  'Opening Balance Equity adjustment during SpendX 2.0 migration',
              'provenance_source': 'migration_v24_reconciliation',
              'status': 'equityAdjustmentRequired',
              'generated_event_id': eventId,
              'created_at': nowStr,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          openingBalancesReconciled++;
        }
      }
    }

    // 6.2 Reconcile Credit Card Balances
    if (await tableExists('credit_cards')) {
      final creditCards = await executor.query('credit_cards');
      for (final cc in creditCards) {
        final cardId = cc['id'] as String;
        final rawUsed = cc['used_amount'] as num? ?? 0.0;
        final legacyUsedMinor = toMinorUnits(rawUsed);

        // For liability: balance = credits (purchases) - debits (payments)
        final credits = accountCredits[cardId] ?? 0;
        final debits = accountDebits[cardId] ?? 0;
        final reconstructedLiabilityMinor = credits - debits;
        final delta = legacyUsedMinor - reconstructedLiabilityMinor;

        if (delta != 0) {
          final eventId = 'evt_openbal_$cardId';
          final obrId = 'obr_$cardId';
          final absDelta = delta.abs();
          final nowStr = DateTime.now().toIso8601String();

          await executor.insert(
            TablesV24.economicEvents,
            {
              'id': eventId,
              'event_type': 'opening_balance',
              'lifecycle_status': 'draft',
              'timestamp': cc['created_at'] as String? ?? nowStr,
              'currency': 'INR',
              'description':
                  'Credit Card Opening Liability reconciliation during SpendX 2.0 migration',
              'created_at': nowStr,
              'updated_at': nowStr,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          eventsMigrated++;

          if (delta > 0) {
            // More liability: Debit Equity:OpeningBalance, Credit Card Liability
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_1',
                'economic_event_id': eventId,
                'account_id': TablesV24.sysEquityOpening,
                'sequence_number': 1,
                'direction': 'debit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_2',
                'economic_event_id': eventId,
                'account_id': cardId,
                'sequence_number': 2,
                'direction': 'credit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            recordPostingImpact(TablesV24.sysEquityOpening, 'debit', absDelta);
            recordPostingImpact(cardId, 'credit', absDelta);
          } else {
            // Less liability: Debit Card Liability, Credit Equity:OpeningBalance
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_1',
                'economic_event_id': eventId,
                'account_id': cardId,
                'sequence_number': 1,
                'direction': 'debit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            await executor.insert(
              TablesV24.postings,
              {
                'id': 'pst_${eventId}_2',
                'economic_event_id': eventId,
                'account_id': TablesV24.sysEquityOpening,
                'sequence_number': 2,
                'direction': 'credit',
                'amount_minor_units': absDelta,
                'currency': 'INR',
                'created_at': nowStr,
              },
            );
            recordPostingImpact(cardId, 'debit', absDelta);
            recordPostingImpact(TablesV24.sysEquityOpening, 'credit', absDelta);
          }
          postingsCreated += 2;

          await executor.insert(
            TablesV24.openingBalanceReconciliations,
            {
              'id': obrId,
              'account_id': cardId,
              'legacy_reported_balance_minor_units': legacyUsedMinor,
              'reconstructed_balance_minor_units': reconstructedLiabilityMinor,
              'adjustment_delta_minor_units': delta,
              'reconciliation_reason':
                  'Credit Card Opening Liability reconciliation during SpendX 2.0 migration',
              'provenance_source': 'migration_v24_reconciliation',
              'status': 'equityAdjustmentRequired',
              'generated_event_id': eventId,
              'created_at': nowStr,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          openingBalancesReconciled++;
        }
      }
    }

    // 7. Migrate Goals & Asset Earmarks
    if (await tableExists('goal_logs') && await tableExists('goals')) {
      final goalLogs = await executor.query('goal_logs');
      for (final gl in goalLogs) {
        final id = gl['id'] as String;
        final goalId = gl['goal_id'] as String;
        final rawAmount = gl['amount'] as num? ?? 0.0;
        final amountMinor = toMinorUnits(rawAmount);
        final createdAt =
            gl['created_at'] as String? ?? DateTime.now().toIso8601String();

        // Resolve goal's target asset account
        final goalRow = await executor.query(
          'goals',
          where: 'id = ?',
          whereArgs: [goalId],
          limit: 1,
        );
        String? assetAccountId;
        if (goalRow.isNotEmpty) {
          final cand = goalRow.first['account_id'] as String?;
          if (cand != null && accountMap[cand] == 'asset') {
            assetAccountId = cand;
          }
        }
        assetAccountId ??= resolveAssetAccount(null);

        await executor.insert(
          TablesV24.assetEarmarks,
          {
            'id': id,
            'goal_id': goalId,
            'asset_account_id': assetAccountId,
            'amount_minor_units': amountMinor,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        earmarksMigrated++;
      }
    }

    // FX07: Support direct goals.current_amount earmarking if goal_logs was omitted
    if (await tableExists('goals')) {
      final goalsRows = await executor.query('goals');
      for (final g in goalsRows) {
        final goalId = g['id'] as String;
        final existingEarmarks = await executor.query(
          TablesV24.assetEarmarks,
          where: 'goal_id = ?',
          whereArgs: [goalId],
        );
        if (existingEarmarks.isEmpty) {
          final currentAmount = g['current_amount'] as num? ?? 0.0;
          if (currentAmount > 0) {
            final amountMinor = toMinorUnits(currentAmount);
            final cand = g['account_id'] as String?;
            final targetAccount = resolveAssetAccount(cand);
            final nowStr = g['created_at'] as String? ??
                DateTime.now().toIso8601String();
            await executor.insert(
              TablesV24.assetEarmarks,
              {
                'id': 'earmark_$goalId',
                'goal_id': goalId,
                'asset_account_id': targetAccount,
                'amount_minor_units': amountMinor,
                'created_at': nowStr,
                'updated_at': nowStr,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
            earmarksMigrated++;
          }
        }
      }
    }

    // 8. Migrate Recurring Rules
    final recurringTable = (await tableExists('recurring_templates'))
        ? 'recurring_templates'
        : ((await tableExists('recurring')) ? 'recurring' : null);

    if (recurringTable != null) {
      final templates = await executor.query(recurringTable);
      for (final t in templates) {
        final id = t['id'] as String;
        final title = (t['title'] ?? t['name'] ?? 'Recurring Rule') as String;
        final rawAmount = t['amount'] as num? ?? 0.0;
        final amountMinor = toMinorUnits(rawAmount);
        final frequency = (t['frequency'] as String? ?? 'monthly').toLowerCase();
        final cadence = switch (frequency) {
          'daily' => 'daily',
          'weekly' => 'weekly',
          'quarterly' => 'quarterly',
          'yearly' => 'yearly',
          _ => 'monthly',
        };
        final categoryId = t['category_id'] as String?;
        final accountId = t['account_id'] as String?;
        final nextDue = t['next_date'] as String? ??
            t['date'] as String? ??
            DateTime.now().toIso8601String();
        final isActive = t['is_active'] as int? ?? 1;
        final createdAt =
            t['created_at'] as String? ?? DateTime.now().toIso8601String();

        await executor.insert(
          TablesV24.recurringRules,
          {
            'id': id,
            'title': title,
            'category_account_id':
                accountMap.containsKey(categoryId) ? categoryId : null,
            'target_account_id':
                accountMap.containsKey(accountId) ? accountId : null,
            'amount_minor_units': amountMinor > 0 ? amountMinor : 1,
            'cadence': cadence,
            'next_due_date': nextDue,
            'is_active': isActive,
            'created_at': createdAt,
            'updated_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        recurringRulesMigrated++;
      }
    }

    // FX06: Migrate salary_contracts to recurring_rules and expected_events
    if (await tableExists('salary_contracts')) {
      final contracts = await executor.query('salary_contracts');
      for (final sc in contracts) {
        final id = sc['id'] as String;
        String employer = sc['employer'] as String? ?? 'Employer';
        final rawBase = sc['base_salary'] as num? ??
            sc['base_amount'] as num? ??
            0.0;
        final amountMinor = toMinorUnits(rawBase);
        int payDay = sc['pay_day'] as int? ?? 1;
        final companyId = sc['company_id'] as String?;
        if (companyId != null && await tableExists('companies')) {
          final compRows = await executor.query(
            'companies',
            where: 'id = ?',
            whereArgs: [companyId],
          );
          if (compRows.isNotEmpty) {
            employer = compRows.first['name'] as String? ?? employer;
            payDay = compRows.first['salary_credit_day'] as int? ?? payDay;
          }
        }
        final isActive = sc['is_active'] as int? ?? 1;
        final nowStr = DateTime.now().toIso8601String();
        final ruleId = 'rr_sal_$id';

        await executor.insert(
          TablesV24.recurringRules,
          {
            'id': ruleId,
            'title': 'Salary: $employer',
            'category_account_id': TablesV24.sysIncMisc,
            'target_account_id': resolveAssetAccount(null),
            'amount_minor_units': amountMinor > 0 ? amountMinor : 1,
            'cadence': 'monthly',
            'day_of_month': payDay,
            'next_due_date': DateTime(
              DateTime.now().year,
              DateTime.now().month + 1,
              payDay,
            ).toIso8601String(),
            'is_active': isActive,
            'created_at': nowStr,
            'updated_at': nowStr,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        recurringRulesMigrated++;

        await executor.insert(
          TablesV24.expectedEvents,
          {
            'id': 'exp_sal_$id',
            'rule_id': ruleId,
            'due_date': DateTime(
              DateTime.now().year,
              DateTime.now().month + 1,
              payDay,
            ).toIso8601String(),
            'amount_minor_units': amountMinor > 0 ? amountMinor : 1,
            'status': 'pending',
            'created_at': nowStr,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    // FX08: Update budgets limit_amount to integer paise
    if (await tableExists('budgets')) {
      try {
        await executor.rawUpdate('''
          UPDATE budgets 
          SET limit_amount = CAST(ROUND(limit_amount * 100.0) AS INTEGER)
          WHERE limit_amount IS NOT NULL;
        ''');
      } catch (_) {}
    }

    // 9. Migrate Review Queue to Review Candidates
    if (await tableExists('review_queue')) {
      final queueRows = await executor.query('review_queue');
      for (final rq in queueRows) {
        final id = rq['id'] as String;
        final rawSms = rq['raw_sms'] as String? ?? '';
        final confidence = (rq['confidence'] as num?)?.toDouble() ?? 0.5;
        final status = rq['status'] as String? ?? 'pending';
        final createdAt =
            rq['created_at'] as String? ?? DateTime.now().toIso8601String();

        await executor.insert(
          TablesV24.reviewCandidates,
          {
            'id': id,
            'source_type': 'sms',
            'raw_payload': rawSms,
            'suggested_event_type': 'expense',
            'suggested_amount_minor_units': 0,
            'confidence_score': confidence,
            'status': status,
            'created_at': createdAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        reviewCandidatesMigrated++;
      }
    }

    // 10. Transition all draft economic events to posted
    await executor.rawUpdate(
      "UPDATE ${TablesV24.economicEvents} SET lifecycle_status = 'posted' "
      "WHERE lifecycle_status = 'draft';",
    );

    // 11. Install Native SQLite Lifecycle & Immutability Triggers
    await TablesV24.installTriggers(executor);

    // 12. Run Pre-Commit Assertion Verification Suite
    await _runPreCommitVerificationSuite(executor);

    // 13. Gated Destructive Drop of Legacy Tables
    bool dropsExecuted = false;
    if (allowDestructiveDrops) {
      for (final tbl in approvedDestructiveDropTables) {
        await executor.execute('DROP TABLE IF EXISTS $tbl;');
      }
      dropsExecuted = true;
    }

    // 14. Update user_version to 24
    await executor.execute('PRAGMA user_version = 24;');

    return MigrationV24Result(
      alreadyMigrated: false,
      backupPath: backupPath,
      accountsMigrated: accountsMigrated,
      eventsMigrated: eventsMigrated,
      postingsCreated: postingsCreated,
      openingBalancesReconciled: openingBalancesReconciled,
      evidenceMigrated: evidenceMigrated,
      earmarksMigrated: earmarksMigrated,
      recurringRulesMigrated: recurringRulesMigrated,
      reviewCandidatesMigrated: reviewCandidatesMigrated,
      destructiveDropsExecuted: dropsExecuted,
      sourceTransactionsTotal: sourceTransactionsTotal,
      sourceTransactionsMigrated: sourceTransactionsMigrated,
      sourceTransactionsExcludedByPolicy: sourceTransactionsExcludedByPolicy,
      sourceTransactionsQuarantined: sourceTransactionsQuarantined,
      sourceTransactionsReconciled: openingBalancesReconciled,
    );
  }

  /// Comprehensive Pre-Commit Assertion Verification Suite.
  ///
  /// Throws [MigrationVerificationException] if any check fails, triggering an
  /// immediate rollback of the migration transaction.
  static Future<void> _runPreCommitVerificationSuite(
    DatabaseExecutor executor,
  ) async {
    // Test 1: Global Ledger Zero-Sum Balance
    final test1 = await executor.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END), 0) AS total_debits,
        COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END), 0) AS total_credits,
        COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS net_imbalance
      FROM ${TablesV24.postings};
    ''');
    final debits = test1.first['total_debits'] as int;
    final credits = test1.first['total_credits'] as int;
    final imbalance = test1.first['net_imbalance'] as int;
    if (imbalance != 0 || debits != credits) {
      throw MigrationVerificationException(
        message: 'Global ledger is unbalanced: debits=$debits, credits=$credits, delta=$imbalance',
        checkName: 'GLOBAL_LEDGER_ZERO_SUM',
        details: {'debits': debits, 'credits': credits, 'delta': imbalance},
      );
    }

    // Test 2: Per-Event Balanced Postings (Zero Unbalanced Events)
    final test2 = await executor.rawQuery('''
      SELECT 
        economic_event_id,
        COUNT(*) AS posting_count,
        SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END) AS event_debits,
        SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END) AS event_credits
      FROM ${TablesV24.postings}
      GROUP BY economic_event_id
      HAVING event_debits != event_credits OR posting_count < 2;
    ''');
    if (test2.isNotEmpty) {
      throw MigrationVerificationException(
        message: 'Found ${test2.length} unbalanced or under-legged economic events.',
        checkName: 'PER_EVENT_BALANCE',
        details: test2,
      );
    }

    // Test 3: Zero Orphan Postings
    final test3 = await executor.rawQuery('''
      SELECT p.id, p.economic_event_id
      FROM ${TablesV24.postings} p
      LEFT JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.id IS NULL;
    ''');
    if (test3.isNotEmpty) {
      throw MigrationVerificationException(
        message: 'Found ${test3.length} postings referencing non-existent economic events.',
        checkName: 'ZERO_ORPHAN_POSTINGS',
        details: test3,
      );
    }

    // Test 4: Zero Orphan Economic Events (Posted events must have >= 2 postings)
    final test4 = await executor.rawQuery('''
      SELECT e.id, COUNT(p.id) AS posting_count
      FROM ${TablesV24.economicEvents} e
      LEFT JOIN ${TablesV24.postings} p ON e.id = p.economic_event_id
      WHERE e.lifecycle_status = 'posted'
      GROUP BY e.id
      HAVING posting_count < 2;
    ''');
    if (test4.isNotEmpty) {
      throw MigrationVerificationException(
        message: 'Found ${test4.length} posted economic events with fewer than 2 postings.',
        checkName: 'ZERO_ORPHAN_ECONOMIC_EVENTS',
        details: test4,
      );
    }

    // Test 5: Soft-Delete Neutrality (Legacy is_deleted = 1 must have 0 postings)
    final hasTxTable = (await executor.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='transactions';",
    )).isNotEmpty;
    if (hasTxTable) {
      final test5 = await executor.rawQuery('''
        SELECT p.id, p.economic_event_id, t.id AS legacy_tx_id
        FROM ${TablesV24.postings} p
        JOIN transactions t ON p.economic_event_id = t.id
        WHERE t.is_deleted = 1;
      ''');
      if (test5.isNotEmpty) {
        throw MigrationVerificationException(
          message: 'Soft-deleted legacy transactions have active postings.',
          checkName: 'SOFT_DELETE_NEUTRALITY',
          details: test5,
        );
      }
    }

    // Test 6: Account Balance Parity for Bank Accounts
    final hasBankAccountsTable = (await executor.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='bank_accounts';",
    )).isNotEmpty;
    if (hasBankAccountsTable) {
      final test6 = await executor.rawQuery('''
        WITH DerivedBalances AS (
          SELECT 
            a.id AS account_id,
            COALESCE(SUM(
              CASE 
                WHEN p.direction = 'debit' THEN p.amount_minor_units
                WHEN p.direction = 'credit' THEN -p.amount_minor_units
                ELSE 0 
              END
            ), 0) AS derived_balance_minor
          FROM ${TablesV24.accounts} a
          LEFT JOIN ${TablesV24.postings} p ON a.id = p.account_id
          WHERE a.account_type = 'asset'
          GROUP BY a.id
        )
        SELECT 
          ba.id AS legacy_account_id,
          CAST(ROUND(ba.balance * 100.0) AS INTEGER) AS legacy_expected_minor,
          db.derived_balance_minor,
          (db.derived_balance_minor - CAST(ROUND(ba.balance * 100.0) AS INTEGER)) AS discrepancy
        FROM bank_accounts ba
        JOIN DerivedBalances db ON ba.id = db.account_id
        WHERE (db.derived_balance_minor - CAST(ROUND(ba.balance * 100.0) AS INTEGER)) != 0;
      ''');
      if (test6.isNotEmpty) {
        throw MigrationVerificationException(
          message: 'Account balance parity violated on ${test6.length} bank accounts.',
          checkName: 'ACCOUNT_BALANCE_PARITY',
          details: test6,
        );
      }
    }

    // Test 7: Zero Credit Card Payment Expense Double-Counting
    final test7 = await executor.rawQuery('''
      SELECT 
        e.id AS event_id,
        p.id AS posting_id,
        a.account_type,
        a.name AS account_name
      FROM ${TablesV24.economicEvents} e
      JOIN ${TablesV24.postings} p ON e.id = p.economic_event_id
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      WHERE e.event_type = 'liability_settlement' AND a.account_type = 'expense';
    ''');
    if (test7.isNotEmpty) {
      throw MigrationVerificationException(
        message: 'Found credit card settlement events posting directly to expense accounts.',
        checkName: 'ZERO_CARD_PAYMENT_EXPENSE_DOUBLE_COUNTING',
        details: test7,
      );
    }

    // Test 8: Foreign Key Integrity Check
    final fkCheck = await executor.rawQuery('PRAGMA foreign_key_check;');
    if (fkCheck.isNotEmpty) {
      throw MigrationVerificationException(
        message: 'PRAGMA foreign_key_check returned ${fkCheck.length} violations.',
        checkName: 'PRAGMA_FOREIGN_KEY_CHECK',
        details: fkCheck,
      );
    }

    // Test 9: Database Integrity Check
    final integrityCheck = await executor.rawQuery('PRAGMA integrity_check;');
    final integrityStatus = integrityCheck.first.values.first as String?;
    if (integrityStatus != 'ok') {
      throw MigrationVerificationException(
        message: 'PRAGMA integrity_check failed with: $integrityStatus',
        checkName: 'PRAGMA_INTEGRITY_CHECK',
        details: integrityStatus,
      );
    }
  }
}
