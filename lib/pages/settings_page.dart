import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/petgram_nav_tab.dart';
import '../services/petgram_db.dart';
import '../services/petgram_photo_repository.dart';
import '../widgets/petgram_bottom_nav_bar.dart';
import 'backup_page.dart';
import 'diary_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _kDonationCompletedKey = 'donation_1000_completed';
  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  bool _isAvailable = false;
  List<ProductDetails> _products = [];
  bool _isLoadingProducts = false;
  bool _isPurchasing = false;
  bool _isRestoring = false;
  bool _receivedRestoreEvent = false;
  bool _isAwaitingPurchaseUpdate = false;
  bool _isDonationCompleted = false;
  String? _errorMessage;

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  Timer? _purchaseStartTimeout;

  @override
  void initState() {
    super.initState();
    _listenToPurchaseUpdates();
    unawaited(_loadDonationState());
    unawaited(_initializePurchase());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _purchaseStartTimeout?.cancel();
    super.dispose();
  }

  void _listenToPurchaseUpdates() {
    _subscription = _inAppPurchase.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _subscription?.cancel(),
      onError: (_) {
        _clearPurchaseStartTimeout();
        if (!mounted) return;
        setState(() {
          _isPurchasing = false;
          _isRestoring = false;
          _errorMessage = '결제 처리 중 오류가 발생했습니다.';
        });
      },
    );
  }

  void _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) {
    for (final purchaseDetails in purchaseDetailsList) {
      if (purchaseDetails.status == PurchaseStatus.pending) {
        _startPurchaseStartTimeout();
        if (!mounted) continue;
        setState(() => _isPurchasing = true);
      } else if (purchaseDetails.status == PurchaseStatus.purchased ||
          purchaseDetails.status == PurchaseStatus.restored) {
        _clearPurchaseStartTimeout();
        if (_isRestoring) {
          _receivedRestoreEvent = true;
          _isRestoring = false;
        }
        _verifyPurchase(purchaseDetails.status);
      } else if (purchaseDetails.status == PurchaseStatus.canceled) {
        _clearPurchaseStartTimeout();
        if (!mounted) continue;
        setState(() {
          _isPurchasing = false;
          _isRestoring = false;
          _errorMessage = '결제가 취소되었습니다.';
        });
      } else if (purchaseDetails.status == PurchaseStatus.error) {
        _clearPurchaseStartTimeout();
        if (!mounted) continue;
        setState(() {
          _isPurchasing = false;
          _isRestoring = false;
          _errorMessage = '결제 중 오류가 발생했습니다.';
        });
      }
      if (purchaseDetails.pendingCompletePurchase) {
        unawaited(_completePendingPurchase(purchaseDetails));
      }
    }
  }

  Future<void> _completePendingPurchase(PurchaseDetails purchaseDetails) async {
    try {
      await _inAppPurchase.completePurchase(purchaseDetails);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = '결제 완료 처리 중 오류가 발생했습니다.');
    }
  }

  void _verifyPurchase(PurchaseStatus status) {
    _clearPurchaseStartTimeout();
    if (!mounted) return;
    setState(() {
      _isPurchasing = false;
      _isRestoring = false;
      _isDonationCompleted = true;
    });
    unawaited(_saveDonationState(true));
    final message = status == PurchaseStatus.restored
        ? '후원 내역을 복원했어요. 감사합니다! 더 열심히 만들게요 🙇'
        : '후원 감사합니다! 더 열심히 만들게요 🙇';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _initializePurchase() async {
    if (!mounted) return;
    setState(() {
      _isLoadingProducts = true;
      _errorMessage = null;
    });

    try {
      _isAvailable = await _inAppPurchase.isAvailable();
      if (!_isAvailable) {
        if (!mounted) return;
        setState(() {
          _products = [];
          _errorMessage = '인앱 결제를 사용할 수 없습니다.\n잠시 후 다시 시도해주세요.';
        });
        return;
      }

      const productIds = {'donation_1000'};
      final response = await _inAppPurchase.queryProductDetails(productIds);

      if (!mounted) return;
      if (response.error != null) {
        setState(() {
          _products = [];
          _errorMessage =
              '상품 정보를 불러오는 중 오류가 발생했습니다.\n${response.error!.message}';
        });
        return;
      }

      if (response.notFoundIDs.isNotEmpty) {
        setState(() {
          _products = [];
          _errorMessage =
              '상품이 등록되지 않았습니다.\nApp Store Connect에서\n상품 ID "donation_1000"을 확인해주세요.';
        });
        return;
      }

      if (response.productDetails.isEmpty) {
        setState(() {
          _products = [];
          _errorMessage = '상품 정보를 불러올 수 없습니다.\n잠시 후 다시 시도해주세요.';
        });
        return;
      }

      setState(() {
        _products = response.productDetails;
        _errorMessage = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _products = [];
        _errorMessage = '상품 정보를 불러오는 중 오류가 발생했습니다.\n잠시 후 다시 시도해주세요.';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoadingProducts = false);
      }
    }
  }

  Future<void> _restorePurchases() async {
    if (_isPurchasing || _isRestoring || _isLoadingProducts) return;
    if (!mounted) return;
    setState(() {
      _isRestoring = true;
      _errorMessage = null;
    });
    _receivedRestoreEvent = false;

    try {
      await _inAppPurchase.restorePurchases();
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      if (_isRestoring && !_receivedRestoreEvent) {
        setState(() {
          _isRestoring = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('복원할 후원 내역이 없어요.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isRestoring = false;
        _errorMessage = '구매 복원 중 오류가 발생했습니다.';
      });
    }
  }

  Future<void> _loadDonationState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final completed = prefs.getBool(_kDonationCompletedKey) ?? false;
      if (!mounted) return;
      setState(() => _isDonationCompleted = completed);
    } catch (_) {}
  }

  Future<void> _saveDonationState(bool completed) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDonationCompletedKey, completed);
    } catch (_) {}
  }

  Future<void> _buyProduct(ProductDetails productDetails) async {
    if (_isPurchasing || _isRestoring || _isLoadingProducts) return;
    if (!mounted) return;
    setState(() {
      _isPurchasing = true;
      _errorMessage = null;
    });
    _startPurchaseStartTimeout();

    try {
      final success = await _inAppPurchase.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: productDetails),
      );
      if (!success) {
        _clearPurchaseStartTimeout();
        if (!mounted) return;
        setState(() {
          _isPurchasing = false;
          _errorMessage = '결제를 시작할 수 없습니다.';
        });
      }
    } catch (_) {
      _clearPurchaseStartTimeout();
      if (!mounted) return;
      setState(() {
        _isPurchasing = false;
        _errorMessage = '결제 중 오류가 발생했습니다.';
      });
    }
  }

  void _startPurchaseStartTimeout() {
    _purchaseStartTimeout?.cancel();
    _isAwaitingPurchaseUpdate = true;
    _purchaseStartTimeout = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      if (_isPurchasing && _isAwaitingPurchaseUpdate) {
        setState(() {
          _isPurchasing = false;
          _isAwaitingPurchaseUpdate = false;
          _errorMessage = '결제가 취소되었거나 응답이 지연되었습니다. 다시 시도해주세요.';
        });
      }
    });
  }

  void _clearPurchaseStartTimeout() {
    _purchaseStartTimeout?.cancel();
    _purchaseStartTimeout = null;
    _isAwaitingPurchaseUpdate = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFF5F8),
        elevation: 0,
        centerTitle: false,
        titleSpacing: 0,
        title: const Text(
          '후원하기',
          style: TextStyle(
            color: Color(0xFF7E4C5F),
            fontWeight: FontWeight.w800,
            fontSize: 19,
            letterSpacing: -0.1,
          ),
        ),
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildDonateCard(),
            if (kDebugMode) ...[
              const SizedBox(height: 20),
              _buildDebugDbCard(),
            ],
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFFFCE4EC),
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.shot,
            onShotTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
            onDiaryTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DiaryPage()),
              );
            },
            onBackupTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BackupPage()),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDonateCard() {
    return Container(
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
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFFFC0CB).withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.coffee, color: Color(0xFFFFC0CB), size: 48),
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
            style: TextStyle(fontSize: 15, color: Colors.grey, height: 1.5),
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
          if (_isLoadingProducts)
            const Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 10),
                Text(
                  '상품 정보를 불러오는 중...',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            )
          else
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _products.isNotEmpty &&
                            !_isDonationCompleted &&
                            !_isPurchasing &&
                            !_isRestoring &&
                            !_isLoadingProducts
                        ? () => _buyProduct(_products.first)
                        : null,
                    icon: Icon(
                      _isDonationCompleted
                          ? Icons.favorite
                          : _isPurchasing
                          ? Icons.hourglass_top_rounded
                          : Icons.coffee,
                      size: 22,
                    ),
                    label: Text(
                      _isDonationCompleted
                          ? '후원 감사합니다 💕'
                          : _isPurchasing
                          ? '결제 진행 중...'
                          : '천원 후원하기',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (_isDonationCompleted) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '이미 1회 후원이 완료된 계정이에요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xFF8F6B7A)),
                  ),
                ],
                const SizedBox(height: 14),
                _buildSupportActions(),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildSupportActions() {
    final canTapActions = !_isPurchasing && !_isRestoring && !_isLoadingProducts;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF2D7E2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '이미 구매하셨거나 상품이 보이지 않으면\n아래 버튼으로 다시 확인해주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF8F6B7A),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 360;
              final restoreButton = OutlinedButton.icon(
                onPressed: canTapActions ? _restorePurchases : null,
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: Text(
                  _isRestoring ? '복원 중...' : '구매 복원',
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF7E4C5F),
                  side: const BorderSide(color: Color(0xFFE8C7D5)),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
              );

              final reloadButton = OutlinedButton.icon(
                onPressed: canTapActions ? _initializePurchase : null,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(
                  _isLoadingProducts ? '불러오는 중...' : '다시 불러오기',
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF7E4C5F),
                  side: const BorderSide(color: Color(0xFFE8C7D5)),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                ),
              );

              if (isCompact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    restoreButton,
                    const SizedBox(height: 8),
                    reloadButton,
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: restoreButton),
                  const SizedBox(width: 8),
                  Expanded(child: reloadButton),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDebugDbCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '데이터베이스 상태 (디버그)',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _checkDatabaseStatus,
            icon: const Icon(Icons.storage, size: 20),
            label: const Text('DB 상태 확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkDatabaseStatus() async {
    try {
      final status = await PetgramDatabase.instance.checkDatabaseStatus();
      final recentRecords = await PetgramPhotoRepository.instance.listRecent(
        limit: 5,
      );

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('데이터베이스 상태'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatusRow(
                  '테이블 존재',
                  status['table_exists'] == true ? '✅' : '❌',
                ),
                _buildStatusRow('레코드 개수', '${status['record_count'] ?? 0}개'),
                _buildStatusRow(
                  'DB 경로',
                  status['db_path']?.toString() ?? 'N/A',
                ),
                _buildStatusRow('DB 버전', '${status['db_version'] ?? 'N/A'}'),
                const SizedBox(height: 12),
                Text(
                  '최근 레코드 (${recentRecords.length}개):',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('DB 상태 확인 실패: $e')));
    }
  }

  Widget _buildStatusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
