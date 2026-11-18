import Foundation

// Compiled only by the isolated bridge verification script, not the app target.
@main struct BridgeProof {
  static func main() async {
    do {
      let socket = try FrameBridgeEnvironment.root().appendingPathComponent("proof.sock")
      if CommandLine.arguments.contains("server") {
        let server = try BridgeSocketServer(url: socket) { request, _ in
          var response = BridgeResponse()
          response.status = request.operation == "proof" ? "verified" : "unexpected"
          return response
        }
        print("READY"); fflush(stdout)
        try await Task.sleep(for: .seconds(55))
        withExtendedLifetime(server) {}
      } else {
        let channel = BridgeChannel(socketURL: socket)
        let response = try await channel.exchange(BridgeRequest("proof")).checked()
        channel.close()
        print("RESULT \(response.status)")
      }
    } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
  }
}
