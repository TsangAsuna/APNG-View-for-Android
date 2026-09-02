import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 图片解码结果
class DecodedImage {
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final String sourcePath;
  final String sourceName;

  /// 缩略图 PNG 缓存（展示用，避免重复编码）
  Uint8List? _thumb;

  DecodedImage({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.sourcePath,
    required this.sourceName,
  });

  /// 直接设置缩略图（后台 isolate 解码时一并生成，避免 UI 线程卡顿）
  void setThumbnailPng(Uint8List bytes) => _thumb = bytes;

  /// 生成（或返回缓存的）缩略图 PNG，用于列表/网格展示
  Uint8List thumbnailPng({int maxDim = 200}) {
    if (_thumb != null) return _thumb!;
    try {
      final im = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgbaBytes.buffer,
        numChannels: 4,
      );
      final scale = width > height ? maxDim / width : maxDim / height;
      final nw = (width * scale).round().clamp(1, width);
      final nh = (height * scale).round().clamp(1, height);
      final resized = img.copyResize(im, width: nw, height: nh);
      _thumb = img.encodePng(resized);
      return _thumb!;
    } catch (_) {
      try {
        final im = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: rgbaBytes.buffer,
          numChannels: 4,
        );
        _thumb = img.encodePng(im);
        return _thumb!;
      } catch (_) {
        return Uint8List(0);
      }
    }
  }
}

/// 转换工具：图片<->APNG
class ApngConverter {
  /// 同步读取并解码图片文件（支持 PNG/JPEG/WebP/GIF/BMP）为 RGBA 数据
  /// 只读取源文件，不产生任何缓存文件。
  /// 供后台 isolate 调用，避免阻塞 UI。
  static DecodedImage? decodeImageFileSync(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final rgba = decoded.numChannels != 4
          ? decoded.convert(numChannels: 4)
          : decoded;
      final name = path.split('/').last;
      final d = DecodedImage(
        rgbaBytes: rgba.getBytes(order: img.ChannelOrder.rgba),
        width: rgba.width,
        height: rgba.height,
        sourcePath: path,
        sourceName: name,
      );
      // 后台顺便生成缩略图
      d.thumbnailPng();
      return d;
    } catch (_) {
      return null;
    }
  }

  /// 将多张已解码图片编码为 APNG
  static Uint8List? encodeToApng(
    List<DecodedImage> images, {
    List<int>? durationsMs,
    int defaultDurationMs = 100,
    int loopCount = 0,
    int? targetWidth,
    int? targetHeight,
    bool padToSameSize = false,
  }) {
    if (images.isEmpty) return null;

    try {
      var outW = targetWidth ??
          images.map((e) => e.width).reduce((a, b) => a > b ? a : b);
      var outH = targetHeight ??
          images.map((e) => e.height).reduce((a, b) => a > b ? a : b);

      final first = _frameToImage(images[0], outW, outH, padToSameSize);
      first.loopCount = loopCount;
      first.frameDuration = (durationsMs != null && durationsMs.isNotEmpty)
          ? durationsMs[0]
          : defaultDurationMs;

      for (var i = 1; i < images.length; i++) {
        final frameImg = _frameToImage(images[i], outW, outH, padToSameSize);
        frameImg.frameDuration =
            (durationsMs != null && i < durationsMs.length)
                ? durationsMs[i]
                : defaultDurationMs;
        first.addFrame(frameImg);
      }

      final encoder = img.PngEncoder();
      return encoder.encode(first);
    } catch (_) {
      return null;
    }
  }

  static img.Image _frameToImage(DecodedImage d, int w, int h, bool pad) {
    var im = img.Image.fromBytes(
      width: d.width,
      height: d.height,
      bytes: d.rgbaBytes.buffer,
      numChannels: 4,
    );
    if (d.width == w && d.height == h) {
      return im;
    }
    if (!pad) {
      final canvas = img.Image(width: w, height: h, numChannels: 4);
      final scale = (w / d.width < h / d.height) ? w / d.width : h / d.height;
      final nw = (d.width * scale).round();
      final nh = (d.height * scale).round();
      final resized = img.copyResize(im, width: nw, height: nh);
      img.compositeImage(
        canvas,
        resized,
        dstX: (w - nw) ~/ 2,
        dstY: (h - nh) ~/ 2,
        blend: img.BlendMode.direct,
      );
      return canvas;
    } else {
      return img.copyResize(im, width: w, height: h);
    }
  }
}
