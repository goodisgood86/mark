import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/constants.dart';
import '../models/one_line_diary_entry.dart';
import '../models/pet_info.dart';
import '../services/petgram_photo_repository.dart';
import 'petgram_db.dart';
import 'petgram_media_ref_service.dart';

/// 한줄일기 서비스
///
/// 목록 소스는 petgram_photos(DB), 사용자 작성 데이터(코멘트/태그/숨김)는
/// diary_entries + diary_tags(DB)로 통합 관리한다.
class OneLineDiaryService {
  OneLineDiaryService._internal();

  static final OneLineDiaryService instance = OneLineDiaryService._internal();

  static const String _legacyDraftPrefix = 'one_line_diary_draft_';
  static const String _dbMigrationDoneKey = 'one_line_diary_db_migrated_v2';
  static const Duration _newCaptureGrace = Duration(minutes: 5);
  Future<void>? _diaryStoreInitFuture;

  Future<List<OneLineDiaryEntry>> loadRecentEntries({
    int limit = 200,
    int offset = 0,
    bool includeHidden = false,
    bool validateExistence = false,
  }) async {
    await _ensureDiaryStoreReady();
    final db = await PetgramDatabase.instance.database;
    final records = await PetgramPhotoRepository.instance.listForDiary(
      limit: limit,
      offset: offset,
      petgramOnly: true,
    );

    final normalizedPaths = <String>[];
    for (final record in records) {
      final normalized = PetgramMediaRefService.instance.normalizeDbFileRef(
        record.filePath,
      );
      normalizedPaths.add(normalized);
    }

    final entryByPath = await _loadDiaryEntryMapForPaths(db, normalizedPaths);
    final entryIds = entryByPath.values
        .map((row) => row['entry_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final tagsByEntryId = await _loadTagMapForEntryIds(db, entryIds);

    final results = <OneLineDiaryEntry>[];
    int existenceCheckBudget = validateExistence ? records.length : 0;

    for (final record in records) {
      final effectivePath = PetgramMediaRefService.instance.normalizeDbFileRef(
        record.filePath,
      );
      if (existenceCheckBudget > 0) {
        existenceCheckBudget--;
        final exists = await _existsOnDevice(
          fileRef: effectivePath,
          takenAt: record.meta.takenAt,
        );
        if (!exists) {
          await _pruneMissingDiaryRecord(
            originalFilePath: record.filePath,
            normalizedFilePath: effectivePath,
          );
          continue;
        }
      }

      final entryId = _entryKeyFromFilePath(effectivePath);
      final entryRow = entryByPath[effectivePath];
      final rowEntryId = entryRow?['entry_id']?.toString() ?? entryId;
      final isHidden = _readInt(entryRow?['is_hidden']) == 1;
      if (isHidden && !includeHidden) continue;

      final fileName = _fileNameFromPath(effectivePath);
      final rawPetName = record.meta.frameMeta['petName']?.toString().trim();
      final rawPetType = record.meta.frameMeta['petType']?.toString().trim();

      results.add(
        OneLineDiaryEntry(
          id: rowEntryId,
          filePath: effectivePath,
          takenAt: record.meta.takenAt.toLocal(),
          fileName: fileName,
          petName: (rawPetName == null || rawPetName.isEmpty)
              ? null
              : rawPetName,
          petType: (rawPetType == null || rawPetType.isEmpty)
              ? null
              : rawPetType.toLowerCase(),
          comment: entryRow?['comment']?.toString() ?? '',
          userTags: tagsByEntryId[rowEntryId] ?? const <String>[],
          isHidden: isHidden,
        ),
      );
    }

    return results;
  }

  Future<void> saveDraft({
    required String entryId,
    required String comment,
    required List<String> userTags,
  }) async {
    await _ensureDiaryStoreReady();
    final filePath = _tryDecodeEntryId(entryId);
    if (filePath == null || filePath.trim().isEmpty) {
      throw StateError('일기 항목 식별자가 올바르지 않습니다.');
    }
    final normalizedPath = PetgramMediaRefService.instance.normalizeDbFileRef(
      filePath,
    );
    final normalizedEntryId = _entryKeyFromFilePath(normalizedPath);
    final normalizedTags = userTags
        .map(_normalizeTag)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final db = await PetgramDatabase.instance.database;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'diary_entries',
        columns: ['created_at', 'is_hidden'],
        where: 'entry_id = ?',
        whereArgs: [normalizedEntryId],
        limit: 1,
      );
      final createdAt = existing.isNotEmpty
          ? _readInt(existing.first['created_at'], nowMs)
          : nowMs;
      final hidden = existing.isNotEmpty
          ? _readInt(existing.first['is_hidden'])
          : 0;

      await txn.insert('diary_entries', {
        'entry_id': normalizedEntryId,
        'file_path': normalizedPath,
        'comment': comment.trim(),
        'is_hidden': hidden,
        'created_at': createdAt,
        'updated_at': nowMs,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await txn.delete(
        'diary_tags',
        where: 'entry_id = ?',
        whereArgs: [normalizedEntryId],
      );
      for (final tag in normalizedTags) {
        await txn.insert('diary_tags', {
          'entry_id': normalizedEntryId,
          'tag': tag,
          'created_at': nowMs,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<void> setHidden({
    required String entryId,
    required bool hidden,
  }) async {
    await _ensureDiaryStoreReady();
    final filePath = _tryDecodeEntryId(entryId);
    if (filePath == null || filePath.trim().isEmpty) {
      throw StateError('일기 항목 식별자가 올바르지 않습니다.');
    }
    final normalizedPath = PetgramMediaRefService.instance.normalizeDbFileRef(
      filePath,
    );
    final normalizedEntryId = _entryKeyFromFilePath(normalizedPath);
    final db = await PetgramDatabase.instance.database;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'diary_entries',
        columns: ['comment', 'created_at'],
        where: 'entry_id = ?',
        whereArgs: [normalizedEntryId],
        limit: 1,
      );
      final createdAt = existing.isNotEmpty
          ? _readInt(existing.first['created_at'], nowMs)
          : nowMs;
      final comment = existing.isNotEmpty
          ? existing.first['comment']?.toString() ?? ''
          : '';

      await txn.insert('diary_entries', {
        'entry_id': normalizedEntryId,
        'file_path': normalizedPath,
        'comment': comment,
        'is_hidden': hidden ? 1 : 0,
        'created_at': createdAt,
        'updated_at': nowMs,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// 사진앱에서 삭제된 항목을 강제로 정리한다.
  /// - DB 레코드 삭제
  /// - diary_entries / diary_tags 삭제
  Future<void> pruneMissingEntryByFilePath(String filePath) async {
    final normalized = PetgramMediaRefService.instance.normalizeDbFileRef(
      filePath,
    );
    await _pruneMissingDiaryRecord(
      originalFilePath: filePath,
      normalizedFilePath: normalized,
    );
  }

  /// 백업 직전 정합성 보정.
  /// 기기에서 이미 삭제된 사진 참조를 DB에서 제거해 삭제 반영 정확도를 높인다.
  Future<int> pruneMissingRecordsForBackup({int maxChecks = 5000}) async {
    await _ensureDiaryStoreReady();
    final db = await PetgramDatabase.instance.database;
    final rows = await db.query(
      'petgram_photos',
      columns: ['file_path', 'taken_at'],
      orderBy: 'taken_at DESC, created_at DESC',
      limit: maxChecks > 0 ? maxChecks : null,
    );
    if (rows.isEmpty) return 0;

    var pruned = 0;
    for (final row in rows) {
      final originalFilePath = row['file_path']?.toString().trim() ?? '';
      if (originalFilePath.isEmpty) continue;
      final takenAtMs = _readInt(row['taken_at']);
      final takenAt = DateTime.fromMillisecondsSinceEpoch(
        takenAtMs,
        isUtc: true,
      );
      final normalizedFilePath = PetgramMediaRefService.instance
          .normalizeDbFileRef(originalFilePath);
      final exists = await _existsOnDeviceForPrune(
        fileRef: normalizedFilePath,
        takenAt: takenAt,
      );
      if (exists) continue;
      await _pruneMissingDiaryRecord(
        originalFilePath: originalFilePath,
        normalizedFilePath: normalizedFilePath,
      );
      pruned++;
    }
    return pruned;
  }

  Future<List<String>> loadRegisteredPetNames() async {
    final prefs = await SharedPreferences.getInstance();
    return _readRegisteredPetNamesFromPrefs(prefs);
  }

  Future<List<PetInfo>> loadRegisteredPets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(kPetListKey) ?? const <String>[];
    final pets = <PetInfo>[];
    for (final item in raw) {
      try {
        final map = jsonDecode(item) as Map<String, dynamic>;
        pets.add(PetInfo.fromJson(map));
      } catch (_) {}
    }
    return pets;
  }

  Future<bool> hasLocalFile(String filePath) async {
    final path = extractLocalFilePath(filePath);
    if (path == null || path.isEmpty) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  String? extractLocalFilePath(String ref) {
    if (ref.startsWith('file:')) return ref.substring(5);
    if (ref.contains('/')) return ref;
    return null;
  }

  String? extractAssetId(String ref) {
    if (!ref.startsWith('asset:')) return null;
    final payload = ref.substring(6);
    final idx = payload.indexOf('|');
    if (idx < 0) return payload;
    return payload.substring(0, idx);
  }

  Future<void> _ensureDiaryStoreReady() async {
    if (_diaryStoreInitFuture != null) return _diaryStoreInitFuture;
    _diaryStoreInitFuture = _initializeDiaryStore();
    return _diaryStoreInitFuture;
  }

  Future<void> _initializeDiaryStore() async {
    final db = await PetgramDatabase.instance.database;
    // DB 버전 업 전에 실행되는 경우를 방어하기 위해 한 번 더 보장
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diary_entries (
        entry_id TEXT PRIMARY KEY,
        file_path TEXT NOT NULL UNIQUE,
        comment TEXT NOT NULL DEFAULT '',
        is_hidden INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diary_tags (
        entry_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (entry_id, tag),
        FOREIGN KEY (entry_id) REFERENCES diary_entries(entry_id) ON DELETE CASCADE
      );
    ''');

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_dbMigrationDoneKey) == true) return;
    await _migrateLegacyDraftsFromPrefs(db, prefs);
    await prefs.setBool(_dbMigrationDoneKey, true);
  }

  Future<void> _migrateLegacyDraftsFromPrefs(
    Database db,
    SharedPreferences prefs,
  ) async {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final keys = prefs.getKeys().where((k) => k.startsWith(_legacyDraftPrefix));
    final draftKeys = keys.toList(growable: false);
    if (draftKeys.isEmpty) return;

    await db.transaction((txn) async {
      for (final key in draftKeys) {
        final entryId = key.substring(_legacyDraftPrefix.length);
        final filePath = _tryDecodeEntryId(entryId);
        if (filePath == null || filePath.trim().isEmpty) continue;

        final normalizedPath = PetgramMediaRefService.instance
            .normalizeDbFileRef(filePath);
        final normalizedEntryId = _entryKeyFromFilePath(normalizedPath);
        final draft = _readLegacyDraft(prefs, key);
        final comment = (draft['comment'] as String?)?.trim() ?? '';
        final hidden = draft['hidden'] == true ? 1 : 0;
        final tags = _parseStringList(draft['tags']);

        await txn.insert('diary_entries', {
          'entry_id': normalizedEntryId,
          'file_path': normalizedPath,
          'comment': comment,
          'is_hidden': hidden,
          'created_at': nowMs,
          'updated_at': nowMs,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        await txn.delete(
          'diary_tags',
          where: 'entry_id = ?',
          whereArgs: [normalizedEntryId],
        );
        for (final tag in tags) {
          await txn.insert('diary_tags', {
            'entry_id': normalizedEntryId,
            'tag': tag,
            'created_at': nowMs,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });

    for (final key in draftKeys) {
      await prefs.remove(key);
    }
  }

  Future<Map<String, Map<String, Object?>>> _loadDiaryEntryMapForPaths(
    Database db,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return const <String, Map<String, Object?>>{};
    final dedup = paths.toSet().toList(growable: false);
    const chunkSize = 200;
    final map = <String, Map<String, Object?>>{};

    for (var i = 0; i < dedup.length; i += chunkSize) {
      final end = (i + chunkSize < dedup.length) ? i + chunkSize : dedup.length;
      final chunk = dedup.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'diary_entries',
        where: 'file_path IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final row in rows) {
        final filePath = row['file_path']?.toString();
        if (filePath == null || filePath.isEmpty) continue;
        map[filePath] = row;
      }
    }

    return map;
  }

  Future<Map<String, List<String>>> _loadTagMapForEntryIds(
    Database db,
    List<String> entryIds,
  ) async {
    if (entryIds.isEmpty) return const <String, List<String>>{};
    const chunkSize = 200;
    final tagsByEntryId = <String, List<String>>{};

    for (var i = 0; i < entryIds.length; i += chunkSize) {
      final end = (i + chunkSize < entryIds.length)
          ? i + chunkSize
          : entryIds.length;
      final chunk = entryIds.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'diary_tags',
        columns: ['entry_id', 'tag'],
        where: 'entry_id IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final row in rows) {
        final entryId = row['entry_id']?.toString();
        final tag = _normalizeTag(row['tag']?.toString() ?? '');
        if (entryId == null || entryId.isEmpty || tag.isEmpty) continue;
        final list = tagsByEntryId.putIfAbsent(entryId, () => <String>[]);
        if (!list.contains(tag)) list.add(tag);
      }
    }

    return tagsByEntryId;
  }

  Future<bool> _existsOnDevice({
    required String fileRef,
    required DateTime takenAt,
  }) async {
    final normalized = PetgramMediaRefService.instance.normalizeDbFileRef(
      fileRef,
    );

    if (normalized.startsWith('asset:')) {
      final assetId = extractAssetId(normalized);
      if (assetId == null || assetId.isEmpty) return false;
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) return false;
      final refreshed = await entity.obtainForNewProperties();
      return refreshed != null;
    }

    if (normalized.startsWith('file:')) {
      final path = extractLocalFilePath(normalized);
      if (path == null || path.isEmpty) return false;
      try {
        final hasLocal = await File(path).exists();
        if (!hasLocal) return false;
        final fileName = p.basename(path).trim();
        if (fileName.isEmpty) return _isWithinNewCaptureGrace(takenAt);
        final entity = await PetgramMediaRefService.instance
            .resolveAssetEntityForDiary(
              fileRef: 'name:$fileName',
              takenAt: takenAt,
            )
            .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
        if (entity != null) return true;
        return _isWithinNewCaptureGrace(takenAt);
      } catch (_) {
        return false;
      }
    }

    if (normalized.startsWith('name:')) {
      try {
        final entity = await PetgramMediaRefService.instance
            .resolveAssetEntityForDiary(fileRef: normalized, takenAt: takenAt)
            .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
        if (entity != null) return true;
        return _isWithinNewCaptureGrace(takenAt);
      } catch (_) {
        return false;
      }
    }

    return true;
  }

  Future<bool> _existsOnDeviceForPrune({
    required String fileRef,
    required DateTime takenAt,
  }) async {
    final normalized = PetgramMediaRefService.instance.normalizeDbFileRef(
      fileRef,
    );

    if (normalized.startsWith('asset:')) {
      final assetId = extractAssetId(normalized);
      if (assetId == null || assetId.isEmpty) return false;
      final entity = await AssetEntity.fromId(assetId);
      return entity != null;
    }

    if (normalized.startsWith('file:')) {
      final path = extractLocalFilePath(normalized);
      if (path == null || path.isEmpty) return false;
      try {
        return await File(path).exists();
      } catch (_) {
        return false;
      }
    }

    if (normalized.startsWith('name:')) {
      try {
        final entity = await PetgramMediaRefService.instance
            .resolveAssetEntityByExactNameForDiary(fileRef: normalized)
            .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
        if (entity != null) return true;
        // 촬영 직후 인덱스 지연 보호
        return _isWithinNewCaptureGrace(takenAt);
      } catch (_) {
        return false;
      }
    }

    return true;
  }

  bool _isWithinNewCaptureGrace(DateTime takenAt) {
    final localTakenAt = takenAt.toLocal();
    final elapsed = DateTime.now().difference(localTakenAt);
    return !elapsed.isNegative && elapsed <= _newCaptureGrace;
  }

  Future<void> _pruneMissingDiaryRecord({
    required String originalFilePath,
    required String normalizedFilePath,
  }) async {
    final db = await PetgramDatabase.instance.database;
    await PetgramPhotoRepository.instance.deleteByFilePath(originalFilePath);
    if (normalizedFilePath != originalFilePath) {
      await PetgramPhotoRepository.instance.deleteByFilePath(
        normalizedFilePath,
      );
    }

    await db.delete(
      'diary_entries',
      where: 'file_path IN (?, ?)',
      whereArgs: [originalFilePath, normalizedFilePath],
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(
      '$_legacyDraftPrefix${_entryKeyFromFilePath(originalFilePath)}',
    );
    await prefs.remove(
      '$_legacyDraftPrefix${_entryKeyFromFilePath(normalizedFilePath)}',
    );
  }

  String _entryKeyFromFilePath(String filePath) {
    return base64Url.encode(utf8.encode(filePath));
  }

  String _fileNameFromPath(String filePath) {
    if (filePath.startsWith('asset:')) {
      final payload = filePath.substring(6);
      final split = payload.split('|');
      if (split.length >= 2 && split[1].trim().isNotEmpty) {
        return split[1].trim();
      }
      return 'asset_photo.jpg';
    }
    if (filePath.startsWith('name:')) {
      return filePath.substring(5);
    }
    if (filePath.startsWith('file:')) {
      final path = filePath.substring(5);
      return p.basename(path);
    }
    if (filePath.trim().isEmpty) return '';
    if (filePath.contains('/')) return p.basename(filePath);
    return filePath;
  }

  List<String> _readRegisteredPetNamesFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getStringList(kPetListKey) ?? const <String>[];
    final names = <String>{};
    for (final item in raw) {
      try {
        final map = jsonDecode(item) as Map<String, dynamic>;
        final pet = PetInfo.fromJson(map);
        final name = pet.name.trim();
        if (name.isNotEmpty) {
          names.add(name);
        }
      } catch (_) {}
    }
    final list = names.toList()..sort();
    return list;
  }

  Map<String, dynamic> _readLegacyDraft(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  String? _tryDecodeEntryId(String entryId) {
    try {
      return utf8.decode(base64Url.decode(entryId));
    } catch (_) {
      return null;
    }
  }

  List<String> _parseStringList(dynamic source) {
    if (source is! List) return const <String>[];
    return source
        .map((e) => _normalizeTag(e.toString()))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  String _normalizeTag(String raw) {
    var tag = raw.trim();
    while (tag.startsWith('#')) {
      tag = tag.substring(1).trimLeft();
    }
    return tag.trim();
  }

  int _readInt(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
