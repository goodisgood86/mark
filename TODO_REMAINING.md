# 남은 TODO 항목 요약

## ✅ 완료된 항목

1. **EXIF 메타데이터 통합** ✅
   - `buildExifTag()` 구현 완료
   - `addExifUserComment()` 구현 완료
   - 촬영 시 EXIF 메타데이터 추가 로직 통합

2. **frameMeta 전달** ✅
   - FilterConfig에 frameMeta 필드 추가
   - takePhoto 호출 시 frameMeta 전달 구현
   - EXIF UserComment에 frameMeta 포함

## ⏳ 진행 중/대기 중인 항목

### 1. Texture ID 생성 및 프리뷰 렌더링
**상태**: pending
**설명**: 현재는 기존 CameraPreviewView 방식을 사용 중입니다. Flutter Texture 위젯을 사용하려면:
- `FlutterTextureRegistry`를 사용하여 texture ID 생성
- `AVCaptureVideoDataOutput`의 샘플 버퍼를 Flutter로 전달
- `Texture(textureId: ...)` 위젯으로 프리뷰 표시

**현재 상태**: 
- `PetgramCameraEngine`에서 `CameraPreviewView`를 직접 사용 중
- 향후 Texture 방식으로 전환 가능하도록 구조 준비 필요

**참고**: 현재 구조에서도 프리뷰가 작동하지만, Flutter Texture 방식이 더 통합적입니다.

### 2. 썸네일 생성
**상태**: pending
**설명**: 촬영한 사진의 썸네일을 생성하여 `PhotoResult.thumbnailPath`에 저장

**구현 방법**:
```swift
// 썸네일 생성 (예: 200x200)
let thumbnailSize = CGSize(width: 200, height: 200)
// CIImage를 썸네일 크기로 리사이즈
// 임시 파일로 저장
```

**현재 상태**: `thumbnailPath: nil`로 반환 중

### 3. 기존 카메라 로직 정리 (cleanup_old)
**상태**: pending
**설명**: `camera_engine.dart`에서 불필요한 상태 계산 로직 제거

**작업 내용**:
- `_nativeInit`, `_isReady` 등의 플래그 기반 로직 제거
- 네이티브 디버그 상태만 사용하도록 정리
- `PetgramCameraShell` 사용으로 전환 완료 후 기존 코드 제거

## 우선순위

1. **썸네일 생성** (중간 우선순위)
   - 기능적으로 필요하며 구현이 비교적 간단

2. **Texture ID 생성** (낮은 우선순위)
   - 현재 방식으로도 작동하므로, 나중에 개선할 수 있음

3. **기존 코드 정리** (낮은 우선순위)
   - 새 구조가 안정화된 후 진행

## 다음 단계

1. 썸네일 생성 기능 구현
2. 실제 디바이스에서 통합 테스트
3. 필요한 경우 Texture 방식으로 전환 검토

