import Foundation
import Testing
@testable import SimulatorKit

@Suite("ProjectConfig")
struct ProjectConfigTests {

    // MARK: - resolveStateDir

    @Test("auto scope returns local dir when local config exists")
    func autoScopeReturnsLocal() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let localDir = tmp + "/.iosef"
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: localDir + "/config.json", contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let dir = resolveStateDir(.auto, cwd: tmp)
        #expect(dir == localDir)
    }

    @Test("auto scope returns global dir when no local config")
    func autoScopeReturnsGlobal() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let dir = resolveStateDir(.auto, cwd: tmp)
        #expect(dir == NSHomeDirectory() + "/.iosef")
    }

    @Test("local scope always returns local dir")
    func localScope() {
        let tmp = "/tmp/test-\(UUID().uuidString)"
        let dir = resolveStateDir(.local, cwd: tmp)
        #expect(dir == tmp + "/.iosef")
    }

    @Test("global scope always returns global dir")
    func globalScope() {
        let tmp = "/tmp/test-\(UUID().uuidString)"
        let dir = resolveStateDir(.global, cwd: tmp)
        #expect(dir == NSHomeDirectory() + "/.iosef")
    }

    // MARK: - readProjectConfig / writeProjectConfig

    @Test("round-trip config read/write")
    func configRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let config = ProjectConfig(device: "my-simulator")
        try writeProjectConfig(config, to: tmp)

        let loaded = readProjectConfig(from: tmp)
        #expect(loaded == config)
        #expect(loaded?.device == "my-simulator")
    }

    @Test("readProjectConfig returns nil for missing config")
    func readMissingConfig() {
        let tmp = "/tmp/nonexistent-\(UUID().uuidString)"
        let config = readProjectConfig(from: tmp)
        #expect(config == nil)
    }

    // MARK: - DeviceCacheEntry.matches

    @Test("cache matches when no default device name is set")
    func cacheMatchesNoDefault() {
        let entry = DeviceCacheEntry(udid: "ABC-123", name: "some-device")
        #expect(entry.matches(defaultDeviceName: nil) == true)
    }

    @Test("cache matches when name equals default")
    func cacheMatchesExact() {
        let entry = DeviceCacheEntry(udid: "ABC-123", name: "my-sim")
        #expect(entry.matches(defaultDeviceName: "my-sim") == true)
    }

    @Test("cache matches with -main suffix convention")
    func cacheMatchesMainSuffix() {
        let entry = DeviceCacheEntry(udid: "ABC-123", name: "my-sim-main")
        #expect(entry.matches(defaultDeviceName: "my-sim") == true)
    }

    @Test("cache does NOT match when name differs from default")
    func cacheDoesNotMatchDifferentName() {
        let entry = DeviceCacheEntry(udid: "ABC-123", name: "old-device")
        #expect(entry.matches(defaultDeviceName: "new-device") == false)
    }

    @Test("cache does NOT match when cached name is nil")
    func cacheDoesNotMatchNilName() {
        let entry = DeviceCacheEntry(udid: "ABC-123", name: nil)
        #expect(entry.matches(defaultDeviceName: "my-sim") == false)
    }

    // MARK: - Device cache I/O

    @Test("device cache round-trip with TTL")
    func deviceCacheRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp + "/cache", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let entry = DeviceCacheEntry(udid: "DEAD-BEEF", name: "test-sim")
        writeDeviceCache(entry, to: tmp)

        let loaded = readDeviceCache(from: tmp)
        #expect(loaded == entry)
    }

    @Test("device cache returns nil when expired")
    func deviceCacheExpired() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: tmp + "/cache", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let entry = DeviceCacheEntry(udid: "DEAD-BEEF", name: "test-sim")
        writeDeviceCache(entry, to: tmp)

        // Set mtime to 60 seconds ago
        let cachePath = tmp + "/cache/device.json"
        let pastDate = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: cachePath)

        let loaded = readDeviceCache(from: tmp, ttl: 30)
        #expect(loaded == nil)
    }

    // MARK: - Integration: config overrides stale cache

    @Test("stale disk cache is invalidated when config device differs")
    func staleCacheInvalidatedByConfig() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let stateDir = tmp + "/.iosef"
        try FileManager.default.createDirectory(atPath: stateDir + "/cache", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Write config pointing to "new-device"
        try writeProjectConfig(ProjectConfig(device: "new-device"), to: stateDir)

        // Write stale disk cache pointing to "old-device"
        writeDeviceCache(DeviceCacheEntry(udid: "OLD-UUID", name: "old-device"), to: stateDir)

        // Resolve config
        let dir = resolveStateDir(.auto, cwd: tmp)
        let config = readProjectConfig(from: dir)
        #expect(config?.device == "new-device")

        // Check if disk cache matches the config device — it should NOT
        let cached = readDeviceCache(from: dir)
        #expect(cached != nil, "Cache should exist on disk")
        #expect(cached!.matches(defaultDeviceName: config!.device!) == false,
                "Stale cache should NOT match new config device")
    }
}
