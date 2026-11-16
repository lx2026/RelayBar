import AVFoundation
import Combine
import Composition

@MainActor
public final class PlaybackController: ObservableObject {
  @Published public private(set) var player: AVPlayer?
  @Published public private(set) var failure: String?
  @Published public private(set) var isPreparing = false
  @Published public private(set) var isPlaying = false
  private var loadTask: Task<Void, Never>?
  private var observations: Set<AnyCancellable> = []
  private var generation = UUID()
  private var work = EffectScope()
  private var retirement: Task<Void, Never>?
  private var isRemote = false

  func prepare(_ photo: PhotoItem, downloadOriginal: Bool, release: @escaping @MainActor () -> Void = {},
               load: @escaping @MainActor (PhotoItem) async throws -> (PhotoItem, VideoInfo)) {
    clear()
    isRemote = photo.remote != nil
    guard photo.format.isVideo, photo.remote == nil || downloadOriginal else { release(); return }
    do { try work.own { release() } } catch { release(); return }
    let token = generation
    isPreparing = true
    loadTask = try? work.task { [weak self] in
      let local: PhotoItem
      let info: VideoInfo
      do { (local, info) = try await load(photo) }
      catch {
        guard let self, !Task.isCancelled, generation == token else { return }
        isPreparing = false; failure = error.localizedDescription; return
      }
      guard let self, !Task.isCancelled, generation == token else { return }
      isPreparing = false
      guard info.playable else {
        failure = "This video can’t be played on this Mac."
        return
      }
      let item = AVPlayerItem(url: local.url)
      let newPlayer = AVPlayer(playerItem: item)
      newPlayer.actionAtItemEnd = .pause
      player = newPlayer
      item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
        guard let self, generation == token else { return }
        if status == .failed {
          newPlayer.pause()
          failure = "This video can’t be played on this Mac."
          player = nil
        }
      }.store(in: &observations)
      newPlayer.publisher(for: \.rate).receive(on: DispatchQueue.main).sink { [weak self] rate in
        self?.isPlaying = rate != 0
      }.store(in: &observations)
    }
  }

  public func toggle() {
    guard let player, failure == nil else { return }
    if player.rate != 0 { player.pause(); return }
    if let duration = player.currentItem?.duration.seconds, duration.isFinite,
       player.currentTime().seconds >= duration - 0.05 {
      player.seek(to: .zero)
    }
    player.play()
  }

  public func clear() {
    isRemote = false
    generation = UUID()
    loadTask?.cancel()
    loadTask = nil
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    observations.removeAll()
    player = nil
    failure = nil
    isPreparing = false
    isPlaying = false
    let previous = retirement, retired = work
    work = EffectScope()
    retirement = Task { await previous?.value; await retired.dispose() }
  }

  public func finishStopping() async { await retirement?.value }
  public func withdrawRemote() { if isRemote { clear() } }
}
