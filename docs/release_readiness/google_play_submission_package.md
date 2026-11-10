# SpendX — Google Play Distribution Preparation Package
**Milestone**: Milestone 5.0 — Phase 5C Distribution Qualification  
**Target Release**: SpendX 1.6.0 (versionCode 16)  
**Package Name**: `com.mashingdesigns.spend_x`  
**Candidate Release AAB SHA-256**: `9d1a7d969c31f8a5846c0c8749ed3c24cf8ab5bfb67667fca776ed7fac7f16cc`  
**Security Gate**: `G-SEC-01-LOCK` remains **HELD** (Internal test track only; zero public release without explicit security release)

---

## 1. Google Play SMS & Call Log Permissions Declaration

### Core Use Case Category
- **Selected Exception Category**: **Financial and money management applications** (Automated SMS-based expense tracking).
- **Declared Permissions**:
  - `android.permission.RECEIVE_SMS`
  - `android.permission.READ_SMS`

### Justification & Purpose Statement for Play Console
> "SpendX is a personal finance and money management application designed for Indian and regional banking users whose financial transactions (debits, credits, refunds, bill reminders, card statements) are communicated almost exclusively via bank-issued transactional SMS.
> 
> SpendX requires `RECEIVE_SMS` to detect incoming transactional SMS in real-time and extract economic events (amount, merchant/beneficiary, source account/card) completely on-device without any cloud transmission.
> 
> SpendX requires `READ_SMS` for the user-initiated 'Sync Transaction History' and 'Sync Upcoming Bills' features, allowing users to import historical bank statements and track active debt obligations.
> 
> Without these permissions, the core value proposition of automated personal financial accounting, Safe-to-Spend calculation, and statement reconciliation is non-functional."

### Critical Safeguards Declared
1. **Zero Network Transmission**: SMS messages are parsed 100% on-device by `FinancialSmsFilter.kt` and `CanonicalTransactionAdapter`. No SMS content, metadata, or phone numbers are ever sent to external servers or third-party SDKs.
2. **Strict Financial Filtering**: Non-financial SMS (OTPs, personal chats, marketing, service alerts, telecom recharges) are dropped natively at the receiver layer before reaching application storage.
3. **Review Queue Approval**: Detected transactions are placed into an in-app review queue for explicit user confirmation before canonical ledger posting.
4. **Automated Evidence Pruning**: Retained raw SMS payloads are automatically pruned after 30 days pursuant to financial privacy retention standards.

---

## 2. Play Console Demonstration Video & Script Requirements

Google Play Policy mandates a video demonstration showing the end-to-end user flow for SMS permissions.

### Demonstration Video Requirements
- **Format**: MP4 / YouTube unlisted link.
- **Resolution**: 1080p, 60fps or 30fps.
- **Audio/Captions**: Clear English voiceover or high-contrast on-screen annotations explaining every user action.
- **Duration**: Between 90 and 150 seconds.

### Demonstration Script (Step-by-Step)
1. **App Launch & Welcome (0:00 - 0:15)**:
   - Launch app from launcher.
   - Show user entering dashboard.
   - Navigate to "Settings" -> "Notifications & Auto-Tracking".
2. **Prominent In-App Disclosure (0:15 - 0:35)**:
   - User toggles "Live SMS Detection".
   - App presents the **Prominent Disclosure Modal** detailing:
     - Why SMS is requested (bank SMS expense tracking).
     - That parsing happens locally on-device.
     - That SMS is never uploaded to any server.
   - User reviews and clicks "Accept & Continue".
3. **Runtime System Permission Request (0:35 - 0:45)**:
   - Android OS permission dialog appears: "Allow SpendX to send and view SMS messages?".
   - User selects "Allow".
4. **Real Financial SMS Event (0:45 - 1:15)**:
   - Send/receive a simulated bank debit SMS (e.g. `HDFC Bank: Rs 450.00 debited from a/c **1234 on 09-Nov-26 to SWIGGY`).
   - Show native heads-up notification: "Bank transaction detected".
   - Tap notification to open SpendX.
5. **Review Queue & Ledger Commitment (1:15 - 1:45)**:
   - SpendX navigates to the "Review Queue".
   - Show candidate transaction: ₹450.00, Merchant: Swiggy, Category: Food & Dining.
   - User taps "Approve".
   - Show instant posting to canonical ledger, updating the account balance and Safe-to-Spend display.
6. **Privacy & Settings Verification (1:45 - 2:00)**:
   - Navigate to Settings -> "Privacy Policy" and "Evidence Retention".
   - Show 30-day raw SMS pruning and local encrypted database explanation.

---

## 3. Prominent Disclosure & Consent Text

The in-app disclosure must be displayed **prior** to triggering the Android runtime permission dialog (`ActivityCompat.requestPermissions`).

### Display Surface
- **Modal Title**: "Financial SMS Auto-Tracking"
- **Primary Message**:
  > "SpendX reads incoming bank and financial SMS messages directly on your device to automatically detect expenses, refunds, and bill payments.
  > 
  > • **100% On-Device**: Your SMS messages are never uploaded to any cloud server or shared with any third party.  
  > • **Financial Messages Only**: SpendX rejects personal texts, marketing promos, and OTPs.  
  > • **User Control**: Every detected transaction appears in your Review Queue for your final approval.  
  > • **Automatic Pruning**: Raw SMS evidence is automatically deleted after 30 days."
- **Actions**:
  - `[Not Now / Decline]` -> Leaves feature disabled without requesting system permission.
  - `[Continue]` -> Requests `android.permission.RECEIVE_SMS` / `READ_SMS`.

---

## 4. Privacy Policy Verification & Data Handling

- **Public URL**: `https://spendx.mashingdesigns.com/privacy-policy` (must match Google Play Store Listing).
- **In-App URL/Screen**: Available offline in `lib/screens/privacy_policy_screen.dart` via Settings -> About SpendX -> Privacy Policy.
- **Compliance Affirmations**:
  - No central backend server collecting financial data.
  - No third-party ad networks or tracking telemetry.
  - AES-256 encrypted Google Drive backup strictly confined to user's personal Drive `appDataFolder`.
  - SQLite database encrypted with SQLCipher via `flutter_secure_storage` hardware-backed key storage.

---

## 5. Google Play Data Safety Declaration Inputs

| Data Type | Collected | Shared | Ephemeral / Stored | Purpose | Optional / Required |
|---|---|---|---|---|---|
| **Financial Info** (User payment info, purchase history, credit/loan balances) | **Yes** (Local on-device) | **No** (0% shared) | Stored locally in SQLCipher DB; encrypted cloud backup optional | App Functionality, Account Management | Required for core functionality |
| **SMS / MMS** (Financial SMS text) | **Yes** (Local on-device) | **No** (0% shared) | Parsed on-device; raw payloads pruned after 30 days | App Functionality (Expense tracking) | Optional (user can use manual logging) |
| **Personal Identifiers** (Name, email address) | **No** | **No** | Not collected (Google Drive backup uses user's Google Auth token) | N/A | N/A |
| **App Performance & Diagnostics** | **No** | **No** | No external crashlytics/telemetry SDKs bundled | N/A | N/A |

### Security Practices Declaration
- **Data Encrypted in Transit**: Yes (HTTPS for Gemini API receipt scan and Google Drive API).
- **Data Encrypted at Rest**: Yes (SQLCipher AES-256 for local SQLite database, AES-256 for Drive backup).
- **User Data Deletion Request**: Yes (In-app "Reset Database & Wipe All Data" + Google Drive app data deletion).

---

## 6. Exact Alarm Permission (`SCHEDULE_EXACT_ALARM`) Justification

- **Permission**: `android.permission.SCHEDULE_EXACT_ALARM`
- **Play Console Policy Category**: **Timely reminders for bills, loan EMIs, and financial commitments**.
- **Justification Statement**:
  > "SpendX is a financial commitment and money management application. Users schedule specific bill payment reminders and loan EMI due-date alerts. Exact alarms are required to notify users at the exact specified time before bank late fees, penalties, or credit score impacts occur.
  > 
  > SpendX does not use `USE_EXACT_ALARM`. On Android 13+, SpendX requests `SCHEDULE_EXACT_ALARM` and implements proactive and reactive graceful fallback (`AndroidScheduleMode.inexactAllowWhileIdle`) when the permission is denied or revoked by the user, ensuring the app never crashes."

---

## 7. Internal Testing Track Release Notes

### What's New in SpendX 1.6.0 (Build 16)
```text
SpendX 1.6.0 — Stability, Precision & Release Candidate Update

• Financial Precision: Hardened Safe-to-Spend attribution for partial credit-card payments and zero-interest loans.
• Real-Time Tracking: Enhanced on-device bank SMS parser with hardened transient retry handling and quarantine protection.
• Privacy & Security: SQLCipher database encryption at rest, 30-day raw SMS payload pruning, and local-first architecture.
• Reliability: Refined exact-alarm permission handling with graceful inexact fallback for bill and EMI reminders.
• Backup & Recovery: Canonical portable backup and restore engine with SHA-256 validation and atomic staging verification.
```

---

## 8. Items Requiring Manual Play Console Approval

The following items cannot be automated and must be executed manually in the Google Play Console:
1. **SMS / Call Log Permissions Declaration Form**: Complete declaration form in Play Console -> App Content -> Permissions.
2. **Review Video Submission**: Submit YouTube unlisted link demonstrating prominent disclosure and SMS parsing flow.
3. **Data Safety Form Submission**: Complete questionnaire using the inputs in Section 5.
4. **App Access Credentials**: SpendX requires no login or cloud account; select "All functionality is available without credentials".
5. **Government / Financial Apps Verification**: Affirm compliance with RBI / local financial application guidelines (purely client-side utility).
