import Composition
import CryptoKit
import Foundation
import LocalAuthentication
import Security

package enum DeviceKey: Sendable {
  case enclave(SecureEnclave.P256.Signing.PrivateKey)
  case memory(P256.Signing.PrivateKey)

  package var authorizedKey: String {
    let point: Data
    switch self {
    case .enclave(let key): point = key.publicKey.x963Representation
    case .memory(let key): point = key.publicKey.x963Representation
    }
    let algorithm = "ecdsa-sha2-nistp256"
    var bytes = Data()
    for field in [Data(algorithm.utf8), Data("nistp256".utf8), point] {
      var size = UInt32(field.count).bigEndian
      withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }
      bytes.append(field)
    }
    return algorithm + " " + bytes.base64EncodedString()
  }
}

package protocol KeyProvider: Sendable {
  func existingKey() async throws -> DeviceKey?
  func key() async throws -> DeviceKey
}

enum KeychainReadError: LocalizedError {
  case locked
  var errorDescription: String? { "Unlock the device and retry to access the Keychain." }
}

struct Keychain {
  static func query(_ name: String) -> [CFString: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass: kSecClassGenericPassword, kSecAttrService: "com.lx2026.RelayBar.ios",
      kSecAttrAccount: name, kSecUseAuthenticationContext: context,
    ]
  }

  static func read(_ name: String) throws -> Data? {
    var query = query(name)
    query[kSecReturnData] = true
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecInteractionNotAllowed { throw KeychainReadError.locked }
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else {
      throw CompositionError("Could not read the device keychain.")
    }
    return data
  }

  static func remove(_ name: String) throws {
    let status = SecItemDelete(query(name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CompositionError("Could not remove the saved password.")
    }
  }

  static func save(_ data: Data, as name: String) throws {
    var item = query(name)
    item.removeValue(forKey: kSecUseAuthenticationContext)
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecDuplicateItem {
      guard
        SecItemUpdate(query(name) as CFDictionary, [kSecValueData: data] as CFDictionary)
          == errSecSuccess
      else {
        throw CompositionError("Could not update the device keychain.")
      }
    } else if status != errSecSuccess {
      throw CompositionError("Could not save to the device keychain.")
    }
  }
}

package actor EnclaveKeys: KeyProvider {
  private let name = "device-signing-key"
  private let read: @Sendable (String) throws -> Data?
  package init() { read = Keychain.read }
  init(read: @escaping @Sendable (String) throws -> Data?) { self.read = read }
  package func existingKey() throws -> DeviceKey? {
    guard let data = try read(name) else { return nil }
    return try .enclave(.init(dataRepresentation: data))
  }
  package func key() throws -> DeviceKey {
    if let existing = try existingKey() { return existing }
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .privateKeyUsage, nil)
    else {
      throw CompositionError("Could not set device key access.")
    }
    let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
    try Keychain.save(key.dataRepresentation, as: name)
    return .enclave(key)
  }
}

@MainActor package final class SignIn: ObservableObject {
  package enum Prompt: Equatable {
    case trust(Identity)
    case password
  }
  @Published package private(set) var prompt: Prompt?
  @Published package private(set) var status = "Connecting…"
  private let profiles: () -> [Profile]
  private(set) var failureReason: String?
  private let profile: Profile
  private let pins: PreferenceStore<[String: Identity]>
  private enum Request {
    case trust(Identity, CheckedContinuation<Bool, Never>)
    case password(CheckedContinuation<String?, Never>)
  }
  private var queue: [Request] = []
  private func advance() {
    while let first = queue.first {
      switch first {
      case .trust(let key, let answer):
        if let result = decision(key) {
          queue.removeFirst()
          answer.resume(returning: result)
          continue
        }
        prompt = .trust(key)
      case .password: prompt = .password
      }
      return
    }
    prompt = nil
  }
  private var closed = false
  private var usedSavedPassword = false
  private var passwordToSave: String?
  private let savedPassword: (String) throws -> Data?
  init(
    _ profile: Profile, _ pins: PreferenceStore<[String: Identity]>,
    profiles: @escaping () -> [Profile] = { [] },
    savedPassword: @escaping (String) throws -> Data? = Keychain.read
  ) {
    self.profiles = profiles
    self.savedPassword = savedPassword
    self.profile = profile
    self.pins = pins
  }

  var pinned: Identity? { pins.value[profile.id.uuidString] }
  // Recheck on approval too. Another scene may have pinned this endpoint while the sheet was open.
  private func decision(_ identity: Identity) -> Bool? {
    let host = profile.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let peers = profiles().filter {
      $0.id != profile.id && $0.port == profile.port
        && $0.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
        && pins.value[$0.id.uuidString] != nil
    }
    if let other = peers.first(where: { pins.value[$0.id.uuidString] != identity }) {
      failureReason = "Host key conflicts with the saved profile " + other.account + "@" + other.host
        + ":" + String(other.port) + ". Check the server key before retrying."
      return false
    }
    if let pinned {
      if pinned != identity { failureReason = "The host key has changed. Connection blocked." }
      return pinned == identity
    }
    guard !peers.isEmpty else { return nil }
    do { try pins.update { $0[profile.id.uuidString] = identity } } catch {
      failureReason = "Could not save the verified host key."
      return false
    }
    return true
  }
  func verify(_ identity: Identity) async -> Bool {
    guard !closed else { return false }
    if let decision = decision(identity) { return decision }
    return await withCheckedContinuation {
      queue.append(.trust(identity, $0))
      advance()
    }
  }

  package func pinForNewMethod() throws {
    guard case .trust(let identity) = prompt else {
      throw CompositionError("The trust request has ended.")
    }
    guard decision(identity) != false else {
      advance()
      throw CompositionError(failureReason ?? "Host key conflict.")
    }
    try pins.update { $0[profile.id.uuidString] = identity }
  }

  package func trust() throws {
    guard case .trust(let identity, let answer) = queue.first else { return }
    guard decision(identity) != false else { advance(); return }
    try pins.update { $0[profile.id.uuidString] = identity }
    queue.removeFirst()
    answer.resume(returning: true)
    advance()
  }

  func signingKey(_ provider: any KeyProvider) async throws -> DeviceKey {
    do { return try await provider.key() } catch let error as KeychainReadError {
      failureReason = error.localizedDescription
      throw error
    }
  }

  func password() async throws -> String {
    do { return try await readPassword() } catch let error as KeychainReadError {
      failureReason = error.localizedDescription
      throw error
    }
  }

  private func readPassword() async throws -> String {
    guard !closed else { throw CancellationError() }
    if !usedSavedPassword, let data = try savedPassword(profile.id.uuidString),
      let saved = String(data: data, encoding: .utf8)
    {
      usedSavedPassword = true
      return saved
    }
    guard
      let result = await withCheckedContinuation({
        queue.append(.password($0))
        advance()
      })
    else { throw CancellationError() }
    return result
  }

  package func submit(_ password: String, remember: Bool) throws {
    guard case .password(let answer) = queue.first else { return }
    passwordToSave = remember ? password : nil
    queue.removeFirst()
    answer.resume(returning: password)
    advance()
  }

  func connected() {
    usedSavedPassword = false
    status = "Connected"
    if let passwordToSave {
      do { try Keychain.save(Data(passwordToSave.utf8), as: profile.id.uuidString) } catch {
        status = "Connected. Could not save the password."
      }
    }
    passwordToSave = nil
  }

  func failed(_ message: String, passwordRefused: Bool) {
    if passwordRefused && usedSavedPassword { try? Keychain.remove(profile.id.uuidString) }
    cancel()
    status = message
  }

  func update(_ status: String) { self.status = status }
  func cancel() {
    passwordToSave = nil
    closed = true
    prompt = nil
    for request in queue {
      switch request {
      case .trust(_, let answer): answer.resume(returning: false)
      case .password(let answer): answer.resume(returning: nil)
      }
    }
    queue.removeAll()
  }
}
