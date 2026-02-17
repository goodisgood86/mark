import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'services/petgram_supabase_sync_service.dart';
import 'services/petgram_db.dart';
import 'widgets/permission_wrapper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // iOS는 LaunchScreen + flutter_native_splash preserve를 함께 쓰면
  // "스플래시 -> 빈 화면 -> 스플래시"처럼 보이는 이중 전환이 발생할 수 있어 비활성화한다.
  if (!Platform.isIOS) {
    FlutterNativeSplash.preserve(widgetsBinding: WidgetsBinding.instance);
  }

  List<CameraDescription> cameras = const [];

  // ⚠️ iOS에서는 네이티브 AVFoundation 카메라를 사용하므로
  //    camera 플러그인의 availableCameras()를 호출하지 않는다.
  //    (불필요한 세션/권한 충돌 가능성을 줄이기 위함)
  if (!Platform.isIOS) {
    try {
      cameras = await availableCameras();
      if (kDebugMode) {
        debugPrint(
          '[Petgram] main(): availableCameras length=${cameras.length}',
        );
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('[Petgram] main(): availableCameras failed → $e');
        debugPrint('[Petgram] stacktrace: $s');
      }
    }
  }

  try {
    await PetgramSupabaseSyncService.instance
        .ensureInitializedFromEnvironment();
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[Petgram] Supabase init skipped: $e');
    }
  }

  runApp(PetgramApp(cameras: cameras));

  // DB 초기화는 앱 시작 안정화 이후로 지연한다.
  // 카메라 첫 진입 경합을 줄이기 위해 시작 직후 heavy debug 점검은 하지 않는다.
  Future.delayed(const Duration(seconds: 3), () async {
    try {
      await PetgramDatabase.instance.database;

      // 상세 상태 점검은 더 늦게, 비차단으로 수행
      if (kDebugMode) {
        Future.delayed(const Duration(seconds: 10), () {
          unawaited(PetgramDatabase.instance.checkDatabaseStatus());
        });
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('[Petgram] ❌ Database initialization error: $e');
        debugPrint('[Petgram] ❌ Stack trace: $s');
      }
      // Release 빌드에서는 에러를 조용히 처리
    }
  });
}

class PetgramApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const PetgramApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    const primaryPink = Color(0xFFDE8AA8);
    const deepRose = Color(0xFF7E4C5F);

    return MaterialApp(
      title: 'Petgram',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryPink,
          primary: primaryPink,
          secondary: const Color(0xFFF3B5C8),
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFFFF5F8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFF5F8),
          foregroundColor: Colors.black,
          elevation: 0,
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: deepRose,
            side: const BorderSide(color: Color(0xFFE3A0B7)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primaryPink,
            foregroundColor: Colors.white,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primaryPink;
            return null;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return primaryPink.withValues(alpha: 0.4);
            }
            return null;
          }),
        ),
        useMaterial3: true,
      ),
      home: PermissionWrapper(cameras: cameras),
    );
  }
}
