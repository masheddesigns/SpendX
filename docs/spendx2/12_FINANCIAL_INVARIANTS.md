# SpendX 2.0 — Financial Invariants Catalog

**Status**: PROPOSED  
**Classification**: CANONICAL ARCHITECTURE SPECIFICATION  
**Scope**: Inviolable Financial, Accounting, and Mathematical Laws

---

## The SpendX 2.0 Invariants Catalog

Every component of SpendX 2.0—from database triggers and domain services to UI widgets and background import workers—must strictly uphold these invariants:

| Invariant ID | Title | Formal Invariant Definition | Enforcement Level |
| :--- | :--- | :--- | :--- |
| **INV-001** | **Balanced Postings** | For every economic event $E$, $\sum \text{Debits} \equiv \sum \text{Credits}$. | SQLite Trigger + Service |
| **INV-002** | **Zero-Impact Transfers** | For any internal transfer between user accounts: $\Delta \text{Income} \equiv 0$, $\Delta \text{Expense} \equiv 0$, $\Delta \text{NetWorth} \equiv 0$. | Ledger Accounting Core |
| **INV-003** | **Card Payment Non-Consumption**| A credit card bill payment from a bank account: $\Delta \text{Expense} \equiv 0$, $\Delta \text{Income} \equiv 0$, $\Delta \text{NetWorth} \equiv 0$. | Ledger Accounting Core |
| **INV-004** | **Refund Netting** | A full merchant refund of purchase amount $A$: $\text{NetExpense} = A - A \equiv 0$. Net worth is restored to pre-purchase baseline. | Ledger Accounting Core |
| **INV-005** | **Account Balance Truth** | Current Balance $\equiv$ Opening Equity Baseline + $\sum \text{Postings}$. Balances cannot be modified via arbitrary overwrite. | Database & Repository |
| **INV-006** | **Multi-Evidence Singleton**| Multiple ingestion streams describing the same real-world event attach to **one** `EconomicEvent` without creating duplicate postings. | Ingestion Deduplication |
| **INV-007** | **Immutable History** | Historical postings are never deleted or modified in place. Edits and deletions emit immutable reversal and correction postings. | Database & Triggers |
| **INV-008** | **Non-Linear Salary Forecast** | Contractual periodic salary must **never** be extrapolated via elapsed-day income velocity: $(\text{income} / \text{daysElapsed}) \times \text{daysInMonth}$. | Forecast Engine |
| **INV-009** | **Loan EMI Split** | Every loan EMI payment must split into Principal Debt Reduction ($\Delta \text{Liability}$) and Interest Expense ($\Delta \text{Expense}$). Principal cannot be logged as an expense. | Loan Service |
| **INV-010** | **Real-Money Goals** | A goal contribution must represent an explicit asset allocation / earmark or physical sub-account transfer. Phantom tallies are prohibited. | Goal Service |
| **INV-011** | **Budget Soft-Delete Exclusion**| Soft-deleted or reversed transactions must have zero impact on period-to-date budget consumption. | Budget Repository |
| **INV-012** | **Account Deletion Guard** | An account with existing ledger postings cannot be physically deleted from SQLite. It may only be closed or archived. | Database Constraints |
| **INV-013** | **Currency Conservation** | Cross-currency transactions must balance via an explicit `Equity:CurrencyExchange` clearing account. | Ledger Accounting Core |
| **INV-014** | **AI Context Verification** | The AI assistant must only receive domain metrics produced by the verified accounting query layer. It must never receive raw, unverified table sums. | AI Context Bridge |
| **INV-015** | **Recurring Reconciliation** | When an ingested transaction matches an active recurring rule, it fulfills the expected instance and advances the rule schedule without duplicating expenses. | Recurring Engine |
