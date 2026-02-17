package com.example.mark_v2

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.MethodChannel
import android.media.ExifInterface
import java.io.IOException

class MainActivity : FlutterActivity(), LifecycleOwner {
    private val EXIF_CHANNEL = "petgram_exif"
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // NativeCamera PlatformView 등록
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "petgram/native_camera_preview",
            NativeCameraFactory(flutterEngine.dartExecutor.binaryMessenger, this)
        )
        
        // EXIF MethodChannel 등록
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXIF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "writeUserComment" -> handleWriteUserComment(call, result)
                    "readUserComment" -> handleReadUserComment(call, result)
                    else -> result.notImplemented()
                }
            }
    }
    
    private fun handleWriteUserComment(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val comment = call.argument<String>("comment")
        
        if (path == null || comment == null) {
            result.success(mapOf("success" to false))
            return
        }
        
        try {
            val exif = ExifInterface(path)
            exif.setAttribute(ExifInterface.TAG_USER_COMMENT, comment)
            exif.saveAttributes()
            result.success(mapOf("success" to true))
        } catch (e: IOException) {
            e.printStackTrace()
            result.success(mapOf("success" to false))
        } catch (e: Exception) {
            e.printStackTrace()
            result.success(mapOf("success" to false))
        }
    }
    
    private fun handleReadUserComment(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        
        if (path == null) {
            result.success(mapOf("comment" to null))
            return
        }
        
        try {
            val exif = ExifInterface(path)
            val comment = exif.getAttribute(ExifInterface.TAG_USER_COMMENT)
            
            if (comment.isNullOrEmpty()) {
                result.success(mapOf("comment" to null))
            } else {
                result.success(mapOf("comment" to comment))
            }
        } catch (e: IOException) {
            e.printStackTrace()
            result.success(mapOf("comment" to null))
        } catch (e: Exception) {
            e.printStackTrace()
            result.success(mapOf("comment" to null))
        }
    }
}
