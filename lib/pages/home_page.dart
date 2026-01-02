import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, rootBundle, HapticFeedback, PlatformException;
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:gal/gal.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../camera/native_camera_preview.dart';
import '../services/camera_engine.dart';
import '../core/shared_image_pipeline.dart';

import '../models/aspect_ratio_mode.dart';
import '../models/constants.dart';
import '../models/filter_data.dart';
import '../models/filter_models.dart';
import '../models/pet_info.dart';
import '../models/petgram_nav_tab.dart';

import '../services/frame_resource_service.dart';
import '../services/image_pipeline_service.dart';
import '../services/petgram_meta_service.dart';
import '../models/petgram_photo_meta.dart';
import '../models/frame_overlay_config.dart';
import '../services/petgram_photo_repository.dart';

import '../widgets/painters/frame_painter.dart';
import '../widgets/painters/frame_screen_painter.dart';
import '../widgets/petgram_bottom_nav_bar.dart';

import 'frame_settings_page.dart';
import 'settings_page.dart';
import 'filter_page.dart';
import 'diary_page.dart';

/// 🔥 AF 상태 세분화: 실제 초점 상태를 구분
enum _FocusStatus {
  adjusting, // 조정 중 (주황색)
  ready, // 준비됨/초점 잡힘 (초록색)
  locked, // 고정됨 (회색)
  unknown, // 알 수 없음 (회색)
}

/// 펫 얼굴 인식 bounding box 데이터 클래스
class PetFaceBoundingBox {
  final bool hasFace;
  final double x; // 0~1 (Vision 좌표계: origin이 좌하단)
  final double y; // 0~1
  final double width; // 0~1
  final double height; // 0~1
  final double confidence;
  final int? classId; // 15=cat, 16=dog

  const PetFaceBoundingBox({
    required this.hasFace,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
    this.classId,
  });
}

class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomePage({super.key, required this.cameras});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // 카메라 디버그 오버레이 전체 ON/OFF 플래그
  // 🔥 릴리즈 빌드에서도 디버그 오버레이 표시
  static const bool kEnableCameraDebugOverlay = false;
  static const bool kShowFrameDebugInfo = false; // 🔥 프레임 디버그 정보 표시 여부
  
  // 🔥 스플래시 제거 플래그: 한 번만 제거하도록 보장
  bool _hasRemovedSplash = false;

  /// Exposure Bias 범위 상수 (-0.4 ~ +0.4)
  /// 슬라이더는 -10 ~ +10 범위를 사용하지만, 실제 적용은 이 범위로 제한
  static const double kExposureBiasRange = 0.4;

  final ImagePicker _picker = ImagePicker();
  final AudioPlayer _audioPlayer = AudioPlayer(); // 강아지/고양이 사운드용

  // 카메라 엔진 - 모든 카메라 로직을 관리
  late final CameraEngine _cameraEngine;

  // 🔥 카메라 제어용 MethodChannel (FilterPage와 통신)
  // ⚠️ static const가 아닌 인스턴스 변수로 변경 (핸들러 등록을 위해)
  late final MethodChannel _cameraControlChannel;

  // 디버그 로그 저장 (오버레이 표시용)
  final List<String> _debugLogs = [];
  final List<String> _pendingDebugLogs = []; // 🔥 로그 버퍼링용
  Timer? _debugLogTimer; // 🔥 로그 업데이트 타이머
  static const int _maxDebugLogs = 50; // 최대 로그 개수 (크래시 디버깅을 위해 증가)

  // 🔥 크래시 디버깅: 디버그 로그 파일 저장용
  File? _debugLogFile;
  static const String _debugLogFileName = 'petgram_debug_logs.txt';

  // 프리뷰 소스 라벨 (디버그 오버레이 표시용)
  String _previewSourceLabel = 'NONE';

  /// 디버그 로그 추가 (오버레이 표시용)
  /// 릴리즈 빌드에서도 디버그 오버레이가 활성화되어 있으면 표시됨
  /// 🔥 빌드 중 setState 방지: 항상 postFrameCallback으로 지연 실행하여 빌드 중 호출 안전하게 처리
  /// 🔥 크래시 디버깅: 로그를 파일에도 저장하여 앱 재시작 후에도 확인 가능
  /// 🔥 릴리즈 빌드: 파일 저장은 항상 수행 (오버레이 표시는 kEnableCameraDebugOverlay에 따라)
  /// 🔥 CameraEngine._emitDebugLog()에서 전달된 로그도 여기로 들어와 디버그 오버레이에 표시됨
  void _addDebugLog(String log) {
    if (!mounted) return;

    // 🔥 크래시 디버깅: 로그를 파일에 즉시 저장
    _saveDebugLogToFile(log);

    // 오버레이 표시는 디버그 모드에서만
    if (!kEnableCameraDebugOverlay) return;

    // 🔥 무한 로그 방지
    if (_debugLogs.isNotEmpty && _debugLogs.last == log) return;
    if (_pendingDebugLogs.isNotEmpty && _pendingDebugLogs.last == log) return;

    _pendingDebugLogs.add(log);

    // 0.5초마다 UI 업데이트
    _debugLogTimer ??= Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        for (final pendingLog in _pendingDebugLogs) {
          if (_debugLogs.isEmpty || _debugLogs.last != pendingLog) {
            _debugLogs.add(pendingLog);
            if (_debugLogs.length > _maxDebugLogs) {
              _debugLogs.removeAt(0);
            }
          }
        }
        _pendingDebugLogs.clear();
      });
      _debugLogTimer = null;
    });
  }

  /// 🔥 크래시 디버깅: 디버그 로그를 파일에 저장
  /// 🔥 릴리즈 빌드: 파일 저장은 항상 수행 (크래시 디버깅을 위해)
  Future<void> _saveDebugLogToFile(String log) async {
    try {
      if (_debugLogFile == null) {
        final directory = await getApplicationDocumentsDirectory();
        _debugLogFile = File('${directory.path}/$_debugLogFileName');
      }

      // 타임스탬프와 함께 로그 저장
      final timestamp = DateTime.now().toIso8601String();
      final logLine = '[$timestamp] $log\n';

      // 파일에 append (비동기로 실행하여 블로킹 방지)
      await _debugLogFile!.writeAsString(logLine, mode: FileMode.append);
    } catch (e) {
      // 파일 저장 실패는 무시 (디버그 로그이므로)
      // 🔥 릴리즈 빌드: 에러는 print로만 출력 (debugPrint는 릴리즈에서 비활성화)
      print('[Petgram] ⚠️ Failed to save debug log to file: $e');
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ Failed to save debug log to file: $e');
      }
    }
  }

  /// 🔥 크래시 디버깅: 저장된 디버그 로그 파일에서 불러오기
  Future<void> _loadDebugLogsFromFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final logFile = File('${directory.path}/$_debugLogFileName');

      if (await logFile.exists()) {
        String content = '';
        try {
          content = await logFile.readAsString();
        } catch (e) {
          // 🔥 UTF-8 디코딩 에러 발생 시 처리 (깨진 데이터 포함된 경우)
          debugPrint('[Petgram] ⚠️ Debug log file corrupted, clearing: $e');
          await logFile.delete();
          return;
        }

        if (content.isEmpty) return;

        final lines = content
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .toList();

        // 최근 로그만 메모리에 로드 (최대 50개)
        final recentLogs = lines.length > _maxDebugLogs
            ? lines.sublist(lines.length - _maxDebugLogs)
            : lines;

        if (mounted) {
          setState(() {
            _debugLogs.clear();
            _debugLogs.addAll(
              recentLogs.map((line) {
                // 타임스탬프 제거 (이미 저장된 로그는 타임스탬프 포함)
                final match = RegExp(r'^\[.*?\] (.*)$').firstMatch(line);
                return match != null ? match.group(1)! : line;
              }),
            );
          });

          if (kDebugMode && _debugLogs.isNotEmpty) {
            debugPrint(
              '[Petgram] 📂 Loaded ${_debugLogs.length} debug logs from file',
            );
            _addDebugLog('[Petgram] 📂 이전 세션에서 ${_debugLogs.length}개 로그 복원됨');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ Failed to load debug logs from file: $e');
      }
    }
  }

  /// 프리뷰 상태를 한 줄로 로깅 (디버그 오버레이용)
  /// 상태가 변경될 때만 로그 출력 (무한 로그 방지)
  void _logPreviewState(String tag) {
    if (!kDebugMode) return;
    final bool nativeInitialized = _cameraEngine.isInitialized;
    final msg = StringBuffer()
      ..write('[PreviewState@$tag] ')
      ..write('isReady=$_isCameraReady, ')
      ..write('shouldUseMock=$_shouldUseMockCamera, ')
      ..write('useMock=${_cameraEngine.useMockCamera}, ')
      ..write('nativeInit=$nativeInitialized, ')
      ..write('cameras=${widget.cameras.length}, ')
      ..write('previewSource=$_previewSourceLabel, ')
      ..write('isInitializing=${_cameraEngine.isInitializing}, ')
      ..write('isProcessing=$_isProcessing');
    final text = msg.toString();
    // 상태가 변경되었을 때만 로그 출력
    if (kEnableCameraDebugOverlay) {
      debugPrint(text);
    }
    _addDebugLog(text);
  }

  /// 디버그 상태 폴링 시작 (0.5초마다 네이티브 상태 확인)
  void _startDebugStatePolling() {
    _debugStatePollTimer?.cancel();
    // 🔥 디버그 로그 폭주 방지: 폴링 간격을 10초로 증가
    //              상태 업데이트는 필수이지만 로그 폭주를 방지하기 위해 간격 증가
    _debugStatePollTimer = Timer.periodic(const Duration(seconds: 10), (
      _,
    ) {
      _pollDebugState();
    });
  }

  /// 포커스 상태 폴링 시작
  /// 🔥 성능 최적화: AF 인디케이터가 활성화된 경우에만 폴링
  /// 간격: 1초 (500ms → 1초로 증가하여 배터리 절약)
  void _startFocusStatusPolling() {
    _focusStatusPollTimer?.cancel();
    
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🎯 _startFocusStatusPolling: canUseCamera=$canUseCamera, _shouldUseMockCamera=$_shouldUseMockCamera, _isAutoFocusEnabled=$_isAutoFocusEnabled',
      );
    }
    
    if (!canUseCamera || _shouldUseMockCamera) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ Focus status polling skipped: canUseCamera=$canUseCamera, _shouldUseMockCamera=$_shouldUseMockCamera');
      }
      return;
    }

    // 🔥 성능 최적화: AF 인디케이터가 활성화되지 않았으면 폴링 비활성화
    if (!_isAutoFocusEnabled) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ Focus status polling skipped: _isAutoFocusEnabled=false');
      }
      return;
    }

    // 🔥 성능 최적화: 포커스 상태 폴링 간격 증가 (1000ms → 2000ms)
    // 배터리/발열 감소를 위해 2초 간격으로 변경 (기존 기능 유지)
    _focusStatusPollTimer = Timer.periodic(const Duration(milliseconds: 2000), (
      _,
    ) {
      _pollFocusStatus();
    });
    
    // 🔥 즉시 첫 번째 폴링 실행 (상태를 바로 확인)
    _pollFocusStatus();
    
    if (kDebugMode) {
      debugPrint('[Petgram] ✅ Focus status polling started');
    }
  }

  /// 포커스 상태 폴링 중지
  void _stopFocusStatusPolling() {
    _focusStatusPollTimer?.cancel();
    _focusStatusPollTimer = null;
  }

  /// 포커스 상태 확인 (상태 변경 시에만 UI 업데이트, 세분화된 상태 지원)
  Future<void> _pollFocusStatus() async {
    if (!mounted || !canUseCamera || _shouldUseMockCamera) {
      _stopFocusStatusPolling();
      return;
    }

    try {
      // 🔥 성능 최적화: getFocusStatus는 매 초마다 호출되므로 로그 제거
      // if (kDebugMode) { debugPrint('[Petgram] 🎯 _pollFocusStatus: calling getFocusStatus...'); }
      
      final status = await _cameraEngine.nativeCamera?.getFocusStatus();
      
      // 🔥 성능 최적화: 정상적인 폴링 결과 로그 제거 (에러만 로그)
      // if (kDebugMode) { debugPrint('[Petgram] 🎯 Focus status poll result: status=$status'); }
      
      if (status != null) {
        final isAdjusting = status['isAdjustingFocus'] as bool? ?? false;
        final focusStatusStr = status['focusStatus'] as String? ?? 'unknown';
        final focusModeStr = status['focusMode'] as String? ?? 'unknown';

        // 🔥 성능 최적화: 정상적인 상태 수신 로그 제거
        // if (kDebugMode) { debugPrint('[Petgram] 🎯 Focus status received: ...'); }

        // 🔥 AF 상태 세분화: 세 가지 상태로 구분
        _FocusStatus newStatus;
        switch (focusStatusStr) {
          case 'adjusting':
            newStatus = _FocusStatus.adjusting;
            break;
          case 'ready':
            newStatus = _FocusStatus.ready;
            break;
          case 'locked':
            newStatus = _FocusStatus.locked;
            break;
          default:
            // 🔥 기본값: continuousAutoFocus 모드이면 ready로 간주
            // 네이티브에서 focusStatus를 반환하지 않으면 focusMode를 확인
            if (focusModeStr == 'continuousAutoFocus' && !isAdjusting) {
              newStatus = _FocusStatus.ready;
            } else if (isAdjusting) {
              newStatus = _FocusStatus.adjusting;
            } else {
            newStatus = _FocusStatus.unknown;
        }
        }

        // 🔥 상태가 변경될 때만 UI 업데이트 (성능 최적화)
        // 하지만 초기 상태(unknown)에서 ready로 변경될 때는 무조건 업데이트
        final shouldUpdate = _focusStatus != newStatus || 
                            _isFocusAdjusting != isAdjusting ||
                            (_focusStatus == _FocusStatus.unknown && newStatus != _FocusStatus.unknown);
        
        if (shouldUpdate) {
          if (mounted) {
            setState(() {
              _focusStatus = newStatus;
              _isFocusAdjusting = isAdjusting; // 호환성 유지
            });

            if (kDebugMode) {
              debugPrint(
                '[Petgram] 🎯 Focus status UI updated: ${_focusStatus.name} → ${newStatus.name} (adjusting=$isAdjusting)',
              );
            }
          }
        } else {
          // 🔥 성능 최적화: 상태 변경 없음 로그 제거 (매 초마다 호출되므로)
          // if (kDebugMode) { debugPrint('[Petgram] 🎯 Focus status unchanged: ...'); }
          }
      } else {
        // 🔥 status가 null인 경우: 네이티브 카메라가 준비되지 않았거나 에러 발생
        // 🔥 성능 최적화: null 상태 로그는 에러 상황이므로 유지하되 빈도 줄임
        // if (kDebugMode) { debugPrint('[Petgram] ⚠️ Focus status is null...'); }
        // status가 null이어도 폴링은 계속 (카메라가 준비되면 다시 시도)
      }
    } catch (e, stackTrace) {
      // 포커스 상태 확인 실패 시 폴링 중지 (크래시 방지)
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ Focus status poll error: $e',
        );
        debugPrint('[Petgram] Stack trace: $stackTrace');
      }
      // 에러가 발생해도 폴링은 계속 (일시적인 에러일 수 있음)
      // _stopFocusStatusPolling();
    }
  }

  /// 네이티브 카메라 디버그 상태 폴링
  /// 🔥 실기기에서도 디버그 오버레이 표시: 실제 상태 값을 업데이트하여 디버그 오버레이에 표시
  Future<void> _pollDebugState() async {
    if (!mounted) return;
    
    // 🔥 중복 호출 방지: 이미 실행 중이면 스킵
    if (_isPollingDebugState) {
      return;
    }
    _isPollingDebugState = true;
    
    try {
      // 🔥 Single Source of Truth: getDebugState() 한 번만 호출
      final rawDebugState = await _cameraEngine.getDebugState();
      final state = _cameraEngine.lastDebugState;
      if (state != null && mounted) {
        // 🔥 viewId 일치 확인: 현재 viewId와 state의 viewId가 일치해야 함
        // ⚠️ 중요: viewId = -1은 초기화 전 상태이므로 mismatch로 처리하지 않음
        final flutterViewId = _cameraEngine.viewId;
        final nativeViewId = state.viewId;
        final nativeInstancePtr = state.instancePtr;

        // 🔥 디버그 로그 폭주 방지: instancePtr 검증 로그는 kDebugMode에서만 출력
        if (nativeInstancePtr.isEmpty && kDebugMode) {
          debugPrint(
            '[CameraDebug][WARN] instancePtr is empty: flutterViewId=$flutterViewId, nativeViewId=$nativeViewId',
          );
        }

        // 🔥 디버그 로그 폭주 방지: viewId 관련 로그는 상태 변경 시에만 출력
        // (초기화 전 상태나 정상 상태는 로그 출력 안 함)
        if (flutterViewId != null &&
            nativeViewId >= 0 &&
            nativeViewId != flutterViewId) {
          final mismatchLog =
              '[CameraDebug][WARN] viewId mismatch: flutterViewId=$flutterViewId, nativeViewId=$nativeViewId';
          if (mismatchLog != _lastViewIdMismatchLog && kDebugMode) {
            _lastViewIdMismatchLog = mismatchLog;
            debugPrint(mismatchLog);
          }
        }

        // 🔥 핵심 수정: nativeInit=false인데 sessionRunning=true인 불일치 상태 감지 및 자동 복구
        // 이는 초기화가 불완전하거나 리소스가 해제된 상태를 의미
        final nativeInit = rawDebugState?['nativeInit'] as bool? ?? false;
        if (!nativeInit &&
            state.sessionRunning &&
            !_isReinitializing &&
            !_cameraEngine.isCapturingPhoto) {
          // 촬영 중이 아니고 재초기화 중이 아닐 때만 자동 복구 시도
          final fenceActive =
              _captureFenceUntil != null &&
              DateTime.now().isBefore(_captureFenceUntil!);
          if (!fenceActive) {
            // 🔥 디버그 로그 폭주 방지: 자동 복구 로그는 kDebugMode에서만 출력
            if (kDebugMode) {
              debugPrint(
                '[AutoRecover] 🔄 Detected inconsistent state: nativeInit=false but sessionRunning=true. Attempting recovery...',
              );
            }
            // 자동 복구: 세션을 중지하고 재초기화
            _maybeAutoRecover();
          }
        }

        // 🔥 보완 포인트 3: 자동 재초기화 완전 제거 (현재는 비활성)
        // - sessionLost 감지 제거 (잘못된 감지로 인한 불필요한 재초기화 방지)
        // - pinkFallbackDetected 감지 제거 (세션이 정상인데도 재초기화되는 문제 해결)
        // - 상태 캐시 업데이트 제거 (중복 상태 소스 제거로 불일치 방지)
        // 이유: 자동 재초기화가 상태 불일치를 유발하고, 실제 세션이 죽지 않았는데도 dispose가 호출됨
        // 대신: 사용자가 수동으로 "카메라 재시작" 버튼을 눌렀을 때만 재초기화
        //
        // 향후 확장 고려: 명백한 하드 에러 상황에서만 1회 자동 복구하는 로직 추가 가능
        // 예: sessionRunning=false && videoConnected=false && hasFirstFrame=false 인 경우
        // _maybeAutoRecover() 훅을 통해 향후 확장 가능하도록 구조 유지

        // 🔥 디버그 로그 폭주 방지: 카메라 상태 로그는 상태 변경 시에만 출력
        // kEnableCameraDebugOverlay가 false일 때는 로그 출력 안 함
        if (kEnableCameraDebugOverlay) {
          final isHealthy = _isCameraHealthy;
          if (!isHealthy) {
            final unhealthyLog =
                '[CameraDebug] ⚠️ Camera not healthy: sessionRunning=${state.sessionRunning}, videoConnected=${state.videoConnected}, hasFirstFrame=${state.hasFirstFrame}, isPinkFallback=${state.isPinkFallback}';
            if (unhealthyLog != _lastUnhealthyLog) {
              _lastUnhealthyLog = unhealthyLog;
              // 🔥 디버그 로그 폭주 방지: _addDebugLog 대신 debugPrint만 사용 (디버그 오버레이에 표시 안 함)
              if (kDebugMode) {
                debugPrint(unhealthyLog);
              }
            }
          } else {
            // 건강한 상태로 변경되었을 때만 로그 출력
            if (_lastUnhealthyLog != null) {
              _lastUnhealthyLog = null;
              // 🔥 디버그 로그 폭주 방지: _addDebugLog 대신 debugPrint만 사용
              if (kDebugMode) {
                debugPrint('[CameraDebug] ✅ Camera healthy');
              }
            }
          }
        }

        // 🔥 프리뷰 불안정 문제 해결: hasFirstFrame이 true가 될 때 초점 설정 및 타임스탬프 기록
        final bool currentHasFirstFrame = state.hasFirstFrame;
        if (currentHasFirstFrame && (_lastHasFirstFrame != true)) {
          // hasFirstFrame이 false에서 true로 변경됨 → 초점 설정 및 타임스탬프 기록
          _firstFrameTimestamp = DateTime.now();
          if (!_shouldUseMockCamera && _cameraEngine.isInitialized) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _setAutoFocusAtCenter();
              }
            });
          }
          
          // 🔥 앱 구동 시간 측정 및 로그 출력 (릴리스 모드에서도 출력)
          if (_appStartTime != null) {
            final totalTime = _firstFrameTimestamp!.difference(_appStartTime!).inMilliseconds;
            final splashTime = _splashRemoveTime != null 
                ? _splashRemoveTime!.difference(_appStartTime!).inMilliseconds 
                : null;
            final initTime = _cameraInitTime != null 
                ? _cameraInitTime!.difference(_appStartTime!).inMilliseconds 
                : null;
            final firstFrameTime = _firstFrameTimestamp!.difference(_appStartTime!).inMilliseconds;
            
            // 🔥 릴리스 모드에서도 로그 출력: print + 파일 저장
            final performanceLog = StringBuffer();
            performanceLog.writeln('[Petgram] ✅ First frame received (splash already removed)');
            performanceLog.writeln('[Petgram] ⏱️ App Startup Performance:');
            performanceLog.writeln('  - Total time: ${totalTime}ms');
            if (splashTime != null) {
              performanceLog.writeln('  - Splash removal: ${splashTime}ms');
            }
            if (initTime != null) {
              performanceLog.writeln('  - Camera init: ${initTime}ms');
            }
            performanceLog.writeln('  - First frame: ${firstFrameTime}ms');
            
            // 일반 카메라 앱 대비 평가
            String statusMsg;
            if (totalTime < 1000) {
              statusMsg = '  - Status: ✅ EXCELLENT (faster than typical camera apps: 1-2s)';
            } else if (totalTime < 2000) {
              statusMsg = '  - Status: ✅ GOOD (typical camera app range: 1-2s)';
            } else if (totalTime < 3000) {
              statusMsg = '  - Status: ⚠️ ACCEPTABLE (slightly slower than typical: 1-2s)';
            } else {
              statusMsg = '  - Status: ❌ SLOW (slower than typical camera apps: 1-2s)';
            }
            performanceLog.writeln(statusMsg);
            
            final logText = performanceLog.toString();
            print(logText);
            _saveDebugLogToFile(logText);
          }
        }
        _lastHasFirstFrame = currentHasFirstFrame;

        // 🔥 보완 포인트 1: UI 리빌드를 위한 최소한의 setState 유지
        // lastDebugState가 업데이트되어도 UI가 자동으로 리빌드되지 않는 문제 해결
        // 상태 캐시는 제거했지만, UI 갱신을 위한 최소한의 트리거는 필요
        if (mounted) {
          setState(() {
            // 🔥 Mock 모드일 때 센서 비율 동기화 (Mock 이미지 짤림 방지)
            if (_cameraEngine.useMockCamera ||
                _shouldUseMockCamera ||
                _cameraEngine.isSimulator) {
              final double mockRatio = _mockupAspectRatio ?? (9.0 / 16.0);
              if ((_sensorAspectRatio - mockRatio).abs() > 0.01) {
                _sensorAspectRatio = mockRatio;
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] 📐 Sensor aspect ratio set for Mock: $_sensorAspectRatio (mockup: $_mockupAspectRatio)',
                  );
                }
              }
            }

            if (rawDebugState != null) {
              // _nativeCurrentFilterKey =
              //     rawDebugState['currentFilterKey'] as String?;

              // 🔥 추가: 네이티브 센서 비율 동기화 (전면/후면 전환 시 화각 문제 해결)
              final double? aspect =
                  (rawDebugState['currentAspectRatio'] as num?)?.toDouble();
              if (aspect != null &&
                  aspect > 0 &&
                  aspect != _sensorAspectRatio &&
                  !(_cameraEngine.useMockCamera || _shouldUseMockCamera)) {
                _sensorAspectRatio = aspect;
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] 📐 Sensor aspect ratio updated from native: $_sensorAspectRatio',
                  );
                }
              }
            }
          });
        }
      }
    } catch (e) {
      // 🔥 디버그 로그 폭주 방지: viewId 불일치 에러는 kDebugMode에서만 출력
      if (e is PlatformException && e.code == 'NO_CAMERA_VIEW') {
        if (kDebugMode) {
          debugPrint('[HomePage] ❌ _pollDebugState: NO_CAMERA_VIEW error');
          debugPrint('[HomePage] ❌ Error details: ${e.message}');
          debugPrint('[HomePage] ❌ This indicates a viewId mismatch bug!');
        }
      }
      // 그 외 에러는 조용히 무시 (네이티브가 아직 준비되지 않았을 수 있음)
    } finally {
      // 🔥 중복 호출 방지 플래그 리셋
      _isPollingDebugState = false;
    }
  }

  /// Mock 카메라 사용 여부 결정
  /// ⚠️ 중요: 실기기에서 카메라가 있으면 절대 Mock 사용 안 함
  ///          프리뷰 표시를 위해 이 분기를 명확히 정리
  /// - 실기기에서 카메라가 있으면 절대 Mock 사용 안 함
  /// - 네이티브 카메라가 정상적으로 초기화되었으면 Mock 사용 안 함
  /// - 그 외에는 _useMockCamera 값 사용
  /// Mock 카메라 사용 여부 (카메라 엔진에서 관리)
  bool get _shouldUseMockCamera => _cameraEngine.shouldUseMockCamera;

  /// 카메라 사용 가능 여부 (카메라 엔진에서 관리)
  bool get _isCameraReady => _cameraEngine.isCameraReady;

  /// 🔥 REFACTORING: 단일 상태 소스 기반 카메라 건강 상태 체크
  /// CameraDebugState만 사용하여 상태 불일치 제거
  bool get _isCameraHealthy {
    final state = _cameraEngine.lastDebugState;
    if (state == null) return false;

    // viewId 일치 확인
    final currentViewId = _cameraEngine.viewId;
    if (currentViewId != null &&
        state.viewId >= 0 &&
        state.viewId != currentViewId) {
      return false; // viewId 불일치 시 건강하지 않음
    }

    // 세션이 정상이고 첫 프레임을 받았으며 핑크 fallback이 아닌 경우만 건강
    return state.sessionRunning &&
        state.videoConnected &&
        state.hasFirstFrame &&
        !state.isPinkFallback;
  }

  /// 🔥 수정 2: fallback 오버레이는 "상태 머신"으로 분명하게 분리
  /// Ready 상태에서는 절대 fallback이 위로 올라오지 않도록 보장
  ///
  /// 상태 머신:
  /// - Idle: 초기화 전 (state == null)
  /// - Initializing: sessionRunning=false, hasFirstFrame=false
  /// - Ready: sessionRunning=true, videoConnected=true, hasFirstFrame=true
  /// - Error: 명백한 에러 상태

  /// 🔥 보완 포인트 3: 자동 복구 훅
  /// nativeInit=false인데 sessionRunning=true인 불일치 상태를 복구
  void _maybeAutoRecover() {
    if (_isReinitializing || _cameraEngine.isCapturingPhoto) {
      _addDebugLog(
        '[AutoRecover] ⏸️ Skipping auto-recover: already reinitializing or capturing',
      );
      return;
    }

    final fenceActive =
        _captureFenceUntil != null &&
        DateTime.now().isBefore(_captureFenceUntil!);
    if (fenceActive) {
      _addDebugLog(
        '[AutoRecover] ⏸️ Skipping auto-recover: capture fence active',
      );
      return;
    }

    _addDebugLog(
      '[AutoRecover] 🔄 Starting auto-recovery: nativeInit=false but sessionRunning=true',
    );

    // 세션을 중지하고 재초기화
    _manualRestartCamera();
  }

  /// 🔥 Single Source of Truth: CameraDebugState 기반으로 canUseCamera 계산
  /// Flutter는 절대 자체적으로 true를 만들지 않음
  /// 조건: viewId 일치 && sessionRunning && videoConnected && hasFirstFrame && !isPinkFallback
  /// 🔥 전면 재설계: canUseCamera 단순화
  /// 오직 sessionRunning && videoConnected만 확인
  /// hasFirstFrame, pinkfallback, viewId mismatch는 UI 경고만 표시
  bool get canUseCamera {
    // 🔥 시뮬레이터 및 실기기 초기화 전 대응:
    // iOS 시뮬레이터이거나 명시적 Mock 모드인 경우 항상 촬영 시도 허용
    if (_shouldUseMockCamera ||
        _cameraEngine.useMockCamera ||
        _cameraEngine.isSimulator) {
      return true;
    }

    // iOS 실기기에서 아직 카메라 리스트가 없어도 촬영 시도 허용 (AVFoundation에서 직접 관리하므로)
    if (widget.cameras.isEmpty &&
        Platform.isIOS &&
        !_cameraEngine.isSimulator) {
      // 하지만 네이티브 세션이 준비되었을 때만 true 반환하도록 함 (아래 state 체크에서 처리)
    }

    // 🔥 Single Source of Truth: CameraDebugState만 사용 (실제 네이티브 카메라 상태)
    final state = _cameraEngine.lastDebugState;
    if (state == null) {
      final logMsg = '[CameraDebug] canUseCamera=false (state is null)';
      if (logMsg != _lastCanUseCameraLog) {
        _lastCanUseCameraLog = logMsg;
        _addDebugLog(logMsg);
      }
      return false;
    }

    // 🔥 핵심 수정: hasFirstFrame도 필수 조건으로 추가
    // hasFirstFrame=false면 프리뷰가 없으므로 카메라 사용 불가
    final result =
        state.sessionRunning && state.videoConnected && state.hasFirstFrame;

    // 🔥 중복 로그 제거: 상태 변경 시에만 최종 로그만 출력 (경고 로그 제거)
    final logMsg =
        '[CameraDebug] canUseCamera=$result (sessionRunning=${state.sessionRunning}, videoConnected=${state.videoConnected}, hasFirstFrame=${state.hasFirstFrame}, isPinkFallback=${state.isPinkFallback})';
    if (logMsg != _lastCanUseCameraLog) {
      _lastCanUseCameraLog = logMsg;
      _addDebugLog(logMsg);
    }

    return result;
  }

  String? _lastCanUseCameraLog; // canUseCamera 로그 중복 방지용
  String? _lastViewIdMismatchLog; // viewId mismatch 로그 중복 방지용
  String? _lastUnhealthyLog; // 카메라 unhealthy 로그 중복 방지용
  bool? _lastHasFirstFrame; // 🔥 프리뷰 불안정 문제 해결: hasFirstFrame 상태 추적용
  DateTime? _firstFrameTimestamp; // 🔥 크래시 방지: 첫 프레임 수신 시간 추적 (프리뷰 안정화 대기용)
  DateTime? _appStartTime; // 🔥 앱 구동 시간 측정: initState 시작 시간
  DateTime? _splashRemoveTime; // 🔥 스플래시 제거 시간 측정
  DateTime? _cameraInitTime; // 🔥 카메라 초기화 완료 시간 측정

  bool _isProcessing = false;
  bool _isCaptureAnimating = false;

  // 촬영용 필터
  String _shootFilterKey = kFilterOrder.first;

  // 라이브 필터 강도
  double _liveIntensity = 0.8;
  String _liveCoatPreset = 'mid'; // light / mid / dark / custom
  // 필터 적용 빈도 제어용 (필터 변경 시에만 네이티브에 전달)
  String? _lastAppliedFilterKey;
  double? _lastAppliedFilterIntensity;

  // 플래시 / 화면 비율
  FlashMode _flashMode = FlashMode.off;
  AspectRatioMode _aspectMode = AspectRatioMode.threeFour;

  // 🔥 프리뷰 비율 크롭 기반 처리: 카메라 센서 원본 비율 (고정)
  // 네이티브에서 받은 센서 비율 또는 기본값 (3:4 = 0.75)
  double _sensorAspectRatio = 3.0 / 4.0; // 기본값: 3:4

  // 촬영용 필터 패널 펼침 여부
  bool _filterPanelExpanded = false;

  // 그리드라인 표시
  bool _showGridLines = false;

  // 연속 촬영 모드
  bool _isBurstMode = false;
  int _burstCount = 0;
  int _burstCountSetting = 5; // 기본 5장, 선택 가능: 3, 5, 10, 20
  bool _shouldStopBurst = false; // 연속 촬영 중지 플래그

  // 타이머 촬영
  int _timerSeconds = 0; // 0 = off, 3, 5, 10
  bool _isTimerCounting = false;
  bool _shouldStopTimer = false; // 타이머 중지 플래그
  bool _isTimerTriggered = false; // 타이머로 인한 촬영인지 구분
  bool _isInitialZoomSetting = false; // 🔥🔥🔥 초기 줌 설정 중 플래그 (렌즈 전환 방지)

  // 🔥 REFACTORING: 중복 상태 필드 제거 - CameraDebugState만 Single Source of Truth로 사용
  // bool? _nativeSessionRunning; // 제거됨 - CameraDebugState.sessionRunning 사용
  // bool? _nativeVideoConnected; // 제거됨 - CameraDebugState.videoConnected 사용
  // bool _nativeHasFirstFrame = false; // 제거됨 - CameraDebugState.hasFirstFrame 사용
  // bool? _nativeIsPinkFallback; // 제거됨 - CameraDebugState.isPinkFallback 사용
  // bool? _lastSessionRunning; // 제거됨 - 자동 재초기화 로직 제거로 불필요
  // bool? _lastVideoConnected; // 제거됨 - 자동 재초기화 로직 제거로 불필요
  // bool? _lastPinkFallback; // 제거됨 - 자동 재초기화 로직 제거로 불필요
  // String? _lastNativeInstancePtr; // 제거됨 - 자동 재초기화 로직 제거로 불필요

  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;
  bool _isReinitializing = false; // 재초기화 중 플래그 (중복 방지)
  // String? _nativeCurrentFilterKey; // unused after debug overlay removed
  Timer? _debugStatePollTimer;
  bool _isPollingDebugState = false; // 🔥 중복 호출 방지 플래그

  // 네이티브 디바이스 타입/포지션 (프론트/백 + wide/ultraWide 디버그용)
  // String? _nativeDeviceType; // "wide" / "ultraWide" / "other" // unused after debug overlay removed
  String _nativeLensKind = 'wide';

  // 디버그 오버레이 표시 여부 (기본값: 비활성화, 상단 플래그 기반)
  final bool _showDebugOverlay = kEnableCameraDebugOverlay;

  List<PetInfo> _petList = [];
  String? _selectedPetId; // 현재 선택된 반려동물 ID

  // 프레임 적용 여부
  bool _frameEnabled = true;

  // 펫 얼굴 인식 관련
  StreamSubscription? _petFaceStreamSubscription;

  // 🔥 AF 상태 세분화: 실제 초점 상태를 구분
  _FocusStatus _focusStatus = _FocusStatus.unknown;

  // 위치 정보
  String? _currentLocation; // 현재 촬영 위치 정보

  /// 위치정보 활성화 여부 확인 후 위치 정보 가져오기
  /// [forceReload]가 true이면 위치정보가 있어도 다시 불러오기 (GPS 업데이트 버튼 클릭 시)
  /// [alwaysReload]가 true이면 프레임 선택 변경 시 항상 다시 불러오기
  Future<void> _checkAndFetchLocation({
    bool forceReload = false,
    bool alwaysReload = false,
  }) async {
    if (!_frameEnabled || _petList.isEmpty) {
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
      return;
    }

    final selectedPet = _selectedPetId != null
        ? _petList.firstWhere(
            (pet) => pet.id == _selectedPetId,
            orElse: () => _petList.first,
          )
        : _petList.first;

    if (selectedPet.locationEnabled) {
      debugPrint(
        '[Petgram] 📍 위치정보 활성화됨: selectedPet.locationEnabled=true, _currentLocation=${_currentLocation != null ? "있음" : "없음"}',
      );
      // 위치 정보가 없거나 강제 재로드가 필요하거나 항상 재로드가 필요한 경우에만 가져오기
      if (_currentLocation == null || forceReload || alwaysReload) {
        debugPrint(
          '[Petgram] 📍 위치정보 불러오기 조건 충족: _currentLocation=${_currentLocation != null ? "있음" : "없음"}, forceReload=$forceReload, alwaysReload=$alwaysReload',
        );
        if (forceReload || alwaysReload) {
          if (mounted) {
            setState(() {
              _currentLocation = null; // 초기화하여 다시 불러오도록
            });
          }
        }
        await _fetchLocation();
      } else {
        debugPrint('[Petgram] 📍 위치정보 불러오기 조건 불충족: 이미 위치정보가 있음');
      }
    } else {
      debugPrint('[Petgram] 📍 위치정보 비활성화됨: selectedPet.locationEnabled=false');
      // 위치 정보 활성화가 안 되어 있으면 null로 설정
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
    }
  }

  /// 위치 정보 가져오기 (동 이전 레벨까지)
  Future<void> _fetchLocation({bool showSnackbar = false}) async {
    debugPrint('[Petgram] 📍 _fetchLocation 시작');
    try {
      // 위치 서비스 활성화 여부 확인
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (kDebugMode) {
          debugPrint('📍 위치 서비스가 비활성화되어 있습니다');
        }
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        return;
      }

      // 위치 권한 확인
      LocationPermission permission = await Geolocator.checkPermission();
      bool permissionJustGranted = false;

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (kDebugMode) {
            debugPrint('📍 위치 권한이 거부되었습니다');
          }
          if (mounted) {
            setState(() {
              _currentLocation = null;
            });
          }
          if (showSnackbar && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('위치 정보를 확인할 수 없습니다'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
          return;
        }
        // 🔥 권한이 방금 허용된 경우 위치 서비스 준비를 위해 약간의 지연
        if (permission == LocationPermission.whileInUse ||
            permission == LocationPermission.always) {
          permissionJustGranted = true;
          if (kDebugMode) {
            debugPrint('📍 위치 권한이 방금 허용되었습니다. 위치 서비스 준비 대기...');
          }
          // 위치 서비스가 준비될 때까지 약간의 지연
          await Future.delayed(const Duration(milliseconds: 500));

          // 🔥 mounted 체크: 지연 후 위젯이 dispose되었는지 확인
          if (!mounted) {
            if (kDebugMode) {
              debugPrint('📍 위치 권한 허용 후 대기 중 위젯이 dispose됨');
            }
            return;
          }
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (kDebugMode) {
          debugPrint('📍 위치 권한이 영구적으로 거부되었습니다');
        }
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        return;
      }

      // 🔥 현재 위치 가져오기 (타임아웃 및 재시도 로직 추가)
      Position? position;
      int retryCount = 0;
      const maxRetries = 3;

      while (position == null && retryCount < maxRetries) {
        try {
          position =
              await Geolocator.getCurrentPosition(
                locationSettings: LocationSettings(
                  accuracy: LocationAccuracy.high,
                  timeLimit: const Duration(seconds: 10), // 🔥 타임아웃 설정
                ),
              ).timeout(
                const Duration(seconds: 15), // 🔥 전체 타임아웃
                onTimeout: () {
                  if (kDebugMode) {
                    debugPrint(
                      '📍 위치 정보 가져오기 타임아웃 (시도 ${retryCount + 1}/$maxRetries)',
                    );
                  }
                  throw TimeoutException('위치 정보 가져오기 타임아웃');
                },
              );
        } catch (e) {
          retryCount++;
          if (kDebugMode) {
            debugPrint('📍 위치 정보 가져오기 실패 (시도 $retryCount/$maxRetries): $e');
          }

          if (retryCount < maxRetries) {
            // 🔥 재시도 전 대기 (권한이 방금 허용된 경우 더 긴 대기)
            final delay = permissionJustGranted && retryCount == 1
                ? const Duration(seconds: 2)
                : const Duration(milliseconds: 1000);
            await Future.delayed(delay);

            // 🔥 mounted 체크: 재시도 전 위젯이 dispose되었는지 확인
            if (!mounted) {
              if (kDebugMode) {
                debugPrint('📍 위치 정보 재시도 중 위젯이 dispose됨');
              }
              return;
            }
          } else {
            // 최대 재시도 횟수 초과
            if (kDebugMode) {
              debugPrint('📍 위치 정보 가져오기 실패: 최대 재시도 횟수 초과');
            }
            if (mounted) {
              setState(() {
                _currentLocation = null;
              });
            }
            if (showSnackbar && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('위치 정보를 확인할 수 없습니다'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                  backgroundColor: Colors.black87,
                ),
              );
            }
            return;
          }
        }
      }

      if (position == null) {
        if (kDebugMode) {
          debugPrint('📍 위치 정보를 가져올 수 없습니다');
        }
        return;
      }

      // 🔥 mounted 체크: 비동기 작업 후 위젯이 dispose되었을 수 있음
      if (!mounted) {
        if (kDebugMode) {
          debugPrint('📍 위치 정보 가져오기 중 위젯이 dispose됨');
        }
        return;
      }

      // geocoding 패키지 사용
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      // 🔥 mounted 체크: geocoding 작업 후 위젯이 dispose되었을 수 있음
      if (!mounted) {
        if (kDebugMode) {
          debugPrint('📍 Geocoding 완료 후 위젯이 dispose됨');
        }
        return;
      }

      if (placemarks.isNotEmpty) {
        final placemark = placemarks[0];
        if (kDebugMode) {
          debugPrint('📍 Placemark 정보:');
          debugPrint('  - administrativeArea: ${placemark.administrativeArea}');
          debugPrint(
            '  - subAdministrativeArea: ${placemark.subAdministrativeArea}',
          );
          debugPrint('  - locality: ${placemark.locality}');
          debugPrint('  - subLocality: ${placemark.subLocality}');
        }

        // 3단계까지 풀로 노출하는 함수
        String buildRegion3Level(Placemark p) {
          // 1레벨 = 시도
          final level1 = (p.administrativeArea ?? '').trim(); // 서울특별시, 경기도 등

          // 2레벨 후보 = 시군구
          String? level2;

          // 1순위: locality (강남구, 의정부시 등)
          if ((p.locality ?? '').trim().isNotEmpty) {
            final locality = p.locality!.trim();
            // 예외처리: 레벨2가 레벨1과 같으면 사용하지 않음
            if (locality != level1) {
              level2 = locality;
            }
          }
          // 2순위: subAdministrativeArea (성남시, 의정부시 등 기기 따라 여기 들어오는 경우도 있어서)
          if ((level2 == null || level2.isEmpty) &&
              (p.subAdministrativeArea ?? '').trim().isNotEmpty) {
            final subArea = p.subAdministrativeArea!.trim();
            // 예외처리: 레벨2가 레벨1과 같으면 사용하지 않음
            if (subArea != level1) {
              level2 = subArea;
            }
          }

          // 3레벨 = subLocality (동, 면 등)
          String? level3;
          if ((p.subLocality ?? '').trim().isNotEmpty) {
            final subLocality = p.subLocality!.trim();
            // 예외처리: 레벨3가 레벨1이나 레벨2와 같으면 사용하지 않음
            if (subLocality != level1 && subLocality != level2) {
              level3 = subLocality;
            }
          }

          // 레벨들을 조합 (중복 제거)
          List<String> levels = [];
          if (level1.isNotEmpty) levels.add(level1);
          if (level2 != null && level2.isNotEmpty && !levels.contains(level2)) {
            levels.add(level2);
          }
          if (level3 != null && level3.isNotEmpty && !levels.contains(level3)) {
            levels.add(level3);
          }

          if (levels.isEmpty) {
            return '';
          }
          return levels.join(' '); // 최종 "서울특별시 강남구 역삼동" 이런 형식
        }

        final koreanLocation = buildRegion3Level(placemark);

        if (koreanLocation.isNotEmpty) {
          // 한글 주소 그대로 사용 (이미 중복 제거됨)
          final finalLocation = koreanLocation;

          // 🔥 mounted 체크: setState 전에 한 번 더 확인
          if (mounted) {
            setState(() {
              _currentLocation = finalLocation;
            });
            debugPrint('[Petgram] 📍 위치 정보 불러오기 성공: $_currentLocation');

            // 🔥 위치 정보 저장 후 프레임이 활성화되어 있으면 프레임 업데이트 트리거
            //    (프리뷰에서 위치 칩이 즉시 표시되도록)
            if (_frameEnabled && _petList.isNotEmpty) {
              if (kDebugMode) {
                debugPrint('[Petgram] 📍 위치 정보 저장 완료, 프레임 업데이트 트리거');
              }
              // 프레임 업데이트는 다음 빌드 사이클에서 자동으로 반영됨
              // 필요시 명시적으로 프레임 프리뷰를 업데이트할 수 있음
            }
          } else {
            if (kDebugMode) {
              debugPrint('[Petgram] 📍 위치 정보 불러오기 성공했으나 위젯이 dispose됨');
            }
          }
        } else {
          // 🔥 mounted 체크: setState 전에 한 번 더 확인
          if (mounted) {
            setState(() {
              _currentLocation = null;
            });
          }
          if (kDebugMode) {
            debugPrint('📍 위치 정보를 가져올 수 없습니다');
          }
          if (showSnackbar && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('위치 정보를 확인할 수 없습니다'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (kDebugMode) {
          debugPrint('📍 주소 정보를 가져올 수 없습니다');
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ 위치 정보 가져오기 실패: $e');
      debugPrint('[Petgram] ❌ Stack trace: ${StackTrace.current}');
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
      if (showSnackbar && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('위치 정보를 확인할 수 없습니다'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.black87,
          ),
        );
      }
    }
  }

  // 카메라 줌 레벨
  // 🔥 Issue 3 & 4 Fix: 줌 배율 정상화 - 선형 줌, 데드존 제거
  // - 내부 줌 범위: 0.5 ~ maxZoom (초광각 지원)
  // - 배율 옵션 버튼: 0.5x(초광각), 1x, 2x, 3x 제공
  // - 핀치 줌: 카메라가 지원하는 최대 배율까지 (최대 10x)
  // - 절대값 기반: zoom *= scale 같은 누적 곱 제거, 직접 값만 clamp
  double _uiZoomScale = 1.0; // 현재 줌 배율 (0.5 ~ 카메라 최대 배율)
  double _baseUiZoomScale = 1.0; // 핀치 시작 시 기준 배율
  double? _savedZoomScaleBeforeBackground; // 🔥🔥🔥 백그라운드 진입 전 줌 값 저장
  static const double _uiZoomMin =
      0.5; // 🔥 광각 지원: 최소 줌 0.5x (초광각 카메라 전환 또는 videoZoomFactor = 0.5)
  static const double _uiZoomMax = 10.0; // 최대 줌 (카메라가 지원하는 최대 배율, 최대 10x)
  static const List<double> _uiZoomPresets = [
    0.5, // 초광각 (0.5x)
    1.0,
    2.0,
    3.0,
  ]; // 프리셋 옵션

  // iOS 네이티브 카메라 렌즈 종류 추적 (후면 카메라 전용)
  // - "wide": 기본 광각
  // - "ultraWide": 초광각
  bool _isNativeLensSwitching = false; // 렌즈 전환 중 중복 호출 방지
  bool _isSettingZoom = false; // 🔥🔥🔥 줌 설정 중 플래그 (중복 호출 방지)
  // Offset _zoomOffset = Offset.zero; // 줌 오프셋 - 제거됨
  // Offset _lastZoomFocalPoint = Offset.zero; // 마지막 줌 포커스 포인트 - 제거됨

  // 카메라 방향 (전면/후면)
  CameraLensDirection _cameraLensDirection = CameraLensDirection.back;

  // 초점 관련
  bool _showFocusIndicator = false; // 초점 표시기 표시 여부
  bool _showAutoFocusIndicator = false; // 자동 초점 표시기 표시 여부
  bool _isPetFaceTracking = false; // 펫 얼굴 자동 추적 초점 활성 여부
  bool _isAutoFocusEnabled = false; // 연속 자동 포커스 모드 활성화 여부
  bool _isFocusAdjusting = false; // 포커스 조정 중 여부 (실시간 상태)
  Timer? _focusStatusPollTimer; // 포커스 상태 폴링 타이머
  Timer? _hideFocusIndicatorTimer; // 포커스 인디케이터 숨김 타이머 (취소 가능)
  DateTime? _lastTapTime; // 마지막 탭 시간 (debounce용)
  bool _isProcessingTap = false; // 탭 처리 중 플래그 (중복 처리 방지)
  Offset? _focusIndicatorNormalized;
  Offset? _lastFocusPoint; // 🔥🔥🔥 마지막 포커스 포인트 (중복 호출 방지)
  Offset? _lastExposurePoint; // 🔥🔥🔥 마지막 노출 포인트 (중복 호출 방지)
  // 🔥 좌표계 통일: _stackKey는 더 이상 사용되지 않음 (deprecated) - 제거됨
  final GlobalKey _mockPreviewKey = GlobalKey(); // Mock 프리뷰용 key
  final GlobalKey _nativePreviewKey = GlobalKey(); // Native 프리뷰용 key
  final GlobalKey _previewStackKey = GlobalKey(); // 프리뷰 스택 측정용 key
  Rect? _lastSyncedPreviewRect; // 🔥 마지막으로 동기화된 프리뷰 영역
  Rect? _pendingPreviewRectForSync; // 네이티브 동기화 대기 중인 프리뷰 rect
  int _previewSyncRetryCount = 0; // 프리뷰 동기화 재시도 카운터
  bool _previewSyncRetryScheduled = false; // 재시도 스케줄 플래그
  bool _isResumingCamera = false; // 🔥🔥🔥 카메라 재개 중 플래그 (중복 호출 방지)
  // 촬영 보호 펜스: 촬영 시작 후 일정 시간 동안 init/resume/sync 차단
  DateTime? _captureFenceUntil;

  // 밝기 조절 (-1.0 ~ 1.0, 0.0이 원본)
  double _brightnessValue = 0.0; // -10 ~ 10 범위
  bool _isBrightnessDragging = false; // 🔥 밝기 슬라이더 드래그 상태 추적

  // 펫톤 보정 저장 시 적용 여부 (디버그용 토글)
  // false로 설정하면 저장 시 펫톤 보정을 건너뜀 (필터 + 밝기만 적용)
  bool _enablePetToneOnSave = true;

  bool get _isPureOriginalMode =>
      _shootFilterKey == 'basic_none' && _brightnessValue == 0.0;

  /// iOS 네이티브 카메라가 활성 상태인지 여부
  bool get _isNativeCameraActive =>
      !kIsWeb &&
      Platform.isIOS &&
      _cameraEngine.isInitialized &&
      !_shouldUseMockCamera;

  /// 네이티브 카메라(iOS) 노출(밝기) 업데이트
  /// 🔥🔥🔥 최초 선택 시 버벅임 해결: async/await로 변경하고 즉시 실행
  void _updateNativeExposureBias() {
    if (!_isNativeCameraActive) return;
    if (!_cameraEngine.isInitialized) return; // 🔥 카메라가 초기화되지 않았으면 스킵

    // 1단계: 슬라이더 값 -10.0 ~ +10.0 → -1.0 ~ +1.0 범위로 정규화
    final double normalized = (_brightnessValue / 10.0).clamp(
      -1.0,
      1.0,
    ); // -1.0 ~ +1.0

    // 2단계: 실제 Exposure Bias는 너무 튀지 않도록 제한된 범위만 사용
    final double uiValue = normalized * kExposureBiasRange; // -0.4 ~ +0.4

    // 🔥🔥🔥 최초 선택 시 버벅임 해결: unawaited로 즉시 실행 (비동기 블로킹 방지)
    // 카메라가 준비되지 않았으면 스킵하므로 안전함
    unawaited(_cameraEngine.setExposureBias(uiValue));
  }

  /// iOS 네이티브 카메라 렌즈 전환 (wide ↔ ultraWide)을 UI 줌 값에 따라 비동기적으로 수행
  /// - 후면 카메라 + 네이티브 카메라 활성 상태일 때만 동작
  /// - 0.9x 이하에서 ultraWide로 전환, 1.05 이상으로 올라가면 wide로 복귀
  /// 🔥 줌 재적용: 렌즈 전환 후 요청한 uiZoom 값을 반드시 재적용하여 데드존 제거
  /// 🔥 줌 프리셋 설정 공통 함수
  /// 프리셋 버튼(0.5x, 1x, 2x, 3x)을 사용하는 모든 코드에서 이 함수를 호출
  /// 🔥🔥🔥 iOS 기본 앱과 동일: Native에서 렌즈 전환을 자동으로 처리하므로 Flutter에서는 setZoom만 호출
  void _setZoomPreset(double presetZoom) {
    // 🔥🔥🔥 중복 호출 방지: 이미 줌 설정 중이면 스킵
    if (_isSettingZoom) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⏸️ _setZoomPreset: Already setting zoom, skipping duplicate call');
      }
      return;
    }
    
    // 🔥🔥🔥 전면 카메라: 0.5x는 렌즈 전환이 불가능하므로 1.0으로 clamp
    double effectiveZoom = presetZoom;
    if (_cameraLensDirection == CameraLensDirection.front && presetZoom < 1.0) {
      if (kDebugMode) {
        debugPrint(
          '[Zoom] ⚠️ Front camera: 0.5x is not available, clamping to 1.0',
        );
      }
      effectiveZoom = 1.0;
    }
    
    final double clamped = effectiveZoom.clamp(_uiZoomMin, _uiZoomMax);
    
    // 🔥🔥🔥 핵심 수정: 0.5배 선택 시 UI를 즉시 0.5로 고정하고 플래그 설정
    _isSettingZoom = true;
    setState(() {
      _uiZoomScale = clamped;
      _baseUiZoomScale = clamped;
    });
    
    // 🔥 Native의 setZoom에서 렌즈 전환을 자동으로 처리하므로 Flutter에서는 setZoom만 호출
    // 🔥🔥🔥 네이티브의 실제 줌 값으로 Flutter 상태 동기화 (중복 호출 방지)
    if (_cameraEngine.isInitialized && !_shouldUseMockCamera) {
      if (kDebugMode) {
        debugPrint(
          '[Zoom] Preset zoom set: ${_uiZoomScale.toStringAsFixed(3)} (Native will handle lens switching)',
        );
      }
      final requestedZoom = clamped;
      _cameraEngine.setZoom(requestedZoom).then((actualZoom) {
        // 🔥🔥🔥 핵심 수정: 0.5배 선택 시 UI는 무조건 0.5로 유지 (네이티브 actualZoom과 무관)
        if (mounted && actualZoom != null) {
          if (requestedZoom == 0.5) {
            // 🔥🔥🔥 0.5배 선택 시: UI는 무조건 0.5로 유지, 네이티브 actualZoom과 무관
            // 네이티브는 ultraWide로 전환을 시도하지만, 전환이 완료되기 전에는 실제 값이 1.0일 수 있음
            // 하지만 UI는 사용자가 선택한 0.5를 유지해야 함
            if (kDebugMode) {
              debugPrint('[Petgram] 🔄 0.5x selected: UI kept at 0.5x (requested=${requestedZoom.toStringAsFixed(2)}, native actual=${actualZoom.toStringAsFixed(2)}x)');
            }
            // 🔥🔥🔥 UI는 이미 0.5로 설정되어 있으므로 변경하지 않음
            _isSettingZoom = false;
            
            // 🔥🔥🔥 핵심 수정: 배율 조정 후 밝기 값 재적용 (렌즈 전환으로 인한 밝기 리셋 방지)
            Future.delayed(const Duration(milliseconds: 200), () {
              if (mounted && _isNativeCameraActive) {
                _updateNativeExposureBias();
                if (kDebugMode) {
                  debugPrint('[Petgram] 🔄 Brightness reapplied after 0.5x zoom (brightness=${_brightnessValue.toStringAsFixed(2)})');
                }
              }
            });
            return;
          }
          
          // 🔥🔥🔥 0.5배가 아닌 경우: 실제 값과 요청 값의 차이가 0.01 이상일 때만 동기화
          if ((actualZoom - requestedZoom).abs() > 0.01) {
            // 🔥🔥🔥 setState로 인한 재호출 방지: 실제 값으로만 업데이트 (setZoom 재호출 안 함)
            setState(() {
              _uiZoomScale = actualZoom;
              _baseUiZoomScale = actualZoom;
            });
            if (kDebugMode) {
              debugPrint('[Petgram] 🔄 Zoom synced: requested=${requestedZoom.toStringAsFixed(2)}, actual=${actualZoom.toStringAsFixed(2)}');
            }
          }
          _isSettingZoom = false;
          
          // 🔥🔥🔥 핵심 수정: 배율 조정 후 밝기 값 재적용 (렌즈 전환으로 인한 밝기 리셋 방지)
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted && _isNativeCameraActive) {
              _updateNativeExposureBias();
              if (kDebugMode) {
                debugPrint('[Petgram] 🔄 Brightness reapplied after zoom (zoom=${actualZoom.toStringAsFixed(2)}, brightness=${_brightnessValue.toStringAsFixed(2)})');
              }
            }
          });
        } else {
          _isSettingZoom = false;
        }
      }).catchError((error) {
        if (kDebugMode) {
          debugPrint('[Petgram] ⚠️ setZoom error: $error');
        }
        _isSettingZoom = false;
      });
    } else {
      _isSettingZoom = false;
    }
  }

  /// 🔥 DEPRECATED: 이 함수는 더 이상 사용되지 않습니다.
  /// Native의 setZoom에서 렌즈 전환을 자동으로 처리하므로 Flutter에서는 setZoom만 호출하면 됩니다.
  /// @deprecated Native에서 렌즈 전환을 자동으로 처리하므로 이 함수는 사용하지 않습니다.
  void _maybeSwitchNativeLensForZoom(double uiZoom) {
    // 🔥 이 함수는 더 이상 사용되지 않습니다. Native의 setZoom에서 렌즈 전환을 자동으로 처리합니다.
    return;
    if (!_cameraEngine.isInitialized) return;
    if (_cameraLensDirection != CameraLensDirection.back) return;
    if (_isNativeLensSwitching) return;
    // 🔥🔥🔥 초기 줌 설정 중에는 렌즈 전환하지 않음 (기본 1.0x 줌 유지)
    if (_isInitialZoomSetting) return;

    // 🔥🔥🔥 일반 카메라 앱처럼 자연스러운 줌: 히스테리시스 대폭 개선
    // 일반 카메라 앱은 렌즈 전환 시 시야각이 일치하도록 매핑함
    // - ultraWide 0.5x ~ 0.9x 구간에서 렌즈 전환 없이 연속 줌
    // - 0.5x 이하에서만 ultraWide로 전환, 1.0x 이상에서 wide로 복귀
    // - 더 넓은 히스테리시스 구간으로 빈번한 전환 방지
    // 🔥🔥🔥 0.5~0.9 구간에서도 연속적으로 줌이 동작하도록 임계값 조정
    const double enterUltraWideThreshold = 0.5; // 0.5 이하에서만 ultraWide 진입 (0.5~0.9 구간은 현재 렌즈 유지)
    const double exitUltraWideThreshold = 1.0; // 1.0 이상에서만 wide 복귀
    // 이렇게 하면 0.5~1.0 구간에서 렌즈 전환이 발생하지 않아 부드러운 줌 가능
    // 0.5 이하에서만 ultraWide로 전환하고, 0.5~0.9 구간에서는 현재 렌즈에서 연속 줌

    if (_nativeLensKind != 'ultraWide' && uiZoom < enterUltraWideThreshold) {
      _isNativeLensSwitching = true;
      _cameraEngine
          .switchToUltraWideIfAvailable()
          .then((result) {
            if (!mounted) return;
            if (result != null) {
              setState(() {
                _nativeLensKind =
                    (result['lensKind'] as String?) ?? 'ultraWide';
              });
              // 🔥🔥🔥 iOS 기본 카메라 앱과 동일: 렌즈 전환 후 요청한 줌 값을 정확히 설정
              // 렌즈 전환 시 네이티브에서 minZoom으로 초기 설정되므로, 요청한 줌 값을 즉시 재설정
              // 0.5를 요청하면 0.5로, 0.7을 요청하면 0.7로 정확히 설정되어야 함
              if (_cameraEngine.isInitialized) {
                // 🔥🔥🔥 렌즈 전환 직후 즉시 줌 재적용: 요청한 값을 정확히 설정
                // 네이티브에서 minZoom으로 초기 설정되었지만, Flutter에서 요청한 값을 정확히 설정
                Future.delayed(const Duration(milliseconds: 30), () {
                  if (mounted && _cameraEngine.isInitialized) {
                    _cameraEngine.setZoom(uiZoom);
                    if (kDebugMode) {
                      debugPrint(
                        '[Zoom] Ultra wide switched, zoom set to ${uiZoom.toStringAsFixed(3)} (requested value)',
                      );
                    }
                  }
                });
                // 🔥 두 번째 재적용으로 네이티브에서 정확히 설정되도록 보장
                Future.delayed(const Duration(milliseconds: 100), () {
                  if (mounted && _cameraEngine.isInitialized) {
                    _cameraEngine.setZoom(uiZoom);
                    if (kDebugMode) {
                      debugPrint(
                        '[Zoom] Ultra wide switched, zoom reapplied: ${uiZoom.toStringAsFixed(3)}',
                      );
                    }
                  }
                });
              }
              // 🔥 필터 유지: 초광각 전환 후 필터를 다시 적용하여 필터가 사라지지 않도록 함
              if (_isNativeCameraActive) {
                _applyFilterIfChanged(
                  _shootFilterKey,
                  _liveIntensity.clamp(0.0, 1.0),
                );
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] 🎨 Filter re-applied after ultra wide switch (maybeSwitch): key=$_shootFilterKey, intensity=$_liveIntensity',
                  );
                }
              }
            }
          })
          .whenComplete(() {
            _isNativeLensSwitching = false;
          });
    } else if (_nativeLensKind == 'ultraWide' &&
        uiZoom > exitUltraWideThreshold) {
      _isNativeLensSwitching = true;
      _cameraEngine
          .switchToWideIfAvailable()
          .then((result) {
            if (!mounted) return;
            if (result != null) {
              setState(() {
                _nativeLensKind = (result['lensKind'] as String?) ?? 'wide';
              });
              // 🔥🔥🔥 일반 카메라 앱처럼 자연스러운 줌: 렌즈 전환 후 즉시 줌 재적용
              // 렌즈 전환 시 네이티브에서 기본값으로 리셋될 수 있으므로 원하는 줌 값을 즉시 재설정
              // 🔥🔥🔥 iOS 기본 카메라 앱과 동일: 렌즈 전환 후 요청한 줌 값을 정확히 설정
              // 렌즈 전환 시 네이티브에서 minZoom(1.0)으로 초기 설정되므로, 요청한 줌 값을 즉시 재설정
              // 1.0을 요청하면 1.0으로, 1.5를 요청하면 1.5로 정확히 설정되어야 함
              if (_cameraEngine.isInitialized) {
                // 🔥🔥🔥 렌즈 전환 직후 즉시 줌 재적용: 요청한 값을 정확히 설정
                // 네이티브에서 minZoom(1.0)으로 초기 설정되었지만, Flutter에서 요청한 값을 정확히 설정
                Future.delayed(const Duration(milliseconds: 30), () {
                  if (mounted && _cameraEngine.isInitialized) {
                    _cameraEngine.setZoom(uiZoom);
                    if (kDebugMode) {
                      debugPrint(
                        '[Zoom] Wide switched, zoom set to ${uiZoom.toStringAsFixed(3)} (requested value)',
                      );
                    }
                  }
                });
                // 🔥 두 번째 재적용으로 네이티브에서 정확히 설정되도록 보장
                Future.delayed(const Duration(milliseconds: 100), () {
                  if (mounted && _cameraEngine.isInitialized) {
                    _cameraEngine.setZoom(uiZoom);
                    if (kDebugMode) {
                      debugPrint(
                        '[Zoom] Wide switched, zoom reapplied: ${uiZoom.toStringAsFixed(3)}',
                      );
                    }
                  }
                });
              }
              // 🔥 필터 유지: 일반 광각 전환 후 필터를 다시 적용하여 필터가 사라지지 않도록 함
              if (_isNativeCameraActive) {
                _applyFilterIfChanged(
                  _shootFilterKey,
                  _liveIntensity.clamp(0.0, 1.0),
                );
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] 🎨 Filter re-applied after wide switch (maybeSwitch): key=$_shootFilterKey, intensity=$_liveIntensity',
                  );
                }
              }
            }
          })
          .whenComplete(() {
            _isNativeLensSwitching = false;
          });
    }
  }

  // 아이콘 이미지 캐시
  ui.Image? _dogIconImage;
  ui.Image? _catIconImage;
  // 🔥 프리뷰와 동일: 아이콘 Base64 캐시 (저장 시 사용)
  String? _dogIconBase64;
  String? _catIconBase64;

  // Mockup 이미지 비율 캐시
  double? _mockupAspectRatio;

  @override
  void initState() {
    super.initState();
    // 🔥 앱 구동 시간 측정 시작
    _appStartTime = DateTime.now();
    debugPrint('[Petgram] HomePage.initState() START');
    
    // 🔥🔥🔥 성능 최적화: 스플래시 즉시 제거 (initState에서 가능한 한 빨리)
    // build()에서 addPostFrameCallback을 기다리지 않고 initState에서 즉시 제거
    // Future.microtask를 사용하여 가능한 한 빨리 실행 (addPostFrameCallback보다 빠름)
    if (!_hasRemovedSplash) {
      _hasRemovedSplash = true;
      // Future.microtask를 사용하여 가능한 한 빨리 실행
      Future.microtask(() {
        try {
          _splashRemoveTime = DateTime.now();
          FlutterNativeSplash.remove();
          if (_appStartTime != null) {
            final splashTime = _splashRemoveTime!.difference(_appStartTime!).inMilliseconds;
            final logMsg = '[Petgram] ✅ Splash removed in initState (as early as possible) - ${splashTime}ms from initState';
            // 🔥 릴리스 모드에서도 로그 출력: print + 파일 저장
            print(logMsg);
            _saveDebugLogToFile(logMsg);
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[Petgram] ⚠️ Failed to remove splash: $e');
          }
        }
      });
    }
    
    // 앱 라이프사이클 관찰자 등록 (화면 이동 시 리소스 해제용)
    WidgetsBinding.instance.addObserver(this);

    // 🔥 카메라 제어용 MethodChannel 초기화 (핸들러 등록 전에 초기화)
    _cameraControlChannel = const MethodChannel('petgram/camera_control');

    // 카메라 엔진 초기화
    _cameraEngine = CameraEngine();

    // 🔥 시뮬레이터 및 실기기 초기화 전 대응:
    // iOS는 실기기에서도 cameras가 비어있으므로 (main.dart),
    // 일단 Mock 이미지를 보여주기 위해 센서 비율을 9:16으로 초기화함 (짤림 방지)
    // 🔥 스플래시 멈춤 방지: initializeMock도 첫 프레임 렌더링 후에 실행
    if (widget.cameras.isEmpty) {
      _sensorAspectRatio = 9.0 / 16.0;
      // initializeMock은 addPostFrameCallback 안으로 이동
    }
    // 🔥 성능 최적화: addListener에서 setState 최소화
    // 전체 위젯 트리 재빌드를 방지하기 위해 필요한 경우에만 setState 호출
    // 🔥 필터 유지: 카메라 상태 변경 시 필터를 다시 적용하여 필터가 사라지지 않도록 함
    bool _lastCameraInitializedState = false;
    bool _lastSessionRunningState = false;
    bool _lastHasFirstFrameState = false;
    bool _zoomRestoreInProgress = false; // 🔥🔥🔥 중복 호출 방지 플래그
    _cameraEngine.addListener(() {
      // 🔥 성능 최적화: 상태가 실제로 변경된 경우에만 처리
      final bool currentInitialized = _cameraEngine.isInitialized;
      final bool currentSessionRunning = _cameraEngine.sessionRunning ?? false;
      final bool currentHasFirstFrame = _cameraEngine.lastDebugState?.hasFirstFrame ?? false;
      
      // 🔥🔥🔥 핵심 수정: 사용자가 줌을 설정하는 중이면 동기화 로직 스킵 (중복 호출 방지)
      if (_isSettingZoom) {
        return;
      }
      
      // 🔥🔥🔥 백그라운드 복귀 시 복원: 세션이 실행 중이고 첫 프레임이 수신되면 복원
      // 네이티브 세션이 완전히 준비된 후에만 복원 실행 (단순화)
      // 🔥🔥🔥 핵심 수정: 세션이 실행 중이고 첫 프레임이 수신되면 복원 (백그라운드 복귀 여부와 무관)
      // 🔥🔥🔥 성능 최적화: 중복 호출 방지 (이미 복원 중이면 스킵)
      if (currentSessionRunning && 
          currentHasFirstFrame && 
          !_lastHasFirstFrameState && 
          !_shouldUseMockCamera &&
          _savedZoomScaleBeforeBackground != null &&
          !_zoomRestoreInProgress) {
        // 🔥🔥🔥 중복 호출 방지 플래그 설정
        _zoomRestoreInProgress = true;
        // 🔥🔥🔥 백그라운드 복귀 시 무조건 1.0으로 고정
        
        // 🔥🔥🔥 Flutter 상태 즉시 1.0으로 설정
        if (mounted) {
          setState(() {
            _uiZoomScale = 1.0;
            _baseUiZoomScale = 1.0;
          });
          if (kDebugMode) {
            debugPrint('[Petgram] 🔄 Background resume: Zoom fixed to 1.0x (ignoring saved value)');
          }
        }
        
        // 🔥🔥🔥 네이티브가 자동으로 줌을 복원한 후, 실제 복원된 줌 값을 Flutter UI에 동기화
        // 네이티브의 pauseSession에서 줌 값을 저장하고, resumeSession에서 자동 복원
        // 복원 후 실제 줌 값을 가져와서 Flutter UI에 반영 (세션이 완전히 준비된 후에만)
        // 🔥🔥🔥 카메라 죽음 방지: 세션이 완전히 안정화될 때까지 충분히 대기
        Future.delayed(const Duration(milliseconds: 2000), () async {
          if (!mounted || !_cameraEngine.isInitialized) {
            _zoomRestoreInProgress = false;
            return;
          }
          
          // 🔥🔥🔥 세션 상태 안정성 확인: 최소 2번 연속 확인하여 세션이 안정적인지 검증
          for (int stabilityCheck = 0; stabilityCheck < 2; stabilityCheck++) {
            if (stabilityCheck > 0) {
              await Future.delayed(const Duration(milliseconds: 300));
            }
            
            if (!mounted || !_cameraEngine.isInitialized) {
              _zoomRestoreInProgress = false;
              return;
            }
            
            final debugState = await _cameraEngine.getDebugState();
            if (debugState == null) {
              if (kDebugMode && stabilityCheck == 0) {
                debugPrint('[Petgram] ⚠️ Background resume: Cannot sync zoom, debugState is null');
              }
              _zoomRestoreInProgress = false;
              return;
            }
            
            final sessionRunning = debugState['sessionRunning'] as bool? ?? false;
            final hasFirstFrame = debugState['hasFirstFrame'] as bool? ?? false;
            
            // 🔥🔥🔥 세션이 완전히 준비되지 않았으면 스킵 (카메라 죽음 방지)
            if (!sessionRunning || !hasFirstFrame) {
              if (kDebugMode && stabilityCheck == 0) {
                debugPrint('[Petgram] ⚠️ Background resume: Session not ready yet (sessionRunning=$sessionRunning, hasFirstFrame=$hasFirstFrame), skipping zoom sync');
              }
              _zoomRestoreInProgress = false;
              return;
            }
          }
          
          // 🔥🔥🔥 세션이 안정적으로 실행 중임을 확인했으므로 추가 안정화 대기
          await Future.delayed(const Duration(milliseconds: 300));
          
          // 🔥🔥🔥 핵심 수정: 세션 상태 최종 재확인 (카메라가 죽지 않았는지 확인)
          if (!mounted || !_cameraEngine.isInitialized) {
            _zoomRestoreInProgress = false;
            return;
          }
          
          final finalDebugState = await _cameraEngine.getDebugState();
          if (finalDebugState == null) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Cannot sync zoom, debugState is null after final check');
            }
            _zoomRestoreInProgress = false;
            return;
          }
          
          final finalSessionRunning = finalDebugState['sessionRunning'] as bool? ?? false;
          final finalHasFirstFrame = finalDebugState['hasFirstFrame'] as bool? ?? false;
          
          // 🔥🔥🔥 세션이 죽었으면 스킵 (카메라 죽음 방지)
          if (!finalSessionRunning || !finalHasFirstFrame) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Session not stable, skipping zoom sync (sessionRunning=$finalSessionRunning, hasFirstFrame=$finalHasFirstFrame)');
            }
            _zoomRestoreInProgress = false;
            return;
          }
          
          try {
            // 🔥🔥🔥 백그라운드 복귀 시 무조건 1.0으로 고정
            // 🔥🔥🔥 핵심 수정: 세션이 재시작되면 iOS가 자동으로 최저 배율(0.5배)로 초기화하므로
            // wide 렌즈로 먼저 전환한 후 1.0으로 설정해야 함
            bool wideLensSwitched = false;
            if (_cameraLensDirection == CameraLensDirection.back) {
              // 🔥🔥🔥 wide 렌즈로 전환 (ultraWide에서 0.5배로 초기화되는 것을 방지)
              await _cameraEngine.switchToWideIfAvailable();
              wideLensSwitched = true;
              await Future.delayed(const Duration(milliseconds: 200)); // 렌즈 전환 대기 (300ms → 200ms)
            }
            
            final requestedZoom = 1.0;
            final actualZoom = await _cameraEngine.setZoom(requestedZoom).timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                if (kDebugMode) {
                  debugPrint('[Petgram] ⚠️ Background resume: Zoom sync timeout');
                }
                return null;
              },
            );
            
            if (mounted && actualZoom != null) {
              // 🔥🔥🔥 백그라운드 복귀 시 무조건 1.0으로 고정
              // 실제 값이 1.0이 아니거나 0.5면 무조건 재시도
              final zoomDiff = (actualZoom - 1.0).abs();
              
              // 🔥🔥🔥 핵심 수정: actualZoom이 0.5면 무조건 재시도 (ultraWide에 있는 경우)
              if (zoomDiff > 0.1 || actualZoom == 0.5) {
                // 🔥🔥🔥 UI는 즉시 1.0으로 설정
                setState(() {
                  _uiZoomScale = 1.0;
                  _baseUiZoomScale = 1.0;
                });
                if (kDebugMode) {
                  debugPrint('[Petgram] 🔄 Background resume: Forcing 1.0x (actual=${actualZoom.toStringAsFixed(2)}, will retry)');
                }
                // 🔥🔥🔥 네이티브에 1.0을 다시 설정 (재시도 로직 최적화: 5번 → 3번, 지연 시간 단축)
                Future.delayed(const Duration(milliseconds: 500), () async {
                  if (!mounted || !_cameraEngine.isInitialized) {
                    _zoomRestoreInProgress = false;
                    return;
                  }
                  
                  // 🔥🔥🔥 성능 최적화: 최대 3번 재시도 (5번 → 3번)
                  for (int retry = 0; retry < 3; retry++) {
                    if (retry > 0) {
                      await Future.delayed(const Duration(milliseconds: 300)); // 지연 시간 단축 (500ms → 300ms)
                    }
                    
                    if (!mounted || !_cameraEngine.isInitialized) break;
                    
                    // 🔥🔥🔥 세션 상태 재확인: 재시도 중에도 세션이 살아있는지 확인
                    final recheckState = await _cameraEngine.getDebugState();
                    if (recheckState == null) {
                      _zoomRestoreInProgress = false;
                      break; // 세션이 죽었으면 즉시 중단
                    }
                    
                    final sessionRunning = recheckState['sessionRunning'] as bool? ?? false;
                    final hasFirstFrame = recheckState['hasFirstFrame'] as bool? ?? false;
                    
                    if (!sessionRunning || !hasFirstFrame) {
                      _zoomRestoreInProgress = false;
                      break; // 세션이 죽었으면 즉시 중단
                    }
                    
                    try {
                      // 🔥🔥🔥 성능 최적화: wide 렌즈로 이미 전환했으면 다시 전환하지 않음 (첫 재시도에서만)
                      if (_cameraLensDirection == CameraLensDirection.back && !wideLensSwitched && retry == 0) {
                        await _cameraEngine.switchToWideIfAvailable();
                        await Future.delayed(const Duration(milliseconds: 200));
                      }
                      
                      final reapplyZoom = await _cameraEngine.setZoom(1.0).timeout(
                        const Duration(seconds: 2),
                        onTimeout: () => null,
                      );
                      
                      if (mounted && reapplyZoom != null) {
                        // 🔥🔥🔥 핵심 수정: actualZoom이 0.5면 무조건 재시도 (ultraWide에 있는 경우)
                        if (reapplyZoom == 0.5 || reapplyZoom < 0.6) {
                          if (kDebugMode && retry < 2) {
                            debugPrint('[Petgram] ⚠️ Background resume: Still at ${reapplyZoom.toStringAsFixed(2)}x, retrying... (retry=$retry)');
                          }
                          continue; // 0.5면 계속 재시도
                        }
                        
                        // 실제 값이 1.0에 가까우면 성공
                        if ((reapplyZoom - 1.0).abs() < 0.2) {
                          setState(() {
                            _uiZoomScale = reapplyZoom;
                            _baseUiZoomScale = reapplyZoom;
                            _nativeLensKind = 'wide'; // wide 렌즈로 설정됨
                          });
                          if (kDebugMode) {
                            debugPrint('[Petgram] ✅ Background resume: 1.0x applied (actual=${reapplyZoom.toStringAsFixed(2)}, retry=$retry)');
                          }
                          // 🔥🔥🔥 성능 최적화: 성공 시 즉시 플래그 리셋
                          _zoomRestoreInProgress = false;
                          _savedZoomScaleBeforeBackground = null;
                          return; // 성공 시 즉시 리턴
                        }
                      }
                    } catch (e) {
                      if (kDebugMode && retry == 0) {
                        debugPrint('[Petgram] ⚠️ Background resume: Error (retry=$retry): $e');
                      }
                    }
                  }
                  // 🔥🔥🔥 재시도 실패 시에도 플래그 리셋
                  _zoomRestoreInProgress = false;
                });
              } else {
                // 이미 1.0에 가까우면 성공
                setState(() {
                  _nativeLensKind = 'wide'; // wide 렌즈로 설정됨
                });
                if (kDebugMode) {
                  debugPrint('[Petgram] ✅ Background resume: 1.0x fixed (actual=${actualZoom.toStringAsFixed(2)})');
                }
                // 🔥🔥🔥 성능 최적화: 성공 시 즉시 플래그 리셋
                _zoomRestoreInProgress = false;
                _savedZoomScaleBeforeBackground = null;
              }
            } else {
              // 🔥🔥🔥 타임아웃 또는 에러 시: UI는 이미 1.0으로 설정되어 있음
              if (kDebugMode) {
                debugPrint('[Petgram] ⚠️ Background resume: Zoom fix timeout, UI already set to 1.0x');
              }
              _zoomRestoreInProgress = false;
            }
          } catch (e) {
            // 🔥🔥🔥 줌 동기화 실패해도 카메라가 죽지 않도록 예외 처리
            // UI는 이미 1.0으로 설정되어 있음
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Zoom fix error, UI already set to 1.0x (error=$e)');
            }
            // 🔥🔥🔥 성능 최적화: 에러 발생 시에도 플래그 리셋
            _zoomRestoreInProgress = false;
          }
        });
        
        // 🔥🔥🔥 비율 복원 (세션이 준비된 후에만 실행 - 카메라 죽음 방지)
        Future.delayed(const Duration(milliseconds: 500), () async {
          if (!mounted || !_cameraEngine.isInitialized) return;
          
          // 🔥🔥🔥 세션 상태 확인: 세션이 완전히 준비되었는지 확인
          final debugState = await _cameraEngine.getDebugState();
          if (debugState == null) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Cannot restore aspect ratio, debugState is null');
            }
            return;
          }
          
          final sessionRunning = debugState['sessionRunning'] as bool? ?? false;
          final hasFirstFrame = debugState['hasFirstFrame'] as bool? ?? false;
          
          // 🔥🔥🔥 세션이 완전히 준비되지 않았으면 스킵 (카메라 죽음 방지)
          if (!sessionRunning || !hasFirstFrame) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Session not ready yet (sessionRunning=$sessionRunning, hasFirstFrame=$hasFirstFrame), skipping aspect ratio restore');
            }
            return;
          }
          
          if (!mounted) return;
          final targetRatio = _getTargetAspectRatio();
          final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
          if (rootBox != null && rootBox.hasSize) {
            // 🔥🔥🔥 SafeArea 고려: 노치바 영역 제외
            final MediaQueryData mediaQuery = MediaQuery.of(context);
            final double safeAreaTop = mediaQuery.padding.top;
            final double safeAreaBottom = mediaQuery.padding.bottom;
            
            final double maxWidth = rootBox.size.width;
            final double maxHeight = rootBox.size.height - safeAreaTop - safeAreaBottom; // SafeArea 제외
            
            double width, height;
            // 🔥🔥🔥 9:16 비율 특별 처리: 세로가 긴 비율이므로 세로를 기준으로 계산
            final bool isNineSixteen = (targetRatio - (9.0 / 16.0)).abs() < 0.001;
            if (targetRatio > 1.0) {
              // 가로가 긴 비율 (예: 16:9)
              height = maxHeight;
              width = height * targetRatio;
              if (width > maxWidth) {
                width = maxWidth;
                height = width / targetRatio;
              }
            } else if (targetRatio < 1.0) {
              // 세로가 긴 비율 (예: 9:16, 3:4)
              // 🔥🔥🔥 9:16은 세로가 매우 길므로 세로를 최대한 보존
              height = maxHeight;
              width = height * targetRatio;
              if (width > maxWidth && !isNineSixteen) {
                // 9:16이 아닌 경우에만 가로를 기준으로 재계산 (3:4 등)
                width = maxWidth;
                height = width / targetRatio;
              }
              // 🔥🔥🔥 9:16 비율은 가로가 화면을 넘어도 세로를 보존 (가로는 좌우로 잘림)
            } else {
              // 1:1 비율
              final double minDimension = math.min(maxWidth, maxHeight);
              width = minDimension;
              height = minDimension;
            }
            
            // 🔥🔥🔥 SafeArea를 고려한 위치 계산: 상단 SafeArea만큼 아래로 이동
            final double top = safeAreaTop + (maxHeight - height) / 2;
            final double left = (maxWidth - width) / 2;
            final Offset globalTopLeft = rootBox.localToGlobal(Offset(left, top));
            final Rect rectToSync = Rect.fromLTWH(
              globalTopLeft.dx,
              globalTopLeft.dy,
              width,
              height,
            );
            
            // 🔥🔥🔥 성능 최적화: 비율 복원 성공 시 _lastSyncedPreviewRect 업데이트하여 중복 복원 방지
            _lastSyncedPreviewRect = rectToSync; // 복원 성공 시 업데이트
            _syncPreviewRectToNativeFromLocal(rectToSync, context);
            _syncPreviewRectWithRetry(rectToSync, context);
            
            if (kDebugMode) {
              debugPrint('[Petgram] 🔄 Background resume: Aspect ratio restored to ${targetRatio.toStringAsFixed(3)} (width=${width.toStringAsFixed(1)}, height=${height.toStringAsFixed(1)})');
            }
            
            // 🔥🔥🔥 성능 최적화: 빈 setState() 제거
            // 비율 동기화는 이미 _syncPreviewRectToNativeFromLocal에서 처리됨
          }
        });
        
        // 🔥🔥🔥 추가 비율 복원 시도 (네이티브가 덮어쓸 수 있으므로) - 세션이 준비된 후에만 실행
        // 🔥🔥🔥 성능 최적화: 첫 번째 복원이 성공했으면 두 번째 복원 스킵 (중복 방지)
        Future.delayed(const Duration(milliseconds: 1200), () async {
          if (!mounted || !_cameraEngine.isInitialized) return;
          
          // 🔥🔥🔥 성능 최적화: 이미 복원되었으면 스킵
          if (_lastSyncedPreviewRect != null) {
            final currentRatio = _lastSyncedPreviewRect!.width / _lastSyncedPreviewRect!.height;
            final targetRatio = _getTargetAspectRatio();
            final ratioDiff = (currentRatio - targetRatio).abs();
            // 비율 차이가 0.05 이하면 이미 복원된 것으로 간주
            if (ratioDiff < 0.05) {
              if (kDebugMode) {
                debugPrint('[Petgram] ⏭️ Background resume: Aspect ratio already restored (ratioDiff=${ratioDiff.toStringAsFixed(3)}), skipping retry');
              }
              return;
            }
          }
          
          // 🔥🔥🔥 세션 상태 확인: 세션이 완전히 준비되었는지 확인
          final debugState = await _cameraEngine.getDebugState();
          if (debugState == null) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Cannot restore aspect ratio (retry), debugState is null');
            }
            return;
          }
          
          final sessionRunning = debugState['sessionRunning'] as bool? ?? false;
          final hasFirstFrame = debugState['hasFirstFrame'] as bool? ?? false;
          
          // 🔥🔥🔥 세션이 완전히 준비되지 않았으면 스킵 (카메라 죽음 방지)
          if (!sessionRunning || !hasFirstFrame) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Background resume: Session not ready yet (retry, sessionRunning=$sessionRunning, hasFirstFrame=$hasFirstFrame), skipping aspect ratio restore');
            }
            return;
          }
          
          if (!mounted) return;
          final targetRatio = _getTargetAspectRatio();
          final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
          if (rootBox != null && rootBox.hasSize) {
            // 🔥🔥🔥 SafeArea 고려: 노치바 영역 제외
            final MediaQueryData mediaQuery = MediaQuery.of(context);
            final double safeAreaTop = mediaQuery.padding.top;
            final double safeAreaBottom = mediaQuery.padding.bottom;
            
            final double maxWidth = rootBox.size.width;
            final double maxHeight = rootBox.size.height - safeAreaTop - safeAreaBottom; // SafeArea 제외
            
            double width, height;
            // 🔥🔥🔥 9:16 비율 특별 처리: 세로가 긴 비율이므로 세로를 기준으로 계산
            final bool isNineSixteen = (targetRatio - (9.0 / 16.0)).abs() < 0.001;
            if (targetRatio > 1.0) {
              // 가로가 긴 비율 (예: 16:9)
              height = maxHeight;
              width = height * targetRatio;
              if (width > maxWidth) {
                width = maxWidth;
                height = width / targetRatio;
              }
            } else if (targetRatio < 1.0) {
              // 세로가 긴 비율 (예: 9:16, 3:4)
              // 🔥🔥🔥 9:16은 세로가 매우 길므로 세로를 최대한 보존
              height = maxHeight;
              width = height * targetRatio;
              if (width > maxWidth && !isNineSixteen) {
                // 9:16이 아닌 경우에만 가로를 기준으로 재계산 (3:4 등)
                width = maxWidth;
                height = width / targetRatio;
              }
              // 🔥🔥🔥 9:16 비율은 가로가 화면을 넘어도 세로를 보존 (가로는 좌우로 잘림)
            } else {
              // 1:1 비율
              final double minDimension = math.min(maxWidth, maxHeight);
              width = minDimension;
              height = minDimension;
            }
            
            // 🔥🔥🔥 SafeArea를 고려한 위치 계산: 상단 SafeArea만큼 아래로 이동
            final double top = safeAreaTop + (maxHeight - height) / 2;
            final double left = (maxWidth - width) / 2;
            final Offset globalTopLeft = rootBox.localToGlobal(Offset(left, top));
            final Rect rectToSync = Rect.fromLTWH(
              globalTopLeft.dx,
              globalTopLeft.dy,
              width,
              height,
            );
            
            // 🔥🔥🔥 성능 최적화: 비율 복원 성공 시 _lastSyncedPreviewRect 업데이트
            _lastSyncedPreviewRect = rectToSync; // 복원 성공 시 업데이트
            _syncPreviewRectToNativeFromLocal(rectToSync, context);
            _syncPreviewRectWithRetry(rectToSync, context);
            
            if (kDebugMode) {
              debugPrint('[Petgram] 🔄 Background resume: Aspect ratio restored again to ${targetRatio.toStringAsFixed(3)} (retry, width=${width.toStringAsFixed(1)}, height=${height.toStringAsFixed(1)}, safeAreaTop=${safeAreaTop.toStringAsFixed(1)})');
            }
          }
        });
        
        // 🔥🔥🔥 핵심 수정: _savedZoomScaleBeforeBackground는 줌 복원 로직에서만 초기화
        // 여기서는 초기화하지 않음 (줌 복원이 완료된 후에만 초기화)
        // _savedZoomScaleBeforeBackground = null; // 🔥 제거: 줌 복원 로직에서만 초기화
      }
      
      // 🔥🔥🔥 추가 보호: 줌이 0.5로 초기화되었을 때 자동 복원 제거
      // 0.5배는 유효한 선택이므로 1.0으로 강제 변경하지 않음
      // 이 로직은 제거: 0.5배를 선택한 경우 그대로 유지해야 함
      
      // 상태 업데이트
      _lastSessionRunningState = currentSessionRunning;
      _lastHasFirstFrameState = currentHasFirstFrame;
      
      // 상태가 변경되지 않았으면 early return
      if (currentInitialized == _lastCameraInitializedState) {
        return;
      }

      // 🔥🔥🔥 근본 원인 해결: 카메라 초기화 완료를 기다리지 않고, 첫 프레임이 렌더링되면 바로 스플래시 제거
      // 카메라 초기화가 실패하거나 지연되어도 화면 진입이 가능하도록 함

      // 🔥 자동 포커스 모드 활성화 체크 (ready 상태로 전환될 때)
      if (currentInitialized &&
          !_lastCameraInitializedState &&
          !_shouldUseMockCamera) {
        // 🔥 카메라 초기화 완료 시간 기록
        _cameraInitTime = DateTime.now();
        if (_appStartTime != null) {
          final initTime = _cameraInitTime!.difference(_appStartTime!).inMilliseconds;
          final logMsg = '[Petgram] ⏱️ Camera initialized: ${initTime}ms from initState';
          // 🔥 릴리스 모드에서도 로그 출력: print + 파일 저장
          print(logMsg);
          _saveDebugLogToFile(logMsg);
        }
        
        if (mounted) {
          setState(() {
            _isAutoFocusEnabled = true;
          });
          
          // 🔥🔥🔥 줌 배율 정상화: 카메라 초기화 완료 후 기본 줌을 1.0으로 명시적으로 설정
          // 네이티브에서 1.0으로 초기화했지만, 초광각 렌즈로 전환되는 것을 방지하기 위해
          // wide 렌즈를 사용하고 1.0 줌을 명시적으로 설정
          // 🔥 성능 최적화: 초기화 지연 단축 (500ms → 200ms)
          _isInitialZoomSetting = true; // 🔥🔥🔥 초기 줌 설정 중 플래그 설정
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted && _cameraEngine.isInitialized && !_shouldUseMockCamera) {
              // wide 렌즈로 전환 (초광각이 아닌 일반 광각 사용)
              if (_cameraLensDirection == CameraLensDirection.back) {
                _cameraEngine.switchToWideIfAvailable().then((_) {
                  if (mounted && _cameraEngine.isInitialized) {
                    // 🔥🔥🔥 줌을 1.0으로 명시적으로 설정하고 실제 값 확인하여 동기화
                    _cameraEngine.setZoom(1.0).then((actualZoom) {
                      if (mounted) {
                        // 🔥🔥🔥 네이티브의 실제 줌 값으로 Flutter 상태 동기화
                        final syncZoom = actualZoom ?? 1.0;
                        setState(() {
                          _uiZoomScale = syncZoom;
                          _baseUiZoomScale = syncZoom;
                          _nativeLensKind = 'wide';
                          _isInitialZoomSetting = false; // 🔥🔥🔥 초기 줌 설정 완료
                        });
                        if (kDebugMode) {
                          debugPrint('[Petgram] ✅ Camera initialized: zoom set to ${syncZoom.toStringAsFixed(2)}x (requested=1.0, actual=$actualZoom), wide lens active');
                        }
                      }
                    }).catchError((error) {
                      if (mounted) {
                        setState(() {
                          _isInitialZoomSetting = false;
                        });
                      }
                      if (kDebugMode) {
                        debugPrint('[Petgram] ⚠️ Failed to sync zoom after setZoom: $error');
                      }
                    });
                  }
                }).catchError((error) {
                  // 렌즈 전환 실패 시에도 플래그 리셋
                  if (mounted) {
                    setState(() {
                      _isInitialZoomSetting = false;
                    });
                  }
                  if (kDebugMode) {
                    debugPrint('[Petgram] ⚠️ Failed to switch to wide lens: $error');
                  }
                });
              } else {
                // 🔥🔥🔥 전면 카메라 줌 문제 해결: 초기화 시 1.0으로 설정하고 실제 값 확인하여 동기화
                // 전면 카메라도 1배가 기본이 되어야 하므로, 1.0으로 설정
                _cameraEngine.setZoom(1.0).then((actualZoom) {
                  if (mounted) {
                    // 🔥🔥🔥 네이티브의 실제 줌 값으로 Flutter 상태 동기화
                    final syncZoom = actualZoom ?? 1.0;
                    setState(() {
                      _uiZoomScale = syncZoom;
                      _baseUiZoomScale = syncZoom;
                      _isInitialZoomSetting = false;
                    });
                    if (kDebugMode) {
                      debugPrint('[Petgram] ✅ Camera initialized: zoom set to ${syncZoom.toStringAsFixed(2)}x (requested=1.0, actual=$actualZoom, direction=${_cameraLensDirection == CameraLensDirection.front ? "front" : "back"})');
                    }
                  }
                }).catchError((error) {
                  // 줌 설정 실패 시에도 플래그 리셋
                  if (mounted) {
                    setState(() {
                      _isInitialZoomSetting = false;
                    });
                  }
                  if (kDebugMode) {
                    debugPrint('[Petgram] ⚠️ Failed to set zoom to 1.0: $error');
                  }
                });
              }
            } else {
              // 초기화 실패 시에도 플래그 리셋
              if (mounted) {
                setState(() {
                  _isInitialZoomSetting = false;
                });
              }
            }
          });
          _startFocusStatusPolling();
        }
      }

      // 🔥 필터 유지: 카메라가 초기화되면 필터를 다시 적용
      if (currentInitialized && !_lastCameraInitializedState) {
        // 🔥 성능 최적화: 백그라운드 복귀 시 비율 유지 (초기화하지 않음)
        // 카메라가 준비되었어도 기존 비율을 유지하고, 비율이 실제로 변경되었을 때만 동기화
        if (_isResumingCamera && kDebugMode) {
          final targetRatio = _getTargetAspectRatio();
          debugPrint(
            '[Petgram] ✅ Camera ready after resume: Preserving aspect ratio (targetRatio=${targetRatio.toStringAsFixed(3)}, aspectMode=$_aspectMode)',
          );
        }
        
        // 카메라가 방금 초기화됨 → 필터 다시 적용
        if (_isNativeCameraActive) {
          _applyFilterIfChanged(
            _shootFilterKey,
            _liveIntensity.clamp(0.0, 1.0),
          );
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🎨 Filter re-applied after camera state change: key=$_shootFilterKey, intensity=$_liveIntensity',
            );
          }
        }
      }
      _lastCameraInitializedState = currentInitialized;
    });

    // 🔥 카메라 제어용 MethodChannel 핸들러 설정 (FilterPage와 통신)
    _cameraControlChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pauseCamera':
          _pauseCameraSession();
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 📱 Camera paused via MethodChannel from FilterPage',
            );
          }
          break;
        case 'resumeCamera':
          _resumeCameraSession();
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 📱 Camera resumed via MethodChannel from FilterPage',
            );
          }
          break;
        default:
          if (kDebugMode) {
            debugPrint('[Petgram] ⚠️ Unknown method call: ${call.method}');
          }
      }
    });

    // 디버그 로그: 플랫폼 및 카메라 상태 확인
    if (kDebugMode) {
      debugPrint(
        '[Petgram] HomePage: platform=${Platform.isIOS
            ? "iOS"
            : Platform.isAndroid
            ? "Android"
            : "Other"}, '
        'cameras.length=${widget.cameras.length}, '
        'useMock=$_shouldUseMockCamera',
      );
    }

    // 🔥 스플래시 멈춤 방지: initState에서 모든 블로킹 작업 완전 제거
    // flutter_native_splash는 첫 프레임이 렌더링되면 자동으로 사라지므로
    // 첫 프레임 렌더링을 방해하는 모든 작업을 제거
    // 모든 초기화 작업은 첫 프레임 렌더링 후에 실행되도록 지연
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 🔥🔥🔥 타임아웃 백업: 1초 내에 첫 프레임이 렌더링되지 않으면 스플래시 강제 제거
      // 🔥 성능 최적화: 타임아웃 제거 (스플래시는 이미 build()에서 즉시 제거됨)
      // 카메라 초기화는 백그라운드에서 비동기로 처리되므로 타임아웃 불필요
      
      // 🔥 성능 최적화: 지연 제거 (초기화 작업은 비동기로 처리되므로 블로킹 없음)
      // 첫 프레임이 렌더링된 후에 모든 초기화 작업 실행 (지연 없이 즉시)
      if (!mounted) return;
      
      // 🔥 Mock 카메라 초기화 (첫 프레임 렌더링 후)
      if (widget.cameras.isEmpty && !Platform.isIOS) {
        _cameraEngine.initializeMock(aspectRatio: _getTargetAspectRatio()).then((_) {
          // 🔥 성능 최적화: 스플래시는 이미 build()에서 제거되었으므로 여기서는 제거하지 않음
          if (kDebugMode) {
            debugPrint('[Petgram] ✅ Mock camera initialized (splash already removed)');
          }
        }).catchError((e) {
          if (kDebugMode) {
            debugPrint('[Petgram] ⚠️ initializeMock error: $e');
          }
          // 🔥 성능 최적화: 스플래시는 이미 build()에서 제거되었으므로 여기서는 제거하지 않음
        });
      }
      
      // 🔥 로딩 문제 해결: 화면 복귀 시 이전 세션 완전히 정리 후 초기화
      // 🔥 필터 페이지에서 돌아올 때 어두워지는 문제 해결:
      //    밝기 값과 노출 바이어스를 리셋하여 기본 밝기로 복원
      setState(() {
        _brightnessValue = 0.0; // 밝기 값 리셋
      });
      
      // 🔥 상태 폴링 시작 (첫 프레임 렌더링 후)
      _startDebugStatePolling();
      
      // 🔥 크래시 디버깅: 앱 시작 시 이전 세션의 로그 불러오기 (비동기, 블로킹 안 함)
      _loadDebugLogsFromFile().catchError((e) {
        if (kDebugMode) {
          debugPrint('[Petgram] ⚠️ _loadDebugLogsFromFile error: $e');
        }
      });
      
      // 🔥 스플래시 멈춤 방지: 모든 비동기 초기화 작업을 첫 프레임 렌더링 후에 실행
      _loadLastSelectedFilter().catchError((e) {
        debugPrint('[Petgram] ⚠️ _loadLastSelectedFilter error: $e');
      });
      _loadPetName().catchError((e) {
        debugPrint('[Petgram] ⚠️ _loadPetName error: $e');
      });
      _loadAllSettings().catchError((e) {
        debugPrint('[Petgram] ⚠️ _loadAllSettings error: $e');
      });
      loadFrameResources().catchError((e) {
        debugPrint('[Petgram] ⚠️ loadFrameResources error: $e');
      }); // 프레임 폰트와 로고 미리 로드 (services/frame_resource_service.dart)
      _loadIconImages().catchError((e) {
        debugPrint('[Petgram] ⚠️ _loadIconImages error: $e');
      }); // 아이콘 이미지 미리 로드
    });
    // 🔥 얼굴 인식 기능 전면 OFF: 현재 버전에서는 완전히 비활성화

    // 🔥 스플래시 멈춤 방지: 상태 폴링은 첫 프레임 렌더링 후에 시작
    // addPostFrameCallback에서 시작하도록 이동
    debugPrint('[Petgram] HomePage.initState() END');
  }

  /// 오디오 플레이어 초기화 (셔터음용)

  /// 아이콘 이미지 및 mockup 비율 미리 로드
  Future<void> _loadIconImages() async {
    try {
      final ByteData dogData = await rootBundle.load('assets/icons/dog.png');
      final Uint8List dogBytes = dogData.buffer.asUint8List();
      final ui.Codec dogCodec = await ui.instantiateImageCodec(dogBytes);
      final ui.FrameInfo dogFrameInfo = await dogCodec.getNextFrame();
      _dogIconImage = dogFrameInfo.image;
      // 🔥 프리뷰와 동일: 아이콘 Base64 인코딩 (저장 시 사용)
      final dogByteData = await _dogIconImage!.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (dogByteData != null) {
        _dogIconBase64 = base64Encode(dogByteData.buffer.asUint8List());
      }

      final ByteData catData = await rootBundle.load('assets/icons/cat.png');
      final Uint8List catBytes = catData.buffer.asUint8List();
      final ui.Codec catCodec = await ui.instantiateImageCodec(catBytes);
      final ui.FrameInfo catFrameInfo = await catCodec.getNextFrame();
      _catIconImage = catFrameInfo.image;
      // 🔥 프리뷰와 동일: 아이콘 Base64 인코딩 (저장 시 사용)
      final catByteData = await _catIconImage!.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (catByteData != null) {
        _catIconBase64 = base64Encode(catByteData.buffer.asUint8List());
      }

      // Mockup 이미지 비율 로드
      try {
        final ByteData mockupData = await rootBundle.load(
          'assets/images/mockup.png',
        );
        final Uint8List mockupBytes = mockupData.buffer.asUint8List();
        final ui.Codec mockupCodec = await ui.instantiateImageCodec(
          mockupBytes,
        );
        final ui.FrameInfo mockupFrameInfo = await mockupCodec.getNextFrame();
        final mockupImage = mockupFrameInfo.image;
        _mockupAspectRatio = mockupImage.width / mockupImage.height;
        mockupImage.dispose();
        debugPrint(
          '[Petgram] 📐 Mockup 이미지 비율: ${_mockupAspectRatio} (${mockupImage.width}x${mockupImage.height})',
        );
      } catch (e) {
        debugPrint('[Petgram] ⚠️ Mockup 이미지 비율 로드 실패: $e, 기본값 9/16 사용');
        _mockupAspectRatio = 9 / 16;
      }
      // _catIconImage는 이미 위에서 할당됨
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] Failed to load icon images: $e');
      }
    }
  }

  /// 필터 적용 빈도 최적화: 필터가 변경된 경우에만 네이티브에 전달
  void _applyFilterIfChanged(String filterKey, double intensity) {
    // ⚠️ 중요: iOS 네이티브 카메라가 활성 상태일 때만 필터 적용
    if (!_isNativeCameraActive) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🎨 Filter not applied: native camera not active (isInitialized=${_cameraEngine.isInitialized}, shouldUseMock=$_shouldUseMockCamera)',
        );
      }
      return;
    }

    // 필터 키나 강도가 변경된 경우에만 네이티브에 전달
    if (_lastAppliedFilterKey != filterKey ||
        (_lastAppliedFilterIntensity != null &&
            (_lastAppliedFilterIntensity! - intensity).abs() > 0.01)) {
      _cameraEngine.setFilter(filterKey: filterKey, intensity: intensity);
      _lastAppliedFilterKey = filterKey;
      _lastAppliedFilterIntensity = intensity;

      // 🔥 필터 일치 보장: 프리뷰 필터 변경 시 FilterConfig 로그
      if (kDebugMode) {
        final config = _buildCurrentFilterConfig();
        debugPrint(
          '[Petgram] 🎨 Preview FilterConfig: filterKey=$filterKey, intensity=$intensity, '
          'brightness=${config.brightness}, petTone=${config.petProfile?.id ?? "none"}, '
          'enablePetTone=${config.enablePetToneOnSave}',
        );
      }
    }
  }

  Future<void> _loadLastSelectedFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFilter = prefs.getString(kLastSelectedFilterKey);
    if (savedFilter != null && allFilters.containsKey(savedFilter)) {
      setState(() {
        _shootFilterKey = savedFilter;
      });
      // iOS 네이티브 카메라가 활성 상태라면 저장된 필터 상태를 즉시 동기화
      if (_isNativeCameraActive) {
        _applyFilterIfChanged(_shootFilterKey, _liveIntensity.clamp(0.0, 1.0));
      }
    }
  }

  Future<void> _saveSelectedFilter(String filterKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLastSelectedFilterKey, filterKey);
  }

  Future<void> _loadPetName() async {
    final prefs = await SharedPreferences.getInstance();
    final savedListJson = prefs.getStringList(kPetListKey);
    if (savedListJson != null && savedListJson.isNotEmpty) {
      try {
        final List<PetInfo> loadedPets = savedListJson
            .map(
              (json) => PetInfo.fromJson(
                Map<String, dynamic>.from(
                  (jsonDecode(json) as Map<dynamic, dynamic>).map(
                    (k, v) => MapEntry(k.toString(), v),
                  ),
                ),
              ),
            )
            .toList();
        // 저장된 선택된 반려동물 ID 로드
        final savedSelectedId = prefs.getString(kSelectedPetIdKey);
        setState(() {
          _petList = loadedPets;
          // 저장된 ID가 있고, 해당 반려동물이 리스트에 있으면 사용, 없으면 첫 번째 반려동물
          if (savedSelectedId != null &&
              loadedPets.any((pet) => pet.id == savedSelectedId)) {
            _selectedPetId = savedSelectedId;
          } else {
            _selectedPetId = loadedPets.isNotEmpty ? loadedPets.first.id : null;
          }
        });

        // 반려동물 정보 로드 후, 프레임이 활성화되어 있고 위치 정보가 활성화된 반려동물이 있으면 위치 정보 불러오기
        final frameEnabled = prefs.getBool(kFrameEnabledKey) ?? true;
        if (frameEnabled && _petList.isNotEmpty) {
          final selectedPet = _selectedPetId != null
              ? _petList.firstWhere(
                  (pet) => pet.id == _selectedPetId,
                  orElse: () => _petList.first,
                )
              : _petList.first;

          if (selectedPet.locationEnabled) {
            // 앱 시작 시: 위치 정보 불러오기
            _checkAndFetchLocation();
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('❌ _loadPetName error: $e');
        }
      }
    }
  }

  // 모든 설정 로드
  Future<void> _loadAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 플래시 모드
      final flashModeStr = prefs.getString(kFlashModeKey);
      if (flashModeStr != null) {
        switch (flashModeStr) {
          case 'off':
            _flashMode = FlashMode.off;
            break;
          case 'auto':
            _flashMode = FlashMode.auto;
            break;
          case 'always':
            _flashMode = FlashMode.always;
            break;
          case 'torch':
            _flashMode = FlashMode.torch;
            break;
        }
      }
      // 그리드라인
      _showGridLines = prefs.getBool(kShowGridLinesKey) ?? false;
      // 프레임 활성화
      _frameEnabled = prefs.getBool(kFrameEnabledKey) ?? true;
      // 연속 촬영 모드
      _isBurstMode = prefs.getBool(kBurstModeKey) ?? false;
      // 연속 촬영 매수
      _burstCountSetting = prefs.getInt(kBurstCountSettingKey) ?? 5;
      // 타이머 초
      _timerSeconds = prefs.getInt(kTimerSecondsKey) ?? 0;
      // 화면 비율
      final aspectModeStr = prefs.getString(kAspectModeKey);
      // 🔥🔥🔥 최초 앱 실행 시 3:4 비율로 강제 설정
      // 최초 실행 시 비율 문제를 해결하기 위해 최초 실행인 경우 무조건 3:4로 설정
      if (aspectModeStr == null) {
        // 최초 실행: 3:4로 강제 설정
        _aspectMode = AspectRatioMode.threeFour;
        if (kDebugMode) {
          debugPrint('[Petgram] 🔄 _loadAllSettings: First launch detected, forcing 3:4 aspect ratio');
        }
      } else {
        // 저장된 비율 사용
        switch (aspectModeStr) {
          case 'nineSixteen':
            _aspectMode = AspectRatioMode.nineSixteen;
            break;
          case 'threeFour':
            _aspectMode = AspectRatioMode.threeFour;
            break;
          case 'oneOne':
            _aspectMode = AspectRatioMode.oneOne;
            break;
        }
      }
    });
  }

  // 플래시 모드 저장
  Future<void> _saveFlashMode() async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'off';
    switch (_flashMode) {
      case FlashMode.off:
        modeStr = 'off';
        break;
      case FlashMode.auto:
        modeStr = 'auto';
        break;
      case FlashMode.always:
        modeStr = 'always';
        break;
      case FlashMode.torch:
        modeStr = 'torch';
        break;
    }
    await prefs.setString(kFlashModeKey, modeStr);
  }

  // 그리드라인 저장
  Future<void> _saveShowGridLines() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kShowGridLinesKey, _showGridLines);
  }

  // 프레임 활성화 저장
  Future<void> _saveFrameEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kFrameEnabledKey, _frameEnabled);
  }

  // 연속 촬영 설정 저장
  Future<void> _saveBurstSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBurstModeKey, _isBurstMode);
    await prefs.setInt(kBurstCountSettingKey, _burstCountSetting);
  }

  // 타이머 설정 저장
  Future<void> _saveTimerSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kTimerSecondsKey, _timerSeconds);
  }

  // 화면 비율 저장
  Future<void> _saveAspectMode() async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'threeFour';
    switch (_aspectMode) {
      case AspectRatioMode.nineSixteen:
        modeStr = 'nineSixteen';
        break;
      case AspectRatioMode.threeFour:
        modeStr = 'threeFour';
        break;
      case AspectRatioMode.oneOne:
        modeStr = 'oneOne';
        break;
    }
    await prefs.setString(kAspectModeKey, modeStr);
  }

  /// 퍼포먼스 로그 헬퍼 (kDebugMode에서만 동작)
  void _logPerf(String tag, DateTime start) {
    if (!kDebugMode) return;
    final ms = DateTime.now().difference(start).inMilliseconds;
    debugPrint('[Perf] $tag: ${ms}ms');
  }

  /// 현재 선택된 반려동물의 펫톤 프로파일 가져오기
  PetToneProfile? _getCurrentPetToneProfile() {
    // 1) _petList, _selectedPetId 기반으로 현재 선택된 PetInfo 구하기
    if (_petList.isEmpty || _selectedPetId == null) {
      return null;
    }

    final selectedPet = _petList.firstWhere(
      (pet) => pet.id == _selectedPetId,
      orElse: () => _petList.first,
    );

    // 2) type이 'dog' / 'cat'이 아니면 null 리턴
    if (selectedPet.type != 'dog' && selectedPet.type != 'cat') {
      return null;
    }

    // 3) _liveCoatPreset (light/mid/dark/custom)으로 tone 결정
    String tone = _liveCoatPreset;
    if (tone == 'custom' ||
        (tone != 'light' && tone != 'mid' && tone != 'dark')) {
      // 'custom'이거나 예상 외 값이면 'mid'로 fallback
      tone = 'mid';
    }

    // 4) key = '${type}_${tone}' 형태로 kPetToneProfiles에서 찾아서 리턴
    final String profileKey = '${selectedPet.type}_$tone';
    return kPetToneProfiles[profileKey];
  }

  /// 현재 필터/밝기/펫 프로필 상태를 FilterConfig로 변환
  FilterConfig _buildCurrentFilterConfig() {
    final petProfile = _getCurrentPetToneProfile();
    return FilterConfig(
      filterKey: _shootFilterKey,
      intensity: _liveIntensity,
      brightness: _brightnessValue, // -10 ~ +10 범위 (Flutter 내부용)
      coatPreset: _liveCoatPreset,
      petProfile: petProfile,
      enablePetToneOnSave: _enablePetToneOnSave,
      aspectRatio: aspectRatioOf(_aspectMode),
      enableFrame: _frameEnabled,
    );
  }

  /// [PERF] 동기 버전 _applyColorMatrixToImage 제거됨
  /// 비동기 버전(_applyColorMatrixToImage)만 유지 (FilterPage 등에서 사용)
  /// 메인 저장 경로(_takePhoto)는 GPU 캡처 방식으로 변경됨

  /// 🔥 수정 4: 수동 카메라 재시작 (PlatformView 재생성 포함)
  /// 사용자가 명시적으로 카메라를 재시작할 때만 호출됨
  /// 자동 재초기화는 완전히 제거되었으며, 모든 dispose 책임은 CameraEngine 내부로 몰림
  /// 요구사항: 1) CameraEngine.dispose() (내부에서 nativeCamera.dispose() 호출) 2) Flutter 상태 전환 3) PlatformView 재생성 4) onCreated 재호출
  ///
  /// 🔥 수정 3: 촬영 중 보호 강화 (세션 라이프사이클 분리)
  Future<void> _manualRestartCamera() async {
    if (_isReinitializing) {
      _addDebugLog(
        '[ManualRestart] ⏳ Already reinitializing, skipping duplicate call',
      );
      return;
    }

    if (_lastLifecycleState != AppLifecycleState.resumed) {
      _addDebugLog(
        '[ManualRestart] ⏸️ skip: lifecycle=$_lastLifecycleState (waiting for resumed)',
      );
      return;
    }

    // 🔥 수정 3: 촬영 중 보호 강화 (세션 라이프사이클 분리)
    // 촬영 중에는 세션 재시작/재초기화를 절대 허용하지 않음
    if (_isProcessing || _cameraEngine.isCapturingPhoto) {
      _addDebugLog(
        '[ManualRestart] ⏸️ skip: photo capture in progress (isProcessing=$_isProcessing, isCapturingPhoto=${_cameraEngine.isCapturingPhoto})',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('촬영 중에는 카메라를 재시작할 수 없습니다.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    _isReinitializing = true;
    _addDebugLog('[ManualRestart] 🔄 START: Manual camera restart');

    try {
      // 🔥 보완 포인트 2: CameraEngine.dispose()만 호출 (이중 dispose 방지)
      // CameraEngine.dispose() 내부에서 이미 nativeCamera.dispose()를 호출하므로
      // UI 레이어에서 직접 호출하면 이중 dispose → race → 크래시 위험
      _addDebugLog('[ManualRestart] Resetting CameraEngine state...');
      await _cameraEngine.dispose(); // 모든 dispose 책임은 CameraEngine 내부로 몰기

      // 4. Flutter 상태 초기화
      if (mounted) {
        _addDebugLog('[ManualRestart] PlatformView reset...');
      }

      // 3. 재초기화 대기 (네이티브 정리 시간 확보)
      await Future.delayed(const Duration(milliseconds: 500));

      // 4. 상태 폴링 (lastDebugState 업데이트)
      // 🔥 중복 호출 방지: 타이머가 이미 1초마다 폴링하므로 직접 호출 제거
      // await _pollDebugState();
      _addDebugLog('[ManualRestart] ✅ State will be polled by timer');

      // 5. PlatformView 재생성 완료 대기 (onCreated 재호출 대기)
      _addDebugLog(
        '[ManualRestart] ✅ Reset complete. PlatformView will be recreated and onCreated will be called...',
      );
    } catch (e, stackTrace) {
      _addDebugLog('[ManualRestart] ❌ ERROR: $e');
      _addDebugLog('[ManualRestart] Stack: $stackTrace');
      if (kDebugMode) {
        debugPrint('[ManualRestart] ❌ Error during manual restart: $e');
        debugPrint('[ManualRestart] Stack: $stackTrace');
      }
    } finally {
      _isReinitializing = false;
      _addDebugLog(
        '[ManualRestart] END: Reinitialization flag reset, protection period started (3s)',
      );
    }
  }

  /// 🔥 수정 4: 카메라 초기화 파이프라인 (통일된 로직)
  /// - 실기기에서 카메라가 있으면 무조건 네이티브 카메라 사용
  /// - 시뮬레이터/카메라 없는 경우에만 Mock 사용
  /// - initState()에서 단 한 번만 호출됨
  /// - _useMockCamera 결정은 여기서만 수행하고, 이후 어디에서도 덮어쓰지 않음
  /// - 실기기 + 카메라 있음 → 네이티브 카메라
  /// - 시뮬레이터/카메라 없음 → Mock 카메라
  ///
  /// 🔥 수정 3: 촬영 중 보호 강화 (세션 라이프사이클 분리)
  @override
  void dispose() {
    // 앱 라이프사이클 관찰자 해제
    WidgetsBinding.instance.removeObserver(this);

    _debugStatePollTimer?.cancel();
    _focusStatusPollTimer?.cancel();
    _debugLogTimer?.cancel(); // 🔥 로그 업데이트 타이머 취소
    _hideFocusIndicatorTimer?.cancel(); // 포커스 인디케이터 숨김 타이머 취소
    _audioPlayer.dispose();
    // 🔥 카메라 제어용 MethodChannel 핸들러 제거
    _cameraControlChannel.setMethodCallHandler(null);
    // 🔥 로딩 문제 해결: 카메라 엔진 완전히 해제
    _cameraEngine.dispose();
    _petFaceStreamSubscription?.cancel();

    // 🔥 전면 재설계: dispose 시 한 번 초기화 플래그 리셋

    super.dispose();
  }

  /// 🔥 로딩 문제 해결: 화면 복귀 시 이전 카메라 세션 완전히 정리
  /// 앱 라이프사이클 변경 감지 (화면 이동 시 리소스 정리)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // 🔥🔥🔥 중복 호출 방지: 같은 상태로 변경되면 무시
    if (_lastLifecycleState == state) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⏸️ didChangeAppLifecycleState: Same state ($state), skipping');
      }
      return;
    }
    
    _lastLifecycleState = state; // 🔥 라이프사이클 상태 기록

    // 🔥 크래시 원인 추적: 촬영 중 라이프사이클 변경 감지
    final isCapturing = _cameraEngine.isCapturingPhoto;
    final lifecycleLog =
        '[Lifecycle] 📱 App lifecycle changed: $state (isCapturingPhoto=$isCapturing)';

    if (kDebugMode) {
      debugPrint('[Petgram] $lifecycleLog');
    }
    _addDebugLog(lifecycleLog);

    // 🔥🔥🔥 백그라운드 진입 시 카메라 pause, 복귀 시 resume + 비율 복원
    // 단순한 로직: 백그라운드에 있으면 pause, 돌아오면 resume
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // 🔥🔥🔥 백그라운드 진입 시 줌은 _pauseCameraSession()에서 1.0으로 고정됨
      // 여기서는 저장하지 않음 (_pauseCameraSession에서 1.0으로 저장)
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🔍 Calling _pauseCameraSession() from didChangeAppLifecycleState ($state), zoom will be fixed to 1.0x',
        );
      }
      _pauseCameraSession();
    }
    // 앱이 다시 활성화되면 카메라 세션 재개 (initPipeline은 호출하지 않음)
    else if (state == AppLifecycleState.resumed) {
      // 🔥🔥🔥 중복 호출 방지: 이미 재개 중이면 무시
      if (_isResumingCamera) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ⏸️ didChangeAppLifecycleState: Already resuming, skipping duplicate resume call',
          );
        }
        return;
      }
      
      // 🔥🔥🔥 세션 상태 확인: 세션이 이미 실행 중이면 resume 스킵
      if (_cameraEngine.isInitialized && _cameraEngine.sessionRunning == true) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ⏸️ didChangeAppLifecycleState: Session already running, skipping resume',
          );
        }
        return;
      }
      
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🔍 Calling _resumeCameraSession() from didChangeAppLifecycleState (isCapturingPhoto=$isCapturing)',
        );
      }
      // 🔥 핵심 수정: lifecycle에서 initPipeline을 다시 호출하지 않음 (resume만 호출)
      _resumeCameraSession();
    }
  }

  /// 🔥 성능 최적화: 카메라 세션 일시 중지 (배터리 절약)
  void _pauseCameraSession() {
    // 🔥 핵심 수정: shouldUseMockCamera만 체크 (isCameraReady로 차단하지 않음)
    if (_shouldUseMockCamera) return;

    if (kDebugMode) {
      debugPrint(
        '[Petgram] ⏸️ _pauseCameraSession: Called (isProcessing=$_isProcessing, isCapturingPhoto=${_cameraEngine.isCapturingPhoto}, isResuming=$_isResumingCamera, isInitialized=${_cameraEngine.isInitialized}, sessionRunning=${_cameraEngine.sessionRunning})',
      );
    }

    // 🔥🔥🔥 백그라운드 진입 시 무조건 pause: 촬영 중이어도 pause 시도
    // 네이티브에서 촬영 중이면 pause를 스킵하므로 여기서는 체크하지 않음
    // 재개 중이어도 백그라운드로 가면 pause해야 함

    // 포커스 상태 폴링 중지
    _stopFocusStatusPolling();

    // 🔥🔥🔥 핵심 수정: 백그라운드 진입 시 네이티브 카메라 줌을 1.0으로 강제 고정
    // Flutter 상태도 1.0으로 동기화하여 UI와 실제 줌 값이 일치하도록 함
    if (_cameraEngine.isInitialized && !_cameraEngine.isCapturingPhoto) {
      // Flutter 상태 즉시 1.0으로 설정
      if (mounted) {
        setState(() {
          _uiZoomScale = 1.0;
          _baseUiZoomScale = 1.0;
        });
      }
      
      // 네이티브 카메라 줌을 1.0으로 설정 (await 없이 비동기 실행)
      unawaited(
        _cameraEngine.setZoom(1.0).then((actualZoom) {
          if (kDebugMode) {
            debugPrint('[Petgram] ⏸️ Background: Zoom fixed to 1.0x (actual=${actualZoom?.toStringAsFixed(2) ?? "null"})');
          }
          _addDebugLog('[Lifecycle] ⏸️ Background zoom fixed to 1.0x');
        }).catchError((e) {
          if (kDebugMode) {
            debugPrint('[Petgram] ⚠️ Background: Failed to fix zoom to 1.0x: $e');
          }
        }),
      );
      
      // 저장된 줌 값도 1.0으로 설정 (복귀 시 1.0으로 복원되도록)
      _savedZoomScaleBeforeBackground = 1.0;
    }

    // 🔥🔥🔥 핵심 수정: pause 호출을 await로 기다리지 않고 unawaited로 처리
    // 하지만 pause가 실제로 실행되었는지 확인하기 위해 로그 추가
    // 네이티브 카메라 세션 명시적 정지 (배터리/발열 감소)
    // 홈 화면이 아닐 때 또는 앱이 백그라운드로 갈 때 세션 완전 정지
    // 네이티브에서 촬영 중이면 pause를 스킵하므로 안전하게 호출 가능
    unawaited(
      _cameraEngine.pause().then((_) {
        if (kDebugMode) {
          debugPrint('[Petgram] ⏸️ _pauseCameraSession: pause() completed successfully');
        }
        _addDebugLog('[Lifecycle] ⏸️ Camera pause completed');
      }).catchError((e) {
        if (kDebugMode) {
          debugPrint('[Petgram] ⚠️ _pauseCameraSession: pause() failed: $e');
        }
        _addDebugLog('[Lifecycle] ⚠️ Camera pause failed: $e');
      }),
    );
    
    if (kDebugMode) {
      debugPrint('[Petgram] ⏸️ _pauseCameraSession: pause() called (async)');
    }
    _addDebugLog('[Lifecycle] ⏸️ Camera pause requested');
  }

  /// 🔥 성능 최적화: 카메라 세션 재개
  void _resumeCameraSession() {
    // 🔥🔥🔥 중복 호출 방지: 이미 재개 중이면 무시
    if (_isResumingCamera) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⏸️ _resumeCameraSession: Already resuming, skipping duplicate call');
      }
      return;
    }

    // 🔥 크래시 원인 추적: 호출 스택 로깅
    final stackTrace = StackTrace.current;
    final stackLines = stackTrace.toString().split('\n');
    final callerInfo = stackLines.length > 2 ? stackLines[1].trim() : 'unknown';

    _addDebugLog(
      '[Lifecycle] 🔍 _resumeCameraSession() CALLED FROM: $callerInfo',
    );
    // 🔥 디버그 오버레이에도 스택 트레이스 표시
    _addDebugLog('[Lifecycle] 🔍 Full stack trace:');
    for (int i = 0; i < stackLines.length && i < 10; i++) {
      _addDebugLog('  [$i] ${stackLines[i]}');
    }
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🔍 _resumeCameraSession() CALLED FROM: $callerInfo',
      );
      debugPrint('[Petgram] 🔍 Full stack trace:');
      for (int i = 0; i < stackLines.length && i < 10; i++) {
        debugPrint('  [$i] ${stackLines[i]}');
      }
    }

    // 🔥 촬영 중 재개/재초기화 금지
    final now = DateTime.now();
    final fenceActive =
        _captureFenceUntil != null && now.isBefore(_captureFenceUntil!);
    if (_isProcessing || _cameraEngine.isCapturingPhoto || fenceActive) {
      _addDebugLog(
        '[Resume] ⏸️ skip resume: capture fence active (isProcessing=$_isProcessing, isCapturingPhoto=${_cameraEngine.isCapturingPhoto}, fenceActive=$fenceActive)',
      );
      return;
    }

    if (_shouldUseMockCamera) {
      // Mock 모드에서는 resume 불필요
      if (kDebugMode) {
        debugPrint('[Petgram] ▶️ Skipping resume: Mock camera mode');
      }
      return;
    }

    // 🔥🔥🔥 중복 호출 방지 플래그 설정
    _isResumingCamera = true;

    // 🔥🔥🔥 백그라운드 복귀 시 기존 비율 유지 (3:4로 강제 변경하지 않음)
    // 기존 비율을 그대로 사용하여 프리뷰 사이즈와 배경색을 복원
    final targetRatio = _getTargetAspectRatio();
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🔄 _resumeCameraSession: Resuming camera with existing aspect ratio (targetRatio=${targetRatio.toStringAsFixed(3)}, aspectMode=$_aspectMode)',
      );
    }

    // 🔥🔥🔥 백그라운드 복귀 시 비율 강제 재동기화
    // 네이티브에서 세션이 재시작되면서 비율이 초기화될 수 있으므로
    // _lastSyncedPreviewRect를 null로 설정하여 비율 재동기화 보장
    _lastSyncedPreviewRect = null;
    
    // 🔥🔥🔥 성능 최적화: 빈 setState() 제거
    // 비율 재동기화는 _buildCameraStack의 postFrameCallback에서 자동으로 처리됨
    // 불필요한 재빌드를 방지하여 성능 향상

    // 🔥🔥🔥 백그라운드 복귀 시 무조건 resume 시도 (상태 체크 완화)
    // 백그라운드에서 복귀할 때는 세션이 중지되어 있을 가능성이 높으므로
    // 상태 체크를 완화하고 무조건 resume을 시도
    _addDebugLog(
      '[Resume] ✅ resumeCameraSession: Calling cameraEngine.resume() (background resume)',
    );

    if (kDebugMode) {
      debugPrint('[Petgram] ▶️ Resuming camera session (background resume)');
    }

    // 🔥 네이티브 카메라 세션 명시적 재개
    // resume() 내부에서 상태를 체크하지만, 백그라운드 복귀 시에는
    // 세션이 중지되어 있을 가능성이 높으므로 무조건 시도
    // 🔥🔥🔥 타임아웃 추가: resume이 너무 오래 걸리면 플래그 리셋
    _cameraEngine.resume().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _isResumingCamera = false;
        if (kDebugMode) {
          debugPrint('[Petgram] ⚠️ _resumeCameraSession: Resume timeout after 5s, flag reset');
        }
        throw TimeoutException('Camera resume timeout after 5 seconds');
      },
    ).then((_) async {
      // 🔥🔥🔥 재개 완료 후 플래그 리셋
      _isResumingCamera = false;
      
      // 🔥🔥🔥 단순화: 백그라운드 복귀 시 복원 로직을 카메라 상태 리스너로 이동
      // 네이티브 세션이 완전히 준비된 후에만 비율/줌 복원 실행
      // Flutter는 resumeSession만 호출하고, 네이티브가 준비되면 자동으로 복원
      
      if (kDebugMode) {
        debugPrint('[Petgram] ✅ _resumeCameraSession: Resume called, waiting for native session to be ready');
      }
    }).catchError((error) {
      // 에러 발생 시에도 플래그 리셋
      _isResumingCamera = false;
      if (kDebugMode) {
        debugPrint('[Petgram] ❌ _resumeCameraSession: Resume failed, flag reset: $error');
      }
      // 🔥🔥🔥 큐 블로킹 에러인 경우 추가 처리
      if (error.toString().contains('timeout') || error.toString().contains('blocked')) {
        if (kDebugMode) {
          debugPrint('[Petgram] ⚠️ _resumeCameraSession: Queue blocked, will retry on next lifecycle change');
        }
      }
    });

    // 🔥🔥🔥 백그라운드 복귀 시 프리뷰 레이아웃 재동기화: 카메라가 준비된 후에만 수행
    // 카메라가 준비되기 전에 _lastSyncedPreviewRect를 null로 설정하면
    // _buildCameraStack의 postFrameCallback이 카메라 준비 전에 동기화를 시도하여 세션 블로킹 발생
    // 카메라 상태 리스너를 통해 카메라가 준비된 후에만 _lastSyncedPreviewRect를 null로 설정
    // 대신 _buildCameraStack의 postFrameCallback에서 비율 검증 로직으로 자동으로 재동기화됨
    // (비율 차이가 임계값 이상이면 자동으로 재동기화하므로 명시적 null 설정 불필요)

    // 🔥 필터 페이지에서 돌아올 때 어두워지는 문제 해결:
    //    밝기 값과 노출 바이어스를 리셋하여 기본 밝기로 복원
    // 🔥🔥🔥 성능 최적화: setExposureBias 중복 호출 방지
    // _brightnessValue를 0.0으로 설정하면 _updateNativeExposureBias()가 자동으로 호출되므로
    // 별도로 setExposureBias(0.0)를 호출할 필요 없음
    setState(() {
      _brightnessValue = 0.0; // 밝기 값 리셋 (자동으로 _updateNativeExposureBias() 호출됨)
    });

    // 🔥 무한 로딩 인디케이터 방지: 필터 페이지에서 돌아올 때 _isProcessing 상태 리셋
    // 🔥🔥🔥 연속 촬영 문제 해결: 플래그를 동기적으로 리셋 (setState() 사용하지 않음)
    if (_isProcessing) {
      _isProcessing = false;
      if (kDebugMode) {
        debugPrint('[Petgram] 🔄 Reset _isProcessing=false after app resume');
      }
    }

    // 🔥 필터 유지: 앱이 다시 활성화되면 필터를 다시 적용하여 필터가 사라지지 않도록 함
    // 🔥 성능 최적화: 중복 호출 제거 (한 번만 호출)
    if (_isNativeCameraActive) {
      _applyFilterIfChanged(_shootFilterKey, _liveIntensity.clamp(0.0, 1.0));
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🎨 Filter re-applied after app resume: key=$_shootFilterKey, intensity=$_liveIntensity',
        );
      }
    }

    // 포커스 상태 폴링 재시작
    if (_isAutoFocusEnabled) {
      _startFocusStatusPolling();
    }

    // 🔥 프리뷰 안 나오는 근본 원인: resume 후 즉시 상태 동기화하여 오버레이 제거
    // 네이티브 카메라가 resume되었지만 Flutter 상태가 업데이트되지 않으면
    // 오버레이가 계속 표시될 수 있으므로 즉시 동기화
    // 🔥 중복 호출 방지: 타이머가 이미 1초마다 폴링하므로 직접 호출 제거
    // Future.delayed(const Duration(milliseconds: 200), () async {
    //   if (mounted) {
    //     await _pollDebugState();
    //     _addDebugLog('[Resume] State synced after resume');
    //   }
    // });
  }

  Future<void> _playDogSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/dog_bark.mp3'));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] dog sound error: $e');
      }
    }
  }

  Future<void> _playCatSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/cat_meow.mp3'));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] cat sound error: $e');
      }
    }
  }

  /// 셔터음 재생 (Flutter 레벨)
  /// iOS 오디오 세션 활성화 및 재생 실패해도 예외 삼킴

  Future<void> _toggleFlash() async {
    if (_shouldUseMockCamera) {
      setState(() {
        _flashMode = _flashMode == FlashMode.off
            ? FlashMode.torch
            : FlashMode.off;
      });
      _saveFlashMode();
      return;
    }

    // 카메라 엔진을 통해 플래시 토글
    if (_cameraEngine.isInitialized) {
      try {
        final next = _flashMode == FlashMode.off
            ? FlashMode.torch
            : FlashMode.off;

        // 카메라 엔진을 통해 플래시 모드 설정
        String flashModeStr = next == FlashMode.torch ? 'torch' : 'off';
        await _cameraEngine.setFlashMode(flashModeStr);

        setState(() => _flashMode = next);
        _saveFlashMode();
      } catch (_) {}
      return;
    }
  }

  Future<void> _switchCamera() async {
    if (_shouldUseMockCamera) return;

    // 현재 방향의 반대 방향으로 전환
    final newDirection = _cameraLensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    // 카메라 엔진을 통해 전환
    if (_cameraEngine.isInitialized) {
      final fromDirection = _cameraLensDirection;
      if (kDebugMode) {
        debugPrint(
          '[Camera] switchCamera start: from=$fromDirection, to=$newDirection, '
          'isInitialized=${_cameraEngine.isInitialized}, isProcessing=$_isProcessing',
        );
      }

      try {
        setState(() {
          _cameraLensDirection = newDirection;
        });

        // 🔥 이슈 1 수정: switchCamera 호출 전에 성공 여부를 확인할 수 없으므로
        // 예외가 발생하지 않으면 성공으로 간주
        final switchResult = await _cameraEngine.switchCamera();

        // 🔥🔥🔥 전면 카메라 줌 문제 해결: 네이티브에서 실제 설정된 줌 값 확인
        // 네이티브에서 minZoom을 반환하지만, 전면 카메라도 1.0이 기본이어야 함
        // 네이티브에서 실제로 1.0으로 설정되었는지 확인하고 UI에 반영
        double actualZoom = 1.0;
        if (switchResult != null) {
          final minZoom = (switchResult['minZoom'] as num?)?.toDouble();
          // 🔥🔥🔥 카메라 전환 시 기본 줌: 전면/후면 모두 1.0으로 설정
          // Native에서 후면 카메라로 전환할 때 기본적으로 wide 카메라를 사용하고 1.0x 줌을 설정
          // minZoom은 렌즈의 최소 줌이지 기본 줌이 아니므로, 항상 1.0으로 설정
          if (newDirection == CameraLensDirection.front) {
            actualZoom = 1.0; // 전면 카메라는 항상 1.0으로 설정
          } else {
            // 🔥🔥🔥 후면 카메라: 기본적으로 wide 카메라를 사용하고 1.0x 줌을 설정
            // minZoom은 ultraWide 렌즈의 최소 줌(0.5)일 수 있지만, 기본 줌은 1.0이어야 함
            actualZoom = 1.0; // 후면 카메라도 기본 1.0으로 설정
            if (kDebugMode) {
              debugPrint(
                '[Petgram] ✅ Back camera switch: using default zoom 1.0 (minZoom=$minZoom is lens minimum, not default)',
              );
            }
          }
        }

        setState(() {
          _uiZoomScale = actualZoom;
          _baseUiZoomScale = actualZoom;
        });

        // 🔥 전면/후면 카메라 모두 1.0으로 설정 시도
        if (newDirection == CameraLensDirection.front) {
          // 전면 카메라 전환 직후 약간의 지연을 두고 줌 설정 (네이티브 전환 완료 대기)
          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted &&
                _cameraEngine.isInitialized &&
                _cameraLensDirection == CameraLensDirection.front) {
              // 1.0으로 설정 시도 (네이티브에서 0.5로 clamp될 수 있음)
              _cameraEngine.setZoom(1.0).then((_) {
                // 🔥🔥🔥 전면 카메라 줌 문제: 실제 설정된 값을 확인하여 UI 업데이트
                // 네이티브에서 실제로 0.5로 clamp되었는지 확인 필요
                // 현재는 네이티브에서 줌 값을 반환하지 않으므로, 
                // 전면 카메라의 경우 UI는 1.0으로 유지하되 네이티브에 1.0 설정 시도
              if (kDebugMode) {
                debugPrint(
                    '[Petgram] ✅ Front camera switch: zoom set to 1.0 (may be clamped to 0.5 by native)',
                );
              }
              });
            }
          });
        } else {
          // 후면 카메라는 즉시 적용
          _cameraEngine.setZoom(actualZoom);
          if (kDebugMode) {
            debugPrint(
              '[Petgram] ✅ Back camera switch: zoom set to $actualZoom',
            );
          }
        }

        // 전면 카메라는 플래시를 지원하지 않으므로 플래시 모드 설정 전에 체크
        if (newDirection == CameraLensDirection.front) {
          if (_flashMode != FlashMode.off) {
            setState(() {
              _flashMode = FlashMode.off;
            });
            _saveFlashMode();
            debugPrint('[Petgram] ⚠️ 전면 카메라는 플래시를 지원하지 않아 플래시를 끕니다');
          }
        }

        // 🔥 필터 유지: 카메라 전환 완료 후 필터를 다시 적용하여 필터가 사라지지 않도록 함
        if (_isNativeCameraActive) {
          _applyFilterIfChanged(
            _shootFilterKey,
            _liveIntensity.clamp(0.0, 1.0),
          );
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🎨 Filter re-applied after camera switch: key=$_shootFilterKey, intensity=$_liveIntensity',
            );
          }
        }

        // 전환 직후 네이티브 디버그 상태 한 번 폴링해서 로그로 남김
        // 🔥 중복 호출 방지: 타이머가 이미 1초마다 폴링하므로 직접 호출 제거
        // if (kDebugMode) {
        //   await _pollDebugState();
        // }

        if (kDebugMode) {
          debugPrint(
            '[Camera] switchCamera success: direction=$newDirection, '
            'sessionRunning=${_cameraEngine.lastDebugState?.sessionRunning ?? false}, '
            'videoConnected=${_cameraEngine.lastDebugState?.videoConnected ?? false}',
          );
        }

        // 카메라 전환 시에도 화면 중앙에 자동 초점 설정
        _setAutoFocusAtCenter();
        // 🔥 이슈 1 수정: 성공 시 return하여 catch 블록이 실행되지 않도록 함
        return;
      } catch (e, stack) {
        // 🔥 이슈 1 수정: 진짜 예외가 발생한 경우에만 실패 메시지 표시
        if (kDebugMode) {
          debugPrint('[Camera] switchCamera error: $e');
          debugPrint('[Camera] switchCamera stack: $stack');
        }

        // 실패 시 방향/상태를 이전 방향으로 복구
        if (mounted) {
          setState(() {
            _cameraLensDirection = fromDirection;
          });
        }

        // 🔥 이슈 1 수정: 진짜 예외가 발생한 경우에만 SnackBar 표시
        if (mounted) {
          final directionText = fromDirection == CameraLensDirection.back
              ? '후면'
              : '전면';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('카메라 전환에 실패했어요. $directionText 카메라를 계속 사용합니다.'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } finally {
        // 카메라 엔진 상태는 엔진에서 관리
      }
    }
  }

  void _changeAspectMode(AspectRatioMode mode) {
    if (_aspectMode == mode) {
      return;
    }
    setState(() {
      _aspectMode = mode;
      // 🔥 프리뷰 비율 크롭 기반 처리: 비율 변경은 UI만 변경, 줌/네이티브 재초기화 없음
      // 🔥 비율 변경 시 프리뷰 위치 캐시 초기화 (레이아웃 재계산 보장)
      // 🔥🔥🔥 촬영 후 비율 변경 시 프리뷰 업데이트 보장: _lastSyncedPreviewRect를 null로 설정하여 강제 동기화
      _lastSyncedPreviewRect = null;
    });
    
    // 🔥🔥🔥 즉시 재빌드 트리거: 비율 변경 시 위젯을 즉시 재빌드하여 프리뷰 크기 업데이트
    // 🔥🔥🔥 여러 번 setState를 호출하여 확실히 재빌드 보장
    if (mounted) {
      // 첫 번째 프레임: 즉시 재빌드
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            // 비율 변경 후 프리뷰 업데이트를 위한 재빌드
          });
          // 두 번째 프레임: 추가 재빌드로 확실히 업데이트
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                // 비율 변경 후 프리뷰 업데이트를 위한 재빌드
              });
            }
          });
        }
      });
    }
    _saveAspectMode();

    // 🔥 프리뷰 비율 크롭 기반 처리: 비율 변경 시 네이티브 재초기화 절대 금지
    // 비율 변경은 Flutter UI에서만 처리 (센서 비율 고정 + 크롭 레이어만 변경)
    // 네이티브 카메라는 센서 원본 비율로 유지, 줌 값도 변경하지 않음
    // ⚠️ 중요: 비율 변경 시 줌을 절대 변경하지 않음 (아이폰 기본 카메라와 동일한 화각 유지)
    if (kDebugMode) {
      final targetRatio = aspectRatioOf(mode);
      debugPrint(
        '[Petgram] 📐 Aspect mode changed to: ${_aspectLabel(mode)} (${targetRatio.toStringAsFixed(3)})',
      );
      debugPrint(
        '[Petgram] 📐 Sensor aspect ratio: ${_sensorAspectRatio.toStringAsFixed(3)} (fixed)',
      );
      debugPrint(
        '[Petgram] 📐 UI only crop change, no native reinitialize, no zoom change',
      );
      debugPrint(
        '[Petgram] 📐 Zoom remains at ${_uiZoomScale.toStringAsFixed(3)} (no zoom change on aspect ratio change)',
      );
    }

    // 🔥 화각 정확도: 비율 변경 시 줌이 변경되지 않도록 명시적으로 확인
    // (이미 setState에서 _aspectMode만 변경하므로 줌은 자동으로 유지됨)

    // 🔥 비율 변경 시 프리뷰 레이아웃 즉시 재동기화
    // _buildCameraStack의 postFrameCallback에서도 동기화하지만,
    // 비율 변경 직후 즉시 동기화를 시도하여 빠른 반응 보장
    _lastSyncedPreviewRect = null; // 이미 setState에서 초기화했지만 명시적으로 다시 초기화

    // 🔥 비율 변경 시 즉시 프리뷰 rect 계산 및 동기화 시도
    // postFrameCallback을 여러 번 호출하여 레이아웃 완료 보장
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 첫 번째 프레임: 레이아웃이 완료되었는지 확인
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 두 번째 프레임: 레이아웃이 확정된 후 동기화 수행
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // 세 번째 프레임: 최종 확인 및 동기화
          if (Platform.isIOS &&
              !_shouldUseMockCamera &&
              _cameraEngine.nativeCamera != null) {
            // 🔥 계산된 rect를 직접 사용하여 동기화 (keyRect가 이전 레이아웃을 반환할 수 있음)
            final dimensions = _calculateCameraPreviewDimensions();
            final previewW = dimensions['previewW']!;
            final previewH = dimensions['previewH']!;
            final offsetX = dimensions['offsetX']!;
            final offsetY = dimensions['offsetY']!;
            
            // Global 좌표로 변환
            final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
            if (rootBox != null) {
              final Offset localTopLeft = Offset(offsetX, offsetY);
              final Offset globalTopLeft = rootBox.localToGlobal(localTopLeft);
              final Rect calculatedRect = Rect.fromLTWH(
                globalTopLeft.dx,
                globalTopLeft.dy,
                previewW,
                previewH,
              );
              
              if (calculatedRect.width > 0 && calculatedRect.height > 0) {
                // 🔥 비율 변경 시 강제 동기화: 항상 동기화 (이전 rect와 무관하게)
                // 비율이 변경되었으므로 _lastSyncedPreviewRect를 무시하고 무조건 동기화
                // 🔥🔥🔥 중요: _lastSyncedPreviewRect는 null로 유지하여 _buildCameraStack에서도 동기화 보장
                // 동기화는 _buildCameraStack의 postFrameCallback에서 수행되므로, 여기서는 null로만 설정
                // _lastSyncedPreviewRect = null; // 이미 setState에서 설정했으므로 중복 설정 불필요
                // 🔥🔥🔥 비율 변경 시 즉시 동기화 시도 (세션 상태와 관계없이)
                // 하지만 _buildCameraStack의 postFrameCallback에서도 동기화가 수행되므로,
                // 여기서는 동기화만 시도하고 _lastSyncedPreviewRect는 업데이트하지 않음
                _syncPreviewRectToNativeFromLocal(calculatedRect, context);
                // 추가로 retry도 시도하여 확실히 업데이트
                _syncPreviewRectWithRetry(calculatedRect, context);
                // 🔥 _lastSyncedPreviewRect는 _buildCameraStack의 postFrameCallback에서 업데이트됨
                // 여기서 업데이트하지 않아서 _buildCameraStack에서도 동기화가 수행됨
                // 🔥 성능 최적화: 비율 변경 로그는 첫 번째만 출력 (빈번한 호출 방지)
                // if (kDebugMode) { debugPrint('[Petgram] 📐 Aspect ratio changed: ...'); }
              } else if (kDebugMode) {
                debugPrint(
                  '[Petgram] ⚠️ Aspect ratio changed: calculated rect is invalid (width=${calculatedRect.width}, height=${calculatedRect.height}), will retry in _buildCameraStack',
                );
              }
            } else if (kDebugMode) {
              debugPrint(
                '[Petgram] ⚠️ Aspect ratio changed: rootBox is null, will retry in _buildCameraStack',
              );
            }
          }
        });
      });
    });
    
    // 🔥 추가 보장: _buildCameraStack의 postFrameCallback에서도 비율 변경을 감지하도록
    // _lastSyncedPreviewRect를 null로 설정하여 _buildCameraStack에서도 동기화가 실행되도록 함
    // (이미 setState에서 설정했지만, 명시적으로 다시 설정하여 보장)
  }

  Future<File> _createTempFileFromAsset(String assetPath) async {
    final byteData = await rootBundle.load(assetPath);
    final buffer = byteData.buffer;
    final dir = await getTemporaryDirectory();
    final filePath =
        '${dir.path}/mock_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File(filePath);
    await file.writeAsBytes(
      buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
      flush: true,
    );
    return file;
  }

  /// 이미지를 지정된 비율로 크롭 (center crop)
  img.Image _cropImageToAspectRatio(img.Image image, double targetAspectRatio) {
    // 🔥 저장 파이프라인 해상도 검증: 크롭 입력 이미지 해상도 로그
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 📐 Crop input: ${image.width}x${image.height} pixels, '
        'aspect=${(image.width / image.height).toStringAsFixed(3)}, '
        'target=${targetAspectRatio.toStringAsFixed(3)}',
      );
    }

    final currentAspect = image.width / image.height;

    if ((currentAspect - targetAspectRatio).abs() < 0.01) {
      // 비율이 거의 동일하면 그대로 반환
      if (kDebugMode) {
        debugPrint('[Petgram] 📐 Crop skipped: aspect ratio already matches');
      }
      return image;
    }

    int cropWidth = image.width;
    int cropHeight = image.height;
    int cropX = 0;
    int cropY = 0;

    if (currentAspect > targetAspectRatio) {
      // 이미지가 더 넓음 → 너비를 줄여서 크롭
      cropWidth = (image.height * targetAspectRatio).round();
      cropX = (image.width - cropWidth) ~/ 2;
    } else {
      // 이미지가 더 높음 → 높이를 줄여서 크롭
      cropHeight = (image.width / targetAspectRatio).round();
      cropY = (image.height - cropHeight) ~/ 2;
    }

    final croppedImage = img.copyCrop(
      image,
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );

    // 🔥 저장 파이프라인 해상도 검증: 크롭 출력 이미지 해상도 로그
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 📐 Crop output: ${croppedImage.width}x${croppedImage.height} pixels',
      );
    }

    return croppedImage;
  }

  /// ColorMatrix를 직접 적용 (메인 스레드, 작은 이미지용)
  /// 🔥 중요: 해상도 변경 없이 색상만 변경 (copyResize 제거)
  img.Image _applyColorMatrixToImageDirect(
    img.Image image,
    List<double> matrix,
  ) {
    // 🔥 중요: 해상도 변경 없이 복사만 수행
    //          같은 크기로 copyResize를 호출하면 리샘플링이 발생할 수 있으므로
    //          새로운 이미지를 생성하고 픽셀을 직접 복사하면서 ColorMatrix 적용
    final result = img.Image(
      width: image.width,
      height: image.height,
      numChannels: image.numChannels,
    );

    // 원본 이미지 픽셀을 복사하면서 ColorMatrix 적용 (해상도 변경 없음)
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        final a = pixel.a.toDouble();

        // ColorMatrix 적용 (0~255 색 공간)
        final newR =
            (matrix[0] * r +
                    matrix[1] * g +
                    matrix[2] * b +
                    matrix[3] * a +
                    matrix[4])
                .clamp(0, 255)
                .toInt();
        final newG =
            (matrix[5] * r +
                    matrix[6] * g +
                    matrix[7] * b +
                    matrix[8] * a +
                    matrix[9])
                .clamp(0, 255)
                .toInt();
        final newB =
            (matrix[10] * r +
                    matrix[11] * g +
                    matrix[12] * b +
                    matrix[13] * a +
                    matrix[14])
                .clamp(0, 255)
                .toInt();
        // Alpha는 원본 유지
        final newA = pixel.a.toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, newA));
      }
    }

    return result;
  }

  /// Mock 이미지에 프레임 오버레이 추가
  Future<img.Image> _addFrameOverlayToImage(
    img.Image image,
    Map<String, dynamic> frameMeta,
  ) async {
    // 🔥 위치 정보가 없고 프레임이 활성화되어 있으면 재시도
    var locationInMeta = frameMeta['location'] as String?;
    if ((locationInMeta == null || locationInMeta.isEmpty) &&
        _frameEnabled &&
        _petList.isNotEmpty) {
      // 위치 정보가 아직 로드 중일 수 있으므로 최대 3회 재시도
      int retryCount = 0;
      const maxRetries = 3;
      const retryDelay = Duration(milliseconds: 500);

      while (retryCount < maxRetries) {
        // 현재 위치 정보 확인
        if (_currentLocation != null && _currentLocation!.isNotEmpty) {
          // 위치 정보가 있으면 frameMeta에 추가
          frameMeta = Map<String, dynamic>.from(frameMeta);
          frameMeta['location'] = _currentLocation;
          locationInMeta = _currentLocation;
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🖼️ 위치 정보 재시도 성공 (시도 ${retryCount + 1}/$maxRetries): $_currentLocation',
            );
          }
          break;
        }

        retryCount++;
        if (retryCount < maxRetries) {
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🖼️ 위치 정보 대기 중 (시도 ${retryCount}/$maxRetries)...',
            );
          }
          await Future.delayed(retryDelay);

          // 🔥 mounted 체크: 재시도 중 위젯이 dispose되었는지 확인
          if (!mounted) {
            if (kDebugMode) {
              debugPrint('[Petgram] 🖼️ 프레임 렌더링 재시도 중 위젯이 dispose됨');
            }
            return image; // 원본 이미지 반환
          }
        } else {
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🖼️ 위치 정보 재시도 실패: 최대 재시도 횟수 초과, 위치 정보 없이 프레임 렌더링',
            );
          }
        }
      }
    }

    // 🔥 저장 파이프라인 해상도 검증: 프레임 오버레이 입력 이미지 해상도 로그
    if (kDebugMode) {
      debugPrint(
        '[Petgram] Save input: ${image.width}x${image.height} pixels '
        '(maxDimension=${image.width > image.height ? image.width : image.height})',
      );
    }

    // ============================================================
    // 1. 해상도 정책 적용 (2K 기준)
    // ============================================================
    // 긴 변 계산
    final int maxDimension = image.width > image.height
        ? image.width
        : image.height;
    final int targetMaxDimension = 2000; // 2K 기준

    img.Image processedImage = image;

    if (maxDimension > targetMaxDimension) {
      // 긴 변이 2000px을 넘으면 다운스케일
      final double scale = targetMaxDimension / maxDimension;
      final int targetWidth = (image.width * scale).round();
      final int targetHeight = (image.height * scale).round();

      // 고품질 다운스케일링 (한 번만)
      processedImage = img.copyResize(
        image,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.cubic, // 고품질 리샘플링
      );

      if (kDebugMode) {
        debugPrint(
          '[Petgram] Save resized: ${processedImage.width}x${processedImage.height} pixels '
          '(from ${image.width}x${image.height}, scale=${scale.toStringAsFixed(3)})',
        );
      }
    } else {
      // 긴 변이 2000px 이하이면 그대로 사용 (절대 업스케일 금지)
      // 🔥 중요: 작은 해상도 이미지는 그대로 사용하되, 프레임은 이 해상도 기준으로 정확히 그려야 함
      if (kDebugMode) {
        debugPrint(
          '[Petgram] Save resized: ${processedImage.width}x${processedImage.height} pixels '
          '(no resize, maxDimension=$maxDimension <= $targetMaxDimension) - '
          '프레임은 이 해상도 기준으로 정확히 렌더링',
        );
      }
    }

    // 최종 해상도 (프레임 렌더링 기준) - processedImage 해상도 그대로 사용
    final int finalWidth = processedImage.width;
    final int finalHeight = processedImage.height;
    final Size canvasSize = Size(finalWidth.toDouble(), finalHeight.toDouble());

    if (kDebugMode) {
      debugPrint(
        '[Petgram] Frame rendering size: ${finalWidth}x${finalHeight} pixels',
      );
    }

    // ============================================================
    // 2. 원본 이미지를 ui.Image로 변환 (정확한 해상도 보장)
    // ============================================================
    final ui.Image uiImage = await _imgImageToUiImage(processedImage);

    // 🔥 중요: uiImage의 실제 크기가 finalWidth/finalHeight와 정확히 일치하는지 확인
    if (kDebugMode) {
      debugPrint(
        '[Petgram] uiImage converted: ${uiImage.width}x${uiImage.height} pixels '
        '(expected: ${finalWidth}x${finalHeight})',
      );
      if (uiImage.width != finalWidth || uiImage.height != finalHeight) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: uiImage size mismatch: '
          '${uiImage.width}x${uiImage.height} != ${finalWidth}x${finalHeight}',
        );
      } else {
        debugPrint('[Petgram] ✅ uiImage size matches expected size');
      }
    }

    // ============================================================
    // 3. 프레임/텍스트는 최종 해상도 기준으로만 렌더링
    //    devicePixelRatio 제거, 이중 스케일 금지
    //    🔥 중요: 작은 해상도에서도 텍스트/칩이 선명하게 그려지도록 보장
    // ============================================================
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // ⚠️ 중요: canvas.scale() 사용하지 않음 (devicePixelRatio 제거)
    // 🔥 중요: 작은 해상도에서도 렌더링 품질 보장을 위해 Paint 기본값 사용

    // FramePainter 생성 및 그리기
    // 프레임 바 높이는 최종 해상도 기준으로 계산
    // 🔥 위치 정보 확인 및 로깅 (재시도 후 업데이트된 frameMeta 사용)
    final finalLocationForPainter = frameMeta['location'] as String?;
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🖼️ FramePainter 생성: location=${finalLocationForPainter ?? "null"}, '
        'petId=${frameMeta['petId']}, frameMeta keys=${frameMeta.keys.toList()}',
      );
      debugPrint(
        '[Petgram] 🖼️ FramePainter 캔버스 크기: ${canvasSize.width}x${canvasSize.height}, '
        'topBarHeight=${canvasSize.height * 0.03}, bottomBarHeight=${canvasSize.height * (1.0 - 0.05)}',
      );
    }

    final painter = FramePainter(
      petList: _petList,
      selectedPetId: frameMeta['petId'] as String?,
      width: canvasSize.width,
      height: canvasSize.height,
      topBarHeight: canvasSize.height * 0.03,
      bottomBarHeight: canvasSize.height * (1.0 - 0.05),
      dogIconImage: _dogIconImage,
      catIconImage: _catIconImage,
      location:
          finalLocationForPainter, // 🔥 frameMeta에서 위치 정보 전달 (재시도 후 업데이트됨)
    );

    try {
      painter.paint(canvas, canvasSize);
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ✅ FramePainter.paint() 완료: location=$finalLocationForPainter',
        );
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[Petgram] ❌ FramePainter.paint() 에러: $e');
        debugPrint('[Petgram] ❌ Stack trace: $stackTrace');
      }
      rethrow;
    }

    // Picture를 ui.Image로 변환 (최종 해상도 그대로)
    // 🔥 중요: 작은 해상도에서도 텍스트/칩이 선명하게 그려지도록 정확한 해상도로 변환
    final picture = recorder.endRecording();
    final frameUiImage = await picture.toImage(finalWidth, finalHeight);

    // 🔥 중요: frameUiImage가 정확한 해상도로 생성되었는지 확인
    if (kDebugMode) {
      debugPrint(
        '[Petgram] frameUiImage created: ${frameUiImage.width}x${frameUiImage.height} pixels '
        '(expected: ${finalWidth}x${finalHeight})',
      );
      if (frameUiImage.width != finalWidth ||
          frameUiImage.height != finalHeight) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: frameUiImage size mismatch: '
          '${frameUiImage.width}x${frameUiImage.height} != ${finalWidth}x${finalHeight}',
        );
      } else {
        debugPrint('[Petgram] ✅ frameUiImage size matches expected size');
      }
    }

    // ============================================================
    // 4. 원본 이미지와 프레임 오버레이 합성
    //    ⚠️ 중요: 원본 이미지는 스케일링 없이 정확한 크기로 그리기
    //    🔥 중요: 작은 해상도에서도 합성 품질 보장
    // ============================================================
    final recorder2 = ui.PictureRecorder();
    final canvas2 = Canvas(recorder2);
    // ⚠️ 중요: canvas2.scale() 사용하지 않음 (devicePixelRatio 제거)
    // 🔥 중요: 작은 해상도에서도 합성 품질 보장을 위해 Paint 기본값 사용

    // 원본 이미지 그리기
    // 🔥 중요: uiImage의 실제 크기와 finalWidth/finalHeight가 같으면 스케일링 없이 그리기
    //          작은 해상도 이미지도 정확한 크기로 그려야 프레임과 함께 깨지지 않음
    if (uiImage.width == finalWidth && uiImage.height == finalHeight) {
      // 크기가 정확히 일치하면 스케일링 없이 직접 그리기 (깨짐 방지)
      // 🔥 렌더링 품질 보장을 위해 필터 품질 명시
      canvas2.drawImage(
        uiImage,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.high,
      );
      if (kDebugMode) {
        debugPrint('[Petgram] ✅ Original image drawn without scaling');
      }
    } else {
      // 크기가 다르면 스케일링 (이론적으로는 발생하지 않아야 함)
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: Scaling original image: '
          '${uiImage.width}x${uiImage.height} → ${finalWidth}x${finalHeight}',
        );
      }
      canvas2.drawImageRect(
        uiImage,
        Rect.fromLTWH(
          0,
          0,
          uiImage.width.toDouble(),
          uiImage.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, finalWidth.toDouble(), finalHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
    }

    // 프레임 오버레이 그리기 (최종 해상도 그대로, 스케일링 없이)
    // 🔥 중요: frameUiImage는 이미 finalWidth x finalHeight로 생성되었으므로 직접 그리기
    //          작은 해상도에서도 프레임이 선명하게 그려져야 함
    if (frameUiImage.width == finalWidth &&
        frameUiImage.height == finalHeight) {
      // 🔥 렌더링 품질 보장을 위해 필터 품질 명시
      canvas2.drawImage(
        frameUiImage,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.high,
      );
      if (kDebugMode) {
        debugPrint('[Petgram] ✅ Frame overlay drawn without scaling');
      }
    } else {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: Frame overlay size mismatch, using drawImageRect: '
          '${frameUiImage.width}x${frameUiImage.height} != ${finalWidth}x${finalHeight}',
        );
      }
      canvas2.drawImageRect(
        frameUiImage,
        Rect.fromLTWH(
          0,
          0,
          frameUiImage.width.toDouble(),
          frameUiImage.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, finalWidth.toDouble(), finalHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
    }

    final picture2 = recorder2.endRecording();
    // 🔥 중요: 최종 합성 이미지를 정확한 해상도로 변환
    //          작은 해상도에서도 프레임과 원본이 선명하게 합성되도록 보장
    final finalUiImage = await picture2.toImage(finalWidth, finalHeight);

    // 🔥 중요: toImage()가 정확한 해상도로 생성했는지 확인
    if (kDebugMode) {
      if (finalUiImage.width != finalWidth ||
          finalUiImage.height != finalHeight) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: finalUiImage size mismatch: '
          '${finalUiImage.width}x${finalUiImage.height} != ${finalWidth}x${finalHeight}',
        );
      } else {
        debugPrint(
          '[Petgram] ✅ finalUiImage size correct: ${finalUiImage.width}x${finalUiImage.height}',
        );
      }
    }

    // ============================================================
    // 5. ui.Image를 img.Image로 변환 (최종 해상도 그대로)
    // ============================================================
    final finalImage = await _uiImageToImgImage(finalUiImage);

    // 🔥 저장 파이프라인 해상도 검증: 최종 출력 이미지 해상도 로그
    if (kDebugMode) {
      final int finalMaxDimension = finalImage.width > finalImage.height
          ? finalImage.width
          : finalImage.height;
      debugPrint(
        '[Petgram] Save final: ${finalImage.width}x${finalImage.height} pixels '
        '(maxDimension=$finalMaxDimension)',
      );

      // 해상도 일치 검증
      if (finalImage.width != finalWidth || finalImage.height != finalHeight) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: Final image size mismatch after conversion: '
          '${finalImage.width}x${finalImage.height} != ${finalWidth}x${finalHeight}',
        );
      }

      // 2K 기준 검증
      if (finalMaxDimension > targetMaxDimension) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: Final image exceeds 2K: maxDimension=$finalMaxDimension > $targetMaxDimension',
        );
      } else if (finalMaxDimension == targetMaxDimension) {
        debugPrint(
          '[Petgram] ✅ Final image at 2K: maxDimension=$finalMaxDimension',
        );
      } else {
        debugPrint(
          '[Petgram] ✅ Final image below 2K: maxDimension=$finalMaxDimension < $targetMaxDimension',
        );
      }
    }

    // 메모리 해제
    uiImage.dispose();
    frameUiImage.dispose();
    finalUiImage.dispose();

    return finalImage;
  }

  /// img.Image를 ui.Image로 변환
  /// 🔥 중요: 해상도 변경 없이 변환만 수행
  Future<ui.Image> _imgImageToUiImage(img.Image image) async {
    if (kDebugMode) {
      debugPrint(
        '[Petgram] _imgImageToUiImage: input=${image.width}x${image.height}',
      );
    }

    // img.Image를 PNG 바이트로 인코딩
    final pngBytes = img.encodePng(image);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(pngBytes, (ui.Image uiImg) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] _imgImageToUiImage: output=${uiImg.width}x${uiImg.height} '
          '(input=${image.width}x${image.height})',
        );
        if (uiImg.width != image.width || uiImg.height != image.height) {
          debugPrint(
            '[Petgram] ⚠️ WARNING: Image size changed during img→ui conversion: '
            '${image.width}x${image.height} → ${uiImg.width}x${uiImg.height}',
          );
        } else {
          debugPrint(
            '[Petgram] ✅ Image size preserved during img→ui conversion',
          );
        }
      }
      completer.complete(uiImg);
    });
    return completer.future;
  }

  /// ui.Image를 img.Image로 변환
  Future<img.Image> _uiImageToImgImage(ui.Image uiImage) async {
    if (kDebugMode) {
      debugPrint(
        '[Petgram] _uiImageToImgImage: input=${uiImage.width}x${uiImage.height}',
      );
    }

    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Failed to convert ui.Image to byteData');
    }

    if (kDebugMode) {
      debugPrint(
        '[Petgram] _uiImageToImgImage: PNG bytes=${byteData.lengthInBytes} bytes',
      );
    }

    final imgImage = img.decodeImage(byteData.buffer.asUint8List());
    if (imgImage == null) {
      throw Exception('Failed to decode image from byteData');
    }

    if (kDebugMode) {
      debugPrint(
        '[Petgram] _uiImageToImgImage: output=${imgImage.width}x${imgImage.height} '
        '(input=${uiImage.width}x${uiImage.height})',
      );
      if (imgImage.width != uiImage.width ||
          imgImage.height != uiImage.height) {
        debugPrint(
          '[Petgram] ⚠️ WARNING: Image size changed during conversion: '
          '${uiImage.width}x${uiImage.height} → ${imgImage.width}x${imgImage.height}',
        );
      } else {
        debugPrint('[Petgram] ✅ Image size preserved during conversion');
      }
    }

    return imgImage;
  }

  /// 타이머 카운트다운 시작
  Future<void> _startTimerCountdown() async {
    if (_timerSeconds == 0 || _isTimerCounting) return;

    // 원래 타이머 설정값 저장
    final originalTimerSeconds = _timerSeconds;
    setState(() {
      _isTimerCounting = true;
      _shouldStopTimer = false;
    });

    for (int i = _timerSeconds; i > 0; i--) {
      if (!mounted || _shouldStopTimer) {
        setState(() {
          _isTimerCounting = false;
          _shouldStopTimer = false;
          _timerSeconds = originalTimerSeconds;
          _isProcessing = false; // 🔥🔥🔥 타이머 취소 시 _isProcessing 리셋
        });
        if (kDebugMode) {
          debugPrint('[Petgram] 🛑 타이머 취소: _isProcessing=false로 리셋');
        }
        // 타이머 강제 종료 시 스낵바 표시 제거 (사용자 요청)
        return;
      }
      setState(() => _timerSeconds = i);
      HapticFeedback.lightImpact();

      // 1초 대기 중에도 중지 요청을 체크할 수 있도록 0.1초씩 나눠서 대기
      for (int j = 0; j < 10; j++) {
        if (!mounted || _shouldStopTimer) {
          debugPrint('🛑 타이머 카운트다운 중지됨 (대기 중: $_shouldStopTimer)');
          setState(() {
            _isTimerCounting = false;
            _shouldStopTimer = false;
            _timerSeconds = originalTimerSeconds;
            _isProcessing = false; // 🔥🔥🔥 타이머 취소 시 _isProcessing 리셋
          });
          if (kDebugMode) {
            debugPrint('[Petgram] 🛑 타이머 취소 (대기 중): _isProcessing=false로 리셋');
          }
          // 타이머 강제 종료 시 스낵바 표시 제거 (사용자 요청)
          return;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    if (!mounted || _shouldStopTimer) {
      setState(() {
        _isTimerCounting = false;
        _shouldStopTimer = false;
        _timerSeconds = originalTimerSeconds;
        _isProcessing = false; // 🔥🔥🔥 타이머 취소 시 _isProcessing 리셋
      });
      if (kDebugMode) {
        debugPrint('[Petgram] 🛑 타이머 취소 (최종 체크): _isProcessing=false로 리셋');
      }
      // 타이머 강제 종료 시 스낵바 표시 제거 (사용자 요청)
      return;
    }

    // 🔥 타이머 종료 후 촬영 전 상태 확인 및 로그
    if (kDebugMode) {
      debugPrint(
        '[Petgram] ⏰ 타이머 종료: 촬영 시작 전 상태 확인, _isProcessing=$_isProcessing, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}',
      );
    }
    _addDebugLog(
      '[Timer] ⏰ 타이머 종료: 촬영 시작 전, _isProcessing=$_isProcessing, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}',
    );

    // 🔥 타이머 종료 후 촬영 문제 해결: _isProcessing이 true이면 리셋
    // 이전 촬영이 완료되지 않았을 수 있으므로 타이머 촬영을 위해 리셋
    if (_isProcessing) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ 타이머 종료: _isProcessing=true 감지, 리셋 후 촬영 진행',
        );
      }
      _addDebugLog('[Timer] ⚠️ _isProcessing=true 감지, 리셋 후 촬영 진행');
      _isProcessing = false; // 타이머 촬영을 위해 리셋
    }

    setState(() {
      // 타이머 설정값 유지 (0으로 리셋하지 않음)
      _timerSeconds = originalTimerSeconds;
      _isTimerCounting = false;
      _isTimerTriggered = true; // 타이머로 인한 촬영임을 표시
    });

    // 타이머 종료 후 촬영 (한 번만)
    // 연속 촬영 모드가 활성화되어 있으면 연속 촬영이 실행됨
    await _takePhoto();

    // 타이머로 인한 촬영 완료 후 플래그 리셋
    // 연속 촬영이 완료될 때까지 기다림 (최대 10초)
    if (mounted) {
      int waitCount = 0;
      // 연속 촬영이 활성화되어 있고 아직 진행 중이면 대기
      while (_isBurstMode && _burstCount > 0 && mounted && waitCount < 200) {
        await Future.delayed(const Duration(milliseconds: 50));
        waitCount++;
      }
      // 연속 촬영이 완료되거나 대기 시간이 지나면 플래그 리셋
      if (mounted) {
        setState(() {
          _isTimerTriggered = false;
        });
        debugPrint('✅ 타이머 촬영 완료, 플래그 리셋 (대기: ${waitCount * 50}ms)');
      }
    }
  }

  /// 캡처된 nativePhotoPath에 대해:
  /// - buildFinalImage (downsample + 필터/펫톤/밝기)
  /// - 프레임 적용 (같은 ui.Image 위에서)
  /// - saveAsJpeg (JPEG 1회 인코딩)
  /// - EXIF + 갤러리 저장 + DB 기록
  /// 을 백그라운드에서 안전하게 처리
  /// 사진 촬영 → 저장 파이프라인 트리거
  /// - 캡처(셔터)까지만 await
  /// - 무거운 저장/필터/프레임/메타/DB는 백그라운드에서 처리
  Future<void> _takePhoto({bool isAutoBurst = false}) async {
    // 🔥🔥🔥 연속 촬영 문제 해결: 플래그를 setState() 호출 전에 동기적으로 설정
    // setState()는 비동기적으로 작동하므로, 플래그를 먼저 설정하여 race condition 방지
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 📸 _takePhoto ENTRY: isAutoBurst=$isAutoBurst, _isProcessing=$_isProcessing, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}, _burstCount=$_burstCount',
      );
    }
    if (_isProcessing) {
      _addDebugLog('[takePhoto] blocked: _isProcessing=true');
      if (kDebugMode) {
        debugPrint('[Petgram] 🚫 _takePhoto blocked: _isProcessing=true');
      }
      return;
    }
    
    // 플래그를 먼저 동기적으로 설정 (setState() 호출 전)
    _isProcessing = true;
    _addDebugLog('[takePhoto] set isProcessing=true (synchronously, before setState)');
    
    // UI 업데이트는 나중에 (필요한 경우)
    // 실제로 _isProcessing은 UI에 직접 표시되지 않으므로 setState() 호출 불필요

    // 🔥 크래시 방지: 프리뷰가 안정화될 때까지 대기 (최소 300ms)
    // 프리뷰가 방금 들어왔을 때 AVFoundation 세션이 완전히 안정화되지 않았을 수 있음
    if (_firstFrameTimestamp != null && !_shouldUseMockCamera) {
      final timeSinceFirstFrame = DateTime.now().difference(
        _firstFrameTimestamp!,
      );
      const minStabilizationDuration = Duration(milliseconds: 300);
      if (timeSinceFirstFrame < minStabilizationDuration) {
        final remainingMs =
            (minStabilizationDuration - timeSinceFirstFrame).inMilliseconds;
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ⏳ Camera stabilization wait: ${remainingMs}ms remaining (firstFrame=${_firstFrameTimestamp}, now=${DateTime.now()})',
          );
        }
        // 안정화 대기 중에는 조용히 무시 (사용자에게 메시지 표시하지 않음)
        return;
      }
    }

    // 🔥 Single Source of Truth: canUseCamera 강제 guard (최우선)
    // canUseCamera가 false이면 절대 네이티브 takePicture()를 호출하지 않음
    // 🔥🔥🔥 세션이 실행 중이 아니면 resumeSession 시도
    if (!canUseCamera) {
      final blockLog =
          '[takePhoto] ❌ BLOCKED: canUseCamera=false '
          '(nativeInit=${_cameraEngine.isInitialized}, isReady=${_cameraEngine.isCameraReady}, '
          'sessionRunning=${_cameraEngine.sessionRunning}, videoConnected=${_cameraEngine.videoConnected}, '
          'hasFirstFrame=${_cameraEngine.hasFirstFrame}, isReinitializing=$_isReinitializing)';
      _addDebugLog(blockLog);
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ $blockLog');
      }

      // 🔥 크래시 방지: 재초기화 중이거나 촬영 중이면 재초기화 시도하지 않음
      if (!_isReinitializing &&
          !_cameraEngine.isCapturingPhoto) {
        // 🔥🔥🔥 세션이 실행 중이 아니면 resumeSession 시도
        if (!(_cameraEngine.sessionRunning ?? false) && _cameraEngine.isInitialized) {
          if (kDebugMode) {
            debugPrint('[Petgram] 🔄 Session not running, attempting resumeSession...');
          }
          try {
            await _cameraEngine.resume();
            // resume 후 잠시 대기하여 세션 상태 확인
            await Future.delayed(const Duration(milliseconds: 500));
            final retryState = _cameraEngine.lastDebugState;
            if (retryState?.sessionRunning == true) {
              if (kDebugMode) {
                debugPrint('[Petgram] ✅ Session resumed successfully, retrying capture...');
              }
              // 세션이 재개되었으면 다시 촬영 시도
              _takePhoto();
              return;
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('[Petgram] ⚠️ Failed to resume session: $e');
            }
          }
        }
        
        // 사용자 안내
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('카메라 연결이 불안정합니다. 잠시 후 다시 시도해주세요.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      return;
    }

    // 타이머 모드인 경우 카운트다운 시작 (타이머로 인한 촬영이 아니고, 연속 촬영이 진행 중이 아닐 때만)
    if (_timerSeconds > 0 &&
        !_isTimerCounting &&
        !_isTimerTriggered &&
        _burstCount == 0) {
      await _startTimerCountdown();
      return;
    }

    // 🔥 실기기 동작 수정: 타이머 카운트다운 중이거나 연속 촬영 중일 때 셔터를 다시 누르면 중단
    // 단, 연속 촬영 자동 호출(isAutoBurst=true)일 때는 이 가드를 통과해야 함
    if (!isAutoBurst) {
    if (_isTimerCounting) {
      setState(() {
        _shouldStopTimer = true;
      });
      _addDebugLog('[UI] Shutter pressed: cancelling active timer');
      return;
    }

    if (_isBurstMode && _burstCount > 0) {
      setState(() {
        _shouldStopBurst = true;
      });
      _addDebugLog('[UI] Shutter pressed: cancelling active burst');
      return;
      }
    }

    // 🔥 촬영 중 중복 호출 방지
    if (_cameraEngine.isCapturingPhoto) {
      final blockLog = '[takePhoto] blocked: already capturing (isCapturingPhoto=true)';
      _addDebugLog(blockLog);
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ $blockLog');
        debugPrint(
          '[Petgram] 🔍 Debug: _isProcessing=$_isProcessing, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}, isAutoBurst=$isAutoBurst',
        );
      }
      return;
    }

    // 캡처 구간 시작
    final captureStart = DateTime.now();
    // 🔒 캡처 보호 펜스: 촬영 직후 일정 시간 동안 init/resume/sync 차단
    _captureFenceUntil = captureStart.add(const Duration(seconds: 4));
    _addDebugLog('[takePhoto] 🚧 capture fence set until $_captureFenceUntil');

    _addDebugLog('[takePhoto] set isProcessing=true (capture begin)');
    _logPreviewState('takePhoto_capture_begin');

    // 연속 촬영 모드 초기화 (촬영 시작 시)
    if (_isBurstMode && _burstCount == 0) {
      setState(() {
        _burstCount = 1; // 첫 장부터 카운팅 시작
        _shouldStopBurst = false;
      });
      if (kDebugMode) {
        debugPrint(
          '📸 연속 촬영 시작: $_burstCountSetting장 (타이머: $_isTimerTriggered)',
        );
      }
    }

    String? nativePhotoPath;

    try {
      _addDebugLog(
        '[takePhoto] BEGIN '
        'isProcessing=$_isProcessing, '
        'isTimerCounting=$_isTimerCounting, '
        'isTimerTriggered=$_isTimerTriggered, '
        'burstCount=$_burstCount, '
        'shouldUseMock=$_shouldUseMockCamera, '
        'isInitialized=${_cameraEngine.isInitialized}',
      );

      File file;
      String? mockImagePath;

      if (_shouldUseMockCamera) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 🎭 _takePhoto: Mock camera mode detected, using CameraEngine.takePicture()',
          );
        }

        // Mock 카메라 모드: CameraEngine.takePicture() 사용
        final meta = _buildCurrentPhotoMeta();
        final aspectRatio = aspectRatioOf(_aspectMode);

        try {
          // CameraEngine.takePicture()가 Mock 이미지 파일 경로를 반환
          mockImagePath = await _cameraEngine.takePicture(
            filterKey: _shootFilterKey,
            filterIntensity: _liveIntensity,
            brightness: null, // Mock에서는 밝기 조정을 이미지 처리로 하지 않음 (프리뷰만)
            enableFrame: _frameEnabled,
            frameMeta: _frameEnabled ? meta.frameMeta : null,
            aspectRatio: aspectRatio,
          );

          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🎭 Mock photo path from CameraEngine: $mockImagePath',
            );
          }

          file = File(mockImagePath);

          // Mock 이미지는 CameraEngine에서 기본 이미지만 생성하므로
          // 필터/밝기/프레임 처리는 여기서 추가로 수행
          final imageBytes = await file.readAsBytes();
          final originalImage = img.decodeImage(imageBytes);

          if (originalImage == null) {
            throw Exception('Failed to decode mock image from CameraEngine');
          }

          // 🔥 저장 파이프라인 해상도 검증: Mock 이미지 원본 해상도 로그
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 📸 Mock original image: ${originalImage.width}x${originalImage.height} pixels, zoom=${_uiZoomScale.toStringAsFixed(3)}',
            );
          }

          // 🔥 Mock 카메라 촬영 시 줌 적용: 줌 배율에 따라 이미지 크롭
          img.Image zoomedImage = originalImage;
          if (_uiZoomScale != 1.0) {
            // 줌 배율이 1.0이 아니면 중앙 기준으로 크롭
            final double zoomFactor = _uiZoomScale.clamp(
              _uiZoomMin,
              _uiZoomMax,
            );
            final int cropWidth = (originalImage.width / zoomFactor).round();
            final int cropHeight = (originalImage.height / zoomFactor).round();
            final int cropX = (originalImage.width - cropWidth) ~/ 2;
            final int cropY = (originalImage.height - cropHeight) ~/ 2;

            zoomedImage = img.copyCrop(
              originalImage,
              x: cropX,
              y: cropY,
              width: cropWidth,
              height: cropHeight,
            );

            // 크롭된 이미지를 원본 크기로 리사이즈 (줌 효과)
            zoomedImage = img.copyResize(
              zoomedImage,
              width: originalImage.width,
              height: originalImage.height,
              interpolation: img.Interpolation.linear,
            );

            if (kDebugMode) {
              debugPrint(
                '[Petgram] 📸 Mock zoom applied: ${originalImage.width}x${originalImage.height} → '
                'crop ${cropWidth}x${cropHeight} at ($cropX, $cropY) → '
                'resize ${zoomedImage.width}x${zoomedImage.height} (zoom=${zoomFactor.toStringAsFixed(3)})',
              );
            }
          }

          // 프리뷰와 동일한 비율로 크롭 (center crop)
          var processedImage = _cropImageToAspectRatio(
            zoomedImage,
            aspectRatio,
          );

          // 🔥 저장 파이프라인 해상도 검증: 크롭 후 해상도 로그
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 📐 Mock cropped image: ${processedImage.width}x${processedImage.height} pixels',
            );
          }

          // 필터와 밝기 적용 (프리뷰와 동일)
          final previewMatrix = _buildPreviewColorMatrix();
          final bool hasFilterOrBrightness = !colorMatrixEquals(
            previewMatrix,
            kIdentityMatrix,
          );

          if (hasFilterOrBrightness) {
            // 🔥 저장 파이프라인 해상도 검증: 필터 적용 전 해상도
            final int beforeWidth = processedImage.width;
            final int beforeHeight = processedImage.height;
            if (kDebugMode) {
              debugPrint(
                '[Petgram] 🎨 Filter input: ${beforeWidth}x${beforeHeight} pixels',
              );
            }

            processedImage = _applyColorMatrixToImageDirect(
              processedImage,
              previewMatrix,
            );

            // 🔥 저장 파이프라인 해상도 검증: 필터 적용 후 해상도 (변경 없어야 함)
            if (kDebugMode) {
              debugPrint(
                '[Petgram] 🎨 Filter output: ${processedImage.width}x${processedImage.height} pixels',
              );
              if (processedImage.width != beforeWidth ||
                  processedImage.height != beforeHeight) {
                debugPrint(
                  '[Petgram] ⚠️ WARNING: Filter changed image size! '
                  '${beforeWidth}x${beforeHeight} → ${processedImage.width}x${processedImage.height}',
                );
              } else {
                debugPrint('[Petgram] ✅ Filter preserved image size');
              }
            }
          }

          // 프레임 오버레이 적용
          if (_frameEnabled && meta.frameMeta.isNotEmpty) {
            // 🔥 위치 정보가 최신인지 확인: _currentLocation이 있으면 frameMeta에 추가
            final frameMetaForOverlay = Map<String, dynamic>.from(
              meta.frameMeta,
            );
            if (_currentLocation != null && _currentLocation!.isNotEmpty) {
              frameMetaForOverlay['location'] = _currentLocation;
              if (kDebugMode) {
                debugPrint(
                  '[Petgram] 🖼️ 프레임 오버레이 적용 전 위치 정보 확인: $_currentLocation',
                );
              }
            } else {
              if (kDebugMode) {
                debugPrint(
                  '[Petgram] 🖼️ 프레임 오버레이 적용 전 위치 정보 없음: _currentLocation=${_currentLocation ?? "null"}',
                );
              }
            }

            processedImage = await _addFrameOverlayToImage(
              processedImage,
              frameMetaForOverlay, // 🔥 최신 위치 정보가 포함된 frameMeta 사용
            );

            // 🔥 저장 파이프라인 해상도 검증: 프레임 오버레이 후 해상도 로그
            if (kDebugMode) {
              debugPrint(
                '[Petgram] 🖼️ Mock with frame overlay: ${processedImage.width}x${processedImage.height} pixels',
              );
            }
          }

          // 🔥 저장 파이프라인 해상도 검증: 최종 저장 전 해상도 확인
          if (kDebugMode) {
            final minDimension = 2560; // 2K 해상도
            if (processedImage.width < minDimension ||
                processedImage.height < minDimension) {
              debugPrint(
                '[Petgram] ⚠️ WARNING: Mock image resolution below 2K: '
                '${processedImage.width}x${processedImage.height} (min=$minDimension px)',
              );
            } else {
              debugPrint(
                '[Petgram] ✅ Mock final image: ${processedImage.width}x${processedImage.height} pixels (2K+)',
              );
            }
          }

          // 🔥 저장 파이프라인 해상도 검증: 최종 JPEG 인코딩 직전 해상도
          if (kDebugMode) {
            final int maxDim = processedImage.width > processedImage.height
                ? processedImage.width
                : processedImage.height;
            debugPrint(
              '[Petgram] 💾 JPEG encode input: ${processedImage.width}x${processedImage.height} pixels '
              '(maxDimension=$maxDim)',
            );
          }

          // 최종 이미지 저장 (고품질: 95%)
          // 🔥 중요: encodeJpg는 해상도를 변경하지 않음 (품질만 조정)
          var jpegBytes = img.encodeJpg(processedImage, quality: 95);

          // 🔥 EXIF 메타데이터 추가 (프레임/펫 정보 포함)
          if (meta.frameMeta.isNotEmpty || meta.isPetgramShot) {
            final exifTag = meta.toExifTag();
            if (kDebugMode) {
              debugPrint('[Petgram] 📝 Adding EXIF metadata: $exifTag');
              debugPrint(
                '[Petgram] 📝 EXIF tag length: ${exifTag.length}, frameMeta keys: ${meta.frameMeta.keys}',
              );
              debugPrint(
                '[Petgram] 📝 isPetgramShot: ${meta.isPetgramShot}, frameKey: ${meta.frameKey}',
              );
            }

            try {
              if (kDebugMode) {
                debugPrint(
                  '[Petgram] 📝 EXIF tag size: ${exifTag.length} bytes (${exifTag.length ~/ 1024}KB)',
                );
              }

              // 🔥 EXIF 크기 제한 체크 (일반적으로 64KB 이하 권장)
              if (exifTag.length > 65535) {
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] ⚠️ EXIF tag too large (${exifTag.length} bytes > 64KB). '
                    'Skipping EXIF write, will save to DB only.',
                  );
                }
                // EXIF가 너무 크면 DB에만 저장 (이미지 파일에는 EXIF 없이 저장)
              } else {
                final updatedBytes = await attachPetgramExif(
                  jpegBytes: Uint8List.fromList(jpegBytes),
                  exifTag: exifTag,
                );

                // 🔥 EXIF가 실제로 추가되었는지 검증
                final verifyExif = await readUserCommentFromJpeg(updatedBytes);
                if (verifyExif != null && verifyExif.isNotEmpty) {
                  jpegBytes = updatedBytes;
                  if (kDebugMode) {
                    debugPrint('[Petgram] ✅ EXIF metadata added and verified');
                    debugPrint(
                      '[Petgram] ✅ Verified EXIF: ${verifyExif.substring(0, verifyExif.length > 100 ? 100 : verifyExif.length)}...',
                    );
                  }
                } else {
                  if (kDebugMode) {
                    debugPrint(
                      '[Petgram] ⚠️ EXIF metadata not found after adding! '
                      'Will save to DB only (EXIF write failed).',
                    );
                  }
                  // EXIF 추가 실패 시 원본 bytes 사용 (DB에는 저장됨)
                }
              }
            } catch (e) {
              if (kDebugMode) {
                debugPrint('[Petgram] ⚠️ Failed to add EXIF metadata: $e');
                debugPrint(
                  '[Petgram] ⚠️ Will save metadata to DB only (EXIF write failed).',
                );
              }
              // EXIF 추가 실패해도 이미지는 저장 (DB에는 메타데이터 저장됨)
            }
          }

          await file.writeAsBytes(jpegBytes);

          if (kDebugMode) {
            debugPrint(
              '[Petgram] 💾 Mock JPEG saved: ${jpegBytes.length ~/ 1024}KB, '
              'quality=95%, resolution=${processedImage.width}x${processedImage.height}',
            );
            // 🔥 최종 저장된 파일의 실제 해상도 확인 (디코딩하여 검증)
            final savedImage = img.decodeImage(jpegBytes);
            if (savedImage != null) {
              debugPrint(
                '[Petgram] 🔍 Saved file decoded: ${savedImage.width}x${savedImage.height} pixels '
                '(original: ${processedImage.width}x${processedImage.height})',
              );
              if (savedImage.width != processedImage.width ||
                  savedImage.height != processedImage.height) {
                debugPrint(
                  '[Petgram] ⚠️ CRITICAL: JPEG encoding changed resolution! '
                  '${processedImage.width}x${processedImage.height} → ${savedImage.width}x${savedImage.height}',
                );
              } else {
                debugPrint('[Petgram] ✅ JPEG encoding preserved resolution');
              }
            }

            // 🔥 저장된 파일을 다시 읽어서 실제 해상도 및 EXIF 확인
            try {
              final savedFileBytes = await file.readAsBytes();
              final reReadImage = img.decodeImage(savedFileBytes);
              if (reReadImage != null) {
                debugPrint(
                  '[Petgram] 🔍 Re-read saved file: ${reReadImage.width}x${reReadImage.height} pixels '
                  '(expected: ${processedImage.width}x${processedImage.height})',
                );
                if (reReadImage.width != processedImage.width ||
                    reReadImage.height != processedImage.height) {
                  debugPrint(
                    '[Petgram] ⚠️ CRITICAL: Saved file resolution mismatch! '
                    '${processedImage.width}x${processedImage.height} → ${reReadImage.width}x${reReadImage.height}',
                  );
                } else {
                  debugPrint('[Petgram] ✅ Saved file resolution matches');
                }
              }

              // 🔥 저장된 파일에서 EXIF 메타데이터 확인
              if (meta.frameMeta.isNotEmpty || meta.isPetgramShot) {
                final savedExifTag = await readUserCommentFromJpeg(
                  savedFileBytes,
                );
                if (savedExifTag != null && savedExifTag.isNotEmpty) {
                  debugPrint(
                    '[Petgram] ✅ EXIF metadata verified in saved file: ${savedExifTag.substring(0, savedExifTag.length > 100 ? 100 : savedExifTag.length)}...',
                  );

                  // EXIF 태그 비교
                  final expectedExifTag = meta.toExifTag();
                  if (savedExifTag == expectedExifTag) {
                    debugPrint(
                      '[Petgram] ✅ EXIF metadata matches expected value',
                    );
                  } else {
                    debugPrint('[Petgram] ⚠️ WARNING: EXIF metadata mismatch!');
                    debugPrint(
                      '[Petgram]   Expected: ${expectedExifTag.substring(0, expectedExifTag.length > 100 ? 100 : expectedExifTag.length)}...',
                    );
                    debugPrint(
                      '[Petgram]   Saved: ${savedExifTag.substring(0, savedExifTag.length > 100 ? 100 : savedExifTag.length)}...',
                    );
                  }
                } else {
                  debugPrint(
                    '[Petgram] ⚠️ CRITICAL: EXIF metadata not found in saved file!',
                  );
                }
              }
            } catch (e) {
              debugPrint('[Petgram] ⚠️ Failed to re-read saved file: $e');
            }
          }

          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🎭 Mock image processed and saved: $mockImagePath',
            );
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[Petgram] ❌ Mock camera takePicture failed: $e');
          }
          rethrow;
        }

        // 갤러리 저장 시도 (시뮬레이터 포함)
        try {
          await Gal.putImage(mockImagePath);

          // 갤러리 저장 성공 (파일명만 반환)
          final galleryFileName =
              'PG_${DateTime.now().millisecondsSinceEpoch}.jpg';

          if (kDebugMode) {
            debugPrint(
              '[Petgram] ✅ Mock photo saved to gallery: $galleryFileName',
            );
          }

          // DB 저장은 백그라운드로 처리하여 UI 블로킹 방지
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 💾 Starting DB save for mock photo (gallery): $galleryFileName',
            );
          }

          unawaited(
            PetgramPhotoRepository.instance
                .upsertPhotoRecord(
                  filePath: galleryFileName, // 갤러리 저장 성공 시 파일명만 사용
                  meta: meta,
                  exifTag: meta.toExifTag(),
                )
                .then((rowId) {
                  if (kDebugMode) {
                    debugPrint(
                      '[Petgram] ✅ Mock photo record saved to DB: $galleryFileName (rowId: $rowId)',
                    );
                  }
                })
                .catchError((e, stackTrace) {
                  if (kDebugMode) {
                    debugPrint('[Petgram] ⚠️ Mock photo DB save error: $e');
                    debugPrint('[Petgram] ⚠️ Stack trace: $stackTrace');
                  }
                }),
          );
        } catch (e) {
          // 갤러리 저장 실패 시 임시 파일 경로로 DB 저장
          if (kDebugMode) {
            debugPrint(
              '[Petgram] ⚠️ Mock photo gallery save failed: $e, using temp path',
            );
          }

          // DB 저장은 백그라운드로 처리하여 UI 블로킹 방지
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 💾 Starting DB save for mock photo (temp): $mockImagePath',
            );
          }

          unawaited(
            PetgramPhotoRepository.instance
                .upsertPhotoRecord(
                  filePath: mockImagePath, // 임시 파일 경로 사용
                  meta: meta,
                  exifTag: meta.toExifTag(),
                )
                .then((rowId) {
                  if (kDebugMode) {
                    debugPrint(
                      '[Petgram] ✅ Mock photo record saved to DB: $mockImagePath (rowId: $rowId)',
                    );
                  }
                })
                .catchError((e, stackTrace) {
                  if (kDebugMode) {
                    debugPrint('[Petgram] ⚠️ Mock photo DB save error: $e');
                    debugPrint('[Petgram] ⚠️ Stack trace: $stackTrace');
                  }
                }),
          );
        }

        // 촬영 성공 피드백
        HapticFeedback.mediumImpact();

        if (kDebugMode) {
          debugPrint('[Petgram] ✅ Mock photo capture completed');
        }

        return; // Mock 촬영 완료
      } else if (_cameraEngine.isInitialized) {
        // 카메라 엔진을 통해 촬영
        final config = _buildCurrentFilterConfig();
        final meta = _buildCurrentPhotoMeta();

        // ⚠️ 중요: brightness는 하드웨어 노출 보정(exposureTargetBias)으로 이미 적용됨
        //          저장 시에는 추가로 brightness를 전달하지 않음 (중복 적용 방지)
        //          프리뷰에서 setExposureBias()로 이미 exposureTargetBias가 설정되어 있음

        // 🔥 프레임/칩 저장 문제 해결: frameMeta 전달 전 로그 확인
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 📸 Taking photo with frameMeta: '
            'enableFrame=${config.enableFrame}, '
            'frameMeta.keys=${meta.frameMeta.keys.toList()}, '
            'frameMeta.count=${meta.frameMeta.length}',
          );
          if (meta.frameMeta.isNotEmpty) {
            meta.frameMeta.forEach((key, value) {
              debugPrint(
                '[Petgram] 📸   frameMeta[$key] = $value (${value.runtimeType})',
              );
            });
          }
        }

        // 🔥 프레임 오버레이 통합: FrameOverlayConfig를 frameMeta에 포함하여 전달
        // 🔥 프레임이 활성화되어 있으면 항상 overlayConfig를 포함 (프리뷰와 동일하게)
        final frameMetaWithOverlay = Map<String, dynamic>.from(meta.frameMeta);
        
        // 🔥 프레임이 활성화되어 있으면 overlayConfig를 반드시 생성
        if (config.enableFrame) {
          final overlayConfig = _buildFrameOverlayConfig();
          
          // 🔥 디버그: overlayConfig 생성 상태 확인
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 📸 overlayConfig check: enableFrame=${config.enableFrame}, '
              'frameEnabled=$_frameEnabled, overlayConfig=${overlayConfig != null ? "exists" : "null"}, '
              'petList.length=${_petList.length}, selectedPetId=$_selectedPetId',
            );
          }
          
          if (overlayConfig != null) {
            final overlayJson = overlayConfig.toJson();
            frameMetaWithOverlay['overlayConfig'] = overlayJson;
            if (kDebugMode) {
              debugPrint(
                '[Petgram] 📸 FrameOverlayConfig added: topChips.count=${overlayConfig.topChips.length}, '
                'bottomChips.count=${overlayConfig.bottomChips.length}',
              );
              debugPrint(
                '[Petgram] 📸 overlayConfig JSON keys: ${overlayJson.keys.toList()}, '
                'topChips.length=${(overlayJson['topChips'] as List?)?.length ?? 0}, '
                'bottomChips.length=${(overlayJson['bottomChips'] as List?)?.length ?? 0}',
              );
            }
          } else {
            // 🔥 프레임이 활성화되어 있는데 overlayConfig가 null이면 경고
            // 이 경우에도 빈 overlayConfig를 전달하여 Native에서 처리하도록 함
            if (kDebugMode) {
              debugPrint(
                '[Petgram] ⚠️ WARNING: enableFrame=true but overlayConfig is null! '
                'frameEnabled=$_frameEnabled, petList.isEmpty=${_petList.isEmpty}, '
                'selectedPetId=$_selectedPetId',
              );
              debugPrint(
                '[Petgram] ⚠️ Creating empty overlayConfig to ensure frame overlay is attempted',
              );
            }
            // 빈 overlayConfig를 전달하여 Native에서 최소한 날짜 칩이라도 표시하도록 함
            frameMetaWithOverlay['overlayConfig'] = {
              'topChips': <Map<String, dynamic>>[],
              'bottomChips': <Map<String, dynamic>>[
                {
                  'label': 'date',
                  'value': '📅 ${DateTime.now().toString().split(' ')[0]}',
                },
              ],
            };
          }
        } else {
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 📸 enableFrame=false, skipping overlayConfig',
            );
          }
        }

        // 🔥 필터 일치 보장: 촬영 시점의 FilterConfig 로그
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 📸 Capture FilterConfig: filterKey=${config.filterKey}, '
            'intensity=${config.intensity}, brightness=${config.brightness}, '
            'petTone=${config.petProfile?.id ?? "none"}, enablePetTone=${config.enablePetToneOnSave}, '
            'aspectRatio=${config.aspectRatio}',
          );
        }

        // 🔥 크래시 디버깅: 촬영 전 상태 확인 및 로그
        final captureStartTime = DateTime.now();
        final cameraState = _cameraEngine.state;
        final isInitialized = _cameraEngine.isInitialized;
        final nativeCameraExists = _cameraEngine.nativeCamera != null;

        // 🔥 REFACTORING: 촬영 전 상태 확인 (동기화 불필요, 게터로 직접 읽음)
        // 🔥 중복 호출 방지: 타이머가 이미 1초마다 폴링하므로 직접 호출 제거
        // await _pollDebugState(); // lastDebugState 업데이트

        // 🔥 촬영 크래시 방지: 재초기화 중이거나 상태가 불안정하면 촬영 차단
        if (_isReinitializing) {
          final skipLog =
              '[Petgram] ⚠️ Capture blocked: camera is reinitializing';
          _addDebugLog(skipLog);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('카메라 초기화 중입니다. 잠시 후 다시 시도해주세요.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }

        // 🔥 REFACTORING: 단일 상태 소스 기반 촬영 차단
        final state = _cameraEngine.lastDebugState;
        if (state == null || !_isCameraHealthy) {
          final skipLog =
              '[Petgram] ⚠️ Capture blocked: camera not healthy (state=${state != null ? "exists" : "null"}, healthy=$_isCameraHealthy, hasFirstFrame=${state?.hasFirstFrame ?? false}, isPinkFallback=${state?.isPinkFallback ?? true})';
          _addDebugLog(skipLog);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('카메라가 준비되지 않았습니다. 잠시 후 다시 시도해주세요.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }

        // 🔥 추가 보호: hasFirstFrame=false이면 무조건 차단 (크래시 방지)
        if (!state.hasFirstFrame) {
          final skipLog =
              '[Petgram] ⚠️ Capture blocked: hasFirstFrame=false (waiting for first frame)';
          _addDebugLog(skipLog);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('카메라 프리뷰가 준비되지 않았습니다. 잠시 후 다시 시도해주세요.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }

        final debugInfo = StringBuffer()
          ..write('[Petgram] 📸 CAPTURE START: ')
          ..write('time=${captureStartTime.toIso8601String()}, ')
          ..write('cameraState=$cameraState, ')
          ..write('isInitialized=$isInitialized, ')
          ..write('nativeCameraExists=$nativeCameraExists, ')
          ..write(
            'sessionRunning=${_cameraEngine.lastDebugState?.sessionRunning ?? false}, ',
          )
          ..write(
            'videoConnected=${_cameraEngine.lastDebugState?.videoConnected ?? false}, ',
          )
          ..write('filterKey=${config.filterKey}, ')
          ..write('filterIntensity=${config.intensity}, ')
          ..write('enableFrame=${config.enableFrame}, ')
          ..write('aspectRatio=${config.aspectRatio}, ')
          ..write('frameMetaSize=${frameMetaWithOverlay.length}');

        if (kDebugMode) {
          debugPrint(debugInfo.toString());
        }
        _addDebugLog(debugInfo.toString());

        String imagePath;
        try {
          imagePath = await _cameraEngine.takePicture(
            filterKey: config.filterKey,
            filterIntensity: config.intensity,
            brightness: null, // 하드웨어 노출 보정만 사용 (일반적인 카메라 앱 방식)
            enableFrame: config.enableFrame,
            frameMeta: frameMetaWithOverlay, // 🔥 프레임 오버레이 포함 메타데이터 전달
            aspectRatio: config.aspectRatio,
          );

          // 🔥 크래시 디버깅: 촬영 성공 로그
          final captureEndTime = DateTime.now();
          final duration = captureEndTime.difference(captureStartTime);
          final successLog =
              '[Petgram] ✅ CAPTURE SUCCESS: duration=${duration.inMilliseconds}ms, imagePath=$imagePath';
          if (kDebugMode) {
            debugPrint(successLog);
          }
          _addDebugLog(successLog);
        } catch (e, stackTrace) {
          // 🔥 크래시 디버깅: 촬영 실패 상세 로그
          final captureEndTime = DateTime.now();
          final duration = captureEndTime.difference(captureStartTime);
          final errorLog = StringBuffer()
            ..write('[Petgram] ❌ CAPTURE FAILED: ')
            ..write('duration=${duration.inMilliseconds}ms, ')
            ..write('error=$e, ')
            ..write('errorType=${e.runtimeType}');

          if (kDebugMode) {
            debugPrint(errorLog.toString());
            debugPrint('[Petgram] ❌ Stack trace: $stackTrace');
          }
          _addDebugLog(errorLog.toString());
          _addDebugLog(
            '[Petgram] ❌ Stack: ${stackTrace.toString().substring(0, stackTrace.toString().length > 500 ? 500 : stackTrace.toString().length)}',
          );

          // 🔥 크래시 방지: StateError (isPinkFallback 등)는 사용자에게 알리고 재초기화 시도하지 않음
          if (e is StateError) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('카메라가 준비되지 않았습니다. 잠시 후 다시 시도해주세요.'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
            // StateError는 rethrow하지 않고 처리 완료
            return;
          }

          rethrow;
        }

        // 네이티브에서 이미지 처리 완료 (갤러리 저장 또는 임시 파일 저장)
        // DB 저장은 항상 수행 (갤러리 저장 성공/실패 여부와 무관)
        final bool isGallerySave = !imagePath.contains('/');

        if (isGallerySave) {
          // 갤러리 저장 성공 (파일명만 반환됨)
          if (kDebugMode) {
            debugPrint('[Petgram] ✅ Photo saved to gallery: $imagePath');
          }
        } else {
          // 임시 파일 경로인 경우 (갤러리 저장 실패 시, 시뮬레이터 등)
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('갤러리 저장에 실패했습니다. 임시 파일로 저장되었습니다.'),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 3),
              ),
            );
          }
          if (kDebugMode) {
            debugPrint(
              '[Petgram] ⚠️ Gallery save failed, saved to temp: $imagePath',
            );
          }
        }

        // DB 저장은 백그라운드로 처리하여 UI 블로킹 방지
        // 갤러리 저장 성공/실패 여부와 무관하게 항상 DB에 저장
        if (kDebugMode) {
          debugPrint('[Petgram] 💾 Starting DB save for: $imagePath');
        }

        unawaited(
          PetgramPhotoRepository.instance
              .upsertPhotoRecord(
                filePath: imagePath, // 갤러리 파일명 또는 임시 파일 경로
                meta: meta,
                exifTag: meta.toExifTag(),
              )
              .then((rowId) {
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] ✅ Photo record saved to DB: $imagePath (rowId: $rowId)',
                  );
                }
              })
              .catchError((e, stackTrace) {
                if (kDebugMode) {
                  debugPrint('[Petgram] ⚠️ DB save error: $e');
                  debugPrint('[Petgram] ⚠️ Stack trace: $stackTrace');
                }
              }),
        );

        return; // Flutter 후처리 불필요
      } else {
        // 카메라가 없으면 mock 사용
        file = await _createTempFileFromAsset('assets/images/mockup.png');
      }

      nativePhotoPath = file.path;
      if (kDebugMode) {
        debugPrint('[Petgram] 📸 Native photo path: $nativePhotoPath');
      }
      _logPerf('takePhoto.capture', captureStart);

      // 촬영 성공 피드백 (짧게)
      HapticFeedback.mediumImpact();

      // 네이티브에서 모든 처리 완료 (필터/밝기/프레임/EXIF/갤러리 저장)
      // Flutter 후처리 불필요
      if (kDebugMode) {
        debugPrint('✅ shoot completed (native processed)');
      }
    } catch (e, stack) {
      _addDebugLog('[takePhoto] ERROR during capture: $e');
      debugPrint('❌ takePhoto capture error: $e');
      debugPrint('❌ takePhoto capture stack: $stack');

      if (mounted) {
        String errorMessage = '사진 촬영 중 오류가 발생했어요.';
        if ('$e'.contains('permission') ||
            '$e'.contains('Permission') ||
            '$e'.contains('권한')) {
          errorMessage = '갤러리 저장 권한이 필요합니다. 설정에서 권한을 허용해주세요.';
        } else if ('$e'.contains('storage') || '$e'.contains('저장')) {
          errorMessage = '저장 공간이 부족할 수 있습니다. 저장 공간을 확인해주세요.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      // 🔥🔥🔥 연속 촬영 문제 해결: setState() 내부에서 _isProcessing을 false로 설정하여 위젯 재빌드 보장
      _addDebugLog('[takePhoto] set isProcessing=false (synchronously, in finally)');
      // 🔥🔥🔥 연속 촬영 문제 디버깅: isCapturingPhoto 상태 확인
      if (kDebugMode) {
        debugPrint('[Petgram] 🔍🔍🔍 _takePhoto finally: _isProcessing=false, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}');
      }
      if (mounted) {
        // 🔥🔥🔥 연속 촬영 문제 해결: setState() 내부에서 _isProcessing을 변경하여 위젯이 확실히 재빌드되도록 함
        setState(() {
          _isProcessing = false; // setState 내부에서 변경하여 위젯 재빌드 보장
        });
        _logPreviewState('takePhoto_capture_end');
        if (kDebugMode) {
          debugPrint('[Petgram] ✅ setState() called: _isProcessing=false, 위젯 재빌드 완료');
        }
      } else {
        // mounted가 false인 경우에도 플래그는 리셋
        _isProcessing = false;
      }

      // 연속 촬영 모드 처리 (캡처만 빠르게 이어감, 저장은 백그라운드)
      // 🔥🔥🔥 연속 촬영 문제 해결: 첫 번째 촬영이 완료될 때까지 기다린 후 다음 촬영 시작
      if (mounted) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 🔍 연속 촬영 체크: _isBurstMode=$_isBurstMode, _shouldStopBurst=$_shouldStopBurst, _burstCount=$_burstCount, _burstCountSetting=$_burstCountSetting',
          );
        }
        if (_isBurstMode && !_shouldStopBurst) {
          // 🔥🔥🔥 연속 촬영 문제 해결: < 로 변경하여 정확한 장수만 촬영
          // 예: 5장 촬영 시 _burstCount가 5일 때는 완료되어야 함 (1,2,3,4,5 총 5장)
          if (_burstCount < _burstCountSetting) {
            final nextBurstCount = _burstCount + 1;
            if (kDebugMode) {
              debugPrint(
                '[Petgram] 📸 연속 촬영 다음 촬영 예약: 현재=$_burstCount, 다음=$nextBurstCount, 목표=$_burstCountSetting',
              );
            }
            setState(() => _burstCount = nextBurstCount);
            Future.delayed(const Duration(milliseconds: 120), () async {
              if (kDebugMode) {
                debugPrint(
                  '[Petgram] 📸 연속 촬영 다음 촬영 시작: mounted=$mounted, _shouldStopBurst=$_shouldStopBurst, _burstCount=$_burstCount',
                );
              }
              if (mounted && !_shouldStopBurst) {
                // 🔥🔥🔥 연속 촬영 문제 해결: await를 사용하여 첫 번째 촬영이 완료될 때까지 기다림
                // 이렇게 하면 세 요청이 거의 동시에 들어오는 것을 방지할 수 있음
                // isAutoBurst=true로 설정하여 연속 촬영 자동 호출임을 표시
                await _takePhoto(isAutoBurst: true);
              } else {
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] 🛑 연속 촬영 중지됨: mounted=$mounted, _shouldStopBurst=$_shouldStopBurst',
                  );
                }
                if (mounted) {
                  setState(() {
                    _burstCount = 0;
                    _shouldStopBurst = false;
                  });
                }
              }
            });
          } else {
            if (kDebugMode) {
              debugPrint(
                '[Petgram] ✅ 연속 촬영 완료: $_burstCountSetting장 (현재=$_burstCount, 타이머: $_isTimerTriggered)',
              );
            }
            setState(() {
              _burstCount = 0;
              _shouldStopBurst = false;
              if (_isTimerTriggered) {
                _isTimerTriggered = false;
              }
            });
          }
        } else if (_shouldStopBurst) {
          if (kDebugMode) {
            debugPrint(
              '[Petgram] 🛑 연속 촬영 중지 요청 처리: _burstCount=$_burstCount',
            );
          }
          setState(() {
            _burstCount = 0;
            _shouldStopBurst = false;
          });
        }
      }
    }
  }

  /// 🔥 Issue 1 Fix: 필터 페이지 이동 시 카메라 상태 정리
  void _openFilterPage(File file, {PetgramPhotoMeta? originalMeta}) {
    // 🔥 필터 페이지 이동 시 카메라 세션 일시 중지 및 상태 플래그 리셋
    _pauseCameraSession();
    // 🔥 성능 최적화: 빈 setState 제거 (기능 영향 없음)
    // 로딩 상태 플래그는 실제로 변경되지 않으므로 setState 불필요
    // if (mounted) {
    //   setState(() {
    //     // 카메라 준비 상태는 유지하되, 초기화 중 플래그는 리셋
    //   });
    // }

    // 현재 선택된 펫 정보 가져오기
    PetInfo? currentPet;
    if (_selectedPetId != null && _petList.isNotEmpty) {
      try {
        currentPet = _petList.firstWhere((pet) => pet.id == _selectedPetId);
      } catch (e) {
        // 펫을 찾지 못한 경우 null
      }
    }

    // 🔥 FilterPage로 이동 시 카메라 pause (이미 위에서 호출됨)
    // FilterPage에서 돌아올 때 resume
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilterPage(
          imageFile: file,
          initialFilterKey: _shootFilterKey,
          selectedPet: currentPet,
          coatPreset: _liveCoatPreset,
          originalMeta:
              originalMeta, // 원본 메타데이터 전달 (우리 앱에서 촬영한 경우, null이면 외부 사진)
          aspectMode: _aspectMode, // 선택된 비율 모드 전달
        ),
      ),
    ).then((_) {
      // 🔥 FilterPage에서 돌아올 때 카메라 resume
      if (mounted) {
        _resumeCameraSession();
      }
    });
  }

  /// 🔥 프레임 오버레이 통합: FrameOverlayConfig 생성
  /// 프리뷰와 저장 모두 이 함수를 사용하여 일관성 유지
  FrameOverlayConfig? _buildFrameOverlayConfig() {
    // 🔥 디버그: 프레임 오버레이 생성 조건 확인
    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🖼️ _buildFrameOverlayConfig: frameEnabled=$_frameEnabled, '
        'petList.length=${_petList.length}, selectedPetId=$_selectedPetId',
      );
    }
    
    if (!_frameEnabled || _petList.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🖼️ _buildFrameOverlayConfig: returning null (frameEnabled=$_frameEnabled, petList.isEmpty=${_petList.isEmpty})',
        );
      }
      return null;
    }

    // 선택된 펫 정보 가져오기
    PetInfo? selectedPet;
    if (_selectedPetId != null) {
      try {
        selectedPet = _petList.firstWhere((pet) => pet.id == _selectedPetId);
      } catch (e) {
        if (_petList.isNotEmpty) {
          selectedPet = _petList.first;
        }
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 🖼️ _buildFrameOverlayConfig: selectedPetId not found, using first pet: ${selectedPet?.name ?? "null"}',
          );
        }
      }
    } else if (_petList.isNotEmpty) {
      selectedPet = _petList.first;
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🖼️ _buildFrameOverlayConfig: no selectedPetId, using first pet: ${selectedPet.name}',
        );
      }
    }

    if (selectedPet == null) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🖼️ _buildFrameOverlayConfig: returning null (selectedPet is null)',
        );
      }
      return null;
    }

    // 나이 계산
    final age = selectedPet.getAge();

    // 성별 텍스트
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

    // 종 텍스트
    String breedText =
        selectedPet.breed != null && selectedPet.breed!.isNotEmpty
        ? selectedPet.breed!.trim()
        : '';

    // 상단 칩 생성 (최대 2개)
    final List<FrameChip> topChips = [];

    // 1. 이름 칩 (아이콘 포함 - 프리뷰와 동일)
    final truncatedName = selectedPet.name.length > 12
        ? '${selectedPet.name.substring(0, 12)}...'
        : selectedPet.name;
    // 🔥 프리뷰와 동일: 아이콘 타입 및 Base64 전달 (dog/cat)
    final iconType = selectedPet.type; // "dog" 또는 "cat"
    String? iconBase64;
    if (iconType == 'dog') {
      iconBase64 = _dogIconBase64;
    } else if (iconType == 'cat') {
      iconBase64 = _catIconBase64;
    }
    topChips.add(
      FrameChip(
        label: 'name',
        value: truncatedName,
        iconType: iconType, // 아이콘 타입 전달
        iconBase64: iconBase64, // 아이콘 이미지 Base64 전달
      ),
    );

    // 2. 정보 칩 (나이, 성별, 종을 한 칩에 묶어서 표시)
    final List<String> infoParts = [];
    infoParts.add('$age살');
    if (genderText.isNotEmpty) {
      infoParts.add(genderText);
    }
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • ');
      topChips.add(FrameChip(label: 'info', value: infoText));
    }

    // 🔥 프리뷰와 동일: 하단 칩 생성 (날짜, 위치)
    final List<FrameChip> bottomChips = [];

    // 날짜 칩
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
    final dateStr = '📅 ${monthNames[now.month]} ${now.day}, ${now.year}';
    bottomChips.add(FrameChip(label: 'date', value: dateStr));

    // 위치 칩 (위치 정보가 있을 때만)
    if (_currentLocation != null && _currentLocation!.isNotEmpty) {
      final locationText = '📍 Shot on location in $_currentLocation';
      bottomChips.add(FrameChip(label: 'location', value: locationText));
    }

    return FrameOverlayConfig(
      topChips: topChips.take(2).toList(), // 최대 2개로 제한
      bottomChips: bottomChips, // 하단 칩 (프리뷰와 동일)
    );
  }

  /// 현재 촬영 설정에 따른 PetgramPhotoMeta 생성 (재사용 가능한 헬퍼)
  ///
  /// 촬영 저장 시나 FilterPage로 메타데이터 전달 시 사용
  PetgramPhotoMeta _buildCurrentPhotoMeta() {
    final frameKey = _frameEnabled ? 'default' : 'none'; // TODO: 실제 프레임 키로 교체

    // 선택된 펫 정보 가져오기 (프레임 설정 시 펫 정보 포함)
    PetInfo? selectedPet;
    if (_frameEnabled && _selectedPetId != null && _petList.isNotEmpty) {
      try {
        selectedPet = _petList.firstWhere((pet) => pet.id == _selectedPetId);
      } catch (e) {
        debugPrint('[Petgram] ⚠️ Selected pet not found: $_selectedPetId');
      }
    }

    // 🔥 프레임 오버레이 통합: FrameOverlayConfig를 frameMeta에 포함
    final overlayConfig = _buildFrameOverlayConfig();
    final baseMeta = buildPetgramMeta(
      frameKey: frameKey,
      selectedPet: selectedPet,
      selectedPetId: _selectedPetId,
      location: _currentLocation,
    );

    final frameMeta = Map<String, dynamic>.from(baseMeta.frameMeta);

    // 🔥 프리뷰와 동일: FrameOverlayConfig를 frameMeta에 추가 (topChips + bottomChips만)
    if (overlayConfig != null) {
      frameMeta['overlayConfig'] = overlayConfig.toJson();
    }

    return PetgramPhotoMeta(
      isPetgramShot: baseMeta.isPetgramShot,
      isPetgramEdited: baseMeta.isPetgramEdited,
      frameKey: baseMeta.frameKey,
      takenAt: baseMeta.takenAt,
      frameMeta: frameMeta,
    );
  }

  String _aspectLabel(AspectRatioMode mode) {
    switch (mode) {
      case AspectRatioMode.nineSixteen:
        return '9:16';
      case AspectRatioMode.threeFour:
        return '3:4';
      case AspectRatioMode.oneOne:
        return '1:1';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 🔥 성능 최적화: 스플래시는 initState에서 제거되므로 여기서는 제거하지 않음
    
    // 🔥 실기기 프리뷰 안 보이는 문제 해결:
    // 네이티브 카메라가 Flutter 뷰 뒤(z-order: back)에 위치하므로,
    // Flutter의 최상위 배경이 불투명하면 카메라 프리뷰가 가려짐.
    // 실기기 네이티브 카메라 모드일 때만 배경을 투명하게 설정.
    // 🔥 프리뷰 상하단 핑크색은 네이티브(RootViewController)가 비율에 맞춰 그리므로,
    // Flutter에서는 배경을 투명하게 설정하여 네이티브 배경색이 보이도록 함.

    return Scaffold(
      key: const Key('home_scaffold'),
      backgroundColor: Colors.transparent, // 🔥 투명: 네이티브 배경색이 보이도록
      body: SafeArea(
        top: true,
        bottom: false,
        child: Stack(
          children: [
            // 🔥 배경색 제거: 네이티브가 프리뷰 영역 외부를 핑크색으로 그리므로 Flutter에서는 투명하게 설정
            // Positioned.fill 배경색 제거 - 네이티브 배경색이 보이도록 함
            _buildCameraPreviewLayer(),
            _buildCameraOverlayLayer(),
            // 🔥 실기기 동작 수정: 타이머나 연속 촬영 중일 때 화면 빈 공간을 터치하면 즉시 중단
            if (_isTimerCounting || (_isBurstMode && _burstCount > 0))
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) {
                    setState(() {
                      if (_isTimerCounting) _shouldStopTimer = true;
                      if (_isBurstMode && _burstCount > 0)
                        _shouldStopBurst = true;
                    });
                    _addDebugLog(
                      '[UI] Global tap: cancelling active timer/burst',
                    );
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
            _buildTopControls(),
            _buildBottomControls(),
            // if (_showDebugOverlay) _buildCameraDebugOverlay(), // 🔥 디버그 삭제
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: kPetgramNavColor,
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.shot,
            onShotTap: () {},
            onDiaryTap: () => _openDiaryPage(context),
          ),
        ),
      ),
    );
  }

  /// 카메라 프리뷰 전용 레이어 (최하단)
  /// ⚠️ 중요: 이 레이어는 Positioned.fill로 전체 화면을 차지하되, 내부 Stack은 실제 프리뷰 영역만 차지
  ///          연핑크 배경이 프리뷰 영역 밖에서 보이도록 함
  Widget _buildCameraPreviewLayer() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _handleZoomScaleStart,
        onScaleUpdate: _handleZoomScaleUpdate,
        onScaleEnd: _handleZoomScaleEnd,
        onTapUp: (details) {
          // 🔥 실기기 동작 수정: 타이머나 연속 촬영 중일 때 화면을 터치하면 중단
          if (_isTimerCounting || (_isBurstMode && _burstCount > 0)) {
            setState(() {
              if (_isTimerCounting) _shouldStopTimer = true;
              if (_isBurstMode && _burstCount > 0) _shouldStopBurst = true;
            });
            _addDebugLog('[UI] Tap ignored: cancelling active timer/burst');
            return; // 중단 시 포커스 동작은 수행하지 않음
          }

          final RenderBox? box =
              _previewStackKey.currentContext?.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            final local = box.globalToLocal(details.globalPosition);
            _handleTapFocusAtPosition(local, box.size);
          }
        },
        child: Container(
          color: Colors.transparent,
          child: _buildCameraBackground(),
        ),
      ),
    );
  }

  /// 카메라 배경 및 프리뷰 영역 빌드
  Widget _buildCameraBackground() {
    final double targetRatio = _getTargetAspectRatio();
    final bool isCameraInitializing = _cameraEngine.isInitializing;

    // 프리뷰 소스 생성
    final Widget source = _buildCameraPreview();

    return _buildCameraStack(
      targetRatio: targetRatio,
      filter: null,
      source: source,
      isCameraInitializing: isCameraInitializing,
    );
  }

  /// 카메라 Stack 빌드 (중첩 AspectRatio 제거로 레이아웃 충돌 방지)
  /// 카메라 Stack 빌드 (가용 영역 꽉 채우기)
  Widget _buildCameraStack({
    required double targetRatio,
    required PetFilter? filter,
    required Widget source,
    required bool isCameraInitializing,
  }) {
    // 🔥 비율 변경 시 레이아웃 재빌드 보장: key에 targetRatio 포함
    return Container(
      key: ValueKey(
        'camera_stack_${targetRatio.toStringAsFixed(3)}_${_aspectMode.toString()}',
      ),
      color: Colors.transparent,
      // Stack을 Center가 아닌 Positioned.fill처럼 동작하게 하여 가용 영역을 꽉 채움
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double maxWidth = constraints.maxWidth;
          final double maxHeight = constraints.maxHeight;

          // targetRatio를 유지하면서 가용 영역 내 최대 크기 계산
          // 🔥🔥🔥 9:16 비율 특별 처리: 세로가 긴 비율이므로 세로를 기준으로 계산
          final bool isNineSixteen = (targetRatio - (9.0 / 16.0)).abs() < 0.001;
          double width, height;
          if (targetRatio > 1.0) {
            // 가로가 더 긴 비율 (예: 16:9)
            height = maxHeight;
            width = height * targetRatio;
            if (width > maxWidth) {
              width = maxWidth;
              height = width / targetRatio;
            }
          } else if (targetRatio < 1.0) {
            // 세로가 더 긴 비율 (예: 9:16, 3:4)
            // 🔥🔥🔥 9:16은 세로가 매우 길므로 세로를 최대한 보존
            height = maxHeight;
            width = height * targetRatio;
            if (width > maxWidth && !isNineSixteen) {
              // 9:16이 아닌 경우에만 가로를 기준으로 재계산 (3:4 등)
              width = maxWidth;
              height = width / targetRatio;
            }
            // 🔥🔥🔥 9:16 비율은 가로가 화면을 넘어도 세로를 보존 (가로는 좌우로 잘림)
          } else {
            // 1:1 비율: 화면의 작은 쪽을 기준으로 정사각형 생성
            final double minDimension = math.min(maxWidth, maxHeight);
            width = minDimension;
            height = minDimension;
          }

          final double top = (maxHeight - height) / 2;
          final double left = (maxWidth - width) / 2;

          // 🔥 iOS 실기기 프리뷰 동기화: 레이아웃 확정 후 다음 프레임에서 수행
          // 🔥 비율 변경 시 즉시 동기화: targetRatio가 변경되면 항상 동기화 시도
          if (Platform.isIOS && !_shouldUseMockCamera) {
            // 🔥 프리뷰 동기화 개선: postFrameCallback을 여러 번 호출하여 레이아웃 완료 보장
            // 비율 변경 시 레이아웃이 완료될 때까지 여러 프레임 대기
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              
              // 🔥🔥🔥 첫 번째 프레임: 카메라가 준비되었는지 확인 (백그라운드 복귀 시 세션 방해 방지)
              // 카메라가 초기화되지 않았거나 세션이 실행 중이 아니면 postFrameCallback 체인 중단
              // 🔥🔥🔥 단, 비율 변경 시(_lastSyncedPreviewRect == null)에는 세션 상태와 관계없이 동기화 시도
              if (!_shouldUseMockCamera) {
                if (!_cameraEngine.isInitialized) {
                  // 🔥 성능 최적화: 불필요한 로그 제거 (정상적인 스킵 상황)
                  return;
                }
                
                // 🔥 세션 상태 확인: 세션이 실행 중이 아니면 동기화 시도하지 않음
                // 🔥 단, 비율 변경 시(_lastSyncedPreviewRect == null) 또는 백그라운드 복귀 시(_isResumingCamera)에는 세션 상태와 관계없이 동기화 시도
                final sessionRunning = _cameraEngine.sessionRunning ?? false;
                final isAspectRatioChange = _lastSyncedPreviewRect == null;
                final isResuming = _isResumingCamera; // 🔥🔥🔥 백그라운드 복귀 시 강제 동기화
                
                if (!sessionRunning && !isAspectRatioChange && !isResuming) {
                  // 🔥 성능 최적화: 불필요한 로그 제거 (정상적인 스킵 상황)
                  return;
                }
                
                // 🔥 성능 최적화: 정상적인 동기화 로그 제거 (에러 상황만 로그)
                // if (kDebugMode && (!sessionRunning && (isAspectRatioChange || isResuming))) {
                //   debugPrint('[Petgram] 🚀 _buildCameraStack: FORCING sync...');
                // }
              }
              
              // 🔥🔥🔥 성능 최적화: 1:1 비율의 경우 즉시 동기화 (여러 프레임 대기 없이)
              // 1:1 비율은 정사각형이므로 레이아웃 계산이 단순하여 즉시 동기화 가능
              final bool isOneToOne = targetRatio == 1.0;
              
              // 첫 번째 프레임: 레이아웃이 완료되었는지 확인
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                
                // 🔥 1:1 비율의 경우: 즉시 동기화 (백그라운드 복귀 시 빠른 복원)
                // 🔥🔥🔥 백그라운드 복귀 시(_isResumingCamera)에도 강제 동기화
                if (isOneToOne && (_lastSyncedPreviewRect == null || _isResumingCamera)) {
                  // 계산된 값으로 즉시 rect 생성
                  final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
                  if (rootBox != null) {
                    final Offset localTopLeft = Offset(left, top);
                    final Offset globalTopLeft = rootBox.localToGlobal(localTopLeft);
                    final Rect rectToSync = Rect.fromLTWH(
                      globalTopLeft.dx,
                      globalTopLeft.dy,
                      width,
                      height,
                    );
                    
                    // 즉시 동기화 (여러 프레임 대기 없이)
                    if (!_shouldUseMockCamera && _cameraEngine.isInitialized) {
                      _syncPreviewRectToNativeFromLocal(rectToSync, context);
                      _syncPreviewRectWithRetry(rectToSync, context);
                      _lastSyncedPreviewRect = rectToSync;
                      if (kDebugMode) {
                        debugPrint(
                          '[Petgram] 🚀 _buildCameraStack: 1:1 ratio - immediate sync (rectToSync=$rectToSync, isResuming=$_isResumingCamera)',
                        );
                      }
                    }
                    return; // 1:1 비율은 여기서 종료
                  }
                }
                
                // 두 번째 프레임: 레이아웃이 확정된 후 동기화 수행 (1:1이 아닌 경우)
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  // 세 번째 프레임: 최종 확인 및 동기화 (비율 변경 시 레이아웃 완료 보장)
                  // 🔥🔥🔥 핵심 수정: _getPreviewRectFromKey()가 이전 레이아웃을 반환할 수 있으므로,
                  // 계산된 width, height, top, left를 직접 사용하여 rect 생성
                  final Rect? keyRect = _getPreviewRectFromKey();
                  Rect? rectToSync;
                  
                  if (keyRect != null && keyRect.width > 0 && keyRect.height > 0) {
                    // 🔥 비율 검증: 실제 rect 비율과 targetRatio를 비교 (백그라운드 복귀 시 잘못된 비율 방지)
                    final actualRatio = keyRect.width / keyRect.height;
                    final ratioDiff = (actualRatio - targetRatio).abs();
                    
                    // 🔥 1:1 비율은 더 엄격한 검증 (0.05 이상 차이면 재생성)
                    // 다른 비율은 0.1 이상 차이일 때만 재생성
                    final ratioThreshold = targetRatio == 1.0 ? 0.05 : 0.1;
                    
                    if (ratioDiff > ratioThreshold) {
                      // 🔥 비율이 크게 다르면 계산된 값으로 rect 재생성 (백그라운드 복귀 시 잘못된 비율 방지)
                      final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
                      if (rootBox != null) {
                        final Offset localTopLeft = Offset(left, top);
                        final Offset globalTopLeft = rootBox.localToGlobal(localTopLeft);
                        rectToSync = Rect.fromLTWH(
                          globalTopLeft.dx,
                          globalTopLeft.dy,
                          width,
                          height,
                        );
                        
                        if (kDebugMode) {
                          debugPrint(
                            '[Petgram] ⚠️ _buildCameraStack: keyRect has wrong ratio (targetRatio=$targetRatio, actualRatio=${actualRatio.toStringAsFixed(3)}, ratioDiff=${ratioDiff.toStringAsFixed(3)}), using calculated rect=$rectToSync',
                          );
                        }
                      } else {
                        rectToSync = keyRect;
                      }
                    } else {
                      // 비율이 맞거나 차이가 작으면 keyRect 사용
                      rectToSync = keyRect;
                    }
                  } else {
                    // keyRect가 null이거나 유효하지 않으면 계산된 값으로 rect 생성
                    final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
                    if (rootBox != null) {
                      final Offset localTopLeft = Offset(left, top);
                      final Offset globalTopLeft = rootBox.localToGlobal(localTopLeft);
                      rectToSync = Rect.fromLTWH(
                        globalTopLeft.dx,
                        globalTopLeft.dy,
                        width,
                        height,
                      );
                      
                      if (kDebugMode) {
                        debugPrint(
                          '[Petgram] ⚠️ _buildCameraStack: keyRect is null or invalid, using calculated rect=$rectToSync (targetRatio=$targetRatio, aspectMode=$_aspectMode)',
                        );
                      }
                    }
                  }
                  
                  if (rectToSync != null && rectToSync.width > 0 && rectToSync.height > 0) {
                    // 🔥🔥🔥 카메라 세션이 준비된 후에만 동기화 (백그라운드 복귀 시 세션 방해 방지)
                    // 카메라가 준비되지 않았거나 재개 중이면 동기화를 건너뛰고 다음 프레임에서 다시 시도
                    // 🔥🔥🔥 단, 비율 변경 시(_lastSyncedPreviewRect == null)에는 세션 상태와 관계없이 동기화 시도
                    final isAspectRatioChange = _lastSyncedPreviewRect == null;
                    
                    if (!_shouldUseMockCamera) {
                      if (!_cameraEngine.isInitialized) {
                        // 🔥 성능 최적화: 불필요한 로그 제거 (정상적인 스킵 상황)
                        return;
                      }
                      
                      // 🔥🔥🔥 백그라운드 복귀 시(_isResumingCamera) 강제 동기화
                      // 재개 중이면 무조건 동기화 시도 (최초 실행 후 첫 백그라운드 복귀 시 비율 복원 보장)
                      final shouldForceSync = _isResumingCamera || isAspectRatioChange;
                      
                      if (shouldForceSync) {
                        // 🔥 성능 최적화: 정상적인 동기화 로그 제거 (에러 상황만 로그)
                        // 즉시 동기화 진행 (아래 코드 계속 실행)
                      } else {
                        // 재개 중이 아니고 비율 변경도 아니면 동기화 스킵
                        // 🔥 성능 최적화: 불필요한 로그 제거 (정상적인 스킵 상황)
                        return;
                      }
                    }
                    
                    // 🔥🔥🔥 비율 검증: 백그라운드 복귀 시 잘못된 비율 방지
                    // 백그라운드 복귀 시 UI는 3:4인데 실제는 9:16으로 노출되는 문제 해결
                    final actualRatio = rectToSync.width / rectToSync.height;
                    final ratioDiff = (actualRatio - targetRatio).abs();
                    
                    // 🔥🔥🔥 성능 최적화: 1:1 비율의 경우 비율 검증 임계값 완화 (백그라운드 복귀 시 빠른 복원)
                    // 1:1 비율은 정사각형이므로 작은 차이도 정상 범위로 간주
                    // 백그라운드 복귀 시에는 더 관대하게 처리하여 빠른 복원 보장
                    final bool isResuming = _isResumingCamera;
                    final double ratioThreshold = (targetRatio == 1.0) 
                        ? (isResuming ? 0.1 : 0.05)  // 1:1 + 재개 중: 0.1, 1:1 + 일반: 0.05
                        : 0.1;  // 다른 비율: 0.1
                    
                    // 🔥 크기나 위치가 변경되면 무조건 동기화
                    final sizeOrPositionChanged =
                        _lastSyncedPreviewRect == null ||
                        (rectToSync.width != _lastSyncedPreviewRect!.width) ||
                        (rectToSync.height != _lastSyncedPreviewRect!.height) ||
                        (rectToSync.top != _lastSyncedPreviewRect!.top) ||
                        (rectToSync.left != _lastSyncedPreviewRect!.left);
                    
                    // 🔥🔥🔥 비율 검증: 크기/위치가 같아도 비율이 임계값 이상 차이나면 무조건 동기화
                    // 백그라운드 복귀 시 크기/위치가 같아도 비율이 다를 수 있음 (예: 3:4 vs 9:16)
                    // 🔥🔥🔥 1:1 비율 + 재개 중: 비율 검증을 완화하여 빠른 복원 보장
                    // ratioDiff > ratioThreshold: 비율 차이가 임계값 이상이면 무조건 동기화
                    // 🔥🔥🔥 촬영 후 비율 변경 시에도 동기화 보장: _lastSyncedPreviewRect가 null이면 무조건 동기화
                    final ratioMismatch = ratioDiff > ratioThreshold || (isResuming && targetRatio == 1.0 && ratioDiff > 0.05);
                    
                    // 🔥🔥🔥 촬영 후 비율 변경 시 동기화 보장: 
                    // 1. _lastSyncedPreviewRect가 null이면 무조건 동기화
                    // 2. 실제 rect의 비율이 targetRatio와 다르면 무조건 동기화 (비율 변경 감지)
                    // 3. 크기나 위치가 변경되면 동기화
                    // 🔥🔥🔥 비율 변경 시 무조건 동기화: isAspectRatioChange가 true이면 무조건 동기화
                    final shouldSync = isAspectRatioChange || sizeOrPositionChanged || ratioMismatch || ratioDiff > 0.01;
                    
                    // 🔥 성능 최적화: 비율 불일치 로그 제거 (정상적인 동기화 상황)
                    // if (kDebugMode && ratioMismatch && !sizeOrPositionChanged) {
                    //   debugPrint('[Petgram] ⚠️ _buildCameraStack: Ratio mismatch detected...');
                    // }
                    
                    if (shouldSync) {
                      // 🔥🔥🔥 성능 최적화: 같은 rect로 중복 호출 방지
                      // 크기와 위치가 모두 같으면 스킵 (비율 변경이 아닌 경우)
                      if (!isAspectRatioChange && _lastSyncedPreviewRect != null) {
                        final rect = _lastSyncedPreviewRect!;
                        final isSameRect = (rect.width - rectToSync.width).abs() < 0.1 &&
                            (rect.height - rectToSync.height).abs() < 0.1 &&
                            (rect.left - rectToSync.left).abs() < 0.1 &&
                            (rect.top - rectToSync.top).abs() < 0.1;
                        if (isSameRect) {
                          // 🔥 성능 최적화: 같은 rect로 중복 호출 방지
                          return;
                        }
                      }
                      
                      // 🔥🔥🔥 비율 변경 시 즉시 동기화 (세션 상태와 관계없이)
                      // 🔥🔥🔥 중요: 비율 변경 시에는 _lastSyncedPreviewRect를 동기화 후에 업데이트해야 함
                      // 동기화 전에 업데이트하면 다음 동기화 시도에서 isAspectRatioChange가 false가 되어 스킵됨
                      if (isAspectRatioChange) {
                        // 비율 변경 시: 동기화를 먼저 수행
                        _syncPreviewRectToNativeFromLocal(rectToSync, context);
                        _syncPreviewRectWithRetry(rectToSync, context);
                        // 동기화가 완료된 후에 _lastSyncedPreviewRect 업데이트 (다음 프레임에서)
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            _lastSyncedPreviewRect = rectToSync;
                            // 🔥 성능 최적화: _lastSyncedPreviewRect 업데이트 로그 제거
                            // if (kDebugMode) { debugPrint('[Petgram] 📐 _buildCameraStack: _lastSyncedPreviewRect updated...'); }
                          }
                        });
                      } else {
                        // 비율 변경이 아닌 경우: 기존 로직 유지 (동기화 전에 업데이트)
                        _lastSyncedPreviewRect = rectToSync;
                        _syncPreviewRectToNativeFromLocal(rectToSync, context);
                        _syncPreviewRectWithRetry(rectToSync, context);
                      }
                      // 🔥 성능 최적화: 정상적인 동기화 로그 제거 (레이아웃 변경 시마다 호출되므로)
                      // if (kDebugMode) { debugPrint('[Petgram] 📐 _buildCameraStack: synced preview rect=...'); }
                    }
                  } else if (kDebugMode) {
                    debugPrint(
                      '[Petgram] ⚠️ _buildCameraStack: rectToSync is null or invalid (rectToSync=$rectToSync)',
                    );
                  }
                });
              });
            });
          }

          // 프레임 칩이 그려질 시작점 계산 (프리뷰 내부 상대 좌표)
          // 저장 시 로직과 동일하게 프리뷰 상단 3% 지점을 기준으로 칩 배치 시작
          final double topBarHeight = height * 0.03;
          final double chipPadding = SharedImagePipeline.calculateChipPadding(
            width,
          );
          final double relativeFrameTopOffset =
              topBarHeight + chipPadding * 2.0;

          return Stack(
            children: [
              // 🔥 iOS 실기기 프리뷰 안 보이는 문제 해결: 네이티브 카메라가 배경을 처리하므로 Flutter에서는 투명하게 설정
              // 시뮬레이터나 Mock 모드일 때만 핑크색 배경을 그림
              if (_shouldUseMockCamera || _cameraEngine.isSimulator)
                Positioned.fill(
                  child: Container(
                    color: const Color(0xFFFFF0F5), // 연핑크색 (시뮬레이터/Mock 모드에서만)
                  ),
                ),
              // 🔥 프리뷰 영역: 계산된 위치와 크기
              Positioned(
                top: top,
                left: left,
                width: width,
                height: height,
                child: RepaintBoundary(
                  key: _previewStackKey,
                  child: Stack(
                    children: [
                      // 1. 카메라 프리뷰
                      // 🔥🔥🔥 ParentDataWidget 에러 근본 해결: ColorFiltered를 SizedBox로 감싸서 제약 명시적 전달
                      // 문제: ColorFiltered가 tight constraints를 제대로 처리하지 못함
                      // 해결책: SizedBox.expand()로 감싸서 부모 제약을 명시적으로 전달
                      Positioned.fill(
                        child: ClipRect(
                          child: SizedBox.expand(
                            child: ColorFiltered(
                              colorFilter: ColorFilter.matrix(
                                _buildPreviewColorMatrix(),
                              ),
                              child: source, // NativeCameraPreview (iOS에서는 LayoutBuilder 반환)
                            ),
                          ),
                        ),
                      ),
                      // 2. 격자선 (RepaintBoundary를 Positioned.fill 내부로 이동)
                      _buildGridLines(width, height),
                      // 3. 포커스 인디케이터
                      _buildFocusIndicatorLayer(width, height),
                      // 4. 프레임 UI (RepaintBoundary를 Positioned.fill 내부로 이동)
                      _buildFrameUILayer(width, height, relativeFrameTopOffset),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 카메라 프리뷰 소스 (순수 위젯만 반환, AspectRatio 금지)
  Widget _buildCameraPreview() {
    final bool isMock = _cameraEngine.useMockCamera || _shouldUseMockCamera;
    final bool isSimulator = _cameraEngine.isSimulator;

    // 🔥 시뮬레이터 및 실기기 초기화 전 대응:
    // 1. 이미 Mock 모드이거나, 시뮬레이터인 경우 (또는 iOS가 아닌데 카메라가 없는 경우)
    if (isMock || isSimulator || (widget.cameras.isEmpty && !Platform.isIOS)) {
      return Image.asset(
        'assets/images/mockup.png',
        fit: BoxFit.cover,
        alignment: Alignment.center,
        key: _mockPreviewKey,
        errorBuilder: (ctx, e, st) => Container(color: Colors.black),
      );
    }

    // 2. 실기기 환경 (iOS)
    // 🔥 프리뷰 표시: NativeCameraPreview는 항상 빌드 (초기화는 onCreated에서 처리)
    //                초기화 전이라도 위젯을 빌드해야 네이티브 뷰가 생성됨
    // 🔥 ParentDataWidget 에러 해결: Stack 제거하고 NativeCameraPreview 직접 반환
    // NativeCameraPreview는 SizedBox.shrink()를 반환하므로 Stack이 불필요
    return NativeCameraPreview(
      key: _nativePreviewKey,
      onCreated: (int viewId) async {
            _cameraEngine.attachNativeView(viewId);
            // 🔥🔥🔥 성능 최적화: 카메라 초기화와 비율 설정을 동시에 처리
            // 초기화 요청 시 비율 정보를 전달하고, 초기화 완료 후 즉시 비율 동기화 트리거
            if (mounted &&
                !_cameraEngine.isInitialized &&
                !_shouldUseMockCamera) {
              try {
                final targetRatio = _getTargetAspectRatio();
                
                // 🔥🔥🔥 카메라 초기화와 비율 설정을 동시에 요청
                // 네이티브 FSM에 초기화 요청 (비율 정보 포함, 중복 체크는 네이티브에서 처리)
                await _cameraEngine.requestInitializeIfNeeded(
                  viewId: viewId,
                  cameraPosition: 'back',
                  aspectRatio: targetRatio,
                );
                _addDebugLog(
                  '[NativePreview] ✅ Camera initialization requested with aspectRatio=${targetRatio.toStringAsFixed(3)}',
                );

                // 🔥🔥🔥 성능 최적화: 초기화 완료 대기 시간 단축 (5초 → 2초)
                // 세션이 시작되면 즉시 초기화 완료로 간주하고, 비율 동기화 트리거
                int checkCount = 0;
                const maxChecks = 20; // 20 * 100ms = 2초
                bool sessionStarted = false;
                while (checkCount < maxChecks && mounted) {
                  await Future.delayed(const Duration(milliseconds: 100));
                  final state = _cameraEngine.lastDebugState;
                  if (state != null && state.sessionRunning) {
                    sessionStarted = true;
                    _addDebugLog(
                      '[NativePreview] ✅ Camera session started (sessionRunning=true)',
                    );
                    break;
                  }
                  checkCount++;
                }

                // 🔥🔥🔥 초기화 완료 후 즉시 비율 동기화 트리거
                // _lastSyncedPreviewRect를 null로 설정하여 다음 프레임에서 즉시 동기화
                if (mounted && sessionStarted) {
                  _lastSyncedPreviewRect = null; // 비율 동기화 강제
                  
                  // 🔥 즉시 재빌드 트리거하여 비율 동기화 시도
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        // 상태 업데이트로 재빌드 트리거 (비율 동기화 보장)
                      });
                    }
                  });
                  
                  if (kDebugMode) {
                    debugPrint(
                      '[Petgram] 🚀 Camera initialized: aspect ratio sync triggered (targetRatio=${targetRatio.toStringAsFixed(3)})',
                    );
                  }
                }

                // 초기화 완료: isInitializing을 false로 설정하도록 강제 업데이트
                if (mounted) {
                  setState(() {
                    // 상태 업데이트를 통해 isInitializing이 false가 되도록 함
                  });
                }
              } catch (e) {
                _addDebugLog(
                  '[NativePreview] ❌ Camera initialization request failed: $e',
                );
                if (kDebugMode) {
                  debugPrint(
                    '[Petgram] ❌ Camera initialization request failed in onCreated: $e',
                  );
                }
                // 초기화 실패해도 isInitializing을 false로 설정 (무한 로딩 방지)
                if (mounted) {
                  setState(() {
                    // 상태 업데이트를 통해 isInitializing이 false가 되도록 함
                  });
                }
              }
            }
          },
        );

    // 🔥 프리뷰 표시: isInitialized가 true이면 프리뷰를 보여줌
    //    canUseCamera 조건은 촬영 시에만 체크하고, 프리뷰 표시는 초기화 완료만 확인
    // 🔥 ParentDataWidget 에러 해결: Stack 제거했으므로 조건부 위젯도 제거
    // NativeCameraPreview만 반환하고, 초기화 중 표시는 다른 곳에서 처리
  }

  /// GlobalKey를 이용한 안전한 좌표 측정
  /// 🔥 프리뷰 위치 문제 해결: 격자와 정확히 일치하도록 수정
  Rect? _getPreviewRectFromKey() {
    final contextObj = _previewStackKey.currentContext;
    if (contextObj == null) return null;
    final RenderBox? box = contextObj.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;

    // 🔥 수정: 최상위 스택(전체 화면) 기준으로 global 좌표 계산
    // 격자는 같은 Positioned 위젯 내부에 있으므로, 네이티브 프리뷰도 같은 위치에 있어야 함
    final RenderBox? rootBox = context.findRenderObject() as RenderBox?;
    if (rootBox == null) return null;

    // Positioned 위젯의 local 좌표를 global로 변환
    final Offset globalTopLeft = box.localToGlobal(
      Offset.zero,
      ancestor: rootBox,
    );
    return Rect.fromLTWH(
      globalTopLeft.dx,
      globalTopLeft.dy,
      box.size.width,
      box.size.height,
    );
  }

  /// 카메라 오버레이 레이어 (프리뷰를 덮지 않는 투명 오버레이)
  /// 옵션 패널, 필터 패널, 포커스 인디케이터 등이 여기에 배치됨
  /// ⚠️ 중요: 프리뷰 전체를 덮는 불투명 배경은 사용하지 않음 (Colors.transparent만 사용)
  Widget _buildCameraOverlayLayer() {
    return Stack(
      children: [
        // 왼쪽 옵션 패널 (Positioned로 제한된 영역에만 배치)
        _buildLeftOptionsPanel(),
        // 오른쪽 옵션 패널 (Positioned로 제한된 영역에만 배치)
        _buildRightOptionsPanel(),
        // 필터 패널 외부 탭 감지: 필터 패널 영역을 제외한 부분만 탭했을 때 패널 닫기
        // ⚠️ 중요: Positioned.fill + Container(color: Colors.transparent)만 사용하여 프리뷰를 가리지 않음
        // 필터 패널 외부 탭 감지: 필터 패널 영역을 제외한 부분만 탭했을 때 패널 닫기
        // ⚠️ 중요: Positioned.fill + Container(color: Colors.transparent)만 사용하여 프리뷰를 가리지 않음
        // 🔥 필터 패널이 열려있을 때 배경 터치로 닫기
        if (_filterPanelExpanded)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                // 배경을 탭하면 필터 패널 닫기
                if (_filterPanelExpanded && mounted) {
                  setState(() {
                    _filterPanelExpanded = false;
                  });
                }
              },
              child: Container(color: Colors.transparent),
            ),
          ),
        // 필터 패널
        Builder(
          builder: (context) {
            final double bottomBarHeight = 80.0;
            final double translateOffset = 40.0;
            final double filterPanelBottom =
                bottomBarHeight + translateOffset + 8;

            return Positioned(
              bottom: filterPanelBottom,
              left: 0,
              right: 0,
              child: ClipRect(
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  offset: _filterPanelExpanded
                      ? Offset.zero
                      : const Offset(0, 1),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _filterPanelExpanded ? 1.0 : 0.0,
                    child: IgnorePointer(
                      ignoring: !_filterPanelExpanded,
                      child: _buildFilterSelectionPanel(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        // 오토포커스 모드 상태 표시
        if (_isAutoFocusEnabled) _buildAutoFocusStatusIndicator(),
        // 프레임 칩 텍스트 디버그 표시 (디버그 모드에서만)
        if (kDebugMode) _buildFrameChipDebugIndicator(),
        // 초점 표시기
        // 자동 초점 표시기
        if (_showAutoFocusIndicator) _buildAutoFocusIndicator(),
        // 타이머 카운트다운 표시
        if (_isTimerCounting) _buildTimerCountdown(),
        // 연속 촬영 진행 표시
        if (_isBurstMode && _burstCount > 0) _buildBurstProgress(),
      ],
    );
  }

  /// 🔥 줌 배율 정상화: 핀치 제스처 시작 핸들러
  /// 🔥 핀치 줌 시작: 기준 줌값 저장
  void _handleZoomScaleStart(ScaleStartDetails details) {
    _baseUiZoomScale = _uiZoomScale;
  }

  /// 🔥 핀치 줌 업데이트: 직관적인 확대/축소 방향
  /// - 두 손가락 벌리면 확대 (scale > 1.0)
  /// - 두 손가락 모으면 축소 (scale < 1.0)
  /// - base * scale 방식으로 연속적인 줌 보장
  void _handleZoomScaleUpdate(ScaleUpdateDetails details) {
    if (!mounted) return;

    final double scale = details.scale;
    if (scale <= 0) return;

    // 🔥 직관적인 줌: base * scale 방식 (두 손가락 벌리면 확대, 모으면 축소)
    double newZoom = (_baseUiZoomScale * scale).clamp(
      _uiZoomMin,
      _uiZoomMax,
    );
    
    // 🔥🔥🔥 전면 카메라: 0.5x는 렌즈 전환이 불가능하므로 1.0으로 clamp
    if (_cameraLensDirection == CameraLensDirection.front && newZoom < 1.0) {
      newZoom = 1.0;
    }

    // 🔥 변화량이 0.001 이상일 때만 업데이트 (불필요한 setState 방지)
    if ((newZoom - _uiZoomScale).abs() > 0.001) {
      setState(() {
        _uiZoomScale = newZoom;
      });

      // 🔥🔥🔥 iOS 기본 카메라 앱과 동일: Native에서 렌즈 전환을 자동으로 처리
      // Flutter에서는 setZoom만 호출하면 Native가 필요한 렌즈 전환을 자동으로 수행
      if (_cameraEngine.isInitialized && !_shouldUseMockCamera) {
        _cameraEngine.setZoom(_uiZoomScale);
        if (kDebugMode) {
          debugPrint(
            '[Zoom] uiZoomScale updated: ${_uiZoomScale.toStringAsFixed(3)}, '
            'lensKind=$_nativeLensKind, '
            'direction=${_cameraLensDirection == CameraLensDirection.front ? "front" : "back"}',
          );
        }
      }
    }
  }

  /// 🔥 핀치 줌 종료: 최종 줌값 적용
  /// 🔥🔥🔥 iOS 기본 앱과 동일: Native에서 렌즈 전환을 자동으로 처리
  void _handleZoomScaleEnd(ScaleEndDetails details) {
    // 최종 줌 값 적용 (Native가 렌즈 전환을 자동으로 처리)
    if (_cameraEngine.isInitialized && !_shouldUseMockCamera) {
      if (kDebugMode) {
        debugPrint(
          '[Zoom] Pinch zoom end: final uiZoomScale=${_uiZoomScale.toStringAsFixed(3)} (Native will handle lens switching)',
        );
      }
      _cameraEngine.setZoom(_uiZoomScale);
    }
  }

  List<double> _getZoomPresets() {
    // 🔥🔥🔥 전면 카메라: 0.5x는 렌즈 전환이 불가능하므로 제외
    if (_cameraLensDirection == CameraLensDirection.front) {
      return _uiZoomPresets.where((zoom) => zoom >= 1.0).toList()..sort();
    }
    // 후면 카메라: 모든 프리셋 옵션 반환 (0.5x, 1x, 2x, 3x)
    return List<double>.from(_uiZoomPresets)..sort();
  }

  /// 🔥 좌표계 통일: Stack 로컬 좌표를 global 좌표로 변환하여 네이티브에 동기화
  /// [localRect]는 Stack 로컬 좌표계의 프리뷰 rect
  /// [stackContext]는 Stack의 BuildContext
  ///
  /// 🔥 수정 3: 촬영 중에는 레이아웃 동기화 차단 (세션 안정성 보장)
  void _syncPreviewRectToNativeFromLocal(
    Rect localRect,
    BuildContext stackContext,
  ) {
    // 🔥 수정 3: 촬영 중에는 레이아웃 동기화 차단
    if (_isProcessing || _cameraEngine.isCapturingPhoto) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ _syncPreviewRectToNativeFromLocal: blocked during photo capture',
        );
      }
      return;
    }

    // 🔥🔥🔥 성능 최적화: 같은 rect로 중복 호출 방지 (함수 레벨에서도 체크)
    if (_lastSyncedPreviewRect != null) {
      final rect = _lastSyncedPreviewRect!;
      final isSameRect = (rect.width - localRect.width).abs() < 0.1 &&
          (rect.height - localRect.height).abs() < 0.1 &&
          (rect.left - localRect.left).abs() < 0.1 &&
          (rect.top - localRect.top).abs() < 0.1;
      if (isSameRect) {
        // 🔥 성능 최적화: 같은 rect로 중복 호출 방지
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ⏭️ _syncPreviewRectToNativeFromLocal: Skipped duplicate call (same rect)',
          );
        }
        return;
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🔍 _syncPreviewRectToNativeFromLocal: ENTRY - localRect=$localRect, nativeCamera=${_cameraEngine.nativeCamera != null ? "exists" : "null"}',
      );
    }
    if (_cameraEngine.nativeCamera == null) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] ⚠️ _syncPreviewRectToNativeFromLocal: nativeCamera is null, returning',
        );
      }
      // 네이티브가 아직 없으면 재동기화 대기열에 rect를 저장 (retry에서 처리)
      _pendingPreviewRectForSync = localRect;
      return;
    }

    try {
      // 🔥 프리뷰 위치 문제 해결: _getPreviewRectFromKey가 이미 global 좌표를 반환하므로
      // 이중 변환하지 않고 그대로 사용
      // localRect는 실제로는 _getPreviewRectFromKey에서 반환된 global 좌표입니다
      final Rect globalRect = localRect;

      // 🔥 validSize 문제 해결: globalRect도 유효한지 확인
      if (globalRect.width <= 0 || globalRect.height <= 0) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ⚠️ _syncPreviewRectToNativeFromLocal: invalid globalRect (width=${globalRect.width}, height=${globalRect.height}), skipping',
          );
        }
        return;
      }

      // 🔥 성능 최적화: 상세 로그 제거 (레이아웃 변경 시마다 호출되므로)
      // if (kDebugMode) { debugPrint('[Petgram] 📐 _syncPreviewRectToNativeFromLocal DETAILED:...'); }

      final now = DateTime.now();
      final fenceActive =
          _captureFenceUntil != null && now.isBefore(_captureFenceUntil!);
      if (_isProcessing || _cameraEngine.isCapturingPhoto || fenceActive) {
        _pendingPreviewRectForSync = localRect;
        if (kDebugMode && _showDebugOverlay) {
          _addDebugLog(
            '[PreviewSync] ⚠️ blocked by capture fence during sync (pending rect saved) fenceActive=$fenceActive',
          );
        }
      } else {
        _cameraEngine.nativeCamera!.updatePreviewLayout(
          x: globalRect.left,
          y: globalRect.top,
          width: globalRect.width,
          height: globalRect.height,
        );
        // 🔥🔥🔥 성능 최적화: 동기화 성공 시 _lastSyncedPreviewRect 업데이트
        _lastSyncedPreviewRect = localRect;
        if (kDebugMode && _showDebugOverlay) {
          _addDebugLog(
            '[PreviewSync] ✅ synced to native: rect=$globalRect (pending=${_pendingPreviewRectForSync != null}, retryCount=$_previewSyncRetryCount)',
          );
        }
        // 🔥 성능 최적화: 정상적인 동기화 로그 제거 (레이아웃 변경 시마다 호출되므로)
        // if (kDebugMode) { debugPrint('[Petgram] 📐 _syncPreviewRectToNativeFromLocal: ... synced to iOS'); }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ _syncPreviewRectToNativeFromLocal failed: $e');
      }
    }
  }

  /// 🔥 프리뷰 rect를 네이티브와 동기화 (네이티브 준비/촬영 여부를 고려해 재시도)
  void _syncPreviewRectWithRetry(
    Rect rect,
    BuildContext stackContext, {
    int maxRetry = 6,
    int delayMs = 80,
  }) {
    if (!mounted) return;

    // 촬영 중이면 재시도 예약
    if (_isProcessing || _cameraEngine.isCapturingPhoto) {
      _pendingPreviewRectForSync = rect;
      if (_previewSyncRetryCount < maxRetry && !_previewSyncRetryScheduled) {
        _previewSyncRetryScheduled = true;
        Future.delayed(Duration(milliseconds: delayMs), () {
          _previewSyncRetryScheduled = false;
          _syncPreviewRectWithRetry(
            rect,
            stackContext,
            maxRetry: maxRetry,
            delayMs: delayMs,
          );
        });
      }
      if (kDebugMode && _showDebugOverlay) {
        _addDebugLog(
          '[PreviewSync] ⏸️ capture in progress, schedule retry=${_previewSyncRetryCount + 1}/$maxRetry rect=$rect',
        );
      }
      return;
    }

    // 네이티브 카메라 준비되지 않음 → 재시도
    if (_cameraEngine.nativeCamera == null) {
      _pendingPreviewRectForSync = rect;
      if (_previewSyncRetryCount < maxRetry && !_previewSyncRetryScheduled) {
        _previewSyncRetryScheduled = true;
        _previewSyncRetryCount += 1;
        Future.delayed(Duration(milliseconds: delayMs), () {
          _previewSyncRetryScheduled = false;
          _syncPreviewRectWithRetry(
            rect,
            stackContext,
            maxRetry: maxRetry,
            delayMs: delayMs,
          );
        });
      }
      if (kDebugMode && _showDebugOverlay) {
        _addDebugLog(
          '[PreviewSync] ⏳ nativeCamera null, schedule retry=${_previewSyncRetryCount}/$maxRetry rect=$rect',
        );
      }
      return;
    }

    // 성공: 카운터/플래그 리셋 후 동기화
    _previewSyncRetryCount = 0;
    _previewSyncRetryScheduled = false;
    _pendingPreviewRectForSync = null;
    _syncPreviewRectToNativeFromLocal(rect, stackContext);
  }

  /// 카메라 프리뷰 크기 및 오버레이 계산 헬퍼 메서드
  /// 카메라 실제 비율을 기준으로 프리뷰 박스를 계산하고, 그 기준으로 오버레이를 계산
  Map<String, double> _calculateCameraPreviewDimensions() {
    final screenSize = MediaQuery.of(context).size;
    final double screenW = screenSize.width;
    final double screenH = screenSize.height;

    // 타겟 비율 계산 (1:1, 3:4, 9:16)
    final double targetRatio = aspectRatioOf(_aspectMode);

    // 프리뷰 박스 크기 계산 (targetRatio 기반)
    double previewW;
    double previewH;

    if (targetRatio > 1.0) {
      // 가로가 더 긴 비율: 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW / targetRatio;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH * targetRatio;
      }
    } else if (targetRatio < 1.0) {
      // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW / targetRatio;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH * targetRatio;
      }
    } else {
      // 1:1 비율: 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH;
      }
    }

    // 오버레이는 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
    // 하지만 기존 코드 호환성을 위해 0으로 설정
    double overlayTop = 0;
    double overlayBottom = 0;
    double nineSixteenOverlayTop = 0;
    double nineSixteenOverlayBottom = 0;

    return {
      'previewW': previewW,
      'previewH': previewH,
      'overlayTop': overlayTop,
      'overlayBottom': overlayBottom,
      'nineSixteenOverlayTop': nineSixteenOverlayTop,
      'nineSixteenOverlayBottom': nineSixteenOverlayBottom,
      'offsetX': (screenW - previewW) / 2,
      'offsetY': (screenH - previewH) / 2,
    };
  }

  /// 상하단 오버레이 (레거시 함수 - 더 이상 사용하지 않음)
  /// ⚠️ 이 함수는 이제 사용하지 않는 레거시 함수입니다.
  /// 실제로는 Stack의 첫 번째 children에서 Positioned.fill + Container로 연핑크 배경을 처리합니다.
  /// 이 함수는 호환성을 위해 유지하지만 항상 빈 위젯(SizedBox.shrink)을 반환합니다.

  /// 🔥 리팩터링: 프레임/칩 UI (전체 화면 기준 고정 배치)
  /// 프리뷰 rect와 완전히 분리하여 전체 화면 Stack의 최상위 children으로 배치
  /// 프리뷰 영역의 실제 위치(offsetY)를 기준으로 chipPadding만큼 아래에 그리기
  /// 🔥 리팩터링: 상단 컨트롤 (최상위 Stack으로 이동)
  /// 로고, 프레임 토글, 설정 버튼 등
  Widget _buildTopControls() {
    return _buildTopBar();
  }

  /// 🔥 리팩터링: 하단 컨트롤 (최상위 Stack으로 이동)
  /// 갤러리 버튼, 촬영 버튼, 사운드 버튼 등
  Widget _buildBottomControls() {
    return _buildBottomBar();
  }

  /// 자동 초점 표시기 (화면 중앙에 표시) - 일반 동그라미로 표시
  Widget _buildAutoFocusIndicator() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.transparent,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.9),
                          width: 1.6,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 오토포커스 모드 상태 표시 인디케이터 (세분화된 상태 지원)
  Widget _buildAutoFocusStatusIndicator() {
    // 🔥 AF 상태 세분화: 세 가지 상태로 구분
    Color borderColor;
    Color iconColor;
    Color textColor;
    final bool isAdjusting;

    switch (_focusStatus) {
      case _FocusStatus.adjusting:
        borderColor = Colors.orange.withValues(alpha: 0.8);
        iconColor = Colors.orangeAccent;
        textColor = Colors.orangeAccent;
        isAdjusting = true;
        break;
      case _FocusStatus.ready:
        borderColor = Colors.green.withValues(alpha: 0.8);
        iconColor = Colors.greenAccent;
        textColor = Colors.greenAccent;
        isAdjusting = false;
        break;
      case _FocusStatus.locked:
      case _FocusStatus.unknown:
        borderColor = Colors.grey.withValues(alpha: 0.8);
        iconColor = Colors.grey;
        textColor = Colors.grey;
        isAdjusting = false;
        break;
    }

    return Positioned(
      top: 60.0, // 상단 바 아래에 배치
      right: 12.0,
      child: IgnorePointer(
        ignoring: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 포커스 조정 중이면 애니메이션 효과
              isAdjusting
                  ? TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0.8, end: 1.2),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeInOut,
                      builder: (context, scale, child) {
                        return Transform.scale(
                          scale: scale,
                          child: Icon(
                            Icons.center_focus_strong,
                            size: 14,
                            color: iconColor,
                          ),
                        );
                      },
                      onEnd: () {
                        if (mounted && _isFocusAdjusting) {
                          setState(() {}); // 애니메이션 재시작
                        }
                      },
                    )
                  : Icon(Icons.center_focus_strong, size: 14, color: iconColor),
              const SizedBox(width: 6),
              Text(
                'AF',
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 타이머 카운트다운 표시
  /// 🔥🔥🔥 ParentDataWidget 오류 해결: Positioned.fill 제거하고 Stack 내에서 직접 배치
  /// 문제: Stack 내에서 여러 Positioned.fill이 충돌할 수 있음
  /// 해결책: Positioned.fill 대신 Positioned를 사용하지 않고 Stack의 child로 직접 배치
  Widget _buildTimerCountdown() {
    return IgnorePointer(
      ignoring: true,
      child: Center(
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$_timerSeconds',
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 프레임 칩 텍스트 디버그 인디케이터 (디버그 모드에서만 표시)
  Widget _buildFrameChipDebugIndicator() {
    final hasPets = _petList.isNotEmpty;
    final hasSelectedPet = _selectedPetId != null;
    final frameEnabled = _frameEnabled;

    PetInfo? selectedPet;
    if (hasSelectedPet && hasPets) {
      try {
        selectedPet = _petList.firstWhere((pet) => pet.id == _selectedPetId);
      } catch (e) {
        selectedPet = null;
      }
    }

    return Positioned(
      top: 100.0,
      right: 8.0,
      child: Container(
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Frame Debug',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Enabled: $frameEnabled',
              style: TextStyle(color: Colors.white, fontSize: 9),
            ),
            Text(
              'Pets: ${_petList.length}',
              style: TextStyle(color: Colors.white, fontSize: 9),
            ),
            Text(
              'Selected: ${hasSelectedPet ? _selectedPetId : "null"}',
              style: TextStyle(color: Colors.white, fontSize: 9),
            ),
            if (selectedPet != null) ...[
              Text(
                'Name: ${selectedPet.name}',
                style: TextStyle(color: Colors.white, fontSize: 9),
              ),
              Text(
                'Age: ${selectedPet.getAge()}',
                style: TextStyle(color: Colors.white, fontSize: 9),
              ),
              Text(
                'Breed: ${selectedPet.breed ?? "N/A"}',
                style: TextStyle(color: Colors.white, fontSize: 9),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 연속 촬영 진행 표시 (타이머와 동일한 위치와 크기)
  /// 고정 크기 Container + FittedBox로 숫자 자리수 증가 시에도 UI가 깨지지 않도록 수정
  Widget _buildBurstProgress() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Container(
                width: 42, // 최대 자리수(100/100)를 고려한 고정 너비
                height: 36, // 고정 높이
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  child: Text(
                    '$_burstCount/$_burstCountSetting',
                    style: const TextStyle(
                      fontSize: 64, // FittedBox가 자동으로 스케일 조정
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 초점 표시기 빌드
  /// - 상태에는 0~1 정규화 좌표만 저장하고
  /// - 실제 픽셀 좌표/크기는 LayoutBuilder 의 constraints 를 기준으로 계산한다.
  /// 화면 중앙에 자동 초점 설정 (최초 진입 시)
  Future<void> _setAutoFocusAtCenter() async {
    if (_shouldUseMockCamera) {
      return;
    }

    // 네이티브 카메라 확인
    // 네이티브 사용 가능 여부는 아래 카메라 API 호출 분기에서 사용된다.
    final bool canUseNative = _cameraEngine.isInitialized;

    if (!canUseNative) {
      return;
    }

    // 연속 자동초점만 활성화 (이미 초기화 시 설정됨)
    if (canUseNative) {
      try {
        // 카메라 엔진은 자동 초점을 기본으로 사용
        if (kDebugMode) {
          debugPrint('[Petgram] ✅ Continuous auto focus enabled');
        }
      } catch (e) {
        debugPrint('[Petgram] ❌ Failed to set continuous auto focus: $e');
      }
      // ⚠️ 중앙 포커스도 설정 (초기 진입 시)
      // 🔥🔥🔥 성능 최적화: 중복 호출 방지 (이미 설정된 경우 스킵)
      const centerPoint = Offset(0.5, 0.5);
      // 🔥🔥🔥 성능 최적화: 마지막 포커스 포인트가 중앙이면 스킵
      if (_lastFocusPoint == null || 
          (_lastFocusPoint!.dx - centerPoint.dx).abs() > 0.01 ||
          (_lastFocusPoint!.dy - centerPoint.dy).abs() > 0.01) {
        try {
          await _cameraEngine.setFocusPoint(centerPoint);
          // 🔥🔥🔥 성능 최적화: 호출 전에 _lastFocusPoint 업데이트하여 중복 호출 방지
          _lastFocusPoint = centerPoint;
          if (kDebugMode) {
            debugPrint('[Petgram] ✅ Center focus point set: $centerPoint');
          }
        } catch (e) {
          debugPrint('[Petgram] ❌ Failed to set center focus point: $e');
        }
      } else {
        // 🔥 성능 최적화: 이미 중앙 포커스가 설정되어 있으면 스킵
        if (kDebugMode) {
          debugPrint('[Petgram] ⏭️ Center focus point already set, skipping');
        }
      }
      return;
    }

    // 화면 중앙 좌표 (0.5, 0.5)
    const centerPoint = Offset(0.5, 0.5);

    // 🔥🔥🔥 성능 최적화: 중복 호출 방지 (이미 설정된 경우 스킵)
    if (_lastFocusPoint == null || 
        (_lastFocusPoint!.dx - centerPoint.dx).abs() > 0.01 ||
        (_lastFocusPoint!.dy - centerPoint.dy).abs() > 0.01) {
      if (kDebugMode) {
        debugPrint('[Petgram] 🔍 자동 초점 설정: 화면 중앙 ($centerPoint)');
      }

      // 카메라에 초점 설정 (자동 초점이므로 UI 표시하지 않음)
      try {
        if (_cameraEngine.isInitialized) {
          await _cameraEngine.setFocusPoint(centerPoint);
          // 🔥🔥🔥 성능 최적화: 호출 전에 _lastFocusPoint 업데이트하여 중복 호출 방지
          _lastFocusPoint = centerPoint;
        }
        if (kDebugMode) {
          debugPrint('[Petgram] ✅ 자동 초점 설정 완료 (화면 중앙)');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Petgram] ❌ Failed to set center focus point: $e');
        }
      }
    } else {
      // 🔥 성능 최적화: 이미 중앙 포커스가 설정되어 있으면 스킵
      if (kDebugMode) {
        debugPrint('[Petgram] ⏭️ Center focus point already set, skipping');
      }
    }

    // 초점 설정 성공 시 자동 초점 표시기만 표시 (수동 터치 초점과 구분)
    if (mounted && _lastFocusPoint != null) {
      setState(() {
        _showAutoFocusIndicator = true;
      });
      // 1.5초 후 자동 초점 표시기 숨기기
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          setState(() {
            _showAutoFocusIndicator = false;
          });
        }
      });
    }
  }

  /// 탭 포커스 핸들러 (RenderBox local 좌표계 기준)
  /// [local]는 프리뷰 RenderBox 기준 local 좌표 (0 <= local.dx <= size.width, 0 <= local.dy <= size.height),
  /// [previewSize]는 프리뷰 RenderBox의 실제 크기.
  Future<void> _handleTapFocusAtPosition(Offset local, Size previewSize) async {
    // 🔥 실기기 터치 씹힘 방지: 빠른 연속 클릭 방지 (debounce)
    final now = DateTime.now();
    if (_lastTapTime != null) {
      final timeSinceLastTap = now.difference(_lastTapTime!);
      // 100ms 이내 연속 클릭은 무시 (실기기 터치 씹힘 방지)
      if (timeSinceLastTap.inMilliseconds < 100) {
        if (kDebugMode) {
          debugPrint(
            '[Petgram] ⚠️ Tap ignored: too fast (${timeSinceLastTap.inMilliseconds}ms since last tap)',
          );
        }
        return;
      }
    }
    _lastTapTime = now;

    // 🔥 실기기 터치 씹힘 방지: 이미 처리 중이면 무시
    if (_isProcessingTap) {
      if (kDebugMode) {
        debugPrint('[Petgram] ⚠️ Tap ignored: already processing');
      }
      return;
    }
    _isProcessingTap = true;

    // 🔥 프리뷰 영역 문제 해결: 이미 RenderBox 기준 local 좌표로 들어오므로
    // 프리뷰 영역 안에 있는지 재확인 (0 <= local.dx <= width, 0 <= local.dy <= height)
    if (local.dx < 0 ||
        local.dx > previewSize.width ||
        local.dy < 0 ||
        local.dy > previewSize.height) {
      if (kDebugMode) {
        debugPrint(
          '[Petgram] 🔍 Tap ignored (local): outside preview bounds (local=$local, size=$previewSize)',
        );
      }
      _isProcessingTap = false;
      return;
    }

    // 🔥 프리뷰 영역 밖이면 조용히 return (이미 위에서 처리됨)
    // preview 안이면 normalized 좌표 계산
    final double nxRaw = previewSize.width == 0
        ? 0.5
        : (local.dx / previewSize.width).clamp(0.0, 1.0);
    final double nyRaw = previewSize.height == 0
        ? 0.5
        : (local.dy / previewSize.height).clamp(0.0, 1.0);

    // 🔥🔥🔥 전면 카메라 포커스 인디케이터 위치 수정:
    // 전면 카메라는 미러링되어 보이므로, 사용자가 터치한 위치 = 화면에서 보이는 위치
    // UI 인디케이터는 터치한 위치와 동일하게 표시해야 함 (원본 좌표 사용)
    // 네이티브에 전달할 좌표는 네이티브에서 자동으로 반전 처리하므로 원본 좌표 전달
    final Offset normalized = Offset(nxRaw, nyRaw);
    
    // 🔥 UI 인디케이터 표시용 좌표: 터치한 위치와 동일 (원본 좌표 사용)
    // 전면 카메라는 이미 미러링되어 보이므로 추가 반전 불필요
    final Offset indicatorNormalized = Offset(nxRaw, nyRaw);

    // 🔥 포커스 UI 표시 시 setState는 딱 한 번만 발생하도록 조정
    // 인디케이터 on/off, 패널 닫기, auto-FE off, 타이머 off 등으로 setState 연속 발생 방지
    // _isPetFaceTracking 변경은 별도 postFrameCallback으로 처리하여 포커스 인디케이터 표시와 분리
    if (_isPetFaceTracking) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _isPetFaceTracking = false;
          });
        }
      });
    }

    // 🔥 실기기 타이머 문제 해결: 이전 타이머를 안전하게 취소
    // 타이머가 실행 중이면 취소하고, 타이머 완료 시점에 null로 설정되도록 보장
    if (_hideFocusIndicatorTimer != null) {
      _hideFocusIndicatorTimer!.cancel();
      // 타이머 취소 후 즉시 null로 설정하지 않고, 타이머 콜백에서 null로 설정하도록 함
      // 하지만 새로운 타이머를 생성하기 전에 null로 설정해야 함
      _hideFocusIndicatorTimer = null;
    }

    // 🔥 포커스 인디케이터 표시: 딱 한 번만 setState
    // UI 인디케이터는 전면 카메라일 때 반전된 좌표를 사용하여 표시
    setState(() {
      _focusIndicatorNormalized = indicatorNormalized;
      _showFocusIndicator = true;
    });

    if (kDebugMode) {
      debugPrint(
        '[Petgram] 🎯 Tap focus UI (local): local=$local, '
        'size=$previewSize, normalized=$normalized',
      );
    }

    // 카메라 API 호출 (비동기, await 없이)
    final bool canUseNative = _cameraEngine.isInitialized;
    if (_shouldUseMockCamera || !canUseNative) {
      if (kDebugMode) {
      debugPrint(
        '[Petgram] ℹ️ Mock or no camera: UI indicator only, skip setFocusPoint/setExposurePoint',
      );
      }
      // Mock 카메라인 경우 즉시 플래그 리셋
      Future.microtask(() {
        if (mounted) {
          _isProcessingTap = false;
        }
      });
    } else {
      try {
        // 🔥🔥🔥 성능 최적화: 같은 좌표로 중복 호출 방지
        // 0.01 이내 차이는 같은 좌표로 간주하여 중복 호출 방지
        // 🔥🔥🔥 중요: _lastFocusPoint와 _lastExposurePoint를 호출 전에 체크하여 즉시 스킵
        final double threshold = 0.01;
        final bool isSameFocusPoint = _lastFocusPoint != null &&
            (normalized.dx - _lastFocusPoint!.dx).abs() < threshold &&
            (normalized.dy - _lastFocusPoint!.dy).abs() < threshold;
        final bool isSameExposurePoint = _lastExposurePoint != null &&
            (normalized.dx - _lastExposurePoint!.dx).abs() < threshold &&
            (normalized.dy - _lastExposurePoint!.dy).abs() < threshold;
        
        if (isSameFocusPoint && isSameExposurePoint) {
          if (kDebugMode) {
            debugPrint('[Petgram] ⏭️ Tap ignored: same coordinates (normalized=$normalized, lastFocus=$_lastFocusPoint, lastExposure=$_lastExposurePoint)');
          }
          if (mounted) {
            _isProcessingTap = false;
          }
          return;
        }
        
        // 🔥🔥🔥 성능 최적화: 호출 전에 _lastFocusPoint와 _lastExposurePoint 업데이트하여 중복 호출 방지
        // 비동기 호출 전에 즉시 업데이트하여 동일한 좌표로 연속 호출되는 것을 방지
        _lastFocusPoint = normalized;
        _lastExposurePoint = normalized;
        
        if (kDebugMode) {
          debugPrint(
            '[Petgram] 🎯 Calling setFocusPoint: normalized=$normalized, cameraInitialized=$canUseNative',
          );
        }
        // 실제 카메라에 넘기는 좌표도 normalized 그대로 (반올림 금지)
        _cameraEngine.setFocusPoint(normalized).then((_) {
          if (mounted) {
            _lastFocusPoint = normalized; // 🔥🔥🔥 성능 최적화: 마지막 포커스 포인트 저장
          }
          if (kDebugMode) {
            debugPrint('[Petgram] ✅ setFocusPoint success: $normalized');
          }
          if (mounted) {
            _isProcessingTap = false;
          }
        }).catchError((e) {
          if (kDebugMode) {
            debugPrint('[Petgram] ❌ setFocusPoint error: $e');
          }
          if (mounted) {
            _isProcessingTap = false;
          }
        });
        
        // 🔥🔥🔥 성능 최적화: 같은 노출 포인트면 스킵
        if (!isSameExposurePoint) {
          _cameraEngine.setExposurePoint(normalized).then((_) {
            if (mounted) {
              _lastExposurePoint = normalized; // 🔥🔥🔥 성능 최적화: 마지막 노출 포인트 저장
            }
            if (kDebugMode) {
              debugPrint('[Petgram] ✅ setExposurePoint success: $normalized');
            }
          }).catchError((e) {
            if (kDebugMode) {
              debugPrint('[Petgram] ❌ setExposurePoint error: $e');
            }
          });
        } else {
          if (kDebugMode) {
            debugPrint('[Petgram] ⏭️ setExposurePoint skipped: same coordinates');
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Petgram] ❌ setFocusPoint/setExposurePoint exception: $e');
        }
        if (mounted) {
          _isProcessingTap = false;
        }
      }
    }

    // 🔥 실기기 타이머 문제 해결: 타이머를 안전하게 생성하고 관리
    // 타이머가 완료되거나 취소될 때 null로 설정되도록 보장
    _hideFocusIndicatorTimer = Timer(const Duration(seconds: 2), () {
      // 타이머가 취소되었는지 확인 (타이머가 null이면 이미 취소됨)
      if (_hideFocusIndicatorTimer == null) {
        return;
      }

      if (!mounted) {
        _hideFocusIndicatorTimer = null;
        return;
      }

      // 페이드아웃 애니메이션 시작
      setState(() {
        _showFocusIndicator = false;
      });

      // 300ms 후 normalized 제거 (페이드아웃 애니메이션 완료 후)
      Future.delayed(const Duration(milliseconds: 300), () {
        // 타이머가 취소되었는지 다시 확인
        if (_hideFocusIndicatorTimer == null) {
          return;
        }

        if (!mounted) {
          _hideFocusIndicatorTimer = null;
          return;
        }

        if (!_showFocusIndicator) {
          // 인디케이터가 여전히 숨겨진 상태일 때만 normalized 제거
          setState(() {
            _focusIndicatorNormalized = null;
          });
        }
        _hideFocusIndicatorTimer = null;
      });
    });

    // 🔥 실기기 터치 씹힘 방지: 처리 완료 플래그 해제 (다음 프레임에서)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isProcessingTap = false;
    });
  }

  List<double> _buildPreviewColorMatrix() {
    if (_isPureOriginalMode) {
      return List.from(kIdentityMatrix);
    }

    List<double> base = List.from(kIdentityMatrix);

    // 1. 펫톤 프로파일 적용 (40% 강도) - FilterPage와 동일
    final petProfile = _getCurrentPetToneProfile();
    if (petProfile != null) {
      final petToneMatrix = mixMatrix(
        kIdentityMatrix,
        petProfile.matrix,
        0.4, // 40% 강도로 약하게 적용
      );
      base = multiplyColorMatrices(base, petToneMatrix);
    }

    // 2. 필터 적용 - FilterPage와 동일
    final PetFilter? currentFilter = allFilters[_shootFilterKey];
    if (currentFilter != null && currentFilter.key != 'basic_none') {
      final filterMatrix = mixMatrix(
        kIdentityMatrix,
        currentFilter.matrix,
        _liveIntensity,
      );
      base = multiplyColorMatrices(base, filterMatrix);
    }

    // 네이티브 카메라(iOS) 경로에서는 Exposure Bias로 밝기를 조절하므로
    // 프리뷰 ColorMatrix에는 밝기 보정을 적용하지 않는다.
    final bool isNativeCameraActive =
        !kIsWeb &&
        Platform.isIOS &&
        _cameraEngine.isInitialized &&
        !_shouldUseMockCamera;

    // 3. 밝기 적용 - FilterPage와 동일한 계산 방식 (Mock/legacy 전용)
    // FilterPage: (_editBrightness / 50.0) * 40.0
    if (!isNativeCameraActive && _brightnessValue != 0.0) {
      // FilterPage와 동일한 계산: (_brightnessValue / 50.0) * 40.0
      // _brightnessValue는 -10 ~ +10 범위이므로, 이를 -50 ~ +50으로 변환
      final double normalizedBrightness =
          _brightnessValue * 5.0; // -10~+10 -> -50~+50
      final double b = (normalizedBrightness / 50.0) * 40.0;
      final List<double> brightnessMatrix = [
        1,
        0,
        0,
        0,
        b,
        0,
        1,
        0,
        0,
        b,
        0,
        0,
        1,
        0,
        b,
        0,
        0,
        0,
        1,
        0,
      ];
      base = multiplyColorMatrices(base, brightnessMatrix);
    }

    // 4. 대비는 HomePage에서 지원하지 않으므로 제외
    // FilterPage는 _editContrast를 지원하지만, HomePage는 밝기만 지원

    return base;
  }

  /// 상단 로고 + 프레임 설정 + 설정 버튼
  Widget _buildTopBar() {
    final double logoSize = 28.0;
    final double fontSize = 20.0;
    final double horizontalPadding = 12.0;
    final double verticalPadding = 10.0;
    final double iconSize = 18.0;

    return Positioned(
      top: 6.0,
      left: 0,
      right: 0,
      child: RepaintBoundary(
        child: Padding(
          padding: EdgeInsets.only(
            left: horizontalPadding,
            right: horizontalPadding,
            top: verticalPadding,
            bottom: verticalPadding,
          ),
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: logoSize,
              height: logoSize,
              child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
            ),
            const SizedBox(width: 0),
            Text(
              'Petgram',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                color: kMainPink,
                letterSpacing: 0.8,
                shadows: [
                  Shadow(
                    blurRadius: 12,
                    color: Colors.black.withValues(alpha: 0.8),
                    offset: const Offset(0, 3),
                  ),
                  Shadow(
                    blurRadius: 6,
                    color: Colors.black.withValues(alpha: 0.6),
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (_frameEnabled && _petList.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  final selectedPet = _selectedPetId != null
                      ? _petList.firstWhere(
                          (pet) => pet.id == _selectedPetId,
                          orElse: () => _petList.first,
                        )
                      : _petList.first;
                  if (selectedPet.locationEnabled) {
                    return Container(
                      width: 36,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 16,
                        onPressed: () async {
                          _checkAndFetchLocation(forceReload: true);
                          HapticFeedback.lightImpact();
                        },
                        icon: Stack(
                          children: [
                            Positioned(
                              left: 0.5,
                              top: 0.5,
                              child: Icon(
                                Icons.location_on,
                                color: Colors.black.withValues(alpha: 0.6),
                                size: 16,
                              ),
                            ),
                            const Icon(
                              Icons.location_on,
                              color: Colors.white,
                              size: 16,
                            ),
                          ],
                        ),
                        tooltip: '위치 정보 업데이트',
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              const SizedBox(width: 4),
            ],
            Container(
              width: 36,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: iconSize,
                onPressed: () async {
                  // 🔥 다른 페이지로 이동 시 카메라 pause
                  _pauseCameraSession();
                  if (!mounted) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FrameSettingsPage(
                        petList: _petList,
                        frameEnabled: _frameEnabled,
                        selectedPetId: _selectedPetId,
                        onPetListChanged: (list, selectedId) {
                          setState(() {
                            _petList = list;
                            _selectedPetId = selectedId;
                          });
                          if (_frameEnabled && _petList.isNotEmpty) {
                            final selectedPet = _selectedPetId != null
                                ? _petList.firstWhere(
                                    (pet) => pet.id == _selectedPetId,
                                    orElse: () => _petList.first,
                                  )
                                : _petList.first;
                            if (selectedPet.locationEnabled) {
                              _checkAndFetchLocation(alwaysReload: true);
                            } else if (mounted) {
                              setState(() {
                                _currentLocation = null;
                              });
                            }
                          }
                        },
                        onFrameEnabledChanged: (enabled) {
                          setState(() {
                            _frameEnabled = enabled;
                          });
                          _saveFrameEnabled();
                          if (enabled && _petList.isNotEmpty) {
                            final selectedPet = _selectedPetId != null
                                ? _petList.firstWhere(
                                    (pet) => pet.id == _selectedPetId,
                                    orElse: () => _petList.first,
                                  )
                                : _petList.first;
                            if (selectedPet.locationEnabled) {
                              _checkAndFetchLocation(alwaysReload: true);
                            }
                          } else if (mounted) {
                            setState(() {
                              _currentLocation = null;
                            });
                          }
                        },
                        onSelectedPetChanged: (selectedId) {
                          setState(() {
                            _selectedPetId = selectedId;
                          });
                          final currentPet = selectedId != null
                              ? _petList.firstWhere(
                                  (pet) => pet.id == selectedId,
                                  orElse: () => _petList.first,
                                )
                              : _petList.first;
                          if (currentPet.locationEnabled) {
                            _checkAndFetchLocation(alwaysReload: true);
                          } else if (mounted) {
                            setState(() {
                              _currentLocation = null;
                            });
                          }
                        },
                      ),
                    ),
                  );
                  // 🔥 페이지에서 돌아올 때 카메라 resume
                  if (mounted) {
                    _resumeCameraSession();
                  }
                },
                icon: Stack(
                  children: [
                    Positioned(
                      left: 0.5,
                      top: 0.5,
                      child: Icon(
                        _frameEnabled
                            ? Icons.photo_filter
                            : Icons.photo_filter_outlined,
                        color: Colors.black.withValues(alpha: 0.6),
                        size: iconSize,
                      ),
                    ),
                    Icon(
                      _frameEnabled
                          ? Icons.photo_filter
                          : Icons.photo_filter_outlined,
                      color: _frameEnabled ? kMainPink : Colors.white,
                      size: iconSize,
                    ),
                  ],
                ),
                tooltip: '프레임 설정',
              ),
            ),
            const SizedBox(width: 4),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () async {
                  debugPrint('[Petgram] ❤️ Support button tapped');
                  // 🔥 다른 페이지로 이동 시 카메라 pause
                  _pauseCameraSession();
                  if (!mounted) return;
                  await Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => SettingsPage()));
                  // 🔥 페이지에서 돌아올 때 카메라 resume
                  if (mounted) {
                    _resumeCameraSession();
                  }
                },
                child: Container(
                  width: 36,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.coffee,
                    color: Colors.white,
                    size: iconSize,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// 오른쪽 옵션 패널 (카메라 전환 버튼, 밝기 조절)
  Widget _buildRightOptionsPanel() {
    final previewDims = _calculateCameraPreviewDimensions();
    final double overlayTop = previewDims['overlayTop']!;
    final double overlayBottom = previewDims['overlayBottom']!;

    return Positioned(
      right: 8,
      top: overlayTop > 0 ? overlayTop : 0,
      bottom: overlayBottom > 0 ? overlayBottom : 0,
      child: GestureDetector(
        // 오른쪽 옵션 패널의 탭이 전체 화면 GestureDetector보다 우선순위를 가지도록
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end, // 오른쪽 끝 정렬
              children: [
                // 밝기 조절 슬라이더 (세로) - 개별 pill 배경 적용
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: RepaintBoundary(
                    child: _buildBrightnessSlider(),
                  ),
                ),
                const SizedBox(height: 10),
                // 카메라 전환 버튼 (전면/후면) - 개별 pill 배경 적용
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _buildOptionIconButton(
                    icon: _cameraLensDirection == CameraLensDirection.back
                        ? Icons.camera_front
                        : Icons.camera_rear,
                    isActive: true,
                    onTap: _switchCamera,
                    tooltip: _cameraLensDirection == CameraLensDirection.back
                        ? '전면 카메라로 전환'
                        : '후면 카메라로 전환',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 밝기 조절 슬라이더 (필터 강도 조절 슬라이더와 동일한 구조)
  Widget _buildBrightnessSlider() {
    return Container(
      width: 48,
      height: 200,
      // 🔥 터치 감지 개선: 수평 padding 추가하여 터치 영역 확대
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 4),
          // 🔥 심플한 밝기 아이콘 (작고 미니멀)
          Icon(
            _brightnessValue > 0
                ? Icons.add_circle_outline
                : _brightnessValue < 0
                ? Icons.remove_circle_outline
                : Icons.circle_outlined,
            color: Colors.white.withValues(alpha: 0.9),
            size: 18,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 1,
                offset: const Offset(0, 0.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 슬라이더 영역 (필터 강도 조절 슬라이더와 동일한 방식 - onPanUpdate 사용)
          // 🔥 터치 감지 개선: 터치 영역을 넓히고 Listener의 behavior를 opaque로 설정
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double sliderHeight = constraints.maxHeight;

                return Listener(
                  // 🔥 터치 감지 개선: behavior를 opaque로 설정하여 터치 영역 확보
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    setState(() {
                      _isBrightnessDragging = true;
                    });
                    // 터치 시작 시 값 업데이트
                    final double localY = event.localPosition.dy.clamp(
                      0.0,
                      sliderHeight,
                    );
                    final double normalized = localY / sliderHeight;
                    final double newValue = ((1.0 - normalized) * 20.0 - 10.0)
                        .clamp(-10.0, 10.0);
                    setState(() {
                      _brightnessValue = newValue;
                    });
                    // iOS 네이티브 카메라일 때는 Exposure Bias로 연결
                    _updateNativeExposureBias();
                    HapticFeedback.selectionClick();
                  },
                  onPointerMove: (event) {
                    // 🔥 터치 감지 개선: _isBrightnessDragging 상태와 event.down 모두 체크
                    if (_isBrightnessDragging && event.down) {
                      // 드래그 중 값 업데이트
                      final double localY = event.localPosition.dy.clamp(
                        0.0,
                        sliderHeight,
                      );
                      final double normalized = localY / sliderHeight;
                      final double newValue = ((1.0 - normalized) * 20.0 - 10.0)
                          .clamp(-10.0, 10.0);
                      setState(() {
                        _brightnessValue = newValue;
                      });
                      // iOS 네이티브 카메라일 때는 Exposure Bias로 연결
                      _updateNativeExposureBias();
                    }
                  },
                  onPointerUp: (_) {
                    setState(() {
                      _isBrightnessDragging = false;
                    });
                    HapticFeedback.selectionClick();
                  },
                  onPointerCancel: (_) {
                    setState(() {
                      _isBrightnessDragging = false;
                    });
                  },
                  child: Stack(
                    children: [
                      // 🔥 터치 감지 개선: 투명한 터치 영역 추가하여 터치 감지 영역 확대
                      Positioned.fill(
                        child: Container(
                          color: Colors.transparent,
                        ),
                      ),
                      // 🔥 심플한 배경 트랙 (더 얇고 투명하게)
                      Center(
                        child: Container(
                          width: 2,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                      // 🔥 심플한 현재 값 표시 (작고 미니멀한 썸)
                      Align(
                        alignment: Alignment(
                          0,
                          -((_brightnessValue + 10.0) / 20.0 * 2.0 -
                              1.0), // -10~10을 -1.0~1.0으로
                        ),
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.5),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          // 🔥 심플한 밝기 값 표시 (작고 미니멀, 0일 때는 숨김)
          if (_brightnessValue != 0.0)
          Text(
              _brightnessValue > 0
                ? '+${_brightnessValue.toInt()}'
                : '${_brightnessValue.toInt()}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 9,
                fontWeight: FontWeight.w500,
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 1,
                    offset: const Offset(0, 0.5),
                  ),
                ],
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 왼쪽 옵션 패널 (아이콘만 표시, 배경 없음)
  Widget _buildLeftOptionsPanel() {
    final previewDims = _calculateCameraPreviewDimensions();
    final double overlayTop = previewDims['overlayTop']!;
    final double overlayBottom = previewDims['overlayBottom']!;

    // 1:1 모드에서 프리뷰 영역 안에 모든 요소가 들어오도록
    // 간격을 최소화하고 프리뷰 영역에 맞춤
    final double topPadding = overlayTop > 0 ? overlayTop + 4.0 : 0;
    final double bottomPadding = overlayBottom > 0 ? overlayBottom + 4.0 : 0;

    return Positioned(
      key: ValueKey('left_options_${_uiZoomScale.toStringAsFixed(2)}'),
      left: 8,
      top: topPadding,
      bottom: bottomPadding,
      child: GestureDetector(
        // 왼쪽 옵션 패널의 탭이 전체 화면 GestureDetector보다 우선순위를 가지도록
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 플래시 토글
                _buildOptionIconButton(
                  icon: _flashMode == FlashMode.off
                      ? Icons.flash_off
                      : Icons.flash_on,
                  isActive: _flashMode != FlashMode.off,
                  onTap: _toggleFlash,
                  tooltip: _flashMode == FlashMode.off ? '플래시 켜기' : '플래시 끄기',
                ),
                const SizedBox(height: 4),
                // 격자 토글
                _buildOptionIconButton(
                  icon: _showGridLines ? Icons.grid_on : Icons.grid_off,
                  isActive: _showGridLines,
                  onTap: () {
                    setState(() {
                      _showGridLines = !_showGridLines;
                    });
                    _saveShowGridLines();
                  },
                  tooltip: _showGridLines ? '격자 끄기' : '격자 켜기',
                ),
                const SizedBox(height: 4),
                // 카메라 배율 선택 (0.8x, 1x, 1.5x 등) - 항상 표시
                _buildOptionIconButton(
                  key: ValueKey(
                    'zoom_button_${_uiZoomScale.toStringAsFixed(2)}',
                  ),
                  icon: Icons.center_focus_strong,
                  isActive: (_uiZoomScale - 1.0).abs() > 0.05,
                  label: '${_uiZoomScale.toStringAsFixed(1)}x',
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '카메라 배율',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Builder(
                          builder: (context) {
                            final uniqueOptions = _getZoomPresets();
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: uniqueOptions
                                  .map((ratio) => RepaintBoundary(
                                        child: _buildZoomRatioOption(ratio),
                                      ))
                                  .toList(),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  tooltip: '배율: ${_uiZoomScale.toStringAsFixed(1)}x',
                ),
                const SizedBox(height: 6),
                // 화면 비율 선택 (활성화 표시 + 비율 표기)
                _buildOptionIconButton(
                  icon: Icons.crop_free,
                  isActive: true, // 항상 활성화 표시
                  label: _aspectLabel(_aspectMode), // 선택된 비율 표기
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '화면 비율',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              title: const Text('9:16'),
                              trailing:
                                  _aspectMode == AspectRatioMode.nineSixteen
                                  ? const Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                _changeAspectMode(AspectRatioMode.nineSixteen);
                                Navigator.of(context).pop();
                              },
                            ),
                            ListTile(
                              title: const Text('3:4'),
                              trailing: _aspectMode == AspectRatioMode.threeFour
                                  ? const Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                _changeAspectMode(AspectRatioMode.threeFour);
                                Navigator.of(context).pop();
                              },
                            ),
                            ListTile(
                              title: const Text('1:1'),
                              trailing: _aspectMode == AspectRatioMode.oneOne
                                  ? const Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                _changeAspectMode(AspectRatioMode.oneOne);
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  tooltip: '화면 비율: ${_aspectLabel(_aspectMode)}',
                ),
                const SizedBox(height: 4),
                // 연속 촬영
                _buildOptionIconButton(
                  icon: Icons.camera_roll,
                  isActive: _isBurstMode,
                  label: _isBurstMode ? '${_burstCountSetting}' : null,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '연속 촬영 매수',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildBurstCountOption(3),
                            _buildBurstCountOption(5),
                            _buildBurstCountOption(10),
                            ListTile(
                              title: const Text('연속 촬영 끄기'),
                              trailing: !_isBurstMode
                                  ? const Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                setState(() {
                                  _isBurstMode = false;
                                });
                                _saveBurstSettings();
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  tooltip: _isBurstMode
                      ? '연속 촬영: ${_burstCountSetting}장'
                      : '연속 촬영',
                ),
                const SizedBox(height: 4),
                // 타이머
                _buildOptionIconButton(
                  icon: Icons.timer,
                  isActive: _timerSeconds > 0,
                  label: _timerSeconds > 0 ? '${_timerSeconds}' : null,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        title: const Text(
                          '타이머 선택',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTimerOption(3),
                            _buildTimerOption(5),
                            _buildTimerOption(10),
                            ListTile(
                              title: const Text('타이머 끄기'),
                              trailing: _timerSeconds == 0
                                  ? const Icon(Icons.check_circle, color: kMainPink)
                                  : const Icon(
                                      Icons.radio_button_unchecked,
                                      color: Colors.grey,
                                    ),
                              onTap: () {
                                setState(() {
                                  _timerSeconds = 0;
                                });
                                _saveTimerSettings();
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  tooltip: _timerSeconds > 0 ? '타이머: ${_timerSeconds}초' : '타이머',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 아이콘만 표시하는 옵션 버튼 (배경 없음)
  Widget _buildOptionIconButton({
    Key? key,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    String? label,
    String? tooltip,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            key: key,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: 44,
            height: label != null ? 56 : 44,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      icon,
                      key: ValueKey(icon),
                      size: 24,
                      color: isActive ? kMainPink : Colors.white,
                      shadows: [
                        // 흰색 배경에서도 또렷하게 보이도록 그림자 추가
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                if (label != null) ...[
                  const SizedBox(height: 2),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        label,
                        key: ValueKey(label), // label 변경 시 애니메이션
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: isActive ? kMainPink : Colors.white,
                          shadows: [
                            // 흰색 배경에서도 또렷하게 보이도록 그림자 추가
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 1,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 촬영용 필터 선택 패널 (펼쳐질 때만 표시)
  Widget _buildFilterSelectionPanel() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 🔥 1:1 필터 레이어 문제 해결: 필터 패널 영역의 터치를 소비하여 바깥 오버레이가 닫히지 않도록 함
        // 이제 전체 화면을 덮는 GestureDetector가 있으므로, 패널 내부 터치는 소비만 하면 됨
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFilterStrip(),
              const SizedBox(height: 8),
              _buildLiveIntensityControls(),
            ],
          ),
        ),
      ),
    );
  }

  /// 촬영용 필터 목록
  Widget _buildFilterStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 필터 선택 타이틀과 아코디언 아이콘
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '필터 선택',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  _filterPanelExpanded = false;
                });
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 20,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: kFilterOrder.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final key = kFilterOrder[index];
              final PetFilter f = allFilters[key]!;
              final bool selected = f.key == _shootFilterKey;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  // 🔥 필터 선택 시 패널이 닫히지 않도록 이벤트 소비
                  setState(() {
                    _shootFilterKey = f.key;
                  });
                  _saveSelectedFilter(f.key);
                  // 🔥 문제 2 해결: 필터 변경 시 즉시 적용 (postFrameCallback 제거)
                  // 실기기에서 카메라가 초기화되기 전에 필터가 변경되면
                  // postFrameCallback이 실행될 때는 이미 카메라가 준비되어 있을 수 있음
                  // 하지만 즉시 적용하는 것이 더 안정적임
                  _applyFilterIfChanged(
                    _shootFilterKey,
                    _liveIntensity.clamp(0.0, 1.0),
                  );
                  // 이벤트가 상위 GestureDetector로 전파되지 않도록 함 (패널이 닫히지 않음)
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 65,
                  height: 60,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    gradient: selected
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              kMainPink,
                              kMainPink.withValues(alpha: 0.8),
                            ],
                          )
                        : null,
                    color: selected
                        ? null
                        : Colors.black.withValues(
                            alpha: 0.4,
                          ), // 상단 후원하기 아이콘과 동일
                    borderRadius: BorderRadius.circular(18), // 상단 후원하기 아이콘과 동일
                    border: Border.all(
                      color: selected
                          ? Colors.transparent
                          : Colors.white.withValues(
                              alpha: 0.3,
                            ), // 상단 후원하기 아이콘과 동일
                      width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: kMainPink.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null, // 선택되지 않은 경우 boxShadow 제거
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        f.icon,
                        size: 18,
                        color: selected
                            ? Colors.white
                            : Colors.white, // 아이콘 색상 흰색으로 통일
                      ),
                      const SizedBox(height: 4),
                      Flexible(
                        child: Text(
                          f.label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: selected
                                ? Colors.white
                                : Colors.white, // 텍스트 색상 흰색으로 통일
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 라이브 필터 강도 / 털색 프리셋
  Widget _buildLiveIntensityControls() {
    final bool isBasic = _shootFilterKey == 'basic_none';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '강도 조절',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: isBasic ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: isBasic,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildLiveCoatChip('밝은 털', 'light', 0.6),
                _buildLiveCoatChip('보통 털', 'mid', 0.8),
                _buildLiveCoatChip('진한 털', 'dark', 1.0),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: isBasic ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: isBasic,
            child: Slider(
              min: 0.4,
              max: 1.2,
              value: _liveIntensity,
              activeColor: kMainPink,
              onChanged: (v) {
                setState(() {
                  _liveIntensity = v;
                  _liveCoatPreset = 'custom';
                });
                // 🔥🔥🔥 필터 강도 조절 시 즉시 적용
                _applyFilterIfChanged(
                  _shootFilterKey,
                  _liveIntensity.clamp(0.0, 1.0),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveCoatChip(String label, String key, double presetValue) {
    final selected = _liveCoatPreset == key;
    return GestureDetector(
      onTap: () {
        setState(() {
          _liveCoatPreset = key;
          _liveIntensity = presetValue;
        });
        // 🔥🔥🔥 필터 강도 프리셋 선택 시 즉시 적용
        _applyFilterIfChanged(
          _shootFilterKey,
          _liveIntensity.clamp(0.0, 1.0),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                )
              : null,
          color: selected
              ? null
              : Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
          borderRadius: BorderRadius.circular(18), // 상단 후원하기 아이콘과 동일
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
            width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일
          ),
          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.white, // 텍스트 색상 흰색으로 통일
          ),
        ),
      ),
    );
  }

  Future<void> _onCapturePressed() async {
    // 셔터 버튼 중복 탭 방지 가드
    if (_isProcessing) {
      if (kDebugMode) {
        debugPrint('[Petgram] 🚫 _onCapturePressed blocked: _isProcessing=true');
      }
      return;
    }
    
    if (kDebugMode) {
      debugPrint('[Petgram] 📸 _onCapturePressed called: _isProcessing=$_isProcessing, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}');
    }

    // 촬영 버튼 클릭 피드백
    HapticFeedback.lightImpact();

    setState(() {
      _isCaptureAnimating = true;
    });

    // 버튼 애니메이션은 짧게만 재생하고, 실제 촬영/저장은
    // _takePhoto() 내부에서 처리하도록 분리해 UI 버벅임을 줄인다.
    try {
      await Future.delayed(const Duration(milliseconds: 120));
    } finally {
      if (mounted) {
        setState(() {
          _isCaptureAnimating = false;
        });
      }
    }

    // 촬영 로직 (셔터 버튼 1회 탭 → _takePhoto 1회 호출 경로)
    // onTap → _onCapturePressed() → _takePhoto() → 네이티브/레거시 카메라
    // 무거운 저장/후처리는 _takePhoto 내부에서 비동기로 처리하며,
    // 여기서는 await하지 않아 메인 UI 이벤트 루프가 덜 막히도록 한다.
    unawaited(_takePhoto());
  }

  /// 하단: 보정(갤러리) - 촬영 버튼 - 강아지/고양이 사운드 버튼
  Widget _buildBottomBar() {
    // 9:16을 기준으로 전체 UI 크기 통일
    final double buttonSize = 36.0;
    final double captureButtonSize = 64.0;
    final double horizontalPadding = 12.0;
    // 네비게이션 바는 Scaffold.bottomNavigationBar로 분리됨
    // 촬영바를 화면 맨 아래(홈 인디케이터 위)에 붙이기 위해 bottom offset 조정
    // navBarHeight는 Scaffold.bottomNavigationBar가 별도로 관리하므로 여기서는 계산하지 않음
    final media = MediaQuery.of(context);
    final double bottomSafe = media.padding.bottom;
    const double kShootBarMargin = 12.0; // 네비게이션 바 위에 살짝 붙게 하고 싶은 여백
    final double bottomOffset = bottomSafe + kShootBarMargin;

    // 하단 바 위치는 하단 네비게이션 위에 고정
    // 🔥 하단 터치 문제 해결: Stack을 IgnorePointer로 감싸되, 버튼들만 터치를 받도록 함
    return Positioned(
      bottom: bottomOffset,
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: const Offset(0, -12), // 살짝만 더 위로 이동 (-8 -> -12)
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 🔥 하단 터치 문제 해결: 배경 Container 제거, 버튼들만 배치
              // Container를 제거하여 터치가 통과되도록 하고, 버튼들만 터치를 받도록 함
              // 왼쪽 버튼들
              Positioned(
                left: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 필터 페이지로 이동하는 버튼
                    GestureDetector(
                      onTap: () async {
                        if (_isProcessing) return;

                        try {
                          final picked = await _picker.pickImage(
                            source: ImageSource.gallery,
                            imageQuality: 100, // 최대 품질
                          );
                          if (!mounted || picked == null) {
                            return;
                          }

                          // HomePage에서는 heavy work 제거
                          // - EXIF 정규화하지 않음 (FilterPage에서 수행)
                          // - 디코딩하지 않음
                          // - 다운샘플하지 않음
                          // - 썸네일 생성하지 않음
                          // - 필터 초기 적용하지 않음
                          // - EXIF 메타데이터 읽기도 FilterPage에서 수행
                          final originalFile = File(picked.path);

                          // FilterPage로 즉시 이동 (heavy work는 FilterPage에서 수행)
                          // 사진 목록이 닫힌 뒤 멈추지 않고 바로 FilterPage로 전환
                          // await를 제거하여 즉시 push (전환 애니메이션이 끊기지 않도록)
                          _openFilterPage(
                            originalFile,
                            originalMeta: null, // FilterPage에서 EXIF에서 읽음
                          );
                        } catch (e) {
                          if (kDebugMode) {
                            debugPrint(
                              '[HomePage] ⚠️ Failed to pick image: $e',
                            );
                          }
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        width: buttonSize,
                        height: buttonSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(
                            alpha: 0.4,
                          ), // 상단 후원하기 아이콘과 동일
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: 0.3,
                            ), // 상단 후원하기 아이콘과 동일
                            width: 1, // 상단 후원하기 아이콘과 동일
                          ),
                          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
                        ),
                        child: Icon(
                          Icons.photo_library_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 촬영용 필터 선택 버튼
                    Flexible(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque, // 🔥 필터 버튼 터치 문제 해결
                        onTap: () {
                          setState(() {
                            _filterPanelExpanded = !_filterPanelExpanded;
                          });
                        },
                        child: Builder(
                          builder: (context) {
                            final bool isFilterActive =
                                _shootFilterKey != 'basic_none';
                            final bool isExpanded = _filterPanelExpanded;
                            final bool shouldShowPink =
                                isFilterActive || isExpanded;

                            return FittedBox(
                              fit: BoxFit.scaleDown,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  gradient: shouldShowPink
                                      ? LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            kMainPink,
                                            kMainPink.withValues(alpha: 0.8),
                                          ],
                                        )
                                      : null,
                                  color: shouldShowPink
                                      ? null
                                      : Colors.black.withValues(
                                          alpha: 0.4,
                                        ), // 상단 후원하기 아이콘과 동일
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: shouldShowPink
                                        ? Colors.transparent
                                        : Colors.white.withValues(
                                            alpha: 0.3,
                                          ), // 상단 후원하기 아이콘과 동일
                                    width: shouldShowPink
                                        ? 0
                                        : 1, // 상단 후원하기 아이콘과 동일 (1.5 -> 1)
                                  ),
                                  // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      child: Icon(
                                        (allFilters[_shootFilterKey] ??
                                                allFilters['basic_none'])!
                                            .icon,
                                        key: ValueKey(_shootFilterKey),
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        child: Text(
                                          (allFilters[_shootFilterKey] ??
                                                  allFilters['basic_none'])!
                                              .label,
                                          key: ValueKey(_shootFilterKey),
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 중앙 촬영 버튼 (항상 화면 가로 중앙)
              Center(
                child: Semantics(
                  label: '사진 촬영',
                  button: true,
                  child: GestureDetector(
                    onTap: () {
                      // 🔥🔥🔥 연속 촬영 문제 디버깅: onTap이 호출되는지 확인
                      if (kDebugMode) {
                        debugPrint('[Petgram] 🎯 GestureDetector onTap called: _isProcessing=$_isProcessing, _cameraEngine.isCapturingPhoto=${_cameraEngine.isCapturingPhoto}');
                      }
                      _onCapturePressed();
                    },
                    child: AnimatedScale(
                      scale: _isCaptureAnimating ? 0.9 : 1.0,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: Container(
                        width: captureButtonSize,
                        height: captureButtonSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.transparent,
                          border: Border.all(color: kMainPink, width: 3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 오른쪽 사운드 버튼들
              Positioned(
                right: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSoundPill('멍', _playDogSound),
                    const SizedBox(width: 8),
                    _buildSoundPill('냥', _playCatSound),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimerOption(int seconds) {
    return ListTile(
      title: Text('${seconds}초'),
      trailing: _timerSeconds == seconds
          ? const Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        setState(() {
          _timerSeconds = seconds;
        });
        _saveTimerSettings();
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildBurstCountOption(int count) {
    return ListTile(
      title: Text('${count}장'),
      trailing: _burstCountSetting == count && _isBurstMode
          ? const Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        setState(() {
          _burstCountSetting = count;
          _isBurstMode = true;
        });
        _saveBurstSettings();
        Navigator.of(context).pop();
      },
    );
  }

  /// 🔥 줌 프리셋 옵션 위젯 빌드
  /// 각 프리셋 버튼(0.5x, 1x, 2x, 3x)을 생성하고 _setZoomPreset을 호출
  Widget _buildZoomRatioOption(double ratio) {
    // 🔥🔥🔥 전면 카메라: 0.5x는 렌즈 전환이 불가능하므로 비활성화
    final bool isDisabled = _cameraLensDirection == CameraLensDirection.front && ratio < 1.0;
    
    // 프리셋 버튼 선택 시에만 정확히 일치하는지 확인 (0.05 이내)
    final bool isSelected = (_uiZoomScale - ratio).abs() <= 0.05;
    return ListTile(
      title: Text(
        '${ratio.toStringAsFixed(1)}x',
        style: TextStyle(
          color: isDisabled ? Colors.grey : null,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      enabled: !isDisabled,
      onTap: isDisabled
          ? null
          : () {
              if (!mounted) return;
              Navigator.of(context).pop();
              // 🔥 _setZoomPreset 공통 함수 사용
              _setZoomPreset(ratio);
            },
    );
  }

  Widget _buildSoundPill(String label, VoidCallback onTap) {
    final bool isDog = label == '멍';
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
            width: 1, // 상단 후원하기 아이콘과 동일
          ),
          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
        ),
        child: Center(
          child: Image.asset(
            isDog ? 'assets/icons/dog.png' : 'assets/icons/cat.png',
            width: 28,
            height: 28,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }

  /// ========================
  ///  하단 네비게이션 오버레이
  /// ========================

  /// Diary 페이지로 이동
  Future<void> _openDiaryPage(BuildContext context) async {
    // 🔥 다른 페이지로 이동 시 카메라 pause
    _pauseCameraSession();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DiaryPage()),
    );
    // 🔥 페이지에서 돌아올 때 카메라 resume
    if (mounted) {
      _resumeCameraSession();
    }
  }

  /*
  /// 디버그 정보를 문자열로 생성 (최소한의 정보만 포함)
  String _buildDebugInfoString() {
    final sessionState = _cameraEngine.lastDebugState;
    final buffer = StringBuffer();
    buffer.writeln('=== Petgram Camera Info ===');
    buffer.writeln('Timestamp: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Engine State: ${_cameraEngine.state}');
    buffer.writeln('Ready: ${_cameraEngine.isCameraReady}');
    buffer.writeln('Session Running: ${sessionState?.sessionRunning ?? false}');
    buffer.writeln('First Frame: ${sessionState?.hasFirstFrame ?? false}');
    buffer.writeln(
      'Lens: ${_cameraLensDirection == CameraLensDirection.back ? "back" : "front"} (${_nativeDeviceType ?? "?"})',
    );
    buffer.writeln('Aspect: ${_aspectLabel(_aspectMode)}');
    buffer.writeln('Zoom: ${_uiZoomScale.toStringAsFixed(2)}x');
    buffer.writeln('Filter: ${_nativeCurrentFilterKey ?? "none"}');
    buffer.writeln('===========================');
    return buffer.toString();
  }
  */

  /// 디버그 정보를 클립보드에 복사 (제거됨)

  /*
  /// 카메라 디버그 오버레이 위젯
  /// 🔥 성능 최적화: 아주 작은 영역으로 축소, 탭 시 복사
  Widget _buildCameraDebugOverlay() {
    return Positioned(
      top: 60, // 상단 바 아래
      left: 10,
      child: GestureDetector(
        onTap: () async {
          // 탭 시 전체 로그 복사 (파일 + 메모리)
          final String allLogs = await _getDebugStateString();
          await Clipboard.setData(ClipboardData(text: allLogs));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('전체 로그가 클립보드에 복사되었습니다.')),
            );
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4), // 투명도 증가
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'DEBUG',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_previewSourceLabel | ${canUseCamera ? "RDY" : "NOT"}',
                    style: const TextStyle(color: Colors.white, fontSize: 8),
                  ),
                ],
              ),
              if (_debugLogs.isNotEmpty)
                Text(
                  _debugLogs.last.length > 30
                      ? '${_debugLogs.last.substring(0, 30)}...'
                      : _debugLogs.last,
                  style: const TextStyle(color: Colors.white70, fontSize: 7),
                ),
            ],
          ),
        ),
      ),
    );
  }
  */

  /*
  /// 탭 시 전체 로그 복사 (파일 + 메모리)
  Future<String> _getDebugStateString() async {
    String fileLogs = '';
    try {
      if (_debugLogFile == null) {
        final directory = await getApplicationDocumentsDirectory();
        _debugLogFile = File('${directory.path}/$_debugLogFileName');
      }
      if (await _debugLogFile!.exists()) {
        fileLogs = await _debugLogFile!.readAsString();
      }
    } catch (e) {
      fileLogs = 'Error reading log file: $e';
    }

    final debugInfo = _buildDebugInfoString();
    return '--- FILE LOGS ---\n$fileLogs\n\n--- CURRENT STATE ---\n$debugInfo';
  }
  */

  double _getTargetAspectRatio() {
    switch (_aspectMode) {
      case AspectRatioMode.threeFour:
        return 3.0 / 4.0;
      case AspectRatioMode.nineSixteen:
        return 9.0 / 16.0;
      case AspectRatioMode.oneOne:
        return 1.0;
    }
  }

  Widget _buildGridLines(double width, double height) {
    if (!_showGridLines) return const SizedBox.shrink();
    return Positioned.fill(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _GridLinesPainter(color: Colors.white.withValues(alpha: 0.3)),
        ),
      ),
    );
  }

  Widget _buildFocusIndicatorLayer(double width, double height) {
    // 🔥 수정: _showFocusIndicator가 false여도 _focusIndicatorNormalized가 있으면 일단 그림 (페이드아웃 애니메이션을 위해)
    if (_focusIndicatorNormalized == null) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: _focusIndicatorNormalized!.dx * width - 35,
      top: _focusIndicatorNormalized!.dy * height - 35,
      child: AnimatedOpacity(
        opacity: _showFocusIndicator ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        child: TweenAnimationBuilder<double>(
          key: ValueKey(
            'focus_${_focusIndicatorNormalized!.dx}_${_focusIndicatorNormalized!.dy}',
          ),
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutBack, // 확대되며 살짝 튕기는 효과
          builder: (context, value, child) {
            return Transform.scale(
              scale: 0.5 + (value * 0.5), // 0.5 -> 1.0으로 확대
              child: _buildFocusIndicator(70),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFrameUILayer(double width, double height, double topOffset) {
    if (!_frameEnabled) return const SizedBox.shrink();

    return Positioned.fill(
      child: RepaintBoundary(
        child: IgnorePointer(
          ignoring: true, // 프레임 UI 자체는 터치를 방해하지 않음
          child: CustomPaint(
            size: Size(width, height),
            painter: FrameScreenPainter(
              petList: _petList,
              selectedPetId: _selectedPetId,
              dogIconImage: _dogIconImage,
              catIconImage: _catIconImage,
              location: _currentLocation,
              screenWidth: width,
              screenHeight: height,
              frameTopOffset: topOffset, // 전달받은 상대 오프셋 사용
              previewWidth: width,
              previewHeight: height,
              showDebugInfo: kShowFrameDebugInfo, // 🔥 추가
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFocusIndicator(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle, // 🔥 동그란 모양
        border: Border.all(color: kMainPink, width: 2),
        // 🔥 그레이 투명 영역 제거: boxShadow 제거하여 완전히 투명하게
      ),
      // 🔥 심플한 디자인: 아이콘 제거, 테두리만 표시
    );
  }
}

class _GridLinesPainter extends CustomPainter {
  final Color color;
  _GridLinesPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0;

    // 가로선
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    canvas.drawLine(
      Offset(0, 2 * size.height / 3),
      Offset(size.width, 2 * size.height / 3),
      paint,
    );

    // 세로선
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(2 * size.width / 3, 0),
      Offset(2 * size.width / 3, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


