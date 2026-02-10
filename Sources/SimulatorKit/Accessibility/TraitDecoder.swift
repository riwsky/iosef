import Foundation

/// Decodes iOS UIAccessibilityTraits bitmask into readable trait names.
public enum TraitDecoder {
    public static func decode(_ traitsBitmask: UInt64) -> [String] {
        var traits: [String] = []

        if traitsBitmask & (1 << 0) != 0 { traits.append("button") }
        if traitsBitmask & (1 << 1) != 0 { traits.append("link") }
        if traitsBitmask & (1 << 2) != 0 { traits.append("image") }
        if traitsBitmask & (1 << 3) != 0 { traits.append("selected") }
        if traitsBitmask & (1 << 4) != 0 { traits.append("playsSound") }
        if traitsBitmask & (1 << 5) != 0 { traits.append("keyboardKey") }
        if traitsBitmask & (1 << 6) != 0 { traits.append("staticText") }
        if traitsBitmask & (1 << 7) != 0 { traits.append("summaryElement") }
        if traitsBitmask & (1 << 8) != 0 { traits.append("notEnabled") }
        if traitsBitmask & (1 << 9) != 0 { traits.append("updatesFrequently") }
        if traitsBitmask & (1 << 10) != 0 { traits.append("searchField") }
        if traitsBitmask & (1 << 11) != 0 { traits.append("startsMediaSession") }
        if traitsBitmask & (1 << 12) != 0 { traits.append("adjustable") }
        if traitsBitmask & (1 << 13) != 0 { traits.append("allowsDirectInteraction") }
        if traitsBitmask & (1 << 14) != 0 { traits.append("causesPageTurn") }
        if traitsBitmask & (1 << 15) != 0 { traits.append("tabBar") }
        if traitsBitmask & (1 << 16) != 0 { traits.append("header") }
        if traitsBitmask & (1 << 17) != 0 { traits.append("toggle") }

        return traits
    }
}
