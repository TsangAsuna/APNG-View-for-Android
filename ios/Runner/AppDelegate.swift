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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 弹出 iOS 原生图片选择器（PHPickerViewController）
  private func presentImagePicker(multiple: Bool, completion: @escaping ([String]?) -> Void) {
    guard let rootVC = window?.rootViewController else {
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
      rootVC.present(picker, animated: true)
    }
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
