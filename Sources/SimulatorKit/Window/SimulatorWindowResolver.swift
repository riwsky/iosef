import Foundation
import CoreGraphics

/// Resolves a specific simulator window by UDID or device name for multi-simulator support.
public enum SimulatorWindowResolver {

    /// Finds the CGWindowID for a simulator window, optionally matching by device name.
    public static func findWindowID(deviceName: String? = nil) -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Simulator",
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            // If a device name is specified, try to match window title
            if let deviceName = deviceName {
                if let windowName = window[kCGWindowName as String] as? String,
                   windowName.contains(deviceName) {
                    return windowID
                }
            } else {
                // No filter, return the first simulator window
                return windowID
            }
        }

        // If device name was specified but no match found, return first simulator window
        if deviceName != nil {
            return findWindowID(deviceName: nil)
        }

        return nil
    }
}
