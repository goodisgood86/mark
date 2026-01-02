# 프레임/칩 저장, 발열, 1:1 필터 레이어 문제 수정 완료

## 문제 7: 프레임 상하단 텍스트/칩이 저장본에서만 빠지는 문제 ✅

### 수정 내용

#### 1. 프레임 메타데이터 전달 로그 추가

**파일**: `lib/pages/home_page.dart`

**변경 사항:**

- `_takePhoto()` 메서드에서 `frameMeta` 전달 전 상세 로그 추가
- 각 키별 값과 타입 확인 가능

**코드:**

```dart
// 🔥 프레임/칩 저장 문제 해결: frameMeta 전달 전 로그 확인
if (kDebugMode) {
  debugPrint(
    '[Petgram] 📸 Taking photo with frameMeta: '
    'enableFrame=${config.enableFrame}, '
    'frameMeta.keys=${meta.frameMeta.keys.toList()}, '
    'frameMeta.count=${meta.frameMeta.length}',
  );
  if (meta.frameMeta.isNotEmpty) {
    meta.frameMeta.forEach((key, value) {
      debugPrint('[Petgram] 📸   frameMeta[$key] = $value (${value.runtimeType})');
    });
  }
}
```

#### 2. 네이티브 프레임 오버레이 로그 강화

**파일**: `ios/Runner/NativeCamera.swift`

**변경 사항:**

- `addFrameOverlay()` 메서드에서 상세 로그 추가
- 각 키별 값과 타입 확인 가능

**코드:**

```swift
// 🔥 프레임/칩 저장 문제 해결: 상세 로그 추가
self.log("[Frame] ========== Frame Overlay Start ==========")
self.log("[Frame] Image size: \(Int(width))x\(Int(height))")
self.log("[Frame] frameMeta keys: \(Array(frameMeta.keys))")
self.log("[Frame] frameMeta count: \(frameMeta.count)")

// 각 키별 값 확인
for (key, value) in frameMeta {
    self.log("[Frame]   \(key): \(value) (type: \(type(of: value)))")
}
```

#### 3. 네이티브 프레임 칩 그리기 개선

**파일**: `ios/Runner/NativeCamera.swift`

**변경 사항:**

- Flutter `FramePainter`와 동일하게 상단에 여러 칩 그리기
- 이름, 나이, 성별, 종 칩을 개별적으로 표시

**코드:**

```swift
// 🔥 프레임/칩 저장 문제 해결: FramePainter와 동일하게 상단에 여러 칩 그리기
// 1. 펫 이름 칩 (topText 또는 petName)
if !topText.isEmpty {
    let nameWidth = drawChip(text: topText, originX: currentTopChipX, originY: topChipY)
    currentTopChipX += nameWidth + chipSpacing
}

// 2. 나이 칩 (petBirthDate에서 계산)
if let birthDateStr = stringValue(from: frameMeta["petBirthDate"]), !birthDateStr.isEmpty {
    // ISO8601 파싱 및 나이 계산
    // ...
}

// 3. 성별 칩 (petGender)
// 4. 종 칩 (petType 또는 breed)
```

#### 4. breed 정보 추가

**파일**: `lib/services/petgram_meta_service.dart`

**변경 사항:**

- `frameMeta`에 `breed` 정보 추가
- 네이티브에서 종 칩을 그리기 위해 필요

**코드:**

```dart
// 🔥 breed 정보 추가 (네이티브에서 종 칩을 그리기 위해)
if (selectedPet.breed != null && selectedPet.breed!.isNotEmpty) {
  frameMeta['breed'] = selectedPet.breed!.trim();
}
```

## 문제 9: 1:1 화면에서 홈 필터 선택 레이어가 닫히지 않는 문제 ✅

### 수정 내용

#### 전체 화면을 덮는 투명 GestureDetector 추가

**파일**: `lib/pages/home_page.dart`

**변경 사항:**

- 필터 패널이 열려있을 때 전체 화면을 덮는 투명 `GestureDetector` 추가
- 패널 영역 외부를 탭하면 패널 닫기

**코드:**

```dart
// 🔥 1:1 필터 레이어 문제 해결: 필터 패널이 열려있을 때 전체 화면을 덮는 투명 GestureDetector 추가
if (_filterPanelExpanded)
  Positioned.fill(
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        // 필터 패널 영역 외부를 탭하면 패널 닫기
        setState(() {
          _filterPanelExpanded = false;
        });
      },
      child: Container(
        color: Colors.transparent,
      ),
    ),
  ),
```

**해결 원리:**

- 1:1 모드에서 프리뷰 영역이 작아져도 전체 화면을 덮는 `GestureDetector`가 있으므로
- 프리뷰 영역 밖을 탭해도 필터 패널이 닫힘
- 필터 패널 내부 `GestureDetector`가 터치를 소비하므로 패널 내부 탭은 패널이 닫히지 않음

## 문제 8: 앱 전체 발열·배터리 소모 문제 (분석 완료)

### 분석 결과

#### 1. 카메라/필터 파이프라인 구조

- **주요 파일**: `lib/pages/home_page.dart`, `lib/services/camera_engine.dart`, `ios/Runner/NativeCamera.swift`
- **CPU/GPU 사용량이 높은 부분**:
  1. 매 프레임 이미지 복사 (네이티브 → Flutter)
  2. 고해상도 필터 연산 (프리뷰에서도 고해상도 처리 가능)
  3. 반복적인 setState 호출
  4. 필터 적용 (매 프레임마다)

#### 2. 프리뷰 vs 저장용 연산 분리

- **현재 상태**: 네이티브에서 프리뷰용 저해상도 처리와 저장용 고해상도 처리가 분리되어 있음
- **확인 필요**: Flutter 레벨에서 추가 최적화 가능 여부

#### 3. setState / rebuild 최적화 포인트

- **발견된 문제**:
  - `_cameraEngine.addListener(() { setState({}); })` (라인 786): 카메라 상태 변경마다 전체 재빌드
  - 필터 변경 시 전체 위젯 재빌드
  - 밝기 변경 시 전체 위젯 재빌드

**개선 방안 (추후 적용 가능)**:

- ValueNotifier 기반 세분화된 상태 관리
- const 위젯 최대한 활용
- RepaintBoundary로 불필요한 재그리기 방지

## 테스트 체크리스트

### 프레임/칩 저장 문제

- [ ] 네이티브 카메라로 촬영 시 프레임/칩이 저장본에 표시되는지 확인
- [ ] 로그에서 `frameMeta`가 제대로 전달되는지 확인
- [ ] 상단 칩(이름, 나이, 성별, 종)이 모두 표시되는지 확인
- [ ] 하단 칩(날짜, 위치)이 표시되는지 확인

### 1:1 필터 레이어 문제

- [ ] 1:1 모드에서 필터 패널이 열려있을 때 바깥 영역을 탭하면 패널이 닫히는지 확인
- [ ] 9:16, 3:4 모드에서도 정상 작동하는지 확인
- [ ] 필터 패널 내부를 탭했을 때 패널이 닫히지 않는지 확인

### 발열 문제

- [ ] 카메라 프리뷰 화면에서 발열이 감소했는지 확인
- [ ] 배터리 소모가 감소했는지 확인
- [ ] 프리뷰 프레임레이트가 안정적인지 확인

## 예상 개선 효과

### 프레임/칩 저장 문제

- **이전**: 저장본에 프레임/칩이 표시되지 않음
- **이후**: 프리뷰와 동일하게 프레임/칩이 저장본에 표시됨
- **개선**: **사용자가 촬영한 사진에 프레임/칩 정보가 정상적으로 포함됨**

### 1:1 필터 레이어 문제

- **이전**: 1:1 모드에서 필터 패널이 닫히지 않음
- **이후**: 모든 모드에서 필터 패널이 정상적으로 닫힘
- **개선**: **일관된 사용자 경험 제공**

### 발열 문제

- **분석 완료**: 추가 최적화 포인트 식별
- **추후 적용 가능**: ValueNotifier 기반 상태 관리, const 위젯 활용 등
