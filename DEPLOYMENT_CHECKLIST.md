# 🚀 배포 준비 체크리스트

## ✅ 코드 검증

- [x] Flutter analyze 에러 0개
- [x] 디버그 모드 코드 정리 (`kDebugMode`로 감쌈)
- [x] DB 초기화 로직 확인 (Release 빌드에서도 정상 작동)
- [x] Base64Url 인코딩 검증 완료

## 📱 앱 정보

### 버전 정보
- **앱 이름**: Petgram
- **버전**: 1.0.0+8
- **iOS Bundle ID**: `com.mark.petgram`
- **Android Package**: `com.mark.petgram`

### 주요 기능
- ✅ 네이티브 카메라 (iOS)
- ✅ 필터/보정 기능
- ✅ 프레임 적용
- ✅ EXIF 메타데이터 저장 (Base64Url 인코딩)
- ✅ 로컬 SQLite DB 저장
- ✅ 위치 정보 연동
- ✅ 인앱 결제 (후원하기)

## 🔒 권한 설정

### iOS (Info.plist)
- ✅ `NSCameraUsageDescription`: "반려동물 사진을 촬영하기 위해 카메라 권한이 필요합니다."
- ✅ `NSPhotoLibraryAddUsageDescription`: "필터 적용한 사진을 갤러리에 저장하기 위해 필요합니다."
- ✅ `NSPhotoLibraryUsageDescription`: "갤러리에서 사진을 선택하기 위해 필요합니다."
- ✅ `NSLocationWhenInUseUsageDescription`: "촬영한 사진의 위치 정보를 표시하기 위해 내 위치를 사용합니다."

### Android (AndroidManifest.xml)
- ✅ 카메라 권한
- ✅ 갤러리 읽기/쓰기 권한
- ✅ 위치 정보 권한

## 📦 빌드 준비

### iOS
- [x] Xcode 설치 확인
- [x] Release 빌드 테스트 완료
- [ ] App Store Connect 설정 필요
- [ ] 코드 서명 인증서 설정 필요
- [ ] 프로비저닝 프로파일 설정 필요

### Android
- [ ] Android SDK 설치 필요
- [ ] 서명 키 생성 필요 (`key.properties` 설정)
- [ ] Google Play Console 설정 필요

## 🧪 테스트 체크리스트

### 필수 테스트 항목
- [ ] 카메라 촬영 → 필터 적용 → 저장
- [ ] 갤러리에서 사진 선택 → 필터 적용 → 저장
- [ ] EXIF 메타데이터 저장/복원 확인
- [ ] DB 저장 확인 (Settings에서 확인 가능 - Debug 모드)
- [ ] 위치 정보 저장 (위치 활성화 시)
- [ ] Mock 카메라 (시뮬레이터/카메라 없는 기기)
- [ ] 네이티브 카메라 (실제 iOS 기기)

## 📋 배포 전 최종 확인

### 코드 품질
- [x] 에러 없음
- [x] 경고만 존재 (사용하지 않는 필드 등 - 배포에 영향 없음)
- [x] 디버그 코드 정리 완료

### 설정 파일
- [x] `pubspec.yaml` 버전 확인: `1.0.0+8`
- [x] Bundle ID/Package 확인: `com.mark.petgram`
- [x] 권한 설명 한국어로 설정 완료

### Release 빌드 특성
- [x] 디버그 UI 제거 (`kDebugMode` 사용)
- [x] 디버그 로그 비활성화
- [x] DB 초기화는 항상 실행 (기능 필수)

## 🚀 배포 단계

### iOS (App Store)
1. Xcode에서 Archive 생성
2. App Store Connect에 업로드
3. 앱 정보 입력
4. 심사 제출

### Android (Google Play Store)
1. Android SDK 설치 후
2. 서명 키 생성
3. Release APK/AAB 빌드
4. Google Play Console에 업로드
5. 앱 정보 입력
6. 심사 제출

## 📝 참고 사항

### 디버그 모드 vs Release 모드
- **디버그 모드**: Settings 페이지에 "DB 상태 확인" 버튼 표시, 모든 로그 출력
- **Release 모드**: 디버그 UI 숨김, 로그 출력 안 됨, 모든 기능 정상 작동

### DB 확인 방법 (Debug 모드만)
1. 앱 실행 시 콘솔에 자동 출력
2. Settings 페이지 → "DB 상태 확인" 버튼 클릭

### EXIF 메타데이터
- Base64Url 인코딩으로 한글 보존
- 포맷: `PETGRAM|v=1|shot=1|edited=1|frame=...|ts=...|meta64=...`
- 하위 호환: 기존 `meta=` 필드도 파싱 지원

## ✅ 배포 준비 완료 상태

- **코드**: ✅ 준비 완료
- **iOS 빌드**: ✅ 테스트 완료 (Release)
- **Android 빌드**: ⚠️ Android SDK 설정 필요
- **설정**: ✅ 완료
- **테스트**: 🔄 실제 기기에서 최종 테스트 권장

---

**마지막 업데이트**: 2024-12-19
**버전**: 1.0.0+8
