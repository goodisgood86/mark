import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_datetime_picker_plus/flutter_datetime_picker_plus.dart'
    as dtp;

const Color kMainPink = Color(0xFFFFC0CB);
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

/// 얼굴 영역 정보 클래스
class FaceRegion {
  final int centerX;
  final int centerY;
  final int radius;

  FaceRegion({
    required this.centerX,
    required this.centerY,
    required this.radius,
  });
}

/// 반려동물 정보 클래스
class PetInfo {
  final String id;
  final String name;
  final String type; // 'dog' or 'cat'
  final DateTime birthDate;
  final int framePattern; // 1 or 2
  final String? gender; // 'male' or 'female' or null
  final String? breed; // 종 (텍스트 입력)
  final bool locationEnabled; // GPS 위치 정보 활성화 여부

  PetInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.birthDate,
    this.framePattern = 1,
    this.gender,
    this.breed,
    this.locationEnabled = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'birthDate': birthDate.toIso8601String(),
    'framePattern': framePattern,
    'gender': gender,
    'breed': breed,
    'locationEnabled': locationEnabled,
  };

  factory PetInfo.fromJson(Map<String, dynamic> json) => PetInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    type: json['type'] as String,
    birthDate: DateTime.parse(json['birthDate'] as String),
    framePattern: json['framePattern'] as int? ?? 1,
    gender: json['gender'] as String?,
    breed: json['breed'] as String?,
    locationEnabled: json['locationEnabled'] as bool? ?? false,
  );

  int getAge() {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }
}

/// 필터용 기본 행렬
const List<double> kIdentityMatrix = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0,
];

List<double> mixMatrix(List<double> a, List<double> b, double t) {
  final clamped = t.clamp(0.0, 1.2);
  return List.generate(a.length, (i) => a[i] + (b[i] - a[i]) * clamped);
}

/// 두 개의 ColorMatrix를 곱셈하여 하나로 합치기 (성능 개선)
List<double> multiplyColorMatrices(List<double> a, List<double> b) {
  // ColorMatrix는 4x5 행렬이지만 실제로는 20개 요소의 배열
  // 곱셈: result = a * b
  // RGB 부분: 일반 행렬 곱셈
  // Offset 부분: a의 offset + (a의 RGB 행렬 * b의 offset)
  final result = List<double>.filled(20, 0.0);

  for (int row = 0; row < 4; row++) {
    // RGB 부분 (0-3 열)
    for (int col = 0; col < 4; col++) {
      double sum = 0.0;
      for (int k = 0; k < 4; k++) {
        sum += a[row * 5 + k] * b[k * 5 + col];
      }
      result[row * 5 + col] = sum;
    }
    // Offset 부분 (4번째 열)
    double offsetSum = a[row * 5 + 4]; // a의 offset
    for (int k = 0; k < 4; k++) {
      offsetSum += a[row * 5 + k] * b[k * 5 + 4]; // a의 RGB 행렬 * b의 offset
    }
    result[row * 5 + 4] = offsetSum;
  }

  return result;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = const [];
  try {
    cameras = await availableCameras();
    if (kDebugMode) {
      debugPrint('[Petgram] main(): availableCameras length=${cameras.length}');
    }
  } catch (e, s) {
    if (kDebugMode) {
      debugPrint('[Petgram] main(): availableCameras failed → $e');
      debugPrint('[Petgram] stacktrace: $s');
    }
  }

  runApp(PetgramApp(cameras: cameras));
}

class PetgramApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const PetgramApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Petgram',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFFFF5F8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFF5F8),
          foregroundColor: Colors.black,
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: HomePage(cameras: cameras),
    );
  }
}

/// 화면 비율 모드
enum AspectRatioMode { nineSixteen, threeFour, oneOne }

double aspectRatioOf(AspectRatioMode mode) {
  switch (mode) {
    case AspectRatioMode.nineSixteen:
      return 9 / 15; // 9:15 비율로 조정
    case AspectRatioMode.threeFour:
      return 3 / 4; // 3:4 비율
    case AspectRatioMode.oneOne:
      return 1.0; // 1:1 비율
  }
}

/// 필터 정의 클래스
class PetFilter {
  final String key;
  final String label;
  final IconData icon;
  final List<double> matrix;

  const PetFilter({
    required this.key,
    required this.label,
    required this.icon,
    required this.matrix,
  });
}

/// ========================
///  필터 정의 (공통)
/// ========================

// 촬영/편집 화면에서 사용하는 전체 필터 목록
final Map<String, PetFilter> _allFilters = {
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
      1.03,
      0.02,
      0.02,
      0,
      0,
      0.01,
      1.00,
      0.00,
      0,
      0,
      0.00,
      0.02,
      0.98,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  'pink_soft': const PetFilter(
    key: 'pink_soft',
    label: '핑크',
    icon: Icons.favorite_rounded,
    matrix: [
      1.05,
      0.05,
      0.00,
      0,
      5,
      0.00,
      0.95,
      0.05,
      0,
      0,
      0.00,
      0.05,
      0.95,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  'pink_blossom': const PetFilter(
    key: 'pink_blossom',
    label: '벚꽃',
    icon: Icons.local_florist_rounded,
    matrix: [
      1.1, 0.08, 0.0, 0, 8, //
      0.0, 0.92, 0.08, 0, 5, //
      0.0, 0.05, 0.9, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_candy': const PetFilter(
    key: 'pink_candy',
    label: '캔디',
    icon: Icons.cake_rounded,
    matrix: [
      1.15, 0.1, 0.0, 0, 10, //
      0.0, 0.9, 0.1, 0, 8, //
      0.0, 0.05, 0.85, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'pink_dream': const PetFilter(
    key: 'pink_dream',
    label: '드림',
    icon: Icons.auto_awesome_rounded,
    matrix: [
      1.08, 0.06, 0.0, 0, 6, //
      0.0, 0.94, 0.06, 0, 4, //
      0.0, 0.04, 0.92, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_soft': const PetFilter(
    key: 'dog_soft',
    label: '미드',
    icon: Icons.brush_rounded,
    matrix: [
      1.02,
      0.03,
      0.00,
      0,
      0,
      0.00,
      1.00,
      0.02,
      0,
      0,
      0.00,
      0.02,
      1.00,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  'cat_soft': const PetFilter(
    key: 'cat_soft',
    label: '자연',
    icon: Icons.nature_rounded,
    matrix: [
      0.98,
      0.02,
      0.02,
      0,
      0,
      0.02,
      1.02,
      0.02,
      0,
      0,
      0.02,
      0.02,
      1.02,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ],
  ),
  // 강아지 전용 필터
  'dog_warm': const PetFilter(
    key: 'dog_warm',
    label: '웜',
    icon: Icons.wb_sunny_rounded,
    matrix: [
      1.15, 0.05, 0.0, 0, 8, //
      0.0, 1.1, 0.0, 0, 5, //
      0.0, 0.0, 0.95, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_vibrant': const PetFilter(
    key: 'dog_vibrant',
    label: '생동',
    icon: Icons.auto_awesome_rounded,
    matrix: [
      1.2, 0.1, 0.0, 0, 0, //
      0.0, 1.15, 0.05, 0, 0, //
      0.0, 0.0, 1.1, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'dog_cozy': const PetFilter(
    key: 'dog_cozy',
    label: '아늑',
    icon: Icons.home_rounded,
    matrix: [
      1.0, 0.05, 0.0, 0, 5, //
      0.0, 0.95, 0.0, 0, 0, //
      0.0, 0.0, 0.9, 0, -5, //
      0, 0, 0, 1, 0,
    ],
  ),
  // 고양이 전용 필터
  'cat_cool': const PetFilter(
    key: 'cat_cool',
    label: '쿨',
    icon: Icons.water_drop_rounded,
    matrix: [
      0.9, 0.05, 0.0, 0, 0, //
      0.0, 0.95, 0.05, 0, 0, //
      0.0, 0.1, 1.1, 0, 5, //
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_elegant': const PetFilter(
    key: 'cat_elegant',
    label: '우아',
    icon: Icons.star_rounded,
    matrix: [
      1.1, 0.05, 0.0, 0, 0, //
      0.0, 1.1, 0.1, 0, 0, //
      0.0, 0.0, 1.0, 0, 0, //
      0, 0, 0, 1, 0,
    ],
  ),
  'cat_mysterious': const PetFilter(
    key: 'cat_mysterious',
    label: '신비',
    icon: Icons.nightlight_round,
    matrix: [
      0.95, 0.05, 0.0, 0, 5, //
      0.0, 0.95, 0.05, 0, 5, //
      0.0, 0.0, 0.95, 0, 0, //
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
final Map<String, List<PetFilter>> _filtersByCategory = {
  'basic': [_allFilters['basic_none']!, _allFilters['basic_soft']!],
  'pink': [
    _allFilters['pink_soft']!,
    _allFilters['pink_blossom']!,
    _allFilters['pink_candy']!,
    _allFilters['pink_dream']!,
  ],
  'dog': [
    _allFilters['dog_soft']!,
    _allFilters['dog_warm']!,
    _allFilters['dog_vibrant']!,
    _allFilters['dog_cozy']!,
  ],
  'cat': [
    _allFilters['cat_soft']!,
    _allFilters['cat_cool']!,
    _allFilters['cat_elegant']!,
    _allFilters['cat_mysterious']!,
  ],
};

/// ========================
///  메인 홈 화면
/// ========================
class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomePage({super.key, required this.cameras});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();
  final AudioPlayer _audioPlayer = AudioPlayer();

  CameraController? _cameraController;
  bool _isCameraInitializing = true;
  bool _useMockCamera = false;
  bool _isProcessing = false;
  bool _isCaptureAnimating = false;

  // 촬영용 필터
  String _shootFilterKey = kFilterOrder.first;

  // 라이브 필터 강도
  double _liveIntensity = 0.8;
  String _liveCoatPreset = 'mid'; // light / mid / dark / custom

  // 플래시 / 화면 비율
  FlashMode _flashMode = FlashMode.off;
  AspectRatioMode _aspectMode = AspectRatioMode.threeFour;

  // 촬영용 필터 패널 펼침 여부
  bool _filterPanelExpanded = false;

  // 그리드라인 표시
  bool _showGridLines = false;

  // 연속 촬영 모드
  bool _isBurstMode = false;
  int _burstCount = 0;
  int _burstCountSetting = 5; // 기본 5장, 선택 가능: 3, 5, 10, 20
  bool _shouldStopBurst = false; // 연속 촬영 중지 플래그

  // 타이머 촬영
  int _timerSeconds = 0; // 0 = off, 3, 5, 10
  bool _isTimerCounting = false;
  bool _shouldStopTimer = false; // 타이머 중지 플래그
  bool _isTimerTriggered = false; // 타이머로 인한 촬영인지 구분

  List<PetInfo> _petList = [];
  String? _selectedPetId; // 현재 선택된 반려동물 ID

  // 프레임 적용 여부
  bool _frameEnabled = true;

  // 위치 정보
  String? _currentLocation; // 현재 촬영 위치 정보

  /// 위치정보 활성화 여부 확인 후 위치 정보 가져오기
  /// [forceReload]가 true이면 위치정보가 있어도 다시 불러오기 (GPS 업데이트 버튼 클릭 시)
  /// [alwaysReload]가 true이면 프레임 선택 변경 시 항상 다시 불러오기
  Future<void> _checkAndFetchLocation({
    bool forceReload = false,
    bool alwaysReload = false,
  }) async {
    if (!_frameEnabled || _petList.isEmpty) {
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
      return;
    }

    final selectedPet = _selectedPetId != null
        ? _petList.firstWhere(
            (pet) => pet.id == _selectedPetId,
            orElse: () => _petList.first,
          )
        : _petList.first;

    if (selectedPet.locationEnabled) {
      debugPrint(
        '[Petgram] 📍 위치정보 활성화됨: selectedPet.locationEnabled=true, _currentLocation=${_currentLocation != null ? "있음" : "없음"}',
      );
      // 위치 정보가 없거나 강제 재로드가 필요하거나 항상 재로드가 필요한 경우에만 가져오기
      if (_currentLocation == null || forceReload || alwaysReload) {
        debugPrint(
          '[Petgram] 📍 위치정보 불러오기 조건 충족: _currentLocation=${_currentLocation != null ? "있음" : "없음"}, forceReload=$forceReload, alwaysReload=$alwaysReload',
        );
        if (forceReload || alwaysReload) {
          if (mounted) {
            setState(() {
              _currentLocation = null; // 초기화하여 다시 불러오도록
            });
          }
        }
        await _fetchLocation();
      } else {
        debugPrint('[Petgram] 📍 위치정보 불러오기 조건 불충족: 이미 위치정보가 있음');
      }
    } else {
      debugPrint('[Petgram] 📍 위치정보 비활성화됨: selectedPet.locationEnabled=false');
      // 위치 정보 활성화가 안 되어 있으면 null로 설정
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
    }
  }

  /// 위치 정보 가져오기 (동 이전 레벨까지)
  Future<void> _fetchLocation({bool showSnackbar = false}) async {
    debugPrint('[Petgram] 📍 _fetchLocation 시작');
    try {
      // 위치 서비스 활성화 여부 확인
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (kDebugMode) {
          debugPrint('📍 위치 서비스가 비활성화되어 있습니다');
        }
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        return;
      }

      // 위치 권한 확인
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (kDebugMode) {
            debugPrint('📍 위치 권한이 거부되었습니다');
          }
          if (mounted) {
            setState(() {
              _currentLocation = null;
            });
          }
          if (showSnackbar && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('위치 정보를 확인할 수 없습니다'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (kDebugMode) {
          debugPrint('📍 위치 권한이 영구적으로 거부되었습니다');
        }
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        return;
      }

      // 현재 위치 가져오기
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      // geocoding 패키지 사용
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final placemark = placemarks[0];
        if (kDebugMode) {
          debugPrint('📍 Placemark 정보:');
          debugPrint('  - administrativeArea: ${placemark.administrativeArea}');
          debugPrint(
            '  - subAdministrativeArea: ${placemark.subAdministrativeArea}',
          );
          debugPrint('  - locality: ${placemark.locality}');
          debugPrint('  - subLocality: ${placemark.subLocality}');
        }

        // 3단계까지 풀로 노출하는 함수
        String buildRegion3Level(Placemark p) {
          // 1레벨 = 시도
          final level1 = (p.administrativeArea ?? '').trim(); // 서울특별시, 경기도 등

          // 2레벨 후보 = 시군구
          String? level2;

          // 1순위: locality (강남구, 의정부시 등)
          if ((p.locality ?? '').trim().isNotEmpty) {
            final locality = p.locality!.trim();
            // 예외처리: 레벨2가 레벨1과 같으면 사용하지 않음
            if (locality != level1) {
              level2 = locality;
            }
          }
          // 2순위: subAdministrativeArea (성남시, 의정부시 등 기기 따라 여기 들어오는 경우도 있어서)
          if ((level2 == null || level2.isEmpty) &&
              (p.subAdministrativeArea ?? '').trim().isNotEmpty) {
            final subArea = p.subAdministrativeArea!.trim();
            // 예외처리: 레벨2가 레벨1과 같으면 사용하지 않음
            if (subArea != level1) {
              level2 = subArea;
            }
          }

          // 3레벨 = subLocality (동, 면 등)
          String? level3;
          if ((p.subLocality ?? '').trim().isNotEmpty) {
            final subLocality = p.subLocality!.trim();
            // 예외처리: 레벨3가 레벨1이나 레벨2와 같으면 사용하지 않음
            if (subLocality != level1 && subLocality != level2) {
              level3 = subLocality;
            }
          }

          // 레벨들을 조합 (중복 제거)
          List<String> levels = [];
          if (level1.isNotEmpty) levels.add(level1);
          if (level2 != null && level2.isNotEmpty && !levels.contains(level2)) {
            levels.add(level2);
          }
          if (level3 != null && level3.isNotEmpty && !levels.contains(level3)) {
            levels.add(level3);
          }

          if (levels.isEmpty) {
            return '';
          }
          return levels.join(' '); // 최종 "서울특별시 강남구 역삼동" 이런 형식
        }

        final koreanLocation = buildRegion3Level(placemark);

        if (koreanLocation.isNotEmpty) {
          // 한글 주소 그대로 사용 (이미 중복 제거됨)
          final finalLocation = koreanLocation;

          if (mounted) {
            setState(() {
              _currentLocation = finalLocation;
            });
          }
          debugPrint('[Petgram] 📍 위치 정보 불러오기 성공: $_currentLocation');
        } else {
          if (mounted) {
            setState(() {
              _currentLocation = null;
            });
          }
          if (kDebugMode) {
            debugPrint('📍 위치 정보를 가져올 수 없습니다');
          }
          if (showSnackbar && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('위치 정보를 확인할 수 없습니다'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _currentLocation = null;
          });
        }
        if (kDebugMode) {
          debugPrint('📍 주소 정보를 가져올 수 없습니다');
        }
        if (showSnackbar && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('위치 정보를 확인할 수 없습니다'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ 위치 정보 가져오기 실패: $e');
      debugPrint('[Petgram] ❌ Stack trace: ${StackTrace.current}');
      if (mounted) {
        setState(() {
          _currentLocation = null;
        });
      }
      if (showSnackbar && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('위치 정보를 확인할 수 없습니다'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.black87,
          ),
        );
      }
    }
  }

  // 카메라 줌 레벨
  double _currentZoomLevel = 1.0;
  double _selectedZoomRatio = 1.0; // 선택된 배율 (0.8x, 1x, 1.5x 등)
  double _baseZoomLevel = 1.0; // 핀치 제스처 시작 시 줌 레벨
  bool _isZooming = false; // 핀치 줌 진행 중 여부
  DateTime? _lastZoomTime; // 마지막 핀치 줌 이벤트 시간
  Offset? _lastTapPosition; // 마지막 탭 위치 (요구사항에 따라 선언, 현재는 사용하지 않음)
  DateTime? _lastScaleUpdateTime; // 마지막 onScaleUpdate 호출 시간

  // 카메라 줌 범위 (카메라 초기화 시 설정)
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 2.0;

  // UI 줌 (FilterPage처럼 Transform.scale 사용)
  double _uiZoomScale = 1.0; // UI 줌 스케일 (1.0 ~ 5.0)
  double _baseZoomScale = 1.0; // 핀치 제스처 시작 시 UI 줌 스케일
  Offset _zoomOffset = Offset.zero; // 줌 오프셋
  Offset _lastZoomFocalPoint = Offset.zero; // 마지막 줌 포커스 포인트

  // 카메라 방향 (전면/후면)
  CameraLensDirection _cameraLensDirection = CameraLensDirection.back;

  // 초점 관련
  Offset? _focusPointRelative; // 초점 위치 (상대 좌표 0.0~1.0)
  bool _showFocusIndicator = false; // 초점 표시기 표시 여부
  bool _showAutoFocusIndicator = false; // 자동 초점 표시기 표시 여부

  // 밝기 조절 (-1.0 ~ 1.0, 0.0이 원본)
  double _brightnessValue = 0.0; // -50 ~ 50 범위

  // 아이콘 이미지 캐시
  ui.Image? _dogIconImage;
  ui.Image? _catIconImage;

  // Mockup 이미지 비율 캐시
  double? _mockupAspectRatio;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadLastSelectedFilter();
    _loadPetName();
    _loadAllSettings();
    loadFrameResources(); // 프레임 폰트와 로고 미리 로드
    _loadIconImages(); // 아이콘 이미지 미리 로드
  }

  /// 아이콘 이미지 및 mockup 비율 미리 로드
  Future<void> _loadIconImages() async {
    try {
      final ByteData dogData = await rootBundle.load('assets/icons/dog.png');
      final Uint8List dogBytes = dogData.buffer.asUint8List();
      final ui.Codec dogCodec = await ui.instantiateImageCodec(dogBytes);
      final ui.FrameInfo dogFrameInfo = await dogCodec.getNextFrame();
      _dogIconImage = dogFrameInfo.image;

      final ByteData catData = await rootBundle.load('assets/icons/cat.png');
      final Uint8List catBytes = catData.buffer.asUint8List();
      final ui.Codec catCodec = await ui.instantiateImageCodec(catBytes);
      final ui.FrameInfo catFrameInfo = await catCodec.getNextFrame();

      // Mockup 이미지 비율 로드
      try {
        final ByteData mockupData = await rootBundle.load(
          'assets/images/mockup.png',
        );
        final Uint8List mockupBytes = mockupData.buffer.asUint8List();
        final ui.Codec mockupCodec = await ui.instantiateImageCodec(
          mockupBytes,
        );
        final ui.FrameInfo mockupFrameInfo = await mockupCodec.getNextFrame();
        final mockupImage = mockupFrameInfo.image;
        _mockupAspectRatio = mockupImage.width / mockupImage.height;
        mockupImage.dispose();
        debugPrint(
          '[Petgram] 📐 Mockup 이미지 비율: ${_mockupAspectRatio} (${mockupImage.width}x${mockupImage.height})',
        );
      } catch (e) {
        debugPrint('[Petgram] ⚠️ Mockup 이미지 비율 로드 실패: $e, 기본값 9/16 사용');
        _mockupAspectRatio = 9 / 16;
      }
      _catIconImage = catFrameInfo.image;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] Failed to load icon images: $e');
      }
    }
  }

  Future<void> _loadLastSelectedFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFilter = prefs.getString(kLastSelectedFilterKey);
    if (savedFilter != null && _allFilters.containsKey(savedFilter)) {
      setState(() {
        _shootFilterKey = savedFilter;
      });
    }
  }

  Future<void> _saveSelectedFilter(String filterKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLastSelectedFilterKey, filterKey);
  }

  Future<void> _loadPetName() async {
    final prefs = await SharedPreferences.getInstance();
    final savedListJson = prefs.getStringList(kPetListKey);
    if (savedListJson != null && savedListJson.isNotEmpty) {
      try {
        final List<PetInfo> loadedPets = savedListJson
            .map(
              (json) => PetInfo.fromJson(
                Map<String, dynamic>.from(
                  (jsonDecode(json) as Map<dynamic, dynamic>).map(
                    (k, v) => MapEntry(k.toString(), v),
                  ),
                ),
              ),
            )
            .toList();
        // 저장된 선택된 반려동물 ID 로드
        final savedSelectedId = prefs.getString(kSelectedPetIdKey);
        setState(() {
          _petList = loadedPets;
          // 저장된 ID가 있고, 해당 반려동물이 리스트에 있으면 사용, 없으면 첫 번째 반려동물
          if (savedSelectedId != null &&
              loadedPets.any((pet) => pet.id == savedSelectedId)) {
            _selectedPetId = savedSelectedId;
          } else {
            _selectedPetId = loadedPets.isNotEmpty ? loadedPets.first.id : null;
          }
        });

        // 반려동물 정보 로드 후, 프레임이 활성화되어 있고 위치 정보가 활성화된 반려동물이 있으면 위치 정보 불러오기
        final frameEnabled = prefs.getBool(kFrameEnabledKey) ?? true;
        if (frameEnabled && _petList.isNotEmpty) {
          final selectedPet = _selectedPetId != null
              ? _petList.firstWhere(
                  (pet) => pet.id == _selectedPetId,
                  orElse: () => _petList.first,
                )
              : _petList.first;

          if (selectedPet.locationEnabled) {
            // 앱 시작 시: 위치 정보 불러오기
            _checkAndFetchLocation();
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('❌ _loadPetName error: $e');
        }
      }
    }
  }

  // 모든 설정 로드
  Future<void> _loadAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 플래시 모드
      final flashModeStr = prefs.getString(kFlashModeKey);
      if (flashModeStr != null) {
        switch (flashModeStr) {
          case 'off':
            _flashMode = FlashMode.off;
            break;
          case 'auto':
            _flashMode = FlashMode.auto;
            break;
          case 'always':
            _flashMode = FlashMode.always;
            break;
          case 'torch':
            _flashMode = FlashMode.torch;
            break;
        }
      }
      // 그리드라인
      _showGridLines = prefs.getBool(kShowGridLinesKey) ?? false;
      // 프레임 활성화
      _frameEnabled = prefs.getBool(kFrameEnabledKey) ?? true;
      // 연속 촬영 모드
      _isBurstMode = prefs.getBool(kBurstModeKey) ?? false;
      // 연속 촬영 매수
      _burstCountSetting = prefs.getInt(kBurstCountSettingKey) ?? 5;
      // 타이머 초
      _timerSeconds = prefs.getInt(kTimerSecondsKey) ?? 0;
      // 화면 비율
      final aspectModeStr = prefs.getString(kAspectModeKey);
      if (aspectModeStr != null) {
        switch (aspectModeStr) {
          case 'nineSixteen':
            _aspectMode = AspectRatioMode.nineSixteen;
            break;
          case 'threeFour':
            _aspectMode = AspectRatioMode.threeFour;
            break;
          case 'oneOne':
            _aspectMode = AspectRatioMode.oneOne;
            break;
        }
      }
    });
  }

  // 플래시 모드 저장
  Future<void> _saveFlashMode() async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'off';
    switch (_flashMode) {
      case FlashMode.off:
        modeStr = 'off';
        break;
      case FlashMode.auto:
        modeStr = 'auto';
        break;
      case FlashMode.always:
        modeStr = 'always';
        break;
      case FlashMode.torch:
        modeStr = 'torch';
        break;
    }
    await prefs.setString(kFlashModeKey, modeStr);
  }

  // 그리드라인 저장
  Future<void> _saveShowGridLines() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kShowGridLinesKey, _showGridLines);
  }

  // 프레임 활성화 저장
  Future<void> _saveFrameEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kFrameEnabledKey, _frameEnabled);
  }

  // 연속 촬영 설정 저장
  Future<void> _saveBurstSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBurstModeKey, _isBurstMode);
    await prefs.setInt(kBurstCountSettingKey, _burstCountSetting);
  }

  // 타이머 설정 저장
  Future<void> _saveTimerSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kTimerSecondsKey, _timerSeconds);
  }

  // 화면 비율 저장
  Future<void> _saveAspectMode() async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'threeFour';
    switch (_aspectMode) {
      case AspectRatioMode.nineSixteen:
        modeStr = 'nineSixteen';
        break;
      case AspectRatioMode.threeFour:
        modeStr = 'threeFour';
        break;
      case AspectRatioMode.oneOne:
        modeStr = 'oneOne';
        break;
    }
    await prefs.setString(kAspectModeKey, modeStr);
  }

  /// 이미지에 반려동물 이름과 촬영 시점을 프레임으로 추가 (새로운 구조)
  Future<File> _addPhotoFrame(File imageFile) async {
    try {
      final Uint8List imageBytes = await imageFile.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(imageBytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      // 최종 캔버스 크기 (이미지 크기 그대로, 칩은 오버레이)
      final double finalWidth = image.width.toDouble();
      final double finalHeight = image.height.toDouble();

      // 캔버스 생성
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);

      // 1. 배경 레이어: 사진 (fit: cover)
      // 이미지를 fit: cover로 그리기
      final double imageAspect = image.width / image.height;
      final double canvasAspect = finalWidth / finalHeight;

      double drawWidth = finalWidth;
      double drawHeight = finalHeight;
      double drawX = 0;
      double drawY = 0;

      if (imageAspect > canvasAspect) {
        // 이미지가 더 넓음 → 높이에 맞춤
        drawHeight = finalHeight;
        drawWidth = drawHeight * imageAspect;
        drawX = (finalWidth - drawWidth) / 2;
      } else {
        // 이미지가 더 높음 → 너비에 맞춤
        drawWidth = finalWidth;
        drawHeight = drawWidth / imageAspect;
        drawY = (finalHeight - drawHeight) / 2;
      }

      // 이미지 그리기 (fit: cover)
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(drawX, drawY, drawWidth, drawHeight),
        Paint(),
      );

      // 2. 프레임 오버레이 (투명 영역 유지)
      // FramePainter와 동일한 로직 사용
      // 촬영 시점의 위치 정보 사용 (프레임 활성화 시 가져온 위치 정보)
      // 저장된 이미지에는 오버레이가 없으므로 전체 이미지가 촬영 영역
      // 프리뷰와 동일한 정규화 비율 계산
      // 촬영본에서: overlayTop / imageHeight = normalizedTop
      // 촬영본에서: normalizedTop * finalHeight = topBarHeight

      // 촬영본은 이미 크롭된 이미지이므로, 프레임 위치를 크롭된 이미지 기준으로 직접 계산
      // 프리뷰와 동일하게 프레임은 크롭된 이미지 상단에서 frameMargin만큼 아래에 배치
      final double frameMargin = finalWidth * 0.02;
      final double finalTopBarHeight = frameMargin;

      debugPrint(
        '[Petgram] 📸 _addPhotoFrame: image=${finalWidth}x${finalHeight}, frameMargin=$frameMargin, finalTopBarHeight=$finalTopBarHeight',
      );

      final framePainter = FramePainter(
        petList: _petList,
        selectedPetId: _selectedPetId,
        width: finalWidth,
        height: finalHeight,
        topBarHeight: finalTopBarHeight, // 프리뷰와 동일한 정규화 비율 사용
        bottomBarHeight: finalHeight, // 저장된 이미지 전체가 촬영 영역이므로 하단 = 이미지 하단
        dogIconImage: _dogIconImage,
        catIconImage: _catIconImage,
        location: _currentLocation, // 촬영 시점의 위치 정보 전달
      );
      framePainter.paint(canvas, Size(finalWidth, finalHeight));

      // Picture를 Image로 변환
      final ui.Picture picture = recorder.endRecording();
      final ui.Image finalImage = await picture.toImage(
        finalWidth.toInt(),
        finalHeight.toInt(),
      );

      // PNG로 임시 인코딩
      final ByteData? byteData = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) {
        image.dispose();
        finalImage.dispose();
        return imageFile;
      }

      final Uint8List pngBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      // PNG를 디코딩하여 image 패키지로 변환
      final img.Image? decodedImage = img.decodeImage(pngBytes);
      if (decodedImage == null) {
        image.dispose();
        finalImage.dispose();
        return imageFile;
      }

      // JPEG로 인코딩 (품질 95)
      final Uint8List jpegBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 100),
      );

      // 임시 파일로 저장 (JPEG)
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/framed_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final File framedFile = File(filePath);
      await framedFile.writeAsBytes(jpegBytes);

      // 원본 이미지 정리
      image.dispose();
      finalImage.dispose();

      return framedFile;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ _addPhotoFrame error: $e');
      }
      return imageFile;
    }
  }

  /// ColorMatrix를 실제 이미지 픽셀에 적용 (원본 색상 보존을 위한 블렌딩)
  img.Image _applyColorMatrixToImage(img.Image image, List<double> matrix) {
    // 원본 이미지를 복사하여 수정 (원본 보존, 해상도 유지)
    // 원본과 동일한 크기이므로 보간법은 영향 없지만, cubic이 가장 고품질
    final result = img.copyResize(
      image,
      width: image.width,
      height: image.height,
      interpolation: img.Interpolation.cubic, // 고품질 보간법 (원본 크기와 동일하므로 영향 없음)
    );

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = result.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        final a = pixel.a.toDouble();

        // ColorMatrix 직접 적용 (블렌딩 없이, mixMatrix에서 이미 intensity 조절됨)
        final newR =
            (matrix[0] * r +
                    matrix[1] * g +
                    matrix[2] * b +
                    matrix[3] * a +
                    matrix[4])
                .clamp(0, 255)
                .toInt();
        final newG =
            (matrix[5] * r +
                    matrix[6] * g +
                    matrix[7] * b +
                    matrix[8] * a +
                    matrix[9])
                .clamp(0, 255)
                .toInt();
        final newB =
            (matrix[10] * r +
                    matrix[11] * g +
                    matrix[12] * b +
                    matrix[13] * a +
                    matrix[14])
                .clamp(0, 255)
                .toInt();
        final newA =
            (matrix[15] * r +
                    matrix[16] * g +
                    matrix[17] * b +
                    matrix[18] * a +
                    matrix[19])
                .clamp(0, 255)
                .toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, newA));
      }
    }

    return result;
  }

  Future<void> _initCamera() async {
    if (kDebugMode) {
      debugPrint(
        '[Petgram] _initCamera() called, widget.cameras.length = ${widget.cameras.length}',
      );
    }

    // 우선 상위에서 전달된 카메라 리스트를 사용
    List<CameraDescription> cams = widget.cameras;

    // 만약 상위에서 카메라 리스트를 제대로 못 받아왔다면 여기서 한 번 더 직접 조회
    if (cams.isEmpty) {
      try {
        cams = await availableCameras();
        if (kDebugMode) {
          debugPrint(
            '[Petgram] availableCameras() from HomePage, length = ${cams.length}',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Petgram] availableCameras() error inside HomePage: $e');
        }
      }
    }

    // 그래도 카메라가 하나도 없으면 목업 모드로 전환
    if (cams.isEmpty) {
      if (mounted) {
        setState(() {
          _isCameraInitializing = false;
          _useMockCamera = true;
          _cameraController = null;
          // 목업 카메라는 5배까지 지원
          _minZoomLevel = 1.0;
          _maxZoomLevel = 5.0;
          _currentZoomLevel = 1.0;
          _selectedZoomRatio = 1.0;
        });
      }
      return;
    }

    // 디폴트는 후면 카메라
    final selectedCamera = cams.firstWhere(
      (c) => c.lensDirection == _cameraLensDirection,
      orElse: () {
        // 원하는 방향의 카메라가 없으면 후면 카메라를 우선 찾고, 없으면 첫 번째 카메라
        return cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first,
        );
      },
    );

    // 연속 촬영 성능을 고려하여 화질 설정
    // veryHigh는 연속 촬영 시 성능 저하가 있을 수 있으므로 high로 변경
    // high도 충분히 고화질이며 연속 촬영 성능이 더 좋음
    final controller = CameraController(
      selectedCamera,
      ResolutionPreset.high, // 연속 촬영 성능 고려하여 high로 변경 (veryHigh -> high)
      enableAudio: false,
    );

    try {
      await controller.initialize();
      // 전면 카메라는 플래시를 지원하지 않으므로 플래시 모드 설정 전에 체크
      if (selectedCamera.lensDirection == CameraLensDirection.front) {
        // 전면 카메라는 플래시를 끄고 상태 업데이트
        if (_flashMode != FlashMode.off) {
          setState(() {
            _flashMode = FlashMode.off;
          });
          _saveFlashMode();
          debugPrint('[Petgram] ⚠️ 전면 카메라는 플래시를 지원하지 않아 플래시를 끕니다');
        }
      } else {
        // 후면 카메라는 플래시 모드 설정 시도
        try {
          await controller.setFlashMode(_flashMode);
        } catch (e) {
          debugPrint('[Petgram] ⚠️ 플래시 모드 설정 실패: $e');
          // 플래시 설정 실패 시 off로 설정
          setState(() {
            _flashMode = FlashMode.off;
          });
        }
      }
      // 자동 초점 모드 설정 및 리스너 추가
      try {
        await controller.setFocusMode(FocusMode.auto);
        debugPrint('[Petgram] ✅ 자동 초점 모드 설정 완료');
        // 자동 초점 상태 리스너 추가
        controller.addListener(_onCameraValueChanged);
      } catch (e) {
        debugPrint('[Petgram] ⚠️ 자동 초점 모드 설정 실패: $e');
      }
      // 초기 줌 레벨 설정 및 카메라 줌 범위 저장
      try {
        _minZoomLevel = await controller.getMinZoomLevel();
        _maxZoomLevel = await controller.getMaxZoomLevel();
        _currentZoomLevel = _minZoomLevel;
        _selectedZoomRatio = 1.0; // 기본 배율
        debugPrint(
          '[Petgram] 📐 카메라 줌 범위: min=$_minZoomLevel, max=$_maxZoomLevel',
        );
      } catch (e) {
        _minZoomLevel = 1.0;
        _maxZoomLevel = 2.0;
        _currentZoomLevel = 1.0;
        _selectedZoomRatio = 1.0;
        debugPrint('[Petgram] ⚠️ 줌 범위 가져오기 실패, 기본값 사용: $e');
      }
      if (!mounted) return;

      // 카메라 초기화 후 실제 비율 확인 및 로그 출력
      final actualAspectRatio = controller.value.aspectRatio;
      debugPrint(
        '[Petgram] 📐 카메라 초기화 완료 - 실제 비율: $actualAspectRatio (${actualAspectRatio > 0 ? (1 / actualAspectRatio).toStringAsFixed(3) : "N/A"}:1)',
      );

      setState(() {
        _cameraController = controller;
        _isCameraInitializing = false;
        _useMockCamera = false;
        // UI 줌 리셋
        _uiZoomScale = 1.0;
        _baseZoomScale = 1.0;
        _zoomOffset = Offset.zero;
      });

      // 최초 진입 시 화면 중앙에 자동 초점 설정
      _setAutoFocusAtCenter();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] camera init error: $e');
      }
      if (!mounted) return;
      setState(() {
        _isCameraInitializing = false;
        _useMockCamera = true;
        _cameraController = null;
        // 목업 카메라는 5배까지 지원
        _minZoomLevel = 1.0;
        _maxZoomLevel = 5.0;
        _currentZoomLevel = 1.0;
        _selectedZoomRatio = 1.0;
      });

      // 카메라 초기화 실패 시 사용자에게 안내 (권한 거부 가능성)
      if (mounted &&
          (e.toString().contains('permission') ||
              e.toString().contains('Permission'))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('카메라 권한이 필요합니다. 설정에서 권한을 허용해주세요.'),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 4),
              ),
            );
          }
        });
      }
    }
  }

  /// 카메라 값 변경 리스너 (자동 초점 상태 감지)
  /// 현재는 사용하지 않지만, 향후 자동 초점 상태 변화 감지 시 사용 가능
  void _onCameraValueChanged() {
    // 자동 초점은 _setAutoFocusAtCenter()에서 직접 처리하므로
    // 여기서는 추가 처리 불필요
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _cameraController?.removeListener(_onCameraValueChanged);
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _playDogSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/dog_bark.mp3'));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] dog sound error: $e');
      }
    }
  }

  Future<void> _playCatSound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/cat_meow.mp3'));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] cat sound error: $e');
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_useMockCamera) {
      setState(() {
        _flashMode = _flashMode == FlashMode.off
            ? FlashMode.torch
            : FlashMode.off;
      });
      _saveFlashMode();
      return;
    }
    if (_cameraController == null) return;

    final next = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _cameraController!.setFlashMode(next);
      setState(() => _flashMode = next);
      _saveFlashMode();
    } catch (_) {}
  }

  Future<void> _switchCamera() async {
    if (_useMockCamera || widget.cameras.isEmpty) return;

    // 현재 방향의 반대 방향으로 전환
    final newDirection = _cameraLensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    // 새로운 방향의 카메라 찾기
    final newCamera = widget.cameras.firstWhere(
      (c) => c.lensDirection == newDirection,
      orElse: () => widget.cameras.first,
    );

    // 기존 컨트롤러 해제
    await _cameraController?.dispose();

    // 새 컨트롤러 생성
    setState(() {
      _isCameraInitializing = true;
      _cameraLensDirection = newDirection;
    });

    // 연속 촬영 성능을 고려하여 화질 설정
    // veryHigh는 연속 촬영 시 성능 저하가 있을 수 있으므로 high로 변경
    // high도 충분히 고화질이며 연속 촬영 성능이 더 좋음
    final controller = CameraController(
      newCamera,
      ResolutionPreset.high, // 연속 촬영 성능 고려하여 high로 변경 (veryHigh -> high)
      enableAudio: false,
    );

    try {
      await controller.initialize();
      // 전면 카메라는 플래시를 지원하지 않으므로 플래시 모드 설정 전에 체크
      if (newDirection == CameraLensDirection.front) {
        // 전면 카메라는 플래시를 끄고 상태 업데이트
        if (_flashMode != FlashMode.off) {
          setState(() {
            _flashMode = FlashMode.off;
          });
          _saveFlashMode();
          debugPrint('[Petgram] ⚠️ 전면 카메라는 플래시를 지원하지 않아 플래시를 끕니다');
        }
      } else {
        // 후면 카메라는 플래시 모드 설정 시도
        try {
          await controller.setFlashMode(_flashMode);
        } catch (e) {
          debugPrint('[Petgram] ⚠️ 플래시 모드 설정 실패: $e');
          // 플래시 설정 실패 시 off로 설정
          setState(() {
            _flashMode = FlashMode.off;
          });
        }
      }
      // 자동 초점 모드 설정 및 리스너 추가
      try {
        await controller.setFocusMode(FocusMode.auto);
        debugPrint('[Petgram] ✅ 자동 초점 모드 설정 완료 (카메라 전환)');
        // 자동 초점 상태 리스너 추가
        controller.addListener(_onCameraValueChanged);
      } catch (e) {
        debugPrint('[Petgram] ⚠️ 자동 초점 모드 설정 실패: $e');
      }
      // 줌 레벨 설정 및 카메라 줌 범위 저장
      try {
        _minZoomLevel = await controller.getMinZoomLevel();
        _maxZoomLevel = await controller.getMaxZoomLevel();
        _currentZoomLevel = _minZoomLevel;
        _selectedZoomRatio = 1.0;
        debugPrint(
          '[Petgram] 📐 카메라 전환 - 줌 범위: min=$_minZoomLevel, max=$_maxZoomLevel',
        );
      } catch (e) {
        _minZoomLevel = 1.0;
        _maxZoomLevel = 2.0;
        _currentZoomLevel = 1.0;
        _selectedZoomRatio = 1.0;
        debugPrint('[Petgram] ⚠️ 줌 범위 가져오기 실패, 기본값 사용: $e');
      }
      if (!mounted) return;

      // 카메라 전환 후 실제 비율 확인 및 로그 출력
      final actualAspectRatio = controller.value.aspectRatio;
      debugPrint(
        '[Petgram] 📐 카메라 전환 완료 - 실제 비율: $actualAspectRatio (${actualAspectRatio > 0 ? (1 / actualAspectRatio).toStringAsFixed(3) : "N/A"}:1)',
      );

      setState(() {
        _cameraController = controller;
        _isCameraInitializing = false;
        _useMockCamera = false;
        // 셀카모드 전환 시 비율 재계산을 위해 강제 리빌드
        // UI 줌도 리셋
        _uiZoomScale = 1.0;
        _baseZoomScale = 1.0;
        _zoomOffset = Offset.zero;
      });

      // 카메라 전환 시에도 화면 중앙에 자동 초점 설정
      _setAutoFocusAtCenter();

      HapticFeedback.lightImpact();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Petgram] camera switch error: $e');
      }
      if (!mounted) return;
      setState(() {
        _isCameraInitializing = false;
        _useMockCamera = true;
        _cameraController = null;
        // 목업 카메라는 5배까지 지원
        _minZoomLevel = 1.0;
        _maxZoomLevel = 5.0;
        _currentZoomLevel = 1.0;
        _selectedZoomRatio = 1.0;
      });
    }
  }

  void _changeAspectMode(AspectRatioMode mode) {
    if (kDebugMode) {
      debugPrint('[Petgram] _changeAspectMode called: $mode');
    }
    if (_aspectMode == mode) {
      if (kDebugMode) {
        debugPrint('[Petgram] aspect mode is already $mode, skipping');
      }
      return;
    }
    setState(() {
      _aspectMode = mode;
    });
    _saveAspectMode();
    if (kDebugMode) {
      debugPrint('[Petgram] _aspectMode updated to: $_aspectMode');
    }
    // 프리뷰 강제 업데이트를 위해 약간의 지연 후 다시 빌드
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<File> _createTempFileFromAsset(String assetPath) async {
    final byteData = await rootBundle.load(assetPath);
    final buffer = byteData.buffer;
    final dir = await getTemporaryDirectory();
    final filePath =
        '${dir.path}/mock_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File(filePath);
    await file.writeAsBytes(
      buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
      flush: true,
    );
    return file;
  }

  /// 타이머 카운트다운 시작
  Future<void> _startTimerCountdown() async {
    if (_timerSeconds == 0 || _isTimerCounting) return;

    // 원래 타이머 설정값 저장
    final originalTimerSeconds = _timerSeconds;
    setState(() {
      _isTimerCounting = true;
      _shouldStopTimer = false;
    });

    for (int i = _timerSeconds; i > 0; i--) {
      if (!mounted || _shouldStopTimer) {
        setState(() {
          _isTimerCounting = false;
          _shouldStopTimer = false;
          _timerSeconds = originalTimerSeconds;
        });
        // 타이머 강제 종료 시 스낵바 표시
        if (_shouldStopTimer && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('타이머가 종료되었습니다.'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      setState(() => _timerSeconds = i);
      HapticFeedback.lightImpact();

      // 1초 대기 중에도 중지 요청을 체크할 수 있도록 0.1초씩 나눠서 대기
      for (int j = 0; j < 10; j++) {
        if (!mounted || _shouldStopTimer) {
          debugPrint('🛑 타이머 카운트다운 중지됨 (대기 중: $_shouldStopTimer)');
          setState(() {
            _isTimerCounting = false;
            _shouldStopTimer = false;
            _timerSeconds = originalTimerSeconds;
          });
          // 타이머 강제 종료 시 스낵바 표시
          if (_shouldStopTimer && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('타이머가 종료되었습니다.'),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    if (!mounted || _shouldStopTimer) {
      setState(() {
        _isTimerCounting = false;
        _shouldStopTimer = false;
        _timerSeconds = originalTimerSeconds;
      });
      // 타이머 강제 종료 시 스낵바 표시
      if (_shouldStopTimer && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('타이머가 종료되었습니다.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    setState(() {
      // 타이머 설정값 유지 (0으로 리셋하지 않음)
      _timerSeconds = originalTimerSeconds;
      _isTimerCounting = false;
      _isTimerTriggered = true; // 타이머로 인한 촬영임을 표시
    });

    // 타이머 종료 후 촬영 (한 번만)
    // 연속 촬영 모드가 활성화되어 있으면 연속 촬영이 실행됨
    await _takePhoto();

    // 타이머로 인한 촬영 완료 후 플래그 리셋
    // 연속 촬영이 완료될 때까지 기다림 (최대 10초)
    if (mounted) {
      int waitCount = 0;
      // 연속 촬영이 활성화되어 있고 아직 진행 중이면 대기
      while (_isBurstMode && _burstCount > 0 && mounted && waitCount < 200) {
        await Future.delayed(const Duration(milliseconds: 50));
        waitCount++;
      }
      // 연속 촬영이 완료되거나 대기 시간이 지나면 플래그 리셋
      if (mounted) {
        setState(() {
          _isTimerTriggered = false;
        });
        debugPrint('✅ 타이머 촬영 완료, 플래그 리셋 (대기: ${waitCount * 50}ms)');
      }
    }
  }

  /// 사진 촬영 → 바로 저장 (화면 전환 없음)
  Future<void> _takePhoto() async {
    if (_isProcessing) return;

    // 타이머 모드인 경우 카운트다운 시작 (타이머로 인한 촬영이 아니고, 연속 촬영이 진행 중이 아닐 때만)
    if (_timerSeconds > 0 &&
        !_isTimerCounting &&
        !_isTimerTriggered &&
        _burstCount == 0) {
      await _startTimerCountdown();
      return;
    }

    // 타이머 카운트다운 중이면 촬영하지 않음
    if (_isTimerCounting) return;

    // 연속 촬영 모드 초기화 (촬영 시작 시)
    // 타이머로 인한 촬영이거나 일반 촬영 모두 연속 촬영 가능
    if (_isBurstMode && _burstCount == 0) {
      setState(() {
        _burstCount = 1; // 첫 장부터 카운팅 시작
        _shouldStopBurst = false;
      });
      debugPrint('📸 연속 촬영 시작: $_burstCountSetting장 (타이머: $_isTimerTriggered)');
    }

    setState(() => _isProcessing = true);

    try {
      File file;
      if (_useMockCamera || _cameraController == null) {
        file = await _createTempFileFromAsset('assets/images/mockup.png');
      } else {
        final XFile xfile = await _cameraController!.takePicture();
        file = File(xfile.path);
      }

      // 이미지 처리 파이프라인: 선명도 먼저 적용 → 필터와 자동보정 색상 조정을 함께 적용
      File processedFile = file;

      try {
        // 1. 이미지 디코딩
        final Uint8List imageBytes = await processedFile.readAsBytes();
        img.Image? decodedImage = img.decodeImage(imageBytes);

        if (decodedImage == null) {
          throw Exception('이미지 디코딩 실패');
        }

        // 1. 프리뷰에서 사용한 비율/프레임 위치 기억
        // 프리뷰에서 계산한 오버레이 영역을 원본 이미지 해상도로 변환
        final double targetRatio = aspectRatioOf(_aspectMode);
        final double currentRatio = decodedImage.width / decodedImage.height;

        if (kDebugMode) {
          debugPrint(
            '🔍 크롭 전: ${decodedImage.width}x${decodedImage.height}, 현재 비율: ${currentRatio.toStringAsFixed(3)}, 목표 비율: ${targetRatio.toStringAsFixed(3)}',
          );
        }

        // 2. 원본 이미지 해상도 기준으로 프레임에 해당하는 Rect 계산
        // 프리뷰에서 오버레이가 없는 영역을 원본 이미지 해상도로 변환
        final double imageWidth = decodedImage.width.toDouble();
        final double imageHeight = decodedImage.height.toDouble();

        // 목표 비율에 맞는 높이 계산
        final double targetHeight = imageWidth / targetRatio;

        // 상하단 오버레이 계산 (원본 이미지 기준)
        double overlayTop = 0;
        double overlayBottom = 0;
        if (targetHeight < imageHeight) {
          // 비율이 더 넓은 경우 (예: 1:1, 3:4) - 상하단에 오버레이
          overlayTop = (imageHeight - targetHeight) / 2;
          overlayBottom = (imageHeight - targetHeight) / 2;
        }
        // 비율이 더 긴 경우 (예: 9:16) - 상하단 오버레이 없음

        // 실제 촬영 영역 (오버레이가 없는 부분) - 원본 이미지 해상도 기준
        final double cropX = 0; // 가로는 항상 0부터
        final double cropY = overlayTop; // 상단 오버레이 아래부터
        final double cropWidth = imageWidth; // 가로는 100% 유지
        final double cropHeight =
            imageHeight - overlayTop - overlayBottom; // 오버레이 제외한 높이

        // 3. 이미지 라이브러리로 해당 Rect만 크롭
        if (cropHeight > 0 && cropY + cropHeight <= imageHeight) {
          decodedImage = img.copyCrop(
            decodedImage,
            x: cropX.round(),
            y: cropY.round(),
            width: cropWidth.round(),
            height: cropHeight.round(),
          );

          final double finalRatio = decodedImage.width / decodedImage.height;
          if (kDebugMode) {
            debugPrint(
              '✅ 이미지 크롭 완료 (오버레이 제외): ${decodedImage.width}x${decodedImage.height}, 최종 비율: ${finalRatio.toStringAsFixed(3)}, 목표: ${targetRatio.toStringAsFixed(3)}',
            );
            debugPrint(
              '📐 크롭 영역: x=${cropX.round()}, y=${cropY.round()}, width=${cropWidth.round()}, height=${cropHeight.round()}',
            );
            // 비율 검증: 목표 비율과 최종 비율이 거의 일치하는지 확인 (0.01 이내 오차 허용)
            final double ratioDiff = (finalRatio - targetRatio).abs();
            if (ratioDiff > 0.01) {
              debugPrint(
                '⚠️ 비율 차이 감지: 차이=${ratioDiff.toStringAsFixed(4)}, 목표=${targetRatio.toStringAsFixed(3)}, 실제=${finalRatio.toStringAsFixed(3)}',
              );
            } else {
              debugPrint('✅ 비율 검증 통과: 차이=${ratioDiff.toStringAsFixed(4)}');
            }
          }
        } else {
          // 크롭할 영역이 없거나 잘못된 경우
          if (kDebugMode) {
            debugPrint(
              '⚠️ 크롭 영역이 유효하지 않음: cropY=$cropY, cropHeight=$cropHeight, imageHeight=$imageHeight',
            );
          }
        }

        // 리사이징 제거 - 원본 해상도 유지

        // 2. 필터 적용 (저장 시에만 적용)
        final PetFilter? currentFilter = _allFilters[_shootFilterKey];
        debugPrint(
          '🔍 필터 적용 확인: filterKey=$_shootFilterKey, filter=${currentFilter?.key}, intensity=$_liveIntensity',
        );
        if (currentFilter != null && currentFilter.key != 'basic_none') {
          // 라이브 필터와 동일한 방식으로 필터 행렬 계산
          List<double> finalMatrix = mixMatrix(
            kIdentityMatrix,
            currentFilter.matrix,
            _liveIntensity,
          );

          debugPrint(
            '📊 필터 행렬 계산 완료: filter=${currentFilter.key}, intensity=$_liveIntensity',
          );

          // 필터 적용 전 이미지 샘플 확인
          final beforeSample = decodedImage.getPixel(0, 0);
          debugPrint(
            '🖼️ 필터 적용 전 샘플 픽셀: R=${beforeSample.r}, G=${beforeSample.g}, B=${beforeSample.b}',
          );

          // 필터 적용
          decodedImage = _applyColorMatrixToImage(decodedImage, finalMatrix);

          // 필터 적용 후 이미지 샘플 확인
          final afterSample = decodedImage.getPixel(0, 0);
          debugPrint(
            '🖼️ 필터 적용 후 샘플 픽셀: R=${afterSample.r}, G=${afterSample.g}, B=${afterSample.b}',
          );

          debugPrint(
            '✅ 필터 적용 완료: ${currentFilter.key}, intensity=$_liveIntensity',
          );
        } else {
          debugPrint(
            '⚠️ 필터가 적용되지 않음: filterKey=$_shootFilterKey, filter=${currentFilter?.key}',
          );
        }

        // 3. 밝기 조절 적용 (밝기 값이 0이 아닐 때만)
        if (_brightnessValue != 0.0) {
          final double brightnessOffset =
              (_brightnessValue / 50.0) *
              255; // -50~50을 -1.0~1.0으로 변환 후 255 곱하기
          final List<double> brightnessMatrix = [
            1,
            0,
            0,
            0,
            brightnessOffset,
            0,
            1,
            0,
            0,
            brightnessOffset,
            0,
            0,
            1,
            0,
            brightnessOffset,
            0,
            0,
            0,
            1,
            0,
          ];
          decodedImage = _applyColorMatrixToImage(
            decodedImage,
            brightnessMatrix,
          );
          debugPrint('✅ 밝기 조절 적용 완료: $_brightnessValue');
        }

        // 처리된 이미지를 임시 파일로 저장 (JPG 품질 100%)
        final Uint8List jpegBytes = Uint8List.fromList(
          img.encodeJpg(decodedImage, quality: 100),
        );

        final dir = await getTemporaryDirectory();
        final filePath =
            '${dir.path}/processed_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final File processedTempFile = File(filePath);
        await processedTempFile.writeAsBytes(jpegBytes);
        processedFile = processedTempFile;

        // decodedImage는 img 패키지가 자동으로 메모리 관리하므로 dispose 불필요

        // 3. 프레임 적용
        if (_frameEnabled) {
          // 프레임 적용 전 이미지 크기 확인
          final beforeFrameBytes = await processedFile.readAsBytes();
          img.Image? beforeFrameImage = img.decodeImage(beforeFrameBytes);
          if (beforeFrameImage != null) {
            debugPrint(
              '📷 프레임 적용 전: ${beforeFrameImage.width}x${beforeFrameImage.height}',
            );
            // img.Image는 자동으로 메모리 관리됨
          }

          final framedFile = await _addPhotoFrame(processedFile);
          if (framedFile.existsSync()) {
            processedFile = framedFile;

            // 프레임 적용 후 이미지 크기 확인
            final afterFrameBytes = await processedFile.readAsBytes();
            img.Image? afterFrameImage = img.decodeImage(afterFrameBytes);
            if (afterFrameImage != null) {
              debugPrint(
                '📷 프레임 적용 후: ${afterFrameImage.width}x${afterFrameImage.height}, 비율: ${(afterFrameImage.width / afterFrameImage.height).toStringAsFixed(3)}',
              );
              // img.Image는 자동으로 메모리 관리됨
            }
            debugPrint('✅ 프레임 적용 완료');
          } else {
            debugPrint('⚠️ 프레임 파일이 생성되지 않음, 이전 단계 결과 사용');
          }
        }

        // 갤러리에만 저장 (내부 폴더 저장 없음)
        if (!processedFile.existsSync()) {
          throw Exception('처리된 이미지 파일이 존재하지 않습니다');
        }

        final finalImageBytes = await processedFile.readAsBytes();
        if (finalImageBytes.isEmpty) {
          throw Exception('이미지 바이트가 비어있습니다');
        }

        // 최종 저장되는 이미지 크기 확인
        img.Image? finalImageCheck = img.decodeImage(finalImageBytes);
        if (finalImageCheck != null) {
          debugPrint(
            '💾 최종 저장 이미지: ${finalImageCheck.width}x${finalImageCheck.height}, 비율: ${(finalImageCheck.width / finalImageCheck.height).toStringAsFixed(3)}, 선택된 비율: ${aspectRatioOf(_aspectMode).toStringAsFixed(3)}',
          );
          // img.Image는 자동으로 메모리 관리됨
        }

        await Gal.putImageBytes(
          finalImageBytes,
          name: 'petgram_shoot_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        debugPrint('✅ 이미지 저장 완료: ${finalImageBytes.length} bytes');
      } catch (processError) {
        debugPrint('❌ 이미지 처리 중 오류: $processError');
        // 처리 실패 시 원본 이미지라도 저장 시도
        try {
          final imageBytes = await file.readAsBytes();
          await Gal.putImageBytes(
            imageBytes,
            name: 'petgram_shoot_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          debugPrint('⚠️ 원본 이미지로 저장됨');
        } catch (saveError) {
          debugPrint('❌ 원본 이미지 저장도 실패: $saveError');
          rethrow;
        }
      }

      // 촬영 성공 피드백
      HapticFeedback.mediumImpact();

      if (kDebugMode) {
        debugPrint('✅ shoot saved to gallery only (no internal storage)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ takePhoto error: $e');
      }
      if (mounted) {
        // 사용자 친화적인 에러 메시지
        String errorMessage = '사진 촬영 중 오류가 발생했어요.';
        if (e.toString().contains('permission') ||
            e.toString().contains('Permission') ||
            e.toString().contains('권한')) {
          errorMessage = '갤러리 저장 권한이 필요합니다. 설정에서 권한을 허용해주세요.';
        } else if (e.toString().contains('storage') ||
            e.toString().contains('저장')) {
          errorMessage = '저장 공간이 부족할 수 있습니다. 저장 공간을 확인해주세요.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);

        // 연속 촬영 모드 처리 (finally에서 처리하여 _isProcessing이 false가 된 후 실행)
        if (_isBurstMode && !_shouldStopBurst) {
          // 현재 촬영한 장수 확인 (이미 증가된 상태)
          debugPrint('📸 연속 촬영 진행: $_burstCount/$_burstCountSetting');

          // 설정한 매수에 도달했는지 확인
          if (_burstCount < _burstCountSetting) {
            // 아직 설정한 매수에 도달하지 않았으면 계속 촬영 (속도 개선: 300ms -> 100ms)
            // 다음 촬영을 위해 카운트 증가
            setState(() => _burstCount++);
            Future.delayed(const Duration(milliseconds: 100), () {
              if (mounted && !_shouldStopBurst) {
                _takePhoto();
              } else {
                // 중지 요청이 있으면 초기화
                debugPrint('🛑 연속 촬영 중지됨');
                if (mounted) {
                  setState(() {
                    _burstCount = 0;
                    _shouldStopBurst = false;
                  });
                }
              }
            });
          } else {
            // 연속 촬영 완료 (현재 촬영 포함하여 설정한 매수 도달)
            debugPrint(
              '✅ 연속 촬영 완료: ${_burstCountSetting}장 (타이머: $_isTimerTriggered)',
            );
            final completedCount = _burstCountSetting;
            setState(() {
              // 연속 촬영 모드는 유지하고 카운트만 초기화
              _burstCount = 0;
              _shouldStopBurst = false;
              // 타이머로 인한 촬영이었다면 플래그 리셋
              if (_isTimerTriggered) {
                _isTimerTriggered = false;
                debugPrint('✅ 타이머 플래그 리셋 (연속 촬영 완료)');
              }
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('연속 촬영 ${completedCount}장이 완료되었어요!'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        } else if (_shouldStopBurst) {
          // 중지 요청이 있으면 초기화
          debugPrint('🛑 연속 촬영 중지 요청 처리');
          setState(() {
            _burstCount = 0;
            _shouldStopBurst = false;
            // 타이머로 인한 촬영이었다면 플래그 리셋
            if (_isTimerTriggered) {
              _isTimerTriggered = false;
            }
          });
          // 중지 요청 시에는 스낵바 표시하지 않음 (완료 메시지와 중복 방지)
        }
      }
    }
  }

  Future<void> _openFilterPage(File file) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            FilterPage(imageFile: file, initialFilterKey: _shootFilterKey),
      ),
    );
    // FilterPage에서 갤러리 저장 후 자동으로 닫히므로 여기서는 추가 처리 불필요
  }

  String _aspectLabel(AspectRatioMode mode) {
    switch (mode) {
      case AspectRatioMode.nineSixteen:
        return '9:16';
      case AspectRatioMode.threeFour:
        return '3:4';
      case AspectRatioMode.oneOne:
        return '1:1';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 상태 변경 시 강제 재빌드를 위한 key 추가
    // 밝기 값이 변경될 때마다 전체 위젯 트리 재빌드
    debugPrint(
      '[Petgram] 🔄 build() called - brightness=$_brightnessValue, focus=$_showFocusIndicator, zoom=$_selectedZoomRatio',
    );
    return Scaffold(
      key: ValueKey(
        'scaffold_${_brightnessValue}_${_showFocusIndicator}_${_selectedZoomRatio}',
      ),
      backgroundColor: const Color(0xFFFFF0F5), // 오버레이 색상으로 고정 (SafeArea 영역 포함)
      body: Stack(
        children: [
          // SafeArea 영역(상단 노치, 하단 홈바) 배경색
          Builder(
            builder: (context) {
              final MediaQueryData mediaQuery = MediaQuery.of(context);
              final double safeAreaTop = mediaQuery.padding.top;
              final double safeAreaBottom = mediaQuery.padding.bottom;

              return Stack(
                children: [
                  // 상단 노치 영역 배경
                  if (safeAreaTop > 0)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: safeAreaTop,
                      child: Container(color: const Color(0xFFFFF0F5)),
                    ),
                  // 하단 홈바 영역 배경
                  if (safeAreaBottom > 0)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: safeAreaBottom,
                      child: Container(color: const Color(0xFFFFF0F5)),
                    ),
                ],
              );
            },
          ),
          // SafeArea 내부 컨텐츠
          SafeArea(
            child: Stack(
              children: [
                // 1) 카메라 / 배경 (중앙 정렬)
                _buildCameraBackground(),
                // GestureDetector는 별도로 추가 (Positioned 위젯과 분리)
                Positioned.fill(
                  child: Builder(
                    builder: (context) => GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onScaleStart: (details) {
                        debugPrint(
                          '[Petgram] ✅ onScaleStart: focalPoint=${details.focalPoint}, pointers=${details.pointerCount}',
                        );
                        _handleZoomScaleStart(details);
                      },
                      onScaleUpdate: (details) {
                        debugPrint(
                          '[Petgram] ✅ onScaleUpdate: scale=${details.scale}, focalPoint=${details.focalPoint}, pointers=${details.pointerCount}',
                        );
                        _handleZoomScaleUpdate(details);
                      },
                      onScaleEnd: (details) {
                        debugPrint(
                          '[Petgram] ✅ onScaleEnd: pointers=${details.pointerCount}',
                        );
                        _handleZoomScaleEnd(details);
                      },
                      // 1) onTapDown: 위치만 저장
                      onTapDown: (details) {
                        debugPrint(
                          '[Petgram] ✅ onTapDown: ${details.globalPosition}',
                        );
                        _lastTapPosition = details.globalPosition;

                        // 필터 패널이 열려있으면 먼저 닫기
                        if (_filterPanelExpanded) {
                          debugPrint('[Petgram] 🔍 필터 패널 닫기 (터치)');
                          setState(() {
                            _filterPanelExpanded = false;
                          });
                          return;
                        }

                        // 연속 촬영 중지 요청
                        if (_isBurstMode && _burstCount > 0) {
                          debugPrint('[Petgram] 🛑 연속 촬영 중지 요청 (터치)');
                          setState(() {
                            _shouldStopBurst = true;
                            _burstCount = 0;
                          });
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('연속 촬영이 종료되었습니다.'),
                                behavior: SnackBarBehavior.floating,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }

                        // 타이머 중지 요청
                        if (_isTimerCounting) {
                          debugPrint('[Petgram] 🛑 타이머 중지 요청 (터치)');
                          setState(() {
                            _shouldStopTimer = true;
                            _isTimerCounting = false;
                            _timerSeconds = 0;
                          });
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('타이머가 종료되었습니다.'),
                                behavior: SnackBarBehavior.floating,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                          return;
                        }
                      },
                      // 2) onTapUp: 여기서만 포커스 실행
                      onTapUp: (details) {
                        final pos = details.globalPosition;
                        final now = DateTime.now();
                        debugPrint(
                          '[Petgram] ✅ onTapUp: ${pos}, _isZooming=$_isZooming, _lastZoomTime=$_lastZoomTime, _lastScaleUpdateTime=$_lastScaleUpdateTime',
                        );

                        // 줌 상태면 무시 (핀치 중에는 절대 탭 포커스 실행 안 됨)
                        // 단, 최근에 onScaleUpdate가 호출되지 않았다면 (200ms 이상 경과)
                        // _isZooming이 true여도 실제로는 핀치가 끝난 것으로 간주
                        if (_isZooming) {
                          // 최근에 onScaleUpdate가 호출되었는지 확인
                          if (_lastScaleUpdateTime != null &&
                              now.difference(_lastScaleUpdateTime!) <
                                  const Duration(milliseconds: 200)) {
                            debugPrint(
                              '[Petgram] 🔍 Tap ignored: zoom in progress (recent scale update: ${now.difference(_lastScaleUpdateTime!).inMilliseconds}ms ago)',
                            );
                            return;
                          } else {
                            // 최근에 onScaleUpdate가 호출되지 않았다면
                            // 핀치가 끝난 것으로 간주하고 _isZooming을 false로 설정
                            debugPrint(
                              '[Petgram] 🔍 Zoom appears to have ended (no recent scale update), allowing tap',
                            );
                            _isZooming = false;
                            _lastZoomTime = null;
                          }
                        }

                        // _isZooming이 false이면 즉시 포커스 실행
                        // onScaleEnd에서 _isZooming = false, _lastZoomTime = null로 설정되면
                        // 바로 탭이 가능해야 함
                        // 쿨타임 완전 제거: _isZooming 플래그만으로 판단

                        _handleTapFocusAtPosition(pos, context);
                      },
                    ),
                  ),
                ),
                // 2) 상하단 오버레이 (비율 조정용)
                _buildAspectRatioOverlay(),
                // 3) 상단 바
                _buildTopBar(),
                // 4) 왼쪽 옵션 패널
                _buildLeftOptionsPanel(),
                // 5) 오른쪽 옵션 패널
                _buildRightOptionsPanel(),
                // 6) 필터 패널
                Builder(
                  builder: (context) {
                    // 하단 바 높이 계산 (버튼 영역이 -40px 위로 올라가 있음)
                    final double bottomBarHeight = 80.0; // 하단 바 높이
                    final double translateOffset =
                        40.0; // Transform.translate offset
                    final double filterPanelBottom =
                        bottomBarHeight + translateOffset + 8; // 여유 공간 추가

                    return Positioned(
                      bottom: filterPanelBottom,
                      left: 0,
                      right: 0,
                      child: ClipRect(
                        child: AnimatedSlide(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          offset: _filterPanelExpanded
                              ? Offset.zero
                              : const Offset(
                                  0,
                                  1,
                                ), // 아래에서 위로 슬라이드 (펼쳐질 때), 위에서 아래로 슬라이드 (닫힐 때)
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 200),
                            opacity: _filterPanelExpanded ? 1.0 : 0.0,
                            child:
                                _buildFilterSelectionPanel(), // 항상 렌더링하여 애니메이션이 부드럽게 작동하도록
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 7) 하단 바
                _buildBottomBar(),
                // 8) 초점 표시기 (모든 UI 요소 위에 표시 - 최상단에 배치)
                if (_showFocusIndicator && _focusPointRelative != null)
                  _buildFocusIndicator(),
                // 9) 자동 초점 표시기 (화면 중앙에 표시)
                if (_showAutoFocusIndicator) _buildAutoFocusIndicator(),
                // 10) 타이머 카운트다운 표시
                if (_isTimerCounting) _buildTimerCountdown(),
                // 11) 연속 촬영 진행 표시
                if (_isBurstMode && _burstCount > 0) _buildBurstProgress(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 핀치 줌 제스처 핸들러
  void _handleZoomScaleStart(ScaleStartDetails details) {
    debugPrint(
      '[Petgram] 🔍 Zoom scale start: currentZoom=$_currentZoomLevel, baseZoom=$_baseZoomLevel, pointers=${details.pointerCount}',
    );

    // details.pointerCount >= 2 인 경우에만 줌 시작으로 본다
    if (details.pointerCount < 2) {
      debugPrint(
        '[Petgram] 🔍 Skipping zoom start: single touch (pointerCount=${details.pointerCount}), resetting _isZooming',
      );
      _isZooming = false;
      return;
    }

    // 핀치 줌 진행 중 플래그를 즉시 설정
    _isZooming = true;
    // _lastZoomTime은 onScaleEnd에서 null로 설정하므로 여기서는 설정하지 않음

    // UI 줌 초기화 (FilterPage처럼)
    _baseZoomScale = _uiZoomScale;
    _lastZoomFocalPoint = details.focalPoint;

    // 목업 모드에서도 기본값이 1.0이 되도록 보장
    if (_currentZoomLevel <= 0) {
      _currentZoomLevel = 1.0;
    }
    // _baseZoomLevel을 현재 줌 레벨로 설정 (제스처 시작 시점의 줌 레벨)
    _baseZoomLevel = _currentZoomLevel;
    debugPrint(
      '[Petgram] 🔍 Zoom scale start: updated baseZoom=$_baseZoomLevel, _isZooming=true, _baseZoomScale=$_baseZoomScale',
    );
  }

  /// 핀치 줌 제스처 업데이트 핸들러
  Future<void> _handleZoomScaleUpdate(ScaleUpdateDetails details) async {
    debugPrint(
      '[Petgram] 🔍 Zoom scale update: scale=${details.scale}, baseZoom=$_baseZoomLevel, currentZoom=$_currentZoomLevel, pointers=${details.pointerCount}',
    );

    // details.pointerCount < 2 이면 줌 처리하지 않고 리턴
    // 핀치 줌이 끝났다는 신호이므로 _isZooming을 false로 설정
    if (details.pointerCount < 2) {
      debugPrint(
        '[Petgram] 🔍 Single touch detected in scale update, resetting _isZooming (pointerCount=${details.pointerCount})',
      );
      _isZooming = false;
      _lastZoomTime = null; // 핀치가 끝났으므로 null로 설정
      _lastScaleUpdateTime = null; // 스케일 업데이트 시간도 초기화
      return;
    }

    // 멀티터치인 경우에만 _isZooming = true 유지
    // 핀치 줌이 진행 중일 때만 true
    _isZooming = true;
    _lastScaleUpdateTime = DateTime.now(); // onScaleUpdate 호출 시간 기록
    // _lastZoomTime은 onScaleEnd에서 null로 설정하므로 여기서는 설정하지 않음

    // UI 줌 업데이트 (FilterPage처럼) - setState로 즉시 반영
    // FilterPage처럼 감쇠 없이 100% 반응으로 자연스럽게 확대/축소
    if (mounted) {
      setState(() {
        // FilterPage처럼 details.scale을 그대로 사용 (감쇠 없음)
        _uiZoomScale = (_baseZoomScale * details.scale).clamp(1.0, 5.0);
        // FilterPage처럼 offset 계산 (focalPoint 변화량, _lastZoomFocalPoint는 업데이트하지 않음)
        _zoomOffset = details.focalPoint - _lastZoomFocalPoint;
      });
    }

    // 카메라가 초기화 중이면 무시
    if (_isCameraInitializing) {
      debugPrint('[Petgram] 🔍 Skipping zoom: camera initializing');
      return;
    }

    // onScaleStart가 호출되지 않았을 때를 대비해 _baseZoomLevel 초기화
    // _baseZoomLevel이 0이거나 유효하지 않으면 현재 줌 레벨로 초기화
    if (_baseZoomLevel <= 0) {
      _baseZoomLevel = _currentZoomLevel > 0 ? _currentZoomLevel : 1.0;
      if (_currentZoomLevel <= 0) {
        _currentZoomLevel = 1.0;
        _baseZoomLevel = 1.0;
      }
      debugPrint(
        '[Petgram] 🔍 Initialized zoom levels (onScaleStart missed): baseZoom=$_baseZoomLevel, currentZoom=$_currentZoomLevel',
      );
    }

    // scale이 1.0에 매우 가까우면 (단일 터치 또는 미세한 움직임) 무시하고 플래그 해제
    if ((details.scale - 1.0).abs() < 0.01) {
      debugPrint(
        '[Petgram] 🔍 Skipping zoom: scale too close to 1.0 (${details.scale}), resetting _isZooming',
      );
      _isZooming = false;
      _lastZoomTime = null; // 핀치가 끝났으므로 null로 설정
      return;
    }

    // 멀티터치가 아닌 경우 추가 체크 (혹시 모를 경우 대비)
    // 이미 위에서 체크했지만, 이중 방어를 위해 다시 체크
    if (details.pointerCount < 2) {
      debugPrint(
        '[Petgram] 🔍 Single touch detected, resetting _isZooming and returning',
      );
      _isZooming = false;
      _lastZoomTime = null; // 핀치가 끝났으므로 null로 설정
      return;
    }

    // 목업 모드에서도 UI 업데이트는 가능하도록 함
    final bool canSetCameraZoom =
        !_useMockCamera &&
        _cameraController != null &&
        _cameraController!.value.isInitialized;

    // 카메라 줌 범위 사용 (초기화 시 저장된 값)
    // 목업 모드에서는 더 넓은 범위 허용 (실제 카메라가 더 높은 줌을 지원할 수 있음)
    final double minZoom = canSetCameraZoom ? _minZoomLevel : 0.5;
    final double maxZoom = canSetCameraZoom
        ? _maxZoomLevel
        : 5.0; // 목업 모드에서도 더 높은 줌 허용

    try {
      double newZoom;
      if (canSetCameraZoom) {
        // 실제 카메라: 저장된 줌 범위 사용
        // FilterPage처럼 감쇠 없이 100% 반응으로 자연스럽게 확대/축소
        newZoom = (_baseZoomLevel * details.scale).clamp(
          _minZoomLevel,
          _maxZoomLevel,
        );
      } else {
        // 목업 모드: 기본 범위 사용
        // FilterPage처럼 감쇠 없이 100% 반응
        newZoom = (_baseZoomLevel * details.scale).clamp(minZoom, maxZoom);
      }

      debugPrint(
        '[Petgram] Zoom: base=$_baseZoomLevel, scale=${details.scale}, new=$newZoom (min=$minZoom, max=$maxZoom), canSetCameraZoom=$canSetCameraZoom',
      );

      // 실제 카메라에 줌 레벨 설정 (목업 모드가 아닐 때만)
      // _currentZoomLevel을 항상 업데이트하여 다음 핀치 제스처의 _baseZoomLevel이 올바르게 설정되도록 함
      _currentZoomLevel = newZoom;

      // 목업 모드에서는 UI 줌 스케일도 실제 줌 레벨과 동기화
      if (!canSetCameraZoom) {
        if (mounted) {
          setState(() {
            _uiZoomScale = newZoom.clamp(1.0, 5.0);
          });
        }
      }

      if (canSetCameraZoom) {
        try {
          await _cameraController!.setZoomLevel(newZoom);
          debugPrint('[Petgram] ✅ Zoom level set to: $newZoom');
        } catch (e) {
          debugPrint('[Petgram] ❌ setZoomLevel error: $e');
          debugPrint('[Petgram] Error stack: ${StackTrace.current}');
        }
      } else {
        // 목업 모드: UI만 업데이트
        debugPrint(
          '[Petgram] 🔍 Mock mode: Zoom level updated to: $newZoom (UI only)',
        );
      }

      // 줌 배율을 0.1 단위로 반올림하여 표시
      // 예: 1.23 -> 1.2, 1.67 -> 1.7, 2.45 -> 2.5
      final double roundedZoom = (newZoom * 10).round() / 10.0;

      // 배율이 0.05 이상 변경되었을 때만 UI 업데이트 (더 빠른 반응)
      final bool ratioChanged =
          (_selectedZoomRatio - roundedZoom).abs() >= 0.05;

      debugPrint(
        '[Petgram] 🔍 Zoom ratio 계산: newZoom=$newZoom, roundedZoom=$roundedZoom, ratioChanged=$ratioChanged, currentRatio=$_selectedZoomRatio',
      );

      // UI 업데이트를 위해 setState 호출 (목업 모드에서도 동작)
      // 0.05 이상 변경되었을 때만 업데이트하여 부드럽고 자연스러운 동작 보장
      // 핀치 줌 시 끝까지 왔다갔다할 수 있도록 더 자주 업데이트
      if (mounted && ratioChanged) {
        setState(() {
          _selectedZoomRatio = roundedZoom;
          debugPrint(
            '[Petgram] 🔍 setState: _currentZoomLevel=$_currentZoomLevel, _selectedZoomRatio=$_selectedZoomRatio',
          );
        });
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ pinch zoom error: $e');
    }
  }

  /// 핀치 줌 제스처 종료 핸들러
  void _handleZoomScaleEnd(ScaleEndDetails details) {
    debugPrint(
      '[Petgram] ✅ onScaleEnd: pointers=${details.pointerCount}, _isZooming=$_isZooming',
    );
    // _isZooming = false (핀치가 끝났으므로 즉시 false로 설정)
    // 핀치가 끝난 직후 탭이 바로 동작하도록 _lastZoomTime을 null로 설정
    _isZooming = false;
    _lastZoomTime = null; // 쿨타임 완전 제거: null로 설정하여 탭이 즉시 동작하도록
    _lastScaleUpdateTime = null; // 스케일 업데이트 시간도 초기화

    if (mounted) {
      setState(() {
        if (_uiZoomScale < 1.1) {
          _uiZoomScale = 1.0;
          _zoomOffset = Offset.zero;
        }
        _baseZoomScale = _uiZoomScale;
      });
    }
    debugPrint(
      '[Petgram] 🔍 Zoom scale end: _isZooming=false, _lastZoomTime=null, _lastScaleUpdateTime=null (쿨타임 제거), _uiZoomScale=$_uiZoomScale',
    );
  }

  /// 카메라 프리뷰 크기 및 오버레이 계산 헬퍼 메서드
  /// 카메라 실제 비율을 기준으로 프리뷰 박스를 계산하고, 그 기준으로 오버레이를 계산
  Map<String, double> _calculateCameraPreviewDimensions() {
    final screenSize = MediaQuery.of(context).size;
    final double screenW = screenSize.width;
    final double screenH = screenSize.height;

    // 타겟 비율 계산 (1:1, 3:4, 9:16)
    final double targetRatio = aspectRatioOf(_aspectMode);

    // 프리뷰 박스 크기 계산 (targetRatio 기반)
    double previewW;
    double previewH;

    if (targetRatio > 1.0) {
      // 가로가 더 긴 비율: 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW / targetRatio;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH * targetRatio;
      }
    } else if (targetRatio < 1.0) {
      // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW / targetRatio;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH * targetRatio;
      }
    } else {
      // 1:1 비율: 가로를 기준으로 계산
      previewW = screenW;
      previewH = previewW;

      if (previewH > screenH) {
        previewH = screenH;
        previewW = previewH;
      }
    }

    // 오버레이는 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
    // 하지만 기존 코드 호환성을 위해 0으로 설정
    double overlayTop = 0;
    double overlayBottom = 0;
    double nineSixteenOverlayTop = 0;
    double nineSixteenOverlayBottom = 0;

    debugPrint(
      '[Petgram] 📐 _calculateCameraPreviewDimensions: targetRatio=$targetRatio, preview=$previewW x $previewH, screen=$screenW x $screenH',
    );

    return {
      'previewW': previewW,
      'previewH': previewH,
      'overlayTop': overlayTop,
      'overlayBottom': overlayBottom,
      'nineSixteenOverlayTop': nineSixteenOverlayTop,
      'nineSixteenOverlayBottom': nineSixteenOverlayBottom,
      'offsetX': (screenW - previewW) / 2,
      'offsetY': (screenH - previewH) / 2,
    };
  }

  /// 상하단 오버레이 (메인 Stack 위에 별도로 표시)
  /// _buildCameraStack 내부의 오버레이 계산과 정확히 동일하게 맞춤
  Widget _buildAspectRatioOverlay() {
    // LayoutBuilder를 사용하여 _buildCameraStack과 동일한 constraints 사용
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth;
        final double maxHeight = constraints.maxHeight;

        // SafeArea 정보 가져오기 (오버레이 위치 계산용)
        final MediaQueryData mediaQuery = MediaQuery.of(context);
        final double safeAreaTop = mediaQuery.padding.top;
        final double safeAreaBottom = mediaQuery.padding.bottom;

        // sensorRatio 계산 (previewSize 기준)
        double sensorRatio = 16.0 / 9.0; // 기본값
        Size? rawPreviewSize;
        if (!_useMockCamera &&
            _cameraController != null &&
            _cameraController!.value.isInitialized) {
          rawPreviewSize = _cameraController!.value.previewSize;
          if (rawPreviewSize != null) {
            sensorRatio =
                math.max(rawPreviewSize.width, rawPreviewSize.height) /
                math.min(rawPreviewSize.width, rawPreviewSize.height);
          }
        }

        // 타겟 비율 계산 (1:1, 3:4, 9:16)
        final double targetRatio = aspectRatioOf(_aspectMode);

        // 프리뷰 박스 크기 계산 (targetRatio 기반)
        double previewBoxW;
        double previewBoxH;

        if (targetRatio > 1.0) {
          // 가로가 더 긴 비율: 가로를 기준으로 계산
          previewBoxW = maxWidth;
          previewBoxH = previewBoxW / targetRatio;

          if (previewBoxH > maxHeight) {
            previewBoxH = maxHeight;
            previewBoxW = previewBoxH * targetRatio;
          }
        } else if (targetRatio < 1.0) {
          // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산
          previewBoxW = maxWidth;
          previewBoxH = previewBoxW / targetRatio;

          if (previewBoxH > maxHeight) {
            previewBoxH = maxHeight;
            previewBoxW = previewBoxH * targetRatio;
          }
        } else {
          // 1:1 비율: 가로를 기준으로 계산
          previewBoxW = maxWidth;
          previewBoxH = previewBoxW;

          if (previewBoxH > maxHeight) {
            previewBoxH = maxHeight;
            previewBoxW = previewBoxH;
          }
        }

        // 호환성을 위해 actualPreviewW/H 사용 (previewBox와 동일)
        final double actualPreviewW = previewBoxW;
        final double actualPreviewH = previewBoxH;

        debugPrint(
          '[Petgram] 📐 _buildAspectRatioOverlay 프리뷰 크기: sensorRatio=$sensorRatio, targetRatio=$targetRatio, previewBox=$actualPreviewW x $actualPreviewH, maxSize=$maxWidth x $maxHeight',
        );

        // 중앙 정렬을 위한 오프셋
        final double offsetX = (maxWidth - actualPreviewW) / 2;
        final double offsetY = (maxHeight - actualPreviewH) / 2;

        // 오버레이는 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
        // 하지만 기존 코드 호환성을 위해 0으로 설정
        double actualOverlayTop = 0;
        double actualOverlayBottom = 0;

        debugPrint(
          '[Petgram] 🔍 AspectRatioOverlay: maxSize=$maxWidth x $maxHeight, actualPreview=$actualPreviewW x $actualPreviewH, targetRatio=$targetRatio, overlayTop=$actualOverlayTop, overlayBottom=$actualOverlayBottom, offsetY=$offsetY, safeAreaTop=$safeAreaTop, safeAreaBottom=$safeAreaBottom',
        );

        // 오버레이는 constraints 전체를 기준으로 배치하되, SafeArea까지 확장
        // 상단 오버레이의 bottom 계산: constraints 기준으로 계산된 위치
        final double overlayTopBottom =
            maxHeight - (offsetY + actualOverlayTop);
        // 하단 오버레이의 top 계산: constraints 기준으로 계산된 위치
        final double overlayBottomTop =
            offsetY + actualPreviewH - actualOverlayBottom;

        return Stack(
          children: [
            // 상단 오버레이 (화면 전체 너비, SafeArea 상단부터 카메라 프리뷰 상단까지)
            if (actualOverlayTop > 0)
              Positioned(
                key: ValueKey('overlay_top_$actualOverlayTop'),
                left: 0,
                right: 0,
                top: -safeAreaTop, // SafeArea 상단까지 확장
                bottom: overlayTopBottom, // constraints 기준 계산된 위치
                child: Container(color: const Color(0xFFFFF0F5)),
              ),
            // 하단 오버레이 (화면 전체 너비, 카메라 프리뷰 하단부터 SafeArea 하단까지)
            if (actualOverlayBottom > 0)
              Positioned(
                key: ValueKey('overlay_bottom_$actualOverlayBottom'),
                left: 0,
                right: 0,
                top: overlayBottomTop, // constraints 기준 계산된 위치
                bottom: -safeAreaBottom, // SafeArea 하단까지 확장
                child: Container(color: const Color(0xFFFFF0F5)),
              ),
          ],
        );
      },
    );
  }

  /// 자동 초점 표시기 (화면 중앙에 표시) - 일반 동그라미로 표시
  Widget _buildAutoFocusIndicator() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.transparent,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.5),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 외부 원
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4),
                            width: 1.2,
                          ),
                        ),
                      ),
                      // 내부 원
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.8),
                        ),
                      ),
                      // 중앙 점
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 타이머 카운트다운 표시
  Widget _buildTimerCountdown() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$_timerSeconds',
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 연속 촬영 진행 표시 (타이머와 동일한 위치와 크기)
  Widget _buildBurstProgress() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$_burstCount/$_burstCountSetting',
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 초점 표시기 빌드 (메인 Stack 최상단에 배치)
  Widget _buildFocusIndicator() {
    debugPrint(
      '[Petgram] 🔍 _buildFocusIndicator called: _showFocusIndicator=$_showFocusIndicator, _focusPointRelative=$_focusPointRelative',
    );

    // MediaQuery를 사용하여 화면 크기 얻기 (LayoutBuilder 대신)
    return Builder(
      key: ValueKey(
        'focus_${_focusPointRelative!.dx}_${_focusPointRelative!.dy}_$_showFocusIndicator',
      ),
      builder: (context) {
        // 프리뷰 박스 크기 및 오프셋 계산
        final previewDims = _calculateCameraPreviewDimensions();
        final double previewW = previewDims['previewW']!;
        final double previewH = previewDims['previewH']!;
        final double offsetX = previewDims['offsetX']!;
        final double offsetY = previewDims['offsetY']!;

        // previewBox 내부 로컬 좌표로 변환 (정규화된 좌표를 previewBox 좌표로)
        final double focusXInPreviewBox = previewW * _focusPointRelative!.dx;
        final double focusYInPreviewBox = previewH * _focusPointRelative!.dy;

        // 화면 좌표로 변환 (Positioned는 Stack 기준이므로 offset 추가)
        final double focusX = offsetX + focusXInPreviewBox - 50;
        final double focusY = offsetY + focusYInPreviewBox - 50;

        debugPrint(
          '[Petgram] 🔍 Focus indicator: preview=$previewW x $previewH, offset=($offsetX, $offsetY), focusInPreviewBox=($focusXInPreviewBox, $focusYInPreviewBox)',
        );
        debugPrint(
          '[Petgram] 🔍 Focus position: relative=${_focusPointRelative}, absolute=($focusX, $focusY)',
        );
        debugPrint(
          '[Petgram] 🔍 Focus state: _showFocusIndicator=$_showFocusIndicator',
        );

        // Positioned는 Stack의 직접 자식이어야 하므로 여기서 반환
        // 크기를 80x80으로 축소
        final double indicatorSize = 80.0;
        final double centerSize = 48.0;
        final double dotSize = 6.0;

        final screenSize = MediaQuery.of(context).size;
        return Positioned(
          left: focusX.clamp(0.0, screenSize.width - indicatorSize),
          top: focusY.clamp(0.0, screenSize.height - indicatorSize),
          child: IgnorePointer(
            ignoring: true,
            child: _showFocusIndicator
                ? TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    builder: (context, scale, child) {
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          width: indicatorSize,
                          height: indicatorSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.transparent,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.white.withValues(alpha: 0.5),
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // 외부 원
                              Container(
                                width: indicatorSize,
                                height: indicatorSize,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.4),
                                    width: 1.2,
                                  ),
                                ),
                              ),
                              // 내부 원
                              Container(
                                width: centerSize,
                                height: centerSize,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.8,
                                  ),
                                ),
                              ),
                              // 중앙 점
                              Container(
                                width: dotSize,
                                height: dotSize,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : const SizedBox.shrink(),
          ),
        );
      },
    );
  }

  /// 화면 중앙에 자동 초점 설정 (최초 진입 시)
  Future<void> _setAutoFocusAtCenter() async {
    if (_useMockCamera ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    // 화면 중앙 좌표 (0.5, 0.5)
    const centerPoint = Offset(0.5, 0.5);

    debugPrint('[Petgram] 🔍 자동 초점 설정: 화면 중앙 ($centerPoint)');

    // 카메라에 초점 설정 (자동 초점이므로 UI 표시하지 않음)
    try {
      await _cameraController!.setFocusPoint(centerPoint);
      debugPrint('[Petgram] ✅ 자동 초점 설정 완료 (화면 중앙)');

      // 초점 설정 성공 시 자동 초점 표시기만 표시 (수동 터치 초점과 구분)
      if (mounted) {
        setState(() {
          _focusPointRelative = centerPoint;
          _showAutoFocusIndicator = true;
        });
        // 1.5초 후 자동 초점 표시기 숨기기
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) {
            setState(() {
              _showAutoFocusIndicator = false;
            });
          }
        });
      }
    } catch (e) {
      debugPrint('[Petgram] ❌ 자동 초점 설정 실패: $e');
    }
  }

  /// 탭 포커스 핸들러 (위치 기반)
  void _handleTapFocusAtPosition(Offset globalPos, BuildContext context) {
    debugPrint(
      '[Petgram] 🔍 _handleTapFocusAtPosition called: ${globalPos}, _isZooming=$_isZooming',
    );

    // 안전을 위해 기본 방어
    if (_isZooming) {
      debugPrint(
        '[Petgram] 🔍 Focus canceled in _handleTapFocusAtPosition: zoom in progress',
      );
      return;
    }

    // 카메라가 초기화 중이면 무시
    if (_isCameraInitializing) {
      debugPrint(
        '[Petgram] 🔍 Skipping focus: _isCameraInitializing=$_isCameraInitializing',
      );
      return;
    }

    // 실제 카메라 초점 설정은 카메라가 준비되었을 때만 수행
    // 하지만 UI 표시는 목업 카메라 모드에서도 가능하도록 함
    final bool canSetCameraFocus =
        !_useMockCamera &&
        _cameraController != null &&
        _cameraController!.value.isInitialized;

    debugPrint(
      '[Petgram] 🔍 Camera focus state: canSetCameraFocus=$canSetCameraFocus, _useMockCamera=$_useMockCamera',
    );

    // GestureDetector의 RenderBox 찾기 (전체 화면 기준)
    final RenderBox? gestureBox = context.findRenderObject() as RenderBox?;
    if (gestureBox == null) {
      debugPrint('[Petgram] ❌ RenderBox not found');
      return;
    }

    // 전체 화면 기준 로컬 좌표
    final Offset localPoint = gestureBox.globalToLocal(globalPos);

    // _buildCameraStack과 동일한 로직으로 프리뷰 박스 크기 계산
    final screenSize = MediaQuery.of(context).size;
    final double maxWidth = screenSize.width;
    final double maxHeight = screenSize.height;

    // 프리뷰 박스 크기는 _aspectMode의 targetRatio를 기준으로 계산
    final double targetRatio = aspectRatioOf(_aspectMode);

    // 프리뷰 박스 크기 계산 (targetRatio 기반)
    double previewBoxW;
    double previewBoxH;

    if (targetRatio > 1.0) {
      // 가로가 더 긴 비율: 가로를 기준으로 계산
      previewBoxW = maxWidth;
      previewBoxH = previewBoxW / targetRatio;

      if (previewBoxH > maxHeight) {
        previewBoxH = maxHeight;
        previewBoxW = previewBoxH * targetRatio;
      }
    } else if (targetRatio < 1.0) {
      // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산 (고정)
      previewBoxW = maxWidth;
      previewBoxH = previewBoxW / targetRatio;

      if (previewBoxH > maxHeight) {
        previewBoxH = maxHeight;
        previewBoxW = previewBoxH * targetRatio;
      }
    } else {
      // 1:1 비율: 가로를 기준으로 계산 (고정)
      previewBoxW = maxWidth;
      previewBoxH = previewBoxW; // 1:1이므로 같음

      if (previewBoxH > maxHeight) {
        previewBoxH = maxHeight;
        previewBoxW = previewBoxH; // 1:1이므로 같음
      }
    }

    // 중앙 정렬을 위한 오프셋
    final double offsetX = (maxWidth - previewBoxW) / 2;
    final double offsetY = (maxHeight - previewBoxH) / 2;

    // sensorRatio 계산 (previewSize 기준)
    double sensorRatio = 16.0 / 9.0; // 기본값 (세로가 긴 경우)
    Size? rawPreviewSize;
    if (!_useMockCamera &&
        _cameraController != null &&
        _cameraController!.value.isInitialized) {
      rawPreviewSize = _cameraController!.value.previewSize;
      if (rawPreviewSize != null) {
        sensorRatio =
            math.max(rawPreviewSize.width, rawPreviewSize.height) /
            math.min(rawPreviewSize.width, rawPreviewSize.height);
      }
    }

    // 터치 좌표를 프리뷰 박스 기준으로 변환 (previewBox 내부 로컬 좌표)
    final double tapXInPreviewBox = localPoint.dx - offsetX;
    final double tapYInPreviewBox = localPoint.dy - offsetY;

    // 프리뷰 박스 영역 밖이면 무시
    if (tapXInPreviewBox < 0 ||
        tapXInPreviewBox > previewBoxW ||
        tapYInPreviewBox < 0 ||
        tapYInPreviewBox > previewBoxH) {
      debugPrint(
        '[Petgram] 🔍 Tap outside preview box: ($tapXInPreviewBox, $tapYInPreviewBox)',
      );
      return;
    }

    // normalize된 sensorRatio 기준으로 상대 좌표 계산 (0.0~1.0)
    // previewBox 내부 로컬 좌표를 센서 좌표계로 변환
    double relativeX;
    double relativeY;

    if (rawPreviewSize != null) {
      // FittedBox 내부의 SizedBox 크기 계산 (_buildCameraStack과 동일한 로직)
      double contentW;
      double contentH;

      if (rawPreviewSize.width >= rawPreviewSize.height) {
        // 가로가 큰 경우
        contentH = previewBoxH;
        contentW = previewBoxH * sensorRatio;
      } else {
        // 세로가 큰 경우
        contentW = previewBoxH;
        contentH = previewBoxH / sensorRatio;
      }

      // FittedBox(BoxFit.cover)는 content를 previewBox에 맞추기 위해 스케일링
      // previewBox 내부 좌표를 content 좌표계로 변환
      final double contentRatio = contentW / contentH;
      final double previewBoxRatio = previewBoxW / previewBoxH;

      double scaledContentW;
      double scaledContentH;
      double contentOffsetX = 0;
      double contentOffsetY = 0;

      if (contentRatio > previewBoxRatio) {
        // content가 더 넓음: 높이를 기준으로 스케일링
        scaledContentH = previewBoxH;
        scaledContentW = scaledContentH * contentRatio;
        contentOffsetX = (previewBoxW - scaledContentW) / 2;
      } else {
        // content가 더 좁음: 너비를 기준으로 스케일링
        scaledContentW = previewBoxW;
        scaledContentH = scaledContentW / contentRatio;
        contentOffsetY = (previewBoxH - scaledContentH) / 2;
      }

      // previewBox 내부 좌표를 content 좌표계로 변환
      final double contentX = tapXInPreviewBox - contentOffsetX;
      final double contentY = tapYInPreviewBox - contentOffsetY;

      // content 좌표를 rawPreviewSize 기준으로 정규화 (0.0~1.0)
      relativeX = (contentX / scaledContentW).clamp(0.0, 1.0);
      relativeY = (contentY / scaledContentH).clamp(0.0, 1.0);
    } else {
      // rawPreviewSize가 없으면 previewBox 기준으로 정규화
      relativeX = (tapXInPreviewBox / previewBoxW).clamp(0.0, 1.0);
      relativeY = (tapYInPreviewBox / previewBoxH).clamp(0.0, 1.0);
    }

    // 상대 좌표를 0.0~1.0 범위로 클램프
    final double clampedX = relativeX.clamp(0.0, 1.0);
    final double clampedY = relativeY.clamp(0.0, 1.0);

    debugPrint(
      '[Petgram] 🔍 Tap: screen=(${localPoint.dx}, ${localPoint.dy}), previewBox=($tapXInPreviewBox, $tapYInPreviewBox), relative=($clampedX, $clampedY), sensorRatio=$sensorRatio',
    );
    debugPrint('[Petgram] 🔍 Focus point calculated: ($clampedX, $clampedY)');
    debugPrint(
      '[Petgram] 🔍 Setting focus indicator: show=true, point=($clampedX, $clampedY)',
    );

    // 초점 표시기를 먼저 표시 (setState로 즉시 업데이트)
    if (mounted) {
      debugPrint('[Petgram] 🔍 Calling setState to update focus indicator');
      setState(() {
        _focusPointRelative = Offset(clampedX, clampedY);
        _showFocusIndicator = true;
        debugPrint(
          '[Petgram] 🔍 Focus indicator state updated: _showFocusIndicator=$_showFocusIndicator, _focusPointRelative=$_focusPointRelative',
        );
      });
      debugPrint('[Petgram] 🔍 setState completed');
    } else {
      debugPrint('[Petgram] 🔍 Widget not mounted, skipping setState');
    }

    // 카메라에 초점 설정 (실제 카메라가 준비되었을 때만)
    if (canSetCameraFocus) {
      _cameraController!
          .setFocusPoint(Offset(clampedX, clampedY))
          .then((_) {
            debugPrint('[Petgram] ✅ Focus point set successfully');
            // 수동 초점 설정 시에는 자동 초점 표시기를 표시하지 않음
            // (_showFocusIndicator만 사용)
          })
          .catchError((e) {
            debugPrint('[Petgram] ❌ Focus point error: $e');
          });
    } else {
      debugPrint(
        '[Petgram] 🔍 Skipping camera focus (mock mode or not initialized)',
      );
    }

    // 1.5초 후 초점 표시기 숨기기 (페이드 아웃 애니메이션)
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() {
          _showFocusIndicator = false;
        });
      }
    });
  }

  /// 카메라 / 목업 배경
  Widget _buildCameraBackground() {
    debugPrint(
      '[Petgram] _buildCameraBackground() called, _aspectMode=$_aspectMode',
    );

    final double targetRatio = aspectRatioOf(_aspectMode);

    final PetFilter? filter = _allFilters[_shootFilterKey];

    final bool canUseCamera =
        !_useMockCamera &&
        _cameraController != null &&
        _cameraController!.value.isInitialized;

    final bool isMockPreview = !canUseCamera;

    debugPrint(
      '[Petgram] 🔍 Camera state: _isCameraInitializing=$_isCameraInitializing, _useMockCamera=$_useMockCamera, canUseCamera=$canUseCamera, isMockPreview=$isMockPreview',
    );

    // CameraPreview는 GestureDetector 없이 사용 (Stack 전체에 GestureDetector 적용)
    final Widget source = canUseCamera
        ? CameraPreview(_cameraController!)
        : Image.asset(
            'assets/images/mockup.png',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );

    // Mock Preview든 실제 Preview든, 초기화 중이든 항상 Stack을 반환하여
    // 오버레이, 밝기, 초점 표시기 등이 항상 표시되도록 함
    if (isMockPreview) {
      debugPrint('[Petgram] mock source widget built (logo + text)');
    }

    // Builder 제거하고 직접 계산 - 상태 변경 시 항상 재빌드되도록 보장
    // MediaQuery는 build 메서드에서 이미 접근 가능하므로 Builder 불필요
    return _buildCameraStack(
      targetRatio: targetRatio,
      filter: filter,
      source: source,
      canUseCamera: canUseCamera,
      isCameraInitializing: _isCameraInitializing,
    );
  }

  /// 카메라 Stack 빌드 (상태 변경 시 항상 재빌드되도록 분리)
  Widget _buildCameraStack({
    required double targetRatio,
    required PetFilter? filter,
    required Widget source,
    required bool canUseCamera,
    required bool isCameraInitializing,
  }) {
    return Builder(
      builder: (context) {
        // sensorRatio 계산 (previewSize 기준)
        double sensorRatio = 16.0 / 9.0; // 기본값
        Size? rawPreviewSize;
        if (!_useMockCamera &&
            _cameraController != null &&
            _cameraController!.value.isInitialized) {
          rawPreviewSize = _cameraController!.value.previewSize;
          if (rawPreviewSize != null) {
            sensorRatio =
                math.max(rawPreviewSize.width, rawPreviewSize.height) /
                math.min(rawPreviewSize.width, rawPreviewSize.height);
            debugPrint(
              '[Petgram] 📐 _buildCameraStack: sensorRatio=$sensorRatio, rawPreviewSize=${rawPreviewSize.width}x${rawPreviewSize.height}',
            );
          }
        } else {
          debugPrint(
            '[Petgram] 📐 _buildCameraStack: 목업 모드 또는 카메라 미초기화, 기본값 사용',
          );
        }

        // 카메라 프리뷰는 원본 비율을 유지, 남는 영역은 오버레이로 채움
        return Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // LayoutBuilder로 실제 AspectRatio가 결정한 크기 측정
              final double maxWidth = constraints.maxWidth;
              final double maxHeight = constraints.maxHeight;

              // 프리뷰 박스 크기는 _aspectMode의 targetRatio를 기준으로 계산
              // 프리뷰 박스 모양이 선택한 비율(1:1, 3:4, 9:16)에 맞춰져야 함
              final double targetRatio = aspectRatioOf(_aspectMode);

              // 프리뷰 박스 크기 계산 (targetRatio 기반)
              // targetRatio에 따라 적절한 기준 선택
              double previewBoxW;
              double previewBoxH;

              if (targetRatio > 1.0) {
                // 가로가 더 긴 비율: 가로를 기준으로 계산
                previewBoxW = maxWidth;
                previewBoxH = previewBoxW / targetRatio;

                if (previewBoxH > maxHeight) {
                  previewBoxH = maxHeight;
                  previewBoxW = previewBoxH * targetRatio;
                }
              } else if (targetRatio < 1.0) {
                // 세로가 더 긴 비율 (3:4 등): 가로를 기준으로 계산 (고정)
                previewBoxW = maxWidth;
                previewBoxH = previewBoxW / targetRatio;

                if (previewBoxH > maxHeight) {
                  previewBoxH = maxHeight;
                  previewBoxW = previewBoxH * targetRatio;
                }
              } else {
                // 1:1 비율: 가로를 기준으로 계산 (고정)
                previewBoxW = maxWidth;
                previewBoxH = previewBoxW; // 1:1이므로 같음

                if (previewBoxH > maxHeight) {
                  previewBoxH = maxHeight;
                  previewBoxW = previewBoxH; // 1:1이므로 같음
                }
              }

              // 중앙 정렬을 위한 오프셋
              final double offsetX = (maxWidth - previewBoxW) / 2;
              final double offsetY = (maxHeight - previewBoxH) / 2;

              // sensorRatio 계산 (previewSize 기준)
              double sensorRatio = 16.0 / 9.0; // 기본값 (세로가 긴 경우)
              Size? rawPreviewSize;
              if (!_useMockCamera &&
                  _cameraController != null &&
                  _cameraController!.value.isInitialized) {
                rawPreviewSize = _cameraController!.value.previewSize;
                if (rawPreviewSize != null) {
                  sensorRatio =
                      math.max(rawPreviewSize.width, rawPreviewSize.height) /
                      math.min(rawPreviewSize.width, rawPreviewSize.height);
                }
              }

              // 디버그 로그
              debugPrint(
                '[Petgram] 📐 preview layout - sensorRatio=$sensorRatio, targetRatio=$targetRatio, box=${previewBoxW}x${previewBoxH}, rawPreviewSize=${rawPreviewSize?.width}x${rawPreviewSize?.height}',
              );

              // 오버레이 계산은 더 이상 필요 없음 (프리뷰 박스가 이미 targetRatio를 따름)
              // 하지만 기존 코드 호환성을 위해 0으로 설정
              double actualOverlayTop = 0;
              double actualOverlayBottom = 0;

              // frameTopOffset 계산 (프리뷰 박스 기준으로 재계산)
              double frameTopOffset = 0;
              if (_aspectMode == AspectRatioMode.nineSixteen ||
                  _aspectMode == AspectRatioMode.threeFour) {
                final double safeAreaTop = MediaQuery.of(context).padding.top;
                final double topBarHeight = 8 + 48 + 8;
                final double screenTopBarHeight = safeAreaTop + topBarHeight;
                final double previewTop = offsetY + actualOverlayTop;

                if (screenTopBarHeight > previewTop) {
                  frameTopOffset = screenTopBarHeight - previewTop;
                  frameTopOffset = frameTopOffset.clamp(0.0, previewBoxH);
                }
              }

              return Stack(
                children: [
                  // 전체 배경을 오버레이 색상으로 채움 (남는 영역 포함)
                  Positioned.fill(
                    child: Container(color: const Color(0xFFFFF0F5)),
                  ),
                  // 카메라 프리뷰 중앙 배치
                  // 프리뷰 박스는 targetRatio 기반, 내부 카메라 콘텐츠는 sensorRatio 유지
                  Positioned(
                    left: offsetX,
                    top: offsetY,
                    width: previewBoxW, // targetRatio 기반 프리뷰 박스 너비
                    height: previewBoxH, // targetRatio 기반 프리뷰 박스 높이
                    child: ClipRect(
                      child: FittedBox(
                        fit: BoxFit.cover, // 비율 유지한 채 박스 꽉 채우기 (크롭 허용)
                        alignment: Alignment.center,
                        child: Builder(
                          builder: (context) {
                            // sensorRatio와 previewBoxW/previewBoxH를 비교하여 SizedBox 크기 계산
                            double contentW;
                            double contentH;

                            // previewBox의 비율
                            final double previewBoxRatio =
                                previewBoxW / previewBoxH;

                            // 센서의 실제 비율 계산
                            // 목업도 같은 경로를 타므로 동일한 로직 사용
                            // 나중에 필요하면 목업만 BoxFit.contain으로 분리 가능
                            double sensorAspectRatio;
                            if (rawPreviewSize != null) {
                              // 센서의 실제 비율 (width/height)
                              sensorAspectRatio =
                                  rawPreviewSize.width / rawPreviewSize.height;
                            } else {
                              // 기본값: 세로가 긴 경우 (9:16)
                              // 목업 이미지의 실제 비율을 가져와서 사용할 수도 있음
                              sensorAspectRatio = 9.0 / 16.0;
                            }

                            // 센서 비율과 previewBox 비율 비교
                            if (sensorAspectRatio > previewBoxRatio) {
                              // 센서가 더 넓음: 높이를 previewBoxH에 맞추고 너비 계산
                              contentH = previewBoxH;
                              contentW = previewBoxH * sensorAspectRatio;
                            } else {
                              // 센서가 더 좁음: 너비를 previewBoxW에 맞추고 높이 계산
                              contentW = previewBoxW;
                              contentH = previewBoxW / sensorAspectRatio;
                            }

                            // AspectRatio는 센서의 실제 비율 사용
                            final double aspectRatioForAspectRatioWidget =
                                sensorAspectRatio;

                            debugPrint(
                              '[Petgram] 📐 Camera content: ${contentW}x${contentH}, sensorAspectRatio=$sensorAspectRatio, previewBoxRatio=$previewBoxRatio, aspectRatio=$aspectRatioForAspectRatioWidget',
                            );

                            return SizedBox(
                              width: contentW,
                              height: contentH,
                              child: AspectRatio(
                                aspectRatio: aspectRatioForAspectRatioWidget,
                                child: Stack(
                                  key: ValueKey(
                                    'camera_stack_${_aspectMode}_${_brightnessValue}_${_showFocusIndicator}',
                                  ),
                                  fit: StackFit.expand,
                                  clipBehavior: Clip.hardEdge,
                                  children: [
                                    // 1. 카메라 프리뷰 또는 초기화 중 표시
                                    Positioned.fill(
                                      child: RepaintBoundary(
                                        key: ValueKey('camera_preview'),
                                        child: Builder(
                                          builder: (context) {
                                            debugPrint(
                                              '[Petgram] 🎥 Rendering preview: isCameraInitializing=$isCameraInitializing, canUseCamera=$canUseCamera',
                                            );
                                            if (isCameraInitializing &&
                                                canUseCamera) {
                                              debugPrint(
                                                '[Petgram] ⏳ Showing loading indicator',
                                              );
                                              return Container(
                                                color: Colors.black,
                                                child: const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: kMainPink,
                                                      ),
                                                ),
                                              );
                                            } else {
                                              debugPrint(
                                                '[Petgram] 📷 Showing camera/mock preview',
                                              );
                                              // 필터와 밝기 적용
                                              Widget preview =
                                                  _buildFilteredWidgetLive(
                                                    filter,
                                                    source,
                                                  );
                                              // UI 줌 적용 (FilterPage처럼)
                                              if (_uiZoomScale != 1.0 ||
                                                  _zoomOffset != Offset.zero) {
                                                preview = Transform.scale(
                                                  scale: _uiZoomScale,
                                                  child: Transform.translate(
                                                    offset: _zoomOffset,
                                                    child: preview,
                                                  ),
                                                );
                                              }
                                              return preview;
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                    // 2. 격자 라인 오버레이 (프리뷰 박스 전체에 표시)
                                    if (_showGridLines)
                                      Positioned.fill(
                                        key: ValueKey(
                                          'grid_lines_${_aspectMode}',
                                        ),
                                        child: _buildGridLines(
                                          previewBoxW,
                                          previewBoxH,
                                          frameTopOffset,
                                        ),
                                      ),
                                    // 3. 프레임 오버레이 (프리뷰 박스 기준)
                                    if (_frameEnabled && _petList.isNotEmpty)
                                      Positioned.fill(
                                        key: ValueKey('frame_overlay'),
                                        child: IgnorePointer(
                                          ignoring: true,
                                          child: _buildFramePreviewOverlay(
                                            maxWidth, // 전체 화면 너비
                                            maxHeight, // 전체 화면 높이
                                            frameTopOffset,
                                            offsetY, // 프리뷰 박스 상단 (화면 기준)
                                            offsetY +
                                                previewBoxH, // 프리뷰 박스 하단 (화면 기준)
                                            previewBoxW,
                                            previewBoxH,
                                            offsetX,
                                            offsetY,
                                          ),
                                        ),
                                      ),
                                  ],
                                ), // Stack 닫기
                              ), // AspectRatio 닫기
                            ); // SizedBox 닫기 (return 문 종료)
                          }, // builder function 닫기
                        ), // Builder 닫기
                      ), // FittedBox 닫기
                    ), // ClipRect 닫기
                  ), // Positioned 닫기
                ],
              ); // Stack 닫기
            },
          ),
        );
      },
    );
  }

  /// 라이브 필터 적용 (촬영 화면 미리보기) - 필터와 밝기 모두 적용
  Widget _buildFilteredWidgetLive(PetFilter? filter, Widget child) {
    debugPrint(
      '[Petgram] 🎨 _buildFilteredWidgetLive called: filter=${filter?.key}, brightness=$_brightnessValue',
    );

    Widget result = child;
    debugPrint(
      '[Petgram] 🎨 Initial result widget type: ${result.runtimeType}',
    );

    // 필터 적용
    final PetFilter safe = filter ?? _allFilters['basic_none']!;
    // 임시로 필터 적용 비활성화하여 목업 프리뷰가 보이는지 확인
    if (safe.key != 'basic_none') {
      debugPrint(
        '[Petgram] 🎨 Applying filter: ${safe.key}, intensity=$_liveIntensity',
      );
      // 필터 행렬 계산
      List<double> finalMatrix = mixMatrix(
        kIdentityMatrix,
        safe.matrix,
        _liveIntensity,
      );

      // ColorFiltered로 필터 적용
      result = ColorFiltered(
        colorFilter: ColorFilter.matrix(finalMatrix),
        child: result,
      );
      debugPrint(
        '[Petgram] 🎨 Filter applied, result type: ${result.runtimeType}',
      );
    } else {
      debugPrint(
        '[Petgram] 🎨 Filter skipped (basic_none or disabled for testing)',
      );
    }

    // 밝기 조절 적용 (필터 위에 적용)
    if (_brightnessValue != 0.0) {
      debugPrint('[Petgram] 🎨 Applying brightness: $_brightnessValue');
      result = ColorFiltered(
        colorFilter: ColorFilter.matrix([
          1,
          0,
          0,
          0,
          (_brightnessValue / 50.0) * 255, // -50~50을 -1.0~1.0으로 변환 후 255 곱하기
          0,
          1,
          0,
          0,
          (_brightnessValue / 50.0) * 255,
          0,
          0,
          1,
          0,
          (_brightnessValue / 50.0) * 255,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: result,
      );
      debugPrint(
        '[Petgram] 🎨 Brightness applied, result type: ${result.runtimeType}',
      );
    }

    // 필터 변경 시 부드러운 전환 애니메이션
    // Positioned.fill 안에서 사용되므로 SizedBox.expand 사용
    debugPrint(
      '[Petgram] 🎨 Final result type: ${result.runtimeType}, returning directly',
    );

    // Positioned.fill이 크기를 제어하므로 직접 반환
    // AnimatedSwitcher는 overflow 발생하므로 제거
    return result;
  }

  /// 그리드라인 오버레이 (풀 오버레이 기준으로 한번에 그리기)
  /// 비율을 바꾸면 상하단 오버레이가 자연스럽게 가려짐
  /// 프레임 유무와 관계없이 항상 풀 오버레이 기준으로 그려짐
  Widget _buildGridLines(double width, double height, double frameTopOffset) {
    // 실제 프리뷰 영역(오버레이 제외)에만 격자 표시
    return IgnorePointer(
      ignoring: true,
      child: CustomPaint(
        painter: GridLinesPainter(),
        size: Size(width, height),
      ),
    );
  }

  /// 프레임 미리보기 오버레이 (새로운 구조)
  /// 프레임은 오버레이가 가려지는 바로 위와 아래에 자동으로 조정됨
  Widget _buildFramePreviewOverlay(
    double screenWidth,
    double screenHeight,
    double frameTopOffset,
    double overlayTopScreen, // 사용하지 않음 (호환성 유지)
    double overlayBottomScreen, // 사용하지 않음 (호환성 유지)
    double previewWidth,
    double previewHeight,
    double previewOffsetX,
    double previewOffsetY,
  ) {
    // 프레임은 프리뷰 박스 내부에 그려지므로, 프리뷰 박스 로컬 좌표계 사용
    // 프리뷰 박스는 Positioned(left: offsetX, top: offsetY, width: previewBoxW, height: previewBoxH)
    // 내부에서는 (0, 0)부터 (previewWidth, previewHeight)까지의 좌표계 사용

    // 촬영본과 동일한 정규화 비율 계산
    // 촬영본에서: overlayTop / imageHeight = normalizedTop
    // 프리뷰에서: normalizedTop * previewHeight = topBarHeight

    // 프리뷰 박스는 이미 크롭된 영역이므로, 프레임 위치를 previewBox 내부 로컬 좌표로 직접 계산
    // 프레임은 크롭된 이미지 상단에서 frameMargin만큼 아래에 배치
    final double frameMargin = previewWidth * 0.02;
    final double finalTopBarHeight = frameMargin;

    // 하단 프레임 위치: 프리뷰 박스 하단 (프리뷰 박스 내부 기준, 로컬 좌표)
    final double bottomBarHeight = previewHeight; // 프리뷰 박스 하단 = previewHeight

    debugPrint(
      '[Petgram] 🔍 FramePreviewOverlay: previewBox=${previewWidth}x${previewHeight}, frameMargin=$frameMargin, finalTopBarHeight=$finalTopBarHeight',
    );

    return CustomPaint(
      painter: FramePreviewPainter(
        petList: _petList,
        selectedPetId: _selectedPetId,
        previewWidth: previewWidth,
        previewHeight: previewHeight,
        imageWidth: previewWidth, // 프리뷰와 동일
        imageHeight: previewHeight, // 프리뷰와 동일
        aspectMode: _aspectMode,
        topBarHeight: finalTopBarHeight, // 프리뷰 박스 내부 기준 상단 위치 (정규화 비율 적용)
        bottomBarHeight: bottomBarHeight, // 프리뷰 박스 내부 기준 하단 위치
        dogIconImage: _dogIconImage,
        catIconImage: _catIconImage,
        location: _currentLocation,
      ),
      size: Size(previewWidth, previewHeight), // 프리뷰 박스 크기
    );
  }

  /// 상단 로고 + 프레임 설정 + 설정 버튼
  Widget _buildTopBar() {
    // 로고와 아이콘 크기 조정
    final double logoSize = 28.0; // 36.0 -> 28.0
    final double fontSize = 20.0; // 16.0 -> 20.0 (텍스트 크기 키움)
    final double horizontalPadding = 12.0;
    final double verticalPadding = 10.0; // 12.0 -> 10.0 (살짝 위로)
    final double iconSize = 18.0; // 16.0 -> 18.0 (아이콘 크기 살짝 키움)

    // 상단 바 위치는 화면 기준에서 아래로 내림
    return Positioned(
      top: 6.0, // 8.0 -> 6.0 (살짝 위로)
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.only(
          left: horizontalPadding,
          right: horizontalPadding,
          top: verticalPadding,
          bottom: verticalPadding,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 투명 박스 제거, 아이콘만 표시
            SizedBox(
              width: logoSize,
              height: logoSize,
              child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
            ),
            const SizedBox(width: 0), // 로고와 글씨 더 가깝게 (1 -> 0)
            Text(
              'Petgram',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                color: kMainPink, // 연분홍색으로 변경
                letterSpacing: 0.8,
                shadows: [
                  Shadow(
                    blurRadius: 12,
                    color: Colors.black.withValues(alpha: 0.8),
                    offset: const Offset(0, 3),
                  ),
                  Shadow(
                    blurRadius: 6,
                    color: Colors.black.withValues(alpha: 0.6),
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // 위치정보 업데이트 버튼 (프레임이 켜져있고 위치정보가 활성화된 경우에만 표시)
            if (_frameEnabled && _petList.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  final selectedPet = _selectedPetId != null
                      ? _petList.firstWhere(
                          (pet) => pet.id == _selectedPetId,
                          orElse: () => _petList.first,
                        )
                      : _petList.first;

                  if (selectedPet.locationEnabled) {
                    return Container(
                      width: 36, // 가로 길이 늘림
                      height: 32, // 세로 길이 조정 (아이콘 크기 + 패딩)
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        iconSize: 16, // 14 -> 16 (아이콘 크기 살짝 키움)
                        onPressed: () async {
                          // GPS 업데이트 시: 위치정보 재로드
                          _checkAndFetchLocation(forceReload: true);
                          HapticFeedback.lightImpact();
                          // _fetchLocation 내부에서 스낵바를 표시하므로 여기서는 추가 처리 불필요
                        },
                        icon: Stack(
                          children: [
                            // 그림자 효과
                            Positioned(
                              left: 0.5,
                              top: 0.5,
                              child: Icon(
                                Icons.location_on,
                                color: Colors.black.withValues(alpha: 0.6),
                                size: 16, // 14 -> 16 (아이콘 크기 살짝 키움)
                              ),
                            ),
                            // 실제 아이콘
                            const Icon(
                              Icons.location_on,
                              color: Colors.white,
                              size: 16, // 14 -> 16 (아이콘 크기 살짝 키움)
                            ),
                          ],
                        ),
                        tooltip: '위치 정보 업데이트',
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              const SizedBox(width: 4),
            ],
            // 프레임 설정 버튼 (별도 그룹)
            Container(
              width: 36, // 가로 길이 늘림
              height: 32, // 세로 길이 조정 (아이콘 크기 + 패딩)
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: iconSize, // 16.0
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FrameSettingsPage(
                        petList: _petList,
                        frameEnabled: _frameEnabled,
                        selectedPetId: _selectedPetId,
                        onPetListChanged: (list, selectedId) {
                          setState(() {
                            _petList = list;
                            _selectedPetId = selectedId;
                          });
                          // 반려동물 리스트 변경 시: 위치정보가 활성화된 프레임이면 위치정보 다시 불러오기
                          if (_frameEnabled && _petList.isNotEmpty) {
                            final selectedPet = _selectedPetId != null
                                ? _petList.firstWhere(
                                    (pet) => pet.id == _selectedPetId,
                                    orElse: () => _petList.first,
                                  )
                                : _petList.first;
                            if (selectedPet.locationEnabled) {
                              debugPrint(
                                '[Petgram] 📍 onPetListChanged: 위치정보 활성화됨, 위치정보 불러오기 시작',
                              );
                              _checkAndFetchLocation(alwaysReload: true);
                            } else {
                              debugPrint(
                                '[Petgram] 📍 onPetListChanged: 위치정보 비활성화됨',
                              );
                              // 위치 정보 활성화가 안 되어 있으면 null로 설정
                              if (mounted) {
                                setState(() {
                                  _currentLocation = null;
                                });
                              }
                            }
                          }
                        },
                        onFrameEnabledChanged: (enabled) {
                          setState(() {
                            _frameEnabled = enabled;
                          });
                          _saveFrameEnabled();
                          // 프레임을 켤 때: 위치정보가 활성화된 프레임이면 위치정보 다시 불러오기
                          if (enabled && _petList.isNotEmpty) {
                            final selectedPet = _selectedPetId != null
                                ? _petList.firstWhere(
                                    (pet) => pet.id == _selectedPetId,
                                    orElse: () => _petList.first,
                                  )
                                : _petList.first;
                            if (selectedPet.locationEnabled) {
                              _checkAndFetchLocation(alwaysReload: true);
                            }
                          } else {
                            // 프레임을 끌 때: 위치정보 초기화
                            if (mounted) {
                              setState(() {
                                _currentLocation = null;
                              });
                            }
                          }
                        },
                        onSelectedPetChanged: (selectedId) {
                          setState(() {
                            _selectedPetId = selectedId;
                          });
                          // 프레임 선택 변경 시: 위치정보가 활성화된 프레임이면 항상 위치정보 갱신
                          final currentPet = selectedId != null
                              ? _petList.firstWhere(
                                  (pet) => pet.id == selectedId,
                                  orElse: () => _petList.first,
                                )
                              : _petList.first;

                          if (currentPet.locationEnabled) {
                            _checkAndFetchLocation(alwaysReload: true);
                          } else {
                            // 위치 정보 활성화가 안 되어 있으면 null로 설정
                            if (mounted) {
                              setState(() {
                                _currentLocation = null;
                              });
                            }
                          }
                        },
                      ),
                    ),
                  );
                },
                icon: Stack(
                  children: [
                    // 그림자 효과
                    Positioned(
                      left: 0.5,
                      top: 0.5,
                      child: Icon(
                        _frameEnabled
                            ? Icons.photo_filter
                            : Icons.photo_filter_outlined,
                        color: Colors.black.withValues(alpha: 0.6),
                        size: iconSize, // 16.0
                      ),
                    ),
                    // 실제 아이콘
                    Icon(
                      _frameEnabled
                          ? Icons.photo_filter
                          : Icons.photo_filter_outlined,
                      color: _frameEnabled ? kMainPink : Colors.white,
                      size: iconSize, // 16.0
                    ),
                  ],
                ),
                tooltip: '프레임 설정',
              ),
            ),
            const SizedBox(width: 4),
            // 후원하기 버튼
            Container(
              width: 36, // 가로 길이 늘림
              height: 32, // 세로 길이 조정 (아이콘 크기 + 패딩)
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: iconSize, // 16.0
                onPressed: () {
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => SettingsPage()));
                },
                icon: Stack(
                  children: [
                    // 그림자 효과
                    Positioned(
                      left: 0.5,
                      top: 0.5,
                      child: Icon(
                        Icons.coffee,
                        color: Colors.black.withValues(alpha: 0.6),
                        size: iconSize, // 16.0
                      ),
                    ),
                    // 실제 아이콘
                    Icon(
                      Icons.coffee,
                      color: Colors.white,
                      size: iconSize,
                    ), // 16.0
                  ],
                ),
                tooltip: '후원하기',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 오른쪽 옵션 패널 (카메라 전환 버튼, 밝기 조절)
  Widget _buildRightOptionsPanel() {
    final previewDims = _calculateCameraPreviewDimensions();
    final double overlayTop = previewDims['overlayTop']!;
    final double overlayBottom = previewDims['overlayBottom']!;

    return Positioned(
      right: 8,
      top: overlayTop > 0 ? overlayTop : 0,
      bottom: overlayBottom > 0 ? overlayBottom : 0,
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 밝기 조절 슬라이더 (세로)
              _buildBrightnessSlider(),
              const SizedBox(height: 12),
              // 카메라 전환 버튼 (전면/후면)
              _buildOptionIconButton(
                icon: _cameraLensDirection == CameraLensDirection.back
                    ? Icons.camera_front
                    : Icons.camera_rear,
                isActive: true,
                onTap: _switchCamera,
                tooltip: _cameraLensDirection == CameraLensDirection.back
                    ? '전면 카메라로 전환'
                    : '후면 카메라로 전환',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 밝기 조절 슬라이더 (필터 강도 조절 슬라이더와 동일한 구조)
  Widget _buildBrightnessSlider() {
    return Container(
      width: 48,
      height: 200,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // 밝기 아이콘
          Icon(
            _brightnessValue > 0
                ? Icons.brightness_high
                : _brightnessValue < 0
                ? Icons.brightness_low
                : Icons.brightness_medium,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(height: 8),
          // 슬라이더 영역 (필터 강도 조절 슬라이더와 동일한 방식 - onPanUpdate 사용)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double sliderHeight = constraints.maxHeight;

                return Listener(
                  onPointerDown: (event) {
                    // 터치 시작 시 값 업데이트
                    final double localY = event.localPosition.dy.clamp(
                      0.0,
                      sliderHeight,
                    );
                    final double normalized = localY / sliderHeight;
                    final double newValue = ((1.0 - normalized) * 100.0 - 50.0)
                        .clamp(-50.0, 50.0);
                    setState(() {
                      _brightnessValue = newValue;
                    });
                    HapticFeedback.selectionClick();
                  },
                  onPointerMove: (event) {
                    if (event.down) {
                      // 드래그 중 값 업데이트
                      final double localY = event.localPosition.dy.clamp(
                        0.0,
                        sliderHeight,
                      );
                      final double normalized = localY / sliderHeight;
                      final double newValue =
                          ((1.0 - normalized) * 100.0 - 50.0).clamp(
                            -50.0,
                            50.0,
                          );
                      setState(() {
                        _brightnessValue = newValue;
                      });
                    }
                  },
                  onPointerUp: (_) {
                    HapticFeedback.selectionClick();
                  },
                  child: Stack(
                    children: [
                      // 배경 트랙
                      Center(
                        child: Container(
                          width: 4,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      // 현재 값 표시 (썸)
                      Align(
                        alignment: Alignment(
                          0,
                          -((_brightnessValue + 50.0) / 100.0 * 2.0 -
                              1.0), // -50~50을 -1.0~1.0으로
                        ),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: kMainPink,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // 밝기 값 표시
          Text(
            _brightnessValue == 0.0
                ? '0'
                : _brightnessValue > 0
                ? '+${_brightnessValue.toInt()}'
                : '${_brightnessValue.toInt()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 왼쪽 옵션 패널 (아이콘만 표시, 배경 없음)
  Widget _buildLeftOptionsPanel() {
    final previewDims = _calculateCameraPreviewDimensions();
    final double overlayTop = previewDims['overlayTop']!;
    final double overlayBottom = previewDims['overlayBottom']!;

    // 1:1 모드에서 프리뷰 영역 안에 모든 요소가 들어오도록
    // 간격을 최소화하고 프리뷰 영역에 맞춤
    final double topPadding = overlayTop > 0 ? overlayTop + 4.0 : 0;
    final double bottomPadding = overlayBottom > 0 ? overlayBottom + 4.0 : 0;

    return Positioned(
      key: ValueKey('left_options_${_selectedZoomRatio}_${_currentZoomLevel}'),
      left: 8,
      top: topPadding,
      bottom: bottomPadding,
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 플래시 토글
              _buildOptionIconButton(
                icon: _flashMode == FlashMode.off
                    ? Icons.flash_off
                    : Icons.flash_on,
                isActive: _flashMode != FlashMode.off,
                onTap: _toggleFlash,
                tooltip: _flashMode == FlashMode.off ? '플래시 켜기' : '플래시 끄기',
              ),
              const SizedBox(height: 4),
              // 격자 토글
              _buildOptionIconButton(
                icon: _showGridLines ? Icons.grid_on : Icons.grid_off,
                isActive: _showGridLines,
                onTap: () {
                  setState(() {
                    _showGridLines = !_showGridLines;
                  });
                  _saveShowGridLines();
                },
                tooltip: _showGridLines ? '격자 끄기' : '격자 켜기',
              ),
              const SizedBox(height: 4),
              // 카메라 배율 선택 (0.8x, 1x, 1.5x 등) - 항상 표시
              _buildOptionIconButton(
                key: ValueKey('zoom_button_$_selectedZoomRatio'),
                icon: Icons.center_focus_strong,
                isActive: _selectedZoomRatio != 1.0,
                label: '${_selectedZoomRatio.toStringAsFixed(1)}x',
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      title: const Text(
                        '카메라 배율',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      content: Builder(
                        builder: (context) {
                          // 카메라 지원에 따라 줌 옵션 동적 생성
                          final List<double> zoomOptions = [];

                          // 최저값 추가 (카메라 최저값이 1.0보다 작으면)
                          if (_minZoomLevel < 1.0) {
                            zoomOptions.add(_minZoomLevel);
                          }

                          // 고정 옵션: 1.0, 2.0, 3.0 (카메라 지원 범위 내에서만)
                          // 단, 카메라가 3배 미만 지원 시 최대값 반영
                          if (_maxZoomLevel >= 1.0) {
                            zoomOptions.add(1.0);
                          }
                          if (_maxZoomLevel >= 2.0) {
                            zoomOptions.add(2.0);
                          }
                          if (_maxZoomLevel >= 3.0) {
                            zoomOptions.add(3.0);
                          } else if (_maxZoomLevel > 2.0 &&
                              _maxZoomLevel < 3.0) {
                            // 카메라가 3배 미만 지원 시 최대값 반영
                            zoomOptions.add(_maxZoomLevel);
                          }

                          // 중복 제거 및 정렬
                          final uniqueOptions = zoomOptions.toSet().toList()
                            ..sort();

                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: uniqueOptions
                                .map((ratio) => _buildZoomRatioOption(ratio))
                                .toList(),
                          );
                        },
                      ),
                    ),
                  );
                },
                tooltip: '카메라 배율: ${_selectedZoomRatio}x',
              ),
              const SizedBox(height: 6),
              // 화면 비율 선택 (활성화 표시 + 비율 표기)
              _buildOptionIconButton(
                icon: Icons.crop_free,
                isActive: true, // 항상 활성화 표시
                label: _aspectLabel(_aspectMode), // 선택된 비율 표기
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      title: const Text(
                        '화면 비율',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            title: const Text('9:16'),
                            trailing: _aspectMode == AspectRatioMode.nineSixteen
                                ? Icon(Icons.check_circle, color: kMainPink)
                                : const Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey,
                                  ),
                            onTap: () {
                              _changeAspectMode(AspectRatioMode.nineSixteen);
                              Navigator.of(context).pop();
                            },
                          ),
                          ListTile(
                            title: const Text('3:4'),
                            trailing: _aspectMode == AspectRatioMode.threeFour
                                ? Icon(Icons.check_circle, color: kMainPink)
                                : const Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey,
                                  ),
                            onTap: () {
                              _changeAspectMode(AspectRatioMode.threeFour);
                              Navigator.of(context).pop();
                            },
                          ),
                          ListTile(
                            title: const Text('1:1'),
                            trailing: _aspectMode == AspectRatioMode.oneOne
                                ? Icon(Icons.check_circle, color: kMainPink)
                                : const Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey,
                                  ),
                            onTap: () {
                              _changeAspectMode(AspectRatioMode.oneOne);
                              Navigator.of(context).pop();
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
                tooltip: '화면 비율: ${_aspectLabel(_aspectMode)}',
              ),
              const SizedBox(height: 4),
              // 연속 촬영
              _buildOptionIconButton(
                icon: Icons.camera_roll,
                isActive: _isBurstMode,
                label: _isBurstMode ? '${_burstCountSetting}' : null,
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      title: const Text(
                        '연속 촬영 매수',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildBurstCountOption(3),
                          _buildBurstCountOption(5),
                          _buildBurstCountOption(10),
                          ListTile(
                            title: const Text('연속 촬영 끄기'),
                            trailing: !_isBurstMode
                                ? Icon(Icons.check_circle, color: kMainPink)
                                : const Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey,
                                  ),
                            onTap: () {
                              setState(() {
                                _isBurstMode = false;
                              });
                              _saveBurstSettings();
                              Navigator.of(context).pop();
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
                tooltip: _isBurstMode
                    ? '연속 촬영: ${_burstCountSetting}장'
                    : '연속 촬영',
              ),
              const SizedBox(height: 4),
              // 타이머
              _buildOptionIconButton(
                icon: Icons.timer,
                isActive: _timerSeconds > 0,
                label: _timerSeconds > 0 ? '${_timerSeconds}' : null,
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      title: const Text(
                        '타이머 선택',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildTimerOption(3),
                          _buildTimerOption(5),
                          _buildTimerOption(10),
                          ListTile(
                            title: const Text('타이머 끄기'),
                            trailing: _timerSeconds == 0
                                ? Icon(Icons.check_circle, color: kMainPink)
                                : const Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey,
                                  ),
                            onTap: () {
                              setState(() {
                                _timerSeconds = 0;
                              });
                              _saveTimerSettings();
                              Navigator.of(context).pop();
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
                tooltip: _timerSeconds > 0 ? '타이머: ${_timerSeconds}초' : '타이머',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 아이콘만 표시하는 옵션 버튼 (배경 없음)
  Widget _buildOptionIconButton({
    Key? key,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    String? label,
    String? tooltip,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            key: key,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: 44,
            height: label != null ? 56 : 44,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      icon,
                      key: ValueKey(icon),
                      size: 24,
                      color: isActive ? kMainPink : Colors.white70,
                    ),
                  ),
                ),
                if (label != null) ...[
                  const SizedBox(height: 2),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        label,
                        key: ValueKey(label), // label 변경 시 애니메이션
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: isActive ? kMainPink : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 촬영용 필터 선택 패널 (펼쳐질 때만 표시)
  Widget _buildFilterSelectionPanel() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 필터 패널 영역의 터치를 소비하여 바깥 오버레이가 닫히지 않도록 함
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFilterStrip(),
              const SizedBox(height: 8),
              _buildLiveIntensityControls(),
            ],
          ),
        ),
      ),
    );
  }

  /// 촬영용 필터 목록
  Widget _buildFilterStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 필터 선택 타이틀과 아코디언 아이콘
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '필터 선택',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  _filterPanelExpanded = false;
                });
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 20,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 60,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: kFilterOrder.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final key = kFilterOrder[index];
              final PetFilter f = _allFilters[key]!;
              final bool selected = f.key == _shootFilterKey;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    _shootFilterKey = f.key;
                  });
                  _saveSelectedFilter(f.key);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 65,
                  height: 60,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    gradient: selected
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              kMainPink,
                              kMainPink.withValues(alpha: 0.8),
                            ],
                          )
                        : null,
                    color: selected
                        ? null
                        : Colors.black.withValues(
                            alpha: 0.4,
                          ), // 상단 후원하기 아이콘과 동일
                    borderRadius: BorderRadius.circular(18), // 상단 후원하기 아이콘과 동일
                    border: Border.all(
                      color: selected
                          ? Colors.transparent
                          : Colors.white.withValues(
                              alpha: 0.3,
                            ), // 상단 후원하기 아이콘과 동일
                      width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: kMainPink.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null, // 선택되지 않은 경우 boxShadow 제거
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        f.icon,
                        size: 18,
                        color: selected
                            ? Colors.white
                            : Colors.white, // 아이콘 색상 흰색으로 통일
                      ),
                      const SizedBox(height: 4),
                      Flexible(
                        child: Text(
                          f.label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: selected
                                ? Colors.white
                                : Colors.white, // 텍스트 색상 흰색으로 통일
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 라이브 필터 강도 / 털색 프리셋
  Widget _buildLiveIntensityControls() {
    final bool isBasic = _shootFilterKey == 'basic_none';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '강도 조절',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: isBasic ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: isBasic,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildLiveCoatChip('밝은 털', 'light', 0.6),
                _buildLiveCoatChip('보통 털', 'mid', 0.8),
                _buildLiveCoatChip('진한 털', 'dark', 1.0),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: isBasic ? 0.4 : 1.0,
          child: IgnorePointer(
            ignoring: isBasic,
            child: Slider(
              min: 0.4,
              max: 1.2,
              value: _liveIntensity,
              activeColor: kMainPink,
              onChanged: (v) {
                setState(() {
                  _liveIntensity = v;
                  _liveCoatPreset = 'custom';
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveCoatChip(String label, String key, double presetValue) {
    final selected = _liveCoatPreset == key;
    return GestureDetector(
      onTap: () {
        setState(() {
          _liveCoatPreset = key;
          _liveIntensity = presetValue;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                )
              : null,
          color: selected
              ? null
              : Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
          borderRadius: BorderRadius.circular(18), // 상단 후원하기 아이콘과 동일
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
            width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일
          ),
          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.white, // 텍스트 색상 흰색으로 통일
          ),
        ),
      ),
    );
  }

  Future<void> _onCapturePressed() async {
    if (_isProcessing) return;

    // 촬영 버튼 클릭 피드백
    HapticFeedback.lightImpact();

    // 참고: 실제 카메라 촬영 사운드는 시스템에서 자동으로 재생됩니다.
    // 추가 사운드 재생은 불필요하므로 제거했습니다.

    setState(() {
      _isCaptureAnimating = true;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 120));

      if (!mounted) return;

      setState(() {
        _isCaptureAnimating = false;
      });

      await _takePhoto();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isCaptureAnimating = false;
      });
    }
  }

  /// 하단: 보정(갤러리) - 촬영 버튼 - 강아지/고양이 사운드 버튼
  Widget _buildBottomBar() {
    // 9:16을 기준으로 전체 UI 크기 통일
    final double buttonSize = 36.0;
    final double captureButtonSize = 64.0;
    final double horizontalPadding = 12.0;
    final double verticalPadding = 6.0;
    // 하단 바 위치는 맨 아래에서 더 아래로 이동
    final double bottomOffset = 0.0; // 하단에 바로 배치

    // 하단 바 위치는 맨 아래에 고정
    return Positioned(
      bottom: bottomOffset,
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: const Offset(0, -12), // 살짝만 더 위로 이동 (-8 -> -12)
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            // 배경 완전히 제거 - 투명하게
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 왼쪽 버튼들
                Positioned(
                  left: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 필터 페이지로 이동하는 버튼
                      GestureDetector(
                        onTap: () async {
                          if (_isProcessing) return;
                          setState(() => _isProcessing = true);
                          try {
                            final picked = await _picker.pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 90,
                            );
                            if (!mounted || picked == null) {
                              setState(() => _isProcessing = false);
                              return;
                            }
                            final file = File(picked.path);
                            await _openFilterPage(file);
                          } finally {
                            if (mounted) {
                              setState(() => _isProcessing = false);
                            }
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          width: buttonSize,
                          height: buttonSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(
                              alpha: 0.4,
                            ), // 상단 후원하기 아이콘과 동일
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: 0.3,
                              ), // 상단 후원하기 아이콘과 동일
                              width: 1, // 상단 후원하기 아이콘과 동일
                            ),
                            // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
                          ),
                          child: Icon(
                            Icons.photo_library_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 촬영용 필터 선택 버튼
                      Flexible(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _filterPanelExpanded = !_filterPanelExpanded;
                            });
                          },
                          child: Builder(
                            builder: (context) {
                              final bool isFilterActive =
                                  _shootFilterKey != 'basic_none';
                              final bool isExpanded = _filterPanelExpanded;
                              final bool shouldShowPink =
                                  isFilterActive || isExpanded;

                              return FittedBox(
                                fit: BoxFit.scaleDown,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: shouldShowPink
                                        ? LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [
                                              kMainPink,
                                              kMainPink.withValues(alpha: 0.8),
                                            ],
                                          )
                                        : null,
                                    color: shouldShowPink
                                        ? null
                                        : Colors.black.withValues(
                                            alpha: 0.4,
                                          ), // 상단 후원하기 아이콘과 동일
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: shouldShowPink
                                          ? Colors.transparent
                                          : Colors.white.withValues(
                                              alpha: 0.3,
                                            ), // 상단 후원하기 아이콘과 동일
                                      width: shouldShowPink
                                          ? 0
                                          : 1, // 상단 후원하기 아이콘과 동일 (1.5 -> 1)
                                    ),
                                    // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        child: Icon(
                                          _allFilters[_shootFilterKey]!.icon,
                                          key: ValueKey(_shootFilterKey),
                                          size: 14,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      Flexible(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          child: Text(
                                            _allFilters[_shootFilterKey]!.label,
                                            key: ValueKey(_shootFilterKey),
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 중앙 촬영 버튼 (항상 화면 가로 중앙)
                Center(
                  child: Semantics(
                    label: '사진 촬영',
                    button: true,
                    child: GestureDetector(
                      onTap: _isProcessing ? null : _onCapturePressed,
                      child: AnimatedScale(
                        scale: _isCaptureAnimating ? 0.9 : 1.0,
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        child: Container(
                          width: captureButtonSize,
                          height: captureButtonSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kMainPink,
                            boxShadow: [
                              BoxShadow(
                                color: kMainPink.withValues(alpha: 0.4),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: captureButtonSize * 0.4,
                              height: captureButtonSize * 0.4,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 오른쪽 사운드 버튼들
                Positioned(
                  right: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSoundPill('멍', _playDogSound),
                      const SizedBox(width: 8),
                      _buildSoundPill('냥', _playCatSound),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimerOption(int seconds) {
    return ListTile(
      title: Text('${seconds}초'),
      trailing: _timerSeconds == seconds
          ? Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        setState(() {
          _timerSeconds = seconds;
        });
        _saveTimerSettings();
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildBurstCountOption(int count) {
    return ListTile(
      title: Text('${count}장'),
      trailing: _burstCountSetting == count && _isBurstMode
          ? Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () {
        setState(() {
          _burstCountSetting = count;
          _isBurstMode = true;
        });
        _saveBurstSettings();
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildZoomRatioOption(double ratio) {
    return ListTile(
      title: Text('${ratio.toStringAsFixed(1)}x'),
      trailing:
          (_selectedZoomRatio - ratio).abs() <
              0.05 // 부동소수점 오차 고려
          ? Icon(Icons.check_circle, color: kMainPink)
          : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      onTap: () async {
        if (_cameraController != null &&
            _cameraController!.value.isInitialized) {
          try {
            final minZoom = await _cameraController!.getMinZoomLevel();
            final maxZoom = await _cameraController!.getMaxZoomLevel();
            final newZoom = ratio.clamp(minZoom, maxZoom);

            debugPrint(
              '[Petgram] 🔍 배율 선택: ratio=$ratio, newZoom=$newZoom (min=$minZoom, max=$maxZoom)',
            );

            // 카메라 줌 레벨 설정
            await _cameraController!.setZoomLevel(newZoom);

            // 모든 줌 관련 변수 업데이트
            if (mounted) {
              setState(() {
                _currentZoomLevel = newZoom;
                _baseZoomLevel = newZoom; // 핀치 줌 기준값도 업데이트
                _selectedZoomRatio = newZoom; // 실제 설정된 값으로 업데이트
              });
              debugPrint(
                '[Petgram] ✅ 배율 설정 완료: _currentZoomLevel=$_currentZoomLevel, _baseZoomLevel=$_baseZoomLevel, _selectedZoomRatio=$_selectedZoomRatio',
              );
            }
          } catch (e) {
            debugPrint('❌ setZoomLevel error: $e');
          }
        } else {
          // 목업 모드 또는 카메라가 초기화되지 않은 경우 UI만 업데이트
          debugPrint(
            '[Petgram] 🔍 목업 모드: 배율 선택 ratio=$ratio, _useMockCamera=$_useMockCamera',
          );
          if (mounted) {
            setState(() {
              _currentZoomLevel = ratio;
              _baseZoomLevel = ratio; // 핀치 줌 기준값도 업데이트
              _selectedZoomRatio = ratio;
              // 목업 모드에서는 UI 줌 스케일도 업데이트 (핀치 줌과 동일하게)
              _uiZoomScale = ratio.clamp(1.0, 5.0);
              _baseZoomScale = ratio.clamp(1.0, 5.0);
            });
            debugPrint(
              '[Petgram] ✅ 목업 모드 배율 설정 완료: _currentZoomLevel=$_currentZoomLevel, _uiZoomScale=$_uiZoomScale, _selectedZoomRatio=$_selectedZoomRatio',
            );
          }
        }
        if (mounted) {
          Navigator.of(context).pop();
        }
      },
    );
  }

  Widget _buildSoundPill(String label, VoidCallback onTap) {
    final bool isDog = label == '멍';
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
            width: 1, // 상단 후원하기 아이콘과 동일
          ),
          // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
        ),
        child: Center(
          child: Image.asset(
            isDog ? 'assets/icons/dog.png' : 'assets/icons/cat.png',
            width: 28,
            height: 28,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

/// ========================
///  설정 화면
/// ========================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  bool _isAvailable = false;
  List<ProductDetails> _products = [];
  bool _isLoading = false;
  String? _errorMessage;

  StreamSubscription<List<PurchaseDetails>>? _subscription;

  @override
  void initState() {
    super.initState();
    _initializePurchase();
    _listenToPurchaseUpdates();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _listenToPurchaseUpdates() {
    _subscription = _inAppPurchase.purchaseStream.listen(
      (List<PurchaseDetails> purchaseDetailsList) {
        _handlePurchaseUpdates(purchaseDetailsList);
      },
      onDone: () {
        _subscription?.cancel();
      },
      onError: (error) {
        setState(() {
          _isLoading = false;
          _errorMessage = '결제 처리 중 오류가 발생했습니다.';
        });
      },
    );
  }

  void _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) {
    for (final purchaseDetails in purchaseDetailsList) {
      if (purchaseDetails.status == PurchaseStatus.pending) {
        // 결제 대기 중
      } else if (purchaseDetails.status == PurchaseStatus.purchased ||
          purchaseDetails.status == PurchaseStatus.restored) {
        // 결제 완료
        _verifyPurchase(purchaseDetails);
      } else if (purchaseDetails.status == PurchaseStatus.error) {
        setState(() {
          _isLoading = false;
          _errorMessage = '결제 중 오류가 발생했습니다.';
        });
      }
      if (purchaseDetails.pendingCompletePurchase) {
        _inAppPurchase.completePurchase(purchaseDetails);
      }
    }
  }

  void _verifyPurchase(PurchaseDetails purchaseDetails) {
    setState(() {
      _isLoading = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('후원해주셔서 감사합니다! 💕'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _initializePurchase() async {
    _isAvailable = await _inAppPurchase.isAvailable();
    if (!_isAvailable) {
      setState(() {
        _errorMessage = '인앱 결제를 사용할 수 없습니다.\n인터넷 연결을 확인해주세요.';
      });
      return;
    }

    // 상품 ID 목록 (Google Play Console / App Store Connect에서 설정한 ID)
    const Set<String> productIds = {'donation_1000'};

    final ProductDetailsResponse response = await _inAppPurchase
        .queryProductDetails(productIds);

    if (response.error != null) {
      debugPrint('인앱 결제 에러: ${response.error}');
      setState(() {
        _errorMessage = '상품 정보를 불러오는 중 오류가 발생했습니다.\n${response.error!.message}';
      });
      return;
    }

    // 찾지 못한 상품 ID 확인
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint('찾지 못한 상품 ID: ${response.notFoundIDs}');
      setState(() {
        _errorMessage =
            '상품이 등록되지 않았습니다.\nGoogle Play Console / App Store Connect에서\n상품 ID "donation_1000"을 등록해주세요.';
      });
      return;
    }

    if (response.productDetails.isEmpty) {
      setState(() {
        _errorMessage = '상품 정보를 불러올 수 없습니다.\n잠시 후 다시 시도해주세요.';
      });
      return;
    }

    setState(() {
      _products = response.productDetails;
      _errorMessage = null;
    });
  }

  Future<void> _buyProduct(ProductDetails productDetails) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final PurchaseParam purchaseParam = PurchaseParam(
      productDetails: productDetails,
    );

    try {
      final bool success = await _inAppPurchase.buyNonConsumable(
        purchaseParam: purchaseParam,
      );

      if (!success) {
        setState(() {
          _isLoading = false;
          _errorMessage = '결제를 시작할 수 없습니다.';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '결제 중 오류가 발생했습니다: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      appBar: AppBar(
        title: const Text('후원하기'),
        backgroundColor: const Color(0xFFFFF5F8),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 후원하기 섹션
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 아이콘
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: kMainPink.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.coffee, color: kMainPink, size: 48),
                ),
                const SizedBox(height: 20),
                const Text(
                  '후원하기',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '이 앱이 마음에 드셨나요?\n개발자를 응원해주세요!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.grey,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(fontSize: 12, color: Colors.red[600]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_products.isEmpty && !_isLoading && _errorMessage == null)
                  const Text(
                    '상품 정보를 불러오는 중...',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  )
                else if (_isLoading)
                  const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(kMainPink),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _products.isNotEmpty
                          ? () => _buyProduct(_products.first)
                          : null,
                      icon: const Icon(Icons.coffee, size: 22),
                      label: const Text(
                        '천원 후원하기',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kMainPink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                if (_products.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '₩1,000',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ========================
///  프레임 설정 화면
/// ========================

class FrameSettingsPage extends StatefulWidget {
  final List<PetInfo> petList;
  final Function(List<PetInfo>, String?) onPetListChanged;
  final bool frameEnabled;
  final Function(bool) onFrameEnabledChanged;
  final String? selectedPetId;
  final Function(String?) onSelectedPetChanged;

  const FrameSettingsPage({
    super.key,
    required this.petList,
    required this.onPetListChanged,
    required this.frameEnabled,
    required this.onFrameEnabledChanged,
    required this.selectedPetId,
    required this.onSelectedPetChanged,
  });

  @override
  State<FrameSettingsPage> createState() => _FrameSettingsPageState();
}

class _FrameSettingsPageState extends State<FrameSettingsPage> {
  late List<PetInfo> _petList;
  late bool _frameEnabled;
  String? _selectedPetId;

  @override
  void initState() {
    super.initState();
    _petList = List.from(widget.petList);
    _frameEnabled = widget.frameEnabled;
    _selectedPetId = widget.selectedPetId;
  }

  Future<void> _savePetList() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _petList.map((pet) => jsonEncode(pet.toJson())).toList();
    await prefs.setStringList(kPetListKey, jsonList);
    // 선택된 반려동물 ID 저장
    if (_selectedPetId != null) {
      await prefs.setString(kSelectedPetIdKey, _selectedPetId!);
    }
    widget.onPetListChanged(_petList, _selectedPetId);
  }

  Future<void> _saveSelectedPetId() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedPetId != null) {
      await prefs.setString(kSelectedPetIdKey, _selectedPetId!);
    }
    widget.onSelectedPetChanged(_selectedPetId);
  }

  void _addPet() {
    _showPetEditDialog(null);
  }

  void _editPet(PetInfo pet) {
    _showPetEditDialog(pet);
  }

  void _deletePet(PetInfo pet) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '정말 삭제하시겠습니까?',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '삭제 시, 복구할 수 없습니다.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              final index = _petList.indexWhere((p) => p.id == pet.id);
              if (index != -1) {
                setState(() {
                  _petList.removeAt(index);
                  if (_selectedPetId == pet.id) {
                    _selectedPetId = _petList.isNotEmpty
                        ? _petList.first.id
                        : null;
                  }
                });
                _savePetList();
                Navigator.of(context).pop();
              }
            },
            child: const Text(
              '삭제',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showPetEditDialog(PetInfo? pet) {
    final nameController = TextEditingController(text: pet?.name ?? '');
    final breedController = TextEditingController(text: pet?.breed ?? '');
    String selectedType = pet?.type ?? 'dog';
    String? selectedGender =
        pet?.gender ?? 'male'; // 'male' or 'female' (기본값: male)
    DateTime? selectedDate = pet?.birthDate;
    int framePattern = pet?.framePattern ?? 1;
    bool locationEnabled = pet?.locationEnabled ?? false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 600),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 헤더
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: kMainPink.withValues(alpha: 0.1),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kMainPink.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            pet == null
                                ? Icons.add_circle_outline
                                : Icons.edit_outlined,
                            color: kMainPink,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            pet == null ? '반려동물 추가' : '반려동물 수정',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          color: Colors.grey[600],
                          onPressed: () => Navigator.of(context).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  // 내용
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 반려동물 종류
                          const Text(
                            '반려동물 종류',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('강아지'),
                                selected: selectedType == 'dog',
                                onSelected: (selected) {
                                  setDialogState(() {
                                    selectedType = 'dog';
                                  });
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedType == 'dog'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('고양이'),
                                selected: selectedType == 'cat',
                                onSelected: (selected) {
                                  setDialogState(() {
                                    selectedType = 'cat';
                                  });
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedType == 'cat'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // 이름 입력
                          const Text(
                            '이름',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: nameController,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: kMainPink,
                                  width: 2,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            maxLength: 9,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 20),
                          // 생년월일 선택
                          const Text(
                            '생년월일',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () {
                              dtp.DatePicker.showDatePicker(
                                context,
                                showTitleActions: true,
                                minTime: DateTime(2000, 1, 1),
                                maxTime: DateTime.now(),
                                onChanged: (date) {},
                                onConfirm: (date) {
                                  setDialogState(() {
                                    selectedDate = date;
                                  });
                                },
                                currentTime: selectedDate ?? DateTime.now(),
                                locale: dtp.LocaleType.ko,
                                theme: dtp.DatePickerTheme(
                                  itemStyle: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                  doneStyle: TextStyle(
                                    color: kMainPink,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  cancelStyle: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 16,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey[300]!),
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.white,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.calendar_today,
                                    color: kMainPink,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      selectedDate != null
                                          ? '${selectedDate!.year}.${selectedDate!.month.toString().padLeft(2, '0')}.${selectedDate!.day.toString().padLeft(2, '0')}'
                                          : '생년월일을 선택해주세요',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: selectedDate != null
                                            ? Colors.black87
                                            : Colors.grey[400],
                                        fontWeight: selectedDate != null
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    size: 16,
                                    color: Colors.grey[400],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          // 성별 선택
                          const Text(
                            '성별',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('Male'),
                                selected: selectedGender == 'male',
                                onSelected: (selected) {
                                  if (selected) {
                                    setDialogState(() {
                                      selectedGender = 'male';
                                    });
                                  }
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedGender == 'male'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('Female'),
                                selected: selectedGender == 'female',
                                onSelected: (selected) {
                                  if (selected) {
                                    setDialogState(() {
                                      selectedGender = 'female';
                                    });
                                  }
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedGender == 'female'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // 종 입력
                          const Text(
                            '품종',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: breedController,
                            decoration: InputDecoration(
                              hintText: '예: 골든 리트리버, 페르시안 등',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: kMainPink,
                                  width: 2,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            maxLength: 12,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 20),
                          // 위치 정보 활성화 옵션
                          const Text(
                            '촬영 위치 정보 표시',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  '사진 촬영 위치를 추가하여 표기하기 위해 위치정보를 사용합니다.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Switch(
                                value: locationEnabled,
                                onChanged: (value) {
                                  setDialogState(() {
                                    locationEnabled = value;
                                  });
                                },
                                activeThumbColor: kMainPink,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 하단 버튼
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: Colors.grey[200]!)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: BorderSide(color: Colors.grey[300]!),
                            ),
                            child: const Text(
                              '취소',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: () async {
                              final name = nameController.text.trim();
                              final breed = breedController.text.trim();
                              if (name.isEmpty ||
                                  selectedDate == null ||
                                  selectedGender == null ||
                                  breed.isEmpty) {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    title: const Text(
                                      '입력 오류',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    content: const Text(
                                      '모든 정보를 입력해주세요',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        child: const Text(
                                          '확인',
                                          style: TextStyle(color: kMainPink),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                return;
                              }
                              if (pet == null) {
                                // 추가
                                final newPet = PetInfo(
                                  id: DateTime.now().millisecondsSinceEpoch
                                      .toString(),
                                  name: name,
                                  type: selectedType,
                                  birthDate: selectedDate!,
                                  framePattern: framePattern,
                                  gender: selectedGender!,
                                  breed: breed,
                                  locationEnabled: locationEnabled,
                                );
                                setState(() {
                                  _petList.add(newPet);
                                  if (_selectedPetId == null) {
                                    _selectedPetId = newPet.id;
                                  }
                                });
                              } else {
                                // 수정
                                final index = _petList.indexWhere(
                                  (p) => p.id == pet.id,
                                );
                                if (index != -1) {
                                  setState(() {
                                    _petList[index] = PetInfo(
                                      id: pet.id,
                                      name: name,
                                      type: selectedType,
                                      birthDate: selectedDate!,
                                      framePattern: framePattern,
                                      gender: selectedGender!,
                                      breed: breed,
                                      locationEnabled: locationEnabled,
                                    );
                                  });
                                }
                              }
                              await _savePetList();
                              if (mounted) {
                                Navigator.of(context).pop();
                                setState(() {});
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kMainPink,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: Text(
                              pet == null ? '추가하기' : '저장하기',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      appBar: AppBar(
        title: const Text('프레임 설정'),
        backgroundColor: const Color(0xFFFFF5F8),
        elevation: 0,
      ),
      body: _petList.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.photo_filter_outlined,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '등록된 반려동물이 없습니다',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '반려동물을 먼저 등록해주세요',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _addPet(),
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('반려동물 추가'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kMainPink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              children: [
                // 프레임 활성화 (간소화)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _frameEnabled
                              ? Icons.photo_filter
                              : Icons.photo_filter_outlined,
                          color: _frameEnabled ? kMainPink : Colors.grey[400],
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '프레임 활성화',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _frameEnabled
                                ? Colors.black87
                                : Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                    Switch(
                      value: _frameEnabled,
                      onChanged: _petList.isEmpty
                          ? null
                          : (value) {
                              setState(() {
                                _frameEnabled = value;
                              });
                              widget.onFrameEnabledChanged(value);
                            },
                      activeThumbColor: kMainPink,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 안내 문구 (간소화)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '반려동물을 탭하여 프레임을 적용할 반려동물을 선택하세요',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                ),
                // 반려동물별 프레임 설정
                ..._petList.map((pet) {
                  final isSelected = _selectedPetId == pet.id;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? kMainPink : Colors.grey[200]!,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          setState(() {
                            _selectedPetId = pet.id;
                          });
                          _saveSelectedPetId();
                          // 프레임 선택이 바뀌면 위치정보를 다시 불러오기
                          widget.onSelectedPetChanged(pet.id);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              // 아이콘
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? kMainPink.withValues(alpha: 0.15)
                                      : Colors.grey[100],
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  pet.type == 'dog'
                                      ? Icons.pets
                                      : Icons.favorite_rounded,
                                  color: isSelected
                                      ? kMainPink
                                      : Colors.grey[600],
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              // 이름과 정보
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          pet.name,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: isSelected
                                                ? Colors.black87
                                                : Colors.black,
                                          ),
                                        ),
                                        if (isSelected) ...[
                                          const SizedBox(width: 6),
                                          Icon(
                                            Icons.check_circle,
                                            color: kMainPink,
                                            size: 18,
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (pet.locationEnabled) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const SizedBox(width: 8),
                                          Icon(
                                            Icons.location_on,
                                            size: 14,
                                            color: Colors.grey[600],
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            '위치정보',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              // 편집/삭제 버튼
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                color: Colors.blue[400],
                                onPressed: () => _editPet(pet),
                                tooltip: '수정',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                color: Colors.red[400],
                                onPressed: () => _deletePet(pet),
                                tooltip: '삭제',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
                const SizedBox(height: 20),
                // 반려동물 추가 버튼
                OutlinedButton.icon(
                  onPressed: () => _addPet(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text(
                    '반려동물 추가',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kMainPink,
                    side: BorderSide(color: kMainPink, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}

/// ========================
///  필터 편집 / 저장 화면
/// ========================

class FilterPage extends StatefulWidget {
  final File imageFile;
  final String initialFilterKey;

  const FilterPage({
    super.key,
    required this.imageFile,
    required this.initialFilterKey,
  });

  @override
  State<FilterPage> createState() => _FilterPageState();
}

class _FilterPageState extends State<FilterPage> {
  late String _category;
  late String _filterKey;
  late File _currentImageFile;
  // initialFilterKey는 UI용 메타 정보로만 사용 (촬영 시 적용된 필터 정보)
  // 실제 필터 적용은 _filterKey로 제어하며, 항상 _currentImageFile만 사용

  final GlobalKey _previewKey = GlobalKey();
  final ImagePicker _picker = ImagePicker();
  bool _isSaving = false;
  bool _isPickingImage = false;

  double _intensity = 0.8;
  String _coatPreset = 'mid'; // light / mid / dark / custom

  // 핀치줌 관련 변수
  double _baseScale = 1.0;
  double _currentScale = 1.0;
  Offset _offset = Offset.zero;
  Offset _lastFocalPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    // 촬영 시 입혀진 필터가 원본이므로, 초기 필터 키를 'basic_none'으로 설정
    // 이미지 파일 자체가 이미 필터가 적용된 상태이므로, 원본 필터를 기본으로 설정
    _filterKey = 'basic_none';
    _category = 'basic';
    _currentImageFile = widget.imageFile;
    // widget.initialFilterKey는 UI용 메타 정보 (현재는 사용하지 않음)
  }

  Future<void> _pickNewImage() async {
    if (_isPickingImage) return;
    setState(() => _isPickingImage = true);

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );

      if (!mounted || picked == null) {
        setState(() => _isPickingImage = false);
        return;
      }

      setState(() {
        _currentImageFile = File(picked.path);
        _filterKey = 'basic_none'; // 새 이미지 선택 시 필터 초기화
        _isPickingImage = false;
        // 새 이미지 선택 시 핀치줌 리셋
        _currentScale = 1.0;
        _baseScale = 1.0;
        _offset = Offset.zero;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isPickingImage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('이미지를 불러오는 중 오류가 발생했어요.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback =
        _filtersByCategory['basic'] ?? <PetFilter>[_allFilters['basic_none']!];
    final filters = _filtersByCategory[_category] ?? fallback;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFFFFF5F8),
        title: const Text(
          '필터 적용',
          style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black87),
        ),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            icon: _isPickingImage
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black87,
                    ),
                  )
                : const Icon(Icons.photo_library_rounded),
            onPressed: _isPickingImage ? null : _pickNewImage,
            tooltip: '새 사진 선택',
          ),
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: const Color(0xFFFFF5F8),
      body: SafeArea(
        child: Stack(
          children: [
            // 스크롤 가능한 전체 콘텐츠
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  // 미리보기 영역 (가로 100%, 세로는 제한)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final availableWidth = constraints.maxWidth;
                        // 가로 세로 100% 표시를 위해 높이 제한 제거
                        return Container(
                          width: availableWidth,
                          constraints: BoxConstraints(minWidth: availableWidth),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: RepaintBoundary(
                              key: _previewKey,
                              child: _buildFilteredImageContent(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 필터 컨트롤 영역 (카드 스타일)
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(28),
                        topRight: Radius.circular(28),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 20,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 10),
                        // 카테고리 탭
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: _buildCategoryTabs(),
                        ),
                        const SizedBox(height: 8),
                        // 필터 버튼들
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: _buildFilterButtons(filters),
                        ),
                        const SizedBox(height: 8),
                        // 강도 조절
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: _buildIntensityControls(),
                        ),
                        const SizedBox(height: 100), // 저장 버튼 공간 확보
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 고정된 저장 버튼 (하단에 고정)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 10,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _onSavePressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kMainPink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Text(
                              '이 사진으로 저장하기',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ColorMatrix를 실제 이미지 픽셀에 적용
  img.Image _applyColorMatrixToImage(img.Image image, List<double> matrix) {
    final result = img.copyResize(
      image,
      width: image.width,
      height: image.height,
    );

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = result.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        final a = pixel.a.toDouble();

        // ColorMatrix 적용
        final newR =
            (matrix[0] * r +
                    matrix[1] * g +
                    matrix[2] * b +
                    matrix[3] * a +
                    matrix[4])
                .clamp(0, 255)
                .toInt();
        final newG =
            (matrix[5] * r +
                    matrix[6] * g +
                    matrix[7] * b +
                    matrix[8] * a +
                    matrix[9])
                .clamp(0, 255)
                .toInt();
        final newB =
            (matrix[10] * r +
                    matrix[11] * g +
                    matrix[12] * b +
                    matrix[13] * a +
                    matrix[14])
                .clamp(0, 255)
                .toInt();
        final newA =
            (matrix[15] * r +
                    matrix[16] * g +
                    matrix[17] * b +
                    matrix[18] * a +
                    matrix[19])
                .clamp(0, 255)
                .toInt();

        result.setPixel(x, y, img.ColorRgba8(newR, newG, newB, newA));
      }
    }

    return result;
  }

  /// 미리보기 영역: 선택된 필터 + 강도 + 자동 보정 적용
  Widget _buildFilteredImageContent() {
    final PetFilter base =
        _allFilters[_filterKey] ?? _allFilters['basic_none']!;

    // 항상 _currentImageFile만 사용 (촬영 시 입혀진 필터가 이미 적용된 상태)
    // 원본 필터(basic_none) 선택 시: 촬영 시 입혀진 필터 상태 그대로 표시 (추가 ColorFiltered 없음)
    // 다른 필터 선택 시: 촬영 시 입혀진 필터 위에 새로운 필터를 합성하여 적용

    final bool isOriginalFilter = base.key == 'basic_none';
    List<double>? matrix;
    if (!isOriginalFilter) {
      // 다른 필터 선택 시: 새로운 필터 매트릭스를 촬영 시 입혀진 필터 위에 합성
      matrix = mixMatrix(kIdentityMatrix, base.matrix, _intensity);
    }

    final imageWidget = Image.file(
      _currentImageFile,
      fit: BoxFit.contain, // 100% 표시를 위해 contain 사용
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: double.infinity,
          color: Colors.grey[200],
          child: const Center(
            child: Icon(Icons.error_outline, size: 48, color: Colors.grey),
          ),
        );
      },
    );

    final filteredWidget = isOriginalFilter
        ? imageWidget // 원본 필터: 촬영 시 입혀진 필터 상태 그대로 (추가 ColorFiltered 없음)
        : ColorFiltered(
            colorFilter: ColorFilter.matrix(matrix!),
            child: imageWidget, // 다른 필터: 촬영 시 입혀진 필터 위에 새로운 필터 합성
          );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Colors.black,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: GestureDetector(
          onScaleStart: (details) {
            _baseScale = _currentScale;
            _lastFocalPoint = details.focalPoint;
          },
          onScaleUpdate: (details) {
            setState(() {
              _currentScale = (_baseScale * details.scale).clamp(1.0, 5.0);
              _offset = details.focalPoint - _lastFocalPoint;
            });
          },
          onScaleEnd: (details) {
            setState(() {
              // 스케일이 1.0에 가까우면 리셋
              if (_currentScale < 1.1) {
                _currentScale = 1.0;
                _offset = Offset.zero;
              }
              _baseScale = _currentScale;
            });
          },
          onDoubleTap: () {
            setState(() {
              _currentScale = 1.0;
              _baseScale = 1.0;
              _offset = Offset.zero;
            });
          },
          child: Transform.scale(
            scale: _currentScale,
            child: Transform.translate(offset: _offset, child: filteredWidget),
          ),
        ),
      ),
    );
  }

  /// 카테고리 탭 (기본 / Pink / Dog / Cat)
  Widget _buildCategoryTabs() {
    final tabs = <_FilterCategoryTab>[
      const _FilterCategoryTab(keyValue: 'basic', label: '기본'),
      const _FilterCategoryTab(keyValue: 'pink', label: 'Pink'),
      const _FilterCategoryTab(keyValue: 'dog', label: 'Dog'),
      const _FilterCategoryTab(keyValue: 'cat', label: 'Cat'),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: tabs.map((t) {
          final bool selected = _category == t.keyValue;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _category = t.keyValue;
                  // 카테고리 변경 시 현재 선택된 필터가 새 카테고리에 없으면 첫 번째 필터로 변경
                  final list = _filtersByCategory[_category];
                  if (list != null && list.isNotEmpty) {
                    // 현재 선택된 필터가 새 카테고리에 있는지 확인
                    final hasCurrentFilter = list.any(
                      (f) => f.key == _filterKey,
                    );
                    if (!hasCurrentFilter) {
                      _filterKey = list.first.key;
                    }
                    // 현재 필터가 새 카테고리에 있으면 그대로 유지
                  } else {
                    _filterKey = 'basic_none';
                  }
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    t.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? kMainPink : Colors.grey[600],
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 카테고리 내 필터 버튼들
  Widget _buildFilterButtons(List<PetFilter> filters) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 0),
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final f = filters[index];
          final bool selected = f.key == _filterKey;
          return GestureDetector(
            onTap: () {
              // 필터 선택 시 즉시 업데이트하여 깜박임 방지
              setState(() {
                _filterKey = f.key;
                // 원본 필터 선택 시 이미지 파일은 그대로 유지 (필터만 제거)
                // _currentImageFile은 변경하지 않음
              });
            },
            child: AnimatedContainer(
              key: ValueKey(
                'filter_${f.key}_${selected}',
              ), // key 추가하여 상태 변경 시 즉시 반영
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 72,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              decoration: BoxDecoration(
                gradient: selected
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                      )
                    : null,
                color: selected
                    ? null
                    : Colors.black.withValues(alpha: 0.4), // 상단 후원하기 아이콘과 동일
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : Colors.white.withValues(alpha: 0.3), // 상단 후원하기 아이콘과 동일
                  width: selected ? 0 : 1, // 상단 후원하기 아이콘과 동일 (1.5 -> 1)
                ),
                // boxShadow 제거 - 상단 후원하기 아이콘과 동일하게
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.2)
                          : Colors.transparent, // 배경 제거 - 후원하기 아이콘과 동일하게
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      f.icon,
                      size: 18,
                      color: selected
                          ? Colors.white
                          : Colors.white, // 아이콘 색상 흰색으로 통일
                    ),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      f.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected
                            ? Colors.white
                            : Colors.white, // 텍스트 색상 흰색으로 통일
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 강도 조절 슬라이더 + 프리셋
  Widget _buildIntensityControls() {
    final PetFilter current =
        _allFilters[_filterKey] ?? _allFilters['basic_none']!;
    final bool isBasicNone = current.key == 'basic_none';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '필터 강도',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              if (isBasicNone)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '기본 모드',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Opacity(
            opacity: isBasicNone ? 0.4 : 1.0,
            child: IgnorePointer(
              ignoring: isBasicNone,
              child: Row(
                children: [
                  Expanded(child: _buildCoatPresetChip('밝은 털', 'light', 0.6)),
                  const SizedBox(width: 5),
                  Expanded(child: _buildCoatPresetChip('보통 털', 'mid', 0.8)),
                  const SizedBox(width: 5),
                  Expanded(child: _buildCoatPresetChip('진한 털', 'dark', 1.0)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Opacity(
            opacity: isBasicNone ? 0.4 : 1.0,
            child: IgnorePointer(
              ignoring: isBasicNone,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: kMainPink,
                  inactiveTrackColor: Colors.grey[300],
                  thumbColor: kMainPink,
                  overlayColor: kMainPink.withValues(alpha: 0.2),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  trackHeight: 2.5,
                ),
                child: Slider(
                  min: 0.4,
                  max: 1.2,
                  value: _intensity,
                  onChanged: (v) {
                    setState(() {
                      _intensity = v;
                      _coatPreset = 'custom';
                    });
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoatPresetChip(String label, String key, double presetValue) {
    final selected = _coatPreset == key;
    return GestureDetector(
      onTap: () {
        setState(() {
          _coatPreset = key;
          _intensity = presetValue;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kMainPink, kMainPink.withValues(alpha: 0.8)],
                )
              : null,
          color: selected ? null : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.transparent : Colors.grey[300]!,
            width: 1.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: kMainPink.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onSavePressed() async {
    if (_isSaving) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // 원본 이미지 파일 읽기
      final Uint8List imageBytes = await _currentImageFile.readAsBytes();
      img.Image? decodedImage = img.decodeImage(imageBytes);

      if (decodedImage == null) {
        setState(() => _isSaving = false);
        return;
      }

      // 리사이즈 제한 제거 - 원본 해상도 유지 (성능 영향 최소화)
      // 필터 적용
      final PetFilter base =
          _allFilters[_filterKey] ?? _allFilters['basic_none']!;

      List<double> finalMatrix = base.key != 'basic_none'
          ? mixMatrix(kIdentityMatrix, base.matrix, _intensity)
          : List.from(kIdentityMatrix);

      // 필터 적용
      if (base.key != 'basic_none') {
        decodedImage = _applyColorMatrixToImage(decodedImage, finalMatrix);
        debugPrint('✅ 필터 적용 완료: ${base.key}');
      }

      // JPEG로 인코딩 (품질 100%)
      final Uint8List jpegBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 100),
      );

      // 갤러리에만 저장 (내부 폴더 저장 없음)
      await Gal.putImageBytes(
        jpegBytes,
        name: 'petgram_edit_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      // 저장 성공 피드백
      HapticFeedback.mediumImpact();

      debugPrint(
        '[Petgram] ✅ filter image saved to gallery only (no internal storage)',
      );

      if (!mounted) return;

      // 성공 메시지 표시
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('필터가 적용된 사진이 갤러리에 저장되었어요! 📸'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );

      // 저장 후 보정 화면 유지 (화면 닫지 않음)
    } catch (e) {
      debugPrint('[Petgram] save filter error: $e');
      if (!mounted) return;

      // 사용자 친화적인 에러 메시지
      String errorMessage = '저장 중 오류가 발생했어요.';
      if (e.toString().contains('permission') ||
          e.toString().contains('Permission') ||
          e.toString().contains('권한')) {
        errorMessage = '갤러리 저장 권한이 필요합니다. 설정에서 권한을 허용해주세요.';
      } else if (e.toString().contains('storage') ||
          e.toString().contains('저장')) {
        errorMessage = '저장 공간이 부족할 수 있습니다. 저장 공간을 확인해주세요.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}

class _FilterCategoryTab {
  final String keyValue;
  final String label;

  const _FilterCategoryTab({required this.keyValue, required this.label});
}

/// 그리드라인 그리기
class GridLinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // 3x3 그리드
    final double thirdWidth = size.width / 3;
    final double thirdHeight = size.height / 3;

    // 세로선 2개
    canvas.drawLine(
      Offset(thirdWidth, 0),
      Offset(thirdWidth, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(thirdWidth * 2, 0),
      Offset(thirdWidth * 2, size.height),
      paint,
    );

    // 가로선 2개
    canvas.drawLine(
      Offset(0, thirdHeight),
      Offset(size.width, thirdHeight),
      paint,
    );
    canvas.drawLine(
      Offset(0, thirdHeight * 2),
      Offset(size.width, thirdHeight * 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 프레임 미리보기 Painter
class FramePreviewPainter extends CustomPainter {
  final List<PetInfo> petList;
  final String? selectedPetId;
  final double previewWidth;
  final double previewHeight;
  final double imageWidth; // 실제 이미지 크기 (저장 시와 동일한 비율 계산용)
  final double imageHeight;
  final AspectRatioMode aspectMode; // 9:16일 때 상단 여백 조정용
  final double topBarHeight; // 상단 바 높이 (9:16일 때 프레임 시작 위치 조정용)
  final double? bottomBarHeight; // 하단 오버레이 경계 (촬영 영역 하단)
  final ui.Image? dogIconImage;
  final ui.Image? catIconImage;
  final String? location; // 위치 정보

  FramePreviewPainter({
    required this.petList,
    required this.selectedPetId,
    required this.previewWidth,
    required this.previewHeight,
    required this.imageWidth,
    required this.imageHeight,
    required this.aspectMode,
    required this.topBarHeight,
    this.bottomBarHeight, // 하단 경계 추가
    this.dogIconImage,
    this.catIconImage,
    this.location,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (petList.isEmpty) return;

    // 선택된 반려동물 정보 가져오기
    PetInfo? selectedPet;
    if (selectedPetId != null) {
      try {
        selectedPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        selectedPet = petList.isNotEmpty ? petList.first : null;
      }
    } else {
      selectedPet = petList.isNotEmpty ? petList.first : null;
    }

    if (selectedPet == null) return;

    // 테두리 제거 - 모든 정보를 칩 형태로 표시 (FramePainter와 동일)
    final double chipHeight = size.width * 0.06;
    final double chipPadding = size.width * 0.03;
    final double chipSpacing = size.width * 0.015;
    final double chipCornerRadius = chipHeight * 0.3;
    final double horizontalPadding = size.width * 0.04;

    // 상단 프레임 위치: FramePainter와 동일한 로직 사용
    // topBarHeight는 프리뷰 박스 내부 로컬 좌표 (0부터 시작)
    // 촬영본과 동기화를 위해 동일한 계산 사용
    double frameTopOffset = (topBarHeight > 0)
        ? topBarHeight + chipPadding * 1.5
        : chipPadding * 1.5;

    debugPrint(
      '[Petgram] 🎨 FramePreviewPainter (로컬 좌표): topBarHeight=$topBarHeight, frameTopOffset=$frameTopOffset, size=${size.width}x${size.height}',
    );

    // 반려동물 정보
    final ui.Image? petIconImage = selectedPet.type == 'dog'
        ? dogIconImage
        : catIconImage;

    // 나이, 젠더, 종 정보
    final age = selectedPet.getAge();
    String genderText = '';
    if (selectedPet.gender != null && selectedPet.gender!.isNotEmpty) {
      final gender = selectedPet.gender!.toLowerCase();
      if (gender == 'male' || gender == 'm') {
        genderText = '♂';
      } else if (gender == 'female' || gender == 'f') {
        genderText = '♀';
      } else {
        genderText = selectedPet.gender!;
      }
    }
    String breedText =
        selectedPet.breed != null && selectedPet.breed!.isNotEmpty
        ? selectedPet.breed!.trim()
        : '';

    String truncateText(String text, int maxLength) {
      if (text.length <= maxLength) return text;
      return '${text.substring(0, maxLength)}...';
    }

    // 칩 너비 계산 헬퍼 함수 (그리지 않고 너비만 계산)
    double calculateChipWidth(String text, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;
      return chipWidth;
    }

    double drawChip(String text, double x, double y, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;

      // 글래스모피즘 효과: 반투명 배경 + 흰색 테두리 + 그림자
      final chipRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, chipWidth, chipHeight),
        Radius.circular(chipCornerRadius),
      );

      // 그림자 효과 (투명도 조절)
      final shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y + 1.5, chipWidth, chipHeight),
          Radius.circular(chipCornerRadius),
        ),
        shadowPaint,
      );

      // 글래스 배경 (반투명 흰색)
      final chipBgPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(chipRect, chipBgPaint);

      // 흰색 테두리
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRRect(chipRect, borderPaint);

      // 아이콘 그리기
      double currentX = x + chipPaddingHorizontal;
      if (iconImage != null) {
        final iconRect = Rect.fromLTWH(
          currentX,
          y + (chipHeight - iconSize) / 2,
          iconSize,
          iconSize,
        );
        canvas.drawImageRect(
          iconImage,
          Rect.fromLTWH(
            0,
            0,
            iconImage.width.toDouble(),
            iconImage.height.toDouble(),
          ),
          iconRect,
          Paint(),
        );
        currentX += iconSize + iconSpacing;
      }

      // 칩 텍스트 그리기
      final double chipTextX = currentX;
      final double chipTextY = y + (chipHeight - chipTextParagraph.height) / 2;
      canvas.drawParagraph(chipTextParagraph, Offset(chipTextX, chipTextY));

      return chipWidth;
    }

    // 상단 칩들
    double currentTopChipX = horizontalPadding;
    final double topChipY = frameTopOffset + chipPadding;

    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 나이, 젠더, 종을 한 칩에 묶어서 표시
    List<String> infoParts = [];
    infoParts.add('$age살');
    if (genderText.isNotEmpty) {
      infoParts.add(genderText);
    }
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • ');
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    // 하단 저작권 정보를 칩 형태로 표시 (촬영날짜, 위치정보)
    // 하단 오버레이 경계를 고려하여 촬영 영역 안에 그리기
    final double bottomInfoPadding = chipPadding * 1.5;
    // 하단 바 높이(80px)와 여유 공간을 줄여서 하단 문구를 더 아래로 배치
    final double bottomBarSpace =
        80.0 + 5.0; // 하단 바 높이 + 여유 공간 (10.0 -> 5.0으로 줄여서 더 아래로)

    // bottomBarHeight는 실제 촬영 영역의 하단 경계 (화면 기준)
    // 하단 문구는 촬영 영역 하단에서 여유 공간을 두고 표시
    double finalBottomInfoY;
    if (bottomBarHeight != null) {
      // 촬영 영역 하단을 기준으로 하단 문구 위치 계산
      // 하단 문구는 촬영 영역 하단에서 bottomBarSpace만큼 위에 배치 (더 아래로 내리기 위해 여유 공간 줄임)
      finalBottomInfoY =
          bottomBarHeight! - bottomBarSpace - bottomInfoPadding - chipHeight;

      // 상단 칩 위치 확인 (하단 문구가 상단 칩 아래에만 그려지도록)
      final double topChipBottom = frameTopOffset + chipHeight + chipPadding;

      // 하단 문구가 상단 칩 영역과 겹치거나, 음수이면 그리지 않음
      if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
          finalBottomInfoY < 0) {
        return; // 하단 문구를 그리지 않음
      }
    } else {
      // bottomBarHeight가 없으면 화면 하단 기준
      finalBottomInfoY =
          size.height - bottomBarSpace - bottomInfoPadding - chipHeight;
    }

    final now = DateTime.now();
    final monthNames = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final dateStr = '📅 ${monthNames[now.month]} ${now.day}, ${now.year}';

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * 2.0; // 오른쪽 패딩
    final double bottomChipSpacing = chipPadding * 0.5; // 칩 간격

    // 1열: 촬영날짜 (아래쪽) - 칩 형태, 오른쪽 정렬
    // 너비만 계산 (그리지 않음)
    final dateChipWidth = calculateChipWidth(dateStr);
    final double dateChipX = size.width - rightMargin - dateChipWidth; // 오른쪽 정렬
    drawChip(dateStr, dateChipX, finalBottomInfoY);

    // 2열: 촬영장소 (위쪽, 위치 정보가 있을 때만) - 칩 형태, 오른쪽 정렬
    if (location != null && location!.isNotEmpty) {
      final locationText = '📍 Shot on location in $location';
      // 너비만 계산 (그리지 않음)
      final locationChipWidth = calculateChipWidth(locationText);
      final double locationChipX =
          size.width - rightMargin - locationChipWidth; // 오른쪽 정렬
      drawChip(
        locationText,
        locationChipX,
        finalBottomInfoY - chipHeight - bottomChipSpacing,
      );
    }
  }

  @override
  bool shouldRepaint(FramePreviewPainter oldDelegate) {
    // 선택된 반려동물의 framePattern도 체크
    PetInfo? oldPet;
    PetInfo? newPet;
    if (oldDelegate.selectedPetId != null) {
      try {
        oldPet = oldDelegate.petList.firstWhere(
          (pet) => pet.id == oldDelegate.selectedPetId,
        );
      } catch (e) {
        oldPet = null;
      }
    }
    if (selectedPetId != null) {
      try {
        newPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        newPet = null;
      }
    }

    return oldDelegate.selectedPetId != selectedPetId ||
        oldDelegate.petList.length != petList.length ||
        oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight ||
        oldDelegate.aspectMode != aspectMode ||
        oldDelegate.topBarHeight != topBarHeight ||
        oldDelegate.location != location ||
        (oldPet?.framePattern != newPet?.framePattern);
  }
}

/// ========================
///  새로운 프레임 시스템
/// ========================

// 프레임 리소스 캐시 (정적 변수로 한 번만 로드)
ui.Image? _cachedLogoImage;
bool _isLoadingFrameResources = false;

/// 프레임 리소스 로드 (HomePage에서 호출)
Future<void> loadFrameResources() async {
  if (_isLoadingFrameResources) return;
  if (_cachedLogoImage != null) return;

  _isLoadingFrameResources = true;
  try {
    // 로고 이미지 로드
    final ByteData logoData = await rootBundle.load('assets/images/logo.png');
    final Uint8List logoBytes = logoData.buffer.asUint8List();
    final ui.Codec logoCodec = await ui.instantiateImageCodec(logoBytes);
    final ui.FrameInfo logoFrameInfo = await logoCodec.getNextFrame();
    _cachedLogoImage = logoFrameInfo.image;
    debugPrint('✅ 프레임 로고 로드 완료');

    // Caveat 폰트는 pubspec.yaml에 추가해야 합니다
    // Google Fonts에서 다운로드: https://fonts.google.com/specimen/Caveat
    // fonts/Caveat-Regular.ttf 파일을 추가하고 pubspec.yaml에 등록 필요
  } catch (e) {
    debugPrint('❌ 리소스 로드 실패: $e');
  }
  _isLoadingFrameResources = false;
}

/// 프레임 Painter (텍스트 중앙 정렬 + dropShadow)
class FramePainter extends CustomPainter {
  final List<PetInfo> petList;
  final String? selectedPetId;
  final double width;
  final double height;
  final double? topBarHeight;
  final double? bottomBarHeight; // 하단 오버레이 경계 (촬영 영역 하단)
  final ui.Image? dogIconImage;
  final ui.Image? catIconImage;
  final String? location; // 위치 정보

  FramePainter({
    required this.petList,
    required this.selectedPetId,
    required this.width,
    required this.height,
    this.topBarHeight,
    this.bottomBarHeight, // 하단 경계 추가
    this.dogIconImage,
    this.catIconImage,
    this.location,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (petList.isEmpty) return;

    // size가 0이거나 너무 작으면 그리지 않음
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    // 선택된 반려동물 정보 가져오기
    PetInfo? selectedPet;
    if (selectedPetId != null) {
      try {
        selectedPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        selectedPet = petList.isNotEmpty ? petList.first : null;
      }
    } else {
      selectedPet = petList.isNotEmpty ? petList.first : null;
    }

    if (selectedPet == null) return;

    // 테두리 제거 - 모든 정보를 칩 형태로 표시
    final double chipHeight = size.width * 0.06; // 칩 높이
    final double chipPadding = size.width * 0.03; // 칩과 화면 경계 사이 여백
    final double chipSpacing = size.width * 0.015; // 칩들 사이 간격
    final double chipCornerRadius = chipHeight * 0.3; // 칩 모서리 둥글기
    final double horizontalPadding = size.width * 0.04; // 좌우 여백

    // 상단 바로 밑 살짝 위쪽에 공간을 주기
    double frameTopOffset = (topBarHeight ?? 0) + chipPadding * 1.5;

    // 반려동물 정보
    final ui.Image? petIconImage = selectedPet.type == 'dog'
        ? dogIconImage
        : catIconImage;

    // 나이, 젠더, 종 정보
    final age = selectedPet.getAge();
    String genderText = '';
    if (selectedPet.gender != null && selectedPet.gender!.isNotEmpty) {
      final gender = selectedPet.gender!.toLowerCase();
      if (gender == 'male' || gender == 'm') {
        genderText = '♂';
      } else if (gender == 'female' || gender == 'f') {
        genderText = '♀';
      } else {
        genderText = selectedPet.gender!;
      }
    }
    String breedText =
        selectedPet.breed != null && selectedPet.breed!.isNotEmpty
        ? selectedPet.breed!.trim()
        : '';

    // 텍스트 길이 제한 헬퍼 함수
    String truncateText(String text, int maxLength) {
      if (text.length <= maxLength) return text;
      return '${text.substring(0, maxLength)}...';
    }

    // 칩 너비 계산 헬퍼 함수 (그리지 않고 너비만 계산)
    double calculateChipWidth(String text, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;
      return chipWidth;
    }

    // 칩 그리기 헬퍼 함수
    double drawChip(String text, double x, double y, {ui.Image? iconImage}) {
      final double chipPaddingHorizontal = chipHeight * 0.4;
      final double iconSize = iconImage != null ? chipHeight * 0.75 : 0;
      final double iconSpacing = iconImage != null ? chipHeight * 0.15 : 0;

      // 최대 칩 너비 설정 (화면 너비의 70%로 제한)
      final double maxChipWidth = size.width * 0.7;
      final double maxTextWidth =
          maxChipWidth - chipPaddingHorizontal * 2 - iconSize - iconSpacing;

      // 텍스트 크기 자동 조정
      double fontSize = chipHeight * 0.5;
      double chipTextWidth = 0;
      ui.Paragraph? chipTextParagraph;

      // 텍스트가 최대 너비를 넘지 않을 때까지 폰트 크기 줄이기
      for (int attempt = 0; attempt < 5; attempt++) {
        final chipTextStyle = ui.ParagraphStyle(
          textAlign: TextAlign.left,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w600,
        );
        final chipTextStyleValue = ui.TextStyle(
          color: const ui.Color.fromARGB(255, 255, 255, 255),
          fontWeight: ui.FontWeight.w600,
        );

        final chipTextBuilder = ui.ParagraphBuilder(chipTextStyle)
          ..pushStyle(chipTextStyleValue);
        chipTextBuilder.addText(text);
        chipTextParagraph = chipTextBuilder.build()
          ..layout(ui.ParagraphConstraints(width: maxTextWidth));

        chipTextWidth = chipTextParagraph.maxIntrinsicWidth;

        if (chipTextWidth <= maxTextWidth) {
          break; // 최대 너비 내에 들어가면 종료
        }

        // 폰트 크기 줄이기
        fontSize = fontSize * 0.9;
      }

      if (chipTextParagraph == null) return 0;

      final double chipWidth =
          chipTextWidth + chipPaddingHorizontal * 2 + iconSize + iconSpacing;

      // 칩 배경 그리기
      // 글래스모피즘 효과: 반투명 배경 + 흰색 테두리 + 그림자
      final chipRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, chipWidth, chipHeight),
        Radius.circular(chipCornerRadius),
      );

      // 그림자 효과 (투명도 조절)
      final shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y + 1.5, chipWidth, chipHeight),
          Radius.circular(chipCornerRadius),
        ),
        shadowPaint,
      );

      // 글래스 배경 (반투명 흰색)
      final chipBgPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(chipRect, chipBgPaint);

      // 흰색 테두리
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRRect(chipRect, borderPaint);

      // 아이콘 그리기
      double currentX = x + chipPaddingHorizontal;
      if (iconImage != null) {
        final iconRect = Rect.fromLTWH(
          currentX,
          y + (chipHeight - iconSize) / 2,
          iconSize,
          iconSize,
        );
        canvas.drawImageRect(
          iconImage,
          Rect.fromLTWH(
            0,
            0,
            iconImage.width.toDouble(),
            iconImage.height.toDouble(),
          ),
          iconRect,
          Paint(),
        );
        currentX += iconSize + iconSpacing;
      }

      // 칩 텍스트 그리기
      final double chipTextX = currentX;
      final double chipTextY = y + (chipHeight - chipTextParagraph.height) / 2;
      canvas.drawParagraph(chipTextParagraph, Offset(chipTextX, chipTextY));

      return chipWidth;
    }

    // 상단 칩들 (왼쪽부터)
    double currentTopChipX = horizontalPadding;
    final double topChipY = frameTopOffset + chipPadding;

    // 이름 칩
    final truncatedName = truncateText(selectedPet.name, 12);
    final nameChipWidth = drawChip(
      truncatedName,
      currentTopChipX,
      topChipY,
      iconImage: petIconImage,
    );
    currentTopChipX += nameChipWidth + chipSpacing;

    // 생년월일/나이 칩
    // 나이, 젠더, 종을 한 칩에 묶어서 표시
    List<String> infoParts = [];
    infoParts.add('$age살');
    if (genderText.isNotEmpty) {
      infoParts.add(genderText);
    }
    if (breedText.isNotEmpty) {
      infoParts.add(breedText);
    }
    if (infoParts.isNotEmpty) {
      final infoText = infoParts.join(' • ');
      final chipWidth = drawChip(infoText, currentTopChipX, topChipY);
      currentTopChipX += chipWidth + chipSpacing;
    }

    // 하단 저작권 정보를 칩 형태로 표시 (촬영날짜, 위치정보)
    // 하단 오버레이 경계를 고려하여 촬영 영역 안에 그리기
    final double bottomInfoPadding = chipPadding * 1.5;

    // bottomBarSpace를 이미지 크기에 비례하도록 계산
    // 프리뷰에서는 화면 기준 100px이지만, 저장 이미지에서는 이미지 높이의 비율로 계산
    // 일반적인 화면 높이(약 800-900px)를 기준으로 100px은 약 11-12%에 해당
    // 안전하게 이미지 높이의 5%를 사용하되, 최소값은 chipHeight의 1.5배로 설정 (8% -> 5%로 줄여서 더 아래로)
    final double minBottomSpace = chipHeight * 1.5;
    final double proportionalBottomSpace =
        size.height * 0.05; // 0.08 -> 0.05로 줄여서 더 아래로
    final double bottomBarSpace = proportionalBottomSpace > minBottomSpace
        ? proportionalBottomSpace
        : minBottomSpace;

    // bottomBarHeight는 실제 촬영 영역의 하단 경계 (화면 기준)
    // 하단 문구는 촬영 영역 하단에서 여유 공간을 두고 표시
    double finalBottomInfoY;
    if (bottomBarHeight != null) {
      // 촬영 영역 하단을 기준으로 하단 문구 위치 계산
      // 하단 문구는 촬영 영역 하단에서 bottomBarSpace만큼 위에 배치 (더 아래로 내리기 위해 여유 공간 줄임)
      finalBottomInfoY =
          bottomBarHeight! - bottomBarSpace - bottomInfoPadding - chipHeight;

      // 상단 칩 위치 확인 (하단 문구가 상단 칩 아래에만 그려지도록)
      final double topChipBottom =
          (topBarHeight ?? chipPadding * 2) + chipHeight + chipPadding;

      // 하단 문구가 상단 칩 영역과 겹치거나, 음수이면 그리지 않음
      if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
          finalBottomInfoY < 0) {
        debugPrint(
          '[Petgram] ⚠️ 하단 문구가 상단 칩과 겹치거나 위치가 잘못됨: finalBottomInfoY=$finalBottomInfoY, topChipBottom=$topChipBottom, 그리지 않음',
        );
        return; // 하단 문구를 그리지 않음
      }

      debugPrint(
        '[Petgram] 🔍 FramePainter 하단 위치: bottomBarHeight=$bottomBarHeight, finalBottomInfoY=$finalBottomInfoY, chipHeight=$chipHeight, size.height=${size.height}, topChipBottom=$topChipBottom, bottomBarSpace=$bottomBarSpace',
      );
    } else {
      // bottomBarHeight가 없으면 화면 하단 기준
      finalBottomInfoY =
          size.height - bottomBarSpace - bottomInfoPadding - chipHeight;

      // 음수 체크
      if (finalBottomInfoY < 0) {
        debugPrint(
          '[Petgram] ⚠️ 하단 문구 위치가 음수: finalBottomInfoY=$finalBottomInfoY, 그리지 않음',
        );
        return;
      }
    }

    final now = DateTime.now();
    final monthNames = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final dateStr = '📅 ${monthNames[now.month]} ${now.day}, ${now.year}';

    // finalBottomInfoY가 유효한지 최종 확인 (상단 칩 아래인지, 양수인지)
    final double topChipBottom =
        (topBarHeight ?? chipPadding * 2) + chipHeight + chipPadding;
    if (finalBottomInfoY < topChipBottom + chipPadding * 2 ||
        finalBottomInfoY < 0) {
      debugPrint(
        '[Petgram] ⚠️ 하단 칩 그리기 전 최종 체크 실패: finalBottomInfoY=$finalBottomInfoY, topChipBottom=$topChipBottom, 그리지 않음',
      );
      return; // 하단 칩을 그리지 않음
    }

    // 오른쪽 정렬로 칩 그리기 (칩의 오른쪽 끝이 화면 오른쪽에 맞춰짐)
    final double rightMargin = horizontalPadding * 2.0; // 오른쪽 패딩
    final double chipSpacingBottom = chipPadding * 0.5; // 칩 간격

    // 1열: 촬영날짜 (아래쪽) - 칩 형태, 오른쪽 정렬
    // 너비만 계산 (그리지 않음)
    final dateChipWidth = calculateChipWidth(dateStr);
    final double dateChipX = size.width - rightMargin - dateChipWidth; // 오른쪽 정렬

    // dateChipX가 유효한지 확인 (음수이거나 화면 밖이면 그리지 않음)
    if (dateChipX >= 0 && dateChipX + dateChipWidth <= size.width) {
      drawChip(dateStr, dateChipX, finalBottomInfoY);
    } else {
      debugPrint(
        '[Petgram] ⚠️ 날짜 칩 X 좌표가 유효하지 않음: dateChipX=$dateChipX, dateChipWidth=$dateChipWidth, size.width=${size.width}',
      );
    }

    // 2열: 촬영장소 (위쪽, 위치 정보가 있을 때만) - 칩 형태, 오른쪽 정렬
    if (location != null && location!.isNotEmpty) {
      final locationText = '📍 Shot on location in $location';
      // 너비만 계산 (그리지 않음)
      final locationChipWidth = calculateChipWidth(locationText);
      final double locationChipX =
          size.width - rightMargin - locationChipWidth; // 오른쪽 정렬
      final double locationChipY =
          finalBottomInfoY - chipHeight - chipSpacingBottom;

      // locationChipY가 유효한지 확인 (상단 칩 아래인지, 양수인지)
      if (locationChipY >= topChipBottom + chipPadding * 2 &&
          locationChipX >= 0 &&
          locationChipX + locationChipWidth <= size.width) {
        drawChip(locationText, locationChipX, locationChipY);
      } else {
        debugPrint(
          '[Petgram] ⚠️ 위치 칩 좌표가 유효하지 않음: locationChipY=$locationChipY, locationChipX=$locationChipX, topChipBottom=$topChipBottom',
        );
      }
    }
  }

  @override
  bool shouldRepaint(FramePainter oldDelegate) {
    PetInfo? oldPet;
    PetInfo? newPet;
    if (oldDelegate.selectedPetId != null) {
      try {
        oldPet = oldDelegate.petList.firstWhere(
          (pet) => pet.id == oldDelegate.selectedPetId,
        );
      } catch (e) {
        oldPet = null;
      }
    }
    if (selectedPetId != null) {
      try {
        newPet = petList.firstWhere((pet) => pet.id == selectedPetId);
      } catch (e) {
        newPet = null;
      }
    }

    return oldDelegate.selectedPetId != selectedPetId ||
        oldDelegate.petList.length != petList.length ||
        oldDelegate.width != width ||
        oldDelegate.height != height ||
        oldDelegate.topBarHeight != topBarHeight ||
        oldDelegate.bottomBarHeight != bottomBarHeight ||
        (oldPet?.framePattern != newPet?.framePattern) ||
        (oldPet?.gender != newPet?.gender) ||
        (oldPet?.breed != newPet?.breed);
  }
}

/// 프레임 이미지 내보내기 클래스
class FrameExporter {
  /// RepaintBoundary를 사용하여 프레임이 적용된 이미지를 내보내기
  static Future<File?> exportFrameImage({
    required GlobalKey repaintBoundaryKey,
    required File sourceImageFile,
    required List<PetInfo> petList,
    required String? selectedPetId,
    required double width,
    required double height,
    double? topBarHeight,
  }) async {
    try {
      // RepaintBoundary에서 이미지 캡처
      final RenderRepaintBoundary? boundary =
          repaintBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;

      if (boundary == null) {
        debugPrint('❌ FrameExporter: RepaintBoundary를 찾을 수 없습니다');
        return null;
      }

      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) {
        image.dispose();
        debugPrint('❌ FrameExporter: 이미지 변환 실패');
        return null;
      }

      final Uint8List pngBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      // PNG를 디코딩하여 JPEG로 변환
      final img.Image? decodedImage = img.decodeImage(pngBytes);
      if (decodedImage == null) {
        image.dispose();
        debugPrint('❌ FrameExporter: PNG 디코딩 실패');
        return null;
      }

      // JPEG로 인코딩 (품질 95)
      final Uint8List jpegBytes = Uint8List.fromList(
        img.encodeJpg(decodedImage, quality: 100),
      );

      // 임시 파일로 저장
      final dir = await getTemporaryDirectory();
      final filePath =
          '${dir.path}/framed_export_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final File framedFile = File(filePath);
      await framedFile.writeAsBytes(jpegBytes);

      image.dispose();
      debugPrint('✅ FrameExporter: 프레임 이미지 내보내기 완료');
      return framedFile;
    } catch (e, stackTrace) {
      debugPrint('❌ FrameExporter error: $e');
      debugPrint('❌ FrameExporter stackTrace: $stackTrace');
      return null;
    }
  }
}
