import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/shared_image_pipeline.dart';
import '../../models/pet_info.dart';

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

    // 🔥 공통 파이프라인 모듈 사용: 프리뷰와 저장이 동일한 위치 계산 사용
    // 테두리 제거 - 모든 정보를 칩 형태로 표시
    final double chipHeight = SharedImagePipeline.calculateChipHeight(
      size.width,
    );
    final double chipPadding = SharedImagePipeline.calculateChipPadding(
      size.width,
    );
    final double chipSpacing = SharedImagePipeline.calculateChipSpacing(
      size.width,
    );
    final double chipCornerRadius =
        SharedImagePipeline.calculateChipCornerRadius(chipHeight);
    final double horizontalPadding =
        SharedImagePipeline.calculateHorizontalPadding(size.width);

    // 상단 바로 밑 살짝 위쪽에 공간을 주기 (텍스트 위치를 살짝 아래로 이동)
    final double frameTopOffset = SharedImagePipeline.calculateFrameTopOffset(
      topBarHeight,
      chipPadding,
    );

    // 반려동물 정보
    final ui.Image? petIconImage = selectedPet.type == 'dog'
        ? dogIconImage
        : catIconImage;

    // 나이, 종 정보 (간결 표기)
    final age = selectedPet.getAge();
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
    // 🔥 공통 파이프라인 모듈 사용
    double calculateChipWidth(String text, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal =
          SharedImagePipeline.calculateChipPaddingHorizontal(chipHeight);
      final double iconSize = iconImage != null
          ? SharedImagePipeline.calculateIconSize(chipHeight)
          : 0;
      final double iconSpacing = iconImage != null
          ? SharedImagePipeline.calculateIconSpacing(chipHeight)
          : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = SharedImagePipeline.calculateMaxChipWidth(
        size.width,
      );
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = SharedImagePipeline.calculateChipFontSize(chipHeight);
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w500,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(242, 255, 255, 255),
          fontWeight: ui.FontWeight.w500,
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
    // 🔥 공통 파이프라인 모듈 사용
    double drawChip(
      String text,
      double x,
      double y, {
      ui.Image? iconImage,
      bool isMeta = false,
    }) {
      final double chipPaddingHorizontal =
          SharedImagePipeline.calculateChipPaddingHorizontal(chipHeight);
      final double iconSize = iconImage != null
          ? SharedImagePipeline.calculateIconSize(chipHeight)
          : 0;
      final double iconSpacing = iconImage != null
          ? SharedImagePipeline.calculateIconSpacing(chipHeight)
          : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = SharedImagePipeline.calculateMaxChipWidth(
        size.width,
      );
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = SharedImagePipeline.calculateChipFontSize(chipHeight);
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w500,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(242, 255, 255, 255),
          fontWeight: ui.FontWeight.w500,
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

      // 칩 배경 그리기 (톤 다운한 소프트 스타일)
      final chipRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, chipWidth, chipHeight),
        Radius.circular(chipCornerRadius),
      );

      // 얇은 그림자
      final shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y + 1.0, chipWidth, chipHeight),
          Radius.circular(chipCornerRadius),
        ),
        shadowPaint,
      );

      // 배경
      final chipBgPaint = Paint()..style = PaintingStyle.fill;
      if (isMeta) {
        chipBgPaint.color = Colors.black.withValues(alpha: 0.26);
      } else {
        chipBgPaint.color = Colors.black.withValues(alpha: 0.32);
      }
      canvas.drawRRect(chipRect, chipBgPaint);

      // 테두리
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: isMeta ? 0.18 : 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
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
    // 🔥 공통 파이프라인 모듈 사용
    final double previewRatio = size.height > 0
        ? (size.width / size.height)
        : (9 / 16);
    final bool isSquareRatio = previewRatio >= 0.95;
    final bool isTallRatio = previewRatio <= 0.62;
    final double topInsetAdjust = isSquareRatio
        ? chipPadding * 0.35
        : (isTallRatio ? chipPadding * 0.12 : chipPadding * 0.2);
    double currentTopChipX =
        horizontalPadding + (isSquareRatio ? chipPadding * 0.2 : 0);
    final double topChipY =
        SharedImagePipeline.calculateTopChipY(frameTopOffset, chipPadding) +
        topInsetAdjust;

    // 이름 칩
    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 정보 칩 (나이, 종)
    List<String> infoParts = [];
    infoParts.add('$age살');
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • ');
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    // 프리뷰와 동일한 하단 칩 Y 계산식을 사용해 저장 결과와 위치를 일치시킨다.
    final double? finalBottomInfoY =
        SharedImagePipeline.calculateBottomChipYForPreview(
          size.height,
          chipHeight,
          chipPadding,
        );

    // 하단 칩 위치가 유효하지 않으면 그리지 않음
    if (finalBottomInfoY == null) {
      return;
    }

    // 상단 칩 위치 확인 (하단 문구가 상단 칩 아래에만 그려지도록)
    final double topChipBottom =
        (topBarHeight ?? chipPadding * 2) + chipHeight + chipPadding;

    // 하단 문구가 상단 칩 영역과 겹치거나, 음수이면 그리지 않음
    if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
        finalBottomInfoY < 0) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ 하단 칩 그리기 전 최종 체크 실패: finalBottomInfoY=$finalBottomInfoY, topChipBottom=$topChipBottom, size.height=${size.height}, 그리지 않음',
        );
      }
      // 🔥 하단 칩을 그리지 않아도 상단 칩은 이미 그려졌으므로 return하지 않음
      //    대신 하단 칩만 스킵하고 상단 칩은 유지
      return; // 하단 칩을 그리지 않음
    }

    final now = DateTime.now();
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * (isSquareRatio ? 2.5 : 2.0);
    final String locationText = (location ?? '').trim();
    final String oneLineMeta = locationText.isNotEmpty
        ? '$locationText · $dateStr'
        : dateStr;

    final oneLineChipWidth = calculateChipWidth(oneLineMeta);
    final double oneLineChipX = (size.width - rightMargin - oneLineChipWidth)
        .clamp(chipPadding, size.width - oneLineChipWidth - chipPadding);
    if (oneLineChipX + oneLineChipWidth <= size.width) {
      drawChip(oneLineMeta, oneLineChipX, finalBottomInfoY, isMeta: true);
    } else if (kDebugMode) {
      debugPrint(
        '[Petgram] ⚠️ 한 줄 메타 칩 X 좌표가 유효하지 않음: oneLineChipX=$oneLineChipX, oneLineChipWidth=$oneLineChipWidth, size.width=${size.width}',
      );
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

    // 🔥 위치 정보 변경도 감지하도록 추가
    final locationChanged = oldDelegate.location != location;
    if (locationChanged && kDebugMode) {
      debugPrint(
        '[Petgram] 🖼️ FramePainter shouldRepaint: location changed from "${oldDelegate.location}" to "$location"',
      );
    }

    final shouldRepaint =
        oldDelegate.selectedPetId != selectedPetId ||
        oldDelegate.petList.length != petList.length ||
        oldDelegate.width != width ||
        oldDelegate.height != height ||
        oldDelegate.topBarHeight != topBarHeight ||
        oldDelegate.bottomBarHeight != bottomBarHeight ||
        (oldPet?.framePattern != newPet?.framePattern) ||
        (oldPet?.gender != newPet?.gender) ||
        (oldPet?.breed != newPet?.breed) ||
        locationChanged; // 🔥 위치 정보 변경 감지

    if (shouldRepaint && kDebugMode) {
      debugPrint(
        '[Petgram] 🖼️ FramePainter shouldRepaint: true (location=$location, oldLocation=${oldDelegate.location})',
      );
    }

    return shouldRepaint;
  }
}
