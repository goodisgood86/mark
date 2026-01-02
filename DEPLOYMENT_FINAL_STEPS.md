# 🚀 최종 배포 단계 (v1.0.0+8)

## ✅ 빌드 완료

- iOS Release 빌드 성공
- 빌드 위치: `build/ios/iphoneos/Runner.app`
- 크기: 40.7MB

## 📋 Xcode에서 Archive 및 업로드

### 1. Xcode 설정 확인

1. Xcode가 열리면 상단 메뉴에서:
   - **Product > Scheme > Runner** 선택
   - **Product > Destination > Any iOS Device** 선택 (시뮬레이터 아님!)

### 2. Archive 생성

1. **Product > Archive** 클릭
2. Archive 완료 대기 (몇 분 소요)
3. Archive 완료 후 Organizer 창이 자동으로 열림

### 3. App Store Connect에 업로드

1. Organizer 창에서 방금 생성한 Archive 선택
2. **Distribute App** 버튼 클릭
3. **App Store Connect** 선택
4. **Upload** 선택
5. 다음 단계들을 따라 진행:
   - Distribution options: 기본 설정 유지
   - App Thinning: All compatible device variants
   - Re-sign: 필요시 자동 서명
6. **Upload** 클릭
7. 업로드 완료 대기

### 4. App Store Connect에서 설정

1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. **내 앱** 메뉴에서 앱 선택
3. **TestFlight** 또는 **App Store** 탭으로 이동
4. 업로드된 빌드가 표시될 때까지 대기 (몇 분~수십 분 소요)
5. 빌드 선택 후:
   - **TestFlight**: 베타 테스터에게 배포
   - **App Store**: 앱 정보 입력 후 심사 제출

## 📝 배포 전 최종 확인

### 수정된 사항
- ✅ 카메라 초기화 에러 처리 개선
- ✅ viewId 설정 순서 문제 해결
- ✅ 프로그래밍 버그와 실제 카메라 불가능 상황 구분
- ✅ 디버그 오버레이 활성화 (릴리즈 빌드에서도 표시)

### 테스트 권장 사항
- [ ] 실기기에서 카메라 초기화 정상 작동 확인
- [ ] 디버그 오버레이에서 상태 확인
- [ ] 비율 변경 시 재초기화 정상 작동 확인

## 🎯 배포 후 모니터링

1. **TestFlight 테스트**: 베타 테스터에게 배포하여 실기기 테스트
2. **디버그 로그 확인**: 디버그 오버레이를 통해 문제 발생 시 즉시 파악
3. **크래시 리포트**: App Store Connect에서 크래시 리포트 확인

---

**배포 준비 완료!** Xcode에서 Archive를 진행하세요.

