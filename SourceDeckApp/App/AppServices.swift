import SourceDeckCore
import Foundation
import Observation

/// The app's long-lived objects, created once at launch.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    enum GitState {
        case resolving
        case ready(GitProcess, GitVersion)
        /// git ran but is older than `GitVersion.minimumSupported`.
        case unsupported(GitVersion)
        /// No usable git: Command Line Tools missing, or the path is wrong.
        case unavailable(path: String)
    }

    /// Opened once, and the failure kept rather than thrown away, so a
    /// database that won't open is reported on screen instead of looking
    /// like an empty repository list (same reasoning as DKB Monitor).
    @ObservationIgnored let database: Result<AppDatabase, Error>
    private(set) var git: GitState = .resolving
    /// Created once git is usable and the database is open.
    private(set) var repositories: RepositoryList?

    private init() {
        database = Result { try AppDatabase(path: AppDatabaseLocation.productionPath().path) }
    }

    /// Asks the login shell for PATH (~400 ms) and checks
    /// `git --version` off the main thread, once per launch.
    func start() async {
        let environment = await GitEnvironment.resolve(gitPath: AppSettings.gitPath)
        let git = GitProcess(environment: environment)
        switch try? await git.version() {
        case let version? where version.isSupported:
            self.git = .ready(git, version)
            if case .success(let database) = database { repositories = RepositoryList(database: database, git: git) }
        case let version?: self.git = .unsupported(version)
        case nil: self.git = .unavailable(path: environment.gitURL.path)
        }
    }
}
