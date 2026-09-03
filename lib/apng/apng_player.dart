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

  /// 已完整播放的循环轮数（用于 loopCount 停止）
  int _completedLoops = 0;

  /// 播放累计时间（毫秒），供时间进度计算
  int _playedMs = 0;

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
    _completedLoops = 0;
    _playedMs = 0;
    notifyListeners();
  }

  void nextFrame() {
    _timer?.cancel();
    _timer = null;
    if (frameCount > 0) {
      _advanceFrame(1);
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
      _advanceFrame(-1);
    }
    if (_playing) {
      _scheduleNext();
    }
    notifyListeners();
  }

  void gotoFrame(int index) {
    if (frameCount == 0) return;
    final target = index.clamp(0, frameCount - 1).toInt();
    _currentFrame = target;
    _playedMs = _elapsedUpTo(target);
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

  /// 按方向推进一帧，并处理 loopCount 边界
  void _advanceFrame(int delta) {
    final n = frameCount;
    if (n == 0) return;
    var next = _currentFrame + delta;
    if (next >= n) {
      // 正向越界 → 完成一轮循环
      _completedLoops++;
      next = 0;
    } else if (next < 0) {
      next = n - 1;
    }
    _currentFrame = next;
    _playedMs = _elapsedUpTo(next);
  }

  int _elapsedUpTo(int index) {
    var ms = 0;
    for (var i = 0; i < index && i < frameCount; i++) {
      ms += result!.frames[i].durationMs;
    }
    return ms;
  }

  /// 是否已达到有限循环次数（loopCount>0 时播放指定轮数后停止）
  bool get _loopFinished {
    final loop = result?.loopCount ?? 0;
    return loop > 0 && _completedLoops >= loop;
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
      // 用实际耗时补偿 Timer 漂移（iOS RunLoop 低功耗/滚动时会延迟）
      final elapsed = _frameWatch.elapsedMilliseconds;
      _playedMs += elapsed;

      if (frameCount == 0) return;

      if (_currentFrame == frameCount - 1) {
        // 到达末帧，先尝试循环轮次推进
        _completedLoops++;
        if (_loopFinished) {
          _playing = false;
          _timer = null;
          notifyListeners();
          return;
        }
      }
      _currentFrame = (_currentFrame + 1) % frameCount;
      if (_currentFrame == 0) {
        _playedMs = 0;
      }
      notifyListeners();
      _scheduleNext();
    });
  }

  /// 时间进度（0.0 ~ 1.0），基于累计播放时间 / 总时长，帧时长不均匀也匀速
  double get progress {
    final total = result?.totalDurationMs ?? 0;
    if (total <= 0 || frameCount <= 1) return 0;
    return (_playedMs % total) / total;
  }

  /// 剩余毫秒估计（进度条用）
  int get remainingMs {
    final total = result?.totalDurationMs ?? 0;
    return (total - (_playedMs % total)).clamp(0, total).toInt();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
