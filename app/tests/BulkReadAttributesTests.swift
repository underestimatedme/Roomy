// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

@main struct BulkReadAttributesTests {
    static func main() throws {
        let fm=FileManager.default
        let root=URL(fileURLWithPath:"/private/tmp/roomy-bulk-attributes-\(UUID())",isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? fm.removeItem(at:root)}
        let inner=root.appendingPathComponent("nested/inner",isDirectory:true)
        try fm.createDirectory(at:inner,withIntermediateDirectories:true)
        for i in 0..<700 {
            let directory=i%3 == 0 ? inner:root
            try Data(repeating:0x41,count:100+(i%17)*123).write(to:directory.appendingPathComponent("entry-\(i)"))
        }
        let original=root.appendingPathComponent("entry-1").path
        precondition(link(original,root.appendingPathComponent("hard-link").path)==0)
        precondition(symlink("nested",root.appendingPathComponent("directory-link").path)==0)
        precondition(symlink("entry-1",root.appendingPathComponent("file-link").path)==0)
        let fifo=root.appendingPathComponent("pipe").path
        precondition(mkfifo(fifo,0o600)==0)
        func entries(_ attributes:BulkReadAttributes,includeFileNames:Bool=true)throws->[DirEntry]{
            let fd=try openDir(root.path);defer{close(fd)}
            var output:[DirEntry]=[]
            try readEntries(fd:fd,into:&output,buf:AttrBuffer(size:4096),attributes:attributes,includeFileNames:includeFileNames)
            return output.sorted{$0.name<$1.name}
        }
        let full=try entries(.full),compact=try entries(.allocatedSize)
        precondition(full.count==compact.count && full.count>400,"multi-batch reads retain every entry")
        for (a,b) in zip(full,compact){
            precondition(a.name==b.name && a.type==b.type && a.dev==b.dev && a.fileID==b.fileID && a.links==b.links && a.alloc==b.alloc,
                         "size mode must preserve identity, type, link count and allocated bytes")
        }
        let unnamed=try entries(.allocatedSize,includeFileNames:false)
        func identities(_ values:[DirEntry])->[String]{
            values.map { "\($0.type):\($0.dev):\($0.fileID):\($0.links):\($0.alloc)" }.sorted()
        }
        precondition(unnamed.count==full.count && identities(unnamed)==identities(full),"omitting unused file strings retains all file identities and bytes")
        precondition(unnamed.filter(\.isDir).map(\.name).sorted()==full.filter(\.isDir).map(\.name).sorted(),"all traversed directory names remain intact")
        let regular=try full.first(where:{$0.name=="entry-1"}).unwrap()
        var posix=stat();precondition(lstat(original,&posix)==0)
        precondition(regular.logical==UInt64(posix.st_size) && regular.mtime==Int(posix.st_mtimespec.tv_sec)
                     && regular.atime==Int(posix.st_atimespec.tv_sec),"default/full metadata retains activity and logical size")
        let defaultEntries=try readDir(root.path)
        precondition(defaultEntries.first(where:{$0.name=="entry-1"})?.mtime==regular.mtime,"readDir classification callers keep timestamps")
        let targets=[root.path,inner.path,root.appendingPathComponent("file-link").path]
        let old=BulkWalker(readAttributes:.full),new=BulkWalker()
        let before=old.measureTargetsDetailed(targets,threads:1),after=new.measureTargetsDetailed(targets,threads:1)
        precondition(before.measurements==after.measurements,"same targets have identical byte and completeness results")
        precondition(old.files==new.files && old.dirs==new.dirs && old.denied==new.denied && old.failed==new.failed,"same complete traversal coverage")
        precondition(after.measurement(for:root.path)?.completeness == .complete)
        precondition(after.measurement(for:targets[2])?.completeness == .unknown,"symlinks remain unknown and are never followed")
        let cancelled=BulkWalker().sizeDetailed(of:root.path,shouldContinue:{false})
        precondition(cancelled.size==nil && cancelled.completeness == .incomplete,"no full result after cancellation")
        let denied=inner.appendingPathComponent("denied",isDirectory:true)
        try fm.createDirectory(at:denied,withIntermediateDirectories:true)
        try Data(repeating:0x42,count:8192).write(to:denied.appendingPathComponent("sample"))
        guard geteuid() != 0 else{throw NSError(domain:"BulkReadAttributesTests",code:1,userInfo:[NSLocalizedDescriptionKey:"permission test requires non-root user"])}
        precondition(chmod(denied.path,0)==0);defer{_ = chmod(denied.path,0o700)}
        let unreadable=BulkWalker().sizeDetailed(of:root.path)
        precondition(unreadable.completeness == .incomplete,"compact mode never hides an unreadable descendant")
        print("BulkReadAttributesTests passed: identical coverage/identity/allocated bytes/completeness, full activity metadata, hard links, symlinks, FIFO, cancellation and denied descendant")
    }
}
private extension Optional {
    func unwrap()throws->Wrapped {guard let value=self else{throw NSError(domain:"BulkReadAttributesTests",code:2)};return value}
}
