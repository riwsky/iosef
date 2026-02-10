import Testing
@testable import SimulatorKit

@Suite("TraitDecoder Tests")
struct TraitDecoderTests {

    @Test("Decodes button trait at bit position 0")
    func decodesButtonTrait() {
        #expect(TraitDecoder.decode(1 << 0) == ["button"])
    }

    @Test("Decodes link trait at bit position 1")
    func decodesLinkTrait() {
        #expect(TraitDecoder.decode(1 << 1) == ["link"])
    }

    @Test("Decodes image trait at bit position 2")
    func decodesImageTrait() {
        #expect(TraitDecoder.decode(1 << 2) == ["image"])
    }

    @Test("Decodes selected trait at bit position 3")
    func decodesSelectedTrait() {
        #expect(TraitDecoder.decode(1 << 3) == ["selected"])
    }

    @Test("Decodes staticText trait at bit position 6")
    func decodesStaticTextTrait() {
        #expect(TraitDecoder.decode(1 << 6) == ["staticText"])
    }

    @Test("Decodes toggle trait at bit position 17")
    func decodesToggleTrait() {
        #expect(TraitDecoder.decode(1 << 17) == ["toggle"])
    }

    @Test("Decodes button and selected traits combined")
    func decodesButtonAndSelectedTraits() {
        #expect(TraitDecoder.decode((1 << 0) | (1 << 3)) == ["button", "selected"])
    }

    @Test("Decodes all 18 traits")
    func decodesAllTraits() {
        var bitmask: UInt64 = 0
        for bit in 0...17 { bitmask |= (1 << bit) }
        let traits = TraitDecoder.decode(bitmask)
        #expect(traits.count == 18)
        #expect(traits.first == "button")
        #expect(traits.last == "toggle")
    }

    @Test("Decodes empty bitmask as empty array")
    func decodesEmptyBitmask() {
        #expect(TraitDecoder.decode(0).isEmpty)
    }

    @Test("Ignores unknown bits above 17")
    func ignoresUnknownBits() {
        #expect(TraitDecoder.decode(1 << 18).isEmpty)
        #expect(TraitDecoder.decode(1 << 50).isEmpty)
    }

    @Test("Filters known from unknown bits")
    func filtersKnownFromUnknown() {
        let bitmask: UInt64 = (1 << 0) | (1 << 18) | (1 << 3) | (1 << 25)
        #expect(TraitDecoder.decode(bitmask) == ["button", "selected"])
    }
}
