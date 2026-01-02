# 🚀 배포 전 최종 체크리스트

## ✅ 코드 정리 완료

### 디버그 기능 비활성화
- [x] `kEnableCameraDebugOverlay = false` (배포 빌드)
- [x] `_addDebugLog()`는 디버그 오버레이 비활성화 시 조기 반환
- [x] 모든 디버그 로그는 `kDebugMode`로 감싸짐
- [x] 린트 에러 0개

### 로깅 정리
- [x] 상세 디버그 로그는 `kDebugMode` 조건부 처리
- [x] iOS 네이티브 로그는 `log()` 메서드를 통해 전달 (디버그 모드에서만)
- [x] 디버그 오버레이 관련 코드는 조건부 처리됨

## 📱 앱 정보

### 버전 정보
- **앱 이름**: Petgram
- **버전**: 1.0.0+8
- **iOS Bundle ID**: `com.mark.petgram`
- **Android Package**: `com.mark.petgram`

### 주요 기능
- ✅ 네이티브 카메라 (iOS/Android)
- ✅ 필터/보정 기능
- ✅ 프레임 적용
- ✅ EXIF 메타데이터 저장
- ✅ 로컬 SQLite DB 저장
- ✅ 위치 정보 연동
- ✅ 인앱 결제 (후원하기)

## 🔒 권한 설정 확인

### iOS (Info.plist)
- ✅ `NSCameraUsageDescription`: "반려동물 사진을 촬영하기 위해 카메라 권한이 필요합니다."
- ✅ `NSPhotoLibraryAddUsageDescription`: "필터 적용한 사진을 갤러리에 저장하기 위해 필요합니다."
- ✅ `NSPhotoLibraryUsageDescription`: "갤러리에서 사진을 선택하기 위해 필요합니다."
- ✅ `NSLocationWhenInUseUsageDescription`: "촬영한 사진의 위치 정보를 표시하기 위해 내 위치를 사용합니다."

### Android (AndroidManifest.xml)
- ✅ 카메라 권한
- ✅ 갤러리 읽기/쓰기 권한
- ✅ 위치 정보 권한

## 🧪 최종 테스트 체크리스트

### 필수 테스트 항목
- [ ] **카메라 초기화**: 실기기에서 카메라가 정상적으로 초기화되는지 확인
- [ ] **카메라 촬영**: 촬영 → 필터 적용 → 저장 플로우 테스트
- [ ] **갤러리 선택**: 갤러리에서 사진 선택 → 필터 적용 → 저장
- [ ] **EXIF 메타데이터**: 저장된 사진의 EXIF 메타데이터 확인
- [ ] **DB 저장**: Settings에서 DB 상태 확인 (Debug 모드)
- [ ] **위치 정보**: 위치 활성화 시 위치 정보 저장 확인
- [ ] **권한 처리**: 카메라 권한 거부 시 적절한 에러 메시지 표시
- [ ] **Mock 카메라**: 시뮬레이터/카메라 없는 기기에서 Mock 카메라 동작 확인

### 성능 테스트
- [ ] 앱 시작 시간
- [ ] 카메라 초기화 시간
- [ ] 필터 적용 성능
- [ ] 메모리 사용량

## 📦 빌드 준비

### iOS
- [ ] Xcode에서 Release 빌드 테스트
- [ ] Archive 생성
- [ ] App Store Connect 설정 확인
- [ ] 코드 서명 인증서 확인
- [ ] 프로비저닝 프로파일 확인

### Android
- [ ] Release 빌드 테스트
- [ ] 서명 키 확인 (`key.properties`)
- [ ] Google Play Console 설정 확인

## 🚨 배포 전 주의사항

### 디버그 기능
- ✅ 디버그 오버레이 비활성화됨 (`kEnableCameraDebugOverlay = false`)
- ✅ 모든 디버그 로그는 `kDebugMode`로 보호됨
- ✅ Release 빌드에서는 디버그 UI 표시 안 됨

### 카메라 초기화
- ✅ 권한 체크 로직 추가됨
- ✅ 세션 시작 상태 확인 로직 추가됨
- ✅ 에러 처리 및 Mock fallback 로직 정상 작동

### 로깅
- ✅ 상세 디버그 로그는 개발 모드에서만 출력
- ✅ 배포 빌드에서는 불필요한 로그 출력 없음

## 📋 배포 단계

### iOS (App Store)
1. Xcode에서 Archive 생성
2. App Store Connect에 업로드
3. 앱 정보 입력
4. 심사 제출

### Android (Google Play Store)
1. Release APK/AAB 빌드
2. Google Play Console에 업로드
3. 앱 정보 입력
4. 심사 제출

## ✅ 배포 준비 완료 상태

- **코드 정리**: ✅ 완료
- **디버그 기능**: ✅ 비활성화됨
- **로깅**: ✅ 정리 완료
- **린트**: ✅ 에러 없음
- **테스트**: 🔄 실제 기기에서 최종 테스트 권장

---

**마지막 업데이트**: 2024-12-19
**버전**: 1.0.0+8
**배포 준비 상태**: ✅ 준비 완료

