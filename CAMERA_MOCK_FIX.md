# 실기기 Mock 카메라 문제 해결 방안

## 문제 분석

1. **현재 상황**:
   - 실기기에서 Mock 이미지가 표시됨
   - Flutter 쪽에서 "카메라 못 씀 → Mock 써라" 분기로 타고 있음
   - Swift 네이티브 카메라는 잘 돌아가고 있지만, Dart 쪽 상태가 `useMock = true` / `_canUseCamera = false`

2. **원인**:
   - 새로운 구조에서 PlatformView를 사용하지 않는데, 기존 코드가 여전히 viewId를 요구함
   - viewId가 없으면 초기화를 시도하지 않거나 실패하여 Mock으로 fallback
   - 초기화 전에 Mock으로 결정되는 로직이 있음

3. **새로운 구조**:
   - iOS에서는 PlatformView 사용 안 함
   - 카메라는 RootViewController의 cameraContainer에 직접 표시됨
   - viewId가 필요 없음

## 해결 방안

### 1. iOS 실기기에서 viewId 없이 바로 초기화
   - `CameraEngine.initialize()`에서 iOS는 viewId 체크 건너뛰기
   - 실기기에서는 네이티브 카메라를 우선 사용

### 2. Mock 감지 로직 수정
   - 초기화 중일 때는 Mock을 사용하지 않음
   - 실기기에서는 네이티브 카메라 실패 시에만 Mock 사용

### 3. 초기화 로직 단순화
   - iOS에서는 viewId 없이 바로 초기화 시도
   - 초기화 실패 시에만 Mock으로 fallback

## 수정 필요 파일

1. `lib/services/camera_engine.dart`:
   - iOS에서 viewId 체크 제거
   - 초기화 로직 단순화

2. `lib/pages/home_page.dart`:
   - 실기기에서 네이티브 카메라 우선 사용
   - Mock 감지 로직 개선

