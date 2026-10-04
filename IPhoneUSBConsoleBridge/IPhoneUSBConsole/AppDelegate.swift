import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configuration = ConsoleConfiguration.load()
    private var driver: IPhoneUSBDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The signed app bundle remains the TCC/Keychain identity, but its
        // production process is a pure background driver. It never creates an
        // NSWindow, MainViewController, menu, password field, or Dock item.
        NSApp.setActivationPolicy(.prohibited)
        let driver = IPhoneUSBDriver(configuration: configuration)
        self.driver = driver
        driver.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        driver?.shutdown()
        driver = nil
    }
}
