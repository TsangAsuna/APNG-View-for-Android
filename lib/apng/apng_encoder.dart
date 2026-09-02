import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// APNG 编码器 - 将多张图片编码为 APNG 动画
/// 基于 image 库的 PngEncoder（原生支持 acTL/fcTL/fdAT 块）
class ApngEncoder {
  /// 将多帧 RGBA 数据编码为 APNG
  ///
  /// [frames] 每帧 RGBA 字节（宽高一致）
  /// [width] [height] 帧尺寸
  /// [frameDurationsMs] 每帧延时（毫秒），为空则全部使用 [defaultDurationMs]
  /// [loopCount] 循环次数，0 表示无限循环
  static Uint8List? encode({
    required List<Uint8List> frames,
    required int width,
    required int height,
    List<int>? frameDurationsMs,
    int defaultDurationMs = 100,
    int loopCount = 0,
  }) {
    if (frames.isEmpty || width <= 0 || height <= 0) return null;

    try {
      // 构造第一帧
      final first = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: frames.first.buffer,
        numChannels: 4,
      );
      first.loopCount = loopCount;
      first.frameDuration =
          (frameDurationsMs != null && frameDurationsMs.isNotEmpty)
              ? frameDurationsMs.first
              : defaultDurationMs;

      // 添加其余帧
      for (var i = 1; i < frames.length; i++) {
        final frameImg = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: frames[i].buffer,
          numChannels: 4,
        );
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
}
