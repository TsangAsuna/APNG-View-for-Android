import Flutter
import UIKit
import Photos
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Filza / 文件 App "Open in" 分享进来的 APNG 文件路径（复制到 tmp 后交给 Dart）
  private var sharedFilePath: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Filza / 文件 App "Open in" 本应用时回调：把文件复制到 tmp 并通知 Dart
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.isFileURL else { return false }
    let dest = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared_\(UUID().uuidString)_\(url.lastPathComponent)")
    do {
      try FileManager.default.copyItem(at: url, to: dest)
      sharedFilePath = dest.path
      // Dart 端在启动/回到前台时通过 getPendingFile 拉取
      return true
    } catch {
      return false
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerImagePickerChannel(engineBridge.pluginRegistry)
    registerIntentChannel(engineBridge.pluginRegistry)
    registerNativeDecodeChannel(engineBridge.pluginRegistry)
  }

  /// 注册原生 APNG 解码通道（Dart decodeAsync 优先调用，秒开大图）
  private func registerNativeDecodeChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ApngNativeDecoder") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.apngviewer.apng_viewer/native_decode",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "decodeApng" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(nil)
        return
      }
      // 后台线程解码，避免阻塞 UI
            DispatchQueue.global(qos: .userInitiated).async {
              let fm = FileManager.default
              // 持久缓存目录（Library/Caches，系统仅在空间不足时清理）
              let baseDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("native_frames", isDirectory: true)
              try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
              // 解码日志（Filza 可直接查看：Library/Caches/native_frames/decode_log.txt）
              func log(_ msg: String) {
                let line = "\(Date()) \(msg)\n"
                if let d = line.data(using: .utf8) {
                  let logUrl = baseDir.appendingPathComponent("decode_log.txt")
                  if fm.fileExists(atPath: logUrl.path) {
                    if let fh = try? FileHandle(forWritingTo: logUrl) {
                      fh.seekToEndOfFile()
                      fh.write(d)
                      try? fh.close()
                    }
                  } else {
                    try? d.write(to: logUrl)
                  }
                }
              }
              log("=== decodeApng path=\(path) ===")
              // 缓存 key = 文件大小 + 最后修改时间（内容变则自动失效）
              let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
              let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
              let cacheKey = "\(size)_\(Int(mtime))"
              let tmpDir = baseDir.appendingPathComponent(cacheKey, isDirectory: true)
              try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
              log("cacheKey=\(cacheKey) exists=\(fm.fileExists(atPath: tmpDir.path))")

              // 缓存命中（frame_0.png 存在且帧数对得上）→ 直接复用，零解码秒开
              let frameCount = ApngNativeDecoder.peekMeta(path: path)?.frames.count ?? 0
              let cached = (try? fm.contentsOfDirectory(atPath: tmpDir.path))?
                .filter { $0.hasPrefix("frame_") && ($0.hasSuffix(".png") || $0.hasSuffix(".rgba")) }
                .sorted() ?? []
              log("frameCount=\(frameCount) cached=\(cached.count)")
              let framePaths: [String]?
              if cached.count == frameCount && frameCount > 0 {
                framePaths = cached.map { tmpDir.appendingPathComponent($0).path }
                log("CACHE HIT")
              } else {
                // 无缓存或不全 → 清残帧后完整解码到缓存目录
                if !cached.isEmpty {
                  for f in cached {
                    try? fm.removeItem(at: tmpDir.appendingPathComponent(f))
                  }
                }
                log("DECODE START")
                framePaths = ApngNativeDecoder.decode(path: path, tmpDir: tmpDir)
                log("DECODE END paths=\(framePaths?.count ?? -1)")
              }
              guard let framePaths = framePaths else {
                DispatchQueue.main.async { result(nil) }
                return
              }
              var durations: [Int] = []
              let meta = ApngNativeDecoder.peekMeta(path: path)
              if let meta = meta {
                for f in meta.frames {
                  var d = 0
                  if f.delayNum > 0 && f.delayDen > 0 {
                    d = Int(Double(f.delayNum) * 1000 / Double(f.delayDen))
                  }
                  durations.append(d > 0 ? d : 100)
                }
              }
              var map: [String: Any] = [:]
              map["paths"] = framePaths
              map["durations"] = durations
              map["width"] = meta?.width ?? 0
              map["height"] = meta?.height ?? 0
              map["loopCount"] = meta?.loopCount ?? 0
              DispatchQueue.main.async { result(map) }
            }
    }
  }

  /// 注册 intent 通道：Dart 主动拉取外部打开的文件（Filza "Open in"）
  private func registerIntentChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ApngSharedFile") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.apngviewer.apng_viewer/intent",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getPendingFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let path = self?.sharedFilePath
      self?.sharedFilePath = nil // 取走后清空，避免重复打开
      result(path)
    }
  }

  /// 注册 iOS 原生图片选择通道（自制 PhotoKit 选择器），供 Dart 端调用
  private func registerImagePickerChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ApngImagePicker") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.apngviewer.apng_viewer/ios_picker",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "pickImages":
        let args = call.arguments as? [String: Any] ?? [:]
        let multiple = (args["multiple"] as? Bool) ?? true
        self.presentImagePicker(multiple: multiple) { paths in
          if let paths = paths {
            result(paths)
          } else {
            result(nil) // 用户取消
          }
        }
      case "pickApngFile":
        self.presentImagePicker(multiple: false) { paths in
          if let paths = paths, !paths.isEmpty {
            result(paths.first)
          } else {
            result(nil)
          }
        }
      case "openDocument":
        // 从「文件」App 选原始 .apng/.png 文件（保真，动画不丢）
        self.presentDocumentPicker { path in
          result(path)
        }
      case "saveFileDialog":
        // iOS 系统「存储」对话框（UIDocumentPicker 导出到「文件」App）
        let args = call.arguments as? [String: Any] ?? [:]
        let name = args["fileName"] as? String ?? "export.png"
        let data = (args["data"] as? FlutterStandardTypedData)?.data
        guard let bytes = data else {
          result(false)
          return
        }
        self.presentSaveDialog(fileName: name, data: bytes) { ok in
          result(ok)
        }
      case "writeToDirectory":
        // 写入应用文稿目录 APNG_Exporter/
        let args = call.arguments as? [String: Any] ?? [:]
        let name = args["fileName"] as? String ?? "export.png"
        let data = (args["data"] as? FlutterStandardTypedData)?.data
        guard let bytes = data else {
          result(false)
          return
        }
        result(self.writeToDocumentsDir(fileName: name, data: bytes))
      case "saveToAlbum":
        // 保存到相册（PhotoKit）
        let args = call.arguments as? [String: Any] ?? [:]
        let data = (args["data"] as? FlutterStandardTypedData)?.data
        guard let bytes = data else {
          result(false)
          return
        }
        PHPhotoLibrary.shared().performChanges({
          PHAssetChangeRequest.creationRequestForAsset(from: UIImage(data: bytes)!)
        }) { ok, _ in
          DispatchQueue.main.async { result(ok) }
        }
      case "clearPendingCache":
        // 清除图片选择/文件打开复制到 tmp 的缓存（picker_/shared_ 前缀），
        // 只清本应用产生的缓存，绝不触碰用户文件
        result(self.clearTmpPickerCache())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 删除 tmp 目录下本应用选择/分享产生的缓存图片（picker_*/shared_*）
  private func clearTmpPickerCache() -> Bool {
    let tmp = FileManager.default.temporaryDirectory
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: tmp, includingPropertiesForKeys: nil) else {
      return false
    }
    var removed = 0
    for url in files {
      if url.lastPathComponent.hasPrefix("picker_") {
        if (try? FileManager.default.removeItem(at: url)) != nil {
          removed += 1
        }
      }
    }
    return removed > 0
  }

  /// 弹出 iOS 系统「存储」对话框（导出到「文件」App）
  private func presentSaveDialog(fileName: String, data: Data, completion: @escaping (Bool) -> Void) {
    guard let topVC = topViewController() else {
      completion(false)
      return
    }
    DispatchQueue.main.async {
      let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + "_" + fileName)
      do {
        try data.write(to: tmp)
      } catch {
        completion(false)
        return
      }
      let picker = UIDocumentPickerViewController(forExporting: [tmp], asCopy: true)
      let handler = SaveExportHandler(fileURL: tmp, completion: completion)
      objc_setAssociatedObject(picker, &SaveExportHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      picker.delegate = handler
      // 手势下滑/触摸空白关闭 picker 时不触发 documentPickerWasCancelled，
      // 但会触发 presentationControllerDidDismiss -> finish(false)
      picker.presentationController?.delegate = handler
      topVC.present(picker, animated: true)
    }
  }

  /// 写入应用文稿目录 APNG_Exporter/（「文件」App -> 我的 iPhone 可见）
  private func writeToDocumentsDir(fileName: String, data: Data) -> Bool {
    do {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dir = docs.appendingPathComponent("APNG_Exporter", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var target = dir.appendingPathComponent(fileName)
      if FileManager.default.fileExists(atPath: target.path) {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        target = dir.appendingPathComponent("\(base)_\(stamp).\(ext)")
      }
      try data.write(to: target)
      return true
    } catch {
      return false
    }
  }

  /// 弹出 iOS 原生「文件」选择器：选原始 .apng/.png 文件（保真，动画不丢）
  private func presentDocumentPicker(completion: @escaping (String?) -> Void) {
    guard let topVC = topViewController() else {
      completion(nil)
      return
    }
    DispatchQueue.main.async {
      // 声明可选的类型：APNG（自定义 UTType，已注册）+ PNG + 图片
      let apngType = UTType(filenameExtension: "apng") ?? UTType.png
      var types = [apngType, UTType.png]
      if let imageType = UTType("public.image") {
        types.append(imageType)
      }
      let picker = UIDocumentPickerViewController(
        forOpeningContentTypes: types, asCopy: true)
      let handler = OpenDocumentHandler(completion: completion)
      objc_setAssociatedObject(picker, &OpenDocumentHandler.assocKey, handler,
                               .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      picker.delegate = handler
      topVC.present(picker, animated: true)
    }
  }

  /// 弹出 iOS 原生图片选择器（自制 PhotoKit 网格，取原始字节保留 APNG 动画）
  private func presentImagePicker(multiple: Bool, completion: @escaping ([String]?) -> Void) {
    guard let topVC = topViewController() else {
      completion(nil)
      return
    }
    DispatchQueue.main.async {
      let picker = CustomPhotoPickerViewController(
        multiple: multiple, completion: completion)
      let nav = UINavigationController(rootViewController: picker)
      nav.modalPresentationStyle = .fullScreen
      topVC.present(nav, animated: true)
    }
  }

  /// 获取当前可 present 的顶层控制器。
  /// 注意：不能用 self.window（Scene 生命周期下 Flutter 隐式引擎的
  /// window 可能尚未挂载 rootViewController），必须从活跃 Scene 取。
  private func topViewController() -> UIViewController? {
    let activeScene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    let window = activeScene?.windows.first { $0.isKeyWindow }
      ?? activeScene?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

/// 导出到「文件」App 后的回调：清理临时文件并返回结果
class SaveExportHandler: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  static var assocKey = "SaveExportHandlerKey"

  private let fileURL: URL
  private let completion: (Bool) -> Void
  private var done = false

  init(fileURL: URL, completion: @escaping (Bool) -> Void) {
    self.fileURL = fileURL
    self.completion = completion
  }


  private func finish(_ ok: Bool) {
    guard !done else { return }
    done = true
    try? FileManager.default.removeItem(at: fileURL)
    completion(ok)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(false)
  }

  /// 手势下滑 / 触摸空白关闭 picker（iOS 15 不触发 documentPickerWasCancelled）
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(false)
  }
}

/// 「文件」App 选择回调：把选中的 .apng/.png 复制到 tmp，返回可读路径
class OpenDocumentHandler: NSObject, UIDocumentPickerDelegate {
  static var assocKey = "OpenDocumentHandlerKey"

  private let completion: (String?) -> Void

  init(completion: @escaping (String?) -> Void) {
    self.completion = completion
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let url = urls.first, url.isFileURL else {
      completion(nil)
      return
    }
    // 保留原始扩展名（.apng 或 .png），解码器按扩展名判断格式
    let dest = FileManager.default.temporaryDirectory
      .appendingPathComponent("picker_\(UUID().uuidString).\(url.pathExtension)")
    do {
      try FileManager.default.copyItem(at: url, to: dest)
      completion(dest.path)
    } catch {
      completion(nil)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    completion(nil)
  }
}
