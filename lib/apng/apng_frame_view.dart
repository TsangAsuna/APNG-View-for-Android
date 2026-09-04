import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 将 APNG 单帧渲染为画面
///
/// 原生解码路径：帧数据为 .rgba 裸像素文件（[rgbaPath]），按需读盘 +
/// [ui.decodeImageFromPixels] 直建 GPU 纹理，绕过 PNG 编解码（秒开关键）。
///
/// 纯 Dart 回退路径：[pngBytes] → Image.memory。
///
/// 内存控制：纹理经 LRU 缓存复用（播放切帧不重建、不泄漏），
/// 帧数据不驻留（按需读盘），彻底规避大 APNG 内存翻倍闪退。
class ApngFrameView extends StatefulWidget {
  final Uint8List? pngBytes;
  final String? rgbaPath;
  final Future<Uint8List?> Function()? rgbaLoader;
  final int? rgbaWidth;
  final int? rgbaHeight;
  final BoxFit fit;

  const ApngFrameView({
    super.key,
    this.pngBytes,
    this.rgbaPath,
    this.rgbaLoader,
    this.rgbaWidth,
    this.rgbaHeight,
    this.fit = BoxFit.contain,
  });

  @override
  State<ApngFrameView> createState() => _ApngFrameViewState();
}

class _ApngFrameViewState extends State<ApngFrameView> {
  ui.Image? _image;
  String? _loadedKey;
  bool _loading = false;

  /// 全局 LRU 纹理缓存（按帧文件路径复用；上限 12 帧 ≈ 67MB 纹理，
  /// 播放器来回切帧不重建，超过上限释放最久未用帧防内存暴涨）
  static final LinkedHashMap<String, ui.Image> _textureCache =
      LinkedHashMap<String, ui.Image>();
  static const int _cacheLimit = 12;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(ApngFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rgbaPath != widget.rgbaPath ||
        oldWidget.pngBytes != widget.pngBytes) {
      _maybeLoad();
    }
  }

  String? get _key {
    final p = widget.rgbaPath;
    if (p != null) return 'rgba:$p';
    final b = widget.pngBytes;
    if (b != null) return 'png:${b.hashCode}';
    return null;
  }

  Future<void> _maybeLoad() async {
    final key = _key;
    if (key == null || _loading || _loadedKey == key) return;
    // LRU 命中：直接复用已解码纹理，零 I/O 零解码
    final cached = _textureCache.remove(key);
    if (cached != null) {
      _textureCache[key] = cached; // 移到队尾（最近使用）
      if (mounted) {
        setState(() {
          _image = cached;
          _loadedKey = key;
        });
      }
      return;
    }
    _loading = true;
    Uint8List? bytes = widget.pngBytes;
    if (bytes == null) {
      final loader = widget.rgbaLoader;
      bytes = loader != null
          ? await loader()
          : await _readRgba(widget.rgbaPath);
    }
    if (bytes == null || !mounted) {
      _loading = false;
      return;
    }
    final w = widget.rgbaWidth ?? 0;
    final h = widget.rgbaHeight ?? 0;
    if (w <= 0 || h <= 0 || bytes.length < w * h * 4) {
      _loading = false;
      return;
    }
    ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      _textureCache.remove(key);
      _textureCache[key] = img;
      if (_textureCache.length > _cacheLimit) {
        final oldest = _textureCache.keys.first;
        _textureCache.remove(oldest)?.dispose();
      }
      setState(() {
        _image = img;
        _loadedKey = key;
        _loading = false;
      });
    });
  }

  static Future<Uint8List?> _readRgba(String? path) async {
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    // 纹理归 LRU 缓存管理，不在此释放（避免切帧时被其他视图引用）
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rgbaPath != null || widget.rgbaLoader != null) {
      final img = _image;
      if (img != null) {
        return RawImage(image: img, fit: widget.fit, filterQuality: FilterQuality.medium);
      }
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final png = widget.pngBytes;
    if (png == null) {
      return const SizedBox.shrink();
    }
    return Image.memory(
      png,
      fit: widget.fit,
      gaplessPlayback: true, // 新帧解码完成前保持上一帧，避免闪烁/空白
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
      ),
    );
  }
}
