import Foundation
import ApplicationServices
import AppKit

/// Finds and interacts with the iOS Simulator process.
public enum SimulatorFinder {
    private static let simulatorBundleID = "com.apple.iphonesimulator"

    /// Finds the running iOS Simulator application.
    public static func findSimulator() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == simulatorBundleID
        }
    }

    /// Finds the iOS app element within the simulator (the AXGroup containing the iOS content).
    public static func findIOSAppElement(in simulator: NSRunningApplication) -> AccessibilityElement? {
        let pid = simulator.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let simulatorElement = AccessibilityElement(element: appElement)

        for window in simulatorElement.children where window.role == "AXWindow" {
            for child in window.children where child.role == "AXGroup" {
                return child
            }
        }

        return nil
    }

    /// Finds the iOS app element for a specific simulator identified by UDID.
    /// Searches window titles for the device name matching the given UDID.
    public static func findIOSAppElement(forUDID udid: String, deviceName: String?) -> AccessibilityElement? {
        guard let simulator = findSimulator() else { return nil }
        let pid = simulator.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let simulatorElement = AccessibilityElement(element: appElement)

        // If we have a device name, try to match it against window titles
        if let deviceName = deviceName {
            for window in simulatorElement.children where window.role == "AXWindow" {
                if let windowTitle = window.title, windowTitle.contains(deviceName) {
                    for child in window.children where child.role == "AXGroup" {
                        return child
                    }
                }
            }
        }

        // Fallback: return first AXGroup found
        return findIOSAppElement(in: simulator)
    }

    /// Returns the AXUIElement for the application-level element of the simulator.
    public static func findSimulatorAppElement() -> AccessibilityElement? {
        guard let simulator = findSimulator() else { return nil }
        let pid = simulator.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        return AccessibilityElement(element: appElement)
    }
}
