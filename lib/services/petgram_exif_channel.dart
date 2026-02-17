import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// Petgram EXIF 메타데이터 네이티브 채널
///
/// iOS/Android 네이티브 EXIF API를 통해 UserComment를 읽고 쓴다.
class PetgramExifChannel {
  static const MethodChannel _channel = MethodChannel('petgram_exif');

  /// jpegBytes를 임시 파일에 쓰고, EXIF UserComment를 추가한 뒤
  /// 다시 bytes로 읽어와 반환한다.
  ///
  /// [jpegBytes]: 원본 JPEG 바이트
  /// [comment]: EXIF UserComment에 쓸 문자열
  ///
  /// 반환: EXIF UserComment가 추가된 JPEG 바이트 (실패 시 원본 반환)
  static Future<Uint8List> writeUserCommentToBytes({
    required Uint8List jpegBytes,
    required String comment,
  }) async {
    // 1) 임시 파일 생성
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(
      '${tempDir.path}/pg_exif_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );

    try {
      await tempFile.writeAsBytes(jpegBytes, flush: true);

      // 2) 네이티브로 EXIF UserComment 쓰기
      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] 📝 Calling native writeUserComment: path=${tempFile.path}, comment length=${comment.length}',
        );
      }

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'writeUserComment',
        {'path': tempFile.path, 'comment': comment},
      );

      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] 📝 Native writeUserComment result: $result',
        );
        if (result != null) {
          result.forEach((key, value) {
            debugPrint('[PetgramExifChannel]   $key: $value');
          });
        }
      }

      final success = result?['success'] == true;
      if (!success) {
        if (kDebugMode) {
          debugPrint('[PetgramExifChannel] ⚠️ writeUserComment failed');
          debugPrint('[PetgramExifChannel] ⚠️ Result: $result');
        }
        // 실패 시 원본 bytes 반환
        return jpegBytes;
      }

      if (kDebugMode) {
        debugPrint('[PetgramExifChannel] ✅ writeUserComment succeeded');
      }

      // 3) 수정된 파일 다시 읽어서 반환
      final updatedBytes = await tempFile.readAsBytes();

      // 🔥 검증: 업데이트된 바이트가 비어있지 않은지 확인
      if (updatedBytes.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramExifChannel] ⚠️ WARNING: Updated bytes are empty! Returning original bytes.',
          );
        }
        return jpegBytes; // 원본 반환
      }

      // 🔥 검증: 업데이트된 바이트 크기가 원본보다 너무 작으면 원본 반환
      if (updatedBytes.length < jpegBytes.length * 0.5) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramExifChannel] ⚠️ WARNING: Updated bytes (${updatedBytes.length}) is too small compared to original (${jpegBytes.length}). Returning original bytes.',
          );
        }
        return jpegBytes; // 원본 반환
      }

      // 🔥 EXIF가 실제로 저장되었는지 즉시 검증
      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] 🔍 Verifying EXIF was written: reading from temp file...',
        );
      }

      final verifyResult = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readUserComment',
        {'path': tempFile.path},
      );

      final verifiedComment = verifyResult?['comment'] as String?;
      if (verifiedComment != null && verifiedComment.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramExifChannel] ✅ EXIF verified: length=${verifiedComment.length}',
          );
          debugPrint(
            '[PetgramExifChannel] ✅ EXIF attach result: ${jpegBytes.length ~/ 1024}KB -> ${updatedBytes.length ~/ 1024}KB',
          );
        }
        return Uint8List.fromList(updatedBytes);
      } else {
        if (kDebugMode) {
          debugPrint(
            '[PetgramExifChannel] ⚠️ WARNING: EXIF verification failed! Comment is null or empty.',
          );
          debugPrint(
            '[PetgramExifChannel] ⚠️ Verification result: $verifyResult',
          );
        }
        // EXIF 검증 실패 시 원본 반환
        return jpegBytes;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[PetgramExifChannel] ❌ writeUserComment error: $e');
        debugPrint('$st');
      }
      return jpegBytes;
    } finally {
      // 임시 파일 정리 (선택적, 메모리 절약)
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (e) {
        // 삭제 실패는 무시
      }
    }
  }

  /// jpegBytes를 임시 파일에 쓰고, EXIF UserComment를 읽어온 뒤
  /// 문자열을 반환한다. 없으면 null.
  ///
  /// [jpegBytes]: JPEG 바이트
  ///
  /// 반환: EXIF UserComment 문자열 또는 null (읽기 실패 시)
  static Future<String?> readUserCommentFromBytes(Uint8List jpegBytes) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(
      '${tempDir.path}/pg_exif_read_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );

    try {
      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] 📖 Reading EXIF from ${jpegBytes.length} bytes',
        );
      }

      await tempFile.writeAsBytes(jpegBytes, flush: true);

      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] 📖 Temp file created: ${tempFile.path}',
        );
        final fileSize = await tempFile.length();
        debugPrint(
          '[PetgramExifChannel] 📖 Temp file size: ${fileSize ~/ 1024}KB',
        );
      }

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'readUserComment',
        {'path': tempFile.path},
      );

      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] 📖 Native readUserComment result: $result',
        );
      }

      final comment = result?['comment'] as String?;
      if (comment == null || comment.isEmpty) {
        if (kDebugMode) {
          debugPrint(
            '[PetgramExifChannel] ⚠️ EXIF UserComment is null or empty',
          );
          if (result != null) {
            debugPrint('[PetgramExifChannel] 📖 Result keys: ${result.keys}');
            result.forEach((key, value) {
              debugPrint('[PetgramExifChannel]   $key: $value');
            });
          }
        }
        return null;
      }

      if (kDebugMode) {
        debugPrint(
          '[PetgramExifChannel] ✅ EXIF UserComment read: length=${comment.length}',
        );
        debugPrint(
          '[PetgramExifChannel] ✅ First 100 chars: ${comment.substring(0, comment.length > 100 ? 100 : comment.length)}',
        );
      }

      return comment;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[PetgramExifChannel] ❌ readUserComment error: $e');
        debugPrint('[PetgramExifChannel] ❌ Stack trace: $st');
      }
      return null;
    } finally {
      // 임시 파일 정리
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (e) {
        // 삭제 실패는 무시
      }
    }
  }
}
