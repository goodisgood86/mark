import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/constants.dart';
import 'one_line_diary_service.dart';
import 'petgram_backup_service.dart';

class SupabaseSyncConfig {
  final String url;
  final String anonKey;

  const SupabaseSyncConfig({required this.url, required this.anonKey});

  String get normalizedUrl => url.trim();
  String get normalizedAnonKey => anonKey.trim();

  bool get isValid =>
      normalizedUrl.startsWith('https://') && normalizedAnonKey.isNotEmpty;

  void validate() {
    if (!normalizedUrl.startsWith('https://')) {
      throw StateError('Supabase URL은 https:// 로 시작해야 합니다.');
    }
    if (normalizedAnonKey.isEmpty) {
      throw StateError('Supabase anon key를 입력해주세요.');
    }
  }
}

class BackupSnapshotInfo {
  final DateTime? updatedAtUtc;
  final int photoCount;
  final int diaryEntryCount;
  final int tagCount;

  const BackupSnapshotInfo({
    required this.updatedAtUtc,
    required this.photoCount,
    required this.diaryEntryCount,
    required this.tagCount,
  });
}

class BackupUploadResult {
  final bool uploaded;
  final bool fullBackup;

  const BackupUploadResult({
    required this.uploaded,
    required this.fullBackup,
  });
}

class AccountWithdrawalResult {
  final bool backupDeleted;
  final bool authDeleted;

  const AccountWithdrawalResult({
    required this.backupDeleted,
    required this.authDeleted,
  });
}

class PetgramSupabaseSyncService {
  PetgramSupabaseSyncService._internal();

  static final PetgramSupabaseSyncService instance =
      PetgramSupabaseSyncService._internal();

  bool _initialized = false;
  SupabaseSyncConfig? _activeConfig;
  String? _backupPayloadColumnCache;
  String? _backupTimestampColumnCache;
  String? _providerHint;
  static const String _oauthRedirectUri = 'com.mark.petgram://login-callback';
  static const String _compressedPayloadPrefix = 'gzb64:';
  static const List<String> _backupPayloadCandidates = [
    'backup_json',
    'backup_data',
    'payload',
    'data',
  ];
  static const List<String> _backupTimestampCandidates = [
    'updated_at',
    'created_at',
  ];
  static const String _googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '16969023366-1piia77uea16fjmu4pcjmj70vf55uca5.apps.googleusercontent.com',
  );
  static const String _googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue:
        '16969023366-ofg77gdr385rg9rk8jdu1t65a94ikqmd.apps.googleusercontent.com',
  );
  static const String _envUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://xkljrppbpneplvjejlwt.supabase.co',
  );
  static const String _envAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhrbGpycHBicG5lcGx2amVqbHd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExNjQzNzIsImV4cCI6MjA4Njc0MDM3Mn0.moxhRAfyM6GsAgABxJszqJ6UClB3yN3jgxKKVi2iBkk',
  );

  bool get hasEnvironmentConfig =>
      _envUrl.trim().isNotEmpty && _envAnonKey.trim().isNotEmpty;

  SupabaseSyncConfig? get environmentConfig {
    if (!hasEnvironmentConfig) return null;
    return const SupabaseSyncConfig(url: _envUrl, anonKey: _envAnonKey);
  }

  Future<void> ensureInitialized() async {
    final config = environmentConfig;
    if (config == null) {
      throw StateError(
        'SUPABASE_URL / SUPABASE_ANON_KEY가 설정되지 않았습니다.\n'
        '--dart-define로 값을 넣어 실행해주세요.',
      );
    }
    config.validate();

    if (_initialized) {
      final active = _activeConfig;
      if (active != null &&
          active.normalizedUrl == config.normalizedUrl &&
          active.normalizedAnonKey == config.normalizedAnonKey) {
        return;
      }
      throw StateError('앱 실행 중 Supabase 설정을 바꾸려면 앱을 재시작해주세요.');
    }

    await Supabase.initialize(
      url: config.normalizedUrl,
      anonKey: config.normalizedAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    _providerHint = prefs.getString(kLastAuthProviderKey);
    _initialized = true;
    _activeConfig = config;
  }

  Future<void> ensureInitializedFromEnvironment() async {
    if (!hasEnvironmentConfig) return;
    await ensureInitialized();
  }

  SupabaseClient get _client {
    if (!_initialized) {
      throw StateError('Supabase가 초기화되지 않았습니다.');
    }
    return Supabase.instance.client;
  }

  User? get currentUser => _initialized ? _client.auth.currentUser : null;

  String get currentUserLabel {
    final user = currentUser;
    if (user == null) return '미인증';
    final email = user.email?.trim();
    if (email != null && email.isNotEmpty) return email;
    return user.id;
  }

  String get currentProviderLabel {
    final user = currentUser;
    if (user == null) return '-';
    final hint = _providerHint?.trim();
    if (hint != null && hint.isNotEmpty) {
      return _normalizeProviderLabel(hint);
    }

    final appMetadata = user.appMetadata;
    final rawProvider = appMetadata['provider'];
    if (rawProvider is String && rawProvider.trim().isNotEmpty) {
      return _normalizeProviderLabel(rawProvider);
    }

    final rawProviders = appMetadata['providers'];
    if (rawProviders is List) {
      for (final item in rawProviders) {
        if (item is String && item.trim().isNotEmpty) {
          return _normalizeProviderLabel(item);
        }
      }
    }

    return '알 수 없음';
  }

  String _normalizeProviderLabel(String raw) {
    final value = raw.trim().toLowerCase();
    if (value == 'google') return 'Google';
    if (value == 'apple') return 'Apple';
    if (value == 'email') return 'Email';
    return raw;
  }

  Future<void> signInWithGoogle() async {
    await ensureInitialized();
    if (Platform.isIOS || Platform.isAndroid) {
      await _signInWithGoogleNative();
      await _saveProviderHint('google');
      return;
    }
    await _signInWithGoogleOAuthFallback();
    await _saveProviderHint('google');
  }

  Future<void> signInWithApple() async {
    await ensureInitialized();
    if (Platform.isIOS || Platform.isMacOS) {
      await _signInWithAppleNative();
      await _saveProviderHint('apple');
      return;
    }
    await _signInWithAppleOAuthFallback();
    await _saveProviderHint('apple');
  }

  Future<void> _signInWithGoogleNative() async {
    // 별도 설정이 없으면 자동으로 OAuth 방식으로 폴백한다.
    // (앱이 크래시하지 않고 로그인 동작을 유지하기 위함)
    if (_googleWebClientId.trim().isEmpty ||
        (Platform.isIOS && _googleIosClientId.trim().isEmpty)) {
      await _signInWithGoogleOAuthFallback();
      return;
    }

    final googleSignIn = GoogleSignIn(
      scopes: const ['email', 'profile', 'openid'],
      serverClientId: _googleWebClientId,
      clientId: Platform.isIOS ? _googleIosClientId : null,
    );

    final account = await googleSignIn.signIn();
    if (account == null) {
      throw StateError('Google 로그인이 취소되었습니다.');
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.trim().isEmpty) {
      throw StateError(
        'Google ID Token을 가져오지 못했습니다. '
        'Google OAuth Web Client ID 설정을 확인해주세요.',
      );
    }
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: auth.accessToken,
    );
  }

  Future<void> _signInWithAppleNative() async {
    final rawNonce = _client.auth.generateRawNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );

    final idToken = credential.identityToken;
    if (idToken == null || idToken.trim().isEmpty) {
      throw const AuthException('Apple ID Token을 가져오지 못했습니다.');
    }
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );
  }

  Future<void> _signInWithGoogleOAuthFallback() async {
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: _oauthRedirectUri,
      scopes: 'openid email profile',
      queryParams: const {'prompt': 'select_account'},
    );
    if (launched == false) {
      throw StateError('Google 로그인 화면을 열지 못했습니다.');
    }
  }

  Future<void> _signInWithAppleOAuthFallback() async {
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.apple,
      redirectTo: _oauthRedirectUri,
      scopes: 'name email',
    );
    if (launched == false) {
      throw StateError('Apple 로그인 화면을 열지 못했습니다.');
    }
  }

  Future<void> signOut() async {
    await ensureInitialized();
    await _client.auth.signOut();
    await _clearProviderHint();
  }

  Future<AccountWithdrawalResult> withdrawAccount() async {
    await ensureInitialized();
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('먼저 로그인해주세요.');
    }

    final result = await _deleteMyAccountByEdgeFunction();

    // Auth 레코드 삭제 후 세션이 만료될 수 있어 signOut 실패는 무시하고 로컬 상태만 정리한다.
    try {
      await _client.auth.signOut();
    } catch (_) {}
    await _clearProviderHint();

    return result;
  }

  Future<AccountWithdrawalResult> _deleteMyAccountByEdgeFunction({
    bool allowRetry = true,
  }) async {
    try {
      final initialToken = _client.auth.currentSession?.accessToken;
      final response = await _invokeDeleteAccount(
        accessToken: initialToken,
      );
      final raw = response.data;
      if (raw is Map<String, dynamic>) {
        final map = raw;
        return AccountWithdrawalResult(
          backupDeleted: map['backup_deleted'] == true,
          authDeleted: map['ok'] == true || map['auth_deleted'] == true,
        );
      }
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        final backupDeleted = map['backup_deleted'] == true;
        return AccountWithdrawalResult(
          backupDeleted: backupDeleted,
          authDeleted: map['ok'] == true || map['auth_deleted'] == true,
        );
      }
      throw StateError('탈퇴 응답 형식이 올바르지 않습니다.');
    } catch (e) {
      final msg = e.toString();
      final lower = msg.toLowerCase();
      final unauthorized =
          lower.contains('status: 401') ||
          lower.contains('unauthorized') ||
          lower.contains('invalid jwt') ||
          lower.contains('invalid_session');
      if (unauthorized) {
        // Edge Function 게이트웨이 JWT 검증에서 막히는 케이스를 위해
        // PostgREST RPC 경로로 한 번 폴백 시도한다.
        try {
          return await _deleteMyAccountByRpcFallback();
        } catch (_) {}
        if (allowRetry) {
          try {
            final refreshed = await _client.auth.refreshSession();
            final retryToken = refreshed.session?.accessToken;
            if (retryToken != null && retryToken.trim().isNotEmpty) {
              final retryResponse = await _invokeDeleteAccount(
                accessToken: retryToken,
              );
              final retryRaw = retryResponse.data;
              if (retryRaw is Map<String, dynamic>) {
                return AccountWithdrawalResult(
                  backupDeleted: retryRaw['backup_deleted'] == true,
                  authDeleted:
                      retryRaw['ok'] == true || retryRaw['auth_deleted'] == true,
                );
              }
            }
          } catch (_) {}
        }
        throw StateError(
          '로그인 세션이 만료되었거나 유효하지 않습니다. 다시 로그인 후 시도해주세요. [$msg]',
        );
      }
      final backupDeleteFailed = lower.contains('backup_delete_failed');
      if (backupDeleteFailed) {
        throw StateError('서버 백업 데이터 삭제에 실패했습니다. 잠시 후 다시 시도해주세요.');
      }
      final authDeleteFailed = lower.contains('auth_delete_failed');
      if (authDeleteFailed) {
        throw StateError('계정 삭제에 실패했습니다. 잠시 후 다시 시도해주세요.');
      }
      final missingFn =
          lower.contains('delete-account') &&
          (lower.contains('404') ||
              lower.contains('not found') ||
              lower.contains('no route matched'));
      if (missingFn) {
        throw StateError(
          '서버에 회원탈퇴 Edge Function(delete-account)이 없습니다. '
          'Supabase Functions에 배포 후 다시 시도해주세요.',
        );
      }
      throw StateError('계정 삭제 처리에 실패했습니다: $msg');
    }
  }

  Future<AccountWithdrawalResult> _deleteMyAccountByRpcFallback() async {
    try {
      final dynamic raw = await _client.rpc<dynamic>('delete_my_account');
      if (raw is Map<String, dynamic>) {
        return AccountWithdrawalResult(
          backupDeleted: raw['backup_deleted'] == true,
          authDeleted: raw['ok'] == true || raw['auth_deleted'] == true,
        );
      }
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        return AccountWithdrawalResult(
          backupDeleted: map['backup_deleted'] == true,
          authDeleted: map['ok'] == true || map['auth_deleted'] == true,
        );
      }
      throw StateError('RPC 탈퇴 응답 형식이 올바르지 않습니다.');
    } catch (e) {
      throw StateError('RPC 탈퇴 처리 실패: $e');
    }
  }

  Future<FunctionResponse> _invokeDeleteAccount({
    String? accessToken,
  }) {
    final token = accessToken?.trim();
    return _client.functions.invoke(
      'delete-account',
      body: (token != null && token.isNotEmpty)
          ? <String, dynamic>{'access_token': token}
          : null,
    );
  }

  Future<void> _saveProviderHint(String provider) async {
    _providerHint = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLastAuthProviderKey, provider);
  }

  Future<void> _clearProviderHint() async {
    _providerHint = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kLastAuthProviderKey);
  }

  Future<BackupUploadResult> uploadBackup({
    bool syncMissingLocalMedia = true,
  }) async {
    await ensureInitialized();
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('먼저 로그인해주세요.');
    }
    if (syncMissingLocalMedia) {
      // 수동 백업 직전, 기기에서 이미 삭제된 사진/일기 레코드를 선정리해
      // "최신데이터" 오탐을 줄이고 삭제 반영 정확도를 높인다.
      await OneLineDiaryService.instance.pruneMissingRecordsForBackup();
    }

    final payloadColumn = await _resolveBackupPayloadColumn(user.id);
    final currentRemotePayload = await _fetchRemotePayload(
      userId: user.id,
      payloadColumn: payloadColumn,
    );

    Map<String, dynamic> payload;
    var isFullBackup = false;
    if (currentRemotePayload == null) {
      payload = await PetgramBackupService.instance.createBackupPayload();
      isFullBackup = true;
    } else {
      final sync = _readSyncState(currentRemotePayload);
      final delta = await PetgramBackupService.instance.createDeltaPayload(
        photoUpdatedAfterMs: sync.photoMaxUpdatedAt,
        diaryUpdatedAfterMs: sync.diaryMaxUpdatedAt,
        tagCreatedAfterMs: sync.tagMaxCreatedAt,
      );
      final keySnapshot = await PetgramBackupService.instance.createKeySnapshot();
      final deletedPhotoPaths = _findDeletedPhotoPaths(
        base: currentRemotePayload,
        localPhotoPaths: keySnapshot.photoPaths,
      );
      final deletedDiaryEntryIds = _findDeletedDiaryEntryIds(
        base: currentRemotePayload,
        localEntryIds: keySnapshot.diaryEntryIds,
      );
      final deletedDiaryTagKeys = _findDeletedDiaryTagKeys(
        base: currentRemotePayload,
        localTagKeys: keySnapshot.diaryTagKeys,
      );
      final hasDeltaChanges =
          (delta['photos'] is List && (delta['photos'] as List).isNotEmpty) ||
          (delta['diary_entries'] is List &&
              (delta['diary_entries'] as List).isNotEmpty) ||
          (delta['diary_tags'] is List &&
              (delta['diary_tags'] as List).isNotEmpty);
      final hasDeletedChanges =
          deletedPhotoPaths.isNotEmpty ||
          deletedDiaryEntryIds.isNotEmpty ||
          deletedDiaryTagKeys.isNotEmpty;
      if (!hasDeltaChanges && !hasDeletedChanges) {
        return const BackupUploadResult(uploaded: false, fullBackup: false);
      }
      payload = _mergePayloadWithDelta(
        base: currentRemotePayload,
        delta: delta,
        deletedPhotoPaths: deletedPhotoPaths,
        deletedDiaryEntryIds: deletedDiaryEntryIds,
        deletedDiaryTagKeys: deletedDiaryTagKeys,
      );
    }

    final timestampColumn = await _resolveBackupTimestampColumn(user.id);
    final payloadCandidates = {
      if (_backupPayloadColumnCache != null) _backupPayloadColumnCache!,
      ..._backupPayloadCandidates,
    }.toList(growable: false);

    PostgrestException? lastMissingColumnError;
    final encodedPayload = _encodePayload(payload);
    for (final payloadColumn in payloadCandidates) {
      final row = <String, dynamic>{
        'user_id': user.id,
        payloadColumn: encodedPayload,
      };
      if (timestampColumn != null) {
        row[timestampColumn] = DateTime.now().toUtc().toIso8601String();
      }
      try {
        await _client.from('user_backups').upsert(row, onConflict: 'user_id');
        _backupPayloadColumnCache = payloadColumn;
        return BackupUploadResult(
          uploaded: true,
          fullBackup: isFullBackup,
        );
      } on PostgrestException catch (e) {
        if (_isMissingColumnError(e, payloadColumn)) {
          lastMissingColumnError = e;
          continue;
        }
        rethrow;
      }
    }

    if (lastMissingColumnError != null) {
      throw StateError(
        'user_backups 테이블에서 백업 데이터 컬럼을 찾지 못했습니다. '
        '(지원 컬럼: ${_backupPayloadCandidates.join(', ')})',
      );
    }
    throw StateError('백업 업로드 처리 중 알 수 없는 오류가 발생했습니다.');
  }

  _BackupSyncState _readSyncState(Map<String, dynamic> payload) {
    final syncRaw = payload['_sync'];
    final syncMap = syncRaw is Map<String, dynamic>
        ? syncRaw
        : <String, dynamic>{};

    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return _BackupSyncState(
      photoMaxUpdatedAt: asInt(syncMap['photo_max_updated_at']),
      diaryMaxUpdatedAt: asInt(syncMap['diary_max_updated_at']),
      tagMaxCreatedAt: asInt(syncMap['tag_max_created_at']),
    );
  }

  Future<Map<String, dynamic>?> _fetchRemotePayload({
    required String userId,
    required String payloadColumn,
  }) async {
    final data = await _client
        .from('user_backups')
        .select(payloadColumn)
        .eq('user_id', userId)
        .maybeSingle();
    if (data == null) return null;
    return _decodePayload(data[payloadColumn]);
  }

  Map<String, dynamic> _mergePayloadWithDelta({
    required Map<String, dynamic> base,
    required Map<String, dynamic> delta,
    Set<String> deletedPhotoPaths = const <String>{},
    Set<String> deletedDiaryEntryIds = const <String>{},
    Set<String> deletedDiaryTagKeys = const <String>{},
  }) {
    final merged = Map<String, dynamic>.from(base);

    List<Map<String, dynamic>> readMapList(dynamic raw) {
      if (raw is! List) return const <Map<String, dynamic>>[];
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
          .toList(growable: false);
    }

    void mergeByKey({
      required String field,
      required String key,
      Set<String> deletedKeys = const <String>{},
    }) {
      final baseList = readMapList(base[field]);
      final deltaList = readMapList(delta[field]);
      if (deltaList.isEmpty) {
        if (deletedKeys.isEmpty) {
          merged[field] = baseList;
          return;
        }
        merged[field] = baseList.where((row) {
          final id = row[key]?.toString();
          if (id == null || id.isEmpty) return false;
          return !deletedKeys.contains(id);
        }).toList(growable: false);
        return;
      }
      final byKey = <String, Map<String, dynamic>>{};
      for (final row in baseList) {
        final id = row[key]?.toString();
        if (id == null || id.isEmpty) continue;
        if (deletedKeys.contains(id)) continue;
        byKey[id] = row;
      }
      for (final row in deltaList) {
        final id = row[key]?.toString();
        if (id == null || id.isEmpty) continue;
        byKey[id] = row;
      }
      merged[field] = byKey.values.toList(growable: false);
    }

    mergeByKey(
      field: 'photos',
      key: 'file_path',
      deletedKeys: deletedPhotoPaths,
    );
    mergeByKey(
      field: 'diary_entries',
      key: 'entry_id',
      deletedKeys: deletedDiaryEntryIds,
    );

    final baseTags = readMapList(base['diary_tags']);
    final deltaTags = readMapList(delta['diary_tags']);
    if (deltaTags.isEmpty) {
      merged['diary_tags'] = baseTags.where((row) {
        final entryId = row['entry_id']?.toString() ?? '';
        final tag = row['tag']?.toString() ?? '';
        if (entryId.isEmpty || tag.isEmpty) return false;
        if (deletedDiaryEntryIds.contains(entryId)) return false;
        final key = '$entryId::$tag';
        return !deletedDiaryTagKeys.contains(key);
      }).toList(growable: false);
    } else {
      final tagMap = <String, Map<String, dynamic>>{};
      String tagKey(Map<String, dynamic> row) {
        final entryId = row['entry_id']?.toString() ?? '';
        final tag = row['tag']?.toString() ?? '';
        return '$entryId::$tag';
      }

      for (final row in baseTags) {
        final id = tagKey(row);
        if (id == '::') continue;
        final entryId = row['entry_id']?.toString() ?? '';
        if (deletedDiaryEntryIds.contains(entryId)) continue;
        if (deletedDiaryTagKeys.contains(id)) continue;
        tagMap[id] = row;
      }
      for (final row in deltaTags) {
        final entryId = row['entry_id']?.toString() ?? '';
        if (deletedDiaryEntryIds.contains(entryId)) continue;
        final id = tagKey(row);
        if (id == '::') continue;
        if (deletedDiaryTagKeys.contains(id)) continue;
        tagMap[id] = row;
      }
      merged['diary_tags'] = tagMap.values.toList(growable: false);
    }

    final basePrefs = base['prefs'];
    final deltaPrefs = delta['prefs'];
    final mergedPrefs = <String, dynamic>{
      if (basePrefs is Map<String, dynamic>) ...basePrefs,
      if (deltaPrefs is Map<String, dynamic>) ...deltaPrefs,
    };
    merged['prefs'] = mergedPrefs;
    merged['created_at'] = DateTime.now().toUtc().toIso8601String();
    merged['backup_version'] = delta['backup_version'] ?? base['backup_version'];
    merged['app'] = delta['app'] ?? base['app'] ?? 'petgram';
    merged['_sync'] = delta['_sync'] ?? base['_sync'];
    return merged;
  }

  Set<String> _findDeletedPhotoPaths({
    required Map<String, dynamic> base,
    required Set<String> localPhotoPaths,
  }) {
    final deleted = <String>{};
    final raw = base['photos'];
    if (raw is! List) return deleted;
    for (final item in raw) {
      if (item is! Map) continue;
      final key = item['file_path']?.toString().trim();
      if (key == null || key.isEmpty) continue;
      if (!localPhotoPaths.contains(key)) {
        deleted.add(key);
      }
    }
    return deleted;
  }

  Set<String> _findDeletedDiaryEntryIds({
    required Map<String, dynamic> base,
    required Set<String> localEntryIds,
  }) {
    final deleted = <String>{};
    final raw = base['diary_entries'];
    if (raw is! List) return deleted;
    for (final item in raw) {
      if (item is! Map) continue;
      final key = item['entry_id']?.toString().trim();
      if (key == null || key.isEmpty) continue;
      if (!localEntryIds.contains(key)) {
        deleted.add(key);
      }
    }
    return deleted;
  }

  Set<String> _findDeletedDiaryTagKeys({
    required Map<String, dynamic> base,
    required Set<String> localTagKeys,
  }) {
    final deleted = <String>{};
    final raw = base['diary_tags'];
    if (raw is! List) return deleted;
    for (final item in raw) {
      if (item is! Map) continue;
      final entryId = item['entry_id']?.toString().trim() ?? '';
      final tag = item['tag']?.toString().trim() ?? '';
      if (entryId.isEmpty || tag.isEmpty) continue;
      final key = '$entryId::$tag';
      if (!localTagKeys.contains(key)) {
        deleted.add(key);
      }
    }
    return deleted;
  }

  Future<bool> deleteBackup() async {
    await ensureInitialized();
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('먼저 로그인해주세요.');
    }

    final deleted = await _client
        .from('user_backups')
        .delete()
        .eq('user_id', user.id)
        .select('user_id');

    final deletedCount = deleted.length;

    final remains = await _client
        .from('user_backups')
        .select('user_id')
        .eq('user_id', user.id)
        .limit(1);

    if (deletedCount == 0 && remains.isNotEmpty) {
      throw StateError(
        '서버에서 삭제 권한이 없어 백업을 지우지 못했습니다. '
        'Supabase user_backups DELETE RLS 정책을 확인해주세요.',
      );
    }

    if (remains.isNotEmpty) {
      throw StateError('서버 백업 삭제 확인에 실패했습니다. 잠시 후 다시 시도해주세요.');
    }

    return deletedCount > 0;
  }

  Future<BackupSnapshotInfo?> fetchRemoteBackupInfo() async {
    await ensureInitialized();
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final payloadColumn = await _resolveBackupPayloadColumn(user.id);
    final timestampColumn = await _resolveBackupTimestampColumn(user.id);
    final selectColumns = timestampColumn == null
        ? payloadColumn
        : '$payloadColumn, $timestampColumn';

    final data = await _client
        .from('user_backups')
        .select(selectColumns)
        .eq('user_id', user.id)
        .maybeSingle();
    if (data == null) return null;

    DateTime? updatedAtUtc;
    final rawUpdatedAt = timestampColumn == null ? null : data[timestampColumn];
    if (rawUpdatedAt is String && rawUpdatedAt.trim().isNotEmpty) {
      updatedAtUtc = DateTime.tryParse(rawUpdatedAt)?.toUtc();
    }

    int photoCount = 0;
    int diaryEntryCount = 0;
    int tagCount = 0;
    final payload = _decodePayload(data[payloadColumn]);

    if (payload != null) {
      final photos = payload['photos'];
      final entries = payload['diary_entries'];
      final tags = payload['diary_tags'];
      final legacyDrafts = payload['drafts'];
      if (photos is List) photoCount = photos.length;
      if (entries is List) {
        diaryEntryCount = entries.length;
      } else if (legacyDrafts is Map) {
        diaryEntryCount = legacyDrafts.length;
      }
      if (tags is List) tagCount = tags.length;
    }

    return BackupSnapshotInfo(
      updatedAtUtc: updatedAtUtc,
      photoCount: photoCount,
      diaryEntryCount: diaryEntryCount,
      tagCount: tagCount,
    );
  }

  Future<PetgramBackupRestoreResult> restoreBackup() async {
    await ensureInitialized();
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('먼저 로그인해주세요.');
    }

    final payloadColumn = await _resolveBackupPayloadColumn(user.id);
    final data = await _client
        .from('user_backups')
        .select(payloadColumn)
        .eq('user_id', user.id)
        .maybeSingle();

    if (data == null) {
      throw StateError('서버에 백업 데이터가 없습니다.');
    }

    final payload = _decodePayload(data[payloadColumn]);
    if (payload == null) {
      throw StateError('서버 백업 형식이 올바르지 않습니다.');
    }

    return PetgramBackupService.instance.restoreFromPayloadMap(payload);
  }

  String _encodePayload(Map<String, dynamic> payload) {
    final json = jsonEncode(payload);
    final compressed = gzip.encode(utf8.encode(json));
    final b64 = base64Encode(compressed);
    return '$_compressedPayloadPrefix$b64';
  }

  Map<String, dynamic>? _decodePayload(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      if (text.startsWith(_compressedPayloadPrefix)) {
        final b64 = text.substring(_compressedPayloadPrefix.length);
        final bytes = base64Decode(b64);
        final decoded = utf8.decode(gzip.decode(bytes));
        final parsed = jsonDecode(decoded);
        return parsed is Map<String, dynamic> ? parsed : null;
      }
      final parsed = jsonDecode(text);
      return parsed is Map<String, dynamic> ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveBackupPayloadColumn(String userId) async {
    final cached = _backupPayloadColumnCache;
    if (cached != null) return cached;

    for (final column in _backupPayloadCandidates) {
      if (await _columnExistsForUser(userId, column)) {
        _backupPayloadColumnCache = column;
        return column;
      }
    }
    throw StateError(
      'user_backups 테이블에서 백업 데이터 컬럼을 찾지 못했습니다. '
      '(필요 컬럼 예: backup_json)',
    );
  }

  Future<String?> _resolveBackupTimestampColumn(String userId) async {
    final cached = _backupTimestampColumnCache;
    if (cached != null) return cached;

    for (final column in _backupTimestampCandidates) {
      if (await _columnExistsForUser(userId, column)) {
        _backupTimestampColumnCache = column;
        return column;
      }
    }
    return null;
  }

  Future<bool> _columnExistsForUser(String userId, String column) async {
    try {
      await _client
          .from('user_backups')
          .select(column)
          .eq('user_id', userId)
          .limit(1);
      return true;
    } on PostgrestException catch (e) {
      if (_isMissingColumnError(e, column)) {
        return false;
      }
      rethrow;
    }
  }

  bool _isMissingColumnError(PostgrestException e, String column) {
    final message = e.message.toLowerCase();
    final code = (e.code ?? '').toUpperCase();
    final lowerColumn = column.toLowerCase();
    final hasColumnHint =
        message.contains(lowerColumn) || message.contains("'$lowerColumn'");
    final missingText =
        message.contains('does not exist') || message.contains('could not find');
    if (hasColumnHint && missingText) return true;
    if (code == '42703' && hasColumnHint) return true;
    return false;
  }
}

class _BackupSyncState {
  final int photoMaxUpdatedAt;
  final int diaryMaxUpdatedAt;
  final int tagMaxCreatedAt;

  const _BackupSyncState({
    required this.photoMaxUpdatedAt,
    required this.diaryMaxUpdatedAt,
    required this.tagMaxCreatedAt,
  });
}
