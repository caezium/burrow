import Foundation
import Darwin

struct PinnedFileIdentity: Sendable, Equatable, Codable {
    enum IdentityError: LocalizedError {
        case missing(String)
        case symlink(String)
        case wrongType(String)
        case mutableComponent(String)

        var errorDescription: String? {
            switch self {
            case .missing(let p): return "A required path no longer exists: \(p)"
            case .symlink(let p): return "A symbolic link is not allowed here: \(p)"
            case .wrongType(let p): return "A required path has the wrong type: \(p)"
            case .mutableComponent(let p): return "A privileged executable can be replaced by the current user: \(p)"
            }
        }
    }

    let path: String
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let mode: UInt16

    var isDirectory: Bool { (mode_t(mode) & S_IFMT) == S_IFDIR }
    var isRegular: Bool { (mode_t(mode) & S_IFMT) == S_IFREG }
    var isSymbolicLink: Bool { (mode_t(mode) & S_IFMT) == S_IFLNK }

    static func capture(_ path: String, rejectSymlink: Bool = true) throws -> Self {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw IdentityError.missing(path) }
        if rejectSymlink, (st.st_mode & S_IFMT) == S_IFLNK { throw IdentityError.symlink(path) }
        return Self(path: path, device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
                    owner: UInt32(st.st_uid), mode: UInt16(st.st_mode))
    }

    func matchesCurrent() -> Bool {
        // A reviewed descendant may itself be a symlink. Capture the link's
        // identity without following it; a regular-file-to-symlink swap still
        // fails because the inode and complete mode are pinned.
        guard let current = try? Self.capture(path, rejectSymlink: false) else { return false }
        return current.device == device && current.inode == inode &&
            current.owner == owner && current.mode == mode
    }

    /// BSD stat's `%p` is the complete mode in octal (for example 100755).
    var shellStatToken: String {
        "\(device):\(inode):\(owner):\(String(mode, radix: 8))"
    }
}
