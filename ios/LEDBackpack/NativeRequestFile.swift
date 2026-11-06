import Foundation
import CryptoKit
import BackpackProtocol
import os

struct NativeRequestFile: Sendable {
    fileprivate let url: URL
    let byteCount: Int
    let bodyHash: String
    func openStream() throws -> InputStream {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == byteCount,
              let stream = InputStream(url: url) else { throw BackpackError.invalid("Owned immutable upload snapshot changed or is unavailable.") }
        return stream
    }
    func remove() throws { try FileManager.default.removeItem(at: url) }
}
actor NativeRequestFileBuilder {
    static let shared = NativeRequestFileBuilder()
    func capture(_ source: URL, maxBytes: Int) throws -> NativeRequestFile {
        guard source.isFileURL, maxBytes > 0 else { throw BackpackError.invalid("A bounded local upload file is required.") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              (1...maxBytes).contains(size) else { throw BackpackError.invalid("Upload source must be a bounded regular file, not a link.") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("attested-upload-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
            throw BackpackError.invalid("Could not create a protected immutable upload snapshot.")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { do { try input.close() } catch { Logger(subsystem: "com.errantactions.ledbackpack", category: "native-upload").error("Upload source handle close failed.") } }
            let output = try FileHandle(forWritingTo: destination)
            defer { do { try output.close() } catch { Logger(subsystem: "com.errantactions.ledbackpack", category: "native-upload").error("Upload snapshot handle close failed.") } }
            var hash = SHA256(), count = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                count += chunk.count
                guard count <= maxBytes else { throw BackpackError.invalid("Upload source grew beyond its byte budget.") }
                try output.write(contentsOf: chunk); hash.update(data: chunk)
            }
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard count == size, after.fileSize == size, after.contentModificationDate == values.contentModificationDate else {
                throw BackpackError.invalid("Upload source changed while taking its snapshot.")
            }
            try output.synchronize()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            return NativeRequestFile(url: destination, byteCount: count,
                bodyHash: NativeIntegrityBinding.base64URL(Data(hash.finalize())))
        } catch {
            do { try FileManager.default.removeItem(at: destination) }
            catch { throw BackpackError.invalid("Upload snapshot failed and its protected temporary file could not be removed.") }
            throw error
        }
    }
}
