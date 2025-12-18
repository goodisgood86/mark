import 'petgram_photo_meta.dart';

/// 촬영 로그 레코드 (로컬 DB 저장용)
/// 
/// 향후 다이어리 기능에서 재사용할 수 있도록
/// 메타데이터와 실제 파일 경로를 함께 보관
class ShootLog {
  /// 고유 ID (UUID)
  final String id;

  /// 최종 저장 파일 경로 또는 contentUri
  final String filePath;

  /// Petgram 사진 메타데이터
  final PetgramPhotoMeta meta;

  const ShootLog({
    required this.id,
    required this.filePath,
    required this.meta,
  });

  /// Map으로 변환 (sqflite/Hive 등에 저장하기 용이)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'filePath': filePath,
      ...meta.toMap(),
    };
  }

  /// Map에서 생성
  factory ShootLog.fromMap(Map<String, dynamic> map) {
    return ShootLog(
      id: map['id'] as String,
      filePath: map['filePath'] as String,
      meta: PetgramPhotoMeta.fromMap(map),
    );
  }
}

