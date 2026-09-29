import SwiftUI

@main
struct APKRunApp: App {
    var body: some Scene {
        WindowGroup("APKRun") {
            Text("APKRun")
                .frame(minWidth: 480, minHeight: 320)
        }
        .windowResizability(.contentSize)
    }
}
