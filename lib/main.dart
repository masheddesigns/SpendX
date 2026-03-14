import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/splash_screen.dart';
import 'services/settings_service.dart';
import 'services/transaction_service.dart';
import 'services/gemini_service.dart';
import 'services/notification_service.dart';
import 'services/cloud_backup_service.dart';
import 'services/app_session_service.dart';
import 'theme/app_theme.dart';

// Background task dispatcher removed as Workmanager is no longer a dependency.

Future<void>? appInitFuture;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  // 1. Critical Settings & Theme Init (Immediate)
  try {
    await SettingsService.instance.init().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('SettingsService init failed/timed out: $e');
  }

  // 2. Start App Immediately to avoid black screen focus on splash
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppTheme()),
        ChangeNotifierProvider.value(value: SettingsService.instance),
      ],
      child: const MyApp(),
    ),
  );

  // 3. Background / Deferred Initializations (Non-blocking)
  appInitFuture = _deferredInitialization();
}

Future<void> _deferredInitialization() async {
  // Groq & Notifications
  try {
    GeminiService.instance.init();
    await NotificationService.instance.init();
  } catch (e) {
    debugPrint('Service deferred init failed: $e');
  }

  // Background sync worker removed (Workmanager dependency removed)

  // Database
  try {
    await TransactionService.instance.init();
    await CloudBackupService.instance.init(); // Initialize sync listener
    AppSessionService.instance.init(); // Initialize session tracking
  } catch (e) {
    debugPrint('Resource deferred init failed: $e');
  }


}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppTheme>(
      builder: (context, themeNotifier, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'SpendX',
          theme: themeNotifier.getTheme().copyWith(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
              },
            ),
          ),
          themeMode: ThemeMode.dark,
          home: const SplashScreen(),
        );
      },
    );
  }
}