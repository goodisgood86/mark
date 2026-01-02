/// 공통 이미지 파이프라인 모듈
/// 
/// 프리뷰(네이티브/GPU)와 저장(Flutter/CPU) 파이프라인이 1:1 동일한 결과를 보장하기 위한
/// 단일 소스 오브 트루스(Single Source of Truth) 모듈
/// 
/// 이 모듈은 모든 필터 수식, 밝기/대비/선명도 계산, 크롭/비율 계산, 줌 매핑 등을 정의합니다.
/// Flutter와 iOS 네이티브 모두 이 모듈의 수식을 참조하여 동일한 결과를 생성합니다.
library shared_image_pipeline;

/// 필터 파이프라인 설정
class SharedFilterConfig {
  final String filterKey;
  final double intensity;
  final double brightness; // HomePage용: -10 ~ +10
  final String? petToneId;
  final bool enablePetTone;
  final double? editBrightness; // FilterPage용: -50 ~ +50
  final double? editContrast; // FilterPage용: -50 ~ +50
  final double? editSharpness; // FilterPage용: 0 ~ 100
  final double? aspectRatio; // 목표 비율 (예: 9/16, 3/4, 1.0)
  final bool enableFrame;
  final double? zoomFactor; // UI 줌 팩터 (0.5 ~ 10.0)

  const SharedFilterConfig({
    required this.filterKey,
    required this.intensity,
    required this.brightness,
    this.petToneId,
    this.enablePetTone = true,
    this.editBrightness,
    this.editContrast,
    this.editSharpness,
    this.aspectRatio,
    this.enableFrame = false,
    this.zoomFactor,
  });
}

/// 공통 필터 파이프라인 수식 정의
/// 
/// 이 클래스는 모든 필터 수식을 정의하며, Flutter와 iOS 네이티브 모두
/// 이 수식을 참조하여 동일한 결과를 생성합니다.
class SharedImagePipeline {
  /// Identity 매트릭스 (변환 없음)
  static const List<double> kIdentityMatrix = [
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  // ============================================================================
  // 필터 적용 순서 (프리뷰와 저장 모두 동일)
  // ============================================================================
  // 1. 펫톤 프로필 (40% 강도)
  // 2. 필터 (intensity 적용)
  // 3. 밝기 (HomePage용: -10 ~ +10)
  // 4. editBrightness (FilterPage용: -50 ~ +50)
  // 5. editContrast (FilterPage용: -50 ~ +50)
  // 6. editSharpness (FilterPage용: 0 ~ 100) - 별도 필터
  // ============================================================================

  /// 펫톤 프로필 매트릭스 생성 (40% 강도)
  /// 
  /// [petToneMatrix]: 펫톤 프로필의 원본 매트릭스
  /// Returns: identity와 petToneMatrix를 40%로 믹스한 매트릭스
  static List<double> buildPetToneMatrix(
    List<double> petToneMatrix,
  ) {
    return mixMatrix(kIdentityMatrix, petToneMatrix, 0.4);
  }

  /// 필터 매트릭스 생성 (intensity 적용)
  /// 
  /// [filterMatrix]: 필터의 원본 매트릭스
  /// [intensity]: 필터 강도 (0.0 ~ 1.0)
  /// Returns: identity와 filterMatrix를 intensity로 믹스한 매트릭스
  static List<double> buildFilterMatrix(
    List<double> filterMatrix,
    double intensity,
  ) {
    return mixMatrix(kIdentityMatrix, filterMatrix, intensity);
  }

  /// 밝기 매트릭스 생성 (HomePage용: -10 ~ +10)
  /// 
  /// [brightness]: 밝기 값 (-10 ~ +10)
  /// Returns: 밝기 조정 매트릭스
  /// 
  /// 수식: offset = (brightness / 10.0) * 255 * 0.1
  static List<double> buildBrightnessMatrix(double brightness) {
    // brightness: -10 ~ +10 → offset: -25.5 ~ +25.5
    final double brightnessOffset = (brightness / 10.0) * 255.0 * 0.1;
    return [
      1, 0, 0, 0, brightnessOffset,
      0, 1, 0, 0, brightnessOffset,
      0, 0, 1, 0, brightnessOffset,
      0, 0, 0, 1, 0,
    ];
  }

  /// 밝기 매트릭스 생성 (FilterPage용: -50 ~ +50)
  /// 
  /// [editBrightness]: 밝기 값 (-50 ~ +50)
  /// Returns: 밝기 조정 매트릭스
  /// 
  /// 수식: offset = (editBrightness / 50.0) * 40.0
  static List<double> buildEditBrightnessMatrix(double editBrightness) {
    // brightness: -50 ~ +50 → offset: -40 ~ +40
    final double brightnessOffset = (editBrightness / 50.0) * 40.0;
    return [
      1, 0, 0, 0, brightnessOffset,
      0, 1, 0, 0, brightnessOffset,
      0, 0, 1, 0, brightnessOffset,
      0, 0, 0, 1, 0,
    ];
  }

  /// 대비 매트릭스 생성 (FilterPage용: -50 ~ +50)
  /// 
  /// [editContrast]: 대비 값 (-50 ~ +50)
  /// Returns: 대비 조정 매트릭스
  /// 
  /// 수식: scale = 1.0 + (editContrast / 50.0) * 0.4
  ///      범위: 0.6 ~ 1.4
  static List<double> buildContrastMatrix(double editContrast) {
    // contrast: -50 ~ +50 → scale: 0.6 ~ 1.4
    final double c = 1.0 + (editContrast / 50.0) * 0.4;
    return [
      c, 0, 0, 0, 0,
      0, c, 0, 0, 0,
      0, 0, c, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// 선명도 값 계산 (FilterPage용: 0 ~ 100)
  /// 
  /// [editSharpness]: 선명도 값 (0 ~ 100)
  /// Returns: CIFilter에 사용할 선명도 값 (0.0 ~ 1.0)
  /// 
  /// 수식: sharpnessValue = editSharpness / 100.0
  static double calculateSharpnessValue(double editSharpness) {
    return editSharpness / 100.0;
  }

  /// 매트릭스 믹스 (선형 보간)
  /// 
  /// [a]: 첫 번째 매트릭스
  /// [b]: 두 번째 매트릭스
  /// [t]: 믹스 비율 (0.0 ~ 1.2, 클램프됨)
  /// Returns: a와 b를 t 비율로 믹스한 매트릭스
  static List<double> mixMatrix(
    List<double> a,
    List<double> b,
    double t,
  ) {
    final double clamped = t.clamp(0.0, 1.2);
    return List.generate(a.length, (i) => a[i] + (b[i] - a[i]) * clamped);
  }

  /// 매트릭스 곱셈
  /// 
  /// [a]: 첫 번째 매트릭스
  /// [b]: 두 번째 매트릭스
  /// Returns: a * b (행렬 곱셈)
  static List<double> multiplyColorMatrices(
    List<double> a,
    List<double> b,
  ) {
    // 4x5 매트릭스 곱셈
    // a는 4x5, b는 4x5
    // 결과는 4x5
    final List<double> result = List.filled(20, 0.0);

    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        double sum = 0.0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        result[row * 5 + col] = sum;
      }
      // bias 항 계산
      result[row * 5 + 4] = a[row * 5 + 4] + b[row * 5 + 4];
    }

    return result;
  }

  /// 전체 ColorMatrix 생성 (모든 필터를 순서대로 적용)
  /// 
  /// [config]: 필터 설정
  /// [petToneMatrix]: 펫톤 프로필 매트릭스 (null이면 스킵)
  /// [filterMatrix]: 필터 매트릭스 (null이면 스킵)
  /// 
  /// 적용 순서:
  /// 1. 펫톤 (40% 강도)
  /// 2. 필터 (intensity 적용)
  /// 3. 밝기 (HomePage용)
  /// 4. editBrightness (FilterPage용)
  /// 5. editContrast (FilterPage용)
  /// 
  /// Returns: 최종 ColorMatrix
  static List<double> buildCompleteColorMatrix(
    SharedFilterConfig config, {
    List<double>? petToneMatrix,
    List<double>? filterMatrix,
  }) {
    List<double> matrix = List.from(kIdentityMatrix);

    // 1. 펫톤 프로필 적용 (40% 강도)
    if (config.enablePetTone &&
        config.petToneId != null &&
        petToneMatrix != null) {
      final petToneMixed = buildPetToneMatrix(petToneMatrix);
      matrix = multiplyColorMatrices(matrix, petToneMixed);
    }

    // 2. 필터 적용 (intensity 적용)
    if (config.filterKey != 'basic_none' && filterMatrix != null) {
      final filterMixed = buildFilterMatrix(filterMatrix, config.intensity);
      matrix = multiplyColorMatrices(matrix, filterMixed);
    }

    // 3. 밝기 조정 (HomePage용: -10 ~ +10)
    if (config.brightness != 0.0) {
      final brightnessMatrix = buildBrightnessMatrix(config.brightness);
      matrix = multiplyColorMatrices(matrix, brightnessMatrix);
    }

    // 4. editBrightness 조정 (FilterPage용: -50 ~ +50)
    if (config.editBrightness != null && config.editBrightness! != 0.0) {
      final editBrightnessMatrix =
          buildEditBrightnessMatrix(config.editBrightness!);
      matrix = multiplyColorMatrices(matrix, editBrightnessMatrix);
    }

    // 5. editContrast 조정 (FilterPage용: -50 ~ +50)
    if (config.editContrast != null && config.editContrast! != 0.0) {
      final contrastMatrix = buildContrastMatrix(config.editContrast!);
      matrix = multiplyColorMatrices(matrix, contrastMatrix);
    }

    // 6. editSharpness는 ColorMatrix로 처리하지 않음 (별도 필터로 처리)

    return matrix;
  }

  // ============================================================================
  // 줌 매핑 (프리뷰와 저장 동일)
  // ============================================================================

  /// UI 줌 팩터를 네이티브 videoZoomFactor로 매핑
  /// 
  /// [uiZoom]: UI 줌 팩터 (0.5 ~ 10.0)
  /// [minAvailableZoom]: 디바이스 최소 줌 (일반적으로 0.5 또는 1.0)
  /// [maxAvailableZoom]: 디바이스 최대 줌
  /// 
  /// Returns: 네이티브 videoZoomFactor
  /// 
  /// 중요: 0.5~0.9 구간에서도 연속적으로 변하도록 보장
  static double mapUiZoomToNative(
    double uiZoom,
    double minAvailableZoom,
    double maxAvailableZoom,
  ) {
    // UI 줌을 디바이스 범위로 클램프
    final double clamped = uiZoom.clamp(minAvailableZoom, maxAvailableZoom);
    return clamped;
  }

  // ============================================================================
  // 크롭/비율 계산 (프리뷰와 저장 동일)
  // ============================================================================

  /// Aspect 비율 크롭 계산
  /// 
  /// [width]: 원본 너비
  /// [height]: 원본 높이
  /// [targetAspectRatio]: 목표 비율 (예: 9/16, 3/4, 1.0)
  /// 
  /// Returns: 크롭 영역 (x, y, width, height)
  static ({int x, int y, int width, int height}) calculateAspectCrop(
    int width,
    int height,
    double targetAspectRatio,
  ) {
    final double sourceAspect = width / height;
    int cropWidth = width;
    int cropHeight = height;
    int cropX = 0;
    int cropY = 0;

    if (sourceAspect > targetAspectRatio) {
      // 원본이 더 넓음 → 좌우를 자름
      cropHeight = height;
      cropWidth = (height * targetAspectRatio).round();
      cropX = ((width - cropWidth) / 2).round();
      cropY = 0;
    } else {
      // 원본이 더 높음 → 상하를 자름
      cropWidth = width;
      cropHeight = (width / targetAspectRatio).round();
      cropX = 0;
      cropY = ((height - cropHeight) / 2).round();
    }

    return (
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );
  }

  /// 줌 기반 크롭 계산
  /// 
  /// [width]: 원본 너비
  /// [height]: 원본 높이
  /// [zoomFactor]: 줌 팩터 (1.0 = 원본, 2.0 = 2배 확대)
  /// 
  /// Returns: 크롭 영역 (x, y, width, height)
  static ({int x, int y, int width, int height}) calculateZoomCrop(
    int width,
    int height,
    double zoomFactor,
  ) {
    if (zoomFactor <= 1.0) {
      // 줌이 1.0 이하면 크롭 없음
      return (x: 0, y: 0, width: width, height: height);
    }

    // 줌 팩터에 따라 중앙 크롭
    final int cropWidth = (width / zoomFactor).round();
    final int cropHeight = (height / zoomFactor).round();
    final int cropX = ((width - cropWidth) / 2).round();
    final int cropY = ((height - cropHeight) / 2).round();

    return (
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );
  }

  // ============================================================================
  // 오버레이 위치 계산 (프리뷰와 저장 동일)
  // ============================================================================

  /// 프레임/텍스트 오버레이 위치 계산
  /// 
  /// [imageWidth]: 이미지 너비
  /// [imageHeight]: 이미지 높이
  /// [overlayWidth]: 오버레이 너비
  /// [overlayHeight]: 오버레이 높이
  /// [alignment]: 정렬 방식 ('center', 'top', 'bottom', 'left', 'right')
  /// 
  /// Returns: 오버레이 위치 (x, y)
  static ({double x, double y}) calculateOverlayPosition(
    int imageWidth,
    int imageHeight,
    int overlayWidth,
    int overlayHeight,
    String alignment,
  ) {
    double x = 0.0;
    double y = 0.0;

    switch (alignment) {
      case 'center':
        x = (imageWidth - overlayWidth) / 2.0;
        y = (imageHeight - overlayHeight) / 2.0;
        break;
      case 'top':
        x = (imageWidth - overlayWidth) / 2.0;
        y = 0.0;
        break;
      case 'bottom':
        x = (imageWidth - overlayWidth) / 2.0;
        y = (imageHeight - overlayHeight).toDouble();
        break;
      case 'left':
        x = 0.0;
        y = (imageHeight - overlayHeight) / 2.0;
        break;
      case 'right':
        x = (imageWidth - overlayWidth).toDouble();
        y = (imageHeight - overlayHeight) / 2.0;
        break;
      default:
        x = (imageWidth - overlayWidth) / 2.0;
        y = (imageHeight - overlayHeight) / 2.0;
    }

    return (x: x, y: y);
  }

  // ============================================================================
  // 프레임 칩 오버레이 위치 계산 (프리뷰와 저장 동일)
  // ============================================================================

  /// 프레임 칩 크기 계산
  /// 
  /// [imageWidth]: 이미지 너비
  /// Returns: 칩 높이
  /// 
  /// 수식: chipHeight = imageWidth * 0.06
  static double calculateChipHeight(double imageWidth) {
    return imageWidth * 0.06;
  }

  /// 프레임 칩 패딩 계산
  /// 
  /// [imageWidth]: 이미지 너비
  /// Returns: 칩과 화면 경계 사이 여백
  /// 
  /// 수식: chipPadding = imageWidth * 0.03
  static double calculateChipPadding(double imageWidth) {
    return imageWidth * 0.03;
  }

  /// 프레임 칩 간격 계산
  /// 
  /// [imageWidth]: 이미지 너비
  /// Returns: 칩들 사이 간격
  /// 
  /// 수식: chipSpacing = imageWidth * 0.015
  static double calculateChipSpacing(double imageWidth) {
    return imageWidth * 0.015;
  }

  /// 프레임 칩 모서리 둥글기 계산
  /// 
  /// [chipHeight]: 칩 높이
  /// Returns: 칩 모서리 반경
  /// 
  /// 수식: chipCornerRadius = chipHeight * 0.3
  static double calculateChipCornerRadius(double chipHeight) {
    return chipHeight * 0.3;
  }

  /// 프레임 칩 가로 패딩 계산
  /// 
  /// [chipHeight]: 칩 높이
  /// Returns: 칩 내부 좌우 패딩
  /// 
  /// 수식: chipPaddingHorizontal = chipHeight * 0.4
  static double calculateChipPaddingHorizontal(double chipHeight) {
    return chipHeight * 0.4;
  }

  /// 프레임 아이콘 크기 계산
  /// 
  /// [chipHeight]: 칩 높이
  /// Returns: 아이콘 크기
  /// 
  /// 수식: iconSize = chipHeight * 0.75
  static double calculateIconSize(double chipHeight) {
    return chipHeight * 0.75;
  }

  /// 프레임 아이콘 간격 계산
  /// 
  /// [chipHeight]: 칩 높이
  /// Returns: 아이콘과 텍스트 사이 간격
  /// 
  /// 수식: iconSpacing = chipHeight * 0.15
  static double calculateIconSpacing(double chipHeight) {
    return chipHeight * 0.15;
  }

  /// 프레임 칩 폰트 크기 계산
  /// 
  /// [chipHeight]: 칩 높이
  /// Returns: 폰트 크기
  /// 
  /// 수식: fontSize = chipHeight * 0.5
  static double calculateChipFontSize(double chipHeight) {
    return chipHeight * 0.5;
  }

  /// 프레임 칩 최대 너비 계산
  /// 
  /// [imageWidth]: 이미지 너비
  /// Returns: 칩 최대 너비
  /// 
  /// 수식: maxChipWidth = imageWidth * 0.7
  static double calculateMaxChipWidth(double imageWidth) {
    return imageWidth * 0.7;
  }

  /// 프레임 칩 가로 패딩 계산
  /// 
  /// [imageWidth]: 이미지 너비
  /// Returns: 좌우 여백
  /// 
  /// 수식: horizontalPadding = imageWidth * 0.04
  static double calculateHorizontalPadding(double imageWidth) {
    return imageWidth * 0.04;
  }

  /// 프레임 상단 오프셋 계산
  /// 
  /// [topBarHeight]: 상단 바 높이 (null이면 0)
  /// [chipPadding]: 칩 패딩
  /// Returns: 상단 칩 시작 Y 위치
  /// 
  /// 수식: frameTopOffset = (topBarHeight ?? 0) + chipPadding * 2.0
  static double calculateFrameTopOffset(double? topBarHeight, double chipPadding) {
    return (topBarHeight ?? 0) + chipPadding * 2.0;
  }

  /// 프레임 상단 칩 Y 위치 계산
  /// 
  /// [frameTopOffset]: 상단 오프셋
  /// [chipPadding]: 칩 패딩
  /// Returns: 상단 칩 Y 위치
  /// 
  /// 수식: topChipY = frameTopOffset + chipPadding
  static double calculateTopChipY(double frameTopOffset, double chipPadding) {
    return frameTopOffset + chipPadding;
  }

  /// 프레임 하단 칩 Y 위치 계산
  /// 
  /// [imageHeight]: 이미지 높이
  /// [bottomBarHeight]: 하단 바 높이 (null이면 이미지 하단 사용)
  /// [chipHeight]: 칩 높이
  /// [chipPadding]: 칩 패딩
  /// Returns: 하단 칩 Y 위치
  /// 
  /// 수식: 
  ///   - bottomBarSpace = max(imageHeight * 0.05, chipHeight * 1.5)
  ///   - additionalOffset = max(20.0, imageHeight * 0.02)
  ///   - finalBottomInfoY = (bottomBarHeight ?? imageHeight) - (bottomBarSpace - additionalOffset) - chipPadding * 1.5 - chipHeight
  static double? calculateBottomChipY(
    double imageHeight,
    double? bottomBarHeight,
    double chipHeight,
    double chipPadding,
  ) {
    // 추가 하향 offset
    final double additionalOffset = (20.0 > imageHeight * 0.02) ? 20.0 : imageHeight * 0.02;
    final double bottomInfoPadding = chipPadding * 1.5;

    // 하단 공간 계산
    final double minBottomSpace = chipHeight * 1.5;
    final double proportionalBottomSpace = imageHeight * 0.05;
    final double bottomBarSpace = proportionalBottomSpace > minBottomSpace
        ? proportionalBottomSpace
        : minBottomSpace;

    // 하단 칩 Y 위치 계산
    double finalBottomInfoY;
    if (bottomBarHeight != null) {
      finalBottomInfoY = bottomBarHeight -
          (bottomBarSpace - additionalOffset) -
          bottomInfoPadding -
          chipHeight;
    } else {
      finalBottomInfoY = imageHeight -
          (bottomBarSpace - additionalOffset) -
          bottomInfoPadding -
          chipHeight;
    }

    // 음수 체크
    if (finalBottomInfoY < 0) {
      return null;
    }

    return finalBottomInfoY;
  }

  /// 프레임 하단 칩 Y 위치 계산 (프리뷰용)
  /// 
  /// [imageHeight]: 이미지 높이
  /// [chipHeight]: 칩 높이
  /// [chipPadding]: 칩 패딩
  /// Returns: 하단 칩 Y 위치
  /// 
  /// 수식:
  ///   - additionalOffset = max(20.0, imageHeight * 0.02)
  ///   - bottomMargin = imageHeight * 0.12 - additionalOffset
  ///   - finalBottomInfoY = imageHeight - bottomMargin - chipHeight
  ///   - 최종값 = min(imageHeight - chipHeight - chipPadding, finalBottomInfoY)
  static double? calculateBottomChipYForPreview(
    double imageHeight,
    double chipHeight,
    double chipPadding,
  ) {
    // 추가 하향 offset
    final double additionalOffset = (20.0 > imageHeight * 0.02) ? 20.0 : imageHeight * 0.02;
    final double bottomMargin = imageHeight * 0.12 - additionalOffset;

    // 하단 칩 위치 계산
    double finalBottomInfoY = imageHeight - bottomMargin - chipHeight;
    final double maxY = imageHeight - chipHeight - chipPadding;
    if (finalBottomInfoY > maxY) {
      finalBottomInfoY = maxY;
    }

    // 음수 체크
    if (finalBottomInfoY < 0) {
      return null;
    }

    return finalBottomInfoY;
  }

  // ============================================================================
  // 해상도 스케일링 (프리뷰와 저장 동일)
  // ============================================================================

  /// 해상도 다운샘플링 계산
  /// 
  /// [originalWidth]: 원본 너비
  /// [originalHeight]: 원본 높이
  /// [maxDimension]: 최대 해상도 (긴 변 기준)
  /// 
  /// Returns: 다운샘플된 크기 (width, height)
  static ({int width, int height}) calculateDownsample(
    int originalWidth,
    int originalHeight,
    int maxDimension,
  ) {
    final int longSide = originalWidth > originalHeight
        ? originalWidth
        : originalHeight;

    if (longSide <= maxDimension) {
      // 다운샘플 불필요
      return (width: originalWidth, height: originalHeight);
    }

    // 비율 유지하며 다운샘플
    final double scale = maxDimension / longSide;
    final int newWidth = (originalWidth * scale).round();
    final int newHeight = (originalHeight * scale).round();

    return (width: newWidth, height: newHeight);
  }
}

