# 네이티브 카메라 구현 가이드

이 문서는 Flutter `camera` 패키지를 iOS/Android 네이티브 카메라로 교체하기 위한 구현 가이드입니다.

## 현재 상태

- ✅ Flutter 인터페이스 정의 완료 (`lib/camera/native_camera_interface.dart`)
- ✅ MethodChannel 브리지 완료 (`lib/camera/native_camera_controller.dart`)
- ✅ PlatformView 프리뷰 위젯 완료 (`lib/camera/native_camera_preview.dart`)
- ⏳ iOS 네이티브 구현 필요
- ⏳ Android 네이티브 구현 필요
- ⏳ main.dart 통합 필요

## 구현 단계

### 1. iOS 네이티브 구현

#### 1.1 NativeCamera.swift 파일 생성

`ios/Runner/NativeCamera.swift` 파일을 생성하고 다음 구조로 구현:

```swift
import Flutter
import UIKit
import AVFoundation

class NativeCamera: NSObject, FlutterPlugin, FlutterPlatformViewFactory {
    static func register(with registrar: FlutterPluginRegistrar) {
        // MethodChannel 등록
        let channel = FlutterMethodChannel(
            name: "petgram/native_camera",
            binaryMessenger: registrar.messenger()
        )
        let instance = NativeCamera()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        // PlatformView 등록
        registrar.register(
            instance,
            withId: "petgram/native_camera_preview"
        )
    }
    
    // AVCaptureSession 관리
    private var captureSession: AVCaptureSession?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var photoOutput: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    // MethodChannel 핸들러 구현
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            initializeCamera(call: call, result: result)
        case "dispose":
            disposeCamera(result: result)
        case "switchCamera":
            switchCamera(result: result)
        case "setFlashMode":
            setFlashMode(call: call, result: result)
        case "setZoom":
            setZoom(call: call, result: result)
        case "setFocusPoint":
            setFocusPoint(call: call, result: result)
        case "setExposurePoint":
            setExposurePoint(call: call, result: result)
        case "takePicture":
            takePicture(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // 각 메서드 구현...
}
```

#### 1.2 AppDelegate.swift 수정

```swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // NativeCamera 등록
    if let registrar = self.registrar(forPlugin: "NativeCamera") {
        NativeCamera.register(with: registrar)
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

#### 1.3 Info.plist 권한 추가

```xml
<key>NSCameraUsageDescription</key>
<string>사진 촬영을 위해 카메라 권한이 필요합니다.</string>
```

### 2. Android 네이티브 구현

#### 2.1 NativeCamera.kt 파일 생성

`android/app/src/main/kotlin/com/example/mark_v2/NativeCamera.kt` 파일 생성:

```kotlin
package com.example.mark_v2

import android.content.Context
import android.view.View
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.platform.PlatformView
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class NativeCamera(
    private val context: Context,
    private val viewId: Int,
    private val messenger: BinaryMessenger
) : PlatformView, MethodChannel.MethodCallHandler {
    
    private val methodChannel = MethodChannel(messenger, "petgram/native_camera")
    private val previewView: PreviewView = PreviewView(context)
    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var camera: Camera? = null
    
    init {
        methodChannel.setMethodCallHandler(this)
    }
    
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initializeCamera(call, result)
            "dispose" -> disposeCamera(result)
            "switchCamera" -> switchCamera(result)
            "setFlashMode" -> setFlashMode(call, result)
            "setZoom" -> setZoom(call, result)
            "setFocusPoint" -> setFocusPoint(call, result)
            "setExposurePoint" -> setExposurePoint(call, result)
            "takePicture" -> takePicture(result)
            else -> result.notImplemented()
        }
    }
    
    override fun getView(): View = previewView
    
    override fun dispose() {
        // 리소스 정리
    }
    
    // 각 메서드 구현...
}
```

#### 2.2 MainActivity.kt 수정

```kotlin
package com.example.mark_v2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // NativeCamera PlatformView 등록
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "petgram/native_camera_preview",
            NativeCameraFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
    }
}
```

#### 2.3 build.gradle.kts 의존성 추가

```kotlin
dependencies {
    // CameraX
    implementation("androidx.camera:camera-core:1.3.0")
    implementation("androidx.camera:camera-camera2:1.3.0")
    implementation("androidx.camera:camera-lifecycle:1.3.0")
    implementation("androidx.camera:camera-view:1.3.0")
}
```

#### 2.4 AndroidManifest.xml 권한 추가

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
```

### 3. main.dart 통합

#### 3.1 import 추가

```dart
import 'camera/native_camera_interface.dart';
import 'camera/native_camera_controller.dart';
import 'camera/native_camera_preview.dart';
```

#### 3.2 필드 변경

```dart
// 기존
CameraController? _cameraController;

// 변경
IPetgramCamera? _nativeCamera;
```

#### 3.3 _initCamera() 수정

```dart
Future<void> _initCamera() async {
  try {
    _nativeCamera = NativeCameraController();
    await _nativeCamera!.initialize(
      cameraPosition: _cameraLensDirection == CameraLensDirection.back 
          ? 'back' 
          : 'front',
      aspectRatio: aspectRatioOf(_aspectMode),
    );
    
    _nativeCamera!.addListener(_onCameraValueChanged);
    
    setState(() {
      _isCameraInitializing = false;
      _useMockCamera = false;
    });
  } catch (e) {
    // 실패 시 mock 모드로 전환
    setState(() {
      _isCameraInitializing = false;
      _useMockCamera = true;
      _nativeCamera = null;
    });
  }
}
```

#### 3.4 프리뷰 위젯 교체

```dart
// 기존
final Widget source = canUseCamera
    ? CameraPreview(_cameraController!)
    : Image.asset(...);

// 변경
final Widget source = canUseCamera
    ? NativeCameraPreview(
        onCreated: (viewId) {
          // PlatformView 생성 완료
        },
      )
    : Image.asset(...);
```

#### 3.5 촬영 로직 수정

```dart
// 기존
final XFile xfile = await _cameraController!.takePicture();
file = File(xfile.path);

// 변경
final String imagePath = await _nativeCamera!.takePicture();
file = File(imagePath);
```

## 주의사항

1. **기존 기능 유지**: UI, 레이아웃, 필터, 저장 파이프라인은 모두 그대로 유지
2. **Mock 모드**: 네이티브 초기화 실패 시 자동으로 mock 모드로 전환
3. **좌표 매핑**: `CameraMappingUtils`와 `_lastPreviewRect` 로직 유지
4. **로그**: `[Petgram]` 접두어 유지

## 테스트 체크리스트

- [ ] iOS에서 1:1, 3:4, 9:16 모드 동작
- [ ] Android에서 1:1, 3:4, 9:16 모드 동작
- [ ] 전면/후면 카메라 전환
- [ ] 플래시 모드 (off/auto/on)
- [ ] 탭 포커스 동작
- [ ] 촬영 후 필터/저장 파이프라인 정상 동작
- [ ] Mock 모드 정상 동작
- [ ] 권한 거부 시 Mock 모드로 전환

