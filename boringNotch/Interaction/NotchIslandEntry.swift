import Darwin
import SwiftUI

/// Bluetooth compatibility calls may stop responding inside the system library.
/// A narrowly scoped child mode gives the UI a real process timeout without
/// constructing the application's scenes, timers, capture tools or delegates.
@main
struct NotchIslandEntry {
    @MainActor
    static func main() {
        if let status = BluetoothPowerHelper.runIfRequested() {
            exit(status)
        }
        DynamicNotchApp.main()
    }
}
