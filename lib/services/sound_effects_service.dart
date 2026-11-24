import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';

import 'haptic_service.dart';

enum SoundEffect {
  pop,
  coin,
  whoosh,
  alert,
  success,
}

/// Central audio and tactile multi-sensory feedback service for SpendX.
///
/// Features:
/// - Pre-warmed audio player pool for zero-latency instant response.
/// - Synchronized haptic feedback matching the sonic frequency of each sound.
/// - Safe fallbacks to SystemSound/HapticFeedback if audio output is unavailable.
/// - Global enabled/disabled toggle hooked to user settings.
class SoundEffectsService {
  SoundEffectsService._() {
    _init();
  }

  static final SoundEffectsService instance = SoundEffectsService._();

  bool enabled = true;
  bool hapticsEnabled = true;

  final Map<SoundEffect, String> _soundPaths = {
    SoundEffect.pop: 'audio/pop.wav',
    SoundEffect.coin: 'audio/coin.wav',
    SoundEffect.whoosh: 'audio/whoosh.wav',
    SoundEffect.alert: 'audio/alert.wav',
    SoundEffect.success: 'audio/success.wav',
  };

  // Fixed pool of reusable AudioPlayers for low latency
  static const int _poolSize = 3;
  final List<AudioPlayer> _players = [];
  int _playerIndex = 0;
  bool _initialized = false;

  void _init() {
    if (_initialized) return;
    try {
      for (int i = 0; i < _poolSize; i++) {
        final p = AudioPlayer();
        p.setReleaseMode(ReleaseMode.stop);
        p.setVolume(0.85);
        _players.add(p);
      }
      _initialized = true;
    } catch (e) {
      debugPrint('SoundEffectsService initialization error: $e');
    }
  }

  /// Plays a sound effect with matching haptic feedback.
  Future<void> play(SoundEffect effect) async {
    // 1. Tactile feedback triggers immediately
    if (hapticsEnabled) {
      _triggerHaptic(effect);
    }

    // 2. Audio feedback
    if (!enabled || !_initialized || _players.isEmpty) {
      if (enabled) {
        // Fallback to built-in system sound
        try {
          if (effect == SoundEffect.alert) {
            unawaited(SystemSound.play(SystemSoundType.alert));
          } else {
            unawaited(SystemSound.play(SystemSoundType.click));
          }
        } catch (_) {}
      }
      return;
    }

    final assetPath = _soundPaths[effect];
    if (assetPath == null) return;

    try {
      final player = _players[_playerIndex];
      _playerIndex = (_playerIndex + 1) % _poolSize;

      await player.stop();
      await player.play(AssetSource(assetPath));
    } catch (e) {
      debugPrint('SoundEffectsService play error: $e');
    }
  }

  void _triggerHaptic(SoundEffect effect) {
    switch (effect) {
      case SoundEffect.pop:
        HapticService.instance.tap();
        break;
      case SoundEffect.coin:
        HapticService.instance.success();
        break;
      case SoundEffect.whoosh:
        HapticService.instance.selection();
        break;
      case SoundEffect.alert:
        HapticService.instance.critical();
        break;
      case SoundEffect.success:
        HapticService.instance.medium();
        break;
    }
  }

  // ── Convenience methods ───────────────────────────────────────
  void pop() => play(SoundEffect.pop);
  void coin() => play(SoundEffect.coin);
  void whoosh() => play(SoundEffect.whoosh);
  void alert() => play(SoundEffect.alert);
  void success() => play(SoundEffect.success);

  void dispose() {
    for (final p in _players) {
      p.dispose();
    }
    _players.clear();
    _initialized = false;
  }
}
