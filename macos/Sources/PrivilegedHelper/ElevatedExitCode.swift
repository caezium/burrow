/// Exit statuses the elevated *wrapper* produces, as opposed to anything the
/// elevated command itself can return.  Spelled once here because the shell
/// that emits them and the UI that has to explain them live in different
/// files, and a drifting number turns a precise refusal into a bare code.
enum ElevatedExitCode {
    /// A pinned identity, or the plan's expiry, failed its check at the
    /// execution boundary.  Nothing ran.
    static let boundaryCheckFailed: Int32 = 124
    /// The root-owned log sink could not be created.  Nothing ran.
    static let logSinkUnavailable: Int32 = 125
    /// The executable failed validation before launch.  Nothing ran.
    static let executableRefused: Int32 = 126
    /// The elevated process could not be spawned at all.
    static let launchFailed: Int32 = 127
}
