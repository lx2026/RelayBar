import MobileUI
import SwiftUI

@main
struct RelayBarMobileApp: App {
    @StateObject private var application = MobileApplication()
    var body: some Scene {
        WindowGroup { MobileScreen(application: application) }
    }
}
