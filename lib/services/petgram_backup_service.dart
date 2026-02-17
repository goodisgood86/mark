import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/constants.dart';
import 'petgram_db.dart';

class PetgramBackupRestoreResult {
  final int restoredPhotoCount;
  final int restoredDraftCount;
  final int restoredTagCount;
  final int restoredPrefCount;
  final bool hasChanges;

  const PetgramBackupRestoreResult({
    required this.restoredPhotoCount,
    required this.restoredDraftCount,
    required this.restoredTagCount,
    required this.restoredPrefCount,
    required this.hasChanges,
  });
}

class PetgramBackupKeySnapshot {
  final Set<String> photoPaths;
  final Set<String> diaryEntryIds;
  final Set<String> diaryTagKeys;

  const PetgramBackupKeySnapshot({
    required this.photoPaths,
    required this.diaryEntryIds,
    required this.diaryTagKeys,
  });
}

class PetgramBackupService {
  PetgramBackupService._internal();

  static final PetgramBackupService instance = PetgramBackupService._internal();

  static const int _backupVersion = 2;
  static const String _backupDirName = 'backups';
  static const String _backupFilePrefix = 'petgram_backup_';
  static const String _backupFileSuffix = '.json';
  static const String _legacyDraftPrefix = 'one_line_diary_draft_';

  Future<String> readDataSignatureToken() async {
    final db = await PetgramDatabase.instance.database;

    final photoAgg = await db.rawQuery(
      'SELECT COUNT(*) AS cnt, COALESCE(MAX(updated_at), 0) AS max_ts FROM petgram_photos;',
    );
    final diaryAgg = await db.rawQuery(
      'SELECT COUNT(*) AS cnt, COALESCE(MAX(updated_at), 0) AS max_ts FROM diary_entries;',
    );
    final tagAgg = await db.rawQuery(
      'SELECT COUNT(*) AS cnt, COALESCE(MAX(created_at), 0) AS max_ts FROM diary_tags;',
    );

    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    final pRow = photoAgg.isNotEmpty
        ? photoAgg.first
        : const <String, Object?>{};
    final dRow = diaryAgg.isNotEmpty
        ? diaryAgg.first
        : const <String, Object?>{};
    final tRow = tagAgg.isNotEmpty ? tagAgg.first : const <String, Object?>{};

    final pCount = asInt(pRow['cnt']);
    final pMax = asInt(pRow['max_ts']);
    final dCount = asInt(dRow['cnt']);
    final dMax = asInt(dRow['max_ts']);
    final tCount = asInt(tRow['cnt']);
    final tMax = asInt(tRow['max_ts']);

    return 'p:$pCount:$pMax|d:$dCount:$dMax|t:$tCount:$tMax';
  }

  Future<PetgramBackupKeySnapshot> createKeySnapshot() async {
    final db = await PetgramDatabase.instance.database;

    final photos = await db.query('petgram_photos', columns: ['file_path']);
    final entries = await db.query('diary_entries', columns: ['entry_id']);
    final tags = await db.query('diary_tags', columns: ['entry_id', 'tag']);

    final photoPaths = <String>{};
    for (final row in photos) {
      final key = row['file_path']?.toString().trim();
      if (key != null && key.isNotEmpty) {
        photoPaths.add(key);
      }
    }

    final diaryEntryIds = <String>{};
    for (final row in entries) {
      final key = row['entry_id']?.toString().trim();
      if (key != null && key.isNotEmpty) {
        diaryEntryIds.add(key);
      }
    }

    final diaryTagKeys = <String>{};
    for (final row in tags) {
      final entryId = row['entry_id']?.toString().trim() ?? '';
      final tag = row['tag']?.toString().trim() ?? '';
      if (entryId.isEmpty || tag.isEmpty) continue;
      diaryTagKeys.add('$entryId::$tag');
    }

    return PetgramBackupKeySnapshot(
      photoPaths: photoPaths,
      diaryEntryIds: diaryEntryIds,
      diaryTagKeys: diaryTagKeys,
    );
  }

  static const List<String> _prefKeysToBackup = [
    kOnboardingSeenKey,
    kLastSelectedFilterKey,
    kPetNameKey,
    kPetListKey,
    kSelectedPetIdKey,
    kFlashModeKey,
    kShowGridLinesKey,
    kFrameEnabledKey,
    kBurstModeKey,
    kBurstCountSettingKey,
    kTimerSecondsKey,
    kAspectModeKey,
  ];

  Future<Map<String, dynamic>> createDeltaPayload({
    required int photoUpdatedAfterMs,
    required int diaryUpdatedAfterMs,
    required int tagCreatedAfterMs,
  }) async {
    final db = await PetgramDatabase.instance.database;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();

    final photos = await db.query(
      'petgram_photos',
      where: 'updated_at > ?',
      whereArgs: [photoUpdatedAfterMs],
      orderBy: 'updated_at ASC',
    );
    final diaryEntries = await db.query(
      'diary_entries',
      where: 'updated_at > ?',
      whereArgs: [diaryUpdatedAfterMs],
      orderBy: 'updated_at ASC',
    );
    final diaryTags = await db.query(
      'diary_tags',
      where: 'created_at > ?',
      whereArgs: [tagCreatedAfterMs],
      orderBy: 'created_at ASC',
    );

    final photoAgg = await db.rawQuery(
      'SELECT COALESCE(MAX(updated_at), 0) AS max_ts FROM petgram_photos;',
    );
    final diaryAgg = await db.rawQuery(
      'SELECT COALESCE(MAX(updated_at), 0) AS max_ts FROM diary_entries;',
    );
    final tagAgg = await db.rawQuery(
      'SELECT COALESCE(MAX(created_at), 0) AS max_ts FROM diary_tags;',
    );

    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    final pMax = asInt(photoAgg.isNotEmpty ? photoAgg.first['max_ts'] : 0);
    final dMax = asInt(diaryAgg.isNotEmpty ? diaryAgg.first['max_ts'] : 0);
    final tMax = asInt(tagAgg.isNotEmpty ? tagAgg.first['max_ts'] : 0);

    final prefMap = <String, dynamic>{};
    for (final key in _prefKeysToBackup) {
      final value = prefs.get(key);
      if (value == null) continue;
      if (value is List<Object?>) {
        prefMap[key] = value.map((e) => e.toString()).toList(growable: false);
      } else {
        prefMap[key] = value;
      }
    }

    return <String, dynamic>{
      'app': 'petgram',
      'backup_version': _backupVersion,
      'created_at': now.toIso8601String(),
      'photos': photos,
      'diary_entries': diaryEntries,
      'diary_tags': diaryTags,
      'prefs': prefMap,
      '_sync': {
        'photo_max_updated_at': pMax,
        'diary_max_updated_at': dMax,
        'tag_max_created_at': tMax,
      },
    };
  }

  Future<Map<String, dynamic>> createBackupPayload() async {
    final db = await PetgramDatabase.instance.database;
    final prefs = await SharedPreferences.getInstance();

    final rows = await db.query('petgram_photos', orderBy: 'created_at DESC');
    final diaryEntries = await db.query(
      'diary_entries',
      orderBy: 'updated_at DESC',
    );
    final diaryTags = await db.query('diary_tags', orderBy: 'created_at DESC');
    final now = DateTime.now().toUtc();

    final prefMap = <String, dynamic>{};
    for (final key in _prefKeysToBackup) {
      final value = prefs.get(key);
      if (value == null) continue;
      if (value is List<Object?>) {
        prefMap[key] = value.map((e) => e.toString()).toList(growable: false);
      } else {
        prefMap[key] = value;
      }
    }

    return <String, dynamic>{
      'app': 'petgram',
      'backup_version': _backupVersion,
      'created_at': now.toIso8601String(),
      'photos': rows,
      'diary_entries': diaryEntries,
      'diary_tags': diaryTags,
      'prefs': prefMap,
    };
  }

  Future<File> createBackupFile() async {
    final payload = await createBackupPayload();
    final now = DateTime.now().toUtc();

    final backupDir = await _ensureBackupDir();
    final stamp = _buildFileStamp(now);
    final filePath = p.join(
      backupDir.path,
      '$_backupFilePrefix$stamp$_backupFileSuffix',
    );

    final file = File(filePath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return file;
  }

  Future<PetgramBackupRestoreResult> restoreFromLatestBackupFile() async {
    final latest = await getLatestBackupFile();
    if (latest == null) {
      throw StateError('복원할 백업 파일이 없습니다.');
    }
    return restoreFromFile(latest);
  }

  Future<PetgramBackupRestoreResult> restoreFromFile(File file) async {
    if (!await file.exists()) {
      throw StateError('백업 파일을 찾을 수 없습니다: ${file.path}');
    }
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('백업 파일 형식이 올바르지 않습니다.');
    }
    return _restoreFromPayload(decoded);
  }

  Future<PetgramBackupRestoreResult> restoreFromPayloadMap(
    Map<String, dynamic> payload,
  ) async {
    return _restoreFromPayload(payload);
  }

  Future<File?> getLatestBackupFile() async {
    final backupDir = await _ensureBackupDir();
    if (!await backupDir.exists()) return null;

    final files = await backupDir
        .list()
        .where(
          (entity) =>
              entity is File &&
              p.basename(entity.path).startsWith(_backupFilePrefix) &&
              entity.path.endsWith(_backupFileSuffix),
        )
        .cast<File>()
        .toList();

    if (files.isEmpty) return null;

    files.sort((a, b) => b.path.compareTo(a.path));
    return files.first;
  }

  Future<PetgramBackupRestoreResult> _restoreFromPayload(
    Map<String, dynamic> payload,
  ) async {
    final version = payload['backup_version'];
    if (version is! int || version <= 0) {
      throw StateError('지원하지 않는 백업 버전입니다.');
    }

    final db = await PetgramDatabase.instance.database;
    final prefs = await SharedPreferences.getInstance();

    final photosRaw = payload['photos'];
    final diaryEntriesRaw = payload['diary_entries'];
    final diaryTagsRaw = payload['diary_tags'];
    final draftsRaw = payload['drafts']; // v1 호환
    final prefsRaw = payload['prefs'];

    int restoredPhotos = 0;
    int restoredDrafts = 0;
    int restoredTags = 0;
    int restoredPrefs = 0;

    final incomingPhotosByPath = <String, Map<String, dynamic>>{};
    if (photosRaw is List) {
      for (final item in photosRaw) {
        if (item is! Map) continue;
        final row = _sanitizePhotoRow(item);
        if (row == null) continue;
        final filePath = row['file_path']?.toString() ?? '';
        if (filePath.isEmpty) continue;
        final existing = incomingPhotosByPath[filePath];
        if (existing == null ||
            _readIntValue(row['updated_at']) >=
                _readIntValue(existing['updated_at'])) {
          incomingPhotosByPath[filePath] = row;
        }
      }
    }
    final incomingPhotoRows = incomingPhotosByPath.values.toList(
      growable: false,
    );

    final entryIdRemap = <String, String>{};
    final incomingEntriesById = <String, Map<String, dynamic>>{};
    if (diaryEntriesRaw is List) {
      for (final item in diaryEntriesRaw) {
        if (item is! Map) continue;
        final rawEntryId = item['entry_id']?.toString().trim() ?? '';
        final row = _sanitizeDiaryEntryRow(item);
        if (row == null) continue;
        final entryId = row['entry_id']?.toString() ?? '';
        if (entryId.isEmpty) continue;
        if (rawEntryId.isNotEmpty && rawEntryId != entryId) {
          entryIdRemap[rawEntryId] = entryId;
        }
        final existing = incomingEntriesById[entryId];
        if (existing == null ||
            _readIntValue(row['updated_at']) >=
                _readIntValue(existing['updated_at'])) {
          incomingEntriesById[entryId] = row;
        }
      }
    }
    final incomingEntryRows = incomingEntriesById.values.toList(
      growable: false,
    );

    final incomingTagsByKey = <String, Map<String, dynamic>>{};
    if (diaryTagsRaw is List) {
      for (final item in diaryTagsRaw) {
        if (item is! Map) continue;
        final row = _sanitizeDiaryTagRow(item, entryIdRemap: entryIdRemap);
        if (row == null) continue;
        final entryId = row['entry_id']?.toString() ?? '';
        final tag = row['tag']?.toString() ?? '';
        if (entryId.isEmpty || tag.isEmpty) continue;
        final key = '$entryId::$tag';
        final existing = incomingTagsByKey[key];
        if (existing == null ||
            _readIntValue(row['created_at']) >=
                _readIntValue(existing['created_at'])) {
          incomingTagsByKey[key] = row;
        }
      }
    }
    final incomingTagRows = incomingTagsByKey.values.toList(growable: false);

    final existingPhotosByPath = await _loadExistingRowsByColumn(
      db: db,
      table: 'petgram_photos',
      keyColumn: 'file_path',
      keys: incomingPhotoRows
          .map((e) => e['file_path']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toSet(),
    );
    final existingEntriesById = await _loadExistingRowsByColumn(
      db: db,
      table: 'diary_entries',
      keyColumn: 'entry_id',
      keys: incomingEntryRows
          .map((e) => e['entry_id']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toSet(),
    );
    final existingEntriesByPath = await _loadExistingRowsByColumn(
      db: db,
      table: 'diary_entries',
      keyColumn: 'file_path',
      keys: incomingEntryRows
          .map((e) => e['file_path']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toSet(),
    );
    final tagEntryIds = incomingTagRows
        .map((e) => e['entry_id']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toSet();
    final existingTagRows = await _loadRowsByEntryIds(
      db: db,
      table: 'diary_tags',
      entryIds: tagEntryIds,
    );
    final validEntryRows = await _loadRowsByEntryIds(
      db: db,
      table: 'diary_entries',
      entryIds: tagEntryIds,
    );
    final validEntryIds = validEntryRows
        .map((row) => row['entry_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final existingTagByKey = <String, Map<String, dynamic>>{};
    for (final row in existingTagRows) {
      final entryId = row['entry_id']?.toString() ?? '';
      final tag = row['tag']?.toString() ?? '';
      if (entryId.isEmpty || tag.isEmpty) continue;
      existingTagByKey['$entryId::$tag'] = Map<String, dynamic>.from(row);
    }

    await db.transaction((txn) async {
      if (incomingPhotoRows.isNotEmpty) {
        final batch = txn.batch();
        for (final row in incomingPhotoRows) {
          final filePath = row['file_path']?.toString() ?? '';
          if (filePath.isEmpty) continue;
          final existing = existingPhotosByPath[filePath];
          if (_isIncomingOlder(existing, row, timestampKey: 'updated_at')) {
            continue;
          }
          if (_rowEqualsForKeys(existing, row, const [
            'file_path',
            'created_at',
            'updated_at',
            'is_petgram_shot',
            'is_petgram_edited',
            'frame_key',
            'taken_at',
            'meta_json',
            'exif_tag',
          ])) {
            continue;
          }
          batch.insert(
            'petgram_photos',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          existingPhotosByPath[filePath] = row;
          restoredPhotos++;
        }
        await batch.commit(noResult: true, continueOnError: false);
      }

      if (incomingEntryRows.isNotEmpty) {
        final batch = txn.batch();
        for (final row in incomingEntryRows) {
          final entryId = row['entry_id']?.toString() ?? '';
          final filePath = row['file_path']?.toString() ?? '';
          if (entryId.isEmpty || filePath.isEmpty) continue;
          final existing =
              existingEntriesById[entryId] ?? existingEntriesByPath[filePath];
          if (_isIncomingOlder(existing, row, timestampKey: 'updated_at')) {
            continue;
          }
          if (_rowEqualsForKeys(existing, row, const [
            'entry_id',
            'file_path',
            'comment',
            'is_hidden',
            'created_at',
            'updated_at',
          ])) {
            continue;
          }
          batch.insert(
            'diary_entries',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          existingEntriesById[entryId] = row;
          existingEntriesByPath[filePath] = row;
          validEntryIds.add(entryId);
          restoredDrafts++;
        }
        await batch.commit(noResult: true, continueOnError: false);
      }

      if (incomingTagRows.isNotEmpty) {
        final batch = txn.batch();
        for (final row in incomingTagRows) {
          final entryId = row['entry_id']?.toString() ?? '';
          final tag = row['tag']?.toString() ?? '';
          if (entryId.isEmpty || tag.isEmpty) continue;
          if (!validEntryIds.contains(entryId)) continue;
          final key = '$entryId::$tag';
          final existing = existingTagByKey[key];
          if (_isIncomingOlder(existing, row, timestampKey: 'created_at')) {
            continue;
          }
          if (_rowEqualsForKeys(existing, row, const [
            'entry_id',
            'tag',
            'created_at',
          ])) {
            continue;
          }
          batch.insert(
            'diary_tags',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          existingTagByKey[key] = row;
          restoredTags++;
        }
        await batch.commit(noResult: true, continueOnError: false);
      }
    });

    // v1 백업 호환 (SharedPreferences drafts -> DB)
    if (diaryEntriesRaw == null && draftsRaw is Map) {
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        for (final entry in draftsRaw.entries) {
          final key = entry.key;
          final value = entry.value;
          if (!key.startsWith(_legacyDraftPrefix) || value is! String) continue;

          final entryId = key.substring(_legacyDraftPrefix.length);
          final filePath = _decodeLegacyEntryId(entryId);
          if (filePath == null || filePath.trim().isEmpty) continue;
          final normalizedEntryId = _entryIdFromFilePath(filePath.trim());

          Map<String, dynamic> parsed;
          try {
            final decoded = jsonDecode(value);
            parsed = decoded is Map<String, dynamic>
                ? decoded
                : const <String, dynamic>{};
          } catch (_) {
            parsed = const <String, dynamic>{};
          }
          final tags = _parseTags(parsed['tags']);
          final comment = (parsed['comment'] as String?)?.trim() ?? '';
          final isHidden = parsed['hidden'] == true ? 1 : 0;

          await txn.insert('diary_entries', {
            'entry_id': normalizedEntryId,
            'file_path': filePath.trim(),
            'comment': comment,
            'is_hidden': isHidden,
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
            restoredTags++;
          }
          restoredDrafts++;
        }
      });
    }

    if (prefsRaw is Map) {
      for (final entry in prefsRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (_isSamePreferenceValue(prefs, key, value)) {
          continue;
        }
        final saved = await _restorePreferenceValue(prefs, key, value);
        if (saved) restoredPrefs++;
      }
    }

    final hasChanges =
        restoredPhotos > 0 ||
        restoredDrafts > 0 ||
        restoredTags > 0 ||
        restoredPrefs > 0;

    return PetgramBackupRestoreResult(
      restoredPhotoCount: restoredPhotos,
      restoredDraftCount: restoredDrafts,
      restoredTagCount: restoredTags,
      restoredPrefCount: restoredPrefs,
      hasChanges: hasChanges,
    );
  }

  Future<Map<String, Map<String, dynamic>>> _loadExistingRowsByColumn({
    required Database db,
    required String table,
    required String keyColumn,
    required Set<String> keys,
  }) async {
    final result = <String, Map<String, dynamic>>{};
    if (keys.isEmpty) return result;

    const int chunkSize = 300;
    final keyList = keys.toList(growable: false);
    for (var i = 0; i < keyList.length; i += chunkSize) {
      final end = (i + chunkSize > keyList.length)
          ? keyList.length
          : i + chunkSize;
      final chunk = keyList.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await db.rawQuery(
        'SELECT * FROM $table WHERE $keyColumn IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        final key = row[keyColumn]?.toString() ?? '';
        if (key.isEmpty) continue;
        result[key] = Map<String, dynamic>.from(row);
      }
    }
    return result;
  }

  Future<List<Map<String, Object?>>> _loadRowsByEntryIds({
    required Database db,
    required String table,
    required Set<String> entryIds,
  }) async {
    if (entryIds.isEmpty) return const <Map<String, Object?>>[];
    const int chunkSize = 300;
    final results = <Map<String, Object?>>[];
    final entryList = entryIds.toList(growable: false);
    for (var i = 0; i < entryList.length; i += chunkSize) {
      final end = (i + chunkSize > entryList.length)
          ? entryList.length
          : i + chunkSize;
      final chunk = entryList.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await db.rawQuery(
        'SELECT * FROM $table WHERE entry_id IN ($placeholders)',
        chunk,
      );
      results.addAll(rows);
    }
    return results;
  }

  bool _rowEqualsForKeys(
    Map<String, dynamic>? left,
    Map<String, dynamic> right,
    List<String> keys,
  ) {
    if (left == null) return false;
    for (final key in keys) {
      final l = left[key];
      final r = right[key];
      if ('$l' != '$r') return false;
    }
    return true;
  }

  int _readIntValue(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _isIncomingOlder(
    Map<String, dynamic>? existing,
    Map<String, dynamic> incoming, {
    required String timestampKey,
  }) {
    if (existing == null) return false;
    final existingTs = _readIntValue(existing[timestampKey]);
    final incomingTs = _readIntValue(incoming[timestampKey]);
    return incomingTs < existingTs;
  }

  bool _isSamePreferenceValue(
    SharedPreferences prefs,
    String key,
    dynamic incomingValue,
  ) {
    final current = prefs.get(key);
    if (incomingValue is List) {
      final incoming = incomingValue
          .map((e) => e.toString())
          .toList(growable: false);
      final currentList = current is List
          ? current.map((e) => '$e').toList()
          : null;
      if (currentList == null || currentList.length != incoming.length) {
        return false;
      }
      for (var i = 0; i < incoming.length; i++) {
        if (incoming[i] != currentList[i]) return false;
      }
      return true;
    }
    return '$current' == '$incomingValue';
  }

  Map<String, dynamic>? _sanitizeDiaryEntryRow(Map row) {
    final filePath = row['file_path']?.toString().trim();
    if (filePath == null || filePath.isEmpty) return null;
    final entryId = _entryIdFromFilePath(filePath);
    if (entryId.isEmpty) return null;

    int readInt(dynamic value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    return <String, dynamic>{
      'entry_id': entryId,
      'file_path': filePath,
      'comment': row['comment']?.toString() ?? '',
      'is_hidden': readInt(row['is_hidden'], 0),
      'created_at': readInt(row['created_at'], nowMs),
      'updated_at': readInt(row['updated_at'], nowMs),
    };
  }

  Map<String, dynamic>? _sanitizeDiaryTagRow(
    Map row, {
    Map<String, String>? entryIdRemap,
  }) {
    final rawEntryId = row['entry_id']?.toString().trim();
    final tag = row['tag']?.toString().trim();
    if (rawEntryId == null || rawEntryId.isEmpty) return null;
    if (tag == null || tag.isEmpty) return null;
    final entryId = entryIdRemap?[rawEntryId] ?? rawEntryId;
    if (entryId.isEmpty) return null;

    int readInt(dynamic value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    return <String, dynamic>{
      'entry_id': entryId,
      'tag': tag,
      'created_at': readInt(row['created_at'], nowMs),
    };
  }

  String? _decodeLegacyEntryId(String entryId) {
    try {
      return utf8.decode(base64Url.decode(entryId));
    } catch (_) {
      return null;
    }
  }

  String _entryIdFromFilePath(String filePath) {
    return base64Url.encode(utf8.encode(filePath));
  }

  List<String> _parseTags(dynamic source) {
    if (source is! List) return const <String>[];
    return source
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Map<String, dynamic>? _sanitizePhotoRow(Map row) {
    final filePath = row['file_path']?.toString().trim();
    if (filePath == null || filePath.isEmpty) return null;

    int readInt(dynamic value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    return <String, dynamic>{
      // 주의: id(자동 증가 PK)는 기기마다 충돌 가능하므로 복원 대상에서 제외한다.
      // 병합 기준은 file_path(unique)이며, id를 포함하면 기존 로컬 row를 잘못 덮어쓸 수 있다.
      'file_path': filePath,
      'created_at': readInt(row['created_at'], nowMs),
      'updated_at': readInt(row['updated_at'], nowMs),
      'is_petgram_shot': readInt(row['is_petgram_shot'], 0),
      'is_petgram_edited': readInt(row['is_petgram_edited'], 0),
      'frame_key': row['frame_key']?.toString() ?? 'none',
      'taken_at': readInt(row['taken_at'], nowMs),
      'meta_json': row['meta_json']?.toString() ?? '{}',
      'exif_tag': row['exif_tag']?.toString(),
    };
  }

  Future<bool> _restorePreferenceValue(
    SharedPreferences prefs,
    String key,
    dynamic value,
  ) async {
    if (value is bool) return prefs.setBool(key, value);
    if (value is int) return prefs.setInt(key, value);
    if (value is double) return prefs.setDouble(key, value);
    if (value is String) return prefs.setString(key, value);
    if (value is List) {
      final values = value.map((e) => e.toString()).toList(growable: false);
      return prefs.setStringList(key, values);
    }
    return false;
  }

  Future<Directory> _ensureBackupDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, _backupDirName));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir;
  }

  String _buildFileStamp(DateTime nowUtc) {
    final y = nowUtc.year.toString().padLeft(4, '0');
    final mo = nowUtc.month.toString().padLeft(2, '0');
    final d = nowUtc.day.toString().padLeft(2, '0');
    final h = nowUtc.hour.toString().padLeft(2, '0');
    final mi = nowUtc.minute.toString().padLeft(2, '0');
    final s = nowUtc.second.toString().padLeft(2, '0');
    return [y, mo, d, '_', h, mi, s, 'Z'].join();
  }
}
