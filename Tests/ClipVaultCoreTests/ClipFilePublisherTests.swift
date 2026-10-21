import Foundation
import Testing
@testable import ClipVaultCore

@Suite("Atomic attachment publication")
struct ClipFilePublisherTests {
    @Test("a verified file moves without overwriting any existing destination")
    func publishAndCollision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("verified")
        let target = root.appendingPathComponent("saved")
        try Data("verified bytes".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        try ClipFilePublisher.publish(verifiedFile: source, to: target)
        #expect(try Data(contentsOf: target) == Data("verified bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        try Data("different bytes".utf8).write(to: source)
        #expect(throws: (any Error).self) { try ClipFilePublisher.publish(verifiedFile: source, to: target) }
        #expect(try Data(contentsOf: target) == Data("verified bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
