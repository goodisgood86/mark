import 'package:shared_preferences/shared_preferences.dart';

import '../models/constants.dart';
import 'petgram_backup_service.dart';
import 'petgram_supabase_sync_service.dart';

class PetgramAutoBackupService {
  PetgramAutoBackupService._internal();

  static final PetgramAutoBackupService instance =
      PetgramAutoBackupService._internal();
  bool _isRunning = false;
  static const Duration _initTimeout = Duration(seconds: 4);
  static const Duration _launchCooldown = Duration(minutes: 30);

  Future<void> runOnAppLaunchIfNeeded({
    Duration uploadTimeout = const Duration(seconds: 12),
  }) async {
    if (_isRunning) return;
    _isRunning = true;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(kAutoBackupEnabledKey) ?? false;
    if (!enabled) {
      _isRunning = false;
      return;
    }

    final now = DateTime.now();
    final today = _ymd(now);
    final lastRunDate = prefs.getString(kLastAutoBackupDateKey);
    // 이미 오늘 자동 백업을 처리했다면, Supabase 초기화/네트워크 작업 자체를 건너뜀.
    if (lastRunDate == today) {
      _isRunning = false;
      return;
    }

    // 앱 시작 직후 중복 트리거(재진입/경합)로 인한 부하를 줄이기 위한 최소 쿨다운.
    final lastRunAtMs = prefs.getInt(kLastAutoBackupAtKey) ?? 0;
    if (lastRunAtMs > 0) {
      final elapsed = now.toUtc().millisecondsSinceEpoch - lastRunAtMs;
      if (elapsed >= 0 && elapsed < _launchCooldown.inMilliseconds) {
        _isRunning = false;
        return;
      }
    }

    if (!PetgramSupabaseSyncService.instance.hasEnvironmentConfig) {
      _isRunning = false;
      return;
    }

    try {
      await PetgramSupabaseSyncService.instance.ensureInitialized().timeout(
        _initTimeout,
      );
      if (PetgramSupabaseSyncService.instance.currentUser == null) return;

      final currentSignature = await PetgramBackupService.instance
          .readDataSignatureToken();
      final lastSignature = prefs.getString(kLastBackupSignatureKey) ?? '';

      if (currentSignature == lastSignature) {
        await prefs.setString(kLastAutoBackupDateKey, today);
        return;
      }

      final result = await PetgramSupabaseSyncService.instance
          .uploadBackup(syncMissingLocalMedia: false)
          .timeout(uploadTimeout);
      if (result.uploaded) {
        await _markBackupSucceeded(
          prefs: prefs,
          signature: currentSignature,
          now: now,
        );
      } else {
        await prefs.setString(kLastAutoBackupDateKey, today);
      }
    } catch (_) {
      // 앱 시작 자동 백업 실패는 사용자 동선을 방해하지 않는다.
    } finally {
      _isRunning = false;
    }
  }

  Future<void> markManualBackupSucceeded() async {
    final prefs = await SharedPreferences.getInstance();
    final signature = await PetgramBackupService.instance
        .readDataSignatureToken();
    await _markBackupSucceeded(
      prefs: prefs,
      signature: signature,
      now: DateTime.now(),
    );
  }

  Future<void> _markBackupSucceeded({
    required SharedPreferences prefs,
    required String signature,
    required DateTime now,
  }) async {
    await prefs.setInt(
      kLastAutoBackupAtKey,
      now.toUtc().millisecondsSinceEpoch,
    );
    await prefs.setString(kLastAutoBackupDateKey, _ymd(now));
    await prefs.setString(kLastBackupSignatureKey, signature);
  }

  String _ymd(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
