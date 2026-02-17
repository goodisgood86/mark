import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';
import 'petgram_db.dart';
import '../models/petgram_photo_record.dart';
import '../models/petgram_photo_meta.dart';

/// Petgram 사진 메타데이터 Repository
///
/// 로컬 SQLite 데이터베이스에 PetgramPhotoRecord를 저장/조회하는 역할
class PetgramPhotoRepository {
  PetgramPhotoRepository._internal();

  static final PetgramPhotoRepository instance =
      PetgramPhotoRepository._internal();

  /// 사진 레코드 저장 또는 업데이트 (upsert)
  ///
  /// [filePath]: 실제 저장된 JPEG 파일의 경로
  /// [meta]: PetgramPhotoMeta 메타데이터
  /// [exifTag]: EXIF UserComment에 쓴 전체 Petgram 태그 문자열
  ///
  /// 반환: 저장/업데이트된 레코드의 rowId
  ///
  /// file_path 기준으로 존재 여부 체크:
  /// - 있으면 UPDATE (updated_at 갱신)
  /// - 없으면 INSERT (created_at, updated_at 세팅)
  Future<int> upsertPhotoRecord({
    required String filePath,
    required PetgramPhotoMeta meta,
    String? exifTag,
  }) async {
    try {
      final db = await PetgramDatabase.instance.database;
      final now = DateTime.now().toUtc();

      // 이미 있는지 확인
      final existing = await db.query(
        'petgram_photos',
        where: 'file_path = ?',
        whereArgs: [filePath],
        limit: 1,
      );

      final record = PetgramPhotoRecord(
        id: existing.isNotEmpty ? existing.first['id'] as int? : null,
        filePath: filePath,
        createdAt: existing.isNotEmpty
            ? DateTime.fromMillisecondsSinceEpoch(
                existing.first['created_at'] as int,
                isUtc: true,
              )
            : now,
        updatedAt: now,
        meta: meta,
        exifTag: exifTag,
      );

      if (existing.isNotEmpty) {
        // UPDATE
        await db.update(
          'petgram_photos',
          record.toMap(),
          where: 'id = ?',
          whereArgs: [record.id],
        );

        if (kDebugMode) {
          debugPrint(
            '[PetgramDB] ✅ Updated photo record: $filePath (id: ${record.id})',
          );
        }

        return record.id ?? 0;
      } else {
        // INSERT
        final rowId = await db.insert(
          'petgram_photos',
          record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        if (kDebugMode) {
          debugPrint(
            '[PetgramDB] ✅ Inserted photo record: $filePath (rowId: $rowId)',
          );
        }

        return rowId;
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Failed to upsert photo record: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      rethrow;
    }
  }

  /// 파일 경로로 사진 레코드 조회
  ///
  /// [filePath]: 조회할 파일 경로
  ///
  /// 반환: PetgramPhotoRecord 또는 null (없으면)
  Future<PetgramPhotoRecord?> getByFilePath(String filePath) async {
    try {
      final db = await PetgramDatabase.instance.database;
      final rows = await db.query(
        'petgram_photos',
        where: 'file_path = ?',
        whereArgs: [filePath],
        limit: 1,
      );

      if (rows.isEmpty) {
        if (kDebugMode) {
          debugPrint('[PetgramDB] 📖 No record found for filePath: $filePath');
        }
        return null;
      }

      final record = PetgramPhotoRecord.fromMap(rows.first);

      if (kDebugMode) {
        debugPrint('[PetgramDB] 📖 Found record for filePath: $filePath');
      }

      return record;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Failed to get photo record by filePath: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      return null;
    }
  }

  /// 파일명에서 PG_ 식별자를 추출하여 사진 레코드 조회
  ///
  /// [fileName]: 조회할 파일명 (예: "PG_1234567890.jpg", "image_picker_ABC123_PG_1234567890.jpg")
  ///
  /// 반환: PetgramPhotoRecord 또는 null (없으면)
  ///
  /// 동작:
  /// 1. 파일명에서 "PG_"로 시작하는 부분을 찾아 추출
  /// 2. 추출된 식별자로 DB 조회 (LIKE 쿼리 사용)
  Future<PetgramPhotoRecord?> getByFileNamePattern(String fileName) async {
    try {
      // 파일명에서 PG_ 식별자 추출
      final pgPattern = RegExp(r'PG_(\d+)\.(jpg|jpeg|JPG|JPEG)');
      final match = pgPattern.firstMatch(fileName);

      if (match == null) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramDB] 📖 No PG_ pattern found in fileName: $fileName',
          );
        }
        return null;
      }

      final pgIdentifier = match.group(0); // "PG_1234567890.jpg"
      final pgBase = match.group(1); // "1234567890"

      if (kDebugMode) {
        debugPrint(
          '[PetgramDB] 📖 Extracted PG identifier: $pgIdentifier (base: $pgBase) from fileName: $fileName',
        );
      }

      final db = await PetgramDatabase.instance.database;

      // LIKE 쿼리로 PG_ 식별자가 포함된 레코드 조회
      // 예: "PG_1234567890.jpg" 또는 "PG_1234567890.jpeg" 등
      final rows = await db.query(
        'petgram_photos',
        where: 'file_path LIKE ?',
        whereArgs: ['%PG_$pgBase.%'],
        limit: 1,
      );

      if (rows.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramDB] 📖 No record found for PG pattern: PG_$pgBase.%',
          );
        }
        return null;
      }

      final record = PetgramPhotoRecord.fromMap(rows.first);

      if (kDebugMode) {
        debugPrint(
          '[PetgramDB] 📖 Found record for PG pattern: PG_$pgBase.% (filePath: ${record.filePath})',
        );
      }

      return record;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[PetgramDB] ❌ Failed to get photo record by fileName pattern: $e',
        );
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      return null;
    }
  }

  /// 최근 저장된 사진 레코드 목록 조회
  ///
  /// [limit]: 조회할 최대 개수 (기본값: 100)
  ///
  /// 반환: 최근 저장된 순서대로 정렬된 PetgramPhotoRecord 목록
  Future<List<PetgramPhotoRecord>> listRecent({int limit = 100}) async {
    try {
      final db = await PetgramDatabase.instance.database;
      final rows = await db.query(
        'petgram_photos',
        orderBy: 'created_at DESC',
        limit: limit,
      );

      final records = rows
          .map((row) => PetgramPhotoRecord.fromMap(row))
          .toList();

      if (kDebugMode) {
        debugPrint(
          '[PetgramDB] 📖 List recent records: ${records.length} items',
        );
      }

      return records;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Failed to list recent records: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      return [];
    }
  }

  /// 다이어리 표시용 최근 사진 레코드 조회
  ///
  /// [limit]: 조회할 최대 개수 (기본값: 200)
  /// [petgramOnly]: true면 Petgram 촬영/편집본만 조회
  ///
  /// 반환: taken_at 최신순(동률 시 created_at 최신순) 정렬 결과
  Future<List<PetgramPhotoRecord>> listForDiary({
    int limit = 200,
    int offset = 0,
    bool petgramOnly = true,
  }) async {
    try {
      final db = await PetgramDatabase.instance.database;
      final rows = await db.query(
        'petgram_photos',
        where: petgramOnly
            ? '''
              (
                is_petgram_shot = 1
                OR is_petgram_edited = 1
                OR exif_tag LIKE 'PETGRAM|%'
              )
              '''
            : null,
        orderBy: 'taken_at DESC, created_at DESC',
        limit: limit,
        offset: offset,
      );

      final records = rows
          .map((row) => PetgramPhotoRecord.fromMap(row))
          .toList();

      if (kDebugMode) {
        debugPrint(
          '[PetgramDB] 📖 List diary records: ${records.length} items',
        );
      }

      return records;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Failed to list diary records: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      return [];
    }
  }

  /// 레코드 삭제
  ///
  /// [filePath]: 삭제할 파일 경로
  ///
  /// 반환: 삭제된 레코드 수
  Future<int> deleteByFilePath(String filePath) async {
    try {
      final db = await PetgramDatabase.instance.database;
      final count = await db.delete(
        'petgram_photos',
        where: 'file_path = ?',
        whereArgs: [filePath],
      );

      if (kDebugMode) {
        debugPrint(
          '[PetgramDB] 🗑️ Deleted $count record(s) for filePath: $filePath',
        );
      }

      return count;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Failed to delete record: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      return 0;
    }
  }

  /// 레코드의 file_path를 갱신 (마이그레이션 용도)
  Future<bool> updateFilePathById({
    required int id,
    required String filePath,
  }) async {
    try {
      final db = await PetgramDatabase.instance.database;
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      final count = await db.update(
        'petgram_photos',
        {'file_path': filePath, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      return count > 0;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Failed to update file_path by id: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
      return false;
    }
  }
}
