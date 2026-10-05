# SpendX 2.0 — Product UX & Information Architecture Specification

**Document**: `18_PRODUCT_UX_ARCHITECTURE.md`  
**Status**: APPROVED SPECIFICATION  
**Scope**: Information Architecture, Navigation Hierarchy, Screen Mental Models, and State Contracts  
**Financial Truth Backbone**: `docs/spendx2/00` through `17`

---

## 1. Information Architecture Philosophy

SpendX 2.0 is designed as a **Precision Financial Instrument**. It rejects the noisy, marketing-heavy, gamified clutter of legacy consumer fintech in favor of a calm, systematic, data-dense, and trustworthy experience.

### Core Architectural Principles:
1. **Financial State Over Raw Activity**: The top-level mental model prioritizes *where the user stands right now* and *where they are projected to be*, rather than an endless feed of uncontextualized transactions.
2. **Strict Hiding of Double-Entry Mechanics**: The application uses a rigorous double-entry engine underneath (`EconomicEvent` $\rightarrow$ balanced `postings`), but ordinary users never encounter "Debits", "Credits", "Journal IDs", or "Reversal legs". They experience intuitive concepts: **Money In**, **Money Out**, **Money Moved**, **Card Payment**, and **Refund**.
3. **Honest Asset Visibility**: The interface never displays fictional numbers. "Goal Savings" never exists without real cash backing; "Safe to Spend" is explicitly distinguished from gross account balances; and credit card bill payments never double-count as consumption.

---

## 2. Navigation Hierarchy & Mental Models

After adversarial review of the legacy 5-tab `IndexedStack` (which mixed accounts, wealth tools, and vehicle logs), SpendX 2.0 consolidates around **Four Primary Pillars** anchored by a persistent, glass-morphed Bottom Navigation Bar, plus a dedicated Contextual Action Hub.

```mermaid
graph TD
    Root[SpendX 2.0 Shell] --> TabHome[1. Home: Financial State & Pulse]
    Root --> TabActivity[2. Activity: Canonical Events & Review]
    Root --> TabMoney[3. Money: Accounts, Cards & Liabilities]
    Root --> TabPlan[4. Plan: Forecast, Budgets & Real Goals]
    Root --> HubAdd[Global Action Hub: (+) Log / Transfer / Scan]
    Root --> SheetAI[AI Assistant: Verified Financial Bridge]
    Root --> ScreenMore[More / Settings: Privacy & System Controls]

    TabHome --> WidgetSafeSpend[Safe to Spend Gauge]
    TabHome --> WidgetCommitments[Upcoming 14-Day Commitments]
    TabHome --> WidgetReviewBanner[Pending Ingestion Tray]

    TabActivity --> EventDetail[Canonical Event Detail]
    TabActivity --> QueueReview[Staged Evidence Review Queue]
    TabActivity --> QueueDedup[Probabilistic Duplicate Review]

    TabMoney --> DetailAccount[Asset Account Ledger View]
    TabMoney --> DetailCard[Credit Card Liability View]
    TabMoney --> DetailLoan[Amortized Debt Schedule]

    TabPlan --> ViewForecast[Deterministic Cashflow Curve]
    TabPlan --> ViewBudgets[Envelope Spend Overlays]
    TabPlan --> ViewGoals[Earmarked Asset Goals]
    TabPlan --> ViewSalary[Salary Contract Manager]
```

---

## 3. Pillar-by-Pillar Architectural Specification

### 3.1 Pillar 1: Home (Financial State & Pulse)
- **User Mental Model**: *"What is my true financial situation right now, and what bills are coming next?"*
- **Primary Information (Above the Fold)**:
  1. **Safe-to-Spend Liquidity**: $\text{Liquid Cash} - \text{Goal Earmarks} - \text{Known 14-Day Commitments}$.
  2. **Net Worth Metric**: $\sum \text{Liquid Assets} - \sum \text{Card Liabilities} - \sum \text{Loan Principal}$.
  3. **Pending Ingestion Review Tray** (Conditional): Appears only if unconfirmed SMS, OCR scans, or duplicate candidates require review.
- **Secondary Information (Below the Fold)**:
  1. **Next 14-Day Cashflow Corridor**: Upcoming Salary, Rent, EMIs, and Subscriptions.
  2. **Month-to-Date Budget Pulse**: Visual indicator of category envelope burn rates.
  3. **Recent Activity Snapshot**: The 5 latest verified `EconomicEvent` records.
- **Primary Action**: Tap Global Floating Action Button `(+)` or Swipe down to trigger bank SMS catch-up sync.
- **Empty State**: New user sees zero accounts prompt: *"Connect an account or set up physical cash to establish your baseline."*

### 3.2 Pillar 2: Activity (Canonical Events & Ingestion Queue)
- **User Mental Model**: *"What economic events have occurred, and what needs my confirmation?"*
- **Primary Information**:
  - Unified chronological feed of canonical `EconomicEvent`s.
  - Sticky search & filter bar (Filter by Account, Category, Event Type, Date Range).
  - Pinned "Review Inbox" chip displaying pending evidence counts (`[3 to Review]`).
- **Data Presentation Rules**:
  - Displays merchant/title, category badge, relative date, and net amount.
  - Directional indicator: Green `+₹X,XXX` for Income, Neutral White `-₹X,XXX` for Expense, Blue `⇄ ₹X,XXX` for Transfer, Amber `↶ ₹X,XXX` for Refund.
  - **Zero Accounting Jargon**: Never displays "Posting #491" or "Credit Asset".
- **Primary Action**: Filter/Search, or tap an item to open the Canonical Event Detail screen.

### 3.3 Pillar 3: Money (Balance Sheet: Assets, Cards & Debts)
- **User Mental Model**: *"Where is my money stored, how much credit do I owe, and what loans am I paying off?"*
- **Structural Grouping**:
  1. **Liquid Assets**: Checking Accounts, Savings Accounts, Physical Cash Wallets, Digital Wallets.
  2. **Credit Cards (Short-Term Liabilities)**: Outstanding statement balances, available limits, upcoming due dates.
  3. **Term Loans (Long-Term Liabilities)**: Mortgages, auto loans, personal loans, remaining tenure, and principal balances.
- **Account Detail Drilldown**:
  - Displays verified ledger-derived balance.
  - Explicitly separates **Total Ledger Balance** from **Earmarked Goal Reserves** and **Pending Draft Deductions**.
  - Provides a clean "Statement View" listing all events affecting this specific account.

### 3.4 Pillar 4: Plan (Deterministic Forecast, Budgets & Real Goals)
- **User Mental Model**: *"How will my cash look in 30/60/90 days, am I sticking to my budget, and how are my savings goals progressing?"*
- **Four Integrated Tabs**:
  1. **Cashflow Forecast**: Interactive balance curve combining ground truth cash, confirmed salary contracts, contractual EMIs/bills, and trailing 90-day median discretionary spending.
  2. **Budgets**: Monthly envelope overlays tracking actual net consumption against limits (with soft-deletes excluded and refunds credited).
  3. **Goals**: Honest asset earmarks displaying how much checking cash is allocated toward targets.
  4. **Recurring & Salary**: Direct management of `SalaryContract` and `RecurringRule` templates.

---

## 4. Cross-Cutting UI Components

1. **Global Action Hub (`+` FAB)**:
   - Centered on the navigation bar. Tapping reveals a clean, modal action palette:
     - **Log Expense** (Quick form pre-filled with recent merchants)
     - **Log Income** (Salary, freelance, cashback)
     - **Transfer Money** (Between own accounts)
     - **Pay Credit Card** (Liability settlement; zero expense impact)
     - **Scan Receipt** (ML Kit on-device camera OCR)
2. **Audited AI Assistant Interface**:
   - Accessed via a discrete sparkle icon in the top AppBar.
   - Slides up as a glass sheet. Displays an explicit **Context Privacy Shield**: *"Using verified October metrics (Income: ₹150k, Spend: ₹34.5k). Account numbers and raw text are never transmitted."*
3. **Pending Ingestion Review Queue**:
   - Dedicated full-screen tray accessible from Home or Activity when evidence requires human confirmation.
   - Presents ambiguous SMS, OCR candidates, and duplicate pairs with clean, one-tap decisions: `[Confirm]`, `[Merge]`, `[Keep Separate]`, `[Discard]`.
