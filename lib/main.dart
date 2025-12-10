import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_datetime_picker_plus/flutter_datetime_picker_plus.dart'
    as dtp;

const Color kMainPink = Color(0xFFFFC0CB);
const String kOnboardingSeenKey = 'petgram_onboarding_seen';
const String kLastSelectedFilterKey = 'petgram_last_selected_filter';
const String kPetNameKey = 'petgram_pet_name';
const String kPetListKey = 'petgram_pet_list';
const String kSelectedPetIdKey = 'petgram_selected_pet_id';
const String kFlashModeKey = 'petgram_flash_mode';
const String kShowGridLinesKey = 'petgram_show_grid_lines';
const String kFrameEnabledKey = 'petgram_frame_enabled';
const String kBurstModeKey = 'petgram_burst_mode';
const String kBurstCountSettingKey = 'petgram_burst_count_setting';
const String kTimerSecondsKey = 'petgram_timer_seconds';
const String kAspectModeKey = 'petgram_aspect_mode';

/// 통합 이미지 로딩 헬퍼 (PNG/JPG/HEIC 모두 지원, EXIF 회전 처리)
/// 모든 이미지 불러오기 경로에서 동일하게 사용
Future<img.Image?> loadImageWithExifRotation(File imageFile) async {
  try {
    final bytes = await imageFile.readAsBytes();

    // 파일 확장자 확인
    final extension = imageFile.path.toLowerCase().split('.').last;
    debugPrint(
      '[Petgram] 📷 Loading image: ${imageFile.path}, extension: $extension',
    );

    // image 패키지로 디코딩 (PNG, JPG 지원)
    img.Image? decodedImage;

    if (extension == 'heic' || extension == 'heif') {
      // HEIC는 image 패키지가 직접 지원하지 않으므로
      // image_picker가 이미 JPG로 변환했을 가능성이 높지만,
      // 만약 변환되지 않았다면 에러 처리
      debugPrint('[Petgram] ⚠️ HEIC format detected, attempting decode...');
      // image 패키지는 HEIC를 지원하지 않으므로 null 반환
      // 실제로는 image_picker가 자동으로 JPG로 변환해주므로
      // 여기서는 일반 디코딩 시도
      decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        debugPrint(
          '[Petgram] ❌ HEIC decode failed, image_picker may not have converted it',
        );
        return null;
      }
    } else {
      // PNG, JPG는 일반 디코딩
      decodedImage = img.decodeImage(bytes);
    }

    if (decodedImage == null) {
      debugPrint('[Petgram] ❌ Image decode failed: ${imageFile.path}');
      return null;
    }

    // EXIF 회전 정보 처리
    // image 패키지의 decodeImage는 기본적으로 EXIF 회전을 자동 처리하지 않을 수 있음
    // 하지만 대부분의 경우 이미 올바른 방향으로 디코딩됨
    // 만약 회전이 필요하다면 별도 처리 필요

    debugPrint(
      '[Petgram] ✅ Image loaded: ${decodedImage.width}x${decodedImage.height}, '
      'format: $extension',
    );

    return decodedImage;
  } catch (e) {
    debugPrint('[Petgram] ❌ loadImageWithExifRotation error: $e');
    return null;
  }
}

/// 얼굴 영역 정보 클래스
class FaceRegion {
  final int centerX;
  final int centerY;
  final int radius;

  FaceRegion({
    required this.centerX,
    required this.centerY,
    required this.radius,
  });
}

/// 반려동물 정보 클래스
class PetInfo {
  final String id;
  final String name;
  final String type; // 'dog' or 'cat'
  final DateTime birthDate;
  final int framePattern; // 1 or 2
  final String? gender; // 'male' or 'female' or null
  final String? breed; // 종 (텍스트 입력)
  final bool locationEnabled; // GPS 위치 정보 활성화 여부

  PetInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.birthDate,
    this.framePattern = 1,
    this.gender,
    this.breed,
    this.locationEnabled = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'birthDate': birthDate.toIso8601String(),
    'framePattern': framePattern,
    'gender': gender,
    'breed': breed,
    'locationEnabled': locationEnabled,
  };

  factory PetInfo.fromJson(Map<String, dynamic> json) => PetInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    type: json['type'] as String,
    birthDate: DateTime.parse(json['birthDate'] as String),
    framePattern: json['framePattern'] as int? ?? 1,
    gender: json['gender'] as String?,
    breed: json['breed'] as String?,
    locationEnabled: json['locationEnabled'] as bool? ?? false,
  );

  int getAge() {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }
}

/// 필터용 기본 행렬
const List<double> kIdentityMatrix = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0,
];

/// 두 리스트가 동일한지 비교 (ColorMatrix 비교용)
bool _listEquals(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 0.0001) return false;
  }
  return true;
}

List<double> mixMatrix(List<double> a, List<double> b, double t) {
  final clamped = t.clamp(0.0, 1.2);
  return List.generate(a.length, (i) => a[i] + (b[i] - a[i]) * clamped);
}

/// 두 개의 ColorMatrix를 곱셈하여 하나로 합치기 (성능 개선)
/// 이미지의 평균 RGB 값을 계산 (색상 손실 추적용)
Map<String, double> _calculateAverageRGB(img.Image image) {
  if (image.width == 0 || image.height == 0) {
    return {'r': 0.0, 'g': 0.0, 'b': 0.0};
  }

  double sumR = 0.0;
  double sumG = 0.0;
  double sumB = 0.0;
  final int totalPixels = image.width * image.height;

  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      sumR += pixel.r;
      sumG += pixel.g;
      sumB += pixel.b;
    }
  }

  return {
    'r': sumR / totalPixels,
    'g': sumG / totalPixels,
    'b': sumB / totalPixels,
  };
}

List<double> multiplyColorMatrices(List<double> a, List<double> b) {
  // ColorMatrix는 4x5 행렬이지만 실제로는 20개 요소의 배열
  // 곱셈: result = a * b
  // RGB 부분: 일반 행렬 곱셈
  // Offset 부분: a의 offset + (a의 RGB 행렬 * b의 offset)
  // Alpha 행(마지막 행, 인덱스 15-19)은 항상 [0, 0, 0, 1, 0]으로 보존
  final result = List<double>.filled(20, 0.0);

  for (int row = 0; row < 4; row++) {
    // Alpha 행(마지막 행)은 항상 [0, 0, 0, 1, 0]으로 강제 설정
    if (row == 3) {
      result[15] = 0.0; // m15
      result[16] = 0.0; // m16
      result[17] = 0.0; // m17
      result[18] = 1.0; // m18 (alpha scale)
      result[19] = 0.0; // m19 (alpha offset)
      continue;
    }

    // RGB 부분 (0-3 열)
    for (int col = 0; col < 4; col++) {
      double sum = 0.0;
      for (int k = 0; k < 4; k++) {
        sum += a[row * 5 + k] * b[k * 5 + col];
      }
      result[row * 5 + col] = sum;
    }
    // Offset 부분 (4번째 열)
    double offsetSum = a[row * 5 + 4]; // a의 offset
    for (int k = 0; k < 4; k++) {
      offsetSum += a[row * 5 + k] * b[k * 5 + 4]; // a의 RGB 행렬 * b의 offset
    }
    result[row * 5 + 4] = offsetSum;
  }

  return result;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = const [];
  try {
    cameras = await availableCameras();
    if (kDebugMode) {
      debugPrint('[Petgram] main(): availableCameras length=${cameras.length}');
    }
  } catch (e, s) {
    if (kDebugMode) {
      debugPrint('[Petgram] main(): availableCameras failed → $e');
      debugPrint('[Petgram] stacktrace: $s');
    }
  }

  runApp(PetgramApp(cameras: cameras));
}

class PetgramApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const PetgramApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Petgram',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFFFF5F8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFF5F8),
          foregroundColor: Colors.black,
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: HomePage(cameras: cameras),
    );
  }
}

/// 화면 비율 모드
enum AspectRatioMode { nineSixteen, threeFour, oneOne }

double aspectRatioOf(AspectRatioMode mode) {
  switch (mode) {
    case AspectRatioMode.nineSixteen:
      return 9 / 16; // 진짜 9:16 비율로 수정
    case AspectRatioMode.threeFour:
      return 3 / 4; // 3:4 비율
    case AspectRatioMode.oneOne:
      return 1.0; // 1:1 비율
  }
}

/// BoxFit.cover 매핑을 위한 공통 헬퍼 클래스
class CameraMappingUtils {
  /// BoxFit.cover 매핑 파라미터 계산
  ///
  /// contentSize: 실제 카메라 프리뷰 크기 (센서 크기)
  /// displaySize: 프리뷰 박스 크기 (targetRatio 기반)
  static Map<String, double> calculateBoxFitCoverParams({
    required Size contentSize,
    required Size displaySize,
  }) {
    final double contentW = contentSize.width;
    final double contentH = contentSize.height;
    final double displayW = displaySize.width;
    final double displayH = displaySize.height;

    // BoxFit.cover scale: scale content to fill display while maintaining aspect ratio
    // scale = max(displayW / contentW, displayH / contentH)
    final double scale = math.max(displayW / contentW, displayH / contentH);

    // Fitted size after scaling
    final double fittedW = contentW * scale;
    final double fittedH = contentH * scale;

    // Offset: center the fitted content in the display area
    // If fitted size is larger than display, offset will be negative (content is cropped)
    final double offsetX = (displayW - fittedW) / 2.0;
    final double offsetY = (displayH - fittedH) / 2.0;

    return {
      'contentW': contentW,
      'contentH': contentH,
      'scale': scale,
      'fittedW': fittedW,
      'fittedH': fittedH,
      'displayW': displayW,
      'displayH': displayH,
      'offsetX': offsetX,
      'offsetY': offsetY,
    };
  }

  /// Global tap position → normalized sensor coordinates (0.0–1.0)
  static Offset mapGlobalToNormalized({
    required Offset globalPos,
    required Rect previewRect,
    required Size contentSize,
  }) {
    // Convert global tap position to previewBox-local coordinates
    final double localX = globalPos.dx - previewRect.left;
    final double localY = globalPos.dy - previewRect.top;
    final Size displaySize = previewRect.size;

    // Check if tap is outside preview box
    if (localX < 0 ||
        localX > displaySize.width ||
        localY < 0 ||
        localY > displaySize.height) {
      return Offset(-1, -1); // Invalid tap
    }

    final params = calculateBoxFitCoverParams(
      contentSize: contentSize,
      displaySize: displaySize,
    );

    final double scale = params['scale']!;
    final double offsetX = params['offsetX']!;
    final double offsetY = params['offsetY']!;

    // Reverse BoxFit.cover mapping: display local → content coordinates
    // Step 1: Remove offset (move from display space to fitted content space)
    final double fittedX = localX - offsetX;
    final double fittedY = localY - offsetY;

    // Step 2: Divide by scale to get content coordinates
    final double contentX = fittedX / scale;
    final double contentY = fittedY / scale;

    // Step 3: Clamp to content bounds and normalize to [0, 1]
    final double nx = (contentX / contentSize.width).clamp(0.0, 1.0);
    final double ny = (contentY / contentSize.height).clamp(0.0, 1.0);

    return Offset(nx, ny);
  }

  /// Normalized sensor coordinates (0.0–1.0) → screen coordinates
  static Offset mapNormalizedToScreen({
    required Offset normalized,
    required Rect previewRect,
    required Size contentSize,
    double indicatorOffset =
        0.0, // For centering indicator (e.g., -40 for 80x80 indicator)
  }) {
    final Size displaySize = previewRect.size;

    final params = calculateBoxFitCoverParams(
      contentSize: contentSize,
      displaySize: displaySize,
    );

    final double scale = params['scale']!;
    final double offsetX = params['offsetX']!;
    final double offsetY = params['offsetY']!;

    // Forward BoxFit.cover mapping: normalized → content → display → screen
    // Step 1: Convert normalized to content coordinates
    final double contentX = normalized.dx * contentSize.width;
    final double contentY = normalized.dy * contentSize.height;

    // Step 2: Apply scale to get fitted coordinates
    final double fittedX = contentX * scale;
    final double fittedY = contentY * scale;

    // Step 3: Add offset to get display local coordinates
    final double displayLocalX = fittedX + offsetX;
    final double displayLocalY = fittedY + offsetY;

    // Step 4: Convert to global screen coordinates
    final double screenX = previewRect.left + displayLocalX + indicatorOffset;
    final double screenY = previewRect.top + displayLocalY + indicatorOffset;

    return Offset(screenX, screenY);
  }
}

/// 필터 정의 클래스
class PetFilter {
  final String key;
  final String label;
  final IconData icon;
  final List<double> matrix;

  const PetFilter({
    required this.key,
    required this.label,
    required this.icon,
    required this.matrix,
  });
}

/// 반려동물 전용 자동 보정 프로파일 (종 + 털톤 기반)
class PetToneProfile {
  final String id; // 'dog_light', 'dog_mid', 'dog_dark', 'cat_light', ...
  final List<double> matrix; // 4x5 color matrix (20 elements)

  const PetToneProfile({required this.id, required this.matrix});
}

/// ========================
///  펫톤 보정 프로파일 정의
/// ========================

/// 반려동물 종 + 털톤에 따른 자동 보정 프로파일
/// 과격한 보정이 아닌 "조금 더 예쁘게 보정된 원본" 수준으로 설계
const Map<String, PetToneProfile> kPetToneProfiles = {
  // 강아지 (dog)
  'dog_light': PetToneProfile(
    id: 'dog_light',
    matrix: [
      // 하이라이트 클리핑 줄이기 + 미세한 warm 톤
      0.98, 0.01, 0.01, 0, 3, // R: 약간 감마 ↓, offset +
      0.01, 0.98, 0.01, 0, 3, // G: 약간 감마 ↓, offset +
      0.01, 0.01, 0.98, 0, 3, // B: 약간 감마 ↓, offset +
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'dog_mid': PetToneProfile(
    id: 'dog_mid',
    matrix: [
      // 미세 S-curve + 채도 약간 증가
      1.05, 0, 0, 0, 0, // R: 중간톤 대비 살짝 ↑
      0, 1.05, 0, 0, 0, // G: 중간톤 대비 살짝 ↑
      0, 0, 1.05, 0, 0, // B: 중간톤 대비 살짝 ↑
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'dog_dark': PetToneProfile(
    id: 'dog_dark',
    matrix: [
      // Shadow lift + 전체 대비 약간 ↑
      1.02, 0, 0, 0, 2, // R: shadow lift, 대비 약간 ↑
      0, 1.02, 0, 0, 2, // G: shadow lift, 대비 약간 ↑
      0, 0, 1.02, 0, 2, // B: shadow lift, 대비 약간 ↑
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  // 고양이 (cat)
  'cat_light': PetToneProfile(
    id: 'cat_light',
    matrix: [
      // White balance 약간 neutral + 채도 살짝만
      0.99, 0.005, 0.005, 0, 0, // R: 붉은기/노란기 조금 줄임
      0.005, 1.01, 0.005, 0, 0, // G: 녹색 미세 보정
      0.005, 0.005, 1.01, 0, 0, // B: 파랑 미세 보정
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'cat_mid': PetToneProfile(
    id: 'cat_mid',
    matrix: [
      // 약간 차가운 톤 + 눈 색 강화
      0.98, 0, 0, 0, 0, // R: red 살짝 -
      0, 1.02, 0, 0, 0, // G: green + (눈 색 강화)
      0, 0, 1.02, 0, 0, // B: blue + (눈 색 강화)
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'cat_dark': PetToneProfile(
    id: 'cat_dark',
    matrix: [
      // Dark fur lift + 채도 유지
      1.01, 0, 0, 0, 1.5, // R: shadow lift (과하지 않게)
      0, 1.01, 0, 0, 1.5, // G: shadow lift (과하지 않게)
      0, 0, 1.01, 0, 1.5, // B: shadow lift (과하지 않게)
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
};

/// ========================
///  필터 정의 (공통)
/// ========================

// 촬영/편집 화면에서 사용하는 전체 필터 목록
final Map<String, PetFilter> _allFilters = {
  'basic_none': const PetFilter(
    key: 'basic_none',
    label: '원본',
    icon: Icons.hide_image_rounded,
    matrix: kIdentityMatrix,
  ),
  'basic_soft': const PetFilter(
    key: 'basic_soft',
    label: '소프',
    icon: Icons.blur_on_rounded,
    matrix: [
      1.03,
      0.02,
      0.02,
      0,
      0,
      0.01,
      1.00,
      0.00,
      0,
      0,
      0.00,
      0.02,
      0.98,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  'pink_soft': const PetFilter(
    key: 'pink_soft',
    label: '핑크',
    icon: Icons.favorite_rounded,
    matrix: [
      1.05,
      0.05,
      0.00,
      0,
      5,
      0.00,
      0.95,
      0.05,
      0,
      0,
      0.00,
      0.05,
      0.95,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  'pink_blossom': const PetFilter(
    key: 'pink_blossom',
    label: '벚꽃',
    icon: Icons.local_florist_rounded,
    matrix: [
      1.1, 0.08, 0.0, 0, 8, //
      0.0, 0.92, 0.08, 0, 5, //
      0.0, 0.05, 0.9, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_candy': const PetFilter(
    key: 'pink_candy',
    label: '캔디',
    icon: Icons.cake_rounded,
    matrix: [
      1.15, 0.1, 0.0, 0, 10, //
      0.0, 0.9, 0.1, 0, 8, //
      0.0, 0.05, 0.85, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_dream': const PetFilter(
    key: 'pink_dream',
    label: '드림',
    icon: Icons.auto_awesome_rounded,
    matrix: [
      1.08, 0.06, 0.0, 0, 6, //
      0.0, 0.94, 0.06, 0, 4, //
      0.0, 0.04, 0.92, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_soft': const PetFilter(
    key: 'dog_soft',
    label: '미드',
    icon: Icons.brush_rounded,
    matrix: [
      1.02,
      0.03,
      0.00,
      0,
      0,
      0.00,
      1.00,
      0.02,
      0,
      0,
      0.00,
      0.02,
      1.00,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  'cat_soft': const PetFilter(
    key: 'cat_soft',
    label: '자연',
    icon: Icons.nature_rounded,
    matrix: [
      0.98,
      0.02,
      0.02,
      0,
      0,
      0.02,
      1.02,
      0.02,
      0,
      0,
      0.02,
      0.02,
      1.02,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  // 강아지 전용 필터
  'dog_warm': const PetFilter(
    key: 'dog_warm',
    label: '웜',
    icon: Icons.wb_sunny_rounded,
    matrix: [
      1.15, 0.05, 0.0, 0, 8, //
      0.0, 1.1, 0.0, 0, 5, //
      0.0, 0.0, 0.95, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_vibrant': const PetFilter(
    key: 'dog_vibrant',
    label: '생동',
    icon: Icons.auto_awesome_rounded,
    matrix: [
      1.2, 0.1, 0.0, 0, 0, //
      0.0, 1.15, 0.05, 0, 0, //
      0.0, 0.0, 1.1, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_cozy': const PetFilter(
    key: 'dog_cozy',
    label: '아늑',
    icon: Icons.home_rounded,
    matrix: [
      1.0, 0.05, 0.0, 0, 5, //
      0.0, 0.95, 0.0, 0, 0, //
      0.0, 0.0, 0.9, 0, -5, //
      0, 0, 0, 1, 0,
    ],
  ),
  // 고양이 전용 필터
  'cat_cool': const PetFilter(
    key: 'cat_cool',
    label: '쿨',
    icon: Icons.water_drop_rounded,
    matrix: [
      0.9, 0.05, 0.0, 0, 0, //
      0.0, 0.95, 0.05, 0, 0, //
      0.0, 0.1, 1.1, 0, 5, //
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_elegant': const PetFilter(
    key: 'cat_elegant',
    label: '우아',
    icon: Icons.star_rounded,
    matrix: [
      1.1, 0.05, 0.0, 0, 0, //
      0.0, 1.1, 0.1, 0, 0, //
      0.0, 0.0, 1.0, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_mysterious': const PetFilter(
    key: 'cat_mysterious',
    label: '신비',
    icon: Icons.nightlight_round,
    matrix: [
      0.95, 0.05, 0.0, 0, 5, //
      0.0, 0.95, 0.05, 0, 5, //
      0.0, 0.0, 0.95, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
};

/// 촬영용 필터 표시 순서
const List<String> kFilterOrder = [
  'basic_none',
  'basic_soft',
  'pink_soft',
  'pink_blossom',
  'pink_candy',
  'pink_dream',
  'dog_soft',
  'dog_warm',
  'dog_vibrant',
  'dog_cozy',
  'cat_soft',
  'cat_cool',
  'cat_elegant',
  'cat_mysterious',
];

/// 편집 화면에서 사용하는 카테고리별 필터 묶음
final Map<String, List<PetFilter>> _filtersByCategory = {
  'basic': [_allFilters['basic_none']!, _allFilters['basic_soft']!],
  'pink': [
    _allFilters['pink_soft']!,
    _allFilters['pink_blossom']!,
    _allFilters['pink_candy']!,
    _allFilters['pink_dream']!,
  ],
  'dog': [
    _allFilters['dog_soft']!,
    _allFilters['dog_warm']!,
    _allFilters['dog_vibrant']!,
    _allFilters['dog_cozy']!,
  ],
  'cat': [
    _allFilters['cat_soft']!,
    _allFilters['cat_cool']!,
    _allFilters['cat_elegant']!,
    _allFilters['cat_mysterious']!,
  ],
};

/// ========================
///  메인 홈 화면
/// ========================
class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomePage({super.key, required this.cameras});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final AudioPlayer _audioPlayer = AudioPlayer();

  CameraController? _cameraController;
  bool _isCameraInitializing = true;
  bool _useMockCamera = false;
  bool _isProcessing = false;
  bool _isCaptureAnimating = false;

  // 촬영용 필터
  String _shootFilterKey = kFilterOrder.first;

  // 라이브 필터 강도
  double _liveIntensity = 0.8;
  String _liveCoatPreset = 'mid'; // light / mid / dark / custom

  // 플래시 / 화면 비율
  FlashMode _flashMode = FlashMode.off;
  AspectRatioMode _aspectMode = AspectRatioMode.threeFour;

  // 촬영용 필터 패널 펼침 여부
  bool _filterPanelExpanded = false;

  // 그리드라인 표시
  bool _showGridLines = false;

  // 연속 촬영 모드
  bool _isBurstMode = false;
  int _burstCount = 0;
  int _burstCountSetting = 5; // 기본 5장, 선택 가능: 3, 5, 10, 20
  bool _shouldStopBurst = false; // 연속 촬영 중지 플래그

  // 타이머 촬영
  int _timerSeconds = 0; // 0 = off, 3, 5, 10
  bool _isTimerCounting = false;
  bool _shouldStopTimer = false; // 타이머 중지 플래그
  bool _isTimerTriggered = false; // 타이머로 인한 촬영인지 구분

  List<PetInfo> _petList = [];
  String? _selectedPetId; // 현재 선택된 반려동물 ID

  // 프레임 적용 여부
  bool _frameEnabled = true;

  // 위치 정보
  String? _currentLocation; // 현재 촬영 위치 정보

  /// 위치정보 활성화 여부 확인 후 위치 정보 가져오기
  /// [forceReload]가 true이면 위치정보가 있어도 다시 불러오기 (GPS 업데이트 버튼 클릭 시)
  /// [alwaysReload]가 true이면 프레임 선택 변경 시 항상 다시 불러오기
  Future<void> _checkAndFetchLocation({
    bool forceReload = false,
    bool alwaysReload = false,
  }) async {
    if (!_frameEnabled || _petList.isEmpty) {
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
      return;
    }

    final selectedPet = _selectedPetId != null
        ? _petList.firstWhere(
            (pet) => pet.id == _selectedPetId,
            orElse: () => _petList.first,
          )
        : _petList.first;

    if (selectedPet.locationEnabled) {
      debugPrint(
        '[Petgram] 📍 위치정보 활성화됨: selectedPet.locationEnabled=true, _currentLocation=${_currentLocation != null ? "있음" : "없음"}',
      );
      // 위치 정보가 없거나 강제 재로드가 필요하거나 항상 재로드가 필요한 경우에만 가져오기
      if (_currentLocation == null || forceReload || alwaysReload) {
        debugPrint(
          '[Petgram] 📍 위치정보 불러오기 조건 충족: _currentLocation=${_currentLocation != null ? "있음" : "없음"}, forceReload=$forceReload, alwaysReload=$alwaysReload',
        );
        if (forceReload || alwaysReload) {
          if (mounted) {
            setState(() {
              _currentLocation = null; // 초기화하여 다시 불러오도록
            });
          }
        }
        await _fetchLocation();
      } else {
        debugPrint('[Petgram] 📍 위치정보 불러오기 조건 불충족: 이미 위치정보가 있음');
      }
    } else {
      debugPrint('[Petgram] 📍 위치정보 비활성화됨: selectedPet.locationEnabled=false');
      // 위치 정보 활성화가 안 되어 있으면 null로 설정
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
    }
  }

  /// 위치 정보 가져오기 (동 이전 레벨까지)
  Future<void> _fetchLocation({bool showSnackbar = false}) async {
    debugPrint('[Petgram] 📍 _fetchLocation 시작');
    try {
      // 위치 서비스 활성화 여부 확인
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (kDebugMode) {
          debugPrint('📍 위치 서비스가 비활성화되어 있습니다');
        }
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        return;
      }

      // 위치 권한 확인
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (kDebugMode) {
            debugPrint('📍 위치 권한이 거부되었습니다');
          }
          if (mounted) {
            setState(() {
              _currentLocation = null;
            });
          }
          if (showSnackbar && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('위치 정보를 확인할 수 없습니다'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (kDebugMode) {
          debugPrint('📍 위치 권한이 영구적으로 거부되었습니다');
        }
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        return;
      }

      // 현재 위치 가져오기
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      // geocoding 패키지 사용
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final placemark = placemarks[0];
        if (kDebugMode) {
          debugPrint('📍 Placemark 정보:');
          debugPrint('  - administrativeArea: ${placemark.administrativeArea}');
          debugPrint(
            '  - subAdministrativeArea: ${placemark.subAdministrativeArea}',
          );
          debugPrint('  - locality: ${placemark.locality}');
          debugPrint('  - subLocality: ${placemark.subLocality}');
        }

        // 3단계까지 풀로 노출하는 함수
        String buildRegion3Level(Placemark p) {
          // 1레벨 = 시도
          final level1 = (p.administrativeArea ?? '').trim(); // 서울특별시, 경기도 등

          // 2레벨 후보 = 시군구
          String? level2;

          // 1순위: locality (강남구, 의정부시 등)
          if ((p.locality ?? '').trim().isNotEmpty) {
            final locality = p.locality!.trim();
            // 예외처리: 레벨2가 레벨1과 같으면 사용하지 않음
            if (locality != level1) {
              level2 = locality;
            }
          }
          // 2순위: subAdministrativeArea (성남시, 의정부시 등 기기 따라 여기 들어오는 경우도 있어서)
          if ((level2 == null || level2.isEmpty) &&
              (p.subAdministrativeArea ?? '').trim().isNotEmpty) {
            final subArea = p.subAdministrativeArea!.trim();
            // 예외처리: 레벨2가 레벨1과 같으면 사용하지 않음
            if (subArea != level1) {
              level2 = subArea;
            }
          }

          // 3레벨 = subLocality (동, 면 등)
          String? level3;
          if ((p.subLocality ?? '').trim().isNotEmpty) {
            final subLocality = p.subLocality!.trim();
            // 예외처리: 레벨3가 레벨1이나 레벨2와 같으면 사용하지 않음
            if (subLocality != level1 && subLocality != level2) {
              level3 = subLocality;
            }
          }

          // 레벨들을 조합 (중복 제거)
          List<String> levels = [];
          if (level1.isNotEmpty) levels.add(level1);
          if (level2 != null && level2.isNotEmpty && !levels.contains(level2)) {
            levels.add(level2);
          }
          if (level3 != null && level3.isNotEmpty && !levels.contains(level3)) {
            levels.add(level3);
          }

          if (levels.isEmpty) {
            return '';
          }
          return levels.join(' '); // 최종 "서울특별시 강남구 역삼동" 이런 형식
        }

        final koreanLocation = buildRegion3Level(placemark);

        if (koreanLocation.isNotEmpty) {
          // 한글 주소 그대로 사용 (이미 중복 제거됨)
          final finalLocation = koreanLocation;

          if (mounted) {
            setState(() {
              _currentLocation = finalLocation;
            });
          }
          debugPrint('[Petgram] 📍 위치 정보 불러오기 성공: $_currentLocation');
        } else {
          if (mounted) {
            setState(() {
              _currentLocation = null;
            });
          }
          if (kDebugMode) {
            debugPrint('📍 위치 정보를 가져올 수 없습니다');
          }
          if (showSnackbar && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('위치 정보를 확인할 수 없습니다'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (kDebugMode) {
          debugPrint('📍 주소 정보를 가져올 수 없습니다');
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ 위치 정보 가져오기 실패: $e');
      debugPrint('[Petgram] ❌ Stack trace: ${StackTrace.current}');
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
      if (showSnackbar && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('위치 정보를 확인할 수 없습니다'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.black87,
          ),
        );
      }
    }
  }

  // 카메라 줌 레벨
  // UI 줌 스케일 (Transform.scale로 프리뷰만 확대)
  double _uiZoomScale = 1.0; // UI 확대 배율 (1.0 ~ 10.0)
  double _baseUiZoomScale = 1.0; // 핀치 시작 시 기준 배율
  static const double _uiZoomMin = 1.0;
  static const double _uiZoomMax = 10.0;
  static const List<double> _uiZoomPresets = [1.0, 2.0, 3.0, 5.0, 10.0];
  bool _isZooming = false; // 핀치 줌 진행 중 여부

  // 카메라 줌은 사용하지 않음 (UI 줌만 사용)
  double _selectedZoomRatio = 1.0; // 프리셋 버튼용 배율
  // Offset _zoomOffset = Offset.zero; // 줌 오프셋 - 제거됨
  // Offset _lastZoomFocalPoint = Offset.zero; // 마지막 줌 포커스 포인트 - 제거됨

  // 카메라 방향 (전면/후면)
  CameraLensDirection _cameraLensDirection = CameraLensDirection.back;

  // 초점 관련
  Offset? _focusPointRelative; // 초점 위치 (상대 좌표 0.0~1.0)
  bool _showFocusIndicator = false; // 초점 표시기 표시 여부
  bool _showAutoFocusIndicator = false; // 자동 초점 표시기 표시 여부
  Rect? _lastPreviewRect; // 프리뷰 박스 사각형 (SafeArea Stack 좌표계)
  Offset? _lastTapLocal; // 마지막 탭 위치 (프리뷰 박스 내부 로컬 좌표) - 카메라 계산용
  Rect? _focusIndicatorPreviewRect; // UI 인디케이터용 프리뷰 rect (SafeArea Stack 좌표계)
  Offset? _focusIndicatorLocal; // UI 인디케이터용 로컬 좌표
  final GlobalKey _previewKey = GlobalKey(); // 프리뷰 Positioned 위젯용 key

  // 밝기 조절 (-1.0 ~ 1.0, 0.0이 원본)
  double _brightnessValue = 0.0; // -10 ~ 10 범위

  // 펫톤 보정 저장 시 적용 여부 (디버그용 토글)
  // false로 설정하면 저장 시 펫톤 보정을 건너뜀 (필터 + 밝기만 적용)
  bool _enablePetToneOnSave = true;

  bool get _isPureOriginalMode =>
      _shootFilterKey == 'basic_none' && _brightnessValue == 0.0;

  // 아이콘 이미지 캐시
  ui.Image? _dogIconImage;
  ui.Image? _catIconImage;

  // Mockup 이미지 비율 캐시
  double? _mockupAspectRatio;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadLastSelectedFilter();
    _loadPetName();
    _loadAllSettings();
    loadFrameResources(); // 프레임 폰트와 로고 미리 로드
    _loadIconImages(); // 아이콘 이미지 미리 로드
  }

  /// 아이콘 이미지 및 mockup 비율 미리 로드
  Future<void> _loadIconImages() async {
    try {
      final ByteData dogData = await rootBundle.load('assets/icons/dog.png');
      final Uint8List dogBytes = dogData.buffer.asUint8List();
      final ui.Codec dogCodec = await ui.instantiateImageCodec(dogBytes);
      final ui.FrameInfo dogFrameInfo = await dogCodec.getNextFrame();
      _dogIconImage = dogFrameInfo.image;

      final ByteData catData = await rootBundle.load('assets/icons/cat.png');
      final Uint8List catBytes = catData.buffer.asUint8List();
      final ui.Codec catCodec = await ui.instantiateImageCodec(catBytes);
      final ui.FrameInfo catFrameInfo = await catCodec.getNextFrame();

      // Mockup 이미지 비율 로드
      try {
        final ByteData mockupData = await rootBundle.load(
          'assets/images/mockup.png',
        );
        final Uint8List mockupBytes = mockupData.buffer.asUint8List();
        final ui.Codec mockupCodec = await ui.instantiateImageCodec(
          mockupBytes,
        );
        final ui.FrameInfo mockupFrameInfo = await mockupCodec.getNextFrame();
        final mockupImage = mockupFrameInfo.image;
        _mockupAspectRatio = mockupImage.width / mockupImage.height;
        mockupImage.dispose();
        debugPrint(
          '[Petgram] 📐 Mockup 이미지 비율: ${_mockupAspectRatio} (${mockupImage.width}x${mockupImage.height})',
        );
      } catch (e) {
        debugPrint('[Petgram] ⚠️ Mockup 이미지 비율 로드 실패: $e, 기본값 9/16 사용');
        _mockupAspectRatio = 9 / 16;
      }
      _catIconImage = catFrameInfo.image;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] Failed to load icon images: $e');
      }
    }
  }

  Future<void> _loadLastSelectedFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFilter = prefs.getString(kLastSelectedFilterKey);
    if (savedFilter != null && _allFilters.containsKey(savedFilter)) {
      setState(() {
        _shootFilterKey = savedFilter;
      });
    }
  }

  Future<void> _saveSelectedFilter(String filterKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLastSelectedFilterKey, filterKey);
  }

  Future<void> _loadPetName() async {
    final prefs = await SharedPreferences.getInstance();
    final savedListJson = prefs.getStringList(kPetListKey);
    if (savedListJson != null && savedListJson.isNotEmpty) {
      try {
        final List<PetInfo> loadedPets = savedListJson
            .map(
              (json) => PetInfo.fromJson(
                Map<String, dynamic>.from(
                  (jsonDecode(json) as Map<dynamic, dynamic>).map(
                    (k, v) => MapEntry(k.toString(), v),
                  ),
                ),
              ),
            )
            .toList();
        // 저장된 선택된 반려동물 ID 로드
        final savedSelectedId = prefs.getString(kSelectedPetIdKey);
        setState(() {
          _petList = loadedPets;
          // 저장된 ID가 있고, 해당 반려동물이 리스트에 있으면 사용, 없으면 첫 번째 반려동물
          if (savedSelectedId != null &&
              loadedPets.any((pet) => pet.id == savedSelectedId)) {
            _selectedPetId = savedSelectedId;
          } else {
            _selectedPetId = loadedPets.isNotEmpty ? loadedPets.first.id : null;
          }
        });

        // 반려동물 정보 로드 후, 프레임이 활성화되어 있고 위치 정보가 활성화된 반려동물이 있으면 위치 정보 불러오기
        final frameEnabled = prefs.getBool(kFrameEnabledKey) ?? true;
        if (frameEnabled && _petList.isNotEmpty) {
          final selectedPet = _selectedPetId != null
              ? _petList.firstWhere(
                  (pet) => pet.id == _selectedPetId,
                  orElse: () => _petList.first,
                )
              : _petList.first;

          if (selectedPet.locationEnabled) {
            // 앱 시작 시: 위치 정보 불러오기
            _checkAndFetchLocation();
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('❌ _loadPetName error: $e');
        }
      }
    }
  }

  // 모든 설정 로드
  Future<void> _loadAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 플래시 모드
      final flashModeStr = prefs.getString(kFlashModeKey);
      if (flashModeStr != null) {
        switch (flashModeStr) {
          case 'off':
            _flashMode = FlashMode.off;
            break;
          case 'auto':
            _flashMode = FlashMode.auto;
            break;
          case 'always':
            _flashMode = FlashMode.always;
            break;
          case 'torch':
            _flashMode = FlashMode.torch;
            break;
        }
      }
      // 그리드라인
      _showGridLines = prefs.getBool(kShowGridLinesKey) ?? false;
      // 프레임 활성화
      _frameEnabled = prefs.getBool(kFrameEnabledKey) ?? true;
      // 연속 촬영 모드
      _isBurstMode = prefs.getBool(kBurstModeKey) ?? false;
      // 연속 촬영 매수
      _burstCountSetting = prefs.getInt(kBurstCountSettingKey) ?? 5;
      // 타이머 초
      _timerSeconds = prefs.getInt(kTimerSecondsKey) ?? 0;
      // 화면 비율
      final aspectModeStr = prefs.getString(kAspectModeKey);
      if (aspectModeStr != null) {
        switch (aspectModeStr) {
          case 'nineSixteen':
            _aspectMode = AspectRatioMode.nineSixteen;
            break;
          case 'threeFour':
            _aspectMode = AspectRatioMode.threeFour;
            break;
          case 'oneOne':
            _aspectMode = AspectRatioMode.oneOne;
            break;
        }
      }
    });
  }

  // 플래시 모드 저장
  Future<void> _saveFlashMode() async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'off';
    switch (_flashMode) {
      case FlashMode.off:
        modeStr = 'off';
        break;
      case FlashMode.auto:
        modeStr = 'auto';
        break;
      case FlashMode.always:
        modeStr = 'always';
        break;
      case FlashMode.torch:
        modeStr = 'torch';
        break;
    }
    await prefs.setString(kFlashModeKey, modeStr);
  }

  // 그리드라인 저장
  Future<void> _saveShowGridLines() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kShowGridLinesKey, _showGridLines);
  }

  // 프레임 활성화 저장
  Future<void> _saveFrameEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kFrameEnabledKey, _frameEnabled);
  }

  // 연속 촬영 설정 저장
  Future<void> _saveBurstSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBurstModeKey, _isBurstMode);
    await prefs.setInt(kBurstCountSettingKey, _burstCountSetting);
  }

  // 타이머 설정 저장
  Future<void> _saveTimerSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kTimerSecondsKey, _timerSeconds);
  }

  // 화면 비율 저장
  Future<void> _saveAspectMode() async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'threeFour';
    switch (_aspectMode) {
      case AspectRatioMode.nineSixteen:
        modeStr = 'nineSixteen';
        break;
      case AspectRatioMode.threeFour:
        modeStr = 'threeFour';
        break;
      case AspectRatioMode.oneOne:
        modeStr = 'oneOne';
        break;
    }
    await prefs.setString(kAspectModeKey, modeStr);
  }

  /// 이미지에 반려동물 이름과 촬영 시점을 프레임으로 추가 (새로운 구조)
  /// 비파괴적 함수: 내부에서 생성한 ui.Image를 dispose하지 않음 (PNG로 변환 완료 후 dispose)
  /// 이 함수는 File을 받아 File을 반환하므로, 내부 ui.Image는 PNG 변환 완료 후 dispose
  Future<File> _addPhotoFrame(File imageFile) async {
    // 내부에서 생성한 ui.Image들을 추적 (PNG 변환 완료 후 dispose)
    final List<ui.Image> imagesToDispose = [];

    try {
      final Uint8List imageBytes = await imageFile.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(imageBytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;
      imagesToDispose.add(image); // dispose 목록에 추가

      // 최종 캔버스 크기 (이미지 크기 그대로, 칩은 오버레이)
      final double finalWidth = image.width.toDouble();
      final double finalHeight = image.height.toDouble();

      // 캔버스 생성
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);

      // 1. 배경 레이어: 사진 (fit: cover)
      // 이미지를 fit: cover로 그리기
      final double imageAspect = image.width / image.height;
      final double canvasAspect = finalWidth / finalHeight;

      double drawWidth = finalWidth;
      double drawHeight = finalHeight;
      double drawX = 0;
      double drawY = 0;

      if (imageAspect > canvasAspect) {
        // 이미지가 더 넓음 → 높이에 맞춤
        drawHeight = finalHeight;
        drawWidth = drawHeight * imageAspect;
        drawX = (finalWidth - drawWidth) / 2;
      } else {
        // 이미지가 더 높음 → 너비에 맞춤
        drawWidth = finalWidth;
        drawHeight = drawWidth / imageAspect;
        drawY = (finalHeight - drawHeight) / 2;
      }

      // 이미지 그리기 (fit: cover)
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(drawX, drawY, drawWidth, drawHeight),
        Paint(),
      );

      // 2. 프레임 오버레이 (투명 영역 유지)
      // FramePainter와 동일한 로직 사용
      // 촬영 시점의 위치 정보 사용 (프레임 활성화 시 가져온 위치 정보)
      // 저장된 이미지에는 오버레이가 없으므로 전체 이미지가 촬영 영역
      // 프리뷰와 동일한 정규화 비율 계산
      // 촬영본에서: overlayTop / imageHeight = normalizedTop
      // 촬영본에서: normalizedTop * finalHeight = topBarHeight

      // 촬영본은 이미 크롭된 이미지이므로, 프레임 위치를 크롭된 이미지 기준으로 직접 계산
      // 프리뷰와 동일하게 프레임은 크롭된 이미지 상단에서 frameMargin만큼 아래에 배치
      final double frameMargin = finalWidth * 0.02;
      final double finalTopBarHeight = frameMargin;

      debugPrint(
        '[Petgram] 📸 _addPhotoFrame: image=${finalWidth}x${finalHeight}, frameMargin=$frameMargin, finalTopBarHeight=$finalTopBarHeight',
      );

      final framePainter = FramePainter(
        petList: _petList,
        selectedPetId: _selectedPetId,
        width: finalWidth,
        height: finalHeight,
        topBarHeight: finalTopBarHeight, // 프리뷰와 동일한 정규화 비율 사용
        bottomBarHeight: finalHeight, // 저장된 이미지 전체가 촬영 영역이므로 하단 = 이미지 하단
        dogIconImage: _dogIconImage,
        catIconImage: _catIconImage,
        location: _currentLocation, // 촬영 시점의 위치 정보 전달
      );
      framePainter.paint(canvas, Size(finalWidth, finalHeight));

      // Picture를 Image로 변환 (원본 해상도 유지)
      // pixelRatio: 1.0으로 고정하여 render pixel과 색 왜곡 방지
      final ui.Picture picture = recorder.endRecording();
      final ui.Image finalImage = await picture.toImage(
        finalWidth.toInt(),
        finalHeight.toInt(),
      );
      picture.dispose(); // Picture는 즉시 dispose 가능
      imagesToDispose.add(finalImage); // dispose 목록에 추가

      // PNG로 임시 인코딩
      final ByteData? byteData = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) {
        // 에러 발생 시 내부에서 생성한 ui.Image들 dispose
        for (final img in imagesToDispose) {
          try {
            img.dispose();
          } catch (e) {
            debugPrint('[HomePage] ⚠️ _addPhotoFrame 이미지 dispose 실패 (무시): $e');
          }
        }
        return imageFile;
      }

      final Uint8List framePngBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      // PNG를 디코딩하여 image 패키지로 변환
      final img.Image? decodedImage = img.decodeImage(framePngBytes);
      if (decodedImage == null) {
        // 에러 발생 시 내부에서 생성한 ui.Image들 dispose
        for (final img in imagesToDispose) {
          try {
            img.dispose();
          } catch (e) {
            debugPrint('[HomePage] ⚠️ _addPhotoFrame 이미지 dispose 실패 (무시): $e');
          }
        }
        return imageFile;
      }

      // 프레임 적용 후 RGB 평균값 로그
      final afterFrameRGB = _calculateAverageRGB(decodedImage);
      debugPrint(
        '[Petgram] 📊 After frame (PNG) - Avg RGB: R=${afterFrameRGB['r']!.toStringAsFixed(2)}, G=${afterFrameRGB['g']!.toStringAsFixed(2)}, B=${afterFrameRGB['b']!.toStringAsFixed(2)}',
      );

      // PNG로 재인코딩 (무손실 포맷, image 패키지로 최종 저장)
      final Uint8List finalPngBytes = Uint8List.fromList(
        img.encodePng(decodedImage),
      );

      // PNG 인코딩 후 디코딩하여 RGB 평균값 비교 (색 손실 최소화 확인)
      final img.Image? afterPngDecoded = img.decodeImage(finalPngBytes);
      if (afterPngDecoded != null) {
        final afterPngRGB = _calculateAverageRGB(afterPngDecoded);
        debugPrint(
          '[Petgram] 📊 After frame PNG encoding/decoding - Avg RGB: R=${afterPngRGB['r']!.toStringAsFixed(2)}, G=${afterPngRGB['g']!.toStringAsFixed(2)}, B=${afterPngRGB['b']!.toStringAsFixed(2)}',
        );
        debugPrint(
          '[Petgram] 📊 Frame PNG RGB diff - R=${(afterPngRGB['r']! - afterFrameRGB['r']!).toStringAsFixed(2)}, G=${(afterPngRGB['g']! - afterFrameRGB['g']!).toStringAsFixed(2)}, B=${(afterPngRGB['b']! - afterFrameRGB['b']!).toStringAsFixed(2)}',
        );
      }

      // 임시 파일로 저장 (PNG)
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/framed_${DateTime.now().millisecondsSinceEpoch}.png';
      final File framedFile = File(filePath);
      await framedFile.writeAsBytes(finalPngBytes);

      // PNG 변환 완료 후 내부에서 생성한 ui.Image들 dispose
      // 이 함수는 File을 받아 File을 반환하므로, PNG 변환 완료 후 dispose가 안전
      for (final img in imagesToDispose) {
        try {
          img.dispose();
        } catch (e) {
          debugPrint('[HomePage] ⚠️ _addPhotoFrame 이미지 dispose 실패 (무시): $e');
        }
      }

      return framedFile;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('❌ _addPhotoFrame error: $e');
        debugPrint('❌ _addPhotoFrame stack trace: $stackTrace');
      }
      // 에러 발생 시 내부에서 생성한 ui.Image들 dispose
      for (final img in imagesToDispose) {
        try {
          img.dispose();
        } catch (disposeError) {
          debugPrint(
            '[HomePage] ⚠️ _addPhotoFrame 이미지 dispose 실패 (무시): $disposeError',
          );
        }
      }
      return imageFile;
    }
  }

  /// 현재 선택된 반려동물의 펫톤 프로파일 가져오기
  PetToneProfile? _getCurrentPetToneProfile() {
    // 1) _petList, _selectedPetId 기반으로 현재 선택된 PetInfo 구하기
    if (_petList.isEmpty || _selectedPetId == null) {
      return null;
    }

    final selectedPet = _petList.firstWhere(
      (pet) => pet.id == _selectedPetId,
      orElse: () => _petList.first,
    );

    // 2) type이 'dog' / 'cat'이 아니면 null 리턴
    if (selectedPet.type != 'dog' && selectedPet.type != 'cat') {
      return null;
    }

    // 3) _liveCoatPreset (light/mid/dark/custom)으로 tone 결정
    String tone = _liveCoatPreset;
    if (tone == 'custom' ||
        (tone != 'light' && tone != 'mid' && tone != 'dark')) {
      // 'custom'이거나 예상 외 값이면 'mid'로 fallback
      tone = 'mid';
    }

    // 4) key = '${type}_${tone}' 형태로 kPetToneProfiles에서 찾아서 리턴
    final String profileKey = '${selectedPet.type}_$tone';
    return kPetToneProfiles[profileKey];
  }

  // [PERF] GPU 캡처 방식으로 저장 경로 변경
  // img.Image를 ui.Image로 변환하는 헬퍼 함수
  Future<ui.Image> _convertImgImageToUiImage(img.Image image) async {
    final Uint8List pngBytes = Uint8List.fromList(img.encodePng(image));
    final ui.Codec codec = await ui.instantiateImageCodec(pngBytes);
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    return frameInfo.image;
  }

  // [PERF] GPU 캡처 방식으로 저장 경로 변경
  // GPU 기반 색 보정 적용 (ui.PictureRecorder와 Canvas 사용)
  // 프리뷰와 동일한 ColorMatrix 로직 사용
  Future<ui.Image> _applyColorMatrixToUiImageGpu(
    ui.Image image,
    List<double> matrix,
  ) async {
    // matrix가 identity면 원본 반환
    if (_listEquals(matrix, kIdentityMatrix)) {
      return image;
    }

    final int width = image.width;
    final int height = image.height;

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
    final ui.Picture picture = recorder.endRecording();
    final ui.Image result = await picture.toImage(width, height);
    picture.dispose();

    return result;
  }

  // [PERF] GPU 캡처 방식으로 저장 경로 변경
  // 프리뷰와 동일한 ColorMatrix 생성 로직
  List<double> _buildColorMatrixForSave() {
    if (_isPureOriginalMode) {
      debugPrint(
        '[Petgram] 🎨 [SAVE PIPELINE] Pure original mode, skipping all color adjustments',
      );
      return List.from(kIdentityMatrix);
    }

    final petProfile = _getCurrentPetToneProfile();
    final PetFilter? currentFilter = _allFilters[_shootFilterKey];

    List<double> base = List.from(kIdentityMatrix);

    // 1. 펫톤 보정 적용 (프리뷰와 동일하게 약하게 적용)
    if (petProfile != null && _enablePetToneOnSave) {
      final petToneMatrix = mixMatrix(
        kIdentityMatrix,
        petProfile.matrix,
        0.4, // 40% 강도로 약하게 적용
      );
      base = multiplyColorMatrices(base, petToneMatrix);
    }

    // 2. 필터 행렬 적용
    if (currentFilter != null && currentFilter.key != 'basic_none') {
      final filterMatrix = mixMatrix(
        kIdentityMatrix,
        currentFilter.matrix,
        _liveIntensity,
      );
      base = multiplyColorMatrices(base, filterMatrix);
    }

    // 3. 밝기 조절 적용
    if (_brightnessValue != 0.0) {
      final double brightnessOffset = (_brightnessValue / 10.0) * 255 * 0.1;
      final List<double> brightnessMatrix = [
        1,
        0,
        0,
        0,
        brightnessOffset,
        0,
        1,
        0,
        0,
        brightnessOffset,
        0,
        0,
        1,
        0,
        brightnessOffset,
        0,
        0,
        0,
        1,
        0,
      ];
      base = multiplyColorMatrices(base, brightnessMatrix);
    }

    return base;
  }

  /// [PERF] 동기 버전 _applyColorMatrixToImage 제거됨
  /// 비동기 버전(_applyColorMatrixToImage)만 유지 (FilterPage 등에서 사용)
  /// 메인 저장 경로(_takePhoto)는 GPU 캡처 방식으로 변경됨

  Future<void> _initCamera() async {
    if (kDebugMode) {
      debugPrint(
        '[Petgram] _initCamera() called, widget.cameras.length = ${widget.cameras.length}',
      );
    }

    // 우선 상위에서 전달된 카메라 리스트를 사용
    List<CameraDescription> cams = widget.cameras;

    // 만약 상위에서 카메라 리스트를 제대로 못 받아왔다면 여기서 한 번 더 직접 조회
    if (cams.isEmpty) {
      try {
        cams = await availableCameras();
        if (kDebugMode) {
          debugPrint(
            '[Petgram] availableCameras() from HomePage, length = ${cams.length}',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Petgram] availableCameras() error inside HomePage: $e');
        }
      }
    }

    // 그래도 카메라가 하나도 없으면 목업 모드로 전환
    if (cams.isEmpty) {
      if (mounted) {
        setState(() {
          _isCameraInitializing = false;
          _useMockCamera = true;
          _cameraController = null;
          _uiZoomScale = _uiZoomMin;
          _baseUiZoomScale = _uiZoomMin;
          _selectedZoomRatio = _uiZoomScale;
        });
      }
      return;
    }

    // 디폴트는 후면 카메라
    final selectedCamera = cams.firstWhere(
      (c) => c.lensDirection == _cameraLensDirection,
      orElse: () {
        // 원하는 방향의 카메라가 없으면 후면 카메라를 우선 찾고, 없으면 첫 번째 카메라
        return cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first,
        );
      },
    );

    // 연속 촬영 성능을 고려하여 화질 설정
    // veryHigh는 연속 촬영 시 성능 저하가 있을 수 있으므로 high로 변경
    // high도 충분히 고화질이며 연속 촬영 성능이 더 좋음
    final controller = CameraController(
      selectedCamera,
      ResolutionPreset.high, // 연속 촬영 성능 고려하여 high로 변경 (veryHigh -> high)
      enableAudio: false,
    );

    try {
      await controller.initialize();
      // 전면 카메라는 플래시를 지원하지 않으므로 플래시 모드 설정 전에 체크
      if (selectedCamera.lensDirection == CameraLensDirection.front) {
        // 전면 카메라는 플래시를 끄고 상태 업데이트
        if (_flashMode != FlashMode.off) {
          setState(() {
            _flashMode = FlashMode.off;
          });
          _saveFlashMode();
          debugPrint('[Petgram] ⚠️ 전면 카메라는 플래시를 지원하지 않아 플래시를 끕니다');
        }
      } else {
        // 후면 카메라는 플래시 모드 설정 시도
        try {
          await controller.setFlashMode(_flashMode);
        } catch (e) {
          debugPrint('[Petgram] ⚠️ 플래시 모드 설정 실패: $e');
          // 플래시 설정 실패 시 off로 설정
          setState(() {
            _flashMode = FlashMode.off;
          });
        }
      }
      // 자동 초점 모드 설정 및 리스너 추가
      try {
        await controller.setFocusMode(FocusMode.auto);
        debugPrint('[Petgram] ✅ 자동 초점 모드 설정 완료');
        // 자동 초점 상태 리스너 추가
        controller.addListener(_onCameraValueChanged);
      } catch (e) {
        debugPrint('[Petgram] ⚠️ 자동 초점 모드 설정 실패: $e');
      }
      // 초기 줌 레벨 설정 및 카메라 줌 범위 저장
      try {
        final cameraMinZoom = await controller.getMinZoomLevel();
        final cameraMaxZoom = await controller.getMaxZoomLevel();
        _uiZoomScale = _uiZoomMin;
        _baseUiZoomScale = _uiZoomMin;
        _selectedZoomRatio = _uiZoomScale;
        debugPrint(
          '[Petgram] 📐 카메라 줌 범위(참고용): min=$cameraMinZoom, max=$cameraMaxZoom, '
          'uiRange=$_uiZoomMin~$_uiZoomMax',
        );
      } catch (e) {
        _uiZoomScale = _uiZoomMin;
        _baseUiZoomScale = _uiZoomMin;
        _selectedZoomRatio = _uiZoomScale;
        debugPrint('[Petgram] ⚠️ 줌 범위 가져오기 실패, 기본값 사용: $e');
      }
      if (!mounted) return;

      // 카메라 초기화 후 실제 비율 확인 및 로그 출력
      final actualAspectRatio = controller.value.aspectRatio;
      debugPrint(
        '[Petgram] 📐 카메라 초기화 완료 - 실제 비율: $actualAspectRatio (${actualAspectRatio > 0 ? (1 / actualAspectRatio).toStringAsFixed(3) : "N/A"}:1)',
      );

      setState(() {
        _cameraController = controller;
        _isCameraInitializing = false;
        _useMockCamera = false;
        // UI 줌 제거: 카메라 줌만 사용
      });

      // 최초 진입 시 화면 중앙에 자동 초점 설정
      _setAutoFocusAtCenter();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] camera init error: $e');
      }
      if (!mounted) return;
      setState(() {
        _isCameraInitializing = false;
        _useMockCamera = true;
        _cameraController = null;
        _uiZoomScale = _uiZoomMin;
        _baseUiZoomScale = _uiZoomMin;
        _selectedZoomRatio = _uiZoomScale;
      });

      // 카메라 초기화 실패 시 사용자에게 안내 (권한 거부 가능성)
      if (mounted &&
          (e.toString().contains('permission') ||
              e.toString().contains('Permission'))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('카메라 권한이 필요합니다. 설정에서 권한을 허용해주세요.'),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 4),
              ),
            );
          }
        });
      }
    }
  }

  /// 카메라 값 변경 리스너 (자동 초점 상태 감지)
  /// 현재는 사용하지 않지만, 향후 자동 초점 상태 변화 감지 시 사용 가능
  void _onCameraValueChanged() {
    // 자동 초점은 _setAutoFocusAtCenter()에서 직접 처리하므로
    // 여기서는 추가 처리 불필요
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _cameraController?.removeListener(_onCameraValueChanged);
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _playDogSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/dog_bark.mp3'));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] dog sound error: $e');
      }
    }
  }

  Future<void> _playCatSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/cat_meow.mp3'));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] cat sound error: $e');
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_useMockCamera) {
      setState(() {
        _flashMode = _flashMode == FlashMode.off
            ? FlashMode.torch
            : FlashMode.off;
      });
      _saveFlashMode();
      return;
    }
    if (_cameraController == null) return;

    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _cameraController!.setFlashMode(next);
      setState(() => _flashMode = next);
      _saveFlashMode();
    } catch (_) {}
  }

  Future<void> _switchCamera() async {
    if (_useMockCamera || widget.cameras.isEmpty) return;

    // 현재 방향의 반대 방향으로 전환
    final newDirection = _cameraLensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    // 새로운 방향의 카메라 찾기
    final newCamera = widget.cameras.firstWhere(
      (c) => c.lensDirection == newDirection,
      orElse: () => widget.cameras.first,
    );

    // 기존 컨트롤러 해제
    await _cameraController?.dispose();

    // 새 컨트롤러 생성
    setState(() {
      _isCameraInitializing = true;
      _cameraLensDirection = newDirection;
    });

    // 연속 촬영 성능을 고려하여 화질 설정
    // veryHigh는 연속 촬영 시 성능 저하가 있을 수 있으므로 high로 변경
    // high도 충분히 고화질이며 연속 촬영 성능이 더 좋음
    final controller = CameraController(
      newCamera,
      ResolutionPreset.high, // 연속 촬영 성능 고려하여 high로 변경 (veryHigh -> high)
      enableAudio: false,
    );

    try {
      await controller.initialize();
      // 전면 카메라는 플래시를 지원하지 않으므로 플래시 모드 설정 전에 체크
      if (newDirection == CameraLensDirection.front) {
        // 전면 카메라는 플래시를 끄고 상태 업데이트
        if (_flashMode != FlashMode.off) {
          setState(() {
            _flashMode = FlashMode.off;
          });
          _saveFlashMode();
          debugPrint('[Petgram] ⚠️ 전면 카메라는 플래시를 지원하지 않아 플래시를 끕니다');
        }
      } else {
        // 후면 카메라는 플래시 모드 설정 시도
        try {
          await controller.setFlashMode(_flashMode);
        } catch (e) {
          debugPrint('[Petgram] ⚠️ 플래시 모드 설정 실패: $e');
          // 플래시 설정 실패 시 off로 설정
          setState(() {
            _flashMode = FlashMode.off;
          });
        }
      }
      // 자동 초점 모드 설정 및 리스너 추가
      try {
        await controller.setFocusMode(FocusMode.auto);
        debugPrint('[Petgram] ✅ 자동 초점 모드 설정 완료 (카메라 전환)');
        // 자동 초점 상태 리스너 추가
        controller.addListener(_onCameraValueChanged);
      } catch (e) {
        debugPrint('[Petgram] ⚠️ 자동 초점 모드 설정 실패: $e');
      }
      // 줌 레벨 설정 및 카메라 줌 범위 저장
      try {
        final cameraMinZoom = await controller.getMinZoomLevel();
        final cameraMaxZoom = await controller.getMaxZoomLevel();
        _uiZoomScale = _uiZoomMin;
        _baseUiZoomScale = _uiZoomMin;
        _selectedZoomRatio = _uiZoomScale;
        debugPrint(
          '[Petgram] 📐 카메라 전환 - 참고용 줌 범위: min=$cameraMinZoom, max=$cameraMaxZoom, '
          'uiRange=$_uiZoomMin~$_uiZoomMax',
        );
      } catch (e) {
        _uiZoomScale = _uiZoomMin;
        _baseUiZoomScale = _uiZoomMin;
        _selectedZoomRatio = _uiZoomScale;
        debugPrint('[Petgram] ⚠️ 줌 범위 가져오기 실패, 기본값 사용: $e');
      }
      if (!mounted) return;

      // 카메라 전환 후 실제 비율 확인 및 로그 출력
      final actualAspectRatio = controller.value.aspectRatio;
      debugPrint(
        '[Petgram] 📐 카메라 전환 완료 - 실제 비율: $actualAspectRatio (${actualAspectRatio > 0 ? (1 / actualAspectRatio).toStringAsFixed(3) : "N/A"}:1)',
      );

      setState(() {
        _cameraController = controller;
        _isCameraInitializing = false;
        _useMockCamera = false;
        // 셀카모드 전환 시 비율 재계산을 위해 강제 리빌드
        // UI 줌 제거: 카메라 줌만 사용
      });

      // 카메라 전환 시에도 화면 중앙에 자동 초점 설정
      _setAutoFocusAtCenter();

      HapticFeedback.lightImpact();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] camera switch error: $e');
      }
      if (!mounted) return;
      setState(() {
        _isCameraInitializing = false;
        _useMockCamera = true;
        _cameraController = null;
        _uiZoomScale = _uiZoomMin;
        _baseUiZoomScale = _uiZoomMin;
        _selectedZoomRatio = _uiZoomScale;
      });
    }
  }

  void _changeAspectMode(AspectRatioMode mode) {
    if (_aspectMode == mode) {
      return;
    }
    setState(() {
      _aspectMode = mode;
      // UI 줌 제거: 카메라 줌만 사용 (비율 변경 시 UI 줌 리셋 불필요)
    });
    _saveAspectMode();

    // previewRect를 즉시 업데이트 (postFrameCallback 사용)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? previewContext = _previewKey.currentContext;
      if (previewContext != null) {
        _updatePreviewRectFromContext(previewContext);
        debugPrint(
          '[Petgram] 📐 Aspect ratio changed to ${_aspectLabel(mode)}, previewRect updated',
        );
      } else {
        debugPrint(
          '[Petgram] ⚠️ Aspect ratio changed but previewContext is null, will retry',
        );
        // 컨텍스트가 아직 준비되지 않았으면 약간의 지연 후 재시도
        Future.delayed(const Duration(milliseconds: 100), () {
          if (!mounted) return;
          final BuildContext? retryContext = _previewKey.currentContext;
          if (retryContext != null) {
            _updatePreviewRectFromContext(retryContext);
            debugPrint('[Petgram] 📐 previewRect updated (retry)');
          }
        });
      }
    });

    // 프리뷰 강제 업데이트를 위해 약간의 지연 후 다시 빌드
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<File> _createTempFileFromAsset(String assetPath) async {
    final byteData = await rootBundle.load(assetPath);
    final buffer = byteData.buffer;
    final dir = await getTemporaryDirectory();
    final filePath =
        '${dir.path}/mock_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File(filePath);
    await file.writeAsBytes(
      buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
      flush: true,
    );
    return file;
  }

  /// 타이머 카운트다운 시작
  Future<void> _startTimerCountdown() async {
    if (_timerSeconds == 0 || _isTimerCounting) return;

    // 원래 타이머 설정값 저장
    final originalTimerSeconds = _timerSeconds;
    setState(() {
      _isTimerCounting = true;
      _shouldStopTimer = false;
    });

    for (int i = _timerSeconds; i > 0; i--) {
      if (!mounted || _shouldStopTimer) {
        setState(() {
          _isTimerCounting = false;
          _shouldStopTimer = false;
          _timerSeconds = originalTimerSeconds;
        });
        // 타이머 강제 종료 시 스낵바 표시 제거 (사용자 요청)
        return;
      }
      setState(() => _timerSeconds = i);
      HapticFeedback.lightImpact();

      // 1초 대기 중에도 중지 요청을 체크할 수 있도록 0.1초씩 나눠서 대기
      for (int j = 0; j < 10; j++) {
        if (!mounted || _shouldStopTimer) {
          debugPrint('🛑 타이머 카운트다운 중지됨 (대기 중: $_shouldStopTimer)');
          setState(() {
            _isTimerCounting = false;
            _shouldStopTimer = false;
            _timerSeconds = originalTimerSeconds;
          });
          // 타이머 강제 종료 시 스낵바 표시 제거 (사용자 요청)
          return;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    if (!mounted || _shouldStopTimer) {
      setState(() {
        _isTimerCounting = false;
        _shouldStopTimer = false;
        _timerSeconds = originalTimerSeconds;
      });
      // 타이머 강제 종료 시 스낵바 표시 제거 (사용자 요청)
      return;
    }

    setState(() {
      // 타이머 설정값 유지 (0으로 리셋하지 않음)
      _timerSeconds = originalTimerSeconds;
      _isTimerCounting = false;
      _isTimerTriggered = true; // 타이머로 인한 촬영임을 표시
    });

    // 타이머 종료 후 촬영 (한 번만)
    // 연속 촬영 모드가 활성화되어 있으면 연속 촬영이 실행됨
    await _takePhoto();

    // 타이머로 인한 촬영 완료 후 플래그 리셋
    // 연속 촬영이 완료될 때까지 기다림 (최대 10초)
    if (mounted) {
      int waitCount = 0;
      // 연속 촬영이 활성화되어 있고 아직 진행 중이면 대기
      while (_isBurstMode && _burstCount > 0 && mounted && waitCount < 200) {
        await Future.delayed(const Duration(milliseconds: 50));
        waitCount++;
      }
      // 연속 촬영이 완료되거나 대기 시간이 지나면 플래그 리셋
      if (mounted) {
        setState(() {
          _isTimerTriggered = false;
        });
        debugPrint('✅ 타이머 촬영 완료, 플래그 리셋 (대기: ${waitCount * 50}ms)');
      }
    }
  }

  /// 사진 촬영 → 바로 저장 (화면 전환 없음)
  Future<void> _takePhoto() async {
    if (_isProcessing) return;

    // 타이머 모드인 경우 카운트다운 시작 (타이머로 인한 촬영이 아니고, 연속 촬영이 진행 중이 아닐 때만)
    if (_timerSeconds > 0 &&
        !_isTimerCounting &&
        !_isTimerTriggered &&
        _burstCount == 0) {
      await _startTimerCountdown();
      return;
    }

    // 타이머 카운트다운 중이면 촬영하지 않음
    if (_isTimerCounting) return;

    // 연속 촬영 모드 초기화 (촬영 시작 시)
    // 타이머로 인한 촬영이거나 일반 촬영 모두 연속 촬영 가능
    if (_isBurstMode && _burstCount == 0) {
      setState(() {
        _burstCount = 1; // 첫 장부터 카운팅 시작
        _shouldStopBurst = false;
      });
      debugPrint('📸 연속 촬영 시작: $_burstCountSetting장 (타이머: $_isTimerTriggered)');
    }

    setState(() => _isProcessing = true);

    // ui.Image 메모리 관리를 위한 변수 (외부 스코프에서 선언하여 finally에서 접근 가능)
    ui.Image? uiImageForDispose;
    final List<ui.Image> imagesToDispose = []; // dispose할 이미지 목록

    try {
      File file;
      if (_useMockCamera || _cameraController == null) {
        file = await _createTempFileFromAsset('assets/images/mockup.png');
      } else {
        final XFile xfile = await _cameraController!.takePicture();
        file = File(xfile.path);
      }

      // 이미지 처리 파이프라인: 선명도 먼저 적용 → 필터와 자동보정 색상 조정을 함께 적용
      File processedFile = file;

      try {
        // 1. 이미지 디코딩
        // 통합 이미지 로딩 헬퍼 사용 (PNG/JPG/HEIC 모두 지원, EXIF 회전 처리)
        img.Image? decodedImage = await loadImageWithExifRotation(
          processedFile,
        );

        if (decodedImage == null) {
          throw Exception('이미지 디코딩 실패: ${processedFile.path}');
        }

        // 1. 프리뷰에서 사용한 비율/프레임 위치 기억
        // 프리뷰에서 계산한 오버레이 영역을 원본 이미지 해상도로 변환
        final double targetRatio = aspectRatioOf(_aspectMode);
        final double currentRatio = decodedImage.width / decodedImage.height;

        if (kDebugMode) {
          debugPrint(
            '🔍 크롭 전: ${decodedImage.width}x${decodedImage.height}, 현재 비율: ${currentRatio.toStringAsFixed(3)}, 목표 비율: ${targetRatio.toStringAsFixed(3)}',
          );
        }

        // 2. 원본 이미지 해상도 기준으로 프레임에 해당하는 Rect 계산
        // 프리뷰에서 오버레이가 없는 영역을 원본 이미지 해상도로 변환
        final double imageWidth = decodedImage.width.toDouble();
        final double imageHeight = decodedImage.height.toDouble();

        // 목표 비율에 맞는 높이 계산
        final double targetHeight = imageWidth / targetRatio;

        // 상하단 오버레이 계산 (원본 이미지 기준)
        double overlayTop = 0;
        double overlayBottom = 0;
        if (targetHeight < imageHeight) {
          // 비율이 더 넓은 경우 (예: 1:1, 3:4) - 상하단에 오버레이
          overlayTop = (imageHeight - targetHeight) / 2;
          overlayBottom = (imageHeight - targetHeight) / 2;
        }
        // 비율이 더 긴 경우 (예: 9:16) - 상하단 오버레이 없음

        // 실제 촬영 영역 (오버레이가 없는 부분) - 원본 이미지 해상도 기준
        final double cropX = 0; // 가로는 항상 0부터
        final double cropY = overlayTop; // 상단 오버레이 아래부터
        final double cropWidth = imageWidth; // 가로는 100% 유지
        final double cropHeight =
            imageHeight - overlayTop - overlayBottom; // 오버레이 제외한 높이

        // 3. 이미지 라이브러리로 해당 Rect만 크롭
        if (cropHeight > 0 && cropY + cropHeight <= imageHeight) {
          decodedImage = img.copyCrop(
            decodedImage,
            x: cropX.round(),
            y: cropY.round(),
            width: cropWidth.round(),
            height: cropHeight.round(),
          );

          final double finalRatio = decodedImage.width / decodedImage.height;
          if (kDebugMode) {
            debugPrint(
              '✅ 이미지 크롭 완료 (오버레이 제외): ${decodedImage.width}x${decodedImage.height}, 최종 비율: ${finalRatio.toStringAsFixed(3)}, 목표: ${targetRatio.toStringAsFixed(3)}',
            );
            debugPrint(
              '📐 크롭 영역: x=${cropX.round()}, y=${cropY.round()}, width=${cropWidth.round()}, height=${cropHeight.round()}',
            );
            // 비율 검증: 목표 비율과 최종 비율이 거의 일치하는지 확인 (0.01 이내 오차 허용)
            final double ratioDiff = (finalRatio - targetRatio).abs();
            if (ratioDiff > 0.01) {
              debugPrint(
                '⚠️ 비율 차이 감지: 차이=${ratioDiff.toStringAsFixed(4)}, 목표=${targetRatio.toStringAsFixed(3)}, 실제=${finalRatio.toStringAsFixed(3)}',
              );
            } else {
              debugPrint('✅ 비율 검증 통과: 차이=${ratioDiff.toStringAsFixed(4)}');
            }

            // 프리뷰 박스와 최종 이미지 비율 비교
            debugPrint(
              '📐 프리뷰 박스 vs 최종 이미지: targetRatio=$targetRatio, finalImageRatio=$finalRatio, 일치 여부=${ratioDiff < 0.01 ? "✅ 일치" : "⚠️ 불일치"}',
            );
          }
        } else {
          // 크롭할 영역이 없거나 잘못된 경우
          if (kDebugMode) {
            debugPrint(
              '⚠️ 크롭 영역이 유효하지 않음: cropY=$cropY, cropHeight=$cropHeight, imageHeight=$imageHeight',
            );
          }
        }

        // 3. UI 줌 적용 전 해상도 저장 (최종 저장 해상도 기준)
        // 비율 맞춤 크롭 후의 해상도를 기준으로 사용
        final int finalTargetWidth = decodedImage.width;
        final int finalTargetHeight = decodedImage.height;

        // 4. UI 줌 스케일에 따른 중앙 크롭 적용 (프리뷰와 동일한 확대 연출)
        double effectiveZoom = _uiZoomScale.isFinite
            ? _uiZoomScale
            : _uiZoomMin;
        if (effectiveZoom < _uiZoomMin) {
          effectiveZoom = _uiZoomMin;
        } else if (effectiveZoom > _uiZoomMax) {
          effectiveZoom = _uiZoomMax;
        }

        if (effectiveZoom > 1.0) {
          final double zoomCropWidth = decodedImage.width / effectiveZoom;
          final double zoomCropHeight = decodedImage.height / effectiveZoom;

          if (zoomCropWidth >= 1 && zoomCropHeight >= 1) {
            int zoomWidth = zoomCropWidth.round();
            int zoomHeight = zoomCropHeight.round();
            zoomWidth = zoomWidth.clamp(1, decodedImage.width);
            zoomHeight = zoomHeight.clamp(1, decodedImage.height);

            int zoomX = ((decodedImage.width - zoomWidth) / 2).round();
            int zoomY = ((decodedImage.height - zoomHeight) / 2).round();
            zoomX = zoomX.clamp(0, math.max(0, decodedImage.width - zoomWidth));
            zoomY = zoomY.clamp(
              0,
              math.max(0, decodedImage.height - zoomHeight),
            );

            decodedImage = img.copyCrop(
              decodedImage,
              x: zoomX,
              y: zoomY,
              width: zoomWidth,
              height: zoomHeight,
            );

            if (kDebugMode) {
              debugPrint(
                '🔍 UI 줌 크롭 적용 (scale=${effectiveZoom.toStringAsFixed(2)}): '
                'x=$zoomX, y=$zoomY, width=$zoomWidth, height=$zoomHeight',
              );
            }
          } else {
            debugPrint(
              '⚠️ UI 줌 크롭을 건너뜀: 계산된 크기가 유효하지 않음 '
              '(width=$zoomCropWidth, height=$zoomCropHeight)',
            );
          }
        }

        // 5. 최종 저장 해상도로 리사이즈 (줌 배율과 상관없이 항상 동일한 해상도 유지)
        // UI 줌 크롭 후 크기가 작아졌을 수 있으므로, 원래 해상도로 복원
        if (decodedImage.width != finalTargetWidth ||
            decodedImage.height != finalTargetHeight) {
          decodedImage = img.copyResize(
            decodedImage,
            width: finalTargetWidth,
            height: finalTargetHeight,
            interpolation: img.Interpolation.cubic,
          );

          if (kDebugMode) {
            debugPrint(
              '🔄 최종 해상도로 리사이즈: '
              '${decodedImage.width}x${decodedImage.height} → ${finalTargetWidth}x${finalTargetHeight}',
            );
          }
        }

        // [PERF] GPU 캡처 방식으로 저장 경로 변경
        // CPU 기반 픽셀 루프 제거, GPU 기반 ColorFilter 적용

        // [PERF] GPU 캡처 방식으로 저장 경로 변경
        // CPU 기반 픽셀 루프 대신 GPU 기반 ColorFilter 적용
        debugPrint(
          '[Petgram] 🚀 [PERF] Using GPU capture for color correction',
        );

        // img.Image를 ui.Image로 변환
        ui.Image uiImage = await _convertImgImageToUiImage(decodedImage);
        uiImageForDispose = uiImage; // finally 블록에서 dispose하기 위해 저장

        // 프리뷰와 동일한 ColorMatrix 생성
        final colorMatrix = _buildColorMatrixForSave();

        // [MATRIX 비교] Preview Matrix vs Save Matrix 로그 (HomePage)
        // _buildFilteredWidgetLive의 matrix 계산 로직을 직접 호출하여 비교
        List<double> previewMatrixForCompare = List.from(kIdentityMatrix);
        final petProfile = _getCurrentPetToneProfile();
        if (petProfile != null) {
          final petToneMatrix = mixMatrix(
            kIdentityMatrix,
            petProfile.matrix,
            0.4,
          );
          previewMatrixForCompare = multiplyColorMatrices(
            previewMatrixForCompare,
            petToneMatrix,
          );
        }
        final PetFilter? currentFilter = _allFilters[_shootFilterKey];
        if (currentFilter != null && currentFilter.key != 'basic_none') {
          final filterMatrix = mixMatrix(
            kIdentityMatrix,
            currentFilter.matrix,
            _liveIntensity,
          );
          previewMatrixForCompare = multiplyColorMatrices(
            previewMatrixForCompare,
            filterMatrix,
          );
        }
        if (_brightnessValue != 0.0) {
          final double brightnessOffset = (_brightnessValue / 10.0) * 255 * 0.1;
          final List<double> brightnessMatrix = [
            1,
            0,
            0,
            0,
            brightnessOffset,
            0,
            1,
            0,
            0,
            brightnessOffset,
            0,
            0,
            1,
            0,
            brightnessOffset,
            0,
            0,
            0,
            1,
            0,
          ];
          previewMatrixForCompare = multiplyColorMatrices(
            previewMatrixForCompare,
            brightnessMatrix,
          );
        }

        debugPrint(
          '[Petgram] 🔍 [HOMEPAGE MATRIX COMPARISON] Preview Matrix = ${previewMatrixForCompare.join(', ')}',
        );
        debugPrint(
          '[Petgram] 🔍 [HOMEPAGE MATRIX COMPARISON] Save Matrix = ${colorMatrix.join(', ')}',
        );

        // Matrix 차이 계산
        bool matricesMatch = true;
        for (int i = 0; i < 20; i++) {
          final diff = (previewMatrixForCompare[i] - colorMatrix[i]).abs();
          if (diff > 0.0001) {
            matricesMatch = false;
            debugPrint(
              '[Petgram] ⚠️ [HOMEPAGE MATRIX COMPARISON] Difference at index $i: preview=${previewMatrixForCompare[i]}, save=${colorMatrix[i]}, diff=$diff',
            );
          }
        }
        if (matricesMatch) {
          debugPrint(
            '[Petgram] ✅ [HOMEPAGE MATRIX COMPARISON] Preview and Save matrices are IDENTICAL',
          );
        } else {
          debugPrint(
            '[Petgram] ⚠️ [HOMEPAGE MATRIX COMPARISON] Preview and Save matrices are DIFFERENT',
          );
        }

        // Context 정보 로그
        debugPrint(
          '[Petgram] 🔍 [HOMEPAGE MATRIX COMPARISON] Context: petProfile=${petProfile?.id ?? 'none'}, '
          'filter=${currentFilter?.key ?? 'none'}, intensity=$_liveIntensity, brightness=$_brightnessValue, '
          'coatPreset=$_liveCoatPreset, enablePetToneOnSave=$_enablePetToneOnSave',
        );

        // GPU에서 ColorFilter 적용
        // 비파괴적 함수: 새로운 이미지를 반환하므로 이전 이미지는 추적하여 finally에서 dispose
        ui.Image? previousUiImage;
        if (!_listEquals(colorMatrix, kIdentityMatrix)) {
          previousUiImage = uiImage; // 이전 이미지 추적
          uiImage = await _applyColorMatrixToUiImageGpu(uiImage, colorMatrix);
          // 이전 이미지가 새 이미지와 다른 경우에만 dispose 목록에 추가
          if (previousUiImage != uiImage) {
            imagesToDispose.add(previousUiImage); // finally에서 dispose
          }
          uiImageForDispose = uiImage; // 최신 이미지는 최종적으로 dispose
        } else {
          // ColorMatrix가 identity면 이미지가 그대로 반환되므로 uiImageForDispose만 설정
          uiImageForDispose = uiImage;
        }

        // ui.Image를 PNG 바이트로 변환 (안정화 + fallback)
        Uint8List? pngBytes;

        // 첫 번째 시도: GPU 렌더 캡처 방식
        try {
          final ByteData? byteData = await uiImage.toByteData(
            format: ui.ImageByteFormat.png,
          );

          if (byteData != null && byteData.lengthInBytes > 0) {
            pngBytes = byteData.buffer.asUint8List(
              byteData.offsetInBytes,
              byteData.lengthInBytes,
            );
            debugPrint('[HomePage] ✅ GPU 렌더 캡처 성공: ${pngBytes.length} bytes');
          } else {
            debugPrint('[HomePage] ⚠️ toByteData가 null 또는 빈 데이터 반환');
          }
        } catch (e) {
          debugPrint('[HomePage] ⚠️ GPU 렌더 캡처 실패: $e');
        }

        // Fallback: img.Image로 직접 PNG 인코딩
        if (pngBytes == null || pngBytes.isEmpty) {
          debugPrint('[HomePage] 🔄 Fallback: img.Image 직접 PNG 인코딩 시도');
          try {
            // ui.Image를 img.Image로 변환 후 PNG 인코딩
            final ByteData? rgbaData = await uiImage.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );

            if (rgbaData != null) {
              // img.Image 객체 생성
              final fallbackImage = img.Image(
                width: uiImage.width,
                height: uiImage.height,
              );

              final pixels = rgbaData.buffer.asUint8List();
              for (int y = 0; y < uiImage.height; y++) {
                for (int x = 0; x < uiImage.width; x++) {
                  final index = (y * uiImage.width + x) * 4;
                  final r = pixels[index];
                  final g = pixels[index + 1];
                  final b = pixels[index + 2];
                  final a = pixels[index + 3];
                  fallbackImage.setPixel(x, y, img.ColorRgba8(r, g, b, a));
                }
              }

              pngBytes = Uint8List.fromList(img.encodePng(fallbackImage));
              debugPrint(
                '[HomePage] ✅ Fallback PNG 인코딩 성공: ${pngBytes.length} bytes',
              );
            }
          } catch (e) {
            debugPrint('[HomePage] ❌ Fallback PNG 인코딩 실패: $e');
            throw Exception('PNG 인코딩 실패: 모든 방식이 실패했습니다.');
          }
        }

        if (pngBytes == null || pngBytes.isEmpty) {
          throw Exception('PNG 바이트 데이터가 비어있습니다.');
        }

        // uiImage는 finally 블록에서 dispose하므로 여기서는 dispose하지 않음

        // [PERF] GPU 캡처 방식으로 변경되어 PNG 인코딩은 ui.Image.toByteData에서 처리됨
        // RGB 평균값 비교 로그 제거 (성능 최적화)

        final dir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filePath = '${dir.path}/processed_$timestamp.png';
        final File processedTempFile = File(filePath);

        // 파일 쓰기 시도 (최대 3회 재시도)
        bool writeSuccess = false;
        for (int attempt = 0; attempt < 3; attempt++) {
          try {
            await processedTempFile.writeAsBytes(
              pngBytes,
              flush: true, // 즉시 디스크에 쓰기
            );

            // 파일이 제대로 쓰였는지 확인
            if (await processedTempFile.exists()) {
              final fileSize = await processedTempFile.length();
              if (fileSize > 0) {
                writeSuccess = true;
                debugPrint(
                  '[HomePage] ✅ 파일 쓰기 성공 (시도 ${attempt + 1}): $fileSize bytes',
                );
                break;
              }
            }
          } catch (e) {
            debugPrint('[HomePage] ⚠️ 파일 쓰기 실패 (시도 ${attempt + 1}): $e');
            if (attempt < 2) {
              await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
            }
          }
        }

        if (!writeSuccess) {
          throw Exception('임시 파일 쓰기 실패: 최대 재시도 횟수 초과');
        }

        processedFile = processedTempFile;

        // decodedImage는 img 패키지가 자동으로 메모리 관리하므로 dispose 불필요

        // 3. 프레임 적용
        if (_frameEnabled) {
          // 프레임 적용 전 이미지 크기 확인
          final beforeFrameImage = await loadImageWithExifRotation(
            processedFile,
          );
          if (beforeFrameImage != null) {
            debugPrint(
              '📷 프레임 적용 전: ${beforeFrameImage.width}x${beforeFrameImage.height}',
            );
            // img.Image는 자동으로 메모리 관리됨
          }

          final framedFile = await _addPhotoFrame(processedFile);
          if (framedFile.existsSync()) {
            processedFile = framedFile;

            // 프레임 적용 후 이미지 크기 확인
            final afterFrameImage = await loadImageWithExifRotation(
              processedFile,
            );
            if (afterFrameImage != null) {
              debugPrint(
                '📷 프레임 적용 후: ${afterFrameImage.width}x${afterFrameImage.height}, 비율: ${(afterFrameImage.width / afterFrameImage.height).toStringAsFixed(3)}',
              );
              // img.Image는 자동으로 메모리 관리됨
            }
            debugPrint('✅ 프레임 적용 완료');
          } else {
            debugPrint('⚠️ 프레임 파일이 생성되지 않음, 이전 단계 결과 사용');
          }
        }

        // 갤러리에만 저장 (내부 폴더 저장 없음)
        if (!processedFile.existsSync()) {
          throw Exception('처리된 이미지 파일이 존재하지 않습니다');
        }

        final finalImageBytes = await processedFile.readAsBytes();
        if (finalImageBytes.isEmpty) {
          throw Exception('이미지 바이트가 비어있습니다');
        }

        // 최종 저장되는 이미지 크기 확인
        // 임시 파일로 저장하여 크기 확인
        final tempFile = File(
          '${(await getTemporaryDirectory()).path}/temp_check_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await tempFile.writeAsBytes(finalImageBytes);
        final finalImageCheck = await loadImageWithExifRotation(tempFile);
        if (finalImageCheck != null) {
          debugPrint(
            '💾 최종 저장 이미지: ${finalImageCheck.width}x${finalImageCheck.height}, 비율: ${(finalImageCheck.width / finalImageCheck.height).toStringAsFixed(3)}, 선택된 비율: ${aspectRatioOf(_aspectMode).toStringAsFixed(3)}',
          );
          // img.Image는 자동으로 메모리 관리됨
        }
        // 임시 파일 삭제
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          // 삭제 실패는 무시
        }

        await Gal.putImageBytes(
          finalImageBytes,
          name: 'petgram_shoot_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        debugPrint('✅ 이미지 저장 완료: ${finalImageBytes.length} bytes');
      } catch (processError) {
        debugPrint('❌ 이미지 처리 중 오류: $processError');
        // 처리 실패 시 원본 이미지라도 저장 시도
        try {
          final imageBytes = await file.readAsBytes();
          await Gal.putImageBytes(
            imageBytes,
            name: 'petgram_shoot_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          debugPrint('⚠️ 원본 이미지로 저장됨');
        } catch (saveError) {
          debugPrint('❌ 원본 이미지 저장도 실패: $saveError');
          rethrow;
        }
      }

      // 촬영 성공 피드백
      HapticFeedback.mediumImpact();

      if (kDebugMode) {
        debugPrint('✅ shoot saved to gallery only (no internal storage)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ takePhoto error: $e');
      }
      if (mounted) {
        // 사용자 친화적인 에러 메시지
        String errorMessage = '사진 촬영 중 오류가 발생했어요.';
        if (e.toString().contains('permission') ||
            e.toString().contains('Permission') ||
            e.toString().contains('권한')) {
          errorMessage = '갤러리 저장 권한이 필요합니다. 설정에서 권한을 허용해주세요.';
        } else if (e.toString().contains('storage') ||
            e.toString().contains('저장')) {
          errorMessage = '저장 공간이 부족할 수 있습니다. 저장 공간을 확인해주세요.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      // 리소스 정리: 모든 ui.Image를 한 번만 dispose
      // 중간에 생성된 이전 이미지들 dispose
      for (final img in imagesToDispose) {
        try {
          img.dispose();
          debugPrint('[HomePage] ✅ 중간 이미지 dispose 완료');
        } catch (e) {
          debugPrint('[HomePage] ⚠️ 중간 이미지 dispose 실패 (무시): $e');
        }
      }
      imagesToDispose.clear();

      // 최종 이미지 dispose (단 한 번만)
      if (uiImageForDispose != null) {
        try {
          uiImageForDispose.dispose();
          debugPrint('[HomePage] ✅ 최종 ui.Image dispose 완료');
        } catch (e) {
          debugPrint('[HomePage] ⚠️ 최종 ui.Image dispose 실패 (무시): $e');
        }
        uiImageForDispose = null; // 중복 dispose 방지
      }

      if (mounted) {
        setState(() => _isProcessing = false);

        // 연속 촬영 모드 처리 (finally에서 처리하여 _isProcessing이 false가 된 후 실행)
        if (_isBurstMode && !_shouldStopBurst) {
          // 현재 촬영한 장수 확인 (이미 증가된 상태)
          debugPrint('📸 연속 촬영 진행: $_burstCount/$_burstCountSetting');

          // 설정한 매수에 도달했는지 확인
          if (_burstCount < _burstCountSetting) {
            // 아직 설정한 매수에 도달하지 않았으면 계속 촬영 (속도 개선: 300ms -> 100ms)
            // 다음 촬영을 위해 카운트 증가
            setState(() => _burstCount++);
            Future.delayed(const Duration(milliseconds: 100), () {
              if (mounted && !_shouldStopBurst) {
                _takePhoto();
              } else {
                // 중지 요청이 있으면 초기화
                debugPrint('🛑 연속 촬영 중지됨');
                if (mounted) {
                  setState(() {
                    _burstCount = 0;
                    _shouldStopBurst = false;
                  });
                }
              }
            });
          } else {
            // 연속 촬영 완료 (현재 촬영 포함하여 설정한 매수 도달)
            debugPrint(
              '✅ 연속 촬영 완료: ${_burstCountSetting}장 (타이머: $_isTimerTriggered)',
            );
            final completedCount = _burstCountSetting;
            setState(() {
              // 연속 촬영 모드는 유지하고 카운트만 초기화
              _burstCount = 0;
              _shouldStopBurst = false;
              // 타이머로 인한 촬영이었다면 플래그 리셋
              if (_isTimerTriggered) {
                _isTimerTriggered = false;
                debugPrint('✅ 타이머 플래그 리셋 (연속 촬영 완료)');
              }
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('연속 촬영 ${completedCount}장이 완료되었어요!'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        } else if (_shouldStopBurst) {
          // 중지 요청이 있으면 초기화
          debugPrint('🛑 연속 촬영 중지 요청 처리');
          setState(() {
            _burstCount = 0;
            _shouldStopBurst = false;
            // 타이머로 인한 촬영이었다면 플래그 리셋
            if (_isTimerTriggered) {
              _isTimerTriggered = false;
            }
          });
          // 중지 요청 시에는 스낵바 표시하지 않음 (완료 메시지와 중복 방지)
        }
      }
    }
  }

  Future<void> _openFilterPage(File file) async {
    // 현재 선택된 펫 정보 가져오기
    PetInfo? currentPet;
    if (_selectedPetId != null && _petList.isNotEmpty) {
      try {
        currentPet = _petList.firstWhere((pet) => pet.id == _selectedPetId);
      } catch (e) {
        // 펫을 찾지 못한 경우 null
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilterPage(
          imageFile: file,
          initialFilterKey: _shootFilterKey,
          selectedPet: currentPet,
          coatPreset: _liveCoatPreset,
        ),
      ),
    );
    // FilterPage에서 갤러리 저장 후 자동으로 닫히므로 여기서는 추가 처리 불필요
  }

  String _aspectLabel(AspectRatioMode mode) {
    switch (mode) {
      case AspectRatioMode.nineSixteen:
        return '9:16';
      case AspectRatioMode.threeFour:
        return '3:4';
      case AspectRatioMode.oneOne:
        return '1:1';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 상태 변경 시 강제 재빌드를 위한 key 추가
    // 밝기 값이 변경될 때마다 전체 위젯 트리 재빌드
    return Scaffold(
      key: ValueKey(
        'scaffold_${_brightnessValue}_${_showFocusIndicator}_${_uiZoomScale}',
      ),
      backgroundColor: const Color(0xFFFFF0F5), // 오버레이 색상으로 고정 (SafeArea 영역 포함)
      body: Stack(
        children: [
          // SafeArea 영역(상단 노치, 하단 홈바) 배경색
          Builder(
            builder: (context) {
              final MediaQueryData mediaQuery = MediaQuery.of(context);
              final double safeAreaTop = mediaQuery.padding.top;
              final double safeAreaBottom = mediaQuery.padding.bottom;

              return Stack(
                children: [
                  // 상단 노치 영역 배경
                  if (safeAreaTop > 0)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: safeAreaTop,
                      child: Container(color: const Color(0xFFFFF0F5)),
                    ),
                  // 하단 홈바 영역 배경
                  if (safeAreaBottom > 0)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: safeAreaBottom,
                      child: Container(color: const Color(0xFFFFF0F5)),
                    ),
                ],
              );
            },
          ),
          // SafeArea 내부 컨텐츠
          SafeArea(
            child: Stack(
              children: [
                // 1) 카메라 / 배경 (중앙 정렬)
                _buildCameraBackground(),
                // 2) 상하단 오버레이 (비율 조정용)
                _buildAspectRatioOverlay(),
                // 3) 왼쪽 옵션 패널
                _buildLeftOptionsPanel(),
                // 4) 오른쪽 옵션 패널
                _buildRightOptionsPanel(),
                // 5) 필터 패널
                Builder(
                  builder: (context) {
                    // 하단 바 높이 계산 (버튼 영역이 -40px 위로 올라가 있음)
                    final double bottomBarHeight = 80.0; // 하단 바 높이
                    final double translateOffset =
                        40.0; // Transform.translate offset
                    final double filterPanelBottom =
                        bottomBarHeight + translateOffset + 8; // 여유 공간 추가

                    return Positioned(
                      bottom: filterPanelBottom,
                      left: 0,
                      right: 0,
                      child: ClipRect(
                        child: AnimatedSlide(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          offset: _filterPanelExpanded
                              ? Offset.zero
                              : const Offset(
                                  0,
                                  1,
                                ), // 아래에서 위로 슬라이드 (펼쳐질 때), 위에서 아래로 슬라이드 (닫힐 때)
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 200),
                            opacity: _filterPanelExpanded ? 1.0 : 0.0,
                            child:
                                _buildFilterSelectionPanel(), // 항상 렌더링하여 애니메이션이 부드럽게 작동하도록
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 6) 하단 바
                _buildBottomBar(),
                // 7) 상단 바 (다른 Positioned 위젯보다 위에 배치하여 터치 우선권 확보)
                _buildTopBar(),
                // 8) 초점 표시기 (모든 UI 요소 위에 표시 - 최상단에 배치)
                if (_showFocusIndicator) _buildFocusIndicator(),
                // 9) 자동 초점 표시기 (화면 중앙에 표시)
                if (_showAutoFocusIndicator) _buildAutoFocusIndicator(),
                // 10) 타이머 카운트다운 표시
                if (_isTimerCounting) _buildTimerCountdown(),
                // 11) 연속 촬영 진행 표시
                if (_isBurstMode && _burstCount > 0) _buildBurstProgress(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 핀치 줌 제스처 핸들러 (연속적인 확대: scale 기반 곱셈 방식)
  void _handleZoomScaleStart(ScaleStartDetails details) {
    _isZooming = true;
    if (_uiZoomScale <= 0) {
      _uiZoomScale = _uiZoomMin;
    }
    _baseUiZoomScale = _uiZoomScale;
  }

  /// 핀치 줌 제스처 업데이트 핸들러 (UI 줌만 사용: Transform.scale로 프리뷰 확대)
  /// 카메라 줌은 사용하지 않고 UI 레벨에서만 확대 처리
  /// 핀치 중에는 어떤 라운딩도 하지 않고 완전히 연속적인 값으로 동작
  void _handleZoomScaleUpdate(ScaleUpdateDetails details) {
    if (!mounted) return;

    final double scale = details.scale;
    if (scale <= 0) return;

    if (_baseUiZoomScale <= 0) {
      _baseUiZoomScale = _uiZoomScale > 0 ? _uiZoomScale : _uiZoomMin;
      if (_uiZoomScale <= 0) {
        _uiZoomScale = _uiZoomMin;
      }
    }

    final double newScale = (_baseUiZoomScale * scale).clamp(
      _uiZoomMin,
      _uiZoomMax,
    );

    setState(() {
      _uiZoomScale = newScale;
    });

    debugPrint(
      '[Petgram] pinch ui zoom: base=${_baseUiZoomScale.toStringAsFixed(3)}, '
      'scale=${details.scale.toStringAsFixed(3)}, new=${newScale.toStringAsFixed(3)}',
    );
  }

  /// 핀치 줌 제스처 종료 핸들러 (상태 즉시 초기화)
  /// 핀치 종료 직후 탭 제스처가 지연 없이 동작하도록 _isZooming을 즉시 false로 설정
  void _handleZoomScaleEnd(ScaleEndDetails details) {
    _isZooming = false;
    debugPrint(
      '[Petgram] pinch ui zoom end: current=${_uiZoomScale.toStringAsFixed(3)}',
    );
  }

  Widget _buildPreviewGestureLayer({
    required BuildContext stackContext,
    required Widget child,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onScaleStart: _handleZoomScaleStart,
      onScaleUpdate: _handleZoomScaleUpdate,
      onScaleEnd: _handleZoomScaleEnd,
      onTapDown: (details) {
        final mediaQuery = MediaQuery.of(stackContext);
        final double protectedTopRegion = mediaQuery.padding.top + 56.0;
        if (details.globalPosition.dy <= protectedTopRegion) {
          return;
        }
        if (_filterPanelExpanded) {
          setState(() {
            _filterPanelExpanded = false;
          });
          return;
        }
        if (_isBurstMode && _burstCount > 0) {
          setState(() {
            _shouldStopBurst = true;
            _burstCount = 0;
          });
          return;
        }
        if (_isTimerCounting) {
          setState(() {
            _shouldStopTimer = true;
            _isTimerCounting = false;
            _timerSeconds = 0;
          });
        }
      },
      onTapUp: (details) {
        final mediaQuery = MediaQuery.of(stackContext);
        final double protectedTopRegion = mediaQuery.padding.top + 56.0;
        if (details.globalPosition.dy <= protectedTopRegion) {
          return;
        }

        final RenderBox? box = stackContext.findRenderObject() as RenderBox?;
        if (box == null) {
          return;
        }
        final Offset tapInAncestor = box.globalToLocal(details.globalPosition);
        if (_isCameraInitializing) {
          return;
        }
        _handleTapFocusAtPosition(tapInAncestor);
      },
      child: child,
    );
  }

  List<double> _getZoomPresets() {
    // 배율 옵션 다이얼로그에는 최대 3배까지만 표시
    // 핀치 줌은 여전히 10배까지 가능
    const double maxOptionZoom = 3.0;
    final presetSet = <double>{..._uiZoomPresets, _uiZoomMin};
    return presetSet
        .where((value) => value >= _uiZoomMin && value <= maxOptionZoom)
        .toList()
      ..sort();
  }

  /// _lastPreviewRect 업데이트 (SafeArea Stack 좌표계 기준)
  void _updatePreviewRectFromContext(BuildContext previewContext) {
    if (!mounted) return;

    final RenderBox? previewBox =
        previewContext.findRenderObject() as RenderBox?;
    if (previewBox == null || !previewBox.hasSize) return;

    // SafeArea의 child Stack을 ancestor로 찾기
    final RenderBox? ancestorBox = previewContext
        .findAncestorRenderObjectOfType<RenderBox>();
    if (ancestorBox == null) return;

    // previewBox의 topLeft를 ancestor 좌표계로 변환
    final Offset topLeftInAncestor = previewBox.localToGlobal(
      Offset.zero,
      ancestor: ancestorBox,
    );
    final Size size = previewBox.size;

    final Rect rectInAncestor = Rect.fromLTWH(
      topLeftInAncestor.dx,
      topLeftInAncestor.dy,
      size.width,
      size.height,
    );

    if (_lastPreviewRect == rectInAncestor) return;

    setState(() {
      _lastPreviewRect = rectInAncestor;
    });
    debugPrint(
      '[Petgram] 📐 previewRect updated (ancestor space): $_lastPreviewRect',
    );

    // 실제 사용 중인 센서 비율 계산
    double sensorRatio;
    if (!_useMockCamera &&
        _cameraController != null &&
        _cameraController!.value.isInitialized) {
      sensorRatio = _cameraController!.value.aspectRatio;
    } else {
      // 목업 또는 카메라 미초기화: _aspectMode 기반 비율 사용
      sensorRatio = aspectRatioOf(_aspectMode);
    }

    _debugTestCenterTap(sensorRatio: sensorRatio);
  }

  /// 프리뷰 중앙 탭 테스트 디버그 함수
  void _debugTestCenterTap({required double sensorRatio}) {
    if (_lastPreviewRect == null) {
      debugPrint('[Petgram] 🎯 _debugTestCenterTap: _lastPreviewRect is null');
      return;
    }

    final rect = _lastPreviewRect!;
    final centerGlobal = rect.center;
    final displaySize = rect.size;

    // contentSize는 프리뷰 레이아웃에서 사용하는 것과 동일한 방식으로 계산
    final contentSize = Size(
      displaySize.height * sensorRatio,
      displaySize.height,
    );

    final normalized = CameraMappingUtils.mapGlobalToNormalized(
      globalPos: centerGlobal,
      previewRect: rect,
      contentSize: contentSize,
    );

    debugPrint(
      '[Petgram] 🎯 forced center tap: previewRect=$rect, centerGlobal=$centerGlobal, '
      'contentSize=$contentSize, normalized=$normalized',
    );
  }

  /// 카메라 프리뷰 크기 및 오버레이 계산 헬퍼 메서드
  /// 카메라 실제 비율을 기준으로 프리뷰 박스를 계산하고, 그 기준으로 오버레이를 계산
  Map<String, double> _calculateCameraPreviewDimensions() {
    final screenSize = MediaQuery.of(context).size;
    final double screenW = screenSize.width;
    final double screenH = screenSize.height;

    // 타겟 비율 계산 (1:1, 3:4, 9:16)
    final double targetRatio = aspectRatioOf(_aspectMode);

    // 프리뷰 박스 크기 계산 (targetRatio 기반)
    double previewW;
    double previewH;

    if (targetRatio > 1.0) {
      // 가로가 더 긴 비율: 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW / targetRatio;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH * targetRatio;
      }
    } else if (targetRatio < 1.0) {
      // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW / targetRatio;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH * targetRatio;
      }
    } else {
      // 1:1 비율: 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH;
      }
    }

    // 오버레이는 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
    // 하지만 기존 코드 호환성을 위해 0으로 설정
    double overlayTop = 0;
    double overlayBottom = 0;
    double nineSixteenOverlayTop = 0;
    double nineSixteenOverlayBottom = 0;

    return {
      'previewW': previewW,
      'previewH': previewH,
      'overlayTop': overlayTop,
      'overlayBottom': overlayBottom,
      'nineSixteenOverlayTop': nineSixteenOverlayTop,
      'nineSixteenOverlayBottom': nineSixteenOverlayBottom,
      'offsetX': (screenW - previewW) / 2,
      'offsetY': (screenH - previewH) / 2,
    };
  }

  /// 상하단 오버레이 (메인 Stack 위에 별도로 표시)
  /// _buildCameraStack 내부의 오버레이 계산과 정확히 동일하게 맞춤
  Widget _buildAspectRatioOverlay() {
    // LayoutBuilder를 사용하여 _buildCameraStack과 동일한 constraints 사용
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth;
        final double maxHeight = constraints.maxHeight;

        // SafeArea 정보 가져오기 (오버레이 위치 계산용)
        final MediaQueryData mediaQuery = MediaQuery.of(context);
        final double safeAreaTop = mediaQuery.padding.top;
        final double safeAreaBottom = mediaQuery.padding.bottom;

        // 타겟 비율 계산 (1:1, 3:4, 9:16)
        final double targetRatio = aspectRatioOf(_aspectMode);

        // 프리뷰 박스 크기 계산 (targetRatio 기반)
        double previewBoxW;
        double previewBoxH;

        if (targetRatio > 1.0) {
          // 가로가 더 긴 비율: 가로를 기준으로 계산
          previewBoxW = maxWidth;
          previewBoxH = previewBoxW / targetRatio;

          if (previewBoxH > maxHeight) {
            previewBoxH = maxHeight;
            previewBoxW = previewBoxH * targetRatio;
          }
        } else if (targetRatio < 1.0) {
          // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산
          previewBoxW = maxWidth;
          previewBoxH = previewBoxW / targetRatio;

          if (previewBoxH > maxHeight) {
            previewBoxH = maxHeight;
            previewBoxW = previewBoxH * targetRatio;
          }
        } else {
          // 1:1 비율: 가로를 기준으로 계산
          previewBoxW = maxWidth;
          previewBoxH = previewBoxW;

          if (previewBoxH > maxHeight) {
            previewBoxH = maxHeight;
            previewBoxW = previewBoxH;
          }
        }

        // 호환성을 위해 actualPreviewH 사용 (previewBox와 동일)
        final double actualPreviewH = previewBoxH;

        // 중앙 정렬을 위한 오프셋
        final double offsetY = (maxHeight - actualPreviewH) / 2;

        // 오버레이는 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
        // 하지만 기존 코드 호환성을 위해 0으로 설정
        double actualOverlayTop = 0;
        double actualOverlayBottom = 0;

        // 오버레이는 constraints 전체를 기준으로 배치하되, SafeArea까지 확장
        // 상단 오버레이의 bottom 계산: constraints 기준으로 계산된 위치
        final double overlayTopBottom =
            maxHeight - (offsetY + actualOverlayTop);
        // 하단 오버레이의 top 계산: constraints 기준으로 계산된 위치
        final double overlayBottomTop =
            offsetY + actualPreviewH - actualOverlayBottom;

        return Stack(
          children: [
            // 상단 오버레이 (화면 전체 너비, SafeArea 상단부터 카메라 프리뷰 상단까지)
            if (actualOverlayTop > 0)
              Positioned(
                key: ValueKey('overlay_top_$actualOverlayTop'),
                left: 0,
                right: 0,
                top: -safeAreaTop, // SafeArea 상단까지 확장
                bottom: overlayTopBottom, // constraints 기준 계산된 위치
                child: Container(color: const Color(0xFFFFF0F5)),
              ),
            // 하단 오버레이 (화면 전체 너비, 카메라 프리뷰 하단부터 SafeArea 하단까지)
            if (actualOverlayBottom > 0)
              Positioned(
                key: ValueKey('overlay_bottom_$actualOverlayBottom'),
                left: 0,
                right: 0,
                top: overlayBottomTop, // constraints 기준 계산된 위치
                bottom: -safeAreaBottom, // SafeArea 하단까지 확장
                child: Container(color: const Color(0xFFFFF0F5)),
              ),
          ],
        );
      },
    );
  }

  /// 자동 초점 표시기 (화면 중앙에 표시) - 일반 동그라미로 표시
  Widget _buildAutoFocusIndicator() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.transparent,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.5),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 외부 원
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4),
                            width: 1.2,
                          ),
                        ),
                      ),
                      // 내부 원
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.8),
                        ),
                      ),
                      // 중앙 점
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 타이머 카운트다운 표시
  Widget _buildTimerCountdown() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$_timerSeconds',
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 연속 촬영 진행 표시 (타이머와 동일한 위치와 크기)
  /// 고정 크기 Container + FittedBox로 숫자 자리수 증가 시에도 UI가 깨지지 않도록 수정
  Widget _buildBurstProgress() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Container(
                width: 42, // 최대 자리수(100/100)를 고려한 고정 너비
                height: 36, // 고정 높이
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  child: Text(
                    '$_burstCount/$_burstCountSetting',
                    style: const TextStyle(
                      fontSize: 64, // FittedBox가 자동으로 스케일 조정
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 초점 표시기 빌드 (previewRect + local 좌표 기준, SafeArea Stack 좌표계)
  Widget _buildFocusIndicator() {
    // 좌표가 없으면 렌더링하지 않음
    if (_focusIndicatorPreviewRect == null || _focusIndicatorLocal == null) {
      debugPrint(
        '[Petgram] 🎯 FocusIndicator: not rendering (rect=$_focusIndicatorPreviewRect, local=$_focusIndicatorLocal)',
      );
      return const SizedBox.shrink();
    }

    const double size = 80.0;
    final rect = _focusIndicatorPreviewRect!;
    final local = _focusIndicatorLocal!;

    final double left = rect.left + local.dx - size / 2;
    final double top = rect.top + local.dy - size / 2;

    debugPrint(
      '[Petgram] 🎯 FocusIndicator build: rect=$rect, local=$local, '
      'indicator position=(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}), '
      'center≈(${(left + size / 2).toStringAsFixed(1)}, ${(top + size / 2).toStringAsFixed(1)})',
    );

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          key: ValueKey('focus_indicator_${local.dx}_${local.dy}'),
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          builder: (context, value, child) {
            // 페이드인 + 스케일 애니메이션
            return AnimatedOpacity(
              opacity: _showFocusIndicator ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: Transform.scale(
                scale: _showFocusIndicator
                    ? (0.3 + (value * 0.7))
                    : (0.3 + (value * 0.7)) * 0.8, // 사라질 때 약간 축소
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.transparent,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withOpacity(0.6 * value),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 외부 원 (펄스 효과) - 표시 중일 때만
                      if (_showFocusIndicator && value > 0.5)
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 400),
                          builder: (context, pulseValue, child) {
                            return Opacity(
                              opacity: (1.0 - pulseValue) * 0.5,
                              child: Transform.scale(
                                scale: 1.0 + (pulseValue * 0.3),
                                child: Container(
                                  width: size,
                                  height: size,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.4),
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      // 내부 원
                      Container(
                        width: size * 0.6,
                        height: size * 0.6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.8),
                            width: 1.5,
                          ),
                        ),
                      ),
                      // 중앙 점
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 화면 중앙에 자동 초점 설정 (최초 진입 시)
  Future<void> _setAutoFocusAtCenter() async {
    if (_useMockCamera ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    // 화면 중앙 좌표 (0.5, 0.5)
    const centerPoint = Offset(0.5, 0.5);

    debugPrint('[Petgram] 🔍 자동 초점 설정: 화면 중앙 ($centerPoint)');

    // 카메라에 초점 설정 (자동 초점이므로 UI 표시하지 않음)
    try {
      await _cameraController!.setFocusPoint(centerPoint);
      debugPrint('[Petgram] ✅ 자동 초점 설정 완료 (화면 중앙)');

      // 초점 설정 성공 시 자동 초점 표시기만 표시 (수동 터치 초점과 구분)
      if (mounted) {
        setState(() {
          _focusPointRelative = centerPoint;
          _showAutoFocusIndicator = true;
        });
        // 1.5초 후 자동 초점 표시기 숨기기
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) {
            setState(() {
              _showAutoFocusIndicator = false;
            });
          }
        });
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ 자동 초점 설정 실패: $e');
    }
  }

  /// 탭 포커스 핸들러 (위치 기반, SafeArea Stack 좌표계)
  Future<void> _handleTapFocusAtPosition(Offset tapInAncestor) async {
    debugPrint(
      '[Petgram] 🎯 _handleTapFocusAtPosition: tapInAncestor=$tapInAncestor, '
      '_lastPreviewRect=$_lastPreviewRect, _useMockCamera=$_useMockCamera, '
      '_cameraController=${_cameraController != null}',
    );

    // ========== Mock 모드 처리 ==========
    // Mock 모드에서는 previewRect 기반 탭 거부를 사용하지 않음
    // 순수 로컬 좌표만 사용하여 UI 인디케이터 표시
    if (_useMockCamera || _cameraController == null) {
      debugPrint(
        '[Petgram] 🎨 Mock mode: using pure local coordinates, no previewRect rejection',
      );

      // Mock 모드에서는 tapInAncestor를 그대로 사용 (전체 화면 기준)
      final indicatorRect = Rect.fromLTWH(
        tapInAncestor.dx - 40,
        tapInAncestor.dy - 40,
        80,
        80,
      );
      final indicatorLocal = const Offset(40, 40); // 인디케이터 중앙

      // UI 인디케이터 표시
      setState(() {
        _focusIndicatorPreviewRect = indicatorRect;
        _focusIndicatorLocal = indicatorLocal;
        _showFocusIndicator = true;
      });

      debugPrint(
        '[Petgram] 🎯 Mock UI indicator: rect=$indicatorRect, local=$indicatorLocal',
      );

      // 2초 후 자동 숨김
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        setState(() {
          _showFocusIndicator = false;
        });
        Future.delayed(const Duration(milliseconds: 200), () {
          if (!mounted) return;
          setState(() {
            _focusIndicatorPreviewRect = null;
            _focusIndicatorLocal = null;
          });
        });
      });
      return;
    }

    // ========== 실제 카메라 모드 처리 ==========
    // 실제 카메라 모드에서만 previewRect 기반 로직 사용
    final rect = _lastPreviewRect;

    if (rect == null) {
      debugPrint(
        '[Petgram] ⚠️ Real camera mode but _lastPreviewRect is null, using tapInAncestor directly for UI indicator',
      );
      // _lastPreviewRect가 null이면 tapInAncestor를 직접 사용
      final indicatorRect = Rect.fromLTWH(
        tapInAncestor.dx - 40,
        tapInAncestor.dy - 40,
        80,
        80,
      );
      final indicatorLocal = const Offset(40, 40);

      setState(() {
        _focusIndicatorPreviewRect = indicatorRect;
        _focusIndicatorLocal = indicatorLocal;
        _showFocusIndicator = true;
      });

      // 2초 후 자동 숨김
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        setState(() {
          _showFocusIndicator = false;
        });
        Future.delayed(const Duration(milliseconds: 200), () {
          if (!mounted) return;
          setState(() {
            _focusIndicatorPreviewRect = null;
            _focusIndicatorLocal = null;
          });
        });
      });
      return;
    }

    // previewRect 기반 로컬 좌표 계산 (실제 카메라 모드에서만)
    final local = Offset(
      tapInAncestor.dx - rect.left,
      tapInAncestor.dy - rect.top,
    );

    // 프리뷰 바깥이면 무시 (실제 카메라 모드에서만)
    const double touchMargin = 8.0; // 경계 근처 터치 허용
    if (local.dx < -touchMargin ||
        local.dy < -touchMargin ||
        local.dx > rect.width + touchMargin ||
        local.dy > rect.height + touchMargin) {
      debugPrint(
        '[Petgram] 🔍 Tap ignored: outside preview rect (local=$local, rect=$rect, margin=$touchMargin)',
      );
      return;
    }

    // 로컬 좌표를 프리뷰 영역 내로 클램프
    final clampedLocal = Offset(
      local.dx.clamp(0.0, rect.width),
      local.dy.clamp(0.0, rect.height),
    );

    setState(() {
      _focusIndicatorPreviewRect = rect;
      _focusIndicatorLocal = clampedLocal;
      _showFocusIndicator = true;
    });

    debugPrint(
      '[Petgram] 🎯 Real camera UI indicator: rect=$rect, local=$clampedLocal',
    );

    // ========== 실 카메라 경로 ==========
    // rect는 이미 null 체크 완료, local도 이미 계산됨
    // local은 위에서 이미 계산되었고 프리뷰 바깥 체크도 완료됨

    // 3단계: rect 기준 raw normalized 계산 (반올림 없이)
    // 실 카메라는 BoxFit.cover 기반 매핑 적용
    // clampedLocal 사용 (이미 클램프됨)
    final double nxRaw = (clampedLocal.dx / rect.width).clamp(0.0, 1.0);
    final double nyRaw = (clampedLocal.dy / rect.height).clamp(0.0, 1.0);

    double nx = nxRaw;
    double ny = nyRaw;

    // 전면 카메라면 X 좌표만 좌우 반전
    if (_cameraLensDirection == CameraLensDirection.front) {
      nx = 1.0 - nxRaw;
    }

    // ✅ 실제로 사용할 normalized: 반올림/파싱 없이 그대로 사용
    final Offset normalized = Offset(nx, ny);

    // 카메라 API용 normalized 저장
    _focusPointRelative = normalized;

    // 6단계: 로그 출력 – 여기서만 반올림해서 문자열로 보여주기
    debugPrint(
      '[Petgram] 🔍 Tap focus byRect: '
      'tapInAncestor=$tapInAncestor, rect=$rect, local=$local, clampedLocal=$clampedLocal → '
      'normalized(raw=Offset(${nxRaw.toStringAsFixed(3)}, ${nyRaw.toStringAsFixed(3)}), '
      'used=Offset(${nx.toStringAsFixed(3)}, ${ny.toStringAsFixed(3)}))',
    );

    // 7단계: 카메라 API 호출 (비동기, await 없이)
    if (_useMockCamera ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      debugPrint(
        '[Petgram] ℹ️ Mock or no camera: UI indicator only, skip setFocusPoint/setExposurePoint',
      );
    } else {
      final controller = _cameraController!;
      try {
        // 실제 카메라에 넘기는 좌표도 normalized 그대로 (반올림 금지)
        controller.setFocusPoint(normalized);
        controller.setExposurePoint(normalized);
      } catch (e) {
        debugPrint('[Petgram] ❌ setFocusPoint/setExposurePoint error: $e');
      }
    }

    // 8단계: 2초 후 인디케이터 자동 숨김 (페이드아웃 애니메이션 포함)
    // 목업 모드에서도 반드시 실행되어야 함
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _showFocusIndicator = false;
      });
      // 페이드아웃 애니메이션 후 완전히 제거
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() {
          _focusIndicatorPreviewRect = null;
          _focusIndicatorLocal = null;
        });
      });
    });
  }

  /// 카메라 / 목업 배경
  Widget _buildCameraBackground() {
    final double targetRatio = aspectRatioOf(_aspectMode);

    final PetFilter? filter = _allFilters[_shootFilterKey];

    final bool canUseCamera =
        !_useMockCamera &&
        _cameraController != null &&
        _cameraController!.value.isInitialized;

    // CameraPreview는 GestureDetector 없이 사용 (Stack 전체에 GestureDetector 적용)
    final Widget source = canUseCamera
        ? CameraPreview(_cameraController!)
        : Image.asset(
            'assets/images/mockup.png',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );

    // Mock Preview든 실제 Preview든, 초기화 중이든 항상 Stack을 반환하여
    // 오버레이, 밝기, 초점 표시기 등이 항상 표시되도록 함

    // Builder 제거하고 직접 계산 - 상태 변경 시 항상 재빌드되도록 보장
    // MediaQuery는 build 메서드에서 이미 접근 가능하므로 Builder 불필요
    return _buildCameraStack(
      targetRatio: targetRatio,
      filter: filter,
      source: source,
      canUseCamera: canUseCamera,
      isCameraInitializing: _isCameraInitializing,
    );
  }

  /// 카메라 Stack 빌드 (상태 변경 시 항상 재빌드되도록 분리)
  Widget _buildCameraStack({
    required double targetRatio,
    required PetFilter? filter,
    required Widget source,
    required bool canUseCamera,
    required bool isCameraInitializing,
  }) {
    return Builder(
      builder: (safeAreaContext) {
        // 카메라 프리뷰는 원본 비율을 유지, 남는 영역은 오버레이로 채움
        return Positioned.fill(
          child: LayoutBuilder(
            builder: (layoutContext, constraints) {
              // LayoutBuilder로 실제 AspectRatio가 결정한 크기 측정
              final double maxWidth = constraints.maxWidth;
              final double maxHeight = constraints.maxHeight;

              // 프리뷰 박스 크기는 _aspectMode의 targetRatio를 기준으로 계산
              // 프리뷰 박스 모양이 선택한 비율(1:1, 3:4, 9:16)에 맞춰져야 함
              final double targetRatio = aspectRatioOf(_aspectMode);

              // 프리뷰 박스 크기 계산 (targetRatio 기반)
              // targetRatio에 따라 적절한 기준 선택
              double previewBoxW;
              double previewBoxH;

              if (targetRatio > 1.0) {
                // 가로가 더 긴 비율: 가로를 기준으로 계산
                previewBoxW = maxWidth;
                previewBoxH = previewBoxW / targetRatio;

                if (previewBoxH > maxHeight) {
                  previewBoxH = maxHeight;
                  previewBoxW = previewBoxH * targetRatio;
                }
              } else if (targetRatio < 1.0) {
                // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산 (고정)
                previewBoxW = maxWidth;
                previewBoxH = previewBoxW / targetRatio;

                if (previewBoxH > maxHeight) {
                  previewBoxH = maxHeight;
                  previewBoxW = previewBoxH * targetRatio;
                }
              } else {
                // 1:1 비율: 가로를 기준으로 계산 (고정)
                previewBoxW = maxWidth;
                previewBoxH = previewBoxW; // 1:1이므로 같음

                if (previewBoxH > maxHeight) {
                  previewBoxH = maxHeight;
                  previewBoxW = previewBoxH; // 1:1이므로 같음
                }
              }

              // 중앙 정렬을 위한 오프셋
              final double offsetX = (maxWidth - previewBoxW) / 2;
              final double offsetY = (maxHeight - previewBoxH) / 2;

              // 오버레이 계산은 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
              // 하지만 기존 코드 호환성을 위해 0으로 설정
              double actualOverlayTop = 0;

              // frameTopOffset 계산 (프리뷰 박스 기준으로 재계산)
              double frameTopOffset = 0;
              if (_aspectMode == AspectRatioMode.nineSixteen ||
                  _aspectMode == AspectRatioMode.threeFour) {
                final double safeAreaTop = MediaQuery.of(context).padding.top;
                final double topBarHeight = 8 + 48 + 8;
                final double screenTopBarHeight = safeAreaTop + topBarHeight;
                final double previewTop = offsetY + actualOverlayTop;

                if (screenTopBarHeight > previewTop) {
                  frameTopOffset = screenTopBarHeight - previewTop;
                  frameTopOffset = frameTopOffset.clamp(0.0, previewBoxH);
                }
              }

              return Stack(
                children: [
                  // 전체 배경을 오버레이 색상으로 채움 (남는 영역 포함)
                  Positioned.fill(
                    child: Container(color: const Color(0xFFFFF0F5)),
                  ),
                  // 카메라 프리뷰 중앙 배치 (단순화된 패턴 사용)
                  Positioned(
                    key: _previewKey,
                    left: offsetX,
                    top: offsetY,
                    width: previewBoxW, // targetRatio 기반 프리뷰 박스 너비
                    height: previewBoxH, // targetRatio 기반 프리뷰 박스 높이
                    child: Builder(
                      builder: (previewContext) {
                        // 실 카메라와 mock 분리 처리
                        final bool isRealCamera =
                            !_useMockCamera && canUseCamera;

                        if (isRealCamera) {
                          // ========== 실 카메라 경로 (단순화된 패턴) ==========
                          // Update preview rect in SafeArea Stack coordinate space
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _updatePreviewRectFromContext(previewContext);
                            }
                          });

                          // 카메라 센서 비율 가져오기
                          double cameraAspect;
                          if (_cameraController != null &&
                              _cameraController!.value.isInitialized) {
                            cameraAspect = _cameraController!.value.aspectRatio;
                          } else {
                            // 초기화 중이면 기본값 사용
                            cameraAspect = 9.0 / 16.0;
                          }

                          // 프리뷰 비율 로그
                          debugPrint(
                            '[Petgram] preview layout: '
                            'aspectMode=$_aspectMode, '
                            'targetRatio=$targetRatio, '
                            'cameraAspect=$cameraAspect',
                          );

                          // 프리뷰 매트릭스 계산 (FilterPage와 동일한 로직)
                          final previewMatrix = _buildPreviewColorMatrix();
                          final bool hasFilter = !_listEquals(
                            previewMatrix,
                            kIdentityMatrix,
                          );

                          // 카메라 프리뷰 위젯 생성
                          Widget cameraPreviewWidget;
                          if (isCameraInitializing) {
                            cameraPreviewWidget = Container(
                              color: Colors.black,
                              child: const Center(
                                child: CircularProgressIndicator(
                                  color: kMainPink,
                                ),
                              ),
                            );
                          } else {
                            // CameraPreview 위젯 생성
                            cameraPreviewWidget = FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: _cameraController!
                                    .value
                                    .previewSize!
                                    .height,
                                height:
                                    _cameraController!.value.previewSize!.width,
                                child: RepaintBoundary(
                                  key: ValueKey('camera_preview'),
                                  child: source, // CameraPreview 또는 Mock 이미지
                                ),
                              ),
                            );
                          }

                          // 필터 적용된 카메라 프리뷰 (ColorFiltered > Transform.scale > CameraPreview)
                          Widget filteredPreview;
                          if (hasFilter) {
                            filteredPreview = ColorFiltered(
                              colorFilter: ColorFilter.matrix(previewMatrix),
                              child: ClipRect(
                                child: Transform.scale(
                                  scale: _uiZoomScale,
                                  child: cameraPreviewWidget,
                                ),
                              ),
                            );
                          } else {
                            // 필터가 없으면 ColorFiltered 없이 Transform.scale만 적용
                            filteredPreview = ClipRect(
                              child: Transform.scale(
                                scale: _uiZoomScale,
                                child: cameraPreviewWidget,
                              ),
                            );
                          }

                          // UI 줌 적용: CameraPreview만 Transform.scale로 확대
                          // 격자 라인은 Transform.scale 밖에 두어 확대되지 않도록 함
                          Widget preview = AspectRatio(
                            aspectRatio: targetRatio, // 9/16, 3/4, 1/1
                            child: Stack(
                              key: ValueKey(
                                'camera_stack_${_aspectMode}_${_brightnessValue}_${_showFocusIndicator}_${_uiZoomScale}',
                              ),
                              fit: StackFit.expand,
                              clipBehavior: Clip.hardEdge,
                              children: [
                                // 1. 카메라 프리뷰 (ColorFiltered > Transform.scale > CameraPreview)
                                Positioned.fill(child: filteredPreview),
                                // 2. 격자 라인 오버레이 - ColorFiltered 밖에 배치하여 확대되지 않음
                                if (_showGridLines)
                                  Positioned.fill(
                                    key: ValueKey('grid_lines_${_aspectMode}'),
                                    child: _buildGridLines(
                                      previewBoxW,
                                      previewBoxH,
                                      frameTopOffset,
                                    ),
                                  ),
                              ],
                            ),
                          );
                          return _buildPreviewGestureLayer(
                            stackContext: safeAreaContext,
                            child: preview,
                          );
                        } else {
                          // ========== Mock 경로 ==========
                          // Mock 이미지 비율 (기본값 9:16)
                          final double mockImageRatio = 9.0 / 16.0;

                          // Mock 모드에서도 _lastPreviewRect 업데이트
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _updatePreviewRectFromContext(previewContext);
                            }
                          });

                          debugPrint(
                            '[Preview] 🎨 Mock camera: previewBox=${previewBoxW.toStringAsFixed(1)}x${previewBoxH.toStringAsFixed(1)}, '
                            'targetRatio=${targetRatio.toStringAsFixed(3)}, mockRatio=${mockImageRatio.toStringAsFixed(3)}',
                          );

                          // Mock 모드에서도 프리뷰 매트릭스 계산 (FilterPage와 동일한 로직)
                          final previewMatrix = _buildPreviewColorMatrix();
                          final bool hasFilter = !_listEquals(
                            previewMatrix,
                            kIdentityMatrix,
                          );

                          // Mock 이미지 위젯 생성
                          final mockImageWidget = RepaintBoundary(
                            key: ValueKey('mock_preview'),
                            child: source, // Mock 이미지
                          );

                          // 필터 적용된 Mock 이미지 (ColorFiltered > Transform.scale > Image)
                          Widget filteredMockPreview;
                          if (hasFilter) {
                            filteredMockPreview = ColorFiltered(
                              colorFilter: ColorFilter.matrix(previewMatrix),
                              child: ClipRect(
                                child: Transform.scale(
                                  scale: _uiZoomScale,
                                  child: mockImageWidget,
                                ),
                              ),
                            );
                          } else {
                            // 필터가 없으면 ColorFiltered 없이 Transform.scale만 적용
                            filteredMockPreview = ClipRect(
                              child: Transform.scale(
                                scale: _uiZoomScale,
                                child: mockImageWidget,
                              ),
                            );
                          }

                          // Mock 모드에서도 UI 줌 적용: Mock 이미지만 Transform.scale로 확대
                          return _buildPreviewGestureLayer(
                            stackContext: safeAreaContext,
                            child: AspectRatio(
                              aspectRatio: targetRatio,
                              child: Stack(
                                key: ValueKey(
                                  'mock_camera_stack_${_aspectMode}_${_uiZoomScale}',
                                ),
                                fit: StackFit.expand,
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  // 1. Mock 이미지 (ColorFiltered > Transform.scale > Image)
                                  Positioned.fill(child: filteredMockPreview),
                                  // 2. 격자 라인 오버레이 - ColorFiltered 밖에 배치하여 확대되지 않음
                                  if (_showGridLines)
                                    Positioned.fill(
                                      key: ValueKey(
                                        'mock_grid_lines_${_aspectMode}',
                                      ),
                                      child: _buildGridLines(
                                        previewBoxW,
                                        previewBoxH,
                                        frameTopOffset,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }
                      },
                    ), // Builder 닫기
                  ), // Positioned 닫기
                  // 프레임 오버레이 (프리뷰 박스 기준, 메인 Stack에 배치)
                  _buildFramePreviewOverlay(
                    previewWidth: previewBoxW,
                    previewHeight: previewBoxH,
                    previewOffsetX: offsetX,
                    previewOffsetY: offsetY,
                  ),
                ],
              ); // Stack 닫기
            },
          ),
        );
      },
    );
  }

  /// 라이브 필터 적용 (촬영 화면 미리보기) - 펫톤 + 필터 + 밝기 모두 적용
  /// 프리뷰용 ColorMatrix 계산 (FilterPage와 동일한 로직)
  /// FilterPage의 _buildPreviewColorMatrix와 동일한 계산 방식 사용
  List<double> _buildPreviewColorMatrix() {
    if (_isPureOriginalMode) {
      debugPrint(
        '[Petgram] 🎨 [PREVIEW PIPELINE] Pure original mode, using identity matrix',
      );
      return List.from(kIdentityMatrix);
    }

    List<double> base = List.from(kIdentityMatrix);

    // 1. 펫톤 프로파일 적용 (40% 강도) - FilterPage와 동일
    final petProfile = _getCurrentPetToneProfile();
    if (petProfile != null) {
      final petToneMatrix = mixMatrix(
        kIdentityMatrix,
        petProfile.matrix,
        0.4, // 40% 강도로 약하게 적용
      );
      base = multiplyColorMatrices(base, petToneMatrix);
    }

    // 2. 필터 적용 - FilterPage와 동일
    final PetFilter? currentFilter = _allFilters[_shootFilterKey];
    if (currentFilter != null && currentFilter.key != 'basic_none') {
      final filterMatrix = mixMatrix(
        kIdentityMatrix,
        currentFilter.matrix,
        _liveIntensity,
      );
      base = multiplyColorMatrices(base, filterMatrix);
    }

    // 3. 밝기 적용 - FilterPage와 동일한 계산 방식
    // FilterPage: (_editBrightness / 50.0) * 40.0
    // HomePage: (_brightnessValue / 10.0) * 255 * 0.1 = (_brightnessValue / 10.0) * 25.5
    // 동일하게 맞추기 위해 FilterPage 방식 사용
    if (_brightnessValue != 0.0) {
      // FilterPage와 동일한 계산: (_brightnessValue / 50.0) * 40.0
      // _brightnessValue는 -10 ~ +10 범위이므로, 이를 -50 ~ +50으로 변환
      final double normalizedBrightness =
          _brightnessValue * 5.0; // -10~+10 -> -50~+50
      final double b = (normalizedBrightness / 50.0) * 40.0;
      final List<double> brightnessMatrix = [
        1,
        0,
        0,
        0,
        b,
        0,
        1,
        0,
        0,
        b,
        0,
        0,
        1,
        0,
        b,
        0,
        0,
        0,
        1,
        0,
      ];
      base = multiplyColorMatrices(base, brightnessMatrix);
    }

    // 4. 대비는 HomePage에서 지원하지 않으므로 제외
    // FilterPage는 _editContrast를 지원하지만, HomePage는 밝기만 지원

    return base;
  }

  /// [DEPRECATED] 이 함수는 더 이상 사용되지 않음
  /// ColorFiltered는 CameraPreview 빌드 시 직접 적용됨
  @Deprecated(
    'Use _buildPreviewColorMatrix and apply ColorFiltered directly to CameraPreview',
  )
  Widget _buildFilteredWidgetLive(PetFilter? filter, Widget child) {
    // 이 함수는 호환성을 위해 유지하지만, 실제로는 사용되지 않음
    final previewMatrix = _buildPreviewColorMatrix();
    if (!_listEquals(previewMatrix, kIdentityMatrix)) {
      return ColorFiltered(
        colorFilter: ColorFilter.matrix(previewMatrix),
        child: child,
      );
    }
    return child;
  }

  /// 그리드라인 오버레이 (풀 오버레이 기준으로 한번에 그리기)
  /// 비율을 바꾸면 상하단 오버레이가 자연스럽게 가려짐
  /// 프레임 유무와 관계없이 항상 풀 오버레이 기준으로 그려짐
  Widget _buildGridLines(double width, double height, double frameTopOffset) {
    // 실제 프리뷰 영역(오버레이 제외)에만 격자 표시
    return IgnorePointer(
      ignoring: true,
      child: CustomPaint(
        painter: GridLinesPainter(),
        size: Size(width, height),
      ),
    );
  }

  /// 프레임 미리보기 오버레이 (새로운 구조)
  /// 프레임은 오버레이가 가려지는 바로 위와 아래에 자동으로 조정됨
  Widget _buildFramePreviewOverlay({
    required double previewWidth,
    required double previewHeight,
    required double previewOffsetX,
    required double previewOffsetY,
  }) {
    if (!_frameEnabled || _petList.isEmpty) {
      return const SizedBox.shrink();
    }

    // _addPhotoFrame과 동일한 규칙 사용
    final double topBarHeight = previewWidth * 0.02; // frameMargin
    final double bottomBarHeight = previewHeight; // previewBox 전체 높이

    return Positioned(
      left: previewOffsetX,
      top: previewOffsetY,
      width: previewWidth,
      height: previewHeight,
      child: IgnorePointer(
        ignoring: true,
        child: CustomPaint(
          painter: FramePainter(
            petList: _petList,
            selectedPetId: _selectedPetId,
            width: previewWidth,
            height: previewHeight,
            topBarHeight: topBarHeight,
            bottomBarHeight: bottomBarHeight,
            dogIconImage: _dogIconImage,
            catIconImage: _catIconImage,
            location: _currentLocation,
          ),
        ),
      ),
    );
  }

  /// 상단 로고 + 프레임 설정 + 설정 버튼
  Widget _buildTopBar() {
    final double logoSize = 28.0;
    final double fontSize = 20.0;
    final double horizontalPadding = 12.0;
    final double verticalPadding = 10.0;
    final double iconSize = 18.0;

    return Positioned(
      top: 6.0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.only(
          left: horizontalPadding,
          right: horizontalPadding,
          top: verticalPadding,
          bottom: verticalPadding,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: logoSize,
              height: logoSize,
              child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
            ),
            const SizedBox(width: 0),
            Text(
              'Petgram',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                color: kMainPink,
                letterSpacing: 0.8,
                shadows: [
                  Shadow(
                    blurRadius: 12,
                    color: Colors.black.withValues(alpha: 0.8),
                    offset: const Offset(0, 3),
                  ),
                  Shadow(
                    blurRadius: 6,
                    color: Colors.black.withValues(alpha: 0.6),
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (_frameEnabled && _petList.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  final selectedPet = _selectedPetId != null
                      ? _petList.firstWhere(
                          (pet) => pet.id == _selectedPetId,
                          orElse: () => _petList.first,
                        )
                      : _petList.first;
                  if (selectedPet.locationEnabled) {
                    return Container(
                      width: 36,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 16,
                        onPressed: () async {
                          _checkAndFetchLocation(forceReload: true);
                          HapticFeedback.lightImpact();
                        },
                        icon: Stack(
                          children: [
                            Positioned(
                              left: 0.5,
                              top: 0.5,
                              child: Icon(
                                Icons.location_on,
                                color: Colors.black.withValues(alpha: 0.6),
                                size: 16,
                              ),
                            ),
                            const Icon(
                              Icons.location_on,
                              color: Colors.white,
                              size: 16,
                            ),
                          ],
                        ),
                        tooltip: '위치 정보 업데이트',
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              const SizedBox(width: 4),
            ],
            Container(
              width: 36,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: iconSize,
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FrameSettingsPage(
                        petList: _petList,
                        frameEnabled: _frameEnabled,
                        selectedPetId: _selectedPetId,
                        onPetListChanged: (list, selectedId) {
                          setState(() {
                            _petList = list;
                            _selectedPetId = selectedId;
                          });
                          if (_frameEnabled && _petList.isNotEmpty) {
                            final selectedPet = _selectedPetId != null
                                ? _petList.firstWhere(
                                    (pet) => pet.id == _selectedPetId,
                                    orElse: () => _petList.first,
                                  )
                                : _petList.first;
                            if (selectedPet.locationEnabled) {
                              _checkAndFetchLocation(alwaysReload: true);
                            } else if (mounted) {
                              setState(() {
                                _currentLocation = null;
                              });
                            }
                          }
                        },
                        onFrameEnabledChanged: (enabled) {
                          setState(() {
                            _frameEnabled = enabled;
                          });
                          _saveFrameEnabled();
                          if (enabled && _petList.isNotEmpty) {
                            final selectedPet = _selectedPetId != null
                                ? _petList.firstWhere(
                                    (pet) => pet.id == _selectedPetId,
                                    orElse: () => _petList.first,
                                  )
                                : _petList.first;
                            if (selectedPet.locationEnabled) {
                              _checkAndFetchLocation(alwaysReload: true);
                            }
                          } else if (mounted) {
                            setState(() {
                              _currentLocation = null;
                            });
                          }
                        },
                        onSelectedPetChanged: (selectedId) {
                          setState(() {
                            _selectedPetId = selectedId;
                          });
                          final currentPet = selectedId != null
                              ? _petList.firstWhere(
                                  (pet) => pet.id == selectedId,
                                  orElse: () => _petList.first,
                                )
                              : _petList.first;
                          if (currentPet.locationEnabled) {
                            _checkAndFetchLocation(alwaysReload: true);
                          } else if (mounted) {
                            setState(() {
                              _currentLocation = null;
                            });
                          }
                        },
                      ),
                    ),
                  );
                },
                icon: Stack(
                  children: [
                    Positioned(
                      left: 0.5,
                      top: 0.5,
                      child: Icon(
                        _frameEnabled
                            ? Icons.photo_filter
                            : Icons.photo_filter_outlined,
                        color: Colors.black.withValues(alpha: 0.6),
                        size: iconSize,
                      ),
                    ),
                    Icon(
                      _frameEnabled
                          ? Icons.photo_filter
                          : Icons.photo_filter_outlined,
                      color: _frameEnabled ? kMainPink : Colors.white,
                      size: iconSize,
                    ),
                  ],
                ),
                tooltip: '프레임 설정',
              ),
            ),
            const SizedBox(width: 4),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  debugPrint('[Petgram] ❤️ Support button tapped');
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => SettingsPage()));
                },
                child: Container(
                  width: 36,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.coffee,
                    color: Colors.white,
                    size: iconSize,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 오른쪽 옵션 패널 (카메라 전환 버튼, 밝기 조절)
  Widget _buildRightOptionsPanel() {
    final previewDims = _calculateCameraPreviewDimensions();
    final double overlayTop = previewDims['overlayTop']!;
    final double overlayBottom = previewDims['overlayBottom']!;

    return Positioned(
      right: 8,
      top: overlayTop > 0 ? overlayTop : 0,
      bottom: overlayBottom > 0 ? overlayBottom : 0,
      child: GestureDetector(
        // 오른쪽 옵션 패널의 탭이 전체 화면 GestureDetector보다 우선순위를 가지도록
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end, // 오른쪽 끝 정렬
              children: [
                // 밝기 조절 슬라이더 (세로) - 개별 pill 배경 적용
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _buildBrightnessSlider(),
                ),
                const SizedBox(height: 10),
                // 카메라 전환 버튼 (전면/후면) - 개별 pill 배경 적용
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _buildOptionIconButton(
                    icon: _cameraLensDirection == CameraLensDirection.back
                        ? Icons.camera_front
                        : Icons.camera_rear,
                    isActive: true,
                    onTap: _switchCamera,
                    tooltip: _cameraLensDirection == CameraLensDirection.back
                        ? '전면 카메라로 전환'
                        : '후면 카메라로 전환',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 밝기 조절 슬라이더 (필터 강도 조절 슬라이더와 동일한 구조)
  Widget _buildBrightnessSlider() {
    return Container(
      width: 48,
      height: 200,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // 밝기 아이콘
          Icon(
            _brightnessValue > 0
                ? Icons.brightness_high
                : _brightnessValue < 0
                ? Icons.brightness_low
                : Icons.brightness_medium,
            color: Colors.white,
            size: 24,
            shadows: [
              // 흰색 배경에서도 또렷하게 보이도록 그림자 추가
              Shadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 슬라이더 영역 (필터 강도 조절 슬라이더와 동일한 방식 - onPanUpdate 사용)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double sliderHeight = constraints.maxHeight;

                return Listener(
                  onPointerDown: (event) {
                    // 터치 시작 시 값 업데이트
                    final double localY = event.localPosition.dy.clamp(
                      0.0,
                      sliderHeight,
                    );
                    final double normalized = localY / sliderHeight;
                    final double newValue = ((1.0 - normalized) * 20.0 - 10.0)
                        .clamp(-10.0, 10.0);
                    setState(() {
                      _brightnessValue = newValue;
                    });
                    HapticFeedback.selectionClick();
                  },
                  onPointerMove: (event) {
                    if (event.down) {
                      // 드래그 중 값 업데이트
                      final double localY = event.localPosition.dy.clamp(
                        0.0,
                        sliderHeight,
                      );
                      final double normalized = localY / sliderHeight;
                      final double newValue = ((1.0 - normalized) * 20.0 - 10.0)
                          .clamp(-10.0, 10.0);
                      setState(() {
                        _brightnessValue = newValue;
                      });
                    }
                  },
                  onPointerUp: (_) {
                    HapticFeedback.selectionClick();
                  },
                  child: Stack(
                    children: [
                      // 배경 트랙
                      Center(
                        child: Container(
                          width: 4,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      // 현재 값 표시 (썸)
                      Align(
                        alignment: Alignment(
                          0,
                          -((_brightnessValue + 10.0) / 20.0 * 2.0 -
                              1.0), // -10~10을 -1.0~1.0으로
                        ),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: kMainPink,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // 밝기 값 표시
          Text(
            _brightnessValue == 0.0
                ? '0'
                : _brightnessValue > 0
                ? '+${_brightnessValue.toInt()}'
                : '${_brightnessValue.toInt()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 왼쪽 옵션 패널 (아이콘만 표시, 배경 없음)
  Widget _buildLeftOptionsPanel() {
    final previewDims = _calculateCameraPreviewDimensions();
    final double overlayTop = previewDims['overlayTop']!;
    final double overlayBottom = previewDims['overlayBottom']!;

    // 1:1 모드에서 프리뷰 영역 안에 모든 요소가 들어오도록
    // 간격을 최소화하고 프리뷰 영역에 맞춤
    final double topPadding = overlayTop > 0 ? overlayTop + 4.0 : 0;
    final double bottomPadding = overlayBottom > 0 ? overlayBottom + 4.0 : 0;

    return Positioned(
      key: ValueKey('left_options_${_uiZoomScale.toStringAsFixed(2)}'),
      left: 8,
      top: topPadding,
      bottom: bottomPadding,
      child: GestureDetector(
        // 왼쪽 옵션 패널의 탭이 전체 화면 GestureDetector보다 우선순위를 가지도록
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 플래시 토글
                _buildOptionIconButton(
                  icon: _flashMode == FlashMode.off
                      ? Icons.flash_off
                      : Icons.flash_on,
                  isActive: _flashMode != FlashMode.off,
                  onTap: _toggleFlash,
                  tooltip: _flashMode == FlashMode.off ? '플래시 켜기' : '플래시 끄기',
                ),
                const SizedBox(height: 4),
                // 격자 토글
                _buildOptionIconButton(
                  icon: _showGridLines ? Icons.grid_on : Icons.grid_off,
                  isActive: _showGridLines,
                  onTap: () {
                    setState(() {
                      _showGridLines = !_showGridLines;
                    });
                    _saveShowGridLines();
                  },
                  tooltip: _showGridLines ? '격자 끄기' : '격자 켜기',
                ),
                const SizedBox(height: 4),
                // 카메라 배율 선택 (0.8x, 1x, 1.5x 등) - 항상 표시
                _buildOptionIconButton(
                  key: ValueKey(
                    'zoom_button_${_uiZoomScale.toStringAsFixed(2)}',
                  ),
                  icon: Icons.center_focus_strong,
                  isActive: (_uiZoomScale - 1.0).abs() > 0.05,
                  label: '${_uiZoomScale.toStringAsFixed(1)}x',
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '카메라 배율',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Builder(
                          builder: (context) {
                            final uniqueOptions = _getZoomPresets();
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: uniqueOptions
                                  .map((ratio) => _buildZoomRatioOption(ratio))
                                  .toList(),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  tooltip: '배율: ${_uiZoomScale.toStringAsFixed(1)}x',
                ),
                const SizedBox(height: 6),
                // 화면 비율 선택 (활성화 표시 + 비율 표기)
                _buildOptionIconButton(
                  icon: Icons.crop_free,
                  isActive: true, // 항상 활성화 표시
                  label: _aspectLabel(_aspectMode), // 선택된 비율 표기
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '화면 비율',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              title: const Text('9:16'),
                              trailing:
                                  _aspectMode == AspectRatioMode.nineSixteen
                                  ? Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                _changeAspectMode(AspectRatioMode.nineSixteen);
                                Navigator.of(context).pop();
                              },
                            ),
                            ListTile(
                              title: const Text('3:4'),
                              trailing: _aspectMode == AspectRatioMode.threeFour
                                  ? Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                _changeAspectMode(AspectRatioMode.threeFour);
                                Navigator.of(context).pop();
                              },
                            ),
                            ListTile(
                              title: const Text('1:1'),
                              trailing: _aspectMode == AspectRatioMode.oneOne
                                  ? Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                _changeAspectMode(AspectRatioMode.oneOne);
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  tooltip: '화면 비율: ${_aspectLabel(_aspectMode)}',
                ),
                const SizedBox(height: 4),
                // 연속 촬영
                _buildOptionIconButton(
                  icon: Icons.camera_roll,
                  isActive: _isBurstMode,
                  label: _isBurstMode ? '${_burstCountSetting}' : null,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '연속 촬영 매수',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildBurstCountOption(3),
                            _buildBurstCountOption(5),
                            _buildBurstCountOption(10),
                            ListTile(
                              title: const Text('연속 촬영 끄기'),
                              trailing: !_isBurstMode
                                  ? Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                setState(() {
                                  _isBurstMode = false;
                                });
                                _saveBurstSettings();
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  tooltip: _isBurstMode
                      ? '연속 촬영: ${_burstCountSetting}장'
                      : '연속 촬영',
                ),
                const SizedBox(height: 4),
                // 타이머
                _buildOptionIconButton(
                  icon: Icons.timer,
                  isActive: _timerSeconds > 0,
                  label: _timerSeconds > 0 ? '${_timerSeconds}' : null,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '타이머 선택',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTimerOption(3),
                            _buildTimerOption(5),
                            _buildTimerOption(10),
                            ListTile(
                              title: const Text('타이머 끄기'),
                              trailing: _timerSeconds == 0
                                  ? Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                setState(() {
                                  _timerSeconds = 0;
                                });
                                _saveTimerSettings();
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  tooltip: _timerSeconds > 0 ? '타이머: ${_timerSeconds}초' : '타이머',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 아이콘만 표시하는 옵션 버튼 (배경 없음)
  Widget _buildOptionIconButton({
    Key? key,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    String? label,
    String? tooltip,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            key: key,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: 44,
            height: label != null ? 56 : 44,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      icon,
                      key: ValueKey(icon),
                      size: 24,
                      color: isActive ? kMainPink : Colors.white,
                      shadows: [
                        // 흰색 배경에서도 또렷하게 보이도록 그림자 추가
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                if (label != null) ...[
                  const SizedBox(height: 2),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        label,
                        key: ValueKey(label), // label 변경 시 애니메이션
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: isActive ? kMainPink : Colors.white,
                          shadows: [
                            // 흰색 배경에서도 또렷하게 보이도록 그림자 추가
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 1,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 촬영용 필터 선택 패널 (펼쳐질 때만 표시)
  Widget _buildFilterSelectionPanel() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 필터 패널 영역의 터치를 소비하여 바깥 오버레이가 닫히지 않도록 함
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFilterStrip(),
              const SizedBox(height: 8),
              _buildLiveIntensityControls(),
            ],
          ),
        ),
      ),
    );
  }

  /// 촬영용 필터 목록
  Widget _buildFilterStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 필터 선택 타이틀과 아코디언 아이콘
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '필터 선택',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  _filterPanelExpanded = false;
                });
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 20,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: kFilterOrder.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final key = kFilterOrder[index];
              final PetFilter f = _allFilters[key]!;
              final bool selected = f.key == _shootFilterKey;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    _shootFilterKey = f.key;
                  });
                  _saveSelectedFilter(f.key);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 65,
                  height: 60,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    gradient: selected
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              kMainPink,
                              kMainPink.withValues(alpha: 0.8),
                            ],
                          )
                        : null,
                    color: selected
                        ? null
                        : Colors.black.withValues(
                            alpha: 0.4,
                          ), // 상단 후원하기 아이콘과 동일
                    borderRadius: BorderRadius.circular(18), // 상단 후원하기 아이콘과 동일
                    border: Border.all(
                      color: selected
                          ? Colors.transparent
                          : Colors.white.withValues(
                              alpha: 0.3,
                            ), // 상단 후원하기 아이콘과 동일
                      width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: kMainPink.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null, // 선택되지 않은 경우 boxShadow 제거
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        f.icon,
                        size: 18,
                        color: selected
                            ? Colors.white
                            : Colors.white, // 아이콘 색상 흰색으로 통일
                      ),
                      const SizedBox(height: 4),
                      Flexible(
                        child: Text(
                          f.label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: selected
                                ? Colors.white
                                : Colors.white, // 텍스트 색상 흰색으로 통일
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 라이브 필터 강도 / 털색 프리셋
  Widget _buildLiveIntensityControls() {
    final bool isBasic = _shootFilterKey == 'basic_none';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '강도 조절',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: isBasic ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: isBasic,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildLiveCoatChip('밝은 털', 'light', 0.6),
                _buildLiveCoatChip('보통 털', 'mid', 0.8),
                _buildLiveCoatChip('진한 털', 'dark', 1.0),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: isBasic ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: isBasic,
            child: Slider(
              min: 0.4,
              max: 1.2,
              value: _liveIntensity,
              activeColor: kMainPink,
              onChanged: (v) {
                setState(() {
                  _liveIntensity = v;
                  _liveCoatPreset = 'custom';
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveCoatChip(String label, String key, double presetValue) {
    final selected = _liveCoatPreset == key;
    return GestureDetector(
      onTap: () {
        setState(() {
          _liveCoatPreset = key;
          _liveIntensity = presetValue;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                )
              : null,
          color: selected
              ? null
              : Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
          borderRadius: BorderRadius.circular(18), // 상단 후원하기 아이콘과 동일
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
            width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일
          ),
          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.white, // 텍스트 색상 흰색으로 통일
          ),
        ),
      ),
    );
  }

  Future<void> _onCapturePressed() async {
    if (_isProcessing) return;

    // 촬영 버튼 클릭 피드백
    HapticFeedback.lightImpact();

    // 참고: 실제 카메라 촬영 사운드는 시스템에서 자동으로 재생됩니다.
    // 추가 사운드 재생은 불필요하므로 제거했습니다.

    setState(() {
      _isCaptureAnimating = true;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 120));

      if (!mounted) return;

      setState(() {
        _isCaptureAnimating = false;
      });

      await _takePhoto();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isCaptureAnimating = false;
      });
    }
  }

  /// 하단: 보정(갤러리) - 촬영 버튼 - 강아지/고양이 사운드 버튼
  Widget _buildBottomBar() {
    // 9:16을 기준으로 전체 UI 크기 통일
    final double buttonSize = 36.0;
    final double captureButtonSize = 64.0;
    final double horizontalPadding = 12.0;
    final double verticalPadding = 6.0;
    // 하단 바 위치는 맨 아래에서 더 아래로 이동
    final double bottomOffset = 0.0; // 하단에 바로 배치

    // 하단 바 위치는 맨 아래에 고정
    return Positioned(
      bottom: bottomOffset,
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: const Offset(0, -12), // 살짝만 더 위로 이동 (-8 -> -12)
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            // 배경 완전히 제거 - 투명하게
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 왼쪽 버튼들
                Positioned(
                  left: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 필터 페이지로 이동하는 버튼
                      GestureDetector(
                        onTap: () async {
                          if (_isProcessing) return;
                          setState(() => _isProcessing = true);
                          try {
                            final picked = await _picker.pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 90,
                            );
                            if (!mounted || picked == null) {
                              setState(() => _isProcessing = false);
                              return;
                            }
                            final file = File(picked.path);
                            await _openFilterPage(file);
                          } finally {
                            if (mounted) {
                              setState(() => _isProcessing = false);
                            }
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          width: buttonSize,
                          height: buttonSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(
                              alpha: 0.4,
                            ), // 상단 후원하기 아이콘과 동일
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: 0.3,
                              ), // 상단 후원하기 아이콘과 동일
                              width: 1, // 상단 후원하기 아이콘과 동일
                            ),
                            // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
                          ),
                          child: Icon(
                            Icons.photo_library_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 촬영용 필터 선택 버튼
                      Flexible(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _filterPanelExpanded = !_filterPanelExpanded;
                            });
                          },
                          child: Builder(
                            builder: (context) {
                              final bool isFilterActive =
                                  _shootFilterKey != 'basic_none';
                              final bool isExpanded = _filterPanelExpanded;
                              final bool shouldShowPink =
                                  isFilterActive || isExpanded;

                              return FittedBox(
                                fit: BoxFit.scaleDown,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: shouldShowPink
                                        ? LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [
                                              kMainPink,
                                              kMainPink.withValues(alpha: 0.8),
                                            ],
                                          )
                                        : null,
                                    color: shouldShowPink
                                        ? null
                                        : Colors.black.withValues(
                                            alpha: 0.4,
                                          ), // 상단 후원하기 아이콘과 동일
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: shouldShowPink
                                          ? Colors.transparent
                                          : Colors.white.withValues(
                                              alpha: 0.3,
                                            ), // 상단 후원하기 아이콘과 동일
                                      width: shouldShowPink
                                          ? 0
                                          : 1, // 상단 후원하기 아이콘과 동일 (1.5 -> 1)
                                    ),
                                    // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        child: Icon(
                                          _allFilters[_shootFilterKey]!.icon,
                                          key: ValueKey(_shootFilterKey),
                                          size: 14,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      Flexible(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          child: Text(
                                            _allFilters[_shootFilterKey]!.label,
                                            key: ValueKey(_shootFilterKey),
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 중앙 촬영 버튼 (항상 화면 가로 중앙)
                Center(
                  child: Semantics(
                    label: '사진 촬영',
                    button: true,
                    child: GestureDetector(
                      onTap: _isProcessing ? null : _onCapturePressed,
                      child: AnimatedScale(
                        scale: _isCaptureAnimating ? 0.9 : 1.0,
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        child: Container(
                          width: captureButtonSize,
                          height: captureButtonSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kMainPink,
                            boxShadow: [
                              BoxShadow(
                                color: kMainPink.withValues(alpha: 0.4),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: captureButtonSize * 0.4,
                              height: captureButtonSize * 0.4,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 오른쪽 사운드 버튼들
                Positioned(
                  right: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSoundPill('멍', _playDogSound),
                      const SizedBox(width: 8),
                      _buildSoundPill('냥', _playCatSound),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimerOption(int seconds) {
    return ListTile(
      title: Text('${seconds}초'),
      trailing: _timerSeconds == seconds
          ? Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        setState(() {
          _timerSeconds = seconds;
        });
        _saveTimerSettings();
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildBurstCountOption(int count) {
    return ListTile(
      title: Text('${count}장'),
      trailing: _burstCountSetting == count && _isBurstMode
          ? Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        setState(() {
          _burstCountSetting = count;
          _isBurstMode = true;
        });
        _saveBurstSettings();
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildZoomRatioOption(double ratio) {
    // 프리셋 버튼 선택 시에만 정확히 일치하는지 확인 (0.05 이내)
    final bool isSelected = (_uiZoomScale - ratio).abs() <= 0.05;
    return ListTile(
      title: Text('${ratio.toStringAsFixed(1)}x'),
      trailing: isSelected
          ? Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        if (!mounted) return;
        // 프리셋 버튼을 탭할 때만 정확한 프리셋 값으로 설정
        final clampedRatio = ratio.clamp(_uiZoomMin, _uiZoomMax);
        setState(() {
          _uiZoomScale = clampedRatio;
          _baseUiZoomScale = clampedRatio;
          _selectedZoomRatio =
              clampedRatio; // 프리셋 선택 시에만 _selectedZoomRatio 업데이트
        });
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildSoundPill(String label, VoidCallback onTap) {
    final bool isDog = label == '멍';
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
            width: 1, // 상단 후원하기 아이콘과 동일
          ),
          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
        ),
        child: Center(
          child: Image.asset(
            isDog ? 'assets/icons/dog.png' : 'assets/icons/cat.png',
            width: 28,
            height: 28,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

/// ========================
///  설정 화면
/// ========================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  bool _isAvailable = false;
  List<ProductDetails> _products = [];
  bool _isLoading = false;
  String? _errorMessage;

  StreamSubscription<List<PurchaseDetails>>? _subscription;

  @override
  void initState() {
    super.initState();
    _initializePurchase();
    _listenToPurchaseUpdates();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _listenToPurchaseUpdates() {
    _subscription = _inAppPurchase.purchaseStream.listen(
      (List<PurchaseDetails> purchaseDetailsList) {
        _handlePurchaseUpdates(purchaseDetailsList);
      },
      onDone: () {
        _subscription?.cancel();
      },
      onError: (error) {
        setState(() {
          _isLoading = false;
          _errorMessage = '결제 처리 중 오류가 발생했습니다.';
        });
      },
    );
  }

  void _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) {
    for (final purchaseDetails in purchaseDetailsList) {
      if (purchaseDetails.status == PurchaseStatus.pending) {
        // 결제 대기 중
      } else if (purchaseDetails.status == PurchaseStatus.purchased ||
          purchaseDetails.status == PurchaseStatus.restored) {
        // 결제 완료
        _verifyPurchase(purchaseDetails);
      } else if (purchaseDetails.status == PurchaseStatus.error) {
        setState(() {
          _isLoading = false;
          _errorMessage = '결제 중 오류가 발생했습니다.';
        });
      }
      if (purchaseDetails.pendingCompletePurchase) {
        _inAppPurchase.completePurchase(purchaseDetails);
      }
    }
  }

  void _verifyPurchase(PurchaseDetails purchaseDetails) {
    setState(() {
      _isLoading = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('후원해주셔서 감사합니다! 💕'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _initializePurchase() async {
    _isAvailable = await _inAppPurchase.isAvailable();
    if (!_isAvailable) {
      setState(() {
        _errorMessage = '인앱 결제를 사용할 수 없습니다.\n인터넷 연결을 확인해주세요.';
      });
      return;
    }

    // 상품 ID 목록 (Google Play Console / App Store Connect에서 설정한 ID)
    const Set<String> productIds = {'donation_1000'};

    final ProductDetailsResponse response = await _inAppPurchase
        .queryProductDetails(productIds);

    if (response.error != null) {
      debugPrint('인앱 결제 에러: ${response.error}');
      setState(() {
        _errorMessage = '상품 정보를 불러오는 중 오류가 발생했습니다.\n${response.error!.message}';
      });
      return;
    }

    // 찾지 못한 상품 ID 확인
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint('찾지 못한 상품 ID: ${response.notFoundIDs}');
      setState(() {
        _errorMessage =
            '상품이 등록되지 않았습니다.\nGoogle Play Console / App Store Connect에서\n상품 ID "donation_1000"을 등록해주세요.';
      });
      return;
    }

    if (response.productDetails.isEmpty) {
      setState(() {
        _errorMessage = '상품 정보를 불러올 수 없습니다.\n잠시 후 다시 시도해주세요.';
      });
      return;
    }

    setState(() {
      _products = response.productDetails;
      _errorMessage = null;
    });
  }

  Future<void> _buyProduct(ProductDetails productDetails) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final PurchaseParam purchaseParam = PurchaseParam(
      productDetails: productDetails,
    );

    try {
      final bool success = await _inAppPurchase.buyNonConsumable(
        purchaseParam: purchaseParam,
      );

      if (!success) {
        setState(() {
          _isLoading = false;
          _errorMessage = '결제를 시작할 수 없습니다.';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '결제 중 오류가 발생했습니다: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      appBar: AppBar(
        title: const Text('후원하기'),
        backgroundColor: const Color(0xFFFFF5F8),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 후원하기 섹션
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 아이콘
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: kMainPink.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.coffee, color: kMainPink, size: 48),
                ),
                const SizedBox(height: 20),
                const Text(
                  '후원하기',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '이 앱이 마음에 드셨나요?\n개발자를 응원해주세요!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.grey,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(fontSize: 12, color: Colors.red[600]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_products.isEmpty && !_isLoading && _errorMessage == null)
                  const Text(
                    '상품 정보를 불러오는 중...',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else if (_isLoading)
                  const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(kMainPink),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _products.isNotEmpty
                          ? () => _buyProduct(_products.first)
                          : null,
                      icon: const Icon(Icons.coffee, size: 22),
                      label: const Text(
                        '천원 후원하기',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kMainPink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                if (_products.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '₩1,000',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ========================
///  프레임 설정 화면
/// ========================

class FrameSettingsPage extends StatefulWidget {
  final List<PetInfo> petList;
  final Function(List<PetInfo>, String?) onPetListChanged;
  final bool frameEnabled;
  final Function(bool) onFrameEnabledChanged;
  final String? selectedPetId;
  final Function(String?) onSelectedPetChanged;

  const FrameSettingsPage({
    super.key,
    required this.petList,
    required this.onPetListChanged,
    required this.frameEnabled,
    required this.onFrameEnabledChanged,
    required this.selectedPetId,
    required this.onSelectedPetChanged,
  });

  @override
  State<FrameSettingsPage> createState() => _FrameSettingsPageState();
}

class _FrameSettingsPageState extends State<FrameSettingsPage> {
  late List<PetInfo> _petList;
  late bool _frameEnabled;
  String? _selectedPetId;

  @override
  void initState() {
    super.initState();
    _petList = List.from(widget.petList);
    _frameEnabled = widget.frameEnabled;
    _selectedPetId = widget.selectedPetId;
  }

  Future<void> _savePetList() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _petList.map((pet) => jsonEncode(pet.toJson())).toList();
    await prefs.setStringList(kPetListKey, jsonList);
    // 선택된 반려동물 ID 저장
    if (_selectedPetId != null) {
      await prefs.setString(kSelectedPetIdKey, _selectedPetId!);
    }
    widget.onPetListChanged(_petList, _selectedPetId);
  }

  Future<void> _saveSelectedPetId() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedPetId != null) {
      await prefs.setString(kSelectedPetIdKey, _selectedPetId!);
    }
    widget.onSelectedPetChanged(_selectedPetId);
  }

  void _addPet() {
    _showPetEditDialog(null);
  }

  void _editPet(PetInfo pet) {
    _showPetEditDialog(pet);
  }

  void _deletePet(PetInfo pet) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '정말 삭제하시겠습니까?',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '삭제 시, 복구할 수 없습니다.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              final index = _petList.indexWhere((p) => p.id == pet.id);
              if (index != -1) {
                setState(() {
                  _petList.removeAt(index);
                  if (_selectedPetId == pet.id) {
                    _selectedPetId = _petList.isNotEmpty
                        ? _petList.first.id
                        : null;
                  }
                });
                _savePetList();
                Navigator.of(context).pop();
              }
            },
            child: const Text(
              '삭제',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showPetEditDialog(PetInfo? pet) {
    final nameController = TextEditingController(text: pet?.name ?? '');
    final breedController = TextEditingController(text: pet?.breed ?? '');
    String selectedType = pet?.type ?? 'dog';
    String? selectedGender =
        pet?.gender ?? 'male'; // 'male' or 'female' (기본값: male)
    DateTime? selectedDate = pet?.birthDate;
    int framePattern = pet?.framePattern ?? 1;
    bool locationEnabled = pet?.locationEnabled ?? false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 600),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 헤더
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: kMainPink.withValues(alpha: 0.1),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kMainPink.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            pet == null
                                ? Icons.add_circle_outline
                                : Icons.edit_outlined,
                            color: kMainPink,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            pet == null ? '반려동물 추가' : '반려동물 수정',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          color: Colors.grey[600],
                          onPressed: () => Navigator.of(context).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  // 내용
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 반려동물 종류
                          const Text(
                            '반려동물 종류',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('강아지'),
                                selected: selectedType == 'dog',
                                onSelected: (selected) {
                                  setDialogState(() {
                                    selectedType = 'dog';
                                  });
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedType == 'dog'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('고양이'),
                                selected: selectedType == 'cat',
                                onSelected: (selected) {
                                  setDialogState(() {
                                    selectedType = 'cat';
                                  });
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedType == 'cat'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // 이름 입력
                          const Text(
                            '이름',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: nameController,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: kMainPink,
                                  width: 2,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            maxLength: 9,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 20),
                          // 생년월일 선택
                          const Text(
                            '생년월일',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () {
                              dtp.DatePicker.showDatePicker(
                                context,
                                showTitleActions: true,
                                minTime: DateTime(2000, 1, 1),
                                maxTime: DateTime.now(),
                                onChanged: (date) {},
                                onConfirm: (date) {
                                  setDialogState(() {
                                    selectedDate = date;
                                  });
                                },
                                currentTime: selectedDate ?? DateTime.now(),
                                locale: dtp.LocaleType.ko,
                                theme: dtp.DatePickerTheme(
                                  itemStyle: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                  doneStyle: TextStyle(
                                    color: kMainPink,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  cancelStyle: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 16,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey[300]!),
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.white,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.calendar_today,
                                    color: kMainPink,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      selectedDate != null
                                          ? '${selectedDate!.year}.${selectedDate!.month.toString().padLeft(2, '0')}.${selectedDate!.day.toString().padLeft(2, '0')}'
                                          : '생년월일을 선택해주세요',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: selectedDate != null
                                            ? Colors.black87
                                            : Colors.grey[400],
                                        fontWeight: selectedDate != null
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    size: 16,
                                    color: Colors.grey[400],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          // 성별 선택
                          const Text(
                            '성별',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('Male'),
                                selected: selectedGender == 'male',
                                onSelected: (selected) {
                                  if (selected) {
                                    setDialogState(() {
                                      selectedGender = 'male';
                                    });
                                  }
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedGender == 'male'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('Female'),
                                selected: selectedGender == 'female',
                                onSelected: (selected) {
                                  if (selected) {
                                    setDialogState(() {
                                      selectedGender = 'female';
                                    });
                                  }
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedGender == 'female'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // 종 입력
                          const Text(
                            '품종',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: breedController,
                            decoration: InputDecoration(
                              hintText: '예: 골든 리트리버, 페르시안 등',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: kMainPink,
                                  width: 2,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            maxLength: 12,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 20),
                          // 위치 정보 활성화 옵션
                          const Text(
                            '촬영 위치 정보 표시',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  '사진 촬영 위치를 추가하여 표기하기 위해 위치정보를 사용합니다.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Switch(
                                value: locationEnabled,
                                onChanged: (value) {
                                  setDialogState(() {
                                    locationEnabled = value;
                                  });
                                },
                                activeThumbColor: kMainPink,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 하단 버튼
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: Colors.grey[200]!)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: BorderSide(color: Colors.grey[300]!),
                            ),
                            child: const Text(
                              '취소',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: () async {
                              final name = nameController.text.trim();
                              final breed = breedController.text.trim();
                              if (name.isEmpty ||
                                  selectedDate == null ||
                                  selectedGender == null ||
                                  breed.isEmpty) {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    title: const Text(
                                      '입력 오류',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    content: const Text(
                                      '모든 정보를 입력해주세요',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        child: const Text(
                                          '확인',
                                          style: TextStyle(color: kMainPink),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                return;
                              }
                              if (pet == null) {
                                // 추가
                                final newPet = PetInfo(
                                  id: DateTime.now().millisecondsSinceEpoch
                                      .toString(),
                                  name: name,
                                  type: selectedType,
                                  birthDate: selectedDate!,
                                  framePattern: framePattern,
                                  gender: selectedGender!,
                                  breed: breed,
                                  locationEnabled: locationEnabled,
                                );
                                setState(() {
                                  _petList.add(newPet);
                                  if (_selectedPetId == null) {
                                    _selectedPetId = newPet.id;
                                  }
                                });
                              } else {
                                // 수정
                                final index = _petList.indexWhere(
                                  (p) => p.id == pet.id,
                                );
                                if (index != -1) {
                                  setState(() {
                                    _petList[index] = PetInfo(
                                      id: pet.id,
                                      name: name,
                                      type: selectedType,
                                      birthDate: selectedDate!,
                                      framePattern: framePattern,
                                      gender: selectedGender!,
                                      breed: breed,
                                      locationEnabled: locationEnabled,
                                    );
                                  });
                                }
                              }
                              await _savePetList();
                              if (mounted) {
                                Navigator.of(context).pop();
                                setState(() {});
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kMainPink,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: Text(
                              pet == null ? '추가하기' : '저장하기',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      appBar: AppBar(
        title: const Text('프레임 설정'),
        backgroundColor: const Color(0xFFFFF5F8),
        elevation: 0,
      ),
      body: _petList.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.photo_filter_outlined,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '등록된 반려동물이 없습니다',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '반려동물을 먼저 등록해주세요',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _addPet(),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('반려동물 추가'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kMainPink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              children: [
                // 프레임 활성화 (간소화)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _frameEnabled
                              ? Icons.photo_filter
                              : Icons.photo_filter_outlined,
                          color: _frameEnabled ? kMainPink : Colors.grey[400],
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '프레임 활성화',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _frameEnabled
                                ? Colors.black87
                                : Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                    Switch(
                      value: _frameEnabled,
                      onChanged: _petList.isEmpty
                          ? null
                          : (value) {
                              setState(() {
                                _frameEnabled = value;
                              });
                              widget.onFrameEnabledChanged(value);
                            },
                      activeThumbColor: kMainPink,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 안내 문구 (간소화)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '반려동물을 탭하여 프레임을 적용할 반려동물을 선택하세요',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                ),
                // 반려동물별 프레임 설정
                ..._petList.map((pet) {
                  final isSelected = _selectedPetId == pet.id;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? kMainPink : Colors.grey[200]!,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() {
                            _selectedPetId = pet.id;
                          });
                          _saveSelectedPetId();
                          // 프레임 선택이 바뀌면 위치정보를 다시 불러오기
                          widget.onSelectedPetChanged(pet.id);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              // 아이콘
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? kMainPink.withValues(alpha: 0.15)
                                      : Colors.grey[100],
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  pet.type == 'dog'
                                      ? Icons.pets
                                      : Icons.favorite_rounded,
                                  color: isSelected
                                      ? kMainPink
                                      : Colors.grey[600],
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 이름과 정보
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          pet.name,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: isSelected
                                                ? Colors.black87
                                                : Colors.black,
                                          ),
                                        ),
                                        if (isSelected) ...[
                                          const SizedBox(width: 6),
                                          Icon(
                                            Icons.check_circle,
                                            color: kMainPink,
                                            size: 18,
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (pet.locationEnabled) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const SizedBox(width: 8),
                                          Icon(
                                            Icons.location_on,
                                            size: 14,
                                            color: Colors.grey[600],
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            '위치정보',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              // 편집/삭제 버튼
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                color: Colors.blue[400],
                                onPressed: () => _editPet(pet),
                                tooltip: '수정',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                color: Colors.red[400],
                                onPressed: () => _deletePet(pet),
                                tooltip: '삭제',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
                const SizedBox(height: 20),
                // 반려동물 추가 버튼
                OutlinedButton.icon(
                  onPressed: () => _addPet(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text(
                    '반려동물 추가',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kMainPink,
                    side: BorderSide(color: kMainPink, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}

/// ========================
///  필터 편집 / 저장 화면
/// ========================

class FilterPage extends StatefulWidget {
  final File imageFile;
  final String initialFilterKey;
  final PetInfo? selectedPet; // 펫 정보 (펫톤 보정용)
  final String? coatPreset; // 코트 프리셋 (light/mid/dark)

  const FilterPage({
    super.key,
    required this.imageFile,
    required this.initialFilterKey,
    this.selectedPet,
    this.coatPreset,
  });

  @override
  State<FilterPage> createState() => _FilterPageState();
}

/// 펫 전용 보정 프리셋 모델
class _PetAdjustPreset {
  final String id;
  final String label;
  final double brightness; // -50 ~ +50
  final double contrast; // -50 ~ +50
  final double sharpness; // 0 ~ 100

  const _PetAdjustPreset({
    required this.id,
    required this.label,
    required this.brightness,
    required this.contrast,
    required this.sharpness,
  });
}

/// 조정 타입 enum (슬라이딩 패널용)
enum AdjustmentType {
  filterAndIntensity, // 필터 + 강도
  petToneAndAdjust, // 펫톤 + 밝기/대비/선명
}

class _FilterPageState extends State<FilterPage> {
  late String _category;
  late String _filterKey;
  late File _currentImageFile;
  // initialFilterKey는 UI용 메타 정보로만 사용 (촬영 시 적용된 필터 정보)
  // 실제 필터 적용은 _filterKey로 제어하며, 항상 _currentImageFile만 사용

  final GlobalKey _previewKey = GlobalKey();
  final ImagePicker _picker = ImagePicker();
  bool _isSaving = false;
  bool _isPickingImage = false;

  double _intensity = 0.8;
  String _coatPreset = 'mid'; // light / mid / dark / custom

  // 썸네일 이미지 (프리뷰용, 저해상도)
  img.Image? _thumbnailImage;
  bool _isLoadingThumbnail = false;

  // 펫 전용 보정 (FilterPage 전용)
  double _editBrightness = 0.0; // -50 ~ +50
  double _editContrast = 0.0; // -50 ~ +50
  double _editSharpness = 0.0; // 0 ~ 100

  // 펫 전용 보정 프리셋
  String _selectedPresetId = 'basic'; // 기본 프리셋
  bool _isManualDetailMode = false; // false=프리셋, true=수동

  // 핀치줌 관련 변수
  double _baseScale = 1.0;
  double _currentScale = 1.0;
  Offset _offset = Offset.zero;
  Offset _lastFocalPoint = Offset.zero;

  // Preview matrix 저장 (Save 시 동일하게 사용)
  List<double>? _cachedPreviewMatrix;

  // 성능 최적화: 썸네일 JPG 바이트 캐시
  Uint8List? _cachedThumbnailBytes;

  // 성능 최적화: 슬라이더 변경 debounce 타이머
  Timer? _sliderDebounceTimer;

  // 성능 최적화: 이미지 크기 캐시
  Size? _cachedImageSize;

  // [UI 개편] 활성 조정 타입 (슬라이딩 패널용)
  AdjustmentType? _activeAdjustment;

  @override
  void initState() {
    super.initState();
    // 촬영 시 입혀진 필터가 원본이므로, 초기 필터 키를 'basic_none'으로 설정
    // 이미지 파일 자체가 이미 필터가 적용된 상태이므로, 원본 필터를 기본으로 설정
    _filterKey = 'basic_none';
    _category = 'basic';
    _currentImageFile = widget.imageFile;
    // widget.initialFilterKey는 UI용 메타 정보 (현재는 사용하지 않음)

    // 펫 정보 초기화
    if (widget.coatPreset != null) {
      _coatPreset = widget.coatPreset!;
    }

    // 기본 프리셋 적용
    if (_detailPresets.isNotEmpty) {
      _applyPreset(_detailPresets.first);
    }

    // 썸네일 생성 (프리뷰 최적화)
    _loadThumbnail();

    // 초기 Preview matrix 계산 및 캐시
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _cachedPreviewMatrix = _buildPreviewColorMatrix();
      }
    });
  }

  @override
  void dispose() {
    _sliderDebounceTimer?.cancel();
    super.dispose();
  }

  /// 썸네일 이미지 로드 (프리뷰 최적화: 고해상도 썸네일 생성)
  /// 화면 크기 측정 후 1.3~1.5배 큰 해상도로 썸네일 생성하여 GPU scaling blur 방지
  Future<void> _loadThumbnail() async {
    if (_isLoadingThumbnail) return;
    _isLoadingThumbnail = true;

    try {
      // 통합 이미지 로딩 헬퍼 사용 (PNG/JPG/HEIC 모두 지원)
      final originalImage = await loadImageWithExifRotation(_currentImageFile);
      if (originalImage != null) {
        // 이미지 비율 계산
        final imageAspectRatio = originalImage.width / originalImage.height;

        // 화면 크기 측정 (BuildContext가 필요하므로 WidgetsBinding 사용)
        final screenSize =
            WidgetsBinding
                .instance
                .platformDispatcher
                .views
                .first
                .physicalSize /
            WidgetsBinding
                .instance
                .platformDispatcher
                .views
                .first
                .devicePixelRatio;
        final screenWidth = screenSize.width;

        // Preview 영역 크기 계산 (화면 너비 기준, 패딩 제외)
        final availableWidth = screenWidth - 32; // 좌우 패딩 16px * 2
        double previewWidth = availableWidth;
        double previewHeight;

        // 이미지 비율에 따라 preview 높이 계산
        if (imageAspectRatio < 0.6) {
          // 9:16 비율 (세로형)
          previewHeight = availableWidth * (4 / 3); // 최대 높이 제한
          previewWidth = previewHeight * imageAspectRatio;
        } else if (imageAspectRatio <= 1.0) {
          // 1:1 이하 비율
          previewHeight = availableWidth / imageAspectRatio;
          if (previewHeight > availableWidth * (4 / 3)) {
            previewHeight = availableWidth * (4 / 3);
            previewWidth = previewHeight * imageAspectRatio;
          }
        } else {
          // 3:4 등 가로형
          previewHeight = availableWidth * (4 / 3);
        }

        // Preview 영역보다 최소 1.4배 큰 해상도로 썸네일 생성 (GPU scaling blur 방지)
        final double scaleFactor = 1.4;
        int targetWidth = (previewWidth * scaleFactor).round();
        int targetHeight = (previewHeight * scaleFactor).round();

        // 비율별 최소 크기 기준 적용
        if (imageAspectRatio < 0.6) {
          // 9:16 비율: 최소 1600px (세로 기준)
          targetHeight = math.max(targetHeight, 1600);
          targetWidth = (targetHeight * imageAspectRatio).round();
        } else if (imageAspectRatio <= 1.0) {
          // 1:1 비율: 최소 1200px
          targetWidth = math.max(targetWidth, 1200);
          targetHeight = (targetWidth / imageAspectRatio).round();
        } else {
          // 3:4 비율: 최소 1400px (가로 기준)
          targetWidth = math.max(targetWidth, 1400);
          targetHeight = (targetWidth / imageAspectRatio).round();
        }

        // 원본 이미지보다 크게 리사이즈하지 않도록 제한
        targetWidth = math.min(targetWidth, originalImage.width);
        targetHeight = math.min(targetHeight, originalImage.height);

        debugPrint(
          '[FilterPage] 📐 썸네일 생성: '
          '원본=${originalImage.width}x${originalImage.height}, '
          '비율=${imageAspectRatio.toStringAsFixed(3)}, '
          '프리뷰영역=${previewWidth.toStringAsFixed(0)}x${previewHeight.toStringAsFixed(0)}, '
          '썸네일=${targetWidth}x${targetHeight}',
        );

        // 고해상도 썸네일 생성
        final thumbnail = img.copyResize(
          originalImage,
          width: targetWidth,
          height: targetHeight,
          maintainAspect: true,
        );

        // 썸네일 JPG 바이트 캐시 (성능 최적화, 화질 향상)
        final thumbnailBytes = Uint8List.fromList(
          img.encodeJpg(thumbnail, quality: 90), // 화질 향상: 85 -> 90
        );

        if (mounted) {
          setState(() {
            _thumbnailImage = thumbnail;
            _cachedThumbnailBytes = thumbnailBytes;
            _isLoadingThumbnail = false;
          });
        }
      } else {
        debugPrint('[FilterPage] ⚠️ 썸네일 로드 실패: 이미지 디코딩 실패');
        if (mounted) {
          setState(() {
            _isLoadingThumbnail = false;
          });
        }
      }
    } catch (e) {
      debugPrint('[FilterPage] ❌ 썸네일 로드 실패: $e');
      if (mounted) {
        setState(() {
          _isLoadingThumbnail = false;
        });
      }
    }
  }

  Future<void> _pickNewImage() async {
    if (_isPickingImage) return;
    setState(() => _isPickingImage = true);

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );

      if (!mounted || picked == null) {
        setState(() => _isPickingImage = false);
        return;
      }

      setState(() {
        _currentImageFile = File(picked.path);
        // 필터 상태 보존: filter key, intensity, brightness, petTone preset은 초기화하지 않음
        // 사용자가 설정한 필터 및 보정 값은 새 이미지에서도 유지됨
        _isPickingImage = false;
        // 새 이미지 선택 시 핀치줌 리셋
        _currentScale = 1.0;
        _baseScale = 1.0;
        _offset = Offset.zero;
        // 캐시 초기화
        _cachedThumbnailBytes = null;
        _cachedImageSize = null;
        _cachedPreviewMatrix = null;
      });

      // 새 이미지 썸네일 로드
      _loadThumbnail();
    } catch (e) {
      if (mounted) {
        setState(() => _isPickingImage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('이미지를 불러오는 중 오류가 발생했어요.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFFFFF5F8),
        title: const Text(
          '필터 적용',
          style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black87),
        ),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            icon: _isPickingImage
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black87,
                    ),
                  )
                : const Icon(Icons.photo_library_rounded),
            onPressed: _isPickingImage ? null : _pickNewImage,
            tooltip: '새 사진 선택',
          ),
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: const Color(0xFFFFF5F8),
      body: SafeArea(
        child: Stack(
          children: [
            // 스크롤 가능한 전체 콘텐츠
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  // 미리보기 영역 (3:4 기준, 9:16의 경우 가로값 조정)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final availableWidth = constraints.maxWidth;
                        // 3:4 기준으로 세로값 계산
                        final double baseHeight = availableWidth * (4 / 3);

                        // 이미지 파일에서 실제 비율 가져오기 (FutureBuilder 사용)
                        return FutureBuilder<Size>(
                          future: _getImageSize(_currentImageFile),
                          builder: (context, snapshot) {
                            double displayWidth = availableWidth;
                            double displayHeight = baseHeight;

                            if (snapshot.hasData) {
                              final imageSize = snapshot.data!;
                              final imageAspectRatio =
                                  imageSize.width / imageSize.height;

                              // 최대 세로값: 3:4 기준
                              final double maxHeight = availableWidth * (4 / 3);

                              // 9:16 비율인 경우 (약 0.5625)
                              if (imageAspectRatio < 0.6) {
                                // 가로값을 줄이면서 비율 맞추기
                                displayHeight = maxHeight;
                                displayWidth = displayHeight * imageAspectRatio;
                              } else if (imageAspectRatio <= 1.0) {
                                // 1:1 이하 비율 (1:1 포함)
                                // 세로값을 이미지 비율에 맞춰 줄임
                                displayWidth = availableWidth;
                                displayHeight =
                                    availableWidth / imageAspectRatio;
                                // 최대값 제한
                                if (displayHeight > maxHeight) {
                                  displayHeight = maxHeight;
                                  displayWidth =
                                      displayHeight * imageAspectRatio;
                                }
                              } else {
                                // 1:1 초과 비율 (3:4 등)
                                // 3:4 기준으로 세로값 조정
                                displayWidth = availableWidth;
                                displayHeight = maxHeight;
                              }
                            }

                            return Container(
                              width: displayWidth,
                              height: displayHeight,
                              constraints: BoxConstraints(
                                minWidth: displayWidth,
                                maxWidth: displayWidth,
                                minHeight: displayHeight,
                                maxHeight: displayHeight,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: _buildFilteredImageContent(),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  // [UI 간소화] 필터 선택 영역 제거됨 (패널 내부로 이동)
                  // [위치 조정] 하단 아이콘 바 높이 + 여백 확보 (사진 하단이 안 짤리도록)
                  SizedBox(
                    height:
                        MediaQuery.of(context).size.height *
                        0.25, // 화면 높이의 25% 여백
                  ),
                ],
              ),
            ),
            // [UI 개편] 하단 아이콘 바
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomToolbar(),
            ),
            // [UI 개편] 슬라이딩 조정 패널
            if (_activeAdjustment != null)
              Positioned.fill(
                child: GestureDetector(
                  // 외부 클릭 시 패널 닫기
                  onTap: () {
                    setState(() {
                      _activeAdjustment = null;
                    });
                  },
                  child: Container(
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            // 패널 영역 클릭은 닫히지 않도록 함
                            onTap: () {},
                            child: _buildAdjustmentPanel(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// ColorMatrix를 실제 이미지 픽셀에 적용 (compute용 정적 함수)
  static img.Image _applyColorMatrixToImageStatic(List<dynamic> args) {
    final imageBytes = args[0] as Uint8List;
    final matrix = args[1] as List<double>;
    final image = img.decodeImage(imageBytes)!;
    final result = img.copyResize(
      image,
      width: image.width,
      height: image.height,
    );

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = result.getPixel(x, y);

        // [ROLLBACK] 0~1 정규화 롤백 - 원래 0~255 방식으로 복원
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        final a = pixel.a.toDouble();

        // ColorMatrix 적용 (0~255 색 공간)
        final newR =
            (matrix[0] * r +
                    matrix[1] * g +
                    matrix[2] * b +
                    matrix[3] * a +
                    matrix[4])
                .clamp(0, 255)
                .toInt();
        final newG =
            (matrix[5] * r +
                    matrix[6] * g +
                    matrix[7] * b +
                    matrix[8] * a +
                    matrix[9])
                .clamp(0, 255)
                .toInt();
        final newB =
            (matrix[10] * r +
                    matrix[11] * g +
                    matrix[12] * b +
                    matrix[13] * a +
                    matrix[14])
                .clamp(0, 255)
                .toInt();
        // Alpha는 원본 유지 (행렬 계산 무시)
        // multiplyColorMatrices에서 alpha 행을 [0, 0, 0, 1, 0]으로 강제하므로
        // alpha는 항상 원본 값 그대로 유지
        final newA = pixel.a.toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, newA));
      }
    }

    return result;
  }

  /// [DEPRECATED - GPU 렌더 캡처 방식 사용]
  /// ColorMatrix를 실제 이미지 픽셀에 적용 (인스턴스 메서드, compute 호출)
  /// GPU 렌더 캡처 방식으로 전환되어 더 이상 사용되지 않음
  @Deprecated('Use GPU render capture instead')
  Future<img.Image> _applyColorMatrixToImage(
    img.Image image,
    List<double> matrix,
  ) async {
    // 성능 최적화: 이미지를 직접 처리 (인코딩/디코딩 제거)
    // 큰 이미지의 경우에만 compute 사용
    if (image.width * image.height > 2000000) {
      // 200만 픽셀 이상이면 isolate에서 처리
      final imageBytes = Uint8List.fromList(img.encodePng(image));
      return await compute(_applyColorMatrixToImageStatic, [
        imageBytes,
        matrix,
      ]);
    } else {
      // 작은 이미지는 메인 스레드에서 직접 처리 (인코딩/디코딩 오버헤드 제거)
      return _applyColorMatrixToImageDirect(image, matrix);
    }
  }

  /// ColorMatrix를 직접 적용 (메인 스레드, 작은 이미지용)
  /// [ROLLBACK] 0~1 정규화 롤백 - 원래 0~255 방식으로 복원
  img.Image _applyColorMatrixToImageDirect(
    img.Image image,
    List<double> matrix,
  ) {
    final result = img.copyResize(
      image,
      width: image.width,
      height: image.height,
    );

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = result.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        final a = pixel.a.toDouble();

        // ColorMatrix 적용 (0~255 색 공간)
        final newR =
            (matrix[0] * r +
                    matrix[1] * g +
                    matrix[2] * b +
                    matrix[3] * a +
                    matrix[4])
                .clamp(0, 255)
                .toInt();
        final newG =
            (matrix[5] * r +
                    matrix[6] * g +
                    matrix[7] * b +
                    matrix[8] * a +
                    matrix[9])
                .clamp(0, 255)
                .toInt();
        final newB =
            (matrix[10] * r +
                    matrix[11] * g +
                    matrix[12] * b +
                    matrix[13] * a +
                    matrix[14])
                .clamp(0, 255)
                .toInt();
        // Alpha는 원본 유지 (행렬 계산 무시)
        // ColorFilter.matrix의 alpha 행은 [0, 0, 0, 1, 0]이므로 alpha는 항상 원본 유지
        final newA = pixel.a.toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, newA));
      }
    }

    return result;
  }

  /// 펫톤 프로파일 가져오기 (HomePage의 _getCurrentPetToneProfile과 동일한 로직)
  PetToneProfile? _getCurrentPetToneProfile() {
    if (widget.selectedPet == null) return null;

    final pet = widget.selectedPet!;
    if (pet.type != 'dog' && pet.type != 'cat') return null;

    String tone = _coatPreset;
    if (tone == 'custom' ||
        (tone != 'light' && tone != 'mid' && tone != 'dark')) {
      tone = 'mid';
    }

    final key = '${pet.type}_$tone';
    return kPetToneProfiles[key];
  }

  /// 프리뷰용 ColorMatrix 생성 (펫톤 + 필터 + 밝기/대비/선명도)
  /// Preview용 ColorMatrix 생성 (순서: petTone → filter → brightness → contrast)
  /// Sharpness는 matrix에 포함하지 않음 (Preview와 Save 모두 별도 적용으로 통일)
  List<double> _buildPreviewColorMatrix() {
    List<double> base = List.from(kIdentityMatrix);

    // 1. 펫톤 프로파일 적용 (40% 강도)
    final petProfile = _getCurrentPetToneProfile();
    if (petProfile != null) {
      final petToneMatrix = mixMatrix(
        kIdentityMatrix,
        petProfile.matrix,
        0.4, // 40% 강도로 약하게 적용
      );
      base = multiplyColorMatrices(base, petToneMatrix);
    }

    // 2. 필터 적용
    final PetFilter? currentFilter = _allFilters[_filterKey];
    if (currentFilter != null && currentFilter.key != 'basic_none') {
      final filterMatrix = mixMatrix(
        kIdentityMatrix,
        currentFilter.matrix,
        _intensity,
      );
      base = multiplyColorMatrices(base, filterMatrix);
    }

    // 3. 밝기 적용
    if (_editBrightness != 0.0) {
      final double b = (_editBrightness / 50.0) * 40.0; // 약한 범위로 clamp
      final List<double> brightnessMatrix = [
        1,
        0,
        0,
        0,
        b,
        0,
        1,
        0,
        0,
        b,
        0,
        0,
        1,
        0,
        b,
        0,
        0,
        0,
        1,
        0,
      ];
      base = multiplyColorMatrices(base, brightnessMatrix);
    }

    // 4. 대비 적용
    if (_editContrast != 0.0) {
      final double c = 1.0 + (_editContrast / 50.0) * 0.4; // 0.6 ~ 1.4 정도
      final List<double> contrastMatrix = [
        c,
        0,
        0,
        0,
        0,
        0,
        c,
        0,
        0,
        0,
        0,
        0,
        c,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ];
      base = multiplyColorMatrices(base, contrastMatrix);
    }

    // Sharpness는 matrix에 포함하지 않음 (Preview와 Save 모두 별도 적용)

    return base;
  }

  /// img.Image를 ui.Image로 변환 (FilterPage 저장용)
  Future<ui.Image> _convertImgImageToUiImage(img.Image image) async {
    final Uint8List pngBytes = Uint8List.fromList(img.encodePng(image));
    final ui.Codec codec = await ui.instantiateImageCodec(pngBytes);
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    return frameInfo.image;
  }

  /// GPU 기반 ColorMatrix 적용 (FilterPage 저장용)
  /// 비파괴적 함수: 입력 이미지를 dispose하지 않음 (소유권은 호출자가 관리)
  Future<ui.Image> _applyColorMatrixToUiImageGpu(
    ui.Image image,
    List<double> matrix,
  ) async {
    // matrix가 identity면 원본 반환
    if (_listEquals(matrix, kIdentityMatrix)) {
      return image;
    }

    final int width = image.width;
    final int height = image.height;

    // PictureRecorder로 새 이미지 생성
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    // ColorFilter 적용하여 그리기
    final paint = Paint()
      ..colorFilter = ColorFilter.matrix(matrix)
      ..filterQuality = FilterQuality.high;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );

    // Picture를 Image로 변환
    final ui.Picture picture = recorder.endRecording();
    final ui.Image filteredImage = await picture.toImage(width, height);
    picture.dispose();
    // 입력 image는 dispose하지 않음 (호출자가 관리)

    return filteredImage;
  }

  /// 펫 전용 보정 프리셋 목록
  static const List<_PetAdjustPreset> _detailPresets = [
    _PetAdjustPreset(
      id: 'basic',
      label: '기본',
      brightness: 0,
      contrast: 0,
      sharpness: 0,
    ),
    _PetAdjustPreset(
      id: 'eye_clear',
      label: '눈 또렷',
      brightness: 5,
      contrast: 20,
      sharpness: 60,
    ),
    _PetAdjustPreset(
      id: 'fur_soft',
      label: '털 보송',
      brightness: 10,
      contrast: -10,
      sharpness: 25,
    ),
    _PetAdjustPreset(
      id: 'dark_fur',
      label: '어두운 털',
      brightness: 20,
      contrast: 5,
      sharpness: 35,
    ),
  ];

  /// 프리셋 적용
  void _applyPreset(_PetAdjustPreset preset) {
    setState(() {
      _selectedPresetId = preset.id;
      _isManualDetailMode = false; // 프리셋 선택 시 수동 모드 해제
      _editBrightness = preset.brightness;
      _editContrast = preset.contrast;
      _editSharpness = preset.sharpness;
      // Preview matrix 캐시 무효화 (다음 빌드에서 재계산)
      _cachedPreviewMatrix = null;
    });
    debugPrint(
      '[Petgram] 🎨 Detail preset: $_selectedPresetId, '
      'brightness=$_editBrightness, contrast=$_editContrast, sharpness=$_editSharpness',
    );
  }

  /// 선명도(샤프) 적용 (compute용 정적 함수)
  static img.Image _applySharpenStatic(List<dynamic> args) {
    final imageBytes = args[0] as Uint8List;
    final amount = args[1] as double;
    if (amount <= 0.0) return img.decodeImage(imageBytes)!;

    final image = img.decodeImage(imageBytes)!;
    // 기본 샤프닝 커널 (3x3)
    // center: 1 + 5*amount, 주변: -amount
    final kernel = [
      -amount,
      -amount,
      -amount,
      -amount,
      1 + 5 * amount,
      -amount,
      -amount,
      -amount,
      -amount,
    ];

    // 간단한 컨볼루션 적용
    final result = img.copyResize(
      image,
      width: image.width,
      height: image.height,
    );

    for (int y = 1; y < image.height - 1; y++) {
      for (int x = 1; x < image.width - 1; x++) {
        double r = 0, g = 0, b = 0;

        // 3x3 커널 적용
        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            final pixel = image.getPixel(x + kx, y + ky);
            final weight = kernel[(ky + 1) * 3 + (kx + 1)];
            r += pixel.r * weight;
            g += pixel.g * weight;
            b += pixel.b * weight;
          }
        }

        final newR = r.clamp(0, 255).toInt();
        final newG = g.clamp(0, 255).toInt();
        final newB = b.clamp(0, 255).toInt();
        final a = image.getPixel(x, y).a.toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, a));
      }
    }

    return result;
  }

  /// [DEPRECATED - GPU 렌더 캡처 방식 사용]
  /// 선명도(샤프) 적용 (인스턴스 메서드, compute 호출)
  /// GPU 렌더 캡처 방식으로 전환되어 더 이상 사용되지 않음
  @Deprecated('Use GPU render capture instead')
  Future<img.Image> _applySharpen(img.Image image, double amount) async {
    if (amount <= 0.0) return image;

    // 성능 최적화: 큰 이미지의 경우에만 compute 사용
    if (image.width * image.height > 2000000) {
      // 200만 픽셀 이상이면 isolate에서 처리
      final imageBytes = Uint8List.fromList(img.encodePng(image));
      return await compute(_applySharpenStatic, [imageBytes, amount]);
    } else {
      // 작은 이미지는 메인 스레드에서 직접 처리
      return _applySharpenDirect(image, amount);
    }
  }

  /// 선명도 직접 적용 (메인 스레드, 작은 이미지용)
  img.Image _applySharpenDirect(img.Image image, double amount) {
    final result = img.copyResize(
      image,
      width: image.width,
      height: image.height,
    );

    // 기본 샤프닝 커널 (3x3)
    final kernel = [
      -amount,
      -amount,
      -amount,
      -amount,
      1 + 5 * amount,
      -amount,
      -amount,
      -amount,
      -amount,
    ];

    // 간단한 컨볼루션 적용
    for (int y = 1; y < image.height - 1; y++) {
      for (int x = 1; x < image.width - 1; x++) {
        double r = 0, g = 0, b = 0;

        // 3x3 커널 적용
        for (int ky = -1; ky <= 1; ky++) {
          for (int kx = -1; kx <= 1; kx++) {
            final pixel = image.getPixel(x + kx, y + ky);
            final weight = kernel[(ky + 1) * 3 + (kx + 1)];
            r += pixel.r * weight;
            g += pixel.g * weight;
            b += pixel.b * weight;
          }
        }

        final newR = r.clamp(0, 255).toInt();
        final newG = g.clamp(0, 255).toInt();
        final newB = b.clamp(0, 255).toInt();
        final a = image.getPixel(x, y).a.toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, a));
      }
    }

    return result;
  }

  /// 이미지 크기 가져오기 (캐시 사용)
  Future<Size> _getImageSize(File imageFile) async {
    // 캐시된 크기가 있고 파일이 동일하면 캐시 사용
    if (_cachedImageSize != null && imageFile.path == _currentImageFile.path) {
      return _cachedImageSize!;
    }

    try {
      // 통합 이미지 로딩 헬퍼 사용 (PNG/JPG/HEIC 모두 지원, EXIF 회전 처리)
      final img.Image? decoded = await loadImageWithExifRotation(imageFile);
      if (decoded != null) {
        final size = Size(decoded.width.toDouble(), decoded.height.toDouble());
        _cachedImageSize = size; // 캐시 저장
        return size;
      }
    } catch (e) {
      debugPrint('[FilterPage] 이미지 크기 가져오기 실패: $e');
    }
    // 기본값: 3:4 비율
    return const Size(3, 4);
  }

  /// 미리보기 영역: 선택된 필터 + 강도 + 펫 전용 보정 적용
  Widget _buildFilteredImageContent() {
    // 썸네일이 로드되지 않았으면 원본 파일 사용 (로딩 중)
    if (_thumbnailImage == null) {
      return Container(
        width: double.infinity,
        height: 200,
        color: Colors.grey[200],
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    // 썸네일을 메모리 이미지로 변환 (캐시된 바이트 사용)
    final thumbnailBytes =
        _cachedThumbnailBytes ??
        Uint8List.fromList(img.encodeJpg(_thumbnailImage!, quality: 85));
    final imageWidget = Image.memory(
      thumbnailBytes,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: double.infinity,
          color: Colors.grey[200],
          child: const Center(
            child: Icon(Icons.error_outline, size: 48, color: Colors.grey),
          ),
        );
      },
    );

    // 프리뷰용 matrix 생성 (펫톤 + 필터 + 밝기/대비)
    // Sharpness는 Preview와 Save 모두 matrix 적용 후 별도 처리로 통일
    final previewMatrix = _buildPreviewColorMatrix();
    final bool hasFilter = !_listEquals(previewMatrix, kIdentityMatrix);

    // Preview matrix를 캐시하여 Save 시 동일하게 사용
    _cachedPreviewMatrix = previewMatrix;

    // Preview matrix 로그 출력 (FilterPage 프리뷰용)
    // 캐시된 matrix를 사용하므로 로그는 최소화 (초기 로드 시에만 출력)
    if (_cachedPreviewMatrix == null || _cachedPreviewMatrix != previewMatrix) {
      debugPrint(
        '[Petgram] 🎨 [FILTER PAGE PREVIEW] Preview matrix = ${previewMatrix.join(', ')}',
      );
      debugPrint(
        '[Petgram] 🎨 [FILTER PAGE PREVIEW] Preview matrix context: petProfile=${_getCurrentPetToneProfile()?.id ?? 'none'}, '
        'filter=$_filterKey, intensity=$_intensity, brightness=$_editBrightness, contrast=$_editContrast',
      );

      // Alpha 행 검증 로그
      final alphaRow = [
        previewMatrix[15],
        previewMatrix[16],
        previewMatrix[17],
        previewMatrix[18],
        previewMatrix[19],
      ];
      if (alphaRow[0] != 0.0 ||
          alphaRow[1] != 0.0 ||
          alphaRow[2] != 0.0 ||
          alphaRow[3] != 1.0 ||
          alphaRow[4] != 0.0) {
        debugPrint(
          '[Petgram] ⚠️ [FILTER PAGE PREVIEW] Preview matrix alpha row is NOT [0,0,0,1,0]: $alphaRow',
        );
      } else {
        debugPrint(
          '[Petgram] ✅ [FILTER PAGE PREVIEW] Preview matrix alpha row is correct: $alphaRow',
        );
      }

      // 각 행의 RGB 계수 합과 offset 로그 (색 파괴 추적용)
      for (int row = 0; row < 3; row++) {
        final rgbSum =
            (previewMatrix[row * 5 + 0].abs() +
                    previewMatrix[row * 5 + 1].abs() +
                    previewMatrix[row * 5 + 2].abs())
                .toStringAsFixed(3);
        final offset = previewMatrix[row * 5 + 4].toStringAsFixed(2);
        final rowName = row == 0 ? 'R' : (row == 1 ? 'G' : 'B');
        debugPrint(
          '[Petgram] 📊 [FILTER PAGE PREVIEW] Preview matrix $rowName row: RGB sum=$rgbSum, offset=$offset',
        );
        if (double.parse(rgbSum) < 0.2) {
          debugPrint(
            '[Petgram] ⚠️ [FILTER PAGE PREVIEW] WARNING: $rowName row RGB sum is too low (<0.2), color may be destroyed!',
          );
        }
      }
    }

    // GPU 렌더 캡처를 위한 최종 위젯 구성
    // RepaintBoundary가 모든 필터 효과를 포함한 최종 렌더를 캡처
    Widget filteredWidget = imageWidget;

    // 1. 펫톤 + 필터 + 밝기/대비 적용 (ColorFiltered)
    if (hasFilter) {
      filteredWidget = ColorFiltered(
        colorFilter: ColorFilter.matrix(previewMatrix),
        child: filteredWidget,
      );
    }

    // 2. 선명도(Sharpness) 적용은 GPU 렌더 캡처에서는 별도 처리 불필요
    // GPU 렌더 캡처 시 프리뷰와 100% 동일하게 저장되므로
    // 선명도는 ColorFilter matrix에 포함시키거나 프리뷰에서도 동일하게 보여줘야 함
    // 현재는 프리뷰에서 선명도 효과를 보여주지 않으므로 저장 시에도 적용하지 않음
    // 향후 프리뷰에 선명도 효과를 추가하면 ImageFiltered를 사용하여 추가할 수 있음

    // 3. RepaintBoundary로 감싸서 GPU 렌더 캡처 준비
    // RepaintBoundary는 필터가 적용된 최종 위젯 전체를 감싸야 함
    final finalWidget = RepaintBoundary(
      key: _previewKey,
      child: filteredWidget,
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Colors.black,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: GestureDetector(
          onScaleStart: (details) {
            _baseScale = _currentScale;
            _lastFocalPoint = details.focalPoint;
          },
          onScaleUpdate: (details) {
            setState(() {
              _currentScale = (_baseScale * details.scale).clamp(1.0, 5.0);
              _offset = details.focalPoint - _lastFocalPoint;
            });
          },
          onScaleEnd: (details) {
            setState(() {
              // 스케일이 1.0에 가까우면 리셋
              if (_currentScale < 1.1) {
                _currentScale = 1.0;
                _offset = Offset.zero;
              }
              _baseScale = _currentScale;
            });
          },
          onDoubleTap: () {
            setState(() {
              _currentScale = 1.0;
              _baseScale = 1.0;
              _offset = Offset.zero;
            });
          },
          child: Transform.scale(
            scale: _currentScale,
            child: Transform.translate(offset: _offset, child: finalWidget),
          ),
        ),
      ),
    );
  }

  /// 카테고리 탭 (기본 / Pink / Dog / Cat)
  /// [UI 간소화] 더 이상 사용되지 않음 (패널 내부용으로 대체됨)
  @Deprecated('Use _buildCategoryTabsForPanel instead')
  Widget _buildCategoryTabs() {
    final tabs = <_FilterCategoryTab>[
      const _FilterCategoryTab(keyValue: 'basic', label: '기본'),
      const _FilterCategoryTab(keyValue: 'pink', label: 'Pink'),
      const _FilterCategoryTab(keyValue: 'dog', label: 'Dog'),
      const _FilterCategoryTab(keyValue: 'cat', label: 'Cat'),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: tabs.map((t) {
          final bool selected = _category == t.keyValue;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() {
                  _category = t.keyValue;
                  // 카테고리 변경 시 현재 선택된 필터가 새 카테고리에 없으면 첫 번째 필터로 변경
                  final list = _filtersByCategory[_category];
                  if (list != null && list.isNotEmpty) {
                    // 현재 선택된 필터가 새 카테고리에 있는지 확인
                    final hasCurrentFilter = list.any(
                      (f) => f.key == _filterKey,
                    );
                    if (!hasCurrentFilter) {
                      _filterKey = list.first.key;
                    }
                    // 현재 필터가 새 카테고리에 있으면 그대로 유지
                  } else {
                    _filterKey = 'basic_none';
                  }
                });
              },
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.95, end: selected ? 1.0 : 0.95),
                duration: const Duration(milliseconds: 200),
                key: ValueKey(selected), // selected 값이 변경될 때마다 애니메이션 재시작
                builder: (context, scale, child) {
                  return Transform.scale(
                    scale: scale,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(11),
                        boxShadow: selected
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          t.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected ? Colors.black87 : Colors.grey[600],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 카테고리 내 필터 버튼들
  /// [UI 간소화] 더 이상 사용되지 않음 (패널 내부용으로 대체됨)
  @Deprecated('Use _buildFilterButtonsForPanel instead')
  Widget _buildFilterButtons(List<PetFilter> filters) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 0),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final f = filters[index];
          final bool selected = f.key == _filterKey;
          return GestureDetector(
            onTap: () {
              // 필터 선택 시 즉시 업데이트하여 깜박임 방지
              setState(() {
                _filterKey = f.key;
                // Preview matrix 캐시 무효화 (다음 빌드에서 재계산)
                _cachedPreviewMatrix = null;
                // 원본 필터 선택 시 이미지 파일은 그대로 유지 (필터만 제거)
                // _currentImageFile은 변경하지 않음
              });
            },
            child: AnimatedContainer(
              key: ValueKey(
                'filter_${f.key}_${selected}',
              ), // key 추가하여 상태 변경 시 즉시 반영
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 72,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              decoration: BoxDecoration(
                gradient: selected
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                      )
                    : null,
                color: selected
                    ? null
                    : Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
                  width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일 (1.5 -> 1)
                ),
                // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.2)
                          : Colors.transparent, // 배경 제거 - 후원하기 아이콘과 동일하게
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      f.icon,
                      size: 18,
                      color: selected
                          ? Colors.white
                          : Colors.white, // 아이콘 색상 흰색으로 통일
                    ),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      f.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected
                            ? Colors.white
                            : Colors.white, // 텍스트 색상 흰색으로 통일
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 강도 조절 슬라이더 + 프리셋
  /// [UI 개편] 더 이상 사용되지 않음 (패널 내부로 이동)
  @Deprecated('Use _buildFilterIntensitySlider in panel instead')
  Widget _buildIntensityControls() {
    final PetFilter current =
        _allFilters[_filterKey] ?? _allFilters['basic_none']!;
    final bool isBasicNone = current.key == 'basic_none';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '필터 강도',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              if (isBasicNone)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '기본 모드',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Opacity(
            opacity: isBasicNone ? 0.4 : 1.0,
            child: IgnorePointer(
              ignoring: isBasicNone,
              child: Row(
                children: [
                  Expanded(child: _buildCoatPresetChip('밝은 털', 'light', 0.6)),
                  const SizedBox(width: 5),
                  Expanded(child: _buildCoatPresetChip('보통 털', 'mid', 0.8)),
                  const SizedBox(width: 5),
                  Expanded(child: _buildCoatPresetChip('진한 털', 'dark', 1.0)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Opacity(
            opacity: isBasicNone ? 0.4 : 1.0,
            child: IgnorePointer(
              ignoring: isBasicNone,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: kMainPink,
                  inactiveTrackColor: Colors.grey[300],
                  thumbColor: kMainPink,
                  overlayColor: kMainPink.withValues(alpha: 0.2),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  trackHeight: 2.5,
                ),
                child: Slider(
                  min: 0.4,
                  max: 1.2,
                  value: _intensity,
                  onChanged: (v) {
                    // 즉시 UI 업데이트
                    setState(() {
                      _intensity = v;
                      _coatPreset = 'custom';
                    });

                    // 프리뷰 업데이트는 debounce 적용 (성능 최적화)
                    _sliderDebounceTimer?.cancel();
                    _sliderDebounceTimer = Timer(
                      const Duration(milliseconds: 150),
                      () {
                        if (mounted) {
                          setState(() {
                            // Preview matrix 캐시 무효화 (다음 빌드에서 재계산)
                            _cachedPreviewMatrix = null;
                          });
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 프리셋 칩 리스트
  Widget _buildPresetChips() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 전체 너비에서 간격(8 * 3 = 24)을 제외하고 4등분
        final double availableWidth = constraints.maxWidth;
        final double spacing = 8.0 * (_detailPresets.length - 1);
        final double chipWidth =
            (availableWidth - spacing) / _detailPresets.length;

        return SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _detailPresets.map((preset) {
              final bool selected =
                  _selectedPresetId == preset.id && !_isManualDetailMode;
              return SizedBox(
                width: chipWidth,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    _applyPreset(preset);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: selected ? kMainPink : Colors.grey[200],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      preset.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: selected ? Colors.white : Colors.black87,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  /// 펫 전용 보정 헤더 (제목 + 프리셋/수동 전환)
  Widget _buildDetailHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          '펫 전용 보정',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: Colors.black87,
          ),
        ),
        TextButton.icon(
          onPressed: () {
            setState(() {
              _isManualDetailMode = !_isManualDetailMode;
              if (_isManualDetailMode) {
                // 슬라이더를 건드리기 시작하면 프리셋 id를 custom으로 변경
                _selectedPresetId = 'custom';
              }
            });
          },
          icon: Icon(
            _isManualDetailMode ? Icons.tune : Icons.auto_awesome,
            size: 16,
          ),
          label: Text(
            _isManualDetailMode ? '프리셋' : '수동설정',
            style: const TextStyle(fontSize: 12),
          ),
          style: TextButton.styleFrom(
            foregroundColor: kMainPink,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
        ),
      ],
    );
  }

  /// 펫 전용 보정 슬라이더 패널 (제목 없음)
  Widget _buildDetailAdjustPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSliderRow(
          label: '밝기',
          value: _editBrightness,
          min: -50,
          max: 50,
          onChanged: (v) {
            // 즉시 UI 업데이트 (슬라이더 값만)
            setState(() {
              _editBrightness = v;
              _selectedPresetId = 'custom';
              _isManualDetailMode = true;
            });

            // 프리뷰 업데이트는 debounce 적용 (성능 최적화)
            _sliderDebounceTimer?.cancel();
            _sliderDebounceTimer = Timer(const Duration(milliseconds: 150), () {
              if (mounted) {
                setState(() {
                  // Preview matrix 캐시 무효화 (다음 빌드에서 재계산)
                  _cachedPreviewMatrix = null;
                });
              }
            });
          },
        ),
        const SizedBox(height: 4),
        _buildSliderRow(
          label: '대비',
          value: _editContrast,
          min: -50,
          max: 50,
          onChanged: (v) {
            // 즉시 UI 업데이트 (슬라이더 값만)
            setState(() {
              _editContrast = v;
              _selectedPresetId = 'custom';
              _isManualDetailMode = true;
            });

            // 프리뷰 업데이트는 debounce 적용 (성능 최적화)
            _sliderDebounceTimer?.cancel();
            _sliderDebounceTimer = Timer(const Duration(milliseconds: 150), () {
              if (mounted) {
                setState(() {
                  // Preview matrix 캐시 무효화 (다음 빌드에서 재계산)
                  _cachedPreviewMatrix = null;
                });
              }
            });
          },
        ),
        const SizedBox(height: 4),
        _buildSliderRow(
          label: '선명도',
          value: _editSharpness,
          min: 0,
          max: 100,
          onChanged: (v) {
            // 즉시 UI 업데이트 (슬라이더 값만)
            setState(() {
              _editSharpness = v;
              _selectedPresetId = 'custom';
              _isManualDetailMode = true;
            });

            // 선명도는 프리뷰에 실시간 반영하지 않음 (저장 시에만 적용)
            // debounce 불필요
          },
        ),
      ],
    );
  }

  /// 펫 전용 보정 전체 섹션 (프리셋 + 수동 조절)
  /// [UI 개편] 더 이상 사용되지 않음 (패널 내부로 이동)
  @Deprecated('Use individual sliders in panel instead')
  Widget _buildPetDetailAdjustSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDetailHeader(),
          const SizedBox(height: 8),
          _buildPresetChips(),
          const SizedBox(height: 8),
          AnimatedCrossFade(
            crossFadeState: _isManualDetailMode
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: const Duration(milliseconds: 200),
            firstChild: _buildDetailAdjustPanel(), // 수동 슬라이더
            secondChild: const SizedBox.shrink(), // 프리셋 모드에서는 슬라이더 숨김
          ),
        ],
      ),
    );
  }

  /// 슬라이더 행 위젯
  Widget _buildSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    Color? textColor, // [UI 개편] 패널 내부에서 흰색 텍스트 사용
  }) {
    final Color labelColor = textColor ?? Colors.black87;
    final Color valueColor = textColor ?? Colors.grey;

    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label, style: TextStyle(fontSize: 12, color: labelColor)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
            activeColor: kMainPink,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 11, color: valueColor),
          ),
        ),
      ],
    );
  }

  // [UI 개편] 하단 아이콘 바
  Widget _buildBottomToolbar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 아이콘 버튼들 (간소화: 필터+강도, 펫톤+보정, 리셋)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildToolbarIconButton(
                  icon: Icons.photo_filter,
                  label: '필터',
                  type: AdjustmentType.filterAndIntensity,
                ),
                _buildToolbarIconButton(
                  icon: Icons.pets,
                  label: '펫톤',
                  type: AdjustmentType.petToneAndAdjust,
                ),
                _buildToolbarIconButton(
                  icon: Icons.refresh,
                  label: '리셋',
                  type: null, // 리셋은 특별 처리
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 저장 버튼
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _onSavePressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kMainPink,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : const Text(
                        '이 사진으로 저장하기',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // [UI 개편] 선택 상태 레이블 가져오기
  String _getSelectionLabel(AdjustmentType type) {
    if (type == AdjustmentType.filterAndIntensity) {
      final currentFilter =
          _allFilters[_filterKey] ?? _allFilters['basic_none']!;
      if (currentFilter.key != 'basic_none') {
        return currentFilter.label;
      }
      return '';
    } else if (type == AdjustmentType.petToneAndAdjust) {
      // 기본 프리셋이고 값이 모두 0인 경우는 표시하지 않음
      if (_selectedPresetId == 'basic' &&
          _editBrightness == 0.0 &&
          _editContrast == 0.0 &&
          _editSharpness == 0.0 &&
          !_isManualDetailMode) {
        return '';
      }

      // 현재 값이 프리셋 중 하나와 일치하는지 확인
      bool matchesPreset = false;
      String? matchingPresetId;
      for (final preset in _detailPresets) {
        if (preset.brightness == _editBrightness &&
            preset.contrast == _editContrast &&
            preset.sharpness == _editSharpness) {
          matchesPreset = true;
          matchingPresetId = preset.id;
          break;
        }
      }

      // 수동 모드이거나 커스텀이거나 프리셋과 일치하지 않으면 "수동 설정" 표시
      if (_isManualDetailMode ||
          _selectedPresetId == 'custom' ||
          !matchesPreset) {
        return '수동 설정';
      }

      // 프리셋이 선택된 경우
      final preset = _detailPresets.firstWhere(
        (p) => p.id == (matchingPresetId ?? _selectedPresetId),
        orElse: () => _detailPresets.first,
      );
      return preset.label;
    }
    return '';
  }

  // [UI 개편] 아이콘 버튼 위젯
  Widget _buildToolbarIconButton({
    required IconData icon,
    required String label,
    required AdjustmentType? type,
  }) {
    final bool isActive = _activeAdjustment == type;

    // [선택 표시] 필터나 펫톤이 선택되었는지 확인
    bool hasSelection = false;
    if (type == AdjustmentType.filterAndIntensity) {
      // 필터가 선택되었는지 확인 (basic_none이 아닌 경우)
      final currentFilter =
          _allFilters[_filterKey] ?? _allFilters['basic_none']!;
      hasSelection = currentFilter.key != 'basic_none';
    } else if (type == AdjustmentType.petToneAndAdjust) {
      // 펫톤 프리셋이 선택되었는지 확인
      hasSelection =
          _selectedPresetId != 'basic' ||
          _editBrightness != 0.0 ||
          _editContrast != 0.0 ||
          _editSharpness != 0.0 ||
          _isManualDetailMode;
    }

    return GestureDetector(
      onTap: () {
        if (type == null) {
          // 리셋 버튼 - 필터와 펫톤 모두 리셋
          setState(() {
            // 필터 리셋
            _filterKey = 'basic_none';
            _intensity = 0.8;
            // 펫톤 리셋
            _editBrightness = 0.0;
            _editContrast = 0.0;
            _editSharpness = 0.0;
            _coatPreset = 'mid';
            _selectedPresetId = 'basic';
            _isManualDetailMode = false;
            if (_detailPresets.isNotEmpty) {
              _applyPreset(_detailPresets.first);
            }
            _activeAdjustment = null;
            _cachedPreviewMatrix = null;
          });
        } else {
          // 같은 버튼 다시 누르면 패널 닫힘
          setState(() {
            _activeAdjustment = isActive ? null : type;
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isActive ? kMainPink : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: isActive ? Colors.white : Colors.black87,
                  size: 24,
                ),
              ),
              // [선택 표시] 선택된 경우 작은 점 표시
              if (hasSelection && !isActive)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: kMainPink,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isActive
                      ? kMainPink
                      : (hasSelection
                            ? kMainPink.withOpacity(0.7)
                            : Colors.black54),
                  fontWeight: isActive || hasSelection
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
              // 선택된 필터/펫톤 정보 표시 (가독성 개선)
              if (hasSelection && !isActive)
                Container(
                  margin: const EdgeInsets.only(top: 3),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: kMainPink.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _getSelectionLabel(type!),
                    style: TextStyle(
                      fontSize: 9,
                      color: kMainPink,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // [UI 개편] 슬라이딩 조정 패널
  Widget _buildAdjustmentPanel() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.only(bottom: 72),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더 (제목 + X 버튼)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _getAdjustmentTitle(_activeAdjustment!),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () {
                    setState(() {
                      _activeAdjustment = null;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 패널 본문
            _buildAdjustmentPanelBody(),
          ],
        ),
      ),
    );
  }

  // [UI 개편] 패널 본문 (타입별 분기)
  Widget _buildAdjustmentPanelBody() {
    switch (_activeAdjustment!) {
      case AdjustmentType.filterAndIntensity:
        return _buildFilterAndIntensityPanel();
      case AdjustmentType.petToneAndAdjust:
        return _buildPetToneAndAdjustPanel();
    }
  }

  // [UI 개편] 조정 타입별 제목
  String _getAdjustmentTitle(AdjustmentType type) {
    switch (type) {
      case AdjustmentType.filterAndIntensity:
        return '필터 & 강도';
      case AdjustmentType.petToneAndAdjust:
        return '펫톤 & 보정';
    }
  }

  // [UI 간소화] 필터 + 강도 패널
  Widget _buildFilterAndIntensityPanel() {
    final fallback =
        _filtersByCategory['basic'] ?? <PetFilter>[_allFilters['basic_none']!];
    final filters = _filtersByCategory[_category] ?? fallback;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 카테고리 탭 (패널 내부용 스타일)
        _buildCategoryTabsForPanel(),
        const SizedBox(height: 12),
        // 필터 버튼들 (패널 내부용 스타일)
        SizedBox(height: 60, child: _buildFilterButtonsForPanel(filters)),
        const SizedBox(height: 16),
        // 필터 강도 슬라이더
        _buildFilterIntensitySlider(),
      ],
    );
  }

  // [UI 간소화] 패널 내부용 카테고리 탭 (흰색 텍스트)
  Widget _buildCategoryTabsForPanel() {
    final tabs = <_FilterCategoryTab>[
      const _FilterCategoryTab(keyValue: 'basic', label: '기본'),
      const _FilterCategoryTab(keyValue: 'pink', label: 'Pink'),
      const _FilterCategoryTab(keyValue: 'dog', label: 'Dog'),
      const _FilterCategoryTab(keyValue: 'cat', label: 'Cat'),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: tabs.map((t) {
          final bool selected = _category == t.keyValue;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() {
                  _category = t.keyValue;
                  final list = _filtersByCategory[_category];
                  if (list != null && list.isNotEmpty) {
                    final hasCurrentFilter = list.any(
                      (f) => f.key == _filterKey,
                    );
                    if (!hasCurrentFilter) {
                      _filterKey = list.first.key;
                    }
                  } else {
                    _filterKey = 'basic_none';
                  }
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withOpacity(0.3)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Center(
                  child: Text(
                    t.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // [UI 간소화] 패널 내부용 필터 버튼들 (흰색 텍스트)
  Widget _buildFilterButtonsForPanel(List<PetFilter> filters) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 0),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final f = filters[index];
          final bool selected = f.key == _filterKey;
          return GestureDetector(
            onTap: () {
              setState(() {
                _filterKey = f.key;
                _cachedPreviewMatrix = null;
              });
            },
            child: AnimatedContainer(
              key: ValueKey('filter_${f.key}_${selected}'),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 72,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              decoration: BoxDecoration(
                gradient: selected
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                      )
                    : null,
                color: selected ? null : Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : Colors.white.withOpacity(0.3),
                  width: selected ? 0 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(f.icon, size: 24, color: Colors.white),
                  const SizedBox(height: 2),
                  Text(
                    f.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // [UI 간소화] 펫톤 + 보정 패널
  Widget _buildPetToneAndAdjustPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 펫톤 프리셋 섹션 (프리셋 모드일 때만 표시)
        if (!_isManualDetailMode) ...[_buildPetTonePresetSection()],
        // 밝기/대비/선명 슬라이더 (수동 모드일 때만 표시)
        if (_isManualDetailMode) ...[
          _buildBrightnessSlider(),
          const SizedBox(height: 8),
          _buildContrastSlider(),
          const SizedBox(height: 8),
          _buildSharpnessSlider(),
        ],
        // 모드 전환 버튼 (하단에 통일)
        const SizedBox(height: 12),
        _buildPetToneModeToggle(),
      ],
    );
  }

  // [UI 간소화] 펫톤 프리셋 섹션 (4가지: 기본, 눈또렷, 털 보송, 어두운 털)
  Widget _buildPetTonePresetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 4가지 프리셋 칩 (선택 표시 개선) - 타이틀 제거
        SizedBox(
          height: 44,
          child: Row(
            children: _detailPresets.map((preset) {
              final bool selected =
                  _selectedPresetId == preset.id && !_isManualDetailMode;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: preset.id != _detailPresets.last.id ? 8 : 0,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      _applyPreset(preset);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        // 선택된 경우: 핑크 그라데이션 배경 + 두꺼운 테두리
                        // 선택되지 않은 경우: 반투명 배경 + 얇은 테두리
                        gradient: selected
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  kMainPink,
                                  kMainPink.withValues(alpha: 0.85),
                                ],
                              )
                            : null,
                        color: selected ? null : Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? kMainPink.withValues(alpha: 1.0) // 선택 시 핑크 테두리
                              : Colors.white.withOpacity(0.4),
                          width: selected ? 2 : 1, // 선택 시 더 두꺼운 테두리
                        ),
                        // 선택된 경우 그림자 추가
                        boxShadow: selected
                            ? [
                                BoxShadow(
                                  color: kMainPink.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 선택된 경우 체크 아이콘 표시
                          if (selected) ...[
                            Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            preset.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // 펫톤 프리셋/수동 전환 버튼 (작고 간결한 형태)
  Widget _buildPetToneModeToggle() {
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _isManualDetailMode = !_isManualDetailMode;
            if (!_isManualDetailMode && _selectedPresetId == 'custom') {
              // 수동 모드에서 프리셋 모드로 전환 시 기본 프리셋 적용
              if (_detailPresets.isNotEmpty) {
                _applyPreset(_detailPresets.first);
              }
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isManualDetailMode ? Icons.auto_awesome : Icons.tune,
                size: 14,
                color: Colors.white.withOpacity(0.8),
              ),
              const SizedBox(width: 4),
              Text(
                _isManualDetailMode ? '프리셋' : '수동 설정',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // [UI 개편] 밝기 슬라이더
  Widget _buildBrightnessSlider() {
    return _buildSliderRow(
      label: '밝기',
      value: _editBrightness,
      min: -50,
      max: 50,
      onChanged: (v) {
        setState(() {
          _editBrightness = v;
          _selectedPresetId = 'custom';
          _isManualDetailMode = true;
        });
        _sliderDebounceTimer?.cancel();
        _sliderDebounceTimer = Timer(const Duration(milliseconds: 150), () {
          if (mounted) {
            setState(() {
              _cachedPreviewMatrix = null;
            });
          }
        });
      },
      textColor: Colors.white, // 패널 내부에서 흰색 텍스트 사용
    );
  }

  // [UI 개편] 대비 슬라이더
  Widget _buildContrastSlider() {
    return _buildSliderRow(
      label: '대비',
      value: _editContrast,
      min: -50,
      max: 50,
      onChanged: (v) {
        setState(() {
          _editContrast = v;
          _selectedPresetId = 'custom';
          _isManualDetailMode = true;
        });
        _sliderDebounceTimer?.cancel();
        _sliderDebounceTimer = Timer(const Duration(milliseconds: 150), () {
          if (mounted) {
            setState(() {
              _cachedPreviewMatrix = null;
            });
          }
        });
      },
      textColor: Colors.white, // 패널 내부에서 흰색 텍스트 사용
    );
  }

  // [UI 개편] 선명도 슬라이더
  Widget _buildSharpnessSlider() {
    return _buildSliderRow(
      label: '선명도',
      value: _editSharpness,
      min: 0,
      max: 100,
      onChanged: (v) {
        setState(() {
          _editSharpness = v;
          _selectedPresetId = 'custom';
          _isManualDetailMode = true;
        });
      },
      textColor: Colors.white, // 패널 내부에서 흰색 텍스트 사용
    );
  }

  // [UI 개편] 필터 강도 슬라이더
  Widget _buildFilterIntensitySlider() {
    final PetFilter current =
        _allFilters[_filterKey] ?? _allFilters['basic_none']!;
    final bool isBasicNone = current.key == 'basic_none';

    return Opacity(
      opacity: isBasicNone ? 0.4 : 1.0,
      child: IgnorePointer(
        ignoring: isBasicNone,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: kMainPink,
            inactiveTrackColor: Colors.grey[300],
            thumbColor: kMainPink,
            overlayColor: kMainPink.withValues(alpha: 0.2),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            trackHeight: 2.5,
          ),
          child: Slider(
            min: 0.4,
            max: 1.2,
            value: _intensity,
            onChanged: (v) {
              setState(() {
                _intensity = v;
                _coatPreset = 'custom';
              });
              _sliderDebounceTimer?.cancel();
              _sliderDebounceTimer = Timer(
                const Duration(milliseconds: 150),
                () {
                  if (mounted) {
                    setState(() {
                      _cachedPreviewMatrix = null;
                    });
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCoatPresetChip(String label, String key, double presetValue) {
    final selected = _coatPreset == key;
    return GestureDetector(
      onTap: () {
        setState(() {
          _coatPreset = key;
          _intensity = presetValue;
          // Preview matrix 캐시 무효화 (다음 빌드에서 재계산)
          _cachedPreviewMatrix = null;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                )
              : null,
          color: selected
              ? null
              : (_activeAdjustment == AdjustmentType.petToneAndAdjust
                    ? Colors.white.withOpacity(0.2)
                    : Colors.white),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : (_activeAdjustment == AdjustmentType.petToneAndAdjust
                      ? Colors.white.withOpacity(0.3)
                      : Colors.grey[300]!),
            width: 1.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: kMainPink.withValues(
                      alpha:
                          _activeAdjustment == AdjustmentType.petToneAndAdjust
                          ? 0.5
                          : 0.3,
                    ),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected
                  ? Colors.white
                  : (_activeAdjustment == AdjustmentType.petToneAndAdjust
                        ? Colors.white
                        : Colors.black87),
            ),
          ),
        ),
      ),
    );
  }

  /// 원본 이미지를 다시 로딩하여 필터 및 보정 처리 후 저장
  /// UI 프리뷰용 축소본이 아닌 원본 파일을 사용하여 고해상도 저장
  /// 9:16 비율 이미지는 중앙 crop으로 9:16 강제 적용
  Future<void> _onSavePressed() async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
    });

    File? processedTempFile;
    // 모든 ui.Image를 추적하여 finally에서 dispose (중복 dispose 방지)
    ui.Image? uiImageForDispose;
    final List<ui.Image> imagesToDispose = []; // dispose할 이미지 목록

    try {
      // ========================================
      // 저장 파이프라인: 원본 이미지만 사용 (preview 이미지 절대 사용 금지)
      // ========================================

      // 1. 원본 이미지 파일 다시 로딩 (UI 프리뷰용 축소본 사용하지 않음)
      // preview 변수(_thumbnailImage, _cachedThumbnailBytes 등) 절대 사용 금지
      final originalFile = widget.imageFile;
      if (!originalFile.existsSync()) {
        throw Exception('원본 이미지 파일을 찾을 수 없습니다: ${originalFile.path}');
      }

      debugPrint('[FilterPage] 📸 원본 이미지 로딩: ${originalFile.path}');

      // 2. 원본 이미지 디코딩 (EXIF 회전 처리 포함)
      // preview 리사이즈된 이미지 절대 사용 금지
      img.Image? decodedImage = await loadImageWithExifRotation(originalFile);

      if (decodedImage == null) {
        throw Exception('이미지 디코딩 실패: ${originalFile.path}');
      }

      // ✅ 저장 입력 이미지 크기 로그 (preview 이미지가 섞였는지 확인)
      debugPrint(
        '[FilterPage] ✅ SAVE INPUT SIZE: ${decodedImage.width}x${decodedImage.height} (원본 파일에서 직접 로딩)',
      );

      // 3. 원본 비율 유지 (crop 제거)
      // FilterPage는 이미 촬영된 이미지를 편집하므로 원본 비율 그대로 유지
      // 9:16 강제 crop 로직 제거 (HomePage에서만 비율 crop 적용)
      debugPrint(
        '[FilterPage] ✅ 원본 비율 유지: ${decodedImage.width}x${decodedImage.height} (비율: ${(decodedImage.width / decodedImage.height).toStringAsFixed(3)})',
      );

      // 4. img.Image를 ui.Image로 변환 (원본 해상도 유지)
      ui.Image uiImage = await _convertImgImageToUiImage(decodedImage);
      uiImageForDispose = uiImage;

      // ✅ ui.Image 변환 후 크기 확인 로그
      debugPrint(
        '[FilterPage] ✅ SAVE INPUT SIZE: ${uiImage.width}x${uiImage.height} (ui.Image 변환 완료)',
      );

      // 5. ColorMatrix 생성 (원본에 적용)
      // 프리뷰와 동일한 ColorMatrix를 재계산하여 원본에 적용
      // preview에서 사용한 ColorMatrix를 그대로 사용 (필터, intensity, brightness, contrast, petTone 모두 포함)
      final colorMatrix = _buildPreviewColorMatrix();

      debugPrint(
        '[FilterPage] 🎨 ColorMatrix 적용: filter=$_filterKey, intensity=$_intensity, '
        'brightness=$_editBrightness, contrast=$_editContrast, '
        'petTone=${_getCurrentPetToneProfile()?.id ?? 'none'}',
      );

      // 6. GPU에서 ColorFilter 적용 (안정화된 방식)
      // 비파괴적 함수: 새로운 이미지를 반환하므로 이전 이미지는 추적하여 finally에서 dispose
      ui.Image? previousImage;
      if (!_listEquals(colorMatrix, kIdentityMatrix)) {
        previousImage = uiImage; // 이전 이미지 추적
        uiImage = await _applyColorMatrixToUiImageGpu(uiImage, colorMatrix);
        // 이전 이미지가 새 이미지와 다른 경우에만 dispose 목록에 추가
        if (previousImage != uiImage) {
          imagesToDispose.add(previousImage); // finally에서 dispose
        }
        uiImageForDispose = uiImage; // 최신 이미지는 최종적으로 dispose
      } else {
        // ColorMatrix가 identity면 이미지가 그대로 반환되므로 uiImageForDispose만 설정
        uiImageForDispose = uiImage;
      }

      // 7. ui.Image를 PNG 바이트로 변환 (안정화 + fallback)
      Uint8List? pngBytes;

      // 첫 번째 시도: GPU 렌더 캡처 방식
      try {
        final ByteData? byteData = await uiImage.toByteData(
          format: ui.ImageByteFormat.png,
        );

        if (byteData != null && byteData.lengthInBytes > 0) {
          pngBytes = byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          );
          debugPrint('[FilterPage] ✅ GPU 렌더 캡처 성공: ${pngBytes.length} bytes');
        } else {
          debugPrint('[FilterPage] ⚠️ toByteData가 null 또는 빈 데이터 반환');
        }
      } catch (e) {
        debugPrint('[FilterPage] ⚠️ GPU 렌더 캡처 실패: $e');
      }

      // Fallback: img.Image로 직접 PNG 인코딩
      if (pngBytes == null || pngBytes.isEmpty) {
        debugPrint('[FilterPage] 🔄 Fallback: img.Image 직접 PNG 인코딩 시도');
        try {
          // ui.Image를 img.Image로 변환 후 PNG 인코딩
          final ByteData? rgbaData = await uiImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );

          if (rgbaData != null) {
            // img.Image 객체 생성
            final fallbackImage = img.Image(
              width: uiImage.width,
              height: uiImage.height,
            );

            final pixels = rgbaData.buffer.asUint8List();
            for (int y = 0; y < uiImage.height; y++) {
              for (int x = 0; x < uiImage.width; x++) {
                final index = (y * uiImage.width + x) * 4;
                final r = pixels[index];
                final g = pixels[index + 1];
                final b = pixels[index + 2];
                final a = pixels[index + 3];
                fallbackImage.setPixel(x, y, img.ColorRgba8(r, g, b, a));
              }
            }

            pngBytes = Uint8List.fromList(img.encodePng(fallbackImage));
            debugPrint(
              '[FilterPage] ✅ Fallback PNG 인코딩 성공: ${pngBytes.length} bytes',
            );
          }
        } catch (e) {
          debugPrint('[FilterPage] ❌ Fallback PNG 인코딩 실패: $e');
        }
      }

      // 최종 fallback: 원본 이미지에 ColorMatrix 직접 적용 (CPU 방식)
      if (pngBytes == null || pngBytes.isEmpty) {
        debugPrint('[FilterPage] 🔄 최종 Fallback: CPU 방식 ColorMatrix 적용 시도');
        try {
          final cpuProcessedImage = _applyColorMatrixToImageDirect(
            decodedImage,
            colorMatrix,
          );
          pngBytes = Uint8List.fromList(img.encodePng(cpuProcessedImage));
          debugPrint(
            '[FilterPage] ✅ CPU 방식 PNG 인코딩 성공: ${pngBytes.length} bytes',
          );
        } catch (e) {
          debugPrint('[FilterPage] ❌ CPU 방식 PNG 인코딩 실패: $e');
          throw Exception('모든 PNG 인코딩 방식이 실패했습니다. 저장할 수 없습니다.');
        }
      }

      // pngBytes가 여전히 null이거나 비어있으면 예외 발생
      if (pngBytes == null || pngBytes.isEmpty) {
        throw Exception('PNG 바이트 데이터가 비어있습니다.');
      }

      // 8. 임시 파일로 저장 (안정화된 방식)
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${dir.path}/filtered_$timestamp.png';
      processedTempFile = File(filePath);

      // 파일 쓰기 시도 (최대 3회 재시도)
      bool writeSuccess = false;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          await processedTempFile.writeAsBytes(
            pngBytes,
            flush: true, // 즉시 디스크에 쓰기
          );

          // 파일이 제대로 쓰였는지 확인
          if (await processedTempFile.exists()) {
            final fileSize = await processedTempFile.length();
            if (fileSize > 0) {
              writeSuccess = true;
              debugPrint(
                '[FilterPage] ✅ 파일 쓰기 성공 (시도 ${attempt + 1}): $fileSize bytes',
              );
              break;
            }
          }
        } catch (e) {
          debugPrint('[FilterPage] ⚠️ 파일 쓰기 실패 (시도 ${attempt + 1}): $e');
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
          }
        }
      }

      if (!writeSuccess) {
        throw Exception('임시 파일 쓰기 실패: 최대 재시도 횟수 초과');
      }

      // 9. 갤러리에 저장
      final finalImageBytes = await processedTempFile.readAsBytes();
      if (finalImageBytes.isEmpty) {
        throw Exception('최종 이미지 바이트가 비어있습니다.');
      }

      await Gal.putImageBytes(
        finalImageBytes,
        name: 'petgram_edit_${timestamp}.png',
      );

      // 저장 성공 피드백
      HapticFeedback.mediumImpact();

      debugPrint(
        '[FilterPage] ✅ 원본 이미지 기반 저장 완료: ${decodedImage.width}x${decodedImage.height}',
      );

      if (!mounted) return;

      // 성공 메시지 표시
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('필터가 적용된 사진이 갤러리에 저장되었어요! 📸'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('[FilterPage] ❌ 원본 이미지 기반 저장 오류: $e');
      debugPrint('[FilterPage] ❌ Stack trace: $stackTrace');
      if (!mounted) return;

      // 사용자 친화적인 에러 메시지
      String errorMessage = '저장 중 오류가 발생했어요.';
      if (e.toString().contains('permission') ||
          e.toString().contains('Permission') ||
          e.toString().contains('권한')) {
        errorMessage = '갤러리 저장 권한이 필요합니다. 설정에서 권한을 허용해주세요.';
      } else if (e.toString().contains('storage') ||
          e.toString().contains('저장')) {
        errorMessage = '저장 공간이 부족할 수 있습니다. 저장 공간을 확인해주세요.';
      } else if (e.toString().contains('디코딩') ||
          e.toString().contains('decode')) {
        errorMessage = '이미지를 불러오는 중 오류가 발생했어요. 다시 시도해주세요.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      // 리소스 정리: 모든 ui.Image를 한 번만 dispose
      // 중간에 생성된 이전 이미지들 dispose
      for (final img in imagesToDispose) {
        try {
          img.dispose();
          debugPrint('[FilterPage] ✅ 중간 이미지 dispose 완료');
        } catch (e) {
          debugPrint('[FilterPage] ⚠️ 중간 이미지 dispose 실패 (무시): $e');
        }
      }
      imagesToDispose.clear();

      // 최종 이미지 dispose (단 한 번만)
      if (uiImageForDispose != null) {
        try {
          uiImageForDispose.dispose();
          debugPrint('[FilterPage] ✅ 최종 ui.Image dispose 완료');
        } catch (e) {
          debugPrint('[FilterPage] ⚠️ 최종 ui.Image dispose 실패 (무시): $e');
        }
        uiImageForDispose = null; // 중복 dispose 방지
      }

      // 임시 파일 삭제
      if (processedTempFile != null) {
        try {
          if (await processedTempFile.exists()) {
            await processedTempFile.delete();
          }
        } catch (e) {
          debugPrint('[FilterPage] ⚠️ 임시 파일 삭제 실패: $e');
        }
      }

      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}

class _FilterCategoryTab {
  final String keyValue;
  final String label;

  const _FilterCategoryTab({required this.keyValue, required this.label});
}

/// 그리드라인 그리기
class GridLinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // 3x3 그리드
    final double thirdWidth = size.width / 3;
    final double thirdHeight = size.height / 3;

    // 세로선 2개
    canvas.drawLine(
      Offset(thirdWidth, 0),
      Offset(thirdWidth, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(thirdWidth * 2, 0),
      Offset(thirdWidth * 2, size.height),
      paint,
    );

    // 가로선 2개
    canvas.drawLine(
      Offset(0, thirdHeight),
      Offset(size.width, thirdHeight),
      paint,
    );
    canvas.drawLine(
      Offset(0, thirdHeight * 2),
      Offset(size.width, thirdHeight * 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 프레임 미리보기 Painter
class FramePreviewPainter extends CustomPainter {
  final List<PetInfo> petList;
  final String? selectedPetId;
  final ui.Image? dogIconImage;
  final ui.Image? catIconImage;
  final String? location; // 위치 정보

  FramePreviewPainter({
    required this.petList,
    required this.selectedPetId,
    this.dogIconImage,
    this.catIconImage,
    this.location,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (petList.isEmpty) return;

    // 선택된 반려동물 정보 가져오기
    PetInfo? selectedPet;
    if (selectedPetId != null) {
      try {
        selectedPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        selectedPet = petList.isNotEmpty ? petList.first : null;
      }
    } else {
      selectedPet = petList.isNotEmpty ? petList.first : null;
    }

    if (selectedPet == null) return;

    // 프레임은 size 전체(= previewBox 전체 테두리)에 맞춰 그림
    // size는 previewBox 크기와 정확히 일치함

    // 테두리 제거 - 모든 정보를 칩 형태로 표시
    final double chipHeight = size.width * 0.06;
    final double chipPadding = size.width * 0.03;
    final double chipSpacing = size.width * 0.015;
    final double chipCornerRadius = chipHeight * 0.3;
    final double horizontalPadding = size.width * 0.04;

    // 반려동물 정보
    final ui.Image? petIconImage = selectedPet.type == 'dog'
        ? dogIconImage
        : catIconImage;

    // 나이, 젠더, 종 정보
    final age = selectedPet.getAge();
    String genderText = '';
    if (selectedPet.gender != null && selectedPet.gender!.isNotEmpty) {
      final gender = selectedPet.gender!.toLowerCase();
      if (gender == 'male' || gender == 'm') {
        genderText = '♂';
      } else if (gender == 'female' || gender == 'f') {
        genderText = '♀';
      } else {
        genderText = selectedPet.gender!;
      }
    }
    String breedText =
        selectedPet.breed != null && selectedPet.breed!.isNotEmpty
        ? selectedPet.breed!.trim()
        : '';

    String truncateText(String text, int maxLength) {
      if (text.length <= maxLength) return text;
      return '${text.substring(0, maxLength)}...';
    }

    // 칩 너비 계산 헬퍼 함수 (그리지 않고 너비만 계산)
    double calculateChipWidth(String text, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;
      return chipWidth;
    }

    double drawChip(String text, double x, double y, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;

      // 글래스모피즘 효과: 반투명 배경 + 흰색 테두리 + 그림자
      final chipRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, chipWidth, chipHeight),
        Radius.circular(chipCornerRadius),
      );

      // 그림자 효과 (투명도 조절)
      final shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y + 1.5, chipWidth, chipHeight),
          Radius.circular(chipCornerRadius),
        ),
        shadowPaint,
      );

      // 글래스 배경 (반투명 흰색)
      final chipBgPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(chipRect, chipBgPaint);

      // 흰색 테두리
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRRect(chipRect, borderPaint);

      // 아이콘 그리기
      double currentX = x + chipPaddingHorizontal;
      if (iconImage != null) {
        final iconRect = Rect.fromLTWH(
          currentX,
          y + (chipHeight - iconSize) / 2,
          iconSize,
          iconSize,
        );
        canvas.drawImageRect(
          iconImage,
          Rect.fromLTWH(
            0,
            0,
            iconImage.width.toDouble(),
            iconImage.height.toDouble(),
          ),
          iconRect,
          Paint(),
        );
        currentX += iconSize + iconSpacing;
      }

      // 칩 텍스트 그리기
      final double chipTextX = currentX;
      final double chipTextY = y + (chipHeight - chipTextParagraph.height) / 2;
      canvas.drawParagraph(chipTextParagraph, Offset(chipTextX, chipTextY));

      return chipWidth;
    }

    // 상단 칩들
    double currentTopChipX = horizontalPadding;
    final double topChipY = chipPadding;

    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 나이, 젠더, 종을 한 칩에 묶어서 표시
    List<String> infoParts = [];
    infoParts.add('$age살');
    if (genderText.isNotEmpty) {
      infoParts.add(genderText);
    }
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • ');
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    // 하단 저작권 정보를 칩 형태로 표시 (촬영날짜, 위치정보)
    // previewBox 기준 상대적 비율로만 계산 (전체 화면 기준 수식 제거)
    final double additionalOffset = math.max(
      20.0,
      size.height * 0.02,
    ); // 추가 하향 offset (20~24px)
    final double bottomMargin =
        size.height * 0.12 - additionalOffset; // 하단 여백을 줄여서 텍스트를 더 아래로

    // 하단 칩 위치: bottomMargin을 줄여서 텍스트를 더 아래로 이동
    double finalBottomInfoY = size.height - bottomMargin - chipHeight;
    finalBottomInfoY = math.min(
      size.height - chipHeight - chipPadding,
      finalBottomInfoY,
    );

    // 상단 칩 위치 확인 (하단 문구가 상단 칩 아래에만 그려지도록)
    final double topChipBottom = topChipY + chipHeight + chipPadding;

    // 하단 문구가 상단 칩 영역과 겹치거나, 음수이면 그리지 않음
    if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
        finalBottomInfoY < 0) {
      return; // 하단 문구를 그리지 않음
    }

    final now = DateTime.now();
    final monthNames = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final dateStr = '📅 ${monthNames[now.month]} ${now.day}, ${now.year}';

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * 2.0; // 오른쪽 패딩
    final double bottomChipSpacing = chipPadding * 0.5; // 칩 간격

    // 1열: 촬영날짜 (아래쪽) - 칩 형태, 오른쪽 정렬
    // 너비만 계산 (그리지 않음)
    final dateChipWidth = calculateChipWidth(dateStr);
    final double dateChipX = size.width - rightMargin - dateChipWidth; // 오른쪽 정렬
    drawChip(dateStr, dateChipX, finalBottomInfoY);

    // 2열: 촬영장소 (위쪽, 위치 정보가 있을 때만) - 칩 형태, 오른쪽 정렬
    if (location != null && location!.isNotEmpty) {
      final locationText = '📍 Shot on location in $location';
      // 너비만 계산 (그리지 않음)
      final locationChipWidth = calculateChipWidth(locationText);
      final double locationChipX =
          size.width - rightMargin - locationChipWidth; // 오른쪽 정렬
      drawChip(
        locationText,
        locationChipX,
        finalBottomInfoY - chipHeight - bottomChipSpacing,
      );
    }
  }

  @override
  bool shouldRepaint(FramePreviewPainter oldDelegate) {
    // 선택된 반려동물의 framePattern도 체크
    PetInfo? oldPet;
    PetInfo? newPet;
    if (oldDelegate.selectedPetId != null) {
      try {
        oldPet = oldDelegate.petList.firstWhere(
          (pet) => pet.id == oldDelegate.selectedPetId,
        );
      } catch (e) {
        oldPet = null;
      }
    }
    if (selectedPetId != null) {
      try {
        newPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        newPet = null;
      }
    }

    return oldDelegate.selectedPetId != selectedPetId ||
        oldDelegate.petList.length != petList.length ||
        oldDelegate.location != location ||
        (oldPet?.framePattern != newPet?.framePattern);
  }
}

/// ========================
///  새로운 프레임 시스템
/// ========================

// 프레임 리소스 캐시 (정적 변수로 한 번만 로드)
ui.Image? _cachedLogoImage;
bool _isLoadingFrameResources = false;

/// 프레임 리소스 로드 (HomePage에서 호출)
Future<void> loadFrameResources() async {
  if (_isLoadingFrameResources) return;
  if (_cachedLogoImage != null) return;

  _isLoadingFrameResources = true;
  try {
    // 로고 이미지 로드
    final ByteData logoData = await rootBundle.load('assets/images/logo.png');
    final Uint8List logoBytes = logoData.buffer.asUint8List();
    final ui.Codec logoCodec = await ui.instantiateImageCodec(logoBytes);
    final ui.FrameInfo logoFrameInfo = await logoCodec.getNextFrame();
    _cachedLogoImage = logoFrameInfo.image;
    debugPrint('✅ 프레임 로고 로드 완료');

    // Caveat 폰트는 pubspec.yaml에 추가해야 합니다
    // Google Fonts에서 다운로드: https://fonts.google.com/specimen/Caveat
    // fonts/Caveat-Regular.ttf 파일을 추가하고 pubspec.yaml에 등록 필요
  } catch (e) {
    debugPrint('❌ 리소스 로드 실패: $e');
  }
  _isLoadingFrameResources = false;
}

/// 프레임 Painter (텍스트 중앙 정렬 + dropShadow)
class FramePainter extends CustomPainter {
  final List<PetInfo> petList;
  final String? selectedPetId;
  final double width;
  final double height;
  final double? topBarHeight;
  final double? bottomBarHeight; // 하단 오버레이 경계 (촬영 영역 하단)
  final ui.Image? dogIconImage;
  final ui.Image? catIconImage;
  final String? location; // 위치 정보

  FramePainter({
    required this.petList,
    required this.selectedPetId,
    required this.width,
    required this.height,
    this.topBarHeight,
    this.bottomBarHeight, // 하단 경계 추가
    this.dogIconImage,
    this.catIconImage,
    this.location,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (petList.isEmpty) return;

    // size가 0이거나 너무 작으면 그리지 않음
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    // 선택된 반려동물 정보 가져오기
    PetInfo? selectedPet;
    if (selectedPetId != null) {
      try {
        selectedPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        selectedPet = petList.isNotEmpty ? petList.first : null;
      }
    } else {
      selectedPet = petList.isNotEmpty ? petList.first : null;
    }

    if (selectedPet == null) return;

    // 테두리 제거 - 모든 정보를 칩 형태로 표시
    final double chipHeight = size.width * 0.06; // 칩 높이
    final double chipPadding = size.width * 0.03; // 칩과 화면 경계 사이 여백
    final double chipSpacing = size.width * 0.015; // 칩들 사이 간격
    final double chipCornerRadius = chipHeight * 0.3; // 칩 모서리 둥글기
    final double horizontalPadding = size.width * 0.04; // 좌우 여백

    // 상단 바로 밑 살짝 위쪽에 공간을 주기
    double frameTopOffset = (topBarHeight ?? 0) + chipPadding * 1.5;

    // 반려동물 정보
    final ui.Image? petIconImage = selectedPet.type == 'dog'
        ? dogIconImage
        : catIconImage;

    // 나이, 젠더, 종 정보
    final age = selectedPet.getAge();
    String genderText = '';
    if (selectedPet.gender != null && selectedPet.gender!.isNotEmpty) {
      final gender = selectedPet.gender!.toLowerCase();
      if (gender == 'male' || gender == 'm') {
        genderText = '♂';
      } else if (gender == 'female' || gender == 'f') {
        genderText = '♀';
      } else {
        genderText = selectedPet.gender!;
      }
    }
    String breedText =
        selectedPet.breed != null && selectedPet.breed!.isNotEmpty
        ? selectedPet.breed!.trim()
        : '';

    // 텍스트 길이 제한 헬퍼 함수
    String truncateText(String text, int maxLength) {
      if (text.length <= maxLength) return text;
      return '${text.substring(0, maxLength)}...';
    }

    // 칩 너비 계산 헬퍼 함수 (그리지 않고 너비만 계산)
    double calculateChipWidth(String text, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;
      return chipWidth;
    }

    // 칩 그리기 헬퍼 함수
    double drawChip(String text, double x, double y, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;

      // 칩 배경 그리기
      // 글래스모피즘 효과: 반투명 배경 + 흰색 테두리 + 그림자
      final chipRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, chipWidth, chipHeight),
        Radius.circular(chipCornerRadius),
      );

      // 그림자 효과 (투명도 조절)
      final shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y + 1.5, chipWidth, chipHeight),
          Radius.circular(chipCornerRadius),
        ),
        shadowPaint,
      );

      // 글래스 배경 (반투명 흰색)
      final chipBgPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(chipRect, chipBgPaint);

      // 흰색 테두리
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRRect(chipRect, borderPaint);

      // 아이콘 그리기
      double currentX = x + chipPaddingHorizontal;
      if (iconImage != null) {
        final iconRect = Rect.fromLTWH(
          currentX,
          y + (chipHeight - iconSize) / 2,
          iconSize,
          iconSize,
        );
        canvas.drawImageRect(
          iconImage,
          Rect.fromLTWH(
            0,
            0,
            iconImage.width.toDouble(),
            iconImage.height.toDouble(),
          ),
          iconRect,
          Paint(),
        );
        currentX += iconSize + iconSpacing;
      }

      // 칩 텍스트 그리기
      final double chipTextX = currentX;
      final double chipTextY = y + (chipHeight - chipTextParagraph.height) / 2;
      canvas.drawParagraph(chipTextParagraph, Offset(chipTextX, chipTextY));

      return chipWidth;
    }

    // 상단 칩들 (왼쪽부터)
    double currentTopChipX = horizontalPadding;
    final double topChipY = frameTopOffset + chipPadding;

    // 이름 칩
    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 생년월일/나이 칩
    // 나이, 젠더, 종을 한 칩에 묶어서 표시
    List<String> infoParts = [];
    infoParts.add('$age살');
    if (genderText.isNotEmpty) {
      infoParts.add(genderText);
    }
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • ');
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    // 하단 저작권 정보를 칩 형태로 표시 (촬영날짜, 위치정보)
    // 하단 오버레이 경계를 고려하여 촬영 영역 안에 그리기
    final double additionalOffset = math.max(
      20.0,
      size.height * 0.02,
    ); // 추가 하향 offset (20~24px)
    final double bottomInfoPadding = chipPadding * 1.5;

    // bottomBarSpace를 이미지 크기에 비례하도록 계산
    // 프리뷰에서는 화면 기준 100px이지만, 저장 이미지에서는 이미지 높이의 비율로 계산
    // 일반적인 화면 높이(약 800-900px)를 기준으로 100px은 약 11-12%에 해당
    // 안전하게 이미지 높이의 5%를 사용하되, 최소값은 chipHeight의 1.5배로 설정
    final double minBottomSpace = chipHeight * 1.5;
    final double proportionalBottomSpace = size.height * 0.05;
    final double bottomBarSpace = proportionalBottomSpace > minBottomSpace
        ? proportionalBottomSpace
        : minBottomSpace;

    // bottomBarHeight는 실제 촬영 영역의 하단 경계 (화면 기준)
    // 하단 문구는 촬영 영역 하단에서 여유 공간을 두고 표시
    // additionalOffset만큼 더 아래로 이동하기 위해 bottomBarSpace를 줄임
    double finalBottomInfoY;
    if (bottomBarHeight != null) {
      // 촬영 영역 하단을 기준으로 하단 문구 위치 계산
      // bottomBarSpace에서 additionalOffset을 빼서 텍스트를 더 아래로 이동
      finalBottomInfoY =
          bottomBarHeight! -
          (bottomBarSpace - additionalOffset) -
          bottomInfoPadding -
          chipHeight;

      // 상단 칩 위치 확인 (하단 문구가 상단 칩 아래에만 그려지도록)
      final double topChipBottom =
          (topBarHeight ?? chipPadding * 2) + chipHeight + chipPadding;

      // 하단 문구가 상단 칩 영역과 겹치거나, 음수이면 그리지 않음
      if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
          finalBottomInfoY < 0) {
        return; // 하단 문구를 그리지 않음
      }
    } else {
      // bottomBarHeight가 없으면 화면 하단 기준
      // bottomBarSpace에서 additionalOffset을 빼서 텍스트를 더 아래로 이동
      finalBottomInfoY =
          size.height -
          (bottomBarSpace - additionalOffset) -
          bottomInfoPadding -
          chipHeight;

      // 음수 체크
      if (finalBottomInfoY < 0) {
        return;
      }
    }

    final now = DateTime.now();
    final monthNames = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final dateStr = '📅 ${monthNames[now.month]} ${now.day}, ${now.year}';

    // finalBottomInfoY가 유효한지 최종 확인 (상단 칩 아래인지, 양수인지)
    final double topChipBottom =
        (topBarHeight ?? chipPadding * 2) + chipHeight + chipPadding;
    if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
        finalBottomInfoY < 0) {
      debugPrint(
        '[Petgram] ⚠️ 하단 칩 그리기 전 최종 체크 실패: finalBottomInfoY=$finalBottomInfoY, topChipBottom=$topChipBottom, 그리지 않음',
      );
      return; // 하단 칩을 그리지 않음
    }

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * 2.0; // 오른쪽 패딩
    final double chipSpacingBottom = chipPadding * 0.5; // 칩 간격

    // 1열: 촬영날짜 (아래쪽) - 칩 형태, 오른쪽 정렬
    // 너비만 계산 (그리지 않음)
    final dateChipWidth = calculateChipWidth(dateStr);
    final double dateChipX = size.width - rightMargin - dateChipWidth; // 오른쪽 정렬

    // dateChipX가 유효한지 확인 (음수이거나 화면 밖이면 그리지 않음)
    if (dateChipX >= 0 && dateChipX + dateChipWidth <= size.width) {
      drawChip(dateStr, dateChipX, finalBottomInfoY);
    } else {
      debugPrint(
        '[Petgram] ⚠️ 날짜 칩 X 좌표가 유효하지 않음: dateChipX=$dateChipX, dateChipWidth=$dateChipWidth, size.width=${size.width}',
      );
    }

    // 2열: 촬영장소 (위쪽, 위치 정보가 있을 때만) - 칩 형태, 오른쪽 정렬
    if (location != null && location!.isNotEmpty) {
      final locationText = '📍 Shot on location in $location';
      // 너비만 계산 (그리지 않음)
      final locationChipWidth = calculateChipWidth(locationText);
      final double locationChipX =
          size.width - rightMargin - locationChipWidth; // 오른쪽 정렬
      final double locationChipY =
          finalBottomInfoY - chipHeight - chipSpacingBottom;

      // locationChipY가 유효한지 확인 (상단 칩 아래인지, 양수인지)
      if (locationChipY >= topChipBottom + chipPadding * 2 &&
          locationChipX >= 0 &&
          locationChipX + locationChipWidth <= size.width) {
        drawChip(locationText, locationChipX, locationChipY);
      } else {
        debugPrint(
          '[Petgram] ⚠️ 위치 칩 좌표가 유효하지 않음: locationChipY=$locationChipY, locationChipX=$locationChipX, topChipBottom=$topChipBottom',
        );
      }
    }
  }

  @override
  bool shouldRepaint(FramePainter oldDelegate) {
    PetInfo? oldPet;
    PetInfo? newPet;
    if (oldDelegate.selectedPetId != null) {
      try {
        oldPet = oldDelegate.petList.firstWhere(
          (pet) => pet.id == oldDelegate.selectedPetId,
        );
      } catch (e) {
        oldPet = null;
      }
    }
    if (selectedPetId != null) {
      try {
        newPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        newPet = null;
      }
    }

    return oldDelegate.selectedPetId != selectedPetId ||
        oldDelegate.petList.length != petList.length ||
        oldDelegate.width != width ||
        oldDelegate.height != height ||
        oldDelegate.topBarHeight != topBarHeight ||
        oldDelegate.bottomBarHeight != bottomBarHeight ||
        (oldPet?.framePattern != newPet?.framePattern) ||
        (oldPet?.gender != newPet?.gender) ||
        (oldPet?.breed != newPet?.breed);
  }
}

/// 프레임 이미지 내보내기 클래스
class FrameExporter {
  /// RepaintBoundary를 사용하여 프레임이 적용된 이미지를 내보내기
  static Future<File?> exportFrameImage({
    required GlobalKey repaintBoundaryKey,
    required File sourceImageFile,
    required List<PetInfo> petList,
    required String? selectedPetId,
    required double width,
    required double height,
    double? topBarHeight,
  }) async {
    try {
      // RepaintBoundary에서 이미지 캡처
      final RenderRepaintBoundary? boundary =
          repaintBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;

      if (boundary == null) {
        debugPrint('❌ FrameExporter: RepaintBoundary를 찾을 수 없습니다');
        return null;
      }

      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) {
        image.dispose();
        debugPrint('❌ FrameExporter: 이미지 변환 실패');
        return null;
      }

      final Uint8List pngBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      // PNG를 디코딩하여 JPEG로 변환
      final img.Image? decodedImage = img.decodeImage(pngBytes);
      if (decodedImage == null) {
        image.dispose();
        debugPrint('❌ FrameExporter: PNG 디코딩 실패');
        return null;
      }

      // JPEG로 인코딩 (품질 95)
      final Uint8List jpegBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 100),
      );

      // 임시 파일로 저장
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/framed_export_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final File framedFile = File(filePath);
      await framedFile.writeAsBytes(jpegBytes);

      image.dispose();
      debugPrint('✅ FrameExporter: 프레임 이미지 내보내기 완료');
      return framedFile;
    } catch (e, stackTrace) {
      debugPrint('❌ FrameExporter error: $e');
      debugPrint('❌ FrameExporter stackTrace: $stackTrace');
      return null;
    }
  }
}

// FilterPage dispose 메서드 추가
