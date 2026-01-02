/// 공통 이미지 파이프라인 테스트
/// 
/// 프리뷰와 저장 파이프라인이 1:1 동일한 결과를 보장하는지 검증합니다.
import 'package:flutter_test/flutter_test.dart';
import 'package:mark_v2/core/shared_image_pipeline.dart';

void main() {
  group('SharedImagePipeline Tests', () {
    group('필터 수식 일치 테스트', () {
      test('펫톤 매트릭스 생성 (40% 강도)', () {
        final petToneMatrix = <double>[
          1.05, 0, 0, 0, 0,
          0, 1.05, 0, 0, 0,
          0, 0, 1.05, 0, 0,
          0, 0, 0, 1, 0,
        ];

        final result = SharedImagePipeline.buildPetToneMatrix(petToneMatrix);

        // 40% 믹스: identity + (petTone - identity) * 0.4
        // identity = [1, 0, 0, 0, 0, ...]
        // petTone = [1.05, 0, 0, 0, 0, ...]
        // result = 1 + (1.05 - 1) * 0.4 = 1 + 0.05 * 0.4 = 1.02
        expect(result[0], closeTo(1.02, 0.001));
        expect(result[6], closeTo(1.02, 0.001));
        expect(result[12], closeTo(1.02, 0.001));
      });

      test('필터 매트릭스 생성 (intensity 적용)', () {
        final filterMatrix = <double>[
          1.1, 0.05, 0, 0, 5,
          0, 0.95, 0.05, 0, 0,
          0, 0.05, 0.9, 0, 0,
          0, 0, 0, 1, 0,
        ];

        final result = SharedImagePipeline.buildFilterMatrix(filterMatrix, 0.8);

        // 80% 믹스: identity + (filter - identity) * 0.8
        // result[0] = 1 + (1.1 - 1) * 0.8 = 1 + 0.1 * 0.8 = 1.08
        expect(result[0], closeTo(1.08, 0.001));
        expect(result[4], closeTo(4.0, 0.001)); // offset도 믹스됨
      });

      test('밝기 매트릭스 생성 (HomePage용: -10 ~ +10)', () {
        final result = SharedImagePipeline.buildBrightnessMatrix(5.0);

        // brightness = 5.0 → offset = (5.0 / 10.0) * 255 * 0.1 = 12.75
        expect(result[4], closeTo(12.75, 0.01));
        expect(result[9], closeTo(12.75, 0.01));
        expect(result[14], closeTo(12.75, 0.01));
      });

      test('밝기 매트릭스 생성 (FilterPage용: -50 ~ +50)', () {
        final result = SharedImagePipeline.buildEditBrightnessMatrix(25.0);

        // editBrightness = 25.0 → offset = (25.0 / 50.0) * 40.0 = 20.0
        expect(result[4], closeTo(20.0, 0.01));
        expect(result[9], closeTo(20.0, 0.01));
        expect(result[14], closeTo(20.0, 0.01));
      });

      test('대비 매트릭스 생성 (FilterPage용: -50 ~ +50)', () {
        final result = SharedImagePipeline.buildContrastMatrix(25.0);

        // contrast = 25.0 → scale = 1.0 + (25.0 / 50.0) * 0.4 = 1.2
        expect(result[0], closeTo(1.2, 0.001));
        expect(result[6], closeTo(1.2, 0.001));
        expect(result[12], closeTo(1.2, 0.001));
      });

      test('선명도 값 계산 (FilterPage용: 0 ~ 100)', () {
        final result = SharedImagePipeline.calculateSharpnessValue(50.0);

        // sharpness = 50.0 → value = 50.0 / 100.0 = 0.5
        expect(result, closeTo(0.5, 0.001));
      });
    });

    group('크롭/비율 계산 일치 테스트', () {
      test('Aspect 크롭 계산 (1:1)', () {
        // 원본: 3000x2000 (3:2)
        // 목표: 1:1
        final crop = SharedImagePipeline.calculateAspectCrop(3000, 2000, 1.0);

        // 원본이 더 넓음 → 좌우를 자름
        // cropHeight = 2000
        // cropWidth = 2000 * 1.0 = 2000
        // cropX = (3000 - 2000) / 2 = 500
        expect(crop.width, 2000);
        expect(crop.height, 2000);
        expect(crop.x, 500);
        expect(crop.y, 0);
      });

      test('Aspect 크롭 계산 (9:16)', () {
        // 원본: 2000x3000 (비율: 2/3 = 0.667)
        // 목표: 9/16 = 0.5625
        // 원본 비율(0.667) > 목표 비율(0.5625) → 원본이 더 넓음 → 좌우를 자름
        final crop = SharedImagePipeline.calculateAspectCrop(2000, 3000, 9.0 / 16.0);

        // 원본이 더 넓음 → 좌우를 자름
        // cropHeight = 3000
        // cropWidth = 3000 * (9/16) = 1687.5 ≈ 1688
        // cropX = (2000 - 1688) / 2 = 156
        expect(crop.width, 1688);
        expect(crop.height, 3000);
        expect(crop.x, 156);
        expect(crop.y, 0);
      });

      test('Aspect 크롭 계산 (3:4)', () {
        // 원본: 3000x2000 (3:2)
        // 목표: 3:4
        final crop = SharedImagePipeline.calculateAspectCrop(3000, 2000, 3.0 / 4.0);

        // 원본이 더 넓음 → 좌우를 자름
        // cropHeight = 2000
        // cropWidth = 2000 * (3/4) = 1500
        // cropX = (3000 - 1500) / 2 = 750
        expect(crop.width, 1500);
        expect(crop.height, 2000);
        expect(crop.x, 750);
        expect(crop.y, 0);
      });
    });

    group('줌 매핑 일치 테스트', () {
      test('UI 줌을 네이티브 줌으로 매핑 (0.5~0.9 구간)', () {
        // 0.5~0.9 구간에서도 연속적으로 변해야 함
        final zoom1 = SharedImagePipeline.mapUiZoomToNative(0.5, 0.5, 10.0);
        final zoom2 = SharedImagePipeline.mapUiZoomToNative(0.6, 0.5, 10.0);
        final zoom3 = SharedImagePipeline.mapUiZoomToNative(0.7, 0.5, 10.0);
        final zoom4 = SharedImagePipeline.mapUiZoomToNative(0.8, 0.5, 10.0);
        final zoom5 = SharedImagePipeline.mapUiZoomToNative(0.9, 0.5, 10.0);

        expect(zoom1, 0.5);
        expect(zoom2, 0.6);
        expect(zoom3, 0.7);
        expect(zoom4, 0.8);
        expect(zoom5, 0.9);

        // 모든 값이 서로 다름 (dead-zone 없음)
        expect(zoom1, lessThan(zoom2));
        expect(zoom2, lessThan(zoom3));
        expect(zoom3, lessThan(zoom4));
        expect(zoom4, lessThan(zoom5));
      });

      test('UI 줌 클램핑 (범위 초과)', () {
        final zoom1 = SharedImagePipeline.mapUiZoomToNative(0.3, 0.5, 10.0);
        final zoom2 = SharedImagePipeline.mapUiZoomToNative(15.0, 0.5, 10.0);

        expect(zoom1, 0.5); // 최소값으로 클램프
        expect(zoom2, 10.0); // 최대값으로 클램프
      });
    });

    group('해상도 스케일링 일치 테스트', () {
      test('다운샘플링 계산 (1200px 초과)', () {
        // 원본: 3000x2000 (긴 변: 3000)
        // 최대: 1200
        final result = SharedImagePipeline.calculateDownsample(3000, 2000, 1200);

        // scale = 1200 / 3000 = 0.4
        // width = 3000 * 0.4 = 1200
        // height = 2000 * 0.4 = 800
        expect(result.width, 1200);
        expect(result.height, 800);
      });

      test('다운샘플링 계산 (1200px 이하)', () {
        // 원본: 1000x800 (긴 변: 1000)
        // 최대: 1200
        final result = SharedImagePipeline.calculateDownsample(1000, 800, 1200);

        // 다운샘플 불필요 (원본 유지)
        expect(result.width, 1000);
        expect(result.height, 800);
      });
    });

    group('오버레이 위치 계산 일치 테스트', () {
      test('오버레이 위치 계산 (center)', () {
        final pos = SharedImagePipeline.calculateOverlayPosition(
          2000, 3000, // 이미지 크기
          500, 300, // 오버레이 크기
          'center',
        );

        // x = (2000 - 500) / 2 = 750
        // y = (3000 - 300) / 2 = 1350
        expect(pos.x, 750.0);
        expect(pos.y, 1350.0);
      });

      test('오버레이 위치 계산 (top)', () {
        final pos = SharedImagePipeline.calculateOverlayPosition(
          2000, 3000,
          500, 300,
          'top',
        );

        expect(pos.x, 750.0);
        expect(pos.y, 0.0);
      });

      test('오버레이 위치 계산 (bottom)', () {
        final pos = SharedImagePipeline.calculateOverlayPosition(
          2000, 3000,
          500, 300,
          'bottom',
        );

        expect(pos.x, 750.0);
        expect(pos.y, 2700.0);
      });
    });

    group('전체 ColorMatrix 생성 일치 테스트', () {
      test('전체 파이프라인 매트릭스 생성', () {
        final config = SharedFilterConfig(
          filterKey: 'basic_soft',
          intensity: 0.8,
          brightness: 5.0,
          petToneId: 'dog_mid',
          enablePetTone: true,
          editBrightness: 25.0,
          editContrast: 25.0,
        );

        final petToneMatrix = <double>[
          1.05, 0, 0, 0, 0,
          0, 1.05, 0, 0, 0,
          0, 0, 1.05, 0, 0,
          0, 0, 0, 1, 0,
        ];

        final filterMatrix = <double>[
          1.03, 0.02, 0.02, 0, 0,
          0.01, 1.00, 0.00, 0, 0,
          0.00, 0.02, 0.98, 0, 0,
          0, 0, 0, 1, 0,
        ];

        final result = SharedImagePipeline.buildCompleteColorMatrix(
          config,
          petToneMatrix: petToneMatrix,
          filterMatrix: filterMatrix,
        );

        // 결과가 identity 매트릭스가 아니어야 함 (변환이 적용됨)
        expect(result[0], isNot(1.0));
        expect(result.length, 20);
      });
    });
  });
}

