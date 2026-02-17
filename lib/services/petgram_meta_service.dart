import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../models/petgram_photo_meta.dart';
import '../models/pet_info.dart';
import 'petgram_exif_channel.dart';

/// PetgramPhotoMeta 생성 헬퍼 함수
///
/// 프레임/촬영 정보에서 PetgramPhotoMeta 인스턴스를 생성
PetgramPhotoMeta buildPetgramMeta({
  required String frameKey,
  String? selectedPetId,
  PetInfo? selectedPet,
  String? titleText,
  String? subtitleText,
  String? labelDateText,
  String? location, // 촬영 위치 정보
  DateTime? takenAtOverride,
}) {
  final now = DateTime.now().toUtc();

  // frameMeta 기본 구조
  final Map<String, dynamic> frameMeta = {};

  // 🔥 프레임/칩 저장 문제 해결: 펫 정보를 네이티브에서 사용할 수 있도록 모든 필드 포함
  if (selectedPet != null) {
    frameMeta['petId'] = selectedPet.id;
    frameMeta['petName'] = selectedPet.name; // 펫 이름
    frameMeta['petGender'] = selectedPet.gender ?? ''; // 펫 성별 (없으면 빈 문자열)
    frameMeta['petType'] = selectedPet.type; // 펫 종 (dog/cat)
    frameMeta['petBirthDate'] = selectedPet.birthDate
        .toIso8601String(); // 펫 생년월일 (ISO8601)
    // 🔥 breed 정보 추가 (네이티브에서 종 칩을 그리기 위해)
    if (selectedPet.breed != null && selectedPet.breed!.isNotEmpty) {
      frameMeta['breed'] = selectedPet.breed!.trim();
    }
  } else if (selectedPetId != null) {
    // selectedPetId만 있는 경우 (하위 호환성)
    frameMeta['petId'] = selectedPetId;
  }

  // 위치 정보 추가 (위치정보 활성화되어 있을 경우)
  if (location != null && location.isNotEmpty) {
    frameMeta['location'] = location;
  }

  // 기타 프레임 텍스트 정보 (선택적)
  if (titleText != null && titleText.isNotEmpty) {
    frameMeta['title'] = titleText;
  }
  if (subtitleText != null && subtitleText.isNotEmpty) {
    frameMeta['subtitle'] = subtitleText;
  }
  if (labelDateText != null && labelDateText.isNotEmpty) {
    frameMeta['labelDate'] = labelDateText;
  }

  return PetgramPhotoMeta(
    isPetgramShot: true, // 우리 카메라로 촬영
    isPetgramEdited: true, // 우리 앱에서 편집/보정
    frameKey: frameKey.isEmpty ? 'none' : frameKey,
    takenAt: takenAtOverride ?? now,
    frameMeta: frameMeta,
  );
}

/// JPEG 파일에 EXIF 메타데이터 추가
///
/// [jpegBytes]: 원본 JPEG 바이트
/// [exifTag]: EXIF UserComment에 추가할 메타데이터 문자열
///
/// 반환: EXIF 메타데이터가 추가된 JPEG 바이트
///
/// 네이티브 EXIF API를 통해 실제로 UserComment를 쓴다.
Future<Uint8List> attachPetgramExif({
  required Uint8List jpegBytes,
  required String exifTag,
}) async {
  try {
    final updated = await PetgramExifChannel.writeUserCommentToBytes(
      jpegBytes: jpegBytes,
      comment: exifTag,
    );

    if (kDebugMode) {
      debugPrint(
        '[PetgramMeta] ✅ EXIF UserComment attached via native channel: $exifTag',
      );
    }

    return updated;
  } catch (e, stackTrace) {
    debugPrint('[PetgramMeta] ❌ Failed to attach EXIF via native: $e');
    debugPrint('[PetgramMeta] ❌ Stack trace: $stackTrace');
    // 실패 시 원본 반환
    return jpegBytes;
  }
}

/// JPEG 파일에서 EXIF UserComment 읽기
///
/// [jpegBytes]: JPEG 바이트
///
/// 반환: UserComment 문자열 또는 null (읽기 실패 시)
///
/// 네이티브 EXIF API를 통해 실제로 UserComment를 읽는다.
Future<String?> readUserCommentFromJpeg(Uint8List jpegBytes) async {
  try {
    final comment = await PetgramExifChannel.readUserCommentFromBytes(
      jpegBytes,
    );

    if (kDebugMode) {
      if (comment != null && comment.isNotEmpty) {
        debugPrint(
          '[PetgramMeta] 📖 EXIF UserComment read via native: $comment',
        );
      } else {
        debugPrint('[PetgramMeta] 📖 EXIF UserComment not found or empty');
      }
    }

    return comment;
  } catch (e) {
    if (kDebugMode) {
      debugPrint(
        '[PetgramMeta] ❌ Failed to read EXIF UserComment via native: $e',
      );
    }
    return null;
  }
}

/// 외부 사진 + 필터/보정 저장용 메타데이터 생성
///
/// 규칙:
/// - originalMeta가 있으면 => 최우선으로 사용 (우리 앱에서 촬영한 사진)
///   - originalMeta의 모든 정보를 유지하고, isPetgramEdited만 true로 설정
/// - originalMeta가 null이고, 원본 JPEG의 EXIF UserComment에 PETGRAM 태그가 있으면:
///   - parsePetgramExif()로 복원
///   - isPetgramShot / frameKey / frameMeta 그대로 가져오고
///   - isPetgramEdited는 true로 강제
/// - 모두 없으면 (외부 사진):
///   - isPetgramShot = false
///   - isPetgramEdited = true
///   - frameKey = 'none'
///   - frameMeta = {}
Future<PetgramPhotoMeta> buildMetaForFilterSave({
  required Uint8List originalJpegBytes,
  PetgramPhotoMeta? originalMeta, // 원본 메타데이터 (최우선)
  DateTime? takenAtOverride,
}) async {
  final now = DateTime.now().toUtc();
  final takenAt = takenAtOverride ?? now;

  // 최우선: originalMeta가 있으면 그것을 기반으로 메타 생성
  if (originalMeta != null) {
    if (kDebugMode) {
      debugPrint(
        '[PetgramMeta] ✅ Using originalMeta in buildMetaForFilterSave: ${originalMeta.frameMeta}',
      );
      debugPrint(
        '[PetgramMeta] ✅ petName: ${originalMeta.frameMeta['petName']}, location: ${originalMeta.frameMeta['location']}',
      );
    }
    // originalMeta의 모든 정보를 유지하고, isPetgramEdited만 true로 설정
    return originalMeta.copyWith(
      isPetgramEdited: true, // 편집 표시
      takenAt: takenAt, // 저장 시각 업데이트
    );
  }

  // originalMeta가 없으면 EXIF에서 읽기 시도
  if (kDebugMode) {
    debugPrint('[PetgramMeta] 🔍 originalMeta is null, reading from EXIF...');
  }

  final String? userComment = await readUserCommentFromJpeg(originalJpegBytes);

  if (kDebugMode) {
    debugPrint(
      '[PetgramMeta] 🔍 readUserCommentFromJpeg result: ${userComment?.substring(0, userComment.length > 100 ? 100 : userComment.length)}...',
    );
  }

  PetgramPhotoMeta? fromExif;

  if (userComment != null) {
    fromExif = parsePetgramExif(userComment);
  }

  if (fromExif != null) {
    // 원래 Petgram 사진을 다시 보정하는 경우:
    // shot/frame/frameMeta 유지, edited만 true로
    if (kDebugMode) {
      debugPrint(
        '[PetgramMeta] 🔄 Found existing Petgram metadata in EXIF, preserving shot/frame/meta',
      );
      debugPrint(
        '[PetgramMeta] 🔄 parsed from EXIF in buildMetaForFilterSave: ${fromExif.frameMeta}',
      );
      debugPrint(
        '[PetgramMeta] 🔄 petName: ${fromExif.frameMeta['petName']}, location: ${fromExif.frameMeta['location']}',
      );
    }
    return PetgramPhotoMeta(
      isPetgramShot: fromExif.isPetgramShot,
      isPetgramEdited: true, // 편집 표시
      frameKey: fromExif.frameKey,
      takenAt: takenAt,
      frameMeta: fromExif.frameMeta, // frameMeta 그대로 유지 (petName, location 포함)
    );
  }

  // 외부 사진 + 우리 앱에서만 보정한 경우:
  // "우리 편집본" 정도의 정보만 남긴다
  if (kDebugMode) {
    debugPrint(
      '[PetgramMeta] 📷 External photo edited by Petgram, creating minimal metadata',
    );
  }
  return PetgramPhotoMeta(
    isPetgramShot: false, // 외부 사진
    isPetgramEdited: true, // 우리 앱에서 편집
    frameKey: 'none',
    takenAt: takenAt,
    frameMeta: {}, // 프레임/펫 정보 없음
  );
}

/// EXIF UserComment에서 Petgram 메타데이터 파싱
///
/// [exifTag]: EXIF UserComment에서 읽은 문자열
///
/// 반환: PetgramPhotoMeta 또는 null (파싱 실패 시)
PetgramPhotoMeta? parsePetgramExif(String exifTag) {
  try {
    if (!exifTag.startsWith('PETGRAM|')) {
      return null;
    }

    // PETGRAM|v=1|shot=1|edited=1|frame=birthday_pink|ts=1234567890|meta={"petId":"123"}
    final parts = exifTag.split('|');

    String? frameKey;
    int? timestamp;
    Map<String, dynamic>? frameMeta;
    bool isShot = true; // default (하위 호환용)
    bool isEdited = false; // default

    for (final part in parts) {
      if (part.startsWith('shot=')) {
        final v = part.substring(5);
        isShot = v == '1';
      } else if (part.startsWith('edited=')) {
        final v = part.substring(7);
        isEdited = v == '1';
      } else if (part.startsWith('frame=')) {
        frameKey = part.substring(6);
      } else if (part.startsWith('ts=')) {
        timestamp = int.tryParse(part.substring(3));
      } else if (part.startsWith('meta64=')) {
        // Base64Url 디코딩 → UTF-8 → JSON 파싱 (한글 깨짐 방지)
        // meta64가 있으면 우선 사용 (frameMeta가 이미 설정되지 않았을 때만)
        if (frameMeta == null) {
          final meta64 = part.substring(7);
          try {
            final decoded = utf8.decode(base64Url.decode(meta64));
            frameMeta = jsonDecode(decoded) as Map<String, dynamic>;
            if (kDebugMode) {
              debugPrint(
                '[PetgramMeta] ✅ Successfully decoded meta64 (Base64Url)',
              );
            }
          } catch (e) {
            debugPrint('[PetgramMeta] ❌ meta64 decode failed: $e');
          }
        }
      } else if (part.startsWith('meta=')) {
        // 하위 호환: 기존 meta= 필드 (이미 한글이 깨진 경우 복원 불가)
        // meta64가 없을 때만 사용 (frameMeta가 이미 설정되지 않았을 때만)
        if (frameMeta == null) {
          final metaJson = part.substring(5);
          try {
            frameMeta = jsonDecode(metaJson) as Map<String, dynamic>;
            if (kDebugMode) {
              debugPrint(
                '[PetgramMeta] ⚠️ Using legacy meta= field (may have broken Korean characters)',
              );
            }
          } catch (e) {
            debugPrint('[PetgramMeta] ⚠️ meta JSON parse failed: $e');
          }
        }
      }
    }

    if (frameKey == null || timestamp == null) {
      return null;
    }

    return PetgramPhotoMeta(
      isPetgramShot: isShot,
      isPetgramEdited: isEdited,
      frameKey: frameKey,
      takenAt: DateTime.fromMillisecondsSinceEpoch(
        timestamp * 1000,
        isUtc: true,
      ),
      frameMeta: frameMeta ?? {},
    );
  } catch (e) {
    debugPrint('[PetgramMeta] ❌ Failed to parse EXIF tag: $e');
    return null;
  }
}
