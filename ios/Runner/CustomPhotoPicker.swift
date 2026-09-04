import UIKit
import Photos
import UniformTypeIdentifiers

/// 自制相册图片选择器（PhotoKit）。
///
/// 为什么不用 PHPicker：系统 PHPicker 从相册读取时会对 PNG/APNG 做转码，
/// 导致 APNG 动画帧丢失（只剩第一帧）。这里用 PhotoKit 直接枚举相册资源，
/// 并通过 `requestImageDataAndOrientation(version: .original)` 取**原始字节**
/// —— 若相册里存的是原件（PNG/APNG 动画 chunk 完整），动画即可保留。
///
/// 性能设计（开销小、滚动高效）：
/// - PHCachingImageManager：滚动预取缩略图，复用系统图像缓存
/// - 缩略图 targetSize 限定为网格 1/3 宽（约 150pt），不做全尺寸解码
/// - NSCache 二次缓存 + 网络允许（iCloud 图也能显示）
/// - 仅在点选后才加载原始字节，浏览阶段零原图开销
class CustomPhotoPickerViewController: UIViewController,
  UICollectionViewDataSource, UICollectionViewDelegate,
  UICollectionViewDataSourcePrefetching {

  private let multiple: Bool
  private let completion: ([String]?) -> Void

  private var assets: PHFetchResult<PHAsset>?
  private var selectedIndexes = Set<Int>()
  private var collectionView: UICollectionView!
  private let imageManager = PHCachingImageManager()
  private let thumbnailCache = NSCache<NSString, UIImage>()

  private let cellId = "PhotoCell"
  private let columns: CGFloat = 3
  private var thumbnailSize: CGSize = .zero

  init(multiple: Bool, completion: @escaping ([String]?) -> Void) {
    self.multiple = multiple
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = multiple ? "选择图片" : "选择 APNG/PNG"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
    if multiple {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: "完成", style: .done, target: self, action: #selector(doneTapped))
      navigationItem.rightBarButtonItem?.isEnabled = false
    }

    let layout = UICollectionViewFlowLayout()
    let spacing: CGFloat = 2
    layout.minimumInteritemSpacing = spacing
    layout.minimumLineSpacing = spacing
    let side = (view.bounds.width - spacing * (columns - 1)) / columns
    layout.itemSize = CGSize(width: side, height: side)

    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.backgroundColor = .systemBackground
    collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: cellId)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])

    requestAuthorization()
  }

  // MARK: - 权限

  private func requestAuthorization() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized, .limited:
      loadAssets()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
        DispatchQueue.main.async {
          if newStatus == .authorized || newStatus == .limited {
            self?.loadAssets()
          } else {
            self?.showPermissionDenied()
          }
        }
      }
    default:
      showPermissionDenied()
    }
  }

  private func showPermissionDenied() {
    let alert = UIAlertController(
      title: "需要相册权限",
      message: "请在 设置 → 隐私 → 照片 中允许访问，以便选择图片。",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
      self?.completion(nil)
      self?.dismiss(animated: true)
    })
    present(alert, animated: true)
  }

  private func loadAssets() {
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    assets = PHAsset.fetchAssets(with: options)
    // 缩略图尺寸按网格 1/3 宽（@2x/@3x 由系统处理），避免全尺寸解码
    let side = (view.bounds.width - 2 * (columns - 1)) / columns
    thumbnailSize = CGSize(width: side, height: side)
    // 预取前两屏
    imageManager.allowsCachingHighQualityImages = false
    let firstBatch = min(assets?.count ?? 0, columns * 18)
    if firstBatch > 0 {
      let idxs = (0..<firstBatch).map { IndexPath(item: $0, section: 0) }
      collectionView.prefetchItems(at: idxs)
    }
    collectionView.reloadData()
  }

  // MARK: - 缩略图预取（滚动高效）

  func collectionView(_ collectionView: UICollectionView,
                      prefetchItemsAt indexPaths: [IndexPath]) {
    let assets = self.assets
    let target = thumbnailSize
    let opt = PHImageRequestOptions()
    opt.deliveryMode = .opportunistic
    opt.resizeMode = .fast
    opt.isNetworkAccessAllowed = true

    for indexPath in indexPaths {
      guard let assets = assets, indexPath.item < assets.count else { continue }
      let asset = assets.object(at: indexPath.item)
      let key = asset.localIdentifier as NSString
      if thumbnailCache.object(forKey: key) == nil {
        imageManager.requestImage(
          for: asset, targetSize: target, contentMode: .aspectFill, options: opt
        ) { [weak self] image, _ in
          guard let image = image else { return }
          self?.thumbnailCache.setObject(image, forKey: key)
          DispatchQueue.main.async {
            if let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell {
              cell.imageView.image = image
            }
          }
        }
      }
    }
  }

  // MARK: - UICollectionViewDataSource

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    assets?.count ?? 0
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellId, for: indexPath) as! PhotoCell
    let asset = assets!.object(at: indexPath.item)

    if let cached = thumbnailCache.object(forKey: asset.localIdentifier as NSString) {
      cell.imageView.image = cached
    } else {
      cell.imageView.image = nil
      let targetSize = CGSize(width: 200, height: 200)
      let opt = PHImageRequestOptions()
      opt.deliveryMode = .opportunistic
      opt.resizeMode = .fast
      opt.isNetworkAccessAllowed = true
      imageManager.requestImage(
        for: asset, targetSize: targetSize, contentMode: .aspectFill, options: opt
      ) { [weak self] image, _ in
        guard let image = image else { return }
        self?.thumbnailCache.setObject(image, forKey: asset.localIdentifier as NSString)
        DispatchQueue.main.async {
          if let visible = collectionView.cellForItem(at: indexPath) as? PhotoCell {
            visible.imageView.image = image
          }
        }
      }
    }

    cell.checkmark.isHidden = !selectedIndexes.contains(indexPath.item)
    return cell
  }

  // MARK: - UICollectionViewDelegate

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    let asset = assets!.object(at: indexPath.item)

    if multiple {
      // 多选：切换选中状态
      if selectedIndexes.contains(indexPath.item) {
        selectedIndexes.remove(indexPath.item)
      } else {
        selectedIndexes.insert(indexPath.item)
      }
      navigationItem.rightBarButtonItem?.isEnabled = !selectedIndexes.isEmpty
      collectionView.reloadItems(at: [indexPath])
      return
    }

    // 单选：立即加载原始字节
    exportAssets([asset]) { [weak self] paths in
      self?.completion(paths)
      self?.dismiss(animated: true)
    }
  }

  // MARK: - Actions

  @objc private func cancelTapped() {
    completion(nil)
    dismiss(animated: true)
  }

  @objc private func doneTapped() {
    let selectedAssets = selectedIndexes.sorted().map { assets!.object(at: $0) }
    guard !selectedAssets.isEmpty else { return }
    exportAssets(selectedAssets) { [weak self] paths in
      self?.completion(paths)
      self?.dismiss(animated: true)
    }
  }

  // MARK: - 原始数据导出

  /// 用 PhotoKit 取原始字节（version: .original），PNG/APNG 保留动画 chunk。
  /// 拿不到原件或非 PNG 时回退转码为标准 PNG（不丢可显示性）。
  private func exportAssets(_ assets: [PHAsset], completion: @escaping ([String]?) -> Void) {
    var paths: [String] = []
    let group = DispatchGroup()
    var anySuccess = false

    for asset in assets {
      group.enter()
      let opt = PHImageRequestOptions()
      opt.version = .original
      opt.isNetworkAccessAllowed = true
      opt.deliveryMode = .highQualityFormat

      imageManager.requestImageDataAndOrientation(
        for: asset, options: opt
      ) { data, uti, _, _ in
        defer { group.leave() }
        guard let data = data, !data.isEmpty else { return }

        let dest = FileManager.default.temporaryDirectory
          .appendingPathComponent("picker_\(UUID().uuidString).png")

        // PNG/APNG 原样保留（动画 chunk 不丢）；其他（HEIC/JPEG）转码
        if self.isPngData(data) {
          if (try? data.write(to: dest)) != nil {
            paths.append(dest.path)
            anySuccess = true
          }
        } else if let image = UIImage(data: data), let png = image.pngData() {
          if (try? png.write(to: dest)) != nil {
            paths.append(dest.path)
            anySuccess = true
          }
        }
      }
    }

    group.notify(queue: .main) {
      completion(anySuccess ? paths : nil)
    }
  }

  private func isPngData(_ data: Data) -> Bool {
    data.count > 8 &&
      data[data.startIndex] == 0x89 &&
      data[data.startIndex + 1] == 0x50 &&
      data[data.startIndex + 2] == 0x4E &&
      data[data.startIndex + 3] == 0x47
  }
}

/// 网格单元格：缩略图 + 选中勾选标记
private class PhotoCell: UICollectionViewCell {
  let imageView = UIImageView()
  let checkmark = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])

    checkmark.image = UIImage(systemName: "checkmark.circle.fill")
    checkmark.tintColor = .systemBlue
    checkmark.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(checkmark)
    NSLayoutConstraint.activate([
      checkmark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      checkmark.widthAnchor.constraint(equalToConstant: 22),
      checkmark.heightAnchor.constraint(equalToConstant: 22),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
