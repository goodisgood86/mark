# Petgram 카메라 구조 재설계 구현 요약

## ✅ 완료된 작업

### 1. 설계 및 분석

- ✅ 현재 구조 분석 (`CAMERA_REFACTORING_PLAN.md`)
- ✅ Flutter에서 중복 계산하는 상태 파악
- ✅ 타겟 아키텍처 설계

### 2. iOS 네이티브 모듈

#### ✅ `ios/Runner/Camera/PetgramCameraEngine.swift` (771 lines)

- **단일 상태머신**: `CameraState` enum (idle, initializing, ready, running, takingPhoto, error)
- **AVCaptureSession 관리**: 초기화, 해제, 프리뷰 시작/중지
- **카메라 제어**: 비율/필터/줌/플래시 설정
- **촬영 로직**: `AVCapturePhotoCaptureDelegate` 구현, 필터 적용, 파일 저장
- **FilterEngine 통합**: 프리뷰 및 촬영 필터 파이프라인

#### ✅ `ios/Runner/Camera/PetgramCameraPlugin.swift` (372 lines)

- **MethodChannel**: `petgram_camera`
  - `initialize`, `dispose`, `startPreview`, `stopPreview`
  - `setAspect`, `setFilter`, `setZoom`, `setFlash`
  - `takePhoto`, `switchCamera`
- **EventChannel**: `petgram_camera/state` (상태 변경 이벤트)
- **EventChannel**: `petgram_camera/preview` (프리뷰 정보)
- **AppDelegate 등록**: 플러그인 자동 등록

### 3. Flutter 셸

#### ✅ `lib/widgets/camera/petgram_camera_shell.dart` (410 lines)

- **MethodChannel 통신**: 네이티브 카메라 제어
- **EventChannel 구독**: 상태 및 프리뷰 이벤트 수신
- **상태 관리**: 네이티브가 Single Source of Truth
- **UI 구성**: 프리뷰, 에러 오버레이, 로딩 오버레이
- **공개 API**: `takePhoto()`, `setAspect()`, `setFilter()`, `setZoom()`, `setFlash()`, `switchCamera()`

### 4. 문서화

#### ✅ `HOME_PAGE_MIGRATION_GUIDE.md`

- 기존 구조 → 새 구조 비교
- 단계별 마이그레이션 방법
- 코드 예제
- 완료 체크리스트

## 🔧 구현 세부사항

### 네이티브 엔진 구조

```swift
PetgramCameraEngine
├── 상태머신: CameraState (단일 소스)
├── AVCaptureSession 관리
├── FilterEngine 통합
├── 프리뷰 렌더링 (CameraPreviewView)
└── 촬영 및 저장 (EXIF 포함)
```

### Flutter 셸 구조

```dart
PetgramCameraShell
├── MethodChannel 통신
├── EventChannel 구독 (state, preview)
├── 상태 수신 (네이티브 → Flutter)
└── 제어 전송 (Flutter → 네이티브)
```

## ⚠️ 남은 작업 (TODO)

### 1. PreviewView 통합

- **현재**: 기존 `CameraManager`를 통해 `NativeCameraViewController.previewView` 사용
- **필요**: 새 엔진에서 PreviewView 생성 또는 재사용 로직 완성
- **위치**: `PetgramCameraPlugin.handleStartPreview()`

### 2. Texture ID 생성 (선택적)

- **현재**: Texture 방식 미구현
- **대안**: iOS에서는 기존 `CameraPreviewView`를 RootViewController에 직접 배치하는 방식 유지 가능
- **필요 시**: Texture 방식으로 전환 가능

### 3. FilterConfig 파싱

- **현재**: 기본값만 사용
- **필요**: Flutter에서 전달된 FilterConfig Map을 Swift FilterConfig로 변환
- **위치**: `PetgramCameraPlugin.handleSetFilter()`

### 4. EXIF 메타데이터

- **현재**: 기본 촬영 로직 구현 완료
- **필요**: EXIF UserComment 추가 (기존 `buildExifTag()` 참고)
- **위치**: `PetgramCameraEngine._performPhotoCapture()` → JPEG 저장 단계

### 5. 프레임 오버레이

- **현재**: 프레임 메타데이터 전달 구조만 있음
- **필요**: `addFrameOverlay()` 로직 통합 (기존 NativeCamera.swift 참고)

## 📝 사용 방법

### Flutter에서 사용

```dart
// 1. 셸 위젯 추가
PetgramCameraShell(
  key: _cameraShellKey,
  initialAspect: AspectRatioMode.nineSixteen,
  initialFilter: _buildCurrentFilterConfig(),
  onPhotoTaken: (photoPath) {
    // 촬영 완료 처리
  },
  onError: (error) {
    // 에러 처리
  },
)

// 2. 제어
final shell = _cameraShellKey.currentState;
await shell?.takePhoto();
shell?.setAspect(AspectRatioMode.threeFour);
shell?.setFilter(filterConfig);
shell?.setZoom(2.0);
shell?.setFlash('on');
```

### 네이티브에서 상태 확인

```swift
// 상태머신
engine.state // .idle, .ready, .running, .takingPhoto, .error

// 상태 변경 콜백
engine.onStateChanged = { state, canTakePhoto in
    // 상태 변경 시 호출
}
```

## 🎯 다음 단계

1. **HomePage 통합** (`HOME_PAGE_MIGRATION_GUIDE.md` 참고)

   - `PetgramCameraShell` 위젯 추가
   - 기존 카메라 로직 제거
   - 상태 계산 로직 제거

2. **테스트 및 검증**

   - 프리뷰 정상 표시 확인
   - 촬영 기능 테스트
   - 상태 동기화 확인

3. **기존 코드 정리** (선택적)
   - `camera_engine.dart` deprecated 표시
   - 불필요한 상태 계산 로직 제거

## 📊 파일 구조

```
ios/Runner/Camera/
├── PetgramCameraEngine.swift      (771 lines) - 핵심 엔진
└── PetgramCameraPlugin.swift      (372 lines) - Flutter 플러그인

lib/widgets/camera/
└── petgram_camera_shell.dart      (410 lines) - Flutter 셸

문서/
├── CAMERA_REFACTORING_PLAN.md     - 설계 계획
├── HOME_PAGE_MIGRATION_GUIDE.md   - 마이그레이션 가이드
└── IMPLEMENTATION_SUMMARY.md      - 구현 요약 (본 문서)
```

## ✨ 핵심 개선사항

1. **단일 상태머신**: 모든 카메라 상태를 네이티브에서 관리
2. **상태 계산 제거**: Flutter에서 `canUseCamera` 등 계산 제거
3. **명확한 책임 분리**: 네이티브 = 로직, Flutter = UI
4. **안정성 향상**: 상태 불일치 문제 해결
