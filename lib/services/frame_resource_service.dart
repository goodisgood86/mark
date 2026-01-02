import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

