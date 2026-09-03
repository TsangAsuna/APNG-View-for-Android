import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerImagePickerChannel(engineBridge.pluginRegistry)
  }

  /// 注册 iOS 原生图片选择通道（PHPicker），供 Dart 端调用
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
      case "clearPendingCache":
        // 清除 PHPicker 复制到 tmp 的图片缓存（picker_ 前缀），
        // 只清本应用产生的缓存，绝不触碰用户文件
        result(self.clearTmpPickerCache())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 删除 tmp 目录下本应用 PHPicker 复制产生的缓存图片（picker_*）
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

  /// 弹出 iOS 原生图片选择器（PHPickerViewController）
  private func presentImagePicker(multiple: Bool, completion: @escaping ([String]?) -> Void) {
    guard let topVC = topViewController() else {
      completion(nil)
      return
    }
    DispatchQueue.main.async {
      var config = PHPickerConfiguration()
      config.selectionLimit = multiple ? 0 : 1 // 0 = 不限数量
      config.filter = .images
      let picker = PHPickerViewController(configuration: config)
      let handler = ImagePickerHandler(completion: completion)
      // 通过关联对象持有 handler，防止提前释放导致回调丢失
      objc_setAssociatedObject(picker, &ImagePickerHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      picker.delegate = handler
      topVC.present(picker, animated: true)
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
class SaveExportHandler: NSObject, UIDocumentPickerDelegate {
  static var assocKey = "SaveExportHandlerKey"

  private let fileURL: URL
  private let completion: (Bool) -> Void

  init(fileURL: URL, completion: @escaping (Bool) -> Void) {
    self.fileURL = fileURL
    self.completion = completion
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    try? FileManager.default.removeItem(at: fileURL)
    completion(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    try? FileManager.default.removeItem(at: fileURL)
    completion(false)
  }
}

/// PHPicker 回调处理：把选中的图片拷贝到临时目录，返回可读路径
class ImagePickerHandler: NSObject, PHPickerViewControllerDelegate {
  static var assocKey = "ImagePickerHandlerKey"

  private let completion: ([String]?) -> Void
  private var pending = 0
  private var results: [String] = []
  private var cancelled = false

  init(completion: @escaping ([String]?) -> Void) {
    self.completion = completion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty else {
      completion(nil) // 用户取消
      return
    }

    cancelled = false
    pending = results.count
    for pickerResult in results {
      loadItem(pickerResult)
    }
  }

  /// 从 NSItemProvider 读取原始文件数据（APNG 以 .png 结尾可被识别为 PNG）
  private func loadItem(_ pickerResult: PHPickerResult) {
    let provider = pickerResult.itemProvider
    let pngType = UTType.png.identifier
    let imageType = UTType.image.identifier

    if provider.hasItemConformingToTypeIdentifier(pngType) {
      provider.loadFileRepresentation(forTypeIdentifier: pngType) { [weak self] url, error in
        self?.handleLoaded(url, error: error)
      }
    } else if provider.hasItemConformingToTypeIdentifier(imageType) {
      provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, error in
        self?.handleData(data, error: error)
      }
    } else {
      finishOne(nil)
    }
  }

  private func handleLoaded(_ url: URL?, error: Error?) {
    guard let url = url, error == nil else {
      finishOne(nil)
      return
    }
    // 拷贝到临时目录，避免原 URL 失效
    let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
    let dest = FileManager.default.temporaryDirectory
      .appendingPathComponent("picker_\(UUID().uuidString).\(ext)")
    do {
      try FileManager.default.copyItem(at: url, to: dest)
      finishOne(dest.path)
    } catch {
      finishOne(nil)
    }
  }

  private func handleData(_ data: Data?, error: Error?) {
    guard let data = data, error == nil else {
      finishOne(nil)
      return
    }
    let dest = FileManager.default.temporaryDirectory
      .appendingPathComponent("picker_\(UUID().uuidString).png")
    do {
      try data.write(to: dest)
      finishOne(dest.path)
    } catch {
      finishOne(nil)
    }
  }

  private func finishOne(_ path: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if let path = path {
        self.results.append(path)
      }
      self.pending -= 1
      if self.pending <= 0 {
        self.completion(self.results.isEmpty ? nil : self.results)
      }
    }
  }
}
