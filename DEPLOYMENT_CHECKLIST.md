# 배포 준비 체크리스트

## ✅ 완료된 사항

### 1. 코드 수정 사항
- [x] `aspectRatioOf()` 함수에서 `nineSixteen`을 `9/16`으로 수정
- [x] 카메라 프리뷰를 단순화된 패턴으로 리팩터링
  - AspectRatio + ClipRect + FittedBox + SizedBox + CameraPreview 패턴 적용
  - 중복된 위젯 제거
- [x] Transform.scale을 전체 프리뷰를 감싸는 상위 위젯에만 적용
- [x] UI 줌 초기화 로직 추가 (비율 변경 시 자동 리셋)
- [x] 디버그 로그 추가 (프리뷰 비율 확인)

### 2. 빌드 및 컴파일
- [x] `flutter clean` 완료
- [x] `flutter pub get` 완료
- [x] iOS 빌드 성공 (`flutter build ios --no-codesign --release`)
- [x] 컴파일 오류 없음

### 3. 코드 분석
- [x] `flutter analyze` 완료
  - 심각한 오류 없음 (모두 warning 또는 info 레벨)
  - 사용되지 않는 필드/함수들은 기능에 영향 없음

### 4. 버전 정보
- [x] 버전: `1.0.0+8` (pubspec.yaml)

## 📋 배포 전 최종 확인 사항

### 기능 테스트 (실기기에서 확인 필요)
- [ ] 9:16 비율이 올바르게 표시되는지
- [ ] 3:4 비율이 올바르게 표시되는지
- [ ] 1:1 비율이 올바르게 표시되는지
- [ ] 카메라 프리뷰가 과도하게 확대되지 않는지
- [ ] 비율 변경 시 프리뷰가 올바르게 업데이트되는지
- [ ] UI 줌이 정상적으로 작동하는지
- [ ] 저장된 이미지가 원본 비율을 유지하는지
- [ ] 필터/밝기 적용이 정상적으로 작동하는지

### 스토어 제출 준비
- [ ] iOS: App Store Connect에 업로드 준비
  - [ ] Archive 생성 (`flutter build ipa`)
  - [ ] 코드 서명 확인
  - [ ] 앱 스크린샷 준비
  - [ ] 앱 설명 업데이트
- [ ] Android: Google Play Console에 업로드 준비 (나중에)
  - [ ] App Bundle 생성 (`flutter build appbundle --release`)
  - [ ] 서명 키 확인
  - [ ] 앱 스크린샷 준비

## 🔍 디버그 로그 확인

프리뷰 비율 확인을 위한 로그:
```
[Petgram] preview layout: aspectMode=..., targetRatio=..., cameraAspect=...
```

이 로그를 통해 프리뷰 비율이 올바르게 설정되었는지 확인할 수 있습니다.

## 📝 변경 사항 요약

### 주요 수정 사항
1. **카메라 프리뷰 비율 수정**: `9/15` → `9/16`
2. **프리뷰 구조 단순화**: 중복 위젯 제거, 단순화된 패턴 적용
3. **UI 줌 초기화**: 비율 변경 시 자동 리셋
4. **디버그 로그 추가**: 프리뷰 비율 확인 가능

### 예상 효과
- 카메라 프리뷰가 정상 비율로 표시됨
- 과도한 확대 문제 해결
- 비율 변경 시 프리뷰가 올바르게 업데이트됨
- 저장된 이미지가 원본 비율 유지

## 🚀 배포 명령어

### iOS 배포
```bash
# Archive 생성 (Xcode에서)
flutter build ipa --release

# 또는 Xcode에서 직접 Archive
# Product > Archive
```

### Android 배포 (나중에)
```bash
flutter build appbundle --release
```

## ⚠️ 주의사항

1. 실기기에서 반드시 테스트 후 배포
2. 프리뷰 비율이 올바르게 표시되는지 확인
3. 저장된 이미지가 원본 비율을 유지하는지 확인
4. 모든 비율 모드(9:16, 3:4, 1:1)에서 정상 작동 확인
