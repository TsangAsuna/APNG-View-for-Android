import 'dart:async';

import 'package:flutter/material.dart';

import 'apng_decoder.dart';

/// APNG 动画播放控制器
class ApngPlayer extends ChangeNotifier {
  final ApngDecodeResult? result;

  int _currentFrame = 0;
  bool _playing = false;
  Timer? _timer;
  final Stopwatch _frameWatch = Stopwatch();

  ApngPlayer(this.result);

  int get frameCount => result?.frames.length ?? 0;
  int get currentFrame => _currentFrame;
  bool get playing => _playing;
  bool get isAnimated => (result?.isAnimated ?? false);
  ApngFrame? get currentFrameData =>
      (result != null && _currentFrame < result!.frames.length)
          ? result!.frames[_currentFrame]
          : null;

  void togglePlay() {
    if (_playing) {
      pause();
    } else {
      play();
    }
  }

  void play() {
    if (!isAnimated || _playing) return;
    _playing = true;
    _scheduleNext();
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  void stop() {
    pause();
    _currentFrame = 0;
    notifyListeners();
  }

  void nextFrame() {
    _timer?.cancel();
    _timer = null;
    if (frameCount > 0) {
      _currentFrame = (_currentFrame + 1) % frameCount;
    }
    if (_playing) {
      _scheduleNext();
    }
    notifyListeners();
  }

  void prevFrame() {
    _timer?.cancel();
    _timer = null;
    if (frameCount > 0) {
      _currentFrame = (_currentFrame - 1 + frameCount) % frameCount;
    }
    if (_playing) {
      _scheduleNext();
    }
    notifyListeners();
  }

  void gotoFrame(int index) {
    if (frameCount == 0) return;
    _currentFrame = index.clamp(0, frameCount - 1);
    if (_playing) {
      _timer?.cancel();
      _scheduleNext();
    }
    notifyListeners();
  }

  /// 调整播放速度倍率 (0.25x ~ 4x)
  double playbackSpeed = 1.0;

  void setSpeed(double speed) {
    playbackSpeed = speed.clamp(0.25, 4.0);
    if (_playing) {
      _timer?.cancel();
      _scheduleNext();
    }
    notifyListeners();
  }

  void _scheduleNext() {
    _timer?.cancel();
    final frame = currentFrameData;
    if (frame == null) return;

    // 根据帧时长和播放速度计算延迟
    var delayMs = (frame.durationMs / playbackSpeed).round();
    if (delayMs < 16) delayMs = 16; // 最低 ~60fps

    _frameWatch
      ..reset()
      ..start();
    _timer = Timer(Duration(milliseconds: delayMs), () {
      _frameWatch.stop();
      _currentFrame = (_currentFrame + 1) % frameCount;
      notifyListeners();
      _scheduleNext();
    });
  }

  /// 剩余毫秒估计（进度条用）
  double get progress =>
      frameCount == 0 ? 0 : (_currentFrame + 1) / frameCount;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}