import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  int get totalDuration => frameDurations.fold(0, (sum, d) => sum + d);

  bool get isAnimated => frameCount > 1;
}

/// 解码完成的 APNG 帧数据
///
/// 两种载荷（二选一）：
/// - [rgbaBytes]：原生解码直出的 RGBA 裸像素（绕过 PNG 编解码，秒开关键）
/// - [pngBytes]：纯 Dart 解码输出的 PNG 压缩字节（内存友好，渲染由引擎解码）
class ApngFrame {
  final Uint8List? pngBytes; // PNG 压缩字节（纯 Dart 回退路径）
  final Uint8List? rgbaBytes; // RGBA 裸像素（原生路径）
  final int width;
  final int height;
  final int durationMs;

  ApngFrame({
    this.pngBytes,
    this.rgbaBytes,
    required this.width,
    required this.height,
    required this.durationMs,
  }) : assert(pngBytes != null || rgbaBytes != null,
            '必须提供 pngBytes 或 rgbaBytes 之一');

  /// 导出/保存用：返回可写盘的 PNG 字节。
  /// 原生 RGBA 帧在此惰性编码（仅保存时开销，不影响播放）。
  Uint8List get exportPng {
    final p = pngBytes;
    if (p != null) return p;
    final r = rgbaBytes;
    if (r == null) return Uint8List(0);
    try {
      final im = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: img.ByteBuffer.view(r.buffer),
        numChannels: 4,
      );
      return Uint8List.fromList(img.encodePng(im));
    } catch (_) {
      return Uint8List(0);
    }
  }
}

/// APNG 解码器 - 基于纯 Dart image 库
///
/// 大体积 APNG 加速策略（需求 1）：
/// 1. 快速路径：PngDecoder.startDecode 只扫 chunk 头，不整体解压；
///    全尺寸 source 帧（绝大多数 APNG）逐帧独立解码，无合成依赖，可安全并行。
/// 2. 多 isolate 并行解码 + 并行 PngEncoder 压缩（默认按 CPU 核数，最多 4 路）。
/// 3. 复杂帧（偏移/叠加/背景清除）回退到原串行 decodeImage，保证正确性。
/// 4. 解码进度通过 ReceivePort 实时上报（大图不再只有空白转圈）。
class ApngDecoder {
  /// 兼容旧调用：串行解码（convert_page 预览等小图场景继续使用）。
  static ApngDecodeResult? decode(Uint8List bytes, {String filePath = ''}) {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final frames = <ApngFrame>[];
      final durations = <int>[];
      final encoder = img.PngEncoder(level: 1);

      final allFrames = decoded.frames;
      for (final frame in allFrames) {
        final img.Image frameImg = frame;
        final rgba = frameImg.numChannels != 4
            ? frameImg.convert(numChannels: 4)
            : frameImg;
        final png = encoder.encode(rgba);
        final dur = frame.frameDuration > 0 ? frame.frameDuration : 100;
        frames.add(ApngFrame(
          pngBytes: png,
          width: frameImg.width,
          height: frameImg.height,
          durationMs: dur,
        ));
        durations.add(dur);
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

  /// 并行解码（viewer 大图入口）。
  /// [onProgress] 收到 (已处理帧数, 总帧数) 进度回调。
  ///
  /// 优先走原生解码通道（Android ImageDecoder 自研解析 / iOS ImageIO）：
  /// 系统 C/C++ 解码比纯 Dart 快 10-30 倍（ImageToolbox 同思路）。
  /// 原生不可用/失败时回退纯 Dart 并行解码，保证任何 APNG 都能显示。
  static Future<ApngDecodeResult?> decodeAsync(
    Uint8List bytes, {
    String filePath = '',
    void Function(int done, int total)? onProgress,
  }) async {
    // 原生解码优先（仅在有真实文件路径时尝试）
    if (filePath.isNotEmpty) {
      try {
        final native = await _nativeDecodeApng(filePath);
        if (native != null) {
          onProgress?.call(native.frames.length, native.frames.length);
          return native;
        }
      } catch (_) {
        // 原生不可用，走纯 Dart
      }
    }
    return _decodeAsyncDart(bytes, filePath: filePath, onProgress: onProgress);
  }

  /// 调用平台原生 APNG 解码器（Android/iOS）。
  /// 返回 Map: {paths: [帧PNG文件路径], durations: [ms], width, height, loopCount}
  /// 原生不支持（复杂帧/格式）时返回 null → 回退纯 Dart。
  static Future<ApngDecodeResult?> _nativeDecodeApng(String path) async {
    final channel = MethodChannel('com.apngviewer.apng_viewer/native_decode');
    final result = await channel.invokeMapMethod<String, dynamic>(
        'decodeApng', {'path': path});
    if (result == null) return null;
    final paths = (result['paths'] as List).cast<String>();
    final durations = (result['durations'] as List).cast<int>();
    if (paths.isEmpty) return null;
    final width = (result['width'] as num?)?.toInt() ?? 0;
    final height = (result['height'] as num?)?.toInt() ?? 0;

    final frames = <ApngFrame>[];
    for (var i = 0; i < paths.length; i++) {
      final fbytes = await File(paths[i]).readAsBytes();
      // 原生直出 .rgba 裸像素 → decodeImageFromPixels 直渲（秒开）
      if (paths[i].endsWith('.rgba')) {
        frames.add(ApngFrame(
          rgbaBytes: fbytes,
          width: width,
          height: height,
          durationMs: i < durations.length ? durations[i] : 100,
        ));
      } else {
        // 兼容旧 .png 帧文件（老缓存）
        frames.add(ApngFrame(
          pngBytes: fbytes,
          width: width,
          height: height,
          durationMs: i < durations.length ? durations[i] : 100,
        ));
      }
    }
    return ApngDecodeResult(
      frames: frames,
      width: width,
      height: height,
      loopCount: (result['loopCount'] as num?)?.toInt() ?? 0,
      durations: durations,
    );
  }

  /// 纯 Dart 并行解码（原生不可用时的回退路径）
  static Future<ApngDecodeResult?> _decodeAsyncDart(
    Uint8List bytes, {
    String filePath = '',
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      // 第一步：快速扫 chunk 头，判断是否走并行快速路径
      final decoder = img.PngDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null) return null;

      final canvasW = info.width;
      final canvasH = info.height;
      final pngInfo = info as img.PngInfo;

      // 收集帧元数据；全尺寸 source 帧才可并行独立解码
      final frames = pngInfo.frames;

      // 安全防护：APNG 允许第一帧无 fcTL（IDAT 默认图），此时
      // frames.length 可能 != numFrames，跳帧索引会越界抛异常。
      // 这类文件直接回退串行 decode()，保证能显示。
      final frameCount = frames.length;
      if (frameCount == 0 || frameCount != pngInfo.numFrames) {
        final r = decode(bytes, filePath: filePath);
        onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
        return r;
      }

      final fast = frameCount > 1 &&
          frames.every((f) =>
              f.xOffset == 0 &&
              f.yOffset == 0 &&
              f.width == canvasW &&
              f.height == canvasH &&
              f.blend == img.PngBlendMode.source);

      // 复杂动画（部分区域更新/混合/清除）回退原串行实现，保证帧合成正确
      if (!fast) {
        final r = decode(bytes, filePath: filePath);
        onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
        return r;
      }

      // 第二步：并行逐帧解码 + 并行 PNG 压缩
      // 帧时长在主子 isolate 由 delayNum/delayDen 计算（decodeFrame 不设置时长）
      final frameDurations = <int>[];
      for (final f in frames) {
        var d = 0;
        if (f.delayNum > 0 && f.delayDen > 0) {
          d = (f.delayNum * 1000 / f.delayDen).round();
        }
        frameDurations.add(d > 0 ? d : 100);
      }

      final workerCount = _workerCount(frameCount);
      final batches = <List<int>>[];
      for (var i = 0; i < frameCount; i += workerCount) {
        batches.add(List.generate(
            i + workerCount <= frameCount ? workerCount : frameCount - i,
            (k) => i + k));
      }

      // 用 TransferableTypedData 零拷贝传递帧字节，避免每帧拷贝整个文件
      final transferable = TransferableTypedData.fromList([bytes]);

      final results = List<ApngFrame?>.filled(frameCount, null);
      final doneCount = _ProgressCounter();

      // 批量并行：每个 isolate 只 startDecode 一次，连续解码多帧。
      // 140 帧时从 140 次全文件 chunk 扫描降到 workerCount 次，显著提速。
      final batchWorkers = <Future<void>>[];
      for (final batch in batches) {
        batchWorkers.add(Future(() async {
          final frames = await _decodeFrameBatch(
            transferable, batch, canvasW, canvasH, frameDurations);
          for (var k = 0; k < batch.length; k++) {
            results[batch[k]] = frames[k];
            final done = doneCount.add();
            onProgress?.call(done, frameCount);
          }
        }));
      }
      await Future.wait(batchWorkers);

      // 收集（保持原始帧序）；任一帧失败则整体回退串行解码，
      // 保证任何 APNG 都能显示而不是返回 null
      final out = <ApngFrame>[];
      final durations = <int>[];
      for (final f in results) {
        if (f == null) {
          final r = decode(bytes, filePath: filePath);
          onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
          return r;
        }
        out.add(f);
        durations.add(f.durationMs);
      }

      // loopCount：acTL 的 num_plays（0 = 无限循环）
      final loopCount = pngInfo.repeat;

      return ApngDecodeResult(
        frames: out,
        width: canvasW,
        height: canvasH,
        loopCount: loopCount,
        durations: durations,
      );
    } catch (e) {
      // 任何意外错误回退串行解码，兜底保证可预览
      final r = decode(bytes, filePath: filePath);
      onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
      return r;
    }
  }

  static int _workerCount(int n) {
    // 默认 4 路并行；帧数少时用帧数（避免空转）
    if (n < 2) return 1;
    return n < 4 ? n : 4;
  }

  /// 在后台 isolate 中批量解码多帧并压缩为 PNG。
  /// 关键优化：每个 isolate 只 startDecode 一次（扫描一次文件 chunk 头），
  /// 连续解码整批帧——140 帧时从 140 次全文件扫描降到 workerCount 次。
  static Future<List<ApngFrame?>> _decodeFrameBatch(
      TransferableTypedData bytes,
      List<int> indices,
      int w,
      int h,
      List<int> durations) async {
    return await compute(
        _frameBatchWorker, <Object>[bytes, indices, w, h, durations]);
  }

  /// isolate worker：单次 startDecode + 批量 decodeFrame + level1 压缩
  static List<ApngFrame?> _frameBatchWorker(List<Object> args) {
    try {
      final data = args[0] as TransferableTypedData;
      final bytes = data.materialize().asUint8List();
      final indices = (args[1] as List).cast<int>();
      final w = args[2] as int;
      final h = args[3] as int;
      final durations = (args[4] as List).cast<int>();

      final decoder = img.PngDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null) return List.filled(indices.length, null);
      final pngInfo = info as img.PngInfo;
      if (pngInfo.frames.length != indices.length &&
          pngInfo.numFrames != indices.length) {
        // 帧数不一致（无 fcTL 第一帧等情况）：让上层回退串行解码
        if (pngInfo.frames.length < indices.length) {
          return List.filled(indices.length, null);
        }
      }

      final encoder = img.PngEncoder(level: 1);
      final out = <ApngFrame?>[];
      for (final idx in indices) {
        try {
          if (idx < 0 || idx >= pngInfo.frames.length) {
            out.add(null);
            continue;
          }
          final image = decoder.decodeFrame(idx);
          if (image == null) {
            out.add(null);
            continue;
          }
          final rgba = image.numChannels != 4
              ? image.convert(numChannels: 4)
              : image;
          final png = encoder.encode(rgba);
          out.add(ApngFrame(
            pngBytes: png,
            width: w,
            height: h,
            durationMs: idx < durations.length ? durations[idx] : 100,
          ));
        } catch (_) {
          out.add(null);
        }
      }
      return out;
    } catch (e) {
      return List.filled((args[1] as List).length, null);
    }
  }
}

/// 线程安全进度计数（主 isolate 内单线程，仅累加）
class _ProgressCounter {
  int _v = 0;
  int add() => ++_v;
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
