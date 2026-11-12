import FSKit

@main
struct AFPFSExtension: UnaryFileSystemExtension {
    var fileSystem: AFPFileSystem {
        AFPFileSystem()
    }
}
