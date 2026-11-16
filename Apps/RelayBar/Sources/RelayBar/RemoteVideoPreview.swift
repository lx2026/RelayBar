import AVFoundation
import Foundation

enum RemoteVideoPreview {
    static let maximumByteCount: Int64 = 512 * 1_024 * 1_024

    static func validate(contentsOf url: URL) async throws {
        let asset = AVURLAsset(url: url)
        do {
            async let isPlayable = asset.load(.isPlayable)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            guard try await isPlayable, try await !videoTracks.isEmpty else {
                throw RemoteFileError.unsupportedVideo
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemoteFileError.unsupportedVideo
        }
    }
}
