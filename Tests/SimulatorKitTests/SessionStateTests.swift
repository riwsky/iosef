import Foundation
import Testing
@testable import SimulatorKit

@Suite("SessionState")
struct SessionStateTests {

    // MARK: - resolveSessionDir

    @Test("auto scope returns local dir when local state exists")
    func autoScopeReturnsLocal() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let localDir = tmp + "/.iosef"
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: localDir + "/state.json", contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let dir = resolveSessionDir(.auto, cwd: tmp)
        #expect(dir == localDir)
    }

    @Test("auto scope returns global dir when no local state")
    func autoScopeReturnsGlobal() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let dir = resolveSessionDir(.auto, cwd: tmp)
        #expect(dir == NSHomeDirectory() + "/.iosef")
    }

    @Test("local scope always returns local dir")
    func localScope() {
        let tmp = "/tmp/test-\(UUID().uuidString)"
        let dir = resolveSessionDir(.local, cwd: tmp)
        #expect(dir == tmp + "/.iosef")
    }

    @Test("global scope always returns global dir")
    func globalScope() {
        let tmp = "/tmp/test-\(UUID().uuidString)"
        let dir = resolveSessionDir(.global, cwd: tmp)
        #expect(dir == NSHomeDirectory() + "/.iosef")
    }

    // MARK: - readSessionState / writeSessionState

    @Test("round-trip state read/write")
    func stateRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let state = SessionState(device: "my-simulator")
        try writeSessionState(state, to: tmp)

        let loaded = readSessionState(from: tmp)
        #expect(loaded == state)
        #expect(loaded?.device == "my-simulator")
    }

    @Test("readSessionState returns nil for missing state")
    func readMissingState() {
        let tmp = "/tmp/nonexistent-\(UUID().uuidString)"
        let state = readSessionState(from: tmp)
        #expect(state == nil)
    }

    // MARK: - isIosefGitignored

    @Test("no .gitignore returns false")
    func noGitignore() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(isIosefGitignored(in: tmp) == false)
    }

    @Test(".gitignore without .iosef returns false")
    func gitignoreWithoutIosef() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try ".build/\n*.xcodeproj/\n".write(toFile: tmp + "/.gitignore", atomically: true, encoding: .utf8)
        #expect(isIosefGitignored(in: tmp) == false)
    }

    @Test(".gitignore with .iosef/ returns true")
    func gitignoreWithTrailingSlash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try ".build/\n.iosef/\n".write(toFile: tmp + "/.gitignore", atomically: true, encoding: .utf8)
        #expect(isIosefGitignored(in: tmp) == true)
    }

    @Test(".gitignore with .iosef (no trailing slash) returns true")
    func gitignoreWithoutTrailingSlash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try ".build/\n.iosef\n".write(toFile: tmp + "/.gitignore", atomically: true, encoding: .utf8)
        #expect(isIosefGitignored(in: tmp) == true)
    }

    @Test("commented .iosef/ line is ignored")
    func commentedLineIgnored() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        try "# .iosef/\n.build/\n".write(toFile: tmp + "/.gitignore", atomically: true, encoding: .utf8)
        #expect(isIosefGitignored(in: tmp) == false)
    }

}
