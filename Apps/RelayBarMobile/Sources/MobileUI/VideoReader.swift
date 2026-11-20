#if os(iOS)
  import AVKit
  import BackgroundTasks
  import Composition
  import MobileCore
  import SwiftUI
  import UniformTypeIdentifiers

  @MainActor
  final class VideoLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate, ObservableObject
  {
    let source: MediaSource
    let player = AVPlayer()
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var bitrate: Double = 0
    private var slowSeconds: Double = 0
    @Published var offerDownload = false
    init(_ source: MediaSource) {
      self.source = source
      super.init()
    }
    func prepare() async {
      let asset = AVURLAsset(url: URL(fileURLWithPath: source.path).replacingSchemeForPlayback)
      asset.resourceLoader.setDelegate(self, queue: .main)
      player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
      if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
        bitrate = Double(source.size) * 8 / duration
      }
    }
    func stop() {
      player.pause()
      player.replaceCurrentItem(with: nil)
      for task in requests.values { task.cancel() }
    }
    func resourceLoader(
      _ resourceLoader: AVAssetResourceLoader,
      shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
      if let info = request.contentInformationRequest {
        info.contentType =
          UTType(filenameExtension: (source.path as NSString).pathExtension)?.identifier
        info.contentLength = source.size
        info.isByteRangeAccessSupported = true
      }
      guard let data = request.dataRequest else {
        request.finishLoading()
        return true
      }
      let key = ObjectIdentifier(request)
      requests[key] = Task {
        defer { requests[key] = nil }
        do {
          var offset = max(data.requestedOffset, data.currentOffset)
          guard data.requestedOffset >= 0, data.requestedOffset <= source.size else {
            throw URLError(.badURL)
          }
          let end =
            data.requestsAllDataToEndOfResource
            ? source.size
            : data.requestedOffset
              + min(source.size - data.requestedOffset, Int64(data.requestedLength))
          let firstOffset = offset
          while offset < end {
            let start = ContinuousClock.now
            let bytes = try await source.read(
              offset: offset, length: Int(min(end - offset, 256 << 10)),
              interactive: offset == firstOffset)
            try Task.checkCancellation()
            data.respond(with: bytes)
            offset += Int64(bytes.count)
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            slowSeconds = Double(bytes.count) * 8 < bitrate * seconds ? slowSeconds + seconds : 0
            if slowSeconds >= 3 { offerDownload = true }
          }
          request.finishLoading()
        } catch { if !Task.isCancelled { request.finishLoading(with: error) } }
      }
      return true
    }
    func resourceLoader(
      _ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest
    ) {
      requests[ObjectIdentifier(request)]?.cancel()
    }
  }

  extension URL {
    fileprivate var replacingSchemeForPlayback: URL {
      var parts = URLComponents()
      parts.scheme = "relay-media"
      parts.host = "video"
      parts.path = path
      return parts.url!
    }
  }

  @MainActor final class DownloadTracker {
    static let shared = DownloadTracker()
    private let prefix = (Bundle.main.bundleIdentifier ?? "RelayBar") + ".download."
    private var jobs: [String: Job] = [:]
    @MainActor private final class Job {
      var system: BGContinuedProcessingTask?
      var worker: Task<URL, Error>?
      var done: Int64 = 0
      var expired = false
    }
    private func register(_ id: String) -> Bool {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
        MainActor.assumeIsolated {
          guard let system = task as? BGContinuedProcessingTask,
            let job = self.jobs[task.identifier]
          else {
            task.setTaskCompleted(success: false)
            return
          }
          job.system = system
          system.expirationHandler = {
            Task { @MainActor in
              job.expired = true
              job.worker?.cancel()
            }
          }
        }
      }
    }
    func download(_ source: MediaSource, core: MobileComposition, profile: UUID) async throws -> URL
    {
      let scene = UUID()
      let id = prefix + scene.uuidString
      let job = Job()
      jobs[id] = job
      let name = (source.path as NSString).lastPathComponent
      let request = BGContinuedProcessingTaskRequest(
        identifier: id, title: "Downloading " + name, subtitle: "Reading from host")
      request.strategy = .fail

      let demand = core.runtime.service(Demand.self)
      demand?.show(profile, in: scene)
      let observer = NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { if job.system == nil { job.worker?.cancel() } }
      }
      defer {
        NotificationCenter.default.removeObserver(observer)
        demand?.show(nil, in: scene)
        jobs[id] = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
      }
      if register(id) { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
      guard !Task.isCancelled, !job.expired,
        job.system != nil || UIApplication.shared.applicationState != .background
      else {
        job.system?.setTaskCompleted(success: false)
        throw CancellationError()
      }
      let task = Task {
        let directory = URL.temporaryDirectory.appending(path: scene.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
          let url = directory.appending(path: name)
          try Data().write(to: url)
          let handle = try FileHandle(forWritingTo: url)
          defer { try? handle.close() }
          while job.done < source.size {
            let data = try await source.read(offset: job.done, length: 1 << 20, interactive: false)
            try handle.write(contentsOf: data)
            job.done += Int64(data.count)
            job.system?.progress.totalUnitCount = source.size
            job.system?.progress.completedUnitCount = job.done
          }
          return url
        } catch {
          try? FileManager.default.removeItem(at: directory)
          throw error
        }
      }
      job.worker = task
      do {
        let url = try await withTaskCancellationHandler {
          try await task.value
        } onCancel: {
          task.cancel()
        }
        job.system?.setTaskCompleted(success: true)
        return url
      } catch {
        job.system?.setTaskCompleted(success: false)
        throw error
      }
    }
  }
  struct VideoReader: View {
    @StateObject var loader: VideoLoader
    let local: URL?
    let download: () -> Void
    var body: some View {
      VStack {
        VideoPlayer(player: loader.player)
        if loader.offerDownload, local == nil {
          Button("Streaming is slow. Download and play", action: download)
        }
      }.task { await loader.prepare() }
        .onChange(of: local) {
          if let local {
            loader.player.replaceCurrentItem(with: AVPlayerItem(url: local))
            loader.player.play()
          }
        }.onDisappear { loader.stop() }
    }
  }
#endif
