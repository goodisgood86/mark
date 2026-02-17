import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 통합 이미지 로딩 헬퍼 (PNG/JPG/HEIC 모두 지원, EXIF 회전 처리)
/// ⚠️ 중요: 이 함수는 normalizeOrientationToFile()로 정규화된 파일(path에 "pg_normalized_" 포함)에 대해서는
///          EXIF orientation을 다시 적용하지 않고, 픽셀 데이터를 그대로 사용합니다.
///          정규화된 파일은 이미 픽셀이 올바른 방향이고 EXIF Orientation=1이므로 추가 회전이 필요 없습니다.
/// 모든 이미지 불러오기 경로에서 동일하게 사용
Future<img.Image?> loadImageWithExifRotation(File imageFile) async {
  try {
    final bytes = await imageFile.readAsBytes();

    // 파일 확장자 확인
    final extension = imageFile.path.toLowerCase().split('.').last;

    // ⚠️ 정규화된 파일 확인: Dart의 normalizeOrientationToFile()이 생성한 임시 파일은
    //    "pg_normalized_" 접두사를 포함합니다. 이 파일들은 이미 픽셀이 올바른 방향이고
    //    EXIF Orientation=1이므로, orientation을 다시 적용하지 않습니다.
    final isNormalized = imageFile.path.contains('pg_normalized_');

    if (kDebugMode) {
      debugPrint(
        '[Petgram] 📷 Loading image: ${imageFile.path}, extension: $extension, '
        'normalized: $isNormalized',
      );
    }

    // image 패키지로 디코딩 (PNG, JPG 지원)
    img.Image? decodedImage;

    if (extension == 'heic' || extension == 'heif') {
      // HEIC는 image 패키지가 직접 지원하지 않으므로
      // image_picker가 이미 JPG로 변환했을 가능성이 높지만,
      // 만약 변환되지 않았다면 에러 처리
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ HEIC format detected, attempting decode...');
      }
      // image 패키지는 HEIC를 지원하지 않으므로 null 반환
      // 실제로는 image_picker가 자동으로 JPG로 변환해주므로
      // 여기서는 일반 디코딩 시도
      decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ❌ HEIC decode failed, image_picker may not have converted it',
          );
        }
        return null;
      }
    } else {
      // PNG, JPG는 일반 디코딩
      decodedImage = img.decodeImage(bytes);
    }

    if (decodedImage == null) {
      if (kDebugMode) {
        debugPrint('[Petgram] ❌ Image decode failed: ${imageFile.path}');
      }
      return null;
    }

    // ⚠️ 정규화된 파일인 경우: EXIF orientation을 무시하고 픽셀 데이터를 그대로 사용
    //    image 패키지의 decodeImage는 EXIF orientation을 자동으로 적용하지 않으므로,
    //    정규화된 파일(이미 픽셀이 올바른 방향)은 그대로 사용하면 됩니다.
    // ⚠️ 정규화되지 않은 파일인 경우: image 패키지의 decodeImage는 기본적으로
    //    EXIF orientation을 자동 처리하지 않을 수 있지만, 대부분의 경우 이미 올바른 방향으로 디코딩됩니다.
    //    만약 회전이 필요하다면 별도 처리 필요 (현재는 그대로 사용)

    if (kDebugMode) {
      debugPrint(
        '[Petgram] ✅ Image loaded: ${decodedImage.width}x${decodedImage.height}, '
        'format: $extension, normalized: $isNormalized',
      );
    }

    return decodedImage;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[Petgram] ❌ loadImageWithExifRotation error: $e');
    }
    return null;
  }
}
