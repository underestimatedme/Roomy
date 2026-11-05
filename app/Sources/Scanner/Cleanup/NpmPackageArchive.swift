// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

/// Hash a tar stream without extracting paths or invoking package code. The
/// system reader handles gzip/PAX; warnings, links and unsupported entries deny
/// the complete unit. Compressed and expanded data have independent bounds.
enum NpmPackageArchive {
    struct Contents {
        let files: [String: String]
        let directories: Set<String>
        let storageBytes: Int
    }
    private final class Reader {
        typealias New = @convention(c) () -> OpaquePointer?
        typealias Operation = @convention(c) (OpaquePointer?) -> Int32
        typealias Callback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
        typealias Input = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int
        typealias Open = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Callback?, Input?, Callback?) -> Int32
        typealias FilterBytes = @convention(c) (OpaquePointer?, Int32) -> Int64
        typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
        typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
        typealias Text = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        typealias FileType = @convention(c) (OpaquePointer?) -> mode_t
        typealias Size = @convention(c) (OpaquePointer?) -> Int64
        let library: UnsafeMutableRawPointer
        let create: New, tar: Operation, gzip: Operation, close: Operation, free: Operation
        let open: Open, next: Next, read: Read, name: Text, symlink: Text, hardlink: Text, type: FileType, size: Size
        let filterBytes: FilterBytes
        init?() {
            guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
            func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: T.self) } }
            guard let create = symbol("archive_read_new", New.self), let tar = symbol("archive_read_support_format_tar", Operation.self),
                let gzip = symbol("archive_read_support_filter_gzip", Operation.self), let close = symbol("archive_read_close", Operation.self),
                let free = symbol("archive_read_free", Operation.self), let open = symbol("archive_read_open", Open.self),
                let next = symbol("archive_read_next_header", Next.self), let read = symbol("archive_read_data", Read.self),
                let name = symbol("archive_entry_pathname", Text.self), let symlink = symbol("archive_entry_symlink", Text.self),
                let hardlink = symbol("archive_entry_hardlink", Text.self), let type = symbol("archive_entry_filetype", FileType.self),
                let size = symbol("archive_entry_size", Size.self),
                let filterBytes = symbol("archive_filter_bytes", FilterBytes.self) else { dlclose(library); return nil }
            self.library = library; self.create = create; self.tar = tar; self.gzip = gzip; self.close = close; self.free = free
            self.open = open; self.next = next; self.read = read; self.name = name; self.symlink = symlink
            self.hardlink = hardlink; self.type = type; self.size = size; self.filterBytes = filterBytes
        }
        deinit { dlclose(library) }
    }
    private static let reader = Reader()

    private final class InputState {
        let fd: Int32, deadline: Date, limit: Int64, bytes: Reader.FilterBytes
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        init(fd: Int32, deadline: Date, limit: Int64, bytes: @escaping Reader.FilterBytes) {
            self.fd = fd; self.deadline = deadline; self.limit = limit; self.bytes = bytes
        }
        deinit { buffer.deallocate() }
    }
    private static let input: Reader.Input = { archive, client, output in
        guard let client, let archive else { return -1 }
        let state = Unmanaged<InputState>.fromOpaque(client).takeUnretainedValue()
        // The closest filter counts ALL uncompressed tar bytes, including PAX
        // metadata hidden by next_header. Abort while feeding compressed data,
        // not just after a potentially long hidden-header chain finishes.
        guard Date() < state.deadline, state.bytes(archive, 0) <= state.limit else { return -1 }
        let count = Darwin.read(state.fd, state.buffer, 4096)
        guard count >= 0 else { return -1 }
        output?.pointee = UnsafeRawPointer(state.buffer)
        return count
    }

    static func contents(path: String, deadline: Date, expandedLimit: Int64 = 512 * 1024 * 1024) -> Contents? {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        guard expandedLimit > 0, expandedLimit <= Int64(CacheContent.byteLimit),
              let api = reader, let archive = api.create() else { return nil }
        let state = InputState(fd: fd, deadline: deadline, limit: expandedLimit, bytes: api.filterBytes)
        defer { _ = api.free(archive); withExtendedLifetime(state) {} }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 128 * 1024 * 1024,
              api.tar(archive) == 0, api.gzip(archive) == 0,
              api.open(archive, Unmanaged.passUnretained(state).toOpaque(), nil, input, nil) == 0 else { return nil }
        var files: [String: String] = [:], directories = Set<String>(), seen = Set<String>(), expanded: Int64 = 0
        var pathBytes = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while Date() < deadline {
            var entry: OpaquePointer?
            let status = api.next(archive, &entry)
            guard Date() < deadline, api.filterBytes(archive, 0) >= 0,
                  api.filterBytes(archive, 0) <= expandedLimit else { return nil }
            if status == 1 {
                guard api.close(archive) == 0, Date() < deadline, !files.isEmpty else { return nil }
                let storage = files.keys.reduce(0) { $0 + $1.utf8.count + 224 } + directories.reduce(0) { $0 + $1.utf8.count + 128 }
                guard storage <= 8 * 1024 * 1024 else { return nil }
                return Contents(files: files, directories: directories, storageBytes: storage)
            }
            guard status == 0, let entry, let pointer = api.name(entry), let raw = String(validatingUTF8: pointer),
                  raw.utf8.count <= 4096, api.symlink(entry) == nil, api.hardlink(entry) == nil,
                  seen.count < 10_000 else { return nil }
            pathBytes += raw.utf8.count
            guard pathBytes <= 1024 * 1024 else { return nil }
            let directory = api.type(entry) == mode_t(S_IFDIR)
            guard directory || api.type(entry) == mode_t(S_IFREG) else { return nil }
            let normalized = directory && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard normalized == "package" || normalized.hasPrefix("package/"), seen.insert(normalized).inserted else { return nil }
            if normalized == "package" { guard directory else { return nil }; continue }
            let relative = String(normalized.dropFirst(8)), parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 40, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !relative.contains("\\") else { return nil }
            for count in 1..<parts.count { directories.insert(parts.prefix(count).joined(separator: "/")) }
            if directory { directories.insert(relative); continue }
            let size = api.size(entry)
            guard size >= 0, size <= Int64(CacheContent.byteLimit), expanded <= Int64(CacheContent.byteLimit) - size else { return nil }
            expanded += size
            var digest = SHA256(), readBytes: Int64 = 0
            while Date() < deadline {
                let count = api.read(archive, &buffer, buffer.count)
                guard Date() < deadline, api.filterBytes(archive, 0) <= expandedLimit else { return nil }
                if count == 0 { break }
                guard count > 0, readBytes <= size - Int64(count) else { return nil }
                readBytes += Int64(count); digest.update(data: Data(buffer.prefix(count)))
            }
            guard Date() < deadline, readBytes == size else { return nil }
            files[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }
}
