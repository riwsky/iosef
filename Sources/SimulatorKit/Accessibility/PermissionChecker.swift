import Foundation
import ApplicationServices
import AppKit

/// Checks and validates accessibility permissions.
public enum PermissionChecker {
    public static func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public static func permissionErrorMessage() -> String {
        """
        Error: This tool requires accessibility permissions.

        To grant permissions:
        1. Open System Settings → Privacy & Security → Accessibility
        2. Add your terminal app (or the process running this server) to the list
        3. Enable the checkbox next to it
        4. Restart this tool
        """
    }

    @discardableResult
    public static func openAccessibilitySettings() -> Bool {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        return NSWorkspace.shared.open(url)
    }
}
