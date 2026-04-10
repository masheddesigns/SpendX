import 'package:shared_preferences/shared_preferences.dart';
import 'sms_pipeline_logger.dart';

/// Safe mode / kill switch for the SMS pipeline.
///
/// If the parser starts producing bad data:
///   1. Disable auto-import
///   2. Route ALL SMS to review queue
///   3. Alert the user
///
/// Triggers:
///   - Too many failures in a row (> 5)
///   - Too many review items in a row (> 10)
///   - User manually enables safe mode
///
/// Recovery:
///   - User reviews and approves queued items
///   - User manually disables safe mode
class SmsSafeMode {
  SmsSafeMode._();
  static final instance = SmsSafeMode._();

  static const _prefKey = 'sms_safe_mode_enabled';
  static const _failThreshold = 5;
  static const _reviewThreshold = 10;

  bool _enabled = false;
  int _consecutiveFailures = 0;
  int _consecutiveReviews = 0;

  bool get isEnabled => _enabled;

  /// Initialize from persisted state.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefKey) ?? false;
  }

  /// Enable safe mode (manual or automatic).
  Future<void> enable({String reason = 'manual'}) async {
    _enabled = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, true);
    SmsPipelineLogger.instance.log(
      stage: 'safe_mode',
      result: PipelineResult.failed,
      reason: 'Safe mode enabled: $reason',
    );
  }

  /// Disable safe mode (manual only).
  Future<void> disable() async {
    _enabled = false;
    _consecutiveFailures = 0;
    _consecutiveReviews = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, false);
  }

  /// Record a successful pipeline result. Resets failure counters.
  void recordSuccess() {
    _consecutiveFailures = 0;
    _consecutiveReviews = 0;
  }

  /// Record a failure. Auto-enables safe mode if threshold exceeded.
  Future<void> recordFailure() async {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _failThreshold && !_enabled) {
      await enable(reason: '$_consecutiveFailures consecutive failures');
    }
  }

  /// Record a review routing. Auto-enables safe mode if threshold exceeded.
  Future<void> recordReview() async {
    _consecutiveReviews++;
    if (_consecutiveReviews >= _reviewThreshold && !_enabled) {
      await enable(reason: '$_consecutiveReviews consecutive reviews — parser may be broken');
    }
  }
}
