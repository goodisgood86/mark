import 'dart:convert';
import 'petgram_photo_meta.dart';

/// Petgram 사진 DB 레코드 모델
///
/// 로컬 SQLite 데이터베이스에 저장되는 사진 메타데이터 레코드
class PetgramPhotoRecord {
  /// 레코드 ID (DB primary key)
  final int? id;

  /// 실제 저장된 JPEG 파일의 경로
  final String filePath;

  /// 레코드 생성 시각 (UTC)
  final DateTime createdAt;

  /// 마지막 수정 시각 (UTC)
  final DateTime updatedAt;

  /// PetgramPhotoMeta (메타데이터)
  final PetgramPhotoMeta meta;

  /// EXIF UserComment에 쓴 전체 Petgram 태그 문자열
  final String? exifTag;

  PetgramPhotoRecord({
    this.id,
    required this.filePath,
    required this.createdAt,
    required this.updatedAt,
    required this.meta,
    this.exifTag,
  });

  /// DB 저장용 Map으로 변환
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'file_path': filePath,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
      'is_petgram_shot': meta.isPetgramShot ? 1 : 0,
      'is_petgram_edited': meta.isPetgramEdited ? 1 : 0,
      'frame_key': meta.frameKey,
      'taken_at': meta.takenAt.millisecondsSinceEpoch,
      'meta_json': jsonEncode(meta.frameMeta),
      'exif_tag': exifTag,
    };
  }

  /// DB Map에서 PetgramPhotoRecord 생성
  factory PetgramPhotoRecord.fromMap(Map<String, dynamic> map) {
    final frameMeta = jsonDecode(map['meta_json'] as String) as Map<String, dynamic>;
    
    final meta = PetgramPhotoMeta(
      isPetgramShot: (map['is_petgram_shot'] as int) == 1,
      isPetgramEdited: (map['is_petgram_edited'] as int) == 1,
      frameKey: map['frame_key'] as String,
      takenAt: DateTime.fromMillisecondsSinceEpoch(
        map['taken_at'] as int,
        isUtc: true,
      ),
      frameMeta: frameMeta,
    );

    return PetgramPhotoRecord(
      id: map['id'] as int?,
      filePath: map['file_path'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int,
        isUtc: true,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        map['updated_at'] as int,
        isUtc: true,
      ),
      meta: meta,
      exifTag: map['exif_tag'] as String?,
    );
  }

  /// copyWith 메서드
  PetgramPhotoRecord copyWith({
    int? id,
    String? filePath,
    DateTime? createdAt,
    DateTime? updatedAt,
    PetgramPhotoMeta? meta,
    String? exifTag,
  }) {
    return PetgramPhotoRecord(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      meta: meta ?? this.meta,
      exifTag: exifTag ?? this.exifTag,
    );
  }
}

