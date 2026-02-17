import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// 이미지 EXIF Orientation 정규화 유틸리티
///
/// 아이폰 카메라로 촬영한 사진의 EXIF Orientation 값을 읽어서
/// 이미지를 정방향(upright)으로 회전시킨 후 저장합니다.
class PetgramImageOrientation {
  /// 이미지 파일의 EXIF Orientation을 읽어서 정규화된 이미지 바이트를 반환
  ///
  /// [filePath]: 원본 이미지 파일 경로
  ///
  /// Returns: 정규화된 JPEG 바이트 (EXIF Orientation = 1로 설정됨)
  static Future<Uint8List> normalizeOrientation(String filePath) async {
    try {
      if (kDebugMode) {
        debugPrint(
          '[PetgramImageOrientation] 📐 Normalizing orientation: $filePath',
        );
      }

      final file = File(filePath);
      if (!await file.exists()) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ⚠️ File does not exist: $filePath',
          );
        }
        // 파일이 없으면 빈 바이트 반환 (에러 방지)
        return Uint8List(0);
      }

      Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[PetgramImageOrientation] ⚠️ Failed to read file: $e');
        }
        // 파일 읽기 실패 시 빈 바이트 반환
        return Uint8List(0);
      }

      // 빈 바이트 체크
      if (bytes.isEmpty) {
        if (kDebugMode) {
          debugPrint('[PetgramImageOrientation] ⚠️ File is empty: $filePath');
        }
        return bytes;
      }

      // 1) EXIF 읽기
      Map<String, IfdTag> tags = {};
      try {
        tags = await readExifFromBytes(bytes);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[PetgramImageOrientation] ⚠️ Failed to read EXIF: $e');
        }
        // EXIF 읽기 실패 시 원본 반환
        return bytes;
      }

      // 2) Orientation 값 추출
      int orientation = 1; // 기본값: 정방향
      final orientationTag = tags['Image Orientation'] ?? tags['Orientation'];
      if (orientationTag != null) {
        try {
          // exif 패키지의 IfdTag는 values 속성으로 값에 접근
          // values를 리스트로 변환하여 첫 번째 값 추출
          final valueList = orientationTag.values.toList();
          if (valueList.isNotEmpty) {
            final value = valueList.first;
            if (value is int) {
              orientation = value;
            } else if (value is String) {
              orientation = int.tryParse(value) ?? 1;
            }
          }
        } catch (e) {
          // 값 추출 실패 시 기본값 사용
          if (kDebugMode) {
            debugPrint(
              '[PetgramImageOrientation] ⚠️ Failed to parse orientation: $e',
            );
          }
        }
      }

      if (kDebugMode) {
        debugPrint(
          '[PetgramImageOrientation] 📐 EXIF Orientation: $orientation',
        );
      }

      // Orientation이 1이면 회전 불필요
      if (orientation == 1) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ✅ Already upright, no rotation needed',
          );
        }
        return bytes;
      }

      // 3) image 패키지로 디코딩
      final img.Image? raw = img.decodeImage(bytes);
      if (raw == null) {
        if (kDebugMode) {
          debugPrint('[PetgramImageOrientation] ⚠️ Failed to decode image');
        }
        return bytes;
      }

      final originalWidth = raw.width;
      final originalHeight = raw.height;

      if (kDebugMode) {
        debugPrint(
          '[PetgramImageOrientation] 📐 Original size: ${originalWidth}x$originalHeight',
        );
      }

      // 4) EXIF orientation에 따라 회전/반전
      img.Image fixed = raw;
      switch (orientation) {
        case 2: // 좌우 반전
          fixed = img.flipHorizontal(raw);
          break;
        case 3: // 180도 회전
          fixed = img.copyRotate(raw, angle: 180);
          break;
        case 4: // 상하 반전
          fixed = img.flipVertical(raw);
          break;
        case 5: // 90도 CW + 좌우 반전
          fixed = img.copyRotate(raw, angle: 90);
          fixed = img.flipHorizontal(fixed);
          break;
        case 6: // 90도 CW
          fixed = img.copyRotate(raw, angle: 90);
          break;
        case 7: // 90도 CCW + 좌우 반전
          fixed = img.copyRotate(raw, angle: -90);
          fixed = img.flipHorizontal(fixed);
          break;
        case 8: // 90도 CCW
          fixed = img.copyRotate(raw, angle: -90);
          break;
        default:
          // 1 또는 알 수 없는 값은 그대로
          fixed = raw;
          break;
      }

      final fixedWidth = fixed.width;
      final fixedHeight = fixed.height;

      if (kDebugMode) {
        debugPrint(
          '[PetgramImageOrientation] 📐 Fixed size: ${fixedWidth}x$fixedHeight',
        );
        debugPrint(
          '[PetgramImageOrientation] 📐 Ratio: ${fixedWidth / fixedHeight}',
        );
      }

      // 5) JPEG로 인코딩 (Orientation = 1로 저장됨, 예외 처리 강화)
      // ⚠️ 중요: img.encodeJpg()는 EXIF 메타데이터를 포함하지 않으므로,
      //          새로 인코딩된 JPEG는 자동으로 Orientation=1 상태가 됩니다.
      //          이후 파이프라인(iOS 네이티브, loadImageWithExifRotation 등)에서
      //          EXIF orientation을 다시 해석하지 않도록 보장합니다.
      //          normalizeOrientationToFile()로 저장된 파일은 "pg_normalized_" 접두사를 포함하므로,
      //          iOS 네이티브와 Dart 측에서 이를 확인하여 orientation을 재적용하지 않습니다.
      Uint8List fixedBytes;
      try {
        // 고해상도 이미지 처리: 메모리 부족 방지를 위해 품질 조정
        final int totalPixels = fixedWidth * fixedHeight;
        final int highResThreshold = 4000 * 3000; // 12MP
        final int quality = totalPixels > highResThreshold ? 90 : 95;

        if (kDebugMode && totalPixels > highResThreshold) {
          debugPrint(
            '[PetgramImageOrientation] 📐 High-resolution image detected: '
            '${fixedWidth}x$fixedHeight ($totalPixels pixels), using quality=$quality',
          );
        }

        final encodedBytes = img.encodeJpg(fixed, quality: quality);
        if (encodedBytes.isEmpty) {
          if (kDebugMode) {
            debugPrint('[PetgramImageOrientation] ⚠️ Encoded bytes is empty');
          }
          return bytes; // 원본 바이트 반환
        }
        fixedBytes = Uint8List.fromList(encodedBytes);

        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ✅ JPEG encoded: ${fixedBytes.length} bytes '
            '(${fixedWidth}x$fixedHeight, quality=$quality, orientation=1)',
          );
        }
      } catch (e, stackTrace) {
        if (kDebugMode) {
          debugPrint('[PetgramImageOrientation] ⚠️ JPEG encoding error: $e');
          debugPrint('[PetgramImageOrientation] Stack trace: $stackTrace');
        }
        // 인코딩 실패 시 원본 바이트 반환
        return bytes;
      }

      if (kDebugMode) {
        debugPrint(
          '[PetgramImageOrientation] ✅ Normalized: ${fixedBytes.length} bytes',
        );
      }

      return fixedBytes;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramImageOrientation] ❌ Error: $e');
        debugPrint('[PetgramImageOrientation] Stack trace: $stackTrace');
      }
      // 에러 발생 시 원본 바이트 반환 (예외 처리 강화)
      try {
        final file = File(filePath);
        if (await file.exists()) {
          final originalBytes = await file.readAsBytes();
          if (originalBytes.isNotEmpty) {
            return originalBytes;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ⚠️ Failed to read original file: $e',
          );
        }
      }
      // 모든 시도 실패 시 빈 바이트 반환 (절대 throw하지 않음)
      return Uint8List(0);
    }
  }

  /// 이미지 파일을 정규화하여 임시 파일로 저장
  ///
  /// [filePath]: 원본 이미지 파일 경로
  ///
  /// Returns: 정규화된 이미지의 임시 파일 경로 (실패 시 원본 경로 반환)
  /// 예외 처리를 강화하여 Flutter 에러 화면이 뜨지 않도록 함
  static Future<String> normalizeOrientationToFile(String filePath) async {
    try {
      // 파일 존재 여부 확인
      final file = File(filePath);
      if (!await file.exists()) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ⚠️ File does not exist: $filePath',
          );
        }
        // 파일이 없으면 원본 경로 반환
        return filePath;
      }

      // 정규화된 바이트 가져오기 (예외 처리 강화)
      Uint8List normalizedBytes;
      try {
        normalizedBytes = await normalizeOrientation(filePath);

        // 빈 바이트 체크
        if (normalizedBytes.isEmpty) {
          if (kDebugMode) {
            debugPrint(
              '[PetgramImageOrientation] ⚠️ Normalized bytes is empty, using original path',
            );
          }
          return filePath;
        }
      } catch (e, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ⚠️ normalizeOrientation error: $e',
          );
          debugPrint('[PetgramImageOrientation] Stack trace: $stackTrace');
        }
        // 정규화 실패 시 원본 경로 반환
        return filePath;
      }

      // 임시 파일 생성 (예외 처리 강화)
      try {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File(
          '${tempDir.path}/pg_normalized_${DateTime.now().microsecondsSinceEpoch}.jpg',
        );

        await tempFile.writeAsBytes(normalizedBytes);

        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ✅ Saved normalized image: ${tempFile.path}',
          );
        }

        return tempFile.path;
      } catch (e, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramImageOrientation] ⚠️ Temp file creation error: $e',
          );
          debugPrint('[PetgramImageOrientation] Stack trace: $stackTrace');
        }
        // 임시 파일 생성 실패 시 원본 경로 반환
        return filePath;
      }
    } catch (e, stackTrace) {
      // 🔴 예외 발생 시에도 절대 Flutter 에러 화면이 뜨지 않도록 여기서 전부 잡기
      if (kDebugMode) {
        debugPrint(
          '[PetgramImageOrientation] ❌ normalizeOrientationToFile error: $e',
        );
        debugPrint('[PetgramImageOrientation] Stack trace: $stackTrace');
      }
      // 에러 발생 시 원본 경로 반환 (절대 throw하지 않음)
      return filePath;
    }
  }
}
