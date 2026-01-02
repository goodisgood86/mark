import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/aspect_ratio_mode.dart';
import 'image_pipeline_service.dart';

/// iOS 네이티브 필터 파이프라인 서비스
/// CoreImage + Metal 기반 GPU 가속 필터 처리
class NativeFilterService {
  static const MethodChannel _channel = MethodChannel('petgram/filter_pipeline');

  /// 프리뷰 이미지 렌더링 (네이티브)
  /// - sourcePath: 원본 이미지 파일 경로
  /// - config: 필터 설정
  /// - aspectMode: 화면 비율 모드 (null이면 원본 비율 유지)
  /// - maxSize: 최대 해상도 제한 (null이면 원본 해상도 사용, 성능 최적화용)
  /// - Returns: ui.Image (프리뷰용)
  Future<ui.Image> renderPreview(
    String sourcePath,
    FilterConfig config,
    AspectRatioMode? aspectMode, {
    int? maxSize,
  }) async {
    try {
      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] 📸 renderPreview: sourcePath=$sourcePath, maxSize=$maxSize',
        );
      }

      // FilterConfig를 딕셔너리로 변환
      final configDict = _filterConfigToDict(config);
      final aspectModeStr = aspectMode != null ? _aspectModeToString(aspectMode) : null;

      // 네이티브 호출
      final result = await _channel.invokeMethod<Uint8List>(
        'renderPreview',
        {
          'sourcePath': sourcePath,
          'config': configDict,
          'aspectMode': aspectModeStr,
          if (maxSize != null) 'maxSize': maxSize, // 최대 해상도 제한
        },
      );

      if (result == null) {
        throw Exception('Native filter pipeline returned null');
      }

      // JPEG 바이트를 ui.Image로 변환
      final codec = await ui.instantiateImageCodec(result);
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;

      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] ✅ Preview rendered: ${image.width}x${image.height}',
        );
      }

      return image;
    } catch (e, stackTrace) {
      debugPrint('[NativeFilterService] ❌ renderPreview error: $e');
      debugPrint('[NativeFilterService] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// 최종 저장 이미지 렌더링 (네이티브)
  /// - sourcePath: 원본 이미지 파일 경로
  /// - config: 필터 설정
  /// - aspectMode: 화면 비율 모드 (null이면 원본 비율 유지)
  /// - Returns: JPEG 바이트 (Uint8List)
  Future<Uint8List> renderFullSize(
    String sourcePath,
    FilterConfig config,
    AspectRatioMode? aspectMode,
  ) async {
    try {
      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] 💾 renderFullSize: sourcePath=$sourcePath',
        );
      }

      // FilterConfig를 딕셔너리로 변환
      final configDict = _filterConfigToDict(config);
      final aspectModeStr = aspectMode != null ? _aspectModeToString(aspectMode) : null;

      // 네이티브 호출
      final result = await _channel.invokeMethod<Uint8List>(
        'renderFullSize',
        {
          'sourcePath': sourcePath,
          'config': configDict,
          'aspectMode': aspectModeStr,
        },
      );

      if (result == null) {
        throw Exception('Native filter pipeline returned null');
      }

      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] ✅ Full size rendered: ${result.length} bytes',
        );
      }

      return result;
    } catch (e, stackTrace) {
      debugPrint('[NativeFilterService] ❌ renderFullSize error: $e');
      debugPrint('[NativeFilterService] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// FilterConfig를 딕셔너리로 변환 (네이티브 전달용)
  Map<String, dynamic> _filterConfigToDict(FilterConfig config) {
    return {
      'filterKey': config.filterKey,
      'intensity': config.intensity,
      'brightness': config.brightness,
      'editBrightness': config.editBrightness,
      'editContrast': config.editContrast,
      'editSharpness': config.editSharpness,
      'petToneId': config.petProfile?.id,
      'enablePetToneOnSave': config.enablePetToneOnSave,
    };
  }

  /// AspectRatioMode를 문자열로 변환
  String _aspectModeToString(AspectRatioMode mode) {
    switch (mode) {
      case AspectRatioMode.oneOne:
        return 'oneOne';
      case AspectRatioMode.threeFour:
        return 'threeFour';
      case AspectRatioMode.nineSixteen:
        return 'nineSixteen';
    }
  }

  /// 고해상도 이미지 썸네일 생성 (2048px 이하, EXIF rotation 적용)
  /// ⚠️ 중요: Flutter에서 imglib.decodeImage() 대신 사용하여 CPU 디코딩 시간 절약
  ///          iOS 네이티브에서 CGImageSourceCreateThumbnail을 사용하여 효율적으로 처리
  /// - sourcePath: 원본 이미지 파일 경로
  /// - Returns: JPEG 바이트 (Uint8List, 2048px 이하 썸네일)
  Future<Uint8List> createThumbnail(String sourcePath) async {
    try {
      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] 📸 createThumbnail: sourcePath=$sourcePath',
        );
      }

      // 네이티브 호출
      final result = await _channel.invokeMethod<Uint8List>(
        'createThumbnail',
        {
          'sourcePath': sourcePath,
        },
      );

      if (result == null) {
        throw Exception('Native thumbnail creation returned null');
      }

      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] ✅ Thumbnail created: ${result.length} bytes',
        );
      }

      return result;
    } catch (e, stackTrace) {
      debugPrint('[NativeFilterService] ❌ createThumbnail error: $e');
      debugPrint('[NativeFilterService] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// 필터별 썸네일 일괄 생성
  /// - sourcePath: 원본 이미지 파일 경로
  /// - filterKeys: 필터 키 목록
  /// - thumbnailMaxSize: 최대 해상도 (기본값: 320)
  /// - baseConfig: 공통 필터 설정 (선택적)
  /// - aspectMode: 화면 비율 모드 (선택적)
  /// - Returns: 각 필터별 썸네일 정보
  Future<List<FilterThumbnailResult>> generateFilterThumbnails(
    String sourcePath,
    List<String> filterKeys, {
    int thumbnailMaxSize = 320,
    FilterConfig? baseConfig,
    AspectRatioMode? aspectMode,
  }) async {
    try {
      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] 📸 generateFilterThumbnails: sourcePath=$sourcePath, filterKeys=${filterKeys.length}, maxSize=$thumbnailMaxSize',
        );
      }

      // FilterConfig를 딕셔너리로 변환 (선택적)
      final configDict = baseConfig != null ? _filterConfigToDict(baseConfig) : null;
      final aspectModeStr = aspectMode != null ? _aspectModeToString(aspectMode) : null;

      // 네이티브 호출
      final result = await _channel.invokeMethod<List<dynamic>>(
        'generateFilterThumbnails',
        {
          'sourcePath': sourcePath,
          'filterKeys': filterKeys,
          'thumbnailMaxSize': thumbnailMaxSize,
          if (configDict != null) 'config': configDict,
          if (aspectModeStr != null) 'aspectMode': aspectModeStr,
        },
      );

      if (result == null) {
        throw Exception('Native filter thumbnail generation returned null');
      }

      // 결과를 FilterThumbnailResult 리스트로 변환
      final thumbnailResults = result
          .map((item) {
            if (item is Map) {
              return FilterThumbnailResult(
                filterKey: item['filterKey'] as String? ?? '',
                thumbnailPath: item['thumbnailPath'] as String? ?? '',
                width: (item['width'] as num?)?.toInt() ?? 0,
                height: (item['height'] as num?)?.toInt() ?? 0,
              );
            }
            return null;
          })
          .whereType<FilterThumbnailResult>()
          .toList();

      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] ✅ Filter thumbnails generated: ${thumbnailResults.length} thumbnails',
        );
      }

      return thumbnailResults;
    } catch (e, stackTrace) {
      debugPrint('[NativeFilterService] ❌ generateFilterThumbnails error: $e');
      debugPrint('[NativeFilterService] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// 필터 적용 최종 이미지 생성
  /// - sourcePath: 원본 이미지 파일 경로
  /// - config: 필터 설정
  /// - aspectMode: 화면 비율 모드 (선택적)
  /// - Returns: 생성된 이미지 정보
  Future<FilterResult> applyFilterToImage(
    String sourcePath,
    FilterConfig config, {
    AspectRatioMode? aspectMode,
  }) async {
    try {
      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] 💾 applyFilterToImage: sourcePath=$sourcePath',
        );
      }

      // FilterConfig를 딕셔너리로 변환
      final configDict = _filterConfigToDict(config);
      final aspectModeStr = aspectMode != null ? _aspectModeToString(aspectMode) : null;

      // 네이티브 호출
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'applyFilterToImage',
        {
          'sourcePath': sourcePath,
          'config': configDict,
          if (aspectModeStr != null) 'aspectMode': aspectModeStr,
        },
      );

      if (result == null) {
        throw Exception('Native filter application returned null');
      }

      // 결과를 FilterResult로 변환
      final filterResult = FilterResult(
        resultPath: result['resultPath'] as String? ?? '',
        width: (result['width'] as num?)?.toInt() ?? 0,
        height: (result['height'] as num?)?.toInt() ?? 0,
      );

      if (kDebugMode) {
        debugPrint(
          '[NativeFilterService] ✅ Filter applied: ${filterResult.resultPath} (${filterResult.width}x${filterResult.height})',
        );
      }

      return filterResult;
    } catch (e, stackTrace) {
      debugPrint('[NativeFilterService] ❌ applyFilterToImage error: $e');
      debugPrint('[NativeFilterService] Stack trace: $stackTrace');
      rethrow;
    }
  }
}

/// 필터 썸네일 결과 모델
class FilterThumbnailResult {
  final String filterKey;
  final String thumbnailPath;
  final int width;
  final int height;

  const FilterThumbnailResult({
    required this.filterKey,
    required this.thumbnailPath,
    required this.width,
    required this.height,
  });
}

/// 필터 적용 결과 모델
class FilterResult {
  final String resultPath;
  final int width;
  final int height;

  const FilterResult({
    required this.resultPath,
    required this.width,
    required this.height,
  });
}

