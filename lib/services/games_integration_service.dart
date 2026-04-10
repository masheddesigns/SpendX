import 'package:games_services/games_services.dart';
import '../core/logging/app_logger.dart';

class GamesIntegrationService {
  GamesIntegrationService._();
  static final GamesIntegrationService instance = GamesIntegrationService._();

  bool _isAuthenticated = false;

  Future<void> signIn() async {
    try {
      await GamesServices.signIn();
      _isAuthenticated = true;
      AppLogger.d('[GAMES] Signed in to Play Games');
    } catch (e) {
      AppLogger.d('[GAMES] Sign in failed: $e');
      _isAuthenticated = false;
    }
  }

  Future<void> unlockAchievement(String achievementId) async {
    if (!_isAuthenticated) return;
    try {
      await GamesServices.unlock(
        achievement: Achievement(
          androidID: achievementId,
        ),
      );
      AppLogger.d('[GAMES] Achievement unlocked: $achievementId');
    } catch (e) {
      AppLogger.d('[GAMES] Failed to unlock achievement: $e');
    }
  }

  Future<void> syncLevel(int level) async {
    if (!_isAuthenticated) return;
    try {
      await GamesServices.submitScore(
        score: Score(
          androidLeaderboardID: 'leaderboard_id',
          value: level,
        ),
      );
    } catch (e) {
      AppLogger.d('[GAMES] Failed to sync level: $e');
    }
  }
}
