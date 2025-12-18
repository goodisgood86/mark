import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';

import '../models/constants.dart';
import '../models/filter_data.dart';
import '../models/filter_models.dart';
import '../models/pet_info.dart';
import '../services/image_pipeline_service.dart';
import '../services/native_filter_service.dart';
import '../services/petgram_meta_service.dart';
import '../models/petgram_photo_meta.dart';
import '../services/petgram_photo_repository.dart';
import 'package:exif/exif.dart';
import '../models/petgram_nav_tab.dart';
import '../widgets/petgram_bottom_nav_bar.dart';
import 'diary_page.dart';
import '../models/aspect_ratio_mode.dart';

class FilterPage extends StatefulWidget {
  final File imageFile;
  final String initialFilterKey;
  final PetInfo? selectedPet; // 펫 정보 (펫톤 보정용)
  final String? coatPreset; // 코트 프리셋 (light/mid/dark)
  final PetgramPhotoMeta? originalMeta; // 원본 메타데이터 (우리 앱에서 촬영한 경우)
  final AspectRatioMode? aspectMode; // 선택된 비율 모드 (1:1, 3:4, 9:16)

  const FilterPage({
    super.key,
    required this.imageFile,
    required this.initialFilterKey,
    this.selectedPet,
    this.coatPreset,
    this.originalMeta, // 원본 메타데이터 추가
    this.aspectMode, // 선택된 비율 모드 추가
  });

  @override
  State<FilterPage> createState() => _FilterPageState();
}

/// 펫 전용 보정 프리셋 모델
class _PetAdjustPreset {
  final String id;
  final String label;
  final double brightness; // -50 ~ +50
  final double contrast; // -50 ~ +50
  final double sharpness; // 0 ~ 100

  const _PetAdjustPreset({
    required this.id,
    required this.label,
    required this.brightness,
    required this.contrast,
    required this.sharpness,
  });
}

/// 조정 타입 enum (슬라이딩 패널용)
enum AdjustmentType {
  filterAndIntensity, // 필터 + 강도
  petToneAndAdjust, // 펫톤 + 밝기/대비/선명
}

/// FilterPage 로딩 상태 enum (단일 플래그로 통일)
enum FilterLoadingState {
  idle,
  loadingInitial,
  loadingNewImage,
  saving,
  error, // 에러 상태 (Flutter 에러 화면 대신 fallback UI 표시)
}

/// FilterPage 로딩 단계 enum (단일 로딩: NativeFilterService.renderPreview만 사용)
enum FilterLoadingPhase {
  initial, // 아직 아무것도 안한 상태
  loading, // 프리뷰 로딩 중 (NativeFilterService.renderPreview 사용)
  ready, // 프리뷰 준비 완료
  error,
}

class _FilterPageState extends State<FilterPage> {
  late String _category;
  late String _filterKey;
  String _currentImagePath = ''; // 정규화된 이미지 경로 (File 대신 String 사용, 초기값은 빈 문자열)
  // initialFilterKey는 UI용 메타 정보로만 사용 (촬영 시 적용된 필터 정보)
  // 실제 필터 적용은 _filterKey로 제어하며, 항상 _currentImagePath만 사용

  final ImagePicker _picker = ImagePicker();

  // 현재 이미지의 메타데이터 (EXIF에서 복원하거나 초기값)
  PetgramPhotoMeta? _currentOriginalMeta;

  double _intensity = 0.8;
  String _coatPreset = 'mid'; // light / mid / dark / custom

  // 썸네일 이미지 (프리뷰용, 저해상도) - buildPreviewImage 결과를 저장
  ui.Image? _previewImage;

  // 로딩 상태를 단일 플래그로 통일
  FilterLoadingState _loadingState = FilterLoadingState.idle;

  // 단일 로딩: NativeFilterService.renderPreview만 사용
  FilterLoadingPhase _loadingPhase = FilterLoadingPhase.initial;
  Uint8List?
  _fullPreviewBytes; // 프리뷰 바이트 (NativeFilterService.renderPreview 결과)

  // 프리뷰 이미지 비율 (width / height)
  double? _previewAspectRatio;

  // 펫 전용 보정 (FilterPage 전용)
  double _editBrightness = 0.0; // -50 ~ +50
  double _editContrast = 0.0; // -50 ~ +50
  double _editSharpness = 0.0; // 0 ~ 100

  // 펫 전용 보정 프리셋
  String _selectedPresetId = 'basic'; // 기본 프리셋
  bool _isManualDetailMode = false; // false=프리셋, true=수동

  // 핀치줌 관련 변수
  double _baseScale = 1.0;
  double _currentScale = 1.0;
  Offset _offset = Offset.zero;
  Offset _lastFocalPoint = Offset.zero;

  // 성능 최적화: 슬라이더 변경 debounce 타이머
  Timer? _sliderDebounceTimer;

  // [UI 개편] 활성 조정 타입 (슬라이딩 패널용)
  AdjustmentType? _activeAdjustment;

  // iOS 네이티브 필터 서비스 (CoreImage + Metal)
  late final NativeFilterService _nativeFilterService;

  // 🔥 카메라 제어용 MethodChannel (HomePage와 통신)
  static const MethodChannel _cameraChannel = MethodChannel(
    'petgram/camera_control',
  );

  @override
  void initState() {
    super.initState();
    _nativeFilterService = NativeFilterService();
    // 촬영 시 입혀진 필터가 원본이므로, 초기 필터 키를 'basic_none'으로 설정
    // 이미지 파일 자체가 이미 필터가 적용된 상태이므로, 원본 필터를 기본으로 설정
    _filterKey = 'basic_none';
    _category = 'basic';
    // widget.initialFilterKey는 UI용 메타 정보 (현재는 사용하지 않음)

    // 초기 메타데이터 설정: widget.originalMeta가 있으면 사용, 없으면 EXIF에서 읽기
    _currentOriginalMeta = widget.originalMeta;

    // originalMeta가 없으면 초기 이미지의 EXIF에서 복원 시도 (나중에 _initImage에서 수행)

    // 펫 정보 초기화
    if (widget.coatPreset != null) {
      _coatPreset = widget.coatPreset!;
    }

    // 기본 프리셋 적용
    if (_detailPresets.isNotEmpty) {
      _applyPreset(_detailPresets.first);
    }

    // 초기 로딩 단계 설정
    _loadingPhase = FilterLoadingPhase.initial;

    // 화면 전환 애니메이션/첫 프레임이 나온 뒤에 heavy work 시작
    // initState()에서는 setState도 호출하지 않고, heavy work도 호출하지 않음
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // EXIF normalize 먼저 수행 후 2단계 로딩 시작
        _initInitialImage();
      }
    });
  }

  /// 초기 이미지 EXIF 정규화 및 2단계 로딩 시작
  /// FilterPage 진입 시 딱 한 번만 호출됨
  /// 원본 경로 → normalize → _currentImagePath 저장 → 2단계 프리뷰 로딩
  Future<void> _initInitialImage() async {
    final sourcePath = widget.imageFile.path;

    // ⚠️ 중요: EXIF orientation 정규화를 Dart 레이어에서 수행하지 않음
    //          iOS 네이티브 파이프라인(FilterPipeline.swift)에서만 EXIF orientation을 처리
    //          원본 파일 경로를 그대로 사용하여 중복 회전을 방지

    if (!mounted) return;

    // 원본 경로를 _currentImagePath에 저장 (정규화 없음)
    // 🔥 깜빡임 방지: 초기 이미지 설정 시에도 이전 이미지를 유지
    setState(() {
      _currentImagePath = sourcePath;
      // 🔥 핵심: _fullPreviewBytes를 null로 설정하지 않음 (이전 이미지 유지)
      //          로딩 상태만 변경하여 새 이미지 로딩 중임을 표시
      _loadingPhase = FilterLoadingPhase.initial;
      // 🔥 _fullPreviewBytes는 유지 (새 이미지가 로드될 때까지 이전 이미지 표시)
    });

    // 🔥 성능 최적화: 필터페이지를 즉시 표시하기 위해 await 제거
    //    프리뷰 로딩은 백그라운드에서 진행되며, 로딩 중에는 로딩 UI가 표시됨
    unawaited(_startPreviewLoad());

    // 🔥 필터 썸네일 생성 비활성화: 기존처럼 아이콘만 사용
    // unawaited(_generateFilterThumbnails());
  }

  /// 통합 프리뷰 로딩 함수 (2단계 로딩: 썸네일 → 고해상도)
  /// EXIF normalize 완료된 _currentImagePath를 사용하여 NativeFilterService.renderPreview로 프리뷰 생성
  /// ⚠️ 중요: 이 함수는 PetgramImageDecodeService를 사용하지 않고,
  ///          NativeFilterService.renderPreview만 사용하여 orientation 일관성을 보장합니다.
  /// - quickMode: true이면 저해상도 썸네일만 로딩 (빠른 반응), false이면 2단계 로딩
  Future<void> _startPreviewLoad({bool quickMode = false}) async {
    final path = _currentImagePath;
    if (path.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingPhase = FilterLoadingPhase.error;
        });
      }
      return;
    }

    if (!mounted) return;

    // 🔥 깜빡임 방지: 필터/펫톤 변경 시에는 로딩 상태를 변경하지 않음
    //    이미 프리뷰가 있는 경우(필터 변경)에는 이전 이미지를 유지
    final bool isFilterChange =
        _fullPreviewBytes != null && _loadingPhase == FilterLoadingPhase.ready;

    if (!isFilterChange) {
      // 초기 로딩 또는 이미지 변경 시에만 로딩 상태 설정
      setState(() {
        _loadingPhase = FilterLoadingPhase.loading;
      });
    }

    try {
      // 🔥 성능 최적화: 파일 검증을 최소화하여 즉시 로딩 시작
      //    네이티브에서 파일 검증을 수행하므로 중복 검증 불필요
      //    파일이 없거나 비어있으면 네이티브에서 에러를 반환하므로 여기서는 스킵

      // 🔥 성능 최적화: EXIF 읽기를 백그라운드로 이동 (프리뷰 로딩과 병렬)
      unawaited(_readExifInBackground(path));

      final config = _buildCurrentFilterConfig();

      // 🔥 성능 최적화: 최초 로딩 시 해상도 확인 스킵하여 즉시 프리뷰 생성
      //    네이티브에서 해상도를 확인하므로 Flutter에서 미리 확인할 필요 없음
      //    빠른 프리뷰를 위해 1200px로 고정하여 즉시 로딩

      // 🔥 성능 최적화: 최초 로딩 시 빠른 프리뷰를 위해 1200px로 고정
      //    해상도 확인 없이 즉시 1200px로 요청하여 빠른 로딩
      const int targetMaxDimension = 1200;
      final int previewMaxSize = targetMaxDimension; // 최초 로딩 시 항상 1200px로 고정

      // 🔥 화질 개선: 9:16 비율 특화 해상도 처리
      //    9:16은 세로가 매우 길기 때문에 더 높은 해상도 필요
      //    가로 기준으로 충분한 해상도를 보장해야 함
      final double? currentAspect =
          _previewAspectRatio ??
          (widget.aspectMode == AspectRatioMode.nineSixteen
              ? 9.0 / 16.0
              : null);
      final bool isNineSixteen =
          currentAspect != null && (currentAspect - 9.0 / 16.0).abs() < 0.01;

      // 9:16 비율일 때는 가로 해상도를 더 높게 보장
      // 예: displayWidth가 360px이면 최소 720px 가로 해상도 필요 (2배)
      //     긴 변 기준으로는 1280px 필요 (360 * 16/9 * 2 = 1280)
      final int finalMaxSize;
      if (isNineSixteen) {
        // 9:16 비율: 최소 1600px (가로 900px, 세로 1600px) 보장
        final int minNineSixteenSize = 1600;
        finalMaxSize = quickMode
            ? minNineSixteenSize // quickMode일 때도 최소 1600px
            : (previewMaxSize > minNineSixteenSize
                  ? previewMaxSize
                  : minNineSixteenSize);
      } else {
        // 다른 비율: 기존 로직 유지
        finalMaxSize = quickMode && previewMaxSize > 1200
            ? 1200 // quickMode일 때도 최소 1200px 유지
            : (previewMaxSize > 1200 ? previewMaxSize : 1200); // 최소 1200px 보장
      }

      final preview = await _nativeFilterService.renderPreview(
        _currentImagePath,
        config,
        null, // FilterPage는 원본 비율 유지
        maxSize: finalMaxSize,
      );

      // 프리뷰 이미지 비율 계산
      final aspect = preview.width / preview.height;

      if (!mounted) {
        preview.dispose();
        return;
      }

      // ui.Image를 PNG 바이트로 직접 변환
      final byteData = await preview.toByteData(format: ui.ImageByteFormat.png);
      preview.dispose();

      if (byteData == null) {
        if (kDebugMode) {
          debugPrint('[FilterPage] ⚠️ Failed to convert preview to PNG bytes');
        }
        if (mounted) {
          setState(() {
            _loadingPhase = FilterLoadingPhase.error;
          });
        }
        return;
      }

      final pngBytes = byteData.buffer.asUint8List();

      if (!mounted) return;

      // 🔥 깜빡임 방지: 필터 변경 시에는 이전 프리뷰를 유지하면서 새 프리뷰를 준비
      //    새 프리뷰가 준비되면 한 번만 교체하여 깜빡임 최소화
      if (mounted) {
        setState(() {
          // 새 프리뷰 바이트로 교체 (이전 프리뷰는 자동으로 사라짐)
          _fullPreviewBytes = pngBytes;
          // 로딩 상태는 항상 ready로 유지 (필터 변경 시에도 깜빡임 방지)
          _loadingPhase = FilterLoadingPhase.ready;
          _previewAspectRatio = aspect;
        });
      }

      // EXIF에서 메타데이터 복원 (백그라운드)
      if (_currentOriginalMeta == null) {
        unawaited(_restoreMetaFromExif(File(path)));
      }
    } catch (e, stackTrace) {
      // 🔴 예외 발생 시에도 절대 Flutter 에러 화면이 뜨지 않도록 여기서 전부 잡기
      if (kDebugMode) {
        debugPrint('[FilterPage] ❌ _startPreviewLoad error: $e');
        debugPrint('[FilterPage] ❌ Error type: ${e.runtimeType}');
        debugPrint('[FilterPage] Stack trace: $stackTrace');

        // 🔥 네이티브 에러 상세 정보 출력
        if (e is PlatformException) {
          debugPrint('[FilterPage] ❌ PlatformException code: ${e.code}');
          debugPrint('[FilterPage] ❌ PlatformException message: ${e.message}');
          debugPrint('[FilterPage] ❌ PlatformException details: ${e.details}');
        }
      }

      if (!mounted) return;

      setState(() {
        _loadingPhase = FilterLoadingPhase.error;
      });
    }
  }

  /// 백그라운드에서 EXIF 읽기 (프리뷰 로딩과 병렬)
  Future<void> _readExifInBackground(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return;
      }

      final bytes = await file.readAsBytes();
      // EXIF orientation은 네이티브에서 처리하므로 여기서는 읽기만 수행
      await readExifFromBytes(bytes);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FilterPage] ⚠️ Failed to read EXIF orientation: $e');
      }
      // 에러는 무시 (프리뷰 로딩에 영향 없음)
    }
  }

  /// 이미지 뷰 빌드 (2단계 로딩: 풀 프리뷰 → 퀵 프리뷰 → 플레이스홀더)
  /// 필터/펫톤 변경 시에도 즉시 반영되도록 previewBytes 선택 기준 통일
  Widget _buildImageView() {
    // ⚠️ 중요: _fullPreviewBytes만 사용 (QuickPreview는 사용하지 않음)
    //          모든 프리뷰는 NativeFilterService.renderPreview로 생성되므로
    //          orientation이 일관되게 유지됩니다.
    // ⚠️ 주의: 이 함수는 _buildZoomablePreview() 내부에서 호출되므로,
    //          Transform.scale과 Center가 이미 적용된 상태입니다.
    //          따라서 여기서는 이미지만 렌더링합니다.
    final previewBytes = _fullPreviewBytes;

    if (previewBytes != null && previewBytes.isNotEmpty) {
      // 🔥 화질 개선: 9:16 비율 특화 fit 전략
      //    9:16은 세로가 길어서 cover 사용 시 잘릴 수 있으므로 contain 사용
      //    다른 비율은 cover 사용하여 여백 제거
      final double? currentAspect = _previewAspectRatio;
      final bool isNineSixteen =
          currentAspect != null && (currentAspect - 9.0 / 16.0).abs() < 0.01;
      final BoxFit fit = isNineSixteen ? BoxFit.contain : BoxFit.cover;

      // 🔥 깜빡임 방지: RepaintBoundary로 감싸서 불필요한 리빌드 방지
      //    ValueKey는 이미지 경로만 사용하여 필터 변경 시에도 위젯 재생성 방지
      return RepaintBoundary(
        child: Image.memory(
          previewBytes,
          fit: fit,
          filterQuality: FilterQuality.high, // 🔥 고품질 렌더링
          // 🔥 안정적인 key: 이미지 경로만 사용 (필터 변경 시에도 위젯 재생성 방지)
          key: ValueKey('preview_image_${_currentImagePath}'),
          // 🔥 이미지가 변경될 때만 fade 효과 (필터 변경 시에는 즉시 교체)
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            // 동기 로드된 경우 (캐시된 이미지) 또는 프레임이 준비된 경우
            if (wasSynchronouslyLoaded || frame != null) {
              return child;
            }
            // 비동기 로드 중에는 이전 이미지 유지 (깜빡임 방지)
            return child;
          },
        ),
      );
    }

    // 🔻 네이티브 프리뷰가 실패했을 때 최소한 원본 이미지는 보여주기
    //    이렇게 하면 네이티브 프리뷰가 실패해도 외부 사진은 최소 화면에 떠서
    //    "아, 이건 orientation/필터 문제다 vs 프리뷰 자체 문제다"를 눈으로라도 구분할 수 있음
    if (_currentImagePath.isNotEmpty) {
      final fallbackFile = File(_currentImagePath);
      if (fallbackFile.existsSync()) {
        if (kDebugMode) {
          debugPrint(
            '[FilterPage] 🔻 Fallback: Using original file for preview: $_currentImagePath',
          );
        }
        return Image.file(
          fallbackFile,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high, // 🔥 고품질 렌더링
          key: ValueKey('fallback_${_currentImagePath}'),
        );
      }
    }

    // 아직 아무것도 준비 안 된 상태
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.grey[200],
      child: const Center(
        child: Text(
          '이미지를 불러오는 중입니다...',
          style: TextStyle(fontSize: 14, color: Colors.black54),
        ),
      ),
    );
  }

  /// 줌 가능한 프리뷰 위젯 (핀치 줌/이동)
  Widget _buildZoomablePreview() {
    // 핀치 줌/축소를 위한 제스처 + 트랜스폼 래퍼
    // ⚠️ 중요: behavior: HitTestBehavior.opaque를 사용하여 제스처가 제대로 감지되도록 함
    return GestureDetector(
      behavior: HitTestBehavior.opaque, // 제스처 감지 영역 확보
      onScaleStart: (details) {
        _baseScale = _currentScale;
        _lastFocalPoint = details.focalPoint;
      },
      onScaleUpdate: (details) {
        setState(() {
          // 기본 스케일을 기준으로 배율 계산 (최소 0.5, 최대 4.0 정도로 제한)
          final newScale = (_baseScale * details.scale).clamp(0.5, 4.0);
          _currentScale = newScale;

          // 확대 상태에서만 이동 허용
          if (_currentScale > 1.0) {
            final delta = details.focalPoint - _lastFocalPoint;
            _lastFocalPoint = details.focalPoint;
            _offset += delta;
          } else {
            _offset = Offset.zero;
          }
        });

        if (kDebugMode) {
          debugPrint(
            '[FilterPage] 🔍 Pinch zoom update: scale=${details.scale.toStringAsFixed(2)}, '
            '_currentScale=${_currentScale.toStringAsFixed(2)}, offset=$_offset',
          );
        }
      },
      onScaleEnd: (details) {
        // 너무 축소되었을 때만 최소 배율(0.5)로 보정
        if (_currentScale < 0.5) {
          setState(() {
            _currentScale = 0.5;
            _offset = Offset.zero;
          });
        }

        if (kDebugMode) {
          debugPrint(
            '[FilterPage] 🔍 Pinch zoom end: finalScale=${_currentScale.toStringAsFixed(2)}, '
            'finalOffset=$_offset',
          );
        }
      },
      child: ClipRect(
        child: Transform.translate(
          offset: _offset,
          child: Transform.scale(
            scale: _currentScale,
            alignment: Alignment.center,
            child: _buildImageView(),
          ),
        ),
      ),
    );
  }

  /// 초기 이미지 로딩 시작 (heavy work 비동기화)

  /// 이미지 변경 흐름 통일 함수
  /// 모든 이미지 변경 경로에서 이 함수를 사용하여 프리뷰가 항상 최신 상태를 보여주도록 함
  /// @deprecated 이 함수는 더 이상 사용하지 않습니다. _initInitialImage() 또는 _pickNewImage()를 사용하세요.
  /// EXIF normalize는 호출 전에 이미 완료되어야 하며, 이 함수는 normalize된 경로만 받습니다.
  @Deprecated(
    'Use _initInitialImage() or _pickNewImage() instead. EXIF normalize should be done before calling this.',
  )
  @override
  /// 🔥 성능 최적화: dispose 시 메모리 정리 강화
  @override
  void dispose() {
    _sliderDebounceTimer?.cancel();
    // 프리뷰 이미지 dispose (메모리 최적화)
    _previewImage?.dispose();
    // 🔥 메모리 정리: 프리뷰 바이트 데이터 초기화
    _fullPreviewBytes = null;
    _currentImagePath = '';
    super.dispose();
  }

  /// 🔥 카메라 pause (다른 페이지로 이동 시 호출)
  Future<void> _pauseCamera() async {
    try {
      await _cameraChannel.invokeMethod('pauseCamera');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FilterPage] ⚠️ Failed to pause camera: $e');
      }
    }
  }

  /// 🔥 카메라 resume (다른 페이지에서 돌아올 때 호출)
  Future<void> _resumeCamera() async {
    try {
      await _cameraChannel.invokeMethod('resumeCamera');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FilterPage] ⚠️ Failed to resume camera: $e');
      }
    }
  }

  /// 필터/펫톤 변경 시 프리뷰 업데이트 (debounce 적용, 성능 최적화)
  /// previewBytes에 필터를 적용하여 _fullPreviewBytes를 업데이트
  /// 🔥 성능 최적화: Debounce 시간을 200ms로 단축 (즉시 반응)
  void _debouncePreviewUpdate() {
    _sliderDebounceTimer?.cancel();
    _sliderDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        // 필터 변경 시에는 빠른 미리보기만 (quickMode: true)
        _startPreviewLoad(quickMode: true);
      }
    });
  }

  Future<void> _pickNewImage() async {
    // 로딩 중이면 중복 호출 방지
    if (_loadingPhase == FilterLoadingPhase.loading) {
      return;
    }

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100, // 최대 품질
      );

      if (!mounted || picked == null) {
        return;
      }

      // 🔥 깜빡임 방지: 새로운 이미지 선택 시 이전 이미지를 유지하면서 새 이미지 로드
      //    이전 프리뷰를 유지하여 깜빡임 최소화
      setState(() {
        _currentImagePath = picked.path;
        // 🔥 핵심: _fullPreviewBytes를 null로 설정하지 않음 (이전 이미지 유지)
        //          로딩 상태만 변경하여 새 이미지 로딩 중임을 표시
        _loadingPhase = FilterLoadingPhase.loading;
        // 핀치줌만 리셋 (필요한 것만)
        _currentScale = 1.0;
        _baseScale = 1.0;
        _offset = Offset.zero;
        // 메타데이터 초기화 (EXIF에서 복원 예정)
        _currentOriginalMeta = null;
        // 🔥 _fullPreviewBytes는 유지 (새 이미지가 로드될 때까지 이전 이미지 표시)
      });

      // 🔥 성능 최적화: 백그라운드에서 프리뷰 로딩 (await 제거하여 UI 블로킹 방지)
      // 2단계 로딩: 썸네일 → 고해상도
      unawaited(_startPreviewLoad(quickMode: false));
    } catch (e, stackTrace) {
      // 🔴 예외 발생 시에도 절대 Flutter 에러 화면이 뜨지 않도록 여기서 전부 잡기
      if (kDebugMode) {
        debugPrint('[FilterPage] ❌ _pickNewImage error: $e');
        debugPrint('[FilterPage] Stack trace: $stackTrace');
      }
      if (mounted) {
        setState(() {
          _loadingPhase = FilterLoadingPhase.error;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('이미지를 불러오는 중 오류가 발생했어요.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 이미지 파일에서 EXIF UserComment를 읽어서 메타데이터 복원
  ///
  /// [imageFile]: 이미지 파일 (호환성을 위해 유지하지만 실제로는 _currentImagePath 사용)
  ///
  /// 복원된 메타데이터는 _currentOriginalMeta에 저장됨
  /// 예외 처리를 강화하여 Flutter 에러 화면이 뜨지 않도록 함
  /// 🔥 중요: DB에서 먼저 확인하고, 없으면 EXIF에서 읽기
  /// 🔥 EXIF에서 메타데이터 복원 (DB 조회 제거, EXIF만 사용)
  ///
  /// 원본 파일은 그대로 두고 보정 파일을 1개 더 만드는 것이므로
  /// 이미지 피커로 불러오는 게 맞고, DB 경로 문제를 피하기 위해
  /// EXIF에 있으면 그대로 복사해오는 것으로 처리
  Future<void> _restoreMetaFromExif(File imageFile) async {
    final file = File(_currentImagePath);

    try {
      // 파일 존재 여부 확인
      if (!await file.exists()) {
        if (kDebugMode) {
          debugPrint(
            '[FilterPage] ⚠️ Image file does not exist: $_currentImagePath',
          );
        }
        return;
      }

      // 파일 크기 확인 (0 바이트 파일 방지)
      final fileSize = await file.length();
      if (fileSize == 0) {
        if (kDebugMode) {
          debugPrint('[FilterPage] ⚠️ Image file is empty (0 bytes)');
        }
        return;
      }

      final imageBytes = await file.readAsBytes();
      final userComment = await readUserCommentFromJpeg(imageBytes);

      // 🔥 EXIF에서 메타데이터 파싱 및 복원
      if (userComment != null && userComment.isNotEmpty) {
        final restoredMeta = parsePetgramExif(userComment);
        if (restoredMeta != null) {
          setState(() {
            _currentOriginalMeta = restoredMeta;
          });
          return;
        }
      }
      // 외부 사진이므로 _currentOriginalMeta는 null로 유지
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[FilterPage] ❌ Failed to restore meta from EXIF: $e');
        debugPrint('[FilterPage] ❌ Stack trace: $stackTrace');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 🔥 깜빡임 방지: 이전 이미지가 있으면 로딩 중에도 표시
    //    새로운 이미지 로딩 중에도 이전 이미지를 유지하여 깜빡임 최소화
    final bool hasPreviousImage = _fullPreviewBytes != null;
    final bool shouldShowLoading =
        (_loadingPhase == FilterLoadingPhase.initial ||
            _loadingPhase == FilterLoadingPhase.loading) &&
        !hasPreviousImage; // 이전 이미지가 없을 때만 로딩 UI 표시

    if (shouldShowLoading) {
      return Scaffold(
        appBar: AppBar(
          elevation: 0,
          backgroundColor: const Color(0xFFFFF5F8),
          title: const Text(
            '필터 적용',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
          centerTitle: true,
          iconTheme: const IconThemeData(color: Colors.black87),
          actions: [
            // 상단 우측 로딩 인디케이터 (로딩 중일 때만 표시)
            if (_loadingPhase == FilterLoadingPhase.loading)
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    color: Colors.black87,
                  ),
                ),
              ),
            const SizedBox(width: 8),
          ],
        ),
        backgroundColor: const Color(0xFFFFF5F8),
        body: SafeArea(
          top: true,
          bottom: false,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(strokeWidth: 2.0, color: kMainPink),
                const SizedBox(height: 16),
                const Text(
                  '이미지를 불러오는 중입니다...',
                  style: TextStyle(fontSize: 14, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: Container(
          color: const Color(0xFFFCE4EC),
          child: SafeArea(
            top: false,
            bottom: true,
            child: PetgramBottomNavBar(
              currentTab: PetgramNavTab.shot,
              onShotTap: () {},
              onDiaryTap: () async {
                // 🔥 다른 페이지로 이동 시 카메라 pause
                await _pauseCamera();
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DiaryPage()),
                );
                // 🔥 페이지에서 돌아올 때 카메라 resume
                if (!mounted) return;
                await _resumeCamera();
              },
            ),
          ),
        ),
      );
    }

    // 에러 상태 처리: Flutter 에러 화면 대신 fallback UI 표시
    if (_loadingPhase == FilterLoadingPhase.error) {
      return Scaffold(
        appBar: AppBar(
          elevation: 0,
          backgroundColor: const Color(0xFFFFF5F8),
          title: const Text(
            '필터 적용',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
          centerTitle: true,
          iconTheme: const IconThemeData(color: Colors.black87),
        ),
        backgroundColor: const Color(0xFFFFF5F8),
        body: SafeArea(
          top: true,
          bottom: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    '이미지를 불러오는 중 문제가 발생했습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '다른 사진으로 다시 시도해 주세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () {
                      // 에러 상태 해제하고 다시 시도
                      setState(() {
                        _loadingPhase = FilterLoadingPhase.initial;
                        _fullPreviewBytes = null;
                      });
                      // 초기 이미지 다시 로드 시도 (통합 프리뷰 로딩 파이프라인 사용)
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _startPreviewLoad();
                        }
                      });
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kMainPink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('다시 시도'),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: Container(
          color: const Color(0xFFFCE4EC),
          child: SafeArea(
            top: false,
            bottom: true,
            child: PetgramBottomNavBar(
              currentTab: PetgramNavTab.shot,
              onShotTap: () {
                // 이미 Shot 플로우 안이므로 별도 내비게이션 없음
              },
              onDiaryTap: () async {
                // 🔥 다른 페이지로 이동 시 카메라 pause
                await _pauseCamera();
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DiaryPage()),
                );
                // 🔥 페이지에서 돌아올 때 카메라 resume
                if (!mounted) return;
                await _resumeCamera();
              },
            ),
          ),
        ),
      );
    }

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
          // 상단 우측 로딩 인디케이터 (로딩 중일 때만 표시)
          if (_loadingPhase == FilterLoadingPhase.loading)
            Padding(
              padding: const EdgeInsets.only(right: 12.0),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.0,
                  color: Colors.black87,
                ),
              ),
            ),
          // 새 사진 선택 버튼 (로딩이 완료되었을 때만 활성화)
          if (_loadingPhase == FilterLoadingPhase.ready)
            IconButton(
              icon: const Icon(Icons.photo_library_rounded),
              onPressed: _pickNewImage,
              tooltip: '새 사진 선택',
            ),
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: const Color(0xFFFFF5F8),
      body: SafeArea(top: true, bottom: false, child: _buildBody()),
      bottomNavigationBar: Container(
        color: const Color(0xFFFCE4EC), // SafeArea bottom 포함 전체 백그라운드
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.shot, // 필터 페이지도 Shot 플로우 내부
            onShotTap: () {
              // 이미 Shot 플로우 안이므로 별도 내비게이션 없음
            },
            onDiaryTap: () async {
              // 🔥 다른 페이지로 이동 시 카메라 pause
              await _pauseCamera();
              if (!mounted) return;
              final _ = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DiaryPage()),
              );
              // 🔥 페이지에서 돌아올 때 카메라 resume
              if (!mounted) return;
              await _resumeCamera();
            },
          ),
        ),
      ),
    );
  }

  /// 펫톤 프로파일 가져오기 (HomePage의 _getCurrentPetToneProfile과 동일한 로직)
  PetToneProfile? _getCurrentPetToneProfile() {
    if (widget.selectedPet == null) return null;

    final pet = widget.selectedPet!;
    if (pet.type != 'dog' && pet.type != 'cat') return null;

    String tone = _coatPreset;
    if (tone == 'custom' ||
        (tone != 'light' && tone != 'mid' && tone != 'dark')) {
      tone = 'mid';
    }

    final key = '${pet.type}_$tone';
    return kPetToneProfiles[key];
  }

  /// 현재 필터/밝기/펫 프로필 상태를 FilterConfig로 변환
  FilterConfig _buildCurrentFilterConfig() {
    final petProfile = _getCurrentPetToneProfile();
    return FilterConfig(
      filterKey: _filterKey,
      intensity: _intensity,
      brightness: 0.0, // FilterPage는 editBrightness 사용
      coatPreset: _coatPreset,
      petProfile: petProfile,
      enablePetToneOnSave: true,
      editBrightness: _editBrightness,
      editContrast: _editContrast,
      editSharpness: _editSharpness,
      aspectRatio: null, // FilterPage는 원본 비율 유지
      enableFrame: false, // FilterPage는 프레임 미적용
    );
  }

  /// 펫 전용 보정 프리셋 목록
  static const List<_PetAdjustPreset> _detailPresets = [
    _PetAdjustPreset(
      id: 'basic',
      label: '기본',
      brightness: 0,
      contrast: 0,
      sharpness: 0,
    ),
    _PetAdjustPreset(
      id: 'eye_clear',
      label: '눈 또렷',
      brightness: 5,
      contrast: 20,
      sharpness: 60,
    ),
    _PetAdjustPreset(
      id: 'fur_soft',
      label: '털 보송',
      brightness: 10,
      contrast: -10,
      sharpness: 25,
    ),
    _PetAdjustPreset(
      id: 'dark_fur',
      label: '어두운 털',
      brightness: 20,
      contrast: 5,
      sharpness: 35,
    ),
  ];

  /// 프리셋 적용
  void _applyPreset(_PetAdjustPreset preset) {
    // 🔥 깜빡임 방지: 상태만 업데이트하고 즉시 UI 반영하지 않음
    _selectedPresetId = preset.id;
    _isManualDetailMode = false; // 프리셋 선택 시 수동 모드 해제
    _editBrightness = preset.brightness;
    _editContrast = preset.contrast;
    _editSharpness = preset.sharpness;
    // 🔥 선택 상태만 즉시 업데이트 (이미지는 프리뷰 업데이트 후 반영)
    setState(() {
      // 상태는 이미 업데이트됨, setState는 선택 상태 UI만 업데이트
    });
    debugPrint(
      '[Petgram] 🎨 Detail preset: $_selectedPresetId, '
      'brightness=$_editBrightness, contrast=$_editContrast, sharpness=$_editSharpness',
    );
    _debouncePreviewUpdate();
  }

  /// 이미지 크기 가져오기 (캐시 사용)

  /// FilterPage body 빌드
  /// 초기 로딩 중일 때는 적절한 UI를 표시하고, 프리뷰가 준비되면 기존 UI를 렌더
  /// null-safe 렌더링: preview가 준비되지 않았으면 아무 계산도 하지 않음
  Widget _buildBody() {
    // 프리뷰가 준비되지 않은 경우: null-safe 렌더링
    // build()에서 이미 처리되지만, 안전을 위해 여기서도 체크
    // 🔥 깜빡임 방지: 초기 로딩(_loadingPhase가 initial 또는 loading)일 때만 로딩 UI 표시
    //    필터/펫톤 변경 중에는 이전 이미지를 유지
    if (_currentImagePath.isEmpty ||
        (_fullPreviewBytes == null &&
            _loadingPhase != FilterLoadingPhase.ready)) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(strokeWidth: 2.0, color: kMainPink),
            SizedBox(height: 16),
            Text(
              '이미지를 불러오는 중입니다...',
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
          ],
        ),
      );
    }

    // ✅ 프리뷰가 준비된 이후의 기존 UI
    return LayoutBuilder(
      builder: (context, constraints) {
        // 하단 툴바 높이 (스크롤 여백용)
        const bottomToolbarHeight = 180.0;

        // displayWidth는 한 번만 계산하고 절대 줄이지 않음
        final double horizontalPadding = 16.0;
        final double displayWidth =
            constraints.maxWidth - horizontalPadding * 2;

        // aspectRatio 계산: 프리뷰 비율 우선, 없으면 widget.aspectMode fallback
        double aspectRatio;
        if (_previewAspectRatio != null && _previewAspectRatio! > 0) {
          aspectRatio = _previewAspectRatio!;
        } else {
          // fallback: 기존 aspectMode 로직 (갤러리 로딩되기 전 대비용)
          switch (widget.aspectMode) {
            case AspectRatioMode.oneOne:
              aspectRatio = 1.0;
              break;
            case AspectRatioMode.threeFour:
              aspectRatio = 3 / 4;
              break;
            case AspectRatioMode.nineSixteen:
            default:
              aspectRatio = 9 / 16;
              break;
          }
        }

        // 🔥 화질 개선: 정확한 비율 계산 (scale-up 방지)
        //    displayWidth를 기준으로 aspectRatio에 맞는 높이를 정확히 계산
        //    최소 높이 강제를 제거하여 비율 정확도 보장
        final double previewHeight = displayWidth / aspectRatio;

        return Stack(
          children: [
            // 미리보기 영역: 가로 100% (패딩 제외), 세로 사용 가능한 높이 100%
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      width: displayWidth, // 가로 100% (패딩 제외)
                      height: previewHeight, // 정확한 비율 기반 높이
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: Colors.black, // 배경색: 라운딩 영역이 보이도록
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
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          width: displayWidth,
                          height: previewHeight,
                          child: _buildZoomablePreview(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: bottomToolbarHeight + 32,
                  ), // 툴바 높이 + 여유 마진 (스크롤 가능 영역)
                ],
              ),
            ),
            // [UI 개편] 하단 아이콘 바
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomToolbar(),
            ),
            // [UI 개편] 슬라이딩 조정 패널
            if (_activeAdjustment != null)
              Positioned.fill(
                child: GestureDetector(
                  // 외부 클릭 시 패널 닫기
                  onTap: () async {
                    // 🔥 패널 닫을 때 카메라 resume
                    await _resumeCamera();
                    setState(() {
                      _activeAdjustment = null;
                    });
                  },
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.3),
                    child: _buildAdjustmentPanel(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 미리보기 영역: 선택된 필터 + 강도 + 펫 전용 보정 적용
  /// @deprecated _buildImageView()를 사용하세요 (2단계 로딩 지원)

  /// 슬라이더 행 위젯
  Widget _buildSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    Color? textColor, // [UI 개편] 패널 내부에서 흰색 텍스트 사용
  }) {
    final Color labelColor = textColor ?? Colors.black87;
    final Color valueColor = textColor ?? Colors.grey;

    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label, style: TextStyle(fontSize: 12, color: labelColor)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
            activeColor: kMainPink,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 11, color: valueColor),
          ),
        ),
      ],
    );
  }

  // [UI 개편] 하단 아이콘 바
  Widget _buildBottomToolbar() {
    return Container(
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 아이콘 버튼들 (간소화: 필터+강도, 펫톤+보정, 리셋)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildToolbarIconButton(
                  icon: Icons.photo_filter,
                  label: '필터',
                  type: AdjustmentType.filterAndIntensity,
                ),
                _buildToolbarIconButton(
                  icon: Icons.pets,
                  label: '펫톤',
                  type: AdjustmentType.petToneAndAdjust,
                ),
                _buildToolbarIconButton(
                  icon: Icons.refresh,
                  label: '리셋',
                  type: null, // 리셋은 특별 처리
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 저장 버튼
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loadingState == FilterLoadingState.saving
                    ? null
                    : _onSavePressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kMainPink,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text(
                  '이 사진으로 저장하기',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // [UI 개편] 선택 상태 레이블 가져오기
  String _getSelectionLabel(AdjustmentType type) {
    if (type == AdjustmentType.filterAndIntensity) {
      final currentFilter = allFilters[_filterKey] ?? allFilters['basic_none']!;
      if (currentFilter.key != 'basic_none') {
        return currentFilter.label;
      }
      return '';
    } else if (type == AdjustmentType.petToneAndAdjust) {
      // 기본 프리셋이고 값이 모두 0인 경우는 표시하지 않음
      if (_selectedPresetId == 'basic' &&
          _editBrightness == 0.0 &&
          _editContrast == 0.0 &&
          _editSharpness == 0.0 &&
          !_isManualDetailMode) {
        return '';
      }

      // 현재 값이 프리셋 중 하나와 일치하는지 확인
      bool matchesPreset = false;
      String? matchingPresetId;
      for (final preset in _detailPresets) {
        if (preset.brightness == _editBrightness &&
            preset.contrast == _editContrast &&
            preset.sharpness == _editSharpness) {
          matchesPreset = true;
          matchingPresetId = preset.id;
          break;
        }
      }

      // 수동 모드이거나 커스텀이거나 프리셋과 일치하지 않으면 "수동 설정" 표시
      if (_isManualDetailMode ||
          _selectedPresetId == 'custom' ||
          !matchesPreset) {
        return '수동 설정';
      }

      // 프리셋이 선택된 경우
      final preset = _detailPresets.firstWhere(
        (p) => p.id == (matchingPresetId ?? _selectedPresetId),
        orElse: () => _detailPresets.first,
      );
      return preset.label;
    }
    return '';
  }

  // [UI 개편] 아이콘 버튼 위젯
  Widget _buildToolbarIconButton({
    required IconData icon,
    required String label,
    required AdjustmentType? type,
  }) {
    final bool isActive = _activeAdjustment == type;

    // [선택 표시] 필터나 펫톤이 선택되었는지 확인
    bool hasSelection = false;
    if (type == AdjustmentType.filterAndIntensity) {
      // 필터가 선택되었는지 확인 (basic_none이 아닌 경우)
      final currentFilter = allFilters[_filterKey] ?? allFilters['basic_none']!;
      hasSelection = currentFilter.key != 'basic_none';
    } else if (type == AdjustmentType.petToneAndAdjust) {
      // 펫톤 프리셋이 선택되었는지 확인
      hasSelection =
          _selectedPresetId != 'basic' ||
          _editBrightness != 0.0 ||
          _editContrast != 0.0 ||
          _editSharpness != 0.0 ||
          _isManualDetailMode;
    }

    return GestureDetector(
      onTap: () {
        if (type == null) {
          // 리셋 버튼 - 필터와 펫톤 모두 리셋
          setState(() {
            // 필터 리셋
            _filterKey = 'basic_none';
            _intensity = 0.8;
            // 펫톤 리셋
            _editBrightness = 0.0;
            _editContrast = 0.0;
            _editSharpness = 0.0;
            _coatPreset = 'mid';
            _selectedPresetId = 'basic';
            _isManualDetailMode = false;
            if (_detailPresets.isNotEmpty) {
              _applyPreset(_detailPresets.first);
            }
            _activeAdjustment = null;
          });
          // 🔥 패널 닫을 때 카메라 resume
          unawaited(_resumeCamera());
          _debouncePreviewUpdate();
        } else {
          // 같은 버튼 다시 누르면 패널 닫힘
          final newValue = isActive ? null : type;
          setState(() {
            _activeAdjustment = newValue;
          });
          // 🔥 패널 열릴 때 카메라 pause, 닫힐 때 resume
          if (newValue != null) {
            unawaited(_pauseCamera());
          } else {
            unawaited(_resumeCamera());
          }
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isActive ? kMainPink : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: isActive ? Colors.white : Colors.black87,
                  size: 24,
                ),
              ),
              // [선택 표시] 선택된 경우 작은 점 표시
              if (hasSelection && !isActive)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: kMainPink,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isActive
                      ? kMainPink
                      : (hasSelection
                            ? kMainPink.withValues(alpha: 0.7)
                            : Colors.black54),
                  fontWeight: isActive || hasSelection
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
              // 선택된 필터/펫톤 정보 표시 (가독성 개선)
              if (hasSelection && !isActive)
                Container(
                  margin: const EdgeInsets.only(top: 3),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: kMainPink.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _getSelectionLabel(type!),
                    style: TextStyle(
                      fontSize: 9,
                      color: kMainPink,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // [UI 개편] 슬라이딩 조정 패널
  Widget _buildAdjustmentPanel() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.only(bottom: 72),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더 (제목 + X 버튼)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _getAdjustmentTitle(_activeAdjustment!),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () async {
                    // 🔥 패널 닫을 때 카메라 resume
                    await _resumeCamera();
                    setState(() {
                      _activeAdjustment = null;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 패널 본문
            _buildAdjustmentPanelBody(),
          ],
        ),
      ),
    );
  }

  // [UI 개편] 패널 본문 (타입별 분기)
  Widget _buildAdjustmentPanelBody() {
    switch (_activeAdjustment!) {
      case AdjustmentType.filterAndIntensity:
        return _buildFilterAndIntensityPanel();
      case AdjustmentType.petToneAndAdjust:
        return _buildPetToneAndAdjustPanel();
    }
  }

  // [UI 개편] 조정 타입별 제목
  String _getAdjustmentTitle(AdjustmentType type) {
    switch (type) {
      case AdjustmentType.filterAndIntensity:
        return '필터 & 강도';
      case AdjustmentType.petToneAndAdjust:
        return '펫톤 & 보정';
    }
  }

  // [UI 간소화] 필터 + 강도 패널
  Widget _buildFilterAndIntensityPanel() {
    final fallback =
        filtersByCategory['basic'] ?? <PetFilter>[allFilters['basic_none']!];
    final filters = filtersByCategory[_category] ?? fallback;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 카테고리 탭 (패널 내부용 스타일)
        _buildCategoryTabsForPanel(),
        const SizedBox(height: 12),
        // 필터 버튼들 (패널 내부용 스타일)
        SizedBox(height: 60, child: _buildFilterButtonsForPanel(filters)),
        const SizedBox(height: 16),
        // 필터 강도 슬라이더
        _buildFilterIntensitySlider(),
      ],
    );
  }

  // [UI 간소화] 패널 내부용 카테고리 탭 (흰색 텍스트)
  Widget _buildCategoryTabsForPanel() {
    final tabs = <_FilterCategoryTab>[
      const _FilterCategoryTab(keyValue: 'basic', label: '기본'),
      const _FilterCategoryTab(keyValue: 'pink', label: 'Pink'),
      const _FilterCategoryTab(keyValue: 'dog', label: 'Dog'),
      const _FilterCategoryTab(keyValue: 'cat', label: 'Cat'),
    ];

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: tabs.map((t) {
          final bool selected = _category == t.keyValue;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                setState(() {
                  _category = t.keyValue;
                  final list = filtersByCategory[_category];
                  if (list != null && list.isNotEmpty) {
                    final hasCurrentFilter = list.any(
                      (f) => f.key == _filterKey,
                    );
                    if (!hasCurrentFilter) {
                      _filterKey = list.first.key;
                    }
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
                  color: selected
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Center(
                  child: Text(
                    t.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: Colors.white,
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

  // [UI 간소화] 패널 내부용 필터 버튼들 (흰색 텍스트)
  Widget _buildFilterButtonsForPanel(List<PetFilter> filters) {
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
              // 🔥 깜빡임 방지: 필터 키만 업데이트하고 즉시 UI 반영하지 않음
              //    프리뷰 업데이트는 _debouncePreviewUpdate에서 처리
              _filterKey = f.key;
              // 🔥 선택 상태만 즉시 업데이트 (이미지는 프리뷰 업데이트 후 반영)
              setState(() {
                // 필터 키는 이미 업데이트됨, setState는 선택 상태 UI만 업데이트
              });
              _debouncePreviewUpdate();
            },
            child: AnimatedContainer(
              key: ValueKey('filter_${f.key}_${selected}'),
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
                color: selected ? null : Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : Colors.white.withValues(alpha: 0.3),
                  width: selected ? 0 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 썸네일 이미지 또는 아이콘 표시
                  _buildFilterThumbnailOrIcon(f.key, f.icon, selected),
                  const SizedBox(height: 2),
                  Text(
                    f.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 필터 썸네일 또는 아이콘 표시
  /// 🔥 수정: 항상 아이콘만 사용 (기존 방식으로 복원)
  Widget _buildFilterThumbnailOrIcon(
    String filterKey,
    IconData icon,
    bool selected,
  ) {
    // 항상 아이콘만 표시 (선택된 사진으로 썸네일 생성하지 않음)
    return Icon(icon, size: 24, color: Colors.white);
  }

  // [UI 간소화] 펫톤 + 보정 패널
  Widget _buildPetToneAndAdjustPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 펫톤 프리셋 섹션 (프리셋 모드일 때만 표시)
        if (!_isManualDetailMode) ...[_buildPetTonePresetSection()],
        // 밝기/대비/선명 슬라이더 (수동 모드일 때만 표시)
        if (_isManualDetailMode) ...[
          _buildBrightnessSlider(),
          const SizedBox(height: 8),
          _buildContrastSlider(),
          const SizedBox(height: 8),
          _buildSharpnessSlider(),
        ],
        // 모드 전환 버튼 (하단에 통일)
        const SizedBox(height: 12),
        _buildPetToneModeToggle(),
      ],
    );
  }

  // [UI 간소화] 펫톤 프리셋 섹션 (4가지: 기본, 눈또렷, 털 보송, 어두운 털)
  Widget _buildPetTonePresetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 4가지 프리셋 칩 (선택 표시 개선) - 타이틀 제거
        SizedBox(
          height: 44,
          child: Row(
            children: _detailPresets.map((preset) {
              final bool selected =
                  _selectedPresetId == preset.id && !_isManualDetailMode;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: preset.id != _detailPresets.last.id ? 8 : 0,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      _applyPreset(preset);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        // 선택된 경우: 핑크 그라데이션 배경 + 두꺼운 테두리
                        // 선택되지 않은 경우: 반투명 배경 + 얇은 테두리
                        gradient: selected
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  kMainPink,
                                  kMainPink.withValues(alpha: 0.85),
                                ],
                              )
                            : null,
                        color: selected
                            ? null
                            : Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? kMainPink.withValues(alpha: 1.0) // 선택 시 핑크 테두리
                              : Colors.white.withValues(alpha: 0.4),
                          width: selected ? 2 : 1, // 선택 시 더 두꺼운 테두리
                        ),
                        // 선택된 경우 그림자 추가
                        boxShadow: selected
                            ? [
                                BoxShadow(
                                  color: kMainPink.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 선택된 경우 체크 아이콘 표시
                          if (selected) ...[
                            Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            preset.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // 펫톤 프리셋/수동 전환 버튼 (작고 간결한 형태)
  Widget _buildPetToneModeToggle() {
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _isManualDetailMode = !_isManualDetailMode;
            if (!_isManualDetailMode && _selectedPresetId == 'custom') {
              // 수동 모드에서 프리셋 모드로 전환 시 기본 프리셋 적용
              if (_detailPresets.isNotEmpty) {
                _applyPreset(_detailPresets.first);
              }
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isManualDetailMode ? Icons.auto_awesome : Icons.tune,
                size: 14,
                color: Colors.white.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 4),
              Text(
                _isManualDetailMode ? '프리셋' : '수동 설정',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // [UI 개편] 밝기 슬라이더
  Widget _buildBrightnessSlider() {
    return _buildSliderRow(
      label: '밝기',
      value: _editBrightness,
      min: -50,
      max: 50,
      onChanged: (v) {
        setState(() {
          _editBrightness = v;
          _selectedPresetId = 'custom';
          _isManualDetailMode = true;
        });
        _debouncePreviewUpdate();
      },
      textColor: Colors.white, // 패널 내부에서 흰색 텍스트 사용
    );
  }

  // [UI 개편] 대비 슬라이더
  Widget _buildContrastSlider() {
    return _buildSliderRow(
      label: '대비',
      value: _editContrast,
      min: -50,
      max: 50,
      onChanged: (v) {
        setState(() {
          _editContrast = v;
          _selectedPresetId = 'custom';
          _isManualDetailMode = true;
        });
        _debouncePreviewUpdate();
      },
      textColor: Colors.white, // 패널 내부에서 흰색 텍스트 사용
    );
  }

  // [UI 개편] 선명도 슬라이더
  Widget _buildSharpnessSlider() {
    return _buildSliderRow(
      label: '선명도',
      value: _editSharpness,
      min: 0,
      max: 100,
      onChanged: (v) {
        setState(() {
          _editSharpness = v;
          _selectedPresetId = 'custom';
          _isManualDetailMode = true;
        });
        _debouncePreviewUpdate();
      },
      textColor: Colors.white, // 패널 내부에서 흰색 텍스트 사용
    );
  }

  // [UI 개편] 필터 강도 슬라이더
  Widget _buildFilterIntensitySlider() {
    final PetFilter current =
        allFilters[_filterKey] ?? allFilters['basic_none']!;
    final bool isBasicNone = current.key == 'basic_none';

    return Opacity(
      opacity: isBasicNone ? 0.4 : 1.0,
      child: IgnorePointer(
        ignoring: isBasicNone,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: kMainPink,
            inactiveTrackColor: Colors.grey[300],
            thumbColor: kMainPink,
            overlayColor: kMainPink.withValues(alpha: 0.2),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
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
              _debouncePreviewUpdate();
            },
          ),
        ),
      ),
    );
  }

  /// 원본 이미지를 다시 로딩하여 필터 및 보정 처리 후 저장
  /// UI 프리뷰용 축소본이 아닌 원본 파일을 사용하여 고해상도 저장
  /// 9:16 비율 이미지는 중앙 crop으로 9:16 강제 적용
  Future<void> _onSavePressed() async {
    if (_loadingState == FilterLoadingState.saving) return;

    setState(() {
      _loadingState = FilterLoadingState.saving;
    });

    File? processedTempFile;
    // ⚠️ 중요: ui.Image 기반 처리는 저장 파이프라인에서 완전히 제거됨
    //          네이티브 renderFullSize만 사용하므로 ui.Image dispose 불필요

    try {
      // ========================================
      // 저장 파이프라인: 원본 이미지만 사용 (preview 이미지 절대 사용 금지)
      // ========================================

      // 1. _currentImagePath 사용 (정규화된 경로)
      // 중요: _currentImagePath는 EXIF 정규화가 완료된 경로이므로 항상 이 경로 사용
      // widget.imageFile은 생성자에서 받은 초기값이므로 사용하지 않음
      final originalFile = File(_currentImagePath);

      if (kDebugMode) {
        debugPrint(
          '[FilterPage] 💾 save pressed for sourcePath=${originalFile.path}',
        );
      }

      if (!originalFile.existsSync()) {
        throw Exception('원본 이미지 파일을 찾을 수 없습니다: ${originalFile.path}');
      }

      if (kDebugMode) {
        debugPrint('[FilterPage] 📸 원본 이미지 경로: ${originalFile.path}');
      }

      // ⚠️ 중요: Dart에서 full-resolution 이미지 디코딩 금지
      //          iOS 네이티브에서만 full-res 이미지를 로드하고 처리
      //          원본 파일 경로만 전달하여 네이티브에서 처리하도록 함

      // iOS 네이티브 필터 파이프라인 사용 (CoreImage + Metal)
      // ⚠️ 중요: renderFullSize는 원본 파일 경로를 받아서 센서 해상도 기준으로 처리
      //          iOS 네이티브 FilterPipeline.swift에서 full-res 이미지를 로드하고 처리
      final config = _buildCurrentFilterConfig();

      // ⚠️ 중요: 네이티브 renderFullSize만 사용 (previewImage, previewBytes, ui.Image 사용 금지)
      //          iOS 네이티브에서 full-resolution CIImage + filter + composite + JPEG encode 수행
      //          저장은 반드시 "원본 파일 → 네이티브 full-res 렌더" 경로만 타도록 강제
      final jpegBytes = await _nativeFilterService.renderFullSize(
        originalFile.path, // ⚠️ 원본 파일 경로 전달 (full-res 이미지)
        config,
        null, // FilterPage는 원본 비율 유지
      );

      // 🔥 jpegBytes 유효성 검사
      if (jpegBytes.isEmpty) {
        throw Exception('renderFullSize가 빈 바이트를 반환했습니다.');
      }

      // JPEG 바이트를 임시 파일로 저장
      final dir = await getTemporaryDirectory();
      final saveTimestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'petgram_edit_$saveTimestamp.jpg';
      final filePath = '${dir.path}/$filename';
      processedTempFile = File(filePath);
      await processedTempFile.writeAsBytes(jpegBytes, flush: true);

      // ⚠️ 중요: 저장은 renderFullSize에서 반환된 jpegBytes만 사용
      //          processedTempFile에서 읽은 finalImageBytes는 검증용으로만 사용
      //          프리뷰/캡쳐 데이터(_fullPreviewBytes, _previewImage)는 절대 사용하지 않음
      final finalImageBytes = await processedTempFile.readAsBytes();
      if (finalImageBytes.isEmpty) {
        throw Exception('최종 이미지 바이트가 비어있습니다.');
      }

      // ⚠️ 검증: jpegBytes와 finalImageBytes가 동일한지 확인
      if (jpegBytes.length != finalImageBytes.length) {
        debugPrint(
          '[FilterPage] ⚠️ WARNING: jpegBytes.length (${jpegBytes.length}) != finalImageBytes.length (${finalImageBytes.length})',
        );
      }

      // 🔥 보정 저장용 메타데이터 생성
      // ⚠️ 중요: originalImageBytes는 메타데이터 생성에만 사용 (저장에 사용하지 않음)
      //          실제 저장은 renderFullSize 결과(jpegBytes)만 사용
      final originalImageBytes = await originalFile.readAsBytes();

      // 🔥 원본 메타데이터 우선 사용 (DB/EXIF에서 복원한 것 또는 widget에서 전달받은 것)
      final originalMeta = _currentOriginalMeta ?? widget.originalMeta;

      // 🔥 buildMetaForFilterSave는 이미 originalMeta를 받아서 isPetgramEdited=true로 설정함
      //    원본 메타데이터의 모든 정보(프레임, 펫 정보 등)를 유지하면서 편집 표시만 추가
      final meta = await buildMetaForFilterSave(
        originalJpegBytes: originalImageBytes,
        originalMeta: originalMeta, // 원본 메타데이터 전달 (프레임 정보 포함)
      );

      // EXIF 메타데이터 추가
      // ⚠️ 중요: jpegBytes (renderFullSize 결과)에 메타데이터 추가
      //          finalImageBytes는 검증용으로만 사용
      final finalImageBytesWithMeta = await attachPetgramExif(
        jpegBytes: jpegBytes, // ⚠️ renderFullSize 결과 사용 (프리뷰 아님)
        exifTag: meta.toExifTag(), // 🔥 보정된 메타데이터 사용 (프레임 정보 포함)
      );

      // 🔥 finalImageBytesWithMeta 유효성 검사
      if (finalImageBytesWithMeta.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[FilterPage] [SAVE] ⚠️ WARNING: finalImageBytesWithMeta is empty! Using original jpegBytes.',
          );
        }
        throw Exception('EXIF 메타데이터 추가 후 이미지 바이트가 비어있습니다.');
      }

      // 🔥 파일명 생성: 사진 찍을 때와 동일한 방식 (타임스탬프 기반)
      //    보정 후 저장 시 새로운 파일이 1개 생기므로 새로운 파일명 사용
      final fileName = 'PG_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // 🔥 갤러리에 저장 (에러 처리 강화)
      try {
        await Gal.putImageBytes(finalImageBytesWithMeta, name: fileName);
      } catch (e, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            '[FilterPage] [SAVE] ❌ Failed to save image to gallery: $e',
          );
          debugPrint('[FilterPage] [SAVE] ❌ Stack trace: $stackTrace');
        }
        rethrow; // 저장 실패 시 예외 재발생
      }

      // 🔥 DB에 메타데이터 기록: 새로운 사진을 찍은 것과 동일하게 처리
      //    보정 후 저장 시 새로운 파일이 1개 생기므로 새로운 레코드로 저장
      //    isPetgramEdited=true로 설정하여 보정된 사진임을 표시
      try {
        // 🔥 항상 새 레코드로 저장 (사진 찍을 때와 동일)
        //    타임스탬프 기반 파일명이므로 중복 가능성 없음
        await PetgramPhotoRepository.instance.upsertPhotoRecord(
          filePath: fileName, // 새로운 파일명 (타임스탬프 기반)
          meta: meta, // 🔥 보정된 메타데이터 (isPetgramEdited=true, 프레임 정보 포함)
          exifTag: meta.toExifTag(),
        );
      } catch (dbError) {
        // DB 저장 실패해도 사진 저장은 성공으로 처리
        if (kDebugMode) {
          debugPrint(
            '[FilterPage] [SAVE] ⚠️ Failed to save photo record to DB: $dbError',
          );
        }
      }

      // 저장 성공 피드백
      HapticFeedback.mediumImpact();

      if (!mounted) return;

      // 성공 메시지 표시
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('필터가 적용된 사진이 갤러리에 저장되었어요! 📸'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('[FilterPage] ❌ 원본 이미지 기반 저장 오류: $e');
      debugPrint('[FilterPage] ❌ Stack trace: $stackTrace');
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
      } else if (e.toString().contains('디코딩') ||
          e.toString().contains('decode')) {
        errorMessage = '이미지를 불러오는 중 오류가 발생했어요. 다시 시도해주세요.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      // ⚠️ 중요: ui.Image 기반 처리는 저장 파이프라인에서 완전히 제거됨
      //          네이티브 renderFullSize만 사용하므로 ui.Image dispose 불필요

      // 임시 파일 삭제
      if (processedTempFile != null) {
        try {
          if (await processedTempFile.exists()) {
            await processedTempFile.delete();
          }
        } catch (e) {
          debugPrint('[FilterPage] ⚠️ 임시 파일 삭제 실패: $e');
        }
      }

      if (mounted) {
        setState(() {
          _loadingState = FilterLoadingState.idle;
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

/// 그리드라인 및 프레임 Painter는 widgets/painters/로 분리됨

/// ========================
///  새로운 프레임 시스템
/// ========================
/// (프레임 관련 클래스들은 widgets/painters/ 및 services/로 분리됨)

// FilterPage dispose 메서드 추가
