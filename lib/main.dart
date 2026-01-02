import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'pages/home_page.dart';
import 'services/petgram_db.dart';

Future<void> main() async {
  // 🔥🔥🔥 preserve()를 호출하지 않음: iOS가 자동으로 스플래시를 제거하도록 함
  // HomePage의 build()에서 명시적으로 제거하되, preserve() 없이도 작동하도록 함
  WidgetsFlutterBinding.ensureInitialized();

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

  // 🔥 스플래시 멈춤 방지: runApp을 먼저 호출하여 첫 프레임이 렌더링되도록 함
  // DB 초기화는 runApp 이후에 비동기로 처리
  runApp(PetgramApp(cameras: cameras));
  
  // 🔥 스플래시 제거: HomePage의 첫 build()가 완료되면 자동으로 제거됨
  // main.dart에서는 제거하지 않고, HomePage에서만 제거하도록 변경
  
  // 🔥 DB 초기화는 runApp 이후에 비동기로 처리 (블로킹 방지)
  // 첫 프레임이 렌더링된 후에 실행되도록 지연
  Future.delayed(const Duration(milliseconds: 200), () async {
    try {
      // DB 인스턴스 초기화 (지연 초기화이므로 여기서는 접근만 함)
      await PetgramDatabase.instance.database;

      // 디버그 모드에서만 DB 상태 확인 및 로그 출력
      if (kDebugMode) {
        debugPrint('[Petgram] 🔍 Database initialized, checking status...');
        await PetgramDatabase.instance.checkDatabaseStatus();
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
