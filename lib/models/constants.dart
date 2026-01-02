/// Petgram 앱의 상수 정의
library constants;

import 'package:flutter/material.dart';

// 색상
const Color kMainPink = Color(0xFFFFC0CB);
const Color kPetgramNavColor = Color(0xFFFCE4EC); // 네비게이션 바 배경색 (연핑크)

// SharedPreferences 키
const String kOnboardingSeenKey = 'petgram_onboarding_seen';
const String kLastSelectedFilterKey = 'petgram_last_selected_filter';
const String kPetNameKey = 'petgram_pet_name';
const String kPetListKey = 'petgram_pet_list';
const String kSelectedPetIdKey = 'petgram_selected_pet_id';
const String kFlashModeKey = 'petgram_flash_mode';
const String kShowGridLinesKey = 'petgram_show_grid_lines';
const String kFrameEnabledKey = 'petgram_frame_enabled';
const String kBurstModeKey = 'petgram_burst_mode';
const String kBurstCountSettingKey = 'petgram_burst_count_setting';
const String kTimerSecondsKey = 'petgram_timer_seconds';
const String kAspectModeKey = 'petgram_aspect_mode';

// 이미지 처리 해상도 상수
// 프리뷰는 1200px, 저장은 3000px 정도로 타협하여 성능과 품질을 균형 있게 유지
const int kPreviewMaxDimension = 1200; // 프리뷰용 최대 해상도 (긴 변 기준)
const int kSaveMaxDimension =
    3000; // 최종 저장용 최대 해상도 (긴 변 기준) - 고해상도이되 과도한 용량/속도 저하 방지
const int kSaveMinDimension =
    2000; // 최종 저장용 최소 해상도 (긴 변 기준) - 너무 낮은 해상도로 떨어지는 것만 방지

