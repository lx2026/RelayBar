import HouseStyle
import MobileCore
import SwiftUI

enum ServicePrompt: Equatable {
  case destination(Destination)
  case certificate(Destination, CertificateInfo, previous: CertificateInfo?)
}
enum ApprovalAnswer { case once, always, refuse, forget }
struct ApprovalSheet: View {
  let prompt: ServicePrompt
  let host: String
  let answer: (ApprovalAnswer) -> Void
  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 14) {
        switch prompt {
        case .destination(let destination):
          Text("Open through " + host + "?").font(.title2.bold())
          Text(destination.label).font(.body.monospaced())
          Button("Allow once") { answer(.once) }
          Button("Always allow for this host") { answer(.always) }
        case .certificate(let endpoint, let leaf, let previous):
          Text(previous == nil ? "Trust this certificate?" : "Certificate changed").font(
            .title2.bold())
          Text(endpoint.label).font(.footnote.monospaced())
          Text(leaf.subject)
          Text("SHA-256").secondaryText()
          Text(leaf.fingerprint).font(.footnote.monospaced()).textSelection(.enabled)
          if let previous {
            Text("Connection refused. Previously trusted fingerprint").secondaryText()
            Text(previous.fingerprint).font(.caption.monospaced())
            Button("Forget previous certificate") { answer(.forget) }
          } else {
            Button("Trust this certificate") { answer(.once) }
          }
        }
        Button("Refuse") { answer(.refuse) }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }.background(HouseColor.panel)
  }
}

@MainActor final class ServiceReview: ObservableObject {
  @Published private(set) var prompt: ServicePrompt?
  private var waiters: [CheckedContinuation<ApprovalAnswer, Never>] = []
  func ask(_ request: ServicePrompt) async -> ApprovalAnswer {
    guard prompt == nil || prompt == request, !Task.isCancelled else { return .refuse }
    prompt = request
    return await withTaskCancellationHandler {
      await withCheckedContinuation { waiters.append($0) }
    } onCancel: {
      Task { @MainActor in if self.prompt == request { self.answer(.refuse) } }
    }
  }
  func answer(_ result: ApprovalAnswer) {
    prompt = nil
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(returning: result) }
  }
}
