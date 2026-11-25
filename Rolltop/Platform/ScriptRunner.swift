import Darwin
import Foundation

/// Runs `/bin/sh -c <command>` for script conditions (Automations) and script widgets
/// (Custom Items): its own process group, a caller-chosen minimal environment and working
/// directory, standard input closed, output captured up to a limit, and a timeout that
/// ends the whole process group (TERM, then KILL), so children the script started in the
/// background do not survive it. Finishes when the shell exits (plus a short drain of its
/// output), never waiting for end-of-file: a background child may hold the pipe open.
nonisolated enum ScriptRunner {
    struct Options: Sendable {
        /// The only variables the script sees.
        var environment: [String: String]
        var currentDirectory: String
        /// Standard error joins standard output (true) or is discarded.
        var capturesStandardError: Bool
        var outputLimit = 4096
        /// Seconds between TERM and KILL after a timeout.
        var killGrace: TimeInterval = 1
    }

    struct Result: Sendable, Equatable {
        /// The exit status, or the signal number when a signal ended the shell (as
        /// `Process.terminationStatus`); nil when it could not start.
        var terminationStatus: Int32?
        var terminatedBySignal = false
        var timedOut = false
        var output = Data()
        var duration: TimeInterval = 0
        var launchError: String?
        /// The process group the run used (the shell's pid); nil when it could not start.
        var processGroup: pid_t?
    }

    static func run(_ command: String, timeout: TimeInterval, options: Options) async -> Result {
        await withCheckedContinuation { continuation in
            ScriptRun(command: command, timeout: timeout, options: options) { continuation.resume(returning: $0) }.start()
        }
    }
}

/// One run; mutable state behind a lock.
nonisolated private final class ScriptRun: @unchecked Sendable {
    private let command: String
    private let timeout: TimeInterval
    private let options: ScriptRunner.Options
    private let completion: @Sendable (ScriptRunner.Result) -> Void
    private let lock = NSLock()
    private var output = Data()
    private var finished = false
    private var timedOut = false
    private var exited = false
    private var pid: pid_t = 0
    private var reader: DispatchSourceRead?
    private let started = Date()
    private let queue = DispatchQueue(label: "rolltop.script-runner", qos: .utility, attributes: .concurrent)

    init(command: String, timeout: TimeInterval, options: ScriptRunner.Options,
         completion: @escaping @Sendable (ScriptRunner.Result) -> Void) {
        self.command = command
        self.timeout = timeout
        self.options = options
        self.completion = completion
    }

    func start() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return fail("pipe failed: \(String(cString: strerror(errno)))") }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        if options.capturesStandardError {
            posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir(&actions, options.currentDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group (pgid = its pid), default signal handling, and no file
        // descriptor of Rolltop's besides the three above.
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                                     | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ["/bin/sh", "-c", command]
        let envp = options.environment.map { "\($0.key)=\($0.value)" }
        var child: pid_t = 0
        let status = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, argvPointers, envPointers)
            }
        }
        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            return fail("could not start /bin/sh: \(String(cString: strerror(status)))")
        }
        let spawned = child
        lock.withLock { pid = spawned }

        startReading(readEnd)
        queue.async { [self] in waitForExit(spawned) }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in stopIfRunning(spawned) }
    }

    /// A read source, not a blocking read: a background child may keep the pipe open after
    /// the shell exits; cancelling the source at the end closes our end either way.
    private func startReading(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                lock.withLock {
                    let room = options.outputLimit - output.count
                    if room > 0 { output.append(contentsOf: buffer.prefix(min(room, count))) }
                }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { close(fd) }
        lock.withLock { reader = source }
        source.resume()
    }

    private func waitForExit(_ child: pid_t) {
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(child, &status, 0) } while waited < 0 && errno == EINTR
        lock.withLock { exited = true }
        let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        let code: Int32? = waited == child ? (signaled ? status & 0x7f : (status >> 8) & 0xff) : nil
        // Let the reader take what the script wrote last.
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            finish(terminationStatus: code, signaled: signaled, launchError: nil)
        }
    }

    /// Ends the process group after the timeout, only while the shell still leads it.
    private func stopIfRunning(_ child: pid_t) {
        let running = lock.withLock { !exited }
        guard running else { return }
        lock.withLock { timedOut = true }
        guard getpgid(child) == child else {
            kill(child, SIGTERM)
            return
        }
        kill(-child, SIGTERM)
        queue.asyncAfter(deadline: .now() + options.killGrace) {
            // The group outlives its leader when children ignore TERM; KILL whatever is left.
            kill(-child, SIGKILL)
        }
    }

    private func fail(_ message: String) {
        finish(terminationStatus: nil, signaled: false, launchError: message)
    }

    private func finish(terminationStatus: Int32?, signaled: Bool, launchError: String?) {
        let result: ScriptRunner.Result? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            reader?.cancel()
            reader = nil
            return ScriptRunner.Result(terminationStatus: terminationStatus, terminatedBySignal: signaled, timedOut: timedOut,
                                       output: output, duration: Date().timeIntervalSince(started), launchError: launchError,
                                       processGroup: pid == 0 ? nil : pid)
        }
        if let result { completion(result) }
    }
}

/// `body` gets a NULL-terminated C array of the strings.
nonisolated private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
