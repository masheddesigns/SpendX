# Architecture Notes

## App Structure

SpendX uses a modular Flutter structure with feature-level organization layered on top of shared data and service abstractions.

## Main Layers

### UI Layer

- `lib/screens/`
- `lib/features/**/screens/`
- `lib/widgets/`
- `lib/shared/widgets/`

This layer contains screens, flows, reusable widgets, and presentation-level composition.

### State Layer

- Riverpod providers
- feature-scoped providers
- app-level providers in `lib/data/providers.dart`

This layer coordinates screen state, derived values, async loading, and view updates.

### Data Layer

- repositories in `lib/data/repositories/`
- SQLite database setup in `lib/data/core/`

This layer handles persistence, querying, and repository boundaries.

### Service Layer

- `lib/services/`

This layer contains product logic such as import handling, forecasting, financial health logic, OCR-related helpers, notifications, and decision support.

## Notable Architectural Traits

- Local-first persistence
- Heavy feature coverage across finance domains
- Mixed app-wide and feature-local provider usage
- Product-oriented service layer for analytics and intelligence

## Areas to Keep Improving

- continue isolating side effects from widget build paths
- expand test coverage around provider and import flows
- document import architecture and analytics pipelines in more depth
- strengthen release and environment configuration for public collaboration
