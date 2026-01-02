# 카메라 초기화 문제 진단 요약

## 현재 상태

### 디버그 정보

- `canUseCamera: false`
- `nativeInit: false`
- `sessionRunning: false`
- `videoConnected: false`
- `hasFirstFrame: false`
- `isPinkFallback: true`

### 로그 분석 결과

- ✅ 라이프사이클 이벤트는 정상 기록
- ❌ `onCreated` 콜백 관련 로그 없음
- ❌ `initializeIfNeeded` 관련 로그 없음
- ❌ `_buildCameraPreview` 호출 로그 없음
- ❌ `_buildCameraPreviewLayer` 호출 로그 없음
- ❌ `[PreviewLayer] Building: ...` 로그 없음

## 문제 진단

### 핵심 문제

**`NativeCameraPreview` 위젯이 빌드되지 않음**

### 가능한 원인

1. `ValueListenableBuilder`가 초기 빌드에서 호출되지 않음
2. `_buildCameraStack`이 호출되지 않음
3. 위젯 트리에 포함되지 않음

## 추가된 디버그 로그

다음 로그들이 추가되었습니다:

- `[HomePage] 🔍 _buildCameraPreviewLayer called`
- `[HomePage] 🔍 _buildCameraBackground called`
- `[HomePage] 🔍 _buildCameraPreview called`
- `[NativeCameraPreview] 🔍 initState called`
- `[NativeCameraPreview] 🔍 didChangeDependencies called`
- `[NativeCameraPreview] 🔍 _callOnCreatedIfNeeded: ...`
- `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
- `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`

## 다음 단계

1. **앱 재시작 후 로그 확인**

   - 위의 모든 디버그 로그가 나타나는지 확인
   - 어느 단계에서 멈추는지 확인

2. **위젯 빌드 체인 확인**

   ```
   _buildCameraStack()
     → ValueListenableBuilder
       → _buildCameraPreviewLayer()
         → _buildCameraBackground()
           → _buildCameraPreview()
             → NativeCameraPreview()
   ```

3. **문제 발견 시**
   - 어느 단계에서 멈추는지 확인
   - 해당 단계의 조건을 확인
   - 필요시 수정

## 예상 결과

앱 재시작 후 다음 로그들이 순차적으로 나타나야 함:

1. `[HomePage] 🔍 _buildCameraPreviewLayer called`
2. `[HomePage] 🔍 _buildCameraBackground called`
3. `[HomePage] 🔍 _buildCameraPreview called`
4. `[NativeCameraPreview] 🔍 initState called`
5. `[NativeCameraPreview] 🔥🔥🔥 About to call widget.onCreated(0)`
6. `[HomePage] 🔥🔥🔥 NativeCameraPreview.onCreated CALLBACK ENTERED: viewId=0`
7. `[Native] 🔥🔥🔥 initializeIfNeeded() STARTED`
