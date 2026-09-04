import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 将 APNG 单帧（PNG 压缩字节）渲染为画面
///
/// 内存优化：帧数据以 PNG 压缩字节存储，由 Flutter 引擎按需解码，
/// 不再手工管理 ui.Image 生命周期，彻底规避快速切帧时的
/// "Image has been disposed" 竞态崩溃（iOS 上尤为致命）。
class ApngFrameView extends StatelessWidget {
  final Uint8List pngBytes;
  final BoxFit fit;

  const ApngFrameView({
    super.key,
    required this.pngBytes,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      pngBytes,
      fit: fit,
      gaplessPlayback: true, // 新帧解码完成前保持上一帧，避免闪烁/空白
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 48),
      ),
    );
  }
}
