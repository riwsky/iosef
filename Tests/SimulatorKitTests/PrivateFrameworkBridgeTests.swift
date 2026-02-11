import Testing
import ObjectiveC
@testable import SimulatorKit

@Suite("PrivateFrameworkBridge Tests")
struct PrivateFrameworkBridgeTests {

    @Test("Can load CoreSimulator and SimulatorKit frameworks")
    func loadFrameworks() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
    }

    @Test("Function pointer for IndigoHIDMessageForMouseNSEvent resolves")
    func mouseNSEventResolved() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        #expect(bridge.messageForMouseNSEvent != nil)
    }

    @Test("Function pointer for IndigoHIDMessageForButton resolves")
    func buttonResolved() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        #expect(bridge.messageForButton != nil)
    }

    @Test("Function pointer for IndigoHIDMessageForKeyboardArbitrary resolves")
    func keyboardResolved() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        #expect(bridge.messageForKeyboardArbitrary != nil)
    }

    @Test("SimServiceContext ObjC class exists")
    func simServiceContextExists() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        let cls: AnyClass? = objc_lookUpClass("SimServiceContext")
        #expect(cls != nil)
    }

    @Test("SimDevice ObjC class exists")
    func simDeviceExists() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        let cls: AnyClass? = objc_lookUpClass("SimDevice")
        #expect(cls != nil)
    }

    @Test("SimDeviceLegacyHIDClient class exists")
    func hidClientClassExists() throws {
        let bridge = PrivateFrameworkBridge.shared
        try bridge.ensureLoaded()
        let cls: AnyClass? = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient")
        #expect(cls != nil)
    }
}
