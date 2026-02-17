# onCreated 콜백 미호출 문제 분석

## 현재 상태

### 디버그 정보

- `canUseCamera: false`
- `nativeInit: false`
- `sessionRunning: false`
- `videoConnected: false`
- `hasFirstFrame: false`
- `isPinkFallback: true`

### 로그 분석

- ✅ 라이프사이클 이벤트는 정상적으로 기록됨
- ❌ `onCreated` 콜백 관련 로그가 전혀 없음
- ❌ `initializeIfNeeded` 관련 로그가 전혀 없음
- ❌ `_buildCameraPreview` 호출 로그가 없음 (추가한 디버그 로그)

## 문제 진단

### 가능한 원인들

1. **`NativeCameraPreview` 위젯이 빌드되지 않음**

   - `_buildCameraPreview`가 호출되지 않음
   - `_buildCameraBackground`가 호출되지 않음
   - `_buildCameraPreviewLayer`가 호출되지 않음

2. **`onCreated` 콜백이 호출되지 않음**

   - `NativeCameraPreview.initState()`가 호출되지 않음
   - `NativeCameraPreview.didChangeDependencies()`가 호출되지 않음
   - `NativeCameraPreview.build()`가 호출되지 않음
   - `_callOnCreatedIfNeeded()`가 호출되지 않음

3. **위젯 트리에 포함되지 않음**
   - `_buildCameraStack`에서 조건부로 제외됨
   - `_buildCameraPreviewLayer`가 호출되지 않음

## 확인해야 할 사항

### 1. 위젯 빌드 체인 확인

```
_buildCameraStack()
  → _buildCameraPreviewLayer()
    → _buildCameraBackground()
      → _buildCameraPreview()
        → NativeCameraPreview()
          → initState()
          → didChangeDependencies()
          → build()
            → _callOnCreatedIfNeeded()
              → widget.onCreated(0)
```

### 2. 추가된 디버그 로그 확인

다음 로그들이 나타나야 함:

- `[HomePage] 🔍 _buildCameraPreviewLayer called`
- `[HomePage] 🔍 _buildCameraBackground called`
- `[HomePage] 🔍 _buildCameraPreview called`
- `[HomePage] 🔍 _buildCameraPreview: shouldShowMock=..., canUseCameraNow=...`
- `[HomePage] 🔥🔥🔥 About to build NativeCameraPreview widget`
- `[NativeCameraPreview] 🔍 initState called, Platform.isIOS=true`
- `[NativeCameraPreview] 🔍 didChangeDependencies called, Platform.isIOS=true`
- `[NativeCameraPreview] 🔍 _callOnCreatedIfNeeded: ...`
- `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
- `[NativeCameraPreview] ✅✅✅ onCreated callback called (iOS) with viewId=0`
- `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`

## 해결 방법

### 즉시 확인할 사항

1. **앱 재시작 후 로그 확인**

   - 위의 모든 디버그 로그가 나타나는지 확인
   - 어느 단계에서 멈추는지 확인

2. **위젯 트리 확인**

   - `_buildCameraStack`이 호출되는지 확인
   - `_buildCameraPreviewLayer`가 호출되는지 확인

3. **조건부 제외 확인**
   - `_shouldUseMockCamera`가 `true`인지 확인
   - 다른 조건으로 `NativeCameraPreview`가 제외되는지 확인

### 다음 단계

1. 앱을 재시작하고 새로운 로그 수집
2. 위의 디버그 로그들이 나타나는지 확인
3. 어느 단계에서 멈추는지 확인
4. 문제가 되는 단계를 수정
