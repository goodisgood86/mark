# Xcode 프로젝트 파일 추가 필요

## 문제
`PetgramCameraPlugin.swift`와 `PetgramCameraEngine.swift` 파일이 Xcode 프로젝트에 포함되지 않아 빌드 오류가 발생합니다.

## 해결 방법

### 방법 1: Xcode에서 수동 추가 (권장)

1. Xcode에서 `ios/Runner.xcodeproj`를 엽니다
2. Xcode 프로젝트 네비게이터에서 `Runner` 그룹을 찾습니다
3. `Camera` 폴더가 없으면 우클릭 → "New Group" → 이름: `Camera`
4. 다음 파일들을 Finder에서 드래그 앤 드롭:
   - `ios/Runner/Camera/PetgramCameraPlugin.swift`
   - `ios/Runner/Camera/PetgramCameraEngine.swift`
5. "Copy items if needed" 체크 해제
6. "Add to targets: Runner" 체크 확인

### 방법 2: 명령어로 추가 (고급)

```bash
cd /Users/grepp/mark_v2
# Xcode 프로젝트 파일을 직접 수정 (주의 필요)
# 또는 Xcode를 사용하여 수동으로 추가
```

### 방법 3: 임시 해결책 - 파일 위치 변경

만약 Xcode 프로젝트 구조상 문제가 있다면, 파일을 `ios/Runner/` 디렉토리로 이동할 수도 있습니다:

```bash
cd /Users/grepp/mark_v2
mv ios/Runner/Camera/PetgramCameraPlugin.swift ios/Runner/
mv ios/Runner/Camera/PetgramCameraEngine.swift ios/Runner/
```

하지만 이 경우 `Camera` 폴더 구조가 깨지므로, 방법 1을 권장합니다.

## 확인 방법

Xcode 프로젝트에서 파일이 추가되었는지 확인:
- Xcode 프로젝트 네비게이터에서 파일이 보여야 합니다
- 파일을 선택하고 Target Membership에서 "Runner"가 체크되어 있어야 합니다

## 현재 파일 위치

- `ios/Runner/Camera/PetgramCameraPlugin.swift` ✅ 파일 존재
- `ios/Runner/Camera/PetgramCameraEngine.swift` ✅ 파일 존재

두 파일 모두 물리적으로는 존재하지만, Xcode 프로젝트에 등록되지 않아 컴파일되지 않습니다.

