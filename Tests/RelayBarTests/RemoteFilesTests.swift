import AppKit
import Darwin
import XCTest
@testable import RelayBar

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

    func testTreatsNumericPadReturnAsUnmodified() {
        XCTAssertTrue(RemoteFilesKeyboardShortcut.isUnmodified([.numericPad]))
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
    func testConfiguredRemoteFolderWhenLiveTestingIsEnabled() async throws {
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
        let server = RemoteServer(
            id: UUID(),
            name: "Live",
            sshHost: sshHost,
            additionalArguments: []
        )

        let entries = try await service.list(server: server, path: remotePath)
        if environment["RELAYBAR_LIVE_REMOTE_EXPECT_NONEMPTY"] == "1" {
            XCTAssertFalse(
                entries.isEmpty,
                "Expected the configured live folder to contain at least one entry."
            )
        }
    }

    func testReportsACommandFailureWithoutInvokingAShell() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/usr/bin/false")
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

    func testRejectsProcessOutputBeyondTheConfiguredLimit() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            standardOutputLimit: 1
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
            previewSizeLimit: 1
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

    func testRejectsOversizedMarkdownWithItsSpecificLimit() async {
        let service = SFTPRemoteFileService(
            executableURL: URL(fileURLWithPath: "/path/that/does/not/exist"),
            markdownPreviewSizeLimit: 1
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
        SFTPRemoteFileService(executableURL: fixtureExecutableURL)
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

    private func partialItems(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(".relaybar-") }
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
}

@MainActor
final class RemoteFilesModelTests: XCTestCase {
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

    func testOpensNavigatesAndReturnsToLauncher() async throws {
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
        XCTAssertEqual(model.screen, .launcher)
        XCTAssertEqual(model.remotePath, "/srv/app")
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

    func testFailedBackNavigationKeepsHistoryForRetry() async throws {
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
        try await waitUntil { model.errorMessage == "Connection lost." && !model.isLoading }
        XCTAssertEqual(model.currentPath, "/srv/app/output")

        service.errors["/srv/app"] = nil
        model.retryLastLoad()
        try await waitUntil { model.currentPath == "/srv/app" && !model.isLoading }
        model.goBack()

        XCTAssertEqual(model.screen, .launcher)
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

private final class StubRemoteFileService: RemoteFileServing, @unchecked Sendable {
    struct ListRequest {
        let server: RemoteServer
        let path: String
    }

    var listings: [String: [RemoteFileEntry]] = [:]
    var errors: [String: Error] = [:]
    var listRequests: [ListRequest] = []
    var downloadError: Error?
    var waitsForDownloadCancellation = false
    var downloadDestinations: [URL] = []
    let downloadProgressCallbacks = LockedDownloadProgressCallbacks()
    var previewURL: URL?

    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        listRequests.append(ListRequest(server: server, path: path))
        if let error = errors[path] {
            throw error
        }
        return listings[path] ?? []
    }

    func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        downloadDestinations.append(destination)
        downloadProgressCallbacks.append(progress)
        progress(64)
        if waitsForDownloadCancellation {
            while true {
                try await Task.sleep(for: .seconds(10))
            }
        }
        if let downloadError {
            throw downloadError
        }
    }

    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        guard let previewURL else {
            throw RemoteFileError.commandFailed("Preview was not expected.")
        }
        return previewURL
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

    func chooseDestination(for entry: RemoteFileEntry) -> URL? {
        chooseCount += 1
        return destination
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
