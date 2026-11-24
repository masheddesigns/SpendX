import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:provider/provider.dart' as provider_pkg;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'core/logging/app_logger.dart';
import 'screens/splash_screen.dart';
import 'navigation/app_route_table.dart';
import 'services/settings_service.dart';
import 'services/auth_service.dart';
import 'services/share_intent_service.dart';
import 'services/live_sms_service.dart';
import 'services/notification_service_v2.dart';
import 'services/reminder_service.dart';
import 'data/core/app_database.dart';
import 'data/core/tracked_database_task_queue.dart';
import 'data/core/schema_validator.dart';
import 'theme/app_theme.dart';
import 'core/config/app_env.dart';
import 'services/sms_live_channel_bridge.dart';
import 'shared/widgets/app_page_route.dart';

Future<void>? appInitFuture;

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Eagerly initialize the live channel bridge to capture cold-start platform messages
      SmsLiveChannelBridge.instance;

      // Catch Flutter-level errors
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        AppLogger.e('Flutter Error', details.exception, details.stack);
      };

      // Catch Platform-level errors (async errors not caught by runZonedGuarded in some cases)
      PlatformDispatcher.instance.onError = (error, stack) {
        AppLogger.e('Platform Error', error, stack);
        return true;
      };
      // Optional .env loading for local development; gracefully skipped in production.
      try {
        await dotenv.load(fileName: ".env");
      } catch (_) {
        // Non-fatal: .env is intentionally omitted from release bundle assets.
      }
      // 1. Critical Settings & Theme Init (Immediate)
      try {
        await SettingsService.instance.init().timeout(
          const Duration(seconds: 5),
        );
      } catch (e, st) {
        AppLogger.e('SettingsService init failed', e, st);
      }

      // Initialize the notifications plugin + channels (idempotent) so that
      // show/showInstant work even before the first scheduled notification.
      try {
        await NotificationServiceV2().init();
      } catch (e, st) {
        AppLogger.e('NotificationService init failed', e, st);
      }

      if (AppEnv.enableDebugTools) {
        try {
          final db = await AppDatabase.instance.database;
          await SchemaValidator.validate(db);
        } catch (e, st) {
          AppLogger.e('Schema validation failed', e, st);
          rethrow;
        }
      } else {
        // NEW: Lightweight DB Pre-warm (tracked background task)
        // Starts opening the DB and running migrations in background to prevent cold hits
        TrackedDatabaseTaskQueue.instance.runTracked(
          'app_db_prewarm',
          () => AppDatabase.instance.database,
          onError: (e, st) {
            AppLogger.e('DB Pre-warm failed', e, st);
          },
        );
      }

      // 2. Start App Immediately
      runApp(
        riverpod.ProviderScope(
          child: provider_pkg.MultiProvider(
            providers: [
              provider_pkg.ChangeNotifierProvider(create: (_) => AppTheme()),
              provider_pkg.ChangeNotifierProvider.value(
                value: SettingsService.instance,
              ),
              provider_pkg.ChangeNotifierProvider.value(
                value: AuthService.instance,
              ),
            ],
            child: const MyApp(),
          ),
        ),
      );

      // 3. Background / Deferred Initializations
      appInitFuture = _deferredInitialization();
    },
    (error, stack) {
      AppLogger.e('Uncaught Zoned Error', error, stack);
    },
  );
}

Future<void> _deferredInitialization() async {
  // Start the periodic reminder/alert dispatch + budget checks. Safe to run
  // after the first frame; the DB pre-warm has already been kicked off above.
  try {
    await ReminderService.instance.init();
  } catch (e, st) {
    AppLogger.e('ReminderService init failed', e, st);
  }

  // Legacy repair routines are intentionally NOT executed here. The inventory
  // and containment policy live in `lib/services/legacy_repair_registry.dart`;
  // `LiveSmsService.runLegacyRepairsForQualification()` is the only entry
  // point and is disabled in release builds.

  // Live SMS detection — listen for incoming bank SMS and drain anything
  // captured while the app was closed.
  try {
    await LiveSmsService.instance.init();
  } catch (e, st) {
    AppLogger.e('LiveSmsService init failed', e, st);
  }
}

class QuickAddIntent extends Intent {
  const QuickAddIntent();
}

class SearchTransactionsIntent extends Intent {
  const SearchTransactionsIntent();
}

class MyApp extends riverpod.ConsumerStatefulWidget {
  const MyApp({super.key});

  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  riverpod.ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends riverpod.ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    // Initialize share intent listener after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ShareIntentService.instance.init(MyApp.navigatorKey);
      SmsLiveChannelBridge.instance.registerDeepLinkHandler((link) async {
        if (!SettingsService.instance.isOnboardingComplete) return;
        final routeName = AppRouteTable.normalize(link);
        await MyApp.navigatorKey.currentState?.pushNamed(routeName);
      });
    });
  }

  @override
  void dispose() {
    ShareIntentService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = provider_pkg.Provider.of<SettingsService>(
      context,
      listen: true,
    );
    final routeBuilders = AppRouteTable.routes;

    return MaterialApp(
      navigatorKey: MyApp.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'SpendX',
      onGenerateRoute: (routeSettings) {
        final routeName = AppRouteTable.normalize(routeSettings.name);
        final routeBuilder = routeBuilders[routeName];
        if (routeBuilder == null) return null;
        return AppPageRoute<void>(
          settings: RouteSettings(name: routeName),
          builder: routeBuilder,
        );
      },
      onGenerateInitialRoutes: (initialRoute) {
        final routeName = AppRouteTable.normalize(initialRoute);
        final linkedRoute = settings.isOnboardingComplete
            ? routeBuilders[routeName]
            : null;
        return [
          AppPageRoute<void>(
            settings: RouteSettings(name: routeName),
            builder: linkedRoute ?? (_) => const SplashScreen(),
          ),
        ];
      },
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        return Shortcuts(
          shortcuts: <ShortcutActivator, Intent>{
            LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyN):
                const QuickAddIntent(),
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyN):
                const QuickAddIntent(),
            LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF):
                const SearchTransactionsIntent(),
            LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
                const SearchTransactionsIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              QuickAddIntent: CallbackAction<QuickAddIntent>(
                onInvoke: (intent) {
                  if (settings.isOnboardingComplete) {
                    MyApp.navigatorKey.currentState
                        ?.pushNamed(AppRouteTable.addExpense);
                  }
                  return null;
                },
              ),
              SearchTransactionsIntent: CallbackAction<SearchTransactionsIntent>(
                onInvoke: (intent) {
                  if (settings.isOnboardingComplete) {
                    MyApp.navigatorKey.currentState
                        ?.pushNamed(AppRouteTable.transactions);
                  }
                  return null;
                },
              ),
            },
            child: content,
          ),
        );
      },
    );
  }
}
