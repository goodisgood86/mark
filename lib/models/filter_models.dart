import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// 필터용 기본 행렬
const List<double> kIdentityMatrix = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0,
];

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

/// 필터 편집 프리셋 클래스
class PetAdjustPreset {
  final String id;
  final String label;
  final double brightness; // -50 ~ +50
  final double contrast; // -50 ~ +50
  final double sharpness; // 0 ~ 100

  const PetAdjustPreset({
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

/// 두 리스트가 동일한지 비교 (ColorMatrix 비교용)
bool colorMatrixEquals(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 0.0001) return false;
  }
  return true;
}

/// 두 매트릭스를 믹스
List<double> mixMatrix(List<double> a, List<double> b, double t) {
  final clamped = t.clamp(0.0, 1.2);
  return List.generate(a.length, (i) => a[i] + (b[i] - a[i]) * clamped);
}

/// 두 개의 ColorMatrix를 곱셈하여 하나로 합치기 (성능 개선)
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

/// 이미지의 평균 RGB 값을 계산 (색상 손실 추적용)
Map<String, double> calculateAverageRGB(img.Image image) {
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

