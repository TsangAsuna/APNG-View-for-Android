import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 跨平台文件选择 / 导出网关。
///
/// Android：沿用 MainActivity.kt 里的 SAF 通道，行为与历史版本完全一致
/// （返回真实路径或缓存副本路径、目录树持久授权、系统保存对话框）。
///
/// iOS：仓库里没有 ios/ 目录（IPA 由 CI 用 flutter create 现生成 Runner），
/// 不便注入原生代码，因此选择用 file_picker 的系统文档选择器实现：
///  - 选择：UIDocumentPicker（从「文件」App / iCloud Drive 选图，无需任何
///    Info.plist 权限声明，插件会拷贝出可读的临时路径）；
///  - 单文件导出：系统「存储」对话框（file_picker saveFile + bytes）；
///  - 批量导出（自定义目录模式）：iOS 沙盒不允许持久写入任意外部目录，
///    改为写入应用文稿目录 APNG_Exporter/（可在「文件」App 中访问）。
class FileGateway {
  FileGateway._();

  static const _channel = MethodChannel('com.apngviewer.apng_viewer/file');

  static bool get _useAndroidSaf => Platform.isAndroid;

  static Directory? _iosExportDir;

  /// 单选一张 APNG/PNG 图片，返回可读文件路径；取消返回 null。
  static Future<String?> pickApngFile() async {
    if (_useAndroidSaf) {
      return _channel.invokeMethod<String>('pickApngFile');
    }
    // iOS 注意事项：
    // - 不能把 'apng' 放进 allowedExtensions：.apng 未在系统注册，
    //   file_picker 会为它生成动态 UTType(dyn.*)，导致 UIDocumentPicker
    //   过滤失效 → 变成"文件选择器"且图片选不中。
    // - 只放系统已知图片扩展名，过滤条件全是有效 public.image 子类型，
    //   选择器会正确显示为"图片选择"。
    // - .apng 文件本身 conforms to public.png（见 Info.plist
    //   UTExportedTypeDeclarations），因此也能被选中。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic', 'heif'],
      dialogTitle: '选择 APNG 图片',
    );
    final path = result?.files.single.path;
    return (path != null && path.isNotEmpty) ? path : null;
  }

  /// 多选图片，返回路径列表；取消返回 null。
  static Future<List<String>?> pickImages() async {
    if (_useAndroidSaf) {
      final result = await _channel.invokeMethod<List<dynamic>>('pickImages');
      return result?.map((e) => e as String).toList();
    }
    // 同 pickApngFile：只放系统已知图片扩展名，避免动态 UTType 导致
    // UIDocumentPicker 降级为文件选择器。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic', 'heif'
      ],
      allowMultiple: true,
      dialogTitle: '选择图片',
    );
    final paths = result?.paths.whereType<String>().toList() ?? const [];
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
