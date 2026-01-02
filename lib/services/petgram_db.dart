import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// Petgram SQLite 데이터베이스 싱글톤
///
/// 앱 전체에서 하나의 데이터베이스 인스턴스만 사용
class PetgramDatabase {
  PetgramDatabase._internal();

  static final PetgramDatabase instance = PetgramDatabase._internal();

  Database? _db;

  /// 데이터베이스 인스턴스 가져오기
  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  /// 데이터베이스 초기화
  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'petgram.db');

    if (kDebugMode) {
      debugPrint('[PetgramDB] 📁 Database path: $dbPath');
    }

    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE petgram_photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            is_petgram_shot INTEGER NOT NULL,
            is_petgram_edited INTEGER NOT NULL,
            frame_key TEXT NOT NULL,
            taken_at INTEGER NOT NULL,
            meta_json TEXT NOT NULL,
            exif_tag TEXT
          );
        ''');
        
        // 인덱스 추가 (조회 성능 향상)
        await db.execute('''
          CREATE INDEX idx_file_path ON petgram_photos(file_path);
        ''');
        
        await db.execute('''
          CREATE INDEX idx_taken_at ON petgram_photos(taken_at DESC);
        ''');
        
        if (kDebugMode) {
          debugPrint('[PetgramDB] ✅ Database initialized with petgram_photos table');
        }
      },
    );
  }

  /// 데이터베이스 닫기 (앱 종료 시 호출)
  Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
      if (kDebugMode) {
        debugPrint('[PetgramDB] 🔒 Database closed');
      }
    }
  }

  /// 데이터베이스 상태 확인 (디버그용)
  ///
  /// 테이블 존재 여부, 스키마, 레코드 개수 등을 확인
  Future<Map<String, dynamic>> checkDatabaseStatus() async {
    final db = await database;
    final status = <String, dynamic>{};

    try {
      // 1. 테이블 존재 여부 확인
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='petgram_photos';",
      );
      status['table_exists'] = tables.isNotEmpty;

      if (tables.isNotEmpty) {
        // 2. 테이블 스키마 확인
        final schema = await db.rawQuery(
          "PRAGMA table_info(petgram_photos);",
        );
        status['schema'] = schema;

        // 3. 레코드 개수 확인
        final countResult = await db.rawQuery(
          "SELECT COUNT(*) as count FROM petgram_photos;",
        );
        status['record_count'] = countResult.first['count'] as int;

        // 4. 인덱스 확인
        final indexes = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='petgram_photos';",
        );
        status['indexes'] = indexes.map((idx) => idx['name'] as String).toList();

        // 5. 최근 레코드 샘플 (최대 3개)
        final recent = await db.query(
          'petgram_photos',
          orderBy: 'created_at DESC',
          limit: 3,
        );
        status['recent_records'] = recent.length;
        status['recent_samples'] = recent.map((r) => {
          'id': r['id'],
          'file_path': r['file_path'],
          'frame_key': r['frame_key'],
          'created_at': r['created_at'],
        }).toList();
      }

      // 6. 데이터베이스 파일 경로
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, 'petgram.db');
      status['db_path'] = dbPath;
      status['db_version'] = 1; // 현재 DB 버전

      if (kDebugMode) {
        debugPrint('[PetgramDB] 🔍 Database Status Check:');
        debugPrint('[PetgramDB]   ✅ Table exists: ${status['table_exists']}');
        debugPrint('[PetgramDB]   📊 Record count: ${status['record_count'] ?? 0}');
        debugPrint('[PetgramDB]   📁 DB path: ${status['db_path']}');
        debugPrint('[PetgramDB]   🔢 DB version: ${status['db_version']}');
        if (status['indexes'] != null) {
          debugPrint('[PetgramDB]   📑 Indexes: ${status['indexes']}');
        }
        if (status['recent_records'] != null && status['recent_records'] > 0) {
          debugPrint('[PetgramDB]   📸 Recent records: ${status['recent_records']}');
        }
      }
    } catch (e, stackTrace) {
      status['error'] = e.toString();
      status['stack_trace'] = stackTrace.toString();
      if (kDebugMode) {
        debugPrint('[PetgramDB] ❌ Error checking database status: $e');
        debugPrint('[PetgramDB] ❌ Stack trace: $stackTrace');
      }
    }

    return status;
  }
}

