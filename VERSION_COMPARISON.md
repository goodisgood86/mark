# 버전 비교: 기존 배포 vs 현재 버전

## 버전 정보
- **기존 배포 버전**: 1.0.0+4 (이전)
- **현재 버전**: 1.0.0+4 (수정됨)

---

## 🔧 주요 변경 사항

### 1. 프리뷰 비율 문제 해결 ✅

#### 기존 버전 (문제)
```dart
// AspectRatio 안에 SizedBox가 있어서 비율 충돌
AspectRatio(
  aspectRatio: cameraAspectRatio,
  child: SizedBox(
    width: actualPreviewW,
    height: actualPreviewW / cameraAspectRatio,
    child: Stack(...)
  )
)
```
- `SizedBox`가 명시적 크기를 지정하여 `AspectRatio`와 충돌
- 프리뷰 비율 왜곡 발생

#### 현재 버전 (수정)
```dart
// SizedBox 제거, AspectRatio만 사용
Center(
  child: AspectRatio(
    aspectRatio: cameraAspectRatio, // 실제 카메라 비율
    child: Stack(...)
  )
)
```
- `SizedBox` 제거로 `AspectRatio`가 정상 작동
- 실제 카메라 비율 유지, 왜곡 없음

---

### 2. 초점 표시 개선 ✅

#### 기존 버전
- 초록색 체크마크 표시
- 오버레이 영역 클릭 시 초점 설정 안 됨

#### 현재 버전
- 일반 동그라미 표시 (애니메이션 200ms)
- 오버레이 영역 클릭 시에도 프리뷰 영역 내에 클램프하여 표시
```dart
final double clampedAdjustedY = adjustedY.clamp(
  overlayTop,
  previewH - overlayBottom,
);
```

---

### 3. 핀치 줌 배율 조정 개선 ✅

#### 기존 버전
- 1단위로 반올림 (예: 1.23 → 1.0, 1.67 → 2.0)
- 배율이 1.0 이상 변경되었을 때만 UI 업데이트

#### 현재 버전
- 0.1단위로 반올림 (예: 1.23 → 1.2, 1.67 → 1.7)
- 배율이 0.1 이상 변경되었을 때만 UI 업데이트
```dart
final double roundedZoom = (newZoom * 10).round() / 10.0;
final bool ratioChanged = (_selectedZoomRatio - roundedZoom).abs() >= 0.1;
```

---

### 4. 줌 범위 동적 처리 ✅

#### 기존 버전
- 최대 줌: 고정 2.0
- 최소 줌: 고정 1.0 또는 0.5 (목업)
- 목업 모드 최대 줌: 2.0

#### 현재 버전
- 카메라 초기화 시 `getMinZoomLevel()`, `getMaxZoomLevel()` 저장
- 실제 카메라 지원 범위에 맞춰 동적 처리
- 목업 모드 최대 줌: 5.0 (테스트용)
```dart
_minZoomLevel = await controller.getMinZoomLevel();
_maxZoomLevel = await controller.getMaxZoomLevel();
```

---

### 5. 배율 선택 메뉴 개선 ✅

#### 기존 버전
- 고정 옵션: 0.8x, 1.0x, 1.5x, 2.0x
- 배율 선택 시 `_baseZoomLevel` 업데이트 안 됨
- 목업 모드에서 UI 줌 스케일 업데이트 안 됨

#### 현재 버전
- 카메라 지원에 따라 동적 생성
  - 최저값 (1.0 미만인 경우)
  - 1.0, 1.5, 2.0 (지원 범위 내에서만)
  - 최대값 (2.0 초과인 경우)
- 배율 선택 시 모든 변수 업데이트:
  - `_currentZoomLevel`
  - `_baseZoomLevel` (핀치 줌 기준값)
  - `_selectedZoomRatio`
  - `_uiZoomScale` (목업 모드)
  - `_baseZoomScale` (목업 모드)

---

### 6. 핀치 줌 부드러움 개선 ✅

#### 기존 버전
- 스케일 변화량 100% 반응
- 급격한 줌 변화

#### 현재 버전
- 스케일 변화량 70% 반응 (더 부드러움)
```dart
final double smoothedScale = 1.0 + (details.scale - 1.0) * 0.7;
```

---

### 7. 하단 프레임 문구 위치 조정 ✅

#### 기존 버전
- `FramePreviewPainter`: `bottomBarSpace = 80.0 + 20.0`
- `FramePainter`: `proportionalBottomSpace = size.height * 0.1`

#### 현재 버전
- `FramePreviewPainter`: `bottomBarSpace = 80.0 + 10.0` (10px 아래로)
- `FramePainter`: `proportionalBottomSpace = size.height * 0.08` (2% 아래로)

---

## 🐛 버그 수정

### 1. "Cannot hit test a render box with no size" 오류
- **원인**: `FittedBox`와 `AspectRatio` 조합으로 크기 계산 충돌
- **해결**: `FittedBox` 제거, `Center` + `AspectRatio`만 사용

### 2. 배율 선택 메뉴 동작 안 함
- **원인**: 목업 모드에서 `_uiZoomScale` 업데이트 안 됨
- **해결**: 목업 모드에서도 모든 줌 변수 업데이트

### 3. 2배 이상 줌 고정 문제
- **원인**: 목업 모드 최대 줌이 2.0으로 제한
- **해결**: 목업 모드 최대 줌을 5.0으로 확대

---

## 📊 성능 및 안정성

### 개선 사항
- ✅ 프리뷰 비율 왜곡 제거
- ✅ 초점 표시 위치 정확도 향상
- ✅ 줌 조작 부드러움 개선
- ✅ 카메라 지원 범위에 맞춘 동적 처리
- ✅ Hit test 오류 해결

### 유지 사항
- ✅ 화질 저하 없음 (JPEG quality 100)
- ✅ 원본 해상도 유지
- ✅ 카메라 왜곡 없음
- ✅ 전체 동작 안정성 유지

---

## 🎯 사용자 경험 개선

1. **프리뷰 비율**: 실제 카메라 비율 정확히 반영
2. **초점 표시**: 더 직관적인 동그라미 표시
3. **줌 조작**: 더 부드럽고 정확한 배율 조정
4. **배율 선택**: 카메라 지원에 맞춘 동적 옵션
5. **하단 프레임**: 문구 위치 개선

---

## ⚠️ 주의 사항

### 테스트 필요 항목
1. 실제 기기에서 프리뷰 비율 확인
2. 다양한 카메라에서 줌 범위 테스트
3. 초점 표시 위치 정확도 확인
4. 핀치 줌 부드러움 체감 확인

---

## 📝 요약

현재 버전은 기존 배포 버전 대비:
- **프리뷰 비율 문제 해결** (가장 중요)
- **초점 표시 개선**
- **줌 기능 전반 개선** (배율, 범위, 부드러움)
- **버그 수정** (hit test, 배율 선택, 줌 고정)

모든 변경 사항은 **하위 호환성 유지**하며, 기존 기능은 그대로 동작합니다.

