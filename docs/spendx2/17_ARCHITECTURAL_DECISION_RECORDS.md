# SpendX 2.0 — Architectural Decision Records (ADRs)

**Status**: PROPOSED  
**Classification**: FORMAL ARCHITECTURE DECISIONS (ADR-001 through ADR-017)

---

### ADR-001: Canonical Economic Event Model
- **Context**: SpendX 1.0 tied events directly to single ingestion sources (`tx.source`), preventing multi-source proof linking.
- **Decision**: Define `EconomicEvent` as an independent entity decoupled from ingestion channels.
- **Alternatives**: Retain flat `transactions` table with overloaded source columns.
- **Reasoning**: Economic events happen in the physical world and exist regardless of whether they are discovered by SMS, OCR, or manual input.
- **Consequences**: Requires a 1-to-many relationship between `EconomicEvent` and `Evidence`.
- **Open Risks**: Requires migration of existing `transactions` rows into canonical events.

---

### ADR-002: Ingestion Evidence Artifacts
- **Context**: Ingesting bank SMS, OCR receipts, and manual forms caused duplicate transaction creation.
- **Decision**: Ingestion channels produce immutable `Evidence` artifacts that attach to `EconomicEvent`s.
- **Alternatives**: Ingestion channels insert directly into the ledger.
- **Reasoning**: Separating raw ingestion data from accounting state allows re-parsing, auditability, and multi-channel verification without altering ledger balances.
- **Consequences**: Storage overhead for raw payloads; UI must support viewing attached evidence proofs.
- **Open Risks**: Raw SMS storage requires privacy-preserving on-device encryption.

---

### ADR-003: Deterministic Event Identity Matching
- **Context**: In-memory heuristic deduplication failed on cold starts and false-merged legitimate same-day purchases.
- **Decision**: Implement a two-tier identity engine: deterministic matching on bank reference IDs (UTR) + probabilistic scoring on amount, timestamp window ($\pm 24$h), and normalized merchant.
- **Alternatives**: Rely exclusively on user review or exact timestamp hashing.
- **Reasoning**: Bank UTRs guarantee uniqueness; probabilistic scoring safely routes ambiguous matches to a user review inbox.
- **Consequences**: Ambiguous items require a user confirmation tray on the dashboard.
- **Open Risks**: Banks occasionally format UTRs inconsistently across SMS gateways.

---

### ADR-004: Lightweight Double-Entry Posting Model
- **Context**: SpendX 1.0 used single-entry records with mutable account balances, leading to untraceable balance drift.
- **Decision**: Adopt a double-entry ledger where every event emits balanced postings ($\sum \text{Debits} \equiv \sum \text{Credits}$).
- **Alternatives**: Single-entry account movement logging.
- **Reasoning**: Double-entry is the only proven mathematical model that guarantees self-verifying financial consistency across assets, liabilities, income, and expenses.
- **Consequences**: Increased database rows (minimum 2 postings per event); requires rigid validation triggers.
- **Open Risks**: Increased SQLite database size over multi-year usage (mitigated by lightweight integer storage).

---

### ADR-005: Account Balance Derivation & Materialized Caching
- **Context**: `bank_accounts.balance` was stored as a mutable scalar updated directly by UI actions.
- **Decision**: Account balances are strictly derived as $\text{Opening Equity} + \sum \text{Postings}$. A materialized cache is maintained solely via SQLite triggers.
- **Alternatives**: Pure on-demand recalculation without caching, or continuing mutable scalars.
- **Reasoning**: Balances must never be an independent source of truth; triggers provide mobile UI performance without application-level drift.
- **Consequences**: Requires database triggers on posting inserts.
- **Open Risks**: SQLite trigger performance during 10,000-transaction bulk historical SMS imports.

---

### ADR-006: Balanced Asset Transfer Semantics
- **Context**: SpendX 1.0 logged destination legs of transfers as `LedgerType.income`, falsely inflating earnings.
- **Decision**: Internal transfers are strictly modeled as asset exchanges: Debit `Asset:Destination`, Credit `Asset:Source`. Net Income = 0, Net Expense = 0.
- **Alternatives**: Special non-ledger transfer table.
- **Reasoning**: Moving money between one's own accounts creates no wealth and consumes no resources.
- **Consequences**: Transfers are completely excluded from income and expense analytics.
- **Open Risks**: Legacy data backfill must re-pair existing transfer records.

---

### ADR-007: Credit Card Liability Accounting
- **Context**: Card bill payments logged the bank deduction as an expense, double-counting monthly spending.
- **Decision**: Purchases debit Expense and credit Card Liability. Payments debit Card Liability and credit Bank Asset. Payments create ₹0 expense.
- **Alternatives**: Treat credit cards as asset accounts with negative balances.
- **Reasoning**: Accurately reflects financial reality: expenses occur when goods are bought, not when credit card statements are paid.
- **Consequences**: Resolves the double-counting bug completely.
- **Open Risks**: Users accustomed to seeing their bank statement bill payment in "Expenses" may initially be confused and require UI onboarding tooltips.

---

### ADR-008: Contra-Expense Refund Semantics
- **Context**: `TransactionRepo` ignored `type = 'refund'`, overstating net monthly expenses.
- **Decision**: Refunds are credited directly to the originating expense account (or contra-expense), automatically reducing net expenses.
- **Alternatives**: Treat refunds as an income category.
- **Reasoning**: Returning a pair of shoes is not earning revenue; it is the reversal of consumption.
- **Consequences**: Expense totals accurately reflect net living costs.
- **Open Risks**: Matching a refund to its original purchase when amounts differ (partial refund).

---

### ADR-009: Integrated Loan Liability & Split EMI Postings
- **Context**: Loans were standalone calculators; EMI payments logged the entire installment as an expense.
- **Decision**: Loans are integrated as formal Liability accounts. EMIs split into Principal Reduction (Debit Liability) and Interest Expense (Debit Expense).
- **Alternatives**: Continue treating loans as visual progress bars.
- **Reasoning**: Repaying debt principal is a balance sheet transfer, not a living cost. Only interest is true consumption.
- **Consequences**: Requires amortization schedule integration with the ledger writer.
- **Open Risks**: Variable interest rate loans require periodic schedule recalculation.

---

### ADR-010: Contractual Salary Expectation Architecture
- **Context**: Naive daily linear extrapolation caused catastrophic forecast swings based on salary payment dates.
- **Decision**: Model salary via explicit `SalaryContract` generating expected income events, reconciled against actual incoming bank deposits.
- **Alternatives**: Multi-month rolling average.
- **Reasoning**: Salaries are discrete contractual events, not continuous daily drips.
- **Consequences**: Forecast remains stable regardless of whether salary arrives on Day 3 or Day 30.
- **Open Risks**: Handling irregular freelance workers without contracts (mitigated by median rolling baseline fallback).

---

### ADR-011: Multi-Tier Deterministic Cashflow Forecasting
- **Context**: SpendX 1.0 forecast was an unexplainable linear formula detached from actual recurring bills.
- **Decision**: Replace linear formula with a deterministic 3-tier model: Actual Cash + Known Inflows - Known Commitments - Trailing Median Variable Spend.
- **Alternatives**: Complex on-device machine learning / neural regression.
- **Reasoning**: Financial users require explainable, transparent math that matches their contractual obligations.
- **Consequences**: Fast O(1) computation; fully explainable daily balance curves.
- **Open Risks**: New users with zero history require onboarding defaults.

---

### ADR-012: Automated Recurring Ingestion Reconciliation
- **Context**: Paying a recurring bill via SMS left the recurring rule pending, prompting duplicate manual entries.
- **Decision**: Implement a reconciliation matcher that links ingested transactions to active `ExpectedEvent` instances, advancing the schedule automatically.
- **Alternatives**: Manual reconciliation only.
- **Reasoning**: Automated matching eliminates double-counting while keeping bill schedules current.
- **Consequences**: Requires matching heuristics based on merchant alias, amount tolerance, and due date window.
- **Open Risks**: Variable utility bills (electricity/water) where amounts fluctuate monthly.

---

### ADR-013: Append-Only Corrections with Materialized Projections
- **Context**: Editing records in place destroyed accounting history; append-only enterprise ledgers confused users.
- **Decision**: The database ledger is strictly append-only (reversal + replacement legs). The UI projection presents a clean, singular transaction card.
- **Alternatives**: Fully mutable CRUD database, or exposing raw debit/credit reversals in UI.
- **Reasoning**: Preserves 100% mathematical auditability while maintaining an intuitive consumer UX.
- **Consequences**: Queries for active transactions filter on `status = 'posted'`.
- **Open Risks**: Slightly higher query complexity on historical point-in-time reports.

---

### ADR-014: Real-Money Goals (Asset Earmarks)
- **Context**: Goals stored phantom counters (`goals.current_amount`) disconnected from actual liquid cash.
- **Decision**: Goals represent explicit asset earmarks on existing bank accounts or transfers to dedicated sub-accounts. Phantom tallies are prohibited.
- **Alternatives**: Retain visual-only progress bars.
- **Reasoning**: Personal finance tools must not deceive users into believing they have saved money that does not exist in liquid reality.
- **Consequences**: Goal contributions reduce "Safe-to-Spend" cash on the dashboard.
- **Open Risks**: User overdraws their checking account, placing the earmarked goal at risk.

---

### ADR-015: Budgets as Read-Only Reporting Envelopes
- **Context**: Budgets were corrupted by soft-deleted transactions due to missing SQL filters.
- **Decision**: Budgets are pure reporting overlays applied over ledger expense postings. Soft-deleted and reversed postings are strictly excluded.
- **Alternatives**: Storing pre-aggregated spent columns in the `budgets` table.
- **Reasoning**: Budgets are policy targets, not financial state. Querying the ledger directly ensures zero drift.
- **Consequences**: Budget progress is always in 100% parity with the transaction ledger.
- **Open Risks**: Multi-category parent/child rollup queries require indexed category hierarchy lookups.

---

### ADR-016: Audited AI Truth Boundary
- **Context**: Gemini AI received ad-hoc context from raw tables, causing it to confidently hallucinate advice based on double-counted card payments.
- **Decision**: Gemini AI communicates strictly with an audited Financial Query Layer that supplies verified domain metrics and anonymized PII.
- **Alternatives**: Let AI write SQL queries directly, or feed raw SQLite tables to prompt context.
- **Reasoning**: LLMs will confidently rationalize false financial state if fed corrupted inputs. Grounding the AI in verified domain facts prevents dangerous financial advice.
- **Consequences**: Structured JSON context assembly; AI has zero direct database write permissions.
- **Open Risks**: LLM latency when constructing comprehensive context summaries.

---

### ADR-017: Vehicle & Fuel Subsystem Removal Boundary
- **Context**: Vehicle tracking, fuel logging, and odometer math added massive maintenance bloat to a personal finance app.
- **Decision**: Completely deprecate and remove all vehicle-specific tables, models, screens, and services. Retain Transport as an ordinary expense category (`Expense:Transport:Fuel`).
- **Alternatives**: Keep vehicles as an optional plugin.
- **Reasoning**: SpendX is a financial sovereignty tool, not a fleet management utility. Refocusing on core finance eliminates architectural bloat.
- **Consequences**: Drops 4 database tables, 6 screens, and legacy repositories.
- **Open Risks**: Migrating historical fuel expenses to ordinary expense postings without losing spending history.
