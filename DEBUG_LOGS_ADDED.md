# 추가된 디버그 로그 요약

## 문제 상황

로그에 `onCreated` 콜백 관련 로그가 전혀 없음:

- `_buildCameraPreviewLayer` 호출 로그 없음
- `_buildCameraBackground` 호출 로그 없음
- `_buildCameraPreview` 호출 로그 없음
- `NativeCameraPreview` 위젯 생명주기 로그 없음

## 추가된 디버그 로그

### 1. ValueListenableBuilder 빌드 확인

**위치**: `lib/pages/home_page.dart` (라인 4463-4469)

```dart
ValueListenableBuilder<CameraState>(
  valueListenable: _cameraEngine.stateNotifier,
  builder: (context, state, child) {
    // 🔥 디버그 로그: ValueListenableBuilder 빌드 확인
    if (kDebugMode) {
      debugPrint(
        '[HomePage] 🔍 ValueListenableBuilder building: state=${state.name}, stateNotifier.value=${_cameraEngine.stateNotifier.value.name}',
      );
    }
    _addDebugLog(
      '[PreviewLayer] ValueListenableBuilder building: state=${state.name}',
    );
    return _buildCameraPreviewLayer();
  },
),
```

### 2. \_buildCameraStack 호출 확인

**위치**: `lib/pages/home_page.dart` (라인 6187-6193)

```dart
Widget _buildCameraStack({...}) {
  // 🔥 디버그 로그: _buildCameraStack 호출 확인
  if (kDebugMode) {
    debugPrint('[HomePage] 🔍 _buildCameraStack called');
  }
  ...
}
```

### 3. 기존 디버그 로그 (이전에 추가됨)

- `[HomePage] 🔍 _buildCameraPreviewLayer called`
- `[HomePage] 🔍 _buildCameraBackground called`
- `[HomePage] 🔍 _buildCameraPreview called`
- `[NativeCameraPreview] 🔍 initState called`
- `[NativeCameraPreview] 🔍 didChangeDependencies called`
- `[NativeCameraPreview] 🔍 _callOnCreatedIfNeeded: ...`
- `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
- `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`

## 예상되는 로그 순서

앱 재시작 후 다음 로그들이 순차적으로 나타나야 함:

1. `[HomePage] 🔍 ValueListenableBuilder building: state=idle`
2. `[HomePage] 🔍 _buildCameraPreviewLayer called`
3. `[HomePage] 🔍 _buildCameraBackground called`
4. `[HomePage] 🔍 _buildCameraStack called`
5. `[HomePage] 🔍 _buildCameraPreview called`
6. `[NativeCameraPreview] 🔍 initState called`
7. `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
8. `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`
9. `[Native] 🔥🔥🔥 initializeIfNeeded() STARTED`

## 진단 방법

### 시나리오 1: ValueListenableBuilder가 호출되지 않음

- 로그: `[HomePage] 🔍 ValueListenableBuilder building: ...` 없음
- 원인: 위젯 트리에 포함되지 않음 또는 `stateNotifier`가 초기화되지 않음
- 해결: `_cameraEngine.stateNotifier` 초기화 확인

### 시나리오 2: \_buildCameraPreviewLayer가 호출되지 않음

- 로그: `[HomePage] 🔍 _buildCameraPreviewLayer called` 없음
- 원인: `ValueListenableBuilder`는 호출되지만 `_buildCameraPreviewLayer`가 호출되지 않음
- 해결: `_buildCameraPreviewLayer` 함수 내부 확인

### 시나리오 3: \_buildCameraBackground가 호출되지 않음

- 로그: `[HomePage] 🔍 _buildCameraBackground called` 없음
- 원인: `_buildCameraPreviewLayer`는 호출되지만 `_buildCameraBackground`가 호출되지 않음
- 해결: `_buildCameraPreviewLayer` 내부에서 `_buildCameraBackground` 호출 확인

### 시나리오 4: NativeCameraPreview가 빌드되지 않음

- 로그: `[NativeCameraPreview] 🔍 initState called` 없음
- 원인: `_buildCameraPreview`가 호출되지 않거나 `NativeCameraPreview` 위젯이 반환되지 않음
- 해결: `_buildCameraPreview` 함수 내부 확인

## 다음 단계

1. 앱 재시작
2. 새로운 로그 확인
3. 어느 단계에서 멈추는지 확인
4. 해당 단계의 문제 해결
