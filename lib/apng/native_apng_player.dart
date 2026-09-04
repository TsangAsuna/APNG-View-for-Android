import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 原生 APNG 播放器封装（对齐 ImageToolbox 架构）。
///
/// 解码与渲染全在原生侧（Android ImageDecoder / iOS 自研解码器），
/// Dart 只拿 textureId 显示实时画面 + 方法通道控制播放。
/// 零 RGBA 跨层传输，字节序/内存/闪退问题彻底消失。
class NativeApngPlayer {
  static const MethodChannel _channel =
      MethodChannel('com.apngviewer.apng_viewer/native_player');

  int? _textureId;
  int _width = 0;
  int _height = 0;
  int _frameCount = 0;
  List<int> _durations = const [];
  int _loopCount = 0;

  int get textureId => _textureId ?? -1;
  int get width => _width;
  int get height => _height;
  int get frameCount => _frameCount;
  List<int> get durations => _durations;
  int get loopCount => _loopCount;

  /// 打开 APNG 文件并创建纹理；失败返回 null
  Future<bool> open(String path) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'open',
        {'path': path},
      );
      if (result == null) return false;
      _textureId = (result['textureId'] as num?)?.toInt() ?? -1;
      _width = (result['width'] as num?)?.toInt() ?? 0;
      _height = (result['height'] as num?)?.toInt() ?? 0;
      _frameCount = (result['frameCount'] as num?)?.toInt() ?? 0;
      _durations = (result['durations'] as List?)?.cast<int>() ?? const [];
      _loopCount = (result['loopCount'] as num?)?.toInt() ?? 0;
      return _textureId >= 0 && _frameCount > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> play() async {
    try {
      await _channel.invokeMethod('play');
    } catch (_) {}
  }

  Future<void> pause() async {
    try {
      await _channel.invokeMethod('pause');
    } catch (_) {}
  }

  Future<void> seekTo(int frame) async {
    try {
      await _channel.invokeMethod('seekTo', {'frame': frame});
    } catch (_) {}
  }

  /// 取当前帧 PNG 字节（保存当前帧用，原生侧编码）
  Future<Uint8List?> getCurrentFramePng() async {
    try {
      final r = await _channel.invokeMethod<Uint8List>('getCurrentFramePng');
      return r;
    } catch (_) {
      return null;
    }
  }

  Future<void> nextFrame() async {
    try {
      await _channel.invokeMethod('nextFrame');
    } catch (_) {}
  }

  Future<void> prevFrame() async {
    try {
      await _channel.invokeMethod('prevFrame');
    } catch (_) {}
  }

  Future<Map<dynamic, dynamic>> getState() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('getState');
      return r ?? const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
  }

  /// 显示原生纹理画面
  Widget buildTexture({BoxFit fit = BoxFit.contain}) {
    if (_textureId == null || _textureId! < 0) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Texture(textureId: _textureId!, fit: fit);
  }
}
