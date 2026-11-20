public enum ConnectionFailure: CaseIterable, Sendable {
  case hostKeyChanged, hostKeyNotTrusted, signInRefused, hostNotFound
  case connectionRefused, timedOut, connectionLost

  public var wording: (title: String, recovery: String) {
    switch self {
    case .hostKeyChanged:
      ("The host key has changed.", "Verify the new fingerprint with the server administrator before reconnecting.")
    case .hostKeyNotTrusted:
      ("The host key was not trusted.", "Verify the server fingerprint and trust the key before reconnecting.")
    case .signInRefused:
      ("The server refused sign-in.", "Check the account and its SSH credentials, then reconnect.")
    case .hostNotFound:
      ("The host could not be found.", "Check the host address and network connection, then retry.")
    case .connectionRefused:
      ("The server refused the connection.", "Check that the service is running on the selected port, then retry.")
    case .timedOut:
      ("The connection timed out.", "Check the network and that the server is reachable, then retry.")
    case .connectionLost:
      ("The connection was lost.", "Check the network connection, then reconnect.")
    }
  }

  public var message: String { wording.title + "\n" + wording.recovery }
}
