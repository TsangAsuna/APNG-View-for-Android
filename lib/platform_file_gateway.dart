import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 跨平台文件选择 / 导出网关。
///
/// Android：沿用 MainActivity.kt 里的 SAF 通道，行为与历史版本完全一致
/// （返回真实路径或缓存副本路径、目录树持久授权、系统保存对话框）。
///
/// iOS：图片选择走 AppDelegate 注册的原生 PHPicker 通道（系统相册风格
/// 图片选择器，非文件列表）；导出走 file_picker 系统存储对话框。
class FileGateway {
  FileGateway._();

  static const _channel = MethodChannel('com.apngviewer.apng_viewer/file');

  /// iOS 原生 PHPicker 通道（AppDelegate.swift 注册）
  static const _iosPickerChannel =
      MethodChannel('com.apngviewer.apng_viewer/ios_picker');

  static bool get _useAndroidSaf => Platform.isAndroid;

  static Directory? _iosExportDir;

  /// 单选一张 APNG/PNG 图片，返回可读文件路径；取消返回 null。
  static Future<String?> pickApngFile() async {
    if (_useAndroidSaf) {
      return _channel.invokeMethod<String>('pickApngFile');
    }
    // iOS：原生 PHPicker（系统图片选择器，相册/最近项目网格）
    final path = await _iosPickerChannel.invokeMethod<String>('pickApngFile');
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
    final dir = await _ensureIosExportDir();
    return dir == null ? null : '文稿/APNG_Exporter';
  }

  /// 写出导出文件。
  ///
  /// Android：自定义目录走 SAF writeToDirectory，否则弹系统保存对话框。
  /// iOS：自定义目录写入应用文稿目录；否则弹系统「存储」对话框。
  /// 注意：iOS 的导出对话框按扩展名匹配文件类型，.apng 不是系统已知
  /// UTType，会弹不出有效选项，因此导出时统一落为 .png（APNG 本身就是
  /// 合法的 PNG，扩展名改为 .png 不影响动画数据与兼容性）。
  static Future<bool> writeExport({
    required String fileName,
    required String mime,
    required Uint8List data,
    required bool useCustomDir,
  }) async {
    if (_useAndroidSaf) {
      final method = useCustomDir ? 'writeToDirectory' : 'saveFileDialog';
      final ok = await _channel.invokeMethod<bool>(method, {
        'fileName': fileName,
        'mime': mime,
        'data': data,
      });
      return ok ?? false;
    }

    // iOS：.apng 扩展名系统不识别，统一导出为 .png
    var name = fileName;
    if (name.toLowerCase().endsWith('.apng')) {
      name = '${name.substring(0, name.length - 5)}.png';
    }

    if (useCustomDir) {
      final dir = await _ensureIosExportDir();
      if (dir == null) return false;
      try {
        final target = File('${dir.path}/$name');
        if (target.existsSync()) {
          final dot = name.lastIndexOf('.');
          final base = dot > 0 ? name.substring(0, dot) : name;
          final ext = dot > 0 ? name.substring(dot) : '';
          final stamp = DateTime.now().millisecondsSinceEpoch;
          name = '${base}_$stamp$ext';
        }
        await File('${dir.path}/$name').writeAsBytes(data, flush: true);
        return true;
      } catch (_) {
        return false;
      }
    }

    final path = await FilePicker.platform.saveFile(
      fileName: name,
      bytes: data,
    );
    return path != null;
  }

  static Future<Directory?> _ensureIosExportDir() async {
    final cached = _iosExportDir;
    if (cached != null) return cached;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}APNG_Exporter');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _iosExportDir = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }
}
