import 'dart:math' as math;

import 'package:flutter/material.dart';

/// BoxFit.cover 기반 카메라 좌표 매핑 유틸리티
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
      return const Offset(-1, -1); // Invalid tap
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


