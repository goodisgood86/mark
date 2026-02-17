# AVFoundation 크래시 방지 작업 완료 요약

## 작업 개요

AVFoundation의 `capturePhotoWithSettings` 호출 시 발생하는 Objective-C 예외 ("No active and enabled video connection")를 방지하기 위한 방어 코드와 디버그 로깅을 추가했습니다.

## 변경 사항

### 1. NativeCamera.swift - capturePhoto 함수 강화

**위치**: `ios/Runner/NativeCamera.swift:2053-2314`

#### 추가된 방어 로직:

1. **photoOutput video connection 상태 체크** (2267-2302 라인)
   - `photoOutput.connections`에서 `.video` 타입의 connection 존재 여부 확인
   - 활성화되고 활성 상태인 video connection 확인 (`isEnabled && isActive`)
   - 조건을 만족하지 않으면 촬영을 차단하고 상세 로그 출력

2. **상세 디버그 로그 추가**
   - 촬영 차단 시 원인별 로그 출력:
     - `[Petgram] ❌ capturePhoto blocked: no video connection found`
     - `[Petgram] ❌ capturePhoto blocked: no active and enabled video connection`
   - 촬영 성공 시 검증 통과 로그:
     - `[Petgram] ✅ capturePhoto validation passed: sessionRunning=..., connectionEnabled=..., connectionActive=..., devicePosition=..., deviceType=...`

#### 기존 가드 로직 유지:
- `isCapturingPhoto` 플래그 체크 (중복 촬영 방지)
- `session.isRunning` 체크 (세션 실행 중 확인)
- `photoOutput`이 세션에 포함되어 있는지 확인
- `videoDevice.isConnected` 체크

### 2. NativeCamera.swift - getState 함수 확장

**위치**: `ios/Runner/NativeCamera.swift:2482-2573`

#### 추가된 디버그 정보:

```swift
"photoOutputConnectionCount": Int
"photoOutputVideoConnectionCount": Int
"photoOutputHasActiveVideoConnection": Bool
"photoOutputConnections": [[String: Any]]  // 각 connection의 상세 정보
```

이 정보는 Flutter 쪽에서 촬영 가능 상태를 확인하는 데 사용됩니다.

### 3. Flutter 쪽 - home_page.dart 가드 추가

**위치**: `lib/pages/home_page.dart:2904-2923`

#### 추가된 가드 로직:

```dart
// 네이티브 카메라 사용 시 추가 검증
if (!_shouldUseMockCamera && _cameraEngine.isInitialized) {
  if (!_isCameraReady) {
    _addDebugLog('[takePhoto] blocked: native camera initialized but not ready');
    return;
  }
}
```

기존 가드:
- `_isProcessing` 체크 (이미 촬영 중인지)
- `_shouldUseMockCamera && !_isCameraReady` 체크 (카메라 준비 상태)

### 4. Flutter 쪽 - 디버그 오버레이 확장

**위치**: `lib/pages/home_page.dart:8322-8330`

#### 추가된 디스플레이 정보:

- `photoConn`: photoOutput connection 상태
  - `total`: 전체 connection 수
  - `video`: video connection 수
  - `active`: 활성화된 video connection 존재 여부 (녹색/빨간색 표시)

#### 디버그 정보 복사본에 추가:

**위치**: `lib/pages/home_page.dart:8182-8189`

```
--- Photo Output Connection (AVFoundation Crash Prevention) ---
photoOutputConnectionCount: ...
photoOutputVideoConnectionCount: ...
photoOutputHasActiveVideoConnection: ...
```

## 크래시 방지 메커니즘

### AVFoundation 예외 발생 조건

`AVCapturePhotoOutput.capturePhotoWithSettings`는 다음 조건에서 예외를 던집니다:
1. `session.isRunning == false`
2. `photoOutput.connections`에 `.video` 타입의 connection이 없음
3. video connection이 있지만 `isEnabled == false` 또는 `isActive == false`

### 방어 전략

1. **네이티브 레벨 사전 검증**
   - `capturePhotoWithSettings` 호출 전에 모든 조건을 직접 검증
   - 조건 불만족 시 예외를 던지지 않고 조용히 리턴
   - 실패 원인을 상세 로그로 기록

2. **Flutter 레벨 사전 차단**
   - 촬영 함수 호출 전에 `isCameraReady` 확인
   - 네이티브 촬영 요청 전에 상태 검증

3. **디버그 로깅**
   - 모든 차단 사유를 로그로 기록
   - 디버그 오버레이로 실시간 상태 확인 가능
   - 클립보드 복사 기능으로 문제 분석 용이

## 테스트 권장 사항

1. **정상 촬영**: 카메라 세션이 정상 실행 중일 때 촬영 가능
2. **세션 중지 후 촬영**: 앱이 백그라운드로 간 후 다시 돌아와서 촬영 시도 시 차단 확인
3. **연속 촬영**: 빠르게 여러 번 촬영 버튼을 눌렀을 때 중복 촬영 방지 확인
4. **디버그 오버레이**: 실기기에서 디버그 오버레이로 connection 상태 확인

## 주의 사항

- 모든 방어 로직은 예외를 방지하는 것이 목적입니다
- 촬영 실패 시 사용자에게 적절한 피드백을 제공해야 합니다 (현재는 조용히 무시)
- 디버그 오버레이는 개발/디버깅용이므로 프로덕션에서는 비활성화 권장

## 관련 파일

- `ios/Runner/NativeCamera.swift`: 네이티브 카메라 촬영 로직
- `lib/pages/home_page.dart`: Flutter 촬영 UI 및 가드 로직
- `lib/services/camera_engine.dart`: 카메라 엔진 상태 관리

## 다음 단계 (선택사항)

1. 촬영 실패 시 사용자 피드백 개선 (SnackBar 메시지)
2. 촬영 불가 상태 자동 복구 메커니즘 (재초기화 시도)
3. 크래시 로그 분석을 위한 자동 리포트 시스템

