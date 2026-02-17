# 위젯 빌드 체인 디버그 로그 추가

## 추가된 디버그 로그

### 1. build() 메서드 호출 확인

- 위치: `lib/pages/home_page.dart` - `build()` 메서드 시작 부분
- 로그: `[HomePage] 🔍 build() called`

### 2. ValueListenableBuilder 생성 전 확인

- 위치: `lib/pages/home_page.dart` - `ValueListenableBuilder` 생성 전
- 로그: `[HomePage] 🔍 About to create ValueListenableBuilder: _cameraEngine=..., stateNotifier=...`
- 목적: `_cameraEngine`과 `stateNotifier`가 null이 아닌지 확인

### 3. ValueListenableBuilder 빌드 확인

- 위치: `lib/pages/home_page.dart` - `ValueListenableBuilder` builder 콜백
- 로그: `[HomePage] 🔍 ValueListenableBuilder building: state=..., stateNotifier.value=...`
- 목적: `ValueListenableBuilder`가 실제로 빌드되는지 확인

### 4. 기존 디버그 로그 (이미 추가됨)

- `[HomePage] 🔍 _buildCameraPreviewLayer called`
- `[HomePage] 🔍 _buildCameraBackground called`
- `[HomePage] 🔍 _buildCameraPreview called`
- `[HomePage] 🔍 _buildCameraStack called`
- `[NativeCameraPreview] 🔍 initState called`
- `[NativeCameraPreview] 🔍 didChangeDependencies called`
- `[NativeCameraPreview] 🔍 _callOnCreatedIfNeeded: ...`
- `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
- `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`

## 예상되는 로그 순서

앱 재시작 후 다음 로그들이 순차적으로 나타나야 함:

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

## 문제 진단 가이드

### 문제 1: `build() called` 로그가 없음

**원인**: `build()` 메서드가 호출되지 않음
**해결**: Flutter 위젯 트리 문제 확인

### 문제 2: `About to create ValueListenableBuilder` 로그가 없음

**원인**: `Stack` children이 빌드되지 않음
**해결**: `Stack` children 빌드 확인

### 문제 3: `ValueListenableBuilder building` 로그가 없음

**원인**: `ValueListenableBuilder`가 빌드되지 않음
**가능한 원인**:

- `_cameraEngine`이 null
- `stateNotifier`가 null
- `ValueListenableBuilder`가 조건부로 제외됨

### 문제 4: `_buildCameraPreviewLayer` 로그가 없음

**원인**: `ValueListenableBuilder`의 builder가 호출되지 않음
**해결**: `ValueListenableBuilder` 빌드 확인

## 다음 단계

1. **앱 재시작 후 로그 확인**

   - 위의 모든 디버그 로그가 나타나는지 확인
   - 어느 단계에서 멈추는지 확인

2. **문제 발견 시**
   - 어느 단계에서 멈추는지 확인
   - 해당 단계의 조건을 확인
   - 필요시 수정
