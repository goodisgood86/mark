
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS 네이티브 카메라 제어용 서비스 인터페이스
///
/// - AVFoundation 기반 네이티브 카메라와 통신한다.
/// - 실제 네이티브 구현은 iOS의 `NativeCamera` (Swift) 에서 처리한다.
abstract class NativeCameraService {
  /// 카메라 초기화
  Future<void> initialize();

  /// 카메라 리소스 해제
  Future<void> dispose();

  /// 초기화 여부
  bool get isInitialized;

  /// 연속 자동초점 활성/비활성
  Future<void> setContinuousAutoFocus(bool enabled);

  /// 특정 포인트로 포커스 이동 (0.0 ~ 1.0 normalized 좌표)
  Future<void> focusOnPoint(Offset normalizedPoint);

  /// 줌 설정
  ///
  /// [uiZoom]은 Flutter UI 기준 값 (예: 0.5 ~ 3.0)
  /// iOS 네이티브에서는 1.0 이상으로 매핑하여 실제 줌을 적용한다.
  Future<void> setZoom(double uiZoom);

  /// 플래시 모드 설정
  ///
  /// [mode]: 'off' | 'on' | 'auto'
  Future<void> setFlashMode(String mode);

  /// 일반 와이드(wide) 렌즈로 전환 (가능한 경우)
  Future<void> switchToWideIfAvailable();

  /// 초광각(ultra wide) 렌즈로 전환 (가능한 경우)
  Future<void> switchToUltraWideIfAvailable();

  /// 네이티브 카메라로 원본 사진 캡처 (HEIF/JPEG) 후 파일 경로 반환
  Future<String> captureNativePhoto();
}

/// MethodChannel 기반 iOS 네이티브 카메라 서비스 구현체
///
/// - 채널 이름: `petgram/native_camera`
/// - Swift 측 `NativeCamera` 클래스와 통신한다.
class NativeCameraServiceImpl implements NativeCameraService {
  static const MethodChannel _channel = MethodChannel('petgram/native_camera');

  bool _initialized = false;

  @override
  bool get isInitialized => _initialized;

  /// 카메라 하드웨어 존재 여부 및 초기화 가능 여부 확인
  /// - "ok": 카메라가 있고 초기화 가능
  /// - "no_camera": 카메라 하드웨어 없음 (시뮬레이터 등)
  /// - "error": 권한 거부 등 기타 오류
  Future<String> initCamera() async {
    try {
      final result = await _channel.invokeMethod<String>('initCamera');
      if (result == null) {
        return 'error';
      }
      debugPrint('[Petgram] 📷 initCamera result: $result');
      return result;
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ initCamera error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
      return 'error';
    } catch (e) {
      debugPrint('[Petgram] ❌ initCamera unexpected error: $e');
      return 'error';
    }
  }

  @override
  Future<void> initialize() async {
    try {
      await _channel.invokeMethod('initialize');
      _initialized = true;
      debugPrint('[Petgram] ✅ NativeCameraService initialized');
    } on PlatformException catch (e, s) {
      _initialized = false;
      debugPrint('[Petgram] ❌ NativeCameraService.initialize error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (!_initialized) return;
    try {
      await _channel.invokeMethod('dispose');
      _initialized = false;
      debugPrint('[Petgram] ✅ NativeCameraService disposed');
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ NativeCameraService.dispose error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<void> setContinuousAutoFocus(bool enabled) async {
    try {
      await _channel.invokeMethod('setContinuousAutoFocus', {
        'enabled': enabled,
      });
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ setContinuousAutoFocus error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<void> focusOnPoint(Offset normalizedPoint) async {
    try {
      await _channel.invokeMethod('focusOnPoint', {
        'x': normalizedPoint.dx,
        'y': normalizedPoint.dy,
      });
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ focusOnPoint error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<void> setZoom(double uiZoom) async {
    try {
      await _channel.invokeMethod('setZoom', {'uiZoom': uiZoom});
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ setZoom error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<void> setFlashMode(String mode) async {
    try {
      await _channel.invokeMethod('setFlashMode', {'mode': mode});
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ setFlashMode error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<void> switchToWideIfAvailable() async {
    try {
      await _channel.invokeMethod('switchToWideIfAvailable');
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ switchToWideIfAvailable error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<void> switchToUltraWideIfAvailable() async {
    try {
      await _channel.invokeMethod('switchToUltraWideIfAvailable');
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ switchToUltraWideIfAvailable error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
    }
  }

  @override
  Future<String> captureNativePhoto() async {
    try {
      final path = await _channel.invokeMethod<String>('captureNativePhoto');
      if (path == null || path.isEmpty) {
        throw Exception('captureNativePhoto: empty path');
      }
      debugPrint('[Petgram] 📸 Native captured file: $path');
      return path;
    } on PlatformException catch (e, s) {
      debugPrint('[Petgram] ❌ captureNativePhoto error: $e');
      debugPrint('[Petgram] ❌ stacktrace: $s');
      rethrow;
    }
  }
}
