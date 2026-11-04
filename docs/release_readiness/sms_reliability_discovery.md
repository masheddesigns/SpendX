# SpendX Release Readiness — Pillar 2: SMS Reliability & Parser Robustness Discovery

**Document Version:** 1.0.0
**Target Release:** SpendX 2.1.0
**Phase:** Pillar 2 Discovery & Technical Mapping
**Status:** Discovery Complete — Production Code Frozen (No parser modifications applied)

---

## 1. Architectural Architecture & Pipeline Separation

SpendX maintains strict boundary isolation between raw SMS text parsing, semantic event classification, evidence deduplication, and canonical double-entry ledger posting.

```
┌────────────────────────────────────────────────────────┐
│ 1. Raw SMS Ingestion (Native Broadcast / Inbox Scan)   │
│    - MethodChannel 'spendx/sms_live'                   │
│    - flutter_sms_inbox query (Inbox batch import)      │
└──────────────────────────┬─────────────────────────────┘
                           │ (body, sender)
                           ▼
┌────────────────────────────────────────────────────────┐
│ 2. Text Normalization & Extraction                     │
│    - TransactionTextParser                             │
│    - Currency context OCR repair & whitespace cleanup  │
│    - Amount, Date, Reference, Last4 extraction         │
└──────────────────────────┬─────────────────────────────┘
                           │ ParsedTransaction
                           ▼
┌────────────────────────────────────────────────────────┐
│ 3. Semantic Event Classification & Gatekeeping         │
│    - SmsImportService.classifyMessage()                │
│    - Gate 0: Hard OTP / 2FA rejection                  │
│    - Gate 1: Hard Promotional / Non-transaction filter │
│    - Gate 2: Numeric Personal Sender rejection         │
│    - Gate 3: Sender shortcode validation               │
│    - Event Classification: expense, income, card spend,│
│      card payment, refund, failed, bill reminder       │
└──────────────────────────┬─────────────────────────────┘
                           │ SmsClassification
                           ▼
┌────────────────────────────────────────────────────────┐
│ 4. Forensic Evidence & Deduplication Engine            │
│    - LiveSmsService._alreadyInApp()                    │
│    - Layer A: External Reference match (RRN / UTR)     │
│    - Layer B: Cryptographic SHA-256 Body Fingerprint   │
│    - Layer C: Temporal window (±30m) & Fuzzy Merchant  │
│    - Cross-Message Reconciliation (Bank Debit + CC Pay)│
└──────────────────────────┬─────────────────────────────┘
                           │ Validated Unposted Event
                           ▼
┌────────────────────────────────────────────────────────┐
│ 5. Canonical Double-Entry Persistence                  │
│    - FinancialTransactionService.createTransaction()   │
│    - AppDatabase SQLite Schema v24 (EconomicEvents)    │
│    - Immutability Triggers, Balanced Postings (2-3 leg)│
└────────────────────────────────────────────────────────┘
```

> [!IMPORTANT]
> **Core Release Invariant:** A correctly parsed SMS is **not** automatically a correctly posted transaction. Testing must evaluate Parser Accuracy (Text $\rightarrow$ Model) independently from Accounting Execution (Model $\rightarrow$ Canonical Postings).

---

## 2. Bank-Specific SMS Coverage Matrix (Indian Ecosystem)

SpendX supports major Indian public, private, digital banking, and credit card issuers via deterministic sender pattern recognition and tailored regex templates.

| Bank / Entity | Verified Sender Codes | Typical SMS Formats & Tokens | Account & Reference Identifiers | Supported Event Types |
| :--- | :--- | :--- | :--- | :--- |
| **HDFC Bank** | `HDFCBK`, `HDFCBN`, `HDFC` | `Debited Rs. [Amt] from A/c **[Last4] on [Date] via UPI to [Merchant]. Ref: [Ref]. Bal: Rs. [Bal]`<br>`PAYMENT OF Rs. [Amt] RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH [Last4]... AVAILABLE LIMIT IS RS. [Limit]` | `A/c **[4]`, `ENDING WITH [4]`, `Ref: [Digits]` | UPI Debit, CC Spend, CC Payment, NetBanking, Balance |
| **ICICI Bank** | `ICICIB`, `ICICIT`, `ICICI` | `INR [Amt] spent using ICICI Bank Card XX[Last4] on [Date] on [Merchant]. Avl Limit: INR [Limit]`<br>`Payment of Rs [Amt] has been received on your ICICI Bank Credit Card XX[Last4] through Bharat Bill Payment System` | `Card XX[4]`, `Acct XX[4]`, `Ref no [Digits]` | CC Purchase, BBPS Bill Payment, ATM Withdrawal, UPI Debit |
| **State Bank of India (SBI)** | `CBSSBI`, `SBIINB`, `SBICRD`, `SBI` | `Your A/C XXXXX[Last4] Credited INR [Amt] on [Date] -Deposit of Cash... Avl Bal INR [Bal]`<br>`Txn of Rs [Amt] on SBI Credit Card [Last4] at [Merchant]` | `A/C XXXXX[4]`, `Card [4]`, `UPI/DR/[Ref]/` | Cash Deposit, Salary Credit, Card Purchase, Mandates |
| **Axis Bank** | `AXSBK`, `AXISBK`, `AXNS` | `INR [Amt] debited from A/c no. XX[Last4] on [Date] towards UPI/P2M/[Ref]/[Merchant]. Avl Bal: INR [Bal]` | `A/c no. XX[4]`, `UPI/P2M/[Ref]`, `RRN [Digits]` | UPI P2M/P2P, Bank Debit, Balance Statement |
| **Kotak Mahindra** | `KOTAKB`, `KOTAK` | `Sent Rs. [Amt] from Kotak Bank AC X[Last4] to [Merchant] on [Date]. Ref [Ref]. Bal: Rs [Bal]` | `AC X[4]`, `Ref [Digits]`, `UPI/[Ref]` | UPI Spend, IMPS Transfer, Account Balance |
| **Federal Bank** | `FEDBNK` | `Debited Rs [Amt] from a/c X[Last4] on [Date] via UPI to [Merchant]. Ref [Ref]. Bal Rs [Bal]` | `a/c X[4]`, `Ref [Digits]` | UPI Debit, ATM Cash, Balance Hit |
| **Jupiter / CSB Bank** | `JTEDGE`, `CSB` | `₹[Amt] paid from your Edge CSB Bank RuPay Credit Card to [Merchant]...`<br>`Your payment of Rs [Amt] for your Edge CSB Bank RuPay Credit Card was successful.` | `RuPay Credit Card`, `Edge CSB`, `card ending [4]` | RuPay CC UPI, Bill Settlement, Available Limit |
| **OneCard / BOBCARD** | `ONECRD`, `BOBCRD`, `BOBONE` | `You have spent INR [Amt] on your OneCard at [Merchant] on [Date]. Available Limit: INR [Limit]` | `OneCard`, `BOBCARD`, `ending [4]` | Card Purchase, Statement Notice, Limit Alert |
| **Jio Payments Bank** | `JIOPBS`, `JIOFBR` | `Rs. [Amt] Sent from x[Last4] on [Date] Info: UPI/DR/[Ref]/[Merchant]` | `x[4]`, `UPI/DR/[Ref]/` | UPI Merchant Payment, P2P Transfer |
| **Wallets & Gateways** | `PAYTM`, `QCAMZN`, `JUSPAY`, `AMZPAY` | `Paid Rs. [Amt] on [Merchant] using Amazon Pay Balance / Paytm Wallet` | Wallet reference, Order ID | Wallet Expense, Top-up Credit |

---

## 3. Classification Semantics & Invariants

Each message is classified into one of the canonical financial event types:

```dart
enum SmsEventType {
  expense,              // Bank asset debit (ordinary spend)
  income,               // Bank asset credit (deposit, salary)
  creditCardPurchase,   // Card liability credit, category debit
  creditCardPayment,    // Paying bank credit, card liability debit (Zero Expense, Zero Income)
  refund,               // Contra-expense credit to expense account / card
  failed,               // Declined, cancelled, or failed transaction (No financial impact)
  billReminder,         // Upcoming e-mandate, autopay, or statement due date
}
```

### Critical Domain Invariants:
1. **Credit Card Bill Settlement Invariant:**
   - A bill payment notification (e.g. HDFC/ICICI BBPS payment received) must **never** be classified as income or duplicate expense.
   - It debits card liability (`accounts.account_type = 'liability'`) and credits the funding bank asset (`accounts.account_type = 'asset'`).
   - Net expense effect = ₹0.00; Net income effect = ₹0.00.
2. **Refund Contra-Expense Invariant:**
   - A refund SMS credits the relevant expense account (or `sys_exp_refunds` if uncategorized).
   - It increases liquid bank assets or reduces credit card liability.
   - It must never be classified as income.
3. **Failed / Declined Isolation:**
   - Transaction texts matching `TransactionTextParser.isFailedPayment` (e.g. "transaction failed", "declined", "insufficient funds") are routed to `SmsEventType.failed`.
   - They register zero postings in the canonical ledger, though trailing balance statements may update account cached balances.

---

## 4. Rejection & False-Positive Prevention Hierarchy

The classifier evaluates messages through a 4-tier filtering pipeline:

```
[Incoming SMS]
      │
      ▼
┌────────────────────────────────────────────────────────┐
│ Tier 0: OTP & Authentication Rejection                 │
│ - Matches `_otpAuthRe` (OTP, passcode, PIN reset, #123)│
│ - Immediate discard (0 transactions, 0 balances)       │
└──────────────────────────┬─────────────────────────────┘
                           │ (Clean)
                           ▼
┌────────────────────────────────────────────────────────┐
│ Tier 1: Personal Numeric Sender Rejection              │
│ - Sender matches `^\d+$` (e.g. +919876543210)          │
│ - Distinguishes human P2P chats from bank shortcodes   │
└──────────────────────────┬─────────────────────────────┘
                           │ (Shortcode)
                           ▼
┌────────────────────────────────────────────────────────┐
│ Tier 2: Non-Transactional Noise Filter                 │
│ - Matches `_nonTransactionRe`                          │
│ - Rejects: Credit limit hike offers, promotional loans,│
│   telecom recharge alerts, weather warnings, courier   │
│ - Whitelist override: Preserves CC payments, CC refunds│
└──────────────────────────┬─────────────────────────────┘
                           │ (Candidate Transaction)
                           ▼
┌────────────────────────────────────────────────────────┐
│ Tier 3: Sender Validation & Financial Verb Gate        │
│ - If sender is non-bank: requires strong transaction   │
│   verbs ("debited from") AND explicit account token    │
│ - Must satisfy amount > 0 and confidence ≥ 0.40        │
└────────────────────────────────────────────────────────┘
```

---

## 5. Deduplication & Idempotency Pipeline

To prevent duplicate postings from network retries, duplicate SMS broadcasts, or manual re-scans, SpendX implements four distinct deduplication layers in `LiveSmsService._alreadyInApp()`:

1. **Gate 1: Transaction External Reference (RRN / UTR):**
   - Matches `evidence.external_reference` exactly against canonical evidence.
   - Prevents duplicate ingestion when banks broadcast both an SMS and an in-app confirmation with the same reference number.
2. **Gate 2: Cryptographic Body Fingerprint (SHA-256):**
   - Computes `SHA256(raw_sms_body)`.
   - Queries `evidence.body_sha256`. Identical SMS broadcasts received twice are discarded at zero cost.
3. **Gate 3: Temporal Proximity Window & Fuzzy Merchant Match:**
   - If an SMS lacks an external reference, checks for transactions within $\pm 30$ minutes with identical amount.
   - Normalizes and compares merchant names (e.g. "Zomato" vs "Zomato Online") using prefix and substring matching.
4. **Gate 4: Cross-Message Reconciliation (Bank Debit + Card Confirmation):**
   - When paying a credit card bill via UPI:
     1. Bank emits: *"Debited Rs 5,000 from A/C XX1234 towards CC Bill"* $\rightarrow$ recorded as bank debit.
     2. Credit Card emits: *"Payment of Rs 5,000 received for Card XX5007"* $\rightarrow$ received minutes later.
   - `_findRecentBankDebitForCcPayment` identifies the matching bank debit and **updates** it into a single canonical `credit_payment` event (linking paying bank and credit card), preventing double-counting.

---

## 6. Edge Cases, Risks, & Gaps Identified for Pillar 2

1. **Reference Collision Under Truncation:**
   - Some banks (e.g. Federal Bank, SBI) emit short reference numbers or omit RRN in SMS.
   - Need to verify that distinct transactions with identical amounts on the same day without reference numbers are not falsely collapsed.
2. **Multi-Currency Transactions:**
   - International spends on credit cards (USD, EUR, AED, GBP) report both foreign currency and converted INR amounts (e.g. *"USD 15.00 spent... INR 1,280.50 debited"*).
   - Parser must extract the INR debited amount, not the foreign currency figure.
3. **Overlapping Account Keywords:**
   - When a user has multiple accounts with the same bank (e.g. two HDFC savings accounts or an HDFC savings account and an HDFC credit card), parser must strictly isolate `last4` to avoid balance and transaction misattribution.
4. **Historical Inbox Re-scan Safety:**
   - Scanning the inbox for the past 60 days must be provably idempotent: 0 duplicate events created when scanning an already-populated ledger.
5. **Permission Lifecycle Recovery:**
   - Revoking SMS permission in Android settings, generating transactions, and re-granting permission must resume cleanly without crashes or partial imports.

---

## 7. Recommended Pillar 2 Execution Plan

1. **Step 2.1: Multi-Bank SMS Fixture Test Suite:**
   - Construct a dedicated real-world SMS test fixture suite (`test/features/sms_parser_matrix_test.dart`) containing 50+ genuine bank formats across HDFC, ICICI, SBI, Axis, Kotak, Federal Bank, Jupiter, OneCard, IndusInd, PNB, and BBPS.
2. **Step 2.2: Parser Isolation Verification:**
   - Verify amount extraction, direction detection, last4 extraction, merchant normalization, and reference parsing strictly at the parser layer.
3. **Step 2.3: Rejection & Noise Verification:**
   - Test adversarial non-financial SMS (OTPs, promo limits, weather, regional language alerts, fake transaction spam).
4. **Step 2.4: Deduplication & Cross-Message Ingestion Verification:**
   - Test simultaneous SMS broadcasts, network retry replays, and Bank Debit $\rightarrow$ CC Payment unification.
5. **Step 2.5: Targeted Fixes (If any parser defects or edge-case gaps are discovered):**
   - Apply minimal regex or classification fixes with zero UI or schema alterations.
