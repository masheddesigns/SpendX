import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warning, error }

class AppLogger {
  static void d(String message) => _log(LogLevel.debug, message);
  static void i(String message) => _log(LogLevel.info, message);
  static void w(String message) => _log(LogLevel.warning, message);
  static void e(String message, [Object? error, StackTrace? stackTrace]) => 
      _log(LogLevel.error, message, error, stackTrace);

  static void _log(LogLevel level, String message, [Object? error, StackTrace? stackTrace]) {
    final time = DateTime.now().toIso8601String();
    final label = level.name.toUpperCase();
    
    // In production, we might send this to Crashlytics/Sentry
    if (kDebugMode) {
      final fullMessage = '[$time] [$label] $message';
      dev.log(fullMessage, name: 'SpendX', error: error, stackTrace: stackTrace);
      
      if (level == LogLevel.error) {
        print('❌ ERROR: $message');
        if (error != null) print('Details: $error');
      }
    } else {
      // PROD: Only log Warning and Error to console/analytics
      if (level == LogLevel.warning || level == LogLevel.error) {
         // analytics.logEvent(name: 'app_error', parameters: {'msg': message});
      }
    }
  }
}
