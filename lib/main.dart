import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:provider/provider.dart' as provider_pkg;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'core/logging/app_logger.dart';
import 'screens/splash_screen.dart';
import 'services/settings_service.dart';
import 'services/auth_service.dart';
import 'services/share_intent_service.dart';
import 'data/core/app_database.dart';
import 'data/core/schema_validator.dart';
import 'theme/app_theme.dart';
import 'core/config/app_env.dart';

Future<void>? appInitFuture;

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

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

      await dotenv.load(fileName: ".env");

      // 1. Critical Settings & Theme Init (Immediate)
      try {
        await SettingsService.instance.init().timeout(
          const Duration(seconds: 5),
        );
      } catch (e, st) {
        AppLogger.e('SettingsService init failed', e, st);
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
        // NEW: Lightweight DB Pre-warm
        // Starts opening the DB and running migrations in background to prevent cold hits
        unawaited(
          AppDatabase.instance.database.then((_) {}).catchError((e, st) {
            AppLogger.e('DB Pre-warm failed', e, st);
          }),
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
              provider_pkg.ChangeNotifierProvider.value(value: AuthService.instance),
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
  return;
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

    return MaterialApp(
      navigatorKey: MyApp.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'SpendX',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      home: const SplashScreen(),
    );
  }
}
