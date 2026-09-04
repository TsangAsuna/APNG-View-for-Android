import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// APNG 编码器 - 将多张图片编码为 APNG 动画
/// 基于 image 库的 PngEncoder（原生支持 acTL/fcTL/fdAT 块）
class ApngEncoder {
  /// 将多帧 RGBA 数据编码为 APNG
  ///
  /// [frames] 每帧 RGBA 字节（可尺寸不一）
  /// [frameWidths]/[frameHeights] 每帧实际宽高（与 [frames] 对齐）；
  /// 缺省时全部使用 [width]/[height]。
  /// [width] [height] 目标帧尺寸（APNG 所有帧必须同尺寸：
  /// 以第一帧为基准，其余帧自动 copyResize 统一，杜绝"编码失败"）
  /// [frameDurationsMs] 每帧延时（毫秒），为空则全部使用 [defaultDurationMs]
  /// [loopCount] 循环次数，0 表示无限循环
  static Uint8List? encode({
    required List<Uint8List> frames,
    required int width,
    required int height,
    List<int>? frameWidths,
    List<int>? frameHeights,
    List<int>? frameDurationsMs,
    int defaultDurationMs = 100,
    int loopCount = 0,
  }) {
    if (frames.isEmpty || width <= 0 || height <= 0) return null;

    try {
      // 构造第一帧
      final first = _buildFrame(
          frames[0], width, height,
          firstWidth: frameWidths?[0], firstHeight: frameHeights?[0]);
      first.loopCount = loopCount;
      first.frameDuration =
          (frameDurationsMs != null && frameDurationsMs.isNotEmpty)
              ? frameDurationsMs.first
              : defaultDurationMs;

      // 添加其余帧（尺寸不一 → 自动 resize 到目标尺寸）
      for (var i = 1; i < frames.length; i++) {
        final frameImg = _buildFrame(
            frames[i], width, height,
            firstWidth: frameWidths != null && i < frameWidths.length
                ? frameWidths[i]
                : width,
            firstHeight: frameHeights != null && i < frameHeights.length
                ? frameHeights[i]
                : height);
        frameImg.frameDuration =
            (frameDurationsMs != null && i < frameDurationsMs.length)
                ? frameDurationsMs[i]
                : defaultDurationMs;
        first.addFrame(frameImg);
      }

      final encoder = img.PngEncoder();
      final encoded = encoder.encode(first);
      return encoded;
    } catch (e) {
      return null;
    }
  }

  /// 从 RGBA 字节构造 Image；若源尺寸与目标不一致则自动缩放。
  static img.Image _buildFrame(
    Uint8List bytes,
    int targetW,
    int targetH, {
    int? firstWidth,
    int? firstHeight,
  }) {
    final srcW = firstWidth ?? targetW;
    final srcH = firstHeight ?? targetH;
    final im = img.Image.fromBytes(
      width: srcW,
      height: srcH,
      bytes: bytes.buffer,
      numChannels: 4,
    );
    if (srcW != targetW || srcH != targetH) {
      return img.copyResize(im, width: targetW, height: targetH);
    }
    return im;
  }
}