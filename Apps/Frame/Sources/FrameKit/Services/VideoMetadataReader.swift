import AVFoundation
import Foundation

public struct VideoInfo: Sendable {
  public var duration: Double?
  public var width: Int?
  public var height: Int?
  public var frameRate: Float?
  public var codec: String?
  public var audio: String?
  public var playable = false
  public var embedded: [MetadataRow] = []

  public var durationLabel: String? {
    guard let duration, duration.isFinite, duration >= 0 else { return nil }
    let seconds = Int(duration.rounded(.up))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

public actor VideoMetadataReader {
  private let remoteClient: (any RemoteFileReading)?
  public init(remoteClient: (any RemoteFileReading)? = nil) { self.remoteClient = remoteClient }
  private var cache: [String: VideoInfo] = [:]
  private let readers = MediaDecodeSlots()
  private var generation = UUID()

  public func info(for photo: PhotoItem) async -> VideoInfo {
    if photo.remote != nil {
      guard let remoteClient else { return VideoInfo() }
      guard let local = await remoteClient.cachedMedia(photo) else { return VideoInfo() }
      return await info(for: local)
    }
    guard !Task.isCancelled else { return VideoInfo() }
    let token = generation
    if let value = cache[photo.contentID] { return value }
    await readers.acquire()
    guard !Task.isCancelled else { await readers.release(); return VideoInfo() }
    if let value = cache[photo.contentID] { await readers.release(); return value }
    let value = await Self.inspect(photo.url)
    await readers.release()
    guard !Task.isCancelled, generation == token else { return VideoInfo() }
    if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
    cache[photo.contentID] = value
    return value
  }

  public func invalidate() { cache.removeAll(); generation = UUID() }

  private static func inspect(_ url: URL) async -> VideoInfo {
    let asset = AVURLAsset(url: url)
    var info = VideoInfo()
    info.playable = (try? await asset.load(.isPlayable)) ?? false
    if let time = try? await asset.load(.duration), time.seconds.isFinite {
      info.duration = time.seconds
    }
    if let track = try? await asset.loadTracks(withMediaType: .video).first {
      if let size = try? await track.load(.naturalSize),
        let transform = try? await track.load(.preferredTransform) {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        info.width = Int(abs(rect.width).rounded())
        info.height = Int(abs(rect.height).rounded())
      }
      if let rate = try? await track.load(.nominalFrameRate), rate > 0 { info.frameRate = rate }
      if let format = try? await track.load(.formatDescriptions).first {
        info.codec = codecName(CMFormatDescriptionGetMediaSubType(format))
      }
    } else {
      info.playable = false
    }
    if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
      if let track = audioTracks.first {
        info.audio = "Present"
        if let format = try? await track.load(.formatDescriptions).first {
          info.audio = codecName(CMFormatDescriptionGetMediaSubType(format))
        }
      } else {
        info.audio = "None"
      }
    }
    var rows: [MetadataRow] = []
    let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
    for format in formats {
      for item in (try? await asset.loadMetadata(for: format)) ?? [] {
        guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
        let label = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "Metadata"
        let row = MetadataRow(label: label, value: value)
        if !rows.contains(row) { rows.append(row) }
      }
    }
    info.embedded = rows
    return info
  }

  private static func codecName(_ value: FourCharCode) -> String {
    switch value {
    case kCMVideoCodecType_H264: return "H.264"
    case kCMVideoCodecType_HEVC: return "HEVC"
    case kAudioFormatMPEG4AAC: return "AAC"
    case kAudioFormatLinearPCM: return "PCM"
    default:
      let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
      return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
    }
  }
}
