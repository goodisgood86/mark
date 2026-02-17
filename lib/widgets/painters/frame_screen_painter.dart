import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../core/shared_image_pipeline.dart';
import '../../models/pet_info.dart';

/// 프레임 화면 Painter (전체 화면 기준 고정 배치)
/// preview rect와 완전히 분리하여 전체 화면 Stack 기준으로 프레임 칩을 그림
/// 🔥 FramePreviewPainter와 동일한 로직 사용하여 저장 시와 동일한 위치에 그리기
class FrameScreenPainter extends CustomPainter {
  final List<PetInfo> petList;
  final String? selectedPetId;
  final ui.Image? dogIconImage;
  final ui.Image? catIconImage;
  final String? location; // 위치 정보
  final double screenWidth; // 전체 화면 너비
  final double screenHeight; // 전체 화면 높이
  final double frameTopOffset; // 프레임 칩 시작 위치 (화면 기준 top offset)
  final double previewWidth; // 프리뷰 영역 너비 (칩 크기 계산용)
  final double previewHeight; // 프리뷰 영역 높이 (하단 칩 위치 계산용)
  final bool showDebugInfo; // 🔥 추가

  FrameScreenPainter({
    required this.petList,
    required this.selectedPetId,
    this.dogIconImage,
    this.catIconImage,
    this.location,
    required this.screenWidth,
    required this.screenHeight,
    required this.frameTopOffset,
    required this.previewWidth,
    required this.previewHeight,
    this.showDebugInfo = false, // 🔥 기본값 false
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

    // 🔥 FramePreviewPainter와 동일한 계산 사용
    // 프리뷰 영역 너비를 기준으로 계산 (저장 시와 동일)
    final double chipHeight = SharedImagePipeline.calculateChipHeight(
      previewWidth,
    );
    final double chipPadding = SharedImagePipeline.calculateChipPadding(
      previewWidth,
    );
    final double chipSpacing = SharedImagePipeline.calculateChipSpacing(
      previewWidth,
    );
    final double chipCornerRadius =
        SharedImagePipeline.calculateChipCornerRadius(chipHeight);
    final double horizontalPadding =
        SharedImagePipeline.calculateHorizontalPadding(previewWidth);

    // 🔥 저장 시 FramePainter와 동일: topChipY 계산
    // frameTopOffset = previewTop + topBarHeight + chipPadding * 2.0
    // topChipY = frameTopOffset + chipPadding (저장 시와 동일)
    final double previewRatio = previewHeight > 0
        ? (previewWidth / previewHeight)
        : (9 / 16);
    final bool isSquareRatio = previewRatio >= 0.95;
    final bool isTallRatio = previewRatio <= 0.62;
    final double topInsetAdjust = isSquareRatio
        ? chipPadding * 0.35
        : (isTallRatio ? chipPadding * 0.12 : chipPadding * 0.2);
    final double topChipY = frameTopOffset + chipPadding + topInsetAdjust;

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

    String truncateText(String text, int maxLength) {
      if (text.length <= maxLength) return text;
      return '${text.substring(0, maxLength)}...';
    }

    // 칩 너비 계산 헬퍼 함수 (그리지 않고 너비만 계산)
    double calculateChipWidth(String text, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal =
          SharedImagePipeline.calculateChipPaddingHorizontal(chipHeight);
      final double iconSize = iconImage != null
          ? SharedImagePipeline.calculateIconSize(chipHeight)
          : 0;
      final double iconSpacing = iconImage != null
          ? SharedImagePipeline.calculateIconSpacing(chipHeight)
          : 0;

      // 최대 칩 너비 설정 (프리뷰 영역 너비의 70%로 제한)
      final double maxChipWidth = SharedImagePipeline.calculateMaxChipWidth(
        previewWidth,
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

      // 최대 칩 너비 설정 (프리뷰 영역 너비의 70%로 제한)
      final double maxChipWidth = SharedImagePipeline.calculateMaxChipWidth(
        previewWidth,
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

      // 칩 배경 (톤 다운한 소프트 스타일)
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

    // 🔥 FramePreviewPainter와 동일한 구조: 상단 칩들
    double currentTopChipX =
        horizontalPadding + (isSquareRatio ? chipPadding * 0.2 : 0);

    // 1. 반려동물 이름 칩 (아이콘 포함)
    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 2. 정보 칩 (나이, 종)
    List<String> infoParts = [];
    infoParts.add('$age살');
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • '); // 🔥 " • "로 구분
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    final double? finalBottomInfoY =
        SharedImagePipeline.calculateBottomChipYForPreview(
          previewHeight,
          chipHeight,
          chipPadding,
        );
    if (finalBottomInfoY == null) return;

    final double topChipBottom = topChipY + chipHeight + chipPadding;
    if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
        finalBottomInfoY < 0) {
      return;
    }

    // 촬영날짜 형식 (간결화)
    final now = DateTime.now();
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * (isSquareRatio ? 2.5 : 2.0);
    final String locationText = (location ?? '').trim();
    final String metaOneLine = locationText.isNotEmpty
        ? '$locationText · $dateStr'
        : dateStr;

    // 위치/날짜를 하단 한 줄로 통합 표시
    final oneLineChipWidth = calculateChipWidth(metaOneLine);
    final double oneLineChipX = (screenWidth - rightMargin - oneLineChipWidth)
        .clamp(chipPadding, screenWidth - oneLineChipWidth - chipPadding);
    drawChip(metaOneLine, oneLineChipX, finalBottomInfoY, isMeta: true);
  }

  @override
  bool shouldRepaint(FrameScreenPainter oldDelegate) {
    return petList != oldDelegate.petList ||
        selectedPetId != oldDelegate.selectedPetId ||
        dogIconImage != oldDelegate.dogIconImage ||
        catIconImage != oldDelegate.catIconImage ||
        location != oldDelegate.location ||
        screenWidth != oldDelegate.screenWidth ||
        screenHeight != oldDelegate.screenHeight ||
        frameTopOffset != oldDelegate.frameTopOffset ||
        previewWidth != oldDelegate.previewWidth ||
        previewHeight != oldDelegate.previewHeight;
  }
}
