package com.example.mark_v2

import android.content.Context
import android.view.View
import android.widget.FrameLayout
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class NativeCamera(
    private val context: Context,
    private val viewId: Int,
    private val messenger: BinaryMessenger,
    private val lifecycleOwner: androidx.lifecycle.LifecycleOwner? = null
) : PlatformView, MethodChannel.MethodCallHandler {
    
    private val methodChannel = MethodChannel(messenger, "petgram/native_camera")
    private val containerView: FrameLayout = FrameLayout(context)
    private val previewView: PreviewView = PreviewView(context)
    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var camera: Camera? = null
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    
    init {
        containerView.addView(previewView)
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
    
    override fun getView(): View = containerView
    
    override fun dispose() {
        cameraProvider?.unbindAll()
        cameraExecutor.shutdown()
        methodChannel.setMethodCallHandler(null)
    }
    
    // MARK: - 카메라 초기화
    
    private fun initializeCamera(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val cameraPositionStr = args["cameraPosition"] as? String ?: "back"
        lensFacing = if (cameraPositionStr == "front") {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        
        cameraProviderFuture.addListener({
            try {
                val cameraProvider = cameraProviderFuture.get()
                
                // Preview 설정
                val preview = Preview.Builder()
                    .build()
                    .also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                
                // ImageCapture 설정
                imageCapture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                    .build()
                
                // CameraSelector
                val cameraSelector = CameraSelector.Builder()
                    .requireLensFacing(lensFacing)
                    .build()
                
                // 카메라 바인딩 (생성자에서 전달받은 lifecycleOwner 사용)
                val owner = lifecycleOwner ?: (context as? androidx.lifecycle.LifecycleOwner)
                if (owner != null) {
                    camera = cameraProvider.bindToLifecycle(
                        owner,
                        cameraSelector,
                        preview,
                        imageCapture
                    )
                } else {
                    result.error("NO_LIFECYCLE_OWNER", "LifecycleOwner is required", null)
                    return@addListener
                }
                
                this.cameraProvider = cameraProvider
                
                // 카메라 정보 가져오기
                val cameraInfo = camera?.cameraInfo
                val sensorSize = cameraInfo?.sensorRotationDegrees?.let {
                    // 실제 센서 크기는 CameraInfo에서 가져올 수 없으므로
                    // 일반적인 해상도 사용 (실제로는 카메라마다 다름)
                    android.util.Size(1920, 1080) // 기본값
                } ?: android.util.Size(1920, 1080)
                
                val aspectRatio = sensorSize.width.toDouble() / sensorSize.height.toDouble()
                
                result(mapOf(
                    "isInitialized" to true,
                    "aspectRatio" to aspectRatio,
                    "previewWidth" to sensorSize.width,
                    "previewHeight" to sensorSize.height
                ))
                
                android.util.Log.d("Petgram", "✅ Android camera initialized: position=$cameraPositionStr, aspectRatio=$aspectRatio")
            } catch (e: Exception) {
                result.error("INIT_FAILED", e.message, null)
                android.util.Log.e("Petgram", "❌ Android camera init error: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }
    
    // MARK: - 카메라 해제
    
    private fun disposeCamera(result: MethodChannel.Result) {
        cameraProvider?.unbindAll()
        cameraProvider = null
        imageCapture = null
        camera = null
        result.success(null)
        android.util.Log.d("Petgram", "✅ Android camera disposed")
    }
    
    // MARK: - 카메라 전환
    
    private fun switchCamera(result: MethodChannel.Result) {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        
        cameraProvider?.unbindAll()
        
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            try {
                val cameraProvider = cameraProviderFuture.get()
                
                val preview = Preview.Builder()
                    .build()
                    .also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                
                imageCapture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                    .build()
                
                val cameraSelector = CameraSelector.Builder()
                    .requireLensFacing(lensFacing)
                    .build()
                
                val lifecycleOwner = (context as? androidx.lifecycle.LifecycleOwner)
                if (lifecycleOwner != null) {
                    camera = cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        cameraSelector,
                        preview,
                        imageCapture
                    )
                } else {
                    result.error("NO_LIFECYCLE_OWNER", "Context is not a LifecycleOwner", null)
                    return@addListener
                }
                
                this.cameraProvider = cameraProvider
                
                val sensorSize = android.util.Size(1920, 1080) // 기본값
                val aspectRatio = sensorSize.width.toDouble() / sensorSize.height.toDouble()
                
                result(mapOf(
                    "aspectRatio" to aspectRatio,
                    "previewWidth" to sensorSize.width,
                    "previewHeight" to sensorSize.height
                ))
                
                android.util.Log.d("Petgram", "✅ Android camera switched to: ${if (lensFacing == CameraSelector.LENS_FACING_BACK) "back" else "front"}")
            } catch (e: Exception) {
                result.error("SWITCH_FAILED", e.message, null)
            }
        }, ContextCompat.getMainExecutor(context))
    }
    
    // MARK: - 플래시 모드
    
    private fun setFlashMode(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val modeStr = args["mode"] as? String ?: "off"
        
        val flashMode = when (modeStr) {
            "off" -> ImageCapture.FLASH_MODE_OFF
            "on", "torch" -> ImageCapture.FLASH_MODE_ON
            "auto" -> ImageCapture.FLASH_MODE_AUTO
            else -> ImageCapture.FLASH_MODE_OFF
        }
        
        imageCapture?.flashMode = flashMode
        result.success(null)
        android.util.Log.d("Petgram", "✅ Android flash mode set to: $modeStr")
    }
    
    // MARK: - 줌
    
    private fun setZoom(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val zoom = (args["zoom"] as? Number)?.toFloat() ?: 1.0f
        
        val cameraControl = camera?.cameraControl
        val zoomState = camera?.cameraInfo?.zoomState?.value
        
        if (cameraControl != null && zoomState != null) {
            val minZoom = zoomState.minZoomRatio
            val maxZoom = minOf(zoomState.maxZoomRatio, 10.0f)
            val clampedZoom = zoom.coerceIn(minZoom, maxZoom)
            
            cameraControl.setZoomRatio(clampedZoom)
            result.success(null)
        } else {
            result.error("ZOOM_FAILED", "Camera not initialized", null)
        }
    }
    
    // MARK: - 포커스 포인트
    
    private fun setFocusPoint(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val x = (args["x"] as? Number)?.toFloat() ?: 0.5f
        val y = (args["y"] as? Number)?.toFloat() ?: 0.5f
        
        val cameraControl = camera?.cameraControl
        if (cameraControl != null) {
            val focusPoint = androidx.camera.core.FocusMeteringPointFactory.createPoint(
                x, y,
                androidx.camera.core.FocusMeteringPointFactory.getDefaultSize()
            )
            val action = androidx.camera.core.FocusMeteringAction.Builder(focusPoint).build()
            cameraControl.startFocusAndMetering(action)
            result.success(null)
            android.util.Log.d("Petgram", "✅ Android focus point set: ($x, $y)")
        } else {
            result.error("FOCUS_FAILED", "Camera not initialized", null)
        }
    }
    
    // MARK: - 노출 포인트
    
    private fun setExposurePoint(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val x = (args["x"] as? Number)?.toFloat() ?: 0.5f
        val y = (args["y"] as? Number)?.toFloat() ?: 0.5f
        
        val cameraControl = camera?.cameraControl
        if (cameraControl != null) {
            val exposurePoint = androidx.camera.core.FocusMeteringPointFactory.createPoint(
                x, y,
                androidx.camera.core.FocusMeteringPointFactory.getDefaultSize()
            )
            val action = androidx.camera.core.FocusMeteringAction.Builder(exposurePoint)
                .setAutoCancelDuration(5, java.util.concurrent.TimeUnit.SECONDS)
                .build()
            cameraControl.startFocusAndMetering(action)
            result.success(null)
            android.util.Log.d("Petgram", "✅ Android exposure point set: ($x, $y)")
        } else {
            result.error("EXPOSURE_FAILED", "Camera not initialized", null)
        }
    }
    
    // MARK: - 사진 촬영
    
    private fun takePicture(result: MethodChannel.Result) {
        val imageCapture = this.imageCapture ?: run {
            result.error("NOT_INITIALIZED", "Camera not initialized", null)
            return
        }
        
        val outputFileOptions = ImageCapture.OutputFileOptions.Builder(
            File(context.cacheDir, "petgram_${System.currentTimeMillis()}.jpg")
        ).build()
        
        imageCapture.takePicture(
            outputFileOptions,
            cameraExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val filePath = outputFileOptions.outputFileOptions.savedUri?.path
                        ?: (outputFileOptions.outputFileOptions.file as? File)?.absolutePath
                    
                    if (filePath != null) {
                        result.success(filePath)
                        android.util.Log.d("Petgram", "✅ Android picture taken: $filePath")
                    } else {
                        result.error("NO_FILE_PATH", "File path is null", null)
                    }
                }
                
                override fun onError(exception: ImageCaptureException) {
                    result.error("CAPTURE_FAILED", exception.message, null)
                    android.util.Log.e("Petgram", "❌ Android capture error: ${exception.message}")
                }
            }
        )
    }
}

// PlatformViewFactory
class NativeCameraFactory(
    private val messenger: BinaryMessenger,
    private val lifecycleOwner: androidx.lifecycle.LifecycleOwner? = null
) : io.flutter.plugin.platform.PlatformViewFactory(io.flutter.plugin.common.StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return NativeCamera(context, viewId, messenger, lifecycleOwner)
    }
}

