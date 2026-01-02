import 'package:flutter/material.dart';

/// 🔥 정적 분석 기반 방어: Geometry 값 안전성 검증 유틸리티
/// UIView_backing_setFrame 크래시 방지를 위한 공통 유틸리티
class GeometrySafety {
  /// 최대 허용 차원 (픽셀 단위)
  static const double maxDimension = 10000.0;
  
  /// 최소 허용 차원 (픽셀 단위)
  static const double minDimension = 0.0;
  
  /// double 값이 안전한지 검증
  /// - [value]: 검증할 값
  /// - [fallback]: 유효하지 않은 경우 사용할 기본값 (기본값: 0)
  /// - Returns: 유효한 값 또는 fallback
  static double safeLength(double value, {double fallback = 0.0}) {
    if (value.isNaN || value.isInfinite || value < minDimension || value > maxDimension) {
      debugPrint('[GeometrySafety] ⚠️ Invalid length detected: $value, using fallback: $fallback');
      return fallback;
    }
    return value;
  }
  
  /// Size가 안전한지 검증하고 수정된 Size 반환
  static Size safeSize(Size size, {Size? fallback}) {
    final safeWidth = safeLength(size.width, fallback: fallback?.width ?? 0.0);
    final safeHeight = safeLength(size.height, fallback: fallback?.height ?? 0.0);
    
    if (safeWidth <= 0 || safeHeight <= 0) {
      debugPrint('[GeometrySafety] ⚠️ Invalid size detected: width=${size.width}, height=${size.height}, using fallback: $fallback');
      return fallback ?? Size.zero;
    }
    
    return Size(safeWidth, safeHeight);
  }
  
  /// Aspect ratio 계산 시 0으로 나누기 방지
  static double safeAspectRatio(double width, double height, {double fallback = 1.0}) {
    final safeWidth = safeLength(width, fallback: 1.0);
    final safeHeight = safeLength(height, fallback: 1.0);
    
    if (safeHeight <= 0) {
      debugPrint('[GeometrySafety] ⚠️ Division by zero prevented: width=$width, height=$height, returning $fallback');
      return fallback;
    }
    
    final ratio = safeWidth / safeHeight;
    
    if (ratio.isNaN || ratio.isInfinite || ratio <= 0 || ratio > 100) {
      debugPrint('[GeometrySafety] ⚠️ Invalid aspect ratio: $ratio, returning $fallback');
      return fallback;
    }
    
    return ratio;
  }
}

