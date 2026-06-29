# Contributing to SpendX

First off, thank you for considering contributing to SpendX! It's people like you who make SpendX a better tool for everyone.

Here are the guidelines to help you contribute effectively to the project.

## How Can I Contribute?

### Reporting Bugs
If you find a bug, please create a new issue using our **Bug Report** template. Ensure you provide:
- Clear steps to reproduce.
- Scoped environment specs (OS, device, Flutter version).
- Expected vs. actual behavior.
- Relevant log files or screenshots.

### Requesting Features
We love suggestions! Create a new issue using our **Feature Request** template to discuss your ideas.

### Submitting Pull Requests
If you want to write code:
1. **Fork the Repository**: Create a fork of this repository.
2. **Create a Feature Branch**: Make your changes in a branch off `main` (e.g., `feature/cool-new-feature` or `bugfix/issue-description`).
3. **Verify and Format Code**:
   - Ensure the code formats correctly:
     ```bash
     dart format .
     ```
   - Run the compiler analysis to catch issues:
     ```bash
     flutter analyze
     ```
   - Ensure all tests pass:
     ```bash
     flutter test
     ```
4. **Submit PR**: Open a pull request against the `main` branch. Provide a clear description of your changes and why they are necessary.

## Development Setup

To run SpendX locally:
1. Clone your fork:
   ```bash
   git clone https://github.com/<your-username>/SpendX.git
   cd SpendX
   ```
2. Get dependencies:
   ```bash
   flutter pub get
   ```
3. Copy environment configuration:
   ```bash
   cp .env.example .env
   ```
4. Run the application:
   ```bash
   flutter run
   ```

## Code of Conduct
Please review and follow our [Code of Conduct](CODE_OF_CONDUCT.md) in all your interactions with the project.
