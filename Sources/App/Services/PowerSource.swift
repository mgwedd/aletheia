import Foundation
import IOKit.ps

/// Whether this Mac is running on battery or in Low Power Mode, for work that
/// can wait (background summaries). Read-only system state; nothing is sent anywhere.
enum PowerSource {
    /// True on battery power. False on AC, on a desktop Mac, or if the system
    /// can't say (the work then runs, as it would on AC).
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
