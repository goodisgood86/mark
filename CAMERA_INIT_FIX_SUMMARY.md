# 카메라 초기화 문제 수정 요약

## 🔍 문제 분석 결과

### 핵심 문제
1. **viewId 설정 전 initialize() 호출**: `viewId`가 설정되기 전에 `initialize()`가 호출되어 "ViewId not set" 예외 발생
2. **에러 처리 오류**: 프로그래밍 버그("ViewId not set")를 "카메라 불가능"으로 오인하여 mock으로 영구 fallback
3. **dispose 후 viewId 손실**: `initialize()` 내부에서 dispose 후 viewId가 null이 되어 재초기화 실패

### 로그 분석 결과
- `canUseCamera: true` (디바이스에는 카메라 있음)
- `useMock: true, shouldUseMock: true` (하지만 mock 모드로 고정)
- `initError: Native camera unavailable, using mock: Exception: ViewId not set...`
- **결론**: 하드웨어/권한 문제가 아니라 프로그래밍 버그

## ✅ 수정 사항

### 1. CameraEngine.initialize() 에러 처리 개선

#### 변경 전
- 모든 예외를 catch하여 무조건 mock으로 fallback
- "ViewId not set"도 mock으로 처리

#### 변경 후
- **StateError (ViewId not set)**: mock으로 돌리지 않고 그대로 throw
- **PlatformException**: 에러 코드로 진짜 카메라 불가능 상황만 선별하여 mock fallback
  - `NO_CAMERA_DEVICE`
  - `PERMISSION_DENIED`
  - `INIT_FAILED` (permission/device 관련 메시지)
- **일반 Exception**: 에러 메시지로 판단하여 mock fallback 여부 결정
  - "ViewId not set" 같은 프로그래밍 버그는 throw
  - "permission denied", "no camera device" 같은 실제 문제만 mock fallback

### 2. viewId 보존 로직 추가

#### 변경 전
```dart
if (_nativeCamera != null) {
  await _nativeCamera!.dispose();  // viewId가 null이 됨
  _nativeCamera = null;
}
_nativeCamera = NativeCameraController();  // viewId가 null인 상태
```

#### 변경 후
```dart
// dispose 전에 viewId 보존
int? preservedViewId = currentViewId;
if (isInitialized) {
  await _nativeCamera!.dispose();
  _nativeCamera = NativeCameraController();
  _nativeCamera.setViewId(preservedViewId!);  // viewId 복원
}
```

### 3. viewId 선 조건 체크 강화

- `initialize()` 시작 시 viewId가 null이면 즉시 `StateError` throw
- mock fallback 없이 명확한 에러 메시지 제공

### 4. home_page.dart 에러 처리 개선

- `onCreated` 콜백의 `catchError`에서 `StateError` (ViewId not set) 구분 처리
- 프로그래밍 버그는 명확한 로그만 남기고 mock으로 fallback하지 않음

### 5. _changeAspectMode() 개선

- 재초기화 전에 viewId 확인
- viewId가 없으면 재초기화 시도하지 않음

## 📋 초기화 순서 (올바른 흐름)

1. `_initCameraPipeline()`: `NativeCameraController` 생성
2. `NativeCameraPreview` 빌드 → `onCreated` 콜백 호출
3. `onCreated`에서:
   - `_cameraEngine.setViewId(viewId)` 호출
   - `_cameraEngine.initialize(...)` 호출
4. `CameraEngine.initialize()`:
   - viewId 확인 (없으면 StateError throw)
   - 네이티브 카메라 초기화 시도
   - 성공/실패에 따라 상태 업데이트

## 🎯 기대 효과

1. **프로그래밍 버그 즉시 인지**: "ViewId not set" 같은 버그는 mock으로 숨겨지지 않고 명확히 표시
2. **진짜 카메라 불가능 상황만 mock fallback**: 권한 거부, 디바이스 없음 등만 mock으로 처리
3. **viewId 보존**: 재초기화 시에도 viewId가 유지되어 정상 작동
4. **명확한 에러 메시지**: 문제 원인을 쉽게 파악 가능

## 🧪 테스트 체크리스트

- [ ] 실기기에서 카메라 초기화 정상 작동
- [ ] viewId 설정 전 initialize() 호출 시 명확한 에러 표시
- [ ] 권한 거부 시 mock으로 fallback
- [ ] 비율 변경 시 재초기화 정상 작동
- [ ] 디버그 오버레이에 정확한 상태 표시

