import 'package:flutter/foundation.dart';

class AppEnv {
  static bool get isDebug => kDebugMode;
  static bool get enableLogs => kDebugMode;
  static bool get enableDebugTools => kDebugMode;
}
