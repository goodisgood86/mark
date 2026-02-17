# 크래시 원인 분석 및 추가 방어 로직

## 현재 상황
- 사진 촬영 순간 `sessionRunning=false` → `videoConnected=false`로 급락
- 네이티브 카메라 세션이 중간에 죽음
- MethodChannel 호출은 보이지만 네이티브 크래시 로그는 Flutter에서 안 보임
- 실제 crash는 Swift / iOS AVFoundation 내부에서 발생

## 가능한 원인들

### 1. ✅ 중복 캡처 방지 (이미 추가됨)
- `isCapturingPhoto` 플래그로 중복 캡처 차단

### 2. ❌ AVCaptureSession 인터럽션 감지 없음 (중요!)
- `AVCaptureSessionWasInterruptedNotification` - 세션이 인터럽트되었을 때
- `AVCaptureSessionRuntimeErrorNotification` - 세션 런타임 에러 발생 시
- `AVCaptureSessionInterruptionEndedNotification` - 인터럽션 종료 시
- **현재 코드에 이 observer들이 없음!**

### 3. ❌ 라이프사이클 변경 중 캡처
- `onAppWillResignActive`에서 세션을 중지하는데, 이 시점에 캡처가 진행 중일 수 있음
- 촬영 중이면 세션 중지를 지연시켜야 함

### 4. ❌ 세션 상태 체크와 실제 호출 사이의 타이밍 문제
- 체크는 통과했지만 `capturePhotoWithSettings` 호출 직전에 세션이 죽음
- **체크와 호출 사이에 시간이 지나면서 상태가 변경됨**

### 5. ❌ iOS 시스템이 카메라를 강제로 해제
- 다른 앱이 카메라 사용
- 시스템 리소스 부족
- 메모리 부족으로 시스템이 카메라 해제

### 6. ❌ 세션 재구성과 캡처 사이의 race condition
- `beginConfiguration` ~ `commitConfiguration` 사이에 캡처 시도
- `isRunningOperationInProgress` 체크는 있지만, 타이밍 이슈 가능

### 7. ❌ Connection 상태 변경 중 캡처
- connection이 활성화되었다가 비활성화되는 순간 캡처 시도

## 추가 방어 로직 필요

### 1. AVCaptureSession 인터럽션 감지 추가
```swift
// 세션 인터럽션 감지
NotificationCenter.default.addObserver(
    self,
    selector: #selector(sessionWasInterrupted),
    name: .AVCaptureSessionWasInterrupted,
    object: session
)

NotificationCenter.default.addObserver(
    self,
    selector: #selector(sessionRuntimeError),
    name: .AVCaptureSessionRuntimeError,
    object: session
)

NotificationCenter.default.addObserver(
    self,
    selector: #selector(sessionInterruptionEnded),
    name: .AVCaptureSessionInterruptionEnded,
    object: session
)
```

### 2. 라이프사이클 변경 시 촬영 중이면 안전하게 처리
```swift
@objc private func onAppWillResignActive() {
    // 촬영 중이면 세션 중지를 지연
    if isCapturingPhoto {
        log("[Native] ⚠️ WillResignActive: Photo capture in progress, delaying session stop")
        // 촬영 완료 후 세션 중지하도록 플래그 설정
        return
    }
    // 촬영 중이 아니면 즉시 세션 중지
    sessionQueue.async { [weak self] in
        guard let self else { return }
        if self.session.isRunning {
            self.session.stopRunning()
        }
    }
}
```

### 3. 세션 상태 실시간 모니터링
- 촬영 시작 전 마지막 순간에 세션 상태 재확인
- `capturePhotoWithSettings` 호출 직전에 동기적으로 상태 확인

### 4. 세션 상태 변경 감지
- KVO로 `session.isRunning` 상태 변경 감지
- 상태가 변경되면 촬영 중이면 취소

### 5. 디바이스 연결 상태 모니터링
- `device.isConnected` 상태 변경 감지
- 연결이 끊어지면 촬영 취소

