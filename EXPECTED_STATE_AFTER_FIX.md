# 수정 후 예상 상태 정리

## 수정 사항 요약

### 수정 1: PlatformView 레이아웃을 "Flutter 컨테이너 기준으로만" 결정
- `_syncPreviewRectToNativeFromLocal`에서 촬영 중 체크 추가
- 촬영 중에는 레이아웃 동기화 차단
- 네이티브 `updatePreviewLayout`에서도 촬영 중 체크 추가

### 수정 2: fallback 오버레이는 "상태 머신"으로 분명하게 분리
- `_shouldShowPinkOverlay`를 상태 머신 기반으로 변경
- Ready 상태에서는 절대 오버레이 표시 안 함

### 수정 3: 촬영 파이프라인과 세션 라이프사이클을 완전히 분리
- `_manualRestartCamera()`: 촬영 중 보호 강화
- `_initCameraPipeline()`: 촬영 중 보호 강화
- `_syncPreviewRectToNativeFromLocal`: 촬영 중 레이아웃 동기화 차단
- 네이티브 `updatePreviewLayout`: 촬영 중 레이아웃 변경 차단

### 수정 4: init / dispose / restart 경로 보호 강화
- `_initCameraPipeline()`: 촬영 중 초기화 차단
- `_manualRestartCamera()`: 촬영 중 재시작 차단

---

## 각 케이스별 예상 상태

### 케이스 1: 프리뷰 off 상태 (검은 화면)

| 상태 필드 | 값 | 설명 |
|---------|-----|------|
| `sessionRunning` | `false` | 세션이 시작되지 않음 |
| `videoConnected` | `false` | 비디오 연결 없음 |
| `hasFirstFrame` | `false` | 첫 프레임 수신 전 |
| `isPinkFallback` | `true` | fallback 상태 |
| `_nativePreviewViewIsHidden` | `true` 또는 `null` | 프리뷰 뷰 숨김 |
| `_nativePreviewViewAlpha` | `0.0` 또는 `null` | 투명 |
| `_nativePreviewViewHasWindow` | `false` 또는 `null` | 윈도우 없음 |
| `_nativeCameraContainerIsHidden` | `true` 또는 `null` | 컨테이너 숨김 |
| `_nativeCameraContainerAlpha` | `0.0` 또는 `null` | 투명 |
| `_nativeCameraContainerHasWindow` | `false` 또는 `null` | 윈도우 없음 |
| `_isCameraHealthy` | `false` | 카메라 비정상 |
| `canUseCamera` | `false` | 카메라 사용 불가 |
| `_shouldShowPinkOverlay` | `true` | 오버레이 표시 |

**결과:** 검은색 오버레이가 표시되고, Flutter는 프리뷰 영역을 정상적으로 인지함

---

### 케이스 2: 프리뷰 on 상태 (정상 작동)

| 상태 필드 | 값 | 설명 |
|---------|-----|------|
| `sessionRunning` | `true` | 세션 실행 중 |
| `videoConnected` | `true` | 비디오 연결됨 |
| `hasFirstFrame` | `true` | 첫 프레임 수신됨 |
| `isPinkFallback` | `false` | fallback 아님 |
| `_nativePreviewViewIsHidden` | `false` | 프리뷰 뷰 표시 |
| `_nativePreviewViewAlpha` | `1.0` | 불투명 |
| `_nativePreviewViewHasWindow` | `true` | 윈도우 있음 |
| `_nativeCameraContainerIsHidden` | `false` | 컨테이너 표시 |
| `_nativeCameraContainerAlpha` | `1.0` | 불투명 |
| `_nativeCameraContainerHasWindow` | `true` | 윈도우 있음 |
| `_isCameraHealthy` | `true` | 카메라 정상 |
| `canUseCamera` | `true` | 카메라 사용 가능 |
| `_shouldShowPinkOverlay` | `false` | 오버레이 표시 안 함 |

**결과:** 프리뷰가 정상적으로 표시되고, Flutter는 프리뷰 영역을 정상적으로 인지함

---

### 케이스 3: 촬영 전

| 상태 필드 | 값 | 설명 |
|---------|-----|------|
| `sessionRunning` | `true` | 세션 실행 중 |
| `videoConnected` | `true` | 비디오 연결됨 |
| `hasFirstFrame` | `true` | 첫 프레임 수신됨 |
| `isPinkFallback` | `false` | fallback 아님 |
| `_isProcessing` | `false` | 촬영 중 아님 |
| `_cameraEngine.isCapturingPhoto` | `false` | 촬영 중 아님 |
| `canUseCamera` | `true` | 카메라 사용 가능 |
| `_shouldShowPinkOverlay` | `false` | 오버레이 표시 안 함 |

**결과:** 촬영 준비 완료, 촬영 버튼 활성화

---

### 케이스 4: 촬영 중

| 상태 필드 | 값 | 설명 |
|---------|-----|------|
| `sessionRunning` | `true` | 세션 실행 중 (유지) |
| `videoConnected` | `true` | 비디오 연결됨 (유지) |
| `hasFirstFrame` | `true` | 첫 프레임 수신됨 (유지) |
| `isPinkFallback` | `false` | fallback 아님 (유지) |
| `_isProcessing` | `true` | 촬영 중 |
| `_cameraEngine.isCapturingPhoto` | `true` | 촬영 중 |
| `canUseCamera` | `false` | 촬영 중이므로 사용 불가 |
| `_shouldShowPinkOverlay` | `false` | 오버레이 표시 안 함 (프리뷰 유지) |
| 레이아웃 동기화 | 차단됨 | `_syncPreviewRectToNativeFromLocal` 차단 |
| 세션 재시작 | 차단됨 | `_manualRestartCamera()` 차단 |
| 초기화 | 차단됨 | `_initCameraPipeline()` 차단 |

**결과:** 촬영 중에는 레이아웃 변경 및 세션 재시작이 차단되어 안정성 보장

---

### 케이스 5: 촬영 후

| 상태 필드 | 값 | 설명 |
|---------|-----|------|
| `sessionRunning` | `true` | 세션 실행 중 (유지) |
| `videoConnected` | `true` | 비디오 연결됨 (유지) |
| `hasFirstFrame` | `true` | 첫 프레임 수신됨 (유지) |
| `isPinkFallback` | `false` | fallback 아님 (유지) |
| `_isProcessing` | `false` | 촬영 완료 |
| `_cameraEngine.isCapturingPhoto` | `false` | 촬영 완료 |
| `canUseCamera` | `true` | 카메라 사용 가능 |
| `_shouldShowPinkOverlay` | `false` | 오버레이 표시 안 함 |
| 레이아웃 동기화 | 허용됨 | `_syncPreviewRectToNativeFromLocal` 허용 |
| 세션 재시작 | 허용됨 | `_manualRestartCamera()` 허용 |
| 초기화 | 허용됨 | `_initCameraPipeline()` 허용 |

**결과:** 촬영 완료 후 정상 상태로 복귀, 모든 작업 허용

---

### 케이스 6: 오류 발생 시

| 상태 필드 | 값 | 설명 |
|---------|-----|------|
| `sessionRunning` | `false` | 세션 중지됨 |
| `videoConnected` | `false` | 비디오 연결 끊김 |
| `hasFirstFrame` | `false` | 첫 프레임 없음 |
| `isPinkFallback` | `true` | fallback 상태 |
| `_cameraEngine.hasError` | `true` | 에러 상태 |
| `_isCameraHealthy` | `false` | 카메라 비정상 |
| `canUseCamera` | `false` | 카메라 사용 불가 |
| `_shouldShowPinkOverlay` | `true` | 오버레이 표시 |

**결과:** 오버레이가 표시되고, 사용자는 수동으로 재시작 가능

---

## 상태 전이 다이어그램

```
[Idle] (state == null)
  ↓ initializeCameraOnce()
[Initializing] (sessionRunning=false, hasFirstFrame=false)
  ↓ 첫 프레임 수신
[Ready] (sessionRunning=true, videoConnected=true, hasFirstFrame=true)
  ↓ 촬영 시작
[Capturing] (isCapturingPhoto=true)
  ↓ 촬영 완료
[Ready] (isCapturingPhoto=false)
  ↓ 에러 발생
[Error] (hasError=true 또는 세션 중지)
  ↓ 수동 재시작
[Initializing]
  ↓ 첫 프레임 수신
[Ready]
```

---

## 핵심 개선 사항

1. **Ready 상태에서는 절대 오버레이 표시 안 함**
   - `_shouldShowPinkOverlay`가 상태 머신 기반으로 동작
   - Ready 상태에서는 `false` 반환 보장

2. **촬영 중에는 모든 세션 조작 차단**
   - 레이아웃 동기화 차단
   - 세션 재시작 차단
   - 초기화 차단

3. **레이아웃 동기화 개선**
   - 촬영 중이 아닐 때만 동기화 허용
   - Flutter 레이아웃 변경 시 즉시 네이티브 동기화

4. **단일 진입점 보호**
   - `_initCameraPipeline()`: 촬영 중 초기화 차단
   - `_manualRestartCamera()`: 촬영 중 재시작 차단

