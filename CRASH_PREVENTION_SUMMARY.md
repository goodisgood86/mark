# 🔥 크래시 방지 작업 완료 요약

## 작업 목표
`-[UIView_backing_setFrame:]` 크래시를 정적 분석 기반 방어 코드로 안정화

## 완료된 작업

### 1. 공통 유틸리티 생성 ✅

#### iOS: `ios/Runner/GeometrySafety.swift`
- `safeLength()`: CGFloat 값 검증 (NaN/Inf/음수/과도한 값)
- `safeSize()`: CGSize 검증
- `safeRect()`: CGRect 검증
- `safePoint()`: CGPoint 검증
- `safeAspectRatio()`: Aspect ratio 계산 시 0으로 나누기 방지
- Extension: CGRect/CGSize/CGPoint/CGFloat에 직접 사용 가능

#### Flutter: `lib/utils/geometry_safety.dart`
- 동일한 검증 로직을 Dart로 구현
- Flutter 쪽 레이아웃 계산에도 적용 가능

### 2. iOS 네이티브 코드 패치 ✅

#### 패치 적용 완료:
1. **NativeCamera.create()** - PlatformView 생성 시 frame 검증 추가
2. **NativeCameraView.init()** - 초기화 시 frame 검증 추가  
3. **CameraPreviewView.init()** - GeometrySafety 유틸리티 사용

#### 패치 필요 (문서에 상세 설명):
- `loadView()` containerView.frame 설정
- Loading Overlay 관련 frame 설정
- `updateDrawableSizeIfNeeded()` 내부 모든 계산값 검증

### 3. Flutter 코드 준비 ✅

- `lib/utils/geometry_safety.dart` 생성 완료
- `lib/pages/home_page.dart`에 import 추가 완료

#### 적용 필요 (문서에 상세 설명):
- Aspect ratio 계산 부분
- nativeWidth/nativeHeight 계산 부분
- AspectRatio 위젯에 전달하는 값 검증

### 4. 문서 작성 ✅

- **CRASH_PREVENTION_PATCHES.md**: 모든 패치의 상세 가이드 (diff 형식)
  - 각 패치마다 "이유" 설명 포함
  - 로그 전략 포함
  - 추가 디버깅 팁 포함

---

## 주요 파일 변경 사항

### 신규 생성
- `ios/Runner/GeometrySafety.swift`
- `lib/utils/geometry_safety.dart`
- `CRASH_PREVENTION_PATCHES.md`
- `CRASH_PREVENTION_SUMMARY.md` (이 파일)

### 수정된 파일
- `ios/Runner/NativeCamera.swift` - frame 검증 추가
- `ios/Runner/CameraPreviewView.swift` - GeometrySafety 사용
- `lib/pages/home_page.dart` - import 추가

---

## 다음 단계

1. **나머지 패치 적용** (CRASH_PREVENTION_PATCHES.md 참조)
   - iOS: Loading Overlay, updateDrawableSizeIfNeeded 등
   - Flutter: Aspect ratio 계산, nativeWidth/nativeHeight 등

2. **테스트**
   - 빌드 테스트
   - 실제 기기에서 테스트
   - 로그 확인

3. **모니터링**
   - Apple 크래시 리포트 확인
   - `[Petgram] ❗` 로그 모니터링

---

## 중요 사항

⚠️ **이 패치는 "NaN/잘못된 frame 값으로 인한 크래시를 최대한 방어"하는 것이 목표입니다.**

- 100% 재현 방지 보장 불가
- 다른 원인의 크래시는 여전히 발생할 수 있음
- 크래시가 계속 발생한다면 로그를 통해 원인 추적 가능

---

## 참고 문서

- `CRASH_PREVENTION_PATCHES.md`: 상세 패치 가이드 (diff 형식)
- Apple 크래시 리포트: 스택 트레이스 분석
- Flutter PlatformView 문서

