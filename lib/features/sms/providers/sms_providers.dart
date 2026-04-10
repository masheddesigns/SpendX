import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/merchant_extractor.dart';
import '../../../models/category.dart';
import '../../../models/review_item.dart';
import '../../../models/transaction.dart';
import '../../../models/bank_account.dart';
import '../../../models/credit_card.dart';
import '../../../models/credit_transaction.dart';
import '../../../models/loan.dart';
import '../../../data/repositories/credit_repo.dart';
import '../../../data/repositories/loan_repo.dart';
import '../../../data/repositories/review_repo.dart';
import '../../../data/repositories/transaction_repo.dart';
import '../../../services/notification_service.dart';
import '../../merchant_rules/data/merchant_rule_repo.dart';
import '../../merchant_rules/providers/merchant_rule_providers.dart';
import '../../accounts/providers/account_providers.dart';
import '../../categories/providers/category_providers.dart';
import '../../review_queue/providers/review_providers.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../models/parsed_sms.dart';
import '../services/sms_service.dart';
import '../../../core/utils/category_classifier.dart';

// Re-export for SMS import usage
export '../../transactions/providers/transaction_providers.dart'
    show BulkTransactionEntry;

final isSmsEnabledProvider = StateProvider<bool>((ref) => false);

final smsServiceProvider = Provider<SmsService>((ref) => SmsService());

final importRecentSmsProvider = Provider((ref) {
  return ({int limit = 4000, DateTime? sinceDate}) async {
    final isEnabled = ref.read(isSmsEnabledProvider);
    if (!isEnabled) {
      debugPrint('📩 SMS import skipped: feature disabled');
      return 0;
    }

    await NotificationService.instance.init();
    await NotificationService.instance.requestPermissions();

    final permission = await Permission.sms.request();
    if (!permission.isGranted) {
      debugPrint('📩 SMS import skipped: permission denied');
      return 0;
    }

    final categories = await ref.read(categoryRepoProvider).getAll();
    var accounts = await ref.read(accountRepoProvider).getAll();

    if (accounts.isEmpty) {
      accounts = await _ensureAccountsFromSms(ref, limit: limit);
      if (accounts.isEmpty) {
        debugPrint('📩 SMS import skipped: no accounts available');
        await NotificationService.instance.cancel(41001);
        await NotificationService.instance.showInstant(
          id: 41002,
          title: 'SMS Import Skipped',
          body: 'Add at least one account before importing SMS.',
        );
        return 0;
      }
    }

    if (categories.isEmpty) {
      debugPrint('📩 SMS import skipped: no categories available');
      await NotificationService.instance.cancel(41001);
      await NotificationService.instance.showInstant(
        id: 41002,
        title: 'SMS Import Skipped',
        body: 'Categories are missing. Reopen the app and try again.',
      );
      return 0;
    }

    await NotificationService.instance.showProgress(
      id: 41001,
      title: 'Importing SMS',
      body: 'Scanning last 6 months of bank messages...',
      indeterminate: true,
    );

    var smsList = await ref
        .read(smsServiceProvider)
        .fetchRecent(limit: limit);

    // Filter by date range if specified
    if (sinceDate != null) {
      smsList = smsList.where((sms) => sms.date.isAfter(sinceDate)).toList();
      debugPrint('📩 SMS filtered to ${smsList.length} after ${sinceDate.toIso8601String()}');
    }
    if (smsList.isEmpty) {
      debugPrint('📩 SMS import found no parsable messages');
      return 0;
    }

    // Import session ID for tracing concurrent/duplicate runs
    final importId = DateTime.now().millisecondsSinceEpoch;
    debugPrint('📩 IMPORT[$importId] starting — ${smsList.length} SMS to process');

    // --- PHASE 1: Parse all SMS into BulkTransactionEntry objects ---
    // Pre-fetch mutable lookups that may grow as we auto-create accounts/cards.
    var cards = await ref.read(accountRepoProvider).getCards();
    final txRepo = TransactionRepo();
    final merchantRuleRepo = ref.read(merchantRuleRepoProvider);

    // Pre-fetch ALL existing external refs in one query (dedup optimization).
    // This replaces 500+ individual existsByExternalRef() calls.
    final allSmsRefs = smsList
        .map((sms) => _buildExternalRef(sms))
        .toList();
    final existingRefs = await txRepo.getExistingExternalRefs(allSmsRefs);
    debugPrint('📩 Pre-fetched ${existingRefs.length} existing refs');

    // Track refs seen within this batch to catch within-batch duplicates
    final seenRefs = <String>{};

    final entries = <BulkTransactionEntry>[];
    final total = smsList.length;

    for (var index = 0; index < total; index++) {
      final sms = smsList[index];
      final entry = await _parseSmsToEntry(
        ref: ref,
        sms: sms,
        categories: categories,
        accounts: accounts,
        cards: cards,
        existingRefs: existingRefs,
        seenRefs: seenRefs,
        merchantRuleRepo: merchantRuleRepo,
      );
      if (entry != null) {
        entries.add(entry);
        // Refresh mutable lists if auto-creation happened
        if (entry.transaction.accountId != null &&
            !accounts.any((a) => a.id == entry.transaction.accountId)) {
          accounts = await ref.read(accountRepoProvider).getAll();
        }
        if (entry.cardId != null && !cards.any((c) => c.id == entry.cardId)) {
          cards = await ref.read(accountRepoProvider).getCards();
        }
      }

      // Update progress notification every 50 messages
      if ((index + 1) % 50 == 0 || index == total - 1) {
        final percent = (((index + 1) / total) * 100).round();
        await NotificationService.instance.showProgress(
          id: 41001,
          title: 'Importing SMS',
          body: 'Parsed ${index + 1} of $total messages ($percent%)',
          maxProgress: total,
          progress: index + 1,
          indeterminate: false,
        );
      }
    }

    if (entries.isEmpty) {
      debugPrint('📩 SMS import: no new transactions to import');
      await NotificationService.instance.cancel(41001);
      await NotificationService.instance.showInstant(
        id: 41002,
        title: 'SMS Import Complete',
        body: 'No new transactions were imported.',
      );
      return 0;
    }

    // --- PHASE 1.5: Split by confidence ─────────────────────────────────
    // High confidence → auto-insert via bulk pipeline
    // Low confidence → review queue for manual approval
    final highConfidence = <BulkTransactionEntry>[];
    final lowConfidence = <BulkTransactionEntry>[];

    for (final entry in entries) {
      if (entry.transaction.source == 'credit_card_purchase' ||
          entry.transaction.source == 'credit_card_payment' ||
          entry.transaction.source == 'loan_payment') {
        // Liability transactions always auto-insert
        highConfidence.add(entry);
      } else if (entry.smsConfidence >= 0.70) {
        // Use the actual SMS parser confidence score
        highConfidence.add(entry);
      } else {
        lowConfidence.add(entry);
      }
    }

    debugPrint('📩 IMPORT[$importId] routing: '
        '${highConfidence.length} auto-insert, '
        '${lowConfidence.length} → review queue');

    // --- PHASE 2a: Send low-confidence to review queue ──────────────────
    if (lowConfidence.isNotEmpty) {
      final reviewRepo = ReviewRepo();
      final reviewItems = lowConfidence.map((entry) {
        final tx = entry.transaction;
        final sms = ParsedSms(
          amount: tx.amount,
          isCredit: tx.type == 'income',
          sender: '',
          body: tx.notes,
          date: tx.date,
          refId: tx.externalRef,
          confidence: entry.smsConfidence,
        );
        return ReviewItem(
          rawSms: tx.notes,
          parsed: sms,
          confidence: entry.smsConfidence,
        );
      }).toList();
      await reviewRepo.insertAll(reviewItems);
      ref.invalidate(reviewQueueProvider);
      ref.invalidate(reviewQueueCountProvider);
      debugPrint('📋 ${reviewItems.length} items sent to review queue');
    }

    // --- PHASE 2b: Bulk insert high-confidence entries ──────────────────
    await NotificationService.instance.showProgress(
      id: 41001,
      title: 'Importing SMS',
      body: 'Saving ${highConfidence.length} transactions...',
      indeterminate: true,
    );

    // Process in chunks for very large imports.
    // Each chunk is an atomic DB transaction — if one chunk fails,
    // previously committed chunks remain valid, and we skip to the next.
    //
    // Resume support: we persist the last successfully committed chunk index.
    const chunkSize = 200;
    final prefs = await SharedPreferences.getInstance();
    final resumeKey = 'sms_import_resume_$importId';

    final lastResumeKey = prefs.getString('sms_import_last_resume_key');
    final lastEntryCount = prefs.getInt('sms_import_last_entry_count') ?? 0;
    int startChunkIndex = 0;
    if (lastResumeKey != null && lastEntryCount == highConfidence.length) {
      startChunkIndex = prefs.getInt(lastResumeKey) ?? 0;
      if (startChunkIndex > 0) {
        debugPrint('📩 IMPORT[$importId] resuming from chunk index $startChunkIndex');
      }
    }

    await prefs.setString('sms_import_last_resume_key', resumeKey);
    await prefs.setInt('sms_import_last_entry_count', highConfidence.length);

    var imported = 0;
    for (var i = startChunkIndex; i < highConfidence.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, highConfidence.length);
      final chunk = highConfidence.sublist(i, end);
      try {
        await ref.read(addTransactionsBulkProvider)(chunk);
        imported += chunk.length;
        await prefs.setInt(resumeKey, i + chunkSize);
      } catch (e, st) {
        debugPrint('❌ IMPORT[$importId] chunk failed (items $i–$end): $e');
        debugPrint('$st');
      }
    }

    await prefs.remove(resumeKey);
    await prefs.remove('sms_import_last_resume_key');
    await prefs.remove('sms_import_last_entry_count');

    final totalImported = imported;
    final totalReview = lowConfidence.length;
    debugPrint('📩 IMPORT[$importId] complete: '
        '$totalImported inserted, $totalReview queued for review');
    final notificationBody = StringBuffer();
    if (totalImported > 0) {
      notificationBody.write('$totalImported transactions imported');
    }
    if (totalReview > 0) {
      if (notificationBody.isNotEmpty) notificationBody.write(', ');
      notificationBody.write('$totalReview need review');
    }
    if (notificationBody.isEmpty) {
      notificationBody.write('No new transactions found.');
    }
    // Dismiss the progress notification first
    await NotificationService.instance.cancel(41001);

    await NotificationService.instance.showInstant(
      id: 41002,
      title: 'SMS Import Complete',
      body: notificationBody.toString(),
    );
    return totalImported;
  };
});

/// Parse a single SMS into a BulkTransactionEntry without touching providers.
/// Returns null if the SMS should be skipped (duplicate, no account match, etc).
///
/// [existingRefs] — pre-fetched set of external_refs already in DB.
/// [seenRefs] — mutable set tracking refs already parsed in this batch.
Future<BulkTransactionEntry?> _parseSmsToEntry({
  required Ref ref,
  required ParsedSms sms,
  required List<Category> categories,
  required List<BankAccount> accounts,
  required List<CreditCard> cards,
  required Set<String> existingRefs,
  required Set<String> seenRefs,
  required MerchantRuleRepo merchantRuleRepo,
}) async {
  var mutableAccounts = accounts;

  if (mutableAccounts.isEmpty || categories.isEmpty) {
    mutableAccounts = await _ensureAccountsFromSms(ref, seedFrom: [sms]);
    if (mutableAccounts.isEmpty || categories.isEmpty) {
      debugPrint('📩 SMS import skipped: missing accounts or categories');
      return null;
    }
  }

  final smsKind = _kindFromParsed(sms) ?? _detectSmsKind(sms.body);
  final bank = sms.bankName ?? _resolveInstitutionKey(
    sender: sms.sender,
    body: sms.body,
    smsKind: smsKind,
  );
  final externalRef = _buildExternalRef(sms);

  // Dedup: check pre-fetched DB refs AND within-batch refs
  if (existingRefs.contains(externalRef)) {
    debugPrint('📩 SMS skipped: duplicate (DB) $externalRef');
    return null;
  }
  if (seenRefs.contains(externalRef)) {
    debugPrint('📩 SMS skipped: duplicate (batch) $externalRef');
    return null;
  }
  seenRefs.add(externalRef);

  if (smsKind == _SmsKind.bank) {
    mutableAccounts = await _ensureBankAccountForBank(
      ref,
      bank,
      mutableAccounts,
      last4: sms.last4,
    );
  }

  final account = smsKind == _SmsKind.creditCardPurchase
      ? null
      : resolveAccount(bank, mutableAccounts, last4: sms.last4);
  if (smsKind == _SmsKind.bank && account == null) {
    debugPrint('📩 SMS import skipped: no account match');
    return null;
  }

  final type = sms.isCredit ? 'income' : 'expense';
  final lower = sms.body.toLowerCase();
  final isCardPayment = smsKind == _SmsKind.creditCardPayment;
  final isCardSpend = smsKind == _SmsKind.creditCardPurchase;
  final isLoanPayment = smsKind == _SmsKind.loanPayment;
  final isTransfer =
      lower.contains('transfer') ||
      lower.contains('imps') ||
      lower.contains('neft') ||
      isCardPayment ||
      isLoanPayment;

  final keyword = (sms.merchant?.trim().isNotEmpty ?? false)
      ? sms.merchant!.trim().toLowerCase()
      : MerchantExtractor.extract(sms.body);

  // Multi-signal merchant rule lookup: exact keyword → contains match
  final merchantRule = await merchantRuleRepo.resolve(
    keyword: keyword,
    fullText: sms.body,
  );
  if (merchantRule != null) {
    // Bump usage count (tracks rule effectiveness)
    await merchantRuleRepo.upsert(keyword, merchantRule.categoryId,
        accountId: merchantRule.accountId);
  }

  final detectedName = merchantRule == null
      ? CategoryClassifier.detect(text: sms.body, type: type)
      : null;
  final category = _resolveCategory(
    categories: categories,
    preferredCategoryId: merchantRule?.categoryId,
    detectedName: detectedName,
    type: type,
  );

  final cardTarget = (isCardPayment || isCardSpend)
      ? await _ensureCreditCardForBank(bank, cards, last4: sms.last4)
      : null;
  final loanTarget = isLoanPayment ? await _ensureLoanForBank(bank) : null;
  final relatedTransferId = isCardPayment
      ? cardTarget?.id
      : isLoanPayment
      ? loanTarget?.id
      : resolveAccount(_detectTargetBank(sms.body), mutableAccounts)?.id;

  final transaction = Transaction(
    amount: sms.amount,
    userId: 'offline_user',
    type: isCardSpend ? 'expense' : (isTransfer ? 'transfer' : type),
    categoryId: isTransfer ? null : category?.id,
    accountId: isCardSpend ? null : account?.id,
    date: sms.date,
    notes: sms.merchant ?? sms.body,
    source: isCardPayment
        ? 'credit_card_payment'
        : isCardSpend
        ? 'credit_card_purchase'
        : isLoanPayment
        ? 'loan_payment'
        : isTransfer
        ? 'bank_transfer'
        : 'sms_import',
    relatedEntityId: relatedTransferId,
    externalRef: externalRef,
  );

  // Build liability side-effects
  double cardDelta = 0;
  CreditTransaction? creditTx;
  String? cardId;
  String? loanId;
  double loanDelta = 0;

  if (isCardSpend && cardTarget != null) {
    cardId = cardTarget.id;
    cardDelta = sms.amount; // increase outstanding
    creditTx = CreditTransaction(
      id: sms.refId?.trim().isNotEmpty == true
          ? sms.refId!.trim()
          : '${cardTarget.id}_${sms.date.millisecondsSinceEpoch}',
      cardId: cardTarget.id,
      amount: sms.amount,
      date: sms.date,
      category: category?.name ?? 'SMS Import',
      note: sms.body,
      type: 'purchase',
      status: 'active',
      categoryId: category?.id,
    );
  } else if (isCardPayment && cardTarget != null) {
    cardId = cardTarget.id;
    cardDelta = -sms.amount; // reduce outstanding
  }

  if (isLoanPayment && loanTarget != null) {
    loanId = loanTarget.id;
    loanDelta = sms.amount;
  }

  return BulkTransactionEntry(
    transaction: transaction,
    cardId: cardId,
    cardOutstandingDelta: cardDelta,
    creditTransaction: creditTx,
    loanId: loanId,
    loanPaidDelta: loanDelta,
    smsConfidence: sms.confidence,
  );
}

Future<List<BankAccount>> _ensureBankAccountForBank(
  Ref ref,
  String bank,
  List<BankAccount> accounts,
  {String? last4}
) async {
  if (bank == 'default') return accounts;
  if (resolveAccount(bank, accounts, last4: last4) != null) return accounts;
  final accountRepo = ref.read(accountRepoProvider);
  final account = BankAccount(
    name: _buildBankAccountName(bank, last4),
    bank: bank,
    accountType: 'savings',
    balance: 0,
    color: BankAccount.colorForType('savings'),
    icon: BankAccount.iconForType('savings'),
  );
  await accountRepo.create(account);
  debugPrint('🏦 SMS auto-created account: ${account.name}');
  ref.invalidate(accountsProvider);
  return accountRepo.getAll();
}

Future<CreditCard?> _ensureCreditCardForBank(
  String bank,
  List<CreditCard> cards,
  {String? last4}
) async {
  final existing = resolveCreditCard(bank, cards, last4: last4);
  if (existing != null) return existing;
  if (bank == 'default') return null;
  final repo = CreditRepo();
  final card = CreditCard(
    name: _buildCreditCardName(bank, last4),
    bank: bank,
    limitAmount: 0,
    last4: last4 ?? '0000',
  );
  await repo.insert(card);
  debugPrint('💳 SMS auto-created credit card: ${card.name}');
  return card;
}

Future<Loan?> _ensureLoanForBank(String bank) async {
  if (bank == 'default') return null;
  final repo = LoanRepo();
  final existing = await repo.getLoans();
  for (final loan in existing) {
    if (loan.bank.toLowerCase().contains(bank.toLowerCase())) {
      return loan;
    }
  }
  final loan = Loan(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    name: '$bank Loan',
    bank: bank,
    total: 0,
    interestRate: 0,
    tenureMonths: 0,
    monthlyInstallment: 0,
    startDate: DateTime.now(),
    paidAmount: 0,
    loanStatus: 'active',
    dueDay: 1,
  );
  await repo.insertLoan(loan);
  debugPrint('🏦 SMS auto-created loan: ${loan.name}');
  return loan;
}

// _syncRelatedLiability is now handled by BulkTransactionEntry side-effects
// in the bulk pipeline (addTransactionsBulkProvider).

String _buildExternalRef(ParsedSms sms) {
  // Priority 1: Use UTR/transaction reference (globally unique)
  if (sms.refId != null && sms.refId!.trim().length >= 6) {
    return sms.refId!.trim();
  }
  // Priority 2: Stable composite key (no hashCode — deterministic across runs)
  // sender|timestamp|amount|last4
  final parts = [
    sms.sender,
    sms.date.millisecondsSinceEpoch.toString(),
    sms.amount.toStringAsFixed(2),
    sms.last4 ?? '',
  ];
  return parts.join('|');
}

Future<List<BankAccount>> _ensureAccountsFromSms(
  Ref ref, {
  int limit = 4000,
  List<ParsedSms>? seedFrom,
}) async {
  final accountRepo = ref.read(accountRepoProvider);
  var accounts = await accountRepo.getAll();
  if (accounts.isNotEmpty) {
    return accounts;
  }

  final smsList =
      seedFrom ?? await ref.read(smsServiceProvider).fetchRecent(limit: limit);
  final bankAccounts = <String, String?>{};
  final creditCardBanks = <String, String?>{};
  final loanBanks = <String>{};
  for (final sms in smsList) {
    final bank = detectBank(sms.sender, sms.body);
    if (bank == 'default') {
      continue;
    }

    final smsKind = _detectSmsKind(sms.body);
    switch (smsKind) {
      case _SmsKind.creditCardPurchase:
      case _SmsKind.creditCardPayment:
        creditCardBanks.putIfAbsent(_entityKey(bank, sms.last4), () => sms.last4);
        break;
      case _SmsKind.loanPayment:
        loanBanks.add(bank);
        break;
      case _SmsKind.bank:
        if (_looksLikeBankAccountMessage(sms.body, sms.sender)) {
          bankAccounts.putIfAbsent(_entityKey(bank, sms.last4), () => sms.last4);
        }
        break;
    }
  }

  for (final entry in bankAccounts.entries) {
    final bank = _bankFromEntityKey(entry.key);
    final account = BankAccount(
      name: _buildBankAccountName(bank, entry.value),
      bank: bank,
      accountType: 'savings',
      balance: 0,
      color: BankAccount.colorForType('savings'),
      icon: BankAccount.iconForType('savings'),
    );
    await accountRepo.create(account);
    debugPrint('🏦 SMS auto-created account: ${account.name}');
  }

  final existingCards = await accountRepo.getCards();
  for (final entry in creditCardBanks.entries) {
    final bank = _bankFromEntityKey(entry.key);
    await _ensureCreditCardForBank(bank, existingCards, last4: entry.value);
  }

  for (final bank in loanBanks) {
    await _ensureLoanForBank(bank);
  }

  if (bankAccounts.isEmpty && creditCardBanks.isEmpty && loanBanks.isEmpty) {
    final fallbackAccount = BankAccount(
      name: 'SMS Imported Account',
      bank: 'Imported',
      accountType: 'savings',
      balance: 0,
      color: BankAccount.colorForType('savings'),
      icon: BankAccount.iconForType('savings'),
    );
    await accountRepo.create(fallbackAccount);
    debugPrint('🏦 SMS auto-created fallback account: ${fallbackAccount.name}');
  }

  ref.invalidate(accountsProvider);
  accounts = await accountRepo.getAll();
  return accounts;
}

String detectBank(String sender, String body) {
  final text = '$sender $body'.toLowerCase();

  if (_looksLikeJupiterSavings(text)) return 'FEDERAL';
  if (_looksLikeJupiterEdgeCard(text)) return 'CSB';

  for (final entry in _bankAliases.entries) {
    for (final alias in entry.value) {
      if (text.contains(alias)) {
        return entry.key;
      }
    }
  }
  return 'default';
}

String _resolveInstitutionKey({
  required String sender,
  required String body,
  required _SmsKind smsKind,
}) {
  final bank = detectBank(sender, body);
  if (smsKind == _SmsKind.creditCardPurchase ||
      smsKind == _SmsKind.creditCardPayment) {
    final issuer = _detectCreditCardIssuer('$sender $body');
    if (issuer != 'default') {
      return issuer;
    }
  }
  return bank;
}

const Map<String, List<String>> _bankAliases = {
  'HDFC': ['hdfc', 'hdfcbk'],
  'SBI': ['sbi', 'sbibnk'],
  'ICICI': ['icici', 'icicib'],
  'AXIS': ['axis', 'axisbk'],
  'KOTAK': ['kotak', 'kotakb'],
  'IDFC': ['idfc'],
  'IDBI': ['idbi'],
  'BOB': ['bob', 'baroda'],
  'YES': ['yesbank', 'yesbk'],
  'FEDERAL': ['federal'],
  'INDUSIND': ['indusind'],
  'CANARA': ['canara'],
  'PNB': ['pnb', 'punjab national'],
  'RBL': ['rbl'],
  'HSBC': ['hsbc'],
  'AU': ['au small finance', 'aubank', 'au bank'],
  'DBS': ['dbs', 'digibank'],
  'STANDARD CHARTERED': ['standard chartered', 'scb'],
  'UNION': ['union bank', 'uboi'],
  'BOM': ['bank of maharashtra', 'mahabank'],
  'IOB': ['indian overseas bank', 'iob'],
  'INDIAN BANK': ['indian bank'],
};

const Map<String, List<String>> _creditCardAliases = {
  'ICICI': [
    'amazon pay icici',
    'amazon pay credit card',
    'makemytrip icici',
    'mmt icici',
    'hpcl super saver',
    'hpcl coral',
    'coral credit card',
    'sapphiro',
    'rubyx',
    'emeralde',
    'manchester united credit card',
    'ferrari credit card',
    'icici credit card',
    'icici card',
  ],
  'CSB': [
    'jtedge',
    'edge csb',
    'edge+ csb',
    'jupiter edge',
    'csb bank credit card',
    'edge rupay',
  ],
  'SBI': [
    'simplysave',
    'simplyclick',
    'cashback sbi',
    'pulse card',
    'prime card',
    'sbi card',
  ],
  'HDFC': [
    'millennia',
    'regalia',
    'diners club',
    'swiggy hdfc',
    'pixel card',
    'tata neu hdfc',
    'hdfc credit card',
  ],
  'AXIS': [
    'flipkart axis',
    'my zone',
    'ace credit card',
    'atlas credit card',
    'axis credit card',
  ],
  'HSBC': [
    'hsbc live+',
    'hsbc platinum',
    'hsbc cashback',
    'hsbc credit card',
  ],
  'RBL': [
    'rbl shoprite',
    'zomato edition',
    'bajaj finserv rbl',
    'rbl credit card',
  ],
  'STANDARD CHARTERED': [
    'smart credit card',
    'ultimate credit card',
    'easemytrip credit card',
    'standard chartered credit card',
  ],
};

enum _SmsKind { bank, creditCardPurchase, creditCardPayment, loanPayment }

/// Map the parser's SmsKind to the provider's internal _SmsKind.
_SmsKind? _kindFromParsed(ParsedSms sms) {
  switch (sms.kind) {
    case SmsKind.creditCardSpend:
      return _SmsKind.creditCardPurchase;
    case SmsKind.creditCardPayment:
      return _SmsKind.creditCardPayment;
    case SmsKind.loanEmi:
      return _SmsKind.loanPayment;
    case SmsKind.bankDebit:
    case SmsKind.bankCredit:
    case SmsKind.upiSend:
    case SmsKind.upiReceive:
    case SmsKind.atm:
    case SmsKind.refund:
    case SmsKind.transfer:
      return _SmsKind.bank;
    case SmsKind.unknown:
      return null; // fallback to old detection
  }
}

_SmsKind _detectSmsKind(String body) {
  final lower = body.toLowerCase();

  if (_looksLikeJupiterEdgeCard(lower)) {
    if (lower.contains('payment') || lower.contains('paid')) {
      return _SmsKind.creditCardPayment;
    }
    return _SmsKind.creditCardPurchase;
  }

  if (_looksLikeIciciCoBrandedCard(lower)) {
    if (lower.contains('payment') || lower.contains('paid towards card')) {
      return _SmsKind.creditCardPayment;
    }
    return _SmsKind.creditCardPurchase;
  }

  final mentionsCreditCard =
      lower.contains('credit card') ||
      lower.contains('card ending') ||
      lower.contains('card xx') ||
      lower.contains('card no');

  if (mentionsCreditCard &&
      (lower.contains('spent') ||
          lower.contains('debited') ||
          lower.contains('swiped') ||
          lower.contains('purchase'))) {
    return _SmsKind.creditCardPurchase;
  }

  if (lower.contains('card payment') ||
      lower.contains('paid towards card') ||
      (mentionsCreditCard &&
          (lower.contains('payment received') ||
              lower.contains('payment done')))) {
    return _SmsKind.creditCardPayment;
  }

  if (lower.contains('loan payment') ||
      lower.contains('emi') ||
      lower.contains('installment due') ||
      lower.contains('emi due')) {
    return _SmsKind.loanPayment;
  }

  return _SmsKind.bank;
}

bool _looksLikeJupiterSavings(String text) {
  return text.contains('jupiter') &&
      (text.contains('savings account') ||
          text.contains('salary account') ||
          text.contains('jupiter account') ||
          text.contains('federal bank') ||
          text.contains('debit card') ||
          text.contains('upi'));
}

bool _looksLikeJupiterEdgeCard(String text) {
  for (final keyword in _creditCardAliases['CSB'] ?? const <String>[]) {
    if (text.contains(keyword)) {
      return true;
    }
  }
  return false;
}

bool _looksLikeIciciCoBrandedCard(String text) {
  for (final keyword in _creditCardAliases['ICICI'] ?? const <String>[]) {
    if (text.contains(keyword)) {
      return true;
    }
  }
  return false;
}

String _detectCreditCardIssuer(String text) {
  final lower = text.toLowerCase();
  for (final entry in _creditCardAliases.entries) {
    for (final keyword in entry.value) {
      if (lower.contains(keyword)) {
        return entry.key;
      }
    }
  }
  final mentionsCard =
      lower.contains('credit card') ||
      lower.contains('card ending') ||
      lower.contains('card xx') ||
      lower.contains('card no') ||
      lower.contains('rupay credit card') ||
      lower.contains('visa credit card') ||
      lower.contains('mastercard credit card');
  if (mentionsCard) {
    final aliasIssuer = _detectAliasKey(lower, _bankAliases);
    if (aliasIssuer != 'default') {
      return aliasIssuer;
    }
  }
  if (lower.contains('credit card') && lower.contains('jupiter')) return 'CSB';
  return 'default';
}

bool _looksLikeBankAccountMessage(String body, String sender) {
  final text = '$sender $body'.toLowerCase();
  const bankCues = [
    'a/c',
    'account',
    'acct',
    'savings',
    'salary account',
    'current account',
    'upi',
    'imps',
    'neft',
    'rtgs',
    'available balance',
    'avl bal',
    'credited to',
    'debited from',
    'deposited',
    'withdrawn',
    'cash withdrawal',
  ];
  const cardOnlyCues = [
    'credit card',
    'card ending',
    'card xx',
    'card no',
    'statement due',
    'total due',
    'minimum due',
    'available limit',
    'spent on your card',
    'credit limit',
  ];

  final hasBankCue = bankCues.any(text.contains);
  final hasCardOnlyCue = cardOnlyCues.any(text.contains);

  return hasBankCue && !hasCardOnlyCue;
}

BankAccount? resolveAccount(String bank, List<BankAccount> accounts, {String? last4}) {
  if (accounts.isEmpty) return null;
  if (bank == 'default') {
    return accounts.length == 1 ? accounts.first : null;
  }
  if (last4 != null && last4.length == 4) {
    for (final account in accounts) {
      final haystack = '${account.bank} ${account.name}'.toLowerCase();
      if (haystack.contains(bank.toLowerCase()) && haystack.contains(last4)) {
        return account;
      }
    }
  }
  for (final account in accounts) {
    final haystack = '${account.bank} ${account.name}'.toLowerCase();
    if (haystack.contains(bank.toLowerCase())) {
      return account;
    }
  }
  return null;
}

CreditCard? resolveCreditCard(String bank, List<CreditCard> cards, {String? last4}) {
  if (cards.isEmpty) return null;
  if (bank == 'default') {
    return cards.length == 1 ? cards.first : null;
  }
  if (last4 != null && last4.length == 4) {
    for (final card in cards) {
      final haystack = '${card.bank} ${card.name}'.toLowerCase();
      if (haystack.contains(bank.toLowerCase()) && card.last4 == last4) {
        return card;
      }
    }
  }
  for (final card in cards) {
    final haystack = '${card.bank} ${card.name}'.toLowerCase();
    if (haystack.contains(bank.toLowerCase())) {
      return card;
    }
  }
  return null;
}

String _entityKey(String bank, String? last4) =>
    last4?.length == 4 ? '$bank|$last4' : bank;

String _bankFromEntityKey(String key) => key.split('|').first;

String _buildBankAccountName(String bank, String? last4) =>
    last4?.length == 4 ? '$bank Account $last4' : '$bank Account';

String _buildCreditCardName(String bank, String? last4) =>
    last4?.length == 4 ? '$bank Credit Card $last4' : '$bank Credit Card';

String _detectTargetBank(String body) {
  return _detectAliasKey(body.toLowerCase(), _bankAliases);
}

String _detectAliasKey(String text, Map<String, List<String>> aliases) {
  for (final entry in aliases.entries) {
    for (final alias in entry.value) {
      if (text.contains(alias)) {
        return entry.key;
      }
    }
  }
  return 'default';
}

Category? _resolveCategory({
  required List<Category> categories,
  required String? preferredCategoryId,
  required String? detectedName,
  required String type,
}) {
  if (preferredCategoryId != null) {
    for (final category in categories) {
      if (category.id == preferredCategoryId) {
        return category;
      }
    }
  }

  if (detectedName != null) {
    for (final category in categories) {
      if (category.type == type && category.name == detectedName) {
        return category;
      }
    }
  }

  final fallbackName = type == 'income' ? 'Other Income' : 'Others';
  for (final category in categories) {
    if (category.type == type && category.name == fallbackName) {
      return category;
    }
  }

  for (final category in categories) {
    if (category.type == type) {
      return category;
    }
  }

  return categories.isNotEmpty ? categories.first : null;
}
