import 'package:flutter/material.dart';

/// Petgram 카메라 추상 인터페이스
/// Flutter의 camera 패키지 대신 네이티브 카메라를 사용하기 위한 인터페이스
abstract class IPetgramCamera {
  /// 카메라 초기화
  /// [cameraPosition] 'back' 또는 'front'
  /// [aspectRatio] 목표 비율 (9/16, 3/4, 1.0 등)
  Future<void> initialize({
    required String cameraPosition,
    double? aspectRatio,
  });

  /// 카메라 해제
  Future<void> dispose();

  /// 초기화 상태
  bool get isInitialized;

  /// 카메라 센서 비율 (width/height)
  double? get aspectRatio;

  /// 프리뷰 크기 (센서 기준)
  Size? get previewSize;

  /// 전면/후면 카메라 전환
  /// 반환: {'aspectRatio': double, 'previewWidth': double, 'previewHeight': double, 'minZoom': double, 'maxZoom': double} 또는 null
  Future<Map<String, dynamic>?> switchCamera();

  /// 플래시 모드 설정
  /// [mode] 'off' | 'auto' | 'on' | 'torch'
  Future<void> setFlashMode(String mode);

  /// 줌 레벨 설정 (1.0 기준)
  Future<void> setZoom(double zoom);

  /// 🔥 성능 최적화: 카메라 세션 일시 중지
  Future<void> pauseSession();
  
  /// 🔥 성능 최적화: 카메라 세션 재개
  Future<void> resumeSession();

  /// 포커스 포인트 설정 (normalized 좌표 0.0~1.0)
  Future<void> setFocusPoint(Offset normalized);

  /// 노출 포인트 설정 (normalized 좌표 0.0~1.0)
  Future<void> setExposurePoint(Offset normalized);

  /// 포커스 상태 확인 (성능 최적화: 상태 변경 시에만 UI 업데이트)
  /// 반환: {'isAdjustingFocus': bool, 'focusMode': String} 또는 null
  Future<Map<String, dynamic>?> getFocusStatus();

  /// 사진 촬영
  /// 반환: 갤러리 저장된 파일명 또는 임시 파일 경로
  Future<String> takePicture({
    String? filterKey,
    double? filterIntensity,
    double? brightness,
    bool? enableFrame,
    Map<String, dynamic>? frameMeta,
    double? aspectRatio,
  });

  /// 카메라 값 변경 리스너
  void addListener(VoidCallback listener);

  /// 리스너 제거
  void removeListener(VoidCallback listener);

  /// 🔥 프리뷰 영역 문제 해결: iOS 네이티브 카메라 뷰와 Flutter 프리뷰 영역 동기화
  /// [x], [y], [width], [height]: Flutter에서 계산한 프리뷰 영역 (픽셀 단위)
  Future<void> updatePreviewLayout({
    required double x,
    required double y,
    required double width,
    required double height,
  });

  /// 시뮬레이터 여부 확인
  Future<bool> isSimulator();
}

