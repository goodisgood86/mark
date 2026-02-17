import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../camera/native_camera_controller.dart';
import '../camera/native_camera_interface.dart';

/// 🔥 Single Source of Truth: Flutter-Native 상태 동기화를 위한 모델
/// 모든 카메라 상태는 이 클래스를 통해 전달됨
class CameraDebugState {
  final int viewId;
  final bool sessionRunning;
  final bool videoConnected;
  final bool hasFirstFrame;
  final bool isPinkFallback;
  final String instancePtr; // 🔥 인스턴스 포인터 (Flutter와 네이티브 인스턴스 일치 확인용)

  const CameraDebugState({
    required this.viewId,
    required this.sessionRunning,
    required this.videoConnected,
    required this.hasFirstFrame,
    required this.isPinkFallback,
    required this.instancePtr,
  });

  factory CameraDebugState.fromMap(Map<String, dynamic>? map) {
    // 🔥 진짜 근본 원인 해결: map이 null이어도 viewId >= 0과 instancePtr이 비어있지 않도록 보장
    if (map == null) {
      return const CameraDebugState(
        viewId: 0, // 네이티브에서 이미 >= 0 보장, null이어도 0 (기존 -1 대신)
        sessionRunning: false,
        videoConnected: false,
        hasFirstFrame: false,
        isPinkFallback: false,
        instancePtr: '0x0', // 네이티브에서 이미 비어있지 않음 보장, null이어도 더미 값 (기존 '' 대신)
      );
    }

    // 타입 보정용 헬퍼
    // 🔥 Swift Bool이 NSNumber로 변환될 수 있으므로 더 견고하게 처리
    // 🔥 CameraEngine._toBool과 동일한 로직 사용 (중복 제거)
    bool toBool(dynamic v) => CameraEngine._toBool(v);

    // 🔥 진짜 근본 원인 해결: 네이티브에서 이미 viewId >= 0과 instancePtr이 비어있지 않도록 보장했으므로,
    //                          기본값을 -1과 빈 문자열 대신 0과 더미 포인터로 변경
    //                          하지만 네이티브 값이 있으면 우선 사용
    final nativeViewId = (map['viewId'] as num?)?.toInt();
    final nativeInstancePtr = map['instancePtr'] as String?;

    return CameraDebugState(
      viewId: nativeViewId ?? 0, // 네이티브에서 이미 >= 0 보장, 없으면 0 (기존 -1 대신)
      sessionRunning: toBool(map['sessionRunning']),
      videoConnected: toBool(map['videoConnected']),
      hasFirstFrame: toBool(map['hasFirstFrame']),
      isPinkFallback: toBool(map['isPinkFallback']),
      instancePtr:
          nativeInstancePtr ??
          '0x0', // 네이티브에서 이미 비어있지 않음 보장, 없으면 더미 값 (기존 '' 대신)
    );
  }

  @override
  String toString() {
    return 'CameraDebugState(viewId=$viewId, sessionRunning=$sessionRunning, videoConnected=$videoConnected, hasFirstFrame=$hasFirstFrame, isPinkFallback=$isPinkFallback, instancePtr=$instancePtr)';
  }
}

/// 카메라 상태 enum (상태 머신)
enum CameraState {
  idle, // 초기 상태, 아무 작업도 하지 않음
  initializing, // 카메라 초기화 중
  ready, // 카메라 준비 완료, 사용 가능
  error, // 에러 발생
}

/// 카메라 엔진 - 카메라 관련 모든 로직을 관리
/// HomePage에서 UI와 카메라 로직을 분리하기 위한 클래스
class CameraEngine {
  IPetgramCamera? _nativeCamera;
  bool _isInitializing = false;
  bool _isInitializingNative = false; // 🔥 네이티브 초기화 중 플래그 (중복 호출 방지)
  Future<void>? _initializeIfNeededInFlight; // 🔥 initializeIfNeeded 단일비행
  int? _initializeIfNeededViewId;
  String? _initializeIfNeededCameraPosition;
  double? _initializeIfNeededAspectRatio;
  DateTime? _lastInitializeIfNeededRequestedAt;
  bool _isResuming = false; // 🔥 resume 중 플래그 (중복 호출 방지)
  Future<void>? _resumeInFlight; // 🔥 resume 중복 호출 coalescing
  DateTime? _lastResumeRequestedAt; // 🔥 resume 호출 간격 제한
  bool _useMockCamera = false;
  bool _isSimulator = false; // 🔥 시뮬레이터 여부 캐시
  String? _initErrorMessage;
  bool _isCapturingPhoto = false; // 🔥 촬영 중 플래그 (재초기화 차단용)
  DateTime? _captureFenceUntil; // 🔥 촬영 직후 재초기화/재개 차단 펜스
  bool _hasInitializedOnce = false; // 🔥 전면 재설계: 앱 생명주기 동안 한 번만 초기화

  // 🔥 Single Source of Truth: CameraDebugState 기반으로 상태 통일
  CameraDebugState? _lastDebugState;

  /// 마지막으로 받은 디버그 상태 (Single Source of Truth)
  CameraDebugState? get lastDebugState => _lastDebugState;

  // 🔥 호환성 유지: 기존 필드들 (deprecated, CameraDebugState 사용 권장)
  bool? _nativeInit;
  bool? _isReady;
  bool? _sessionRunning;
  bool? _videoConnected;
  bool? _hasFirstFrame;
  bool? _isPinkFallback;
  double? _currentAspectRatio;
  int? _viewId;

  // 상태 머신
  CameraState _state = CameraState.idle;

  // 상태 리스너
  final List<VoidCallback> _listeners = [];

  // 🔥 배터리/발열 최적화: ValueNotifier 기반 세분화된 상태 관리
  final ValueNotifier<CameraState> stateNotifier = ValueNotifier(
    CameraState.idle,
  );
  final ValueNotifier<bool> isInitializedNotifier = ValueNotifier(false);
  final ValueNotifier<bool> useMockCameraNotifier = ValueNotifier(false);

  // 🔥 디버그 로그 리스너 (디버그 오버레이 표시용)
  final List<Function(String)> _debugLogListeners = [];

  // 🔥🔥🔥 핵심: EventChannel 리스너 (네이티브 상태 변경 실시간 수신)
  StreamSubscription<dynamic>? _cameraStateSubscription;
  static const EventChannel _cameraStateChannel = EventChannel(
    'petgram/cameraStateStream',
  );

  // Getters
  IPetgramCamera? get nativeCamera => _nativeCamera;
  bool get isInitializing => _isInitializing;
  bool get useMockCamera => _useMockCamera;
  bool get isSimulator => _isSimulator; // 🔥 시뮬레이터 여부 공개
  String? get initErrorMessage => _initErrorMessage;

  /// 🔥 실기기에 카메라 장치가 없는지 여부 (시뮬레이터 판정용)
  bool get isDeviceEmpty =>
      _useMockCamera && !Platform.isAndroid && !Platform.isIOS;
  // 🔥 Single Source of Truth: 네이티브 상태만 반환 (Flutter 자체 계산 금지)
  bool get isInitialized => _nativeInit ?? false; // 네이티브에서만 갱신
  bool get isCapturingPhoto => _isCapturingPhoto; // 🔥 촬영 중 여부
  bool? get sessionRunning => _sessionRunning; // 🔥 네이티브 세션 실행 중 여부
  bool? get videoConnected => _videoConnected; // 🔥 비디오 연결 여부
  bool? get hasFirstFrame => _hasFirstFrame; // 🔥 첫 프레임 수신 여부
  bool? get isPinkFallback => _isPinkFallback; // 🔥 핑크 fallback 상태
  double? get currentAspectRatio => _currentAspectRatio; // 🔥 현재 aspect ratio
  int? get viewId => _viewId; // 🔥 viewId

  // 상태 머신 Getters
  CameraState get state => _state;
  bool get isIdle => _state == CameraState.idle;
  bool get isReady => _state == CameraState.ready;
  bool get hasError => _state == CameraState.error;

  // Setters
  set nativeCamera(IPetgramCamera? camera) {
    _nativeCamera = camera;
    // 🔥 Single Source of Truth: 네이티브 상태는 getDebugState()에서만 갱신
    // 여기서는 ValueNotifier만 업데이트 (UI 업데이트용)
    isInitializedNotifier.value = camera != null && camera.isInitialized;
    _notifyListeners();
  }

  /// 🔥 Single Source of Truth: 네이티브에서 받은 isReady만 사용
  /// Flutter는 절대 자체적으로 계산하지 않음
  bool get isCameraReady {
    // Mock 카메라 모드이면 항상 true (네이티브 상태와 무관)
    if (_useMockCamera) {
      return true;
    }
    // 네이티브에서 받은 isReady 값만 사용
    return _isReady ?? false;
  }

  /// Mock 카메라 사용 여부
  /// 🔥 iOS 실기기 프리뷰 보장: iOS 실기기에서는 항상 네이티브 카메라 사용
  ///    Mock은 시뮬레이터일 때만 사용 (네이티브 카메라 초기화 실패 시)
  ///    iOS 실기기에서는 cameras.length와 무관하게 네이티브 카메라를 시도
  bool get shouldUseMockCamera {
    // 🔥 Single Source of Truth: _useMockCamera가 true면 무조건 true (시뮬레이터 판정 후 또는 에러 시)
    if (_useMockCamera) return true;

    // iOS 정책: 시뮬레이터이면 무조건 true, 실기기면 NativeCameraPreview 빌드 유도
    if (Platform.isIOS) {
      if (_isSimulator) return true;
      return false;
    }

    // Android/기타 플랫폼: 기본적으로 _useMockCamera 상태를 따름
    return _useMockCamera;
  }

  /// 리스너 추가
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  /// 리스너 제거
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// 상태 변경 알림
  void _notifyListeners() {
    for (final listener in _listeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('[CameraEngine] Listener error: $e');
      }
    }
  }

  /// 상태 변경 헬퍼 메서드
  /// 🔥 배터리/발열 최적화: ValueNotifier도 함께 업데이트
  void _setState(CameraState newState, {String? errorMessage}) {
    if (_state != newState) {
      _state = newState;
      if (errorMessage != null) {
        _initErrorMessage = errorMessage;
      }
      // 🔥 배터리/발열 최적화: ValueNotifier 업데이트 (세분화된 재빌드 가능)
      stateNotifier.value = newState;
      _notifyListeners(); // 기존 리스너도 유지 (하위 호환성)
      if (kDebugMode) {
        debugPrint('[CameraEngine] 📊 State changed: ${_state.name}');
      }
    }
  }

  /// Mock 카메라 초기화 (시뮬레이터/카메라 없을 때)
  /// ⚠️ 중요: 네이티브 카메라 API를 호출하지 않음
  Future<void> initializeMock({required double aspectRatio}) async {
    if (kDebugMode) {
      debugPrint('[CameraEngine] 🎭 Initializing MOCK camera');
    }

    _isInitializing = true;
    _initErrorMessage = null;
    // 🔥 배터리/발열 최적화: ValueNotifier 업데이트
    stateNotifier.value = CameraState.initializing;
    _setState(CameraState.initializing);
    _notifyListeners();

    try {
      // 기존 카메라 해제
      if (_nativeCamera != null) {
        await _nativeCamera!.dispose();
        _nativeCamera = null;
      }

      // Mock 카메라 모드 활성화
      _useMockCamera = true;
      _nativeCamera = null;
      _initErrorMessage = null;
      // 🔥 배터리/발열 최적화: ValueNotifier 업데이트
      useMockCameraNotifier.value = true;
      isInitializedNotifier.value = false;
      _setState(CameraState.ready);

      if (kDebugMode) {
        debugPrint('[CameraEngine] ✅ Mock camera initialized');
        debugPrint(
          '[CameraEngine] 📊 isCameraReady=$isCameraReady, shouldUseMockCamera=$shouldUseMockCamera',
        );
      }
    } catch (e) {
      _setState(CameraState.error, errorMessage: e.toString());
      rethrow;
    } finally {
      _isInitializing = false;
      _notifyListeners();
    }
  }

  /// viewId를 저장하고 NativeCameraController를 생성 (attachNativeView)
  /// NativeCameraPreview.onCreated에서만 호출됨. onCreated에서 await 후 _doCameraInit 호출.
  /// isSimulator는 비블로킹(백그라운드) — await 시 네이티브에서 지연/블록되면 _doCameraInit가 호출되지 않는 문제 방지.
  Future<void> attachNativeView(int viewId) async {
    _viewId = viewId;

    _nativeCamera ??= NativeCameraController();

    if (_nativeCamera is NativeCameraController) {
      (_nativeCamera as NativeCameraController).setViewId(viewId);

      // 시뮬레이터 체크: 블로킹하지 않고 백그라운드에서 실행 (await 시 네이티브 지연/블록으로 _doCameraInit 미호출 방지)
      (_nativeCamera as NativeCameraController)
          .isSimulator()
          .then((v) {
            _isSimulator = v;
            if (kDebugMode) {
              debugPrint('[CameraEngine] 📱 Simulator check: $_isSimulator');
            }
            if (Platform.isIOS && _isSimulator) {
              _useMockCamera = true;
              useMockCameraNotifier.value = true;
              _notifyListeners();
            }
          })
          .catchError((e) {
            if (kDebugMode) {
              debugPrint('[CameraEngine] ⚠️ Simulator check failed: $e');
            }
          });
    }

    _startCameraStateListener();
  }

  /// EventChannel 리스너 시작
  void _startCameraStateListener() {
    if (_cameraStateSubscription != null) {
      return;
    }

    _cameraStateSubscription = _cameraStateChannel
        .receiveBroadcastStream()
        .listen(
          (dynamic event) {
            try {
              if (event is String) {
                final stateMap = jsonDecode(event) as Map<String, dynamic>;
                _handleNativeStateChange(stateMap);
              }
            } catch (e) {
              _emitDebugLog('[CameraEngine] ❌ EventChannel parse error: $e');
            }
          },
          onError: (error) {
            _emitDebugLog('[CameraEngine] ❌ EventChannel error: $error');
          },
        );
  }

  /// 네이티브 상태 변경 처리
  void _handleNativeStateChange(Map<String, dynamic> stateMap) {
    // 🔥 Single Source of Truth: 네이티브 상태를 즉시 반영
    final viewId = (stateMap['viewId'] as num?)?.toInt();
    final instancePtr = stateMap['instancePtr'] as String? ?? '0x0';
    final sessionRunning = _toBool(stateMap['sessionRunning']);
    final videoConnected = _toBool(stateMap['videoConnected']);
    final hasFirstFrame = _toBool(stateMap['hasFirstFrame']);
    final isPinkFallback = _toBool(stateMap['isPinkFallback']);
    final nativeInit = _toBool(stateMap['nativeInit']);
    final String stateStr = stateMap['state'] as String? ?? 'idle';

    // 🔥 카메라 초기화 완료 감지: sessionRunning && videoConnected && hasFirstFrame이면 초기화 완료
    final bool cameraReady = sessionRunning && videoConnected && hasFirstFrame;
    if (cameraReady && _isInitializing) {
      _isInitializing = false;
      _isInitializingNative = false;
      _emitDebugLog(
        '[CameraEngine] ✅ Camera initialization completed: sessionRunning=$sessionRunning, videoConnected=$videoConnected, hasFirstFrame=$hasFirstFrame',
      );
    }

    // CameraDebugState 업데이트
    _lastDebugState = CameraDebugState(
      viewId: viewId ?? 0,
      sessionRunning: sessionRunning,
      videoConnected: videoConnected,
      hasFirstFrame: hasFirstFrame,
      isPinkFallback: isPinkFallback,
      instancePtr: instancePtr,
    );

    // 기존 필드도 업데이트 (호환성)
    _nativeInit = nativeInit;
    _sessionRunning = sessionRunning;
    _videoConnected = videoConnected;
    _hasFirstFrame = hasFirstFrame;
    _isPinkFallback = isPinkFallback;
    _viewId = viewId;

    // 상태 머신 업데이트
    switch (stateStr) {
      case 'idle':
        _setState(CameraState.idle);
        break;
      case 'initializing':
        _setState(CameraState.initializing);
        break;
      case 'ready':
        _setState(CameraState.ready);
        break;
      case 'error':
        _setState(CameraState.error);
        break;
    }

    _notifyListeners();
  }

  /// 🔥 A' 구조: 네이티브 FSM에 초기화 요청만 전달 (얇은 wrapper)
  /// Flutter는 상태 판단 없이 네이티브의 initializeIfNeeded()를 호출만 함
  /// 실제 초기화 여부는 네이티브 FSM이 cameraState를 보고 결정
  Future<void> requestInitializeIfNeeded({
    required int viewId,
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    final now = DateTime.now();
    final inFlight = _initializeIfNeededInFlight;
    final hasInFlight = inFlight != null;
    final isSameAsInFlight =
        hasInFlight &&
        _initializeIfNeededViewId == viewId &&
        _initializeIfNeededCameraPosition == cameraPosition &&
        _isAspectRatioClose(_initializeIfNeededAspectRatio, aspectRatio);

    // 🔥 단일비행: 같은 인자면 기존 in-flight 요청에 합류
    if (isSameAsInFlight) {
      _emitDebugLog(
        '[CameraEngine] ⏸️ requestInitializeIfNeeded coalesced: same args in-flight (viewId=$viewId, position=$cameraPosition, aspectRatio=$aspectRatio)',
      );
      await inFlight;
      return;
    }

    // 🔥 짧은 디바운스: 직전 요청 직후 같은 키로 다시 들어오면 스킵
    final lastRequestedAt = _lastInitializeIfNeededRequestedAt;
    if (lastRequestedAt != null &&
        now.difference(lastRequestedAt) < const Duration(milliseconds: 120) &&
        _initializeIfNeededViewId == viewId &&
        _initializeIfNeededCameraPosition == cameraPosition &&
        _isAspectRatioClose(_initializeIfNeededAspectRatio, aspectRatio)) {
      _emitDebugLog(
        '[CameraEngine] ⏸️ requestInitializeIfNeeded debounced: duplicate within 120ms (viewId=$viewId)',
      );
      return;
    }

    _initializeIfNeededViewId = viewId;
    _initializeIfNeededCameraPosition = cameraPosition;
    _initializeIfNeededAspectRatio = aspectRatio;
    _lastInitializeIfNeededRequestedAt = now;

    final operation = _requestInitializeIfNeededInternal(
      viewId: viewId,
      cameraPosition: cameraPosition,
      aspectRatio: aspectRatio,
    );
    _initializeIfNeededInFlight = operation;

    try {
      await operation;
    } finally {
      if (identical(_initializeIfNeededInFlight, operation)) {
        _initializeIfNeededInFlight = null;
      }
    }
  }

  Future<void> _requestInitializeIfNeededInternal({
    required int viewId,
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    _emitDebugLog(
      '[CameraEngine] 📷 requestInitializeIfNeeded: viewId=$viewId, position=$cameraPosition, aspectRatio=$aspectRatio',
    );

    if (_nativeCamera == null) {
      throw StateError(
        'NativeCameraController is null. Call attachNativeView() first.',
      );
    }

    if (_nativeCamera is NativeCameraController) {
      final controller = _nativeCamera as NativeCameraController;
      try {
        await controller.requestInitializeIfNeeded(
          viewId: viewId,
          cameraPosition: cameraPosition,
          aspectRatio: aspectRatio,
        );
        _emitDebugLog(
          '[CameraEngine] ✅ requestInitializeIfNeeded: command sent to native FSM',
        );
      } on PlatformException catch (e, _) {
        if (e.code == 'INIT_CALL_TIMEOUT') {
          _emitDebugLog(
            '[CameraEngine] ⚠️ initializeIfNeeded timeout -> recoverIfNeeded + retry 1회',
          );
          try {
            await controller.recoverIfNeeded();
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 150));
          await controller.requestInitializeIfNeeded(
            viewId: viewId,
            cameraPosition: cameraPosition,
            aspectRatio: aspectRatio,
          );
          _emitDebugLog(
            '[CameraEngine] ✅ timeout retry succeeded: initializeIfNeeded',
          );
          return;
        }
        _emitDebugLog(
          '[CameraEngine] ❌ requestInitializeIfNeeded failed: code=${e.code}, message=${e.message}',
        );
        rethrow;
      }
    }
  }

  static bool _isAspectRatioClose(double? a, double? b) {
    if (a == null && b == null) {
      return true;
    }
    if (a == null || b == null) {
      return false;
    }
    return (a - b).abs() < 0.0001;
  }

  Future<void> initializeSingle({
    required String position,
    required double aspectRatio,
  }) async {
    if (_nativeCamera is! NativeCameraController) {
      return;
    }
    final controller = _nativeCamera as NativeCameraController;
    // viewId는 attachNativeView에서 설정됨; 없으면 0 전달
    final viewId = controller.viewId ?? 0;
    try {
      final result = await controller.requestInitializeIfNeeded(
        viewId: viewId,
        cameraPosition: position,
        aspectRatio: aspectRatio,
      );

      if (result == null) {
        return;
      }

      // 🔥 네이티브 디버그 정보 확인
      // sessionRunning, hasFirstFrame은 로깅용으로 사용 가능하나 현재는 체크 용도로만 존재
      final bool nativeDeviceExists =
          result['device'] != null &&
          (result['device'] is! Map || (result['device'] as Map).isNotEmpty);

      // 🔥🔥🔥 핵심 수정: 카메라 디바이스가 없으면 즉시 Mock 모드로 전환
      if (!nativeDeviceExists) {
        await initializeMock(aspectRatio: aspectRatio);
        return;
      }

      // 🔥 핵심 수정: 네이티브 FSM이 error 상태에 있으면 recoverIfNeeded 호출
      final beforeState = result['_beforeCameraState'];
      final afterState = result['_afterCameraState'];
      if (beforeState == 'error' || afterState == 'error') {
        try {
          await controller.recoverIfNeeded();
          // recoverIfNeeded 후 즉시 재시도
          Future.delayed(const Duration(milliseconds: 100), () async {
            try {
              await controller.requestInitializeIfNeeded(
                viewId: viewId,
                cameraPosition: position,
                aspectRatio: aspectRatio,
              );
            } catch (_) {}
          });
        } catch (_) {}
      }
    } on PlatformException catch (_) {
      rethrow;
    } catch (_) {
      rethrow;
    }
  }

  /// 🔥 전면 재설계: 앱 생명주기 동안 한 번만 초기화되는 메서드
  /// HomePage.initState에서 딱 한 번만 호출됨
  /// onCreated/build/resume 등에서는 절대 호출되지 않음
  Future<void> initializeNativeCameraOnce({
    required int viewId,
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    // 🔥 핵심 규칙: 이미 한 번 초기화했으면 절대 재초기화 금지
    if (_hasInitializedOnce) {
      _emitDebugLog(
        '[InitOnce] ⏸️ skipping initializeNativeCameraOnce: already initialized once (viewId=$viewId)',
      );
      if (kDebugMode) {
        debugPrint(
          '[CameraEngine] ⏸️ initializeNativeCameraOnce: already initialized, skipping',
        );
      }
      return;
    }

    // 🔒 촬영 직후 펜스: 촬영 완료 후 잠시 동안 재초기화 차단
    final now = DateTime.now();
    if (_captureFenceUntil != null && now.isBefore(_captureFenceUntil!)) {
      return;
    }
    // 🔥 촬영 중 초기화 금지: 세션이 안정화될 때까지 대기
    if (_isCapturingPhoto) {
      return;
    }

    // 🔥 기존 initializeNativeCamera 로직 호출
    try {
      await _performInitializeNativeCamera(
        viewId: viewId,
        cameraPosition: cameraPosition,
        aspectRatio: aspectRatio,
      );

      // 🔥 Mock 모드로 전환되었으면 first frame 체크 스킵
      if (_useMockCamera) {
        // Mock 모드로 전환되면 초기화 완료로 간주
        _hasInitializedOnce = true;
        return; // Mock 모드에서는 first frame이 없으므로 체크 스킵
      }

      // 🔥🔥🔥 성능 최적화: initialize() 호출 제거 (일반 카메라 앱처럼 즉시 진입)
      // initialize()는 Flutter 측 상태만 업데이트하는데, 이미 네이티브 초기화가 완료되었으므로
      // 세션이 시작되면 즉시 초기화 완료로 간주하고, 첫 프레임은 백그라운드에서 수신
      // UI는 먼저 표시하고 프리뷰는 준비되면 자동으로 표시됨
      // initialize() 호출은 블로킹될 수 있으므로 제거

      // 🔥 성능 최적화: 세션 상태 확인 (짧은 대기)
      // 네이티브 초기화가 완료되었으므로 세션이 곧 시작될 것임
      // 최대 500ms 대기 후 세션 상태 확인
      bool sessionRunning = false;
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final debugState = await getDebugState();
        sessionRunning = debugState?['sessionRunning'] as bool? ?? false;
        if (sessionRunning) {
          break;
        }
      }

      if (sessionRunning) {
        // 세션이 실행 중이면 초기화 완료로 간주 (첫 프레임은 나중에 수신)
        _emitDebugLog(
          '[InitOnce] ✅ Camera session started (first frame will arrive asynchronously)',
        );
        // 🔥 Flutter 측 상태 업데이트 (initialize() 대신 직접 업데이트)
        _useMockCamera = false;
        _initErrorMessage = null;
        _nativeInit = true;
        _isReady = true;
        useMockCameraNotifier.value = false;
        isInitializedNotifier.value = true;
        _setState(CameraState.ready);
        _hasInitializedOnce = true;
      } else {
        // 세션이 시작되지 않았어도 초기화 완료로 간주 (네이티브에서 곧 시작될 것)
        // 일반 카메라 앱처럼 UI를 먼저 표시하고 세션은 백그라운드에서 시작
        _emitDebugLog(
          '[InitOnce] ⚠️ Session not running yet, but initialization completed (session will start in background)',
        );
        // 🔥 Flutter 측 상태 업데이트
        _useMockCamera = false;
        _initErrorMessage = null;
        _nativeInit = true;
        _isReady = true;
        useMockCameraNotifier.value = false;
        isInitializedNotifier.value = true;
        _setState(CameraState.ready);
        _hasInitializedOnce = true;
      }
    } catch (e, stackTrace) {
      // 🔥 Mock 모드로 전환되었으면 에러를 다시 던지지 않음
      if (_useMockCamera) {
        _emitDebugLog(
          '[InitOnce] ✅ Mock camera mode activated after error, initialization completed',
        );
        // Mock 모드로 전환되면 초기화 완료로 간주
        _hasInitializedOnce = true;
        return;
      }

      // 🔥 초기화 실패 시 플래그 리셋하여 재시도 가능하게
      // (단, "operation in progress"는 재시도했으므로 실패로 간주하지 않음)
      _hasInitializedOnce = false;
      _emitDebugLog('[InitOnce] ❌ INIT FAILED: $e');
      _emitDebugLog('[InitOnce] Stack: $stackTrace');
      rethrow;
    }
  }

  /// 🔥 내부 초기화 로직 (기존 initializeNativeCamera의 핵심 로직)
  /// 반환값: 재시도 성공 여부 (재시도가 있었고 성공했으면 true)
  Future<bool> _performInitializeNativeCamera({
    required int viewId,
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    // 🔥 핵심 수정: 중복 호출 방지
    if (_isInitializingNative) {
      return false; // 중복 초기화 스킵 (재시도 없음)
    }

    // 🔥 제거됨: Flutter에서 healthy 상태 판단 로직
    // 네이티브 FSM이 상태를 관리하므로, Flutter는 무조건 네이티브에 명령만 전달
    // 네이티브 FSM이 initializeIfNeeded() 내부에서 상태를 확인하고 처리

    // 🔥 핵심 수정: 촬영 중이면 대기 후 재시도 (차단하지 않음)
    if (_isCapturingPhoto) {
      final waitLog =
          '[Init] init skipped because isCapturingPhoto=true, waiting...';
      _emitDebugLog(waitLog);
      if (kDebugMode) {
        debugPrint('[CameraEngine] ⚠️ $waitLog');
      }

      // 촬영 완료까지 대기 (최대 5초)
      int retryCount = 0;
      const maxRetries = 50; // 50 * 100ms = 5초
      while (_isCapturingPhoto && retryCount < maxRetries) {
        await Future.delayed(const Duration(milliseconds: 100));
        retryCount++;
      }

      if (_isCapturingPhoto) {
        final timeoutLog =
            '[Init] init timeout: photo capture still in progress after 5s';
        _emitDebugLog(timeoutLog);
        if (kDebugMode) {
          debugPrint('[CameraEngine] ⚠️ $timeoutLog');
        }
        // 타임아웃이어도 계속 진행 (플래그가 잘못 설정되었을 수 있음)
      } else {
        final resumeLog = '[Init] init resuming: photo capture completed';
        _emitDebugLog(resumeLog);
        if (kDebugMode) {
          debugPrint('[CameraEngine] ✅ $resumeLog');
        }
      }
    }

    // 🔥 상태 리셋: 실제 초기화를 진행할 때만 이전 세션 상태를 무효화
    _lastDebugState = null;

    _isInitializingNative = true;
    try {
      // attachNativeView가 먼저 호출되어야 함
      if (_nativeCamera == null) {
        throw StateError(
          'NativeCameraController is null. Call attachNativeView(viewId) from NativeCameraPreview.onCreated first.',
        );
      }

      // viewId 검증
      if (_nativeCamera is NativeCameraController) {
        final controller = _nativeCamera as NativeCameraController;
        if (controller.viewId != viewId) {
          throw StateError(
            'ViewId mismatch. Expected $viewId but got ${controller.viewId}. Call attachNativeView($viewId) first.',
          );
        }
      }

      // 네이티브에 initializeNativeCamera 호출
      try {
        if (_nativeCamera is NativeCameraController) {
          final controller = _nativeCamera as NativeCameraController;
          await controller.initializeNativeCamera(
            viewId: viewId,
            cameraPosition: cameraPosition,
          );
        }
      } on PlatformException catch (e, _) {
        // NO_CAMERA_DEVICE, INIT_TIMEOUT 등의 에러는 mock으로 전환
        // ⚠️ "operation in progress"는 카메라가 없어서가 아니라 작업 진행 중이므로 재시도 필요
        final String? msg = e.message?.toLowerCase();
        final bool isOperationInProgress =
            msg?.contains('operation in progress') == true ||
            msg?.contains('isrunningoperationinprogress') == true;

        if (isOperationInProgress) {
          // "operation in progress" 에러: 짧은 대기 후 재시도 (최대 3회)
          const int maxRetries = 3;
          const Duration retryDelay = Duration(milliseconds: 500);
          PlatformException? lastError = e;
          bool retrySucceeded = false;

          for (int retry = 0; retry < maxRetries; retry++) {
            await Future.delayed(retryDelay);

            try {
              if (_nativeCamera is NativeCameraController) {
                final controller = _nativeCamera as NativeCameraController;
                await controller.initializeNativeCamera(
                  viewId: viewId,
                  cameraPosition: cameraPosition,
                );
                // 재시도 성공
                retrySucceeded = true;
                break; // 성공했으므로 루프 종료
              }
            } on PlatformException catch (retryError, _) {
              lastError = retryError;
              final String? retryMsg = retryError.message?.toLowerCase();
              final bool stillInProgress =
                  retryMsg?.contains('operation in progress') == true ||
                  retryMsg?.contains('isrunningoperationinprogress') == true;

              if (!stillInProgress) {
                break; // 다른 에러로 처리하도록 루프 종료
              }

              // 마지막 재시도 실패
              if (retry == maxRetries - 1) {
                _isInitializing = false;
                _isInitializingNative = false;
                _notifyListeners();
                throw PlatformException(
                  code: 'INIT_RETRY_FAILED',
                  message:
                      'Camera initialization failed after $maxRetries retries: operation still in progress',
                  details: null,
                );
              }
            }
          }

          // 재시도 성공했으면 _performInitializeNativeCamera 완료로 간주하고 return
          if (retrySucceeded) {
            return true; // 재시도 성공했음을 반환
          } else {
            // 재시도 실패했지만 다른 에러로 변경되었으면 lastError로 처리
            if (lastError != null && lastError.code != e.code) {
              // lastError로 다시 처리하도록 throw
              _isInitializing = false;
              _isInitializingNative = false;
              _notifyListeners();
              throw lastError;
            }
            // 재시도 실패 및 다른 에러도 없으면 원래 에러 rethrow
            _isInitializing = false;
            _isInitializingNative = false;
            _notifyListeners();
            rethrow;
          }
        }

        final bool isRealCameraUnavailable =
            (e.code == 'NO_CAMERA_DEVICE' ||
            e.code == 'PERMISSION_DENIED' ||
            (e.code == 'INIT_FAILED' &&
                (msg?.contains('permission') == true ||
                    msg?.contains('device') == true ||
                    msg?.contains('no camera') == true ||
                    msg?.contains('simulator') == true ||
                    msg?.contains('hardware unavailable') == true)) ||
            e.code == 'INIT_TIMEOUT' ||
            (msg?.contains('permission') == true ||
                msg?.contains('device') == true ||
                msg?.contains('no camera') == true ||
                msg?.contains('simulator') == true ||
                msg?.contains('timeout') == true ||
                msg?.contains('hardware unavailable') == true));

        // 🔥 iOS 정책: 실기기에서는 어떤 에러가 발생해도 자동으로 Mock으로 전환하지 않음
        // 시뮬레이터일 때만 Mock fallback 허용
        bool isSimulator = false;
        if (Platform.isIOS && _nativeCamera is NativeCameraController) {
          try {
            isSimulator = await (_nativeCamera as NativeCameraController)
                .isSimulator();
          } catch (_) {
            isSimulator = false;
          }
        }

        final bool allowMockFallback =
            (!Platform.isIOS && isRealCameraUnavailable) ||
            (Platform.isIOS && isSimulator && isRealCameraUnavailable);

        if (allowMockFallback) {
          // Mock으로 전환
          _nativeCamera = null;
          _useMockCamera = true;
          _initErrorMessage =
              'Native camera unavailable, using mock: ${e.message ?? e.code}';
          useMockCameraNotifier.value = true;
          isInitializedNotifier.value = false;
          _setState(CameraState.ready);
          _isInitializing = false;
          _isInitializingNative = false;
          _notifyListeners();
          return false; // Mock 모드로 전환했으므로 초기화 중단 (재시도 없음)
        } else {
          // 다른 에러는 rethrow하여 initialize()의 catch 블록에서 처리
          _isInitializing = false;
          _isInitializingNative = false;
          _notifyListeners();
          rethrow;
        }
      }

      // 정상 완료 (재시도 없이 성공)
      return false; // 재시도 없이 정상 완료
    } finally {
      _isInitializingNative = false;
    }
  }

  /// 카메라 초기화
  Future<void> initialize({
    required String cameraPosition,
    double? aspectRatio,
  }) async {
    if (_isCapturingPhoto) {
      return;
    }

    if (_isInitializing) {
      return;
    }

    // 🔥 시작 시 상태 로깅
    final int? viewId = _nativeCamera is NativeCameraController
        ? (_nativeCamera as NativeCameraController).viewId
        : null;
    final startStateMsg = StringBuffer()
      ..write('[CameraEngine] 📷 INIT START: ')
      ..write('position=$cameraPosition, ')
      ..write('aspectRatio=$aspectRatio, ')
      ..write('viewId=$viewId, ')
      ..write('isCameraReady=$isCameraReady, ')
      ..write('useMockCamera=$useMockCamera');
    _emitDebugLog(startStateMsg.toString());

    _isInitializing = true;
    _initErrorMessage = null;
    // 🔥 배터리/발열 최적화: ValueNotifier 업데이트
    stateNotifier.value = CameraState.initializing;
    _setState(CameraState.initializing);
    _notifyListeners();

    try {
      // iOS에서는 네이티브 카메라 초기화 시도
      if (Platform.isIOS) {
        try {
          // 🔥 Pattern A 보장: NativeCameraController는 initializeNativeCamera에서만 생성됨
          //    여기서는 이미 생성되어 있어야 함
          if (_nativeCamera == null) {
            _isInitializing = false;
            _notifyListeners();
            throw StateError(
              'NativeCameraController is null. Call initializeNativeCamera() from NativeCameraPreview.onCreated first.',
            );
          }

          // 🔥 Pattern A 보장: viewId 검증
          // iOS에서는 viewId를 사용하지 않지만, Android에서는 필수
          final controller = _nativeCamera as NativeCameraController;
          final int? currentViewId = controller.viewId;

          // viewId 검증 (Android에서만 필수, iOS에서는 선택적)
          if (!Platform.isIOS) {
            // Android에서는 viewId가 null이거나 -1 이하이면 프로그래밍 버그
            if (currentViewId == null || currentViewId < 0) {
              _isInitializing = false;
              _notifyListeners();
              throw StateError(
                'ViewId not set or invalid (viewId=$currentViewId). Call setViewId() with a valid viewId (>= 0) from NativeCameraPreview.onCreated before initialize(). '
                'This is a programming error, not a camera unavailability issue.',
              );
            }
          } else {
            // iOS에서는 viewId를 사용하지 않지만, 로깅용으로 확인
            if (kDebugMode && (currentViewId == null || currentViewId < 0)) {
              debugPrint(
                '[CameraEngine] ⚠️ iOS: viewId=$currentViewId is invalid, but iOS does not require viewId. This may indicate a programming error.',
              );
            }
          }

          // 🔥 Single Source of Truth: 네이티브 상태 확인 후 결정
          final debugState = await getDebugState();
          final nativeInit = debugState?['nativeInit'] as bool? ?? false;
          final isReady = debugState?['isReady'] as bool? ?? false;
          final sessionRunning =
              debugState?['sessionRunning'] as bool? ?? false;

          // 🔥 이미 초기화되었으면 네이티브 초기화 스킵 (중복 초기화 방지)
          bool skippedNativeInit = false;
          if (nativeInit && isReady && sessionRunning) {
            // 네이티브는 이미 초기화되었으므로 Flutter 측 상태만 업데이트
            _useMockCamera = false;
            _initErrorMessage = null;
            _nativeInit = true;
            _isReady = true;
            useMockCameraNotifier.value = false;
            isInitializedNotifier.value = true;
            _setState(CameraState.ready);
            skippedNativeInit = true;
          } else if (nativeInit && isReady && !sessionRunning) {
            // 네이티브는 초기화되었지만 세션이 중지된 경우: dispose 후 재초기화
            await _nativeCamera!.dispose();
            await _nativeCamera!.initialize(
              cameraPosition: cameraPosition,
              aspectRatio: aspectRatio,
            );
          } else {
            // 네이티브가 초기화되지 않은 경우: 정상 초기화 진행
            await _nativeCamera!.initialize(
              cameraPosition: cameraPosition,
              aspectRatio: aspectRatio,
            );
          }

          // 🔥 초기화 성공 확인 및 상세 로깅
          if (!skippedNativeInit) {
            final bool isInit = _nativeCamera!.isInitialized;

            if (isInit) {
              // 🔥 Single Source of Truth: 초기화 성공 시 상태 확실히 설정
              _useMockCamera = false;
              _initErrorMessage = null;
              _nativeInit = true; // 🔥 네이티브 초기화 성공 플래그
              _isReady = true; // 🔥 카메라 준비 완료 플래그
              // 🔥 배터리/발열 최적화: ValueNotifier 업데이트
              useMockCameraNotifier.value = false;
              isInitializedNotifier.value = true;
              _setState(CameraState.ready);
            } else {
              throw Exception(
                'Camera initialized but not ready (isInitialized=false).',
              );
            }
          }
        } on StateError catch (e) {
          // 🔄 리팩토링: iOS에서는 viewId가 필요 없으므로, StateError는 다른 프로그래밍 버그일 수 있음
          //             iOS에서는 viewId 관련 StateError가 발생하지 않아야 함
          final errorStateMsg = StringBuffer()
            ..write('[CameraEngine] ❌ INIT FAILED (Programming Error): ')
            ..write('error=$e');
          debugPrint(errorStateMsg.toString());

          // iOS/Android 공통: 프로그래밍 버그는 Mock으로 전환하지 않고 그대로 에러 처리
          _isInitializing = false;
          _nativeCamera = null;
          _setState(CameraState.error, errorMessage: e.toString());
          _notifyListeners();
          rethrow;
        } on PlatformException catch (e) {
          // 🔥 플랫폼 예외: 에러 코드로 진짜 카메라 불가능 상황만 선별
          final int? errorViewId = _nativeCamera is NativeCameraController
              ? (_nativeCamera as NativeCameraController).viewId
              : null;

          final errorStateMsg = StringBuffer()
            ..write('[CameraEngine] ❌ INIT FAILED (PlatformException): ')
            ..write('code=${e.code}, ')
            ..write('message=${e.message}, ')
            ..write('viewId=$errorViewId');
          debugPrint(errorStateMsg.toString());

          // 진짜 카메라 불가능 상황만 mock으로 fallback
          // ⚠️ "operation in progress"는 카메라가 없어서가 아니라 작업 진행 중이므로 Mock으로 전환하지 않음
          final String? msg = e.message?.toLowerCase();
          final bool isOperationInProgress =
              msg?.contains('operation in progress') == true ||
              msg?.contains('isrunningoperationinprogress') == true;

          // iOS 실기기 vs 시뮬레이터 구분
          bool isIOS = Platform.isIOS;
          bool isSimulator = false;
          if (isIOS && _nativeCamera is NativeCameraController) {
            try {
              isSimulator = await (_nativeCamera as NativeCameraController)
                  .isSimulator();
            } catch (_) {
              isSimulator = false;
            }
          }

          final bool isRealCameraUnavailable =
              !isOperationInProgress &&
              (e.code == 'NO_CAMERA_DEVICE' ||
                  e.code == 'PERMISSION_DENIED' ||
                  (e.code == 'INIT_FAILED' &&
                      (msg?.contains('permission') == true ||
                          msg?.contains('device') == true ||
                          msg?.contains('no camera') == true ||
                          msg?.contains('simulator') == true ||
                          msg?.contains('hardware unavailable') == true)) ||
                  e.code == 'INIT_TIMEOUT' ||
                  (msg?.contains('permission') == true ||
                      msg?.contains('device') == true ||
                      msg?.contains('no camera') == true ||
                      msg?.contains('simulator') == true ||
                      msg?.contains('timeout') == true ||
                      msg?.contains('hardware unavailable') == true));

          final bool allowMockFallback =
              (!isIOS && isRealCameraUnavailable) ||
              (isIOS && isSimulator && isRealCameraUnavailable);

          if (allowMockFallback) {
            // 진짜 카메라 불가능 → Mock으로 fallback (단, iOS에서는 시뮬레이터에서만)
            _nativeCamera = null;
            _useMockCamera = true;
            _initErrorMessage =
                'Native camera unavailable, using mock: ${e.message ?? e.code}';
            // 🔥 배터리/발열 최적화: ValueNotifier 업데이트
            useMockCameraNotifier.value = true;
            isInitializedNotifier.value = false;
            _setState(CameraState.ready); // Mock 카메라는 ready 상태
            _isInitializing = false; // 🔥 초기화 완료 처리
            _notifyListeners(); // 🔥 상태 변경 알림
            return;
          } else {
            _isInitializing = false;
            _nativeCamera = null;
            _setState(CameraState.error, errorMessage: e.toString());
            _notifyListeners();
            rethrow;
          }
        } catch (e) {
          // 🔥 일반 예외: 메시지로 판단하여 mock fallback 여부 결정
          final int? errorViewId = _nativeCamera is NativeCameraController
              ? (_nativeCamera as NativeCameraController).viewId
              : null;

          final errorStateMsg = StringBuffer()
            ..write('[CameraEngine] ❌ INIT FAILED (General Exception): ')
            ..write('error=$e, ')
            ..write('type=${e.runtimeType}, ')
            ..write('viewId=$errorViewId');
          debugPrint(errorStateMsg.toString());

          // 에러 메시지로 진짜 카메라 불가능 상황 판단
          final String errorStr = e.toString().toLowerCase();
          // ⚠️ "operation in progress"는 카메라가 없어서가 아니라 작업 진행 중이므로 Mock으로 전환하지 않음
          final bool isOperationInProgress =
              errorStr.contains('operation in progress') ||
              errorStr.contains('isrunningoperationinprogress');

          bool isIOS = Platform.isIOS;
          bool isSimulator = false;
          if (isIOS && _nativeCamera is NativeCameraController) {
            try {
              isSimulator = await (_nativeCamera as NativeCameraController)
                  .isSimulator();
            } catch (_) {
              isSimulator = false;
            }
          }

          final bool isRealCameraUnavailable =
              !isOperationInProgress &&
              (errorStr.contains('permission denied') ||
                  errorStr.contains('no camera device') ||
                  errorStr.contains('camera not found') ||
                  errorStr.contains('camera unavailable') ||
                  errorStr.contains('simulator') ||
                  errorStr.contains('timeout') ||
                  errorStr.contains('hardware unavailable') ||
                  (errorStr.contains('initialized but not ready') &&
                      (errorStr.contains('permission') ||
                          errorStr.contains('device'))));

          // "ViewId not set" 같은 프로그래밍 버그는 mock으로 돌리지 않음
          final bool isProgrammingError =
              errorStr.contains('viewid not set') ||
              errorStr.contains('viewid is null') ||
              errorStr.contains('programming error');

          if (isProgrammingError) {
            _isInitializing = false;
            _nativeCamera = null;
            _notifyListeners();
            rethrow;
          } else if ((!isIOS && isRealCameraUnavailable) ||
              (isIOS && isSimulator && isRealCameraUnavailable)) {
            _nativeCamera = null;
            _useMockCamera = true;
            _initErrorMessage =
                'Native camera unavailable, using mock: ${e.toString()}';
            // 🔥 배터리/발열 최적화: ValueNotifier 업데이트
            useMockCameraNotifier.value = true;
            isInitializedNotifier.value = false;
            _setState(CameraState.ready); // Mock 카메라는 ready 상태
          } else {
            _isInitializing = false;
            _nativeCamera = null;
            _notifyListeners();
            rethrow;
          }
        }
      } else {
        // Android는 추후 구현
        throw UnimplementedError('Android camera not implemented');
      }
    } catch (e) {
      _initErrorMessage = e.toString();

      // 🔥 최종 예외: iOS 실기기에서는 Mock으로 도망가지 않고 에러 상태로 유지
      final bool isIOS = Platform.isIOS;
      bool isSimulator = false;
      if (isIOS && _nativeCamera is NativeCameraController) {
        try {
          isSimulator = await (_nativeCamera as NativeCameraController)
              .isSimulator();
        } catch (_) {
          isSimulator = false;
        }
      }

      if (!isIOS || (isIOS && isSimulator)) {
        // Android 또는 iOS 시뮬레이터에서는 Mock fallback 허용
        _useMockCamera = true;
        _nativeCamera = null;
        useMockCameraNotifier.value = true;
        isInitializedNotifier.value = false;
      } else {
        // iOS 실기기: 에러 상태로 유지 (사용자에게 재시작 안내 등)
        _useMockCamera = false;
        useMockCameraNotifier.value = false;
        isInitializedNotifier.value = false;
        _setState(CameraState.error, errorMessage: _initErrorMessage);
      }
    } finally {
      _isInitializing = false;
      _notifyListeners();
    }
  }

  /// 카메라 해제
  Future<void> dispose() async {
    // 🔥 EventChannel 리스너 정리
    await _cameraStateSubscription?.cancel();
    _cameraStateSubscription = null;

    if (_nativeCamera != null) {
      await _nativeCamera!.dispose();
      _nativeCamera = null;
    }
    // 🔥 실제 dispose 시점에만 플래그/캐시를 리셋
    _nativeInit = false;
    _isReady = false;
    _lastDebugState = null;
    _sessionRunning = null;
    _videoConnected = null;
    _hasFirstFrame = null;
    _isPinkFallback = null;
    _currentAspectRatio = null;
    _viewId = null;
    _isInitializing = false;
    _useMockCamera = false;
    _initErrorMessage = null;
    // 🔥 배터리/발열 최적화: ValueNotifier 초기화
    stateNotifier.value = CameraState.idle;
    isInitializedNotifier.value = false;
    useMockCameraNotifier.value = false;
    _listeners.clear();
    // 🔥 전면 재설계: 실제 dispose 시에만 한 번 초기화 플래그 리셋
    _hasInitializedOnce = false;
    _emitDebugLog(
      '[Dispose] ✅ Camera engine disposed, one-time init flag reset',
    );
    _notifyListeners();
  }

  /// 카메라 전환
  /// 반환: 실제 설정된 줌 값 등 카메라 정보
  Future<Map<String, dynamic>?> switchCamera() async {
    if (_nativeCamera == null) return null;
    final result = await _nativeCamera!.switchCamera();
    _notifyListeners();
    return result;
  }

  /// 줌 설정
  /// 🔥 줌 범위 확장: 0.5 ~ 10.0 (3배 이상 줌 데드존 제거)
  /// 🔥🔥🔥 반환값: 네이티브에서 실제 설정된 줌 값 (동기화용)
  Future<double?> setZoom(double zoom) async {
    if (_nativeCamera == null) return null;
    if (_nativeCamera is! NativeCameraController) return null;

    // 🔥 UI에서 전달된 zoom(0.5~10.0)을 네이티브에 그대로 전달
    // 네이티브에서 디바이스별 min/maxZoomFactor를 확인하여 최종 clamp 수행
    // Flutter 레벨에서는 최소한의 범위 체크만 수행
    final clamped = zoom.clamp(0.5, 10.0);

    // 🔥🔥🔥 setZoomAndGetActual 사용: 한 번의 호출로 setZoom + actualZoom 반환 (중복 호출 방지)
    final actualZoom = await (_nativeCamera as NativeCameraController)
        .setZoomAndGetActual(clamped);

    if (kDebugMode) {
      if (actualZoom != null && (actualZoom - clamped).abs() > 0.01) {
        debugPrint(
          '[CameraEngine] 🔄 setZoom: ui=$zoom → clamped=$clamped → actual=$actualZoom',
        );
      } else if (clamped != zoom) {
        debugPrint(
          '[CameraEngine] 🔍 setZoom: ui=$zoom → clamped=$clamped (sent to native, range: 0.5~10.0)',
        );
      }
    }

    return actualZoom;
  }

  /// 핀치 제스처용 빠른 줌 적용 (actualZoom 동기화 없이 즉시 반영)
  Future<void> setZoomFast(double zoom) async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;

    final clamped = zoom.clamp(0.5, 10.0);
    await (_nativeCamera as NativeCameraController).setZoom(clamped);
  }

  /// 포커스 포인트 설정
  Future<void> setFocusPoint(Offset normalized) async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;
    await (_nativeCamera as NativeCameraController).setFocusPoint(normalized);
  }

  Future<void> setContinuousAutoFocus(bool enabled) async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;
    await (_nativeCamera as NativeCameraController).setContinuousAutoFocus(
      enabled,
    );
  }

  /// 노출 포인트 설정
  Future<void> setExposurePoint(Offset normalized) async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;
    await (_nativeCamera as NativeCameraController).setExposurePoint(
      normalized,
    );
  }

  /// 노출 바이어스 설정
  Future<void> setExposureBias(double normalized) async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;
    await (_nativeCamera as NativeCameraController).setExposureBias(normalized);
  }

  /// 필터 설정
  Future<void> setFilter({
    required String filterKey,
    required double intensity,
  }) async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;
    await (_nativeCamera as NativeCameraController).setFilter(
      filterKey: filterKey,
      intensity: intensity,
    );
  }

  /// 플래시 모드 설정
  Future<void> setFlashMode(String mode) async {
    if (_nativeCamera == null) return;
    await _nativeCamera!.setFlashMode(mode);
  }

  /// Mock 이미지 파일 생성 (assets/images/mockup.png에서)
  Future<File> _createMockImage({required double aspectRatio}) async {
    try {
      // Asset에서 이미지 로드
      final ByteData data = await rootBundle.load('assets/images/mockup.png');
      final Uint8List bytes = data.buffer.asUint8List();

      // 🔥 저장 파이프라인 해상도 검증: Mock 이미지 asset 해상도 확인
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage != null && kDebugMode) {
        debugPrint(
          '[CameraEngine] 🎭 Mock asset image: ${decodedImage.width}x${decodedImage.height} pixels',
        );
        final minDimension = 2560; // 2K 해상도
        if (decodedImage.width < minDimension ||
            decodedImage.height < minDimension) {
          debugPrint(
            '[CameraEngine] ⚠️ WARNING: Mock asset resolution below 2K: '
            '${decodedImage.width}x${decodedImage.height} (min=$minDimension px)',
          );
        }
      }

      // 임시 디렉토리에 저장
      final dir = await getTemporaryDirectory();
      final fileName =
          'PG_MOCK_${DateTime.now().millisecondsSinceEpoch}_${aspectRatio.toStringAsFixed(3)}.jpg';
      final file = File('${dir.path}/$fileName');

      await file.writeAsBytes(bytes);

      if (kDebugMode) {
        debugPrint('[CameraEngine] 🎭 Mock image created: ${file.path}');
      }

      return file;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CameraEngine] ❌ Failed to create mock image: $e');
      }
      rethrow;
    }
  }

  /// 사진 촬영
  Future<String> takePicture({
    String? filterKey,
    double? filterIntensity,
    double? brightness,
    bool? enableFrame,
    Map<String, dynamic>? frameMeta,
    double? aspectRatio,
  }) async {
    // 🔥 크래시 방지: 이미 촬영 중이면 차단
    if (_isCapturingPhoto) {
      throw StateError('Photo capture already in progress');
    }
    _isCapturingPhoto = true;
    _emitDebugLog('[Photo] isCapturingPhoto=true START');
    _emitDebugLog(
      '[CameraEngine] 🔒 isCapturingPhoto = true (takePicture started)',
    );

    // 🔒 촬영 보호 펜스 시작: 짧은 구간만 보호 (복귀 지연 최소화)
    final captureStart = DateTime.now();
    _captureFenceUntil = captureStart.add(const Duration(milliseconds: 1200));
    _emitDebugLog('[Photo] 🚧 capture fence set until $_captureFenceUntil');

    // 🔥 Mock 카메라 모드: getDebugState() 호출 전에 확인하여 null 오류 방지
    // Mock 카메라 모드에서는 _nativeCamera가 null일 수 있으므로 getDebugState()를 호출하지 않음
    // 🔥🔥🔥 iOS 시뮬레이터 지원: _nativeCamera가 없으면 항상 Mock 경로로 처리
    final bool useMockNow = _useMockCamera || _nativeCamera == null;
    if (useMockNow) {
      // Mock 카메라 모드에서는 네이티브 상태 확인 없이 바로 진행
      _emitDebugLog(
        '[CameraEngine] 🎭 Mock camera mode: skipping debugState check',
      );
    } else {
      // 🔥 핵심 수정: 세션 상태 확인 (강화된 방어 로직)
      // 🔥 Single Source of Truth: 네이티브 상태만 확인 (Flutter 내부 플래그 무시)
      final debugState = await getDebugState();
      if (debugState == null) {
        final error = 'Camera not initialized (debugState is null)';
        _emitDebugLog('[CameraEngine] ❌ $error');
        throw StateError(error);
      }

      final sessionRunning = debugState['sessionRunning'] as bool? ?? false;
      final videoConnected = debugState['videoConnected'] as bool? ?? false;
      final hasFirstFrame = debugState['hasFirstFrame'] as bool? ?? false;
      final isPinkFallback = debugState['isPinkFallback'] as bool? ?? false;

      // 🔥 핵심 수정: 세션이 정상 실행 중이고 프레임을 받고 있으면 촬영 허용
      // isPinkFallback이 일시적으로 true여도, 세션이 정상이면 촬영 진행
      final isSessionHealthy =
          sessionRunning && videoConnected && hasFirstFrame;

      if (!isSessionHealthy && !isPinkFallback) {
        // 세션이 일시적으로 false로 떨어지는 구간(네이티브 auto-restart 직후)을 흡수
        if (!sessionRunning && videoConnected && hasFirstFrame) {
          _emitDebugLog(
            '[CameraEngine] ⏳ Transient session drop detected before capture; attempting short recovery...',
          );
          try {
            await resume();
          } catch (_) {
            // resume 실패는 아래 재확인으로 최종 판단
          }
          await Future.delayed(const Duration(milliseconds: 350));
          final retryState = await getDebugState();
          final retrySessionRunning =
              retryState?['sessionRunning'] as bool? ?? false;
          final retryVideoConnected =
              retryState?['videoConnected'] as bool? ?? false;
          final retryHasFirstFrame =
              retryState?['hasFirstFrame'] as bool? ?? false;
          final recovered =
              retrySessionRunning && retryVideoConnected && retryHasFirstFrame;
          if (!recovered) {
            final error =
                'Camera session not ready for capture: sessionRunning=$retrySessionRunning, videoConnected=$retryVideoConnected, hasFirstFrame=$retryHasFirstFrame, isPinkFallback=${retryState?['isPinkFallback'] as bool? ?? false}';
            _emitDebugLog('[CameraEngine] ❌ $error');
            throw StateError(error);
          }
          _emitDebugLog(
            '[CameraEngine] ✅ Session recovered after transient drop; proceeding with capture',
          );
        } else {
          // 세션이 정상이 아니고 핑크 fallback도 아니면 에러
          final error =
              'Camera session not ready for capture: sessionRunning=$sessionRunning, videoConnected=$videoConnected, hasFirstFrame=$hasFirstFrame, isPinkFallback=$isPinkFallback';
          _emitDebugLog('[CameraEngine] ❌ $error');
          throw StateError(error);
        }
      }

      // 🔥 핑크 fallback이지만 세션이 정상이면 촬영 허용 (네이티브에서 동일 로직)
      if (isPinkFallback && !isSessionHealthy) {
        final error =
            'Camera preview is in fallback state (pink screen). Please wait for camera to initialize.';
        _emitDebugLog('[CameraEngine] ❌ $error');
        throw StateError(error);
      }
    }

    // 🔥 크래시 디버깅: takePicture 진입 로그
    final engineDebugInfo = StringBuffer()
      ..write('[CameraEngine] 📸 takePicture ENTRY: ')
      ..write('useMockCamera=$_useMockCamera, ')
      ..write('nativeCamera=${_nativeCamera != null ? "exists" : "null"}, ')
      ..write('isInitialized=$isInitialized, ')
      ..write('isInitializing=$_isInitializing, ')
      ..write('filterKey=$filterKey, ')
      ..write('filterIntensity=$filterIntensity, ')
      ..write('enableFrame=$enableFrame, ')
      ..write('aspectRatio=$aspectRatio');

    if (kDebugMode) {
      debugPrint(engineDebugInfo.toString());
    }
    _emitDebugLog(engineDebugInfo.toString());

    try {
      // Mock 카메라 모드: Mock 이미지 파일 생성
      // 🔥 iOS 시뮬레이터 지원: useMockNow=true이면 항상 Mock 경로로 처리
      if (useMockNow) {
        if (kDebugMode) {
          debugPrint('[CameraEngine] 🎭 Taking picture with MOCK camera');
        }
        _emitDebugLog('[CameraEngine] 🎭 Using MOCK camera');
        final mockFile = await _createMockImage(
          aspectRatio: aspectRatio ?? 1.0,
        );
        _emitDebugLog('[CameraEngine] ✅ MOCK image created: ${mockFile.path}');
        return mockFile.path;
      }

      // 네이티브 카메라 모드
      if (_nativeCamera == null) {
        final error = 'Native camera not initialized';
        _emitDebugLog('[CameraEngine] ❌ $error');
        throw Exception(error);
      }

      // 🔥 크래시 디버깅: 네이티브 takePicture 호출 전 로그
      _emitDebugLog('[CameraEngine] 📸 Calling nativeCamera.takePicture()...');
      final result = await _nativeCamera!.takePicture(
        filterKey: filterKey,
        filterIntensity: filterIntensity,
        brightness: brightness,
        enableFrame: enableFrame,
        frameMeta: frameMeta,
        aspectRatio: aspectRatio,
      );
      _emitDebugLog('[CameraEngine] ✅ Native takePicture success: $result');
      return result;
    } catch (e, stackTrace) {
      // 🔥 크래시 디버깅: 네이티브 takePicture 실패 상세 로그
      final errorLog = StringBuffer()
        ..write('[CameraEngine] ❌ Native takePicture FAILED: ')
        ..write('error=$e, ')
        ..write('errorType=${e.runtimeType}');
      _emitDebugLog(errorLog.toString());
      if (kDebugMode) {
        debugPrint('[CameraEngine] ❌ Native error: $e');
        debugPrint('[CameraEngine] ❌ Stack: $stackTrace');
      }
      _emitDebugLog(
        '[CameraEngine] ❌ Stack: ${stackTrace.toString().substring(0, stackTrace.toString().length > 500 ? 500 : stackTrace.toString().length)}',
      );
      rethrow;
    } finally {
      // 🔥 핵심 수정: finally 블록에서 항상 플래그 리셋 (예외 발생 시에도 보장)
      _isCapturingPhoto = false;
      // 촬영 종료 시점에는 펜스를 즉시 해제해 페이지 복귀 resume 지연을 방지
      _captureFenceUntil = null;
      _emitDebugLog('[Photo] isCapturingPhoto=false END');
      _emitDebugLog(
        '[CameraEngine] 🔓 isCapturingPhoto = false (takePicture completed/failed)',
      );
      // 🔥🔥🔥 연속 촬영 문제 디버깅: debugPrint로 항상 출력하여 리셋 확인
      if (kDebugMode) {
        debugPrint(
          '[CameraEngine] 🔓🔓🔓 isCapturingPhoto RESET to false in finally block',
        );
      }
    }
  }

  /// 디버그 상태 가져오기
  /// 🔥 네이티브 세션 상태를 가져와서 내부 상태도 업데이트
  /// 🔥 Single Source of Truth: 네이티브 상태를 받아서 Flutter 상태를 덮어씀
  /// Flutter는 절대 자체적으로 상태를 계산하지 않고, 네이티브 값만 사용
  /// 🔥 Single Source of Truth: CameraDebugState 기반으로 상태 통일

  // 🔥 타입 보정용 헬퍼 (getDebugState에서 사용)
  static bool _toBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.toLowerCase() == 'true';
    return v == true;
  }

  Future<Map<String, dynamic>?> getDebugState() async {
    if (_nativeCamera == null || _nativeCamera is! NativeCameraController) {
      // 실제 dispose가 아닌 이상 플래그를 건드리지 않고 마지막 상태를 그대로 반환
      if (_lastDebugState != null) {
        return {
          'viewId': _lastDebugState!.viewId,
          'sessionRunning': _lastDebugState!.sessionRunning,
          'videoConnected': _lastDebugState!.videoConnected,
          'hasFirstFrame': _lastDebugState!.hasFirstFrame,
          'isPinkFallback': _lastDebugState!.isPinkFallback,
          'instancePtr': _lastDebugState!.instancePtr,
          'nativeInit': _nativeInit ?? false,
          'isReady': _isReady ?? false,
        };
      }
      return null;
    }
    final rawDebugState = await (_nativeCamera as NativeCameraController)
        .getDebugState();

    // 🔥 로그 빈도 대폭 감소: getDebugState()는 매우 자주 호출되므로 로그 최소화
    // 디버그 오버레이가 버벅거리지 않도록 로그 제거
    // 🔥 타입 변환 문제 해결: Swift Bool이 NSNumber로 변환될 수 있으므로 더 견고하게 처리
    final rawHasFirstFrameValue = rawDebugState['hasFirstFrame'];
    final rawHasFirstFrame = _toBool(rawHasFirstFrameValue);
    final rawSessionRunningValue = rawDebugState['sessionRunning'];
    final rawSessionRunning = _toBool(rawSessionRunningValue);
    final rawVideoConnectedValue = rawDebugState['videoConnected'];
    final rawVideoConnected = _toBool(rawVideoConnectedValue);
    final rawSampleBufferCount =
        rawDebugState['sampleBufferCount'] as int? ?? 0;

    // 🔥🔥🔥 근본 해결: sampleBufferCount > 0이면 무조건 hasFirstFrame=true로 강제 설정
    // 네이티브에서 이미 처리했지만, Flutter에서도 이중 체크하여 확실히 보장
    // 🔥🔥🔥 핵심: sampleBufferCount > 0이면 무조건 true (프레임을 받고 있다는 확실한 증거)
    // sessionRunning && videoConnected 조건은 추가 검증용이지만, sampleBufferCount > 0이면 무조건 true
    final finalHasFirstFrame = rawSampleBufferCount > 0
        ? true // 🔥🔥🔥 근본 해결: sampleBufferCount > 0이면 무조건 true
        : (rawHasFirstFrame ||
              (rawSampleBufferCount > 0 &&
                  rawSessionRunning &&
                  rawVideoConnected));

    // 🔥 로그 제거: getDebugState()는 매우 자주 호출되므로 로그 최소화
    // 에러 상황에서만 로그 출력
    if (rawSampleBufferCount == 0 && rawSessionRunning && rawVideoConnected) {
      // 에러 상황만 로그 (빈도 낮음)
      _emitDebugLog(
        '[CameraEngine] ⚠️ CRITICAL: sampleBufferCount=0 but sessionRunning=true && videoConnected=true!',
      );
    }

    // 🔥 Single Source of Truth: CameraDebugState로 파싱
    // 🔥🔥🔥 근본 해결: finalHasFirstFrame을 사용하여 강제 수정 반영
    // sampleBufferCount > 0이면 무조건 hasFirstFrame=true로 설정
    final rawDebugStateFixed = Map<String, dynamic>.from(rawDebugState);
    // 🔥🔥🔥 근본 해결: sampleBufferCount > 0이면 무조건 hasFirstFrame=true로 설정 (원본 값과 무관하게)
    if (rawSampleBufferCount > 0) {
      rawDebugStateFixed['hasFirstFrame'] = true;
      if (!rawHasFirstFrame) {
        _emitDebugLog(
          '[CameraEngine] 🔥🔥🔥 FORCED: sampleBufferCount=$rawSampleBufferCount > 0, hasFirstFrame forced to true in state dict',
        );
      }
    } else if (finalHasFirstFrame != rawHasFirstFrame) {
      rawDebugStateFixed['hasFirstFrame'] = finalHasFirstFrame;
    }

    // 🔥🔥🔥 TASK 4: sessionRunning && videoConnected && hasFirstFrame이면 강제로 isPinkFallback=false, nativeInit=true, isReady=true 설정
    if (rawSessionRunning && rawVideoConnected && finalHasFirstFrame) {
      // 강제 동기화: 카메라가 정상 작동 중이면 상태 강제 설정
      rawDebugStateFixed['isPinkFallback'] = false;
      rawDebugStateFixed['nativeInit'] = true;
      rawDebugStateFixed['isReady'] = true;

      _emitDebugLog(
        '[CameraEngine] 🔥 FORCE SYNC: sessionRunning=true && videoConnected=true && hasFirstFrame=true → isPinkFallback=false, nativeInit=true, isReady=true',
      );

      // 내부 상태도 즉시 업데이트
      _nativeInit = true;
      _isReady = true;
    }

    final debugState = CameraDebugState.fromMap(rawDebugStateFixed);

    // 🔥🔥🔥 핵심: _lastDebugState를 먼저 업데이트하여 canUseCamera가 최신 값을 읽을 수 있도록 함
    _lastDebugState = debugState;

    // 🔥 즉시 _hasFirstFrame도 업데이트 (canUseCamera에서 사용)
    _hasFirstFrame = debugState.hasFirstFrame;

    // 🔥🔥🔥 핵심: 파싱 후 CameraDebugState 값 로그 (디버그 오버레이에 전송)
    _emitDebugLog(
      '[CameraEngine] 🔥 CameraDebugState PARSED: hasFirstFrame=${debugState.hasFirstFrame}, sessionRunning=${debugState.sessionRunning}, videoConnected=${debugState.videoConnected}',
    );

    // 🔥 viewId와 instancePtr mismatch 체크
    final flutterViewId = _viewId;
    final nativeInstancePtr = rawDebugState['instancePtr'] as String?;

    // 🔥 instancePtr 검증: 비어있으면 경고
    if (nativeInstancePtr == null || nativeInstancePtr.isEmpty) {
      _emitDebugLog(
        '[CameraDebug][WARN] instancePtr is empty or null: flutterViewId=$flutterViewId, nativeViewId=${debugState.viewId}',
      );
    }

    // 🔥 viewId mismatch 체크 (viewId = -1은 초기화 전 상태이므로 제외)
    if (flutterViewId != null &&
        debugState.viewId >= 0 &&
        debugState.viewId != flutterViewId) {
      _emitDebugLog(
        '[CameraDebug][WARN] viewId mismatch: flutterViewId=$flutterViewId, nativeViewId=${debugState.viewId}, instancePtr=$nativeInstancePtr',
      );
    }

    // 🔥 핵심 수정: nativeHealthy를 먼저 체크하여 _nativeInit과 _isReady를 설정
    //              이렇게 하면 rawDebugState의 값이 덮어쓰지 않음
    final bool nativeHealthy =
        debugState.sessionRunning &&
        debugState.videoConnected &&
        debugState.hasFirstFrame &&
        !debugState.isPinkFallback;

    if (nativeHealthy) {
      // 🔥 네이티브 상태가 완전히 정상일 때 에러/준비 플래그 자동 복원
      _nativeInit = true;
      _isReady = true;
      _initErrorMessage = null;
      _setState(CameraState.ready);
      _isInitializing = false;
      isInitializedNotifier.value = _nativeCamera?.isInitialized ?? true;
      _emitDebugLog(
        '[CameraDebug] ✅ Native healthy → cleared error state (nativeInit=true, isReady=true)',
      );
    } else {
      // 🔥 호환성 유지: 기존 필드도 업데이트 (deprecated)
      final rawNativeInit = rawDebugState['nativeInit'] as bool?;
      final rawIsReady = rawDebugState['isReady'] as bool?;

      // 🔥 핵심 수정: rawNativeInit이 true이면 무조건 반영 (hasFirstFrame과 무관)
      // 세션이 실행 중이면 videoDevice/videoInput이 존재한다는 의미
      if (rawNativeInit == true) {
        _nativeInit = true;
      } else if (_nativeInit == true) {
        // 이미 초기화 성공했으면 네이티브 값으로 덮어쓰지 않음
      } else {
        // 초기화 전이면 네이티브 값 사용
        _nativeInit = rawNativeInit;
      }

      if (_isReady == true) {
        // 이미 준비 완료했으면 네이티브 값으로 덮어쓰지 않음
      } else {
        // 준비 전이면 네이티브 값 사용
        _isReady = rawIsReady;
      }
    }

    _sessionRunning = debugState.sessionRunning;
    _videoConnected = debugState.videoConnected;
    _hasFirstFrame = debugState.hasFirstFrame;
    _isPinkFallback = debugState.isPinkFallback;
    _currentAspectRatio = (rawDebugState['currentAspectRatio'] as num?)
        ?.toDouble();

    // 🔥 viewId = -1이면 Flutter의 _viewId를 덮어쓰지 않음
    if (debugState.viewId >= 0) {
      _viewId = debugState.viewId;
    }

    // 🔥 핵심 수정: 반환 맵에 최신 _nativeInit, _isReady, _hasFirstFrame 값 반영
    // takePicture()에서 이 맵을 읽어오므로 최신 값이 반드시 포함되어야 함
    final updatedDebugState = Map<String, dynamic>.from(rawDebugState);
    updatedDebugState['nativeInit'] = _nativeInit ?? false;
    updatedDebugState['isReady'] = _isReady ?? false;
    // 🔥🔥🔥 핵심: _hasFirstFrame도 반환 맵에 반영 (canUseCamera에서 사용)
    updatedDebugState['hasFirstFrame'] =
        _hasFirstFrame ?? debugState.hasFirstFrame;

    _notifyListeners();
    return updatedDebugState;
  }

  /// 디버그 로그 리스너 추가
  void addDebugLogListener(Function(String) listener) {
    if (!_debugLogListeners.contains(listener)) {
      _debugLogListeners.add(listener);
    }
    // NativeCameraController에도 전달
    if (_nativeCamera is NativeCameraController) {
      (_nativeCamera as NativeCameraController).addDebugLogListener(listener);
    }
  }

  /// 디버그 로그 리스너 제거
  void removeDebugLogListener(Function(String) listener) {
    _debugLogListeners.remove(listener);
    // NativeCameraController에서도 제거
    if (_nativeCamera is NativeCameraController) {
      (_nativeCamera as NativeCameraController).removeDebugLogListener(
        listener,
      );
    }
  }

  /// 🔥 디버그 로그 전송 (디버그 오버레이 표시용)
  /// HomePage의 _addDebugLog()로 전달되어 디버그 오버레이에 표시됩니다.
  void _emitDebugLog(String message) {
    // ⚠️ 릴리즈 빌드 및 일반적인 상황에서는 로그 출력 안함
    if (!kDebugMode) return;

    // 🔥 중요 로그(📸, ❌, ⚠️)만 출력하거나, 필요할 때만 활성화
    final isCritical =
        message.contains('📸') ||
        message.contains('❌') ||
        message.contains('⚠️');
    if (isCritical) {
      debugPrint(message);
    }

    // 디버그 오버레이 리스너에게는 전달 (오버레이 표시 여부는 HomePage에서 결정)
    for (final listener in _debugLogListeners) {
      try {
        listener(message);
      } catch (e) {
        // ignore
      }
    }
  }

  /// Wide 렌즈로 전환 (가능한 경우)
  Future<Map<String, dynamic>?> switchToWideIfAvailable() async {
    if (_nativeCamera == null) return null;
    if (_nativeCamera is! NativeCameraController) return null;
    return await (_nativeCamera as NativeCameraController)
        .switchToWideIfAvailable();
  }

  /// Ultra Wide 렌즈로 전환 (가능한 경우)
  Future<Map<String, dynamic>?> switchToUltraWideIfAvailable() async {
    if (_nativeCamera == null) return null;
    if (_nativeCamera is! NativeCameraController) return null;
    return await (_nativeCamera as NativeCameraController)
        .switchToUltraWideIfAvailable();
  }

  /// PlatformView ID 설정 (프리뷰 생성 후 호출)
  void setViewId(int viewId) {
    if (_nativeCamera is NativeCameraController) {
      (_nativeCamera as NativeCameraController).setViewId(viewId);
    }
  }

  /// 🔥 성능 최적화: 카메라 세션 일시 중지 (배터리/발열 감소)
  /// 홈 화면이 아닐 때 또는 앱이 백그라운드로 갈 때 호출
  Future<void> pause() async {
    if (_nativeCamera == null) return;
    if (_nativeCamera is! NativeCameraController) return;
    try {
      await (_nativeCamera as NativeCameraController).pauseSession();
      // pause 직후에는 stale 상태(canUseCamera=true)가 남지 않도록 즉시 not-ready로 동기화
      _sessionRunning = false;
      _videoConnected = false;
      _hasFirstFrame = false;
      _isReady = false;
      if (_lastDebugState != null) {
        _lastDebugState = CameraDebugState(
          viewId: _lastDebugState!.viewId,
          sessionRunning: false,
          videoConnected: false,
          hasFirstFrame: false,
          isPinkFallback: _lastDebugState!.isPinkFallback,
          instancePtr: _lastDebugState!.instancePtr,
        );
      }
      _notifyListeners();
      if (kDebugMode) {
        debugPrint('[CameraEngine] ⏸️ Camera session paused');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CameraEngine] ❌ Failed to pause session: $e');
      }
    }
  }

  /// 🔥 성능 최적화: 카메라 세션 재개
  /// 홈 화면으로 돌아올 때 또는 앱이 포그라운드로 올 때 호출
  Future<void> resume() async {
    // 중복 resume 호출은 같은 Future를 공유
    if (_resumeInFlight != null) {
      if (kDebugMode) {
        debugPrint('[CameraEngine] ⏸️ Resume already in flight, joining...');
      }
      await _resumeInFlight;
      return;
    }

    // 너무 짧은 간격의 resume 스파이크 방지
    final now = DateTime.now();
    if (_lastResumeRequestedAt != null &&
        now.difference(_lastResumeRequestedAt!).inMilliseconds < 700) {
      if (kDebugMode) {
        debugPrint('[CameraEngine] ⏸️ Resume throttled (<700ms)');
      }
      return;
    }
    _lastResumeRequestedAt = now;

    _resumeInFlight = _resumeInternal();
    try {
      await _resumeInFlight;
    } finally {
      _resumeInFlight = null;
    }
  }

  Future<void> _resumeInternal() async {
    // 🔥 핵심 수정: 중복 호출 방지
    if (_isResuming) {
      if (kDebugMode) {
        debugPrint(
          '[CameraEngine] ⏸️ Resume already in progress, skipping duplicate call',
        );
      }
      return;
    }

    // 촬영 중에는 resume를 지연한다. (촬영 후에는 즉시 복귀 가능해야 하므로 fence 대기는 하지 않음)
    if (_isCapturingPhoto) {
      // 촬영 완료까지 대기 (최대 2초)
      int retryCount = 0;
      const maxRetries = 20; // 20 * 100ms = 2초
      while (_isCapturingPhoto && retryCount < maxRetries) {
        await Future.delayed(const Duration(milliseconds: 100));
        retryCount++;
      }
    }

    // 🔥🔥🔥 백그라운드 복귀 시 처리: 무조건 resumeSession 시도
    // 백그라운드에서 복귀할 때는 세션이 중지되어 있을 가능성이 높으므로
    // 상태 체크를 완화하고 무조건 resumeSession을 시도
    if (_nativeCamera == null) {
      if (kDebugMode) {
        debugPrint('[CameraEngine] ⚠️ Resume skipped: nativeCamera is null');
      }
      return;
    }
    if (_nativeCamera is! NativeCameraController) {
      if (kDebugMode) {
        debugPrint(
          '[CameraEngine] ⚠️ Resume skipped: nativeCamera is not NativeCameraController',
        );
      }
      return;
    }

    // 🔥 플래그 설정 (try 블록 시작 전에 설정)
    _isResuming = true;

    bool isRecoverableResumeError(Object error) {
      final msg = error.toString().toLowerCase();
      return msg.contains('resume_timeout') ||
          msg.contains('resume_not_ready') ||
          msg.contains('timeout');
    }

    try {
      // 🔥🔥🔥 백그라운드 복귀 시 무조건 resumeSession 시도
      await (_nativeCamera as NativeCameraController).resumeSession();

      // 네이티브 resumeSession은 queue 작업을 비동기로 시작하고 즉시 반환할 수 있으므로,
      // 실제 세션 복귀(sessionRunning/videoConnected)까지 대기한다.
      bool sessionRecovered = await _waitForSessionRecovery(
        const Duration(milliseconds: 1200),
      );

      // 1차 실패 시 resumeSession 1회 재시도
      if (!sessionRecovered) {
        if (kDebugMode) {
          debugPrint(
            '[CameraEngine] ⚠️ Resume not recovered in 1.2s, retrying resumeSession once...',
          );
        }
        await (_nativeCamera as NativeCameraController).resumeSession();
        sessionRecovered = await _waitForSessionRecovery(
          const Duration(milliseconds: 1200),
        );
      }

      if (!sessionRecovered) {
        // 응답 타이밍 이슈가 있어도 실제 세션이 살아있으면 성공 처리한다.
        final softRecovered = await _waitForSessionRecovery(
          const Duration(milliseconds: 1500),
        );
        if (!softRecovered) {
          throw StateError('Camera session did not recover after resume/retry');
        }
      }

      // 🔥🔥🔥 핵심 수정: Flutter에서 재초기화를 완전히 제거
      // 네이티브 FSM이 자동으로 복구하므로 Flutter는 resumeSession만 호출하고 기다림
      // 상태 확인을 최소화하여 Flutter-네이티브 동기화 문제 방지
      _isResuming = false; // 플래그 즉시 리셋 (네이티브가 처리하도록)

      if (kDebugMode) {
        debugPrint(
          '[CameraEngine] ✅ Resume called: native FSM will handle recovery automatically',
        );
      }

      // 🔥🔥🔥 네이티브 FSM이 자동으로 복구하므로 Flutter는 기다리기만 함
      // 상태 폴링 타이머가 자동으로 상태를 업데이트하므로 여기서는 아무것도 하지 않음
      return;
    } catch (e) {
      if (isRecoverableResumeError(e)) {
        final recovered = await _waitForSessionRecovery(
          const Duration(milliseconds: 1600),
        );
        if (recovered) {
          _isResuming = false;
          if (kDebugMode) {
            debugPrint(
              '[CameraEngine] ⚠️ resumeSession error ignored after soft recovery: $e',
            );
          }
          return;
        }
      }
      _isResuming = false; // 플래그 리셋
      if (kDebugMode) {
        debugPrint('[CameraEngine] ❌ resumeSession failed: $e');
      }
      // 실패를 상위로 전달해야 호출부가 복구 대기/재시도 UI를 올바르게 제어할 수 있다.
      rethrow;
    }
  }

  Future<bool> _waitForSessionRecovery(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    int consecutiveHealthy = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
      final state = await getDebugState();
      final bool running = (state?['sessionRunning'] as bool?) ?? false;
      final bool connected = (state?['videoConnected'] as bool?) ?? false;
      final bool hasFirstFrame = (state?['hasFirstFrame'] as bool?) ?? false;
      final int sampleBufferCount = (state?['sampleBufferCount'] as int?) ?? 0;
      final bool healthyNow =
          running && connected && (hasFirstFrame || sampleBufferCount > 0);
      if (healthyNow) {
        consecutiveHealthy++;
        if (consecutiveHealthy >= 2) {
          return true;
        }
      } else {
        consecutiveHealthy = 0;
      }
    }
    return false;
  }
}
