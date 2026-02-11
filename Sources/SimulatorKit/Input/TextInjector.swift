import Foundation
import CoreGraphics
import AppKit

/// Injects text into the iOS Simulator using pasteboard + Cmd+V.
public enum TextInjector {

    /// Types text into the simulator by copying to the simulator's pasteboard and pasting.
    ///
    /// Uses `xcrun simctl pbcopy` to set the pasteboard, then sends Cmd+V to paste.
    public static func typeText(_ text: String, deviceID: String) async throws {
        // Copy text to simulator pasteboard via simctl pbcopy
        let pbcopy = Process()
        pbcopy.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        pbcopy.arguments = ["simctl", "pbcopy", deviceID]

        let inputPipe = Pipe()
        pbcopy.standardInput = inputPipe
        pbcopy.standardOutput = FileHandle.nullDevice
        pbcopy.standardError = FileHandle.nullDevice

        try pbcopy.run()

        guard let data = text.data(using: .utf8) else {
            throw TextInjectorError.encodingFailed
        }
        inputPipe.fileHandleForWriting.write(data)
        inputPipe.fileHandleForWriting.closeFile()

        pbcopy.waitUntilExit()

        guard pbcopy.terminationStatus == 0 else {
            throw TextInjectorError.pbcopyFailed(exitCode: pbcopy.terminationStatus)
        }

        // Send Cmd+V to paste via native NSAppleScript (no process spawn)
        try sendPasteViaNSAppleScript()
    }

    /// Sends Cmd+V to the Simulator via native NSAppleScript (in-process, no osascript spawn).
    private static func sendPasteViaNSAppleScript() throws {
        let scriptSource = """
        tell application "Simulator" to activate
        delay 0.05
        tell application "System Events" to keystroke "v" using command down
        """
        let script = NSAppleScript(source: scriptSource)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            // Fall back to CGEvent if AppleScript fails
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            FileHandle.standardError.write(Data("[TextInjector] NSAppleScript failed: \(msg), falling back to CGEvent\n".utf8))
            sendPasteViaCGEvent()
        }
    }

    /// Fallback: Sends Cmd+V via CGEvent if AppleScript is unavailable.
    private static func sendPasteViaCGEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9

        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        else { return }
        vDown.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        usleep(10000)

        guard let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        vUp.flags = .maskCommand
        vUp.post(tap: .cghidEventTap)
    }

    public enum TextInjectorError: Error, LocalizedError {
        case pbcopyFailed(exitCode: Int32)
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .pbcopyFailed(let code):
                return "simctl pbcopy failed with exit code \(code)"
            case .encodingFailed:
                return "Failed to encode text as UTF-8"
            }
        }
    }
}
