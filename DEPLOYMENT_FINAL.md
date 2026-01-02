# 🚀 Petgram 배포 최종 확인 및 가이드

**점검 일시**: 2024-12-19  
**버전**: 1.0.0+8  
**Bundle ID**: com.mark.petgram

---

## ✅ 최종 오류 확인 결과

### 컴파일 상태
- ✅ **에러(Error)**: 0개
- ⚠️ **경고(Warning)**: 21개 (모두 사용하지 않는 필드/함수 - 배포에 영향 없음)
- ✅ **컴파일 성공**: 확인 완료

### 개발 환경
- ✅ Flutter: 3.38.3 (정상)
- ✅ Xcode: 26.1.1 (정상)
- ✅ iOS 배포: 준비 완료

---

## ✅ 최신 변경사항 확인

### 1. 실기기 Mock 카메라 방지
- ✅ 실기기에서 `cameras.isNotEmpty`이면 무조건 네이티브 카메라 사용
- ✅ Mock 카메라는 시뮬레이터/카메라 없는 기기에서만 사용

### 2. EXIF 방향 정규화
- ✅ `petgram_image_orientation.dart` 서비스 추가
- ✅ HomePage 갤러리 이미지 선택 시 EXIF 정규화
- ✅ FilterPage 이미지 로딩 시 EXIF 정규화
- ✅ `exif: ^3.3.0` 패키지 추가 완료

### 3. UI 통일
- ✅ 네비게이션 바 색상 통일 (#FCE4EC)
- ✅ 하단 SafeArea 색상 통일
- ✅ 모든 페이지 일관성 확보

---

## 📱 앱 정보

### 기본 정보
- **앱 이름**: Petgram
- **버전**: 1.0.0+8
- **iOS Bundle ID**: `com.mark.petgram`
- **Android Package**: `com.mark.petgram`

### 주요 기능
- ✅ 네이티브 카메라 (iOS)
- ✅ 필터/보정 기능
- ✅ 프레임 적용
- ✅ EXIF 메타데이터 저장 (Base64Url 인코딩)
- ✅ EXIF 방향 정규화 (최신 추가)
- ✅ 로컬 SQLite DB 저장
- ✅ 위치 정보 연동
- ✅ 인앱 결제 (후원하기)
- ✅ Mock 카메라 (시뮬레이터 대응)

---

## 🔒 권한 설정 확인

### iOS (Info.plist) ✅
- ✅ `NSCameraUsageDescription`: "반려동물 사진을 촬영하기 위해 카메라 권한이 필요합니다."
- ✅ `NSPhotoLibraryAddUsageDescription`: "필터 적용한 사진을 갤러리에 저장하기 위해 필요합니다."
- ✅ `NSPhotoLibraryUsageDescription`: "갤러리에서 사진을 선택하기 위해 필요합니다."
- ✅ `NSLocationWhenInUseUsageDescription`: "촬영한 사진의 위치 정보를 표시하기 위해 내 위치를 사용합니다."

---

## 🚀 iOS 배포 단계

### 1. Xcode 프로젝트 열기
```bash
cd /Users/grepp/mark_v2
open ios/Runner.xcworkspace
```

### 2. 빌드 설정 확인
1. Xcode에서 **Runner** 프로젝트 선택
2. **Signing & Capabilities** 탭 확인
3. **Team** 선택 (Apple Developer 계정)
4. **Automatically manage signing** 체크

### 3. Archive 생성
1. Xcode 메뉴: **Product** > **Scheme** > **Runner** 선택
2. **Product** > **Destination** > **Any iOS Device** 선택
3. **Product** > **Archive** 실행
4. Archive가 완료되면 **Organizer** 창이 자동으로 열림

### 4. App Store Connect 업로드
1. **Organizer** 창에서 생성된 Archive 선택
2. **Distribute App** 버튼 클릭
3. **App Store Connect** 선택
4. **Upload** 선택
5. 다음 단계들 진행:
   - Distribution options 확인
   - Re-sign (필요시)
   - **Upload** 클릭

### 5. App Store Connect 설정
1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. **내 앱** > **Petgram** 선택 (또는 새로 생성)
3. **버전** 탭에서 다음 정보 입력:
   - 앱 설명
   - 키워드
   - 스크린샷 (필수)
   - 앱 아이콘
   - 개인정보 처리방침 URL
4. **빌드 선택** 후 업로드된 빌드 선택
5. **검토 제출**

---

## 🧪 배포 전 테스트 권장

### 필수 테스트 항목
- [ ] **실기기에서 네이티브 카메라 작동 확인**
  - Mock 카메라가 나타나지 않는지 확인
  - 촬영 → 필터 → 저장 플로우 정상 작동

- [ ] **EXIF 방향 정규화 테스트**
  - 16:9 세로 사진 (정방향 표시 확인)
  - 3:4 세로 사진 (정방향 표시 확인)
  - 가로 사진 (정방향 표시 확인)
  - 갤러리에서 선택한 이미지가 올바른 방향으로 표시되는지

- [ ] **기본 기능 테스트**
  - 카메라 촬영 → 필터 적용 → 저장
  - 갤러리에서 사진 선택 → 필터 적용 → 저장
  - EXIF 메타데이터 저장/복원
  - 위치 정보 저장 (위치 활성화 시)

### 시뮬레이터 테스트
- [ ] Mock 카메라 정상 작동 (시뮬레이터에서만)
- [ ] FilterPage 정상 작동

---

## 📋 최종 체크리스트

### 코드 품질 ✅
- [x] 컴파일 에러 0개
- [x] 크리티컬 경고 없음
- [x] 디버그 코드 정리 완료 (`kDebugMode` 사용)
- [x] 메모리 관리 확인 (이미지 dispose 등)

### 설정 파일 ✅
- [x] `pubspec.yaml` 버전: `1.0.0+8`
- [x] Bundle ID 확인: `com.mark.petgram`
- [x] 권한 설명 한국어로 설정 완료
- [x] 의존성 패키지 정상 설치

### 최신 기능 ✅
- [x] 실기기 Mock 카메라 방지 로직 적용
- [x] EXIF 방향 정규화 구현
- [x] UI 통일 완료

---

## 📝 참고 사항

### 디버그 모드 vs Release 모드
- **디버그 모드**: Settings 페이지에 "DB 상태 확인" 버튼 표시, 모든 로그 출력
- **Release 모드**: 디버그 UI 숨김, 로그 출력 안 됨, 모든 기능 정상 작동

### EXIF 메타데이터
- Base64Url 인코딩으로 한글 보존
- 포맷: `PETGRAM|v=1|shot=1|edited=1|frame=...|ts=...|meta64=...`
- 하위 호환: 기존 `meta=` 필드도 파싱 지원

### EXIF 방향 정규화
- 모든 이미지가 정방향(upright)으로 표시
- Orientation 값(1-8) 자동 처리
- 정규화된 이미지는 Orientation = 1로 저장

### Mock 카메라 동작
- **실기기**: 절대 Mock 사용 안 함 (네이티브 카메라만)
- **시뮬레이터**: Mock 카메라 자동 사용
- **카메라 없음**: Mock 카메라 사용

---

## 🎉 배포 준비 완료!

### 다음 단계
1. ✅ 실기기에서 최종 테스트 수행
2. ✅ Xcode에서 Archive 생성
3. ✅ App Store Connect에 업로드
4. ✅ 앱 정보 입력 및 심사 제출

**모든 준비가 완료되었습니다. 배포를 진행하세요!** 🚀

---

**마지막 업데이트**: 2024-12-19  
**버전**: 1.0.0+8  
**상태**: 배포 준비 완료 ✅

