// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Shared by the GUI and CLI so their persistent mutation records cannot overlap.
final class OperationLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(path: String) throws -> OperationLease {
        func failure(_ message: String, code: Int = 1) -> NSError {
            NSError(domain: "RoomyOperation", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法安全打开操作锁：\(String(cString: strerror(errno)))") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else {
            close(fd); throw failure("操作锁的类型或所有者异常，已暂停操作")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw failure("Roomy 的其他窗口或命令正在处理文件，请完成后重试", code: 2)
        }
        return OperationLease(fd)
    }
}
