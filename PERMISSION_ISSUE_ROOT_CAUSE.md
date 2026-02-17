# 권한 설정 문제 근본 원인 분석

## 문제 증상
1. 권한을 변경하지 않으면: 다이얼로그가 잘 떠있고 문제 없음
2. 권한을 변경하고 돌아오면: 앱이 멈춤 (SIGKILL), 다이얼로그가 안 뜸

## 근본 원인

### 1. 네이티브 카메라의 UIApplication 라이프사이클 구독
- `NativeCameraViewController`가 앱 시작 시 `UIApplication.willResignActiveNotification`과 `UIApplication.didEnterBackgroundNotification`을 구독
- 설정으로 이동할 때 이 이벤트들이 발생
- 각각 `applyLifecycleTransition("stop")`과 `applyLifecycleTransition("teardown")`을 호출하여 카메라 세션을 정리

### 2. 충돌 시점
```
타임라인:
1. 사용자가 "설정으로 이동" 버튼 클릭
   → _returnedFromSettings = true 설정
   → 다이얼로그 닫기
   → openSettings() 호출

2. 설정 앱으로 이동
   → iOS가 willResignActive 이벤트 발생
   → 네이티브 카메라가 applyLifecycleTransition("stop") 호출
   → 카메라 세션 정리 시작

3. didEnterBackground 이벤트 발생
   → 네이티브 카메라가 applyLifecycleTransition("teardown") 호출
   → 카메라 세션 완전 정리

4. 사용자가 설정에서 권한 변경
   → iOS가 즉시 권한 변경을 감지
   → 하지만 앱은 백그라운드에 있고, 네이티브 카메라는 cleanup 중

5. 사용자가 앱으로 복귀
   → iOS가 didBecomeActive → resumed 상태로 전환
   → Flutter의 didChangeAppLifecycleState(resumed) 호출
   → 현재 코드: 다이얼로그만 닫고 _hasCheckedPermissions = false 설정
   → 하지만 네이티브 카메라는 아직 cleanup 중이거나 완료된 상태

6. 문제 발생
   - 만약 어딘가에서 checkCameraPermission을 호출하면
   - 네이티브 카메라가 cleanup 중인데 권한 체크 시도
   - 충돌 발생 → SIGKILL
```

### 3. 왜 권한을 변경하지 않으면 문제가 없나?
- 권한 변경 없음:
  - iOS가 추가 알림 없음
  - 네이티브 카메라가 정상적으로 cleanup 완료
  - 복귀 시 네이티브 카메라가 정상 상태
  
- 권한 변경 있음:
  - iOS가 즉시 권한 변경 알림
  - 네이티브 카메라가 cleanup 중인데 상태가 변경됨
  - 네이티브 메서드 호출 시 충돌 발생

## 해결 방안

### 핵심 원칙
**설정에서 복귀할 때는 네이티브 카메라와 전혀 상호작용하지 않아야 함**

### 구체적 해결책
1. **네이티브 권한 체크 완전 제거**: 설정에서 복귀할 때 `checkCameraPermission` 같은 네이티브 메서드를 절대 호출하지 않음
2. **다이얼로그만 처리**: 다이얼로그를 닫고, 권한 상태는 실제 카메라 사용 시에만 확인
3. **플래그 관리**: `_hasCheckedPermissions = false`로 설정하여 다음 카메라 사용 시 권한을 다시 체크하도록 함

### 현재 코드의 문제점
- `resumed` 상태에서 `_returnedFromSettings`가 true일 때 다이얼로그만 닫고 있음 (올바름)
- 하지만 어딘가에서 여전히 네이티브 메서드를 호출할 가능성이 있음
- 또는 네이티브 카메라가 자체적으로 권한 변경을 감지하여 반응할 수 있음

### 추가 확인 필요 사항
1. 네이티브 카메라가 권한 변경을 감지하는지 확인
2. 다른 곳에서 checkCameraPermission을 호출하는지 확인
3. 네이티브 카메라의 cleanup이 완전히 완료될 때까지 기다리는지 확인

## 추가 발견: 네이티브 카메라의 자동 재초기화

### 문제
`onAppDidBecomeActive()`에서:
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
    // ...
    self.initializeIfNeeded(position: self.currentPosition, aspectRatio: nil)
}
```

**설정에서 권한을 변경하고 돌아올 때:**
1. `didBecomeActive` 이벤트 발생
2. 0.2초 후 `initializeIfNeeded()` 자동 호출
3. 하지만 권한이 변경되어서 카메라 세션이 불안정한 상태
4. 또는 cleanup이 완료되지 않은 상태에서 재초기화 시도
5. 충돌 발생 → SIGKILL

### 해결 방안
네이티브 카메라의 `onAppDidBecomeActive()`에서 자동 재초기화를 시도하기 전에 권한 상태를 확인해야 함.

또는 더 나은 방법:
- **권한이 거부된 상태에서는 재초기화를 시도하지 않음**
- Flutter에서 명시적으로 요청할 때만 카메라를 초기화하도록 변경

### 임시 해결책 (Flutter 측)
네이티브 코드를 수정할 수 없다면:
- 설정에서 복귀할 때 네이티브 카메라와 전혀 상호작용하지 않음 (이미 구현됨)
- 하지만 네이티브 카메라가 자체적으로 재초기화를 시도하므로 여전히 문제 발생 가능

### 근본 해결책
네이티브 코드 수정 필요:
- `onAppDidBecomeActive()`에서 `initializeIfNeeded()`를 호출하기 전에 권한 상태 확인
- 권한이 거부/제한된 경우 재초기화 시도하지 않음
- 또는 `_returnedFromSettings` 플래그를 네이티브에 전달하여 자동 재초기화를 건너뛰도록 함
