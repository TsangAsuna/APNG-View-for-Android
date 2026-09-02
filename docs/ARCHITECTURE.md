# APNG 阅览器 — 应用框架导图

> 基于 Flutter 3.47.2，架构采用「单 Activity + 纯 Dart 逻辑层 + 轻量原生桥」，无重型框架依赖，便于维护与二次开发。

---

## 一、总体分层架构

```
┌────────────────────────────────────────────────────────────────────┐
│                        Presentation 表现层                          │
│                                                                    │
│   ┌──────────────┐        ┌──────────────┐      ┌──────────────┐  │
│   │  HomePage     │ ────▶ │  ViewerPage   │ ──▶ │ ApngFrameView │  │
│   │  (首页/文件)  │  push  │  (查看/播放)  │     │  (帧渲染组件) │  │
│   └──────────────┘        └──────────────┘      └──────────────┘  │
│         │ 主题切换               │ 播放控制                          │
│         ▼                       ▼                                  │
└─────────┼───────────────────────┼──────────────────────────────────┘
          │                       │
┌─────────▼───────────────────────▼──────────────────────────────────┐
│                       State / Controller 状态层                     │
│                                                                    │
│   ┌────────────────────┐      ┌────────────────────┐              │
│   │ ApngViewerApp       │      │ ApngPlayer          │              │
│   │ (ThemeMode 管理)    │      │ (帧调度/速度/暂停)   │              │
│   └────────────────────┘      └────────────────────┘              │
└─────────┬──────────────────────────┬───────────────────────────────┘
          │                          │
┌─────────▼──────────────────────────▼───────────────────────────────┐
│                        Data / Service 数据层                       │
│                                                                    │
│   ┌────────────────────┐      ┌────────────────────┐              │
│   │ ApngDecoder         │      │ SharedPreferences   │              │
│   │ (image 包解码 APNG) │      │ (最近记录/主题持久化)│              │
│   └────────────────────┘      └────────────────────┘              │
└─────────┬──────────────────────────┬───────────────────────────────┘
          │                          │
┌─────────▼──────────────────────────▼───────────────────────────────┐
│                      Platform 平台桥 (MethodChannel)               │
│                                                                    │
│   MainActivity.kt                                                  │
│   ├── pickApngFile   → SAF ACTION_OPEN_DOCUMENT 选择 APNG/PNG      │
│   └── getPendingFile → 接收外部 ACTION_VIEW/SEND 打开的文件         │
└────────────────────────────────────────────────────────────────────┘
```

---

## 二、模块调用关系（时序）

```
用户点击"选择 APNG 图片"
        │
        ▼
┌─────────────────┐     invokeMethod("pickApngFile")      ┌──────────────────┐
│  HomePage        │ ────────────────────────────────────▶ │ MainActivity      │
│  (_pickAndOpen)  │                                       │  (SAF 文件选择)    │
└─────────────────┘                                       └──────────────────┘
        │◀──────────────────── 返回缓存文件路径 ────────────────────┤
        ▼
┌─────────────────┐   readAsBytes   ┌─────────────────┐
│  ApngDecoder     │ ──────────────▶ │ decodeImage()   │  image 包解码
└─────────────────┘                  └─────────────────┘
        │
        ▼  返回 ApngDecodeResult (frames[] + width/height + loopCount)
┌─────────────────┐
│  ApngPlayer      │  管理当前帧、播放/暂停、速度、进度
└─────────────────┘
        │  currentFrameData (RGBA bytes)
        ▼
┌─────────────────┐   decodeImageFromPixels ─▶ ui.Image
│  ApngFrameView   │   CustomPainter 绘制（保持宽高比居中）
└─────────────────┘
```

---

## 三、核心类职责说明

### 1. `main.dart` — 应用入口 + 首页
| 类/函数 | 职责 |
|---------|------|
| `ApngViewerApp` | 根组件，管理 `ThemeMode`（亮/暗/跟随系统），持久化主题 |
| `HomePage` | 首页：展示引导卡片、最近浏览列表、清空记录 |
| `_pickAndOpen()` | 调用 MethodChannel 打开系统文件选择器 |
| `_openFile(path)` | 读取文件 → 解码 → 存入最近记录 → 跳转查看器 |
| `_checkIntent()` | 检查外部打开（文件管理器分享/打开） |

### 2. `viewer_page.dart` — 查看器页面
| 类/函数 | 职责 |
|---------|------|
| `ViewerPage` | 全屏查看页，含 AppBar、播放控制栏、信息栏 |
| `_buildViewer()` | 动画：AnimatedBuilder + InteractiveViewer；静态：PhotoView 大图缩放 |
| `_buildControlBar()` | 上一帧/播放暂停/下一帧/速度/进度条 |
| `_SpeedButton` | 速度选择（0.25×~4×） |

### 3. `apng/apng_decoder.dart` — APNG 解码器
| 类 | 职责 |
|----|------|
| `ApngDecoder.decode()` | 纯 Dart 解码 APNG，提取全部帧 + 每帧延迟 |
| `ApngDecodeResult` | 解码结果（帧列表、宽高、循环次数） |
| `ApngFrame` | 单帧 RGBA 字节 + 宽高 + 时长 |

### 4. `apng/apng_player.dart` — 播放控制器
| 成员 | 职责 |
|------|------|
| `play()/pause()` | 播放/暂停控制 |
| `nextFrame()/prevFrame()` | 单帧步进 |
| `gotoFrame()` | 跳转到指定帧（进度条拖动） |
| `setSpeed()` | 调整播放速度倍率 |
| `Timer` 调度 | 根据帧时长和速度自动切换到下一帧 |

### 5. `apng/apng_frame_view.dart` — 帧渲染
| 成员 | 职责 |
|------|------|
| `_loadImage()` | RGBA 字节 → `ui.Image`（`decodeImageFromPixels`） |
| `RgbaImagePainter` | 自定义绘制，保持宽高比居中显示 |

### 6. `MainActivity.kt` — 原生桥
| 方法 | 职责 |
|------|------|
| `openFilePicker()` | SAF `ACTION_OPEN_DOCUMENT`，MIME 限定 image/png,image/apng |
| `copyToCache()` | 将所选 URI 复制到应用缓存，返回可读文件路径 |
| `handleIntent()` | 响应外部 ACTION_VIEW / ACTION_SEND 打开 APNG |

---

## 四、数据流（打开一个 APNG 文件）

```
APNG 文件字节
    │
    ▼
ApngDecoder.decode()          ── 用 image 包解析 PNG 块（acTL/fcTL/fdAT）
    │
    ▼
ApngDecodeResult
  ├── frames: List<ApngFrame>   （每帧 RGBA 数据 + durationMs）
  ├── width / height
  └── loopCount
    │
    ▼
ApngPlayer (ChangeNotifier)
  ├── currentFrameData → 当前帧 RGBA
  ├── Timer 每 durationMs 推进一帧
  └── notifyListeners() 触发 UI 重建
    │
    ▼
ApngFrameView
  ├── decodeImageFromPixels → ui.Image（GPU 纹理）
  └── CustomPainter.paint()  → 屏幕绘制（居中、保持比例）
```

---

## 五、依赖与产物关系

```
pubspec.yaml
  ├── image            → APNG 纯 Dart 解码
  ├── photo_view       → 静态大图缩放预览
  ├── shared_preferences → 最近记录 & 主题持久化
  └── flutter/material → UI 框架

Android 构建产物
  └── app-release.apk
       ├── classes.dex             (Dart 代码编译产物)
       ├── lib/arm64-v8a/libapp.so (Dart AOT 快照)
       ├── lib/arm64-v8a/libflutter.so (Flutter 引擎, 已剥离符号 11.7MB)
       ├── assets/flutter_assets/  (字体/图标/清单)
       └── resources.arsc          (资源表)
```
