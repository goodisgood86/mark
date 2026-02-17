# 디버그 오버레이 표시 수정

## 문제

일부 디버그 로그가 `debugPrint()`만 사용하여 디버그 오버레이에 표시되지 않았습니다.

## 수정 사항

모든 디버그 로그에 `_addDebugLog()` 호출을 추가했습니다.

### 수정된 로그들

1. ✅ `[HomePage] 🔍 build() called` - 이미 `_addDebugLog()` 있음
2. ✅ `[HomePage] 🔍 About to create ValueListenableBuilder: ...` - 이미 `_addDebugLog()` 있음
3. ✅ `[HomePage] 🔍 ValueListenableBuilder building: ...` - 이미 `_addDebugLog()` 있음
4. ✅ `[HomePage] 🔍 _buildCameraPreviewLayer called` - `_addDebugLog()` 추가됨
5. ✅ `[HomePage] 🔍 _buildCameraBackground called` - `_addDebugLog()` 추가됨
6. ✅ `[HomePage] 🔍 _buildCameraPreview called` - `_addDebugLog()` 추가됨
7. ✅ `[HomePage] 🔍 _buildCameraStack called` - `_addDebugLog()` 추가됨

## 확인 방법

### 실기기에서 확인할 로그들

다음 로그들이 디버그 오버레이에 순차적으로 나타나야 합니다:

1. `[HomePage] 🔍 build() called`
2. `[HomePage] 🔍 About to create ValueListenableBuilder: _cameraEngine=true, stateNotifier=true`
3. `[HomePage] 🔍 ValueListenableBuilder building: state=idle, stateNotifier.value=idle`
4. `[HomePage] 🔍 _buildCameraPreviewLayer called`
5. `[HomePage] 🔍 _buildCameraBackground called`
6. `[HomePage] 🔍 _buildCameraPreview called`
7. `[HomePage] 🔍 _buildCameraStack called`
8. `[NativeCameraPreview] 🔍 initState called`
9. `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
10. `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`
11. `[Native] 🔥🔥🔥 initializeIfNeeded() STARTED`

## 참고

- `debugPrint()`: 콘솔에만 출력 (Xcode/Android Studio 로그)
- `_addDebugLog()`: 디버그 오버레이에 표시 (실기기에서도 확인 가능)
