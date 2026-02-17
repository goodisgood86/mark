# 📱 TestFlight vs App Store Connect

## ✅ 핵심 정리

**한 번만 업로드하면 됩니다!**

같은 빌드를 TestFlight와 App Store 배포 모두에 사용할 수 있습니다.

---

## 🔄 빌드 업로드 프로세스

### 1단계: 빌드 업로드 (한 번만)

1. **Xcode에서 Archive**
   - Product > Archive

2. **App Store Connect에 업로드**
   - Distribute App > App Store Connect > Upload
   - ✅ **이것만 하면 끝!**

---

### 2단계: 빌드 사용 (두 가지 방법)

#### 방법 1: TestFlight (베타 테스트)
1. App Store Connect > **TestFlight** 탭
2. 업로드한 빌드가 자동으로 표시됨
3. 테스터 초대 및 테스트

#### 방법 2: App Store 배포
1. App Store Connect > **앱 스토어** 탭
2. **버전** 페이지에서 빌드 선택
3. 앱 정보 입력 후 검토 제출

---

## 📋 상세 설명

### TestFlight란?
- **베타 테스트 플랫폼**
- 앱을 실제 사용자에게 배포하기 전에 테스트
- 최대 10,000명의 외부 테스터
- 최대 100명의 내부 테스터

### App Store Connect란?
- **앱 배포 관리 플랫폼**
- TestFlight, App Store 배포 모두 관리
- 앱 정보, 스크린샷, 검토 제출 등

---

## 🎯 실제 사용 시나리오

### 시나리오 1: TestFlight만 사용
1. 빌드 업로드 ✅
2. TestFlight에서 테스터 초대
3. 테스트 완료
4. **끝** (App Store에 출시 안 함)

### 시나리오 2: TestFlight → App Store
1. 빌드 업로드 ✅
2. TestFlight에서 테스트
3. 문제 없으면 App Store에 제출
4. **같은 빌드 사용!**

### 시나리오 3: 바로 App Store
1. 빌드 업로드 ✅
2. TestFlight 건너뛰기
3. 바로 App Store에 제출

---

## ✅ 체크리스트

### 빌드 업로드 (한 번만)
- [ ] Xcode에서 Archive
- [ ] App Store Connect에 업로드
- [ ] 업로드 완료 확인

### TestFlight 사용 (선택사항)
- [ ] TestFlight 탭에서 빌드 확인
- [ ] 테스터 초대
- [ ] 테스트 진행

### App Store 배포
- [ ] 앱 스토어 > 버전에서 빌드 선택
- [ ] 앱 정보 입력
- [ ] 검토 제출

---

## 💡 중요 사항

### 같은 빌드 사용
- ✅ TestFlight와 App Store에 **같은 빌드** 사용 가능
- ✅ 한 번만 업로드하면 됨
- ✅ TestFlight에서 테스트 후 문제 없으면 같은 빌드를 App Store에 제출

### 빌드 번호
- TestFlight와 App Store 모두 **같은 빌드 번호** 사용
- 빌드 번호는 계속 증가: 1, 2, 3, 4...

### 버전 관리
- TestFlight: 빌드만 있으면 됨
- App Store: 버전 정보 + 빌드 필요

---

## 🎯 요약

**질문: TestFlight와 App Store Connect에 따로 올려야 하나요?**

**답변: 아니요! 한 번만 업로드하면 됩니다.**

1. **빌드 업로드** (한 번만)
   - Xcode > Archive > App Store Connect 업로드

2. **TestFlight 사용** (선택사항)
   - TestFlight 탭에서 테스터 초대

3. **App Store 배포**
   - 앱 스토어 > 버전에서 같은 빌드 선택
   - 앱 정보 입력 후 제출

**핵심: 같은 빌드를 TestFlight와 App Store 모두에 사용할 수 있습니다!**

