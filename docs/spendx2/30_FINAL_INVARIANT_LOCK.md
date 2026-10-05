# SpendX 2.0 — Final Invariant Lock

**Document**: `30_FINAL_INVARIANT_LOCK.md`  
**Status**: APPROVED CANONICAL SPECIFICATION  
**Scope**: Inviolable Mathematical, Ledger, and State Invariants

---

## 1. Locked Invariants Catalog

The following invariants are mathematically locked. Any code change, migration script, service method, or UI feature that violates any of these laws is **strictly rejected**.

### Invariant 1: Conservation of Ledger Value (Balanced Postings)
For every `EconomicEvent` $E$ with postings $P_1, P_2, \dots, P_n$:
$$\sum_{i=1}^n \mathbf{1}_{\{P_i.\text{direction} = \text{'debit'}\}} \cdot P_i.\text{amount} \equiv \sum_{i=1}^n \mathbf{1}_{\{P_i.\text{direction} = \text{'credit'}\}} \cdot P_i.\text{amount}$$
*Enforcement*: Verified by `LedgerService` pre-commit check and guaranteed by SQLite deferred trigger.

---

### Invariant 2: Pure Asset Rebalancing (Zero-Impact Transfers)
An internal transfer between accounts owned by the user (e.g. HDFC $\rightarrow$ SBI) must create:
- Credit `Asset:Source` $A$
- Debit `Asset:Destination` $A$
$$\Delta \text{Income} \equiv 0, \quad \Delta \text{Expense} \equiv 0, \quad \Delta \text{NetWorth} \equiv 0, \quad \Delta \text{LiquidCash} \equiv 0$$
*Enforcement*: `financial_transaction_service.dart:102` bug (typing destination as income) is eliminated.

---

### Invariant 3: Card Payment Liability Settlement
Paying a credit card bill from a bank checking account must create:
- Credit `Asset:Bank` $A$
- Debit `Liability:CreditCard` $A$
$$\Delta \text{Expense} \equiv 0, \quad \Delta \text{Income} \equiv 0, \quad \Delta \text{NetWorth} \equiv 0$$
*Enforcement*: `credit_card_service.dart:172` bug (logging payment as expense) is eliminated.

---

### Invariant 4: True Net Consumption (Contra-Expense Refunds)
A merchant refund of purchase amount $A$ returned to account $X$:
- Debit `Asset:X` $A$
- Credit `Expense:Category` $A$ (or `Expense:General:Refunds`)
$$\text{NetPeriodExpense} = \sum \text{ExpenseDebits} - \sum \text{ExpenseCredits}$$
*Enforcement*: `TransactionRepo.getStatsForRange` bug (ignoring refunds) is eliminated.

---

### Invariant 5: Real-Money Goal Conservation
Creating or funding a goal via an asset earmark of amount $A$ on account $X$:
- Total verified balance of account $X$ remains **completely unchanged**.
- Discretionary cash decreases by $A$:
$$\text{DiscretionaryCash} = \text{TotalLiquidCash} - \sum \text{Earmarks} - \dots$$
$$\text{TotalLiquidCash} \ge \sum \text{Earmarks}$$
*Enforcement*: `goals.current_amount` phantom counter is replaced by relational `asset_earmarks`.

---

### Invariant 6: Append-Only History Preservation (Corrections & Deletions)
Past rows in `postings` are **never updated or deleted**:
- An **edit** appends an exact reversal posting pair for the old event, transitions the old event to `status = 'corrected'`, and appends replacement postings under a new event.
- A **deletion** appends an exact reversal posting pair and transitions the event to `status = 'reversed'`.
*Enforcement*: SQLite triggers abort any raw `UPDATE` or `DELETE` on `postings`.

---

### Invariant 7: Deduplication Evidence Singleton
When multiple evidence records (SMS, OCR, Manual, Share Intent) describe the same real-world purchase:
- Exactly **one** `EconomicEvent` exists in `economic_events`.
- Exactly **one balanced set of postings** is committed to `postings`.
- Multiple rows in `evidence` link back to that single `event_id`.
*Enforcement*: Persistent SQLite index lookups on `evidence.external_reference`.

---

### Invariant 8: Non-Linear Contractual Income Velocity
A periodic contractual salary of amount $S$ must **never** be extrapolated via elapsed-day income velocity:
$$\text{ProjectedSalary} \ne \left(\frac{S}{\text{DaysElapsed}}\right) \times \text{DaysInMonth}$$
*Enforcement*: Salary expectations are governed strictly by discrete `SalaryContract` schedules.

---

### Invariant 9: Multi-Tier Cashflow Forecasting Distinction
The cashflow forecast engine must maintain strict separation between:
1. `ACTUAL`: Ground truth ledger balances as of today.
2. `CONFIRMED`: Contractual fixed obligations (EMIs, rent, fixed subscriptions).
3. `EXPECTED`: Contractual salaries and recurring bills with historical variance.
4. `PREDICTED`: Statistical trailing 90-day median discretionary variable burn.
*Enforcement*: The forecast curve is deterministic, fully explainable, and zero-ML.

---

### Invariant 10: Complete Vehicle Domain Isolation
All vehicle entities (`vehicles`, `fuel_logs`, `vehicle_services`, `vehicle_reminders`) reside **completely outside the SpendX 2.0 financial truth model**:
- Fuel and maintenance purchases are recorded strictly as ordinary expenses: `Expense:Transport:Fuel` and `Expense:Transport:Maintenance`.
- No vehicle metadata (liters, odometer km, tank capacity) touches the general ledger.
