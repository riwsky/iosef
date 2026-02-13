import Foundation
import CoreGraphics
import ObjectiveC
import IndigoCTypes

/// Errors from loading Apple private frameworks.
public enum PrivateFrameworkError: Error, LocalizedError {
    case frameworkNotFound(String)
    case symbolNotFound(String, String)
    case classNotFound(String)
    case deviceNotFound(String)
    case clientCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkNotFound(let path):
            return "Could not load framework at \(path). Is Xcode installed?"
        case .symbolNotFound(let symbol, let framework):
            return "Could not find symbol '\(symbol)' in \(framework)"
        case .classNotFound(let name):
            return "Could not find ObjC class '\(name)'"
        case .deviceNotFound(let udid):
            return "No simulator device found with UDID '\(udid)'"
        case .clientCreationFailed(let reason):
            return "Failed to create HID client: \(reason)"
        }
    }
}

/// Bridges to Apple's private SimulatorKit and CoreSimulator frameworks via dlopen/dlsym
/// and ObjC runtime. Loads once and caches all resolved symbols.
public final class PrivateFrameworkBridge: @unchecked Sendable {
    public static let shared = PrivateFrameworkBridge()

    private var simulatorKitHandle: UnsafeMutableRawPointer?
    private var coreSimulatorHandle: UnsafeMutableRawPointer?
    private var axpHandle: UnsafeMutableRawPointer?
    private var loaded = false
    private var axpLoaded = false
    private let lock = NSLock()
    private var deviceCache: [String: AnyObject] = [:]

    // Cached CoreSimulator singletons (populated on first device access)
    private var cachedServiceContext: AnyObject?
    private var cachedDeviceSet: AnyObject?

    // MARK: - Resolved function pointers from SimulatorKit

    private(set) var messageForMouseNSEvent: (
        @convention(c) (UnsafeMutablePointer<CGPoint>, UnsafeMutableRawPointer?, Int32, Int32, Bool) -> UnsafeMutablePointer<IndigoMessage>
    )?

    private(set) var messageForButton: (
        @convention(c) (Int32, Int32, Int32) -> UnsafeMutablePointer<IndigoMessage>
    )?

    private(set) var messageForKeyboardArbitrary: (
        @convention(c) (Int32, Int32) -> UnsafeMutablePointer<IndigoMessage>
    )?

    // MARK: - Loading

    private static let simulatorKitPath =
        "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
    private static let coreSimulatorPath =
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"

    public func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !loaded else { return }

        guard let csHandle = dlopen(Self.coreSimulatorPath, RTLD_LAZY) else {
            throw PrivateFrameworkError.frameworkNotFound(Self.coreSimulatorPath)
        }
        coreSimulatorHandle = csHandle

        guard let skHandle = dlopen(Self.simulatorKitPath, RTLD_LAZY) else {
            throw PrivateFrameworkError.frameworkNotFound(Self.simulatorKitPath)
        }
        simulatorKitHandle = skHandle

        messageForMouseNSEvent = try resolveSymbol(skHandle, "IndigoHIDMessageForMouseNSEvent", framework: "SimulatorKit")
        messageForButton = try resolveSymbol(skHandle, "IndigoHIDMessageForButton", framework: "SimulatorKit")
        messageForKeyboardArbitrary = try resolveSymbol(skHandle, "IndigoHIDMessageForKeyboardArbitrary", framework: "SimulatorKit")

        loaded = true
    }

    private func resolveSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, framework: String) throws -> T {
        guard let sym = dlsym(handle, name) else {
            throw PrivateFrameworkError.symbolNotFound(name, framework)
        }
        return unsafeBitCast(sym, to: T.self)
    }

    // MARK: - CoreSimulator ObjC Bridge

    /// Looks up a SimDevice by UDID. Cached per UDID after first lookup.
    public func lookUpDevice(udid: String) throws -> AnyObject {
        lock.lock()
        if let cached = deviceCache[udid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let device = try lookUpDeviceUncached(udid: udid)

        lock.lock()
        deviceCache[udid] = device
        lock.unlock()

        return device
    }

    // MARK: - CoreSimulator context helpers (cached)

    /// Returns the shared SimServiceContext, creating and caching on first call.
    private func getServiceContext() throws -> AnyObject {
        if let ctx = cachedServiceContext { return ctx }

        guard let contextClass: AnyClass = objc_lookUpClass("SimServiceContext") else {
            throw PrivateFrameworkError.classNotFound("SimServiceContext")
        }

        let contextSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let contextMethod = class_getClassMethod(contextClass, contextSel) else {
            throw PrivateFrameworkError.classNotFound("SimServiceContext.sharedServiceContextForDeveloperDir:error:")
        }

        typealias ContextFn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let contextImp = method_getImplementation(contextMethod)
        let getContext = unsafeBitCast(contextImp, to: ContextFn.self)

        let developerDir = "/Applications/Xcode.app/Contents/Developer" as NSString
        var contextError: NSError?
        guard let ctx = getContext(contextClass, contextSel, developerDir, &contextError) else {
            throw PrivateFrameworkError.clientCreationFailed(
                "Could not create SimServiceContext: \(contextError?.localizedDescription ?? "unknown")")
        }

        cachedServiceContext = ctx
        return ctx
    }

    /// Returns the default SimDeviceSet, creating and caching on first call.
    private func getDeviceSet() throws -> AnyObject {
        if let ds = cachedDeviceSet { return ds }

        let serviceContext = try getServiceContext()
        let deviceSetSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSetMethod = class_getInstanceMethod(type(of: serviceContext as AnyObject), deviceSetSel) else {
            throw PrivateFrameworkError.clientCreationFailed("defaultDeviceSetWithError: not found")
        }

        typealias DeviceSetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let deviceSetImp = method_getImplementation(deviceSetMethod)
        let getDeviceSet = unsafeBitCast(deviceSetImp, to: DeviceSetFn.self)

        var dsError: NSError?
        guard let ds = getDeviceSet(serviceContext, deviceSetSel, &dsError) else {
            throw PrivateFrameworkError.clientCreationFailed(
                "Could not get default device set: \(dsError?.localizedDescription ?? "unknown")")
        }

        cachedDeviceSet = ds
        return ds
    }

    /// Returns the devicesByUDID dictionary from the default device set.
    private func getDevicesMap() throws -> NSDictionary {
        let deviceSet = try getDeviceSet()
        guard let devicesMap = (deviceSet as AnyObject).value(forKey: "devicesByUDID") as? NSDictionary else {
            throw PrivateFrameworkError.clientCreationFailed("Could not get devices map from device set")
        }
        return devicesMap
    }

    private func lookUpDeviceUncached(udid: String) throws -> AnyObject {
        try ensureLoaded()

        let devicesMap = try getDevicesMap()

        guard let nsUUID = NSUUID(uuidString: udid) else {
            throw PrivateFrameworkError.deviceNotFound(udid)
        }
        guard let device = devicesMap[nsUUID] else {
            throw PrivateFrameworkError.deviceNotFound(udid)
        }

        return device as AnyObject
    }

    /// Device state constants from CoreSimulator's SimDeviceState enum.
    private static let stateNames: [Int: String] = [
        0: "Creating",
        1: "Shutdown",
        2: "Booting",
        3: "Booted",
        4: "ShuttingDown",
    ]

    /// Returns all devices from the default device set.
    public func allDevices() throws -> [(udid: String, name: String, state: String, isAvailable: Bool)] {
        try ensureLoaded()

        let devicesMap = try getDevicesMap()
        var result: [(udid: String, name: String, state: String, isAvailable: Bool)] = []

        for (key, value) in devicesMap {
            guard let nsUUID = key as? NSUUID else { continue }
            let device = value as AnyObject

            let udid = nsUUID.uuidString
            let name = (device.value(forKey: "name") as? String) ?? "Unknown"
            let stateNum = (device.value(forKey: "state") as? NSNumber)?.intValue ?? 1
            let stateName = Self.stateNames[stateNum] ?? "Unknown"
            let available = (device.value(forKey: "available") as? NSNumber)?.boolValue ?? true

            result.append((udid: udid, name: name, state: stateName, isAvailable: available))
        }

        return result
    }

    /// Gets the screen size in pixels from a SimDevice's deviceType.
    public func screenSize(forDevice device: AnyObject) -> CGSize {
        guard let deviceType = (device as AnyObject).value(forKey: "deviceType") else {
            return CGSize(width: 1179, height: 2556)
        }
        if let size = (deviceType as AnyObject).value(forKey: "mainScreenSize") as? CGSize {
            return size
        }
        return CGSize(width: 1179, height: 2556)
    }

    /// Gets the screen scale from a SimDevice's deviceType.
    public func screenScale(forDevice device: AnyObject) -> Float {
        guard let deviceType = (device as AnyObject).value(forKey: "deviceType") else {
            return 3.0
        }
        if let scale = (deviceType as AnyObject).value(forKey: "mainScreenScale") as? NSNumber {
            return scale.floatValue
        }
        return 3.0
    }

    /// Creates a SimDeviceLegacyHIDClient for the given SimDevice.
    public func createHIDClient(device: AnyObject) throws -> AnyObject {
        try ensureLoaded()

        guard let clientClass: AnyClass = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient") else {
            throw PrivateFrameworkError.classNotFound("SimulatorKit.SimDeviceLegacyHIDClient")
        }

        // Call [[SimDeviceLegacyHIDClient alloc] initWithDevice:error:]
        // Use IMP to properly handle NSError** parameter
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let initMethod = class_getInstanceMethod(clientClass, initSel) else {
            throw PrivateFrameworkError.clientCreationFailed("initWithDevice:error: not found on class")
        }

        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let initImp = method_getImplementation(initMethod)
        let initClient = unsafeBitCast(initImp, to: InitFn.self)

        // alloc via perform (safe, no error params)
        let allocSel = NSSelectorFromString("alloc")
        guard let allocated = (clientClass as AnyObject).perform(allocSel)?.takeRetainedValue() else {
            throw PrivateFrameworkError.clientCreationFailed("alloc returned nil")
        }

        var initError: NSError?
        guard let client = initClient(allocated, initSel, device, &initError) else {
            throw PrivateFrameworkError.clientCreationFailed(
                "initWithDevice:error: returned nil: \(initError?.localizedDescription ?? "unknown")")
        }

        // Prevent ARC from releasing `allocated` separately since init consumed it
        _ = Unmanaged.passUnretained(allocated)

        return client
    }

    // MARK: - App Install & Launch

    /// Installs an app bundle on the given SimDevice.
    /// Calls -[SimDevice installApplication:withOptions:error:] via IMP.
    public func installApp(device: AnyObject, appURL: URL) throws {
        let sel = NSSelectorFromString("installApplication:withOptions:error:")
        guard let method = class_getInstanceMethod(type(of: device as AnyObject), sel) else {
            throw PrivateFrameworkError.classNotFound("SimDevice.installApplication:withOptions:error:")
        }

        typealias InstallFn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, UnsafeMutablePointer<NSError?>?) -> ObjCBool
        let imp = method_getImplementation(method)
        let install = unsafeBitCast(imp, to: InstallFn.self)

        let nsURL = appURL as NSURL
        let options = NSDictionary()
        var installError: NSError?
        let success = install(device, sel, nsURL, options, &installError)

        if !success.boolValue {
            // Retry once for Apple bug 46691107 (first install after uninstall can fail)
            var retryError: NSError?
            let retrySuccess = install(device, sel, nsURL, options, &retryError)
            if !retrySuccess.boolValue {
                throw PrivateFrameworkError.clientCreationFailed(
                    "installApplication failed: \(retryError?.localizedDescription ?? installError?.localizedDescription ?? "unknown")")
            }
        }
    }

    /// Launches an app on the given SimDevice by bundle identifier.
    /// Calls -[SimDevice launchApplicationAsyncWithID:options:completionQueue:completionHandler:] via IMP.
    /// Returns the launched process PID.
    public func launchApp(device: AnyObject, bundleID: String, terminateExisting: Bool = false) throws -> Int32 {
        let sel = NSSelectorFromString("launchApplicationAsyncWithID:options:completionQueue:completionHandler:")
        guard let method = class_getInstanceMethod(type(of: device as AnyObject), sel) else {
            throw PrivateFrameworkError.classNotFound("SimDevice.launchApplicationAsyncWithID:options:completionQueue:completionHandler:")
        }

        typealias LaunchFn = @convention(c) (AnyObject, Selector, NSString, NSDictionary, DispatchQueue, Any) -> Void
        let imp = method_getImplementation(method)
        let launch = unsafeBitCast(imp, to: LaunchFn.self)

        var options: [String: Any] = [:]
        if terminateExisting {
            options["terminate_running_process"] = true as NSNumber
        }

        let group = DispatchGroup()
        group.enter()

        let queue = DispatchQueue(label: "com.simulator-mcp.launch.callback")
        var resultPID: Int32 = -1
        var resultError: NSError?

        let completionBlock: @convention(block) (NSError?, Int32) -> Void = { error, pid in
            resultError = error
            resultPID = pid
            group.leave()
        }
        let completionObj: Any = completionBlock

        launch(device, sel, bundleID as NSString, options as NSDictionary, queue, completionObj)

        let waitResult = group.wait(timeout: .now() + 30.0)
        if waitResult == .timedOut {
            throw TimeoutError.processTimedOut(command: "launchApplication(\(bundleID))", timeoutSeconds: 30.0)
        }

        if let error = resultError {
            throw PrivateFrameworkError.clientCreationFailed("launchApplication failed: \(error.localizedDescription)")
        }

        return resultPID
    }

    // MARK: - AccessibilityPlatformTranslation Framework

    private static let axpPath =
        "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"

    /// Loads the AccessibilityPlatformTranslation private framework. Must be called before using AXP APIs.
    public func ensureAXPLoaded() throws {
        // CoreSimulator must be loaded first (for SimDevice).
        // Called outside our lock because ensureLoaded() acquires it internally.
        try ensureLoaded()

        lock.lock()
        defer { lock.unlock() }

        guard !axpLoaded else { return }

        guard let handle = dlopen(Self.axpPath, RTLD_LAZY) else {
            throw PrivateFrameworkError.frameworkNotFound(Self.axpPath)
        }
        axpHandle = handle
        axpLoaded = true
    }

    /// Returns AXPTranslator.sharedInstance via objc runtime.
    public func getAXPTranslatorSharedInstance() throws -> AnyObject {
        try ensureAXPLoaded()

        guard let translatorClass: AnyClass = objc_lookUpClass("AXPTranslator") else {
            throw PrivateFrameworkError.classNotFound("AXPTranslator")
        }

        let sel = NSSelectorFromString("sharedInstance")
        guard let method = class_getClassMethod(translatorClass, sel) else {
            throw PrivateFrameworkError.classNotFound("AXPTranslator.sharedInstance")
        }

        typealias SharedFn = @convention(c) (AnyObject, Selector) -> AnyObject
        let imp = method_getImplementation(method)
        let getShared = unsafeBitCast(imp, to: SharedFn.self)
        return getShared(translatorClass, sel)
    }

    /// Calls -[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:] via IMP.
    /// Blocks the calling thread until the async response arrives, or times out.
    public func sendAccessibilityRequest(_ request: AnyObject, toDevice device: AnyObject, timeoutSeconds: Double = 10.0) throws -> AnyObject {
        let sel = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        guard let method = class_getInstanceMethod(type(of: device as AnyObject), sel) else {
            throw PrivateFrameworkError.classNotFound("SimDevice.sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        }

        typealias SendFn = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, Any) -> Void
        let imp = method_getImplementation(method)
        let send = unsafeBitCast(imp, to: SendFn.self)

        let group = DispatchGroup()
        group.enter()

        let queue = DispatchQueue(label: "com.simulator-mcp.accessibility.callback")
        var result: AnyObject?

        let completionBlock: @convention(block) (AnyObject?) -> Void = { response in
            result = response
            group.leave()
        }
        let completionObj: Any = completionBlock

        send(device, sel, request, queue, completionObj)

        let waitResult = group.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            throw TimeoutError.accessibilityTimedOut(timeoutSeconds: timeoutSeconds)
        }

        if let response = result {
            return response
        }

        // Return an empty response if nil came back
        guard let responseClass: AnyClass = objc_lookUpClass("AXPTranslatorResponse") else {
            throw PrivateFrameworkError.classNotFound("AXPTranslatorResponse")
        }
        let emptySel = NSSelectorFromString("emptyResponse")
        guard let emptyResult = (responseClass as AnyObject).perform(emptySel)?.takeUnretainedValue() else {
            throw PrivateFrameworkError.classNotFound("AXPTranslatorResponse.emptyResponse")
        }
        return emptyResult
    }

    /// Sends an IndigoMessage to the HID client.
    public func sendMessage(_ data: Data, to client: AnyObject) {
        let size = data.count
        let buffer = malloc(size)!
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: size)

        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")

        guard let method = class_getInstanceMethod(type(of: client as AnyObject), sel) else {
            free(buffer)
            return
        }

        let imp = method_getImplementation(method)

        // -(void)sendWithMessage:(void*)msg freeWhenDone:(BOOL)free
        //        completionQueue:(dispatch_queue_t)queue completion:(void(^)(NSError*))completion
        typealias SendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, DispatchQueue, Any?) -> Void
        let send = unsafeBitCast(imp, to: SendFn.self)
        let queue = DispatchQueue.global(qos: .userInteractive)
        send(client, sel, buffer, ObjCBool(true), queue, nil)
    }
}
