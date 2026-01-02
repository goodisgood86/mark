import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 이미지 디코딩 서비스 (isolate 사용)
/// 고해상도 이미지를 프리뷰용으로 다운샘플하면서 CPU 작업은 compute/isolate에서 수행
class PetgramImageDecodeService {
  /// 퀵 프리뷰용 (아주 빠른 디코딩, 작은 사이즈)
  /// 최대 600x600 픽셀로 다운샘플링
  static Future<Uint8List?> decodeQuickPreview(String path) async {
    try {
      return await compute(_decodeImpl, _DecodeParams(
        path: path,
        maxWidth: 600,
        maxHeight: 600,
      ));
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramImageDecodeService] ❌ decodeQuickPreview error: $e');
        debugPrint('[PetgramImageDecodeService] Stack trace: $stackTrace');
      }
      // 에러 발생 시 null 반환 (절대 throw하지 않음)
      return null;
    }
  }

  /// 본 프리뷰용 (필터 적용 기준 사이즈)
  /// 최대 1080x1350 픽셀로 다운샘플링 (짧은 변 1080 기준)
  static Future<Uint8List?> decodeFullPreview(String path) async {
    try {
      return await compute(_decodeImpl, _DecodeParams(
        path: path,
        maxWidth: 1080,
        maxHeight: 1350,
      ));
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramImageDecodeService] ❌ decodeFullPreview error: $e');
        debugPrint('[PetgramImageDecodeService] Stack trace: $stackTrace');
      }
      // 에러 발생 시 null 반환 (절대 throw하지 않음)
      return null;
    }
  }

  /// isolate에서 실행되는 디코딩 함수
  /// compute 클로저 안에서는 플러터 UI API를 사용하지 않고 순수 Dart 로직만 사용
  static Uint8List? _decodeImpl(_DecodeParams params) {
    try {
      final file = File(params.path);
      if (!file.existsSync()) {
        if (kDebugMode) {
          debugPrint('[PetgramImageDecodeService] ⚠️ File does not exist: ${params.path}');
        }
        return null;
      }

      // 파일 읽기
      final bytes = file.readAsBytesSync();
      if (bytes.isEmpty) {
        if (kDebugMode) {
          debugPrint('[PetgramImageDecodeService] ⚠️ File is empty: ${params.path}');
        }
        return null;
      }

      // 이미지 디코딩
      final image = img.decodeImage(bytes);
      if (image == null) {
        if (kDebugMode) {
          debugPrint('[PetgramImageDecodeService] ⚠️ Failed to decode image: ${params.path}');
        }
        return null;
      }

      // 다운샘플링 (비율 유지)
      final int originalWidth = image.width;
      final int originalHeight = image.height;
      final double aspectRatio = originalWidth / originalHeight;

      int targetWidth = originalWidth;
      int targetHeight = originalHeight;

      // 긴 변 기준으로 리사이즈
      if (originalWidth > originalHeight) {
        // 가로가 긴 경우
        if (originalWidth > params.maxWidth) {
          targetWidth = params.maxWidth;
          targetHeight = (targetWidth / aspectRatio).round();
        }
      } else {
        // 세로가 긴 경우
        if (originalHeight > params.maxHeight) {
          targetHeight = params.maxHeight;
          targetWidth = (targetHeight * aspectRatio).round();
        }
      }

      // 리사이즈 (원본 크기와 같으면 리사이즈하지 않음)
      img.Image resizedImage = image;
      if (targetWidth != originalWidth || targetHeight != originalHeight) {
        resizedImage = img.copyResize(
          image,
          width: targetWidth,
          height: targetHeight,
          interpolation: img.Interpolation.linear, // 빠른 리사이즈
        );
      }

      // JPEG로 인코딩 (품질 85로 빠른 인코딩)
      final encodedBytes = img.encodeJpg(resizedImage, quality: 85);
      if (encodedBytes.isEmpty) {
        if (kDebugMode) {
          debugPrint('[PetgramImageDecodeService] ⚠️ Failed to encode image');
        }
        return null;
      }

      if (kDebugMode) {
        debugPrint(
          '[PetgramImageDecodeService] ✅ Decoded: ${originalWidth}x${originalHeight} → ${targetWidth}x${targetHeight}, ${encodedBytes.length} bytes',
        );
      }

      return Uint8List.fromList(encodedBytes);
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[PetgramImageDecodeService] ❌ _decodeImpl error: $e');
        debugPrint('[PetgramImageDecodeService] Stack trace: $stackTrace');
      }
      // 에러 발생 시 null 반환 (절대 throw하지 않음)
      return null;
    }
  }
}

/// 디코딩 파라미터 (compute에 전달하기 위한 데이터 클래스)
class _DecodeParams {
  final String path;
  final int maxWidth;
  final int maxHeight;

  _DecodeParams({
    required this.path,
    required this.maxWidth,
    required this.maxHeight,
  });
}

