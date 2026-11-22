import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/logging/app_logger.dart';

/// Encapsulates Google Play Store update status for the app.
class SpendXUpdateInfo {
  final bool isUpdateAvailable;
  final String currentVersion;
  final String currentBuildNumber;
  final int? availableVersionCode;
  final bool immediateAllowed;
  final bool flexibleAllowed;
  final String? error;

  const SpendXUpdateInfo({
    this.isUpdateAvailable = false,
    this.currentVersion = '',
    this.currentBuildNumber = '',
    this.availableVersionCode,
    this.immediateAllowed = false,
    this.flexibleAllowed = false,
    this.error,
  });

  String get displayVersion => 'v$currentVersion ($currentBuildNumber)';
}

/// Service managing Play Store In-App Updates and manual version verification.
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  AppUpdateInfo? _cachedUpdateInfo;
  SpendXUpdateInfo? _lastResult;

  SpendXUpdateInfo? get lastResult => _lastResult;
  bool get isUpdateAvailable => _lastResult?.isUpdateAvailable ?? false;

  static const String playStorePackageName = 'com.mashingdesigns.spendx';
  static const String playStoreMarketUrl =
      'market://details?id=$playStorePackageName';
  static const String playStoreWebUrl =
      'https://play.google.com/store/apps/details?id=$playStorePackageName';

  /// Queries Google Play Store Core API to check if an update is available.
  Future<SpendXUpdateInfo> checkForUpdate() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      final currentVer = pkg.version;
      final currentBuild = pkg.buildNumber;

      if (!kIsWeb && Platform.isAndroid) {
        try {
          final info = await InAppUpdate.checkForUpdate();
          _cachedUpdateInfo = info;

          final updateAvailable =
              info.updateAvailability == UpdateAvailability.updateAvailable;

          final result = SpendXUpdateInfo(
            isUpdateAvailable: updateAvailable,
            currentVersion: currentVer,
            currentBuildNumber: currentBuild,
            availableVersionCode: info.availableVersionCode,
            immediateAllowed: info.immediateUpdateAllowed,
            flexibleAllowed: info.flexibleUpdateAllowed,
          );
          _lastResult = result;
          return result;
        } catch (e) {
          AppLogger.w('[AppUpdateService] Play InAppUpdate query: $e');
        }
      }

      final fallbackResult = SpendXUpdateInfo(
        isUpdateAvailable: false,
        currentVersion: currentVer,
        currentBuildNumber: currentBuild,
      );
      _lastResult = fallbackResult;
      return fallbackResult;
    } catch (e) {
      AppLogger.w('[AppUpdateService] Check update failed: $e');
      final errResult = SpendXUpdateInfo(
        isUpdateAvailable: false,
        error: e.toString(),
      );
      _lastResult = errResult;
      return errResult;
    }
  }

  /// Triggers the Google Play In-App Update flow (immediate full-screen update).
  /// Falls back to opening the Play Store listing if in-app flow is unavailable.
  Future<bool> startUpdateFlow() async {
    if (!kIsWeb && Platform.isAndroid) {
      final info = _cachedUpdateInfo;
      if (info != null && info.immediateUpdateAllowed) {
        try {
          final appUpdateResult =
              await InAppUpdate.performImmediateUpdate();
          return appUpdateResult == AppUpdateResult.success;
        } catch (e) {
          AppLogger.w(
              '[AppUpdateService] Immediate update failed, falling back to Play Store: $e');
        }
      }
    }
    return openPlayStore();
  }

  /// Launches Google Play Store directly to SpendX's application page.
  Future<bool> openPlayStore() async {
    try {
      final marketUri = Uri.parse(playStoreMarketUrl);
      if (await canLaunchUrl(marketUri)) {
        return await launchUrl(
          marketUri,
          mode: LaunchMode.externalApplication,
        );
      }
      final webUri = Uri.parse(playStoreWebUrl);
      return await launchUrl(
        webUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      AppLogger.w('[AppUpdateService] Open Play Store failed: $e');
      return false;
    }
  }
}
