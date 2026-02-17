import 'dart:async';

import 'package:photo_manager/photo_manager.dart';

/// DB의 file_path를 단일 규격으로 저장하기 위한 참조 문자열 서비스
///
/// 규격:
/// - 갤러리 자산: `asset:<assetId>|<fileName>`
/// - 로컬 파일: `file:<absolutePath>`
/// - 파일명 fallback: `name:<fileName>`
class PetgramMediaRefService {
  PetgramMediaRefService._internal();

  static final PetgramMediaRefService instance =
      PetgramMediaRefService._internal();
  final Map<String, String> _assetIdByName = <String, String>{};
  DateTime? _indexBuiltAt;
  Future<void>? _indexBuildFuture;
  static const Duration _indexTtl = Duration(minutes: 10);
  final Map<String, Future<AssetEntity?>> _diaryResolveCache =
      <String, Future<AssetEntity?>>{};
  List<AssetEntity>? _recentAssetCache;
  DateTime? _recentAssetCacheAt;
  Future<List<AssetEntity>>? _recentAssetLoadFuture;
  static const Duration _recentAssetCacheTtl = Duration(minutes: 2);

  Future<String> buildDbFileRef({
    required String savedPathOrName,
    required bool isGallerySave,
  }) async {
    final trimmed = savedPathOrName.trim();
    if (trimmed.isEmpty) return 'name:unknown';

    if (!isGallerySave) {
      return 'file:$trimmed';
    }

    final fileName = trimmed.contains('/') ? trimmed.split('/').last : trimmed;
    final assetId = await _findAssetIdByFileName(fileName);
    if (assetId != null && assetId.isNotEmpty) {
      return 'asset:$assetId|$fileName';
    }
    return 'name:$fileName';
  }

  Future<String> buildDbFileRefWithTakenAt({
    required String savedPathOrName,
    required bool isGallerySave,
    required DateTime takenAt,
  }) async {
    final primary = await buildDbFileRef(
      savedPathOrName: savedPathOrName,
      isGallerySave: isGallerySave,
    );
    if (!isGallerySave || !primary.startsWith('name:')) {
      return primary;
    }

    final fileName = _extractFileNameFromRef(primary) ?? '';
    final byRecent = await _resolveRecentAssetRefByTakenAt(
      fileName: fileName,
      takenAt: takenAt,
    );
    return byRecent ?? primary;
  }

  /// 구버전 file_path를 표준 ref로 정규화
  String normalizeDbFileRef(String filePath) {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) return 'name:unknown';
    if (trimmed.startsWith('asset:') ||
        trimmed.startsWith('file:') ||
        trimmed.startsWith('name:')) {
      return trimmed;
    }
    if (trimmed.contains('/')) {
      return 'file:$trimmed';
    }
    return 'name:$trimmed';
  }

  /// `name:<fileName>` 또는 `fileName`에서 asset 참조를 찾음
  Future<String?> resolveNameToAssetRef(String nameOrRef) async {
    final fileName = _extractFileNameFromNameRef(nameOrRef);
    if (fileName == null || fileName.isEmpty) return null;
    final assetId = await _findAssetIdByFileName(fileName);
    if (assetId == null || assetId.isEmpty) return null;
    return 'asset:$assetId|$fileName';
  }

  Future<AssetEntity?> resolveAssetEntityForDiary({
    required String fileRef,
    DateTime? takenAt,
  }) {
    final normalized = normalizeDbFileRef(fileRef);
    final key = '$normalized|${takenAt?.millisecondsSinceEpoch ?? 0}';
    final future = _diaryResolveCache.putIfAbsent(key, () async {
      final assetId = _extractAssetId(normalized);
      if (assetId != null && assetId.isNotEmpty) {
        final entity = await AssetEntity.fromId(assetId);
        if (entity != null) return entity;
      }

      final fileName = _extractFileNameFromRef(normalized);
      final assets = await _loadRecentAssets();
      if (assets.isEmpty) return null;

      if (fileName != null && fileName.isNotEmpty) {
        final byName = _matchAssetByFileName(assets, fileName);
        if (byName != null) return byName;
      }

      final pgTs = fileName == null ? null : _extractPgUnixSeconds(fileName);
      final targetTs =
          pgTs ?? ((takenAt?.toUtc().millisecondsSinceEpoch ?? 0) ~/ 1000);
      if (targetTs > 0) {
        final byTs = _matchAssetByTimestamp(
          assets,
          targetTs,
          toleranceSec: 600,
        );
        if (byTs != null) return byTs;
      }

      // 캐시 미스 시 1회 강제 새로고침 후 재탐색 (새 촬영 직후 대응)
      final refreshedAssets = await _loadRecentAssets(forceRefresh: true);
      if (refreshedAssets.isEmpty) return null;
      if (fileName != null && fileName.isNotEmpty) {
        final byName = _matchAssetByFileName(refreshedAssets, fileName);
        if (byName != null) return byName;
      }
      if (targetTs > 0) {
        return _matchAssetByTimestamp(
          refreshedAssets,
          targetTs,
          toleranceSec: 600,
        );
      }

      return null;
    });
    return future.then((entity) {
      // null 결과는 고착시키지 않아 다음 진입/새로고침 때 재시도 가능하게 한다.
      if (entity == null) {
        _diaryResolveCache.remove(key);
      }
      return entity;
    });
  }

  /// 삭제/정합성 검증 전용.
  /// `fileName` 정확 매칭만 허용하고 timestamp 근사 매칭은 사용하지 않는다.
  Future<AssetEntity?> resolveAssetEntityByExactNameForDiary({
    required String fileRef,
  }) async {
    final normalized = normalizeDbFileRef(fileRef);
    final assetId = _extractAssetId(normalized);
    if (assetId != null && assetId.isNotEmpty) {
      final entity = await AssetEntity.fromId(assetId);
      if (entity != null) return entity;
    }

    final fileName = _extractFileNameFromRef(normalized);
    if (fileName == null || fileName.isEmpty) return null;

    final assets = await _loadRecentAssets();
    final byName = _matchAssetByFileName(assets, fileName);
    if (byName != null) return byName;

    final refreshed = await _loadRecentAssets(forceRefresh: true);
    return _matchAssetByFileName(refreshed, fileName);
  }

  String? _extractFileNameFromNameRef(String nameOrRef) {
    final trimmed = nameOrRef.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('name:')) {
      return trimmed.substring(5);
    }
    if (trimmed.startsWith('asset:') || trimmed.startsWith('file:')) {
      return null;
    }
    return trimmed;
  }

  String? _extractAssetId(String ref) {
    if (!ref.startsWith('asset:')) return null;
    final payload = ref.substring(6);
    final idx = payload.indexOf('|');
    if (idx < 0) return payload;
    return payload.substring(0, idx);
  }

  String? _extractFileNameFromRef(String ref) {
    if (ref.startsWith('asset:')) {
      final payload = ref.substring(6);
      final idx = payload.indexOf('|');
      if (idx >= 0 && idx + 1 < payload.length) {
        final name = payload.substring(idx + 1).trim();
        return name.isEmpty ? null : name;
      }
      return null;
    }
    if (ref.startsWith('name:')) {
      final name = ref.substring(5).trim();
      return name.isEmpty ? null : name;
    }
    if (ref.startsWith('file:')) {
      final path = ref.substring(5).trim();
      if (path.isEmpty) return null;
      final parts = path.split('/');
      return parts.isEmpty ? null : parts.last;
    }
    if (ref.contains('/')) return ref.split('/').last.trim();
    return ref.trim().isEmpty ? null : ref.trim();
  }

  Future<String?> _findAssetIdByFileName(String fileName) async {
    final lookupExact = _normalizeName(fileName);
    final lookupBase = _baseName(lookupExact);
    if (_assetIdByName[lookupExact] case final id?) return id;
    if (_assetIdByName[lookupBase] case final id?) return id;

    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) return null;

    final quick = await _findInRecentAssets(lookupExact: lookupExact);
    if (quick != null && quick.isNotEmpty) {
      _assetIdByName[lookupExact] = quick;
      _assetIdByName[lookupBase] = quick;
      return quick;
    }

    await _ensureAssetIndex();
    if (_assetIdByName[lookupExact] case final id?) return id;
    if (_assetIdByName[lookupBase] case final id?) return id;

    // PG_<unix-seconds>.jpg 패턴은 파일명이 바뀐 경우가 많아
    // 촬영 시각 기반으로 최근 자산에서 근접 매칭한다.
    final pgTs = _extractPgUnixSeconds(fileName);
    if (pgTs != null) {
      final byTimestamp = await _findByTimestamp(pgTs);
      if (byTimestamp != null) {
        _assetIdByName[lookupExact] = byTimestamp;
        _assetIdByName[lookupBase] = byTimestamp;
        return byTimestamp;
      }
    }

    // 캐시가 오래된 상태일 수 있으므로 1회 강제 리프레시 후 재탐색
    _invalidateAssetCaches();
    final quickAfterRefresh = await _findInRecentAssets(
      lookupExact: lookupExact,
    );
    if (quickAfterRefresh != null && quickAfterRefresh.isNotEmpty) {
      _assetIdByName[lookupExact] = quickAfterRefresh;
      _assetIdByName[lookupBase] = quickAfterRefresh;
      return quickAfterRefresh;
    }
    await _ensureAssetIndex();
    if (_assetIdByName[lookupExact] case final id?) return id;
    if (_assetIdByName[lookupBase] case final id?) return id;
    return null;
  }

  Future<String?> _findInRecentAssets({required String lookupExact}) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (paths.isEmpty) return null;

    const pageSize = 240;
    const maxPages = 4; // 최근 최대 960장만 빠르게 확인
    for (int page = 0; page < maxPages; page++) {
      final assets = await paths.first.getAssetListPaged(
        page: page,
        size: pageSize,
      );
      if (assets.isEmpty) break;
      for (final asset in assets) {
        final title = (asset.title?.trim().isNotEmpty ?? false)
            ? asset.title!.trim()
            : await asset.titleAsync;
        if (_normalizeName(title) == lookupExact) {
          return asset.id;
        }
      }
    }
    return null;
  }

  Future<void> _ensureAssetIndex() async {
    final now = DateTime.now();
    final hasFreshIndex =
        _indexBuiltAt != null && now.difference(_indexBuiltAt!) < _indexTtl;
    if (hasFreshIndex && _assetIdByName.isNotEmpty) return;

    if (_indexBuildFuture != null) {
      await _indexBuildFuture;
      return;
    }

    _indexBuildFuture = _buildAssetIndex();
    try {
      await _indexBuildFuture;
    } finally {
      _indexBuildFuture = null;
    }
  }

  Future<void> _buildAssetIndex() async {
    final map = <String, String>{};
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: false,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );

    const pageSize = 300;
    const maxPagesPerAlbum = 8;
    const maxTotalAssets = 8000;
    int scanned = 0;

    for (final path in paths) {
      for (int page = 0; page < maxPagesPerAlbum; page++) {
        if (scanned >= maxTotalAssets) break;
        final assets = await path.getAssetListPaged(page: page, size: pageSize);
        if (assets.isEmpty) break;
        for (final asset in assets) {
          final title = (asset.title?.trim().isNotEmpty ?? false)
              ? asset.title!.trim()
              : await asset.titleAsync;
          final exact = _normalizeName(title);
          if (exact.isEmpty) continue;
          map.putIfAbsent(exact, () => asset.id);
          map.putIfAbsent(_baseName(exact), () => asset.id);
          scanned++;
          if (scanned >= maxTotalAssets) break;
        }
      }
      if (scanned >= maxTotalAssets) break;
    }

    _assetIdByName
      ..clear()
      ..addAll(map);
    _indexBuiltAt = DateTime.now();
  }

  Future<List<AssetEntity>> _loadRecentAssets({
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    final fresh =
        !forceRefresh &&
        _recentAssetCache != null &&
        _recentAssetCacheAt != null &&
        now.difference(_recentAssetCacheAt!) < _recentAssetCacheTtl;
    if (fresh) return _recentAssetCache!;

    if (_recentAssetLoadFuture != null) {
      return _recentAssetLoadFuture!;
    }

    _recentAssetLoadFuture = () async {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) return <AssetEntity>[];

      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: const [
            OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (paths.isEmpty) return <AssetEntity>[];

      const pageSize = 300;
      const maxPages = 10; // 최대 3,000장
      final list = <AssetEntity>[];
      for (int page = 0; page < maxPages; page++) {
        final pageItems = await paths.first.getAssetListPaged(
          page: page,
          size: pageSize,
        );
        if (pageItems.isEmpty) break;
        list.addAll(pageItems);
      }

      _recentAssetCache = list;
      _recentAssetCacheAt = DateTime.now();
      return list;
    }();

    try {
      return await _recentAssetLoadFuture!;
    } finally {
      _recentAssetLoadFuture = null;
    }
  }

  AssetEntity? _matchAssetByFileName(
    List<AssetEntity> assets,
    String fileName,
  ) {
    final key = _normalizeName(fileName);
    final keyBase = _baseName(key);
    for (final asset in assets) {
      final title = asset.title?.trim();
      if (title == null || title.isEmpty) continue;
      final t = _normalizeName(title);
      final tBase = _baseName(t);
      if (t == key || tBase == keyBase) return asset;
    }
    return null;
  }

  AssetEntity? _matchAssetByTimestamp(
    List<AssetEntity> assets,
    int unixSeconds, {
    required int toleranceSec,
  }) {
    AssetEntity? best;
    var bestDelta = 1 << 30;
    for (final asset in assets) {
      final createdAt = asset.createDateSecond;
      if (createdAt == null) continue;
      final delta = (createdAt - unixSeconds).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = asset;
      }
    }
    if (best != null && bestDelta <= toleranceSec) return best;
    return null;
  }

  void _invalidateAssetCaches() {
    _assetIdByName.clear();
    _indexBuiltAt = null;
    _recentAssetCache = null;
    _recentAssetCacheAt = null;
  }

  int? _extractPgUnixSeconds(String fileName) {
    final match = RegExp(
      r'PG_(\d{9,})',
      caseSensitive: false,
    ).firstMatch(fileName);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<String?> _findByTimestamp(int unixSeconds) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (paths.isEmpty) return null;

    const pageSize = 260;
    const maxPages = 6; // 최근 1,560장 내에서만 탐색
    String? bestId;
    int bestDelta = 1 << 30;

    for (int page = 0; page < maxPages; page++) {
      final assets = await paths.first.getAssetListPaged(
        page: page,
        size: pageSize,
      );
      if (assets.isEmpty) break;
      for (final asset in assets) {
        final createdAt = asset.createDateSecond;
        if (createdAt == null) continue;
        final delta = (createdAt - unixSeconds).abs();
        if (delta < bestDelta) {
          bestDelta = delta;
          bestId = asset.id;
        }
      }
    }

    // 최대 5분 이내면 같은 촬영으로 간주
    if (bestId != null && bestDelta <= 300) return bestId;
    return null;
  }

  String _normalizeName(String value) => value.trim().toLowerCase();

  String _baseName(String value) {
    final idx = value.lastIndexOf('.');
    if (idx <= 0) return value;
    return value.substring(0, idx);
  }

  Future<String?> _resolveRecentAssetRefByTakenAt({
    required String fileName,
    required DateTime takenAt,
  }) async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) return null;

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (paths.isEmpty) return null;

    final targetSec = takenAt.toUtc().millisecondsSinceEpoch ~/ 1000;
    const pageSize = 120;
    const maxPages = 3; // 최근 360장만 탐색
    AssetEntity? best;
    var bestDelta = 1 << 30;

    for (int page = 0; page < maxPages; page++) {
      final assets = await paths.first.getAssetListPaged(
        page: page,
        size: pageSize,
      );
      if (assets.isEmpty) break;
      for (final asset in assets) {
        final createSec = asset.createDateSecond;
        if (createSec == null) continue;
        final delta = (createSec - targetSec).abs();
        if (delta < bestDelta) {
          bestDelta = delta;
          best = asset;
        }
      }
    }

    if (best == null || bestDelta > 240) return null; // 4분 초과는 제외
    final selected = best;
    final title = (selected.title?.trim().isNotEmpty ?? false)
        ? selected.title!.trim()
        : fileName;
    return 'asset:${selected.id}|$title';
  }
}
