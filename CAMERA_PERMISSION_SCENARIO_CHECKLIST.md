# 카메라 앱 권한 시나리오 체크리스트

Apple HIG·일반 카메라 앱 패턴과 펫그램 구현을 대조한 요약.

---

## 1. 요청 시점 (When to request)

| 가이드 | 내용 | 펫그램 |
|--------|------|--------|
| Apple HIG | **기능이 필요할 때만** 요청. 앱 시작 직후 X | ✅ **PermissionWrapper** 루트: `_preCheckGranted` 후 notDetermined이면 **즉시** ensure(카메라→갤러리) |
| 일반 카메라 앱 | 앱 열면 곧바로 카메라 화면 = 즉시 권한 요청 | ✅ `_requestPermissionsOnce` 자동 1회 (요구 1) |

---

## 2. notDetermined (최초)

| 가이드 | 내용 | 펫그램 |
|--------|------|--------|
| 시스템 | `AVCaptureDevice.requestAccess(for: .video)` → 시스템 팝업 1회 | ✅ `ensureCameraPermission` → 네이티브 `requestAccess` |
| 사용자 | "허용" / "허용 안 함" | ✅ 3=허용, 2=거부 처리 |

---

## 3. denied (거부 후)

| 가이드 | 내용 | 펫그램 |
|--------|------|--------|
| Apple | **같은 권한으로 시스템 팝업 다시 띄우지 않음** | ✅ `ensure` 2 반환 시 `requestAccess` 재호출 없음, `_canRequest=false` |
| 일반 앱 | "설정에서 허용해 주세요" + **설정으로 이동** 버튼 | ✅ **`_showPermissionDeniedDialog`** (요구 2) + 풀스크린 "설정으로 이동" (PermissionWrapper) |
| UI | 거부 상태 명확 표시, 설정 유도 | ✅ 다이얼로그 + `openSettings`, `_returnedFromSettings`로 복귀 시 재확인 |

---

## 4. 거부 후 lifecycle (멈춤/SIGKILL 방지, 요구 4)

| 가이드 | 내용 | 펫그램 |
|--------|------|--------|
| 실제 동작 | 권한 팝업 닫힘 → `inactive` → `resumed` | ✅ |
| 위험 | **카메라 미초기화 상태에서 `resume`/`pause` 호출** → 5초 대기·타임아웃·SIGKILL | ✅ **거부 시 HomePage 미마운트** (PermissionWrapper가 `_permissionsGranted=false` 유지) → `onCreated`/`_doCameraInit`/pause/resume **호출 없음** |
| 적용 위치 | PermissionWrapper가 HomePage를 숨김; HomePage 내부 `_cameraPermissionDenied` 방어는 비정상 진입 대비 유지 | ✅ |
| 프리뷰 동기화 | 카메라 없이 네이티브 접근 스킵 | ✅ HomePage 미표시 시 동기화 코드 미실행 |

---

## 5. 설정에서 복귀 (요구 3)

| 가이드 | 내용 | 펫그램 |
|--------|------|--------|
| 일반 앱 | 설정에서 권한 켜고 돌아오면 **권한 재확인 후 카메라 시작** | ✅ **PermissionWrapper** `didChangeAppLifecycleState(resumed)` + `_returnedFromSettings` → `_preCheckGranted` → 3,3이면 `_permissionsGranted=true` → HomePage |
| iOS | 설정에서 권한 변경 시 앱 **SIGKILL** 가능 | ✅ 재실행 → PermissionWrapper → `_preCheckGranted` → 3,3 → HomePage. `openSettings`는 AppDelegate `petgram/permissions` 채널로 실제 설정 앱 이동 |

---

## 6. Info.plist

| 키 | 용도 | 펫그램 |
|----|------|--------|
| `NSCameraUsageDescription` | 카메라 (시스템 팝업 문구) | ✅ |
| `NSPhotoLibraryUsageDescription` | 앨범 읽기 | ✅ |
| `NSPhotoLibraryAddUsageDescription` | 앨범 저장 | ✅ |

---

## 7. 갤러리 권한 시점 (요구 5: 중복 없이)

| 패턴 | 설명 | 펫그램 |
|------|------|--------|
| A | 카메라와 동시 (앱 시작 직후) | ✅ **PermissionWrapper** `_requestPermissionsOnce`: 카메라 ensure → 갤러리 ensure **순차 1회** |
| B | **첫 저장 시** 갤러리만 요청 | FilterPage `_onSavePressed`에서 `Gal.hasAccess`/`Gal.requestAccess` (이미 Wrapper에서 요청했을 경우 대비) |

---

## 8. (선택) 사전 안내 / 취소

| 항목 | 일반 앱 | 펫그램 |
|------|---------|--------|
| **사전 rationale** | "카메라가 필요해요" 등 한 번 보여주고 → 시스템 팝업 | ❌ 생략, 최초 `ensure`에서 바로 시스템 팝업 |
| **설정으로 이동** 외 "나중에"** | 일부 앱에서 제공 | ❌ 미제공. 카메라 영역만 오버레이, 다른 탭으로 이동 가능 |

---

## 9. 허용 직후 lifecycle (inactive→resumed) — 카메라 안 뜨는 문제

| 가이드 | 내용 | 펫그램 |
|--------|------|--------|
| 실제 동작 | 권한 **허용** 후 팝업 닫힘 → `inactive` → `resumed` | ✅ |
| 위험 | 이때 `isInitialized=false`(아직 `_doCameraInit`가 `requestInitializeIfNeeded` 완료 전). `_resumeCameraSession` 호출 시 **init과 겹쳐 5초 대기·타임아웃** → 카메라 안 뜸 | ✅ **`!isInitialized`일 때 resumed 경로 전부 스킵** (resume·checkRequired·setState). `_doCameraInit`가 init 완료하도록 함 |
| 적용 위치 | `didChangeAppLifecycleState(resumed)`, `_resumeCameraSession` 진입 | ✅ `if (!_cameraEngine.isInitialized) return;` |

---

## 10. 시나리오별 동작 요약 (검증 시나리오)

| 시나리오 | 동작 |
|----------|------|
| **앱 최초 실행 (iOS, notDetermined)** | **PermissionWrapper** → `_preCheckGranted` → `_requestPermissionsOnce` → ensureCamera → ensurePhoto → 시스템 팝업(들) → 허용 시 `_permissionsGranted=true` → **HomePage** → `_doCameraInit`(ensure 없음) → `requestInitializeIfNeeded` |
| **최초 허용 → 팝업 닫힘** | `inactive` → `resumed`. HomePage `!isInitialized`라 **resume 스킵** → `_doCameraInit`가 세션 대기 완료 → 카메라 정상 기동 |
| **최초 거부 (카메라)** | ensure → 2 → `_canRequest=false` → **`_showPermissionDeniedDialog`** (요구 2) + 풀스크린 "설정으로 이동" |
| **최초 거부 (갤러리)** | 카메라 3, 갤러리 2 → `_canRequest=false` → **`_showPermissionDeniedDialog`** + 풀스크린 "설정으로 이동" |
| **거부 후 팝업 사라짐** | `inactive` → `resumed`. **HomePage 미마운트** → pause/resume/동기화 **호출 없음** (요구 4, SIGKILL 회피) |
| **설정으로 이동 → 권한 켬 → 복귀** | `resumed` + `_returnedFromSettings` → PermissionWrapper `_preCheckGranted` → 3,3 → `_permissionsGranted=true` → **HomePage** → `_doCameraInit` → `requestInitializeIfNeeded` (요구 3) |
| **설정에서 권한 켬 → iOS SIGKILL → 재실행** | 새 프로세스 → **PermissionWrapper** → `_preCheckGranted` → 3,3 → HomePage → 정상 초기화 |

---

## 11. 코드 위치 (참고)

- **루트**: `main.dart` `home: PermissionWrapper(cameras: cameras)`
- **요청 시점**: **PermissionWrapper** `_preCheckGranted` → `_requestPermissionsOnce` (ensureCamera → ensurePhotoLibrary 순, 요구 5)
- **거부 시**: `_requestPermissionsOnce` / `_onPrimaryButtonTap` 내 `(c??2)!=3` or `(g??2)!=3` → `_canRequest=false` → **`_showPermissionDeniedDialog`** (요구 2)
- **설정 열기**: `MethodChannel('petgram/permissions').invokeMethod('openSettings')` (PermissionWrapper, HomePage `_showPermissionDeniedDialog`, `_buildPermissionOverlay`)
- **설정 복귀**: PermissionWrapper `didChangeAppLifecycleState(resumed)` + `_returnedFromSettings` → `_preCheckGranted` → 3,3이면 `_permissionsGranted=true` → HomePage
- **HomePage `_doCameraInit`**: ensure **제거**. `requestInitializeIfNeeded`만. (`_cameraPermissionDenied`/`_buildPermissionOverlay`/`_returnedFromSettings`는 비정상 진입·`_checkRequiredPermissionsOnResume`용 유지)
- **거부 시 카메라 init/resume 미호출 (요구 4)**: PermissionWrapper가 거부 시 HomePage를 표시하지 않아 `onCreated`/`_doCameraInit`/pause/resume 미호출.
