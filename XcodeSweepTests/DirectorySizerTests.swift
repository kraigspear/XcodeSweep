import Foundation
import os
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
        let files = try (1 ... 3).map { index in
            let url = tempRoot.appendingPathComponent("file\(index).bin")
            try Data(repeating: 0xAB, count: 4096).write(to: url)
            return url
        }

        // Given: a walk that starts uncancelled and is cancelled once the first entry is handed out
        let entries = CancelAfterFirstEntry(urls: files)

        // When
        let result = await Task {
            Result { () throws(CancellationError) in try DirectorySizer.totalSize(of: entries) }
        }.value

        // Then: the walk stopped at the next entry instead of finishing
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(entries.handedOut.withLock { $0 } < files.count)
    }
}

/// Hands out entries in order and cancels the walking task after the first, as Stop would mid-walk.
private struct CancelAfterFirstEntry: Sequence, Sendable {
    let urls: [URL]
    let handedOut = OSAllocatedUnfairLock(initialState: 0)

    func makeIterator() -> AnyIterator<URL> {
        AnyIterator {
            let index = handedOut.withLock { count in
                defer { count += 1 }
                return count
            }
            if index == 1 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return index < urls.count ? urls[index] : nil
        }
    }
}
