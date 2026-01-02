# 🔄 리팩토링 다음 단계 가이드

## ✅ 완료된 작업

1. **RootViewController.swift** 생성
   - 카메라 컨테이너 뷰 구조
   - FlutterViewController 래핑

2. **CameraManager.swift** 생성
   - 전역 카메라 관리자

3. **AppDelegate.swift** 수정
   - RootViewController 설정

4. **NativeCameraViewController.loadView()** 단순화
   - PlatformView 구조 제거

## ⏳ 남은 작업 (매우 큰 작업)

### 5. MethodChannel 핸들러 변경
현재 `NativeCamera.handle()`는 viewId 기반으로 `NativeCameraView`를 찾고 있습니다.
이를 `CameraManager`를 통해 전역 카메라 인스턴스에 접근하도록 변경해야 합니다.

**변경 사항:**
- `cameraViews: [Int64: NativeCameraView]` 제거
- `CameraManager.shared.getCameraViewController()` 사용
- viewId 파라미터 제거 또는 무시

### 6. PlatformView 등록 제거
- `NativeCamera`에서 `FlutterPlatformViewFactory` 구현 제거
- `registrar.register(instance, withId: "petgram/native_camera_view")` 제거
- `create(withFrame:viewIdentifier:arguments:)` 메서드 제거

### 7. NativeCameraView 클래스 제거
- `NativeCameraView` 클래스 전체 제거 (약 700줄)
- 관련 `handleMethodCall` 로직을 `NativeCamera.handle()`로 이동

### 8. Flutter UI 변경
- `NativeCameraPreview` 위젯 제거
- `home_page.dart`에서 UiKitView 사용 중지
- 투명 배경으로 변경

## ⚠️ 주의사항

이 작업은 매우 큽니다. 각 단계마다:
- 빌드 가능한 상태 유지
- 기존 기능 손실 없음 확인
- 충분한 테스트 필요

## 🎯 권장 접근 방법

1. 먼저 MethodChannel 핸들러를 변경 (viewId → CameraManager)
2. PlatformView 등록 제거
3. NativeCameraView 클래스 제거
4. Flutter UI 변경

각 단계마다 빌드하고 테스트하는 것이 안전합니다.

