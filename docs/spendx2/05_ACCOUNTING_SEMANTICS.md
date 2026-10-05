# SpendX 2.0 — Accounting Semantics Specification

**Status**: PROPOSED  
**Classification**: CANONICAL ARCHITECTURE SPECIFICATION  
**Scope**: Complete Double-Entry Postings Guide for Transfers, Credit Cards, Refunds, and Loans

---

## 1. Transfer Semantics (Internal Asset Movements)

An internal transfer moves liquid purchasing power between accounts belonging to the user. It **never** creates income or expense.

### 1.1 Bank-to-Bank Transfer (HDFC $\rightarrow$ SBI ₹20,000)
- **Economic Event**: Internal Transfer
- **Postings**:
  ```
  Debit  Asset:Bank:SBI      ₹20,000  (Asset Increases)
  Credit Asset:Bank:HDFC     ₹20,000  (Asset Decreases)
  ```
- **Financial Invariants**:
  - Income Impact: **₹0**
  - Expense Impact: **₹0**
  - Net Worth Impact: **₹0**
  - Liquid Cash Impact: **₹0**

### 1.2 ATM Cash Withdrawal (Bank $\rightarrow$ Physical Wallet ₹5,000)
- **Postings**:
  ```
  Debit  Asset:Cash:PhysicalWallet ₹5,000  (Asset Increases)
  Credit Asset:Bank:HDFC           ₹5,000  (Asset Decreases)
  ```
- **Result**: Digital money converted to physical money. Zero expense. Spending occurs only when the cash is actually paid to a merchant.

### 1.3 Bank-to-Digital Wallet (Bank $\rightarrow$ Paytm Wallet ₹2,000)
- **Postings**:
  ```
  Debit  Asset:Wallet:Paytm ₹2,000
  Credit Asset:Bank:HDFC    ₹2,000
  ```

### 1.4 Currency Exchange / International Transfer ($1,000 USD $\rightarrow$ ₹83,000 INR)
- **Postings** (using Equity:CurrencyExchange clearing):
  ```
  Credit Asset:Bank:USChecking   $1,000  (USD)
  Debit  Equity:CurrencyExchange  $1,000  (USD)
  Credit Equity:CurrencyExchange  ₹83,000 (INR)
  Debit  Asset:Bank:IndiaSavings  ₹83,000 (INR)
  ```

---

## 2. Credit Card Accounting Semantics

A credit card is a short-term revolving liability.

### 2.1 Card Purchase (₹5,000 Groceries)
- **Economic Reality**: User incurs debt to acquire consumable goods.
- **Postings**:
  ```
  Debit  Expense:Food:Groceries     ₹5,000  (Expense Increases)
  Credit Liability:CreditCard:HDFC  ₹5,000  (Liability Increases)
  ```
- **Invariants**:
  - Monthly Expenses: **+₹5,000**
  - Bank Account Balance: **Unchanged**
  - Card Outstanding Debt: **+₹5,000**
  - Net Worth: **-₹5,000**

### 2.2 Card Bill Payment (₹5,000 from Bank Account)
- **Economic Reality**: Liquid asset used to extinguish debt. **NOT A CONSUMPTION EXPENSE**.
- **Postings**:
  ```
  Debit  Liability:CreditCard:HDFC  ₹5,000  (Liability Decreases)
  Credit Asset:Bank:HDFC            ₹5,000  (Asset Decreases)
  ```
- **Invariants**:
  - Monthly Expenses: **₹0 (Fixes the SpendX 1.0 double-counting bug)**
  - Monthly Income: **₹0**
  - Bank Balance: **-₹5,000**
  - Card Outstanding Debt: **-₹5,000**
  - Net Worth Impact: **₹0**

---

## 3. Refund Accounting Semantics

A refund is a reversal of a prior consumption event.

### 3.1 Full Refund on Same Account (Original ₹2,000 Shoes Returned)
- **Postings**:
  ```
  Debit  Asset:Bank:HDFC           ₹2,000  (Asset Restored)
  Credit Expense:Shopping:Apparel  ₹2,000  (Contra-Expense / Expense Decreases)
  ```
- **Invariants**:
  - Net Monthly Expense: ₹2,000 (original) - ₹2,000 (refund) = **₹0**
  - Net Worth: Restored to baseline.

### 3.2 Partial Refund (Kept ₹1,200 item, returned ₹800 item from ₹2,000 purchase)
- **Postings**:
  ```
  Debit  Asset:Bank:HDFC           ₹800
  Credit Expense:Shopping:Apparel  ₹800
  ```
- **Invariants**: Net Expense = **₹1,200**.

### 3.3 Refund Received on a Different Account
- User bought ₹10,000 phone on Credit Card, but merchant refunded ₹10,000 directly to Bank Savings via UPI:
  ```
  Debit  Asset:Bank:Savings        ₹10,000
  Credit Expense:Shopping:Gadgets  ₹10,000
  ```
- Gadgets expense is netted to ₹0; Bank Asset increases; Credit Card liability remains until bill payment.

---

## 4. Loan Accounting Semantics

Loans are formal liability contracts with amortization.

### 4.1 Loan Disbursement (₹500,000 Auto Loan)
- **Postings**:
  ```
  Debit  Asset:Bank:Savings     ₹500,000  (Cash Inflow)
  Credit Liability:Loan:Auto    ₹500,000  (Obligation Established)
  ```
- **Invariants**: Income = **₹0**; Net Worth Impact = **₹0**.

### 4.2 Monthly EMI Payment (₹15,000 Total: ₹10,000 Principal + ₹5,000 Interest)
- **Postings (Split Under Single Event)**:
  ```
  Credit Asset:Bank:Savings         ₹15,000  (Cash Outflow)
  Debit  Liability:Loan:Auto        ₹10,000  (Debt Principal Reduction)
  Debit  Expense:Finance:Interest    ₹5,000  (True Economic Consumption)
  ```
- **Invariants**:
  - Liquid Cash Outflow: **₹15,000**
  - Recognized Monthly Expense: **₹5,000** (Interest only)
  - Loan Principal Remaining: **Decreases by ₹10,000**
  - Net Worth Impact: **-₹5,000** (Depleted solely by interest cost)

### 4.3 Principal Prepayment (₹50,000 Lump Sum Prepayment)
- **Postings**:
  ```
  Credit Asset:Bank:Savings         ₹50,000
  Debit  Liability:Loan:Auto        ₹50,000
  ```
- **Invariants**: Expense = **₹0**; Debt reduced by ₹50,000; Net Worth change = **₹0**.
