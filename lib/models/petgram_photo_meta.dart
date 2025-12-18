import 'dart:convert';

/// Petgram 사진 메타데이터 모델
/// 
/// 촬영/보정하여 저장되는 모든 최종 이미지에 포함되는 메타데이터
class PetgramPhotoMeta {
  /// 우리 카메라로 촬영한 사진인지 여부
  final bool isPetgramShot;

  /// 우리 앱에서 편집/보정된 결과인지 여부
  final bool isPetgramEdited;

  /// 어떤 프레임을 적용했는지 (없으면 'none')
  final String frameKey;

  /// 촬영/저장 기준 시각 (UTC)
  final DateTime takenAt;

  /// 프레임 내부에 채워진 동적 정보(petId, 텍스트, 날짜 등)
  final Map<String, dynamic> frameMeta;

  const PetgramPhotoMeta({
    required this.isPetgramShot,
    required this.isPetgramEdited,
    required this.frameKey,
    required this.takenAt,
    required this.frameMeta,
  });

  /// frameMeta를 JSON 문자열로 직렬화
  String get frameMetaJson => jsonEncode(frameMeta);

  /// EXIF UserComment 등에 쓸 단일 문자열 포맷
  /// 
  /// 포맷: PETGRAM|v=1|shot={0|1}|edited={0|1}|frame={frameKey}|ts={unix_timestamp}|meta64={base64Url}
  /// 
  /// meta64는 JSON을 UTF-8 → Base64Url로 인코딩한 값 (한글 깨짐 방지)
  /// 
  /// ⚠️ 주의: EXIF 크기 제한을 피하기 위해 iconBase64는 제외됨 (DB에만 저장)
  String toExifTag() {
    final ts = takenAt.millisecondsSinceEpoch ~/ 1000; // Unix timestamp
    
    // 🔥 EXIF 크기 제한을 피하기 위해 iconBase64 제거
    final metaForExif = Map<String, dynamic>.from(frameMeta);
    if (metaForExif.containsKey('overlayConfig')) {
      final overlayConfig = Map<String, dynamic>.from(metaForExif['overlayConfig'] as Map);
      // overlayConfig의 각 chip에서 iconBase64 제거
      if (overlayConfig.containsKey('topChips')) {
        final topChips = (overlayConfig['topChips'] as List).map((chip) {
          final chipMap = Map<String, dynamic>.from(chip as Map);
          chipMap.remove('iconBase64'); // iconBase64 제거
          return chipMap;
        }).toList();
        overlayConfig['topChips'] = topChips;
      }
      if (overlayConfig.containsKey('bottomChips')) {
        final bottomChips = (overlayConfig['bottomChips'] as List).map((chip) {
          final chipMap = Map<String, dynamic>.from(chip as Map);
          chipMap.remove('iconBase64'); // iconBase64 제거
          return chipMap;
        }).toList();
        overlayConfig['bottomChips'] = bottomChips;
      }
      metaForExif['overlayConfig'] = overlayConfig;
    }
    
    final metaJson = jsonEncode(metaForExif);
    
    // JSON → UTF-8 → Base64Url 인코딩 (한글 깨짐 방지)
    final metaBase64 = base64Url.encode(utf8.encode(metaJson));
    
    return 'PETGRAM'
        '|v=1'
        '|shot=${isPetgramShot ? 1 : 0}'
        '|edited=${isPetgramEdited ? 1 : 0}'
        '|frame=$frameKey'
        '|ts=$ts'
        '|meta64=$metaBase64';
  }

  /// 파일명에 사용할 안전한 문자열 (옵션)
  /// 
  /// 포맷: {unix_timestamp}_{frameKey}
  String toFileNameSuffix() {
    final ts = takenAt.millisecondsSinceEpoch ~/ 1000;
    // 파일명에 사용할 수 없는 문자 제거
    final safeFrameKey = frameKey.replaceAll(RegExp(r'[^\w-]'), '_');
    return '${ts}_$safeFrameKey';
  }

  /// Map으로 변환 (로컬 DB 저장용)
  Map<String, dynamic> toMap() {
    return {
      'isPetgramShot': isPetgramShot ? 1 : 0,
      'isPetgramEdited': isPetgramEdited ? 1 : 0,
      'frameKey': frameKey,
      'takenAt': takenAt.toIso8601String(),
      'frameMetaJson': frameMetaJson,
      'exifTag': toExifTag(),
    };
  }

  /// Map에서 생성
  factory PetgramPhotoMeta.fromMap(Map<String, dynamic> map) {
    return PetgramPhotoMeta(
      isPetgramShot: (map['isPetgramShot'] as int? ?? 0) == 1,
      isPetgramEdited: (map['isPetgramEdited'] as int? ?? 0) == 1,
      frameKey: map['frameKey'] as String? ?? 'none',
      takenAt: DateTime.parse(map['takenAt'] as String),
      frameMeta: jsonDecode(map['frameMetaJson'] as String? ?? '{}') as Map<String, dynamic>,
    );
  }

  /// copyWith 메서드 - 일부 필드만 변경하여 새로운 인스턴스 생성
  PetgramPhotoMeta copyWith({
    bool? isPetgramShot,
    bool? isPetgramEdited,
    String? frameKey,
    DateTime? takenAt,
    Map<String, dynamic>? frameMeta,
  }) {
    return PetgramPhotoMeta(
      isPetgramShot: isPetgramShot ?? this.isPetgramShot,
      isPetgramEdited: isPetgramEdited ?? this.isPetgramEdited,
      frameKey: frameKey ?? this.frameKey,
      takenAt: takenAt ?? this.takenAt,
      frameMeta: frameMeta ?? this.frameMeta,
    );
  }
}

