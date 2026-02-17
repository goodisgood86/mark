import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import '../models/constants.dart';
import '../pages/home_page.dart';

/// 권한 게이트
/// 1) 카메라 시스템 팝업 → 사용자 답변 후 → 갤러리 시스템 팝업
/// 2) 카메라·갤러리 중 하나라도 Off → "설정으로 이동" 버튼만 표시
/// 3) 둘 다 On → 카메라 앱(HomePage) 진입
class PermissionWrapper extends StatefulWidget {
  final List<CameraDescription> cameras;

  const PermissionWrapper({super.key, required this.cameras});

  @override
  State<PermissionWrapper> createState() => _PermissionWrapperState();
}

class _PermissionWrapperState extends State<PermissionWrapper>
    with WidgetsBindingObserver {
  bool _permissionsGranted = false;
  bool _isChecking = true;
  bool _isRequesting = false;
  bool _canRequest = true;
  bool _returnedFromSettings = false;
  bool _didNavigateHome = false;

  static const int _resumeRecheckMaxAttempts = 10;
  static const Duration _resumeRecheckInterval = Duration(milliseconds: 350);
  static const Duration _bootstrapWatchdogDelay = Duration(seconds: 4);

  Timer? _bootstrapWatchdog;

  static const _channel = MethodChannel('petgram/native_camera');
  static const _permChannel = MethodChannel('petgram/permissions');

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      debugPrint('[PermissionWrapper] initState');
    }
    try {
      FlutterNativeSplash.remove();
    } catch (_) {}

    WidgetsBinding.instance.addObserver(this);
    _startBootstrapWatchdog();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (kDebugMode) {
        debugPrint('[PermissionWrapper] postFrameCallback start');
      }
      if (!Platform.isIOS) {
        if (mounted) {
          setState(() {
            _permissionsGranted = true;
            _isChecking = false;
          });
        }
        return;
      }
      if (mounted) {
        _runPermissionFlow();
      }
    });
  }

  void _startBootstrapWatchdog() {
    _bootstrapWatchdog?.cancel();
    _bootstrapWatchdog = Timer(_bootstrapWatchdogDelay, () async {
      if (!mounted || _permissionsGranted) return;

      if (kDebugMode) {
        debugPrint(
          '[PermissionWrapper] ⏱️ bootstrap watchdog fired: checking=$_isChecking requesting=$_isRequesting',
        );
      }

      int c = 0;
      int g = 0;
      try {
        c =
            await _channel
                .invokeMethod<int>('checkCameraPermission')
                .timeout(
                  const Duration(milliseconds: 900),
                  onTimeout: () => 0,
                ) ??
            0;
      } catch (_) {}
      try {
        g =
            await _channel
                .invokeMethod<int>('checkPhotoLibraryPermission')
                .timeout(
                  const Duration(milliseconds: 900),
                  onTimeout: () => 0,
                ) ??
            0;
      } catch (_) {}

      if (!mounted || _permissionsGranted) return;

      if (c == 3 && g == 3) {
        if (kDebugMode) {
          debugPrint('[PermissionWrapper] ✅ watchdog fast-path: granted');
        }
        setState(() {
          _permissionsGranted = true;
          _isChecking = false;
          _isRequesting = false;
        });
        _navigateToHomeIfNeeded();
        return;
      }

      if (_isChecking || _isRequesting) {
        if (kDebugMode) {
          debugPrint(
            '[PermissionWrapper] ⚠️ watchdog fallback: leave loading (camera=$c, gallery=$g)',
          );
        }
        setState(() {
          _isChecking = false;
          _isRequesting = false;
          _canRequest = true;
        });
      }
    });
  }

  Future<void> _runPermissionFlow() async {
    if (kDebugMode) {
      debugPrint('[PermissionWrapper] _runPermissionFlow start');
    }
    if (!mounted || !Platform.isIOS) return;

    try {
      final c = await _channel
          .invokeMethod<int>('checkCameraPermission')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      final g = await _channel
          .invokeMethod<int>('checkPhotoLibraryPermission')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);

      if (mounted && c == 3 && g == 3) {
        if (kDebugMode) {
          debugPrint(
            '[PermissionWrapper] permissions granted by check: c=$c, g=$g',
          );
        }
        setState(() {
          _permissionsGranted = true;
          _isChecking = false;
          _isRequesting = false;
        });
        _navigateToHomeIfNeeded();
        return;
      }
    } catch (_) {
      // check 실패 시 ensure 경로로 진행
    }

    if (!mounted) return;
    setState(() {
      _isRequesting = true;
      _isChecking = false;
    });

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    _requestPermissionsOnce();
  }

  Future<bool> _checkBothGranted() async {
    try {
      final c = await _channel
          .invokeMethod<int>('checkCameraPermission')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      final g = await _channel
          .invokeMethod<int>('checkPhotoLibraryPermission')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      return c == 3 && g == 3;
    } catch (_) {
      return false;
    }
  }

  Future<void> _recheckPermissionsAfterSettings() async {
    if (!mounted || !Platform.isIOS) return;
    setState(() {
      _isChecking = true;
    });

    for (int i = 0; i < _resumeRecheckMaxAttempts; i++) {
      final granted = await _checkBothGranted();
      if (!mounted) return;
      if (granted) {
        setState(() {
          _permissionsGranted = true;
          _isChecking = false;
          _isRequesting = false;
        });
        _navigateToHomeIfNeeded();
        return;
      }
      if (i < _resumeRecheckMaxAttempts - 1) {
        await Future.delayed(_resumeRecheckInterval);
      }
    }

    if (mounted) {
      setState(() {
        _isChecking = false;
      });
    }
  }

  Future<void> _requestPermissionsOnce() async {
    if (kDebugMode) {
      debugPrint('[PermissionWrapper] _requestPermissionsOnce start');
    }
    if (!mounted || !Platform.isIOS) return;

    try {
      final alreadyC = await _channel
          .invokeMethod<int>('checkCameraPermission')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      final alreadyG = await _channel
          .invokeMethod<int>('checkPhotoLibraryPermission')
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);

      if (mounted && alreadyC == 3 && alreadyG == 3) {
        setState(() {
          _permissionsGranted = true;
          _isRequesting = false;
          _isChecking = false;
        });
        _navigateToHomeIfNeeded();
        return;
      }
    } catch (_) {
      // check 실패 시 ensure 진행
    }

    if (!mounted) return;

    setState(() => _isRequesting = true);
    int? c;
    try {
      c = await _channel
          .invokeMethod<int>('ensureCameraPermission')
          .timeout(const Duration(seconds: 10), onTimeout: () => 2);
      if (!mounted) return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRequesting = false;
          _canRequest = true;
        });
      }
      c = null;
    }

    if (mounted) {
      await _requestPhotoAfterCamera(c);
    }
  }

  Future<void> _requestPhotoAfterCamera(int? c) async {
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    try {
      if (kDebugMode) {
        debugPrint(
          '[PermissionWrapper] 📸 calling ensurePhotoLibraryPermission',
        );
      }
      final g = await _channel
          .invokeMethod<int>('ensurePhotoLibraryPermission')
          .timeout(const Duration(seconds: 10), onTimeout: () => 2);

      if (!mounted) return;
      if ((c ?? 2) == 3 && (g ?? 2) == 3) {
        setState(() {
          _permissionsGranted = true;
          _isRequesting = false;
          _isChecking = false;
        });
        _navigateToHomeIfNeeded();
        return;
      }

      setState(() {
        _isRequesting = false;
        _canRequest = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRequesting = false;
          _canRequest = true;
        });
      }
    }
  }

  void _navigateToHomeIfNeeded() {
    if (!mounted || _didNavigateHome) return;
    _didNavigateHome = true;
    // 권한 허용 후 화면 전환은 build()의 `_permissionsGranted` 분기에서 처리한다.
    // 여기서 pushReplacement를 추가로 호출하면 HomePage가 중복 생성되어
    // 첫 인스턴스 dispose 시 네이티브 카메라가 끊기는 문제가 생긴다.
    if (kDebugMode) {
      debugPrint('[PermissionWrapper] ✅ Home navigation delegated to build()');
    }
  }

  @override
  void dispose() {
    _bootstrapWatchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_returnedFromSettings) return;
    _returnedFromSettings = false;
    try {
      _channel.invokeMethod('setSkipAutoReinit', {'skip': false});
    } catch (_) {}
    _recheckPermissionsAfterSettings();
  }

  Future<void> _onPrimaryButtonTap() async {
    if (!mounted || _isRequesting || !Platform.isIOS) return;
    if (!_canRequest) {
      _openSettings();
      return;
    }

    setState(() => _isRequesting = true);
    int? c;
    try {
      c = await _channel
          .invokeMethod<int>('ensureCameraPermission')
          .timeout(const Duration(seconds: 10), onTimeout: () => 2);
      if (!mounted) return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRequesting = false;
          _canRequest = true;
        });
      }
      c = null;
    }

    if (mounted) {
      await _requestPhotoAfterCamera(c);
    }
  }

  Future<void> _openSettings() async {
    _returnedFromSettings = true;
    try {
      await _channel.invokeMethod('setSkipAutoReinit', {'skip': true});
    } catch (_) {}
    try {
      await _permChannel.invokeMethod('openSettings');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) {
      debugPrint(
        '[PermissionWrapper] build: granted=$_permissionsGranted, checking=$_isChecking, requesting=$_isRequesting, canRequest=$_canRequest',
      );
    }

    if (_permissionsGranted) {
      return HomePage(cameras: widget.cameras);
    }

    if (_isChecking || _isRequesting) {
      return Scaffold(
        backgroundColor: const Color(0xFFFFF5F8),
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(color: kMainPink),
                const SizedBox(height: 24),
                Text(
                  _isRequesting ? '권한 요청 중...' : '권한 확인 중...',
                  style: const TextStyle(fontSize: 16, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.camera_alt_outlined, size: 64, color: kMainPink),
              const SizedBox(height: 24),
              const Text(
                '카메라와 갤러리 권한이 필요합니다',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                '사진 촬영과 저장을 위해\n권한을 허용해주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _onPrimaryButtonTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kMainPink,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _canRequest ? '권한 허용' : '설정으로 이동',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
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
}
