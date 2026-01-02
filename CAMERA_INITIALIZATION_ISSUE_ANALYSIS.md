# 카메라 초기화 문제 분석 및 해결 방안

## 문제 현상
1. 실기기에서 카메라 프리뷰가 검은 화면으로 표시됨
2. 촬영 시 "카메라 연결이 불안정합니다" 스낵바 표시
3. `canUseCamera`가 false로 유지됨

## 원인 분석

### 1. 카메라 초기화 플로우 문제

**현재 플로우:**
1. `NativeCameraPreview.onCreated()` → `attachNativeView(viewId)` 호출
2. `attachNativeView()`는 `NativeCameraController` 생성 및 `_startCameraStateListener()` 호출
3. 네이티브는 `viewDidAppear`에서 자동으로 초기화 시작
4. **문제**: Flutter에서 명시적으로 초기화를 요청하지 않음

**해결 방안:**
- ✅ `onCreated`에서 `requestInitializeIfNeeded()` 호출 추가 (수정 완료)

### 2. canUseCamera 조건

**현재 조건:**
```dart
bool get canUseCamera {
  final state = _cameraEngine.lastDebugState;
  if (state == null) return false;
  
  return state.sessionRunning && 
         state.videoConnected && 
         state.hasFirstFrame;
}
```

**문제점:**
- `lastDebugState`가 null이거나 업데이트되지 않을 수 있음
- EventChannel 리스너가 제대로 작동하지 않을 수 있음

### 3. 네이티브 카메라 초기화

**네이티브 자동 초기화:**
- `viewDidAppear`에서 `cameraState == .idle`일 때 자동 초기화 시작
- 기본값: 백 카메라, 3:4 비율

**문제점:**
- Flutter 설정(카메라 위치, 비율)이 반영되지 않을 수 있음
- 초기화 실패 시 재시도 로직이 복잡함

### 4. hasFirstFrame 업데이트

**네이티브에서:**
- `captureOutput`에서 첫 프레임 수신 시 `hasFirstFrame = true` 설정
- `notifyStateChange()` 호출하여 Flutter에 알림

**문제점:**
- `captureOutput`이 호출되지 않으면 `hasFirstFrame`이 false로 유지됨
- 세션이 시작되지 않으면 프레임이 오지 않음

## 해결 방안

### 1. ✅ Flutter에서 명시적 초기화 요청 (수정 완료)

```dart
onCreated: (int viewId) async {
  _cameraEngine.attachNativeView(viewId);
  // 네이티브에 초기화 요청
  await _cameraEngine.requestInitializeIfNeeded(
    viewId: viewId,
    cameraPosition: 'back',
    aspectRatio: _getTargetAspectRatio(),
  );
  // 초기화 완료 확인 (최대 3초 대기)
  // sessionRunning && videoConnected && hasFirstFrame 확인
}
```

### 2. ✅ 초기화 전 상태 폴링 활성화 (수정 완료)

- `_pollDebugState()`에서 `isInitialized` 체크 제거
- 초기화 전에도 상태 모니터링 가능

### 2. ⚠️ 확인 필요: EventChannel 리스너 작동 여부

**확인 사항:**
- `_startCameraStateListener()`가 제대로 호출되는지
- EventChannel이 제대로 등록되는지
- 네이티브에서 `CameraStateStreamHandler.shared.sendStateChange()`가 호출되는지

### 3. ⚠️ 확인 필요: 카메라 세션 시작 여부

**확인 사항:**
- 네이티브에서 `session.startRunning()`이 호출되는지
- `captureOutput`이 호출되는지
- `hasFirstFrame`이 true가 되는지

### 4. ⚠️ 확인 필요: 프리뷰 동기화

**확인 사항:**
- `updatePreviewLayout()`이 호출되는지
- 프리뷰 rect가 올바르게 설정되는지
- 네이티브 프리뷰가 올바른 위치에 표시되는지

## 디버깅 방법

### 1. 로그 확인
- `[NativePreview] ✅ Camera initialization requested` - 초기화 요청 확인
- `[Native] 🔥 viewDidAppear: cameraState=idle, starting auto-initialization` - 네이티브 자동 초기화 확인
- `[Native] ✅✅✅ captureOutput CALLED!` - 프레임 수신 확인
- `[Native] ✅ hasFirstFrame set to true` - hasFirstFrame 설정 확인
- `[CameraDebug] canUseCamera=true/false` - canUseCamera 상태 확인

### 2. 상태 확인
- `sessionRunning`: 세션이 실행 중인지
- `videoConnected`: 비디오 연결이 활성화되었는지
- `hasFirstFrame`: 첫 프레임을 받았는지
- `nativeInit`: 네이티브 초기화 완료 여부

## 수정 완료 사항

1. ✅ Flutter에서 명시적 초기화 요청 추가
   - `onCreated`에서 `requestInitializeIfNeeded()` 호출
   - 초기화 완료 확인 로직 추가 (최대 3초 대기)

2. ✅ 초기화 전 상태 폴링 활성화
   - `_pollDebugState()`에서 `isInitialized` 체크 제거
   - 초기화 전에도 상태 모니터링 가능

## 다음 단계 (실기기 테스트 필요)

1. ⚠️ 초기화 요청 확인
   - `[NativePreview] ✅ Camera initialization requested` 로그 확인
   - 네이티브에서 초기화가 시작되는지 확인

2. ⚠️ 세션 시작 확인
   - `[Native] 🔥 viewDidAppear: cameraState=idle, starting auto-initialization` 로그 확인
   - `session.startRunning()` 호출 확인

3. ⚠️ 프레임 수신 확인
   - `[Native] ✅✅✅ captureOutput CALLED!` 로그 확인
   - `[Native] ✅ hasFirstFrame set to true` 로그 확인

4. ⚠️ canUseCamera 상태 확인
   - `[CameraDebug] canUseCamera=true` 로그 확인
   - `sessionRunning && videoConnected && hasFirstFrame` 모두 true인지 확인

## 문제가 지속되는 경우 확인 사항

1. **EventChannel 리스너**
   - `_startCameraStateListener()`가 호출되는지
   - EventChannel이 제대로 등록되는지
   - 네이티브에서 `CameraStateStreamHandler.shared.sendStateChange()` 호출되는지

2. **네이티브 초기화 로직**
   - `viewDidAppear`에서 자동 초기화가 시작되는지
   - `initializeIfNeeded()`가 호출되는지
   - 초기화가 실패하는지 (에러 로그 확인)

3. **프리뷰 동기화**
   - `updatePreviewLayout()`이 호출되는지
   - 프리뷰 rect가 올바르게 설정되는지
   - 네이티브 프리뷰가 올바른 위치에 표시되는지

4. **카메라 권한**
   - 카메라 권한이 허용되었는지
   - Info.plist에 권한 설명이 있는지

