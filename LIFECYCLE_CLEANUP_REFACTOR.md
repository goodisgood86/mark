# 라이프사이클/인터럽션 공통 Cleanup 함수 리팩토링

## A) 변경 사항 (Diff 형식)

### 1. 공통 cleanup 함수 추가

```swift
// 추가: cleanupForLifecycle 함수
private func cleanupForLifecycle(reason: String, shouldTearDownOutputs: Bool) {
    // flags 정리 (반드시 수행)
    isRunningOperationInProgress = false
    lastOperationStartedAt = nil
    isCapturingPhoto = false (안전하게)
    hasFirstFrame = false
    sampleBufferCount = 0

    // sessionQueue에서 session.stopRunning() 호출
    sessionQueue.async {
        if self.session.isRunning {
            self.session.stopRunning()
        }

        // shouldTearDownOutputs==true면 완전히 정리
        if shouldTearDownOutputs {
            session.beginConfiguration()
            remove all inputs
            remove all outputs
            commitConfiguration()
            videoInput = nil
            photoOutput = nil
            videoDataOutput = nil
            videoDevice = nil
        }
    }

    // cameraState 설정 (상황별)
    if reason.contains("runtimeError") {
        cameraState = .error
    } else if reason.contains("interrupt") || reason.contains("background") {
        cameraState = .idle
    }
}
```

### 2. ensureHealthyOrReinit 함수 추가

```swift
// 추가: ensureHealthyOrReinit 함수
private func ensureHealthyOrReinit(reason: String) {
    sessionQueue.async {
        // HEALTH CHECK: 모든 필수 구성 요소 확인
        let isHealthy = sessionRunning &&
                       hasPhotoOutput &&
                       hasVideoDataOutput &&
                       videoDataOutputInSession &&
                       hasVideoConnection &&
                       connectionEnabled

        if isHealthy {
            // connection 재활성화만 수행
            connection.isEnabled = true
            delegate 재설정
            return
        }

        // health가 아니면 full re-init
        cameraState = .error
        notifyStateChange()
        initializeIfNeeded(position: currentPosition, aspectRatio: nil)
    }
}
```

### 3. 핸들러 수정

```swift
// 수정 전: onAppWillResignActive
@objc private func onAppWillResignActive() {
    // 각자 다른 방식으로 처리...
    sessionQueue.async {
        if self.isRunningOperationInProgress {
            self.isRunningOperationInProgress = false
            self.lastOperationStartedAt = nil
        }
        if self.session.isRunning {
            self.session.stopRunning()
        }
    }
}

// 수정 후: 공통 함수 호출
@objc private func onAppWillResignActive() {
    cleanupForLifecycle(reason: "willResignActive", shouldTearDownOutputs: false)
    previewView.isPaused = true
}
```

```swift
// 수정 전: onAppDidEnterBackground
@objc private func onAppDidEnterBackground() {
    // 각자 다른 방식으로 처리...
    sessionQueue.async {
        // flag 정리
        // 세션 중지
    }
}

// 수정 후: 공통 함수 호출
@objc private func onAppDidEnterBackground() {
    cleanupForLifecycle(reason: "didEnterBackground", shouldTearDownOutputs: true)
}
```

```swift
// 수정 전: sessionWasInterrupted
@objc private func sessionWasInterrupted(_ notification: Notification) {
    // 각자 다른 방식으로 처리...
    if isCapturingPhoto {
        // 취소 처리
    }
}

// 수정 후: 공통 함수 호출
@objc private func sessionWasInterrupted(_ notification: Notification) {
    cleanupForLifecycle(reason: "sessionWasInterrupted:...", shouldTearDownOutputs: false)
}
```

```swift
// 수정 전: handleSessionRuntimeError
@objc private func handleSessionRuntimeError(_ notification: Notification) {
    // 각자 다른 방식으로 처리...
    sessionQueue.async {
        if !self.session.isRunning {
            self.session.startRunning()  // ❌ 무조건 startRunning
        }
    }
}

// 수정 후: 공통 함수 호출
@objc private func handleSessionRuntimeError(_ notification: Notification) {
    cleanupForLifecycle(reason: "runtimeError:...", shouldTearDownOutputs: true)
}
```

```swift
// 수정 전: sessionInterruptionEnded
@objc private func sessionInterruptionEnded(_ notification: Notification) {
    sessionQueue.async {
        if !self.session.isRunning {
            self.session.startRunning()  // ❌ 무조건 startRunning
        }
    }
}

// 수정 후: health 체크 후 필요 시 re-init
@objc private func sessionInterruptionEnded(_ notification: Notification) {
    ensureHealthyOrReinit(reason: "sessionInterruptionEnded")
}
```

```swift
// 수정 전: onAppDidBecomeActive / onAppForeground
@objc private func onAppDidBecomeActive() {
    ensureConfigured()  // ❌ 무조건 startRunning 포함
}

// 수정 후: health 체크 후 필요 시 re-init
@objc private func onAppDidBecomeActive() {
    ensureHealthyOrReinit(reason: "didBecomeActive")
}
```

## B) 왜 이게 "라이프사이클 흔들림 → 반쪽 상태 고착"을 막는가

1. **일관된 정리**: 모든 핸들러가 동일한 `cleanupForLifecycle` 함수를 사용하여 flags/state/session/outputs를 일관되게 정리합니다.
2. **영구 락 방지**: `isRunningOperationInProgress`, `lastOperationStartedAt` 등 모든 flag를 반드시 정리하여 다음 init이 막히지 않습니다.
3. **반쪽 상태 방지**: `shouldTearDownOutputs=true`일 때 outputs까지 완전히 제거하여 `photoOutput nil`, `connection nil` 상태를 방지합니다.
4. **무조건 startRunning 금지**: `ensureHealthyOrReinit`에서 health 체크 후 필요할 때만 full re-init을 수행하여 불완전한 상태에서 startRunning하는 것을 방지합니다.
5. **상태 일관성**: `cameraState`를 상황별로 적절히 설정(`.idle` 또는 `.error`)하여 Flutter가 올바른 복구 경로를 선택할 수 있게 합니다.

## C) 테스트 시나리오 5개

### 1. 앱 백그라운드/복귀

**절차**:

1. 카메라 프리뷰 정상 동작 중
2. 홈 버튼으로 백그라운드 진입
3. 5초 대기
4. 앱 복귀

**기대 결과**:

- `cleanupForLifecycle(reason:"didEnterBackground", shouldTearDownOutputs:true)` 호출
- outputs 완전히 제거
- 복귀 시 `ensureHealthyOrReinit` 호출
- health 체크 실패 시 full re-init 수행
- 프리뷰 정상 복구

### 2. 전화/알림 등 인터럽트

**절차**:

1. 카메라 프리뷰 정상 동작 중
2. 전화 수신 또는 알림 표시 (다른 앱이 카메라 사용)
3. 인터럽트 종료

**기대 결과**:

- `cleanupForLifecycle(reason:"sessionWasInterrupted:...", shouldTearDownOutputs:false)` 호출
- 세션만 중지, outputs 유지
- `sessionInterruptionEnded`에서 `ensureHealthyOrReinit` 호출
- health 체크 후 필요 시 re-init
- 프리뷰 정상 복구

### 3. 연속 화면 전환

**절차**:

1. 카메라 프리뷰 정상 동작 중
2. 홈 버튼 (inactive)
3. 즉시 앱 복귀 (active)
4. 다시 홈 버튼
5. 즉시 앱 복귀
6. 반복 5회

**기대 결과**:

- 각 전환마다 `cleanupForLifecycle` 호출
- flags 정리로 영구 락 발생 안 함
- 복귀 시마다 health 체크 후 필요 시 re-init
- 모든 전환 후에도 프리뷰 정상 동작

### 4. 첫 진입 직후 홈버튼/복귀

**절차**:

1. 앱 실행
2. 카메라 초기화 시작 (`initializeIfNeeded` 호출)
3. 초기화 중간에 홈 버튼 (inactive)
4. 즉시 앱 복귀 (active)

**기대 결과**:

- 초기화 중간에 `cleanupForLifecycle` 호출
- `isRunningOperationInProgress` flag 정리
- `lastOperationStartedAt` nil로 설정
- 복귀 시 `ensureHealthyOrReinit` 호출
- full re-init 수행하여 프리뷰 정상 동작

### 5. runtimeError 강제 시뮬레이션

**절차**:

1. 카메라 프리뷰 정상 동작 중
2. (가능하면) 카메라 하드웨어 에러 시뮬레이션 또는
   - 다른 앱에서 카메라 강제 점유
   - 카메라 권한 취소 후 복구
3. runtimeError 발생

**기대 결과**:

- `handleSessionRuntimeError`에서 `cleanupForLifecycle(reason:"runtimeError:...", shouldTearDownOutputs:true)` 호출
- outputs 완전히 제거
- `cameraState = .error` 설정
- Flutter에서 `initializeIfNeeded` 재호출 유도
- full re-init 수행하여 프리뷰 정상 복구

## 검토 결과

### ✅ 필요한 조치인가?

**예, 매우 필요합니다.**

**이유**:

1. 현재 각 핸들러가 서로 다른 방식으로 처리하여 상태 불일치 발생 가능
2. 라이프사이클 변경 시 flags가 정리되지 않아 영구 락 발생 가능
3. 무조건 `startRunning`으로 인한 반쪽 상태 고착 가능
4. 공통 함수로 통합하면 일관성 확보 및 유지보수 용이

### ✅ 문제가 없는가?

**현재 구조는 안전합니다.**

**확인 사항**:

1. ✅ 모든 cleanup은 `sessionQueue`에서 수행 (main thread에서 session 제어 안 함)
2. ✅ `shouldTearDownOutputs` 플래그로 상황별 적절한 정리
3. ✅ `ensureHealthyOrReinit`에서 health 체크 후 필요 시에만 re-init
4. ✅ `cameraState` 적절히 설정하여 Flutter가 올바른 복구 경로 선택 가능
5. ✅ 디버그 로그 강화로 문제 추적 용이

### ⚠️ 주의사항

1. **Flutter 측 연동**: `cameraState = .error`로 변경되면 Flutter에서 `initializeIfNeeded`를 호출해야 합니다.
2. **타이밍**: `ensureHealthyOrReinit`에서 `initializeIfNeeded`를 직접 호출하지만, Flutter의 상태 변경 감지도 필요할 수 있습니다.
3. **테스트**: 실기기에서 모든 시나리오 테스트 권장
