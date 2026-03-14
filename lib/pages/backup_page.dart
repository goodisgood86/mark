import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/constants.dart';
import '../models/petgram_nav_tab.dart';
import '../services/petgram_auto_backup_service.dart';
import '../services/petgram_camera_lifecycle_guard.dart';
import '../services/petgram_supabase_sync_service.dart';
import '../widgets/petgram_bottom_nav_bar.dart';
import 'diary_page.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> with WidgetsBindingObserver {
  static const MethodChannel _cameraChannel = MethodChannel(
    'petgram/camera_control',
  );
  static const MethodChannel _nativeCameraChannel = MethodChannel(
    'petgram/native_camera',
  );
  static int _overlayPageCount = 0;

  final int _instanceId = DateTime.now().microsecondsSinceEpoch;
  StreamSubscription<AuthState>? _authStateSub;
  bool _isBusy = false;
  bool _awaitingAuthCompletion = false;
  bool _autoBackupEnabled = false;
  bool _policyAccepted = false;
  bool _isRefreshingBackupInfo = false;
  bool _backupPageCameraLockHeld = false;
  bool _backupPageCameraLockReleased = false;
  bool? _lastSkipAutoReinitValue;
  BackupSnapshotInfo? _lastBackupInfo;

  bool get _isLinked => PetgramSupabaseSyncService.instance.currentUser != null;

  @override
  void initState() {
    super.initState();
    PetgramCameraLifecycleGuard.acquire();
    _backupPageCameraLockHeld = true;
    _overlayPageCount++;
    _log('initState (overlayCount=$_overlayPageCount)');
    WidgetsBinding.instance.addObserver(this);
    if (_overlayPageCount == 1) {
      // 첫 오버레이 페이지만 카메라 라이프사이클 제어
      unawaited(_setCameraLifecycleSuppressed(true));
      unawaited(_setNativeSkipAutoReinit(true));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_pauseCameraSafely());
      });
    }
    unawaited(_loadPagePrefs());
    unawaited(_bindAuthStateListener());
    unawaited(_refreshRemoteBackupInfo());
  }

  @override
  void dispose() {
    _log('dispose (overlayCount=$_overlayPageCount)');
    if (_backupPageCameraLockHeld) {
      _backupPageCameraLockHeld = false;
      if (!_backupPageCameraLockReleased) {
        _backupPageCameraLockReleased = true;
        PetgramCameraLifecycleGuard.release();
      }
    }
    _overlayPageCount = _overlayPageCount > 0 ? _overlayPageCount - 1 : 0;
    if (_overlayPageCount == 0) {
      unawaited(_setCameraLifecycleSuppressed(false));
      unawaited(_setNativeSkipAutoReinit(false));
    }
    WidgetsBinding.instance.removeObserver(this);
    _authStateSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_refreshRemoteBackupInfo());
    }
  }

  Future<void> _pauseCameraSafely() async {
    try {
      await _cameraChannel.invokeMethod('pauseCamera');
    } catch (e) {
      if (e is MissingPluginException) return;
    }
  }

  Future<void> _setCameraLifecycleSuppressed(bool value) async {
    try {
      await _cameraChannel.invokeMethod('setCameraLifecycleSuppressed', value);
    } catch (e) {
      if (e is MissingPluginException) return;
    }
  }

  Future<void> _setNativeSkipAutoReinit(bool skip) async {
    if (_lastSkipAutoReinitValue == skip) return;
    _lastSkipAutoReinitValue = skip;
    try {
      await _nativeCameraChannel.invokeMethod('setSkipAutoReinit', {
        'skip': skip,
      });
    } catch (_) {}
  }

  Future<void> _loadPagePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _autoBackupEnabled = prefs.getBool(kAutoBackupEnabledKey) ?? false;
      _policyAccepted = prefs.getBool(kBackupPolicyAcceptedKey) ?? false;
    });
  }

  Future<void> _bindAuthStateListener() async {
    if (!PetgramSupabaseSyncService.instance.hasEnvironmentConfig) return;
    try {
      await PetgramSupabaseSyncService.instance.ensureInitialized();
    } catch (_) {
      return;
    }
    await _authStateSub?.cancel();

    _authStateSub = Supabase.instance.client.auth.onAuthStateChange.listen((
      data,
    ) {
      _log(
        'auth event=${data.event.name}, hasSession=${data.session != null}, user=${data.session?.user.id ?? '-'}',
      );
      if (!mounted) return;
      if (data.event == AuthChangeEvent.initialSession) {
        // initialSession은 앱 복귀/리스너 재구독 시 반복되므로 UI/카메라 흐름에 관여시키지 않는다.
        return;
      }
      if (data.event == AuthChangeEvent.signedIn &&
          !_awaitingAuthCompletion &&
          data.session?.user.id ==
              PetgramSupabaseSyncService.instance.currentUser?.id) {
        // 같은 세션의 signedIn 이벤트가 외부 OAuth 복귀 과정에서 반복 발생할 수 있어 무시
        return;
      }
      setState(() {});

      if (data.event == AuthChangeEvent.signedIn) {
        if (_awaitingAuthCompletion) {
          _awaitingAuthCompletion = false;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('연동이 완료되었습니다.'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 2),
            ),
          );
        }
        unawaited(_refreshRemoteBackupInfo());
      }
      if (data.event == AuthChangeEvent.signedOut) {
        setState(() => _lastBackupInfo = null);
      }
    });
  }

  Future<void> _setPolicyAccepted(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBackupPolicyAcceptedKey, value);
    if (!mounted) return;
    setState(() => _policyAccepted = value);
  }

  Future<void> _setAutoBackupEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAutoBackupEnabledKey, value);
    if (!mounted) return;
    setState(() => _autoBackupEnabled = value);
    if (value && _isLinked) {
      unawaited(PetgramAutoBackupService.instance.runOnAppLaunchIfNeeded());
    }
  }

  Future<void> _refreshRemoteBackupInfo() async {
    if (_isRefreshingBackupInfo) return;
    _isRefreshingBackupInfo = true;
    try {
      final info = await PetgramSupabaseSyncService.instance
          .fetchRemoteBackupInfo();
      if (!mounted) return;
      setState(() => _lastBackupInfo = info);
    } catch (_) {
      if (!mounted) return;
      setState(() => _lastBackupInfo = null);
    } finally {
      _isRefreshingBackupInfo = false;
    }
  }

  String _backupSummaryText() {
    final info = _lastBackupInfo;
    if (info == null) return '최근 백업: 없음';
    final updated = info.updatedAtUtc?.toLocal();
    final when = updated == null
        ? '시간 정보 없음'
        : '${updated.year}.${updated.month.toString().padLeft(2, '0')}.${updated.day.toString().padLeft(2, '0')} '
              '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
    return '최근 백업: $when\n상세 내역 : 사진 ${info.photoCount}건, 일기 ${info.diaryEntryCount}건, 태그 ${info.tagCount}건';
  }

  String _friendlyAuthError(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('authorizationerror error 1000') ||
        lower.contains('authorizationerrorcode.unknown') ||
        lower.contains('com.apple.authenticationservices.authorizationerror')) {
      return '애플 로그인 설정이 완료되지 않았습니다. '
          'Xcode Sign in with Apple Capability와 Apple Developer 설정(App ID/Service ID/Key)을 확인해주세요.';
    }
    if (lower.contains('provider is not enabled')) {
      return 'Supabase에서 해당 연동 Provider가 비활성화되어 있습니다.';
    }
    if (lower.contains('signups not allowed')) {
      return '신규 가입이 비활성화되어 있습니다. Supabase Auth 설정에서 가입 허용을 켜주세요.';
    }
    if (lower.contains('redirect') || lower.contains('session이 생성되지')) {
      return '로그인 후 앱으로 돌아오지 못했습니다. Supabase Redirect URL 설정을 확인해주세요.';
    }
    if (lower.contains('invalid_client') || lower.contains('unauthorized')) {
      return 'OAuth 클라이언트 설정이 올바르지 않습니다. Google/Apple 콘솔 설정을 확인해주세요.';
    }
    return raw;
  }

  bool _isAuthCancelled(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();
    return lower.contains('cancelled') ||
        lower.contains('canceled') ||
        lower.contains('user cancelled') ||
        lower.contains('user canceled') ||
        lower.contains('aborted') ||
        lower.contains('close') ||
        lower.contains('취소') ||
        lower.contains('authorizationerrorcode.canceled') ||
        lower.contains('authorizationerror error 1001') ||
        lower.contains('sign_in_canceled') ||
        lower.contains('access_denied');
  }

  bool _canLink(bool hasConfig) => hasConfig && !_isBusy && _policyAccepted;

  Future<void> _signInWithGoogle() async {
    if (_isBusy) return;
    if (!_policyAccepted) {
      _showSnack('연동 전에 개인정보 수집/이용 안내에 동의해주세요.');
      return;
    }
    PetgramCameraLifecycleGuard.acquire();
    PetgramCameraLifecycleGuard.beginAuthFlow();
    _awaitingAuthCompletion = true;
    setState(() => _isBusy = true);
    try {
      await PetgramSupabaseSyncService.instance.signInWithGoogle();
    } catch (e) {
      _awaitingAuthCompletion = false;
      if (_isAuthCancelled(e)) return;
      _showSnack('Google 연동 실패: ${_friendlyAuthError(e)}');
    } finally {
      PetgramCameraLifecycleGuard.endAuthFlow();
      PetgramCameraLifecycleGuard.release();
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _signInWithApple() async {
    if (_isBusy) return;
    if (!_policyAccepted) {
      _showSnack('연동 전에 개인정보 수집/이용 안내에 동의해주세요.');
      return;
    }
    PetgramCameraLifecycleGuard.acquire();
    PetgramCameraLifecycleGuard.beginAuthFlow();
    _awaitingAuthCompletion = true;
    setState(() => _isBusy = true);
    try {
      await PetgramSupabaseSyncService.instance.signInWithApple();
    } catch (e) {
      _awaitingAuthCompletion = false;
      if (_isAuthCancelled(e)) return;
      _showSnack('Apple 연동 실패: ${_friendlyAuthError(e)}');
    } finally {
      PetgramCameraLifecycleGuard.endAuthFlow();
      PetgramCameraLifecycleGuard.release();
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _log(String msg) {
    if (!kDebugMode) return;
    debugPrint('[Petgram][BackupPage#$_instanceId] $msg');
  }

  Future<void> _signOutSupabase() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      await PetgramSupabaseSyncService.instance.signOut();
      _awaitingAuthCompletion = false;
      _showSnack('연동 해제되었습니다.');
    } catch (e) {
      _showSnack('연동 해제 실패: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _withdrawAccount() async {
    if (_isBusy || !_isLinked) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('계정 탈퇴'),
        content: const Text(
          '계정을 탈퇴하면 서버 백업 데이터도 함께 삭제됩니다.\n탈퇴 후에는 되돌릴 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('탈퇴하기'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBusy = true);
    try {
      final result = await PetgramSupabaseSyncService.instance
          .withdrawAccount();
      _awaitingAuthCompletion = false;
      setState(() => _lastBackupInfo = null);
      if (result.authDeleted && result.backupDeleted) {
        _showSnack('계정 탈퇴가 완료되었습니다. 백업 데이터도 삭제되었습니다.');
      } else if (result.authDeleted) {
        _showSnack('계정 탈퇴가 완료되었습니다.');
      } else {
        _showSnack('계정 탈퇴 처리 결과를 확인해주세요.');
      }
    } catch (e) {
      _showSnack('계정 탈퇴 실패: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _uploadBackupToSupabase() async {
    if (_isBusy) return;
    if (!_isLinked) {
      _showSnack('먼저 계정 연동을 완료해주세요.');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final result = await PetgramSupabaseSyncService.instance.uploadBackup();
      if (result.uploaded) {
        await PetgramAutoBackupService.instance.markManualBackupSucceeded();
        await _refreshRemoteBackupInfo();
        _showSnack(result.fullBackup ? '백업이 완료되었습니다.' : '최신 데이터로 업데이트 되었습니다.');
      } else {
        _showSnack('최신데이터 입니다.');
      }
    } catch (e) {
      _showSnack('백업 실패: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _restoreFromSupabase() async {
    if (_isBusy) return;
    if (!_isLinked) {
      _showSnack('먼저 계정 연동을 완료해주세요.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('백업 불러오기'),
        content: const Text('서버의 최신 백업을 불러올까요?\n기존 데이터와 병합됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('불러오기'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBusy = true);
    try {
      final result = await PetgramSupabaseSyncService.instance.restoreBackup();
      if (result.hasChanges) {
        await _refreshRemoteBackupInfo();
        _showSnack(
          '복원 완료: 사진 ${result.restoredPhotoCount}건, 일기 ${result.restoredDraftCount}건, 태그 ${result.restoredTagCount}건, 설정 ${result.restoredPrefCount}건',
        );
      } else {
        _showSnack('최신 데이터입니다.');
      }
    } catch (e) {
      _showSnack('복원 실패: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _deleteRemoteBackup() async {
    if (_isBusy) return;
    if (!_isLinked) {
      _showSnack('먼저 계정 연동을 완료해주세요.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('백업 데이터 삭제'),
        content: const Text('서버에 저장된 백업 데이터를 삭제할까요?\n삭제 후에는 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBusy = true);
    try {
      final deleted = await PetgramSupabaseSyncService.instance.deleteBackup();
      await _refreshRemoteBackupInfo();
      if (!mounted) return;
      if (deleted) {
        _showSnack('서버 백업 데이터가 삭제되었습니다.');
      } else {
        _showSnack('삭제할 서버 백업 데이터가 없습니다.');
      }
    } catch (e) {
      _showSnack('백업 데이터 삭제 실패: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showPolicySummaryDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('개인정보 동의 안내'),
        content: const SingleChildScrollView(
          child: Text(
            '아래 항목에 동의하면 계정 연동 및 백업 기능을 사용할 수 있습니다.\n\n'
            '1. 수집 항목: 소셜 로그인 식별값(이메일/UID), 백업 데이터(한줄 일기/태그/사진 메타데이터)\n'
            '2. 이용 목적: 계정 연동, 백업 저장/복원 제공\n'
            '3. 보관/삭제: 연동 해제 또는 삭제 요청 시 관련 데이터 삭제 처리\n'
            '4. 제3자/위탁: Supabase(해외 서버 포함 가능)를 통해 저장/처리\n'
            '5. 동의 거부 권리: 거부 시 연동/백업 기능 사용 제한',
            style: TextStyle(fontSize: 13, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasConfig = PetgramSupabaseSyncService.instance.hasEnvironmentConfig;
    final authLabel = PetgramSupabaseSyncService.instance.currentUserLabel;
    final canBackup = hasConfig && _isLinked && !_isBusy;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 0,
        title: const Text(
          '기록 백업하기',
          style: TextStyle(
            color: Color(0xFF7E4C5F),
            fontWeight: FontWeight.w800,
            fontSize: 19,
            letterSpacing: -0.1,
          ),
        ),
        actions: [
          if (_isLinked)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _isBusy ? null : _withdrawAccount,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF9A6A7B),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.person_remove_alt_1_rounded, size: 16),
                label: const Text(
                  '계정 탈퇴',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios,
            color: Colors.black87,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          children: [
            _buildSyncCard(
              hasConfig: hasConfig,
              authLabel: authLabel,
              canBackup: canBackup,
            ),
            const SizedBox(height: 12),
            _buildGuideCard(),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFFFCE4EC),
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.backup,
            onShotTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
            onDiaryTap: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const DiaryPage()),
              );
            },
            onBackupTap: () {},
          ),
        ),
      ),
    );
  }

  Widget _buildSyncCard({
    required bool hasConfig,
    required String authLabel,
    required bool canBackup,
  }) {
    final linkedColor = _isLinked
        ? const Color(0xFF2E7D32)
        : const Color(0xFF9A6A7B);
    final providerLabel =
        PetgramSupabaseSyncService.instance.currentProviderLabel;
    final hasRemoteBackup = _lastBackupInfo != null;
    final canRestoreOrDelete = canBackup && hasRemoteBackup;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFECD6DE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF5F8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFF6D9E3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '계정 연동',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (_isLinked)
                      SizedBox(
                        height: 28,
                        child: TextButton.icon(
                          onPressed: _isBusy ? null : _signOutSupabase,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.logout_rounded, size: 15),
                          label: const Text(
                            '연동 해제',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(
                      _isLinked
                          ? Icons.verified_user_rounded
                          : Icons.account_circle_outlined,
                      size: 16,
                      color: linkedColor,
                    ),
                    Text(
                      _isLinked ? '연동됨' : '미연동',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: linkedColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!_isLinked)
                      const Text(
                        'Google/Apple 계정으로 시작',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (_isLinked)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF0F5),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0xFFF2D4DF)),
                        ),
                        child: Text(
                          providerLabel,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF7E4C5F),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                if (_isLinked) ...[
                  const SizedBox(height: 6),
                  Text(
                    authLabel,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Colors.black87,
                      height: 1.35,
                    ),
                    softWrap: true,
                  ),
                ],
              ],
            ),
          ),
          if (!hasConfig) ...[
            const SizedBox(height: 8),
            Text(
              '앱 빌드에 Supabase 설정이 없습니다. 설정된 빌드가 필요합니다.',
              style: TextStyle(fontSize: 12, color: Colors.red.shade600),
            ),
          ],
          const SizedBox(height: 12),
          if (!_isLinked) ...[
            const Text(
              '백업을 사용하려면 먼저 계정을 연동해주세요.\n연동 시 회원가입/로그인이 함께 처리됩니다.',
              style: TextStyle(
                fontSize: 13,
                color: Colors.black54,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF5F8),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF2D4DF)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '동의 항목(필수)',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '[01 수집 항목] 소셜 로그인 식별값(이메일/UID), 백업 데이터',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  Text(
                    '[02 이용 목적] 계정 연동 및 백업/복원 제공',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  Text(
                    '[03 보관/삭제] 연동 해제 또는 삭제 요청 시 처리',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  Text(
                    '[04 제3자/위탁] Supabase(해외 서버 포함 가능)',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  Text(
                    '[05 거부 권리] 동의 거부 시 연동/백업 기능 제한',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _isBusy
                  ? null
                  : () => _setPolicyAccepted(!_policyAccepted),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _policyAccepted,
                      onChanged: _isBusy
                          ? null
                          : (v) => _setPolicyAccepted(v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    const SizedBox(width: 2),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text(
                          '개인정보 수집/이용(식별값, 백업 데이터 처리)에 동의합니다.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Colors.black87,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _showPolicySummaryDialog,
                child: const Text('자세히 보기'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _canLink(hasConfig) ? _signInWithGoogle : null,
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('Google로 시작하기'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _canLink(hasConfig) ? _signInWithApple : null,
                icon: const Icon(Icons.apple),
                label: const Text('Apple로 시작하기'),
              ),
            ),
          ],
          if (_isLinked) ...[
            const Text(
              '백업',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF5F8),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF2D4DF)),
              ),
              child: Text(
                _backupSummaryText(),
                style: const TextStyle(fontSize: 12.5, color: Colors.black87),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '자동 백업',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                '하루 1회(앱 첫 실행 시)\n새 데이터가 있을 때만 백업',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              isThreeLine: true,
              value: _autoBackupEnabled,
              onChanged: canBackup ? (v) => _setAutoBackupEnabled(v) : null,
              activeThumbColor: kMainPink,
              activeTrackColor: kMainPink.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canBackup ? _uploadBackupToSupabase : null,
                    icon: const Icon(Icons.cloud_upload_rounded),
                    label: const Text('지금 백업'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canRestoreOrDelete ? _restoreFromSupabase : null,
                    icon: const Icon(Icons.cloud_download_rounded),
                    label: const Text('백업 불러오기'),
                  ),
                ),
              ],
            ),
            if (hasRemoteBackup)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: canRestoreOrDelete ? _deleteRemoteBackup : null,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: Colors.red.shade600,
                  ),
                  label: Text(
                    '백업 데이터 삭제',
                    style: TextStyle(color: Colors.red.shade600),
                  ),
                ),
              ),
          ],
          if (_isBusy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 3),
          ],
        ],
      ),
    );
  }

  Widget _buildGuideCard() {
    const items = [
      '사진과 기록은 내 휴대폰에 저장돼요.',
      '휴대폰을 바꾸거나 앱을 다시 설치하면 [백업 불러오기]를 해야 이전 기록이 다시 연결돼요.',
      '백업을 안 했거나 불러오지 않으면, 한줄 일기에서 예전 사진이 자동 연결되지 않아요.',
    ];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFECD6DE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '안내',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          for (final item in items) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.check_circle_outline_rounded,
                    size: 16,
                    color: Color(0xFF9A6A7B),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Colors.black87,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
