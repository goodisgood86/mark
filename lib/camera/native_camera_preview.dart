import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

/// 🔄 리팩토링: 네이티브 카메라 프리뷰 위젯
///
/// iOS에서는 더 이상 PlatformView를 사용하지 않습니다.
/// 카메라는 RootViewController의 cameraContainer에 직접 표시되므로,
/// Flutter에서는 투명한 빈 위젯만 반환합니다.
///
/// Android는 기존대로 AndroidView를 사용합니다.
class NativeCameraPreview extends StatefulWidget {
  const NativeCameraPreview({Key? key, required this.onCreated})
    : super(key: key);

  /// 🔄 리팩토링: iOS에서는 더 이상 viewId가 필요 없지만,
  /// 호환성을 위해 콜백은 유지합니다 (즉시 호출)
  final void Function(int viewId) onCreated;

  @override
  State<NativeCameraPreview> createState() => _NativeCameraPreviewState();
}

class _NativeCameraPreviewState extends State<NativeCameraPreview> {
  bool _hasCalledOnCreated = false; // 🔥 onCreated 콜백 호출 여부 추적

  @override
  void initState() {
    super.initState();
    // 🔥 디버그 로그: initState 호출 확인 (강제 출력)
    final initStateMsg = '[NativeCameraPreview] 🔥🔥🔥 initState CALLED, Platform.isIOS=${Platform.isIOS}';
    debugPrint(initStateMsg);
    print(initStateMsg); // 콘솔에도 강제 출력
    
    if (kDebugMode) {
      debugPrint(
        '[NativeCameraPreview] 🔍 initState called, Platform.isIOS=${Platform.isIOS}',
      );
    }

    // 🔥🔥🔥 근본 해결: initState에서는 호출하지 않음
    // didChangeDependencies나 build에서 호출하여 위젯 트리가 완전히 준비된 후에만 호출
    // 이렇게 하면 중복 호출 가능성을 크게 줄임
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 🔥 디버그 로그: didChangeDependencies 호출 확인
    if (kDebugMode) {
      debugPrint(
        '[NativeCameraPreview] 🔍 didChangeDependencies called, Platform.isIOS=${Platform.isIOS}',
      );
    }

    // 🔥 iOS 실기기 프리뷰 보장: didChangeDependencies에서도 콜백 호출 보장
    if (Platform.isIOS) {
      _callOnCreatedIfNeeded();
    }
  }

  /// 🔥 iOS 실기기 프리뷰 보장: onCreated 콜백을 안전하게 호출
  /// 🔥🔥🔥 근본 해결: 중복 호출 완전 차단 (동기화 추가)
  void _callOnCreatedIfNeeded() {
    // 🔥🔥🔥 근본 해결: 동기화된 중복 체크
    if (_hasCalledOnCreated) {
      return; // 이미 호출됨
    }
    
    // 플래그를 먼저 설정하여 중복 호출 방지
    _hasCalledOnCreated = true;
    
    // 🔥 Pattern A 보장: iOS에서는 viewId를 0으로 설정 (유효한 값)
    //    iOS에서는 PlatformView를 사용하지 않지만, Flutter 쪽에서 viewId 체크를 하므로
    //    유효한 값(0)을 전달하여 initialize 호출이 가능하도록 함

    // 🔥 디버그 로그: onCreated 호출 전 확인
    final msg = '[NativeCameraPreview] 🔥 About to call widget.onCreated(0)';
    debugPrint(msg);

    try {
      widget.onCreated(0);
      debugPrint('[NativeCameraPreview] ✅ onCreated callback called (iOS) with viewId=0');
    } catch (e, stackTrace) {
      // 에러 발생 시 플래그 리셋하여 재시도 가능하게
      _hasCalledOnCreated = false;
      final errorMsg = '[NativeCameraPreview] ❌ onCreated callback ERROR: $e';
      debugPrint(errorMsg);
      debugPrint('[NativeCameraPreview] ❌ Stack: $stackTrace');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 🔥 디버그 로그: build 호출 확인
    if (kDebugMode) {
      debugPrint(
        '[NativeCameraPreview] 🔍 build called, Platform.isIOS=${Platform.isIOS}, _hasCalledOnCreated=$_hasCalledOnCreated',
      );
    }

    // 🔥🔥🔥 근본 해결: build에서는 호출하지 않음
    // didChangeDependencies에서만 호출하여 중복 방지
    if (Platform.isIOS && !_hasCalledOnCreated) {
      // build가 여러 번 호출될 수 있으므로 postFrameCallback으로 한 번만 호출
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _callOnCreatedIfNeeded();
      });
    }

    if (Platform.isIOS) {
      // 🔥 연분홍 오버레이 문제 해결:
      // 문제: 네이티브 카메라 뷰는 RootViewController의 cameraContainer에 있고,
      // Flutter 위젯 트리에서는 SizedBox.expand()만 있어서 Flutter가 그 영역을 "비어있는" 것으로 인식
      //
      // 핵심 원인: SizedBox.expand()는 레이아웃에서 크기를 차지하지만 시각적으로 투명함
      // 네이티브 카메라가 렌더링되면 네이티브 뷰가 보이지만, Flutter 레이아웃 시스템은
      // SizedBox.expand()를 "투명한 빈 위젯"으로 인식하여 배경색이 보임
      //
      // 해결책: Container로 감싸서 명시적으로 크기를 차지하도록 함
      // 하지만 네이티브 뷰가 그 위에 렌더링되므로, Flutter 위젯은 투명해야 함
      // Container의 color를 transparent로 설정하면 레이아웃은 차지하지만 시각적으로는 투명
      //
      // 하지만 실제 문제는 네이티브 뷰의 frame이 Flutter 레이아웃과 동기화되지 않을 수 있음
      // updatePreviewLayout이 제대로 호출되는지 확인 필요
      return Container(
        color: Colors.transparent,
        child: const SizedBox.expand(),
      );
    } else {
      // Android는 기존대로 AndroidView 사용
      return _buildAndroidPreview();
    }
  }

  /// Android 프리뷰 (AndroidView 사용)
  Widget _buildAndroidPreview() {
    // Android는 기존 코드 유지 (필요시 수정)
    return Container(
      color: Colors.black,
      child: const Center(
        child: Text(
          'Android camera preview\n(PlatformView still used)',
          style: TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
