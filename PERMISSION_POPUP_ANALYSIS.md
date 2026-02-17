# 권한 팝업이 안 뜨고 "설정으로 이동"만 나오는 원인 분석

## 1. 흐름 요약

### Flutter (PermissionWrapper)
1. **initState** → `addPostFrameCallback` → `_preCheckGranted()`
2. **_preCheckGranted**
   - `checkCameraPermission`, `checkPhotoLibraryPermission` 호출 (status만 읽기, **요청 아님**)
   - 둘 다 3 → `_permissionsGranted=true` → HomePage
   - 하나라도 !=3 → 700ms 후 `_requestPermissionsOnce()`
3. **_requestPermissionsOnce**
   - `ensureCameraPermission` (await) → 400ms → `ensurePhotoLibraryPermission` (await)
   - 둘 다 3 → HomePage
   - 하나라도 !=3 → `_canRequest=false` + `_showSettingsPopup()` → "설정으로 이동" UI

### Native (ensureCameraPermission)
1. `wasHandling || wasRequesting || alreadyRequested` 이면 **스킵** → `alreadyRequested`일 때만 `result(현재 status)` 호출 후 return
2. `authStatus = AVCaptureDevice.authorizationStatus(for: .video)`
3. **`authStatus != .notDetermined`** 이면  
   → `result(statusCode)` **즉시 return, `requestAccess` 호출 안 함** → **시스템 팝업 없음**
4. `authStatus == .notDetermined`일 때만  
   → `tryRequest()` → … → `AVCaptureDevice.requestAccess(for: .video)` 호출 → **이때만 시스템 팝업**

### Native (ensurePhotoLibraryPermission)
- `authStatus != .notDetermined` 이면 `result(statusCode)` 즉시 return, `requestAuthorization` 호출 안 함.
- `authStatus == .notDetermined`일 때만 `PHPhotoLibrary.requestAuthorization(for: .readWrite)` 호출.

---

## 2. "팝업 없이 설정으로 이동"이 나오는 조건

- `ensure*`에서 **`result(2)` (또는 0, 1)** 가 호출되면  
  → Flutter가 `(c ?? 2) != 3 || (g ?? 2) != 3` 으로 판단 → `_canRequest=false` + 설정 팝업/페이지.
- `result(2)`가 나오는 대표 경로:
  1. **`authStatus != .notDetermined`**  
     - 이미 **거부/허용/제한** 되어 있어서, `requestAccess` / `requestAuthorization` 를 **호출하지 않고**  
       `result(statusCode)` 만 호출.
     - 이때는 시스템 권한 팝업이 절대 안 뜸.
  2. **`finish(false, …)`**  
     - `poll_timeout`, `app_background_timeout` 등으로 `requestAccess`를 기다리다가 실패.

즉, **"팝업 없이 설정으로 이동" = `authStatus != .notDetermined` 인 상태에서 ensure가 실행된 경우가 대부분**이다.

---

## 3. `authStatus != .notDetermined`가 되는 경우

1. **이전에 이미 거부/허용한 경우**
   - 같은 앱을 이전에 실행해서 카메라/갤러리에서 "허용" 또는 "허용 안 함"을 선택했으면  
     이후에는 `authStatus`가 `.denied` 또는 `.authorized` 로 고정.
   - 이 상태에서 ensure를 호출해도 `requestAccess`/`requestAuthorization` 는 호출되지 않고,  
     현재 값만 반환 → Flutter는 2 또는 3을 받고, 2이면 "설정으로 이동"으로 간다.

2. **시뮬레이터**
   - 카메라가 없으면 `AVCaptureDevice.authorizationStatus(for: .video)` 가  
     `.denied` 를 반환하는 경우가 많음.
   - `requestAccess` 를 호출해도, 시뮬레이터에선 시스템 팝업이 안 뜨고  
     곧바로 `granted=false` 로 콜백되는 경우가 많음.

3. **앱/다른 코드가 더 먼저 `requestAccess` / `requestAuthorization` 를 호출한 경우**
   - 그때 사용자가 "허용 안 함"을 누르면, 그 시점에 `authStatus`가 `.denied` 로 바뀜.
   - 이후 우리 `ensure*` 가 돌 때는 이미 `.notDetermined` 가 아니므로  
     `requestAccess`/`requestAuthorization` 를 호출하지 않고, `result(2)` 만 반환.

현재 구조상:
- `main()` 에서 iOS일 때 `availableCameras()` 를 호출하지 않음.
- `NativeCamera` 등록/초기화만 하고, **카메라 세션/캡처는 HomePage(권한 통과 후)에서만** 쓰도록 되어 있어,  
  우리 코드가 **ensure 이전에** `requestAccess` 를 호출하는 경로는 보이지 않음.  
  (다른 플러그인/라이브러리가 네이티브에서 먼저 호출하는지는 별도 확인 필요.)

---

## 4. 정리: 왜 팝업이 안 보이는가

- **`authStatus != .notDetermined`** 이면,  
  네이티브 `ensure*` 는 **`requestAccess` / `requestAuthorization` 를 호출하지 않고**  
  현재 `statusCode` 만 `result(...)` 로 돌려준다.  
  → 이 경우 **시스템 권한 팝업은 절대 발생하지 않는다.**
- 그래서:
  - **한 번이라도 거부/허용을 선택한 이후**,  
    또는
  - **시뮬레이터처럼 처음부터 `.denied` 인 환경**  
  에서는 "권한 요청 중" 인디케이터만 잠깐 돌고, 곧바로 "설정으로 이동"만 보이게 된다.

---

## 5. 대응 방향

1. **`authStatus == .notDetermined` 일 때만 팝업이 뜬다**  
   - 이건 iOS 동작이므로, 우리가 “강제로 한 번 더 팝업”을 띄우는 것은 불가능.
   - `.denied` 상태에서 `requestAccess` 를 다시 호출해도, iOS는 팝업을 띄우지 않고  
     `granted=false` 만 콜백한다.

2. **확실히 팝업을 보이게 하려면**
   - **실기기**에서,
   - **앱 삭제 후 재설치** 해서 `authStatus` 를 `.notDetermined` 로 만든 다음,
   - 그 상태에서 ensure가 실행되도록 하는 수밖에 없다.

3. **코드 측 개선 (의도 불일치·중복 제거)**
   - `check`로 “이미 3,3이면 ensure 생략” 하는 shortcut이 있으면,  
     **ensure만 보는 단일 경로**로 맞추는 편이 디버깅에 유리.
   - ensure 쪽은:  
     - `authStatus == .notDetermined` → `requestAccess` / `requestAuthorization` 호출 (현재와 동일)  
     - `authStatus != .notDetermined` → `result(statusCode)` 만 호출 (현재와 동일)  
     이 동작을 유지하면, “팝업이 나와야 할 때”는 `.notDetermined` 인 첫 실행 구간뿐이다.

4. **앱 시작 시 `ensure` 전에 static 플래그 정리**
   - `hasRequestedCameraAccess`, `didFinishCameraPermission` 등이  
     이전 세션/재진입 시 잘못 켜져 있으면, 엔트리 스킵으로 `requestAccess`까지 안 갈 수 있다.
   - 앱 구동 시점(또는 ensure 최초 1회)에, **ensure용 static 플래그를 한 번 초기화**해 두면  
     “첫 ensure” 경로가 더 예측 가능해진다.

---

## 6. 시뮬레이터 vs 실기기

- **시뮬레이터**  
  - 카메라/사진 라이브러리 권한이 `.denied` 이거나, `requestAccess` 호출 시 팝업 없이 거부로 끝나는 경우가 많다.  
  - “권한 팝업이 안 뜬다”는 현상이 시뮬레이터에서만 발생할 수 있다.
- **실기기 + 앱 삭제 후 재설치**  
  - `authStatus == .notDetermined` 인 상태에서 ensure가 한 번이라도 실행되면,  
    그때는 `requestAccess` / `requestAuthorization` 가 호출되고, 시스템 팝업이 한 번은 뜬다.

이 문서는 위 흐름을 기준으로,  
- Flutter: check 의존을 줄이고 **ensure 단일 경로**로 정리,  
- Native: ensure 실행 전/앱 구동 시 **static 플래그 초기화**  
를 적용한 변경과 함께 두면, “팝업이 왜 안 뜨는지”를 코드와 동작으로 맞춰서 추적하기 쉬워진다.
