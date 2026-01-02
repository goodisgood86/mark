import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../core/shared_image_pipeline.dart';
import '../models/constants.dart';
import '../models/filter_data.dart';
import '../models/filter_models.dart';
import '../services/image_service.dart';

/// 필터/프레임 설정을 담는 DTO
class FilterConfig {
  final String filterKey;
  final double intensity;
  final double brightness;
  final String? coatPreset;
  final PetToneProfile? petProfile;
  final bool enablePetToneOnSave;
  final double? editBrightness; // FilterPage 전용: -50 ~ +50
  final double? editContrast; // FilterPage 전용: -50 ~ +50
  final double? editSharpness; // FilterPage 전용: 0 ~ 100
  final double? aspectRatio; // 목표 비율 (예: 9/16, 3/4, 1.0) - null이면 원본 비율 유지
  final bool enableFrame; // 프레임 적용 여부

  const FilterConfig({
    required this.filterKey,
    required this.intensity,
    required this.brightness,
    this.coatPreset,
    this.petProfile,
    this.enablePetToneOnSave = true,
    this.editBrightness,
    this.editContrast,
    this.editSharpness,
    this.aspectRatio,
    this.enableFrame = false,
  });
}

/// 이미지 처리 파이프라인 서비스
///
/// - 네이티브 촬영 파일 또는 갤러리 파일을 입력으로 받아
/// - 필터/프레임 적용 후 JPEG로 저장
/// - 프리뷰: 저해상도 (1080px), 저장: 고해상도 (2560px)
class ImagePipelineService {
  const ImagePipelineService();

  // 프리뷰 베이스 이미지 캐시 (원본 경로 → 프리뷰 베이스 경로)
  static final Map<String, String> _previewBasePathCache = {};

  /// full-res 이미지 로드 (다운샘플링 없음)
  Future<ui.Image> decodeFullImage(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frameInfo = await codec.getNextFrame();
    return frameInfo.image;
  }

  /// 프리뷰 베이스 이미지 생성 또는 재사용
  /// 원본 경로를 받아서 1080px 이하로 다운샘플링한 베이스 이미지를 생성하고 캐시에 저장
  Future<String> getOrCreatePreviewBase(String originalPath) async {
    // 캐시 확인
    if (_previewBasePathCache.containsKey(originalPath)) {
      final cachedPath = _previewBasePathCache[originalPath]!;
      final cachedFile = File(cachedPath);
      if (await cachedFile.exists()) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 🧱 Preview BASE reuse: $originalPath → $cachedPath',
          );
        }
        return cachedPath;
      } else {
        // 캐시된 파일이 없으면 캐시에서 제거
        _previewBasePathCache.remove(originalPath);
      }
    }

    // 원본 이미지 디코딩
    final originalImage = await loadImageWithExifRotation(File(originalPath));
    if (originalImage == null) {
      throw Exception('Failed to decode image: $originalPath');
    }

    // 긴 변이 kPreviewMaxDimension 이하가 되도록 리사이즈
    final int width = originalImage.width;
    final int height = originalImage.height;
    final int longSide = width > height ? width : height;

    img.Image? resizedImage = originalImage;
    if (longSide > kPreviewMaxDimension) {
      final double scale = kPreviewMaxDimension / longSide;
      resizedImage = img.copyResize(
        originalImage,
        width: (width * scale).round(),
        height: (height * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
    }

    // 프리뷰 베이스 이미지를 임시 디렉토리에 JPEG로 저장
    final dir = await getTemporaryDirectory();
    // 원본 경로의 해시를 사용하여 고유한 파일명 생성
    final pathHash = originalPath.hashCode.toUnsigned(32).toRadixString(16);
    final basePath = '${dir.path}/preview_base_$pathHash.jpg';
    final baseFile = File(basePath);

    // JPEG 인코딩 (품질 90%)
    final jpegBytes = Uint8List.fromList(
      img.encodeJpg(resizedImage, quality: 90),
    );
    await baseFile.writeAsBytes(jpegBytes, flush: true);

    // 캐시에 저장
    _previewBasePathCache[originalPath] = basePath;

    debugPrint(
      '[Petgram] 🧱 Preview BASE create: ${width}x${height} → ${resizedImage.width}x${resizedImage.height}, path=$basePath',
    );

    return basePath;
  }

  /// Aspect 비율에 맞게 크롭 (공통 파이프라인 모듈 사용)
  /// 
  /// 프리뷰와 저장이 동일한 크롭 계산을 사용하도록 보장하기 위해
  /// SharedImagePipeline의 수식을 사용합니다.
  img.Image _cropToAspectRatio(img.Image image, double targetRatio) {
    final double currentRatio = image.width / image.height;

    // 비율이 이미 일치하면 그대로 반환
    if ((currentRatio - targetRatio).abs() < 0.001) {
      return image;
    }

    // 공통 파이프라인 모듈의 크롭 계산 사용
    final crop = SharedImagePipeline.calculateAspectCrop(
      image.width,
      image.height,
      targetRatio,
    );

    if (crop.width > 0 && crop.height > 0 &&
        crop.x + crop.width <= image.width &&
        crop.y + crop.height <= image.height) {
      final cropped = img.copyCrop(
        image,
        x: crop.x,
        y: crop.y,
        width: crop.width,
        height: crop.height,
      );

      if (kDebugMode) {
      debugPrint(
          '[Petgram] 📐 Aspect crop (shared pipeline): ${image.width}x${image.height} → ${cropped.width}x${cropped.height}, ratio=${(cropped.width / cropped.height).toStringAsFixed(3)}',
      );
      }

      return cropped;
    }

    return image;
  }

  /// 미리보기용 축소 이미지 생성 (프리뷰 베이스 캐시 사용)
  /// buildFinalImage와 동일한 처리 순서 사용 (다운샘플만 다름)
  Future<ui.Image> buildPreviewImage(
    String originalPath,
    FilterConfig config,
  ) async {
    if (kDebugMode) {
      debugPrint('[FilterPage] 📷 Preview source: $originalPath');
    }

    // 1. 프리뷰 베이스 이미지 경로 확보 (캐시 사용)
    final basePath = await getOrCreatePreviewBase(originalPath);

    // 2. 프리뷰 베이스 이미지 디코딩
    final baseImage = await loadImageWithExifRotation(File(basePath));
    if (baseImage == null) {
      throw Exception('Failed to decode preview base image: $basePath');
    }

    if (kDebugMode) {
      debugPrint(
        '[FilterPage] 📐 Preview BASE input: ${baseImage.width}x${baseImage.height}',
      );
    }

    // 3. Aspect 비율 크롭 (필요한 경우)
    // 주의: 프리뷰 베이스는 이미 다운샘플링되어 있으므로, aspect 크롭은 선택적으로 적용
    img.Image processedImage = baseImage;
    final double? aspectRatio = config.aspectRatio;
    if (aspectRatio != null) {
      processedImage = _cropToAspectRatio(baseImage, aspectRatio);
      if (kDebugMode) {
        debugPrint(
          '[FilterPage] 📐 Preview aspect crop: ${baseImage.width}x${baseImage.height} → ${processedImage.width}x${processedImage.height}, ratio=${aspectRatio.toStringAsFixed(3)}, aspectMode=${aspectRatio == 1.0 ? "1:1" : (aspectRatio == 3 / 4 ? "3:4" : (aspectRatio == 9 / 16 ? "9:16" : "custom"))}',
        );
      }
    }

    // 4. 필터/펫톤 적용 (프리뷰 베이스 기준)
    if (kDebugMode) {
      debugPrint(
        '[FilterPage] 🎨 Preview filter: key=${config.filterKey}, intensity=${config.intensity.toStringAsFixed(2)}, petTone=${config.petProfile?.id ?? "none"}, enablePetTone=${config.enablePetToneOnSave}, editBrightness=${config.editBrightness?.toStringAsFixed(1) ?? "0"}, editContrast=${config.editContrast?.toStringAsFixed(1) ?? "0"}, editSharpness=${config.editSharpness?.toStringAsFixed(1) ?? "0"}',
      );
    }

    final colorMatrix = _buildColorMatrix(config);
    final filteredImage = await _applyColorMatrixToImage(
      processedImage,
      colorMatrix,
    );

    // 5. 프리뷰 베이스는 이미 kPreviewMaxDimension 이하이므로 추가 다운샘플링 불필요
    // 단, aspect 크롭으로 인해 해상도가 약간 달라질 수 있으므로 그대로 사용

    // 6. ui.Image로 변환
    final result = await _convertImgImageToUiImage(filteredImage);

    if (kDebugMode) {
      final finalRatio = result.width / result.height;
      debugPrint(
        '[FilterPage] 📐 Preview final: ${result.width}x${result.height}, ratio=${finalRatio.toStringAsFixed(3)}, aspectMode=${aspectRatio == null ? "original" : (aspectRatio == 1.0 ? "1:1" : (aspectRatio == 3 / 4 ? "3:4" : (aspectRatio == 9 / 16 ? "9:16" : "custom")))}',
      );
    }

    return result;
  }

  /// 최종 저장용 이미지 생성 (긴 변 기준 kSaveMaxDimension)
  /// buildPreviewImage와 동일한 처리 순서 사용 (다운샘플만 다름)
  /// 반드시 원본 파일 경로에서 다시 로드하여 처리
  /// 주의: path는 항상 호출자가 명시적으로 전달한 현재 이미지 경로여야 함 (캐시/이전 값 사용 금지)
  Future<ui.Image> buildFinalImage(String path, FilterConfig config) async {
    final start = DateTime.now();
    if (kDebugMode) {
      debugPrint(
        '[ImagePipelineService] 💾 renderForSave using sourcePath=$path',
      );
    }

    // 1. 원본 디코딩 (EXIF 회전 처리 포함)
    //    프리뷰 이미지는 재사용하지 않고 반드시 원본에서 다시 로드
    final originalImage = await loadImageWithExifRotation(File(path));
    if (originalImage == null) {
      throw Exception('Failed to decode image: $path');
    }

    // ⚠️ 원본 해상도 확인 로그 (최소화)
    if (kDebugMode) {
      debugPrint(
        '[ImagePipelineService] 💾 원본 해상도: ${originalImage.width}x${originalImage.height}',
      );
    }

    // 2. 해상도 다운샘플링을 "가장 앞"에서 수행
    //    긴 변이 kSaveMaxDimension을 초과하면 먼저 리사이즈한 뒤,
    //    그 해상도에서 aspect/필터/프레임 처리를 진행하여 연산량을 줄인다.
    img.Image baseImage = originalImage;
    final int originalWidth = originalImage.width;
    final int originalHeight = originalImage.height;
    final int originalLongSide =
        originalWidth > originalHeight ? originalWidth : originalHeight;

    if (originalLongSide > kSaveMaxDimension) {
      final double scale = kSaveMaxDimension / originalLongSide;
      baseImage = img.copyResize(
        originalImage,
        width: (originalWidth * scale).round(),
        height: (originalHeight * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
      if (kDebugMode) {
        debugPrint(
          '[ImagePipelineService] 📐 Early downsample: '
          '${originalWidth}x${originalHeight} → '
          '${baseImage.width}x${baseImage.height} (longSide: $originalLongSide → ${(originalLongSide * scale).round()})',
        );
      }
    }

    // 3. Aspect 비율 크롭 (필요한 경우)
    img.Image processedImage = baseImage;
    final double? aspectRatio = config.aspectRatio;
    if (aspectRatio != null) {
      processedImage = _cropToAspectRatio(baseImage, aspectRatio);
      if (kDebugMode) {
        debugPrint(
          '[FilterPage] 📐 Save aspect crop: ${baseImage.width}x${baseImage.height} → ${processedImage.width}x${processedImage.height}, ratio=${aspectRatio.toStringAsFixed(3)}, aspectMode=${aspectRatio == 1.0 ? "1:1" : (aspectRatio == 3 / 4 ? "3:4" : (aspectRatio == 9 / 16 ? "9:16" : "custom"))}',
        );
      }
    }

    // 4. 필터/펫톤 적용 (다운샘플 + aspect 크롭된 해상도 기준)
    if (kDebugMode) {
      debugPrint(
        '[FilterPage] 🎨 Save filter: key=${config.filterKey}, intensity=${config.intensity.toStringAsFixed(2)}, petTone=${config.petProfile?.id ?? "none"}, enablePetTone=${config.enablePetToneOnSave}, editBrightness=${config.editBrightness?.toStringAsFixed(1) ?? "0"}, editContrast=${config.editContrast?.toStringAsFixed(1) ?? "0"}, editSharpness=${config.editSharpness?.toStringAsFixed(1) ?? "0"}',
      );
    }

    final colorMatrix = _buildColorMatrix(config);
    final filteredImage = await _applyColorMatrixToImage(
      processedImage,
      colorMatrix,
    );

    // 5. 저장용 해상도 처리
    //    앞에서 한 번 다운샘플을 했기 때문에, 여기서는 최소 해상도 체크만 수행하고
    //    추가 리사이즈는 거의 발생하지 않는다.
    final int width = filteredImage.width;
    final int height = filteredImage.height;
    final int longSide = width > height ? width : height;

    img.Image? resizedImage = filteredImage;

    // 최소 해상도 보장: 너무 작은 경우만 경고 로그 출력 (업스케일은 하지 않음)
    if (longSide < kSaveMinDimension) {
      if (kDebugMode) {
        debugPrint(
          '[ImagePipelineService] ⚠️ Save image is smaller than minimum: ${width}x${height} (longSide: $longSide < $kSaveMinDimension)',
        );
        debugPrint(
          '[ImagePipelineService] ℹ️ Keeping original size (no upscaling to avoid quality loss)',
        );
      }
      resizedImage = filteredImage;
    }
    // 정상 범위: 현재 해상도 그대로 사용
    else {
      if (kDebugMode) {
        debugPrint(
          '[ImagePipelineService] 📐 Save image size: ${width}x${height} (longSide: $longSide, within range: $kSaveMinDimension~$kSaveMaxDimension)',
        );
      }
      resizedImage = filteredImage;
    }

    // 5. ui.Image로 변환
    final result = await _convertImgImageToUiImage(resizedImage);

    // ⚠️ 최종 저장 해상도 및 전체 처리 시간 로그 (최소화)
    if (kDebugMode) {
      final finalRatio = result.width / result.height;
      final ms = DateTime.now().difference(start).inMilliseconds;
      debugPrint(
        '[ImagePipelineService] 💾 최종 저장 해상도: ${result.width}x${result.height}, 비율=${finalRatio.toStringAsFixed(3)}, elapsed=${ms}ms',
      );
    }

    return result;
  }

  /// ui.Image를 JPEG로 인코딩 후 파일로 저장, 최종 경로 반환
  Future<String> saveAsJpeg(ui.Image image, {String baseName = 'shot'}) async {
    final start = DateTime.now();
    // ui.Image를 img.Image로 변환
    final imgImage = await _convertUiImageToImgImage(image);

    // JPEG 인코딩 (품질 85%)
    // 품질을 약간 낮춰 파일 크기와 인코딩 시간을 줄여 성능을 개선한다.
    final jpegBytes = Uint8List.fromList(img.encodeJpg(imgImage, quality: 85));

    // 파일 저장
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filename = '${baseName}_$timestamp.jpg';
    final filePath = '${dir.path}/$filename';
    final file = File(filePath);

    await file.writeAsBytes(jpegBytes, flush: true);

    if (kDebugMode) {
      final ms = DateTime.now().difference(start).inMilliseconds;
      debugPrint(
        '[FilterPage] 💾 JPEG saved: ${jpegBytes.length} bytes (${imgImage.width}x${imgImage.height}), elapsed=${ms}ms',
      );
    }

    return filePath;
  }

  /// ColorMatrix 생성 (공통 파이프라인 모듈 사용)
  /// 
  /// 프리뷰와 저장이 동일한 수식을 사용하도록 보장하기 위해
  /// SharedImagePipeline의 수식을 사용합니다.
  List<double> _buildColorMatrix(FilterConfig config) {
    // FilterConfig를 SharedFilterConfig로 변환
    final sharedConfig = SharedFilterConfig(
      filterKey: config.filterKey,
      intensity: config.intensity,
      brightness: config.brightness,
      petToneId: config.petProfile?.id,
      enablePetTone: config.enablePetToneOnSave,
      editBrightness: config.editBrightness,
      editContrast: config.editContrast,
      editSharpness: config.editSharpness,
      aspectRatio: config.aspectRatio,
      enableFrame: config.enableFrame,
    );

    // 펫톤 매트릭스 가져오기
    List<double>? petToneMatrix;
    if (config.enablePetToneOnSave && config.petProfile != null) {
      petToneMatrix = config.petProfile!.matrix;
    }

    // 필터 매트릭스 가져오기
    List<double>? filterMatrix;
    final PetFilter? filter = allFilters[config.filterKey];
    if (filter != null && filter.key != 'basic_none') {
      filterMatrix = filter.matrix;
    }

    // 공통 파이프라인 모듈 사용
    return SharedImagePipeline.buildCompleteColorMatrix(
      sharedConfig,
      petToneMatrix: petToneMatrix,
      filterMatrix: filterMatrix,
    );
  }

  /// 디버그용: img.Image의 평균 RGB 값을 계산하여 로그 출력
  void _debugPrintAverageColor({
    required String tag,
    required img.Image image,
    FilterConfig? config,
  }) {
    if (!kDebugMode) return;

    final int width = image.width;
    final int height = image.height;
    if (width == 0 || height == 0) return;

    // 큰 이미지에서도 성능을 위해 샘플링 (최대 100k 픽셀)
    final int totalPixels = width * height;
    final int maxSamples = 100000;
    final int step = totalPixels > maxSamples
        ? (totalPixels / maxSamples).ceil()
        : 1;

    double sumR = 0;
    double sumG = 0;
    double sumB = 0;
    int count = 0;

    for (int y = 0; y < height; y += step) {
      for (int x = 0; x < width; x += step) {
        final pixel = image.getPixel(x, y);
        sumR += pixel.r.toDouble();
        sumG += pixel.g.toDouble();
        sumB += pixel.b.toDouble();
        count++;
      }
    }

    if (count == 0) return;

    final double avgR = sumR / count;
    final double avgG = sumG / count;
    final double avgB = sumB / count;

    final buffer = StringBuffer()
      ..write('[FilterDebug] $tag avgRGB=(')
      ..write('R=${avgR.toStringAsFixed(1)}, ')
      ..write('G=${avgG.toStringAsFixed(1)}, ')
      ..write('B=${avgB.toStringAsFixed(1)})');

    if (config != null) {
      buffer
        ..write(', filterKey=${config.filterKey}')
        ..write(', intensity=${config.intensity.toStringAsFixed(2)}')
        ..write(', petTone=${config.petProfile?.id ?? "none"}')
        ..write(', enablePetTone=${config.enablePetToneOnSave}')
        ..write(', brightness=${config.brightness.toStringAsFixed(1)}')
        ..write(
          ', editBrightness=${config.editBrightness?.toStringAsFixed(1) ?? "0"}',
        )
        ..write(
          ', editContrast=${config.editContrast?.toStringAsFixed(1) ?? "0"}',
        )
        ..write(
          ', editSharpness=${config.editSharpness?.toStringAsFixed(1) ?? "0"}',
        );
    }

    debugPrint(buffer.toString());
  }

  /// img.Image에 ColorMatrix 적용
  Future<img.Image> _applyColorMatrixToImage(
    img.Image image,
    List<double> colorMatrix,
  ) async {
    // ColorMatrix가 identity면 그대로 반환
    if (colorMatrixEquals(colorMatrix, kIdentityMatrix)) {
      return image;
    }

    // 디버그: 필터 적용 전 평균 색상
    _debugPrintAverageColor(tag: 'beforeColorMatrix', image: image);

    // ui.Image로 변환 → GPU ColorMatrix 적용 → img.Image로 변환
    final uiImage = await _convertImgImageToUiImage(image);
    final filteredUiImage = await _applyColorMatrixToUiImageGpu(
      uiImage,
      colorMatrix,
    );
    final result = await _convertUiImageToImgImage(filteredUiImage);

    // 디버그: 필터 적용 후 평균 색상
    _debugPrintAverageColor(tag: 'afterColorMatrix', image: result);

    return result;
  }

  /// img.Image를 ui.Image로 변환 (PNG 인코딩 없이, RGBA 버퍼를 직접 사용)
  Future<ui.Image> _convertImgImageToUiImage(img.Image imgImage) async {
    // image 패키지의 RGBA8 버퍼를 그대로 사용하여 decodeImageFromPixels로 ui.Image 생성
    final Uint8List rgbaBytes = Uint8List.fromList(
      imgImage.getBytes(order: img.ChannelOrder.rgba),
    );

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgbaBytes,
      imgImage.width,
      imgImage.height,
      ui.PixelFormat.rgba8888,
      (ui.Image image) {
        completer.complete(image);
      },
    );
    return completer.future;
  }

  /// ui.Image를 img.Image로 변환
  Future<img.Image> _convertUiImageToImgImage(ui.Image uiImage) async {
    final ByteData? rgbaData = await uiImage.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );

    if (rgbaData == null) {
      throw Exception('Failed to convert ui.Image to img.Image');
    }

    final imgImage = img.Image(width: uiImage.width, height: uiImage.height);

    final pixels = rgbaData.buffer.asUint8List();
    for (int y = 0; y < uiImage.height; y++) {
      for (int x = 0; x < uiImage.width; x++) {
        final index = (y * uiImage.width + x) * 4;
        final r = pixels[index];
        final g = pixels[index + 1];
        final b = pixels[index + 2];
        final a = pixels[index + 3];
        imgImage.setPixel(x, y, img.ColorRgba8(r, g, b, a));
      }
    }

    return imgImage;
  }

  /// GPU 기반 ColorMatrix 적용 (기존 HomePage 로직 재사용)
  /// ⚠️ 중요: 저장용 파이프라인에서는 원본 이미지의 width/height를 그대로 사용하여
  ///          센서 해상도를 유지합니다. 화면 사이즈로 고정하지 않습니다.
  Future<ui.Image> _applyColorMatrixToUiImageGpu(
    ui.Image image,
    List<double> matrix,
  ) async {
    // matrix가 identity면 원본 반환
    if (colorMatrixEquals(matrix, kIdentityMatrix)) {
      return image;
    }

    // ⚠️ 원본 이미지의 해상도를 그대로 사용 (센서 해상도 유지)
    final int width = image.width;
    final int height = image.height;

    if (kDebugMode) {
      debugPrint(
        '[ImagePipelineService] 🎨 GPU ColorMatrix: input=${width}x${height} (preserving sensor resolution)',
      );
    }

    // PictureRecorder로 GPU에서 직접 그리기
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    // ColorFilter를 적용하여 이미지 그리기
    final Paint paint = Paint();
    paint.colorFilter = ColorFilter.matrix(matrix);

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );

    // Picture를 Image로 변환
    // ⚠️ 중요: 원본 해상도(width, height)를 그대로 사용하여 센서 해상도 유지
    final ui.Picture picture = recorder.endRecording();
    final ui.Image result = await picture.toImage(width, height);
    picture.dispose();

    if (kDebugMode) {
      debugPrint(
        '[ImagePipelineService] ✅ GPU ColorMatrix: output=${result.width}x${result.height} (resolution preserved)',
      );
    }

    return result;
  }
}
