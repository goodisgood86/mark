# HomePage 마이그레이션 가이드

## 🔄 기존 구조 → 새 구조

### 기존 방식 (제거 대상)

```dart
// ❌ 제거: CameraEngine 사용
late final CameraEngine _cameraEngine;

// ❌ 제거: canUseCamera 계산
bool get canUseCamera {
  final state = _cameraEngine.getState();
  return state.sessionRunning &&
         state.videoConnected &&
         state.hasFirstFrame;
}

// ❌ 제거: 상태 폴링
void _pollDebugState() {
  _cameraEngine.getDebugState().then((state) {
    // 상태 업데이트...
  });
}

// ❌ 제거: NativeCameraPreview + 복잡한 초기화
NativeCameraPreview(
  onCreated: (viewId) {
    _cameraEngine.attachNativeView(viewId);
    _cameraEngine.initializeNativeCameraOnce();
  },
)

// ❌ 제거: 복잡한 촬영 로직
Future<void> _takePhoto() async {
  if (!canUseCamera) {
    // 차단...
  }
  // 복잡한 촬영 로직...
}
```

### 새 방식 (적용 대상)

```dart
// ✅ 추가: PetgramCameraShell 사용
import '../widgets/camera/petgram_camera_shell.dart';

// ✅ 추가: GlobalKey로 셸 제어
final GlobalKey<_PetgramCameraShellState> _cameraShellKey = GlobalKey();

// ✅ 새 프리뷰 위젯 사용
PetgramCameraShell(
  key: _cameraShellKey,
  initialAspect: _aspectMode,
  initialFilter: _buildCurrentFilterConfig(),
  onPhotoTaken: (photoPath) {
    // 촬영 완료 처리
    _handlePhotoTaken(photoPath);
  },
  onError: (error) {
    // 에러 처리
    _handleCameraError(error);
  },
  onStateChanged: (state, canTakePhoto) {
    // 상태 변경 로그 (디버그용)
    debugPrint('[Camera] State: $state, canTakePhoto: $canTakePhoto');
  },
)

// ✅ 간단한 촬영 로직
Future<void> _takePhoto() async {
  final shell = _cameraShellKey.currentState;
  if (shell != null) {
    await shell.takePhoto();
  }
}

// ✅ 비율 변경
void _changeAspectMode(AspectRatioMode mode) {
  final shell = _cameraShellKey.currentState;
  if (shell != null) {
    shell.setAspect(mode);
  }
}

// ✅ 필터 변경
void _applyFilter(FilterConfig filter) {
  final shell = _cameraShellKey.currentState;
  if (shell != null) {
    shell.setFilter(filter);
  }
}

// ✅ 줌 변경
void _setZoom(double zoom) {
  final shell = _cameraShellKey.currentState;
  if (shell != null) {
    shell.setZoom(zoom);
  }
}

// ✅ 플래시 변경
void _setFlash(String mode) {
  final shell = _cameraShellKey.currentState;
  if (shell != null) {
    shell.setFlash(mode);
  }
}
```

## 📝 단계별 마이그레이션

### 1단계: Import 추가

```dart
import '../widgets/camera/petgram_camera_shell.dart';
```

### 2단계: GlobalKey 추가

```dart
final GlobalKey<_PetgramCameraShellState> _cameraShellKey = GlobalKey();
```

### 3단계: 프리뷰 위젯 교체

**기존:**

```dart
_buildCameraPreviewLayer() {
  return NativeCameraPreview(
    onCreated: (viewId) {
      // 복잡한 초기화 로직...
    },
  );
}
```

**새로운:**

```dart
_buildCameraPreviewLayer() {
  return PetgramCameraShell(
    key: _cameraShellKey,
    initialAspect: _aspectMode,
    initialFilter: _buildCurrentFilterConfig(),
    onPhotoTaken: _handlePhotoTaken,
    onError: _handleCameraError,
  );
}
```

### 4단계: 상태 계산 제거

**제거할 코드:**

- `canUseCamera` getter
- `_pollDebugState()` 메서드
- `_cameraEngine.getDebugState()` 호출
- `sessionRunning`, `videoConnected`, `hasFirstFrame` 계산

**대체:**

- 네이티브에서 전달되는 `onStateChanged` 콜백 사용
- `canTakePhoto`는 셸에서 직접 확인

### 5단계: 촬영 로직 간소화

**기존:**

```dart
Future<void> _takePhoto() async {
  if (!canUseCamera) {
    _addDebugLog('[takePhoto] ❌ BLOCKED: canUseCamera=false');
    return;
  }

  if (_isProcessing || _cameraEngine.isCapturingPhoto) {
    return;
  }

  // 복잡한 촬영 로직...
}
```

**새로운:**

```dart
Future<void> _takePhoto() async {
  final shell = _cameraShellKey.currentState;
  if (shell == null) {
    _addDebugLog('[takePhoto] ❌ Camera shell not available');
    return;
  }

  if (!shell.canTakePhoto) {
    _addDebugLog('[takePhoto] ❌ Camera not ready');
    return;
  }

  try {
    await shell.takePhoto();
  } catch (e) {
    _addDebugLog('[takePhoto] ❌ Error: $e');
  }
}
```

### 6단계: 제어 메서드 교체

**비율 변경:**

```dart
void _changeAspectMode(AspectRatioMode mode) {
  setState(() {
    _aspectMode = mode;
  });

  final shell = _cameraShellKey.currentState;
  shell?.setAspect(mode);
}
```

**필터 적용:**

```dart
void _applyFilter(FilterConfig filter) {
  final shell = _cameraShellKey.currentState;
  shell?.setFilter(filter);
}
```

**줌 설정:**

```dart
void _setZoom(double zoom) {
  final shell = _cameraShellKey.currentState;
  shell?.setZoom(zoom);
}
```

**플래시 설정:**

```dart
void _toggleFlash() {
  final newMode = _flashMode == FlashMode.off ? 'on' : 'off';
  setState(() {
    _flashMode = newMode == 'on' ? FlashMode.on : FlashMode.off;
  });

  final shell = _cameraShellKey.currentState;
  shell?.setFlash(newMode);
}
```

## ⚠️ 주의사항

1. **점진적 마이그레이션**: 전체를 한 번에 바꾸지 말고, 단계별로 테스트
2. **기존 CameraEngine 제거 전**: 새 셸이 정상 작동하는지 확인
3. **디버그 로그**: 상태 변경 로그는 `onStateChanged` 콜백에서 확인
4. **에러 처리**: `onError` 콜백에서 네이티브 에러 처리

## ✅ 완료 체크리스트

- [ ] `PetgramCameraShell` import 추가
- [ ] GlobalKey 추가
- [ ] 프리뷰 위젯 교체
- [ ] `canUseCamera` 계산 제거
- [ ] 상태 폴링 제거
- [ ] 촬영 로직 간소화
- [ ] 비율/필터/줌/플래시 제어 메서드 교체
- [ ] 기존 `CameraEngine` 의존성 제거 (선택적)
- [ ] 테스트 및 검증
