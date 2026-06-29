<div align="center">

# 📊 SpendX

### **Your Money, Local-First. Secure, Subscription-Free Personal Finance.**

[![Flutter CI](https://github.com/masheddesigns/SpendX/actions/workflows/flutter_ci.yml/badge.svg)](https://github.com/masheddesigns/SpendX/actions/workflows/flutter_ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](https://makeapullrequest.com)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-lightgrey)](https://flutter.dev)

---

SpendX is a modern, privacy-friendly personal finance tracker designed for developers, creators, and individuals who want full ownership of their financial data. No subscriptions, no cloud lock-in, and no spreadsheet fatigue.

[Features](#-key-features) • [Tech Stack](#%EF%B8%8F-tech-stack) • [Architecture](#%EF%B8%8F-architecture) • [Getting Started](#-getting-started) • [Release Setup](#-release--production-signing)

</div>

---

## 💡 The Problem & The Solution

### **The Problem**
Most personal finance tools today require constant cloud syncing, force you into expensive monthly subscriptions, or compromise your privacy by linking directly to live bank accounts. When those services shut down or change their models, your history goes with them.

### **The Solution**
SpendX is built on a **local-first** philosophy. All transactional databases, settings, and credentials live directly on your physical device. It gives you the power of a comprehensive financial ledger, budgeting sheets, analytics, and intelligent imports without sacrificing your data privacy.

---

## ✨ Key Features

### 💳 Core Ledger & Money Flows
* **Multi-Account Management:** Track balances across cash, bank accounts, credit cards, loans, and lending arrangements.
* **Granular Tracking:** Organize transactions with categories, customizable tags, and advanced search/filters.
* **Offline-First Storage:** Powered by a local SQLite engine for instantaneous loads and zero-connection operation.

### 📅 Budgeting & Financial Control
* **Flexible Budgets:** Set up category-based budgets to visualize monthly or periodic spending.
* **Salary Planning Ledger:** Integrated flows to allocate and plan salary distribution across goals and bills.
* **Recurring Transactions:** Automate recurring expense logging (subscriptions, utility bills) on a flexible timeline engine.

### 📈 Reports & Deep Insights
* **Interactive Analytics:** View spending breakdowns, category metrics, and tag distributions through native canvas charts.
* **Net Worth History:** Track your overall net worth over time with local database snapshots.
* **Nudges & Health Nudges:** Receive subtle behavioral triggers about your spending trends.

### 🤖 Smart Inputs (OCR & Imports)
* **Digital Statement Parser:** Import records using bank-agnostic statement template mappings.
* **On-Device OCR Receipt Scanning:** Scan physical receipts using Google ML Kit to extract transaction details on-device.
* **SMS Intent Handler:** Optionally parse transaction messages locally to speed up entry.

---

## 🛠️ Tech Stack

SpendX uses modern mobile components to ensure high performance and maintainability:

* **Framework:** [Flutter](https://flutter.dev) (Dart)
* **State Management:** [Riverpod](https://riverpod.dev) & [Provider](https://pub.dev/packages/provider) for reactive state updates
* **Local Storage:** [sqflite](https://pub.dev/packages/sqflite) (SQLite for Android & iOS)
* **ML Engines:** [Google ML Kit Text Recognition](https://pub.dev/packages/google_mlkit_text_recognition) (local, on-device OCR)
* **CI/CD:** GitHub Actions workflow automatically verifying linting, formatting, and unit tests

---

## 🏗️ Architecture

SpendX follows a modular, feature-first structure with clean separation of layers:

```text
lib/
  ├── core/          # App configuration, logging, and global utilities
  ├── data/          # Local database schemas, migrations, and shared repositories
  ├── features/      # Feature modules (salary ledger, transactions, budget) with scoped state
  ├── models/        # Scoped serialization and domain models
  ├── screens/       # Core app screen structures and layout routes
  ├── services/      # Business logic, SMS parsing, and file import engines
  ├── shared/        # Reusable global UI elements and layout rules
  └── widgets/       # Core components and modular visual cards
```

Detailed documentation:
* 📘 [Architecture Specifications](docs/architecture.md)
* 💡 [Design Decisions & Tradeoffs](docs/design-decisions.md)
* 🗺️ [Development Roadmap](docs/roadmap.md)

---

## 🚀 Getting Started

### Prerequisites
* Flutter SDK (`3.10.0` or higher)
* Android Studio, VS Code, or Xcode (for iOS compilation)
* CocoaPods (if compiling on macOS for iOS)

### Installation & Run

1. **Clone the repository:**
   ```bash
   git clone https://github.com/masheddesigns/SpendX.git
   cd SpendX
   ```

2. **Install Flutter packages:**
   ```bash
   flutter pub get
   ```

3. **Configure Environment Variables:**
   ```bash
   cp .env.example .env
   ```

4. **Launch the application:**
   ```bash
   flutter run
   ```

---

## 🔐 Release & Production Signing

SpendX uses a robust, secure release setup designed to prevent sensitive credentials from ever being committed to Git.

### 1. Keystore Configuration
1. Place your release keystore at `android/keystore/spendx-release.jks`.
2. Create a local properties file at `android/key.properties` (this is ignored by Git):
   ```properties
   storePassword=YOUR_KEYSTORE_PASSWORD
   keyPassword=YOUR_KEY_PASSWORD
   keyAlias=spendx
   storeFile=keystore/spendx-release.jks
   ```

### 2. Gradle Integration
The [build.gradle.kts](android/app/build.gradle.kts) handles signing config parsing safely. It automatically trims copy/paste whitespace to prevent build signing mismatches:
```kotlin
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Inside android { ... }
signingConfigs {
    create("release") {
        keyAlias = (keystoreProperties["keyAlias"] as String?)?.trim()
        keyPassword = (keystoreProperties["keyPassword"] as String?)?.trim()
        storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it.toString().trim()) }
        storePassword = (keystoreProperties["storePassword"] as String?)?.trim()
    }
}
```

### 3. Generate Release APK
Build the release bundle:
```bash
flutter build apk --release
```

---

## 🔒 Security & Privacy

Since SpendX operates entirely local-first, **no personal financial data is ever sent to any remote server**. 
* SMS parsing is executed on-device using local string patterns.
* Receipt text extraction runs on-device using Google's local ML Kit OCR library.
* Backup and export features generate files locally to place control strictly in your hands.

Review our full security policy in [SECURITY.md](SECURITY.md).

---

## 🤝 Contributing

We welcome contributions! Please review the setup rules, testing workflows, and branching patterns in [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

---

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
