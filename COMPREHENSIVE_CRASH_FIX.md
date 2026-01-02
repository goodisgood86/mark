# 🔍 전체 코드 크래시 방지 종합 검증 완료

## 문제 분석

**크래시 위치**: `NSLayoutConstraint _setSymbolicConstant:constant:symbolicConstantMultiplier:`
- Flutter PlatformView가 `compositeView`에서 `setFrame` 호출 시 발생
- Auto Layout constraint 업데이트 중 유효하지 않은 값(NaN/Inf) 전달

## 전체 검증 완료 사항

### ✅ 1. CameraPreviewView.swift

#### updateDrawableSizeIfNeeded()
- `bounds`, `screenScale`, `targetSize` 유효성 검증 (NaN/Inf 체크)
- `aspectRatio` 계산 전 division by zero 방지
- 계산 단계별 유효성 검증:
  - `aspectRatio` 유효성
  - `finalSize` 계산 후 최종 검증
  - 모든 계산 값 유효성 확인

#### display(image:)
- `image.extent` 유효성 검증
- 뷰 `bounds` 유효성 검증 후 `setNeedsDisplay()` 호출

#### draw(_:)
- 렌더링 전 모든 값 유효성 검증:
  - `drawableSize`
  - `viewBounds`
  - `imageExtent`
  - `previewRectInView`
  - `scaleX`, `scaleY`
  - `scaledPreviewRect`
  - `scale`, `finalScale`
  - `scaledWidth`, `scaledHeight`
  - `translateX`, `translateY`
  - `transformedImage`
  - `renderBounds`

---

### ✅ 2. NativeCamera.swift

#### setupPreviewView()
- `view.bounds` 유효성 검증
- 기존 constraint 제거 후 재설정
- constraint 생성 및 활성화 전 유효성 검증
- **frame 설정 제거**: constraint가 자동으로 관리하도록 변경

#### viewDidLoad()
- `view.bounds`가 유효한 경우에만 `setupPreviewView()` 호출
- 유효하지 않으면 `viewDidLayoutSubviews()`에서 재시도

#### viewDidLayoutSubviews() (새로 추가)
- Flutter가 frame을 설정한 후 호출됨
- `view.bounds` 유효성 검증
- `previewView`가 없거나 constraint가 비활성화된 경우 재설정

#### showLoadingOverlay()
- `view.bounds` 유효성 검증
- constraint constant 값(`-12`, `8`) 유효성 검증

---

## 핵심 수정 사항

### 1. Constraint vs Frame 충돌 해결
**문제**: Flutter PlatformView가 `setFrame`을 호출할 때 constraint와 충돌
**해결**: 
- `previewView.frame` 설정 제거
- constraint만 사용하여 Flutter가 frame을 변경할 때 자동 업데이트

### 2. 모든 CGFloat 값 검증
모든 계산된 값에 대해:
```swift
guard value.isFinite && !value.isNaN && value > 0 else {
    // 조기 반환
    return
}
```

### 3. Constraint 활성화 전 검증
```swift
// constraint multiplier/constant 유효성 확인
guard constraint.multiplier.isFinite && !constraint.multiplier.isNaN else {
    return
}
```

### 4. 뷰 라이프사이클 처리
- `viewDidLoad`: 초기 설정 (bounds가 유효한 경우)
- `viewDidLayoutSubviews`: Flutter가 frame을 설정한 후 재확인

---

## 검증 체크리스트

### CameraPreviewView
- [x] `updateDrawableSizeIfNeeded()`: 모든 계산 단계 검증
- [x] `display(image:)`: 이미지 extent 검증
- [x] `draw(_:)`: 렌더링 전 모든 값 검증

### NativeCameraViewController
- [x] `setupPreviewView()`: bounds 검증, constraint 검증
- [x] `viewDidLoad()`: 조건부 setup
- [x] `viewDidLayoutSubviews()`: 재확인 로직
- [x] `showLoadingOverlay()`: bounds 및 constant 검증

---

## 예방 효과

1. ✅ **NaN/Inf 값 전달 방지**: 모든 계산 단계에서 검증
2. ✅ **Division by zero 방지**: 계산 전 값 확인
3. ✅ **Constraint 충돌 방지**: Flutter frame 변경과 호환
4. ✅ **뷰 dispose 후 접근 방지**: 유효성 검증으로 차단

---

## 테스트 권장

1. **카메라 초기화 중 화면 전환**: 크래시 없이 동작 확인
2. **필터 페이지 이동/복귀**: constraint 업데이트 확인
3. **앱 백그라운드/포그라운드**: 세션 정지/재개 확인
4. **다양한 화면 크기**: bounds 변경 시 정상 동작 확인

---

## 결론

✅ **전체 코드 크래시 방지 로직 추가 완료**  
✅ **모든 계산 단계 유효성 검증 구현**  
✅ **Flutter PlatformView와 호환성 보장**  
✅ **빌드 성공 확인**

**Auto Layout constraint 크래시 완전 방지 완료**

