# SpendX

SpendX is a Flutter personal finance app for tracking money across bank accounts, credit cards, loans, recurring payments, salary flows, vehicles, and long-term financial goals.

The project is built as a local-first mobile app with rich analytics, smart import workflows, notification support, and modular feature areas for budgeting, reporting, planning, and financial health.

## Highlights

- Local-first finance tracking using Flutter and SQLite
- Multi-account support for bank accounts, credit cards, lending, and loans
- Transaction management with categories, tags, filters, and review flows
- Smart import and parsing workflows for statements, shared files, OCR, and CSV-like data
- Budgeting, goal tracking, and financial planning dashboards
- Salary, recurring payment, and reminder management
- Net worth, reports, analytics, timeline, and health insights
- Vehicle expense and fuel tracking
- Gamification, streaks, wrapped summaries, and progress views
- Notification scheduling and share intent handling

## Tech Stack

- Flutter
- Dart
- Riverpod and Provider
- SQLite (`sqflite`)
- Google ML Kit text recognition
- Google Generative AI integrations
- Local notifications

## Project Structure

```text
lib/
  core/          App config, logging, shared utilities
  data/          Database, repositories, providers
  features/      Feature-first modules
  models/        Domain models
  screens/       App screens and flows
  services/      Business logic and integrations
  shared/        Shared UI primitives
  theme/         Theming and styling
  widgets/       Reusable widgets
```

## Features

### Money Management

- Add, edit, delete, and review transactions
- Track income, expenses, transfers, and liabilities
- Manage bank accounts, credit cards, loans, and lending records
- Organize spending with categories and tags

### Planning and Insights

- Budget tracking and category-level spending views
- Goal tracking for savings, debt payoff, and spending limits
- Financial timeline, daily digest, and alerts
- Net worth, monthly trends, and report screens
- Financial health and money score style dashboards

### Smart Input and Automation

- Smart import for CSV, ZIP, JSON, and shared files
- OCR-assisted receipt or document extraction
- Merchant normalization and duplicate detection helpers
- Recurring payment detection and reminder flows

### Lifestyle Modules

- Salary setup and month-level salary tracking
- Vehicle and fuel expense tracking
- Wrapped summaries, streaks, and gamification screens

## Installation

### Prerequisites

- Flutter SDK 3.10+
- Dart SDK compatible with the Flutter version above
- Android Studio or VS Code with Flutter tooling
- Xcode for iOS builds on macOS

### 1. Clone the project

```bash
git clone <your-repository-url>
cd SpendX
```

### 2. Install dependencies

```bash
flutter pub get
```

### 3. Create environment file

Copy the example environment file and fill in any values your local setup needs:

```bash
cp .env.example .env
```

### 4. Run the app

```bash
flutter run
```

## Configuration Notes

- `.env` is intentionally ignored by Git.
- Android notification, share intent, and exact alarm behavior rely on platform permissions declared in the Android manifest.
- The app uses a local SQLite database, so most day-to-day development can be done without a backend.

## Useful Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk
```

## Screenshots

Add screenshots to `/docs/screenshots/` and replace the placeholders below.

| Screen | Placeholder file |
| --- | --- |
| Dashboard | `docs/screenshots/dashboard-placeholder.png` |
| Accounts | `docs/screenshots/accounts-placeholder.png` |
| Transactions | `docs/screenshots/transactions-placeholder.png` |
| Insights | `docs/screenshots/insights-placeholder.png` |

## Roadmap Ideas

- Polished onboarding and demo data flow
- Expanded import validation and reconciliation tools
- Improved automated categorization confidence controls
- More complete test coverage across providers and services

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
