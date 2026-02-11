import Testing
import CoreGraphics
@testable import SimulatorKit
import IndigoCTypes

@Suite("IndigoTypes Tests")
struct IndigoTypesTests {

    @Test("MachMessageHeader is 24 bytes")
    func machHeaderSize() {
        #expect(MemoryLayout<IndigoMachHeader>.size == 24)
    }

    @Test("IndigoTouch is 112 bytes (0x70) with pack(4)")
    func touchSize() {
        #expect(MemoryLayout<IndigoTouch>.size == 112)
    }

    @Test("IndigoButton is 20 bytes (0x14)")
    func buttonSize() {
        #expect(MemoryLayout<IndigoButton>.size == 20)
    }

    @Test("IndigoPayload is 144 bytes (0x90)")
    func payloadSize() {
        #expect(MemoryLayout<IndigoPayload>.size == 144)
    }

    @Test("IndigoMessage base size is 176 bytes (0xb0)")
    func messageBaseSize() {
        #expect(MemoryLayout<IndigoMessage>.size == 176)
    }

    @Test("Touch message total is 320 bytes (0x140)")
    func touchMessageTotalSize() {
        let total = MemoryLayout<IndigoMessage>.size + MemoryLayout<IndigoPayload>.size
        #expect(total == 320)
    }

    @Test("IndigoTouch xRatio offset is at 0x0c within touch struct")
    func touchXRatioOffset() {
        let offset = MemoryLayout<IndigoTouch>.offset(of: \IndigoTouch.xRatio)!
        #expect(offset == 0x0c)
    }

    @Test("IndigoTouch yRatio offset is at 0x14 within touch struct")
    func touchYRatioOffset() {
        let offset = MemoryLayout<IndigoTouch>.offset(of: \IndigoTouch.yRatio)!
        #expect(offset == 0x14)
    }

    @Test("Payload starts at offset 0x20 in IndigoMessage")
    func payloadOffsetInMessage() {
        let offset = MemoryLayout<IndigoMessage>.offset(of: \IndigoMessage.payload)!
        #expect(offset == 0x20)
    }

    @Test("Event starts at offset 0x10 in IndigoPayload")
    func eventOffsetInPayload() {
        let offset = MemoryLayout<IndigoPayload>.offset(of: \IndigoPayload.event)!
        #expect(offset == 0x10)
    }

    @Test("Coordinate ratio calculation")
    func coordinateRatio() {
        // iPhone 15 Pro: 393pt logical, 3x scale, 1179px
        let ratio = indigoScreenRatio(
            x: 100, y: 200,
            screenSize: CGSize(width: 1179, height: 2556),
            screenScale: 3.0
        )
        // xRatio = (100 * 3.0) / 1179 ≈ 0.2544
        #expect(abs(ratio.xRatio - 0.2544) < 0.001)
        // yRatio = (200 * 3.0) / 2556 ≈ 0.2348
        #expect(abs(ratio.yRatio - 0.2348) < 0.001)
    }

    @Test("Coordinate ratio at center is ~0.5")
    func coordinateRatioCenter() {
        let ratio = indigoScreenRatio(
            x: 196.5, y: 426,
            screenSize: CGSize(width: 1179, height: 2556),
            screenScale: 3.0
        )
        #expect(abs(ratio.xRatio - 0.5) < 0.001)
        #expect(abs(ratio.yRatio - 0.5) < 0.001)
    }

    @Test("Constants match expected values")
    func constants() {
        #expect(IndigoEventTypeConst.touch == 2)
        #expect(IndigoEventTypeConst.button == 1)
        #expect(IndigoDirection.down == 1)
        #expect(IndigoDirection.up == 2)
        #expect(IndigoButtonSourceConst.homeButton == 0)
        #expect(IndigoButtonSourceConst.lock == 1)
        #expect(IndigoButtonTargetConst.hardware == 0x33)
    }
}
