import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/constants.dart';
import '../models/one_line_diary_entry.dart';
import '../models/petgram_nav_tab.dart';
import '../services/one_line_diary_service.dart';
import '../services/petgram_media_ref_service.dart';
import '../widgets/petgram_bottom_nav_bar.dart';
import 'backup_page.dart';

enum _SortType { newest, oldest }

enum _DiaryViewMode { list, grid }

class DiaryPage extends StatefulWidget {
  const DiaryPage({super.key});

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  static const MethodChannel _cameraChannel = MethodChannel(
    'petgram/camera_control',
  );
  static const Color _accent = Color(0xFFE58FAA);
  static const Color _accentDeep = Color(0xFF9E5A71);
  static const Color _lineSoft = Color(0xFFF1D8E2);
  static const int _pageSize = 30;
  static const double _loadMoreThreshold = 360;
  static const bool _enableDiaryPerfLog = false;
  static const String _quickTagUserKey = 'diary_quick_tags_user_v1';
  static const int _maxUserQuickTags = 30;
  static const List<String> _defaultQuickTagsSeed = <String>[
    '산책',
    '놀이',
    '간식',
    '낮잠',
    '추억',
    '행복',
  ];

  bool _loading = true;
  bool _isLoadingMore = false;
  bool _isDeletingOriginalPhoto = false;
  bool _hasMore = true;
  int _nextOffset = 0;
  _SortType _sortType = _SortType.newest;
  _DiaryViewMode _viewMode = _DiaryViewMode.list;
  bool _showHidden = false;
  String? _selectedMonthKey;
  String _selectedPetKey = 'all';
  String _selectedTagKey = 'all';
  List<OneLineDiaryEntry> _entries = const <OneLineDiaryEntry>[];
  final ScrollController _scrollController = ScrollController();
  final Map<String, Future<AssetEntity?>> _assetFutureCache =
      <String, Future<AssetEntity?>>{};
  final Map<String, Future<File?>> _displayFileFutureCache =
      <String, Future<File?>>{};
  final Map<String, File?> _resolvedDisplayFileCache = <String, File?>{};
  final Map<String, double> _entryAspectRatioCache = <String, double>{};
  List<OneLineDiaryEntry>? _cacheMonthCountsEntries;
  Map<String, int>? _cacheMonthCounts;
  Map<String, int>? _cacheMonthKeysSource;
  List<String>? _cacheMonthKeysSorted;
  List<OneLineDiaryEntry>? _cacheMonthScopedSource;
  String? _cacheMonthScopedKey;
  List<OneLineDiaryEntry>? _cacheMonthScopedEntries;
  List<OneLineDiaryEntry>? _cachePetCountsSource;
  Map<String, int>? _cachePetCounts;
  Map<String, int>? _cachePetKeysSource;
  List<String>? _cachePetKeysSorted;
  List<OneLineDiaryEntry>? _cachePetScopedSource;
  String? _cachePetScopedKey;
  List<OneLineDiaryEntry>? _cachePetScopedEntries;
  List<OneLineDiaryEntry>? _cacheTagCountsSource;
  Map<String, int>? _cacheTagCounts;
  Map<String, int>? _cacheTagPopularitySource;
  List<String>? _cacheTagKeysByPopularity;
  List<OneLineDiaryEntry>? _cacheFilteredSource;
  Map<String, int>? _cacheFilteredTagCountsSource;
  String? _cacheFilteredSelectedTag;
  _SortType? _cacheFilteredSortType;
  List<OneLineDiaryEntry>? _cacheFilteredEntries;

  static List<OneLineDiaryEntry>? _entryCache;
  static DateTime? _cacheAt;
  static bool? _cacheHasMore;
  static int? _cacheNextOffset;
  static const Duration _cacheTtl = Duration(minutes: 3);
  static final Map<String, double> _globalAspectRatioCache = <String, double>{};
  bool _cameraPausedByDiary = false;
  final Stopwatch _pageStopwatch = Stopwatch();
  int _loadRequestSeq = 0;
  bool _didLogFirstContent = false;
  int _lastLoadMoreTriggerMs = 0;
  Map<String, int> _petAgeByName = const <String, int>{};
  bool _didRunSilentExistenceValidation = false;
  List<String> _userQuickTags = <String>[];

  void _logPerf(String Function() messageBuilder) {
    if (!_enableDiaryPerfLog) return;
    debugPrint('[DiaryPerf] ${messageBuilder()}');
  }

  @override
  void initState() {
    super.initState();
    _pageStopwatch.start();
    _logPerf(() => 'initState');
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logPerf(
        () => 'first_frame ready: ${_pageStopwatch.elapsedMilliseconds}ms',
      );
      unawaited(_pauseCameraSafely());
      unawaited(_loadPetAgeMap());
      unawaited(_loadQuickTagPrefs());
      // 캐시/기존 데이터 우선 표시 (진입 지연 최소화)
      unawaited(_loadEntries(forceRefresh: false));
    });
  }

  Future<void> _loadPetAgeMap() async {
    try {
      final pets = await OneLineDiaryService.instance.loadRegisteredPets();
      if (!mounted) return;
      final map = <String, int>{};
      for (final pet in pets) {
        final name = pet.name.trim();
        if (name.isEmpty) continue;
        map[name] = pet.getAge();
      }
      setState(() {
        _petAgeByName = map;
      });
    } catch (_) {}
  }

  Future<void> _pauseCameraSafely() async {
    final sw = Stopwatch()..start();
    try {
      await _cameraChannel.invokeMethod('pauseCamera');
      _cameraPausedByDiary = true;
      _logPerf(() => 'pauseCamera success: ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      _logPerf(() => 'pauseCamera failed: ${sw.elapsedMilliseconds}ms, $e');
    }
  }

  Future<void> _resumeCameraSafely() async {
    if (!_cameraPausedByDiary) return;
    final sw = Stopwatch()..start();
    try {
      await _cameraChannel
          .invokeMethod('resumeCamera')
          .timeout(const Duration(milliseconds: 900));
      _logPerf(() => 'resumeCamera success: ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      _logPerf(() => 'resumeCamera failed: ${sw.elapsedMilliseconds}ms, $e');
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    unawaited(_resumeCameraSafely());
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_loading || _isLoadingMore || !_hasMore) return;
    final position = _scrollController.position;
    if (position.pixels + _loadMoreThreshold >= position.maxScrollExtent) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastLoadMoreTriggerMs < 250) return;
      _lastLoadMoreTriggerMs = nowMs;
      unawaited(
        _loadEntries(
          append: true,
          showLoadingIndicator: false,
          validateExistence: false,
        ),
      );
    }
  }

  Future<void> _loadEntries({
    bool forceRefresh = false,
    bool append = false,
    bool showLoadingIndicator = true,
    bool? validateExistence,
    bool skipCache = false,
  }) async {
    if (append && (_loading || _isLoadingMore || !_hasMore)) return;

    final requestId = ++_loadRequestSeq;
    final sw = Stopwatch()..start();
    _logPerf(
      () =>
          'load#$requestId start: forceRefresh=$forceRefresh, append=$append, '
          'showLoading=$showLoadingIndicator, validate=${validateExistence ?? forceRefresh}, '
          'skipCache=$skipCache, offset=${append ? _nextOffset : 0}',
    );

    if (forceRefresh) {
      _assetFutureCache.clear();
      _displayFileFutureCache.clear();
      _resolvedDisplayFileCache.clear();
      _entryAspectRatioCache.clear();
      _hasMore = true;
      _nextOffset = 0;
      _didRunSilentExistenceValidation = false;
    }

    final cacheValid =
        !skipCache &&
        !forceRefresh &&
        !append &&
        _entryCache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _cacheTtl;
    if (cacheValid) {
      setState(() {
        _loading = false;
        _entries = _entryCache!;
        _hasMore = _cacheHasMore ?? (_entries.length == _pageSize);
        _nextOffset = _cacheNextOffset ?? _entries.length;
      });
      _logPerf(
        () =>
            'load#$requestId cache-hit: ${sw.elapsedMilliseconds}ms, entries=${_entries.length}',
      );
      _syncDefaultMonthSelection();
      // 캐시를 즉시 보여주되, 백그라운드에서 최신 DB를 한 번 더 당겨
      // 신규 촬영 사진이 누락되지 않도록 동기화한다.
      unawaited(
        _loadEntries(
          forceRefresh: false,
          append: false,
          showLoadingIndicator: false,
          validateExistence: true,
          skipCache: true,
        ),
      );
      return;
    }

    if (append) {
      setState(() {
        _isLoadingMore = true;
      });
    } else if (showLoadingIndicator) {
      setState(() {
        _loading = true;
      });
    }

    final currentOffset = append ? _nextOffset : 0;
    final shouldValidate = validateExistence ?? forceRefresh;
    List<OneLineDiaryEntry> entries;
    try {
      entries = await OneLineDiaryService.instance
          .loadRecentEntries(
            limit: _pageSize,
            offset: currentOffset,
            includeHidden: _showHidden,
            validateExistence: shouldValidate,
          )
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // 수동 새로고침(삭제 검증 포함) 타임아웃 시,
      // 최신 촬영분 반영을 위해 검증 없는 빠른 재조회로 한 번 더 시도한다.
      if (forceRefresh && !append) {
        try {
          final fastEntries = await OneLineDiaryService.instance
              .loadRecentEntries(
                limit: _pageSize,
                offset: 0,
                includeHidden: _showHidden,
                validateExistence: false,
              )
              .timeout(const Duration(seconds: 3));
          if (!mounted) return;
          setState(() {
            _loading = false;
            _isLoadingMore = false;
            _entries = fastEntries;
            _hasMore = fastEntries.length == _pageSize;
            _nextOffset = fastEntries.length;
          });
          _entryCache = fastEntries;
          _cacheAt = DateTime.now();
          _cacheHasMore = _hasMore;
          _cacheNextOffset = _nextOffset;
          _syncDefaultMonthSelection();
          _logPerf(
            () =>
                'load#$requestId timeout-fallback success: ${sw.elapsedMilliseconds}ms, '
                'entries=${fastEntries.length}',
          );
          return;
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _loading = false;
        _isLoadingMore = false;
        // 타임아웃 시에도 기존/캐시 데이터는 유지
        if (!append && _entryCache != null && _entryCache!.isNotEmpty) {
          _entries = _entryCache!;
        }
      });
      if (showLoadingIndicator && !append) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('한줄 일기 로딩이 지연되어 기존 목록을 먼저 보여줍니다.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _isLoadingMore = false;
        if (!append && _entryCache != null && _entryCache!.isNotEmpty) {
          _entries = _entryCache!;
        }
      });
      if (showLoadingIndicator && !append) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('한줄 일기 로딩 중 오류가 발생했습니다: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (!mounted) return;

    final mergedEntries = append
        ? () {
            final existingIds = _entries
                .map((e) => e.id)
                .whereType<String>()
                .toSet();
            final dedupedIncoming = entries.where((incoming) {
              final id = incoming.id;
              if (existingIds.contains(id)) return false;
              existingIds.add(id);
              return true;
            });
            return <OneLineDiaryEntry>[..._entries, ...dedupedIncoming];
          }()
        : entries;
    final hasMore = entries.length == _pageSize;
    final nextOffset = mergedEntries.length;

    setState(() {
      _loading = false;
      _isLoadingMore = false;
      _entries = mergedEntries;
      _hasMore = hasMore;
      _nextOffset = nextOffset;
    });
    unawaited(_warmupVisibleThumbnails(mergedEntries));
    _entryCache = mergedEntries;
    _cacheAt = DateTime.now();
    _cacheHasMore = hasMore;
    _cacheNextOffset = nextOffset;
    _syncDefaultMonthSelection();
    if (!append && !shouldValidate && !_didRunSilentExistenceValidation) {
      _didRunSilentExistenceValidation = true;
      unawaited(
        _loadEntries(
          forceRefresh: false,
          append: false,
          showLoadingIndicator: false,
          validateExistence: true,
          skipCache: true,
        ),
      );
    }
    _logPerf(
      () =>
          'load#$requestId done: ${sw.elapsedMilliseconds}ms, '
          'entries=${mergedEntries.length}, hasMore=$hasMore, append=$append',
    );
    if (!_didLogFirstContent && mergedEntries.isNotEmpty) {
      _didLogFirstContent = true;
      _logPerf(
        () =>
            'first_content_ready: ${_pageStopwatch.elapsedMilliseconds}ms '
            '(count=${mergedEntries.length})',
      );
    }
    if (_enableDiaryPerfLog) {
      debugPrint(
        '[OneLineDiary] load complete: page=${append ? 'append' : 'initial'}, entries=${mergedEntries.length}, hasMore=$hasMore, top=${mergedEntries.isNotEmpty ? mergedEntries.first.filePath : 'none'}',
      );
    }
  }

  String _monthKey(DateTime date) {
    final m = date.month.toString().padLeft(2, '0');
    return '${date.year}-$m';
  }

  String _monthLabel(String key) {
    final parts = key.split('-');
    if (parts.length != 2) return key;
    final year = parts[0];
    final month = int.tryParse(parts[1]) ?? 0;
    return '$year년 $month월';
  }

  String _petKeyOf(OneLineDiaryEntry entry) {
    final name = entry.petName?.trim();
    if (name == null || name.isEmpty) return '이름없음';
    return name;
  }

  void _syncDefaultMonthSelection() {
    if (_entries.isEmpty) {
      _selectedMonthKey = null;
      return;
    }
    final monthKeys =
        _entries
            .map((e) => _monthKey(e.takenAt))
            .toSet()
            .toList(growable: false)
          ..sort((a, b) => b.compareTo(a));
    if (monthKeys.isEmpty) {
      _selectedMonthKey = null;
      return;
    }
    if (_selectedMonthKey != null && !monthKeys.contains(_selectedMonthKey)) {
      _selectedMonthKey = null;
    }
  }

  Map<String, int> get _monthCounts {
    if (identical(_cacheMonthCountsEntries, _entries) &&
        _cacheMonthCounts != null) {
      return _cacheMonthCounts!;
    }
    final map = <String, int>{};
    for (final e in _entries) {
      final key = _monthKey(e.takenAt);
      map[key] = (map[key] ?? 0) + 1;
    }
    _cacheMonthCountsEntries = _entries;
    _cacheMonthCounts = map;
    return map;
  }

  List<String> get _monthKeysSorted {
    final monthCounts = _monthCounts;
    if (identical(_cacheMonthKeysSource, monthCounts) &&
        _cacheMonthKeysSorted != null) {
      return _cacheMonthKeysSorted!;
    }
    final keys = monthCounts.keys.toList(growable: false)
      ..sort((a, b) => b.compareTo(a));
    _cacheMonthKeysSource = monthCounts;
    _cacheMonthKeysSorted = keys;
    return keys;
  }

  List<OneLineDiaryEntry> get _monthScopedEntries {
    if (identical(_cacheMonthScopedSource, _entries) &&
        _cacheMonthScopedKey == _selectedMonthKey &&
        _cacheMonthScopedEntries != null) {
      return _cacheMonthScopedEntries!;
    }
    late final List<OneLineDiaryEntry> result;
    if (_selectedMonthKey == null || _selectedMonthKey!.isEmpty) {
      result = _entries;
    } else {
      result = _entries
          .where((e) => _monthKey(e.takenAt) == _selectedMonthKey)
          .toList(growable: false);
    }
    _cacheMonthScopedSource = _entries;
    _cacheMonthScopedKey = _selectedMonthKey;
    _cacheMonthScopedEntries = result;
    return result;
  }

  Map<String, int> get _petCountsInMonth {
    final source = _monthScopedEntries;
    if (identical(_cachePetCountsSource, source) && _cachePetCounts != null) {
      return _cachePetCounts!;
    }
    final map = <String, int>{};
    for (final e in source) {
      final key = _petKeyOf(e);
      map[key] = (map[key] ?? 0) + 1;
    }
    _cachePetCountsSource = source;
    _cachePetCounts = map;
    return map;
  }

  List<OneLineDiaryEntry> get _petScopedEntries {
    final source = _monthScopedEntries;
    if (identical(_cachePetScopedSource, source) &&
        _cachePetScopedKey == _selectedPetKey &&
        _cachePetScopedEntries != null) {
      return _cachePetScopedEntries!;
    }
    final result = source
        .where(
          (e) => (_selectedPetKey == 'all' || _petKeyOf(e) == _selectedPetKey),
        )
        .toList(growable: false);
    _cachePetScopedSource = source;
    _cachePetScopedKey = _selectedPetKey;
    _cachePetScopedEntries = result;
    return result;
  }

  String _normalizeTag(String raw) {
    var tag = raw.trim();
    while (tag.startsWith('#')) {
      tag = tag.substring(1).trimLeft();
    }
    return tag.trim();
  }

  Future<void> _loadQuickTagPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final users = prefs.getStringList(_quickTagUserKey);
      if (!mounted) return;
      setState(() {
        _userQuickTags = (users ?? const <String>[])
            .map(_normalizeTag)
            .where((e) => e.isNotEmpty)
            .where((e) => !_defaultQuickTagsSeed.contains(e))
            .toSet()
            .toList(growable: true);
      });
    } catch (_) {}
  }

  Future<void> _saveQuickTagPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_quickTagUserKey, _userQuickTags);
  }

  Future<void> _removeUserQuickTag(String tag) async {
    final normalized = _normalizeTag(tag);
    if (normalized.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _userQuickTags.removeWhere((e) => _normalizeTag(e) == normalized);
    });
    await _saveQuickTagPrefs();
  }

  Future<void> _upsertUserQuickTagsFromSavedTags(List<String> tags) async {
    final normalized = tags
        .map(_normalizeTag)
        .where((e) => e.isNotEmpty)
        .where((e) => !_defaultQuickTagsSeed.contains(e))
        .toList(growable: false);
    if (normalized.isEmpty) return;
    final set = _userQuickTags.map(_normalizeTag).toSet();
    var changed = false;
    for (final tag in normalized) {
      if (set.add(tag)) {
        _userQuickTags.add(tag);
        changed = true;
      }
    }
    if (_userQuickTags.length > _maxUserQuickTags) {
      _userQuickTags = _userQuickTags
          .sublist(_userQuickTags.length - _maxUserQuickTags)
          .toList(growable: true);
      changed = true;
    }
    if (changed) {
      await _saveQuickTagPrefs();
    }
  }

  List<String> _defaultQuickTagsForEditor() {
    return _defaultQuickTagsSeed
        .map(_normalizeTag)
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _userQuickTagsForEditor() {
    return _userQuickTags
        .map(_normalizeTag)
        .where((e) => e.isNotEmpty)
        .where((e) => !_defaultQuickTagsSeed.contains(e))
        .toSet()
        .toList(growable: false);
  }

  Map<String, int> get _tagCountsInScope {
    final source = _petScopedEntries;
    if (identical(_cacheTagCountsSource, source) && _cacheTagCounts != null) {
      return _cacheTagCounts!;
    }
    final map = <String, int>{};
    for (final e in source) {
      for (final raw in e.allTags) {
        final tag = _normalizeTag(raw);
        if (tag.isEmpty) continue;
        map[tag] = (map[tag] ?? 0) + 1;
      }
    }
    _cacheTagCountsSource = source;
    _cacheTagCounts = map;
    return map;
  }

  List<String> get _tagKeysByPopularity {
    final counts = _tagCountsInScope;
    if (identical(_cacheTagPopularitySource, counts) &&
        _cacheTagKeysByPopularity != null) {
      return _cacheTagKeysByPopularity!;
    }
    final entries = counts.entries.toList(growable: false)
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    final keys = entries.map((e) => e.key).toList(growable: false);
    _cacheTagPopularitySource = counts;
    _cacheTagKeysByPopularity = keys;
    return keys;
  }

  List<String> get _petKeysSorted {
    final petCounts = _petCountsInMonth;
    if (identical(_cachePetKeysSource, petCounts) &&
        _cachePetKeysSorted != null) {
      return _cachePetKeysSorted!;
    }
    final keys = List<String>.of(petCounts.keys)..sort();
    final unnamedIndex = keys.indexOf('이름없음');
    if (unnamedIndex >= 0) {
      final unnamed = keys[unnamedIndex];
      keys
        ..removeAt(unnamedIndex)
        ..add(unnamed);
    }
    _cachePetKeysSource = petCounts;
    _cachePetKeysSorted = keys;
    return keys;
  }

  List<OneLineDiaryEntry> get _filteredEntries {
    final source = _petScopedEntries;
    final tagCounts = _tagCountsInScope;
    if (identical(_cacheFilteredSource, source) &&
        identical(_cacheFilteredTagCountsSource, tagCounts) &&
        _cacheFilteredSelectedTag == _selectedTagKey &&
        _cacheFilteredSortType == _sortType &&
        _cacheFilteredEntries != null) {
      return _cacheFilteredEntries!;
    }
    final activeTag = tagCounts.containsKey(_selectedTagKey)
        ? _selectedTagKey
        : 'all';
    final list = source
        .where((e) {
          if (activeTag == 'all') return true;
          return e.allTags.any((tag) => _normalizeTag(tag) == activeTag);
        })
        .toList(growable: false);

    list.sort((a, b) {
      final diff = a.takenAt.compareTo(b.takenAt);
      return _sortType == _SortType.newest ? -diff : diff;
    });
    _cacheFilteredSource = source;
    _cacheFilteredTagCountsSource = tagCounts;
    _cacheFilteredSelectedTag = _selectedTagKey;
    _cacheFilteredSortType = _sortType;
    _cacheFilteredEntries = list;
    return list;
  }

  String _dayKey(DateTime date) {
    final m = date.month.toString().padLeft(2, '0');
    return '${date.year}-$m';
  }

  String _dayLabel(DateTime date) {
    return '${date.year}년 ${date.month}월';
  }

  List<Object> _buildSectionedItems(List<OneLineDiaryEntry> entries) {
    if (entries.isEmpty) return const <Object>[];
    final dayCounts = <String, int>{};
    for (final e in entries) {
      final key = _dayKey(e.takenAt);
      dayCounts[key] = (dayCounts[key] ?? 0) + 1;
    }

    final items = <Object>[];
    String? lastDayKey;
    for (final e in entries) {
      final key = _dayKey(e.takenAt);
      if (lastDayKey != key) {
        items.add(
          _DiaryDayHeader(
            label: _dayLabel(e.takenAt),
            count: dayCounts[key] ?? 0,
          ),
        );
        lastDayKey = key;
      }
      items.add(e);
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 0,
        title: const Text(
          '한줄 일기',
          style: TextStyle(
            color: Color(0xFF7E4C5F),
            fontWeight: FontWeight.w800,
            fontSize: 19,
            letterSpacing: -0.1,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '한줄 일기 안내',
            onPressed: _showInfoGuide,
            icon: const Icon(Icons.info_outline_rounded, color: Colors.black87),
          ),
          IconButton(
            tooltip: _showHidden ? '비노출 숨기기' : '비노출 보기',
            onPressed: () {
              _logPerf(
                () =>
                    'toggleHiddenFilter tapped: nowShowHidden=${!_showHidden}',
              );
              setState(() {
                _showHidden = !_showHidden;
              });
              unawaited(
                _loadEntries(forceRefresh: true, showLoadingIndicator: false),
              );
            },
            icon: Icon(
              _showHidden ? Icons.visibility : Icons.visibility_off,
              color: Colors.black87,
            ),
          ),
          IconButton(
            onPressed: () async {
              final sw = Stopwatch()..start();
              _logPerf(() => 'manual_refresh tapped');
              await _loadEntries(
                forceRefresh: true,
                showLoadingIndicator: false,
              );
              _logPerf(
                () => 'manual_refresh done: ${sw.elapsedMilliseconds}ms',
              );
            },
            icon: const Icon(Icons.refresh, color: Colors.black87),
          ),
        ],
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios,
            color: Colors.black87,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(top: true, bottom: false, child: _buildBody()),
      bottomNavigationBar: Container(
        color: kPetgramNavColor,
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.diary,
            onShotTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
            onDiaryTap: () {},
            onBackupTap: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const BackupPage()),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final filtered = _filteredEntries;
    final sectioned = _buildSectionedItems(filtered);
    final showPlaceholder = _loading && _entries.isEmpty;
    final showLoadMore = _isLoadingMore && filtered.isNotEmpty;

    return Column(
      children: [
        _buildSearchSection(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              final sw = Stopwatch()..start();
              _logPerf(() => 'pull_to_refresh start');
              await _loadEntries(
                forceRefresh: true,
                append: false,
                showLoadingIndicator: false,
                validateExistence: true,
              );
              _logPerf(
                () => 'pull_to_refresh done: ${sw.elapsedMilliseconds}ms',
              );
            },
            child: _viewMode == _DiaryViewMode.list
                ? ListView.builder(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    cacheExtent: 1400,
                    padding: const EdgeInsets.fromLTRB(0, 6, 0, 12),
                    itemCount: showPlaceholder
                        ? 4
                        : (filtered.isEmpty
                              ? 1
                              : sectioned.length + (showLoadMore ? 1 : 0)),
                    itemBuilder: (context, index) {
                      if (showPlaceholder) {
                        return _buildLoadingCard();
                      }
                      if (filtered.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.only(top: 56),
                          child: Center(
                            child: Text(
                              '촬영된 사진이 없습니다.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.black54),
                            ),
                          ),
                        );
                      }
                      if (showLoadMore && index == sectioned.length) {
                        return _buildLoadMoreIndicator();
                      }
                      final item = sectioned[index];
                      if (item is _DiaryDayHeader) {
                        return _buildDayHeader(item);
                      }
                      return _buildEntryCard(item as OneLineDiaryEntry);
                    },
                  )
                : _buildGridBody(
                    filtered: filtered,
                    showPlaceholder: showPlaceholder,
                    showLoadMore: showLoadMore,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadMoreIndicator() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _buildGridBody({
    required List<OneLineDiaryEntry> filtered,
    required bool showPlaceholder,
    required bool showLoadMore,
  }) {
    if (showPlaceholder) {
      return GridView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        cacheExtent: 900,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: 1,
        ),
        itemCount: 12,
        itemBuilder: (context, index) =>
            Container(color: const Color(0xFFF2F3F5)),
      );
    }

    if (filtered.isEmpty) {
      return ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 56),
          Center(
            child: Text(
              '촬영된 사진이 없습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ),
        ],
      );
    }

    final monthSections = _buildMonthSections(filtered);

    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      cacheExtent: 900,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ...monthSections.map((section) {
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        _monthLabel(section.monthKey),
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: Color(0xFF5A4A50),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F2F4),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${section.entries.length}장',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF666666),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                    childAspectRatio: 1,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    return _buildGridTile(section.entries[index]);
                  }, childCount: section.entries.length),
                ),
              ),
            ],
          );
        }),
        if (showLoadMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  List<_DiaryMonthSection> _buildMonthSections(
    List<OneLineDiaryEntry> entries,
  ) {
    final grouped = <String, List<OneLineDiaryEntry>>{};
    for (final e in entries) {
      final key = _monthKey(e.takenAt);
      grouped.putIfAbsent(key, () => <OneLineDiaryEntry>[]).add(e);
    }
    return grouped.entries
        .map((e) => _DiaryMonthSection(monthKey: e.key, entries: e.value))
        .toList(growable: false);
  }

  Future<void> _warmupVisibleThumbnails(List<OneLineDiaryEntry> entries) async {
    if (entries.isEmpty) return;
    final warmupCount = entries.length > 24 ? 24 : entries.length;
    for (var i = 0; i < warmupCount; i++) {
      await _resolveAssetEntity(entries[i]);
      await _resolveDisplayFile(entries[i]);
    }
  }

  Widget _buildDayHeader(_DiaryDayHeader header) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Text(
        header.label,
        style: const TextStyle(
          fontSize: 13,
          color: Color(0xFF4A4A4A),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0x11000000))),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE9EBEF),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 140,
                  height: 12,
                  color: const Color(0xFFE9EBEF),
                ),
              ],
            ),
          ),
          Container(height: 260, color: const Color(0xFFF1F3F5)),
        ],
      ),
    );
  }

  Widget _buildSearchSection() {
    final monthCounts = _monthCounts;
    final petCounts = _petCountsInMonth;
    final monthKeys = _monthKeysSorted;
    final petKeys = _petKeysSorted;
    final tagCounts = _tagCountsInScope;
    final tagKeys = _tagKeysByPopularity;
    final String monthValue =
        (_selectedMonthKey != null && monthKeys.contains(_selectedMonthKey))
        ? _selectedMonthKey!
        : 'all';
    final petValue = _selectedPetKey == 'all'
        ? 'all'
        : (petKeys.contains(_selectedPetKey) ? _selectedPetKey : 'all');
    final tagValue = _selectedTagKey == 'all'
        ? 'all'
        : (tagKeys.contains(_selectedTagKey) ? _selectedTagKey : 'all');

    final monthTitle = monthValue == 'all' ? '전체' : _monthLabel(monthValue);
    final petTitle = petValue == 'all' ? '전체' : petValue;
    final tagTitle = tagValue == 'all' ? '전체' : '#$tagValue';
    final monthCountLabel = monthValue == 'all'
        ? '${_entries.length}개'
        : '${monthCounts[monthValue] ?? 0}개';
    final petCountLabel =
        '${petValue == 'all' ? petKeys.length : (petCounts[petValue] ?? 0)}개';
    final petCountIcon = petValue == 'all'
        ? Icons.pets_rounded
        : Icons.photo_camera_outlined;
    final tagCountLabel =
        '${tagValue == 'all' ? tagKeys.length : (tagCounts[tagValue] ?? 0)}개';
    final tagCountIcon = tagValue == 'all'
        ? Icons.sell_rounded
        : Icons.photo_camera_outlined;

    final monthOptions = <_DiaryFilterOption>[
      _DiaryFilterOption(
        value: 'all',
        label: '전체',
        count: _entries.length,
        chipIcon: Icons.photo_camera_outlined,
      ),
      ...monthKeys.map(
        (key) => _DiaryFilterOption(
          value: key,
          label: _monthLabel(key),
          count: monthCounts[key] ?? 0,
          chipIcon: Icons.photo_camera_outlined,
        ),
      ),
    ];
    final petOptions = <_DiaryFilterOption>[
      _DiaryFilterOption(
        value: 'all',
        label: '전체',
        count: petKeys.length,
        chipIcon: Icons.pets_rounded,
      ),
      ...petKeys.map(
        (petKey) => _DiaryFilterOption(
          value: petKey,
          label: petKey,
          count: petCounts[petKey] ?? 0,
          chipIcon: Icons.photo_camera_outlined,
        ),
      ),
    ];
    final tagOptions = <_DiaryFilterOption>[
      _DiaryFilterOption(
        value: 'all',
        label: '전체',
        count: tagKeys.length,
        chipIcon: Icons.sell_rounded,
      ),
      ...tagKeys.map(
        (tag) => _DiaryFilterOption(
          value: tag,
          label: '#$tag',
          count: tagCounts[tag] ?? 0,
          chipIcon: Icons.photo_camera_outlined,
        ),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEFECEF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildFilterPill(
                    title: '촬영기간',
                    value: monthTitle,
                    countLabel: monthCountLabel,
                    countIcon: Icons.photo_camera_outlined,
                    onTap: () => _openFilterBottomSheet(
                      title: '촬영기간',
                      currentValue: monthValue,
                      options: monthOptions,
                      showOptionCountChip: true,
                      onSelected: (v) {
                        _logPerf(
                          () => 'filter month changed: $monthValue -> $v',
                        );
                        setState(() {
                          _selectedMonthKey = v == 'all' ? null : v;
                          _selectedPetKey = 'all';
                          _selectedTagKey = 'all';
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildFilterPill(
                    title: '반려동물',
                    value: petTitle,
                    countLabel: petCountLabel,
                    countIcon: petCountIcon,
                    onTap: () => _openFilterBottomSheet(
                      title: '반려동물 이름',
                      currentValue: petValue,
                      options: petOptions,
                      showOptionCountChip: true,
                      onSelected: (v) {
                        _logPerf(() => 'filter pet changed: $petValue -> $v');
                        setState(() {
                          _selectedPetKey = v;
                          _selectedTagKey = 'all';
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: _buildFilterPill(
                    title: '태그',
                    value: tagTitle,
                    countLabel: tagCountLabel,
                    countIcon: tagCountIcon,
                    onTap: () => _openFilterBottomSheet(
                      title: '태그',
                      currentValue: tagValue,
                      options: tagOptions,
                      showOptionCountChip: true,
                      onSelected: (v) {
                        _logPerf(() => 'filter tag changed: $tagValue -> $v');
                        setState(() => _selectedTagKey = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _buildModeActionIcons(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterPill({
    required String title,
    required String value,
    required String countLabel,
    IconData countIcon = Icons.photo_camera_outlined,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFFF9F7F8),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFEFECEF)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.2,
                        color: Color(0xFF9F9197),
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF4A3E43),
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              if (countLabel.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEEF4),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFFEFCAD8)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(countIcon, size: 11, color: _accentDeep),
                      const SizedBox(width: 3),
                      Text(
                        countLabel,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: _accentDeep,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
              ],
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 15,
                color: Color(0xFF9A7481),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFilterBottomSheet({
    required String title,
    required String currentValue,
    required List<_DiaryFilterOption> options,
    required ValueChanged<String> onSelected,
    bool showOptionCountChip = false,
  }) async {
    if (options.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 34,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3E4E8),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xFF362B2F),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: options.length,
                    separatorBuilder: (_, index) =>
                        const Divider(height: 1, color: Color(0xFFF1F2F4)),
                    itemBuilder: (context, index) {
                      final option = options[index];
                      final selected = option.value == currentValue;
                      final canShowChip =
                          showOptionCountChip && option.count != null;
                      Widget? trailing;
                      if (canShowChip || selected) {
                        final widgets = <Widget>[];
                        if (canShowChip) {
                          widgets.add(
                            _buildOptionCountChip(
                              count: option.count!,
                              icon: option.chipIcon,
                            ),
                          );
                        }
                        if (selected) {
                          if (widgets.isNotEmpty) {
                            widgets.add(const SizedBox(width: 6));
                          }
                          widgets.add(
                            const Icon(
                              Icons.check_rounded,
                              color: _accentDeep,
                              size: 18,
                            ),
                          );
                        }
                        trailing = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: widgets,
                        );
                      }
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          option.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color: selected
                                ? _accentDeep
                                : const Color(0xFF53464B),
                          ),
                        ),
                        trailing: trailing,
                        onTap: () => Navigator.of(context).pop(option.value),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || picked == currentValue || !mounted) return;
    onSelected(picked);
  }

  Widget _buildOptionCountChip({required int count, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEEF4),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFEFCAD8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: _accentDeep),
            const SizedBox(width: 3),
          ],
          Text(
            '$count개',
            style: const TextStyle(
              fontSize: 10.5,
              color: _accentDeep,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(OneLineDiaryEntry entry) {
    final comment = entry.comment.trim();
    final allTags = entry.allTags
        .map(_normalizeTag)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final petName = (entry.petName ?? '').trim();
    final petAge = _petAgeByName[petName];
    final petType = (entry.petType ?? '').trim().toLowerCase();
    final hasPetInfo =
        petName.isNotEmpty && (petType == 'dog' || petType == 'cat');
    final isNew = _isNewEntry(entry);

    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x14000000)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1F6),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFDFAABB)),
                    ),
                    child: _buildPetTypeIcon(entry),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: hasPetInfo
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      petAge != null
                                          ? '$petName · $petAge살'
                                          : petName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        color: Color(0xFF3C3C3C),
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  if (isNew) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFEEF4),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        border: Border.all(
                                          color: const Color(0xFFEFCAD8),
                                        ),
                                      ),
                                      child: const Text(
                                        'N',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: _accentDeep,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _formatMonthDay(entry.takenAt),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF9A7A86),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            _formatMonthDay(entry.takenAt),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF9A7A86),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                  if (entry.isHidden)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF0F4),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '비노출',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF5E6A74),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => _openEditSheet(entry),
                    icon: const Icon(Icons.edit_note_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: entry.isHidden ? '다시 노출' : '비노출',
                    onPressed: () => _toggleHidden(entry),
                    icon: Icon(
                      entry.isHidden ? Icons.visibility : Icons.visibility_off,
                      color: entry.isHidden ? Colors.blueGrey : Colors.black54,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: '원본 사진 삭제',
                    onPressed: () => _deleteOriginalPhoto(entry),
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFB28395),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            ClipRRect(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              child: _buildThumbnail(entry),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (comment.isNotEmpty)
                    Text(
                      comment,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        color: Color(0xFF111111),
                        height: 1.35,
                      ),
                    ),
                  if (comment.isNotEmpty && allTags.isNotEmpty)
                    const SizedBox(height: 8),
                  if (allTags.isNotEmpty) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: allTags
                          .map(
                            (e) => Text(
                              '#$e',
                              style: const TextStyle(
                                fontSize: 13,
                                color: _accentDeep,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPetTypeIcon(OneLineDiaryEntry entry) {
    final petType = (entry.petType ?? '').trim().toLowerCase();
    if (petType == 'cat') {
      return ClipOval(
        child: Image.asset(
          'assets/icons/cat.png',
          width: 22,
          height: 22,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return const Icon(Icons.pets_rounded, size: 18, color: _accentDeep);
          },
        ),
      );
    }
    if (petType == 'dog') {
      return ClipOval(
        child: Image.asset(
          'assets/icons/dog.png',
          width: 22,
          height: 22,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return const Icon(Icons.pets_rounded, size: 18, color: _accentDeep);
          },
        ),
      );
    }
    return const Icon(Icons.pets_rounded, size: 18, color: _accentDeep);
  }

  Widget _buildThumbnail(OneLineDiaryEntry entry) {
    final cacheKey = _entryCacheKey(entry);
    final resolvedFile = _resolvedDisplayFileCache[cacheKey];
    if (resolvedFile != null && resolvedFile.path.isNotEmpty) {
      final mq = MediaQuery.of(context);
      final targetWidth = (mq.size.width * mq.devicePixelRatio).round();
      return _buildZoomableThumbnail(
        entry: entry,
        child: Image.file(
          resolvedFile,
          width: double.infinity,
          fit: BoxFit.fitWidth,
          cacheWidth: targetWidth,
          filterQuality: FilterQuality.low,
          errorBuilder: (context, error, stackTrace) {
            return _buildImageFallbackIcon(icon: Icons.broken_image_outlined);
          },
        ),
      );
    }

    return FutureBuilder<File?>(
      future: _resolveDisplayFile(entry),
      builder: (context, snapshot) {
        final mq = MediaQuery.of(context);
        final targetWidth = (mq.size.width * mq.devicePixelRatio).round();
        final estimatedHeight = _estimatedListThumbHeight(entry, mq);
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            color: const Color(0xFFF5F6F8),
            height: estimatedHeight,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final f = snapshot.data;
        if (f != null && f.path.isNotEmpty) {
          return _buildZoomableThumbnail(
            entry: entry,
            child: Image.file(
              f,
              width: double.infinity,
              fit: BoxFit.fitWidth,
              cacheWidth: targetWidth,
              filterQuality: FilterQuality.low,
              errorBuilder: (context, error, stackTrace) {
                return _buildImageFallbackIcon(
                  icon: Icons.broken_image_outlined,
                );
              },
            ),
          );
        }
        return _buildImageFallbackIcon(
          icon: entry.filePath.startsWith('name:')
              ? Icons.photo_outlined
              : Icons.broken_image_outlined,
          height: estimatedHeight,
        );
      },
    );
  }

  Widget _buildZoomableThumbnail({
    required OneLineDiaryEntry entry,
    required Widget child,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openZoomViewer(entry),
      child: Stack(
        children: [
          child,
          Positioned(
            right: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: const Color(0x8A000000),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Icon(
                Icons.zoom_in_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<File?> _resolveDisplayFile(OneLineDiaryEntry entry) async {
    final cacheKey = _entryCacheKey(entry);
    final resolved = _resolvedDisplayFileCache[cacheKey];
    if (resolved != null && resolved.path.isNotEmpty) {
      return resolved;
    }
    final future = _displayFileFutureCache.putIfAbsent(cacheKey, () async {
      final asset = await _resolveAssetEntity(entry);
      final assetFile = await asset?.file;
      if (assetFile != null && assetFile.path.isNotEmpty) {
        _resolvedDisplayFileCache[cacheKey] = assetFile;
        return assetFile;
      }

      final localPath = OneLineDiaryService.instance.extractLocalFilePath(
        entry.filePath,
      );
      if (localPath == null || localPath.isEmpty) return null;
      final f = File(localPath);
      try {
        if (await f.exists()) {
          _resolvedDisplayFileCache[cacheKey] = f;
          return f;
        }
      } catch (_) {}
      _resolvedDisplayFileCache[cacheKey] = null;
      return null;
    });
    return future;
  }

  Future<void> _openZoomViewer(OneLineDiaryEntry entry) async {
    final file = await _resolveDisplayFile(entry);
    if (!mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('원본 사진을 찾을 수 없습니다.')));
      return;
    }

    final cacheKey = _entryCacheKey(entry);
    final ratioCandidate =
        _entryAspectRatioCache[cacheKey] ?? _globalAspectRatioCache[cacheKey];
    final imageRatio =
        ratioCandidate != null && ratioCandidate.isFinite && ratioCandidate > 0
        ? ratioCandidate
        : (3 / 4);
    final zoomController = TransformationController();
    TapDownDetails? lastDoubleTapDown;

    try {
      await showDialog<void>(
        context: context,
        barrierColor: const Color(0xE6000000),
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
                Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final maxWidth = constraints.maxWidth.isFinite
                          ? constraints.maxWidth
                          : MediaQuery.of(dialogContext).size.width;
                      final maxHeight = constraints.maxHeight.isFinite
                          ? constraints.maxHeight
                          : MediaQuery.of(dialogContext).size.height;
                      final widthByHeight = maxHeight * imageRatio;
                      final viewerWidth = widthByHeight < maxWidth
                          ? widthByHeight
                          : maxWidth;
                      final viewerHeight = viewerWidth / imageRatio;

                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {},
                        onDoubleTapDown: (details) {
                          lastDoubleTapDown = details;
                        },
                        onDoubleTap: () {
                          final currentScale = zoomController.value
                              .getMaxScaleOnAxis();
                          if (currentScale > 1.05) {
                            zoomController.value = Matrix4.identity();
                            return;
                          }
                          final tapPosition =
                              lastDoubleTapDown?.localPosition ??
                              Offset(viewerWidth / 2, viewerHeight / 2);
                          const targetScale = 2.6;
                          final translateX =
                              -tapPosition.dx * (targetScale - 1);
                          final translateY =
                              -tapPosition.dy * (targetScale - 1);
                          final zoomed = Matrix4.identity()
                            ..setEntry(0, 0, targetScale)
                            ..setEntry(1, 1, targetScale)
                            ..setEntry(0, 3, translateX)
                            ..setEntry(1, 3, translateY);
                          zoomController.value = zoomed;
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: viewerWidth,
                            height: viewerHeight,
                            child: InteractiveViewer(
                              transformationController: zoomController,
                              minScale: 1,
                              maxScale: 4.5,
                              child: Image.file(
                                file,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return const Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white70,
                                      size: 34,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(dialogContext).padding.top + 8,
                  right: 12,
                  child: Material(
                    color: const Color(0xB3000000),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(dialogContext).pop(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0x66FFFFFF),
                            width: 1.1,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      zoomController.dispose();
    }
  }

  Future<AssetEntity?> _resolveAssetEntity(OneLineDiaryEntry entry) {
    final cacheKey =
        '${entry.filePath}|${entry.takenAt.millisecondsSinceEpoch}';
    return _assetFutureCache.putIfAbsent(cacheKey, () async {
      for (int attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) {
          await Future.delayed(Duration(milliseconds: 250 * attempt));
        }
        final asset = await PetgramMediaRefService.instance
            .resolveAssetEntityForDiary(
              fileRef: entry.filePath,
              takenAt: entry.takenAt,
            );
        if (asset != null) {
          _cacheEntryAspectRatio(entry, asset.width, asset.height);
          return asset;
        }
      }
      return null;
    });
  }

  void _cacheEntryAspectRatio(OneLineDiaryEntry entry, int width, int height) {
    if (width <= 0 || height <= 0) return;
    final ratio = width / height;
    if (!ratio.isFinite || ratio <= 0) return;
    final key = _entryCacheKey(entry);
    _entryAspectRatioCache[key] = ratio;
    _globalAspectRatioCache[key] = ratio;
  }

  double _estimatedListThumbHeight(OneLineDiaryEntry entry, MediaQueryData mq) {
    final key = _entryCacheKey(entry);
    final ratio =
        _entryAspectRatioCache[key] ?? _globalAspectRatioCache[key] ?? (3 / 4);
    final safeRatio = ratio <= 0 ? (3 / 4) : ratio;
    final width = mq.size.width - 24;
    final h = width / safeRatio;
    // 과도한 높이/너무 작은 높이로 레이아웃이 튀지 않도록 제한
    return h.clamp(200.0, 560.0);
  }

  Widget _buildImageFallbackIcon({required IconData icon, double? height}) {
    return Container(
      height: height,
      color: const Color(0xFFF2F3F5),
      child: Center(child: Icon(icon, size: 28, color: Colors.black38)),
    );
  }

  Widget _buildModeActionIcons() {
    final sortIsNewest = _sortType == _SortType.newest;
    final viewIsGrid = _viewMode == _DiaryViewMode.grid;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToggleIconButton(
          icon: sortIsNewest ? Icons.south_rounded : Icons.north_rounded,
          tooltip: sortIsNewest ? '최신순 (탭: 오래된순)' : '오래된순 (탭: 최신순)',
          onTap: () => setState(() {
            _logPerf(
              () =>
                  'sort toggled: ${_sortType.name} -> ${sortIsNewest ? _SortType.oldest.name : _SortType.newest.name}',
            );
            _sortType = sortIsNewest ? _SortType.oldest : _SortType.newest;
          }),
        ),
        const SizedBox(width: 6),
        _buildToggleIconButton(
          icon: viewIsGrid
              ? Icons.grid_view_rounded
              : Icons.view_agenda_rounded,
          tooltip: viewIsGrid ? '격자 보기 (탭: 리스트)' : '리스트 보기 (탭: 격자)',
          onTap: () => setState(() {
            _logPerf(
              () =>
                  'view toggled: ${_viewMode.name} -> ${viewIsGrid ? _DiaryViewMode.list.name : _DiaryViewMode.grid.name}',
            );
            _viewMode = viewIsGrid ? _DiaryViewMode.list : _DiaryViewMode.grid;
          }),
        ),
      ],
    );
  }

  Widget _buildToggleIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFFF9F7F8),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFE3D8DE)),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: const Color(0xFF8D7A83)),
        ),
      ),
    );
  }

  Widget _buildGridTile(OneLineDiaryEntry entry) {
    final isNew = _isNewEntry(entry);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFFF3F4F6)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildGridThumbnail(entry),
            if (isNew)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE6FFEEF4),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFFEFCAD8)),
                  ),
                  child: const Text(
                    'N',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: _accentDeep,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            if (entry.isHidden)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Icon(
                    Icons.visibility_off,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridThumbnail(OneLineDiaryEntry entry) {
    final cacheKey = _entryCacheKey(entry);
    final resolvedFile = _resolvedDisplayFileCache[cacheKey];
    if (resolvedFile != null && resolvedFile.path.isNotEmpty) {
      final mq = MediaQuery.of(context);
      final tileWidthLogical = (mq.size.width - 20) / 3;
      final targetWidth = (tileWidthLogical * mq.devicePixelRatio).round();
      return GestureDetector(
        onTap: () => _openZoomViewer(entry),
        child: Image.file(
          resolvedFile,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: targetWidth,
          filterQuality: FilterQuality.low,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
      );
    }

    return FutureBuilder<File?>(
      future: _resolveDisplayFile(entry),
      builder: (context, snapshot) {
        final mq = MediaQuery.of(context);
        final tileWidthLogical = (mq.size.width - 20) / 3;
        final targetWidth = (tileWidthLogical * mq.devicePixelRatio).round();
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.expand(
            child: Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final f = snapshot.data;
        if (f == null || f.path.isEmpty) {
          if (entry.filePath.startsWith('name:')) {
            return Container(
              color: const Color(0xFFF2F3F5),
              child: const Center(
                child: Icon(
                  Icons.photo_outlined,
                  size: 20,
                  color: Colors.black38,
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        }
        return GestureDetector(
          onTap: () => _openZoomViewer(entry),
          child: Image.file(
            f,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: targetWidth,
            filterQuality: FilterQuality.low,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        );
      },
    );
  }

  String _entryCacheKey(OneLineDiaryEntry entry) {
    return '${entry.filePath}|${entry.takenAt.millisecondsSinceEpoch}';
  }

  bool _isNewEntry(OneLineDiaryEntry entry) {
    final now = DateTime.now();
    final takenAt = entry.takenAt.toLocal();
    if (takenAt.isAfter(now)) return true;
    return now.difference(takenAt) <= const Duration(days: 3);
  }

  Future<void> _openEditSheet(OneLineDiaryEntry entry) async {
    final controller = TextEditingController(text: entry.comment);
    final tagsController = TextEditingController(
      text: entry.userTags.join(', '),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 170),
        reverseDuration: Duration(milliseconds: 130),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final defaultQuickTags = _defaultQuickTagsForEditor();
            final userQuickTags = _userQuickTagsForEditor();
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFFFFAFC),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 10,
                bottom: bottomInset + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFDDBCC8),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '한줄 일기',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _accentDeep,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: controller,
                      maxLines: 2,
                      maxLength: 80,
                      decoration: InputDecoration(
                        hintText: '오늘의 순간을 한 줄로 남겨보세요',
                        counterStyle: const TextStyle(
                          color: Color(0xFF9C8A91),
                          fontSize: 11.5,
                        ),
                        hintStyle: const TextStyle(
                          color: Color(0xFF9C8A91),
                          fontSize: 14,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _lineSoft),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _accent),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '기본 태그',
                      style: TextStyle(
                        fontSize: 13,
                        color: _accentDeep,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: defaultQuickTags.length,
                        separatorBuilder: (_, index) =>
                            const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final tag = defaultQuickTags[index];
                          return ActionChip(
                            label: Text('#$tag'),
                            labelStyle: const TextStyle(
                              color: _accentDeep,
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                            backgroundColor: const Color(0xFFFFEFF5),
                            side: const BorderSide(color: _lineSoft),
                            onPressed: () {
                              final existing = tagsController.text
                                  .split(',')
                                  .map((e) => e.trim())
                                  .where((e) => e.isNotEmpty)
                                  .toSet();
                              if (existing.contains(tag)) return;
                              existing.add(tag);
                              tagsController.text = existing.join(', ');
                              setModalState(() {});
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '내 태그',
                          style: TextStyle(
                            fontSize: 13,
                            color: _accentDeep,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (userQuickTags.isNotEmpty)
                      SizedBox(
                        height: 40,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: userQuickTags.length,
                          separatorBuilder: (_, index) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final tag = userQuickTags[index];
                            return InputChip(
                              label: Text('#$tag'),
                              labelStyle: const TextStyle(
                                color: _accentDeep,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                              backgroundColor: const Color(0xFFFFEFF5),
                              side: const BorderSide(color: _lineSoft),
                              onPressed: () {
                                final existing = tagsController.text
                                    .split(',')
                                    .map((e) => e.trim())
                                    .where((e) => e.isNotEmpty)
                                    .toSet();
                                if (existing.contains(tag)) return;
                                existing.add(tag);
                                tagsController.text = existing.join(', ');
                                setModalState(() {});
                              },
                              onDeleted: () async {
                                await _removeUserQuickTag(tag);
                                if (!mounted || !sheetContext.mounted) return;
                                setModalState(() {});
                              },
                              deleteIconColor: const Color(0xFFB28395),
                              visualDensity: VisualDensity.compact,
                            );
                          },
                        ),
                      )
                    else
                      const Text(
                        '사용자 등록 태그가 없습니다.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF9C8A91),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: tagsController,
                      decoration: InputDecoration(
                        hintText: '쉼표(,)로 구분 입력 (예: 산책, 공원, 저녁)',
                        hintStyle: const TextStyle(
                          color: Color(0xFF9C8A91),
                          fontSize: 13.5,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _lineSoft),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _accent),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '별도 등록한 태그는 [내  태그]에 자동 등록됩니다. (최대 30개)',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9C8A91),
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () async {
                          final tags = tagsController.text
                              .split(RegExp(r'[,\\n]+'))
                              .map(_normalizeTag)
                              .where((e) => e.isNotEmpty)
                              .toList(growable: false);
                          await _upsertUserQuickTagsFromSavedTags(tags);

                          await OneLineDiaryService.instance.saveDraft(
                            entryId: entry.id,
                            comment: controller.text,
                            userTags: tags,
                          );
                          if (!sheetContext.mounted || !mounted) return;
                          Navigator.of(sheetContext).pop();
                          await _loadEntries(forceRefresh: true);
                        },
                        child: const Text(
                          '저장',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleHidden(OneLineDiaryEntry entry) async {
    final nextHidden = !entry.isHidden;
    await OneLineDiaryService.instance.setHidden(
      entryId: entry.id,
      hidden: nextHidden,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nextHidden ? '비노출 처리되었습니다. (사진은 삭제되지 않음)' : '다시 노출되었습니다.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
    await _loadEntries(forceRefresh: true);
  }

  Future<void> _deleteOriginalPhoto(OneLineDiaryEntry entry) async {
    if (_isDeletingOriginalPhoto) return;
    _isDeletingOriginalPhoto = true;
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('사진 삭제 권한이 없어 삭제할 수 없습니다.')),
        );
        return;
      }

      final asset = await PetgramMediaRefService.instance
          .resolveAssetEntityByExactNameForDiary(fileRef: entry.filePath);
      if (asset == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('원본 사진을 찾을 수 없습니다.')));
        return;
      }

      final deletedIds = await PhotoManager.editor.deleteWithIds([asset.id]);
      final deleted = deletedIds.contains(asset.id);
      if (!deleted) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('사진 삭제가 취소되었거나 실패했습니다.')));
        return;
      }

      await OneLineDiaryService.instance.pruneMissingEntryByFilePath(
        entry.filePath,
      );
      _entryCache = null;
      _cacheAt = null;
      _cacheHasMore = null;
      _cacheNextOffset = null;

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('원본 사진이 삭제되었습니다.')));
      await _loadEntries(
        forceRefresh: true,
        showLoadingIndicator: false,
        validateExistence: true,
        skipCache: true,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('사진 삭제 중 오류가 발생했습니다: $e')));
    } finally {
      _isDeletingOriginalPhoto = false;
    }
  }

  String _formatMonthDay(DateTime date) {
    return '${date.month}월 ${date.day}일';
  }

  void _showInfoGuide() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.78;
        return SafeArea(
          top: false,
          child: SizedBox(
            height: maxHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFDDBCC8),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '한줄 일기 안내',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF7E4C5F),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildGuideHighlight(
                            icon: Icons.photo_camera_outlined,
                            text: '한줄 일기는 Petgram에서 촬영하거나\n보정한 사진만 자동으로 추가됩니다.',
                          ),
                          const SizedBox(height: 10),
                          _buildGuideRow(
                            icon: Icons.delete_outline_rounded,
                            text: '사진앱에서 사진을 삭제하면\n해당 한줄 일기/태그도 함께 삭제됩니다.',
                          ),
                          const SizedBox(height: 8),
                          _buildGuideRow(
                            icon: Icons.phone_android_rounded,
                            text:
                                '휴대폰 변경/앱 재설치 후에는\n[기록 백업하기]에서 백업 불러오기를 해야\n기존 한줄 일기가 다시 연결됩니다.',
                          ),
                          const SizedBox(height: 8),
                          _buildGuideRow(
                            icon: Icons.zoom_in_rounded,
                            text: '썸네일을 탭하면 확대해서 볼 수 있습니다.',
                          ),
                          const SizedBox(height: 8),
                          _buildGuideRow(
                            icon: Icons.pets_rounded,
                            text: '백업의 경우 원본파일은 저장되지 않고\n식별정보만 저장 처리됩니다.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('확인'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGuideRow({required IconData icon, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: const Color(0xFFFFEFF5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: _accentDeep),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: Color(0xFF5E4A52),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGuideHighlight({required IconData icon, required String text}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEEF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEFCAD8)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: const Color(0xFF9A5D74)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Color(0xFF7E4C5F),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiaryDayHeader {
  final String label;
  final int count;

  const _DiaryDayHeader({required this.label, required this.count});
}

class _DiaryMonthSection {
  final String monthKey;
  final List<OneLineDiaryEntry> entries;

  const _DiaryMonthSection({required this.monthKey, required this.entries});
}

class _DiaryFilterOption {
  final String value;
  final String label;
  final int? count;
  final IconData? chipIcon;

  const _DiaryFilterOption({
    required this.value,
    required this.label,
    this.count,
    this.chipIcon,
  });
}
