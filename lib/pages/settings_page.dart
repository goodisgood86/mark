import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/constants.dart';
import '../services/petgram_db.dart';
import '../services/petgram_photo_repository.dart';
import '../models/petgram_nav_tab.dart';
import '../widgets/petgram_bottom_nav_bar.dart';
import 'diary_page.dart';

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
    const Set<String> productIds = {'donation_1000.0'};

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
            '상품이 등록되지 않았습니다.\nGoogle Play Console / App Store Connect에서\n상품 ID "donation_1000.0"을 등록해주세요.';
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
      body: SafeArea(
        top: true,
        bottom: false,
        child: ListView(
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

            // 디버그 모드에서만 DB 상태 확인 섹션 표시
            if (kDebugMode) ...[
              const SizedBox(height: 20),
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
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[600],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFFFCE4EC), // SafeArea bottom 포함 전체 백그라운드
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.shot,
            onShotTap: () {
              // SettingsPage에서 Shot으로 돌아가기
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
            onDiaryTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DiaryPage()),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 데이터베이스 상태 확인 (디버그용)
  Future<void> _checkDatabaseStatus() async {
    try {
      // DB 상태 확인
      final status = await PetgramDatabase.instance.checkDatabaseStatus();

      // 최근 레코드 조회
      final recentRecords = await PetgramPhotoRepository.instance.listRecent(
        limit: 5,
      );

      // 결과를 다이얼로그로 표시
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
                if (status['indexes'] != null) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '인덱스:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  ...((status['indexes'] as List?) ?? []).map(
                    (idx) => Text('  • $idx'),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  '최근 레코드 (${recentRecords.length}개):',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (recentRecords.isEmpty)
                  const Text(
                    '저장된 레코드가 없습니다.',
                    style: TextStyle(color: Colors.grey),
                  )
                else
                  ...recentRecords.map(
                    (record) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '  • ID: ${record.id}, 파일: ${record.filePath.split('/').last}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('DB 상태 확인 실패: $e'), backgroundColor: Colors.red),
      );
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

/// ========================
///  프레임 설정 화면
/// ========================
