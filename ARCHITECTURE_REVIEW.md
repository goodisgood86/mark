# iOS 네이티브 카메라 아키텍처 점검 리포트

**점검 일시**: 2024년  
**점검 범위**: `lib/` 전체 + `ios/Runner/NativeCamera.swift`  
**목표 아키텍처**: iOS 네이티브 카메라(AVCaptureSession) 메인, Flutter는 UI/명령 전송만

---

## 1. 구조 요약

### 현재 런타임 플로우 (코드 기준)

```
[사용자 액션]
  ↓
[Flutter UI]
  ├─ 촬영 버튼 탭 → _onCapturePressed() → _takePhoto()
  ├─ 필터 변경 → _cameraEngine.setFilter()
  ├─ 밝기 조정 → _updateNativeExposureBias() → _cameraEngine.setExposureBias()
  ├─ 줌 조정 → _applyZoomToNativeCamera() → _cameraEngine.setZoom()
  ├─ 비율 변경 → _changeAspectMode() → (UI만 변경, 네이티브는 촬영 시 전달)
  └─ 전면/후면 전환 → _switchCamera() → _cameraEngine.switchCamera()
  ↓
[CameraEngine] (단일 진입점)
  ↓
[NativeCameraController] (MethodChannel)
  ↓
[NativeCameraViewController] (AVCaptureSession)
  ├─ 프리뷰: AVCaptureVideoDataOutput → FilterEngine → MTKView
  ├─ 촬영: AVCapturePhotoOutput → 필터/밝기/비율/프레임 적용 → 갤러리 저장
  └─ 제어: setZoom, setFocusPoint, setExposurePoint, setFlashMode 등
  ↓
[결과]
  ├─ 촬영 성공 → 파일명 반환 → Flutter에서 DB 저장만
  └─ 프리뷰 → 실시간 MTKView 렌더링
```

---

## 2. 정상적으로 의도대로 연결된 부분 (OK 리스트)

### ✅ 2.1 촬영 경로
- **`_takePhoto()` 단일 진입점**: 모든 촬영 요청이 `_takePhoto()` 하나로 통합됨
  - 호출부: `_onCapturePressed()` (1524줄), 타이머 완료 시 (1728줄), 연속 촬영 (1728줄)
  - `_takePhotoLegacy()` 호출 없음 ✅
- **네이티브 경로 사용**: `_cameraEngine.takePicture()` → `NativeCameraController.takePicture()` → 네이티브 처리
- **중복 호출 방지**: `_isProcessing` 플래그로 중복 촬영 차단 (1560줄)
- **비동기 처리**: `unawaited(_takePhoto())` 사용으로 UI 블로킹 최소화 (4992줄)

### ✅ 2.2 카메라 전환
- **네이티브 전환만 사용**: `_switchCamera()` → `_cameraEngine.switchCamera()` → `NativeCameraController.switchCamera()` (1326-1349줄)
- **CameraController 사용 없음**: 모든 `canUseLegacy` 변수가 `false`로 설정됨
- **상태 복구**: 전환 실패 시 이전 방향으로 복구 (1384-1390줄)

### ✅ 2.3 밝기 조정
- **네이티브 경로**: `_updateNativeExposureBias()` → `_cameraEngine.setExposureBias()` → 네이티브 처리 (588-600줄)
- **Flutter 후처리 없음**: 촬영 경로에서 ColorMatrix 기반 밝기 보정 없음

### ✅ 2.4 줌/렌즈 전환
- **네이티브 줌**: `_applyZoomToNativeCamera()` → `_cameraEngine.setZoom()` (2004줄)
- **렌즈 전환**: `_maybeSwitchNativeLensForZoom()` → `switchToUltraWideIfAvailable()` / `switchToWideIfAvailable()` (606-650줄)
- **히스테리시스 적용**: 0.9x 이하 → ultraWide, 1.05x 이상 → wide (614-615줄)

### ✅ 2.5 필터 적용
- **네이티브 필터**: `_cameraEngine.setFilter()` → 네이티브 FilterEngine 사용
- **프리뷰 필터**: ColorFiltered 위젯으로 UI만 표시 (실제 프리뷰는 네이티브 FilterEngine)

### ✅ 2.6 레거시 코드 제거
- **`_takePhotoLegacy()` 제거됨**: 호출부 없음
- **`_processAndSaveCapturedPhoto()` 제거됨**: 주석으로 표시 (1551줄)
- **`_addPhotoFrameOnUiImage()`, `_addPhotoFrame()` 제거됨**: 주석으로 표시 (1061줄)
- **`_initLegacyCameraFallback()` 제거됨**: 호출부 없음

---

## 3. 문제 가능성이 있는 부분 (WARNING 리스트)

### ⚠️ 3.1 촬영 경로 - 임시 파일 경로 처리 (중요)

**위치**: `lib/pages/home_page.dart:1667-1672`

**문제점**:
```dart
// 임시 파일 경로인 경우 (갤러리 저장 실패 시)
file = File(imagePath);
```

**상황**: 네이티브에서 갤러리 저장이 실패하면 임시 파일 경로를 반환하는데, 이 경우 Flutter에서 추가 처리가 없어 빈 코드 블록이 됨.

**영향**: 
- 갤러리 저장 실패 시 사진이 저장되지 않음
- 사용자에게 에러 피드백 없음

**수정 제안**:
```dart
// 임시 파일 경로인 경우 (갤러리 저장 실패 시)
if (imagePath.contains('/')) {
  // 갤러리 저장 실패 - 사용자에게 알림
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('사진 저장에 실패했습니다. 갤러리 권한을 확인해주세요.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ),
    );
  }
  return; // 추가 처리 없이 종료
}
```

---

### ⚠️ 3.2 비율 변경 - 네이티브에 실시간 전달 없음

**위치**: `lib/pages/home_page.dart:1408-1427`

**문제점**:
```dart
void _changeAspectMode(AspectRatioMode mode) {
  // ... UI만 변경
  // 네이티브에 비율 변경을 즉시 알리지 않음
}
```

**상황**: 
- 비율 변경 시 Flutter UI만 업데이트됨
- 네이티브 카메라는 촬영 시에만 `aspectRatio`를 받음
- 프리뷰 비율은 네이티브에서 자동 계산하지만, Flutter UI와 불일치 가능

**영향**:
- 9:16 선택 시 프리뷰가 3:4처럼 보일 수 있음
- 촬영 시에만 올바른 비율로 저장됨

**수정 제안**:
```dart
void _changeAspectMode(AspectRatioMode mode) {
  if (_aspectMode == mode) return;
  
  setState(() {
    _aspectMode = mode;
  });
  _saveAspectMode();
  
  // 네이티브에 비율 변경 알림 (프리뷰 재초기화)
  if (_cameraEngine.isInitialized) {
    final targetRatio = aspectRatioOf(mode);
    _cameraEngine.initialize(
      cameraPosition: _cameraLensDirection == CameraLensDirection.back ? 'back' : 'front',
      aspectRatio: targetRatio,
    );
  }
  
  // ... 기존 postFrameCallback 로직
}
```

**또는** 네이티브에 `setAspectRatio` 메서드 추가:
```swift
// NativeCameraViewController
func setAspectRatio(_ ratio: Double) {
    // 프리뷰 비율만 업데이트 (재초기화 없이)
    // 또는 previewView의 aspect ratio constraint 업데이트
}
```

---

### ⚠️ 3.3 프리뷰 필터 - ColorFiltered 중복 적용 가능성

**위치**: `lib/pages/home_page.dart:3496-3509, 3601-3611`

**문제점**:
```dart
filteredPreview = ColorFiltered(
  colorFilter: ColorFilter.matrix(previewMatrix),
  child: Transform.scale(...),
);
```

**상황**:
- 네이티브에서 이미 FilterEngine으로 필터 적용 중
- Flutter에서 ColorFiltered로 또 필터 적용
- **중복 필터링 가능성**

**영향**:
- 필터가 두 번 적용되어 의도와 다르게 보일 수 있음
- 성능 저하 (GPU 연산 중복)

**수정 제안**:
```dart
// 네이티브에서 필터 적용 중이므로 Flutter ColorFiltered 제거
// 또는 네이티브 필터를 끄고 Flutter ColorFiltered만 사용
if (hasFilter && !_cameraEngine.isInitialized) {
  // Mock 모드에서만 ColorFiltered 사용
  filteredPreview = ColorFiltered(...);
} else {
  // 네이티브 카메라는 ColorFiltered 없이 사용
  filteredPreview = Transform.scale(...);
}
```

---

### ⚠️ 3.4 촬영 후 처리 - DB 저장이 메인 스레드에서 실행

**위치**: `lib/pages/home_page.dart:1656-1660`

**문제점**:
```dart
await PetgramPhotoRepository.instance.upsertPhotoRecord(
  filePath: imagePath,
  meta: meta,
  exifTag: meta.toExifTag(),
);
```

**상황**:
- DB 저장이 `await`로 메인 스레드에서 실행됨
- 큰 메타데이터나 복잡한 쿼리 시 UI 블로킹 가능

**영향**:
- 촬영 후 약간의 딜레이
- UI 반응성 저하

**수정 제안**:
```dart
// DB 저장을 백그라운드로 이동
if (!imagePath.contains('/')) {
  // 갤러리 저장 성공 - DB 저장은 백그라운드로
  unawaited(
    PetgramPhotoRepository.instance.upsertPhotoRecord(
      filePath: imagePath,
      meta: meta,
      exifTag: meta.toExifTag(),
    ).catchError((e) {
      debugPrint('[Petgram] ⚠️ DB save error: $e');
    })
  );
  if (kDebugMode) {
    debugPrint('[Petgram] ✅ Photo saved to gallery: $imagePath');
  }
  return;
}
```

---

### ⚠️ 3.5 전면 카메라 전환 - 상태 복구 로직 불완전

**위치**: `lib/pages/home_page.dart:1384-1390`

**문제점**:
```dart
// 실패 시 방향/상태를 이전(back) 기준으로 복구
if (mounted) {
  setState(() {
    _cameraLensDirection = CameraLensDirection.back;
  });
}
```

**상황**:
- 전환 실패 시 항상 `back`으로 복구
- 실제 이전 방향이 `front`였을 수도 있음

**영향**:
- 상태 불일치 가능성

**수정 제안**:
```dart
// 실패 시 이전 방향으로 복구
if (mounted) {
  setState(() {
    _cameraLensDirection = fromDirection; // 실제 이전 방향 사용
  });
}
```

---

### ⚠️ 3.6 렌즈 전환 - 중복 호출 가능성

**위치**: `lib/pages/home_page.dart:606-650`

**문제점**:
- `_isNativeLensSwitching` 플래그로 중복 방지하지만, 빠른 줌 조작 시 경쟁 조건 가능

**영향**:
- 렌즈 전환이 여러 번 시도될 수 있음

**수정 제안**:
```dart
void _maybeSwitchNativeLensForZoom(double uiZoom) {
  if (!_cameraEngine.isInitialized) return;
  if (_cameraLensDirection != CameraLensDirection.back) return;
  if (_isNativeLensSwitching) return; // 이미 전환 중이면 무시
  
  // ... 기존 로직
}
```
(이미 구현되어 있지만, 추가 검증 필요)

---

## 4. 레거시/중복 코드 정리 제안

### 🔴 4.1 CameraController 관련 주석 (완전 제거 가능)

**위치**: `lib/pages/home_page.dart` 여러 곳

**발견된 주석**:
- 1323줄: `// CameraController는 더 이상 사용하지 않음`
- 1405줄: `// CameraController는 더 이상 사용하지 않음 (카메라 엔진으로 완전 교체)`
- 2622줄: `false; // CameraController는 더 이상 사용하지 않음`
- 2705줄: `final bool canUseLegacy = false; // CameraController는 더 이상 사용하지 않음`
- 2858줄: `final bool canUseLegacyForFocus = false; // CameraController는 더 이상 사용하지 않음`
- 2925줄: `// CameraController는 더 이상 사용하지 않음 (네이티브 카메라로 완전 교체)`

**제안**:
- `canUseLegacy` 변수들을 완전히 제거하고 조건문 단순화
- 주석 제거 또는 "레거시 제거됨" 한 줄로 통일

**예시**:
```dart
// 기존
final bool canUseLegacy = false; // CameraController는 더 이상 사용하지 않음
if (!canUseNative && !canUseLegacy) { ... }

// 수정
if (!canUseNative) { ... }
```

---

### 🟡 4.2 ImagePipelineService - FilterPage에서만 사용

**위치**: `lib/services/image_pipeline_service.dart`, `lib/pages/filter_page.dart`

**상황**:
- `ImagePipelineService`는 `FilterPage`에서만 사용됨 (160줄)
- `HomePage`에서는 사용하지 않음 ✅

**제안**:
- 현재 상태 유지 (FilterPage에서 필요)
- `HomePage`에서 import 제거 확인 (이미 제거됨 ✅)

---

### 🟡 4.3 ColorFiltered - 프리뷰 필터 중복 가능성

**위치**: `lib/pages/home_page.dart:3496-3509, 3601-3611`

**상황**:
- 네이티브 FilterEngine과 Flutter ColorFiltered가 동시에 사용될 수 있음

**제안**:
- 네이티브 카메라 사용 시 ColorFiltered 제거
- Mock 모드에서만 ColorFiltered 사용

**수정 예시**:
```dart
// 네이티브 카메라 사용 시
if (_cameraEngine.isInitialized && !_shouldUseMockCamera) {
  // ColorFiltered 없이 네이티브 필터만 사용
  filteredPreview = Transform.scale(...);
} else {
  // Mock 모드에서만 ColorFiltered 사용
  filteredPreview = ColorFiltered(
    colorFilter: ColorFilter.matrix(previewMatrix),
    child: Transform.scale(...),
  );
}
```

---

### 🟢 4.4 레거시 함수 주석 - 정리 완료

**위치**: `lib/pages/home_page.dart:1061, 1551`

**상황**:
- `_addPhotoFrameOnUiImage`, `_addPhotoFrame`, `_processAndSaveCapturedPhoto` 제거됨
- 주석으로만 표시됨

**제안**:
- 주석 제거 (코드에서 완전히 삭제)

---

## 5. 추가 개선 제안

### 💡 5.1 네이티브 초기화 시 aspectRatio 전달

**위치**: `lib/pages/home_page.dart:3038`

**현재**:
```dart
_cameraEngine.initialize(
  cameraPosition: ...,
  aspectRatio: targetRatio,
);
```

**상황**: 초기화 시에만 aspectRatio 전달, 이후 변경 시 재초기화 없음

**제안**: 
- 네이티브에 `setAspectRatio` 메서드 추가하여 재초기화 없이 비율 변경
- 또는 비율 변경 시 재초기화 (성능 고려)

---

### 💡 5.2 에러 처리 강화

**위치**: `lib/pages/home_page.dart:1641-1665`

**제안**:
- 네이티브 촬영 실패 시 사용자 피드백 추가
- 갤러리 저장 실패 시 명확한 에러 메시지

---

### 💡 5.3 디버그 로그 정리

**위치**: 전체 파일

**제안**:
- 프로덕션 빌드에서 디버그 로그 제거 또는 조건부 컴파일
- 중요한 에러만 로그 남기기

---

## 6. 최종 체크리스트

### ✅ 완료된 항목
- [x] `_takePhoto()` 단일 진입점
- [x] `_takePhotoLegacy()` 제거
- [x] `CameraController` 사용 제거
- [x] `ImagePipelineService` 촬영 경로에서 제거
- [x] 네이티브 카메라 전환 사용
- [x] 네이티브 밝기/줌/필터 사용
- [x] 레거시 함수 제거

### ⚠️ 개선 필요 항목
- [ ] 임시 파일 경로 처리 로직 추가
- [ ] 비율 변경 시 네이티브에 실시간 전달
- [ ] ColorFiltered 중복 적용 방지
- [ ] DB 저장 백그라운드 처리
- [ ] 전면 카메라 전환 실패 시 상태 복구 개선
- [ ] CameraController 관련 주석/변수 정리

### 💡 권장 개선 사항
- [ ] 네이티브 `setAspectRatio` 메서드 추가
- [ ] 에러 처리 강화
- [ ] 디버그 로그 정리

---

## 7. 결론

**전체 평가**: ✅ **아키텍처 목표 90% 달성**

**강점**:
- 네이티브 카메라를 메인으로 사용하는 구조가 잘 구현됨
- 레거시 코드 대부분 제거됨
- 단일 진입점(`CameraEngine`)으로 통합됨

**개선 필요**:
- 비율 변경 시 네이티브 연동
- 프리뷰 필터 중복 방지
- 에러 처리 강화

**우선순위**:
1. **높음**: 비율 변경 네이티브 연동 (3.2)
2. **중간**: ColorFiltered 중복 방지 (3.3)
3. **낮음**: 주석 정리, 디버그 로그 정리

