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

        // Delay to ensure pasteboard is ready
        try await Task.sleep(for: .milliseconds(50))

        // Send Cmd+V to paste via AppleScript (most reliable for modifier keys)
        try sendPasteViaAppleScript()
    }

    /// Sends Cmd+V to the Simulator via AppleScript System Events.
    ///
    /// This is more reliable than CGEvent for sending keyboard shortcuts with modifiers,
    /// since AppleScript targets the specific application and handles modifier state correctly.
    private static func sendPasteViaAppleScript() throws {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = [
            "-e", "tell application \"Simulator\" to activate",
            "-e", "delay 0.1",
            "-e", "tell application \"System Events\" to keystroke \"v\" using command down",
        ]
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice

        try script.run()
        script.waitUntilExit()

        guard script.terminationStatus == 0 else {
            // Fall back to CGEvent if AppleScript fails (e.g., no System Events access)
            sendPasteViaCGEvent()
            return
        }
    }

    /// Fallback: Sends Cmd+V via CGEvent if AppleScript is unavailable.
    private static func sendPasteViaCGEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandKeyCode: CGKeyCode = 55
        let vKeyCode: CGKeyCode = 9

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true)
        else { return }
        cmdDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        else { return }
        vDown.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        guard let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        vUp.flags = .maskCommand
        vUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else { return }
        cmdUp.post(tap: .cghidEventTap)
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
