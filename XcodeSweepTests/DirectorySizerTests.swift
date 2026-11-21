import Foundation
import Testing
@testable import XcodeSweep

@Suite("DirectorySizer")
struct DirectorySizerTests {
    @Test("Computes non-zero allocated size for directory containing files")
    func computesDirectorySize() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectorySizerTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let payload = Data(repeating: 0xAB, count: 65536)
        try payload.write(to: tempRoot.appendingPathComponent("file1.bin"))
        try payload.write(to: tempRoot.appendingPathComponent("file2.bin"))

        let size = DirectorySizer.allocatedSize(of: tempRoot)
        #expect(size >= 131_072)
    }

    @Test("Returns zero for nonexistent path")
    func returnsZeroForMissingPath() {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-xcodesweep-\(UUID().uuidString)")
        #expect(DirectorySizer.allocatedSize(of: missing) == 0)
    }
}
