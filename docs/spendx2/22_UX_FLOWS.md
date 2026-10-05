# SpendX 2.0 — UX Flow Specifications (25 Financial Scenarios)

**Document**: `22_UX_FLOWS.md`  
**Status**: APPROVED SPECIFICATION  
**Scope**: End-to-End User Journeys, Decision Branches, Error Recovery, and Accounting Boundaries

---

## Master Flow Inventory

| Flow ID | Scenario Name | Primary Entry Point | Core Accounting Outcome |
| :--- | :--- | :--- | :--- |
| **FLOW-01** | First Launch & Baseline | App Cold Boot | Provisions default equity and initial account baselines. |
| **FLOW-02** | Add Bank Account | Money Tab $\rightarrow$ `+ Add Account` | Registers Asset account; sets opening balance equity. |
| **FLOW-03** | Add Credit Card | Money Tab $\rightarrow$ `+ Add Card` | Registers Liability account; sets credit limit and cycle. |
| **FLOW-04** | Add Term Loan | Money Tab $\rightarrow$ `+ Add Loan` | Registers Loan Liability; generates amortization schedule. |
| **FLOW-05** | Add Manual Expense | Global `(+)` FAB $\rightarrow$ Expense | Emits Debit Expense, Credit Asset. |
| **FLOW-06** | Add Manual Income | Global `(+)` FAB $\rightarrow$ Income | Emits Debit Asset, Credit Income. |
| **FLOW-07** | Transfer Money | Global `(+)` FAB $\rightarrow$ Transfer | Balanced asset exchange; zero income/expense. |
| **FLOW-08** | Card Purchase | Global `(+)` FAB $\rightarrow$ Expense (Card) | Emits Debit Expense, Credit Card Liability. |
| **FLOW-09** | Pay Credit Card Bill | Card Detail $\rightarrow$ `Pay Bill` | Emits Debit Card Liability, Credit Bank Asset. Expense = 0. |
| **FLOW-10** | Record Refund | Global `(+)` FAB $\rightarrow$ Refund | Emits Debit Asset, Credit Expense (Contra-Expense). |
| **FLOW-11** | Live SMS Detection | Background Telephony Broadcast | Staged or Auto-Committed with UTR deduplication. |
| **FLOW-12** | Scan Paper Receipt (OCR) | Global `(+)` FAB $\rightarrow$ Scan | ML Kit extracts total/date; pre-populates review sheet. |
| **FLOW-13** | Duplicate Candidate Review | Review Tray on Home/Activity | User decides: `[Merge as Evidence]` or `[Keep Separate]`. |
| **FLOW-14** | Edit Event Details (Metadata)| Event Detail $\rightarrow$ `Edit Notes/Tag`| Updates event metadata in place; no ledger mutation. |
| **FLOW-15** | Correct Amount / Date | Event Detail $\rightarrow$ `Edit Amount` | Emits immutable reversal posting + replacement event. |
| **FLOW-16** | Delete / Reverse Event | Event Detail $\rightarrow$ `Delete` | Emits immutable reversal posting; event tombstoned. |
| **FLOW-17** | Create Category Budget | Plan Tab $\rightarrow$ `Budgets` $\rightarrow$ `+` | Configures monthly spending policy envelope. |
| **FLOW-18** | Create Goal (Asset Earmark) | Plan Tab $\rightarrow$ `Goals` $\rightarrow$ `+` | Earmarks portion of checking balance; updates safe-to-spend. |
| **FLOW-19** | Create Recurring Rule | Plan Tab $\rightarrow$ `Recurring` $\rightarrow$ `+` | Creates template; instantiates next `ExpectedEvent`. |
| **FLOW-20** | Configure Salary Contract | Plan Tab $\rightarrow$ `Salary` $\rightarrow$ `+` | Sets employer, expected pay day, and variance rules. |
| **FLOW-21** | View Cashflow Forecast | Plan Tab $\rightarrow$ `Forecast` | Renders 30/60/90-day curve with confidence corridors. |
| **FLOW-22** | Ask AI Assistant | Top Bar Sparkle Icon | Assembles verified context; queries Gemini API. |
| **FLOW-23** | Export Financial Data | More Tab $\rightarrow$ `Export` | Generates verified PDF statements or CSV ledger dumps. |
| **FLOW-24** | Import Bank Statement (CSV) | More Tab $\rightarrow$ `Import` | Batch parses CSV; runs dedup matcher; stages candidates. |
| **FLOW-25** | Privacy & Evidence Control | More Tab $\rightarrow$ `Privacy` | Manages raw SMS purge timers and biometric locks. |

---

## Detailed Specification for Critical Flows

### FLOW-07: Transfer Money Between Accounts
1. **Entry**: User taps global `(+)` FAB $\rightarrow$ selects `[Transfer]` segment.
2. **Steps**:
   - Step 1: User enters Amount: `₹20,000`.
   - Step 2: "From Account" selector defaults to last used checking account (`HDFC Bank`).
   - Step 3: "To Account" selector presents remaining asset accounts (`SBI Savings`).
   - Step 4: User adds optional note: *"Monthly savings allocation"*.
   - Step 5: Taps `[Complete Transfer]`.
3. **Validation**:
   - Fails if `From Account == To Account` (*"Source and destination must be different"*).
   - Warns if `From Account balance < Amount` (*"This will cause an overdraft"*).
4. **Accounting Outcome**:
   - `EconomicEvent` created with `eventType = 'transfer'`.
   - Posting 1: `Credit Asset:Bank:HDFC ₹20,000`.
   - Posting 2: `Debit Asset:Bank:SBI ₹20,000`.
   - **Income = ₹0, Expense = ₹0, Net Worth $\Delta = 0$**.
5. **Success State**: Immediate tabular balance roll on Home Tab. Haptic medium feedback.

---

### FLOW-09: Pay Credit Card Bill
1. **Entry**: User navigates to Money Tab $\rightarrow$ taps `ICICI Credit Card` $\rightarrow$ taps `[Pay Bill]`.
2. **Steps**:
   - Step 1: Pre-fills with **Total Due** (`₹18,400.00`) or **Minimum Due** (`₹1,200.00`).
   - Step 2: User selects funding bank account (`HDFC Salary`).
   - Step 3: Taps `[Confirm Payment]`.
3. **Accounting Outcome**:
   - Posting 1: `Credit Asset:Bank:HDFC ₹18,400` (Asset decreases).
   - Posting 2: `Debit Liability:CreditCard:ICICI ₹18,400` (Liability decreases).
   - **Critical FinTech Invariant**: Expense impact is strictly **₹0.00**. Monthly living expenses are **not** inflated.
4. **Success State**: Card card shows *"Paid in Full — Available Credit Restored"*.

---

### FLOW-13: Duplicate Candidate Review
1. **Entry**: User opens Home Tab $\rightarrow$ taps amber badge: *"2 Potential Duplicates Detected"*.
2. **Screen Presentation**:
   - Left Pane: Manual expense entered yesterday: *"₹1,250 at Amazon (10:15 AM)"*.
   - Right Pane: Bank SMS received yesterday: *"₹1,250 debited to Amazon Pay (UTR: 591024 at 10:18 AM)"*.
3. **User Decisions**:
   - **Option A: `[Merge & Link Proof]`**: The engine attaches the SMS UTR as verified evidence to the existing manual event. No new postings are emitted.
   - **Option B: `[Keep Both as Separate Events]`**: Confirms that the user made two separate ₹1,250 purchases. Emits a new set of postings for the second event.
4. **Recovery / Undo**: An in-app undo banner persists for 8 seconds: *"Transactions merged. Tap to undo"*.
