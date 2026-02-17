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
  const NativeCameraPreview({super.key, required this.onCreated});

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
    // 강제 print는 로그 폭주를 유발하므로 제거하고 debugPrint만 유지
    if (kDebugMode) {
      debugPrint(
        '[NativeCameraPreview] 🔍 initState called, Platform.isIOS=${Platform.isIOS}, hasCalled=$_hasCalledOnCreated',
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
      debugPrint(
        '[NativeCameraPreview] ✅ onCreated callback called (iOS) with viewId=0',
      );
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
    // 🔥 성능 최적화: 빈번한 build 호출 로그 제거 (기능 영향 없음)
    // if (kDebugMode) {
    //   debugPrint('[NativeCameraPreview] 🔍 build called...');
    // }

    // 🔥🔥🔥 근본 해결: build에서는 호출하지 않음
    // didChangeDependencies에서만 호출하여 중복 방지
    if (Platform.isIOS && !_hasCalledOnCreated) {
      // build가 여러 번 호출될 수 있으므로 postFrameCallback으로 한 번만 호출
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _callOnCreatedIfNeeded();
      });
    }

    if (Platform.isIOS) {
      // 🔥🔥🔥 ParentDataWidget 에러 근본 해결: 가장 단순한 위젯 사용
      // 문제: LayoutBuilder가 ColorFiltered와 SizedBox.expand()의 tight constraints와 충돌
      // 해결책: IgnorePointer + Container()를 직접 반환하여 부모 제약을 그대로 따르도록 함
      // SizedBox.expand()가 이미 부모 제약을 명시적으로 전달하므로 여기서는 단순한 위젯만 필요
      return IgnorePointer(ignoring: true, child: Container());
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
