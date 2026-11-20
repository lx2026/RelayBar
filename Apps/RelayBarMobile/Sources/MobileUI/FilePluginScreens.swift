import Composition
import HouseStyle
import MobileCore
import SwiftUI

struct DeletePanel: View {
  let path: String
  let submitted: Bool
  let undo: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(submitted ? "Deleting file…" : "Will delete in five seconds", systemImage: "trash")
        .font(.headline)
      Text(path).font(.footnote.monospaced())
      if !submitted {
        Button("Undo", action: undo).frame(minHeight: 44).foregroundStyle(MobileAccent.link)
      }
    }.padding().frame(maxWidth: .infinity, alignment: .leading).card()
  }
}

struct LogPage: View {
  let path: String
  @ObservedObject var files: ServicePort<any RemoteFiles>
  let record: (FileStamp) throws -> Void
  @State private var paused = false
  @State private var content = ""
  @State private var error = ""
  var body: some View {
    LogContent(path: path, content: content, status: error, paused: $paused)
      .task(id: files.generation) {
        guard let service = files.value else { return }
        var cursor = LogCursor()
        var recorded = false
        do {
          while !Task.isCancelled {
            if !paused {
              try await cursor.poll(path, files: service)
              if !recorded {
                let stamp = try await service.stat(path)
                try Task.checkCancellation()
                try record(stamp)
                recorded = true
              }
              if !paused { content = cursor.text }
              error = ""
            }
            try await Task.sleep(for: .seconds(1))
          }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
  }
}
struct LogContent: View {
  let path: String
  let content: String
  var status = ""
  @Binding var paused: Bool
  @State private var scrolling = false
  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        VStack(alignment: .leading) {
          Text((path as NSString).lastPathComponent).font(.title2.bold())
          Text(paused ? "Paused" : "Following").secondaryText()
        }
        Spacer()
        Button(paused ? "Resume" : "Pause") { paused.toggle() }
      }
      if !status.isEmpty { Text(status) }
      ScrollViewReader { proxy in
        ScrollView {
          Text(content).font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
          Color.clear.frame(height: 1).id("end")
        }
        #if os(iOS)
          .onScrollPhaseChange { _, phase in
            scrolling = phase == .interacting || phase == .decelerating
          }
          .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y
          } action: { old, new in
            if scrolling && new < old && new >= 0 { paused = true }
          }
        #else
          .simultaneousGesture(
            DragGesture().onChanged { if $0.translation.height > 4 { paused = true } })
        #endif
        .onChange(of: content) { if !paused { proxy.scrollTo("end", anchor: .bottom) } }
        .onChange(of: paused) { if !paused { proxy.scrollTo("end", anchor: .bottom) } }
      }
    }.padding().background(HouseColor.paper)
  }
}

struct FileActionButtons: View {
  let workspace: HostWorkspace
  let registry: Registry<FileAction>
  let row: FileRow
  let path: String
  let open: () -> Void
  let follow: () -> Void
  let confirm: (FileAction) -> Void
  let failure: (String) -> Void
  var body: some View {
    Entries(registry: registry) { entries in
      ForEach(entries) { action in
        switch action.command {
        case .deleteFile:
          if row.remove != nil { Button("Delete…", role: .destructive) { confirm(action) } }
        case .follow:
          if !row.stamp.directory && canFollow(path) {
            Button(action.title, action: follow)
          }
        case .ordinary:
          if action.id == "favourite" {
            if path != workspace.homePath {
              Button(workspace.pinned.contains { $0.path == path } ? "Unpin" : "Pin") {
                workspace.togglePin(.init(path: path, directory: row.stamp.directory))
              }
            }
          } else {
            Button(row.stamp.directory && action.id == "open" ? "Open Folder" : action.title) {
              do { try action.perform(path, open) } catch { failure(error.localizedDescription) }
            }
          }
        }
      }
    }
  }
}

struct RemovalTarget: Identifiable {
  let path: String
  let action: FileAction
  let row: FileRow
  var id: String { path }
}
struct RemovalPrompt: ViewModifier {
  @Environment(\.scenePhase) private var phase
  @Binding var target: RemovalTarget?
  @State private var pending: RemovalTarget?
  @StateObject private var removal = PendingRemoval()
  let completed: (String) -> Void
  let failure: (String) -> Void
  func body(content: Content) -> some View {
    content.disabled(pending != nil)
      .sheet(item: $target) { selection in
        DeleteConfirmation(path: selection.path, cancel: { target = nil }) {
          target = nil
          guard pending == nil, let remove = selection.row.remove else { return }
          pending = selection
          removal.schedule {
            try selection.action.perform(selection.path) {}
            try await remove()
          } finish: { error in
            pending = nil
            if let error { failure(error) } else { completed(selection.row.id) }
          }
        }.presentationDetents([.medium])
      }
      .safeAreaInset(edge: .bottom) {
        if let pending {
          DeletePanel(path: pending.path, submitted: removal.submitted) {
            removal.undo()
            self.pending = nil
          }
        }
      }.onChange(of: phase) {
        if phase != .active && !removal.submitted {
          removal.undo()
          pending = nil
        }
      }
      .onDisappear {
        removal.undo()
        pending = nil
      }
  }
}

struct DeleteConfirmation: View {
  let path: String
  let cancel: () -> Void
  let confirm: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Delete this file?").font(.title2.bold())
      Text(path).font(.body.monospaced())
      Text("You have five seconds to undo before the file is removed from the host.")
        .secondaryText()
      Button("Delete file", role: .destructive, action: confirm).frame(minHeight: 44)
      Button("Cancel", action: cancel).frame(minHeight: 44)
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(
      HouseColor.panel)
  }
}
