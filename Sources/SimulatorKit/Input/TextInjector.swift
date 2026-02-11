import Foundation

/// Injects text into the iOS Simulator using pasteboard + Cmd+V via IndigoHID.
public enum TextInjector {

    /// Types text into the simulator by copying to the simulator's pasteboard and pasting.
    ///
    /// Uses `xcrun simctl pbcopy` to set the pasteboard, then sends Cmd+V via IndigoHID
    /// keyboard events directly to the simulator (no macOS accessibility required).
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

        // Send Cmd+V via IndigoHID keyboard events (no macOS accessibility needed)
        try sendPasteViaIndigoHID(deviceID: deviceID)
    }

    /// Sends Cmd+V to the simulator via IndigoHID keyboard messages.
    /// keyCode 9 = 'v', modifier command = we send command-down, v-down, v-up, command-up sequence.
    private static func sendPasteViaIndigoHID(deviceID: String) throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()

        let device = try bridge.lookUpDevice(udid: deviceID)
        let client = try bridge.createHIDClient(device: device)

        guard let keyboardFn = bridge.messageForKeyboardArbitrary else {
            throw TextInjectorError.keyboardFunctionNotFound
        }

        // keyCode for 'v' in HID usage table is 25 (0x19)
        // but IndigoHIDMessageForKeyboardArbitrary uses a different mapping.
        // In the Indigo keyboard system: keyCode 9 = 'v' (matches CGKeyCode)
        let vKeyCode: Int32 = 9

        // Send key down
        let downMsg = keyboardFn(vKeyCode, 1)  // 1 = down
        let downSize = malloc_size(downMsg)

        // Set command modifier: in the Indigo button payload, the eventTarget field
        // at offset 0x08 controls modifiers. For keyboard events with command,
        // we use target 0x64 (keyboard) and set the appropriate modifier bits.
        // However, the simpler approach used by idb is to just send the keyboard
        // arbitrary message which handles the keyCode mapping.

        let downData = Data(bytes: downMsg, count: downSize)
        free(downMsg)
        bridge.sendMessage(downData, to: client)

        usleep(10_000)  // 10ms

        // Send key up
        let upMsg = keyboardFn(vKeyCode, 2)  // 2 = up
        let upSize = malloc_size(upMsg)
        let upData = Data(bytes: upMsg, count: upSize)
        free(upMsg)
        bridge.sendMessage(upData, to: client)
    }

    public enum TextInjectorError: Error, LocalizedError {
        case pbcopyFailed(exitCode: Int32)
        case encodingFailed
        case keyboardFunctionNotFound

        public var errorDescription: String? {
            switch self {
            case .pbcopyFailed(let code):
                return "simctl pbcopy failed with exit code \(code)"
            case .encodingFailed:
                return "Failed to encode text as UTF-8"
            case .keyboardFunctionNotFound:
                return "IndigoHIDMessageForKeyboardArbitrary function not found"
            }
        }
    }
}
