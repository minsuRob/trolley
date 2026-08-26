import Foundation

/// Restarts the app after its bundle has been swapped underneath it.
///
/// `replace` uses `renamex_np(RENAME_SWAP)`, which gives the path a new inode.
/// The process already running keeps the old one -- it does not pick up the new
/// version by itself, and there is nothing it can do to.
public enum TrolleyRelaunch {
    /// Builds the command that reopens `bundle` once this process is gone.
    ///
    /// Ordering is the whole difficulty. `open -a` on a bundle whose app is still
    /// running just activates the running copy -- the old one -- so launching
    /// before exiting is a no-op that looks like a broken button. Waiting for our
    /// own pid to disappear and only then opening is what makes the relaunch
    /// real.
    ///
    /// Exposed as a pure function so the shell it produces can be asserted
    /// without terminating the test runner.
    public static func command(bundlePath: String, pid: Int32) -> [String] {
        // `kill -0` tests for the process without signalling it; the loop ends
        // when the pid is gone. Bounded so a pid that somehow never exits leaves
        // a shell that gives up rather than one that spins forever.
        let script = """
        for i in $(seq 1 100); do
          /bin/kill -0 \(pid) 2>/dev/null || break
          /bin/sleep 0.1
        done
        /usr/bin/open -a \(shellQuoted(bundlePath))
        """
        return ["/bin/sh", "-c", script]
    }

    /// Single-quoted for `sh`, with embedded quotes broken out. Paths under
    /// /Applications rarely need it; a development copy under a directory with a
    /// space in it always does.
    public static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Spawns the waiter and returns. The caller terminates itself next.
    ///
    /// Detached on purpose: the child has to outlive us, which is the one thing
    /// it exists to do.
    public static func scheduleRelaunch(bundlePath: String, pid: Int32 = getpid()) {
        let argv = command(bundlePath: bundlePath, pid: pid)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        try? process.run()
    }
}
