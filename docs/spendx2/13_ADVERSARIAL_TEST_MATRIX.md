# SpendX 2.0 — Adversarial Financial Test Matrix

**Status**: PROPOSED  
**Classification**: CANONICAL ARCHITECTURE SPECIFICATION  
**Scope**: 30+ Automated Correctness Test Scenarios

---

## 1. Core Test Scenarios (Tests A through J)

| Test ID | Scenario Description | Inputs & Lifecycle | Expected Outcomes & Accounting Assertions |
| :--- | :--- | :--- | :--- |
| **TEST-A** | Simple Inflow / Outflow | Earn ₹50,000 salary; spend ₹10,000 on rent. | Income = ₹50,000; Expense = ₹10,000; Net Cash Flow = +₹40,000; Net Worth $\Delta = +₹40,000$. |
| **TEST-B** | Internal Bank Transfer | Transfer ₹20,000 from HDFC to SBI. | Income = ₹0; Expense = ₹0; Total Transfer = ₹20,000; Net Worth $\Delta = ₹0$; HDFC = -₹20k; SBI = +₹20k. |
| **TEST-C** | Credit Card Cycle | ₹5,000 card purchase on Day 5; ₹5,000 bill paid on Day 25. | Total Expense = ₹5,000; Card Payment Expense Impact = **₹0**; Card Liability = ₹0; Bank = -₹5,000. |
| **TEST-D** | Purchase & Refund | Buy ₹2,000 shoes on Day 2; return on Day 4 for ₹2,000 refund. | Gross Expense = ₹2,000; Refund = ₹2,000; **Net Expense = ₹0**; Cash position restored. |
| **TEST-E** | Multi-Evidence Ingestion | User enters ₹1,200 lunch; SMS arrives with UTR; receipt OCR scanned. | Exactly **1 Economic Event**; 3 Evidence records attached; Ledger reflects single ₹1,200 debit. |
| **TEST-F** | Legitimate Same-Day Multi-Purchase | Buy Starbucks ₹500 at 10:00 AM; buy Starbucks ₹500 at 06:00 PM. | Exactly **2 distinct Economic Events**; Total Expense = ₹1,000. System does not false-merge. |
| **TEST-G** | Early Salary Forecast | Monthly salary of ₹150,000 arrives on Day 3 of calendar month. | Month-end projected income = **₹150,000** (Strictly forbids linear velocity projection of ₹1.5 Million). |
| **TEST-H** | Late Salary Forecast | Monthly salary of ₹150,000 expected on Day 30; date is Day 28. | Actual Income = ₹0; Expected Income = ₹150,000; Forecast displays pending salary corridor. |
| **TEST-I** | Large Return Offset | User buys ₹100,000 appliance; returns next day for full refund. | Month-to-date Net Expense = **₹0**. Financial health score remains unaffected by temporary gross flow. |
| **TEST-J** | Card Purchase & Full Settlement | ₹40,000 card purchase, then ₹40,000 card payment from bank. | Net Expense = ₹40,000; Bank Cash Flow = -₹40,000; Credit Card Liability $\Delta = 0$. |

---

## 2. Additional Adversarial Scenarios (Tests K through AD)

| Test ID | Scenario Description | Inputs & Lifecycle | Expected Outcomes & Accounting Assertions |
| :--- | :--- | :--- | :--- |
| **TEST-K** | Partial Refund | ₹5,000 clothing purchase; ₹2,000 partial return. | Net Expense = **₹3,000**; Asset restored +₹2,000. |
| **TEST-L** | Cross-Account Refund | ₹10,000 purchase on Credit Card; merchant refunds ₹10,000 to Bank via UPI. | Expense nets to ₹0; Bank increases ₹10k; Card liability remains until statement settlement. |
| **TEST-M** | Loan EMI Split | ₹10,000 EMI payment (Amortization: ₹7,000 principal, ₹3,000 interest). | Bank = -₹10k; Loan Liability = -₹7k; Expense = **₹3,000** (Interest only); Net Worth $\Delta = -₹3,000$. |
| **TEST-N** | Loan Principal Prepayment | ₹50,000 lump sum prepayment on home loan. | Bank = -₹50k; Loan Principal = -₹50k; Expense Impact = **₹0**; Net Worth $\Delta = ₹0$. |
| **TEST-O** | ATM Cash Withdrawal | User withdraws ₹10,000 cash from ATM. | Bank Checking = -₹10k; Physical Wallet = +₹10k; Expense = **₹0**; Net Worth $\Delta = ₹0$. |
| **TEST-P** | Physical Cash Spend | User spends ₹1,500 cash from wallet at farmer's market. | Physical Wallet = -₹1,500; Expense = ₹1,500; Bank balance untouched. |
| **TEST-Q** | Cross-Currency Transfer | Transfer \$1,000 USD to ₹83,000 INR account. | USD Asset = -\$1,000; INR Asset = +₹83,000; Balances reconciled via CurrencyExchange equity. |
| **TEST-R** | Budget Soft-Delete Exemption | ₹10,000 expense added to Dining, then immediately deleted. | Dining Budget spent = **₹0**. Deleted record produces zero budget consumption. |
| **TEST-S** | Edit ₹500 to ₹700 | User edits ₹500 grocery expense to ₹700. | Ledger records reversal leg (-₹500) and replacement leg (+₹700); UI displays single card for ₹700. |
| **TEST-T** | Goal Asset Earmarking | Allocate ₹20,000 from Checking to Emergency Fund Goal. | Checking total = ₹50k; Safe-to-Spend cash = ₹30k; Goal reserves = ₹20k; No phantom money created. |
| **TEST-U** | Spending from Goal | Buy ₹18,000 flight tickets linked to Vacation Goal. | Travel Expense = ₹18k; Bank = -₹18k; Goal earmark released; Goal marked completed. |
| **TEST-V** | Opening Balance Baseline | New user starts app with ₹80,000 in HDFC Bank. | Asset:Bank = +₹80k; Equity:OpeningBalance = +₹80k; Income Statement shows **₹0** salary/income. |
| **TEST-W** | Recurring Bill SMS Dedup | Netflix rule expects ₹649; bank SMS arrives for ₹649 Netflix. | Ingested SMS fulfills expected rule; next due date advances to next month; exactly **1** expense logged. |
| **TEST-X** | Loan Disbursement | ₹200,000 personal loan deposited into checking. | Bank = +₹200k; Liability:Loan = +₹200k; Monthly Income = **₹0**; Net Worth $\Delta = ₹0$. |
| **TEST-Y** | Bank Overdraft Fee | Bank charges ₹500 penalty fee for low balance. | Bank = -₹500; Expense:Finance:BankFees = +₹500; Net Worth $\Delta = -₹500$. |
| **TEST-Z** | Interest Earned on Savings | Bank deposits ₹1,200 quarterly interest. | Bank = +₹1,200; Income:Passive:Interest = +₹1,200; Net Worth $\Delta = +₹1,200$. |
| **TEST-AA** | Split Receipt with Cash Back | ₹6,000 payment: ₹3,500 groceries, ₹1,500 clothes, ₹1,000 cash back. | Bank = -₹6k; Groceries = ₹3.5k; Clothes = ₹1.5k; Cash Wallet = +₹1k; Ledger balances perfectly. |
| **TEST-AB** | Account Archival | User archives closed bank account with 500 historical txns. | Account hidden from add forms; historical transactions and Net Worth contributions remain intact. |
| **TEST-AC** | Transit Tap Collisions | User taps transit card twice: ₹40 at 08:14:02 and ₹40 at 08:14:35. | Two distinct UTRs parsed; engine creates 2 distinct events. Total fare = ₹80. |
| **TEST-AD** | Missed Recurring Payment | Expected gym membership due on Day 5; no payment detected by Day 12. | Rule flagged as `OVERDUE`; forecast alerts user; does not log an unconfirmed ghost expense. |
