import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/widgets.dart';

import '../models/pet_info.dart';
import 'petgram_meta_service.dart';

/// 프레임 이미지 내보내기 서비스
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
    String? location, // 촬영 위치 정보 (활성화되어 있을 경우)
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

      final ui.Image uiImage = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData = await uiImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) {
        uiImage.dispose();
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
        uiImage.dispose();
        debugPrint('❌ FrameExporter: PNG 디코딩 실패');
        return null;
      }

      // JPEG로 인코딩 (품질 100)
      final Uint8List jpegBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 100),
      );

      // 선택된 펫 정보 가져오기 (프레임 설정 시 펫 정보 포함)
      PetInfo? selectedPet;
      if (selectedPetId != null && petList.isNotEmpty) {
        try {
          selectedPet = petList.firstWhere((pet) => pet.id == selectedPetId);
        } catch (e) {
          debugPrint(
            '[FrameExporter] ⚠️ Selected pet not found: $selectedPetId',
          );
        }
      }

      // PetgramPhotoMeta 생성 및 EXIF 메타데이터 추가
      final meta = buildPetgramMeta(
        frameKey: 'default', // TODO: 실제 프레임 키로 교체
        selectedPet: selectedPet, // 프레임 설정 시 펫 정보 포함
        selectedPetId: selectedPetId, // 하위 호환성
        location: location, // 촬영 위치 정보 (활성화되어 있을 경우)
        // titleText, subtitleText, labelDateText는 프레임에서 가져올 수 있으면 추가
      );

      // 메타데이터 디버그 출력
      if (kDebugMode) {
        debugPrint('═══════════════════════════════════════════════════════');
        debugPrint('[Petgram] 📸 저장 메타데이터 정보 (FrameExporter)');
        debugPrint('───────────────────────────────────────────────────────');
        debugPrint('  isPetgramShot: ${meta.isPetgramShot}');
        debugPrint('  isPetgramEdited: ${meta.isPetgramEdited}');
        debugPrint('  frameKey: ${meta.frameKey}');
        debugPrint('  takenAt: ${meta.takenAt.toIso8601String()} (UTC)');
        debugPrint('  frameMeta:');
        meta.frameMeta.forEach((key, value) {
          debugPrint('    - $key: $value');
        });
        debugPrint('  frameMetaJson: ${meta.frameMetaJson}');
        debugPrint('  EXIF Tag: ${meta.toExifTag()}');
        debugPrint('  FileName Suffix: ${meta.toFileNameSuffix()}');
        debugPrint('═══════════════════════════════════════════════════════');
      }

      // EXIF 메타데이터 추가
      final jpegBytesWithMeta = await attachPetgramExif(
        jpegBytes: jpegBytes,
        exifTag: meta.toExifTag(),
      );

      // 임시 파일로 저장
      final dir = await getTemporaryDirectory();
      final fileNameSuffix = meta.toFileNameSuffix();
      final filePath = '${dir.path}/PG_${fileNameSuffix}.jpg';
      final File framedFile = File(filePath);
      await framedFile.writeAsBytes(jpegBytesWithMeta);

      uiImage.dispose();
      debugPrint('✅ FrameExporter: 프레임 이미지 내보내기 완료');
      return framedFile;
    } catch (e, stackTrace) {
      debugPrint('❌ FrameExporter error: $e');
      debugPrint('❌ FrameExporter stackTrace: $stackTrace');
      return null;
    }
  }
}
