# 프레임/칩 저장, 발열, 1:1 필터 레이어 문제 분석 및 수정 방안

## 문제 7: 프레임 상하단 텍스트/칩이 저장본에서만 빠지는 문제

### 1. 데이터 흐름 정리

#### a) 프리뷰 단계

**파일/클래스:**
- `lib/pages/home_page.dart`: `_buildFramePreviewOverlay()` (라인 4797)
- `lib/widgets/painters/frame_painter.dart`: `FramePainter` 클래스
- `lib/pages/home_page.dart`: `_buildCurrentPhotoMeta()` (라인 2473)

**흐름:**
```
1. Flutter 프리뷰:
   - _buildFramePreviewOverlay() → FramePainter로 프레임/칩 그리기
   - FramePainter.paint()에서 종/나이/위치 정보를 칩으로 렌더링
   - CustomPaint 위젯으로 프리뷰 위에 오버레이

2. 데이터 소스:
   - _petList: 펫 리스트
   - _selectedPetId: 선택된 펫 ID
   - _currentLocation: 현재 위치 정보
   - _frameEnabled: 프레임 활성화 여부
```

#### b) 촬영/저장 단계

**파일/클래스:**
- `lib/pages/home_page.dart`: `_takePhoto()` (라인 2023)
- `lib/pages/home_page.dart`: `_buildCurrentPhotoMeta()` (라인 2473)
- `lib/services/petgram_meta_service.dart`: `buildPetgramMeta()` (라인 11)
- `lib/services/camera_engine.dart`: `takePicture()` (라인 584)
- `lib/camera/native_camera_controller.dart`: `takePicture()` (라인 313)
- `ios/Runner/NativeCamera.swift`: `capturePhoto()` (라인 1120)
- `ios/Runner/NativeCamera.swift`: `addFrameOverlay()` (라인 1450)

**흐름:**
```
1. Flutter 촬영 요청:
   _takePhoto() 
   → _buildCurrentPhotoMeta() (frameMeta 생성)
   → CameraEngine.takePicture(frameMeta: meta.frameMeta)
   → NativeCameraController.takePicture(frameMeta: frameMeta)
   → MethodChannel: 'capture' with frameMeta

2. 네이티브 촬영 처리:
   NativeCamera.capturePhoto(frameMeta: frameMeta)
   → CaptureConfig에 frameMeta 저장
   → AVCapturePhotoOutput.capturePhoto()
   → photoOutput delegate에서 이미지 처리
   → addFrameOverlay(to: image, frameMeta: config.frameMeta)

3. Mock 카메라 경로:
   _takePhoto() (Mock 분기)
   → _addFrameOverlayToImage(image, meta.frameMeta)
   → FramePainter로 프레임 그리기 (Flutter에서 처리)
```

**메타 정보 전달 형태:**
- **형태**: `Map<String, dynamic>` (JSON 직렬화 가능)
- **전달 경로**: MethodChannel 인자로 전달
- **키**: `petId`, `petName`, `petType`, `petGender`, `petBirthDate`, `location` 등

### 2. 시뮬레이터 vs 실기기 차이점 분석

**시뮬레이터 (Mock 카메라):**
- Flutter에서 `_addFrameOverlayToImage()` 직접 호출
- `FramePainter`를 사용하여 프레임 그리기
- **정상 작동**: Flutter 레벨에서 완전히 처리

**실기기 (네이티브 카메라):**
- 네이티브 `addFrameOverlay()` 사용
- `frameMeta`를 MethodChannel로 전달
- **문제 가능성**: 
  - `frameMeta`가 비어있거나
  - 네이티브에서 `frameMeta` 키를 제대로 읽지 못하거나
  - 비동기 타이밍 문제

**확인 필요 사항:**
1. `frameMeta`가 실제로 네이티브에 전달되는지 로그 확인
2. 네이티브 `addFrameOverlay()`에서 `frameMeta` 키 읽기 확인
3. `enableFrame` 플래그가 올바르게 전달되는지 확인

### 3. 구조 개선 제안

#### 공통 데이터 모델 설계

```dart
// lib/models/frame_overlay_model.dart
class FrameOverlayModel {
  final bool enabled;
  final String? petId;
  final String? petName;
  final String? petType; // 'dog' or 'cat'
  final String? petGender;
  final String? petBirthDate; // ISO8601
  final String? location;
  final String? topLabel; // 상단 라벨 (직접 지정)
  final String? bottomLabel; // 하단 라벨 (직접 지정)
  
  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      if (petId != null) 'petId': petId,
      if (petName != null) 'petName': petName,
      if (petType != null) 'petType': petType,
      if (petGender != null) 'petGender': petGender,
      if (petBirthDate != null) 'petBirthDate': petBirthDate,
      if (location != null) 'location': location,
      if (topLabel != null) 'topLabel': topLabel,
      if (bottomLabel != null) 'bottomLabel': bottomLabel,
    };
  }
  
  factory FrameOverlayModel.fromMap(Map<String, dynamic> map) {
    return FrameOverlayModel(
      enabled: map['enabled'] as bool? ?? false,
      petId: map['petId'] as String?,
      petName: map['petName'] as String?,
      petType: map['petType'] as String?,
      petGender: map['petGender'] as String?,
      petBirthDate: map['petBirthDate'] as String?,
      location: map['location'] as String?,
      topLabel: map['topLabel'] as String?,
      bottomLabel: map['bottomLabel'] as String?,
    );
  }
}
```

## 문제 8: 앱 전체 발열·배터리 소모 문제

### 1. 카메라/필터 파이프라인 전체 구조

**주요 클래스/파일:**
- `lib/pages/home_page.dart`: 메인 카메라 UI
- `lib/services/camera_engine.dart`: 카메라 엔진 추상화
- `lib/camera/native_camera_controller.dart`: 네이티브 카메라 컨트롤러
- `ios/Runner/NativeCamera.swift`: iOS 네이티브 카메라 구현
- `ios/Runner/FilterPipeline.swift`: 필터 파이프라인

**CPU/GPU 사용량이 높은 부분:**
1. **매 프레임 이미지 복사**: 네이티브 → Flutter 이미지 전달
2. **고해상도 필터 연산**: 프리뷰에서도 고해상도 처리
3. **반복적인 setState 호출**: 카메라 상태 변경마다 전체 위젯 트리 재빌드
4. **필터 적용**: 매 프레임마다 필터 연산

### 2. 프리뷰 vs 저장용 연산 분리 여부

**현재 구조 확인 필요:**
- 프리뷰에서 저해상도 처리하는지
- 저장 시에만 고해상도 처리하는지

### 3. setState / rebuild 최적화 포인트

**발견된 setState 호출:**
- `_cameraEngine.addListener(() { setState({}); })` (라인 786): 카메라 상태 변경마다 전체 재빌드
- 필터 변경 시 전체 위젯 재빌드
- 밝기 변경 시 전체 위젯 재빌드

**개선 방안:**
- ValueNotifier 기반 세분화된 상태 관리
- const 위젯 최대한 활용
- RepaintBoundary로 불필요한 재그리기 방지

## 문제 9: 1:1 화면에서 홈 필터 선택 레이어가 닫히지 않는 문제

### 1. 필터 선택 레이어 구현 코드

**파일/위젯:**
- `lib/pages/home_page.dart`: `_buildFilterSelectionPanel()` (라인 5663)
- `lib/pages/home_page.dart`: `_buildCameraOverlayLayer()` (라인 2620)
- `lib/pages/home_page.dart`: `GestureDetector` (라인 2775)

**닫기 로직:**
- `GestureDetector.onTapDown` (라인 2775): 프리뷰 영역 탭 시 `_filterPanelExpanded = false`
- 필터 패널 내부 `GestureDetector` (라인 5664): 패널 영역 터치 소비

### 2. 1:1 모드에서만 닫히지 않는 원인 분석

**가능한 원인:**
- 1:1 모드에서 프리뷰 영역이 작아져서 hitTest 영역이 변경됨
- 필터 패널이 프리뷰 영역을 덮어버림
- Stack 레이아웃에서 z-index 문제

### 3. 수정 제안

**해결 방안:**
- 전체 화면을 덮는 투명 GestureDetector 추가
- 필터 패널 영역만 제외하고 나머지 영역 탭 시 닫기
- 1:1 모드에서도 동일한 hitTest 로직 적용

