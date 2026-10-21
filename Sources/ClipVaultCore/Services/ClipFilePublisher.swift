import Darwin
import Foundation

/// Publishes a fully verified file on the destination volume without replacing
/// an existing path, including a symlink created after the Save panel closes.
public enum ClipFilePublisher {
    public static func publish(verifiedFile: URL, to destination: URL) throws {
        guard verifiedFile.isFileURL, destination.isFileURL else { throw ClipSyncError.invalidPayload }
        let result = verifiedFile.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
