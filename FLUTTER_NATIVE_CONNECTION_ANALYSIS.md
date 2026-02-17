# Flutter ↔ 네이티브 연결 분석 및 문제 해결

## 1. Flutter ↔ 네이티브 연결 점검

### 1.1 MethodChannel 진입점 리스트

#### Flutter → 네이티브 호출 (NativeCameraController)

**MethodChannel**: `petgram/native_camera`

| Flutter 메서드                   | 네이티브 메서드                | 파라미터                                                                            | 용도                 |
| -------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------- | -------------------- |
| `initialize()`                   | `initialize`                   | viewId, cameraPosition, aspectRatio                                                 | 카메라 초기화        |
| `dispose()`                      | `dispose`                      | viewId                                                                              | 카메라 해제          |
| `switchCamera()`                 | `switchCamera`                 | viewId, cameraPosition                                                              | 전면/후면 전환       |
| `setFlashMode()`                 | `setFlashMode`                 | viewId, mode                                                                        | 플래시 모드 설정     |
| `setZoom()`                      | `setZoom`                      | viewId, zoom                                                                        | 줌 레벨 설정         |
| `setFocusPoint()`                | `setFocusPoint`                | viewId, x, y                                                                        | 포커스 포인트 설정   |
| `setExposurePoint()`             | `setExposurePoint`             | viewId, x, y                                                                        | 노출 포인트 설정     |
| `takePicture()`                  | `capture`                      | viewId, filterKey, filterIntensity, brightness, enableFrame, frameMeta, aspectRatio | 사진 촬영            |
| `setExposureBias()`              | `setExposureBias`              | viewId, value                                                                       | 노출 바이어스 설정   |
| `setFilter()`                    | `setFilter`                    | viewId, filterKey, intensity                                                        | 필터 적용            |
| `getFocusStatus()`               | `getFocusStatus`               | viewId                                                                              | 포커스 상태 확인     |
| `getDebugState()`                | `getDebugState`                | viewId                                                                              | 디버그 상태 조회     |
| `switchToWideIfAvailable()`      | `switchToWideIfAvailable`      | viewId                                                                              | Wide 렌즈 전환       |
| `switchToUltraWideIfAvailable()` | `switchToUltraWideIfAvailable` | viewId                                                                              | Ultra Wide 렌즈 전환 |

#### 네이티브 → Flutter 콜백

| 네이티브 콜백         | Flutter 핸들러                             | 파라미터                                                | 용도             |
| --------------------- | ------------------------------------------ | ------------------------------------------------------- | ---------------- |
| `onCameraInitialized` | `_handleMethodCall('onCameraInitialized')` | isInitialized, aspectRatio, previewWidth, previewHeight | 초기화 완료 알림 |
| `onCameraError`       | `_handleMethodCall('onCameraError')`       | errorMessage                                            | 에러 알림        |
| `onDebugLog`          | `_handleMethodCall('onDebugLog')`          | message                                                 | 디버그 로그 전달 |

### 1.2 호출 흐름 다이어그램

```
[HomePage]
    │
    ├─> [CameraEngine]
    │       │
    │       ├─> [NativeCameraController] (MethodChannel: 'petgram/native_camera')
    │       │       │
    │       │       ├─> initialize() ──────────────> [iOS: NativeCameraView.handleMethodCall]
    │       │       │                                       │
    │       │       │                                       └─> [NativeCameraViewController.initialize]
    │       │       │                                               │
    │       │       │                                               ├─> AVCaptureSession 설정
    │       │       │                                               ├─> AVCaptureDeviceInput 추가
    │       │       │                                               ├─> AVCapturePhotoOutput 추가
    │       │       │                                               ├─> AVCaptureVideoDataOutput 추가
    │       │       │                                               └─> onCameraInitialized 콜백 ──┐
    │       │       │                                                                              │
    │       │       └─> <──────────────────────────────────────────────────────────────────────────┘
    │       │           (콜백 수신: _handleMethodCall('onCameraInitialized'))
    │       │
    │       └─> [NativeCameraPreview] (PlatformView)
    │               │
    │               └─> onCreated 콜백 ──> setViewId() ──> initialize() 호출
    │
    └─> [UI 위젯들]
            │
            ├─> setZoom() ──> [NativeCameraController.setZoom] ──> [iOS: setZoom]
            ├─> setFocusPoint() ──> [NativeCameraController.setFocusPoint] ──> [iOS: setFocusPoint]
            ├─> setFilter() ──> [NativeCameraController.setFilter] ──> [iOS: setFilter]
            └─> takePicture() ──> [NativeCameraController.takePicture] ──> [iOS: capture]
```

### 1.3 네이티브 리소스 해제 점검

#### 현재 dispose 흐름

```
[HomePage.dispose()]
    │
    ├─> _cameraEngine.dispose()
    │       │
    │       └─> _nativeCamera?.dispose()
    │               │
    │               └─> [NativeCameraController.dispose()]
    │                       │
    │                       └─> MethodChannel.invokeMethod('dispose', {viewId})
    │                               │
    │                               └─> [iOS: NativeCameraView.handleMethodCall('dispose')]
    │                                       │
    │                                       └─> [NativeCameraViewController.dispose()]
    │                                               │
    │                                               ├─> session.stopRunning()
    │                                               ├─> session.inputs 제거
    │                                               ├─> session.outputs 제거
    │                                               └─> 리소스 정리
```

#### 문제점 및 수정 필요 사항

1. **화면 이동 시 리소스 해제 미완료**

   - `HomePage`가 dispose되지 않고 `push`/`pop`만 되는 경우 리소스가 해제되지 않음
   - 해결: `didChangeDependencies` 또는 라이프사이클 이벤트에서 처리

2. **PlatformView 재생성 시 이전 리소스 미해제**

   - `NativeCameraPreview`가 재생성될 때 이전 `viewId`의 리소스가 남아있을 수 있음
   - 해결: `viewId` 변경 시 이전 리소스 명시적 해제

3. **세션 중지 타이밍 문제**
   - 다른 화면으로 이동 시 세션이 계속 실행 중일 수 있음
   - 해결: `WidgetsBindingObserver`로 앱 상태 변경 감지

## 2. 로딩바 축소 + 무한 로딩 이슈

### 2.1 현재 상태값 관리

**주요 상태 변수:**

- `_cameraEngine.isInitializing` - 카메라 초기화 중 여부
- `_cameraEngine.isCameraReady` - 카메라 준비 완료 여부
- `_cameraEngine.isInitialized` - 네이티브 카메라 초기화 완료 여부
- `_shouldUseMockCamera` - Mock 카메라 사용 여부

### 2.2 문제점 분석

1. **초기화 실패 시 상태 미리셋**

   - `isInitializing`이 `true`로 남아있을 수 있음
   - 해결: try-catch-finally에서 항상 `isInitializing = false` 설정

2. **로딩바 크기 문제**

   - `CircularProgressIndicator`가 작은 Container에 감싸져 있을 수 있음
   - 해결: 최소 크기 제약 추가

3. **중복 초기화 호출**
   - `build` 메서드에서 매번 초기화 로직이 호출될 수 있음
   - 해결: 초기화 플래그로 중복 호출 방지

## 3. 상하단 프레임 + 칩 텍스트 미표시 이슈

### 3.1 프레임 렌더링 위치

**예상 위치:**

- `_buildCameraOverlayLayer()` - 프레임 오버레이 레이어
- `FramePainter` - 프레임 그리기
- `_buildTopBar()` / `_buildBottomBar()` - 상하단 UI

### 3.2 칩 텍스트 데이터 흐름

```
[PetInfo 모델]
    │
    ├─> _selectedPetId
    │       │
    │       └─> _petList에서 선택된 PetInfo 찾기
    │               │
    │               ├─> PetInfo.name (종)
    │               ├─> PetInfo.age (나이)
    │               └─> PetInfo.breed (품종)
    │                       │
    │                       └─> [FramePainter 또는 Text 위젯]
    │                               │
    │                               └─> 화면에 표시
```

### 3.3 문제점 분석

1. **데이터 미전달**

   - `_selectedPetId`가 null이거나 `_petList`에 없는 경우
   - 해결: null 체크 및 기본값 처리

2. **위젯 미빌드**

   - 조건부 렌더링으로 인해 위젯이 빌드되지 않음
   - 해결: 디버그 모드에서 항상 표시

3. **레이어 순서 문제**

   - 프레임은 보이지만 텍스트가 프레임 뒤에 가려짐
   - 해결: Stack의 children 순서 확인

4. **색상/투명도 문제**
   - 텍스트 색상이 배경과 동일하여 보이지 않음
   - 해결: 명확한 색상 대비 확보

## 4. 발열 & 배터리 소모 이슈

### 4.1 현재 연산 부하 분석

**매 프레임마다 실행되는 작업:**

1. `AVCaptureVideoDataOutput` → `captureOutput(_:didOutput:from:)`
2. 필터 적용 (CoreImage/Metal)
3. 프리뷰 렌더링 (Metal)
4. 펫 얼굴 인식 (Vision Framework)

### 4.2 최적화 포인트

1. **프리뷰 해상도 낮추기**

   - 현재: 센서 해상도 그대로 사용
   - 개선: 프리뷰는 720p, 촬영 시에만 고해상도

2. **필터 적용 빈도 줄이기**

   - 현재: 매 프레임마다 필터 적용
   - 개선: 필터 변경 시에만 적용, 프리뷰는 간단한 필터만

3. **얼굴 인식 빈도 줄이기**

   - 현재: 매 프레임마다 인식
   - 개선: 0.3초마다 인식

4. **불필요한 setState 호출 제거**
   - 현재: 프레임마다 상태 업데이트 가능
   - 개선: 상태 변경 시에만 업데이트
