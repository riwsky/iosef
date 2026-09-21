import Foundation
import XPC

/// Errors from connecting to the simulator's `dtuhidd`.
enum DTUHIDError: Error, LocalizedError {
    case symbolsUnavailable
    case serviceUnavailable(String)
    case connectionFailed
    case unresponsive(String)

    var errorDescription: String? {
        switch self {
        case .symbolsUnavailable:
            return "The private XPC simulator-endpoint symbols are not available on this host"
        case .serviceUnavailable(let reason):
            return "Simulator does not vend the dtuhidd digitizer service: \(reason)"
        case .connectionFailed:
            return "Could not create an XPC connection to dtuhidd"
        case .unresponsive(let reason):
            return "dtuhidd did not answer: \(reason)"
        }
    }
}

/// Sends touch and keyboard events through `dtuhidd`, the HID daemon CoreSimulator injects
/// into the guest from Xcode 27 (CoreSimulator 1155.4).
///
/// Once `dtuhidd` goes active the guest disconnects the legacy Indigo touch, button and
/// keyboard services. An Indigo event reconnects a suppressed service, but if that service
/// had already been connected earlier in the boot the reconnect is torn down in the same
/// instant (IOHID logs "Service added" then "Service removed") and backboardd never gets
/// its digitizer back, so Indigo touches are reported delivered and go nowhere. Whether a
/// given boot ends up in that state is a startup race, which is why this transport is
/// preferred whenever it is available rather than used as a fallback.
///
/// Events are plain XPC dictionaries: `{messageType, isBarrier, featureIdentifier, payload}`.
/// Wire format and connection setup follow idb's SimulatorDTUHIDTransport (MIT, Meta Platforms).
final class DTUHIDTransport: HIDTransport, @unchecked Sendable {
    let name = "dtuhidd"

    /// First CoreSimulator version whose guests run `dtuhidd`.
    static let firstCoreSimulatorVersion = "1155.4"

    private static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"

    /// The liveness probe is the send that demand-launches `dtuhidd`, so it pays for a cold start.
    private static let livenessTimeout: DispatchTimeInterval = .seconds(4)
    /// launchd throttles the respawn of a `dtuhidd` that died early in a slow boot.
    private static let livenessRetryBackoffMicros: UInt32 = 4_000_000
    private static let livenessAttempts = 3
    /// Time for the daemon to open its HID devices after first answering.
    private static let replyTailMicros: UInt32 = 200_000
    /// Time for already-sent events to be dispatched before the connection goes away.
    private static let drainMicros: UInt32 = 80_000

    /// Flipped by the connection's event handler when XPC reports the peer gone.
    private final class Validity: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        var isValid: Bool { lock.withLock { valid } }
        func invalidate() { lock.withLock { valid = false } }
    }

    private let connection: xpc_connection_t
    private let validity: Validity
    private let lock = NSLock()
    private var needsDrain = false

    /// False once the connection has died, e.g. because the simulator rebooted under it.
    var isValid: Bool { validity.isValid }

    /// Whether the loaded CoreSimulator is new enough to have `dtuhidd` at all.
    static var isSupportedByCoreSimulator: Bool {
        guard let simDevice = NSClassFromString("SimDevice"),
              let version = Bundle(for: simDevice).infoDictionary?["CFBundleVersion"] as? String else {
            return false
        }
        return version.compare(firstCoreSimulatorVersion, options: .numeric) != .orderedAscending
    }

    init(device: AnyObject) throws {
        var lastError: Error = DTUHIDError.connectionFailed
        for attempt in 1...Self.livenessAttempts {
            do {
                let validity = Validity()
                let candidate = try Self.makeConnection(device: device, validity: validity)
                do {
                    try Self.confirmLiveness(candidate)
                    self.connection = candidate
                    self.validity = validity
                    usleep(Self.replyTailMicros)
                    return
                } catch {
                    xpc_connection_cancel(candidate)
                    throw error
                }
            } catch DTUHIDError.unresponsive(let reason) {
                lastError = DTUHIDError.unresponsive(reason)
                logDiagnostic("liveness attempt \(attempt)/\(Self.livenessAttempts) failed: \(reason)", prefix: "DTUHIDTransport")
                if attempt < Self.livenessAttempts { usleep(Self.livenessRetryBackoffMicros) }
            }
        }
        throw lastError
    }

    deinit {
        flush()
        xpc_connection_cancel(connection)
    }

    // MARK: - Events

    /// Sends one digitizer contact. `xRatio`/`yRatio` are 0...1 from the top-left.
    func sendTouch(xRatio: Double, yRatio: Double, phase: HIDTouchPhase) {
        sendDigitizerEvent(points: [(xRatio, yRatio)], phase: phase)
    }

    func sendTouches(
        _ first: (xRatio: Double, yRatio: Double),
        _ second: (xRatio: Double, yRatio: Double),
        phase: HIDTouchPhase
    ) {
        sendDigitizerEvent(points: [first, second], phase: phase)
    }

    /// `pointTwo` is simply absent for a single contact.
    private func sendDigitizerEvent(points: [(xRatio: Double, yRatio: Double)], phase: HIDTouchPhase) {
        let payload = xpc_dictionary_create_empty()
        for (key, point) in zip(["pointOne", "pointTwo"], points) {
            let encoded = xpc_dictionary_create_empty()
            xpc_dictionary_set_double(encoded, "x", point.xRatio)
            xpc_dictionary_set_double(encoded, "y", point.yRatio)
            xpc_dictionary_set_value(payload, key, encoded)
        }
        xpc_dictionary_set_uint64(payload, "eventType", Self.wireValue(of: phase))
        xpc_dictionary_set_uint64(payload, "edge", 0)
        xpc_dictionary_set_uint64(payload, "target", 0)
        send(Self.message(type: "IndigoDigitizerEvent", payload: payload))
    }

    /// dtuhidd's per-contact `eventType`. It decodes these as integers, not strings.
    private static func wireValue(of phase: HIDTouchPhase) -> UInt64 {
        switch phase {
        case .start: return 0
        case .position: return 1
        case .end: return 2
        }
    }

    /// Sends one keyboard event. `usage` is a USB HID keyboard usage code.
    func sendKey(usage: UInt8, down: Bool) {
        send(Self.message(type: "IndigoKeyboardButtonEvent", payload: Self.keyPayload(usage: UInt64(usage), down: down)))
    }

    /// Not carried: dtuhidd identifies buttons by HID usage, not by Indigo source, and
    /// buttons still work over Indigo, which is where `CompositeHIDTransport` sends them.
    func sendButton(source: UInt32, direction: Int32) {
        logDiagnostic("dropping button source \(source): not routed over dtuhidd", prefix: "DTUHIDTransport")
    }

    /// Waits for sent events to be dispatched. XPC sends are asynchronous, so a process that
    /// exits (or drops this client) straight after sending would take its events with it.
    func flush() {
        let pending = lock.withLock {
            defer { needsDrain = false }
            return needsDrain
        }
        if pending { usleep(Self.drainMicros) }
    }

    private func send(_ message: xpc_object_t) {
        lock.withLock { needsDrain = true }
        xpc_connection_send_message(connection, message)
        let sent = DispatchSemaphore(value: 0)
        xpc_connection_send_barrier(connection) { sent.signal() }
        _ = sent.wait(timeout: .now() + 2.0)
    }

    // MARK: - Messages

    private static func message(type: String, payload: xpc_object_t, isBarrier: Bool = false) -> xpc_object_t {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", isBarrier)
        xpc_dictionary_set_string(message, "featureIdentifier", serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }

    /// HIDButtonState is 1-based on the wire: down = 1, up = 2 (0 fails dtuhidd's decode).
    private static func keyPayload(usage: UInt64, down: Bool) -> xpc_object_t {
        let payload = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(payload, "usageCode", usage)
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        return payload
    }

    // MARK: - Connection

    private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
    private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
    private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

    private static func makeConnection(device: AnyObject, validity: Validity) throws -> xpc_connection_t {
        guard let handle = dlopen(nil, RTLD_NOW),
              let endpointSym = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let connectionSym = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let sim2hostSym = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            throw DTUHIDError.symbolsUnavailable
        }
        let endpointFromPort = unsafeBitCast(endpointSym, to: EndpointFromMachPortFn.self)
        let connectionFromEndpoint = unsafeBitCast(connectionSym, to: ConnectionFromEndpointFn.self)
        let enableSim2Host = unsafeBitCast(sim2hostSym, to: EnableSim2HostFn.self)

        // -[SimDevice lookup:error:] resolves a Mach service in the guest's bootstrap namespace.
        let lookupSel = NSSelectorFromString("lookup:error:")
        guard let lookupMethod = class_getInstanceMethod(type(of: device), lookupSel) else {
            throw DTUHIDError.serviceUnavailable("SimDevice.lookup:error: not found")
        }
        typealias LookupFn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> mach_port_t
        let lookup = unsafeBitCast(method_getImplementation(lookupMethod), to: LookupFn.self)

        var lookupError: NSError?
        let port = lookup(device, lookupSel, serviceName as NSString, &lookupError)
        guard port != 0 else {
            throw DTUHIDError.serviceUnavailable(lookupError?.localizedDescription ?? "lookup returned no port")
        }

        guard let endpoint = endpointFromPort(port, 0, 0),
              let connection = connectionFromEndpoint(endpoint) else {
            throw DTUHIDError.connectionFailed
        }

        // Without this the daemon sees the peer connect but never receives a payload.
        enableSim2Host(connection)
        xpc_connection_set_event_handler(connection) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { validity.invalidate() }
        }
        xpc_connection_resume(connection)
        return connection
    }

    /// Sends a no-op barrier message and waits for the daemon itself to reply. An XPC error
    /// reply means XPC answered on the peer's behalf, i.e. nothing took the message.
    private static func confirmLiveness(_ connection: xpc_connection_t) throws {
        let probe = message(type: "IndigoKeyboardButtonEvent", payload: keyPayload(usage: 0, down: false), isBarrier: true)

        final class Failure: @unchecked Sendable {
            private let lock = NSLock()
            private var reason: String?
            func set(_ value: String) { lock.withLock { reason = value } }
            var value: String? { lock.withLock { reason } }
        }
        let answered = DispatchSemaphore(value: 0)
        let failure = Failure()
        xpc_connection_send_message_with_reply(connection, probe, DispatchQueue.global(qos: .userInitiated)) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) }
                failure.set(description ?? "unknown XPC error")
            }
            answered.signal()
        }

        if answered.wait(timeout: .now() + livenessTimeout) == .timedOut {
            throw DTUHIDError.unresponsive("no reply within \(livenessTimeout)")
        }
        if let reason = failure.value {
            throw DTUHIDError.unresponsive(reason)
        }
    }
}
