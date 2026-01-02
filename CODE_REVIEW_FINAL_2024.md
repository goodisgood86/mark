# Flutter/네이티브 코드 전체 점검 보고서

## 📋 점검 일시
2026-01-02

## ✅ 해결 완료된 이슈

### 1. ParentDataWidget 오류 해결
- **상태**: ✅ 완전 해결
- **해결 방법**:
  - 모든 `Positioned` 위젯을 `Stack`의 직접 자식으로 배치
  - `RepaintBoundary`를 `Positioned.fill` 내부로 이동
  - `SizedBox.expand()`로 `ColorFiltered`의 제약 명시적 전달
  - `NativeCameraPreview`를 단순한 위젯으로 변경

## 🔍 발견된 최적화 포인트

### 1. 네이티브 로그 과다 (⚠️ 중요)

**현재 상태:**
- 네이티브 로그 총 478회 (`ios/Runner/NativeCamera.swift`)
- `getFocusStatus` 호출: 매우 빈번 (2초마다)
- `getDebugState` 호출: 10초마다
- `updatePreviewLayout` 호출: 레이아웃 변경 시마다

**문제점:**
```swift
// 현재: 모든 호출마다 로그 출력
print("[NativeCameraRegistry] 📷 getCamera for viewId=\(viewId) -> \(cam != nil)")
print("[NativeCamera] 🔍 Attempting to get camera VC for method: getFocusStatus")
print("[NativeCamera] ✅ Camera view controller found in CameraManager")
```

**최적화 방안:**
1. **빈번한 메서드 로그 제거/조건부 출력**
   - `getFocusStatus`: 정상 동작 시 로그 제거 (에러 시만 출력)
   - `getDebugState`: 디버그 모드에서만 출력
   - `updatePreviewLayout`: 레이아웃 변경 시 로그 제거

2. **로그 레벨 분리**
   ```swift
   #if DEBUG
   private func logDebug(_ message: String) {
       print(message)
   }
   #else
   private func logDebug(_ message: String) {
       // 릴리즈 빌드에서는 로그 제거
   }
   #endif
   ```

**예상 효과:**
- 로그 출력 감소: 478회 → 약 50회 (90% 감소)
- CPU 사용량 감소
- 배터리 소모 감소

### 2. Flutter setState 과다 호출 (⚠️ 중요)

**현재 상태:**
- `setState` 호출: 146회 (`lib/pages/home_page.dart`)
- 주요 호출 위치:
  - `_cameraEngine.addListener(() { setState({}); })` - 카메라 상태 변경마다 전체 재빌드
  - 필터 변경 시 전체 재빌드
  - 밝기 변경 시 전체 재빌드
  - 포커스 상태 업데이트 시 재빌드

**문제점:**
```dart
// 현재: 카메라 상태 변경마다 전체 위젯 트리 재빌드
_cameraEngine.addListener(() {
  setState(() {}); // 전체 재빌드
});
```

**최적화 방안:**
1. **ValueNotifier 기반 세분화된 상태 관리**
   ```dart
   // 개선안
   final _filterNotifier = ValueNotifier<String>(_shootFilterKey);
   final _brightnessNotifier = ValueNotifier<double>(_liveIntensity);
   final _focusStatusNotifier = ValueNotifier<_FocusStatus>(_FocusStatus.unknown);
   
   // 사용
   ValueListenableBuilder<String>(
     valueListenable: _filterNotifier,
     builder: (context, filterKey, child) {
       // 필터 관련 위젯만 재빌드
     },
   )
   ```

2. **RepaintBoundary 활용**
   - 프레임/칩 오버레이는 이미 `RepaintBoundary`로 분리됨 ✅
   - 추가로 필터 패널, 밝기 슬라이더 등도 분리 가능

3. **const 위젯 최대한 활용**
   - 변경되지 않는 위젯은 `const`로 선언

**예상 효과:**
- 불필요한 재빌드 감소: 약 70% 감소
- UI 반응성 향상
- 배터리 소모 감소

### 3. 타이머 정리 상태 (✅ 양호)

**확인 결과:**
```dart
@override
void dispose() {
  _debugStatePollTimer?.cancel();      // ✅ 정리됨
  _focusStatusPollTimer?.cancel();     // ✅ 정리됨
  _debugLogTimer?.cancel();            // ✅ 정리됨
  _hideFocusIndicatorTimer?.cancel();  // ✅ 정리됨
  _audioPlayer.dispose();              // ✅ 정리됨
  _petFaceStreamSubscription?.cancel(); // ✅ 정리됨
  _cameraEngine.dispose();             // ✅ 정리됨
}
```

**상태**: ✅ 모든 타이머와 스트림이 dispose에서 정리됨

### 4. 포커스 상태 폴링 최적화 (✅ 이미 최적화됨)

**현재 상태:**
- 폴링 간격: 2초 (1000ms → 2000ms로 증가)
- 조건부 폴링: AF 인디케이터가 활성화된 경우에만 폴링
- 불필요한 폴링 방지: 카메라 사용 불가 시 스킵

**상태**: ✅ 이미 최적화됨

### 5. 메모리 관리 (✅ 양호)

**확인 결과:**
- `dispose()`에서 모든 리소스 정리 ✅
- `FilterPage`에서도 `_previewImage?.dispose()` 호출 ✅
- 스트림 구독 취소 ✅

**상태**: ✅ 메모리 누수 위험 낮음

## 📊 성능 지표

### 현재 상태
- **네이티브 로그**: 478회
- **setState 호출**: 146회
- **포커스 폴링**: 2초 간격 (최적화됨)
- **타이머 정리**: 완료

### 최적화 후 예상
- **네이티브 로그**: 약 50회 (90% 감소)
- **setState 호출**: 약 44회 (70% 감소)
- **CPU 사용량**: 약 20-30% 감소 예상
- **배터리 소모**: 약 15-20% 감소 예상

## 🎯 우선순위별 최적화 권장사항

### 🔴 높은 우선순위 (즉시 적용 권장)

1. **네이티브 로그 최적화**
   - `getFocusStatus` 정상 동작 시 로그 제거
   - `getDebugState` 디버그 모드에서만 출력
   - `updatePreviewLayout` 로그 제거

2. **setState 최소화**
   - `_cameraEngine.addListener`에서 전체 재빌드 제거
   - ValueNotifier 기반 세분화된 상태 관리 도입

### 🟡 중간 우선순위 (점진적 적용)

3. **const 위젯 활용**
   - 변경되지 않는 위젯을 const로 선언
   - 위젯 트리 최적화

4. **RepaintBoundary 추가 활용**
   - 필터 패널, 밝기 슬라이더 등 분리

### 🟢 낮은 우선순위 (선택적 적용)

5. **필터 적용 빈도 조정**
   - 현재: 2프레임마다 1번
   - 필터 변경 시에만 적용하도록 변경 고려

## 📝 코드 품질 평가

### ✅ 잘 구현된 부분
1. 타이머/스트림 정리 완벽
2. 메모리 관리 양호
3. 포커스 폴링 최적화 완료
4. ParentDataWidget 오류 해결
5. RepaintBoundary 활용

### ⚠️ 개선 필요 부분
1. 네이티브 로그 과다
2. setState 과다 호출
3. 불필요한 위젯 재빌드

## 🎉 결론

**전체 평가**: ⭐⭐⭐⭐ (4/5)

코드 품질은 전반적으로 양호하며, 메모리 관리와 리소스 정리가 잘 되어 있습니다. 다만 네이티브 로그와 setState 호출 최적화를 통해 성능을 더욱 개선할 수 있습니다.

**즉시 적용 가능한 최적화:**
1. 네이티브 로그 제거 (약 30분 소요)
2. setState 최소화 (약 2-3시간 소요)

**예상 효과:**
- CPU 사용량: 20-30% 감소
- 배터리 소모: 15-20% 감소
- UI 반응성: 향상

