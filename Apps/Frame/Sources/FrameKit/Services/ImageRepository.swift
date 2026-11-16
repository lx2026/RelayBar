import AppKit
import AVFoundation
import Foundation
import ImageIO

private final class CachedCGImage: NSObject {
  let image: CGImage

  init(_ image: CGImage) {
    self.image = image
  }
}

public actor ImageRepository {
  private let remoteClient: (any RemoteFileReading & RemotePreviewServing)?

  private let cache: NSCache<NSString, CachedCGImage>
  private let decoders = MediaDecodeSlots()
  private var generation = UUID()

  public init(totalCostLimit: Int = 128 * 1_024 * 1_024, remoteClient: (any RemoteFileReading & RemotePreviewServing)? = nil) {
    self.remoteClient = remoteClient
    cache = NSCache<NSString, CachedCGImage>()
    cache.totalCostLimit = totalCostLimit
  }

  public func image(for photo: PhotoItem, maxPixelSize: Int, priority: Int = 0) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    if photo.remote != nil {
      guard let remoteClient else { return nil }
      if photo.format.isVideo, let local = await remoteClient.cachedMedia(photo) {
        return await image(for: local.url, maxPixelSize: maxPixelSize)
      }
      guard let result = try? await remoteClient.preview(photo, pixels: priority > 0 ? 512 : maxPixelSize, priority: priority),
            let data = result.image, !Task.isCancelled else { return nil }
      return await image(data: data, key: photo.contentID, maxPixelSize: maxPixelSize)
    }
    return await image(for: photo.url, maxPixelSize: maxPixelSize)
  }

  public func image(data: Data, key: String, maxPixelSize: Int) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let token = generation
    let key = (key + "|preview|" + String(maxPixelSize / 64)) as NSString
    if let value = cache.object(forKey: key) { return value.image }
    await decoders.acquire()
    guard !Task.isCancelled, generation == token else { await decoders.release(); return nil }
    let task = Task.detached {
      guard !Task.isCancelled else { return nil as CGImage? }
      guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil as CGImage? }
      return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize)
      ] as CFDictionary)
    }
    let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    await decoders.release()
    guard !Task.isCancelled, generation == token else { return nil }
    if let value { cache.setObject(CachedCGImage(value), forKey: key, cost: value.bytesPerRow * value.height) }
    return value
  }

  public func image(for url: URL, maxPixelSize: Int) async -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let normalizedSize = max(64, ((maxPixelSize + 63) / 64) * 64)
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let keyString = "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|\(normalizedSize)"
    let key = keyString as NSString
    if let cached = cache.object(forKey: key) {
      return cached.image
    }

    let token = generation
    let slots = decoders
    await slots.acquire()
    guard !Task.isCancelled, generation == token else { await slots.release(); return nil }
    if let cached = cache.object(forKey: key) { await slots.release(); return cached.image }
    let task = Task.detached(priority: .userInitiated) {
      let result: CGImage?
      if PhotoFormat(pathExtension: url.pathExtension)?.isVideo == true {
        result = await Self.poster(url: url, maxPixelSize: normalizedSize)
      } else {
        result = Self.downsample(url: url, maxPixelSize: normalizedSize)
      }
      await slots.release()
      return result
    }
    let image = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    guard !Task.isCancelled, generation == token else { return nil }

    if let image {
      let cost = max(1, image.bytesPerRow * image.height)
      cache.setObject(CachedCGImage(image), forKey: key, cost: cost)
    }
    return image
  }

  public func invalidate() {
    cache.removeAllObjects()
    generation = UUID()
  }

  private static func poster(url: URL, maxPixelSize: Int) async -> CGImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
    let duration = (try? await asset.load(.duration).seconds) ?? 0
    let seconds = duration.isFinite ? min(0.5, max(0, duration * 0.1)) : 0
    if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
      return result.image
    }
    return try? await generator.image(at: .zero).image
  }

  private static func downsample(url: URL, maxPixelSize: Int) -> CGImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
    else {
      return nil
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }
}

actor MediaDecodeSlots {
  private var active = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func acquire() async {
    if active < 4 { active += 1; return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
  }
}
