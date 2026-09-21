import Foundation
import Testing
@testable import SimulatorKit

@Suite("DeveloperDir")
struct DeveloperDirTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let env: String?
        let link: String?
        let expected: String
    }

    static let beta = "/Applications/Xcode-beta.app/Contents/Developer"
    static let stable = "/Applications/Xcode.app/Contents/Developer"
    static let clt = "/Library/Developer/CommandLineTools"

    /// Paths that "exist" for the injected fileExists.
    static let existing: Set<String> = [
        "/Applications/Xcode-beta.app", beta,
        "/Applications/Xcode.app", stable,
        clt,
        "/opt/custom-developer",
    ]

    static let cases: [Case] = [
        Case(testDescription: "env developer dir wins over xcode-select", env: beta, link: stable, expected: beta),
        Case(testDescription: "env bare .app bundle is normalised", env: "/Applications/Xcode-beta.app", link: stable, expected: beta),
        Case(testDescription: "env trailing slash is tolerated", env: "/Applications/Xcode-beta.app/", link: stable, expected: beta),
        Case(testDescription: "env non-bundle developer dir is accepted", env: "/opt/custom-developer", link: stable, expected: "/opt/custom-developer"),
        Case(testDescription: "empty env falls through to xcode-select", env: "", link: beta, expected: beta),
        Case(testDescription: "nonexistent env falls through to xcode-select", env: "/nonexistent", link: beta, expected: beta),
        Case(testDescription: "CommandLineTools env falls through", env: clt, link: beta, expected: beta),
        Case(testDescription: "xcode-select used when env absent", env: nil, link: beta, expected: beta),
        Case(testDescription: "CommandLineTools selection is skipped", env: nil, link: clt, expected: stable),
        Case(testDescription: "dangling xcode-select link is skipped", env: nil, link: "/nonexistent/Contents/Developer", expected: stable),
        Case(testDescription: "nothing set falls back to /Applications/Xcode.app", env: nil, link: nil, expected: stable),
    ]

    @Test("resolution order", arguments: cases)
    func resolves(_ c: Case) {
        let env = c.env.map { ["DEVELOPER_DIR": $0] } ?? [:]
        let dir = resolveDeveloperDir(env: env, xcodeSelectLink: c.link) { Self.existing.contains($0) }
        #expect(dir == c.expected)
    }

    @Test("child environment pins DEVELOPER_DIR to the resolved dir")
    func childEnvironment() {
        #expect(DeveloperDir.childEnvironment["DEVELOPER_DIR"] == DeveloperDir.resolved)
    }
}
