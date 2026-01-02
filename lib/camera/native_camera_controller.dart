import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'native_camera_interface.dart';

/// 네이티브 카메라 컨트롤러 (MethodChannel 기반)
///
/// 🔄 리팩토링: iOS에서는 더 이상 viewId가 필요 없습니다.
/// 카메라는 RootViewController의 cameraContainer에 직접 표시되므로
/// PlatformView를 사용하지 않습니다.
class NativeCameraController implements IPetgramCamera {
  static const MethodChannel _channel = MethodChannel('petgram/native_camera');

  bool _isInitialized = false;
  double? _aspectRatio;
  Size? _previewSize;
  String _cameraPosition = 'back';
  int? _viewId; // PlatformView ID (Android에서만 사용)
  final List<VoidCallback> _listeners = [];
  final List<Function(String)> _debugLogListeners = [];

  /// 🔄 리팩토링: iOS에서는 viewId가 필요 없지만, Android 호환성을 위해 유지
  void setViewId(int viewId) {
    _viewId = viewId;
  }

  /// PlatformView ID 가져오기 (디버깅용)
  int? get viewId => _viewId;

  /// 🔄 리팩토링: iOS에서는 viewId가 필요 없음
  bool get _isIOS => Platform.isIOS;

  /// 🔥 Single Source of Truth: MethodChannel arguments 생성 헬퍼
  /// iOS에서도 viewId를 항상 포함하여 네이티브에서 올바른 controller를 찾을 수 있도록 함
  /// ⚠️ 중요: _viewId가 null이거나 -1이어도, 0 이상의 유효한 값이면 전달해야 함
  Map<String, dynamic> _createArguments([Map<String, dynamic>? additional]) {
    final args = <String, dynamic>{...?additional};
    // 🔥 iOS에서도 viewId를 항상 포함 (NativeCameraRegistry를 통해 controller 찾기)
    // ⚠️ 핵심 수정: _viewId가 null이거나 -1이어도, 0 이상의 유효한 값이면 전달
    //    이렇게 하지 않으면 네이티브에서 requestedViewId가 nil이 되어 effectiveViewId가 -1이 됨
    if (_viewId != null && _viewId! >= 0) {
      args['viewId'] = _viewId;
    } else {
      // _viewId가 null이거나 -1이면, 기본값 0을 전달 (iOS에서는 첫 번째 PlatformView ID가 0)
      // 이렇게 하면 네이티브에서 최소한 0을 받아서 처리할 수 있음
      args['viewId'] = 0;
    }
    return args;
  }

  @override
  bool get isInitialized => _isInitialized;

  @override
  double? get aspectRatio => _aspectRatio;

  @override
  Size? get previewSize => _previewSize;

  NativeCameraController() {
    // 네이티브에서 카메라 상태 변경 알림을 받기 위한 리스너
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  /// 내부 디버그 로그 헬퍼: 콘솔 + Flutter 디버그 오버레이로 동시에 전달
  void _emitDebugLog(String message) {
    debugPrint(message);
    for (final listener in _debugLogListeners) {
      try {
        listener(message);
      } catch (_) {
        // 리스너 쪽 에러는 무시 (로그 흐름만 위한 것이므로)
      }
    }
  }

  /// 네이티브에서 호출되는 메서드 처리
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCameraInitialized':
        _isInitialized = call.arguments['isInitialized'] as bool? ?? false;
        _aspectRatio = (call.arguments['aspectRatio'] as num?)?.toDouble();
        final width = (call.arguments['previewWidth'] as num?)?.toDouble();
        final height = (call.arguments['previewHeight'] as num?)?.toDouble();
        if (width != null && height != null) {
          _previewSize = Size(width, height);
        }
        _notifyListeners();
        break;
      case 'onCameraError':
        debugPrint('[Petgram] ❌ Native camera error: ${call.arguments}');
        _isInitialized = false;
        _notifyListeners();
        break;
      case 'onDebugLog':
        // 네이티브에서 보낸 디버그 로그를 처리
        final message = call.arguments['message'] as String?;
        if (message != null) {
          // 콜백으로 전달 (home_page에서 처리)
          for (final listener in _debugLogListeners) {
            listener(message);
          }
        }
        break;
      default:
        debugPrint('[Petgram] ⚠️ Unknown method call: ${call.method}');
    }
  }

  /// 디버그 로그 리스너 추가
  void addDebugLogListener(Function(String) listener) {
    _debugLogListeners.add(listener);
  }

  /// 디버그 로그 리스너 제거
  void removeDebugLogListener(Function(String) listener) {
    _debugLogListeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// 네이티브에 initializeNativeCamera 호출 (viewId와 position 전달)
  Future<void> initializeNativeCamera({
    required int viewId,
    required String cameraPosition,
  }) async {
    try {
      debugPrint(
        '[Petgram] 📷 Native camera initializeNativeCamera: viewId=$viewId, position=$cameraPosition',
      );

      final arguments = <String, dynamic>{
        'viewId': viewId,
        'cameraPosition': cameraPosition,
      };

      await _channel.invokeMethod('initializeNativeCamera', arguments);
    } catch (e) {
      debugPrint('[Petgram] ❌ initializeNativeCamera failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> initialize({
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    try {
      _cameraPosition = cameraPosition;
      debugPrint(
        '[Petgram] 📷 Native camera initialize: position=$cameraPosition, aspectRatio=$aspectRatio, viewId=$_viewId, isIOS=$_isIOS',
      );

      // 🔥 Pattern A 보장: viewId 검증
      // iOS에서는 viewId를 사용하지 않지만, Android에서는 필수
      // viewId가 null이거나 -1 이하인 경우는 프로그래밍 버그
      if (!_isIOS) {
        if (_viewId == null || _viewId! < 0) {
          throw Exception(
            'ViewId not set or invalid (viewId=$_viewId). Call setViewId() with a valid viewId (>= 0) after creating NativeCameraPreview.',
          );
        }
      } else {
        // iOS에서는 viewId를 사용하지 않지만, 로깅용으로 확인
        if (kDebugMode && (_viewId == null || _viewId! < 0)) {
          debugPrint(
            '[Petgram] ⚠️ iOS: viewId=$_viewId is invalid, but iOS does not require viewId. This may indicate a programming error.',
          );
        }
      }

      // 🔄 리팩토링: iOS에서는 viewId를 전달하지 않음
      final arguments = _createArguments({
        'cameraPosition': cameraPosition,
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
      });

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'initialize',
        arguments,
      );

      if (result != null) {
        _isInitialized = result['isInitialized'] as bool? ?? false;
        _aspectRatio = (result['aspectRatio'] as num?)?.toDouble();
        final width = (result['previewWidth'] as num?)?.toDouble();
        final height = (result['previewHeight'] as num?)?.toDouble();
        if (width != null && height != null) {
          _previewSize = Size(width, height);
        }

        debugPrint(
          '[Petgram] ✅ Native camera initialize result: '
          'isInitialized=$_isInitialized, aspectRatio=$_aspectRatio, '
          'previewSize=$_previewSize, result=$result',
        );

        // ⚠️ 중요: 실기기에서 isInitialized가 false로 반환되는 경우
        //          네이티브에서 카메라를 찾지 못했거나 권한이 없는 경우일 수 있음
        if (!_isInitialized) {
          throw Exception(
            'Native camera initialize() returned isInitialized=false. '
            'This may indicate camera hardware not found or permission denied. '
            'Result: $result',
          );
        }
      } else {
        throw Exception('Native camera initialize() returned null result');
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ Native camera initialize error: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  /// 🔥 프리뷰 영역 문제 해결: iOS 네이티브 카메라 뷰와 Flutter 프리뷰 영역 동기화
  @override
  Future<void> updatePreviewLayout({
    required double x,
    required double y,
    required double width,
    required double height,
  }) async {
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🔍 NativeCameraController.updatePreviewLayout: ENTRY - x=$x, y=$y, width=$width, height=$height, _isIOS=$_isIOS',
      );
    }
    if (!_isIOS) {
      // Android는 필요 없음
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ NativeCameraController.updatePreviewLayout: Not iOS, returning',
        );
      }
      return;
    }

    try {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 📐 NativeCameraController.updatePreviewLayout: Calling _channel.invokeMethod',
        );
      }
      await _channel.invokeMethod(
        'updatePreviewLayout',
        _createArguments({'x': x, 'y': y, 'width': width, 'height': height}),
      );
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ✅ NativeCameraController.updatePreviewLayout: Method call succeeded - x=$x, y=$y, width=$width, height=$height',
        );
      }
    } catch (e) {
      debugPrint(
        '[Petgram] ❌ NativeCameraController.updatePreviewLayout failed: $e',
      );
      debugPrint('[Petgram] ❌ Stack trace: ${StackTrace.current}');
    }
  }

  @override
  Future<void> dispose() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (_isIOS) {
        await _channel.invokeMethod('dispose', {});
      } else if (_viewId != null) {
        await _channel.invokeMethod('dispose', {'viewId': _viewId});
      }
      _isInitialized = false;
      _aspectRatio = null;
      _previewSize = null;
      _viewId = null;
      _listeners.clear();
      debugPrint('[Petgram] ✅ Native camera disposed');
    } catch (e) {
      debugPrint('[Petgram] ❌ Native camera dispose error: $e');
    }
  }

  @override
  Future<void> switchCamera() async {
    try {
      final from = _cameraPosition;
      _cameraPosition = _cameraPosition == 'back' ? 'front' : 'back';
      if (kDebugMode) {
        _emitDebugLog(
          '[Camera] switchCamera start: from=$from, to=$_cameraPosition, viewId=$_viewId',
        );
      }

      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) {
        throw Exception('ViewId not set');
      }

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'switchCamera',
        _createArguments({'cameraPosition': _cameraPosition}),
      );

      if (result != null) {
        _aspectRatio = (result['aspectRatio'] as num?)?.toDouble();
        final width = (result['previewWidth'] as num?)?.toDouble();
        final height = (result['previewHeight'] as num?)?.toDouble();
        if (width != null && height != null) {
          _previewSize = Size(width, height);
        }
        _notifyListeners();

        if (kDebugMode) {
          final sessionRunning = result['sessionRunning'];
          final devicePosition = result['devicePosition'];
          final deviceType = result['deviceType'];
          _emitDebugLog(
            '[Camera] switchCamera success: direction=$_cameraPosition, '
            'sessionRunning=$sessionRunning, devicePosition=$devicePosition, deviceType=$deviceType, '
            'previewSize=$_previewSize, aspectRatio=$_aspectRatio',
          );
        }
      } else {
        if (kDebugMode) {
          _emitDebugLog(
            '[Camera] switchCamera completed with null result (direction=$_cameraPosition)',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        _emitDebugLog('[Camera] switchCamera error: $e');
      }
      rethrow;
    }
  }

  @override
  Future<void> setFlashMode(String mode) async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod(
        'setFlashMode',
        _createArguments({'mode': mode}),
      );
      debugPrint('[Petgram] 📷 Flash mode set to: $mode');
    } catch (e) {
      debugPrint('[Petgram] ❌ Set flash mode error: $e');
      // 플래시 모드 설정 실패는 치명적이지 않으므로 예외를 다시 던지지 않음
    }
  }

  /// 포커스 상태 확인 (성능 최적화: 상태 변경 시에만 UI 업데이트)
  @override
  Future<Map<String, dynamic>?> getFocusStatus() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if ((!_isIOS && _viewId == null) || !_isInitialized) return null;
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getFocusStatus',
        _createArguments(),
      );
      if (result != null) {
        return {
          'isAdjustingFocus': result['isAdjustingFocus'] as bool? ?? false,
          'focusMode': result['focusMode'] as String? ?? 'unknown',
          'focusStatus':
              result['focusStatus'] as String? ?? 'unknown', // 추가: 세분화된 상태
        };
      }
      return null;
    } catch (e) {
      debugPrint('[Petgram] ⚠️ Get focus status error: $e');
      return null;
    }
  }

  @override
  Future<void> setZoom(double zoom) async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod('setZoom', _createArguments({'zoom': zoom}));
    } catch (e) {
      debugPrint('[Petgram] ❌ Set zoom error: $e');
    }
  }

  @override
  Future<void> setFocusPoint(Offset normalized) async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod(
        'setFocusPoint',
        _createArguments({'x': normalized.dx, 'y': normalized.dy}),
      );
      debugPrint(
        '[Petgram] 🎯 Focus point set: (${normalized.dx.toStringAsFixed(3)}, ${normalized.dy.toStringAsFixed(3)})',
      );
    } catch (e) {
      debugPrint('[Petgram] ❌ Set focus point error: $e');
    }
  }

  @override
  Future<void> setExposurePoint(Offset normalized) async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod(
        'setExposurePoint',
        _createArguments({'x': normalized.dx, 'y': normalized.dy}),
      );
      debugPrint(
        '[Petgram] ☀️ Exposure point set: (${normalized.dx.toStringAsFixed(3)}, ${normalized.dy.toStringAsFixed(3)})',
      );
    } catch (e) {
      debugPrint('[Petgram] ❌ Set exposure point error: $e');
    }
  }

  @override
  Future<String> takePicture({
    String? filterKey,
    double? filterIntensity,
    double? brightness,
    bool? enableFrame,
    Map<String, dynamic>? frameMeta,
    double? aspectRatio,
  }) async {
    // 🔥 크래시 디버깅: takePicture 진입 로그
    final controllerStartTime = DateTime.now();
    final controllerDebugInfo = StringBuffer()
      ..write('[NativeCameraController] 📸 takePicture ENTRY: ')
      ..write('time=${controllerStartTime.toIso8601String()}, ')
      ..write('isIOS=$_isIOS, ')
      ..write('viewId=$_viewId, ')
      ..write('isInitialized=$_isInitialized, ')
      ..write('filterKey=$filterKey, ')
      ..write('filterIntensity=$filterIntensity, ')
      ..write('brightness=$brightness, ')
      ..write('enableFrame=$enableFrame, ')
      ..write('aspectRatio=$aspectRatio, ')
      ..write('frameMetaSize=${frameMeta?.length ?? 0}');

    if (kDebugMode) {
      debugPrint(controllerDebugInfo.toString());
    }
    _emitDebugLog(controllerDebugInfo.toString());

    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) {
        final error = 'ViewId not set';
        _emitDebugLog('[NativeCameraController] ❌ $error');
        throw Exception(error);
      }

      // 🔥 크래시 디버깅: MethodChannel 호출 전 로그
      final methodCallArgs = _createArguments({
        if (filterKey != null) 'filterKey': filterKey,
        if (filterIntensity != null) 'filterIntensity': filterIntensity,
        if (brightness != null) 'brightness': brightness,
        if (enableFrame != null) 'enableFrame': enableFrame,
        if (frameMeta != null) 'frameMeta': frameMeta,
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
      });

      _emitDebugLog(
        '[NativeCameraController] 📸 Calling _channel.invokeMethod("capture") with args: ${methodCallArgs.keys.toList()}',
      );

      final invokeStartTime = DateTime.now();
      final result = await _channel.invokeMethod<String>(
        'capture',
        methodCallArgs,
      );
      final invokeEndTime = DateTime.now();
      final invokeDuration = invokeEndTime.difference(invokeStartTime);

      if (result == null) {
        final error = 'Take picture returned null';
        _emitDebugLog(
          '[NativeCameraController] ❌ $error (invokeDuration=${invokeDuration.inMilliseconds}ms)',
        );
        throw Exception(error);
      }

      // 🔥 크래시 디버깅: 촬영 성공 로그
      final controllerEndTime = DateTime.now();
      final controllerDuration = controllerEndTime.difference(
        controllerStartTime,
      );
      final successLog =
          '[NativeCameraController] ✅ takePicture SUCCESS: duration=${controllerDuration.inMilliseconds}ms, invokeDuration=${invokeDuration.inMilliseconds}ms, result=$result';
      if (kDebugMode) {
        debugPrint(successLog);
      }
      _emitDebugLog(successLog);

      return result;
    } catch (e, stackTrace) {
      // 🔥 크래시 디버깅: 촬영 실패 상세 로그
      final controllerEndTime = DateTime.now();
      final controllerDuration = controllerEndTime.difference(
        controllerStartTime,
      );
      final errorLog = StringBuffer()
        ..write('[NativeCameraController] ❌ takePicture FAILED: ')
        ..write('duration=${controllerDuration.inMilliseconds}ms, ')
        ..write('error=$e, ')
        ..write('errorType=${e.runtimeType}');

      if (kDebugMode) {
        debugPrint(errorLog.toString());
        debugPrint('[NativeCameraController] ❌ Stack trace: $stackTrace');
      }
      _emitDebugLog(errorLog.toString());
      _emitDebugLog(
        '[NativeCameraController] ❌ Stack: ${stackTrace.toString().substring(0, stackTrace.toString().length > 500 ? 500 : stackTrace.toString().length)}',
      );

      rethrow;
    }
  }

  /// 후면 카메라에서 wide 렌즈로 강제 전환 (지원 기기 한정)
  Future<Map<String, dynamic>?> switchToWideIfAvailable() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return null;
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'switchToWideIfAvailable',
        _createArguments(),
      );
      if (result == null) return null;
      return result.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      debugPrint('[Petgram] ❌ Native switchToWideIfAvailable error: $e');
      return null;
    }
  }

  /// 후면 카메라에서 ultra wide 렌즈로 강제 전환 (지원 기기 한정)
  Future<Map<String, dynamic>?> switchToUltraWideIfAvailable() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return null;
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'switchToUltraWideIfAvailable',
        _createArguments(),
      );
      if (result == null) return null;
      return result.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      debugPrint('[Petgram] ❌ Native switchToUltraWideIfAvailable error: $e');
      return null;
    }
  }

  /// iOS 네이티브 카메라 노출(밝기) 제어
  /// - [normalized]: -1.0 ~ +1.0 범위값 (네이티브에서 min~max bias로 매핑)
  Future<void> setExposureBias(double normalized) async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod(
        'setExposureBias',
        _createArguments({'value': normalized}),
      );
      debugPrint(
        '[Petgram] ☀️ Native setExposureBias: value=${normalized.toStringAsFixed(3)}',
      );
    } catch (e) {
      debugPrint('[Petgram] ❌ Native setExposureBias error: $e');
    }
  }

  /// 라이브 필터 상태를 네이티브 카메라에 전달
  /// - [filterKey]: Flutter `allFilters` 의 key 그대로 사용 (예: 'basic_soft')
  /// - [intensity]: 0.0 ~ 1.0
  Future<void> setFilter({
    required String filterKey,
    required double intensity,
  }) async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod(
        'setFilter',
        _createArguments({'filterKey': filterKey, 'intensity': intensity}),
      );
      debugPrint(
        '[Petgram] 🎨 Native setFilter: key=$filterKey, intensity=$intensity',
      );
    } catch (e) {
      debugPrint('[Petgram] ❌ Native setFilter error: $e');
    }
  }

  @override
  void addListener(VoidCallback listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// 디버그용: iOS 네이티브 카메라 세션 상태 조회
  /// - sessionRunning: AVCaptureSession.isRunning
  /// - videoConnected: 현재 디바이스가 isConnected 인지
  /// - connectionEnabled: previewLayer.connection?.isEnabled
  /// - viewBounds / previewFrame: 네이티브 프리뷰 뷰와 레이어의 frame 문자열
  /// - previewLayerHasSession: 프리뷰 레이어에 세션이 실제로 연결되어 있는지
  Future<Map<String, dynamic>> getDebugState() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) {
        debugPrint('[Petgram] ⚠️ getDebugState: viewId is null');
        return {
          'sessionRunning': false,
          'videoConnected': false,
          'connectionEnabled': false,
          'viewBounds': '',
          'previewFrame': '',
          'previewLayerHasSession': false,
        };
      }
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getDebugState',
        _createArguments(),
      );
      if (result == null) {
        debugPrint(
          '[Petgram] ⚠️ getDebugState: result is null${!_isIOS ? " for viewId=$_viewId" : ""}',
        );
        return {
          // 🔥 진짜 근본 원인 해결: null 반환 시에도 viewId와 instancePtr 포함
          'viewId': 0, // 기본값 0 (네이티브에서 이미 >= 0 보장)
          'instancePtr': '0x0', // 기본값 더미 포인터
          'sessionRunning': false,
          'videoConnected': false,
          'connectionEnabled': false,
          'viewBounds': '',
          'previewFrame': '',
          'previewLayerHasSession': false,
          'hasFirstFrame': false,
          'isPinkFallback': false,
        };
      }
      // 🔥 진짜 근본 원인 해결: viewId와 instancePtr을 반환값에 포함
      // 네이티브에서 이미 viewId >= 0과 instancePtr이 비어있지 않도록 보장했으므로,
      // Dart에서도 이를 파싱하여 CameraDebugState.fromMap()에서 사용할 수 있도록 함
      final nativeViewId = result['viewId'] as num?;
      final nativeInstancePtr = result['instancePtr'] as String?;

      return {
        // 🔥 Single Source of Truth: viewId와 instancePtr을 최우선으로 포함
        'viewId': nativeViewId?.toInt() ?? 0, // 네이티브에서 이미 >= 0 보장, 없으면 0
        'instancePtr':
            nativeInstancePtr ?? '0x0', // 네이티브에서 이미 비어있지 않음 보장, 없으면 더미 값
        'sessionRunning': result['sessionRunning'] as bool? ?? false,
        'videoConnected': result['videoConnected'] as bool? ?? false,
        'connectionEnabled': result['connectionEnabled'] as bool? ?? false,
        'viewBounds': result['viewBounds'] as String? ?? '',
        'previewFrame': result['previewFrame'] as String? ?? '',
        'previewLayerHasSession':
            result['previewLayerHasSession'] as bool? ?? false,
        // 네이티브 파이프라인 디버그 정보 추가
        'previewFrameCount': result['previewFrameCount'] as int?,
        'displayCallCount': result['displayCallCount'] as int?,
        'hasCurrentImage': result['hasCurrentImage'] as bool?,
        'previewViewSize': result['previewViewSize'] as String?,
        'hasValidSize': result['hasValidSize'] as bool?,
        'drawableSize': result['drawableSize'] as String?,
        'sampleBufferCount': result['sampleBufferCount'] as int?,
        'drawCallCount': result['drawCallCount'] as int?,
        'renderSuccessCount': result['renderSuccessCount'] as int?,
        'drawNoImageCount': result['drawNoImageCount'] as int?,
        'drawInvalidSizeCount': result['drawInvalidSizeCount'] as int?,
        'hasFirstFrame': result['hasFirstFrame'] as bool? ?? false,
        'isPinkFallback': result['isPinkFallback'] as bool? ?? false,
        // 🔥 AVFoundation 크래시 방지: photoOutput connection 정보 추가
        'photoOutputIsNil': result['photoOutputIsNil'] as bool?,
        'photoOutputConnectionCount':
            result['photoOutputConnectionCount'] as int?,
        'photoOutputVideoConnectionCount':
            result['photoOutputVideoConnectionCount'] as int?,
        'photoOutputHasActiveVideoConnection':
            result['photoOutputHasActiveVideoConnection'] as bool?,
        // 인스턴스 동일성 확인용 포인터 (네이티브에서 문자열로 전달)
        'debugCaptureInstancePtr':
            result['debugCaptureInstancePtr'] as String? ?? 'nil',
        'debugGetStateInstancePtr':
            result['debugGetStateInstancePtr'] as String? ?? 'nil',
      };
    } catch (e) {
      // 🔥 viewId 불일치 에러를 명확하게 로깅
      if (e is PlatformException && e.code == 'NO_CAMERA_VIEW') {
        debugPrint(
          '[Petgram] ❌ getDebugState: NO_CAMERA_VIEW error for viewId=$_viewId',
        );
        debugPrint('[Petgram] ❌ Error details: ${e.message}');
        debugPrint('[Petgram] ❌ This indicates a viewId mismatch bug!');
      } else {
        debugPrint('[Petgram] ❌ Native getDebugState error: $e');
      }
      return {
        // 🔥 진짜 근본 원인 해결: 에러 시에도 viewId와 instancePtr 포함
        'viewId': 0, // 기본값 0 (네이티브에서 이미 >= 0 보장)
        'instancePtr': '0x0', // 기본값 더미 포인터
        'sessionRunning': false,
        'videoConnected': false,
        'connectionEnabled': false,
        'viewBounds': '',
        'previewFrame': '',
        'previewLayerHasSession': false,
        'hasFirstFrame': false,
        'isPinkFallback': false,
      };
    }
  }

  @override
  Future<bool> isSimulator() async {
    try {
      final result = await _channel.invokeMethod<bool>('isSimulator', {});
      return result ?? false;
    } catch (e) {
      debugPrint('[Petgram] ❌ isSimulator error: $e');
      return false;
    }
  }

  /// 🔥 FSM 명령: 필요시 초기화 (idle 또는 error 상태에서만)
  Future<Map<String, dynamic>?> initializeIfNeeded() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'initializeIfNeeded',
        _createArguments(),
      );
      if (result == null) return null;
      return result.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      debugPrint('[Petgram] ❌ initializeIfNeeded error: $e');
      rethrow;
    }
  }

  /// 🔥 Flutter → Native: initializeIfNeeded (viewId/cameraPosition 전달)
  /// Returns Map with camera state and debug info
  Future<Map<String, dynamic>?> requestInitializeIfNeeded({
    required int viewId,
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    final args = _createArguments({
      'viewId': viewId,
      'cameraPosition': cameraPosition,
      if (aspectRatio != null) 'aspectRatio': aspectRatio,
    });
    debugPrint(
      '[Petgram] 📷 requestInitializeIfNeeded: viewId=$viewId, position=$cameraPosition, aspect=$aspectRatio',
    );
    debugPrint(
      '[Petgram] 📷 About to invokeMethod: initializeIfNeeded, args=$args',
    );
    _emitDebugLog(
      '[Petgram] 📷 About to invokeMethod: initializeIfNeeded, args=$args',
    );

    // 🔥 invokeMethod 호출 전 상태 확인
    _emitDebugLog(
      '[Petgram] 🔥 About to await invokeMethod: initializeIfNeeded',
    );
    _emitDebugLog('[Petgram] 🔥 Channel name: petgram/native_camera');
    _emitDebugLog('[Petgram] 🔥 Args: $args');

    try {
      debugPrint(
        '[Petgram] 🔥 [TIMING] invokeMethod call started at ${DateTime.now().millisecondsSinceEpoch}',
      );
      _emitDebugLog('[Petgram] 🔥 [TIMING] invokeMethod call started');

      final result = await _channel.invokeMethod('initializeIfNeeded', args);

      debugPrint(
        '[Petgram] 🔥 [TIMING] invokeMethod call completed at ${DateTime.now().millisecondsSinceEpoch}',
      );
      _emitDebugLog('[Petgram] 🔥 [TIMING] invokeMethod call completed');

      if (result == null) {
        final errorMsg =
            '[Petgram] ❌ CRITICAL: invokeMethod returned NULL! This means native handler was NOT called or returned nil';
        debugPrint(errorMsg);
        _emitDebugLog(errorMsg);
        return null;
      }

      final resultStr = result.toString();
      final resultType = result.runtimeType.toString();
      debugPrint(
        '[Petgram] ✅ invokeMethod returned: $resultStr (type: $resultType)',
      );
      _emitDebugLog(
        '[Petgram] ✅ invokeMethod returned: $resultStr (type: $resultType)',
      );

      // result가 Map인 경우 상세 정보 로깅
      if (result is Map) {
        _emitDebugLog('[Petgram] ✅ Result is Map, extracting details...');
        final sessionRunning = result['sessionRunning'];
        final hasFirstFrame = result['hasFirstFrame'];
        final videoConnected = result['videoConnected'];

        // 🔥 네이티브 디버그 정보 확인
        final nativeHandled = result['_nativeHandled'];
        final nativeCase = result['_case'];
        final nativeViewId = result['_viewId'];
        final nativePosition = result['_position'];
        final fromRegistry = result['_fromRegistry'];

        debugPrint(
          '[Petgram] 📊 Result details: sessionRunning=$sessionRunning, hasFirstFrame=$hasFirstFrame, videoConnected=$videoConnected',
        );
        debugPrint(
          '[Petgram] 🔍 Native debug: handled=$nativeHandled, case=$nativeCase, viewId=$nativeViewId, position=$nativePosition, fromRegistry=$fromRegistry',
        );
        _emitDebugLog(
          '[Petgram] 📊 Result: sessionRunning=$sessionRunning, hasFirstFrame=$hasFirstFrame, videoConnected=$videoConnected',
        );
        _emitDebugLog(
          '[Petgram] 🔍 Native handled=$nativeHandled, case=$nativeCase, viewId=$nativeViewId, position=$nativePosition, fromRegistry=$fromRegistry',
        );

        // 네이티브가 처리하지 않았다면 에러
        if (nativeHandled != true) {
          final errorMsg =
              '[Petgram] ❌ CRITICAL: Native handle() was NOT called! result=$result';
          debugPrint(errorMsg);
          _emitDebugLog(errorMsg);
        }

        // 🔥 Map을 반환
        return Map<String, dynamic>.from(result);
      } else {
        final errorMsg =
            '[Petgram] ❌ CRITICAL: Result is not a Map! result=$result (type: ${result.runtimeType})';
        debugPrint(errorMsg);
        _emitDebugLog(errorMsg);
        return null;
      }
    } on PlatformException catch (e, st) {
      // 🔥 PlatformException: 네이티브 handler가 없거나 에러 발생
      final errorMsg =
          '[Petgram] ❌ CRITICAL PlatformException: code=${e.code}, message=${e.message}, details=${e.details}';
      debugPrint(errorMsg);
      _emitDebugLog(errorMsg);
      debugPrint('[Petgram] ❌ PlatformException stack: $st');
      _emitDebugLog('[Petgram] ❌ PlatformException stack: $st');

      // 코드별 상세 분석
      if (e.code == 'not_implemented' ||
          e.message?.contains('not implemented') == true) {
        final detailMsg =
            '[Petgram] ❌ METHOD NOT IMPLEMENTED: Native handler for "initializeIfNeeded" is not registered!';
        debugPrint(detailMsg);
        _emitDebugLog(detailMsg);
      } else if (e.code == 'channel_error' ||
          e.message?.contains('channel') == true) {
        final detailMsg =
            '[Petgram] ❌ CHANNEL ERROR: MethodChannel "petgram/native_camera" is not properly connected!';
        debugPrint(detailMsg);
        _emitDebugLog(detailMsg);
      }

      rethrow;
    } catch (e, st) {
      // 🔥 일반 예외
      final errorMsg =
          '[Petgram] ❌ CRITICAL Exception: $e (type: ${e.runtimeType})';
      debugPrint(errorMsg);
      _emitDebugLog(errorMsg);
      debugPrint('[Petgram] ❌ Exception stack: $st');
      _emitDebugLog('[Petgram] ❌ Exception stack: $st');
      rethrow;
    }
  }

  /// 🔥 FSM 명령: 필요시 복구 (error 상태에서만)
  Future<Map<String, dynamic>?> recoverIfNeeded() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'recoverIfNeeded',
        _createArguments(),
      );
      if (result == null) return null;
      return result.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      debugPrint('[Petgram] ❌ recoverIfNeeded error: $e');
      rethrow;
    }
  }

  /// 🔥 FSM 명령: 세션 재시작 (ready 또는 error 상태에서만)
  Future<Map<String, dynamic>?> restartSession() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'restartSession',
        _createArguments(),
      );
      if (result == null) return null;
      return result.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      debugPrint('[Petgram] ❌ restartSession error: $e');
      rethrow;
    }
  }

  /// 🔥 성능 최적화: 카메라 세션 일시 중지
  @override
  Future<void> pauseSession() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod('pauseSession', _createArguments());
      if (kDebugMode) {
        debugPrint('[Petgram] ⏸️ pauseSession called for viewId=$_viewId');
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ pauseSession error: $e');
    }
  }

  /// 🔥 성능 최적화: 카메라 세션 재개
  @override
  Future<void> resumeSession() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod('resumeSession', _createArguments());
      if (kDebugMode) {
        debugPrint('[Petgram] ▶️ resumeSession called for viewId=$_viewId');
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ resumeSession error: $e');
    }
  }

  /// 🔥 iOS 실기기 프리뷰 보장: 세션 강제 시작 (초기화 후 세션이 시작되지 않은 경우)
  Future<void> startSession() async {
    try {
      // 🔄 리팩토링: iOS에서는 viewId가 필요 없음
      if (!_isIOS && _viewId == null) return;
      await _channel.invokeMethod('startSession', _createArguments());
      if (kDebugMode) {
        debugPrint('[Petgram] ▶️ startSession called for viewId=$_viewId');
      }
      _emitDebugLog('[Camera] ✅ startSession called');
    } catch (e) {
      debugPrint('[Petgram] ❌ startSession error: $e');
      _emitDebugLog('[Camera] ❌ startSession error: $e');
      rethrow;
    }
  }
}
