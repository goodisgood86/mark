# 프리뷰 렌더링 파이프라인 구조 분석

## 현재 파이프라인

```
1. sampleBuffer 수신 (captureOutput)
   └─ videoQueue (비동기)
   └─ sampleBufferCount++

2. pixelBuffer 추출
   └─ CMSampleBufferGetImageBuffer(sampleBuffer)
   └─ 실패 시 return

3. 필터링 (FilterEngine.applyToPreview)
   └─ CIImage(cvPixelBuffer:)
   └─ applyCommonPipeline
   └─ extent 유효성 검증
   └─ invalid 시 return (display 호출 안 됨!)

4. display(image:) 호출
   └─ DispatchQueue.main.async
   └─ previewView.display(image:)
   └─ currentImage 설정
   └─ hasNewImage = true

5. draw(in:) 호출 (MTKView 자동)
   └─ isPaused=false일 때만
   └─ hasNewImage 체크
   └─ currentImage 읽기
   └─ currentDrawable 확인
   └─ ciContext.render()
   └─ renderSuccessCount++

6. 화면 표시
   └─ currentDrawable.present()
```

## 구조적 문제점

### 문제 1: 재초기화 시 previewView 리셋 부족
- 재초기화 시 previewView는 재사용됨
- 하지만 내부 상태(currentImage, displayCallCount 등)가 리셋되지 않음
- ciContext가 재초기화되지 않을 수 있음

### 문제 2: MTKView 초기화 상태 확인 부족
- delegate가 제대로 설정되었는지 확인 없음
- ciContext가 nil인 경우 복구 없음
- drawableSize가 0인 경우 복구 시도하지만 타이밍 문제 가능

### 문제 3: extent invalid 시 fallback 부족
- FilterEngine.applyToPreview가 invalid extent 반환 시 return
- display(image:)가 호출되지 않아 hasCurrentImage=false 유지
- 프리뷰가 영구적으로 표시되지 않음

### 문제 4: window hierarchy 문제
- previewView.window가 nil이면 렌더링은 되지만 화면에 표시되지 않음
- 로그만 출력하고 복구 시도 없음

### 문제 5: 재초기화 후 타이밍 문제
- 재초기화 완료 후 즉시 sampleBuffer가 올 수 있음
- 하지만 previewView의 drawableSize가 아직 설정되지 않았을 수 있음
- bounds가 아직 설정되지 않았을 수 있음

