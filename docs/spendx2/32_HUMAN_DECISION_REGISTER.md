# SpendX 2.0 — Human Decision Register (Approved & Locked)

**Document**: `32_HUMAN_DECISION_REGISTER.md`  
**Status**: APPROVED & LOCKED BY PRODUCT OWNER  
**Scope**: Non-Technical Policy Decisions Impacting Financial Semantics and User Experience  
**Superseded By / Detailed in**: [`docs/spendx2/34_FINAL_PRODUCT_DECISION_LOCK.md`](file:///Users/sivek/Documents/SpendX/docs/spendx2/34_FINAL_PRODUCT_DECISION_LOCK.md)

---

## The Five Approved & Locked Human Decisions

The product owner has formally approved and locked all five policy decisions:

---

### Decision 1: Unmatched Refund Accounting Classification
- **LOCKED DECISION**: **Option A (`Expense:General:Refunds`)**.
- **Rule**: Unmatched refunds are classified strictly as contra-expense activity, directly reducing total living expenses. They must **never** be classified as personal income.
- **Status**: **LOCKED**.

---

### Decision 2: Raw Bank SMS Body Retention & Local Privacy
- **LOCKED DECISION**: **Option B Modified (30-Day Auto-Purge of Raw Message Body)**.
- **Rule**: Raw SMS message bodies are retained locally on device for exactly 30 days. After 30 days, the raw body text is purged from `evidence.raw_payload`. All structured metadata (amount, UTR, merchant, timestamp, sender, confidence) persists indefinitely. Deduplication operates strictly on structured metadata and never requires raw body text.
- **Status**: **LOCKED**.

---

### Decision 3: Goal Funding Semantics (Earmarks vs. Real Accounts)
- **LOCKED DECISION**: **Option A (Mode A: Asset Earmarks)**.
- **Rule**: Goals use `asset_earmarks` to reserve liquid cash inside existing checking accounts. Earmarks reduce `discretionary_cash` and `safe_to_spend` without moving ledger money. Dedicated physical savings accounts remain ordinary Asset accounts and must not be double-earmarked.
- **Status**: **LOCKED**.

---

### Decision 4: Phase 1 Currency Constraint
- **LOCKED DECISION**: **Option A (Single Base Currency: `INR` ₹)**.
- **Rule**: Phase 1 operates strictly in INR. Amounts are stored as integer paise. Multi-currency and FX exchange engines are excluded from Phase 1. The `currency` string field is retained on schema entities for Phase 2 extensibility.
- **Status**: **LOCKED**.

---

### Decision 5: Default Cashflow Forecast Horizon
- **LOCKED DECISION**: **Option A (30 Days Default Horizon)**.
- **Rule**: Default forecast curve displays 30 days. UI exposes 60-day and 90-day toggles powered by the identical deterministic engine. Naive daily income extrapolation is strictly prohibited.
- **Status**: **LOCKED**.
