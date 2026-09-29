import AppKit
import SwiftUI

@main
struct APKRunMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("APKRun", systemImage: "command") {
            Button("Quit APKRun") {
                NSApp.terminate(nil)
            }
        }
    }
}
