# 카메라/갤러리 권한 흐름 점검 결과

## 1. 현재 동작 요약 (파일/함수 기준)

### 1.1 앱 시작 시 루트 위젯
| 파일 | 내용 |
|------|------|
| `lib/main.dart` | `home: HomePage(cameras: cameras)` — **PermissionWrapper 미사용** |
| `lib/widgets/permission_wrapper.dart` | 정의만 있고 **main에서 사용되지 않음** |
| `lib/pages/permission_check_screen.dart` | **삭제됨** (미사용) |

### 1.2 카메라 초기화 시점
| 위치 | 동작 |
|------|------|
| `home_page.dart` `NativeCameraPreview` `onCreated` | `attachNativeView(viewId)` → `_doCameraInit(viewId)` |
| `_doCameraInit` | iOS: `ensureCameraPermission` → (3이면) `requestInitializeIfNeeded`. **갤러리 ensure 없음** |
| `camera_engine.dart` | `requestInitializeIfNeeded` → NativeCameraController, `initializeNativeCameraOnce`는 `HomePage`에서 별도 사용 |

### 1.3 ensure/check 권한 호출
| 위치 | 메서드 | when |
|------|--------|------|
| `home_page.dart` `_doCameraInit` | `ensureCameraPermission` | onCreated 직후, **카메라만** |
| `home_page.dart` `_checkRequiredPermissionsOnResume` | `checkCameraPermission`, `checkPhotoLibraryPermission` | `didChangeAppLifecycleState(resumed)` |
| `permission_wrapper.dart` | `checkCameraPermission`, `checkPhotoLibraryPermission` (`_preCheckGranted`) | initState postFrame (iOS만). **ensure는 "권한 허용" 탭 시에만** |
| `filter_page.dart` `_onSavePressed` | `Gal.hasAccess` / `Gal.requestAccess` | **저장 시점**에만 갤러리 |

### 1.4 거부/설정 복귀 시 state
| 플래그 | 설정 위치 | 사용 |
|--------|-----------|------|
| `_cameraPermissionDenied` | `_doCameraInit`에서 `(c??2)!=3` 시 true | `_pauseCameraSession`, `_resumeCameraSession`, `_buildCameraStack` postFrame, `_buildPermissionOverlay`, 촬영/줌 등에서 **모두 스킵** |
| `_returnedFromSettings` | `_buildPermissionOverlay` "설정으로 이동" onPressed | `didChangeAppLifecycleState(resumed)`에서 `pushAndRemoveUntil(HomePage)`로 재진입 |

### 1.5 갤러리 권한
| 시점 | 처리 |
|------|------|
| 촬영 직후 | 없음 (HomePage 촬영 → FilterPage) |
| **FilterPage 저장 시** | `Gal.hasAccess` / `Gal.requestAccess` (`_onSavePressed`) |

---

## 2. 문제점 리스트

### 2.1 구조적
- **PermissionWrapper 미사용**: main이 `HomePage` 직접 루트. `home_page` 주석 "PermissionWrapper에서 이미 처리"는 **거짓**.
- **PermissionCheckScreen 미사용**: 어디서도 사용하지 않음. 삭제 후보.

### 2.2 요구 1) 앱 최초 실행 시 즉시 권한 요청
- **현재**: 권한 요청은 `onCreated` → `_doCameraInit` → `ensureCameraPermission`. 카메라 **뷰가 붙은 뒤**에만 요청. “즉시”에 가깝지만, 뷰 생성 전까지 지연 있음.
- **PermissionWrapper**가 있었다면: “권한 허용” **탭 시에만** ensure → **즉시 요청 아님**.

### 2.3 요구 2) 거부 시 “설정으로 이동” 다이얼로그
- **현재**: `_buildPermissionOverlay` — 카메라 영역 위 **오버레이 카드** + “설정으로 이동” 버튼. `showDialog` 형태의 **다이얼로그는 아님**.
- **`_checkRequiredPermissionsOnResume`**: `_showPermissionDeniedDialog`에 **“앱 종료”** 포함 → 요구와 다름.

### 2.4 요구 4) 거부 시 카메라 init/resume 미호출
- **현재**: `_cameraPermissionDenied`일 때 `_pauseCameraSession`, `_resumeCameraSession`, `_buildCameraStack` postFrame, 촬영/줌 등에서 `return` → **방어됨**.
- **주의**: `_doCameraInit`는 `ensureCameraPermission`을 **항상 호출**. 거부(2) 반환 시 `requestInitializeIfNeeded`는 호출 안 함 → init은 스킵됨. `ensure` 자체는 “권한 확인/요청”이므로 init이 아님. **OK**.

### 2.5 요구 5) 카메라/갤러리 요청 타이밍 중복 없이
- **현재**: 카메라 ensure는 `_doCameraInit`에서 1회. 갤러리는 FilterPage 저장 시 `Gal` 1회. **서로 다른 시점**이라 중복 없음.
- **갤러리**: `_doCameraInit`에 갤러리 ensure **없음**. 체크리스트는 “_doCameraInit에서 카메라→갤러리 순”으로 되어 있으나 미구현.

### 2.6 기타
- **`_doCameraInit`**: 갤러리 `ensurePhotoLibraryPermission` 없음.
- **`_checkRequiredPermissionsOnResume`**: “앱 종료” 옵션 — 요구 2)와 무관하지만, “설정으로 이동”만 있어도 동작에는 문제 없음.

---

## 3. 개선 설계 (단일화 방향)

### 3.1 루트: PermissionWrapper
- **main.dart**: `home: PermissionWrapper(cameras: cameras)`.
- **PermissionWrapper**:  
  - **iOS**: 앱 시작 후 `_preCheckGranted`(check) → `c==3 && g==3`이면 `_permissionsGranted=true` → `HomePage`.  
  - 그렇지 않을 때 `_canRequest==true`(notDetermined)이면 **첫 프레임에서 자동으로 1회** `ensureCamera` → (거부면 `_canRequest=false`, setState, **“설정으로 이동” 다이얼로그** `showDialog`) → (통과 시) `ensurePhotoLibrary` → (거부면 동일).  
  - `_canRequest==false`(이미 거부): **“설정으로 이동” 다이얼로그** 1회 + 풀스크린 안내/버튼 유지.  
  - **설정 복귀**: `didChangeAppLifecycleState(resumed)` + `_returnedFromSettings` → `_preCheckGranted` → 3,3이면 `_permissionsGranted=true` → `HomePage`.

### 3.2 HomePage (PermissionWrapper 통과 후만 진입)
- **진입 조건**: `_permissionsGranted==true`이므로, **카메라·갤러리 권한은 이미 확보된 상태**.
- **`_doCameraInit`**:  
  - **ensure 제거**. `requestInitializeIfNeeded`만 수행. (권한은 Wrapper에서 보장.)
- **`_cameraPermissionDenied` / `_returnedFromSettings` / `_buildPermissionOverlay` / `_checkRequiredPermissionsOnResume` / `_showPermissionDeniedDialog`**:  
  - **제거 또는 퇴화**.  
  - `_checkRequiredPermissionsOnResume`만 유지 시: “앱 종료” 제거, **“설정으로 이동”만** 두어, 설정에서 권한 끈 뒤 재진입 시 대응.

### 3.3 권한 거부 시 “설정으로 이동” 다이얼로그
- **위치**: PermissionWrapper.  
  - ensure 후 `c!=3` or `g!=3` → `_canRequest=false`, setState,  
  - `if (mounted) _showPermissionDeniedDialog()`.  
- **`_showPermissionDeniedDialog`**:  
  - `showDialog( barrierDismissible: false, “설정으로 이동” 버튼만 )`.  
  - onPressed: `openSettings`, `_returnedFromSettings=true`, `Navigator.pop(context)`.

### 3.4 갤러리 요청 타이밍
- **PermissionWrapper**: iOS에서 `ensureCamera` 통과 후 `ensurePhotoLibrary` 호출.  
  - 카메라·갤러리 **순차 1회씩**, 중복 없음.
- **FilterPage**: 저장 시 `Gal`은 **이미 Wrapper에서 갤러리 권한 요청했을 가능성**이 있으므로, `Gal.hasAccess` false일 때만 `Gal.requestAccess` (기존 유지).

### 3.5 거부 시 카메라 init/resume 미호출
- **PermissionWrapper**가 거부 시에는 `HomePage`를 **안 보여줌** → `onCreated` / `_doCameraInit` / `requestInitializeIfNeeded` / `_pauseCameraSession` / `_resumeCameraSession` 호출 없음.  
- **HomePage** 내부의 `_cameraPermissionDenied` 방어는, **Wrapper를 우회해 들어오는 비정상 경로**에 대한 안전망으로만 선택적으로 유지 가능. 최소 변경에서는 **Wrapper만** 거부 시 HomePage 진입을 막으면 됨.

### 3.6 PermissionCheckScreen
- **삭제**. 사용처 없음.

---

## 4. 필요한 코드 변경 (파일별)

### 4.1 `lib/main.dart`
- `home: HomePage(cameras: cameras)`  
  → `home: PermissionWrapper(cameras: cameras)`  
- `PermissionWrapper` import 추가.

### 4.2 `lib/widgets/permission_wrapper.dart`
- **iOS, notDetermined**: `_preCheckGranted` 후 `(c!=3 || g!=3) && _canRequest`이면, **postFrameCallback 1회**로 `ensureCamera` → (거부 시 `_canRequest=false`, setState, **`_showPermissionDeniedDialog()`**) → (3일 때만) `ensurePhotoLibrary` → (거부 시 동일).
- **`_showPermissionDeniedDialog()`** 신규:  
  - `showDialog( barrierDismissible: false, “설정으로 이동” only )`.  
  - onPressed: `openSettings`, `_returnedFromSettings=true`, `Navigator.pop(context)`.
- **이미 거부(`_canRequest==false`)**:  
  - `_preCheckGranted`만으로는 **시스템 팝업 재호출 불가** → 기존처럼 “설정으로 이동” 버튼만 노출.  
  - **최초 거부 직후**에만 `_showPermissionDeniedDialog` 호출. 이미 거부 후 재진입이면 다이얼로그 중복 방지(예: `_hasShownPermissionDialog` 플래그).
- **설정 복귀**: 기존 `didChangeAppLifecycleState(resumed)` + `_returnedFromSettings` → `_preCheckGranted` 유지.  
- **Android**: `_preCheckGranted` 없이 `_permissionsGranted=true` 유지 (기존과 동일).

### 4.3 `lib/pages/home_page.dart`
- **`_doCameraInit`**:  
  - iOS 분기에서 `ensureCameraPermission`(및 갤러리 ensure) **삭제**.  
  - `requestInitializeIfNeeded`만 호출.
- **`_cameraPermissionDenied`**:  
  - Wrapper가 거부 시 HomePage 진입을 막으므로, **이론상 불필요**.  
  - **최소 수정**:  
    - `_doCameraInit`에서 setState로 `_cameraPermissionDenied` 넣는 코드 **삭제**.  
    - `_cameraPermissionDenied` 필드와, `_pauseCameraSession` / `_resumeCameraSession` / `_buildCameraStack` / 촬영·줌 등에서의 `if (_cameraPermissionDenied) return` — **유지**해도 동작에는 문제 없음 (항상 false).  
  - **정리용(선택)**: `_cameraPermissionDenied` 제거 시, 위 `return`들도 제거. 여기서는 **유지**로 두고 `_doCameraInit`의 ensure·setState만 제거.
- **`_returnedFromSettings`**:  
  - `_buildPermissionOverlay` “설정으로 이동” onPressed 제거되면, `_returnedFromSettings` 설정 위치 없음.  
  - `didChangeAppLifecycleState(resumed)`의 `if (_returnedFromSettings){ pushAndRemoveUntil(HomePage); return; }` **삭제** 가능. (설정 복귀는 PermissionWrapper에서 처리.)
- **`_buildPermissionOverlay` / `_buildCameraStack`의 `if (_cameraPermissionDenied) Positioned.fill(_buildPermissionOverlay)`**:  
  - **유지**해도 됨 (`_cameraPermissionDenied`가 항상 false이면 그리지 않아도 되는 분기와 동일).  
  - **정리**: `_cameraPermissionDenied`를 **제거**할 경우에만 함께 제거. 최소 수정에서는 **유지**.
- **`_checkRequiredPermissionsOnResume` / `_showPermissionDeniedDialog`**:  
  - **유지**.  
  - `_showPermissionDeniedDialog`: **“앱 종료” 버튼 제거**, **“설정으로 이동”만** 두어 요구 2)와 정합.

### 4.4 `lib/pages/permission_check_screen.dart`
- **삭제** (미사용).

### 4.5 `lib/services/camera_engine.dart`
- **변경 없음**.  
- `requestInitializeIfNeeded` / `initializeNativeCameraOnce` / `pause` / `resume`은 **HomePage·네이티브**에서만 호출.  
- PermissionWrapper가 거부 시 HomePage를 안 보이게 하면, **권한 거부 상태에서 init/resume 호출 자체가 없음**.  
- 추가로, **CameraEngine**에 “권한 거부” 플래그를 넘겨 init/resume을 스킵하는 방어는, **구조상 불필요** (HomePage가 마운트되지 않음). 유지해도 무방.

### 4.6 `lib/pages/filter_page.dart`
- **변경 없음**.  
- 갤러리: `Gal.hasAccess` / `Gal.requestAccess` — **저장 시점**에만.  
- Wrapper에서 `ensurePhotoLibrary`를 이미 호출했어도, `Gal`은 별도 API이므로 **이중 확인/요청**만 될 뿐, 중복 타이밍 이슈는 없음.

### 4.7 `ios/Runner/NativeCamera.swift`, `AppDelegate.swift`, `Info.plist`
- **변경 없음**.  
- `ensureCameraPermission` / `ensurePhotoLibraryPermission` / `check*` / `openSettings` / `Info.plist` 키 유지.

### 4.8 `android/.../AndroidManifest.xml`
- **변경 없음**.

---

## 5. 검증 시나리오 (CAMERA_PERMISSION_SCENARIO_CHECKLIST.md와의 대응)

| # | 시나리오 | 기대 | 점검 포인트 |
|---|----------|------|-------------|
| 1 | **앱 최초 실행 (iOS, notDetermined)** | PermissionWrapper → 자동 ensure(카메라→갤러리) → 시스템 팝업 | `_preCheckGranted` 후 자동 ensure 1회, `ensureCamera` → `ensurePhotoLibrary` 순서 |
| 2 | **최초 허용 → inactive→resumed** | 카메라 정상 기동 | HomePage `!isInitialized`일 때 resume 스킵 유지 |
| 3 | **최초 거부 (카메라)** | ensure→2 → `_canRequest=false` → **“설정으로 이동” 다이얼로그** + 풀스크린 “설정으로 이동” 버튼 | `_showPermissionDeniedDialog` 1회, openSettings |
| 4 | **최초 거부 (갤러리)** | 카메라 3, 갤러리 2 → 동일 | `_showPermissionDeniedDialog`, `_canRequest=false` |
| 5 | **거부 후 팝업 사라짐 → inactive→resumed** | pause/resume/postFrame **호출 없음** (HomePage 미마운트) | PermissionWrapper가 HomePage를 숨김 → `onCreated`/`_doCameraInit`/pause/resume 미호출 |
| 6 | **설정으로 이동 → 권한 켬 → 복귀** | `resumed` + `_returnedFromSettings` → `_preCheckGranted` → 3,3 → `_permissionsGranted=true` → HomePage | Wrapper `didChangeAppLifecycleState` + `_returnedFromSettings` |
| 7 | **설정에서 권한 켬 → iOS SIGKILL → 재실행** | 새 프로세스 → PermissionWrapper → `_preCheckGranted` → 3,3 → HomePage | `_preCheckGranted` |
| 8 | **갤러리만 거부** | `ensurePhotoLibrary`→2 → `_canRequest=false` → “설정으로 이동” 다이얼로그 | Wrapper ensure 순서: 카메라 3 → 갤러리 2 |
| 9 | **FilterPage 저장 시 갤러리** | `Gal.hasAccess`/`Gal.requestAccess` (기존) | FilterPage 변경 없음 |

---

## 6. 핵심 코드 스니펫 (개선 후)

### PermissionWrapper — 자동 ensure 및 다이얼로그 (개략)

```dart
// _preCheckGranted 후 (c!=3||g!=3) && _canRequest일 때
void _requestPermissionsIfNeeded() {
  if (!mounted || _isRequesting || !_canRequest || !Platform.isIOS) return;
  _isRequesting = true;
  () async {
    var c = await _channel.invokeMethod<int>('ensureCameraPermission').timeout(..., onTimeout: () => 2);
    if ((c ?? 2) != 3) {
      if (mounted) { setState(() { _canRequest = false; _isRequesting = false; }); _showPermissionDeniedDialog(); }
      return;
    }
    var g = await _channel.invokeMethod<int>('ensurePhotoLibraryPermission').timeout(..., onTimeout: () => 2);
    if ((g ?? 2) != 3) {
      if (mounted) { setState(() { _canRequest = false; _isRequesting = false; }); _showPermissionDeniedDialog(); }
      return;
    }
    if (mounted) setState(() { _permissionsGranted = true; _isRequesting = false; });
  }();
}

void _showPermissionDeniedDialog() {
  if (!mounted || !context.mounted) return;
  showDialog(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(
    title: Text('권한 필요'),
    content: Text('카메라와 갤러리 권한이 필요합니다.\n설정에서 허용해 주세요.'),
    actions: [TextButton(onPressed: () { _returnedFromSettings = true; _permChannel.invokeMethod('openSettings'); Navigator.pop(ctx); }, child: Text('설정으로 이동'))],
  ));
}
```

### main.dart

```dart
import 'package:.../widgets/permission_wrapper.dart';
...
home: PermissionWrapper(cameras: cameras),
```

### HomePage `_doCameraInit` (ensure 제거)

```dart
Future<void> _doCameraInit(int viewId) async {
  if (_isDoCameraInitRunning) return;
  _isDoCameraInitRunning = true;
  try {
    // PermissionWrapper에서 이미 카메라·갤러리 권한 확보. ensure 제거.
    final targetRatio = _getTargetAspectRatio();
    await _cameraEngine.requestInitializeIfNeeded(viewId: viewId, cameraPosition: 'back', aspectRatio: targetRatio);
    // ... 이하 session 대기 등 기존 유지
  } finally { _isDoCameraInitRunning = false; }
}
```

(이때 `_cameraPermissionDenied` setState 및 `ensureCameraPermission` 호출 제거.)
