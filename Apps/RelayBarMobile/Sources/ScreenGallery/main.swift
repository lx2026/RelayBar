#if os(macOS)
  import Foundation
  import MobileUI

  do {
    try await MobileGallery.write(
      to: URL(
        fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/screens",
        isDirectory: true))
  } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
  }
#endif
