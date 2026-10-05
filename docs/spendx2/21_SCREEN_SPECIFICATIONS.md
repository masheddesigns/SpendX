# SpendX 2.0 — Screen Specifications

**Document**: `21_SCREEN_SPECIFICATIONS.md`  
**Status**: APPROVED SPECIFICATION  
**Scope**: Complete Screen Inventory, Layout Wireframes, State Contracts, and Interactions

---

## 1. Onboarding & Baseline Setup

### 1.1 `SplashScreen`
- **Visuals**: Obsidian black canvas (`surface.canvas`). Center geometric SpendX logomark in brushed titanium white.
- **Behavior**:
  - Initializes SQLite database connection and runs fast integrity check.
  - If PIN/Biometrics enabled in `SecurityService` $\rightarrow$ transitions smoothly to `PinLockScreen`.
  - If no accounts exist in `accounts` table $\rightarrow$ transitions to `WelcomeScreen`.
  - Otherwise $\rightarrow$ transitions directly to `HomeScreen`.

### 1.2 `WelcomeScreen` & `InitialAccountSetupScreen`
- **Header**: Large title: *"Establish your baseline."* Subtitle: *"SpendX is a local-first financial instrument. Your data never leaves your device."*
- **Form Controls**:
  - **Account Name**: e.g. `"HDFC Salary"`, `"Cash Wallet"`.
  - **Account Type**: Segmented picker: `[Checking | Savings | Cash | Credit Card]`.
  - **Opening Balance**: Monetary input with large tabular numbers (`₹0.00`).
- **Accounting Action**: Saving writes an opening balance posting: Debit `Asset:Account`, Credit `Equity:OpeningBalance`. (Income Statement remains strictly ₹0).

---

## 2. Pillar 1: Home (Financial State & Pulse)

### 2.1 `HomeDashboardScreen`
```
+-------------------------------------------------------------+
| [Profile / Shield]    SPENDX 2.0          [Sparkle AI] [Bell]|
+-------------------------------------------------------------+
|                                                             |
|  [ GLASS 2: HERO FINANCIAL STATE CARD ]                     |
|  Total Liquid Cash:  ₹ 1,42,850.00                          |
|  ---------------------------------------------------------  |
|  Safe to Spend:      ₹   84,200.00                          |
|  (After ₹35k Goal Earmarks & ₹23.6k Known 14-Day Bills)     |
|                                                             |
+-------------------------------------------------------------+
|                                                             |
|  [ OPTIONAL REVIEW TRAY: 2 Transactions Need Review ]       |
|  "Amazon ₹1,250 from SMS"                [Review All ->]    |
|                                                             |
+-------------------------------------------------------------+
|                                                             |
|  UPCOMING 14-DAY COMMITMENTS                                |
|  - 10 Oct: Home Loan EMI               - ₹ 32,450  [CONFIRMED]
|  - 15 Oct: Bescom Electricity          - ₹  2,400  [EXPECTED] 
|  - 30 Oct: Salary (Employer Inc)       + ₹ 1,50,000 [EXPECTED] 
|                                                             |
+-------------------------------------------------------------+
|                                                             |
|  RECENT VERIFIED ACTIVITY                                   |
|  [Cart]  Whole Foods Market             - ₹  3,420  [SMS]    |
|  [Move]  HDFC -> SBI Transfer           ⇄ ₹ 20,000  [MANUAL] |
|  [Food]  Starbucks Coffee               - ₹    650  [OCR]    |
|                                                             |
+-------------------------------------------------------------+
| [Home (Active)]   [Activity]     (+)     [Money]    [Plan]  |
+-------------------------------------------------------------+
```

---

## 3. Pillar 2: Activity (Canonical Events & Ingestion)

### 3.1 `ActivityScreen` (Chronological Feed)
- **Top Bar**: Search bar (`"Search merchant, amount, or tag..."`) with filter icon.
- **Filter Chips Row**: `[All]`, `[Expenses]`, `[Income]`, `[Transfers]`, `[Refunds]`, `[Review Queue (3)]`.
- **Feed Sectioning**: Sticky date headers: `"TODAY"`, `"YESTERDAY"`, `"SEPTEMBER 2026"`.
- **List Item Interaction**:
  - Tap: Pushes `EventDetailScreen`.
  - Swipe Left: Quick tag or categorize sheet.
  - Swipe Right: Prohibited on verified events (prevents accidental destructive actions).

### 3.2 `EventDetailScreen` (Canonical Presentation)
The screen adapts its structure dynamically based on the event's type:

#### A. Standard Expense View:
- Header: Large merchant name, Net Amount in bold (`-₹2,500.00`).
- Account: Paid from `HDFC Salary (XX1234)`.
- Category: `Food:Dining` (Tap to change category).
- Attached Evidence: Displays proof chip: `[Bank SMS: "Txn ₹2,500 debited... at 14:12 on 02-Oct"]` and receipt thumbnail if attached.
- Action Buttons: `[Edit Details (✎)]`, `[Delete / Reverse (🗑)]`.

#### B. Internal Transfer View:
- Header: `"Account Transfer"`, Amount: `⇄ ₹20,000.00`.
- Flow Graphic: `[HDFC Bank] ──────( ₹20,000 )──────> [SBI Savings]`.
- Accounting Proof Note: *"Balance exchange between own accounts. Net income and expense impact: ₹0."*

#### C. Credit Card Payment View:
- Header: `"Credit Card Settlement"`, Amount: `₹18,400.00`.
- Flow Graphic: `[Bank Checking] ──( ₹18,400 )──> [ICICI Amazon Card]`.
- Accounting Proof Note: *"Extinguished revolving credit debt. Does not affect monthly consumption expenses."*

#### D. Refund View:
- Header: `"Merchant Refund"`, Amount: `↶ +₹2,000.00` in warm amber.
- Link: *"Offsets original purchase: Nike Shoes (28 Sep)"*.
- Net Effect: *"Reduces month-to-date Shopping expenses by ₹2,000.00"*.

---

## 4. Ingestion Review & Duplicate Queues

### 4.1 `ReviewQueueScreen`
- **Header**: Large Title: *"Pending Ingestion Review (3)"*.
- **List Items**: Rendered using `ReviewCard` components.
- **Card Contents**:
  - Detection source badge (`[Live SMS]` or `[Camera OCR]`).
  - Extracted Merchant and Amount.
  - Proposed Account and Category dropdowns.
  - Quick action buttons: `[Confirm & Post]` (one-tap commit) and `[Discard]`.

### 4.2 `DuplicateReviewScreen`
- **Header**: *"Potential Duplicate Detected"*.
- **Comparison View**: Side-by-side comparison of the existing transaction and the newly ingested evidence.
- **Decision Controls**:
  - `[Merge & Attach Evidence]`: Links the new SMS/OCR to the existing event as secondary proof. No new postings.
  - `[Keep as Separate Event]`: Confirms that two distinct purchases occurred. Emits new ledger postings.

---

## 5. Pillar 3: Money (Assets, Cards & Liabilities)

### 5.1 `MoneyOverviewScreen`
- **Total Balance Sheet Card**: Assets (`₹3,45,000`) minus Debts (`₹1,20,000`) = **Net Worth (`₹2,25,000`)**.
- **Section 1: Liquid Accounts**: Checking, Savings, Cash Wallets. Each row displays Verified Balance + Earmarked Sub-label.
- **Section 2: Credit Cards**: Each card displays Current Liability, Available Limit, Billing Due Date, and `[Pay Bill]` button.
- **Section 3: Loans & Mortgages**: Each loan displays Remaining Principal, Monthly EMI, and `[View Schedule]` button.

### 5.2 `LoanDetailScreen`
- **Top Card**: Principal Remaining (`₹4,50,000` of `₹5,00,000`), Interest Rate (`8.5%`), Next EMI Due Date.
- **Amortization Split Bar**: Visual breakdown showing next EMI split: `₹7,200 Principal (Debt Reduction)` + `₹3,150 Interest (Finance Cost)`.
- **Prepayment Calculator**: Interactive slider: *"What if I prepay ₹50,000 today?"* $\rightarrow$ dynamically calculates interest saved and tenure reduction.

---

## 6. Pillar 4: Plan (Forecast, Budgets & Goals)

### 6.1 `CashflowForecastScreen`
- **Header**: Hero metric: `"~₹92.4K Projected Month-End Balance"`. Subtitle: *"Based on confirmed salary, 3 scheduled bills, and ₹850/day median spending."*
- **Interactive Chart**: Solid line (known commitments) + translucent corridor (variable spend). Tapping any future date displays the projected breakdown on that day.
- **Confidence Badges**: Highlights any overdue salary or missing recurring bills with clear warning chips.

### 6.2 `BudgetScreen` & `GoalScreen`
- **Budget Screen**: Monthly category envelopes with progress rings. Overspent envelopes display subtle amber/crimson borders without alarmist modals.
- **Goal Screen**:
  - Displays **Goal Earmarks**.
  - Example: Vacation Goal (Target: ₹50,000, Earmarked: ₹30,000).
  - Explicitly states: *"₹30,000 is safely locked within your HDFC Checking balance. Safe-to-spend cash reflects this reserve."*

---

## 7. Global Action Hub: `AddTransactionModal`

Opened via the central `(+)` FAB. A glass bottom sheet featuring a top segmented selector:

```
[  Expense  |  Income  |  Transfer  |  Card Pay  |  Refund  ]
```

1. **Amount Input**: Giant tabular numeric field (`₹ 0`). Tapping brings up custom numeric keypad.
2. **Account Selector**: Clean horizontal carousel of user accounts.
3. **Category Picker**: Grid of minimal geometric category chips.
4. **Merchant Field**: Predictive search field backed by `MerchantMemoryService`.
5. **Attach Evidence**: Camera icon to attach paper receipt; text icon to paste raw SMS snippet.
6. **Save Button**: Large high-contrast action button: `[Record Expense]`.
