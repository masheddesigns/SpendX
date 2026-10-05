# SpendX 2.0 — UX Writing & Financial Terminology Specification

**Document**: `23_UX_WRITING.md`  
**Status**: APPROVED SPECIFICATION  
**Scope**: Voice & Tone, Plain-Language Financial Translation, Copy Rules, and Error Microcopy

---

## 1. Voice and Tone Principles

SpendX 2.0 speaks with the calm, objective authority of a **high-precision instrument**:
1. **Calm & Objective**: Never scolds, panics, or lectures. A budget overrun is reported as a mathematical observation (`₹1,200 over budget`), not an emotional disaster (`"Danger! You overspent!"`).
2. **Plain Financial Language**: The internal double-entry engine uses formal accounting terms; the user interface uses crystal-clear consumer financial English.
3. **Zero Faux-Human Fluff**: Avoids cheesy chatty personas (`"Hey there, superstar!"`). It delivers data with crisp, machine-clean brevity.

---

## 2. Plain-Language Translation Dictionary

| Internal Accounting Concept | Technical Ledger Term | User-Facing UI Label | In-App Example Usage |
| :--- | :--- | :--- | :--- |
| **Incoming Cash / Revenue** | Credit Posting to Income Account | **Money In** / **Income** | `+₹1,50,000.00 • Money In` |
| **Living Consumption** | Debit Posting to Expense Account | **Money Out** / **Expense** | `-₹2,450.00 • Dining` |
| **Internal Rebalancing** | Cross-Asset Debit/Credit Exchange | **Transfer** / **Money Moved** | `⇄ ₹20,000.00 • HDFC to SBI` |
| **Paying Debt Liability** | Debit Liability / Credit Asset | **Card Payment** | `₹18,400.00 • Card Payment (₹0 expense)` |
| **Merchant Return** | Contra-Expense Credit Posting | **Refund** | `↶ +₹2,000.00 • Offsets Shoes Expense` |
| **Discretionary Cash** | Unallocated Liquid Asset Sum | **Safe to Spend** | `₹42,100 Safe to Spend this month` |
| **Goal Cash Allocation** | Asset Balance Earmark | **Goal Reserve** / **Locked** | `₹30,000 locked for Emergency Fund` |
| **Contractual Obligation** | Amortized Debt Schedule | **Loan EMI** / **Upcoming Bill**| `Home Loan EMI due in 4 days` |
| **Income Contract** | Expected Income Template | **Salary Contract** | `Employer Inc • Expected Oct 30` |

---

## 3. Microcopy Rules Across States

### 3.1 Empty State Microcopy (Educational, Not Dead Ends)
- **No Accounts Configured**:
  - *Title*: `"Establish your baseline"`
  - *Body*: `"SpendX tracks your wealth across your accounts and cash. Add your primary bank account or physical cash wallet to begin."`
  - *Button*: `[+ Add Your First Account]`
- **No Transactions in Feed**:
  - *Title*: `"No activity yet"`
  - *Body*: `"Transactions will appear here as you log expenses, transfer money, or import bank SMS."`
  - *Button*: `[Log a Transaction]`
- **No Review Items**:
  - *Title*: `"All caught up"`
  - *Body*: `"Every ingested SMS, receipt scan, and import has been verified and posted to your ledger."`

### 3.2 Error & Recovery Microcopy (Constructive, Not Alarmist)
- **Account Transfer to Same Account**:
  - *Bad*: `"Error! Invalid destination!"`
  - *SpendX 2.0*: `"Source and destination accounts must be different."`
- **Goal Exceeds Available Checking Balance**:
  - *Bad*: `"Insufficient funds for goal!"`
  - *SpendX 2.0*: `"Your checking account has ₹15,000 available. You cannot allocate ₹20,000 without causing an overdraft."`
- **Salary Not Detected on Expected Date**:
  - *Bad*: `"Your salary is missing!"`
  - *SpendX 2.0*: `"Expected salary from Employer Inc was scheduled for 03-Oct. If you received it under a different bank name, tap here to reconcile."`
