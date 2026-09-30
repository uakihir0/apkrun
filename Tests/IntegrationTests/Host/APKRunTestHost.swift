import AppKit

@main
enum APKRunTestHost {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.run()
    }
}
