import AppKit
import Composition
import Foundation

@MainActor
final class TunnelStore: ObservableObject {
    static let retryLimitRange = 0...100
    private static let retryLimitKey = "sshRetryLimit.v1"

    @Published private(set) var tunnels: [Tunnel] {
        didSet { cachedGrouping = nil }
    }
    private var cachedGrouping: TunnelGrouping?
    @Published private(set) var phases: [UUID: TunnelPhase] = [:]
    @Published private(set) var runtimePorts: [UUID: [UUID: Int]] = [:]
    @Published private(set) var terminatingSSHProcessCount = 0
    @Published private(set) var maxRetryAttempts: Int

    private let defaults: UserDefaults
    private let sshExecutableURL: URL
    private let retryDelayProvider: (Int) -> TimeInterval
    private let monotonicNow: () -> TimeInterval
    private let browserOpener: (URL) -> Void
    private let persistsRetryLimit: Bool
    private let processEnvironment: [String: String]?
    private let controlOperationTimeout: TimeInterval
    private let processTerminationGracePeriod: TimeInterval
    private let storageKey = "savedTunnels.v2"
    private let legacyStorageKey = "savedTunnels.v1"
    private var profiles: [UUID: TunnelProfileRuntime] = [:]
    private var retiringProfiles: [ObjectIdentifier: TunnelProfileRuntime] = [:]
    private var profileTokens: [UUID: UUID] = [:]
    private let ownership = EffectScope()
    private let retirements = EffectScope()
    private var isClosed = false

    init(
        defaults: UserDefaults = .standard,
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        maxRetryAttempts: Int? = nil,
        retryDelayProvider: @escaping (Int) -> TimeInterval = TunnelStore.retryDelay(for:),
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        browserOpener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        processEnvironment: [String: String]? = nil,
        controlOperationTimeout: TimeInterval = 10,
        processTerminationGracePeriod: TimeInterval = 5,
        persistsRetryLimit: Bool = true
    ) {
        self.defaults = defaults
        self.sshExecutableURL = sshExecutableURL
        // A composed app keeps the limit in its preference document and passes it in.
        let retryLimit = maxRetryAttempts
            ?? (persistsRetryLimit ? defaults.object(forKey: Self.retryLimitKey) as? Int : nil)
            ?? 10
        self.persistsRetryLimit = persistsRetryLimit
        self.maxRetryAttempts = min(max(0, retryLimit), Self.retryLimitRange.upperBound)
        self.retryDelayProvider = retryDelayProvider
        self.monotonicNow = monotonicNow
        self.browserOpener = browserOpener
        self.processEnvironment = processEnvironment
        self.controlOperationTimeout = max(0.1, controlOperationTimeout)
        self.processTerminationGracePeriod = max(0.1, processTerminationGracePeriod)

        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode([Tunnel].self, from: data)
        {
            tunnels = saved
        } else if
            let data = defaults.data(forKey: legacyStorageKey),
            let migrated = try? JSONDecoder().decode([Tunnel].self, from: data),
            let encoded = try? JSONEncoder().encode(migrated)
        {
            tunnels = migrated
            defaults.set(encoded, forKey: storageKey)
        } else {
            tunnels = []
        }
    }

    var runningCount: Int {
        phases.values.count(where: \.isLifecycleActive)
    }

    /// Rebuilt only when `tunnels` changes. Views evaluate their bodies on every
    /// phase publish, so deriving sections per evaluation would repeat the
    /// bucketing and localized sort on every retry tick.
    var grouping: TunnelGrouping {
        if let cachedGrouping { return cachedGrouping }
        let grouping = TunnelGrouping(tunnels: tunnels)
        cachedGrouping = grouping
        return grouping
    }

    var groupNames: [String] {
        grouping.groupNames
    }

    func phase(for tunnel: Tunnel) -> TunnelPhase {
        phases[tunnel.id] ?? .stopped
    }

#if DEBUG
    /// Gives deterministic previews and snapshot tests lifecycle state without
    /// creating an SSH process. Production builds cannot call this seam.
    func setPreviewPhase(_ phase: TunnelPhase, for tunnel: Tunnel) {
        guard tunnels.contains(where: { $0.id == tunnel.id }) else { return }
        phases[tunnel.id] = phase
    }
#endif

    func runtimePorts(for tunnel: Tunnel) -> [UUID: Int] {
        runtimePorts[tunnel.id] ?? [:]
    }

    func add(_ tunnel: Tunnel) {
        guard !isClosed, let tunnel = resolvingGroupTag(in: tunnel),
              !tunnels.contains(where: { $0.id == tunnel.id }) else { return }
        tunnels.append(tunnel)
        save()
    }

    func update(_ tunnel: Tunnel) {
        guard
            !isClosed,
            let index = tunnels.firstIndex(where: { $0.id == tunnel.id }),
            let tunnel = resolvingGroupTag(in: tunnel)
        else {
            return
        }
        let previous = tunnels[index]
        if previous.hasSameNonTagFields(as: tunnel) {
            applyGroupTag(tunnel.groupTag, at: index)
            return
        }

        let wasActive = profiles[tunnel.id]?.isRequested == true
        if wasActive { stop(tunnel) }
        retireProfile(tunnel.id)
        tunnels[index] = tunnel
        phases[tunnel.id] = .stopped
        save()
    }

    func move(_ tunnel: Tunnel, toGroup rawGroup: String?) {
        guard !isClosed, let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
            return
        }
        let groupTag: String?
        if let rawGroup {
            guard
                case .valid(let resolved) = TunnelGroupTag.resolve(
                    rawGroup,
                    existingNames: groupNames
                )
            else {
                return
            }
            groupTag = resolved
        } else {
            groupTag = nil
        }
        applyGroupTag(groupTag, at: index)
    }

    func renameGroup(_ groupName: String, to rawGroup: String) {
        guard !isClosed else { return }
        let sourceKey = TunnelGroupTag.canonicalKey(groupName)
        guard
            case .valid(let resolved) = TunnelGroupTag.resolve(
                rawGroup,
                existingNames: groupNames
            )
        else {
            return
        }

        var changed = false
        for index in tunnels.indices where tunnels[index].groupTag.map(
            TunnelGroupTag.canonicalKey
        ) == sourceKey {
            guard tunnels[index].groupTag != resolved else { continue }
            tunnels[index].groupTag = resolved
            changed = true
        }
        if changed { save() }
    }

    func ungroup(_ groupName: String) {
        guard !isClosed else { return }
        let key = TunnelGroupTag.canonicalKey(groupName)
        var changed = false
        for index in tunnels.indices where tunnels[index].groupTag.map(
            TunnelGroupTag.canonicalKey
        ) == key {
            tunnels[index].groupTag = nil
            changed = true
        }
        if changed { save() }
    }

    func delete(_ tunnel: Tunnel) {
        guard !isClosed else { return }
        stop(tunnel)
        tunnels.removeAll { $0.id == tunnel.id }
        retireProfile(tunnel.id)
        phases[tunnel.id] = nil
        runtimePorts[tunnel.id] = nil
        save()
    }

    func toggle(_ tunnel: Tunnel) {
        if profiles[tunnel.id]?.isRequested == true {
            stop(tunnel)
        } else {
            start(tunnel)
        }
    }

    func start(_ tunnel: Tunnel) {
        guard !isClosed else { return }
        profile(for: tunnel.id).start(tunnel)
    }

    func openInBrowser(_ tunnel: Tunnel) {
        guard !isClosed else { return }
        profile(for: tunnel.id).openInBrowser(tunnel)
    }

    func openInBrowser(_ tunnel: Tunnel, ruleID: UUID) {
        guard !isClosed else { return }
        profile(for: tunnel.id).openInBrowser(tunnel, ruleID: ruleID)
    }

    func stop(_ tunnel: Tunnel) { profiles[tunnel.id]?.stop() }

    func stopAll() {
        for profile in profiles.values where profile.isRequested || profile.hasManagedResources {
            profile.stop()
        }
    }

    /// Closes command admission at once. The owner calls this on withdrawal, before the awaited `shutdown`.
    func closeAdmission() {
        guard !isClosed else { return }
        isClosed = true
        stopAll()
    }

    func shutdown() async {
        isClosed = true
        stopAll()
        await retirements.dispose()
        await ownership.dispose()
    }

    // A group command snapshots membership and applies to its profiles in one
    // main-actor turn; moving group membership never restarts a running profile.

    func startGroup(_ groupName: String) {
        for tunnel in savedMembers(ofGroup: groupName)
        where profiles[tunnel.id]?.isRequested != true {
            start(tunnel)
        }
    }

    func stopGroup(_ groupName: String) {
        // Restricted to lifecycle-active members so a stopped or failed
        // peer keeps its phase and failure message untouched.
        for tunnel in savedMembers(ofGroup: groupName)
        where profiles[tunnel.id]?.isRequested == true {
            stop(tunnel)
        }
    }

    func restartGroup(_ groupName: String) {
        let activeMembers = savedMembers(ofGroup: groupName).filter {
            profiles[$0.id]?.isRequested == true
        }
        for tunnel in activeMembers {
            stop(tunnel)
        }
        for tunnel in activeMembers {
            start(tunnel)
        }
    }

    func quit() {
        stopAll()
        NSApplication.shared.terminate(nil)
    }

    /// Makes every scheduled retry now. Reconnect on Wake calls this when the Mac wakes or the network returns.
    func retryWaitingNow() {
        guard !isClosed else { return }
        for profile in profiles.values {
            profile.retryNow()
        }
    }

    func setMaxRetryAttempts(_ limit: Int) {
        guard !isClosed else { return }
        let next = min(max(0, limit), Self.retryLimitRange.upperBound)
        if persistsRetryLimit { defaults.set(next, forKey: Self.retryLimitKey) }
        guard next != maxRetryAttempts else { return }
        maxRetryAttempts = next
        for profile in profiles.values { profile.setMaxRetryAttempts(maxRetryAttempts) }
    }

    nonisolated static func retryDelay(for attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt, 1), 7) - 1
        return min(5 * pow(2, Double(exponent)), 300)
    }

    private func profile(for id: UUID) -> TunnelProfileRuntime {
        if let profile = profiles[id] { return profile }
        let profile = TunnelProfileRuntime(id: id, sshExecutableURL: sshExecutableURL,
            maxRetryAttempts: maxRetryAttempts, retryDelayProvider: retryDelayProvider,
            monotonicNow: monotonicNow, browserOpener: { [weak self] url in
                guard let self, !isClosed else { return }
                browserOpener(url)
            },
            processEnvironment: processEnvironment, controlOperationTimeout: controlOperationTimeout,
            processTerminationGracePeriod: processTerminationGracePeriod)
        profiles[id] = profile
        profile.didChange = { [weak self, weak profile] in
            guard let self, let profile else { return }
            if profiles[profile.id] === profile {
                if phases[profile.id] != profile.phase { phases[profile.id] = profile.phase }
                let ports = profile.runtimePorts.isEmpty ? nil : profile.runtimePorts
                if runtimePorts[profile.id] != ports { runtimePorts[profile.id] = ports }
            }
            refreshRetirementCount()
        }
        profileTokens[id] = try? ownership.own { await profile.shutdown() }
        return profile
    }

    private func retireProfile(_ id: UUID) {
        guard let profile = profiles.removeValue(forKey: id), let token = profileTokens.removeValue(forKey: id) else { return }
        let identity = ObjectIdentifier(profile)
        retiringProfiles[identity] = profile
        if !tunnels.contains(where: { $0.id == id }) { phases[id] = nil }
        else if phases[id]?.isLifecycleActive == true { phases[id] = .stopped }
        runtimePorts[id] = nil
        profile.invalidate()
        _ = try? retirements.task { [weak self] in
            guard let self else { return }
            await ownership.release(token)
            retiringProfiles.removeValue(forKey: identity)
            refreshRetirementCount()
        }
    }

    private func refreshRetirementCount() {
        let count = profiles.values.reduce(0) { $0 + $1.terminatingSSHProcessCount }
            + retiringProfiles.values.reduce(0) { $0 + $1.terminatingSSHProcessCount }
        if terminatingSSHProcessCount != count { terminatingSSHProcessCount = count }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Current saved profiles whose tags share the requested group's
    /// canonical identity, tolerating case and harmless whitespace
    /// differences in both the request and the stored tags.
    private func savedMembers(ofGroup groupName: String) -> [Tunnel] {
        guard
            case .valid(let normalized) = TunnelGroupTag.validate(groupName)
        else {
            return []
        }
        let key = TunnelGroupTag.canonicalKey(normalized)
        return tunnels.filter {
            $0.groupTag.map(TunnelGroupTag.canonicalKey) == key
        }
    }

    private func resolvingGroupTag(in tunnel: Tunnel) -> Tunnel? {
        var resolvedTunnel = tunnel
        guard let groupTag = tunnel.groupTag else { return resolvedTunnel }
        guard
            case .valid(let resolved) = TunnelGroupTag.resolve(
                groupTag,
                existingNames: groupNames
            )
        else {
            return nil
        }
        resolvedTunnel.groupTag = resolved
        return resolvedTunnel
    }

    private func applyGroupTag(_ groupTag: String?, at index: Int) {
        guard tunnels[index].groupTag != groupTag else { return }
        tunnels[index].groupTag = groupTag
        save()
    }
}
