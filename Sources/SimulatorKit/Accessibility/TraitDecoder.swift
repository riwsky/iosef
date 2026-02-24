import Foundation

public enum AccessibilityTrait: Int, CaseIterable {
    case button = 0, link = 1, image = 2, selected = 3,
         playsSound = 4, keyboardKey = 5, staticText = 6, summaryElement = 7,
         notEnabled = 8, updatesFrequently = 9, searchField = 10, startsMediaSession = 11,
         adjustable = 12, allowsDirectInteraction = 13, causesPageTurn = 14, tabBar = 15,
         header = 16, toggle = 17
}

/// Decodes iOS UIAccessibilityTraits bitmask into readable trait names.
public enum TraitDecoder {
    public static func decode(_ traitsBitmask: UInt64) -> [String] {
        AccessibilityTrait.allCases.compactMap {
            traitsBitmask & (1 << $0.rawValue) != 0 ? String(describing: $0) : nil
        }
    }
}
