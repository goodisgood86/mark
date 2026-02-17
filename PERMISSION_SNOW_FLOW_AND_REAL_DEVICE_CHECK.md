# 스노우 앱 시나리오 정렬 + 설정→재시작→진입처리 (실기기 점검)

## 1. 스노우 앱 시나리오 (Snow app scenario)

| 단계 | 스노우 | 펫그램 구현 |
|------|--------|-------------|
| 1 | 권한 허용/거부 시스템 팝업 | ✅ `ensureCameraPermission` / `ensurePhotoLibraryPermission` → 시스템 팝업 |
| 2 | **거부 시** → **설정하기 다이얼로그** + **설정으로 이동** 버튼 | ✅ `_buildPermissionOverlay`: 제목 "설정하기", 본문, **설정으로 이동** 버튼 (다이얼로그 스타일 카드) |
| 3 | 설정 이동 → 권한 변경 | ✅ `MethodChannel('petgram/permissions').invokeMethod('openSettings')` → iOS 설정 앱 |
| 4 | **권한 변경 시 앱 재시작** → **다시 진입처리** | ✅ 아래 §2, §3 |

---

## 2. 설정에서 권한 변경 시 동작 (iOS)

- iOS는 **설정 > [앱] > 카메라/사진**에서 권한을 켜거나 끄면, **해당 앱을 SIGKILL로 종료하는 경우가 많음**.
- 사용자가 앱 아이콘을 다시 눌러 **콜드 스타트**하게 됨.

### 2.1 콜드 스타트 시 진입처리 (다시 진입처리)

- `main()` → `runApp(HomePage(cameras: cameras))` → **HomePage** 직접 진입 (PermissionWrapper 없음).
- HomePage 빌드 → **NativeCameraPreview** 배치 → `onCreated(viewId)` 호출.
- `onCreated` → `attachNativeView(viewId)` → **`_doCameraInit(viewId)`**:
  - `ensureCameraPermission` → 설정에서 허용했으면 **3** 반환.
  - `ensurePhotoLibraryPermission` → **3** (또는 갤러리도 설정에서 허용했으면 3).
  - `(c==3 && g==3)` 이면 `requestInitializeIfNeeded` → 카메라 세션 기동.

즉, **다시 진입처리 = `_doCameraInit`가 onCreated에서 1회 수행**되고, 이때 권한이 이미 허용(3)이므로 곧바로 `requestInitializeIfNeeded`까지 진행됨.

### 2.2 재시작하지 않는 경우 (앱이 살아 있는 경우) — **앱 재진입(재시작)으로 통일**

- 설정에서 권한만 바꾸고, iOS가 앱을 kill하지 않으면:
  - 사용자가 앱으로 복귀 시 **`resumed`**.
  - `_returnedFromSettings == true` (설정으로 이동 직전에 설정) → **HomePage를 `pushAndRemoveUntil`로 갈아끼워 앱 재진입(재시작) 효과**.
  - 새 HomePage → `onCreated` → `_doCameraInit` → `ensure*` 3이면 `requestInitializeIfNeeded` → 카메라 기동.
- 즉, **설정에서 복귀 시에는 (kill 여부와 관계없이) 항상 “첫 진입”과 같은 경로**로만 동작.

---

## 3. 실기기 점검 (테스트 시 연결 끊김 대비)

### 3.1 테스트 시 “연결 끊김”이 나는 이유

- `flutter run`으로 실행 중, **설정에서 권한을 변경**하면 iOS가 앱을 **SIGKILL**할 수 있음.
- 앱 프로세스가 종료되면 **Flutter 디버그 연결(dart VM, DevTools)이 끊김**.
- 이는 **정상 동작**이며, 실기기에서 앱만 단독 실행되는 상황을 의미함.

### 3.2 실기기에서 “재시작 후 진입처리”가 정상인지 보는 방법

**목적**: 설정에서 권한 허용 후 앱이 kill → 사용자가 앱 아이콘으로 다시 실행 → **콜드 스타트 시 `_doCameraInit`만으로 카메라가 정상 기동하는지** 확인.

- **권장**: `flutter run --release` 또는 `flutter build ios` 후 Xcode/TestFlight로 설치해, 연결 끊김 없이 **앱만 단독 실행**되는 환경에서 동일 시나리오를 재현하면, 실기기 동작을 가장 확실히 검증할 수 있음.

#### A. `flutter run`(디버그) 사용 시

1. `flutter run`으로 실기기 실행.
2. **권한 거부** → **설정하기** 다이얼로그 → **설정으로 이동** → 설정 앱에서 **카메라·사진 권한 ON**.
3. (선택) 홈으로 나갔다가 **앱 아이콘**으로 다시 실행.  
   - iOS가 이미 앱을 kill했으면, 2번 직후 앱이 사라졌을 수 있고, 이때는 3번에서 **앱 아이콘으로 최초 실행**하는 것과 동일.
4. **예상**:
   - 터미널에서 `flutter run` 연결이 끊겼을 수 있음 (정상).
   - 앱은 **콜드 스타트** → `main` → `HomePage` → `onCreated` → `_doCameraInit` → `ensure*` 3 → `requestInitializeIfNeeded` → **카메라 프리뷰 기동**.
5. **체크**:
   - [ ] 카메라 프리뷰가 보인다.
   - [ ] 촬영이 가능하다.
   - [ ] (선택) `flutter run` 끊김 후에도 앱만으로 위 동작이 재현된다.

#### B. `flutter run --release` 또는 IPA 설치 후

- `flutter run --release`로 실기기 실행하거나,  
  `flutter build ios` → Xcode/TestFlight로 설치한 뒤 **앱 아이콘**으로 실행.
- 위 2–4와 동일한 시나리오 수행.
- **체크**:
  - [ ] 설정에서 권한 ON 후, 앱이 kill되면 → 앱 아이콘으로 다시 실행 시 카메라 정상 기동.
  - [ ] `_returnedFromSettings`·`_cameraPermissionDenied` 등 **메모리 상태에 의존하지 않고**, `main` → `onCreated` → `_doCameraInit`만으로 진입처리가 된다.

### 3.3 콜드 스타트에서 가정하는 것 (점검 포인트)

| 항목 | 의미 | 점검 |
|------|------|------|
| `main` → `HomePage` | PermissionWrapper 없이 HomePage가 첫 화면 | ✅ `main.dart` `home: HomePage(cameras: cameras)` |
| `onCreated` 1회 호출 | NativeCameraPreview 배치 시 1회만 | ✅ `didChangeDependencies` / `addPostFrameCallback` 에서 1회 |
| `_doCameraInit` 진입 | `ensure*` → 3이면 `requestInitializeIfNeeded` | ✅ `_doCameraInit` 내 분기 |
| `_returnedFromSettings` | 콜드 스타트 시 **사용하지 않음** (초기값 false) | ✅ `didChangeAppLifecycleState`에서만 true 사용, `main`/저장 없음 |
| `_cameraPermissionDenied` | 콜드 스타트 시 **사용하지 않음** (초기값 false) | ✅ `_doCameraInit`에서만 true 설정, `main`/저장 없음 |
| `petgram/permissions` `openSettings` | 설정 앱 오픈 | ✅ `ios/Runner/AppDelegate.swift`에 구현 |

### 3.4 디버그 연결 끊김 후에도 확인할 수 있는 것

- **앱 단독 실행** 시:
  - `main` → `HomePage` → `onCreated` → `_doCameraInit` 흐름은 **디버거 부재와 무관**하게 동일.
  - `ensure*`·`requestInitializeIfNeeded`는 **MethodChannel**로 네이티브와 통신하므로, **dart VM 연결이 없어도** 동작.
- 따라서 **“연결 끊김”이 나도, 앱 아이콘으로 다시 켰을 때 카메라가 뜨고 촬영이 되면**, 실기기에서의 재시작 후 진입처리는 정상으로 볼 수 있음.

---

## 4. 요약

- **스노우 시나리오**:  
  권한 거부 → **설정하기 다이얼로그** + **설정으로 이동** → 설정에서 권한 변경 → (가능하면) **앱 재시작** → **다시 진입처리**.
- **다시 진입처리**:
  - **콜드 스타트**: `onCreated` → `_doCameraInit` → `ensure*` 3 → `requestInitializeIfNeeded` (저장/연결 상태에 의존하지 않음).
  - **웜 복귀**: `_returnedFromSettings` → `_doCameraInit(0)`.
- **실기기 점검**:  
  설정에서 권한 ON 후 앱이 kill되면 `flutter run` 연결이 끊기는 것은 정상.  
  **앱 아이콘으로 재실행** → 카메라 정상 기동·촬영 가능한지 확인하면, 실기기에서의 정상 동작을 점검한 것으로 볼 수 있음.
