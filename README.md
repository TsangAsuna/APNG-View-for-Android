# <img src="assets/icon.png" width="28" height="28" style="vertical-align: middle; margin-right: 6px;"> APNG 阅览器 (APNG Viewer)

一个基于 **Flutter** 的 APNG 格式图片阅览器，支持 APNG 动画逐帧播放、静态 PNG 预览大图缩放、图片与 APNG 互转，完整适配 **Android 16 (API 36)**。

## ✨ 功能特性

- 🎞️ **APNG 动画播放**：逐帧渲染 APNG 动图，支持播放/暂停、上一帧/下一帧、帧进度拖动
- 🔍 **预览大图**：双指缩放（InteractiveViewer / PhotoView），静态 PNG 全屏预览
- 🔄 **图片转 APNG**：多选 PNG/JPG/WebP/GIF/BMP 图片，可调帧延时与循环次数，生成 APNG 后逐帧预览播放
- 🖼️ **APNG 转图片**：打开 APNG 提取每一帧为独立 PNG（通常 APNG 由多帧图组成）
- 📂 **自定义导出目录**：开关可切换「系统保存对话框」或「批量写入已选目录」
- 📁 **源文件路径**：选择图片直接使用源文件路径读取，不在本地产生图片缓存
- 🎨 **播放速度控制**：0.25× ~ 4× 倍速调节
- 🌗 **深色模式**：亮/暗主题一键切换（状态持久化）
- 🗂️ **最近浏览记录**：记住最近打开的 10 个文件
- 📱 **外部打开支持**：可从文件管理器直接打开 APNG 文件

## 🏗️ 项目架构

[![APNG 阅览器信号流架构](docs/architecture.svg)](docs/architecture.html)

> 🖱️ 点击上图打开**可交互信号流架构图**：鼠标悬停/点击组件可聚焦高亮，支持缩放、搜索、四信号链视图（打开/播放/互转/保存）、明暗主题切换与路线追踪。

| 层 | 模块 | 说明 |
|------|------|------|
| 🖥️ 表现层 | `HomePage` / `ViewerPage` / `ConvertPage` | 文件选择、逐帧播放控制、图片↔APNG 互转 |
| ⚙️ 逻辑层 | `ApngDecoder` / `ApngPlayer` / `ApngEncoder` | 原生优先·Dart 回退解码、Ticker 帧调度、多帧编码 |
| 🔌 原生桥 | `MainActivity.kt`（线程池解码）/ `AppDelegate.swift`（ImageIO 解码）| 双端原生多核解码，帧文件写 `native_frames` 缓存实现秒开 |
| 🛡️ 保存护栏 | Dart 30s 超时 + try/finally | 取消保存弹窗必复位按钮，不卡转圈 |

## 📦 安装包

最新安装包位于 `Download/APNG/` 目录：

| 文件 | 大小 | 说明 |
|------|------|------|
| `APNG阅览器_v1.1.0.apk` | ~18.4 MB | 最新版（含图片互转，推荐） |
| `APNG阅览器_v1.0.1_优化版.apk` | ~17.9 MB | 旧版（仅阅览） |
| `APNG阅览器_应用图标.png` | - | 应用图标 1024px |

> 💡 **体积优化说明**：通过剥离 `libflutter.so`（165MB → 11.7MB）等原生库的调试符号实现，`.so` 保持 STORED 未压缩存储并页对齐，符合 Flutter `extractNativeLibs=false` 的安装要求。

## 🚀 本地构建

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

## 📁 项目结构

```
apng_viewer/
├── lib/
│   ├── main.dart                 # 应用入口 + 首页（文件选择、最近记录、主题切换、图片互转入口）
│   ├── viewer_page.dart          # 查看器页（APNG 播放控制 + 大图预览）
│   ├── convert_page.dart         # 图片互转页（图片→APNG / APNG→图片 + 自定义导出目录）
│   └── apng/
│       ├── apng_decoder.dart     # APNG 解码器（基于 image 库，纯 Dart）
│       ├── apng_encoder.dart     # APNG 编码器（多帧 RGBA → APNG）
│       ├── apng_converter.dart   # 图片文件解码工具（只读源文件，不产生缓存）
│       ├── apng_player.dart      # 动画播放控制器（帧调度、速度控制）
│       └── apng_frame_view.dart  # 帧渲染组件（RGBA → ui.Image → CustomPainter）
├── android/
│   └── app/src/main/kotlin/.../MainActivity.kt  # SAF 选图/目录/保存 + 源路径解析 + 外部打开
├── assets/icon.png               # 应用图标
├── test/widget_test.dart         # 组件测试
└── .github/workflows/            # GitHub Actions 构建（APK / iOS IPA）
```

## 🔄 图片互转说明

### 图片转 APNG
1. 首页点「图片互转」→「图片转 APNG」
2. 「选择图片」多选若干张图片（PNG/JPG/WebP/GIF/BMP）
3. 调整「帧延时」与「循环次数」
4. 「生成 APNG」后可在内置播放器逐帧预览
5. 「导出 APNG」：开启自定义目录则批量写入，否则用系统保存对话框

### APNG 转图片
1. 「APNG 转图片」→「打开 APNG」
2. 网格预览每一帧
3. 「导出 N 帧」：开启自定义目录则一次导出全部帧 PNG，否则逐个选择位置

> 选择图片始终使用**源文件路径**读取（`resolveRealPath` 优先），仅在 SAF 无法解析时才回退到应用缓存临时副本，阅览本身不产生本地图片缓存。
