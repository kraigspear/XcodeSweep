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

        let size = try DirectorySizer.allocatedSize(of: tempRoot)
        #expect(size >= 131_072)
    }

    @Test("Returns zero for nonexistent path")
    func returnsZeroForMissingPath() throws {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-xcodesweep-\(UUID().uuidString)")
        #expect(try DirectorySizer.allocatedSize(of: missing) == 0)
    }

    @Test("Throws CancellationError instead of a partial size when cancelled mid-walk")
    func throwsWhenCancelledDuringWalk() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectorySizerTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try Data(repeating: 0xAB, count: 65536).write(to: tempRoot.appendingPathComponent("file.bin"))

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { () throws(CancellationError) in try DirectorySizer.allocatedSize(of: tempRoot) }
        }.value

        #expect(throws: CancellationError.self) { try result.get() }
    }
}
