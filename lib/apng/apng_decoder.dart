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
class ApngFrame {
  final Uint8List rgbaBytes; // RGBA 像素数据
  final int width;
  final int height;
  final int durationMs;

  ApngFrame({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.durationMs,
  });
}

/// APNG 解码器 - 基于纯 Dart image 库
class ApngDecoder {
  /// 解码 APNG 文件字节并提取全部帧
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
        // 转为 RGBA 字节
        final rgba = frameImg.numChannels != 4
            ? frameImg.convert(numChannels: 4)
            : frameImg;
        final bytesData = rgba.getBytes(order: img.ChannelOrder.rgba);
        frames.add(ApngFrame(
          rgbaBytes: bytesData,
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
}
