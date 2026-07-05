import Foundation
import Photos
import UIKit
import CoreLocation

/// A camera-roll photo that matches a planned place by location and time.
struct PhotoMatch: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
    var takenAt: Date? { asset.creationDate }
    var coordinate: CLLocationCoordinate2D? { asset.location?.coordinate }
}

/// Finds camera-roll photos taken near a place within a time window, and
/// prepares stripped JPEGs for upload. Nothing here uploads or leaves the
/// device — that only happens when the user attaches a chosen photo.
struct PhotoMatchService {
    /// ~150 m default radius; photo GPS is noisy, especially indoors.
    static let defaultRadius: CLLocationDistance = 150

    enum AccessLevel {
        case full        // can scan the whole library to match
        case limited     // user granted specific photos only
        case denied
    }

    func requestAccess() async -> AccessLevel {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        default: return .denied
        }
    }

    /// Photos within `radius` of the coordinate and within [start, end].
    /// Location filtering is in-memory (PhotoKit can't predicate on distance);
    /// the date predicate keeps the fetch small.
    func matches(
        near coordinate: CLLocationCoordinate2D,
        start: Date,
        end: Date,
        radius: CLLocationDistance = defaultRadius
    ) -> [PhotoMatch] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@ AND mediaType == %d",
            start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let assets = PHAsset.fetchAssets(with: options)

        var result: [PhotoMatch] = []
        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            if location.distance(from: target) <= radius {
                result.append(PhotoMatch(asset: asset))
            }
        }
        return result
    }

    /// A small thumbnail for the picker grid.
    func thumbnail(for asset: PHAsset, size: CGFloat = 200) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: size, height: size),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // opportunistic can call back twice; take the first non-degraded
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded || image != nil {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Full-quality image downscaled and re-encoded as JPEG. Re-encoding via
    /// UIImage drops all EXIF/GPS metadata — only the pixels leave the device.
    func strippedJPEG(for asset: PHAsset, maxDimension: CGFloat = 1600, quality: CGFloat = 0.8) async -> Data? {
        let image: UIImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .default,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.resume(returning: image)
                }
            }
        }
        guard let image else { return nil }
        return downscaled(image, maxDimension: maxDimension).jpegData(compressionQuality: quality)
    }

    private func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
