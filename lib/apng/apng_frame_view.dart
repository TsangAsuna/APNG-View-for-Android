import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 将 RGBA 字节数据转换为 ui.Image
class RgbaImagePainter extends CustomPainter {
  final ui.Image? image;

  RgbaImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    if (image == null) return;
    // 保持宽高比居中绘制
    final imgW = image!.width.toDouble();
    final imgH = image!.height.toDouble();
    if (imgW == 0 || imgH == 0) return;

    final scale = (size.width / imgW < size.height / imgH)
        ? size.width / imgW
        : size.height / imgH;
    final drawW = imgW * scale;
    final drawH = imgH * scale;
    final dx = (size.width - drawW) / 2;
    final dy = (size.height - drawH) / 2;

    canvas.drawImageRect(
      image!,
      Rect.fromLTWH(0, 0, imgW, imgH),
      Rect.fromLTWH(dx, dy, drawW, drawH),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant RgbaImagePainter oldDelegate) =>
      oldDelegate.image != image;
}

/// 在 Widget 中把 RGBA 字节转换为 ui.Image 并显示
class ApngFrameView extends StatefulWidget {
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final BoxFit fit;

  const ApngFrameView({
    super.key,
    required this.rgbaBytes,
    required this.width,
    required this.height,
    this.fit = BoxFit.contain,
  });

  @override
  State<ApngFrameView> createState() => _ApngFrameViewState();
}

class _ApngFrameViewState extends State<ApngFrameView> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant ApngFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rgbaBytes != widget.rgbaBytes ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      widget.rgbaBytes,
      widget.width,
      widget.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final img = await completer.future;
    if (mounted) {
      setState(() {
        _image?.dispose();
        _image = img;
      });
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return CustomPaint(
      painter: RgbaImagePainter(_image),
      size: Size.infinite,
    );
  }
}