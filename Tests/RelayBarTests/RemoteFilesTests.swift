import AppKit
import AVFoundation
import Darwin
import SwiftUI
import XCTest
@testable import RelayBar

func writePlayableTestMP4(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ]
    )
    guard writer.canAdd(input) else { throw RemoteFileError.unsupportedVideo }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? RemoteFileError.unsupportedVideo
    }
    writer.startSession(atSourceTime: .zero)
    while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard let pool = adaptor.pixelBufferPool else {
        throw RemoteFileError.unsupportedVideo
    }
    var pixelBuffer: CVPixelBuffer?
    guard
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
        let pixelBuffer,
        adaptor.append(pixelBuffer, withPresentationTime: .zero)
    else {
        throw writer.error ?? RemoteFileError.unsupportedVideo
    }
    while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard adaptor.append(
        pixelBuffer,
        withPresentationTime: CMTime(value: 1, timescale: 1)
    ) else {
        throw writer.error ?? RemoteFileError.unsupportedVideo
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error ?? RemoteFileError.unsupportedVideo
    }
}

final class RemotePathTests: XCTestCase {
    func testRequiresAbsoluteSingleLinePath() {
        XCTAssertNotNil(RemotePath.validationMessage(for: ""))
        XCTAssertNotNil(RemotePath.validationMessage(for: "relative/path"))
        XCTAssertNotNil(RemotePath.validationMessage(for: "/safe\nsecond-command"))
        XCTAssertEqual(
            RemotePath.validationMessage(
                for: "/" + String(repeating: "a", count: RemotePath.maximumUTF8ByteCount)
            ),
            "The remote path is too long."
        )
        XCTAssertNil(RemotePath.validationMessage(for: "/srv/app/output"))
    }

    func testNormalizesAndNavigatesPaths() {
        XCTAssertEqual(RemotePath.normalized("/srv/app///"), "/srv/app")
        XCTAssertEqual(RemotePath.normalized("/"), "/")
        XCTAssertEqual(
            RemotePath.normalized(
                String(repeating: "/", count: RemotePath.maximumUTF8ByteCount)
            ),
            "/"
        )
        XCTAssertEqual(RemotePath.normalized("/srv/folder with space "), "/srv/folder with space ")
        XCTAssertEqual(RemotePath.joining("/", "tmp"), "/tmp")
        XCTAssertEqual(RemotePath.joining("/srv/app", "output"), "/srv/app/output")
        XCTAssertEqual(RemotePath.parent(of: "/srv/app/output"), "/srv/app")
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
    }

    func testQuotesBatchPathsWithoutCreatingAnotherCommand() throws {
        XCTAssertEqual(
            try RemotePath.batchQuoted(#"/srv/a "quoted" \ folder"#),
            #""/srv/a \"quoted\" \\ folder""#
        )
        XCTAssertThrowsError(try RemotePath.batchQuoted("/srv/app\nrm -rf"))
        XCTAssertThrowsError(
            try RemotePath.batchQuoted(
                "/" + String(repeating: "a", count: RemotePath.maximumUTF8ByteCount)
            )
        )
    }

    // sftp's own quoting suppresses glob(3) expansion, so paths holding
    // metacharacters are accepted and quoted without extra escaping. Verified
    // against OpenSSH 10.2; see the note on `batchQuoted`. A previous change
    // rejected these paths and had to be reverted, so the behavior is pinned.
    func testAcceptsAndQuotesPathsCarryingGlobMetacharacters() throws {
        for path in ["/srv/star*dir", "/srv/report[2026]", "/srv/draft?.md"] {
            XCTAssertNil(
                RemotePath.validationMessage(for: path),
                "\(path) must remain openable"
            )
            XCTAssertEqual(try RemotePath.batchQuoted(path), "\"\(path)\"")
        }
        XCTAssertEqual(
            try RemotePath.batchQuoted("/Users/me/Downloads/set[1]/payload"),
            #""/Users/me/Downloads/set[1]/payload""#
        )
    }
}

final class RemoteServerTests: XCTestCase {
    func testUsesSSHHostWhenTunnelNameIsTheImportedDestinationEndpoint() {
        let tunnel = Tunnel(
            name: "127.0.0.1:4321",
            localPort: 4_321,
            destinationHost: "127.0.0.1",
            destinationPort: 4_321,
            sshHost: "spark-422e.local"
        )

        let server = RemoteServer(tunnel: tunnel)

        XCTAssertEqual(server.displayName, "spark-422e.local")
    }

    func testUsesSSHHostWhenTunnelHasNoName() {
        let tunnel = Tunnel(
            name: "  ",
            localPort: 4_321,
            destinationHost: "127.0.0.1",
            destinationPort: 4_321,
            sshHost: "spark-422e.local"
        )

        let server = RemoteServer(tunnel: tunnel)

        XCTAssertEqual(server.displayName, "spark-422e.local")
    }

    func testPreservesAnIntentionalTunnelNameAsServerContext() {
        let tunnel = Tunnel(
            name: "Research Mac",
            localPort: 4_321,
            destinationHost: "127.0.0.1",
            destinationPort: 4_321,
            sshHost: "spark-422e.local"
        )

        let server = RemoteServer(tunnel: tunnel)

        XCTAssertEqual(server.displayName, "Research Mac — spark-422e.local")
    }

    @MainActor
    func testCollapsesForwardingPresetsThatUseTheSameSSHConnection() {
        let virtualDesktop = Tunnel(
            name: "Virtual Desktop",
            localPort: 5_902,
            destinationHost: "127.0.0.1",
            destinationPort: 5_902,
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "22"]
        )
        let dashboard = Tunnel(
            name: "Hermes Dashboard",
            localPort: 9_119,
            destinationHost: "127.0.0.1",
            destinationPort: 9_119,
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "22"]
        )
        let model = RemoteFilesModel(tunnels: [virtualDesktop, dashboard])

        XCTAssertEqual(model.servers.count, 1)
        XCTAssertEqual(model.servers.first?.displayName, "spark-422e.local")
    }

    @MainActor
    func testMultiRuleProfilesRemainAvailableAsDeduplicatedSavedServers() {
        let profile = Tunnel(
            name: "spark-422e.local · 2 rules",
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "22"],
            rules: [
                .localTCP(
                    bindAddress: "localhost",
                    port: 4_321,
                    destinationHost: "localhost",
                    destinationPort: 4_321
                ),
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 1_080)
                )
            ]
        )
        let duplicateConnection = Tunnel(
            name: "SOCKS",
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "22"],
            rules: [
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 1_081)
                )
            ]
        )

        let model = RemoteFilesModel(tunnels: [profile, duplicateConnection])

        XCTAssertEqual(model.servers.count, 1)
        XCTAssertEqual(model.servers.first?.displayName, "spark-422e.local")
    }

    @MainActor
    func testGroupTagsDoNotSplitOrMergeRemoteServerConnections() {
        let work = Tunnel(
            name: "Dashboard",
            localPort: 9_119,
            destinationHost: "127.0.0.1",
            destinationPort: 9_119,
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "22"],
            groupTag: "Work"
        )
        let personal = Tunnel(
            name: "Photos",
            localPort: 9_120,
            destinationHost: "127.0.0.1",
            destinationPort: 9_120,
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "22"],
            groupTag: "Personal"
        )
        let distinct = Tunnel(
            name: "Alternate",
            localPort: 9_121,
            destinationHost: "127.0.0.1",
            destinationPort: 9_121,
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "2222"],
            groupTag: "Work"
        )

        let model = RemoteFilesModel(tunnels: [work, personal, distinct])

        XCTAssertEqual(model.servers.count, 2)
        XCTAssertEqual(
            Set(model.servers.map(\.connectionIdentity)),
            Set([
                RemoteServer(tunnel: work).connectionIdentity,
                RemoteServer(tunnel: distinct).connectionIdentity
            ])
        )
    }

    @MainActor
    func testKeepsSSHConnectionsWithDifferentAliasesOrArgumentsSeparate() {
        let defaultConnection = Tunnel(
            name: "Dashboard",
            localPort: 9_119,
            destinationHost: "127.0.0.1",
            destinationPort: 9_119,
            sshHost: "spark-422e.local"
        )
        let explicitUser = Tunnel(
            name: "Dashboard",
            localPort: 9_120,
            destinationHost: "127.0.0.1",
            destinationPort: 9_119,
            sshHost: "linxy97@spark-422e"
        )
        let alternatePort = Tunnel(
            name: "Dashboard",
            localPort: 9_121,
            destinationHost: "127.0.0.1",
            destinationPort: 9_119,
            sshHost: "spark-422e.local",
            additionalArguments: ["-p", "2222"]
        )
        let model = RemoteFilesModel(
            tunnels: [defaultConnection, explicitUser, alternatePort]
        )

        XCTAssertEqual(model.servers.count, 3)
    }
}

final class SSHConfigHostReaderTests: XCTestCase {
    func testParsesConcreteAliasesAndIgnoresPatternsNegationAndComments() {
        let aliases = SSHConfigHostReader.parse(
            """
            Host *
              ServerAliveInterval 30
            Host devbox staging
              HostName devbox.example.com
            host DEVBOX
            Host !blocked *.internal bracket[0-9] question?
            Host "quoted-host" # trailing comment
            Match host other
              User ignored
            """
        )

        XCTAssertEqual(aliases, ["devbox", "staging", "quoted-host"])
    }

    func testBoundsTheNumberOfConfigAliases() {
        let contents = (0..<300)
            .map { "Host server-\($0)" }
            .joined(separator: "\n")

        let aliases = SSHConfigHostReader.parse(contents)

        XCTAssertEqual(aliases.count, SSHConfigHostReader.maximumHostCount)
        XCTAssertEqual(aliases.first, "server-0")
        XCTAssertEqual(aliases.last, "server-255")
    }

    func testRejectsAConfigLargerThanTheReadBound() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configURL = temporaryDirectory.appendingPathComponent("config")
        let oversizedConfig =
            Data("Host should-not-load\n".utf8)
            + Data(repeating: 0x20, count: SSHConfigHostReader.maximumFileSize)
        try oversizedConfig.write(to: configURL)

        XCTAssertTrue(SSHConfigHostReader.load(from: configURL).isEmpty)
    }
}

@MainActor
final class RemoteServerCatalogTests: XCTestCase {
    func testCombinesSourcesInPriorityOrderAndDeduplicatesConnections() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configURL = temporaryDirectory.appendingPathComponent("config")
        try """
        Host config-only
        Host duplicate.example.com
        Host *
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let catalog = RemoteServerCatalog(sshConfigURL: configURL)
        let saved = try catalog.add(name: "Saved", sshHost: "saved.example.com")
        let profile = Tunnel(
            name: "Dashboard",
            localPort: 8_080,
            destinationHost: "localhost",
            destinationPort: 3_000,
            sshHost: "duplicate.example.com"
        )
        catalog.recordSuccessfulOpen(
            RemoteServer(
                id: UUID(),
                name: "Recent",
                sshHost: "recent.example.com",
                additionalArguments: [],
                source: .sshConfig
            )
        )

        let servers = catalog.servers(from: [profile])

        XCTAssertEqual(
            servers.map(\.sshHost),
            [
                "recent.example.com",
                saved.sshHost,
                "duplicate.example.com",
                "config-only"
            ]
        )
        XCTAssertEqual(
            servers.map(\.source),
            [.recent, .saved, .forwardingProfile, .sshConfig]
        )
    }

    func testPersistsStandaloneHostsAndRemovalAlsoDropsTheirRecentEntry() throws {
        let suiteName = "RelayBar.RemoteServerCatalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = RemoteServerCatalog(defaults: defaults)
        let saved = try catalog.add(name: "Build Server", sshHost: "builder.example.com")
        catalog.recordSuccessfulOpen(saved)

        let reloaded = RemoteServerCatalog(defaults: defaults)
        XCTAssertEqual(reloaded.servers(from: []).map(\.source), [.recent])
        XCTAssertEqual(reloaded.servers(from: []).first?.displayName, "Build Server — builder.example.com")

        reloaded.removeSavedServer(id: saved.id)

        XCTAssertTrue(reloaded.servers(from: []).isEmpty)
        XCTAssertTrue(RemoteServerCatalog(defaults: defaults).servers(from: []).isEmpty)
    }

    func testRejectsDuplicateAndInvalidStandaloneHosts() throws {
        let catalog = RemoteServerCatalog()
        _ = try catalog.add(name: "", sshHost: "devbox")

        XCTAssertThrowsError(try catalog.add(name: "Duplicate", sshHost: "devbox")) {
            XCTAssertEqual($0 as? RemoteServerCatalogError, .duplicateSavedHost)
        }
        XCTAssertThrowsError(try catalog.add(name: "", sshHost: "-oProxyCommand=bad")) {
            XCTAssertEqual($0 as? RemoteServerCatalogError, .invalidHost)
        }
        XCTAssertThrowsError(try catalog.add(name: "Build\nServer", sshHost: "builder")) {
            XCTAssertEqual($0 as? RemoteServerCatalogError, .invalidName)
        }
    }

    func testRecentConnectionsStayBoundedAndNewestFirst() {
        let catalog = RemoteServerCatalog()
        for index in 0..<12 {
            catalog.recordSuccessfulOpen(
                RemoteServer(
                    id: UUID(),
                    name: "Server \(index)",
                    sshHost: "server-\(index)",
                    additionalArguments: []
                )
            )
        }

        let servers = catalog.servers(from: [])

        XCTAssertEqual(servers.count, 8)
        XCTAssertEqual(servers.first?.sshHost, "server-11")
        XCTAssertEqual(servers.last?.sshHost, "server-4")
        XCTAssertTrue(servers.allSatisfy { $0.source == .recent })
    }

    func testRecentLocationsPersistDeduplicateAndStayBounded() throws {
        let suiteName = "RelayBar.RemoteLocations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = RemoteServerCatalog(defaults: defaults)
        let server = RemoteServer(
            id: UUID(),
            name: "Development",
            sshHost: "devbox",
            additionalArguments: []
        )

        for index in 0..<18 {
            catalog.recordSuccessfulOpen(server, path: "/srv/project-\(index)/")
        }
        let reopened = try XCTUnwrap(
            catalog.recordSuccessfulOpen(server, path: "/srv/project-10")
        )

        let reloaded = RemoteServerCatalog(defaults: defaults)
        let locations = reloaded.recentLocations(from: [])
        XCTAssertEqual(locations.count, 16)
        XCTAssertEqual(locations.first?.id, reopened.id)
        XCTAssertEqual(locations.first?.path, "/srv/project-10")
        XCTAssertEqual(Set(locations.map(\.key)).count, locations.count)
        XCTAssertFalse(locations.contains { $0.path == "/srv/project-0" })
    }

    func testRecentLocationRemovalAndClearDoNotRemoveHosts() throws {
        let suiteName = "RelayBar.RemoteLocationRemoval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = RemoteServerCatalog(defaults: defaults)
        let server = try catalog.add(name: "Development", sshHost: "devbox")
        let first = try XCTUnwrap(catalog.recordSuccessfulOpen(server, path: "/srv/one"))
        _ = catalog.recordSuccessfulOpen(server, path: "/srv/two")

        catalog.removeRecentLocation(id: first.id)
        XCTAssertEqual(catalog.recentLocations(from: []).map(\.path), ["/srv/two"])
        catalog.clearRecentLocations()

        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
        XCTAssertEqual(catalog.servers(from: []).first?.sshHost, "devbox")
    }

    func testRemovingSavedHostAlsoDropsMatchingLocations() throws {
        let catalog = RemoteServerCatalog()
        let server = try catalog.add(name: "Development", sshHost: "devbox")
        _ = catalog.recordSuccessfulOpen(server, path: "/srv/project")

        catalog.removeSavedServer(id: server.id)

        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
    }
}

final class RemoteImageDecoderTests: XCTestCase {
    func testDecodesAValidImageToABoundedNSImage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("pixel.png")
        try validPNGData.write(to: imageURL)

        let image = try RemoteImageDecoder.decode(contentsOf: imageURL)

        XCTAssertEqual(image.size.width, 1)
        XCTAssertEqual(image.size.height, 1)
    }

    func testRejectsMalformedImageData() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: imageURL)

        XCTAssertThrowsError(try RemoteImageDecoder.decode(contentsOf: imageURL)) { error in
            XCTAssertEqual(error as? RemoteFileError, .unsupportedImage)
        }
    }
}

final class RemoteJSONPreviewTests: XCTestCase {
    func testRecognizesCaseInsensitiveJSONRegularFilesOnly() {
        for name in ["data.json", "EXPORT.JSON", "mixed.JsOn"] {
            let entry = RemoteFileEntry(
                name: name,
                path: "/srv/app/\(name)",
                kind: .file,
                size: 8,
                modificationText: "Aug 30 12:00"
            )
            XCTAssertTrue(entry.isPreviewableJSON)
            XCTAssertTrue(entry.isPreviewable)
        }
        let directory = RemoteFileEntry(
            name: "data.json",
            path: "/srv/app/data.json",
            kind: .directory,
            size: nil,
            modificationText: "Aug 30 12:00"
        )
        XCTAssertFalse(directory.isPreviewableJSON)
    }

    func testLoadsBOMPrefixedObjectsArraysAndScalarsAsFormattedUTF8() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, bytes) in [
            ("object.json", Data([0xEF, 0xBB, 0xBF]) + Data(#"{"b":2,"a":true}"#.utf8)),
            ("array.json", Data(#"[1,null,"value"]"#.utf8)),
            ("scalar.json", Data(#""value""#.utf8))
        ] {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            let document = try await RemoteJSONDecoder.load(contentsOf: url)
            XCTAssertFalse(document.formattedText.isEmpty)
        }

        let object = try await RemoteJSONDecoder.load(
            contentsOf: directory.appendingPathComponent("object.json")
        )
        XCTAssertTrue(object.formattedText.contains("\n"))
        XCTAssertLessThan(
            object.formattedText.range(of: #""a""#)!.lowerBound,
            object.formattedText.range(of: #""b""#)!.lowerBound
        )
    }

    func testRejectsInvalidEncodingNULMalformedAndOversizedInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, Data, RemoteFileError)] = [
            ("utf8.json", Data([0xC3, 0x28]), .invalidJSONEncoding),
            ("nul.json", Data([0x7B, 0x00, 0x7D]), .invalidJSONEncoding),
            ("broken.json", Data(#"{"missing":}"#.utf8), .malformedJSON),
            (
                "large.json",
                Data(repeating: 0x20, count: RemoteJSONDecoder.maximumByteCount + 1),
                .jsonTooLarge
            )
        ]
        for (name, data, expected) in cases {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            do {
                _ = try await RemoteJSONDecoder.load(contentsOf: url)
                XCTFail("Expected \(expected) for \(name)")
            } catch {
                XCTAssertEqual(error as? RemoteFileError, expected)
            }
        }
    }

    @MainActor
    func testSyntaxHighlighterDistinguishesKeysValuesAndNumbers() {
        let text = #"{"key":"value","count":2,"enabled":true}"#
        let highlighted = RemoteJSONSyntaxHighlighter.attributedString(for: text)
        let source = text as NSString
        let keyColor = highlighted.attribute(
            .foregroundColor,
            at: source.range(of: #""key""#).location,
            effectiveRange: nil
        ) as? NSColor
        let valueColor = highlighted.attribute(
            .foregroundColor,
            at: source.range(of: #""value""#).location,
            effectiveRange: nil
        ) as? NSColor
        let numberColor = highlighted.attribute(
            .foregroundColor,
            at: source.range(of: "2").location,
            effectiveRange: nil
        ) as? NSColor

        XCTAssertEqual(keyColor, .systemPurple)
        XCTAssertEqual(valueColor, .systemRed)
        XCTAssertEqual(numberColor, .systemBlue)
    }

    @MainActor
    func testNativeTextViewWrapsLongTokensAndProvidesVerticalScrolling() throws {
        let longValue = String(repeating: "unbroken-value-", count: 80)
        let text = (0..<24).map { #""row-\#($0)": "\#(longValue)""# }
            .joined(separator: ",\n")
        let document = RemoteJSONDocument(formattedText: "{\n\(text)\n}")
        let scrollView = RemoteJSONTextViewFactory.make(document: document)
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 170)
        scrollView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let textContainer = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertTrue(textView.isVerticallyResizable)
        XCTAssertFalse(textView.isHorizontallyResizable)
        XCTAssertTrue(textContainer.widthTracksTextView)
        XCTAssertFalse(textContainer.heightTracksTextView)
        XCTAssertEqual(textView.string, document.formattedText)
        XCTAssertGreaterThan(textView.frame.height, scrollView.contentSize.height)
        XCTAssertLessThanOrEqual(
            layoutManager.usedRect(for: textContainer).maxX,
            textContainer.containerSize.width + 0.5
        )

        let maximumOffset = max(
            textView.frame.height - scrollView.contentSize.height,
            0
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)

        scrollView.frame.size.width = 520
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(textView.frame.width, scrollView.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(
            textContainer.containerSize.width,
            textView.bounds.width - (textView.textContainerInset.width * 2),
            accuracy: 0.5
        )
    }
}

final class RemoteVideoPreviewTests: XCTestCase {
    func testRecognizesCaseInsensitiveMP4RegularFilesOnly() {
        for name in ["clip.mp4", "MOVIE.MP4", "mixed.Mp4"] {
            let entry = RemoteFileEntry(
                name: name,
                path: "/srv/app/\(name)",
                kind: .file,
                size: 128,
                modificationText: "Aug 30 12:00"
            )
            XCTAssertTrue(entry.isPreviewableVideo)
            XCTAssertTrue(entry.isPreviewable)
        }
        let directory = RemoteFileEntry(
            name: "clip.mp4",
            path: "/srv/app/clip.mp4",
            kind: .directory,
            size: nil,
            modificationText: "Aug 30 12:00"
        )
        XCTAssertFalse(directory.isPreviewableVideo)
    }

    func testRejectsUnreadableOrUnsupportedMP4Data() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.mp4")
        try Data("not media".utf8).write(to: url)

        do {
            try await RemoteVideoPreview.validate(contentsOf: url)
            XCTFail("Expected invalid media to be rejected.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .unsupportedVideo)
        }
    }

    func testAcceptsAPlayableMP4WithAVideoTrack() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("playable.mp4")
        try await writePlayableTestMP4(to: url)

        try await RemoteVideoPreview.validate(contentsOf: url)
    }

    @MainActor
    func testNativePlayerControllerInstallsMediaWithoutAutoplayAndStopsCleanly() {
        let controller = RemoteVideoPlayerController()
        let url = URL(fileURLWithPath: "/tmp/RelayBar-paused-preview.mp4")

        controller.show(url)

        XCTAssertEqual(controller.url, url)
        XCTAssertNotNil(controller.player.currentItem)
        XCTAssertEqual(controller.player.rate, 0)
        controller.stop()
        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.url)
    }
}

@MainActor
final class RemoteUploadPresentationTests: XCTestCase {
    func testStagingPercentageRequiresAcknowledgedPutSuccessForOneHundred() {
        var presentation = RemoteFilesModel.UploadPresentation(
            localFile: URL(fileURLWithPath: "/tmp/payload"),
            replaceExisting: false,
            connectionIdentity: RemoteServer.ConnectionIdentity(
                sshHost: "devbox",
                additionalArguments: []
            ),
            remoteDirectory: "/srv/app",
            phase: .active,
            operationPhase: .staging,
            completedBytes: 7,
            totalBytes: 7,
            isStagingComplete: false,
            message: nil
        )
        XCTAssertEqual(presentation.percentage, 99)

        presentation.isStagingComplete = true
        XCTAssertEqual(presentation.percentage, 100)
        presentation.operationPhase = .publishing
        XCTAssertNil(presentation.percentage)
    }

    func testZeroByteUploadBecomesCompleteOnlyAfterPutSuccess() {
        var presentation = RemoteFilesModel.UploadPresentation(
            localFile: URL(fileURLWithPath: "/tmp/empty"),
            replaceExisting: false,
            connectionIdentity: RemoteServer.ConnectionIdentity(
                sshHost: "devbox",
                additionalArguments: []
            ),
            remoteDirectory: "/srv/app",
            phase: .active,
            operationPhase: .staging,
            completedBytes: 0,
            totalBytes: 0,
            isStagingComplete: false,
            message: nil
        )
        XCTAssertEqual(presentation.percentage, 0)
        presentation.isStagingComplete = true
        XCTAssertEqual(presentation.percentage, 100)
    }
}

final class RemoteMarkdownTests: XCTestCase {
    func testRecognizesOnlyConventionalMarkdownFileExtensions() {
        for name in ["README.md", "guide.markdown", "notes.mdown", "draft.mkd"] {
            let entry = RemoteFileEntry(
                name: name,
                path: "/srv/app/\(name)",
                kind: .file,
                size: 128,
                modificationText: "Jul 24 00:20"
            )
            XCTAssertTrue(entry.isPreviewableMarkdown, name)
            XCTAssertTrue(entry.isPreviewable, name)
        }

        let source = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            kind: .directory,
            size: nil,
            modificationText: "Jul 24 00:20"
        )
        XCTAssertFalse(source.isPreviewableMarkdown)
    }

    func testLoadsUTF8AndParsesGitHubFlavoredMarkdownOffTheMainPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("README.md")
        let source = """
        \u{FEFF}# RelayBar

        - [x] safe preview

        | Feature | State |
        | --- | --- |
        | Markdown | ready |

        ~~removed~~
        """
        try Data(source.utf8).write(to: url)

        let decoded = try RemoteMarkdownDecoder.decode(Data(source.utf8))
        let document = try await RemoteMarkdownDecoder.load(contentsOf: url)

        XCTAssertTrue(decoded.hasPrefix("# RelayBar"))
        XCTAssertTrue(document.plainText.contains("RelayBar"))
        XCTAssertTrue(document.plainText.contains("safe preview"))
        XCTAssertTrue(document.plainText.contains("Markdown"))
        XCTAssertTrue(document.plainText.contains("ready"))
    }

    func testCancellationStopsDetachedParsingWork() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("README.md")
        try Data("# RelayBar".utf8).write(to: url)
        let probe = LockedCancellationProbe()
        let task = Task {
            try await RemoteMarkdownDecoder.load(
                contentsOf: url,
                renderingSourceWith: { source, _ in
                    probe.markStarted()
                    let timeout = Date().addingTimeInterval(2)
                    while !Task.isCancelled, Date() < timeout {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    probe.recordWorkerCancellation(Task.isCancelled)
                    return source
                }
            )
        }

        let startDeadline = Date().addingTimeInterval(1)
        while !probe.hasStarted, Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(probe.hasStarted)

        let cancellationStart = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(probe.workerObservedCancellation)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 0.5)
    }

    func testCancellationStopsTheRealCompatibilityPassWithinBound() async throws {
        let source = Array(repeating: "==cancel me==", count: 40_000)
            .joined(separator: "\n")
        let task = Task.detached(priority: .userInitiated) {
            ObsidianMarkdownCompatibility.renderSource(source)
        }

        try await Task.sleep(for: .milliseconds(5))
        let cancellationStart = Date()
        task.cancel()
        let rendered = await task.value

        XCTAssertEqual(rendered, source)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 0.5)
    }

    func testTranslatesObsidianReadingSyntaxWithoutFetchingOrExecutingContent() {
        let source = """
        ---
        status: ready
        tags: [relay, mac]
        ---

        > [!warning] Check the tunnel
        > Keep the service private.

        This is ==important== and links to [[Operations|the runbook]].[^note]
        ![[architecture.png]]
        Inline math is $x^2 + y^2$.

        $$
        \\int_0^1 x^2\\,dx
        $$

        %% hidden operational note %%

        [^note]: A local footnote.

        ```mermaid
        graph TD
          A[==literal==] --> B[[wiki literal]]
        ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("> **Properties**"))
        XCTAssertTrue(rendered.contains("`status` — ready"))
        XCTAssertTrue(rendered.contains("> **⚠︎ Check the tunnel**"))
        XCTAssertTrue(rendered.contains("This is **important**"))
        XCTAssertTrue(rendered.contains("[the runbook](relaybar-wiki://open/"))
        XCTAssertTrue(rendered.contains("**Embedded file not loaded:** `architecture.png`"))
        XCTAssertTrue(rendered.contains("relaybar-math://inline/"))
        XCTAssertTrue(rendered.contains("relaybar-math://display/"))
        XCTAssertTrue(rendered.contains("#### Footnotes"))
        XCTAssertTrue(rendered.contains("1. A local footnote."))
        XCTAssertFalse(rendered.contains("hidden operational note"))
        XCTAssertTrue(rendered.contains("A[==literal==] --> B[[wiki literal]]"))
    }

    func testRendersFoldableAndNestedObsidianCalloutsAsExpandedReadingContent() {
        let source = """
        > [!faq]- Collapsed in Obsidian
        > The answer remains readable.
        >
        > > [!todo]+ Nested task
        > > This is ==ready== with [[Runbook|the runbook]].
        >
        > > > [!abstract]
        > > > A third level.

        > [!custom-question-type] Custom type
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("> **? Collapsed in Obsidian**"))
        XCTAssertTrue(rendered.contains("> The answer remains readable."))
        XCTAssertTrue(rendered.contains("> > **☑︎ Nested task**"))
        XCTAssertTrue(rendered.contains("> > This is **ready**"))
        XCTAssertTrue(rendered.contains("[the runbook](relaybar-wiki://open/"))
        XCTAssertTrue(rendered.contains("> > > **▤ Abstract**"))
        XCTAssertTrue(rendered.contains("> > > A third level."))
        XCTAssertTrue(rendered.contains("> **ⓘ Custom type**"))
        XCTAssertFalse(rendered.contains("[!faq]-"))
        XCTAssertFalse(rendered.contains("[!todo]+"))
    }

    func testRendersObsidianCustomTaskMarkersWithoutRewritingIndentedCode() {
        let source = """
        - [?] Investigate
        > - [-] Deferred
        - [ ] Open
        - [x] Complete

        Code example:

            - [?] literal code sample
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("- [x] Investigate"))
        XCTAssertTrue(rendered.contains("> - [x] Deferred"))
        XCTAssertTrue(rendered.contains("- [ ] Open"))
        XCTAssertTrue(rendered.contains("- [x] Complete"))
        XCTAssertTrue(rendered.contains("    - [?] literal code sample"))
    }

    func testTransformsCompatibilitySyntaxInsideFourSpaceNestedLists() {
        let source = """
        - Parent
            - [?] Nested ==important== [[Runbook|runbook]] %% hidden %%
            - ```markdown
              [[literal]] ==literal== %% literal %%
              ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(
            rendered.contains(
                "    - [x] Nested **important** [runbook](relaybar-wiki://open/"
            )
        )
        XCTAssertFalse(rendered.contains("hidden"))
        XCTAssertTrue(rendered.contains("[[literal]] ==literal== %% literal %%"))
        XCTAssertFalse(rendered.contains("**literal**"))
    }

    func testRendersInlineFootnotesAndKeepsCodeExamplesLiteral() {
        let source = """
        Inline note^[This is ==important== with [docs](https://example.com) and [[Runbook|runbook]].]
        Escaped \\^[not a footnote].
        `^[inline code]`

        > ```markdown
        > ^[fenced code]
        > ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertEqual(
            rendered.components(separatedBy: "relaybar-footnote://note/").count - 1,
            1
        )
        XCTAssertTrue(rendered.contains("#### Footnotes"))
        XCTAssertTrue(rendered.contains("1. This is **important**"))
        XCTAssertTrue(rendered.contains("[docs](https://example.com)"))
        XCTAssertTrue(rendered.contains("[runbook](relaybar-wiki://open/"))
        XCTAssertTrue(rendered.contains("\\^[not a footnote]"))
        XCTAssertTrue(rendered.contains("`^[inline code]`"))
        XCTAssertTrue(rendered.contains("> ^[fenced code]"))
    }

    func testRendersObsidianTwoSpaceMultilineFootnotes() {
        let source = """
        Read the details.[^detail]

        [^detail]: First line with ==highlighting==.
          Second line with [[Runbook|the runbook]].

          A second paragraph.

        This stays in the document.
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("#### Footnotes"))
        XCTAssertTrue(
            rendered.contains(
                "1. First line with **highlighting**. Second line with "
                    + "[the runbook](relaybar-wiki://open/"
            )
        )
        XCTAssertTrue(rendered.contains("A second paragraph."))
        XCTAssertTrue(rendered.contains("This stays in the document."))
        XCTAssertFalse(rendered.contains("[^detail]:"))
    }

    func testHidesObsidianBlockIdentifiersOnlyOutsideCode() {
        let source = """
        Paragraph text ^paragraph-id
        ^standalone-id
        > ^quoted-block-id
        - List item ^list-id

        Escaped \\^literal-id
        `code ^code-id`

        `multiline code
        content ^multiline-code-id`

        [[Note#^paragraph-id|Linked block]]
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("Paragraph text"))
        XCTAssertTrue(rendered.contains("- List item"))
        XCTAssertFalse(rendered.contains("^paragraph-id"))
        XCTAssertFalse(rendered.contains("^standalone-id"))
        XCTAssertFalse(rendered.contains("^quoted-block-id"))
        XCTAssertFalse(rendered.contains("^list-id"))
        XCTAssertTrue(rendered.contains("\\^literal-id"))
        XCTAssertTrue(rendered.contains("`code ^code-id`"))
        XCTAssertTrue(rendered.contains("content ^multiline-code-id`"))
        XCTAssertTrue(rendered.contains("[Linked block](relaybar-wiki://open/"))
    }

    func testParsesEscapedObsidianWikiPipesInsideTables() throws {
        let referenceToken = "table-preview"
        let source = """
        | Link | Embed |
        | --- | --- |
        | [[Basic formatting syntax\\|Markdown syntax]] | ![[Engelbart.jpg\\|200]] |
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(
            source,
            referenceToken: referenceToken
        )
        let wikiURL = try XCTUnwrap(
            rendered
                .split(whereSeparator: { $0 == "(" || $0 == ")" })
                .compactMap { URL(string: String($0)) }
                .first { $0.scheme == "relaybar-wiki" }
        )

        XCTAssertTrue(rendered.contains("[Markdown syntax](relaybar-wiki://open/"))
        XCTAssertEqual(
            ObsidianMarkdownCompatibility.internalValue(
                from: wikiURL,
                expectedScheme: "relaybar-wiki",
                referenceToken: referenceToken
            )?.value,
            "Basic formatting syntax"
        )
        XCTAssertTrue(
            rendered.contains("**Embedded file not loaded:** `Engelbart.jpg`")
        )
        XCTAssertFalse(rendered.contains(#"syntax\"#))
        XCTAssertFalse(rendered.contains(#"jpg\"#))
    }

    func testGroupsCommonMultilineFrontmatterValuesIntoProperties() {
        let source = """
        ---
        aliases:
          - Relay Bar
          - Port Forwarding
        tags:
          - remote
          - macOS
        description: |
          A focused remote reader.
          No vault indexing.
        ---

        # Document
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("`aliases` — Relay Bar · Port Forwarding"))
        XCTAssertTrue(rendered.contains("`tags` — remote · macOS"))
        XCTAssertTrue(
            rendered.contains(
                "`description` — A focused remote reader\\. · No vault indexing\\."
            )
        )
        XCTAssertFalse(rendered.contains("> `- Relay Bar`"))
    }

    func testKeepsActiveRawHTMLLiteralInParsedReadingText() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unsafe.md")
        let source = """
        <script>alert("never execute")</script>
        <style>body { display: none; }</style>
        """
        try Data(source.utf8).write(to: url)

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)
        let document = try await RemoteMarkdownDecoder.load(contentsOf: url)

        XCTAssertTrue(rendered.contains("&lt;script>"))
        XCTAssertTrue(rendered.contains("&lt;/script>"))
        XCTAssertTrue(rendered.contains("&lt;style>"))
        XCTAssertTrue(document.plainText.contains("<script>"))
        XCTAssertTrue(document.plainText.contains("never execute"))
        XCTAssertTrue(document.plainText.contains("<style>"))
    }

    func testKeepsMultilineRawHTMLAndLinkLabelHTMLLiteral() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("multiline-unsafe.md")
        let source = """
        <script
          data-value="unsafe">
        alert("never execute")
        </script>

        [<style>linked label</style>](https://example.com)
        """
        try Data(source.utf8).write(to: url)

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)
        let document = try await RemoteMarkdownDecoder.load(contentsOf: url)

        XCTAssertTrue(rendered.contains("&lt;script"))
        XCTAssertTrue(rendered.contains("data-value=\"unsafe\">"))
        XCTAssertTrue(
            rendered.contains(
                "[&lt;style>linked label&lt;/style>](https://example.com)"
            )
        )
        XCTAssertTrue(document.plainText.contains("<script"))
        XCTAssertTrue(document.plainText.contains("alert(\"never execute\")"))
        XCTAssertTrue(document.plainText.contains("<style>linked label</style>"))
    }

    func testEscapesHTMLLookingSpansWithoutBreakingAllowedAutolinks() {
        let source = """
        <https://example.com/docs>
        <hello@example.com>
        <script data-value="unsafe">
        <javascript:alert(1)>
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("<https://example.com/docs>"))
        XCTAssertTrue(rendered.contains("<hello@example.com>"))
        XCTAssertTrue(rendered.contains("&lt;script data-value=\"unsafe\">"))
        XCTAssertTrue(rendered.contains("&lt;javascript:alert(1)>"))
    }

    func testReplacesMarkdownImagesWithVisibleInertAltTextOutsideCode() {
        let source = """
        ![Architecture diagram](https://example.com/private.png)
        Inline ![deployment status](./status.svg "Current status") stays readable.
        ![](file:///Users/example/secret.png)

        `![inline code](https://example.com/literal.png)`

        ```markdown
        ![fenced code](https://example.com/literal.png)
        ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("**Image not loaded:** Architecture diagram"))
        XCTAssertTrue(rendered.contains("**Image not loaded:** deployment status"))
        XCTAssertTrue(rendered.contains("**Image not loaded:** Unlabelled image"))
        XCTAssertFalse(rendered.contains("https://example.com/private.png"))
        XCTAssertFalse(rendered.contains("./status.svg"))
        XCTAssertFalse(rendered.contains("file:///Users/example/secret.png"))
        XCTAssertTrue(
            rendered.contains(
                "`![inline code](https://example.com/literal.png)`"
            )
        )
        XCTAssertTrue(
            rendered.contains(
                "![fenced code](https://example.com/literal.png)"
            )
        )
    }

    func testReplacesDefinedReferenceImagesWithoutChangingLinksOrCode() {
        let source = """
        ![Full diagram][asset]
        ![Collapsed diagram][]
        ![Shortcut diagram]
        ![Mixed case][MIXED   LABEL]
        ![Next line destination][next line]
        ![After heading][heading reference]
        [ordinary link][asset]
        ![Undefined image][missing]
        ![Code-only image]
        ![Fenced-only image]

        [asset]: https://example.com/full.png
        [Collapsed diagram]: https://example.com/collapsed.png
        [shortcut diagram]: https://example.com/shortcut.png
        [mixed label]: https://example.com/mixed.png
        [next line]:
          <https://example.com/next.png>

        # Reference boundary
        [heading reference]: https://example.com/heading.png

            [Code-only image]: https://example.com/code.png

        ```markdown
        [Fenced-only image]: https://example.com/fenced.png
        ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        for label in [
            "Full diagram",
            "Collapsed diagram",
            "Shortcut diagram",
            "Mixed case",
            "Next line destination",
            "After heading"
        ] {
            XCTAssertTrue(
                rendered.contains("**Image not loaded:** \(label)"),
                label
            )
        }
        XCTAssertEqual(
            rendered.components(separatedBy: "**Image not loaded:**").count - 1,
            6
        )
        XCTAssertTrue(rendered.contains("[ordinary link][asset]"))
        XCTAssertTrue(rendered.contains("![Undefined image][missing]"))
        XCTAssertTrue(rendered.contains("![Code-only image]"))
        XCTAssertTrue(rendered.contains("![Fenced-only image]"))
        XCTAssertTrue(
            rendered.contains(
                "    [Code-only image]: https://example.com/code.png"
            )
        )
        XCTAssertTrue(
            rendered.contains(
                "[Fenced-only image]: https://example.com/fenced.png"
            )
        )
    }

    func testDoesNotActivateMalformedOrParagraphInterruptingReferenceDefinitions() {
        let source = """
        Ordinary paragraph
        [paragraph lookalike]: https://example.com/not-a-definition.png
        ![Paragraph image][paragraph lookalike]

        ![Missing destination][empty]
        [empty]:

        ![Malformed destination][malformed]
        [malformed]: <https://example.com/unclosed.png
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertFalse(rendered.contains("**Image not loaded:**"))
        XCTAssertTrue(
            rendered.contains("![Paragraph image][paragraph lookalike]")
        )
        XCTAssertTrue(rendered.contains("![Missing destination][empty]"))
        XCTAssertTrue(rendered.contains("![Malformed destination][malformed]"))
    }

    func testHidesObsidianMarkdownImageSizeHintsWithoutDroppingAltText() {
        let source = """
        ![Chart|640x480](https://example.com/chart.png)
        ![Icon|96](https://example.com/icon.png)
        ![Reference chart|320][asset]
        ![Metric | p95](https://example.com/metric.png)
        ![|120](https://example.com/unlabelled.png)

        | Preview |
        | --- |
        | ![Table chart\\|240](https://example.com/table.png) |

        [asset]: https://example.com/reference.png
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        for label in ["Chart", "Icon", "Reference chart", "Table chart"] {
            XCTAssertTrue(rendered.contains("**Image not loaded:** \(label)"))
        }
        XCTAssertTrue(
            rendered.contains("**Image not loaded:** Metric \\| p95")
        )
        XCTAssertTrue(rendered.contains("**Image not loaded:** Unlabelled image"))
        for sizeHint in ["640x480", "|96", "|320", "240", "|120"] {
            XCTAssertFalse(rendered.contains(sizeHint), sizeHint)
        }
        XCTAssertTrue(rendered.contains("[asset]: https://example.com/reference.png"))
    }

    func testRendersObsidianTagsAsInertReferencesOutsideCodeAndURLs() {
        let referenceToken = "tag-compatibility"
        let source = """
        #meeting #inbox/to-read #status/✅ #status/❤️ and (#MixedCase).
        Numeric #1984, language C# and color color:#fff stay literal.
        https://example.com/#meeting
        https://example.com/?tag=#meeting
        \\#escaped
        `#inline-code`

        ```text
        #fenced-code
        ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(
            source,
            referenceToken: referenceToken
        )
        let tagURLs = rendered
            .split(whereSeparator: { $0 == "(" || $0 == ")" })
            .filter { $0.hasPrefix("relaybar-tag://") }
            .compactMap { URL(string: String($0)) }
        let tagValues = tagURLs.compactMap {
            ObsidianMarkdownCompatibility.internalValue(
                from: $0,
                expectedScheme: "relaybar-tag",
                referenceToken: referenceToken
            )?.value
        }

        XCTAssertEqual(
            tagValues,
            [
                "meeting",
                "inbox/to-read",
                "status/✅",
                "status/❤️",
                "MixedCase"
            ]
        )
        XCTAssertTrue(rendered.contains("#1984"))
        XCTAssertTrue(rendered.contains("C#"))
        XCTAssertTrue(rendered.contains("color:#fff"))
        XCTAssertTrue(rendered.contains("https://example.com/#meeting"))
        XCTAssertTrue(rendered.contains("https://example.com/?tag=#meeting"))
        XCTAssertTrue(rendered.contains("\\#escaped"))
        XCTAssertTrue(rendered.contains("`#inline-code`"))
        XCTAssertTrue(rendered.contains("#fenced-code"))
    }

    func testCompatibilitySyntaxDoesNotRewriteInlineOrFencedCode() {
        let source = """
        `==visible syntax== $x$ [[note]] %% comment marker %%`

            ==indented code== [[indented]]

        ~~~text
        ==fenced syntax== $y$ [[other]] %% literal %%
        ~~~
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains("`==visible syntax== $x$ [[note]] %% comment marker %%`"))
        XCTAssertTrue(rendered.contains("    ==indented code== [[indented]]"))
        XCTAssertTrue(rendered.contains("==fenced syntax== $y$ [[other]] %% literal %%"))
    }

    func testCompatibilitySyntaxDoesNotRewriteCodeInsideContainers() {
        let fencedCode = "> ==nested highlight== [[nested-wiki]] %% nested comment %%"
        let indentedCode =
            "> " + String(repeating: " ", count: 4)
            + "==indented highlight== [[indented-wiki]] %% indented comment %%"
        let listFencedCode = "  ==list highlight== [[list-wiki]] %% list comment %%"
        let listIndentedCode =
            "- " + String(repeating: " ", count: 4)
            + "==list indented== [[list-indented]] %% list indented comment %%"
        let source = [
            "> [!note] Code examples",
            ">",
            "> ```markdown",
            fencedCode,
            "> ```",
            ">",
            indentedCode,
            "",
            "- ```markdown",
            listFencedCode,
            "  ```",
            "",
            listIndentedCode
        ].joined(separator: "\n")

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertTrue(rendered.contains(fencedCode))
        XCTAssertTrue(rendered.contains(indentedCode))
        XCTAssertTrue(rendered.contains(listFencedCode))
        XCTAssertTrue(rendered.contains(listIndentedCode))
        XCTAssertFalse(rendered.contains("relaybar-wiki://"))
        XCTAssertFalse(rendered.contains("**nested highlight**"))
        XCTAssertFalse(rendered.contains("**indented highlight**"))
        XCTAssertFalse(rendered.contains("**list highlight**"))
        XCTAssertFalse(rendered.contains("**list indented**"))
    }

    func testCompatibilitySyntaxDoesNotRewriteMultilineCodeSpans() {
        let source = """
        `[[wiki]]
        ==highlight== %% visible comment markers %% $x^2$`
        """

        XCTAssertEqual(ObsidianMarkdownCompatibility.renderSource(source), source)

        let unmatched = """
        `not a closed span
        ==still highlighted==
        """
        XCTAssertEqual(
            ObsidianMarkdownCompatibility.renderSource(unmatched),
            """
            `not a closed span
            **still highlighted**
            """
        )
    }

    func testInternalMarkdownURLsRoundTripUnicodeAndRejectWrongSchemes() {
        let referenceToken = "test-preview"
        let rendered = ObsidianMarkdownCompatibility.renderSource(
            "See [[運用ガイド|guide]] and $\\sqrt{x}$.",
            referenceToken: referenceToken
        )
        let urls = rendered
            .split(whereSeparator: { $0 == "(" || $0 == ")" })
            .compactMap { URL(string: String($0)) }

        let wikiURL = try? XCTUnwrap(urls.first { $0.scheme == "relaybar-wiki" })
        let mathURL = try? XCTUnwrap(urls.first { $0.scheme == "relaybar-math" })

        XCTAssertEqual(
            wikiURL.flatMap {
                ObsidianMarkdownCompatibility.internalValue(
                    from: $0,
                    expectedScheme: "relaybar-wiki",
                    referenceToken: referenceToken
                )?.value
            },
            "運用ガイド"
        )
        XCTAssertEqual(
            mathURL.flatMap {
                ObsidianMarkdownCompatibility.internalValue(
                    from: $0,
                    expectedScheme: "relaybar-math",
                    referenceToken: referenceToken
                )?.value
            },
            "\\sqrt{x}"
        )
        if let wikiURL {
            XCTAssertNil(
                ObsidianMarkdownCompatibility.internalValue(
                    from: wikiURL,
                    expectedScheme: "relaybar-math",
                    referenceToken: referenceToken
                )
            )
            XCTAssertNil(
                ObsidianMarkdownCompatibility.internalValue(
                    from: wikiURL,
                    expectedScheme: "relaybar-wiki",
                    referenceToken: "another-preview"
                )
            )
        }
    }

    func testMalformedMathStaysSelectableAndForgedInternalReferencesAreRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("malformed-math.md")
        let malformedMath = #"Before $\frac{1}{$ after."#
        let forgedMath = "![forged](relaybar-math://inline/attacker/eA)"
        try Data("\(malformedMath)\n\n\(forgedMath)".utf8).write(to: url)

        let document = try await RemoteMarkdownDecoder.load(contentsOf: url)
        let secondDocument = try await RemoteMarkdownDecoder.load(contentsOf: url)
        let rendered = ObsidianMarkdownCompatibility.renderSource(
            "\(malformedMath)\n\n\(forgedMath)",
            referenceToken: document.referenceToken,
            mathValidator: { RemoteMathRenderer.canParse($0) }
        )

        XCTAssertTrue(rendered.contains(malformedMath))
        XCTAssertTrue(document.plainText.contains(#"$\frac{1}{$"#))
        XCTAssertNotEqual(document.referenceToken, secondDocument.referenceToken)
        XCTAssertFalse(
            rendered
                .components(separatedBy: "relaybar-math://inline/")
                .dropFirst()
                .contains { $0.hasPrefix(document.referenceToken) }
        )

        let forgedURL = try XCTUnwrap(
            URL(string: "relaybar-math://inline/attacker/eA")
        )
        XCTAssertNil(
            ObsidianMarkdownCompatibility.internalValue(
                from: forgedURL,
                expectedScheme: "relaybar-math",
                referenceToken: document.referenceToken
            )
        )
    }

    func testLeavesCurrencyAndURLComparisonsUnchanged() {
        let source = "The fee is $5 and https://example.com/check?a==b."
        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertEqual(rendered, source)
    }

    func testLeavesPathologicalLongCompatibilityLineLiteral() {
        let source = String(
            repeating: "[[",
            count: ObsidianMarkdownCompatibility.maximumCompatibilityLineCharacterCount
        )

        XCTAssertEqual(ObsidianMarkdownCompatibility.renderSource(source), source)
    }

    func testBoundsLookaheadForUnmatchedWikiLinksWithinTheLineLimit() {
        let source = String(
            repeating: "[[",
            count: ObsidianMarkdownCompatibility.maximumCompatibilityLineCharacterCount / 2
        )

        XCTAssertEqual(ObsidianMarkdownCompatibility.renderSource(source), source)
    }

    func testBoundsTagURLLookbehindWithinTheLineLimit() {
        let source = String(
            repeating: ",#tag",
            count: ObsidianMarkdownCompatibility.maximumCompatibilityLineCharacterCount / 5
        )

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)
        let renderedTagCount =
            rendered.components(separatedBy: "relaybar-tag://open/").count - 1

        XCTAssertLessThan(
            renderedTagCount,
            ObsidianMarkdownCompatibility.maximumInternalLinkCount
        )
        XCTAssertTrue(rendered.hasSuffix(",#tag"))
    }

    func testNativeMathRendererIsBoundedAndFailsClosed() async {
        let image = await RemoteMathRenderer.shared.image(
            for: "\\frac{1}{2} + \\sqrt{2}",
            display: true
        )
        XCTAssertNotNil(image)
        XCTAssertFalse(image?.data.isEmpty ?? true)
        XCTAssertLessThanOrEqual(image?.width ?? .infinity, 1_600)
        XCTAssertLessThanOrEqual(image?.height ?? .infinity, 500)

        let oversized = String(
            repeating: "x",
            count: ObsidianMarkdownCompatibility.maximumFormulaCharacterCount + 1
        )
        let rejected = await RemoteMathRenderer.shared.image(for: oversized, display: true)
        XCTAssertNil(rejected)
    }

    func testCapsAggregateMathWorkAndPreservesRejectedFormulaSource() {
        let source = Array(
            repeating: "$x$",
            count: ObsidianMarkdownCompatibility.maximumRenderedMathCount + 4
        ).joined(separator: " ")

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertEqual(
            rendered.components(separatedBy: "relaybar-math://inline/").count - 1,
            ObsidianMarkdownCompatibility.maximumRenderedMathCount
        )
        XCTAssertTrue(rendered.hasSuffix("$x$ $x$ $x$ $x$"))

        let oversizedFormula = String(
            repeating: "x^2 + ",
            count: ObsidianMarkdownCompatibility.maximumFormulaCharacterCount / 3
        )
        let oversizedBlock = """
        $$
        \(oversizedFormula)
        $$
        """
        XCTAssertEqual(
            ObsidianMarkdownCompatibility.renderSource(oversizedBlock),
            oversizedBlock
        )
    }

    func testCapsExtractedFootnotesAndLeavesOverflowDefinitionsReadable() async throws {
        let definitions = (0...ObsidianMarkdownCompatibility.maximumFootnoteCount)
            .map { "[^note-\($0)]: body \($0)" }
            .joined(separator: "\n")
        let source = definitions + "\nInline ^[overflow inline note]."

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("footnote-overflow.md")
        try Data(source.utf8).write(to: url)
        let document = try await RemoteMarkdownDecoder.load(contentsOf: url)

        XCTAssertTrue(rendered.contains("#### Footnotes"))
        XCTAssertTrue(
            rendered.contains(
                "\\[^note-\(ObsidianMarkdownCompatibility.maximumFootnoteCount)]: "
                    + "body \(ObsidianMarkdownCompatibility.maximumFootnoteCount)"
            )
        )
        XCTAssertTrue(
            document.plainText.contains(
                "[^note-\(ObsidianMarkdownCompatibility.maximumFootnoteCount)]: "
                    + "body \(ObsidianMarkdownCompatibility.maximumFootnoteCount)"
            )
        )
        XCTAssertTrue(rendered.contains("Inline ^[overflow inline note]."))
    }

    func testCapsAggregateInternalLinksAndEmbeds() {
        let wikiSource = (0...ObsidianMarkdownCompatibility.maximumInternalLinkCount)
            .map { "[[note-\($0)]]" }
            .joined(separator: " ")
        let renderedWiki = ObsidianMarkdownCompatibility.renderSource(wikiSource)
        XCTAssertEqual(
            renderedWiki.components(separatedBy: "relaybar-wiki://open/").count - 1,
            ObsidianMarkdownCompatibility.maximumInternalLinkCount
        )
        XCTAssertTrue(
            renderedWiki.hasSuffix(
                "[[note-\(ObsidianMarkdownCompatibility.maximumInternalLinkCount)]]"
            )
        )

        let tagSource = (0...ObsidianMarkdownCompatibility.maximumInternalLinkCount)
            .map { "#tag-\($0)" }
            .joined(separator: " ")
        let renderedTags = ObsidianMarkdownCompatibility.renderSource(tagSource)
        XCTAssertEqual(
            renderedTags.components(separatedBy: "relaybar-tag://open/").count - 1,
            ObsidianMarkdownCompatibility.maximumInternalLinkCount
        )
        XCTAssertTrue(
            renderedTags.hasSuffix(
                "#tag-\(ObsidianMarkdownCompatibility.maximumInternalLinkCount)"
            )
        )

        let embedSource = (0...ObsidianMarkdownCompatibility.maximumEmbedCount)
            .map { "![[asset-\($0).png]]" }
            .joined(separator: "\n")
        let renderedEmbeds = ObsidianMarkdownCompatibility.renderSource(embedSource)
        XCTAssertEqual(
            renderedEmbeds.components(separatedBy: "**Embedded file not loaded:**").count - 1,
            ObsidianMarkdownCompatibility.maximumEmbedCount
        )
        XCTAssertTrue(
            renderedEmbeds.hasSuffix(
                "![[asset-\(ObsidianMarkdownCompatibility.maximumEmbedCount).png]]"
            )
        )

        let imageSource = (0...ObsidianMarkdownCompatibility.maximumEmbedCount)
            .map {
                "![asset \($0)](https://example.com/asset-\($0).png)"
            }
            .joined(separator: "\n")
        let renderedImages = ObsidianMarkdownCompatibility.renderSource(imageSource)
        XCTAssertEqual(
            renderedImages.components(separatedBy: "**Image not loaded:**").count - 1,
            ObsidianMarkdownCompatibility.maximumEmbedCount
        )
        XCTAssertTrue(
            renderedImages.hasSuffix(
                "`![asset \(ObsidianMarkdownCompatibility.maximumEmbedCount)]"
                    + "(https://example.com/asset-"
                    + "\(ObsidianMarkdownCompatibility.maximumEmbedCount).png)`"
            )
        )

        let oversizedTarget = String(
            repeating: "a",
            count: ObsidianMarkdownCompatibility.maximumFormulaCharacterCount + 1
        )
        let oversizedWiki = "[[\(oversizedTarget)|label]]"
        XCTAssertEqual(
            ObsidianMarkdownCompatibility.renderSource(oversizedWiki),
            oversizedWiki
        )
    }

    func testCapsAggregateSyntaxHighlightingWithoutHidingCodeOrMermaidSafety() {
        let swiftBlocks = (0...ObsidianMarkdownCompatibility.maximumHighlightedCodeBlockCount)
            .map { index in
                """
                ```swift
                let value\(index) = \(index)
                ```
                """
            }
            .joined(separator: "\n\n")
        let source = swiftBlocks + """


        ```mermaid
        graph TD
          A --> B
        ```
        """

        let rendered = ObsidianMarkdownCompatibility.renderSource(source)

        XCTAssertEqual(
            rendered.components(separatedBy: "```swift").count - 1,
            ObsidianMarkdownCompatibility.maximumHighlightedCodeBlockCount
        )
        XCTAssertTrue(
            rendered.contains(
                "let value\(ObsidianMarkdownCompatibility.maximumHighlightedCodeBlockCount) "
                    + "= \(ObsidianMarkdownCompatibility.maximumHighlightedCodeBlockCount)"
            )
        )
        XCTAssertTrue(rendered.contains("```mermaid"))
        XCTAssertTrue(rendered.contains("A --> B"))
    }

    func testDisplayMathLayoutNeverUpscalesAndBoundsLongFormulae() {
        XCTAssertEqual(
            RemoteMathImageLayout.fittedSize(
                for: CGSize(width: 180, height: 70),
                maximumSize: CGSize(width: 780, height: 180)
            ),
            CGSize(width: 180, height: 70)
        )

        let bounded = RemoteMathImageLayout.fittedSize(
            for: CGSize(width: 1_600, height: 500),
            maximumSize: CGSize(width: 780, height: 180)
        )
        XCTAssertEqual(bounded.width, 576, accuracy: 0.001)
        XCTAssertEqual(bounded.height, 180, accuracy: 0.001)
    }

    func testRejectsInvalidUTF8NullsAndOversizedInput() {
        XCTAssertThrowsError(try RemoteMarkdownDecoder.decode(Data([0xC3, 0x28]))) { error in
            XCTAssertEqual(error as? RemoteFileError, .invalidMarkdownEncoding)
        }
        XCTAssertThrowsError(try RemoteMarkdownDecoder.decode(Data([0x41, 0x00, 0x42]))) { error in
            XCTAssertEqual(error as? RemoteFileError, .invalidMarkdownEncoding)
        }
        XCTAssertThrowsError(
            try RemoteMarkdownDecoder.decode(
                Data(repeating: 0x41, count: RemoteMarkdownDecoder.maximumByteCount + 1)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .markdownTooLarge)
        }
    }

    func testAllowsOnlyAbsoluteUserInitiatedWebAndMailLinks() {
        XCTAssertTrue(SafeMarkdownLinkPolicy.allows(URL(string: "https://example.com/docs")!))
        XCTAssertTrue(
            SafeMarkdownLinkPolicy.allows(
                URL(string: "https://example.com/%E2%9C%85")!
            )
        )
        XCTAssertTrue(SafeMarkdownLinkPolicy.allows(URL(string: "http://example.com")!))
        XCTAssertTrue(SafeMarkdownLinkPolicy.allows(URL(string: "mailto:hello@example.com")!))

        XCTAssertFalse(SafeMarkdownLinkPolicy.allows(URL(string: "relative/path")!))
        XCTAssertFalse(SafeMarkdownLinkPolicy.allows(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(SafeMarkdownLinkPolicy.allows(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(SafeMarkdownLinkPolicy.allows(URL(string: "data:text/plain,hello")!))
        XCTAssertFalse(
            SafeMarkdownLinkPolicy.allows(URL(string: "mailto:?subject=Missing%20recipient")!)
        )
        XCTAssertFalse(
            SafeMarkdownLinkPolicy.allows(
                URL(
                    string:
                        "mailto:hello@example.com?subject=Hi%0ABcc:other@example.com"
                )!
            )
        )
        XCTAssertFalse(
            SafeMarkdownLinkPolicy.allows(
                URL(string: "https://example.com/%00hidden")!
            )
        )
        XCTAssertFalse(
            SafeMarkdownLinkPolicy.allows(URL(string: "https://user:secret@example.com")!)
        )

        let referenceToken = "link-policy"
        XCTAssertEqual(
            SafeMarkdownLinkPolicy.decision(
                for: URL(string: "Guides/Setup.md#Install")!,
                referenceToken: referenceToken
            ),
            .internalMarkdown("Guides/Setup.md#Install")
        )
        XCTAssertEqual(
            SafeMarkdownLinkPolicy.decision(
                for: URL(string: "#Local-heading")!,
                referenceToken: referenceToken
            ),
            .internalMarkdown("#Local-heading")
        )
        XCTAssertEqual(
            SafeMarkdownLinkPolicy.decision(
                for: URL(string: "Guides/My%20Setup.md")!,
                referenceToken: referenceToken
            ),
            .internalMarkdown("Guides/My Setup.md")
        )
        XCTAssertEqual(
            SafeMarkdownLinkPolicy.decision(
                for: URL(string: "Guides/Setup.md%0AInjected")!,
                referenceToken: referenceToken
            ),
            .blocked
        )
        XCTAssertEqual(
            SafeMarkdownLinkPolicy.decision(
                for: URL(fileURLWithPath: "/etc/passwd"),
                referenceToken: referenceToken
            ),
            .blocked
        )

        let wikiSource = ObsidianMarkdownCompatibility.renderSource(
            "[[Runbook]]",
            referenceToken: referenceToken
        )
        let wikiURLString = wikiSource
            .split(whereSeparator: { $0 == "(" || $0 == ")" })
            .first { $0.hasPrefix("relaybar-wiki://") }
        let wikiURL = wikiURLString.flatMap { URL(string: String($0)) }
        XCTAssertEqual(
            wikiURL.map {
                SafeMarkdownLinkPolicy.decision(
                    for: $0,
                    referenceToken: referenceToken
                )
            },
            .wiki("Runbook")
        )
        XCTAssertEqual(
            wikiURL.map {
                SafeMarkdownLinkPolicy.decision(
                    for: $0,
                    referenceToken: "different-preview"
                )
            },
            .blocked
        )

        let tagSource = ObsidianMarkdownCompatibility.renderSource(
            "#inbox/to-read",
            referenceToken: referenceToken
        )
        let tagURLString = tagSource
            .split(whereSeparator: { $0 == "(" || $0 == ")" })
            .first { $0.hasPrefix("relaybar-tag://") }
        let tagURL = tagURLString.flatMap { URL(string: String($0)) }
        XCTAssertEqual(
            tagURL.map {
                SafeMarkdownLinkPolicy.decision(
                    for: $0,
                    referenceToken: referenceToken
                )
            },
            .tag("inbox/to-read")
        )
        XCTAssertEqual(
            tagURL.map {
                SafeMarkdownLinkPolicy.decision(
                    for: $0,
                    referenceToken: "different-preview"
                )
            },
            .blocked
        )
    }
}

final class RemoteFilesKeyboardShortcutTests: XCTestCase {
    func testAcceptsArrowKeySystemFlagsWithCommand() {
        XCTAssertTrue(
            RemoteFilesKeyboardShortcut.isCommandDown([.command, .function, .numericPad])
        )
    }

    func testRejectsAdditionalCommandDownModifiers() {
        XCTAssertFalse(
            RemoteFilesKeyboardShortcut.isCommandDown([.command, .shift, .function])
        )
        XCTAssertFalse(RemoteFilesKeyboardShortcut.isCommandDown([.function]))
    }

    func testTreatsSystemNavigationFlagsAsUnmodified() {
        XCTAssertTrue(RemoteFilesKeyboardShortcut.isUnmodified([.numericPad]))
        XCTAssertTrue(RemoteFilesKeyboardShortcut.isUnmodified([.function]))
        XCTAssertTrue(
            RemoteFilesKeyboardShortcut.isUnmodified([.numericPad, .function])
        )
        XCTAssertFalse(RemoteFilesKeyboardShortcut.isUnmodified([.shift]))
    }
}

final class SFTPCommandBuilderTests: XCTestCase {
    // Metacharacters reach sftp quoted, not escaped and not rejected; its own
    // quoting matches them literally.
    func testQuotesGlobMetacharactersInBothArguments() throws {
        XCTAssertEqual(
            try SFTPCommandBuilder.listCommand(path: "/srv/report[2026]"),
            "ls -la \"/srv/report[2026]\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.downloadCommand(
                remotePath: "/srv/report[2026]/data.csv",
                localPath: "/Users/me/Downloads/set[1]/payload",
                recursively: false
            ),
            "get \"/srv/report[2026]/data.csv\" \"/Users/me/Downloads/set[1]/payload\"\n"
        )
    }

    func testTranslatesSSHPortAndLoginOptionsForSFTP() throws {
        let server = RemoteServer(
            id: UUID(),
            name: "Production",
            sshHost: "host.example.com",
            additionalArguments: [
                "-p", "2222",
                "-l", "alice",
                "-J", "jump.example.com",
                "-i", "~/.ssh/work",
                "-o", "IdentitiesOnly=yes",
                "-k"
            ]
        )

        let arguments = try SFTPCommandBuilder.processArguments(for: server)

        XCTAssertTrue(arguments.containsSubsequence(["-P", "2222"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "User=alice"]))
        XCTAssertTrue(arguments.containsSubsequence(["-J", "jump.example.com"]))
        XCTAssertTrue(arguments.containsSubsequence(["-i", "~/.ssh/work"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "IdentitiesOnly=yes"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "GSSAPIDelegateCredentials=no"]))
        XCTAssertFalse(arguments.contains("-q"))
        XCTAssertEqual(arguments.last, "host.example.com")
    }

    func testTranslatesAttachedPortAndLoginOptions() throws {
        let server = RemoteServer(
            id: UUID(),
            name: "Attached",
            sshHost: "host",
            additionalArguments: ["-p2222", "-lalice"]
        )

        let arguments = try SFTPCommandBuilder.processArguments(for: server)

        XCTAssertTrue(arguments.containsSubsequence(["-P", "2222"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "User=alice"]))
    }

    func testRoutesSFTPChildrenThroughTheExactOwnedControlSocket() throws {
        let server = RemoteServer(
            id: UUID(),
            name: "Production",
            sshHost: "host.example.com",
            additionalArguments: ["-p", "2222", "-l", "alice"]
        )
        let socket = URL(fileURLWithPath: "/tmp/relaybar-private/control")

        let arguments = try SFTPCommandBuilder.processArguments(
            for: server,
            controlSocket: socket
        )

        XCTAssertTrue(
            arguments.containsSubsequence([
                "-o", "ControlPath=/tmp/relaybar-private/control"
            ])
        )
        XCTAssertTrue(arguments.containsSubsequence(["-o", "ControlMaster=no"]))
        XCTAssertTrue(arguments.containsSubsequence(["-P", "2222"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "User=alice"]))
        XCTAssertEqual(arguments.last, "host.example.com")
    }

    func testRejectsTamperedServerArguments() {
        let commandServer = RemoteServer(
            id: UUID(),
            name: "Unsafe",
            sshHost: "host",
            additionalArguments: ["-o", "LocalCommand=whoami"]
        )
        let controlServer = RemoteServer(
            id: UUID(),
            name: "Control character",
            sshHost: "host",
            additionalArguments: ["-o", "User=alice\nProxyCommand=whoami"]
        )

        XCTAssertThrowsError(try SFTPCommandBuilder.processArguments(for: commandServer)) { error in
            XCTAssertEqual(error as? RemoteFileError, .invalidConnection)
        }
        XCTAssertThrowsError(try SFTPCommandBuilder.processArguments(for: controlServer)) { error in
            XCTAssertEqual(error as? RemoteFileError, .invalidConnection)
        }
    }

    func testBuildsShellFreeBatchCommands() throws {
        XCTAssertEqual(
            try SFTPCommandBuilder.listCommand(path: "/srv/my output"),
            "ls -la \"/srv/my output\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.downloadCommand(
                remotePath: "/srv/my output/image.png",
                localPath: "/tmp/image.png",
                recursively: false
            ),
            "get \"/srv/my output/image.png\" \"/tmp/image.png\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.downloadCommand(
                remotePath: "/srv/folder",
                localPath: "/tmp/folder",
                recursively: true
            ),
            "get -R \"/srv/folder\" \"/tmp/folder\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.uploadCommand(
                localPath: "/tmp/release 1.zip",
                remotePath: "/srv/releases/.relaybar-upload.partial"
            ),
            "put \"/tmp/release 1.zip\" \"/srv/releases/.relaybar-upload.partial\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.hardLinkCommand(
                existingPath: "/srv/releases/.relaybar-upload.partial",
                newPath: "/srv/releases/release 1.zip"
            ),
            "ln \"/srv/releases/.relaybar-upload.partial\" \"/srv/releases/release 1.zip\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.renameCommand(
                existingPath: "/srv/releases/.relaybar-upload.partial",
                newPath: "/srv/releases/release 1.zip"
            ),
            "rename \"/srv/releases/.relaybar-upload.partial\" \"/srv/releases/release 1.zip\"\n"
        )
        XCTAssertEqual(
            try SFTPCommandBuilder.removeCommand(
                path: "/srv/releases/.relaybar-upload.partial"
            ),
            "rm \"/srv/releases/.relaybar-upload.partial\"\n"
        )
    }

    func testAddsAppOwnedDebugLevelAfterUserArguments() throws {
        let server = RemoteServer(
            id: UUID(),
            name: "Quiet",
            sshHost: "host",
            additionalArguments: ["-q"]
        )

        let arguments = try SFTPCommandBuilder.processArguments(
            for: server,
            diagnosticLevel: 2
        )

        XCTAssertEqual(arguments.suffix(3), ["-q", "-vv", "host"])
    }

    func testParsesOnlyExactAdvertisedUploadExtensions() {
        let capabilities = RemoteUploadCapabilities.parse(
            """
            debug2: Server supports extension "posix-rename@openssh.com" revision 1
            debug2: Server supports extension "hardlink@openssh.com" revision 1
            """
        )
        let unrelated = RemoteUploadCapabilities.parse(
            "server text mentions hardlink@openssh.com without an advertisement"
        )

        XCTAssertEqual(
            capabilities,
            RemoteUploadCapabilities(supportsHardLink: true, supportsPOSIXRename: true)
        )
        XCTAssertEqual(
            unrelated,
            RemoteUploadCapabilities(supportsHardLink: false, supportsPOSIXRename: false)
        )
    }
}

final class RemoteFileSSHSessionTests: XCTestCase {
    func testBuildsForegroundMasterArgumentsWithoutSFTPTranslation() throws {
        let server = RemoteServer(
            id: UUID(),
            name: "Production",
            sshHost: "host.example.com",
            additionalArguments: [
                "-p", "2222",
                "-l", "alice",
                "-J", "jump.example.com",
                "-i", "~/.ssh/work"
            ]
        )
        let socket = URL(fileURLWithPath: "/tmp/relaybar-private/control")

        let arguments = try RemoteFileSSHSession.masterArguments(
            for: server,
            controlSocket: socket
        )

        XCTAssertTrue(arguments.containsSubsequence(["-N", "-T", "-M", "-S", socket.path]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "ControlPersist=no"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "ClearAllForwardings=yes"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "BatchMode=yes"]))
        XCTAssertTrue(arguments.containsSubsequence(["-o", "ExitOnForwardFailure=yes"]))
        XCTAssertTrue(arguments.containsSubsequence(["-p", "2222"]))
        XCTAssertTrue(arguments.containsSubsequence(["-l", "alice"]))
        XCTAssertFalse(arguments.contains("-P"))
        XCTAssertFalse(arguments.contains("User=alice"))
        XCTAssertEqual(arguments.last, "host.example.com")
    }

    func testRejectsUnsafeMasterArgumentsBeforeLaunching() {
        let server = RemoteServer(
            id: UUID(),
            name: "Unsafe",
            sshHost: "host.example.com",
            additionalArguments: ["-o", "ControlMaster=yes"]
        )

        XCTAssertThrowsError(
            try RemoteFileSSHSession.masterArguments(
                for: server,
                controlSocket: URL(fileURLWithPath: "/tmp/control")
            )
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .invalidConnection)
        }
    }

    func testEarlyMasterExitFailsWaitersAndCleansItsDirectory() async throws {
        let root = try shortTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RemoteFileSSHSession(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            temporaryDirectory: root,
            startupPollCount: 20,
            startupPollInterval: 0.01,
            forceStopDelay: 0.05
        )
        defer { session.shutdown() }

        do {
            _ = try await session.controlSocket(for: server())
            XCTFail("Expected the master to exit before readiness.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .commandFailed("The remote operation failed."))
        }
        try await waitUntil {
            (try? self.privateSessionDirectories(in: root).isEmpty) == true
        }
    }

    func testAcceptsTheExactOpenSSHBindPathBudget() async throws {
        let root = try boundaryTemporaryDirectory(
            finalSocketPathByteCount:
                RemoteFileSSHSession.maximumControlSocketPathByteCount
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RemoteFileSSHSession(
            executableURL: fakeSSHExecutableURL,
            temporaryDirectory: root,
            startupPollCount: 100,
            startupPollInterval: 0.01,
            forceStopDelay: 0.05
        )
        defer { session.shutdown() }

        let socket = try await session.controlSocket(for: server())
        XCTAssertEqual(
            socket.path.utf8.count,
            RemoteFileSSHSession.maximumControlSocketPathByteCount
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: socket.deletingLastPathComponent().path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            getuid()
        )
    }

    func testRejectsTheFirstPathThatCannotFitOpenSSHBindSuffix() async throws {
        let root = try boundaryTemporaryDirectory(
            finalSocketPathByteCount:
                RemoteFileSSHSession.maximumControlSocketPathByteCount + 1
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RemoteFileSSHSession(
            executableURL: fakeSSHExecutableURL,
            temporaryDirectory: root
        )
        defer { session.shutdown() }

        do {
            _ = try await session.controlSocket(for: server())
            XCTFail("Expected OpenSSH bind-suffix headroom to be enforced.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .connectionSessionUnavailable)
        }
        XCTAssertTrue(try privateSessionDirectories(in: root).isEmpty)
    }

    func testDefaultLocationFitsTheRealMacOSTemporaryDirectory() async throws {
        let session = RemoteFileSSHSession(
            executableURL: fakeSSHExecutableURL,
            startupPollCount: 100,
            startupPollInterval: 0.01,
            forceStopDelay: 0.05
        )
        defer { session.shutdown() }

        let socket = try await session.controlSocket(for: server())

        XCTAssertTrue(
            socket.path.hasPrefix(
                FileManager.default.temporaryDirectory.path
                    + "/"
                    + RemoteFileSSHSession.privateDirectoryPrefix
            )
        )
        XCTAssertLessThan(
            socket.path.utf8.count
                + RemoteFileSSHSession.openSSHBindTemporarySuffixByteCount,
            RemoteFileSSHSession.unixSocketPathByteCapacity
        )
    }

    func testRejectsAnOverlongControlSocketPathAndRemovesTheDirectory() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/\(String(repeating: "x", count: 80))",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RemoteFileSSHSession(temporaryDirectory: root)
        defer { session.shutdown() }

        do {
            _ = try await session.controlSocket(for: server())
            XCTFail("Expected the control socket path limit to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .connectionSessionUnavailable)
        }
        XCTAssertTrue(try privateSessionDirectories(in: root).isEmpty)
    }

    func testReadinessTimeoutStopsTheHungMasterAndCleansItsDirectory() async throws {
        let root = try shortTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let readyURL = root.appendingPathComponent("never-ready")
        let session = RemoteFileSSHSession(
            executableURL: fakeSSHExecutableURL,
            temporaryDirectory: root,
            processEnvironment: [
                "RELAYBAR_FAKE_SSH_READY_FILE": readyURL.path
            ],
            startupPollCount: 2,
            startupPollInterval: 0.01,
            forceStopDelay: 0.05
        )
        defer { session.shutdown() }

        do {
            _ = try await session.controlSocket(for: server())
            XCTFail("Expected the readiness deadline to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .connectionSessionUnavailable)
        }
        try await waitUntil {
            (try? self.privateSessionDirectories(in: root).isEmpty) == true
        }
    }

    private func server() -> RemoteServer {
        RemoteServer(
            id: UUID(),
            name: "Test",
            sshHost: "example.com",
            additionalArguments: []
        )
    }

    private func shortTemporaryDirectory() throws -> URL {
        let root = URL(
            fileURLWithPath: "/tmp/RelayBarSession-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }

    private func boundaryTemporaryDirectory(
        finalSocketPathByteCount: Int
    ) throws -> URL {
        let fixedByteCount =
            "/tmp/".utf8.count
            + 1 // slash between the injected root and private directory
            + RemoteFileSSHSession.privateDirectoryPrefix.utf8.count
            + 8 // mkdtemp template characters
            + "/s".utf8.count
        let repeatedByteCount = finalSocketPathByteCount - fixedByteCount
        XCTAssertGreaterThan(repeatedByteCount, 0)
        let root = URL(
            fileURLWithPath:
                "/tmp/" + String(repeating: "x", count: repeatedByteCount),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }

    private func privateSessionDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                RemoteFileSSHSession.privateDirectoryPrefix
            )
        }
    }

    private var fakeSSHExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh.sh")
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class RemoteByteCountTests: XCTestCase {
    // Task 014 reuses one formatter instead of building one per row. The output
    // must stay identical to the per-call convenience it replaced; the
    // `.formatted(.byteCount(style:))` alternative is not equivalent, because it
    // renders SI `kB` and rounds 999 bytes up to `1 kB`.
    func testMatchesByteCountFormatterExactly() {
        for size in [
            Int64(0), 1, 2, 999, 1_000, 1_024, 4_096, 842_700,
            1_258_291, 3_565_158, 50_000_000, 5_000_000_000
        ] {
            XCTAssertEqual(
                RemoteByteCount.string(size),
                ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                "size \(size) formatted differently"
            )
        }
    }

    func testUsesBinaryPrefixedFileStyleWording() {
        XCTAssertEqual(RemoteByteCount.string(999), "999 bytes")
        XCTAssertEqual(RemoteByteCount.string(1_024), "1 KB")
        XCTAssertEqual(RemoteByteCount.string(842_700), "843 KB")
    }
}

final class ProgressPollingIntervalTests: XCTestCase {
    // Task 011. Each directory poll re-walks the tree, so the gap widens with it.
    func testDirectoryPollingWidensWithTreeSize() {
        XCTAssertEqual(
            SFTPRemoteFileService.progressPollingInterval(
                forEntryCount: 12_000,
                isDirectory: false
            ),
            .milliseconds(250)
        )
        XCTAssertEqual(
            SFTPRemoteFileService.progressPollingInterval(
                forEntryCount: 0,
                isDirectory: true
            ),
            .seconds(1)
        )
        XCTAssertEqual(
            SFTPRemoteFileService.progressPollingInterval(
                forEntryCount: 3_500,
                isDirectory: true
            ),
            .seconds(3)
        )
        XCTAssertEqual(
            SFTPRemoteFileService.progressPollingInterval(
                forEntryCount: 500_000,
                isDirectory: true
            ),
            .seconds(8),
            "the interval must stay bounded"
        )
    }
}

final class SFTPListingParserTests: XCTestCase {
    func testResolvesAnExactAbsoluteFilePath() throws {
        let path = "/home/linxy97/workspace/2026/youtube-video-transcript/TRANSCRIPTION_LEARNINGS.md"
        let output = "-rw-r--r-- 1 linxy97 staff 4096 Aug 3 20:30 \(path)"

        XCTAssertEqual(
            try SFTPListingParser.parsePath(output, path: path),
            .file(RemoteFileEntry(
                name: "TRANSCRIPTION_LEARNINGS.md",
                path: path,
                kind: .file,
                size: 4_096,
                modificationText: "Aug 3 20:30"
            ))
        )
    }

    func testDoesNotMistakeDirectoryContentsForTheRequestedPath() throws {
        let directoryOutput = """
        drwxr-xr-x 2 alice staff 64 Aug 3 20:30 .
        drwxr-xr-x 3 alice staff 96 Aug 3 20:30 ..
        -rw-r--r-- 1 alice staff 128 Aug 3 20:30 app
        """
        XCTAssertEqual(
            try SFTPListingParser.parsePath(directoryOutput, path: "/srv/app"),
            .directory([RemoteFileEntry(
                name: "app",
                path: "/srv/app/app",
                kind: .file,
                size: 128,
                modificationText: "Aug 3 20:30"
            )])
        )
    }

    // Entries whose names hold glob metacharacters parse, render, and remain
    // openable; sftp resolves their quoted paths literally.
    func testKeepsEntriesWhoseNamesCarryGlobMetacharacters() throws {
        let output = """
        drwxr-xr-x    3 alice staff        96 Jul 23 21:04 report[2026]
        -rw-r--r--    1 alice staff      4096 Jul 23 20:55 draft?.md
        -rw-r--r--    1 alice staff      2048 Jul 23 20:56 notes*.md
        """

        let entries = try SFTPListingParser.parse(output, parentPath: "/srv/app")

        XCTAssertEqual(
            entries.map(\.name),
            ["report[2026]", "draft?.md", "notes*.md"]
        )
        XCTAssertEqual(entries[0].path, "/srv/app/report[2026]")
    }

    func testParsesSortsAndPreservesNamesWithSpaces() throws {
        let output = """
        drwxr-xr-x    3 alice staff        96 Jul 23 21:04 reports
        -rw-r--r--    1 alice staff      4096 Jul 23 20:55 README.md
        -rw-r--r--    1 alice staff   1258291 Jul 23 20:56 dashboard final.png
        drwxr-xr-x    4 alice staff       128 Jul 23 21:03 screenshots
        lrwxr-xr-x    1 alice staff        12 Jul 23 21:06 latest -> reports
        """

        let entries = try SFTPListingParser.parse(output, parentPath: "/srv/app/output")

        XCTAssertEqual(
            entries.map(\.name),
            ["reports", "screenshots", "dashboard final.png", "latest", "README.md"]
        )
        XCTAssertEqual(entries[0].kind, .directory)
        XCTAssertEqual(entries[2].size, 1_258_291)
        XCTAssertTrue(entries[2].isPreviewableImage)
        XCTAssertEqual(entries[3].kind, .symbolicLink)
        XCTAssertEqual(entries[2].path, "/srv/app/output/dashboard final.png")
    }

    func testParsesAbsoluteDirectChildNamesProducedByOpenSSHServers() throws {
        let output = """
        drwxrwxr-x    ? alice staff      4096 Jul 22 21:02 /srv/app/output/2026
        drwxrwxr-x    ? alice staff      4096 Feb 26 21:08 /srv/app/output/openclaw
        -rw-r--r--    ? alice staff      4096 Jul 23 20:55 /srv/app/output/README.md
        lrwxr-xr-x    ? alice staff        12 Jul 23 21:06 /srv/app/output/latest -> 2026
        drwxr-xr-x    ? alice staff      4096 Jul 23 21:04 /srv/app/output/.
        drwxr-xr-x    ? alice staff      4096 Jul 23 21:04 /srv/app/output/..
        """

        let entries = try SFTPListingParser.parse(
            output,
            parentPath: "/srv/app/output"
        )

        XCTAssertEqual(
            entries.map(\.name),
            ["2026", "openclaw", "latest", "README.md"]
        )
        XCTAssertEqual(entries.map(\.path), [
            "/srv/app/output/2026",
            "/srv/app/output/openclaw",
            "/srv/app/output/latest",
            "/srv/app/output/README.md"
        ])
    }

    func testRejectsAbsoluteListingNamesOutsideRequestedFolder() {
        XCTAssertThrowsError(
            try SFTPListingParser.parse(
                "-rw-r--r-- 1 alice staff 1 Jul 24 00:20 /srv/other/secret.txt",
                parentPath: "/srv/app"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .malformedListing)
        }
    }

    func testIgnoresPromptsHeadersAndUnsafeNames() throws {
        let output = """
        Connected to host.
        sftp> ls -la "/srv/app"
        /srv/app:
        drwxr-xr-x    2 alice staff        64 Jul 23 21:04 .
        drwxr-xr-x    3 alice staff        96 Jul 23 21:04 ..
        prw-r--r--    1 alice staff         0 Jul 23 21:04 pipe
        """

        XCTAssertTrue(try SFTPListingParser.parse(output, parentPath: "/srv/app").isEmpty)
    }

    func testRejectsAnUnrecognizedListingInsteadOfShowingAFalseEmptyFolder() {
        XCTAssertThrowsError(
            try SFTPListingParser.parse(
                "unexpected server response",
                parentPath: "/srv/app"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .malformedListing)
        }
    }

    func testCapsTheNumberOfDirectoryEntries() {
        let line = "-rw-r--r-- 1 alice staff 1 Jul 24 00:20 file"
        let output = (0...SFTPListingParser.maximumEntryCount)
            .map { "\(line)-\($0)" }
            .joined(separator: "\n")

        XCTAssertThrowsError(
            try SFTPListingParser.parse(output, parentPath: "/srv/app")
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .tooManyEntries)
        }
    }

    func testRejectsOversizedOrNegativeStructuredListingFields() {
        let oversizedName = String(
            repeating: "a",
            count: SFTPListingParser.maximumEntryNameUTF8ByteCount + 1
        )
        XCTAssertThrowsError(
            try SFTPListingParser.parse(
                "-rw-r--r-- 1 alice staff 1 Jul 24 00:20 \(oversizedName)",
                parentPath: "/srv/app"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .malformedListing)
        }

        XCTAssertThrowsError(
            try SFTPListingParser.parse(
                "-rw-r--r-- 1 alice staff -1 Jul 24 00:20 impossible.txt",
                parentPath: "/srv/app"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteFileError, .malformedListing)
        }
    }
}

final class SFTPRemoteFileServiceTests: XCTestCase {
    func testLoadsAnExactRemoteFileWithoutTreatingItAsADirectory() async throws {
        let service = makeFixtureService()
        let path = "/home/linxy97/workspace/2026/youtube-video-transcript/TRANSCRIPTION_LEARNINGS.md"

        let result = try await service.loadPath(
            server: makeFixtureServer(host: "directfile"),
            path: path
        )

        XCTAssertEqual(
            result,
            .file(RemoteFileEntry(
                name: "TRANSCRIPTION_LEARNINGS.md",
                path: path,
                kind: .file,
                size: 4_096,
                modificationText: "Aug 3 20:30"
            ))
        )
    }

    func testDeleteRevalidatesFingerprintThenSubmitsOneExactQuotedRemove() async throws {
        let host = "RelayBarDeleteSuccess-\(UUID().uuidString)"
        let logURL = URL(fileURLWithPath: "/tmp/\(host).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let service = makeFixtureService()
        let entry = makeDeleteEntry()

        try await service.delete(server: makeFixtureServer(host: host), entry: entry)

        let commands = try String(contentsOf: logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(
            commands[0],
            try SFTPCommandBuilder.listCommand(path: entry.path)
                .trimmingCharacters(in: .newlines)
        )
        XCTAssertEqual(
            commands[1],
            try SFTPCommandBuilder.removeCommand(path: entry.path)
                .trimmingCharacters(in: .newlines)
        )
    }

    func testDeleteDoesNotSubmitRemoveWhenFingerprintChanged() async throws {
        let host = "RelayBarDeleteChanged-\(UUID().uuidString)"
        let logURL = URL(fileURLWithPath: "/tmp/\(host).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let service = makeFixtureService()

        do {
            try await service.delete(
                server: makeFixtureServer(host: host),
                entry: makeDeleteEntry()
            )
            XCTFail("Expected the changed fingerprint to fail closed")
        } catch {
            XCTAssertEqual(error as? RemoteFileError, .deleteTargetChanged)
        }

        let commands = try String(contentsOf: logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].hasPrefix("ls "))
    }

    func testDeleteDistinguishesServerRejectionFromUnknownOutcome() async throws {
        let rejectedHost = "RelayBarDeleteRejected-\(UUID().uuidString)"
        let rejectedLog = URL(fileURLWithPath: "/tmp/\(rejectedHost).log")
        defer { try? FileManager.default.removeItem(at: rejectedLog) }
        let service = makeFixtureService()
        do {
            try await service.delete(
                server: makeFixtureServer(host: rejectedHost),
                entry: makeDeleteEntry()
            )
            XCTFail("Expected server rejection")
        } catch let error as RemoteFileError {
            guard case .deleteRejected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let unknownHost = "RelayBarDeleteUnknown-\(UUID().uuidString)"
        let unknownLog = URL(fileURLWithPath: "/tmp/\(unknownHost).log")
        defer { try? FileManager.default.removeItem(at: unknownLog) }
        let unknownServer = makeFixtureServer(host: unknownHost)
        let unknownEntry = makeDeleteEntry()
        let task = Task {
            try await service.delete(
                server: unknownServer,
                entry: unknownEntry
            )
        }
        try await waitUntil(timeout: 1) {
            ((try? String(contentsOf: unknownLog, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).count == 2
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected unknown deletion outcome")
        } catch {
            XCTAssertEqual(error as? RemoteFileError, .deleteOutcomeUnknown)
        }
    }

    func testDeleteRejectsDirectoriesAndSymlinksBeforeLaunchingSFTP() async throws {
        let service = makeFixtureService()
        for kind in [RemoteFileEntry.Kind.directory, .symbolicLink] {
            var entry = makeDeleteEntry(kind: kind)
            if kind == .directory {
                entry = RemoteFileEntry(
                    name: entry.name,
                    path: entry.path,
                    kind: kind,
                    size: nil,
                    modificationText: entry.modificationText
                )
            }
            do {
                try await service.delete(
                    server: makeFixtureServer(host: "unused"),
                    entry: entry
                )
                XCTFail("Expected \(kind) to be rejected")
            } catch let error as RemoteFileError {
                guard case .deleteNotSubmitted = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testUploadPublishesANewNameWithHardLinkThenRemovesStaging() async throws {
        let fixture = makeUploadFixture(kind: "New")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()
        let phases = LockedUploadPhases()

        try await service.upload(
            server: fixture.server,
            localFile: localFile,
            remoteDirectory: "/srv/releases",
            replaceExisting: false,
            phase: { phases.record($0) }
        )

        let commands = try uploadCommands(for: fixture)
        XCTAssertEqual(commands.map(commandName), ["ls", "quit", "put", "ls", "ln", "rm"])
        XCTAssertTrue(commands[2].contains(".relaybar-upload-"))
        XCTAssertTrue(commands[4].hasSuffix(" \"/srv/releases/release.zip\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
        XCTAssertEqual(phases.values, [.staging, .publishing, .cleaningUp])
    }

    func testUploadMeasuresExactStagingPathAndCompletesAtOneHundredAfterPut()
        async throws
    {
        let fixture = makeUploadFixture(kind: "Progress")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()
        let updates = LockedUploadUpdates()

        try await service.uploadWithProgress(
            server: fixture.server,
            localFile: localFile,
            remoteDirectory: "/srv/releases",
            replaceExisting: false,
            update: { updates.record($0) }
        )

        let staging = updates.values.filter { $0.phase == .staging }
        XCTAssertEqual(staging.first?.completedBytes, 0)
        XCTAssertTrue(staging.contains { $0.completedBytes == 3 && !$0.isStagingComplete })
        XCTAssertEqual(staging.last?.completedBytes, 7)
        XCTAssertEqual(staging.last?.isStagingComplete, true)
        XCTAssertTrue(updates.values.contains { $0.phase == .publishing })

        let commands = try uploadCommands(for: fixture)
        let stagingMeasurements = commands.filter {
            $0.hasPrefix("ls ") && $0.contains(".relaybar-upload-")
        }
        XCTAssertFalse(stagingMeasurements.isEmpty)
        XCTAssertLessThanOrEqual(stagingMeasurements.count, 3)
    }

    func testUploadMeasurementFailureKeepsLastBytesAndDoesNotFailUpload() async throws {
        let fixture = makeUploadFixture(kind: "MeasureFail")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()
        let updates = LockedUploadUpdates()

        try await service.uploadWithProgress(
            server: fixture.server,
            localFile: localFile,
            remoteDirectory: "/srv/releases",
            replaceExisting: false,
            update: { updates.record($0) }
        )

        let staging = updates.values.filter { $0.phase == .staging }
        XCTAssertEqual(staging.map(\.completedBytes), [0, 7])
        XCTAssertEqual(staging.last?.isStagingComplete, true)
        XCTAssertTrue(
            try uploadCommands(for: fixture).contains {
                $0.hasPrefix("ls ") && $0.contains(".relaybar-upload-")
            }
        )
    }

    func testUploadCancellationCarriesOnlyLastMeasuredBytesIntoCleanup() async throws {
        let fixture = makeUploadFixture(kind: "Progress")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()
        let updates = LockedUploadUpdates()

        let task = Task {
            try await service.uploadWithProgress(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false,
                update: { updates.record($0) }
            )
        }
        try await waitUntil(timeout: 2) {
            updates.values.contains {
                $0.phase == .staging && $0.completedBytes == 3
            }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after exact staging cleanup finishes.
        }

        let cleanup = try XCTUnwrap(
            updates.values.last(where: { $0.phase == .cleaningUp })
        )
        XCTAssertEqual(cleanup.completedBytes, 3)
        XCTAssertEqual(cleanup.totalBytes, 7)
        XCTAssertFalse(cleanup.isStagingComplete)
    }

    func testUploadReplacesAnApprovedRegularFileWithPOSIXRename() async throws {
        let fixture = makeUploadFixture(kind: "Replace")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()

        try await service.upload(
            server: fixture.server,
            localFile: localFile,
            remoteDirectory: "/srv/releases",
            replaceExisting: true
        )

        let commands = try uploadCommands(for: fixture)
        XCTAssertEqual(commands.map(commandName), ["ls", "quit", "put", "ls", "rename"])
        XCTAssertTrue(commands[4].hasSuffix(" \"/srv/releases/release.zip\""))
    }

    func testUploadFailsClosedWhenRequiredPublicationExtensionIsMissing() async throws {
        let cases = [
            (kind: "NoHardLink", replaceExisting: false),
            (kind: "NoRename", replaceExisting: true)
        ]

        for testCase in cases {
            let fixture = makeUploadFixture(kind: testCase.kind)
            defer { removeUploadFixture(fixture) }
            let localFile = try makeUploadFile(named: "release.zip")
            defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
            let service = makeFixtureService()

            do {
                try await service.upload(
                    server: fixture.server,
                    localFile: localFile,
                    remoteDirectory: "/srv/releases",
                    replaceExisting: testCase.replaceExisting
                )
                XCTFail("Expected \(testCase.kind) to fail closed.")
            } catch let error as RemoteFileError {
                guard case .uploadCapabilityUnavailable = error else {
                    XCTFail("Unexpected error: \(error)")
                    continue
                }
            }

            XCTAssertEqual(
                try uploadCommands(for: fixture).map(commandName),
                ["ls", "quit"]
            )
        }
    }

    func testUploadNeverReplacesObservedDirectoryOrSymbolicLink() async throws {
        for kind in ["Directory", "Symlink"] {
            let fixture = makeUploadFixture(kind: kind)
            defer { removeUploadFixture(fixture) }
            let localFile = try makeUploadFile(named: "release.zip")
            defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
            let service = makeFixtureService()

            do {
                try await service.upload(
                    server: fixture.server,
                    localFile: localFile,
                    remoteDirectory: "/srv/releases",
                    replaceExisting: true
                )
                XCTFail("Expected \(kind) to be refused.")
            } catch let error as RemoteFileError {
                XCTAssertEqual(error, .unsupportedUploadTarget)
            }

            XCTAssertEqual(try uploadCommands(for: fixture).map(commandName), ["ls"])
        }
    }

    func testUploadRaceRemovesStagingWithoutPublishingOverNewTarget() async throws {
        let fixture = makeUploadFixture(kind: "Race")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()

        do {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
            XCTFail("Expected the raced-in target to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .uploadConflict)
        }

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "ls", "rm"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testHardLinkCollisionAfterFinalListingFailsClosedAndCleansStaging() async throws {
        let fixture = makeUploadFixture(kind: "LinkCollision")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()

        do {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
            XCTFail("Expected hard-link collision to fail closed.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .uploadConflict)
        }

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "ls", "ln", "ls", "rm"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testUploadCancellationRemovesItsExactRemoteStagingName() async throws {
        let fixture = makeUploadFixture(kind: "Cancel")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            connectionSharing: false
        )
        let task = Task {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
        }
        try await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: fixture.stateURL.path)
        }

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected after the detached cleanup has completed.
        }

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "rm"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testCancellationAfterPublicationStillReportsUploadSuccess() async throws {
        let fixture = makeUploadFixture(kind: "PublishCancel")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            connectionSharing: false
        )
        let task = Task {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
        }
        try await waitUntil(timeout: 2) {
            FileManager.default.fileExists(atPath: fixture.stateURL.path + ".cleanup")
        }

        task.cancel()
        try await task.value

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "ls", "ln", "rm", "rm"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testUploadReportsWhenStagingCleanupCannotBeConfirmed() async throws {
        let fixture = makeUploadFixture(kind: "CleanupFail")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()

        do {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
            XCTFail("Expected upload and cleanup to fail.")
        } catch let error as RemoteFileError {
            guard case .uploadCleanupUnconfirmed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "rm"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testPublishedUploadSucceedsWhenBoundedCleanupRetryIsConfirmed() async throws {
        let fixture = makeUploadFixture(kind: "CleanupRetry")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()

        try await service.upload(
            server: fixture.server,
            localFile: localFile,
            remoteDirectory: "/srv/releases",
            replaceExisting: false
        )

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "ls", "ln", "rm", "rm"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testPublishedUploadReportsOnlyUnconfirmedStagingCleanup() async throws {
        let fixture = makeUploadFixture(kind: "PublishCleanupFail")
        defer { removeUploadFixture(fixture) }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        let service = makeFixtureService()

        do {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
            XCTFail("Expected staging cleanup to remain unconfirmed.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(
                error,
                .uploadCleanupUnconfirmed("The upload was published.")
            )
        }

        XCTAssertEqual(
            try uploadCommands(for: fixture).map(commandName),
            ["ls", "quit", "put", "ls", "ln", "rm", "rm"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testUploadCapabilityProbeIsCachedForTheActiveServiceSession() async throws {
        let fixture = makeUploadFixture(kind: "Cache")
        defer { removeUploadFixture(fixture) }
        let first = try makeUploadFile(named: "first.zip")
        let directory = first.deletingLastPathComponent()
        let second = directory.appendingPathComponent("second.zip")
        try Data("second".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeFixtureService()

        for file in [first, second] {
            try await service.upload(
                server: fixture.server,
                localFile: file,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
        }

        let commandNames = try uploadCommands(for: fixture).map(commandName)
        XCTAssertEqual(commandNames.filter { $0 == "quit" }.count, 1)
        XCTAssertEqual(commandNames.filter { $0 == "put" }.count, 2)
        XCTAssertEqual(commandNames.filter { $0 == "ln" }.count, 2)
    }

    func testUploadCapabilitiesAreProbedAgainAfterSSHMasterReplacement() async throws {
        let fixture = makeUploadFixture(kind: "Cache")
        defer { removeUploadFixture(fixture) }
        let sessionRoot = URL(
            fileURLWithPath: "/tmp/RelayBarSSHTests-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let sshLogURL = sessionRoot.appendingPathComponent("ssh.log")
        let pidURL = sessionRoot.appendingPathComponent("ssh.pid")
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            sshExecutableURL: fakeSSHExecutableURL,
            sessionTemporaryDirectory: sessionRoot,
            processEnvironment: [
                "RELAYBAR_FAKE_SSH_LOG": sshLogURL.path,
                "RELAYBAR_FAKE_SSH_PID": pidURL.path
            ]
        )
        defer { service.shutdown() }
        let first = try makeUploadFile(named: "first.zip")
        let localDirectory = first.deletingLastPathComponent()
        let second = localDirectory.appendingPathComponent("second.zip")
        try Data("second".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        try await service.upload(
            server: fixture.server,
            localFile: first,
            remoteDirectory: "/srv/releases",
            replaceExisting: false
        )
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let processIdentifier = try XCTUnwrap(pid_t(pidText))
        XCTAssertEqual(Darwin.kill(processIdentifier, SIGTERM), 0)
        try await waitUntil(timeout: 2) {
            !FileManager.default.fileExists(atPath: pidURL.path)
                && (try? self.privateSessionDirectories(in: sessionRoot).isEmpty) == true
        }

        try await service.upload(
            server: fixture.server,
            localFile: second,
            remoteDirectory: "/srv/releases",
            replaceExisting: false
        )

        let commandNames = try uploadCommands(for: fixture).map(commandName)
        XCTAssertEqual(commandNames.filter { $0 == "quit" }.count, 2)
        let sshLog = try String(contentsOf: sshLogURL, encoding: .utf8)
        XCTAssertEqual(
            sshLog.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            2
        )
    }

    func testUploadMasterLossBeforePublishFailsClosedAndCleansStaging() async throws {
        let fixture = makeUploadFixture(kind: "SessionChange")
        defer { removeUploadFixture(fixture) }
        let sessionRoot = URL(
            fileURLWithPath: "/tmp/RelayBarSSHTests-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let sshLogURL = sessionRoot.appendingPathComponent("ssh.log")
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            sshExecutableURL: fakeSSHExecutableURL,
            sessionTemporaryDirectory: sessionRoot,
            processEnvironment: ["RELAYBAR_FAKE_SSH_LOG": sshLogURL.path]
        )
        defer { service.shutdown() }
        let localFile = try makeUploadFile(named: "release.zip")
        defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }

        do {
            try await service.upload(
                server: fixture.server,
                localFile: localFile,
                remoteDirectory: "/srv/releases",
                replaceExisting: false
            )
            XCTFail("Expected the replaced SSH session to stop publication.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .connectionSessionUnavailable)
        }

        let commands = try uploadCommands(for: fixture).map(commandName)
        XCTAssertEqual(commands, ["ls", "quit", "put", "rm"])
        XCTAssertFalse(commands.contains("ln"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
        let sshLog = try String(contentsOf: sshLogURL, encoding: .utf8)
        XCTAssertEqual(
            sshLog.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            2
        )
    }

    func testConfiguredRemotePathWhenLiveTestingIsEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["RELAYBAR_REMOTE_FILES_LIVE_TEST"] == "1",
            let sshHost = environment["RELAYBAR_LIVE_SSH_HOST"],
            !sshHost.isEmpty,
            let remotePath = environment["RELAYBAR_LIVE_REMOTE_PATH"],
            RemotePath.validationMessage(for: remotePath) == nil
        else {
            throw XCTSkip(
                "Set RELAYBAR_REMOTE_FILES_LIVE_TEST=1, RELAYBAR_LIVE_SSH_HOST, and RELAYBAR_LIVE_REMOTE_PATH to run the live Remote Files test."
            )
        }

        let service = SFTPRemoteFileService()
        defer { service.shutdown() }
        let server = RemoteServer(
            id: UUID(),
            name: "Live",
            sshHost: sshHost,
            additionalArguments: environment["RELAYBAR_LIVE_SSH_IDENTITY_FILE"].map {
                ["-i", $0]
            } ?? []
        )

        let result = try await service.loadPath(server: server, path: remotePath)
        if environment["RELAYBAR_LIVE_REMOTE_EXPECT_FILE"] == "1" {
            guard case .file(let entry) = result else {
                return XCTFail("Expected the configured live path to resolve as a file.")
            }
            XCTAssertEqual(entry.path, RemotePath.normalized(remotePath))
            XCTAssertTrue(entry.isPreviewableMarkdown)
            let previewURL = try await service.preparePreview(server: server, entry: entry)
            defer {
                try? FileManager.default.removeItem(
                    at: previewURL.deletingLastPathComponent()
                )
            }
            let document = try await RemoteMarkdownDecoder.load(contentsOf: previewURL)
            XCTAssertFalse(document.plainText.isEmpty)
        } else if environment["RELAYBAR_LIVE_REMOTE_EXPECT_NONEMPTY"] == "1" {
            guard case .directory(let entries) = result else {
                return XCTFail("Expected the configured live path to resolve as a folder.")
            }
            XCTAssertFalse(entries.isEmpty)
        }
    }

    func testReportsACommandFailureWithoutInvokingAShell() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            connectionSharing: false
        )
        let server = RemoteServer(
            id: UUID(),
            name: "Unavailable",
            sshHost: "example.com",
            additionalArguments: []
        )

        do {
            _ = try await service.list(server: server, path: "/srv/app")
            XCTFail("Expected the command to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .commandFailed("The remote operation failed."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSerializesConcurrentStartupAndReusesOnePrivateMaster() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let sessionRoot = URL(
            fileURLWithPath: "/tmp/RelayBarSSHTests-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let logURL = sessionRoot.appendingPathComponent("ssh.log")
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.2,
            sshExecutableURL: fakeSSHExecutableURL,
            sessionTemporaryDirectory: sessionRoot,
            processEnvironment: ["RELAYBAR_FAKE_SSH_LOG": logURL.path]
        )
        defer { service.shutdown() }
        let server = makeFixtureServer(host: "shared")

        async let first = service.list(server: server, path: "/srv/app")
        async let second = service.list(server: server, path: "/srv/app/output")
        let (firstEntries, secondEntries) = try await (first, second)

        XCTAssertEqual(firstEntries.map(\.name), ["output", "report.txt"])
        XCTAssertEqual(secondEntries.map(\.name), ["output", "report.txt"])
        for depth in 2...5 {
            _ = try await service.list(
                server: server,
                path: "/srv/app/output/\(depth)"
            )
        }
        let image = RemoteFileEntry(
            name: "dashboard.png",
            path: "/srv/app/dashboard.png",
            kind: .file,
            size: 10,
            modificationText: "Jul 29 12:02"
        )
        let imagePreviewURL = try await service.preparePreview(
            server: server,
            entry: image
        )
        XCTAssertEqual(
            try String(contentsOf: imagePreviewURL, encoding: .utf8),
            "downloaded"
        )
        try? FileManager.default.removeItem(
            at: imagePreviewURL.deletingLastPathComponent()
        )
        let markdown = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            kind: .file,
            size: 10,
            modificationText: "Jul 29 12:02"
        )
        let previewURL = try await service.preparePreview(
            server: server,
            entry: markdown
        )
        XCTAssertEqual(
            try String(contentsOf: previewURL, encoding: .utf8),
            "downloaded"
        )
        try? FileManager.default.removeItem(
            at: previewURL.deletingLastPathComponent()
        )
        let destination = sessionRoot.appendingPathComponent("download.txt")
        try await service.download(
            server: server,
            entry: markdown,
            to: destination
        ) { _ in }
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "downloaded"
        )
        var log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            1
        )
        XCTAssertTrue(log.contains("ARG:-M"))
        XCTAssertTrue(log.contains("ARG:-S"))
        XCTAssertTrue(log.contains("ARG:ControlPersist=no"))
        XCTAssertTrue(log.contains("ARG:ClearAllForwardings=yes"))

        let sessionDirectories = try privateSessionDirectories(in: sessionRoot)
        XCTAssertEqual(sessionDirectories.count, 1)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: try XCTUnwrap(sessionDirectories.first).path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )

        service.shutdown()
        try await waitUntil(timeout: 2) {
            (try? self.privateSessionDirectories(in: sessionRoot).isEmpty) == true
        }

        _ = try await service.list(server: server, path: "/srv/app")
        log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            2,
            "Only a later explicit operation may recreate a stopped master."
        )
        service.shutdown()
        try await waitUntil(timeout: 2) {
            (try? self.privateSessionDirectories(in: sessionRoot).isEmpty) == true
        }
    }

    func testCancellingOneSFTPChildLeavesTheMasterReusable() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let sessionRoot = URL(
            fileURLWithPath: "/tmp/RelayBarSSHTests-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let logURL = sessionRoot.appendingPathComponent("ssh.log")
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            sshExecutableURL: fakeSSHExecutableURL,
            sessionTemporaryDirectory: sessionRoot,
            processEnvironment: ["RELAYBAR_FAKE_SSH_LOG": logURL.path]
        )
        defer { service.shutdown() }
        let server = makeFixtureServer(host: "sharedslow")
        let entry = makeFileEntry()
        let destination = sessionRoot.appendingPathComponent("result.txt")
        let task = Task {
            try await service.download(
                server: server,
                entry: entry,
                to: destination
            ) { _ in }
        }
        try await waitUntil(timeout: 2) {
            !self.partialItems(in: sessionRoot).isEmpty
        }

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let entries = try await service.list(server: server, path: "/srv/app")
        XCTAssertEqual(entries.map(\.name), ["output", "report.txt"])
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            1
        )
        XCTAssertTrue(partialItems(in: sessionRoot).isEmpty)
    }

    func testMasterLossWaitsForTheNextExplicitOperationToReconnect() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let sessionRoot = URL(
            fileURLWithPath: "/tmp/RelayBarSSHTests-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let logURL = sessionRoot.appendingPathComponent("ssh.log")
        let pidURL = sessionRoot.appendingPathComponent("ssh.pid")
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            sshExecutableURL: fakeSSHExecutableURL,
            sessionTemporaryDirectory: sessionRoot,
            processEnvironment: [
                "RELAYBAR_FAKE_SSH_LOG": logURL.path,
                "RELAYBAR_FAKE_SSH_PID": pidURL.path
            ]
        )
        defer { service.shutdown() }
        let server = makeFixtureServer(host: "shared")
        _ = try await service.list(server: server, path: "/srv/app")
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let processIdentifier = try XCTUnwrap(pid_t(pidText))

        XCTAssertEqual(Darwin.kill(processIdentifier, SIGTERM), 0)
        try await waitUntil(timeout: 2) {
            !FileManager.default.fileExists(atPath: pidURL.path)
                && (try? self.privateSessionDirectories(in: sessionRoot).isEmpty) == true
        }
        var log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            1,
            "Master exit must not start a background reconnect."
        )

        _ = try await service.list(server: server, path: "/srv/app")
        log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            2
        )
    }

    func testCancellationDuringMasterStartupReturnsPromptlyAndStartsNoSFTPChild() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let sessionRoot = URL(
            fileURLWithPath: "/tmp/RelayBarSSHTests-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let readyURL = sessionRoot.appendingPathComponent("ready")
        let logURL = sessionRoot.appendingPathComponent("ssh.log")
        let host = "RelayBarCancelledSFTP-\(suffix)"
        let childMarkerURL = URL(fileURLWithPath: "/tmp/\(host)")
        try? FileManager.default.removeItem(at: childMarkerURL)
        defer { try? FileManager.default.removeItem(at: childMarkerURL) }
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.1,
            sshExecutableURL: fakeSSHExecutableURL,
            sessionTemporaryDirectory: sessionRoot,
            processEnvironment: [
                "RELAYBAR_FAKE_SSH_LOG": logURL.path,
                "RELAYBAR_FAKE_SSH_READY_FILE": readyURL.path
            ]
        )
        defer { service.shutdown() }
        let server = makeFixtureServer(host: host)
        let task = Task {
            try await service.list(server: server, path: "/srv/app")
        }
        try await waitUntil(timeout: 1) {
            (try? self.privateSessionDirectories(in: sessionRoot).count) == 1
        }
        let delayedRelease = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? Data().write(to: readyURL)
        }
        let cancellationStarted = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
        delayedRelease.cancel()
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStarted),
            0.3,
            "A cancelled startup waiter must not remain parked until readiness."
        )

        try Data().write(to: readyURL)
        try await waitUntil(timeout: 1) {
            (try? self.privateSessionDirectories(in: sessionRoot).first)
                .map {
                    FileManager.default.fileExists(
                        atPath: $0.appendingPathComponent(
                            RemoteFileSSHSession.controlSocketName
                        ).path
                    )
                } == true
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: childMarkerURL.path))

        _ = try await service.list(server: server, path: "/srv/app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: childMarkerURL.path))
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            log.split(whereSeparator: \.isNewline).filter { $0 == "BEGIN" }.count,
            1
        )
    }

    func testNormalizesSFTPNotFoundErrors() async {
        let service = makeFixtureService()

        do {
            _ = try await service.list(
                server: makeFixtureServer(host: "notfound"),
                path: "/workspace"
            )
            XCTFail("Expected the missing path to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .commandFailed("The remote path wasn’t found."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNormalizesActionableConnectionErrors() async {
        let service = makeFixtureService()
        let cases: [(host: String, message: String)] = [
            ("hostkey", "SSH could not verify this server’s host key."),
            ("refused", "The server refused the connection.")
        ]

        for testCase in cases {
            do {
                _ = try await service.list(
                    server: makeFixtureServer(host: testCase.host),
                    path: "/srv/app"
                )
                XCTFail("Expected \(testCase.host) to fail.")
            } catch let error as RemoteFileError {
                XCTAssertEqual(error, .commandFailed(testCase.message))
            } catch {
                XCTFail("Unexpected error for \(testCase.host): \(error)")
            }
        }
    }

    func testFriendlyMessageNeverSurfacesDebugDiagnostics() {
        XCTAssertEqual(
            SFTPRemoteFileService.friendlyMessage(
                from: "debug1: identity file /Users/alice/.ssh/id_ed25519\n"
                    + "debug2: local client account alice\n"
            ),
            "The remote operation failed."
        )
        XCTAssertEqual(
            SFTPRemoteFileService.friendlyMessage(
                from: "debug2: noisy probe line\nPermission denied\n"
            ),
            "Permission was denied for this server or path."
        )
    }

    func testRejectsProcessOutputBeyondTheConfiguredLimit() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            standardOutputLimit: 1,
            connectionSharing: false
        )
        let server = RemoteServer(
            id: UUID(),
            name: "Verbose",
            sshHost: "example.com",
            additionalArguments: []
        )

        do {
            _ = try await service.list(server: server, path: "/srv/app")
            XCTFail("Expected the output limit to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBatchInputDescriptorSuppressesSIGPIPE() throws {
        let inputPipe = Pipe()
        defer {
            inputPipe.fileHandleForReading.closeFile()
            inputPipe.fileHandleForWriting.closeFile()
        }

        try SFTPRemoteFileService.suppressSIGPIPE(
            on: inputPipe.fileHandleForWriting.fileDescriptor
        )

        XCTAssertEqual(
            fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE),
            1
        )
    }

    func testSpawnInheritsBatchInputWhenPipeReaderIsStandardInput() throws {
        let savedStandardInput = dup(STDIN_FILENO)
        XCTAssertNotEqual(savedStandardInput, -1)
        guard savedStandardInput != -1 else { return }
        XCTAssertEqual(close(STDIN_FILENO), 0)
        defer {
            XCTAssertEqual(dup2(savedStandardInput, STDIN_FILENO), STDIN_FILENO)
            XCTAssertEqual(close(savedStandardInput), 0)
        }

        let inputPipe = Pipe()
        XCTAssertEqual(
            inputPipe.fileHandleForReading.fileDescriptor,
            STDIN_FILENO
        )
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))

        let processIdentifier = try SFTPRemoteFileService.spawnProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            inputPipe: inputPipe,
            outputURL: outputURL,
            errorURL: errorURL
        )
        inputPipe.fileHandleForReading.closeFile()
        try inputPipe.fileHandleForWriting.write(
            contentsOf: Data("batch input\n".utf8)
        )
        try inputPipe.fileHandleForWriting.close()

        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = waitpid(processIdentifier, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR

        XCTAssertEqual(waitResult, processIdentifier)
        XCTAssertEqual(waitStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            "batch input\n"
        )
    }

    func testRejectsAnOversizedPreviewBeforeStartingSFTP() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist"),
            previewSizeLimit: 1,
            connectionSharing: false
        )
        let entry = RemoteFileEntry(
            name: "large.png",
            path: "/srv/app/large.png",
            kind: .file,
            size: 2,
            modificationText: "Jul 23 21:04"
        )
        let server = RemoteServer(
            id: UUID(),
            name: "Preview",
            sshHost: "example.com",
            additionalArguments: []
        )

        do {
            _ = try await service.preparePreview(server: server, entry: entry)
            XCTFail("Expected the preview size limit to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .previewTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsAnOversizedVideoBeforeStartingSFTP() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist"),
            videoPreviewSizeLimit: 1,
            connectionSharing: false
        )
        let entry = RemoteFileEntry(
            name: "large.MP4",
            path: "/srv/app/large.MP4",
            kind: .file,
            size: 2,
            modificationText: "Aug 30 12:00"
        )
        let server = RemoteServer(
            id: UUID(),
            name: "Preview",
            sshHost: "example.com",
            additionalArguments: []
        )

        do {
            _ = try await service.preparePreviewWithProgress(
                server: server,
                entry: entry,
                progress: { _ in }
            )
            XCTFail("Expected the video preview size limit to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .videoTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsOversizedMarkdownWithItsSpecificLimit() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist"),
            markdownPreviewSizeLimit: 1,
            connectionSharing: false
        )
        let entry = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            kind: .file,
            size: 2,
            modificationText: "Jul 24 00:20"
        )
        let server = RemoteServer(
            id: UUID(),
            name: "Preview",
            sshHost: "example.com",
            additionalArguments: []
        )

        do {
            _ = try await service.preparePreview(server: server, entry: entry)
            XCTFail("Expected the Markdown preview size limit to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(error, .markdownTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFileDownloadMovesACompletePartialIntoPlace() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.txt")
        try Data("old".utf8).write(to: destination)
        let progress = LockedProgress()
        let service = makeFixtureService()

        try await service.download(
            server: makeFixtureServer(host: "success"),
            entry: makeFileEntry(),
            to: destination
        ) { progress.record($0) }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "downloaded")
        XCTAssertGreaterThanOrEqual(progress.maximum, 10)
        XCTAssertTrue(partialItems(in: directory).isEmpty)
    }

    func testDownloadSupportsDestinationNamesNearFilesystemLimit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(
            String(repeating: "a", count: 220)
        )
        let service = makeFixtureService()

        try await service.download(
            server: makeFixtureServer(host: "success"),
            entry: makeFileEntry(),
            to: destination
        ) { _ in }

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "downloaded"
        )
        XCTAssertTrue(partialItems(in: directory).isEmpty)
    }

    func testFailedDownloadPreservesExistingDestinationAndRemovesPartial() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.txt")
        try Data("original".utf8).write(to: destination)
        let service = makeFixtureService()

        do {
            try await service.download(
                server: makeFixtureServer(host: "failure"),
                entry: makeFileEntry(),
                to: destination
            ) { _ in }
            XCTFail("Expected the fixture transfer to fail.")
        } catch let error as RemoteFileError {
            XCTAssertEqual(
                error,
                .commandFailed("Permission was denied for this server or path.")
            )
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertTrue(partialItems(in: directory).isEmpty)
    }

    func testCancellationStopsTheProcessAndRemovesPartial() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.txt")
        let signals = LockedSignalRecorder()
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.2,
            connectionSharing: false,
            signalProcess: { processIdentifier, signal in
                signals.send(processIdentifier: processIdentifier, signal: signal)
            }
        )
        let server = makeFixtureServer(host: "slow")
        let entry = makeFileEntry()
        let task = Task {
            try await service.download(
                server: server,
                entry: entry,
                to: destination
            ) { _ in }
        }

        try await waitUntil(timeout: 2) {
            self.partialItems(in: directory).contains {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("payload").path
                )
            }
        }
        let stagingDirectory = try XCTUnwrap(partialItems(in: directory).first)
        let stagingAttributes = try FileManager.default.attributesOfItem(
            atPath: stagingDirectory.path
        )
        XCTAssertEqual(
            (stagingAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(partialItems(in: directory).isEmpty)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(signals.values, [SIGTERM])
    }

    func testCancellationForceStopsAProcessThatIgnoresTermination() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.txt")
        let signals = LockedSignalRecorder()
        let service = SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            forceStopDelay: 0.05,
            connectionSharing: false,
            signalProcess: { processIdentifier, signal in
                signals.send(processIdentifier: processIdentifier, signal: signal)
            }
        )
        let server = makeFixtureServer(host: "stubborn")
        let entry = makeFileEntry()
        let task = Task {
            try await service.download(
                server: server,
                entry: entry,
                to: destination
            ) { _ in }
        }

        try await waitUntil(timeout: 2) {
            self.partialItems(in: directory).contains {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("payload").path
                )
            }
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(partialItems(in: directory).isEmpty)
        XCTAssertEqual(signals.values, [SIGTERM, SIGKILL])
    }

    func testFolderProgressIncludesHiddenFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: destination.appendingPathComponent("old.txt")
        )
        let progress = LockedProgress()
        let service = makeFixtureService()
        let entry = RemoteFileEntry(
            name: "folder",
            path: "/srv/app/folder",
            kind: .directory,
            size: nil,
            modificationText: "Jul 23 21:04"
        )

        try await service.download(
            server: makeFixtureServer(host: "folder"),
            entry: entry,
            to: destination
        ) { progress.record($0) }

        XCTAssertEqual(progress.maximum, 13)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(".hidden").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("old.txt").path
            )
        )
    }

    private func makeFixtureService() -> SFTPRemoteFileService {
        SFTPRemoteFileService(
            executableURL: fixtureExecutableURL,
            connectionSharing: false
        )
    }

    private typealias UploadFixture = (
        server: RemoteServer,
        logURL: URL,
        stateURL: URL
    )

    private func makeUploadFixture(kind: String) -> UploadFixture {
        let host = "RelayBarUpload\(kind)-\(UUID().uuidString)"
        return (
            makeFixtureServer(host: host),
            URL(fileURLWithPath: "/tmp/\(host).log"),
            URL(fileURLWithPath: "/tmp/\(host).state")
        )
    }

    private func removeUploadFixture(_ fixture: UploadFixture) {
        try? FileManager.default.removeItem(at: fixture.logURL)
        try? FileManager.default.removeItem(at: fixture.stateURL)
        try? FileManager.default.removeItem(
            atPath: fixture.stateURL.path + ".cleanup"
        )
        try? FileManager.default.removeItem(
            atPath: fixture.stateURL.path + ".collision"
        )
    }

    private func makeUploadFile(named name: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent(name)
        try Data("payload".utf8).write(to: file)
        return file
    }

    private func uploadCommands(for fixture: UploadFixture) throws -> [String] {
        try String(contentsOf: fixture.logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func commandName(_ command: String) -> String {
        String(command.prefix(while: { !$0.isWhitespace }))
    }

    private func makeFixtureServer(host: String) -> RemoteServer {
        RemoteServer(
            id: UUID(),
            name: host,
            sshHost: host,
            additionalArguments: []
        )
    }

    private func makeFileEntry() -> RemoteFileEntry {
        RemoteFileEntry(
            name: "result.txt",
            path: "/srv/app/result.txt",
            kind: .file,
            size: 10,
            modificationText: "Jul 23 21:04"
        )
    }

    private func makeDeleteEntry(
        kind: RemoteFileEntry.Kind = .file
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: "report[1].json",
            path: "/srv/app/report[1].json",
            kind: kind,
            size: 7,
            modificationText: "Aug 30 12:00"
        )
    }

    private func partialItems(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(".relaybar-") }
    }

    private func privateSessionDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                RemoteFileSSHSession.privateDirectoryPrefix
            )
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    private var fixtureExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-sftp.sh")
    }

    private var fakeSSHExecutableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh.sh")
    }
}

final class RemoteDirectoryCacheTests: XCTestCase {
    func testDefaultsToTwentyThousandUnitsAndEvictsWholeLRUSnapshots() {
        XCTAssertEqual(RemoteDirectoryCache().maximumEntryCount, 20_000)
        var cache = RemoteDirectoryCache(maximumEntryCount: 3)
        let connection = identity(host: "alpha")

        cache.insert(entries(count: 2, parent: "/a"), for: connection, path: "/a/")
        cache.insert(entries(count: 1, parent: "/b"), for: connection, path: "/b")
        XCTAssertNotNil(cache.entries(for: connection, path: "/a"))
        cache.insert(entries(count: 1, parent: "/c"), for: connection, path: "/c")

        XCTAssertEqual(cache.entryCount, 3)
        XCTAssertTrue(cache.contains(connection: connection, path: "/a"))
        XCTAssertFalse(cache.contains(connection: connection, path: "/b"))
        XCTAssertTrue(cache.contains(connection: connection, path: "/c"))
    }

    func testIsolatesExactConnectionsAndInvalidatesEverySnapshot() {
        var cache = RemoteDirectoryCache(maximumEntryCount: 4)
        let first = identity(host: "devbox", arguments: ["-p", "22"])
        let second = identity(host: "devbox", arguments: ["-p", "2222"])
        cache.insert(entries(count: 1, parent: "/srv"), for: first, path: "/srv")

        XCTAssertNotNil(cache.entries(for: first, path: "/srv/"))
        XCTAssertNil(cache.entries(for: second, path: "/srv"))

        cache.removeAll()
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertFalse(cache.contains(connection: first, path: "/srv"))
    }

    func testEmptyFoldersStillConsumeBoundedCacheUnits() {
        var cache = RemoteDirectoryCache(maximumEntryCount: 2)
        let connection = identity(host: "devbox")

        cache.insert([], for: connection, path: "/one")
        cache.insert([], for: connection, path: "/two")
        cache.insert([], for: connection, path: "/three")

        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertFalse(cache.contains(connection: connection, path: "/one"))
        XCTAssertTrue(cache.contains(connection: connection, path: "/two"))
        XCTAssertTrue(cache.contains(connection: connection, path: "/three"))
    }

    private func identity(
        host: String,
        arguments: [String] = []
    ) -> RemoteServer.ConnectionIdentity {
        RemoteServer.ConnectionIdentity(
            sshHost: host,
            additionalArguments: arguments
        )
    }

    private func entries(count: Int, parent: String) -> [RemoteFileEntry] {
        (0..<count).map { index in
            RemoteFileEntry(
                name: "item-\(index)",
                path: "\(parent)/item-\(index)",
                kind: .file,
                size: 1,
                modificationText: "Jul 29 12:00"
            )
        }
    }
}

@MainActor
final class RemoteFilesModelTests: XCTestCase {
    func testOpeningWorkspaceWithRecentLocationsStartsNoNetworkOperation() throws {
        let catalog = RemoteServerCatalog()
        let server = try catalog.add(name: "Devbox", sshHost: "devbox.local")
        _ = catalog.recordSuccessfulOpen(server, path: "/srv/project")
        let service = StubRemoteFileService()

        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            serverCatalog: catalog
        )

        XCTAssertEqual(model.screen, .welcome)
        XCTAssertEqual(model.recentLocations.map(\.path), ["/srv/project"])
        XCTAssertTrue(service.listRequests.isEmpty)
        XCTAssertTrue(service.loadPathRequests.isEmpty)
        XCTAssertEqual(service.shutdownCount, 0)
    }

    func testRecentLocationActivationPreservesRootAndBackReturnsToWelcome() async throws {
        let catalog = RemoteServerCatalog()
        let server = try catalog.add(name: "Devbox", sshHost: "devbox.local")
        let location = try XCTUnwrap(
            catalog.recordSuccessfulOpen(server, path: "/srv/project")
        )
        let service = StubRemoteFileService()
        service.pathResults[location.path] = .directory([])
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            serverCatalog: catalog
        )

        XCTAssertEqual(model.recentLocations.map(\.id), [location.id])
        model.activate(location)
        try await waitUntil { model.screen == .browser && !model.isLoading }

        XCTAssertEqual(model.activeLocationID, location.id)
        XCTAssertEqual(model.currentPath, location.path)
        model.goBack()
        XCTAssertEqual(model.screen, .welcome)
        XCTAssertNil(model.activeLocationID)
        XCTAssertEqual(service.shutdownCount, 1)
    }

    func testFailedCrossHostActivationCannotOperateOnThePriorHostListing() async throws {
        let catalog = RemoteServerCatalog()
        let firstServer = try catalog.add(name: "First", sshHost: "first.example.com")
        let secondServer = try catalog.add(name: "Second", sshHost: "second.example.com")
        let firstLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(firstServer, path: "/srv/first")
        )
        let secondLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(secondServer, path: "/srv/second")
        )
        let priorEntry = makeFileEntry(name: "prior.txt", parentPath: firstLocation.path)
        let service = StubRemoteFileService()
        service.pathResults[firstLocation.path] = .directory([priorEntry])
        service.errors[secondLocation.path] = RemoteFileError.commandFailed("Offline.")
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            serverCatalog: catalog
        )

        model.activate(firstLocation)
        try await waitUntil { model.screen == .browser && !model.isLoading }
        XCTAssertEqual(model.entries, [priorEntry])

        model.activate(secondLocation)
        try await waitUntil { model.errorMessage == "Offline." && !model.isLoading }

        XCTAssertEqual(model.screen, .welcome)
        XCTAssertEqual(model.currentPath, "")
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.canUpload)
        model.refresh()
        XCTAssertEqual(service.loadPathRequests.count, 2)
        XCTAssertEqual(service.shutdownCount, 1)
    }

    func testLocationActivationCancelsPendingPreviewBeforeOpeningNewRoot() async throws {
        let catalog = RemoteServerCatalog()
        let firstServer = try catalog.add(name: "First", sshHost: "first.example.com")
        let secondServer = try catalog.add(name: "Second", sshHost: "second.example.com")
        let firstLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(firstServer, path: "/srv/first")
        )
        let secondLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(secondServer, path: "/srv/second")
        )
        let markdown = makeFileEntry(name: "README.md", parentPath: firstLocation.path)
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(markdown.name)
        try Data("# Pending".utf8).write(to: previewURL)
        let decoder = BlockingMarkdownDecoder()
        let service = StubRemoteFileService()
        service.pathResults[firstLocation.path] = .directory([markdown])
        service.pathResults[secondLocation.path] = .directory([])
        service.previewURL = previewURL
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            markdownDecoder: decoder.load,
            serverCatalog: catalog
        )

        model.activate(firstLocation)
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.preview(markdown)
        try await waitUntil { decoder.hasStarted }

        model.activate(secondLocation)
        try await waitUntil {
            model.screen == .browser
                && model.currentPath == secondLocation.path
                && !model.isLoading
        }
        try await waitUntil {
            !FileManager.default.fileExists(atPath: previewDirectory.path)
        }

        XCTAssertNil(model.previewEntry)
        XCTAssertNil(model.previewMarkdown)
        XCTAssertNil(model.errorMessage)
    }

    func testExpandedGlobalRecentsStayExcludedFromNestedHostPaths() throws {
        let catalog = RemoteServerCatalog()
        let server = try catalog.add(name: "Devbox", sshHost: "devbox.local")
        for index in 1...8 {
            _ = catalog.recordSuccessfulOpen(server, path: "/srv/project-\(index)")
        }
        let model = RemoteFilesModel(tunnels: [], serverCatalog: catalog)

        XCTAssertEqual(model.recentLocations.count, 8)
        XCTAssertEqual(model.nestedLocations(for: server).count, 2)
        XCTAssertTrue(
            model.nestedLocations(
                for: server,
                excluding: model.recentLocations
            ).isEmpty
        )
    }

    func testFailedRecentLocationCanBeRemovedWithoutChangingHost() async throws {
        let catalog = RemoteServerCatalog()
        let server = try catalog.add(name: "Devbox", sshHost: "devbox.local")
        let location = try XCTUnwrap(
            catalog.recordSuccessfulOpen(server, path: "/missing")
        )
        let service = StubRemoteFileService()
        service.errors[location.path] = RemoteFileError.commandFailed("Not found.")
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            serverCatalog: catalog
        )

        model.activate(location)
        try await waitUntil { model.errorMessage == "Not found." }
        XCTAssertEqual(model.failedLocationID, location.id)

        model.removeFailedLocation()
        XCTAssertTrue(model.recentLocations.isEmpty)
        XCTAssertEqual(model.servers.first?.sshHost, "devbox.local")
    }

    func testUploadUsesCurrentFolderAndExplicitReplacementConsent() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let existing = makeFileEntry(name: "release.zip")
        let service = StubRemoteFileService()
        service.pathResults["/srv/app"] = .directory([existing])
        let presenter = StubRemoteFilePresenter()
        let localDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localFile = localDirectory.appendingPathComponent(existing.name)
        try Data("archive".utf8).write(to: localFile)
        presenter.uploadFile = localFile
        presenter.replacementConfirmation = true
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.beginUpload()
        try await waitUntil { model.upload?.phase == .completed }

        XCTAssertEqual(presenter.replacementNames, [existing.name])
        XCTAssertEqual(service.uploadRequests.count, 1)
        XCTAssertEqual(service.uploadRequests.first?.remoteDirectory, "/srv/app")
        XCTAssertEqual(service.uploadRequests.first?.replaceExisting, true)
    }

    func testUploadConflictRefreshesAndRetryRequiresReplacementConsent() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let existing = makeFileEntry(name: "release.zip")
        let service = StubRemoteFileService()
        service.pathResults["/srv/app"] = .directory([])
        service.uploadError = RemoteFileError.uploadConflict
        let presenter = StubRemoteFilePresenter()
        let localDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localFile = localDirectory.appendingPathComponent(existing.name)
        try Data("archive".utf8).write(to: localFile)
        presenter.uploadFile = localFile
        presenter.replacementConfirmation = true
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        service.listings["/srv/app"] = [existing]

        model.beginUpload()
        try await waitUntil {
            model.upload?.phase == .failed
                && !model.isRefreshing
                && model.entries == [existing]
        }
        service.uploadError = nil
        model.retryUpload()
        try await waitUntil { model.upload?.phase == .completed }

        XCTAssertEqual(presenter.replacementNames, [existing.name])
        XCTAssertEqual(service.uploadRequests.map(\.replaceExisting), [false, true])
    }

    func testApprovedUploadRetryCannotFollowNavigationToAnotherHost() async throws {
        let catalog = RemoteServerCatalog()
        let firstServer = try catalog.add(name: "First", sshHost: "first.example.com")
        let secondServer = try catalog.add(name: "Second", sshHost: "second.example.com")
        let firstLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(firstServer, path: "/srv/first")
        )
        let secondLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(secondServer, path: "/srv/second")
        )
        let existing = makeFileEntry(name: "release.zip", parentPath: firstLocation.path)
        let service = StubRemoteFileService()
        service.pathResults[firstLocation.path] = .directory([existing])
        service.pathResults[secondLocation.path] = .directory([])
        service.uploadError = RemoteFileError.commandFailed("Connection lost.")
        let presenter = StubRemoteFilePresenter()
        let localDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localFile = localDirectory.appendingPathComponent(existing.name)
        try Data("replacement".utf8).write(to: localFile)
        presenter.uploadFile = localFile
        presenter.replacementConfirmation = true
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            presenter: presenter,
            serverCatalog: catalog
        )

        model.activate(firstLocation)
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.beginUpload()
        try await waitUntil { model.upload?.phase == .failed }
        XCTAssertEqual(service.uploadRequests.map(\.replaceExisting), [true])

        model.activate(secondLocation)
        try await waitUntil {
            model.currentPath == secondLocation.path && !model.isLoading
        }
        XCTAssertNil(model.upload)
        model.retryUpload()
        XCTAssertEqual(service.uploadRequests.count, 1)
    }

    func testUploadCancellationBlocksLocationActivationUntilCleanupCompletes() async throws {
        let catalog = RemoteServerCatalog()
        let server = try catalog.add(name: "Devbox", sshHost: "devbox.local")
        let first = try XCTUnwrap(catalog.recordSuccessfulOpen(server, path: "/srv/one"))
        let second = try XCTUnwrap(catalog.recordSuccessfulOpen(server, path: "/srv/two"))
        let service = StubRemoteFileService()
        service.pathResults[first.path] = .directory([])
        service.pathResults[second.path] = .directory([])
        service.waitsForUploadCancellation = true
        let presenter = StubRemoteFilePresenter()
        let localDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localFile = localDirectory.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: localFile)
        presenter.uploadFile = localFile
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            presenter: presenter,
            serverCatalog: catalog
        )
        model.activate(first)
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.beginUpload()
        try await waitUntil { model.upload?.phase == .active }

        model.activate(second)
        XCTAssertEqual(model.currentPath, first.path)
        model.cancelUpload()
        try await waitUntil { model.upload?.phase == .cancelled }
        XCTAssertTrue(model.canActivateLocation)
    }

    func testWindowCloseCancellationWaitsForUploadCleanupBeforeShutdown() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        service.pathResults["/srv/app"] = .directory([])
        service.waitsForUploadCancellation = true
        let presenter = StubRemoteFilePresenter()
        let localDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let localFile = localDirectory.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: localFile)
        presenter.uploadFile = localFile
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.beginUpload()
        try await waitUntil { service.uploadRequests.count == 1 }

        var didFinishShutdown = false
        let waitsForShutdown = model.cancelAll {
            didFinishShutdown = true
        }
        XCTAssertTrue(waitsForShutdown)
        XCTAssertFalse(didFinishShutdown)
        try await waitUntil { service.shutdownCount == 1 }

        XCTAssertNil(model.upload)
        XCTAssertTrue(model.canActivateLocation)
        XCTAssertTrue(didFinishShutdown)
    }

    func testDirectMarkdownPathOpensPreviewAndPreservesBackPath() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let entry = makeFileEntry(
            name: "TRANSCRIPTION_LEARNINGS.md",
            parentPath: "/home/linxy97/workspace/2026/youtube-video-transcript"
        )
        service.pathResults[entry.path] = .file(entry)
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(entry.name)
        try Data("# Transcription learnings\n\nDirect preview.".utf8).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = entry.path

        model.openRemotePath()
        try await waitUntil {
            model.screen == .preview
                && model.previewMarkdown?.plainText.contains("Direct preview") == true
        }

        XCTAssertEqual(service.loadPathRequests.map(\.path), [entry.path])
        XCTAssertEqual(model.currentPath, RemotePath.parent(of: entry.path))
        XCTAssertEqual(model.remotePath, entry.path)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.selectedEntryID, entry.id)
        XCTAssertEqual(model.previewEntry, entry)
        XCTAssertEqual(model.recentLocations.first?.path, RemotePath.parent(of: entry.path))

        model.goBack()
        XCTAssertEqual(model.screen, .browser)
        XCTAssertEqual(model.entries, [entry])
        model.goBack()
        XCTAssertEqual(model.screen, .welcome)
        XCTAssertEqual(model.remotePath, entry.path)
    }

    func testDirectJSONPathOpensTheBoundedPreview() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let entry = makeFileEntry(name: "status.JSON", parentPath: "/srv/app")
        service.pathResults[entry.path] = .file(entry)
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(entry.name)
        try Data(#"{"message":"direct","unicode":"你好"}"#.utf8).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = entry.path

        model.openRemotePath()
        try await waitUntil {
            model.screen == .preview
                && model.previewJSON?.formattedText.contains("你好") == true
        }

        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.previewEntry, entry)
        model.goBack()
        XCTAssertEqual(model.screen, .browser)
    }

    func testDirectMP4PathOpensTheBoundedNativePreview() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let entry = makeFileEntry(name: "release-demo.MP4", parentPath: "/srv/app")
        service.pathResults[entry.path] = .file(entry)
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(entry.name)
        try Data(repeating: 0, count: 128).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            videoValidator: { _ in }
        )
        model.remotePath = entry.path

        model.openRemotePath()
        try await waitUntil {
            model.screen == .preview && model.previewVideoURL == previewURL
        }

        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.previewEntry, entry)
        XCTAssertEqual(service.previewRequests, [entry.id])
        model.goBack()
        XCTAssertEqual(model.screen, .browser)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDirectory.path))
    }

    func testDirectNonPreviewableFileIsSelectedWithoutStartingDownload() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let entry = makeFileEntry(name: "archive.zip")
        service.pathResults[entry.path] = .file(entry)
        let presenter = StubRemoteFilePresenter()
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = entry.path

        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.selectedEntryID, entry.id)
        XCTAssertTrue(service.previewRequests.isEmpty)
        XCTAssertEqual(presenter.chooseCount, 0)
        XCTAssertFalse(model.canUpload)
    }

    func testStandaloneHostOpensWithoutAForwardingProfileAndBecomesRecent() async throws {
        let catalog = RemoteServerCatalog()
        let service = StubRemoteFileService()
        service.listings["/srv/app"] = []
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            serverCatalog: catalog
        )

        try model.addServer(name: "Devbox", sshHost: "user@devbox")
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        XCTAssertEqual(service.listRequests.first?.server.sshHost, "user@devbox")
        XCTAssertEqual(model.servers.first?.source, .recent)
        XCTAssertEqual(model.servers.first?.displayName, "Devbox — user@devbox")
    }

    func testFailedStandaloneOpenDoesNotBecomeRecent() async throws {
        let catalog = RemoteServerCatalog()
        let service = StubRemoteFileService()
        service.errors["/missing"] = RemoteFileError.commandFailed("Not found.")
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            serverCatalog: catalog
        )

        try model.addServer(name: "", sshHost: "devbox")
        model.remotePath = "/missing"
        model.openRemotePath()
        try await waitUntil { model.errorMessage == "Not found." && !model.isLoading }

        XCTAssertEqual(model.servers.map(\.source), [.saved])
    }

    func testChangingConnectionAfterFailedInitialOpenShutsDownTheOldSession() async throws {
        let first = makeTunnel(name: "First", host: "first.example.com")
        let second = makeTunnel(name: "Second", host: "second.example.com")
        let service = StubRemoteFileService()
        service.errors["/missing"] = RemoteFileError.commandFailed("Not found.")
        let model = RemoteFilesModel(
            tunnels: [first, second],
            service: service
        )
        model.remotePath = "/missing"
        model.openRemotePath()
        try await waitUntil {
            model.errorMessage == "Not found." && !model.isLoading
        }

        service.errors["/missing"] = nil
        model.selectedServerID = second.id
        model.openRemotePath()
        try await waitUntil {
            model.screen == .browser && !model.isLoading
        }

        XCTAssertEqual(service.shutdownCount, 1)
        XCTAssertEqual(
            service.listRequests.map(\.server.sshHost),
            ["first.example.com", "second.example.com"]
        )
        model.cancelAll()
    }

    func testRemovingStandaloneHostLeavesForwardingProfilesAvailable() throws {
        let profile = makeTunnel(name: "Profile", host: "profile.example.com")
        let catalog = RemoteServerCatalog()
        let model = RemoteFilesModel(
            tunnels: [profile],
            serverCatalog: catalog
        )

        try model.addServer(name: "Standalone", sshHost: "standalone.example.com")
        XCTAssertTrue(model.canRemoveSelectedServer)
        model.removeSelectedServer()

        XCTAssertEqual(model.servers.map(\.sshHost), ["profile.example.com"])
        XCTAssertEqual(model.servers.first?.source, .forwardingProfile)
    }

    func testSavedServerSelectionSurvivesDuplicateRepresentativeReplacement() {
        let original = Tunnel(
            name: "Virtual Desktop",
            localPort: 5_902,
            destinationHost: "127.0.0.1",
            destinationPort: 5_902,
            sshHost: "spark-422e.local"
        )
        let duplicate = Tunnel(
            name: "Hermes Dashboard",
            localPort: 9_119,
            destinationHost: "127.0.0.1",
            destinationPort: 9_119,
            sshHost: "spark-422e.local"
        )
        let model = RemoteFilesModel(tunnels: [original, duplicate])

        XCTAssertEqual(model.servers.count, 1)
        XCTAssertEqual(model.selectedServerID, original.id)

        model.updateTunnels([duplicate])

        XCTAssertEqual(model.selectedServerID, duplicate.id)
        XCTAssertEqual(model.selectedServer?.sshHost, "spark-422e.local")
    }

    func testOpensNavigatesAndReturnsToWelcome() async throws {
        let tunnel = Tunnel(
            name: "Devbox",
            localPort: 8080,
            destinationHost: "localhost",
            destinationPort: 3000,
            sshHost: "devbox.local"
        )
        let service = StubRemoteFileService()
        service.listings["/srv/app"] = [
            RemoteFileEntry(
                name: "output",
                path: "/srv/app/output",
                kind: .directory,
                size: nil,
                modificationText: "Jul 23 21:04"
            )
        ]
        service.listings["/srv/app/output"] = []
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"

        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.entries.map(\.name), ["output"])

        model.activate(model.entries[0])
        try await waitUntil { model.currentPath == "/srv/app/output" && !model.isLoading }

        model.goBack()
        try await waitUntil { model.currentPath == "/srv/app" && !model.isLoading }
        XCTAssertEqual(model.selectedEntryID, "/srv/app/output")

        model.goBack()
        XCTAssertEqual(model.screen, .welcome)
        XCTAssertEqual(model.remotePath, "/srv/app")
        XCTAssertEqual(service.shutdownCount, 1)
    }

    func testCachedBackPublishesRowsSynchronouslyThenRevalidatesInPlace() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let output = makeDirectoryEntry(name: "output")
        service.listings["/srv/app"] = [output]
        service.listings[output.path] = []
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.activate(output)
        try await waitUntil { model.currentPath == output.path && !model.isLoading }
        service.suspendedListPaths.insert("/srv/app")

        model.goBack()

        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.presentedPath, "/srv/app")
        XCTAssertEqual(model.entries, [output])
        XCTAssertEqual(model.selectedEntryID, output.id)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isRefreshing)
        model.cancelAll()
    }

    func testBackCancelsAnUncachedOpenAndRestoresThePriorFolder() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let output = makeDirectoryEntry(name: "output")
        service.listings["/srv/app"] = [output]
        service.suspendedListPaths.insert(output.path)
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.activate(output)
        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.presentedPath, output.path)
        XCTAssertEqual(model.entries, [output])
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.canGoBack)
        XCTAssertEqual(model.backHelp, "Cancel opening this folder")
        try await waitUntil {
            service.listRequests.filter { $0.path == output.path }.count == 1
        }
        model.activate(output)
        await Task.yield()
        XCTAssertEqual(
            service.listRequests.filter { $0.path == output.path }.count,
            1,
            "Duplicate activation must coalesce with the pending open."
        )

        model.goBack()
        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.presentedPath, "/srv/app")
        XCTAssertEqual(model.entries, [output])
        XCTAssertEqual(model.selectedEntryID, output.id)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.pendingPath)
        model.cancelAll()
    }

    func testCachedRevisitSupersedesAnOlderRevalidation() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let output = makeDirectoryEntry(name: "output")
        let report = makeFileEntry(name: "report.txt", parentPath: output.path)
        service.listings["/srv/app"] = [output]
        service.listings[output.path] = [report]
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.activate(output)
        try await waitUntil { model.currentPath == output.path && !model.isLoading }
        service.suspendedListPaths = ["/srv/app", output.path]

        model.goBack()
        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertTrue(model.isRefreshing)
        model.activate(output)

        XCTAssertEqual(model.currentPath, output.path)
        XCTAssertEqual(model.presentedPath, output.path)
        XCTAssertEqual(model.entries, [report])
        XCTAssertTrue(model.isRefreshing)
        try await waitUntil {
            service.listRequests.filter { $0.path == output.path }.count == 2
        }
        XCTAssertEqual(model.currentPath, output.path)
        model.cancelAll()
    }

    func testRetriesTheFolderThatFailedToOpen() async throws {
        let tunnel = Tunnel(
            name: "Devbox",
            localPort: 8080,
            destinationHost: "localhost",
            destinationPort: 3000,
            sshHost: "devbox.local"
        )
        let service = StubRemoteFileService()
        let output = RemoteFileEntry(
            name: "output",
            path: "/srv/app/output",
            kind: .directory,
            size: nil,
            modificationText: "Jul 23 21:04"
        )
        service.listings["/srv/app"] = [output]
        service.errors["/srv/app/output"] = RemoteFileError.commandFailed("Connection lost.")
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.activate(output)
        try await waitUntil { model.errorMessage == "Connection lost." && !model.isLoading }
        XCTAssertEqual(model.currentPath, "/srv/app")

        service.errors["/srv/app/output"] = nil
        service.listings["/srv/app/output"] = []
        model.retryLastLoad()
        try await waitUntil { model.currentPath == "/srv/app/output" && !model.isLoading }
        XCTAssertNil(model.errorMessage)
    }

    func testRefreshPreservesContentSelectionAndUsesNonblockingRetry() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let report = makeFileEntry(name: "report.txt")
        service.listings["/srv/app"] = [report]
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.select(report)

        service.errors["/srv/app"] = RemoteFileError.commandFailed("Connection lost.")
        model.refresh()
        try await waitUntil { model.errorMessage == "Connection lost." && !model.isRefreshing }

        XCTAssertEqual(model.entries, [report])
        XCTAssertEqual(model.selectedEntryID, report.id)
        XCTAssertEqual(model.screen, .browser)

        service.errors["/srv/app"] = nil
        model.retryLastLoad()
        try await waitUntil {
            service.listRequests.count == 3
                && !model.isRefreshing
                && model.errorMessage == nil
        }

        XCTAssertEqual(model.entries, [report])
        XCTAssertEqual(model.selectedEntryID, report.id)
    }

    func testFailedCachedBackRevalidationKeepsRowsAndUsesNonblockingRetry() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let output = RemoteFileEntry(
            name: "output",
            path: "/srv/app/output",
            kind: .directory,
            size: nil,
            modificationText: "Jul 23 21:04"
        )
        service.listings["/srv/app"] = [output]
        service.listings["/srv/app/output"] = []
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.activate(output)
        try await waitUntil { model.currentPath == "/srv/app/output" && !model.isLoading }

        service.errors["/srv/app"] = RemoteFileError.commandFailed("Connection lost.")
        model.goBack()
        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.entries, [output])
        try await waitUntil { model.errorMessage == "Connection lost." && !model.isRefreshing }
        XCTAssertEqual(model.currentPath, "/srv/app")
        XCTAssertEqual(model.entries, [output])

        service.errors["/srv/app"] = nil
        model.retryLastLoad()
        try await waitUntil { model.errorMessage == nil && !model.isRefreshing }
        model.goBack()

        XCTAssertEqual(model.screen, .welcome)
    }

    func testOpenSessionKeepsItsServerSnapshotWhenSavedServersChange() async throws {
        let original = makeTunnel(name: "Original", host: "original.example.com")
        let replacement = makeTunnel(name: "Replacement", host: "replacement.example.com")
        let service = StubRemoteFileService()
        service.listings["/srv/app"] = []
        let model = RemoteFilesModel(tunnels: [original], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.updateTunnels([replacement])
        model.refresh()
        try await waitUntil { service.listRequests.count == 2 && !model.isRefreshing }

        XCTAssertEqual(
            service.listRequests.map(\.server.sshHost),
            ["original.example.com", "original.example.com"]
        )
    }

    func testTransferRetryReusesDestinationAndRevealUsesPresenter() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let presenter = StubRemoteFilePresenter()
        let file = makeFileEntry(name: "report.txt")
        service.listings["/srv/app"] = [file]
        service.downloadError = RemoteFileError.commandFailed("Connection lost.")
        presenter.destination = URL(fileURLWithPath: "/tmp/relaybar-test-report.txt")
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.download(file)
        try await waitUntil { model.transfer?.phase == .failed }
        XCTAssertEqual(presenter.chooseCount, 1)
        XCTAssertEqual(
            model.transfer?.message,
            "Connection lost. Temporary data was removed; existing files were unchanged."
        )

        service.downloadError = nil
        model.retryTransfer()
        try await waitUntil { model.transfer?.phase == .completed }
        XCTAssertEqual(presenter.chooseCount, 1)
        XCTAssertEqual(service.downloadDestinations.count, 2)
        XCTAssertEqual(service.downloadDestinations[0], service.downloadDestinations[1])

        model.revealTransfer()
        XCTAssertEqual(
            presenter.revealedDestinations,
            [presenter.destination].compactMap { $0 }
        )
    }

    func testDownloadRetryCannotFollowNavigationToAnotherHost() async throws {
        let catalog = RemoteServerCatalog()
        let firstServer = try catalog.add(name: "First", sshHost: "first.example.com")
        let secondServer = try catalog.add(name: "Second", sshHost: "second.example.com")
        let firstLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(firstServer, path: "/srv/first")
        )
        let secondLocation = try XCTUnwrap(
            catalog.recordSuccessfulOpen(secondServer, path: "/srv/second")
        )
        let file = makeFileEntry(name: "report.txt", parentPath: firstLocation.path)
        let service = StubRemoteFileService()
        service.pathResults[firstLocation.path] = .directory([file])
        service.pathResults[secondLocation.path] = .directory([])
        service.downloadError = RemoteFileError.commandFailed("Connection lost.")
        let presenter = StubRemoteFilePresenter()
        presenter.destination = URL(fileURLWithPath: "/tmp/relaybar-test-report.txt")
        let model = RemoteFilesModel(
            tunnels: [],
            service: service,
            presenter: presenter,
            serverCatalog: catalog
        )

        model.activate(firstLocation)
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.download(file)
        try await waitUntil { model.transfer?.phase == .failed }

        model.activate(secondLocation)
        try await waitUntil {
            model.currentPath == secondLocation.path && !model.isLoading
        }
        XCTAssertNil(model.transfer)
        model.retryTransfer()
        XCTAssertEqual(service.downloadDestinations.count, 1)
    }

    func testTransferCancellationBlocksLeavingRootUntilCleanupFinishes() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let presenter = StubRemoteFilePresenter()
        let file = makeFileEntry(name: "report.txt")
        service.listings["/srv/app"] = [file]
        service.waitsForDownloadCancellation = true
        presenter.destination = URL(fileURLWithPath: "/tmp/relaybar-test-report.txt")
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.download(file)
        try await waitUntil { model.transfer?.phase == .active }
        XCTAssertFalse(model.canGoBack)

        model.cancelTransfer()
        XCTAssertEqual(model.transfer?.phase, .cancelling)
        XCTAssertFalse(model.canGoBack)
        try await waitUntil { model.transfer?.phase == .cancelled }

        XCTAssertTrue(model.canGoBack)
    }

    func testTransferCancellationBlocksNestedNavigationUntilCleanupFinishes() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let presenter = StubRemoteFilePresenter()
        let folder = makeDirectoryEntry(name: "output")
        let file = makeFileEntry(name: "report.txt", parentPath: folder.path)
        service.listings["/srv/app"] = [folder]
        service.listings[folder.path] = [file]
        service.waitsForDownloadCancellation = true
        presenter.destination = URL(fileURLWithPath: "/tmp/relaybar-test-report.txt")
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.activate(folder)
        try await waitUntil { model.currentPath == folder.path && !model.isLoading }

        model.download(file)
        try await waitUntil { model.transfer?.phase == .active }
        XCTAssertFalse(model.canGoBack)

        model.cancelTransfer()
        try await waitUntil { model.transfer?.phase == .cancelled }
        XCTAssertTrue(model.canGoBack)
    }

    func testDelayedProgressFromFailedTransferDoesNotChangeRetry() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let presenter = StubRemoteFilePresenter()
        let file = makeFileEntry(name: "report.txt")
        service.listings["/srv/app"] = [file]
        service.downloadError = RemoteFileError.commandFailed("Connection lost.")
        presenter.destination = URL(fileURLWithPath: "/tmp/relaybar-test-report.txt")
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.download(file)
        try await waitUntil { model.transfer?.phase == .failed }

        service.downloadError = nil
        service.waitsForDownloadCancellation = true
        model.retryTransfer()
        try await waitUntil {
            model.transfer?.phase == .active
                && service.downloadProgressCallbacks.count == 2
                && model.transfer?.completedBytes == 64
        }

        service.downloadProgressCallbacks.send(value: 7, at: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.transfer?.completedBytes, 64)

        model.cancelTransfer()
        try await waitUntil { model.transfer?.phase == .cancelled }
    }

    func testPreviewRestoresSelectionAndRemovesTemporaryContent() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let image = RemoteFileEntry(
            name: "pixel.png",
            path: "/srv/app/pixel.png",
            kind: .file,
            size: Int64(validPNGData.count),
            modificationText: "Jul 23 21:04"
        )
        service.listings["/srv/app"] = [image]
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent("pixel.png")
        try validPNGData.write(to: previewURL)
        service.previewURL = previewURL
        let threadProbe = LockedThreadProbe()
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            imageDecoder: { url in
                threadProbe.recordDecode(isMainThread: Thread.isMainThread)
                return try RemoteImageDecoder.decodeCGImage(contentsOf: url)
            }
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.select(image)

        model.preview(image)
        try await waitUntil { model.previewImage != nil && !model.isLoadingPreview }
        model.closePreview()

        XCTAssertEqual(model.screen, .browser)
        XCTAssertEqual(model.selectedEntryID, image.id)
        XCTAssertFalse(threadProbe.decodedOnMainThread)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDirectory.path))
    }

    func testMarkdownPreviewRestoresSelectionAndRemovesTemporaryContent() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let markdown = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            kind: .file,
            size: 24,
            modificationText: "Jul 24 00:20"
        )
        service.listings["/srv/app"] = [markdown]
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent("README.md")
        try Data("# RelayBar\n\nSafe preview.".utf8).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.select(markdown)

        model.preview(markdown)
        try await waitUntil {
            model.previewMarkdown != nil && !model.isLoadingPreview
        }

        XCTAssertTrue(model.previewMarkdown?.plainText.contains("RelayBar") == true)
        XCTAssertNil(model.previewImage)
        model.closePreview()

        XCTAssertEqual(model.screen, .browser)
        XCTAssertEqual(model.selectedEntryID, markdown.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDirectory.path))
    }

    func testPreviewSidebarSwitchesSiblingWithoutRelistingAndCleansSupersededContent()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let first = makeFileEntry(name: "FIRST.md")
        let second = makeFileEntry(name: "SECOND.md")
        let plainText = makeFileEntry(name: "notes.txt")
        let folder = makeDirectoryEntry(name: "archive")
        service.listings["/srv/app"] = [folder, first, second, plainText]

        let firstDirectory = try makeTemporaryDirectory()
        let firstURL = firstDirectory.appendingPathComponent(first.name)
        try Data("# First".utf8).write(to: firstURL)
        let secondDirectory = try makeTemporaryDirectory()
        let secondURL = secondDirectory.appendingPathComponent(second.name)
        try Data("# Second\n\nCurrent preview.".utf8).write(to: secondURL)
        service.previewURLs[first.id] = firstURL
        service.previewURLs[second.id] = secondURL
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let firstDecoder = BlockingMarkdownDecoder()
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            markdownDecoder: { url in
                if url == firstURL {
                    return try await firstDecoder.load(contentsOf: url)
                }
                return try await RemoteMarkdownDecoder.load(contentsOf: url)
            }
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        XCTAssertEqual(model.previewableEntries, [first, second])
        model.preview(first)
        try await waitUntil { firstDecoder.hasStarted }

        XCTAssertTrue(model.movePreviewSelection(by: 1))
        try await waitUntil {
            model.previewEntry == second
                && model.previewMarkdown?.plainText.contains("Current preview") == true
                && !model.isLoadingPreview
        }
        try await waitUntil {
            !FileManager.default.fileExists(atPath: firstDirectory.path)
        }

        XCTAssertEqual(model.selectedEntryID, second.id)
        XCTAssertEqual(service.listRequests.map(\.path), ["/srv/app"])
        XCTAssertEqual(service.previewRequests, [first.id, second.id])

        model.closePreview()
        XCTAssertEqual(model.screen, .browser)
        XCTAssertEqual(model.selectedEntryID, second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    func testCancelDuringMarkdownDecodeRemovesTemporaryContent() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let markdown = RemoteFileEntry(
            name: "README.md",
            path: "/srv/app/README.md",
            kind: .file,
            size: 24,
            modificationText: "Jul 24 00:20"
        )
        service.listings["/srv/app"] = [markdown]
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent("README.md")
        try Data("# RelayBar".utf8).write(to: previewURL)
        service.previewURL = previewURL
        let decoder = BlockingMarkdownDecoder()
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            markdownDecoder: { url in
                try await decoder.load(contentsOf: url)
            }
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.preview(markdown)
        try await waitUntil { decoder.hasStarted }
        model.closePreview()
        try await waitUntil {
            !FileManager.default.fileExists(atPath: previewDirectory.path)
        }

        XCTAssertEqual(model.screen, .browser)
        XCTAssertFalse(model.isLoadingPreview)
    }

    func testJSONPreviewUsesTheExistingPreviewLifecycle() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let json = makeFileEntry(name: "status.JSON")
        service.listings["/srv/app"] = [json]
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(json.name)
        try Data(#"{"ready":true,"count":2}"#.utf8).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(tunnels: [tunnel], service: service)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.preview(json)
        try await waitUntil { model.previewJSON != nil && !model.isLoadingPreview }

        XCTAssertTrue(model.previewJSON?.formattedText.contains(#""ready""#) == true)
        XCTAssertNil(model.previewImage)
        XCTAssertNil(model.previewMarkdown)
        model.closePreview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDirectory.path))
    }

    func testVideoPreviewReportsProgressPublishesURLAndCleansUpOnBack() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let video = makeFileEntry(name: "demo.MP4")
        service.listings["/srv/app"] = [video]
        service.previewProgressUpdates = [32, 128]
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(video.name)
        try Data(repeating: 0x01, count: 128).write(to: previewURL)
        service.previewURL = previewURL
        var validatedURL: URL?
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            videoValidator: { url in validatedURL = url }
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.preview(video)
        try await waitUntil { model.previewVideoURL != nil && !model.isLoadingPreview }

        XCTAssertEqual(model.previewVideoURL, previewURL)
        XCTAssertEqual(validatedURL, previewURL)
        XCTAssertNil(model.previewImage)
        XCTAssertNil(model.previewMarkdown)
        XCTAssertNil(model.previewJSON)
        XCTAssertNil(model.previewProgress)
        model.closePreview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDirectory.path))
    }

    func testVideoRetrievalCanBeCancelledAfterMeasuredProgress() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let video = makeFileEntry(name: "demo.mp4")
        service.listings["/srv/app"] = [video]
        service.previewProgressUpdates = [64]
        service.waitsForPreviewCancellation = true
        let previewDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: previewDirectory) }
        let previewURL = previewDirectory.appendingPathComponent(video.name)
        try Data(repeating: 0x01, count: 128).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            videoValidator: { _ in }
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.preview(video)
        try await waitUntil { model.previewProgress?.completedBytes == 64 }
        XCTAssertEqual(model.previewProgress?.percentage, 50)
        model.cancelPreviewLoading()

        XCTAssertFalse(model.isLoadingPreview)
        XCTAssertNil(model.previewProgress)
        XCTAssertNil(model.previewVideoURL)
        XCTAssertEqual(model.errorMessage, "Video preview canceled.")
    }

    func testUnsupportedVideoCannotPublishAndRemovesTemporaryContent() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let video = makeFileEntry(name: "broken.mp4")
        service.listings["/srv/app"] = [video]
        let previewDirectory = try makeTemporaryDirectory()
        let previewURL = previewDirectory.appendingPathComponent(video.name)
        try Data("broken".utf8).write(to: previewURL)
        service.previewURL = previewURL
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            videoValidator: { _ in throw RemoteFileError.unsupportedVideo }
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.preview(video)
        try await waitUntil { model.errorMessage != nil && !model.isLoadingPreview }

        XCTAssertNil(model.previewVideoURL)
        XCTAssertEqual(
            model.errorMessage,
            RemoteFileError.unsupportedVideo.localizedDescription
        )
        try await waitUntil {
            !FileManager.default.fileExists(atPath: previewDirectory.path)
        }
    }

    func testDeletingPreviewedVideoStopsItAndAdvancesToNextPreviewableFile()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let video = makeFileEntry(name: "demo.mp4")
        let json = makeFileEntry(name: "status.json")
        service.listings["/srv/app"] = [video, json]
        let videoDirectory = try makeTemporaryDirectory()
        let jsonDirectory = try makeTemporaryDirectory()
        let videoURL = videoDirectory.appendingPathComponent(video.name)
        let jsonURL = jsonDirectory.appendingPathComponent(json.name)
        try Data(repeating: 0, count: 128).write(to: videoURL)
        try Data(#"{"next":true}"#.utf8).write(to: jsonURL)
        service.previewURLs = [video.id: videoURL, json.id: jsonURL]
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            videoValidator: { _ in },
            deletionUndoDelay: 0
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.preview(video)
        try await waitUntil { model.previewVideoURL == videoURL }

        model.deletePreviewEntry()
        try await waitUntil {
            model.previewEntry == json
                && model.previewJSON != nil
                && model.deletion == nil
        }

        XCTAssertNil(model.previewVideoURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoDirectory.path))
        XCTAssertEqual(service.deleteRequests.map(\.entry), [video])
        XCTAssertTrue(
            model.deletionAnnouncement?.contains("Showing status.json") == true
        )
        model.closePreview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonDirectory.path))
    }

    func testDefaultDeletionOffersFiveSecondsToUndo() async throws {
        let service = StubRemoteFileService()
        let entry = makeFileEntry(name: "keep.txt")
        service.listings["/srv/app"] = [entry]
        let model = RemoteFilesModel(
            tunnels: [makeTunnel(name: "Devbox", host: "devbox.local")], service: service
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.delete(entry)
        XCTAssertEqual(model.deletion?.phase, .pendingUndo)
        let remaining = try XCTUnwrap(model.deletion?.undoDeadline).timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 4)
        XCTAssertLessThanOrEqual(remaining, 5)
        XCTAssertTrue(service.deleteRequests.isEmpty)
        model.undoDeletion()
        model.cancelAll()
    }

    func testUndoPreventsSingleAndBulkDeletionPastTheOriginalDeadline() async throws {
        for bulk in [false, true] {
            let service = StubRemoteFileService()
            let first = makeFileEntry(name: "a.txt")
            let second = makeFileEntry(name: "b.txt")
            service.listings["/srv/app"] = [first, second]
            let model = RemoteFilesModel(
                tunnels: [makeTunnel(name: "Devbox", host: "devbox.local")],
                service: service, deletionUndoDelay: 0.15
            )
            defer { model.cancelAll() }
            model.remotePath = "/srv/app"
            model.openRemotePath()
            try await waitUntil { model.screen == .browser && !model.isLoading }
            model.select(first)
            if bulk {
                model.beginFileSelection()
                model.toggleFileSelection(first)
                model.toggleFileSelection(second)
                model.deleteSelectedFiles()
            } else {
                model.delete(first)
            }
            XCTAssertEqual(model.deletion?.phase, .pendingUndo)
            XCTAssertTrue(service.deleteRequests.isEmpty)
            XCTAssertFalse(model.canActivateLocation)
            model.undoDeletion()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(service.deleteRequests.isEmpty)
            XCTAssertEqual(model.entries, [first, second])
            XCTAssertEqual(model.selectedEntryID, first.id)
            XCTAssertEqual(model.isSelectingFiles, bulk)
            if bulk { XCTAssertEqual(model.selectedFileIDs, [first.id, second.id]) }
            XCTAssertNil(model.deletion)
        }
    }

    func testSingleAndBulkDeletionSubmitOnlyAfterTheUndoDelay() async throws {
        for bulk in [false, true] {
            let service = StubRemoteFileService()
            let first = makeFileEntry(name: "a.txt")
            let second = makeFileEntry(name: "b.txt")
            service.listings["/srv/app"] = [first, second]
            let model = RemoteFilesModel(
                tunnels: [makeTunnel(name: "Devbox", host: "devbox.local")],
                service: service, deletionUndoDelay: 0.15
            )
            defer { model.cancelAll() }
            model.remotePath = "/srv/app"
            model.openRemotePath()
            try await waitUntil { model.screen == .browser && !model.isLoading }
            if bulk {
                model.beginFileSelection()
                model.toggleFileSelection(first)
                model.toggleFileSelection(second)
                model.deleteSelectedFiles()
            } else { model.delete(first) }
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(service.deleteRequests.isEmpty)
            try await waitUntil { model.deletion == nil }
            XCTAssertEqual(service.deleteRequests.map(\.entry), bulk ? [first, second] : [first])
            model.undoDeletion()
            XCTAssertEqual(model.entries, bulk ? [] : [second])
        }
    }

    func testClosingDuringUndoWindowNeverSubmitsDeletion() async throws {
        let service = StubRemoteFileService()
        let entry = makeFileEntry(name: "keep.txt")
        service.listings["/srv/app"] = [entry]
        let model = RemoteFilesModel(
            tunnels: [makeTunnel(name: "Devbox", host: "devbox.local")],
            service: service, deletionUndoDelay: 0.15
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.delete(entry)
        var completed = false
        model.cancelAll { completed = true }
        try await waitUntil { completed }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(service.deleteRequests.isEmpty)
        XCTAssertNil(model.deletion)
    }

    func testAcknowledgedBrowserDeletionSelectsTheNextRowWithoutConfirmation()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let first = makeFileEntry(name: "a.txt")
        let deleted = makeFileEntry(name: "b.txt")
        let next = makeFileEntry(name: "c.txt")
        service.listings["/srv/app"] = [first, deleted, next]
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.select(deleted)

        model.delete(deleted)
        try await waitUntil { model.deletion == nil && model.entries.count == 2 }

        XCTAssertEqual(service.deleteRequests.map(\.entry), [deleted])
        XCTAssertEqual(model.entries, [first, next])
        XCTAssertEqual(model.selectedEntryID, next.id)
        XCTAssertEqual(model.deletionAnnouncement, "Deleted b.txt.")
    }

    func testAcknowledgedDeletionShowsASameNameRecreatedByAnotherClient() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let original = makeFileEntry(name: "report.txt")
        let replacement = RemoteFileEntry(
            name: original.name,
            path: original.path,
            kind: .file,
            size: 999,
            modificationText: "Aug 30 13:00"
        )
        service.listings["/srv/app"] = [original]
        service.deleteReplacement = replacement
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.delete(original)
        try await waitUntil { model.deletion == nil }

        XCTAssertEqual(model.entries, [replacement])
        XCTAssertEqual(model.selectedEntry, replacement)
    }

    func testAcknowledgedPreviewDeletionStaysInPreviewAndMovesToNextImage()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let first = makeFileEntry(name: "a.png")
        let deleted = makeFileEntry(name: "b.png")
        let next = makeFileEntry(name: "c.png")
        service.listings["/srv/app"] = [first, deleted, next]
        var temporaryDirectories: [URL] = []
        for entry in [first, deleted, next] {
            let directory = try makeTemporaryDirectory()
            temporaryDirectories.append(directory)
            let url = directory.appendingPathComponent(entry.name)
            try validPNGData.write(to: url)
            service.previewURLs[entry.id] = url
        }
        defer {
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.preview(deleted)
        try await waitUntil { model.previewEntry == deleted && model.previewImage != nil }

        model.deletePreviewEntry()
        try await waitUntil {
            model.deletion == nil
                && model.previewEntry == next
                && model.previewImage != nil
                && !model.isLoadingPreview
        }

        XCTAssertEqual(model.screen, .preview)
        XCTAssertEqual(model.selectedEntryID, next.id)
        XCTAssertEqual(
            model.deletionAnnouncement,
            "Deleted b.png. Showing c.png."
        )
        XCTAssertEqual(service.deleteRequests.count, 1)
    }

    func testPreviewDeletionFallsBackToEarlierImageAndThenBrowserWhenNoneRemain()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let earlier = makeFileEntry(name: "a.png")
        let deleted = makeFileEntry(name: "b.png")
        service.listings["/srv/app"] = [earlier, deleted]
        let earlierDirectory = try makeTemporaryDirectory()
        let deletedDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: earlierDirectory)
            try? FileManager.default.removeItem(at: deletedDirectory)
        }
        let earlierURL = earlierDirectory.appendingPathComponent(earlier.name)
        let deletedURL = deletedDirectory.appendingPathComponent(deleted.name)
        try validPNGData.write(to: earlierURL)
        try validPNGData.write(to: deletedURL)
        service.previewURLs[earlier.id] = earlierURL
        service.previewURLs[deleted.id] = deletedURL
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.preview(deleted)
        try await waitUntil { model.previewEntry == deleted && model.previewImage != nil }

        model.deletePreviewEntry()
        try await waitUntil {
            model.previewEntry == earlier && model.previewImage != nil
                && !model.isLoadingPreview
        }
        XCTAssertEqual(model.screen, .preview)

        model.deletePreviewEntry()
        try await waitUntil { model.screen == .browser && model.entries.isEmpty }
        XCTAssertNil(model.selectedEntryID)
        XCTAssertEqual(
            model.deletionAnnouncement,
            "Deleted a.png. No images remain."
        )
    }

    func testRejectedDeletionKeepsTheCurrentPreviewAndDoesNotNavigate() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let image = makeFileEntry(name: "only.png")
        service.listings["/srv/app"] = [image]
        service.deleteError = RemoteFileError.deleteRejected("Permission denied.")
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(image.name)
        try validPNGData.write(to: url)
        service.previewURL = url
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.preview(image)
        try await waitUntil { model.previewImage != nil }

        model.deletePreviewEntry()
        try await waitUntil { model.deletion?.phase == .failed }

        XCTAssertEqual(model.screen, .preview)
        XCTAssertEqual(model.previewEntry, image)
        XCTAssertEqual(model.entries, [image])
        XCTAssertFalse(model.canDeletePreviewEntry)
    }

    func testUnknownDeletionRefreshesWithoutRetryOrSelectionAdvance() async throws {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let first = makeFileEntry(name: "a.txt")
        let selected = makeFileEntry(name: "b.txt")
        service.listings["/srv/app"] = [first, selected]
        service.deleteError = RemoteFileError.deleteOutcomeUnknown
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.select(selected)

        model.delete(selected)
        try await waitUntil { model.deletion?.phase == .failed }

        XCTAssertEqual(service.deleteRequests.count, 1)
        XCTAssertEqual(model.entries, [first, selected])
        XCTAssertEqual(model.selectedEntryID, selected.id)
        XCTAssertTrue(model.deletion?.message?.contains("still contains") == true)
        model.dismissDeletion()
        XCTAssertTrue(model.canDelete(selected))
        XCTAssertEqual(service.deleteRequests.count, 1)
    }

    func testFileSelectionModeSelectsOnlyFilesAndCancelsWithoutMutation()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let folder = makeDirectoryEntry(name: "assets")
        let first = makeFileEntry(name: "a.txt")
        let second = makeFileEntry(name: "b.txt")
        service.listings["/srv/app"] = [folder, first, second]
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.select(first)

        XCTAssertTrue(model.canBeginFileSelection)
        model.beginFileSelection()
        XCTAssertTrue(model.isSelectingFiles)
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertEqual(model.selectedEntryID, first.id)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canActivateLocation)

        model.toggleFileSelection(folder)
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        model.toggleFileSelection(second)
        XCTAssertEqual(model.selectedFileIDs, [second.id])

        model.cancelFileSelection()
        XCTAssertFalse(model.isSelectingFiles)
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertEqual(model.selectedEntryID, first.id)
        XCTAssertTrue(service.deleteRequests.isEmpty)
    }

    func testBulkDeletionRemovesSelectedFilesSequentiallyAndRepairsSelection()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let folder = makeDirectoryEntry(name: "assets")
        let first = makeFileEntry(name: "a.txt")
        let second = makeFileEntry(name: "b.txt")
        let next = makeFileEntry(name: "c.txt")
        let last = makeFileEntry(name: "d.txt")
        service.listings["/srv/app"] = [folder, first, second, next, last]
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.beginFileSelection()
        model.toggleFileSelection(second)
        model.toggleFileSelection(last)

        XCTAssertTrue(model.canDeleteSelectedFiles)
        model.deleteSelectedFiles()
        try await waitUntil { model.deletion == nil && model.entries.count == 3 }

        XCTAssertEqual(service.deleteRequests.map(\.entry), [second, last])
        XCTAssertEqual(model.entries, [folder, first, next])
        XCTAssertFalse(model.isSelectingFiles)
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertEqual(model.selectedEntryID, next.id)
        XCTAssertEqual(model.deletionAnnouncement, "Deleted 2 files.")
    }

    func testBulkDeletionStopsAtFirstFailureAndPreservesRemainingSelection()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        let first = makeFileEntry(name: "a.txt")
        let rejected = makeFileEntry(name: "b.txt")
        let unattempted = makeFileEntry(name: "c.txt")
        service.listings["/srv/app"] = [first, rejected, unattempted]
        service.deleteErrors[rejected.id] = RemoteFileError.deleteRejected(
            "Permission denied."
        )
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, deletionUndoDelay: 0)
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }
        model.beginFileSelection()
        model.toggleFileSelection(first)
        model.toggleFileSelection(rejected)
        model.toggleFileSelection(unattempted)

        model.deleteSelectedFiles()
        try await waitUntil { model.deletion?.phase == .failed }

        XCTAssertEqual(service.deleteRequests.map(\.entry), [first, rejected])
        XCTAssertEqual(model.entries, [rejected, unattempted])
        XCTAssertTrue(model.isSelectingFiles)
        XCTAssertEqual(model.selectedFileIDs, [rejected.id, unattempted.id])
        XCTAssertTrue(
            model.deletion?.message?.contains("Deleted 1 of 3 files.") == true
        )
        XCTAssertTrue(
            model.deletion?.message?.contains("server rejected") == true
        )
        model.dismissDeletion()
        XCTAssertTrue(model.canDeleteSelectedFiles)
    }

    func testUploadPresentsMeasuredStagingBytesAndNeverRoundsEarlyToOneHundred()
        async throws
    {
        let tunnel = makeTunnel(name: "Devbox", host: "devbox.local")
        let service = StubRemoteFileService()
        service.listings["/srv/app"] = []
        service.waitsForUploadCancellation = true
        service.uploadProgressUpdates = [
            RemoteUploadUpdate(
                phase: .staging,
                completedBytes: 6,
                totalBytes: 7,
                isStagingComplete: false
            )
        ]
        let presenter = StubRemoteFilePresenter()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let localFile = directory.appendingPathComponent("seven.bin")
        try Data("payload".utf8).write(to: localFile)
        presenter.uploadFile = localFile
        let model = RemoteFilesModel(
            tunnels: [tunnel],
            service: service,
            presenter: presenter
        )
        model.remotePath = "/srv/app"
        model.openRemotePath()
        try await waitUntil { model.screen == .browser && !model.isLoading }

        model.beginUpload()
        try await waitUntil { model.upload?.completedBytes == 6 }

        XCTAssertEqual(model.upload?.totalBytes, 7)
        XCTAssertEqual(model.upload?.percentage, 85)
        model.cancelUpload()
        try await waitUntil { model.upload?.phase == .cancelled }
    }

    private func makeTunnel(name: String, host: String) -> Tunnel {
        Tunnel(
            name: name,
            localPort: 8_080,
            destinationHost: "localhost",
            destinationPort: 3_000,
            sshHost: host
        )
    }

    private func makeFileEntry(
        name: String,
        parentPath: String = "/srv/app"
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: "\(parentPath)/\(name)",
            kind: .file,
            size: 128,
            modificationText: "Jul 23 21:04"
        )
    }

    private func makeDirectoryEntry(name: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: "/srv/app/\(name)",
            kind: .directory,
            size: nil,
            modificationText: "Jul 23 21:04"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

final class RemoteFilesWindowSizingTests: XCTestCase {
    func testPreviewGrowsTheDefaultBrowserWindow() {
        XCTAssertEqual(
            RemoteFilesWindowSizing.previewSize(from: RemoteFilesWindowSizing.browser),
            RemoteFilesWindowSizing.previewPreferred
        )
    }

    func testPreviewNeverShrinksAUserResizedWindow() {
        let enlarged = NSSize(width: 1_180, height: 760)
        XCTAssertEqual(
            RemoteFilesWindowSizing.previewSize(from: enlarged),
            enlarged
        )
    }
}

private final class StubRemoteFileService: RemoteFileServing, @unchecked Sendable {
    struct ListRequest {
        let server: RemoteServer
        let path: String
    }

    struct UploadRequest {
        let server: RemoteServer
        let localFile: URL
        let remoteDirectory: String
        let replaceExisting: Bool
    }

    struct DeleteRequest {
        let server: RemoteServer
        let entry: RemoteFileEntry
    }

    private struct State {
        var listings: [String: [RemoteFileEntry]] = [:]
        var pathResults: [String: RemotePathLoadResult] = [:]
        var errors: [String: Error] = [:]
        var suspendedListPaths: Set<String> = []
        var listRequests: [ListRequest] = []
        var loadPathRequests: [ListRequest] = []
        var shutdownCount = 0
        var downloadError: Error?
        var waitsForDownloadCancellation = false
        var downloadDestinations: [URL] = []
        var previewURL: URL?
        var previewURLs: [String: URL] = [:]
        var previewRequests: [String] = []
        var previewProgressUpdates: [Int64]?
        var waitsForPreviewCancellation = false
        var previewError: Error?
        var uploadRequests: [UploadRequest] = []
        var uploadError: Error?
        var waitsForUploadCancellation = false
        var uploadProgressUpdates: [RemoteUploadUpdate]?
        var deleteRequests: [DeleteRequest] = []
        var deleteError: Error?
        var deleteErrors: [String: Error] = [:]
        var deleteReplacement: RemoteFileEntry?
    }

    private let lock = NSLock()
    private var state = State()

    var listings: [String: [RemoteFileEntry]] {
        get { withLock { state.listings } }
        set { withLock { state.listings = newValue } }
    }

    var pathResults: [String: RemotePathLoadResult] {
        get { withLock { state.pathResults } }
        set { withLock { state.pathResults = newValue } }
    }

    var errors: [String: Error] {
        get { withLock { state.errors } }
        set { withLock { state.errors = newValue } }
    }

    var suspendedListPaths: Set<String> {
        get { withLock { state.suspendedListPaths } }
        set { withLock { state.suspendedListPaths = newValue } }
    }

    var listRequests: [ListRequest] {
        withLock { state.listRequests }
    }

    var loadPathRequests: [ListRequest] {
        withLock { state.loadPathRequests }
    }

    var shutdownCount: Int {
        withLock { state.shutdownCount }
    }

    var downloadError: Error? {
        get { withLock { state.downloadError } }
        set { withLock { state.downloadError = newValue } }
    }

    var waitsForDownloadCancellation: Bool {
        get { withLock { state.waitsForDownloadCancellation } }
        set { withLock { state.waitsForDownloadCancellation = newValue } }
    }

    var downloadDestinations: [URL] {
        withLock { state.downloadDestinations }
    }

    let downloadProgressCallbacks = LockedDownloadProgressCallbacks()

    var previewURL: URL? {
        get { withLock { state.previewURL } }
        set { withLock { state.previewURL = newValue } }
    }

    var previewURLs: [String: URL] {
        get { withLock { state.previewURLs } }
        set { withLock { state.previewURLs = newValue } }
    }

    var previewRequests: [String] {
        withLock { state.previewRequests }
    }

    var previewProgressUpdates: [Int64]? {
        get { withLock { state.previewProgressUpdates } }
        set { withLock { state.previewProgressUpdates = newValue } }
    }

    var waitsForPreviewCancellation: Bool {
        get { withLock { state.waitsForPreviewCancellation } }
        set { withLock { state.waitsForPreviewCancellation = newValue } }
    }

    var previewError: Error? {
        get { withLock { state.previewError } }
        set { withLock { state.previewError = newValue } }
    }

    var uploadRequests: [UploadRequest] {
        withLock { state.uploadRequests }
    }

    var uploadError: Error? {
        get { withLock { state.uploadError } }
        set { withLock { state.uploadError = newValue } }
    }

    var waitsForUploadCancellation: Bool {
        get { withLock { state.waitsForUploadCancellation } }
        set { withLock { state.waitsForUploadCancellation = newValue } }
    }

    var uploadProgressUpdates: [RemoteUploadUpdate]? {
        get { withLock { state.uploadProgressUpdates } }
        set { withLock { state.uploadProgressUpdates = newValue } }
    }

    var deleteRequests: [DeleteRequest] {
        withLock { state.deleteRequests }
    }

    var deleteError: Error? {
        get { withLock { state.deleteError } }
        set { withLock { state.deleteError = newValue } }
    }

    var deleteErrors: [String: Error] {
        get { withLock { state.deleteErrors } }
        set { withLock { state.deleteErrors = newValue } }
    }

    var deleteReplacement: RemoteFileEntry? {
        get { withLock { state.deleteReplacement } }
        set { withLock { state.deleteReplacement = newValue } }
    }

    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        let result = withLock {
            state.listRequests.append(ListRequest(server: server, path: path))
            return (
                isSuspended: state.suspendedListPaths.contains(path),
                error: state.errors[path],
                listing: state.listings[path] ?? []
            )
        }
        if result.isSuspended {
            while true {
                try await Task.sleep(for: .seconds(60))
            }
        }
        if let error = result.error {
            throw error
        }
        return result.listing
    }

    func loadPath(server: RemoteServer, path: String) async throws -> RemotePathLoadResult {
        let resolution = withLock {
            state.loadPathRequests.append(ListRequest(server: server, path: path))
            return state.pathResults[path]
        }
        if let resolution {
            return resolution
        }
        return .directory(try await list(server: server, path: path))
    }

    func shutdown() {
        withLock {
            state.shutdownCount += 1
        }
    }

    func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let result = withLock {
            state.downloadDestinations.append(destination)
            return (
                waitsForCancellation: state.waitsForDownloadCancellation,
                error: state.downloadError
            )
        }
        downloadProgressCallbacks.append(progress)
        progress(64)
        if result.waitsForCancellation {
            while true {
                try await Task.sleep(for: .seconds(10))
            }
        }
        if let error = result.error {
            throw error
        }
    }

    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        let result = withLock {
            state.previewRequests.append(entry.id)
            return (
                url: state.previewURLs[entry.id] ?? state.previewURL,
                waitsForCancellation: state.waitsForPreviewCancellation,
                error: state.previewError
            )
        }
        if result.waitsForCancellation {
            while true { try await Task.sleep(for: .seconds(10)) }
        }
        if let error = result.error { throw error }
        guard let previewURL = result.url else {
            throw RemoteFileError.commandFailed("Preview was not expected.")
        }
        return previewURL
    }

    func preparePreviewWithProgress(
        server: RemoteServer,
        entry: RemoteFileEntry,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let result = withLock {
            state.previewRequests.append(entry.id)
            return (
                url: state.previewURLs[entry.id] ?? state.previewURL,
                updates: state.previewProgressUpdates ?? [],
                waitsForCancellation: state.waitsForPreviewCancellation,
                error: state.previewError
            )
        }
        for update in result.updates { progress(update) }
        if result.waitsForCancellation {
            while true { try await Task.sleep(for: .seconds(10)) }
        }
        if let error = result.error { throw error }
        guard let previewURL = result.url else {
            throw RemoteFileError.commandFailed("Preview was not expected.")
        }
        if result.updates.isEmpty {
            let size = Int64(
                (try? previewURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            progress(size)
        }
        return previewURL
    }

    func upload(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        phase: @escaping @Sendable (RemoteUploadPhase) -> Void
    ) async throws {
        let result = withLock {
            state.uploadRequests.append(
                UploadRequest(
                    server: server,
                    localFile: localFile,
                    remoteDirectory: remoteDirectory,
                    replaceExisting: replaceExisting
                )
            )
            return (
                waitsForCancellation: state.waitsForUploadCancellation,
                error: state.uploadError
            )
        }
        phase(.staging)
        if result.waitsForCancellation {
            while true {
                try await Task.sleep(for: .seconds(10))
            }
        }
        if let error = result.error {
            throw error
        }
        phase(.publishing)
    }

    func uploadWithProgress(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        update: @escaping @Sendable (RemoteUploadUpdate) -> Void
    ) async throws {
        if let updates = withLock({ state.uploadProgressUpdates }) {
            let result = withLock {
                state.uploadRequests.append(
                    UploadRequest(
                        server: server,
                        localFile: localFile,
                        remoteDirectory: remoteDirectory,
                        replaceExisting: replaceExisting
                    )
                )
                return (
                    waitsForCancellation: state.waitsForUploadCancellation,
                    error: state.uploadError
                )
            }
            for progressUpdate in updates {
                update(progressUpdate)
            }
            if result.waitsForCancellation {
                while true { try await Task.sleep(for: .seconds(10)) }
            }
            if let error = result.error { throw error }
            return
        }
        let total = Int64(
            (try? localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        try await upload(
            server: server,
            localFile: localFile,
            remoteDirectory: remoteDirectory,
            replaceExisting: replaceExisting
        ) { phase in
            update(
                RemoteUploadUpdate(
                    phase: phase,
                    completedBytes: phase == .staging ? 0 : total,
                    totalBytes: total,
                    isStagingComplete: phase != .staging
                )
            )
        }
    }

    func delete(server: RemoteServer, entry: RemoteFileEntry) async throws {
        let error = withLock {
            state.deleteRequests.append(DeleteRequest(server: server, entry: entry))
            return state.deleteErrors[entry.id] ?? state.deleteError
        }
        if let error { throw error }
        withLock {
            let parent = RemotePath.parent(of: entry.path)
            state.listings[parent]?.removeAll { $0.id == entry.id }
            if let replacement = state.deleteReplacement {
                state.listings[parent]?.append(replacement)
            }
        }
    }

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@MainActor
private final class BlockingMarkdownDecoder {
    private(set) var hasStarted = false

    func load(contentsOf url: URL) async throws -> RemoteMarkdownDocument {
        hasStarted = true
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

@MainActor
private final class StubRemoteFilePresenter: RemoteFilePresenting {
    var destination: URL?
    var chooseCount = 0
    var revealedDestinations: [URL] = []
    var uploadFile: URL?
    var replacementConfirmation = false
    var replacementNames: [String] = []

    func chooseDestination(for entry: RemoteFileEntry) -> URL? {
        chooseCount += 1
        return destination
    }

    func chooseUploadFile() -> URL? {
        uploadFile
    }

    func confirmUploadReplacement(name: String) -> Bool {
        replacementNames.append(name)
        return replacementConfirmation
    }

    func revealInFinder(_ destination: URL) {
        revealedDestinations.append(destination)
    }
}

private final class LockedDownloadProgressCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Int64) -> Void] = []

    func append(_ callback: @escaping @Sendable (Int64) -> Void) {
        lock.lock()
        callbacks.append(callback)
        lock.unlock()
    }

    func send(value: Int64, at index: Int) {
        lock.lock()
        let callback = callbacks.indices.contains(index) ? callbacks[index] : nil
        lock.unlock()
        callback?(value)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callbacks.count
    }
}

private final class LockedSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Int32] = []

    func send(processIdentifier: pid_t, signal: Int32) -> Int32 {
        lock.lock()
        recordedValues.append(signal)
        lock.unlock()
        return Darwin.kill(processIdentifier, signal)
    }

    var values: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}

private final class LockedCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var observedCancellation = false

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func recordWorkerCancellation(_ wasCancelled: Bool) {
        lock.lock()
        observedCancellation = wasCancelled
        lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var workerObservedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedCancellation
    }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func record(_ value: Int64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var maximum: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return values.max() ?? 0
    }
}

private final class LockedUploadPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RemoteUploadPhase] = []

    func record(_ phase: RemoteUploadPhase) {
        lock.lock()
        recorded.append(phase)
        lock.unlock()
    }

    var values: [RemoteUploadPhase] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class LockedUploadUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RemoteUploadUpdate] = []

    func record(_ update: RemoteUploadUpdate) {
        lock.lock()
        recorded.append(update)
        lock.unlock()
    }

    var values: [RemoteUploadUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class LockedThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var wasMainThread = true

    func recordDecode(isMainThread: Bool) {
        lock.lock()
        wasMainThread = isMainThread
        lock.unlock()
    }

    var decodedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasMainThread
    }
}

private var validPNGData: Data {
    Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RelayBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private extension Array where Element == String {
    func containsSubsequence(_ subsequence: [String]) -> Bool {
        guard !subsequence.isEmpty, count >= subsequence.count else { return false }
        for start in 0...(count - subsequence.count) {
            if Array(self[start..<(start + subsequence.count)]) == subsequence {
                return true
            }
        }
        return false
    }
}
