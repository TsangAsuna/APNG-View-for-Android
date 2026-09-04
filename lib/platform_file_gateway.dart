import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 跨平台文件选择 / 导出网关。
///
/// Android：MainActivity.kt 原生 SAF 通道（选择/目录/保存，行为与历史版本一致）。
/// iOS：AppDelegate.swift 原生通道——
///   - 图片选择：PHPickerViewController（系统相册风格图片选择器，非文件列表）；
///   - 导出：UIDocumentPicker 系统「存储」对话框 / 应用文稿目录 APNG_Exporter。
/// 不依赖 file_picker 插件（其 Android 端硬编码 compileSdk 34 与 AGP 9 冲突，
/// 且 iOS 端底层是文档选择器而非图片选择器）。
/// 保存方式：dialog=系统对话框 / folder=默认文件夹(APNG_Exporter) / album=相册
enum SaveMode { dialog, folder, album }

class FileGateway {
  FileGateway._();

  static const _channel = MethodChannel('com.apngviewer.apng_viewer/file');

  /// 清空本应用产生的图片缓存。
  /// Android：cacheDir/pending/；iOS：tmp 下 PHPicker 复制的 picker_*。
  /// 只清理应用自己复制产生的缓存，绝不触碰源文件。
  static Future<void> clearPendingCache() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('clearPendingCache');
      } else {
        await _iosPickerChannel.invokeMethod<bool>('clearPendingCache');
      }
    } catch (_) {
      // 原生通道不可用时静默失败，不影响主流程
    }
  }

  /// iOS 原生通道（AppDelegate.swift 注册：PHPicker 选择 + 导出）
  static const _iosPickerChannel =
      MethodChannel('com.apngviewer.apng_viewer/ios_picker');

  static bool get _useAndroidSaf => Platform.isAndroid;


  /// 保存到相册（iOS PhotoKit / Android MediaStore）
  static Future<bool> saveToAlbum({
    required String fileName,
    required Uint8List data,
  }) async {
    final channel = _useAndroidSaf ? _channel : _iosPickerChannel;
    final ok = await channel.invokeMethod<bool>('saveToAlbum', {
      'fileName': fileName,
      'data': data,
    });
    return ok ?? false;
  }

  /// 读取全局保存方式（无设置时默认系统对话框）
  static Future<SaveMode> loadSaveMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString('save_mode');
      return switch (v) {
        'folder' => SaveMode.folder,
        'album' => SaveMode.album,
        _ => SaveMode.dialog,
      };
    } catch (_) {
      return SaveMode.dialog;
    }
  }

  /// 按全局保存方式写文件
  static Future<bool> writeExportSmart({
    required String fileName,
    required String mime,
    required Uint8List data,
    SaveMode? mode,
    bool keepOriginal = false,
  }) async {
    final m = mode ?? await loadSaveMode();
    if (m == SaveMode.album) {
      return saveToAlbum(fileName: fileName, data: data);
    }
    if (m == SaveMode.folder) {
      return writeExport(
        fileName: fileName, mime: mime, data: data,
        useCustomDir: true, keepOriginal: keepOriginal);
    }
    return writeExport(
      fileName: fileName, mime: mime, data: data,
      useCustomDir: false, keepOriginal: keepOriginal);
  }

  /// 单选一张 APNG/PNG 图片，返回可读文件路径；取消返回 null。
  static Future<String?> pickApngFile() async {
    if (_useAndroidSaf) {
      return _channel.invokeMethod<String>('pickApngFile');
    }
    // iOS：原生 PHPicker（系统图片选择器，相册/最近项目网格）
    final path = await _iosPickerChannel.invokeMethod<String>('pickApngFile');
    return (path != null && path.isNotEmpty) ? path : null;
  }

  /// iOS：从「文件」App 选择原始 .apng/.png 文件（保真，动画不丢）。
  /// Android 走 SAF 的 pickApngFile 即可，无需此方法。
  static Future<String?> pickApngFileFromFiles() async {
    if (_useAndroidSaf) {
      return pickApngFile();
    }
    final path = await _iosPickerChannel.invokeMethod<String>('openDocument');
    return (path != null && path.isNotEmpty) ? path : null;
  }

  /// 多选图片，返回路径列表；取消返回 null。
  static Future<List<String>?> pickImages() async {
    if (_useAndroidSaf) {
      final result = await _channel.invokeMethod<List<dynamic>>('pickImages');
      return result?.map((e) => e as String).toList();
    }
    // iOS：原生 PHPicker，多选
    final result =
        await _iosPickerChannel.invokeMethod<List<dynamic>>('pickImages', {
      'multiple': true,
    });
    final paths = result?.whereType<String>().toList() ?? const [];
    return paths.isEmpty ? null : paths;
  }

  /// 选择导出目录，返回展示给用户看的目录名。
  ///
  /// iOS 沙盒不允许长期持有任意目录的写权限，因此不弹目录选择器，
  /// 直接采用应用文稿目录 APNG_Exporter/（「文件」App -> 我的 iPhone 可见）。
  static Future<String?> pickExportDirectory() async {
    if (_useAndroidSaf) {
      return _channel.invokeMethod<String>('pickDirectory');
    }
    return '文稿/APNG_Exporter';
  }

  /// 写出导出文件。
  ///
  /// [keepOriginal] 为 true 时保留原始文件名与字节（用于"保存原文件"，
  /// 导出的 APNG 保持动画与原始大小）；默认 false 时按历史行为把
  /// .apng 统一落为 .png（APNG 本身是合法 PNG，动画数据不丢）。
  static Future<bool> writeExport({
    required String fileName,
    required String mime,
    required Uint8List data,
    required bool useCustomDir,
    bool keepOriginal = false,
  }) async {
    var name = fileName;
    if (!keepOriginal && name.toLowerCase().endsWith('.apng')) {
      // iOS 导出对话框按扩展名匹配 UTType，.apng 不是系统已知类型会弹不出选项；
      // APNG 是合法 PNG，改名 .png 不影响动画数据与兼容性。
      name = '${name.substring(0, name.length - 5)}.png';
    }

    final method = useCustomDir ? 'writeToDirectory' : 'saveFileDialog';
    final channel = _useAndroidSaf ? _channel : _iosPickerChannel;
    final ok = await channel.invokeMethod<bool>(method, {
      'fileName': name,
      'mime': mime,
      'data': data,
    });
    return ok ?? false;
  }
}
