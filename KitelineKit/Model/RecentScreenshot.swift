import Foundation
#if canImport(UIKit)
import Photos
import UIKit

/// 「你可能要发送的截图」（同微信）：点「+」时，刚截的图（3 分钟内、还没提示过的）在旁边弹个小气泡，一点就加进要发的图里
enum RecentScreenshot {
    struct Shot: Identifiable {
        let id: String
        let thumb: UIImage
        let asset: PHAsset
    }

    private static let offeredKey = "offeredScreenshot"
    private static let window: TimeInterval = 180

    /// 找最近一张截图；第一次用会问相册权限（只问一次，不给就不弹）。
    /// ask = false：还没给过相册权限就不找、也不问（记待办这种打开就要打字的地方，别一打开先弹授权）
    static func find(ask: Bool = true) async -> Shot? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, ask { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "creationDate > %@", Date().addingTimeInterval(-window) as NSDate)
        options.fetchLimit = 10
        var found: PHAsset?
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, stop in
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                found = asset
                stop.pointee = true
            }
        }
        // 同一张只提示一次
        guard let asset = found, UserDefaults.standard.string(forKey: offeredKey) != asset.localIdentifier else { return nil }
        guard let thumb = await thumbnail(asset) else { return nil }
        UserDefaults.standard.set(asset.localIdentifier, forKey: offeredKey)
        return Shot(id: asset.localIdentifier, thumb: thumb, asset: asset)
    }

    /// 原图数据（iCloud 里的会先下下来）
    static func data(_ asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func thumbnail(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 480),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
#endif
