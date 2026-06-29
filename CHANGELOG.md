# Changelog

All notable changes to the SpendX project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-29

### Added
- **Core Wallet**: Multi-account support (cards, banks, loans, lending) and local SQLite storage.
- **Salary & Budgets**: Integrated salary planning ledger, envelopes/budgets, and recurring transaction engine.
- **Analytics**: Dashboards tracking expenses, categories, tags, and overall Net Worth.
- **Smart Imports**: SMS import parser, file-based imports, and Google ML Kit OCR receipt text extractor.
- **Extended Capabilities**: Vehicle mileage/fuel tracker, gamification streaks, and adaptive dark mode support.
- **CI/CD**: Added GitHub Actions workflow to build, test, and analyze code automatically.

### Fixed
- **Release Build Stability**: Configured ProGuard/R8 rules to avoid missing class compilation errors from optional ML Kit recognizers.
- **Production Signing**: Fully configured production release signing setup via Kotlin DSL reading from local `.gitignore`'d `key.properties`.
