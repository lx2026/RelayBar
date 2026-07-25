// Measures the performance claims this branch acted on. Each case runs the old
// shape and the new one in the same process so the comparison is direct.
// Skipped unless RELAYBAR_BENCH is set; it prints numbers rather than asserting
// timings, which would be flaky on shared hardware.
import CryptoKit
import Foundation
import XCTest
@testable import RelayBar

final class PerformanceClaimTests: XCTestCase {
    private func skipUnlessBenchmarking() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RELAYBAR_BENCH"] == nil,
            "Set RELAYBAR_BENCH=1 to measure."
        )
    }

    private func measure(_ label: String, iterations: Int, _ body: () -> Void) -> Double {
        body() // warm up
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
        let perCall = elapsed / Double(iterations) / 1_000
        print(String(format: "  %-34s %10.3f us/call", (label as NSString).utf8String!, perCall))
        return perCall
    }

    /// Task 012 assumed a digest would beat interpolating the code into the key.
    /// It does not: a digest must read every byte, while NSString bridging is
    /// lazy and NSCache does not hash the whole string. This is why that task
    /// was withdrawn; the case is kept so the conclusion stays checkable.
    func testHighlightCacheKeyCost() throws {
        try skipUnlessBenchmarking()
        let cache = NSCache<NSString, NSNumber>()
        for size in [1_024, 16 * 1_024, 64 * 1_024] {
            let code = String(repeating: "let x = 1\n", count: size / 10)
            print("code \(code.utf8.count) bytes")
            let old = measure("old: interpolated key", iterations: 2_000) {
                let key = "dark|swift|\(code)" as NSString
                _ = cache.object(forKey: key)
            }
            let new = measure("rejected: sha256 digest key", iterations: 2_000) {
                var hasher = SHA256()
                hasher.update(data: Data("dark".utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data("swift".utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data(code.utf8))
                let digest = hasher.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
                _ = cache.object(forKey: digest as NSString)
            }
            print(String(format: "  -> new is %.2fx the old cost\n", new / old))
        }
    }

    /// Task 010: compiling the expression per call versus once.
    func testPermitRemoteOpenValidationCost() throws {
        try skipUnlessBenchmarking()
        let pattern = #"^(\*|[^:\s]+|\[[^\]]+\]):(\*|[0-9]+)$"#
        let value = "api.example.com:443"
        let old = measure("old: compile per call", iterations: 20_000) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            _ = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            )
        }
        let new = measure("new: static expression", iterations: 20_000) {
            _ = SSHArgumentPolicy.isValidPermitRemoteOpenDestination(value)
        }
        print(String(format: "  -> new is %.2fx the old cost\n", new / old))
    }

    /// Task 009: deriving sections per view evaluation versus once per change.
    func testGroupingDerivationCost() throws {
        try skipUnlessBenchmarking()
        var tunnels: [Tunnel] = []
        for index in 0..<24 {
            tunnels.append(
                Tunnel(
                    name: "Profile \(index)",
                    localPort: 8_000 + index,
                    destinationHost: "localhost",
                    destinationPort: 3_000 + index,
                    sshHost: "host-\(index).example.com",
                    groupTag: ["Work", "Personal", "Research", "Ops"][index % 4]
                )
            )
        }
        let sectionCount = TunnelGrouping(tunnels: tunnels).sections.count
        print("24 profiles across \(sectionCount) sections")
        _ = measure("one derivation", iterations: 5_000) {
            _ = TunnelGrouping(tunnels: tunnels)
        }
        _ = measure("old: 1 + per-section rebuilds", iterations: 5_000) {
            let grouping = TunnelGrouping(tunnels: tunnels)
            for _ in grouping.sections { _ = TunnelGrouping(tunnels: tunnels).groupNames }
        }
        print("")
    }

    /// Task 013: what a `Task.isCancelled` check costs per character, and what
    /// a full render of a large document costs overall.
    func testMarkdownScannerCosts() throws {
        try skipUnlessBenchmarking()
        let iterations = 1_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<iterations where Task.isCancelled { sink += 1 }
        let perCheck = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations)
        print(String(format: "  Task.isCancelled            %10.3f ns/check (sink %d)", perCheck, sink))

        let document = String(
            repeating: """
            # Heading

            Body text with **bold**, `code`, a [link](https://example.com), and ==highlight==.
            Some ==marked== text with [[wiki]] links and a #tag plus $x^2$ math.

            - [ ] task one
            - [x] task two

            """,
            count: 4_000
        )
        print("  document \(document.utf8.count) bytes")
        _ = measure("renderSource (full pipeline)", iterations: 3) {
            _ = ObsidianMarkdownCompatibility.renderSource(document)
        }
        print("")
    }

    /// Task 011: the cost of one progress poll as the partial tree grows.
    func testDirectoryWalkCost() throws {
        try skipUnlessBenchmarking()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayBarBench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for count in [100, 1_000, 5_000] {
            let directory = root.appendingPathComponent("n\(count)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for index in 0..<count {
                try Data("x".utf8).write(
                    to: directory.appendingPathComponent("file-\(index).bin")
                )
            }
            let service = SFTPRemoteFileService()
            let perPoll = measure("walk \(count) files", iterations: 20) {
                _ = service.benchmarkMeasureLocal(directory)
            }
            let interval = SFTPRemoteFileService.progressPollingInterval(
                forEntryCount: count,
                isDirectory: true
            )
            print("     interval at \(count) entries: \(interval), poll cost \(Int(perPoll)) us")
        }
        print("")
    }
}
