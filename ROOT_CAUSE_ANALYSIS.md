# 근본 원인 분석 및 수정 계획

## 1. 현재 코드 기준 문제점 요약

### 문제 1: 프리뷰가 들어오는 순간 Flutter가 카메라 영역을 잘못 인지

#### A. 앱 처음 진입, 아직 카메라 프레임이 오기 전 (검은 화면 단계)

- **Flutter 상태:**

  - `_nativePreviewViewFrame`: null 또는 초기값
  - `_nativeCameraContainerFrame`: null 또는 초기값
  - `_nativePreviewViewIsHidden`: null 또는 true
  - `_nativePreviewViewAlpha`: null 또는 0.0
  - `_nativePreviewViewHasWindow`: null 또는 false
  - `_isCameraHealthy`: false (hasFirstFrame=false)
  - `canUseCamera`: false
  - `_shouldShowPinkOverlay`: true

- **네이티브 상태:**

  - `cameraContainer.frame`: Flutter에서 `updatePreviewLayout` 호출 전까지 설정되지 않음
  - `previewView.frame`: cameraContainer.bounds와 동기화되지 않음
  - `sessionRunning`: false
  - `hasFirstFrame`: false

- **레이아웃:**
  - Flutter: `Container(color: Colors.transparent) + SizedBox.expand()`가 Stack의 Positioned 내부에 배치됨
  - 네이티브: `cameraContainer`는 아직 frame이 설정되지 않아 보이지 않음
  - **결과:** 검은색 오버레이가 표시되고, Flutter는 프리뷰 영역을 정상적으로 인지함

#### B. 첫 프레임 도착 직전

- **Flutter 상태:**

  - `_buildCameraStack`에서 `_syncPreviewRectToNativeFromLocal` 호출
  - `updatePreviewLayout(x, y, width, height)` 호출
  - 하지만 `hasFirstFrame=false`이므로 `canUseCamera=false`

- **네이티브 상태:**

  - `updatePreviewLayout`에서 `cameraContainer.frame` 설정
  - `previewView.frame = cameraContainer.bounds` 설정
  - `sessionRunning`: true
  - `hasFirstFrame`: false (아직 sampleBuffer 수신 전)

- **레이아웃:**
  - Flutter: Positioned의 크기와 위치는 계산됨
  - 네이티브: `cameraContainer.frame`이 Flutter의 global 좌표로 설정됨
  - **문제:** Flutter의 Positioned 크기와 네이티브의 cameraContainer.frame이 동기화되지만, 프리뷰가 아직 없어서 검은색 오버레이가 표시됨

#### C. 첫 프레임 도착 직후 (hasFirstFrame == true가 되는 시점)

- **Flutter 상태:**

  - `hasFirstFrame`: true로 변경
  - `_isCameraHealthy`: true (sessionRunning && videoConnected && hasFirstFrame && !isPinkFallback)
  - `canUseCamera`: true
  - `_shouldShowPinkOverlay`: false

- **네이티브 상태:**

  - `sampleBufferCount > 0` → `hasFirstFrame = true`
  - `previewView.display(image:)` 호출
  - `previewView.hasCurrentImage()`: true
  - `renderSuccessCount`: 증가

- **레이아웃:**
  - Flutter: `_shouldShowPinkOverlay=false`이므로 검은색 오버레이 제거
  - 네이티브: `cameraContainer.frame`은 이미 설정되어 있음
  - **문제 발생 지점:**
    1. 네이티브 `previewView`가 실제 프레임을 렌더링하기 시작
    2. 하지만 `updatePreviewLayout`이 호출된 후 Flutter의 Positioned 크기가 변경되면 네이티브 frame이 업데이트되지 않음
    3. Flutter의 Stack 레이아웃이 재계산되면 (예: 키보드, 상태바 변경) Positioned의 크기가 바뀌지만 네이티브는 그대로
    4. **결과:** Flutter가 기대하는 프리뷰 영역과 실제 네이티브 cameraContainer.frame이 어긋남

#### D. 촬영 버튼을 누른 직후 ~ 콜백이 끝나기 전

- **Flutter 상태:**

  - `_isProcessing`: true
  - `_cameraEngine.isCapturingPhoto`: true
  - `canUseCamera`: false (촬영 중)

- **네이티브 상태:**

  - `isCapturingPhoto`: true
  - `photoOutput.capturePhotoWithSettings` 호출
  - `photoOutput(_:didFinishProcessingPhoto:)` 콜백 대기

- **레이아웃:**
  - Flutter: 촬영 중이므로 오버레이 표시 안 함
  - 네이티브: 세션이 계속 실행 중
  - **문제 발생 지점:**
    1. 촬영 완료 후 `isCapturingPhoto = false` 설정
    2. 하지만 촬영 중에 Flutter의 Stack이 재빌드되면 `_syncPreviewRectToNativeFromLocal`이 다시 호출될 수 있음
    3. 네이티브에서 `updatePreviewLayout`이 호출되면 `cameraContainer.frame`이 변경됨
    4. **결과:** 촬영 중에 프리뷰 레이아웃이 변경되어 크래시 가능성

### 문제 2: PlatformView의 레이아웃이 "native preview의 실제 크기"에 종속

#### 현재 구조:

1. **Flutter 쪽:**

   - `_buildCameraStack`에서 `LayoutBuilder`로 constraints 계산
   - `Positioned(left, top, width, height)`로 프리뷰 영역 지정
   - `_syncPreviewRectToNativeFromLocal`에서 global 좌표 계산 후 `updatePreviewLayout` 호출

2. **네이티브 쪽:**
   - `updatePreviewLayout`에서 `cameraContainer.frame` 설정
   - `previewView.frame = cameraContainer.bounds` 설정
   - 하지만 `previewView`는 MTKView이고, `drawableSize`는 자동으로 계산됨

#### 문제점:

- **Flutter의 Positioned 크기**는 Flutter 레이아웃 시스템에 의해 결정됨
- **네이티브의 cameraContainer.frame**은 Flutter에서 `updatePreviewLayout` 호출 시에만 업데이트됨
- **네이티브의 previewView.drawableSize**는 MTKView가 자동으로 계산하는데, 이는 `previewView.bounds`에 종속됨
- **결과:** Flutter 레이아웃이 변경되어도 네이티브 frame이 업데이트되지 않으면 불일치 발생

### 문제 3: 촬영 시 크래시의 직접 원인

#### 촬영 파이프라인 순서:

1. `_takePhoto()` 호출

   - `_isProcessing = true`
   - `_cameraEngine.isCapturingPhoto = true` (Flutter 측)
   - `_cameraEngine.takePicture()` 호출

2. 네이티브 `capturePhoto()` 호출

   - `isCapturingPhoto = true` (네이티브 측)
   - `photoOutput.capturePhotoWithSettings` 호출
   - `photoOutput(_:didFinishProcessingPhoto:)` 콜백 대기

3. 촬영 완료 콜백
   - `photoOutput(_:didFinishProcessingPhoto:)` 실행
   - 이미지 처리 및 저장
   - `isCapturingPhoto = false` 설정

#### 문제 발생 지점:

1. **촬영 중에 세션 재시작:**

   - `_manualRestartCamera()` 또는 `_initCameraPipeline()`이 호출되면
   - `CameraEngine.dispose()` → `nativeCamera.dispose()` 호출
   - 네이티브에서 `session.stopRunning()` 호출
   - 하지만 `isCapturingPhoto = true`인 상태에서 세션이 중지되면 크래시

2. **촬영 중에 레이아웃 변경:**

   - Flutter Stack이 재빌드되면 `_syncPreviewRectToNativeFromLocal` 호출
   - `updatePreviewLayout`이 호출되면 `cameraContainer.frame` 변경
   - 하지만 촬영 중에 frame이 변경되면 예상치 못한 동작 가능

3. **photoOutput이 nil인 상태에서 capture 호출:**
   - `dispose()` 후 `photoOutput = nil`이 되지만
   - Flutter 측에서 `isCapturingPhoto`가 아직 true이면
   - 다시 `capturePhoto` 호출 시 크래시

## 2. 수정 방향

### 수정 1: PlatformView 레이아웃을 "Flutter 컨테이너 기준으로만" 결정

**목표:** Flutter의 Positioned 크기가 변경되면 네이티브 frame도 즉시 동기화

**방법:**

1. `_buildCameraStack`에서 `LayoutBuilder`의 `didChangeDependencies` 또는 `didUpdateWidget`에서 레이아웃 변경 감지
2. 레이아웃이 변경되면 즉시 `_syncPreviewRectToNativeFromLocal` 호출
3. 네이티브에서 `updatePreviewLayout` 호출 시 `cameraContainer.frame`만 설정하고, `previewView`는 자동으로 bounds를 따르도록 함

### 수정 2: fallback 오버레이는 "상태 머신"으로 분명하게 분리

**목표:** Ready 상태에서는 절대 fallback이 위로 올라오지 않도록 보장

**방법:**

1. 상태 머신 정의:

   - `Idle`: 초기화 전
   - `Initializing`: sessionRunning=false, hasFirstFrame=false
   - `Ready`: sessionRunning=true, videoConnected=true, hasFirstFrame=true
   - `Error`: 명백한 에러 상태

2. `_shouldShowPinkOverlay`를 상태 머신 기반으로 변경:
   ```dart
   bool get _shouldShowPinkOverlay {
     final state = _cameraEngine.lastDebugState;
     if (state == null) return true; // Idle

     if (state.sessionRunning && state.videoConnected && state.hasFirstFrame) {
       return false; // Ready - 절대 오버레이 표시 안 함
     }

     if (_isReinitializing) return true; // Initializing
     if (_cameraEngine.hasError) return true; // Error

     return true; // 그 외는 모두 오버레이 표시
   }
   ```

### 수정 3: 촬영 파이프라인과 세션 라이프사이클을 완전히 분리

**목표:** 촬영 중에는 세션 재시작/재초기화/레이아웃 변경을 절대 허용하지 않음

**방법:**

1. `_takePhoto()` 진입 시:

   - `_isProcessing = true`
   - `_cameraEngine.isCapturingPhoto = true`
   - 네이티브 `isCapturingPhoto = true`

2. 촬영 중 보호:

   - `_manualRestartCamera()`: `isCapturingPhoto` 체크 추가
   - `_initCameraPipeline()`: `isCapturingPhoto` 체크 추가
   - `_syncPreviewRectToNativeFromLocal`: `isCapturingPhoto` 체크 추가

3. 촬영 완료 후:
   - 모든 콜백이 끝난 후에만 `isCapturingPhoto = false`
   - 그 이후에만 세션 재시작/재초기화 가능

### 수정 4: init / dispose / restart 경로를 하나로 통일

**목표:** 단일 진입점으로 통일하여 중복 호출 방지

**방법:**

1. `initializeCameraOnce()`: 앱 시작 시 1회만 호출
2. `restartCameraManually()`: 사용자가 "카메라 재시작" 버튼 눌렀을 때만 호출
3. lifecycle 변화: 세션 pause/resume만 처리, init/dispose는 건드리지 않음
