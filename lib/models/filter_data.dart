import 'package:flutter/material.dart';
import 'filter_models.dart';

/// 반려동물 종 + 털톤에 따른 자동 보정 프로파일
/// 과격한 보정이 아닌 "조금 더 예쁘게 보정된 원본" 수준으로 설계
const Map<String, PetToneProfile> kPetToneProfiles = {
  // 강아지 (dog)
  'dog_light': PetToneProfile(
    id: 'dog_light',
    matrix: [
      // 하이라이트 클리핑 줄이기 + 미세한 warm 톤
      0.98, 0.01, 0.01, 0, 3, // R: 약간 감마 ↓, offset +
      0.01, 0.98, 0.01, 0, 3, // G: 약간 감마 ↓, offset +
      0.01, 0.01, 0.98, 0, 3, // B: 약간 감마 ↓, offset +
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'dog_mid': PetToneProfile(
    id: 'dog_mid',
    matrix: [
      // 미세 S-curve + 채도 약간 증가
      1.05, 0, 0, 0, 0, // R: 중간톤 대비 살짝 ↑
      0, 1.05, 0, 0, 0, // G: 중간톤 대비 살짝 ↑
      0, 0, 1.05, 0, 0, // B: 중간톤 대비 살짝 ↑
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'dog_dark': PetToneProfile(
    id: 'dog_dark',
    matrix: [
      // Shadow lift + 전체 대비 약간 ↑
      1.02, 0, 0, 0, 2, // R: shadow lift, 대비 약간 ↑
      0, 1.02, 0, 0, 2, // G: shadow lift, 대비 약간 ↑
      0, 0, 1.02, 0, 2, // B: shadow lift, 대비 약간 ↑
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  // 고양이 (cat)
  'cat_light': PetToneProfile(
    id: 'cat_light',
    matrix: [
      // White balance 약간 neutral + 채도 살짝만
      0.99, 0.005, 0.005, 0, 0, // R: 붉은기/노란기 조금 줄임
      0.005, 1.01, 0.005, 0, 0, // G: 녹색 미세 보정
      0.005, 0.005, 1.01, 0, 0, // B: 파랑 미세 보정
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'cat_mid': PetToneProfile(
    id: 'cat_mid',
    matrix: [
      // 약간 차가운 톤 + 눈 색 강화
      0.98, 0, 0, 0, 0, // R: red 살짝 -
      0, 1.02, 0, 0, 0, // G: green + (눈 색 강화)
      0, 0, 1.02, 0, 0, // B: blue + (눈 색 강화)
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
  'cat_dark': PetToneProfile(
    id: 'cat_dark',
    matrix: [
      // Dark fur lift + 채도 유지
      1.01, 0, 0, 0, 1.5, // R: shadow lift (과하지 않게)
      0, 1.01, 0, 0, 1.5, // G: shadow lift (과하지 않게)
      0, 0, 1.01, 0, 1.5, // B: shadow lift (과하지 않게)
      0, 0, 0, 1, 0, // Alpha
    ],
  ),
};

/// 촬영/편집 화면에서 사용하는 전체 필터 목록
final Map<String, PetFilter> allFilters = {
  'basic_none': const PetFilter(
    key: 'basic_none',
    label: '원본',
    icon: Icons.hide_image_rounded,
    matrix: kIdentityMatrix,
  ),
  'basic_soft': const PetFilter(
    key: 'basic_soft',
    label: '소프',
    icon: Icons.blur_on_rounded,
    matrix: [
      1.03, 0.02, 0.02, 0, 0,
      0.01, 1.00, 0.00, 0, 0,
      0.00, 0.02, 0.98, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_soft': const PetFilter(
    key: 'pink_soft',
    label: '핑크',
    icon: Icons.favorite_rounded,
    matrix: [
      1.05, 0.05, 0.00, 0, 5,
      0.00, 0.95, 0.05, 0, 0,
      0.00, 0.05, 0.95, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_blossom': const PetFilter(
    key: 'pink_blossom',
    label: '벚꽃',
    icon: Icons.local_florist_rounded,
    matrix: [
      1.1, 0.08, 0.0, 0, 8,
      0.0, 0.92, 0.08, 0, 5,
      0.0, 0.05, 0.9, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_candy': const PetFilter(
    key: 'pink_candy',
    label: '캔디',
    icon: Icons.cake_rounded,
    matrix: [
      1.15, 0.1, 0.0, 0, 10,
      0.0, 0.9, 0.1, 0, 8,
      0.0, 0.05, 0.85, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_dream': const PetFilter(
    key: 'pink_dream',
    label: '드림',
    icon: Icons.auto_awesome_rounded,
    matrix: [
      1.08, 0.06, 0.0, 0, 6,
      0.0, 0.94, 0.06, 0, 4,
      0.0, 0.04, 0.92, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_soft': const PetFilter(
    key: 'dog_soft',
    label: '미드',
    icon: Icons.brush_rounded,
    matrix: [
      1.02, 0.03, 0.00, 0, 0,
      0.00, 1.00, 0.02, 0, 0,
      0.00, 0.02, 1.00, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_soft': const PetFilter(
    key: 'cat_soft',
    label: '자연',
    icon: Icons.nature_rounded,
    matrix: [
      0.98, 0.02, 0.02, 0, 0,
      0.02, 1.02, 0.02, 0, 0,
      0.02, 0.02, 1.02, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  // 강아지 전용 필터
  'dog_warm': const PetFilter(
    key: 'dog_warm',
    label: '웜',
    icon: Icons.wb_sunny_rounded,
    matrix: [
      1.15, 0.05, 0.0, 0, 8,
      0.0, 1.1, 0.0, 0, 5,
      0.0, 0.0, 0.95, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_vibrant': const PetFilter(
    key: 'dog_vibrant',
    label: '생동',
    icon: Icons.auto_awesome_rounded,
    matrix: [
      1.2, 0.1, 0.0, 0, 0,
      0.0, 1.15, 0.05, 0, 0,
      0.0, 0.0, 1.1, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_cozy': const PetFilter(
    key: 'dog_cozy',
    label: '아늑',
    icon: Icons.home_rounded,
    matrix: [
      1.0, 0.05, 0.0, 0, 5,
      0.0, 0.95, 0.0, 0, 0,
      0.0, 0.0, 0.9, 0, -5,
      0, 0, 0, 1, 0,
    ],
  ),
  // 고양이 전용 필터
  'cat_cool': const PetFilter(
    key: 'cat_cool',
    label: '쿨',
    icon: Icons.water_drop_rounded,
    matrix: [
      0.9, 0.05, 0.0, 0, 0,
      0.0, 0.95, 0.05, 0, 0,
      0.0, 0.1, 1.1, 0, 5,
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_elegant': const PetFilter(
    key: 'cat_elegant',
    label: '우아',
    icon: Icons.star_rounded,
    matrix: [
      1.1, 0.05, 0.0, 0, 0,
      0.0, 1.1, 0.1, 0, 0,
      0.0, 0.0, 1.0, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_mysterious': const PetFilter(
    key: 'cat_mysterious',
    label: '신비',
    icon: Icons.nightlight_round,
    matrix: [
      0.95, 0.05, 0.0, 0, 5,
      0.0, 0.95, 0.05, 0, 5,
      0.0, 0.0, 0.95, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
};

/// 촬영용 필터 표시 순서
const List<String> kFilterOrder = [
  'basic_none',
  'basic_soft',
  'pink_soft',
  'pink_blossom',
  'pink_candy',
  'pink_dream',
  'dog_soft',
  'dog_warm',
  'dog_vibrant',
  'dog_cozy',
  'cat_soft',
  'cat_cool',
  'cat_elegant',
  'cat_mysterious',
];

/// 편집 화면에서 사용하는 카테고리별 필터 묶음
final Map<String, List<PetFilter>> filtersByCategory = {
  'basic': [allFilters['basic_none']!, allFilters['basic_soft']!],
  'pink': [
    allFilters['pink_soft']!,
    allFilters['pink_blossom']!,
    allFilters['pink_candy']!,
    allFilters['pink_dream']!,
  ],
  'dog': [
    allFilters['dog_soft']!,
    allFilters['dog_warm']!,
    allFilters['dog_vibrant']!,
    allFilters['dog_cozy']!,
  ],
  'cat': [
    allFilters['cat_soft']!,
    allFilters['cat_cool']!,
    allFilters['cat_elegant']!,
    allFilters['cat_mysterious']!,
  ],
};

