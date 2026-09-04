import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 将 APNG 单帧渲染为画面
///
/// 原生解码路径：帧数据为 RGBA 裸像素（[rgbaBytes]），直接用
/// [ui.decodeImageFromPixels] 直建 GPU 纹理，绕过 PNG 编解码
/// （ImageToolbox 同思路，秒开关键）。
///
/// 纯 Dart 回退路径：[pngBytes] → Image.memory。
///
/// 内存/防频闪：State 内缓存已解码的 ui.Image，切帧时保留旧帧
/// 直到新帧就绪（gapless），dispose 时释放旧纹理，避免
/// "Image has been disposed" 竞态崩溃。
class ApngFrameView extends StatefulWidget {
  final Uint8List? pngBytes;
  final Uint8List? rgbaBytes;
  final int? rgbaWidth;
  final int? rgbaHeight;
  final BoxFit fit;

  const ApngFrameView({
    super.key,
    this.pngBytes,
    this.rgbaBytes,
    this.rgbaWidth,
    this.rgbaHeight,
    this.fit = BoxFit.contain,
  }) : assert(pngBytes != null || rgbaBytes != null,
            '必须提供 pngBytes 或 rgbaBytes');

  @override
  State<ApngFrameView> createState() => _ApngFrameViewState();
}

class _ApngFrameViewState extends State<ApngFrameView> {
  ui.Image? _rgbaImage;
  Uint8List? _loadedRgba;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _maybeLoadRgba();
  }

  @override
  void didUpdateWidget(ApngFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rgbaBytes != widget.rgbaBytes) {
      _maybeLoadRgba();
    }
  }

  void _maybeLoadRgba() {
    final rgba = widget.rgbaBytes;
    if (rgba == null || _loading || identical(_loadedRgba, rgba)) return;
    _loading = true;
    final w = widget.rgbaWidth ?? 0;
    final h = widget.rgbaHeight ?? 0;
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) {
      _loading = false;
      return;
    }
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _loadedRgba = rgba;
        _rgbaImage?.dispose();
        _rgbaImage = img;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _rgbaImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rgbaBytes != null) {
      final img = _rgbaImage;
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
