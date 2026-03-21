import Foundation

public protocol SessionConfigurableFilesystem: WorkspaceFilesystem {
    func configureForSession() throws
}
