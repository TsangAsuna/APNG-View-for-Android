import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// APNG 文件信息
class ApngInfo {
  final String fileName;
  final String filePath;
  final int width;
  final int height;
  final int frameCount;
  final int loopCount;
  final List<int> frameDurations; // 每帧显示毫秒
  final int fileSize;

  ApngInfo({
    required this.fileName,
    required this.filePath,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.loopCount,
    required this.frameDurations,
    required this.fileSize,
  });

  /// 总时长（毫秒）
  int get totalDuration =>
      frameDurations.fold(0, (sum, d) => sum + d);

  bool get isAnimated => frameCount > 1;
}

/// 解码完成的 APNG 帧数据
///
/// 内存优化：只保留压缩后的 PNG 字节（通常比 RGBA 小 10~20 倍），
/// 渲染时由 Flutter 引擎按需解码为纹理，避免大 APNG 全量 RGBA 常驻内存导致闪退。
class ApngFrame {
  final Uint8List pngBytes; // PNG 压缩字节（内存友好）
  final int width;
  final int height;
  final int durationMs;

  ApngFrame({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.durationMs,
  });
}

/// APNG 解码器 - 基于纯 Dart image 库
class ApngDecoder {
  /// 解码 APNG 文件字节并提取全部帧
  ///
  /// 在后台 isolate 中调用，避免大 APNG 阻塞 UI。
  /// 每帧解码后立即压缩为 PNG 存储，原始 RGBA 不常驻内存。
  static ApngDecodeResult? decode(Uint8List bytes, {String filePath = ''}) {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final frames = <ApngFrame>[];
      final durations = <int>[];

      // image 库将动画帧存于 frames 列表 (包含自身)
      final allFrames = decoded.frames;
      for (final frame in allFrames) {
        final img.Image frameImg = frame;
        // 统一为 4 通道后直接压缩为 PNG（encodePng 内部才做必要拷贝，
        // 避免 getBytes + fromBytes 两次整帧 RGBA 拷贝放大内存峰值）
        final rgba = frameImg.numChannels != 4
            ? frameImg.convert(numChannels: 4)
            : frameImg;
        final png = img.encodePng(rgba);
        frames.add(ApngFrame(
          pngBytes: png,
          width: frameImg.width,
          height: frameImg.height,
          durationMs: frame.frameDuration > 0 ? frame.frameDuration : 100,
        ));
        durations.add(frame.frameDuration > 0 ? frame.frameDuration : 100);
      }

      return ApngDecodeResult(
        frames: frames,
        width: decoded.width,
        height: decoded.height,
        loopCount: decoded.loopCount,
        durations: durations,
      );
    } catch (e) {
      return null;
    }
  }
}

class ApngDecodeResult {
  final List<ApngFrame> frames;
  final int width;
  final int height;
  final int loopCount;
  final List<int> durations;

  ApngDecodeResult({
    required this.frames,
    required this.width,
    required this.height,
    required this.loopCount,
    required this.durations,
  });

  bool get isAnimated => frames.length > 1;

  /// 总时长（毫秒）
  int get totalDurationMs =>
      frames.fold<int>(0, (sum, f) => sum + f.durationMs);
}
