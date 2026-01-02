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
    final double chipHeight = SharedImagePipeline.calculateChipHeight(previewWidth);
    final double chipPadding = SharedImagePipeline.calculateChipPadding(previewWidth);
    final double chipSpacing = SharedImagePipeline.calculateChipSpacing(previewWidth);
    final double chipCornerRadius = SharedImagePipeline.calculateChipCornerRadius(chipHeight);
    final double horizontalPadding = SharedImagePipeline.calculateHorizontalPadding(previewWidth);

    // 🔥 저장 시 FramePainter와 동일: topChipY 계산
    // frameTopOffset = previewTop + topBarHeight + chipPadding * 2.0
    // topChipY = frameTopOffset + chipPadding (저장 시와 동일)
    final double topChipY = frameTopOffset + chipPadding;

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
      final double chipPaddingHorizontal = SharedImagePipeline.calculateChipPaddingHorizontal(chipHeight);
      final double iconSize = iconImage != null ? SharedImagePipeline.calculateIconSize(chipHeight) : 0;
      final double iconSpacing = iconImage != null ? SharedImagePipeline.calculateIconSpacing(chipHeight) : 0;

      // 최대 칩 너비 설정 (프리뷰 영역 너비의 70%로 제한)
      final double maxChipWidth = SharedImagePipeline.calculateMaxChipWidth(previewWidth);
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
      final double chipPaddingHorizontal = SharedImagePipeline.calculateChipPaddingHorizontal(chipHeight);
      final double iconSize = iconImage != null ? SharedImagePipeline.calculateIconSize(chipHeight) : 0;
      final double iconSpacing = iconImage != null ? SharedImagePipeline.calculateIconSpacing(chipHeight) : 0;

      // 최대 칩 너비 설정 (프리뷰 영역 너비의 70%로 제한)
      final double maxChipWidth = SharedImagePipeline.calculateMaxChipWidth(previewWidth);
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

    // 🔥 FramePreviewPainter와 동일한 구조: 상단 칩들
    double currentTopChipX = horizontalPadding;

    // 1. 반려동물 이름 칩 (아이콘 포함)
    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 2. 나이, 젠더, 종을 한 칩에 묶어서 표시 (FramePreviewPainter와 동일)
    List<String> infoParts = [];
    infoParts.add('$age살'); // 🔥 나이에 "살" 추가
    if (genderText.isNotEmpty) {
      infoParts.add(genderText); // 🔥 젠더 추가
    }
    if (breedText.isNotEmpty) {
      infoParts.add(breedText); // 🔥 종 추가
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • '); // 🔥 " • "로 구분
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    // 🔥 저장 시 FramePainter와 동일: 하단 칩 위치 계산
    // 저장 시: bottomBarHeight = canvasSize.height * (1.0 - 0.05)
    // 프리뷰 영역이 이미지 전체와 같다면, bottomBarHeight = previewHeight * (1.0 - 0.05)
    final double bottomBarHeight = previewHeight * (1.0 - 0.05);
    
    // 저장 시와 동일한 calculateBottomChipY 사용
    final double? finalBottomInfoY = SharedImagePipeline.calculateBottomChipY(
      previewHeight,
      bottomBarHeight,
      chipHeight,
      chipPadding,
    );

    // 하단 칩 위치가 유효하지 않으면 그리지 않음
    if (finalBottomInfoY == null) {
      return;
    }

    // 상단 칩 위치 확인 (하단 문구가 상단 칩 아래에만 그려지도록)
    // 저장 시와 동일한 계산: topChipBottom = (topBarHeight ?? chipPadding * 2) + chipHeight + chipPadding
    // topBarHeight = previewHeight * 0.03
    final double topBarHeight = previewHeight * 0.03;
    final double topChipBottom = topBarHeight + chipHeight + chipPadding;

    // 하단 문구가 상단 칩 영역과 겹치거나, 음수이면 그리지 않음
    if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
        finalBottomInfoY < 0) {
      return; // 하단 문구를 그리지 않음
    }

    // 🔥 하단 칩 위치를 프리뷰 영역 기준으로 변환 (전체 화면 기준으로)
    // finalBottomInfoY는 프리뷰 영역 내부 상대 위치이므로, 프리뷰 영역 top을 더해야 함
    // frameTopOffset = previewTop + topBarHeight + chipPadding * 2.0
    // 따라서 previewTop = frameTopOffset - topBarHeight - chipPadding * 2.0
    final double topBarHeightForPreview = previewHeight * 0.03;
    final double previewTop = frameTopOffset - topBarHeightForPreview - chipPadding * 2.0;
    final double screenBottomInfoY = previewTop + finalBottomInfoY;

    // 🔥 FramePreviewPainter와 동일: 촬영날짜 형식 (이모지 포함)
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
    final dateStr = '📅 ${monthNames[now.month]} ${now.day}, ${now.year}'; // 🔥 이모지 추가

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * 2.0; // 오른쪽 패딩
    final double bottomChipSpacing = chipPadding * 0.5; // 칩 간격

    // 1열: 촬영날짜 (아래쪽) - 칩 형태, 오른쪽 정렬
    final dateChipWidth = calculateChipWidth(dateStr);
    final double dateChipX = screenWidth - rightMargin - dateChipWidth; // 오른쪽 정렬
    drawChip(dateStr, dateChipX, screenBottomInfoY); // 🔥 전체 화면 기준 Y 위치 사용

    // 2열: 촬영장소 (위쪽, 위치 정보가 있을 때만) - 칩 형태, 오른쪽 정렬
    if (location != null && location!.isNotEmpty) {
      final locationText = '📍 Shot on location in $location'; // 🔥 이모지 추가
      final locationChipWidth = calculateChipWidth(locationText);
      final double locationChipX =
          screenWidth - rightMargin - locationChipWidth; // 오른쪽 정렬
      drawChip(
        locationText,
        locationChipX,
        screenBottomInfoY - chipHeight - bottomChipSpacing, // 🔥 전체 화면 기준 Y 위치 사용
      );
    }
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
