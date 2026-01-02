# 배터리 소모 및 발열 문제 전체 분석

## 1. 전체 파이프라인 구조

### 1-1. 파일/클래스 목록

#### Flutter 레벨
- **`lib/pages/home_page.dart`**: 메인 카메라 UI, 상태 관리
- **`lib/services/camera_engine.dart`**: 카메라 엔진 추상화
- **`lib/camera/native_camera_controller.dart`**: 네이티브 카메라 컨트롤러 (MethodChannel)
- **`lib/camera/native_camera_preview.dart`**: 네이티브 카메라 프리뷰 위젯 (PlatformView)
- **`lib/widgets/painters/frame_painter.dart`**: 프레임/칩 오버레이 그리기

#### iOS 네이티브 레벨
- **`ios/Runner/NativeCamera.swift`**: 
  - `NativeCameraViewController`: 카메라 세션 관리
  - `FilterEngine`: 실시간 필터 적용
  - `PetFaceDetector`: 펫 얼굴 인식
- **`ios/Runner/NativeCameraPlugin.swift`**: Flutter MethodChannel 처리
- **`ios/Runner/NativeCameraView.swift`**: PlatformView 구현

### 1-2. 각 단계별 연산 요약

#### [A] 카메라 프리뷰 시작 시

**네이티브 (iOS):**
1. `AVCaptureSession` 생성 및 설정
2. `AVCaptureDevice` 선택 (720p 이하 포맷으로 제한 - 이미 최적화됨)
3. `AVCaptureVideoDataOutput` 생성:
   - 포맷: `kCVPixelFormatType_32BGRA`
   - 해상도: 720p 이하 (1280x720 또는 그 이하)
   - Delegate: `didOutput sampleBuffer` (비디오 큐에서 실행)
4. 세션 시작 → 프레임 수신 시작

**Flutter:**
1. `NativeCameraPreview` 위젯 생성 (PlatformView)
2. `NativeCameraController` 생성 및 초기화
3. `CameraEngine` 초기화
4. 프리뷰 표시

**현재 상태:**
- ✅ 프리뷰 해상도는 이미 720p로 제한됨 (라인 354-391)
- ⚠️ 하지만 매 프레임마다 필터 적용이 발생할 수 있음

#### [B] 프리뷰에 필터가 적용되는 방식

**현재 구조:**
```
AVCaptureVideoDataOutput 
  → didOutput sampleBuffer (videoQueue)
    → previewFrameSampleInterval로 샘플링 (기본값: 2)
      → filterEngine.render(pixelBuffer:) 
        → CIImage 생성 (CVPixelBuffer → CIImage)
        → CIColorMatrix 필터 적용 (GPU 가속)
        → previewView.display(image:) (메인 스레드)
```

**문제점:**
1. **매 샘플링마다 필터 적용**: 2프레임마다 1번 = 약 15fps로 필터 적용
2. **CIImage 변환**: 매번 CVPixelBuffer → CIImage 변환
3. **메인 스레드 업데이트**: 필터 적용 후 메인 스레드에서 프리뷰 업데이트

**코드 위치:**
- `ios/Runner/NativeCamera.swift:1786-1796`
- `ios/Runner/NativeCamera.swift:2942-2944` (FilterEngine.render)

#### [C] UI 오버레이(프레임/칩/아이콘)를 그리는 방식

**Flutter 레벨:**
1. `_buildFramePreviewOverlay()`: `FramePainter`로 프레임/칩 그리기
2. `CustomPaint` 위젯으로 프리뷰 위에 오버레이
3. `setState` 호출 시 전체 위젯 트리 재빌드

**문제점:**
- `_cameraEngine.addListener(() { setState({}); })` (라인 786-789)
- 카메라 상태 변경마다 전체 위젯 트리 재빌드
- 프레임/칩 오버레이는 `CustomPaint`이므로 repaint만 하면 되는데 전체 rebuild 발생

#### [D] 실제 촬영/저장 시

**네이티브 (iOS):**
1. `AVCapturePhotoOutput.capturePhoto()` 호출
2. 고해상도 이미지 캡처 (센서 해상도)
3. `didFinishProcessingPhoto` delegate:
   - CIImage 디코딩
   - 필터 적용 (FilterEngine)
   - Aspect Ratio 조정
   - 프레임 오버레이 합성
   - JPEG 인코딩
   - EXIF 추가
   - 갤러리 저장

**현재 상태:**
- ✅ 저장용은 고해상도 사용 (정상)
- ✅ 프리뷰와 저장 파이프라인이 분리되어 있음

## 2. 프리뷰 vs 저장 파이프라인 분리 여부

### 2-1. 현재 상태

**프리뷰:**
- 해상도: 720p 이하 (이미 최적화됨)
- 포맷: `kCVPixelFormatType_32BGRA`
- 필터: 실시간 적용 (2프레임마다 1번)

**저장:**
- 해상도: 센서 해상도 (고해상도)
- 포맷: JPEG (AVCapturePhotoOutput)
- 필터: 촬영 시에만 적용

**결론:**
- ✅ 프리뷰와 저장 파이프라인은 이미 분리되어 있음
- ⚠️ 하지만 프리뷰에서도 필터를 매 샘플링마다 적용하고 있음

### 2-2. 추가 최적화 가능성

**현재 문제:**
- 프리뷰에서도 필터를 매 샘플링마다 적용 (2프레임마다 1번)
- CIImage 변환이 매번 발생
- 메인 스레드에서 프리뷰 업데이트

**개선 방안:**
- 필터 변경 시에만 필터 적용
- 프리뷰는 원본만 표시하고, 필터는 촬영 시에만 적용
- 또는 필터 미리보기는 더 낮은 주기로만 업데이트

## 3. 프레임마다 setState / rebuild 과도 여부

### 3-1. setState 호출 위치

**발견된 문제:**
1. **`_cameraEngine.addListener(() { setState({}); })`** (라인 786-789)
   - 카메라 상태 변경마다 전체 위젯 트리 재빌드
   - `CameraEngine`의 모든 상태 변경이 전체 재빌드 유발

2. **필터 변경 시 `setState`** (라인 5749-5751)
   - 필터 선택 시 전체 위젯 재빌드

3. **밝기 변경 시 `setState`** (라인 1114)
   - 밝기 슬라이더 변경 시 전체 위젯 재빌드

**문제점:**
- 프레임/칩 오버레이는 `CustomPaint`이므로 repaint만 하면 되는데
- 전체 위젯 트리를 rebuild하고 있음
- 카메라 프리뷰는 PlatformView이므로 rebuild가 불필요함

### 3-2. 리팩토링 제안

**ValueNotifier 기반 세분화:**
- 카메라 상태: `ValueNotifier<CameraState>`
- 필터 상태: `ValueNotifier<String>`
- 밝기 상태: `ValueNotifier<double>`
- 프레임 오버레이: `CustomPaint`만 repaint

## 4. 필터/얼굴인식/오버레이 무거운 연산 위치

### 4-1. 현재 호출 주기

**필터 적용:**
- 위치: `ios/Runner/NativeCamera.swift:1790`
- 주기: `previewFrameSampleInterval` (기본값: 2) = 2프레임마다 1번
- 연산: CVPixelBuffer → CIImage → CIColorMatrix → 프리뷰 업데이트

**얼굴 인식:**
- 위치: `ios/Runner/NativeCamera.swift:1805`
- 주기: `petFaceDetectionSampleInterval` (기본값: 10) = 10프레임마다 1번
- 연산: Vision 프레임워크 사용 (비동기)

**프레임/칩 오버레이:**
- 위치: `lib/widgets/painters/frame_painter.dart`
- 주기: `setState` 호출 시마다 (카메라 상태 변경마다)
- 연산: Flutter CustomPaint로 그리기

### 4-2. 발견된 문제

1. **필터 적용이 너무 빈번함**
   - 2프레임마다 1번 = 약 15fps로 필터 적용
   - 사용자가 필터를 변경하지 않아도 계속 적용

2. **CIImage 변환이 매번 발생**
   - CVPixelBuffer → CIImage 변환 비용
   - 필터 적용 후 프리뷰 업데이트 비용

3. **프레임/칩 오버레이가 불필요하게 재그리기**
   - 카메라 상태 변경마다 전체 위젯 재빌드
   - 프레임/칩 데이터가 변경되지 않아도 재그리기

### 4-3. 최적화 방안

**필터 적용:**
- 필터 변경 시에만 필터 적용
- 프리뷰는 원본만 표시하고, 필터는 촬영 시에만 적용
- 또는 필터 미리보기는 더 낮은 주기(예: 500ms)로만 업데이트

**프레임/칩 오버레이:**
- 데이터 변경 시에만 repaint
- `RepaintBoundary`로 분리하여 불필요한 재그리기 방지

## 5. 네이티브 레벨 버퍼 복사/세션 관리

### 5-1. iOS 버퍼 복사 확인

**현재 구조:**
```
AVCaptureVideoDataOutput 
  → CVPixelBuffer (참조, 복사 없음) ✅
    → CIImage(cvPixelBuffer:) (참조, 복사 없음) ✅
      → CIColorMatrix 필터 (GPU 가속) ✅
        → previewView.display() (메인 스레드 전달)
```

**결론:**
- ✅ CVPixelBuffer는 참조만 사용 (복사 없음)
- ✅ CIImage도 참조만 사용 (복사 없음)
- ✅ 필터는 GPU 가속 (효율적)

**추가 확인 필요:**
- `previewView.display()`에서 내부적으로 복사가 발생하는지 확인 필요

### 5-2. 세션 관리

**현재 상태:**
- ✅ 세션은 화면 이동 시 정리됨 (`dispose()`)
- ✅ 세션은 하나만 유지됨

## 6. 구체적인 최적화 제안

### 6-1. 즉시 적용 가능한 최적화

1. **필터 적용 주기 증가**
   - `previewFrameSampleInterval` 기본값을 2 → 5로 증가
   - 또는 필터 변경 시에만 필터 적용

2. **setState 최소화**
   - `ValueNotifier` 기반 세분화된 상태 관리
   - `RepaintBoundary`로 프레임/칩 오버레이 분리

3. **프레임/칩 오버레이 최적화**
   - 데이터 변경 시에만 repaint
   - `const` 위젯 최대한 활용

### 6-2. 구조적 개선

1. **프리뷰 필터 비활성화 옵션**
   - 프리뷰는 원본만 표시
   - 필터는 촬영 시에만 적용

2. **필터 미리보기 주기 제한**
   - 필터 변경 시에만 미리보기 업데이트
   - 또는 500ms 주기로만 업데이트

