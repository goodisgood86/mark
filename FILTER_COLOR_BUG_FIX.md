# FilterPage 색상 버그 수정 요약

## 발견된 문제

1. **필터 적용 순서 불일치**
   - HomePage (카메라 프리뷰): 펫톤 → 필터 → 밝기
   - FilterPage (네이티브 파이프라인): 필터 → 밝기/대비 → 선명도 → 펫톤
   - **순서 차이로 인해 최종 색상 결과가 달라짐**

2. **밝기/대비 적용 방식 차이**
   - HomePage: 매트릭스 방식 (ColorMatrix)
   - FilterPage: CIColorControls 필터 방식
   - **다른 방식으로 인해 색상 계산 결과가 달라짐**

## 수정 내용

### 1. 필터 적용 순서 통일 (`ios/Runner/FilterPipeline.swift`)

**변경 전:**
```swift
// 3-1. 필터 (filterKey)
// 3-2. 밝기/대비 (editBrightness, editContrast)
// 3-3. 선명도 (editSharpness)
// 3-4. 펫톤 (petTonePreset)
```

**변경 후 (HomePage와 동일한 순서):**
```swift
// 3-1. 펫톤 (petTonePreset) - HomePage와 동일한 순서
// 3-2. 필터 (filterKey) - HomePage와 동일한 순서
// 3-3. 밝기 (editBrightness) - 매트릭스 방식으로 적용
// 3-4. 대비 (editContrast) - 매트릭스 방식으로 적용
// 3-5. 선명도 (editSharpness) - 별도 필터 (순서는 마지막)
```

### 2. 밝기/대비를 매트릭스 방식으로 변경

**변경 전:**
```swift
// CIColorControls 필터 사용
private static func applyBrightnessContrast(_ image: CIImage, brightness: Double, contrast: Double) -> CIImage {
    // CIColorControls 필터로 밝기/대비 적용
}
```

**변경 후:**
```swift
// 매트릭스 방식으로 변경 (HomePage와 동일)
private static func applyBrightnessMatrix(_ image: CIImage, brightness: Double) -> CIImage {
    // HomePage: (_editBrightness / 50.0) * 40.0
    let b = (brightness / 50.0) * 40.0
    let brightnessMatrix: [Double] = [
        1, 0, 0, 0, b,
        0, 1, 0, 0, b,
        0, 0, 1, 0, b,
        0, 0, 0, 1, 0,
    ]
    return applyColorMatrix(image, matrix: brightnessMatrix)
}

private static func applyContrastMatrix(_ image: CIImage, contrast: Double) -> CIImage {
    // HomePage: 1.0 + (_editContrast / 50.0) * 0.4
    let c = 1.0 + (contrast / 50.0) * 0.4
    let contrastMatrix: [Double] = [
        c, 0, 0, 0, 0,
        0, c, 0, 0, 0,
        0, 0, c, 0, 0,
        0, 0, 0, 1, 0,
    ]
    return applyColorMatrix(image, matrix: contrastMatrix)
}
```

### 3. 디버그 로그 추가

`applyColorMatrix` 함수에 bias 값 디버그 로그 추가:
```swift
#if DEBUG
// 디버그: bias 값 확인 (0이 아닌 경우만 로그)
if matrix[4] != 0.0 || matrix[9] != 0.0 || matrix[14] != 0.0 || matrix[19] != 0.0 {
    print("[FilterPipeline] 🎨 applyColorMatrix bias values: R=\(matrix[4]), G=\(matrix[9]), B=\(matrix[14]), A=\(matrix[19])")
    print("[FilterPipeline] 🎨 applyColorMatrix scaled bias: R=\(matrix[4] * biasScale), G=\(matrix[9] * biasScale), B=\(matrix[14] * biasScale), A=\(matrix[19] * biasScale)")
}
#endif
```

## 검증 방법

1. **동일한 사진으로 테스트**
   - HomePage 라이브 프리뷰에서 필터 적용 후 느낌 확인
   - 같은 사진을 FilterPage로 가져와 프리뷰에서 필터 적용
   - FilterPage에서 저장 후, 아이폰 갤러리에서 결과 확인

2. **필터 강도 3단계 확인**
   - 필터 강도 0%, 50%, 100%에서 모두 색이 비정상적으로 튀지 않는지 확인
   - 최소 하나의 "identity 필터" 또는 "basic_none" 상태에서 원본과 완전히 같은 색이 나오는지 확인

3. **다양한 필터 테스트**
   - pink_soft, pink_blossom 등 다양한 필터에서 색상이 정상적으로 나오는지 확인
   - 펫톤 프로파일 적용 시에도 색상이 정상인지 확인

## 주의사항

- 카메라 비율/해상도/네이티브 캡처/EXIF/DB 로직은 변경하지 않았음
- 필터 색 계산 부분만 수정함
- bias 값 스케일링 (1/255)은 이미 올바르게 적용되어 있었음

