import Foundation

/// Runs the update check on a schedule and reports what it found.
///
/// Every network call happens off the main thread. `LiveUpdateIO.send` blocks on
/// a semaphore, so a check on the main thread freezes the widget for as long as
/// the feed takes to answer -- commit `e97ded4` is the record of that exact
/// failure, from a different caller. `onChange` is always delivered back on the
/// main queue, because everything that reads it (the pet, the panel, the menu
/// bar) is main-thread-only by convention in this package.
public final class UpdateCoordinator {
    /// The latest thing we know. Read on the main thread only.
    public private(set) var status: UpdateStatus = .upToDate

    /// Called on the main queue whenever `status` changes.
    public var onChange: ((UpdateStatus) -> Void)?

    /// What a relaunch has to reopen -- the bundle, not the executable inside it.
    public var installedPath: String { layout.target.path }

    private let policy: UpdatePolicy
    private let installer: UpdateInstaller
    private let feed: URL
    private let assetName: String
    private let current: SemanticVersion
    private let layout: InstallLayout
    /// Hands work back to the UI. Injected so tests can run it inline instead of
    /// waiting on a real run loop.
    private let toMain: (@escaping () -> Void) -> Void

    private let queue = DispatchQueue(label: "ink.markhub.trolley.update", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// The verified copy waiting to be swapped in, if any.
    ///
    /// Written by the download on `queue` and read by the button on the main
    /// thread, so it is the one piece of state here that two threads touch. The
    /// language mode is v5, so nothing would have told us -- the lock is the
    /// whole guarantee.
    private var stagedStorage: UpdateInstaller.StagedUpdate?
    private let stagedLock = NSLock()

    private var staged: UpdateInstaller.StagedUpdate? {
        get { stagedLock.lock(); defer { stagedLock.unlock() }; return stagedStorage }
        set { stagedLock.lock(); stagedStorage = newValue; stagedLock.unlock() }
    }
    /// Guards against a timer firing while the previous check is still running --
    /// a slow feed would otherwise stack downloads of the same asset.
    private var isWorking = false

    public init(
        policy: UpdatePolicy = .default,
        installer: UpdateInstaller = LiveUpdateIO.live,
        feed: URL = TrolleyVersion.releaseFeed,
        assetName: String = TrolleyVersion.updateAssetName,
        current: SemanticVersion,
        layout: InstallLayout,
        toMain: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }
    ) {
        self.policy = policy
        self.installer = installer
        self.feed = feed
        self.assetName = assetName
        self.current = current
        self.layout = layout
        self.toMain = toMain
    }

    deinit {
        timer?.cancel()
    }

    /// Checks now, then every `policy.interval`.
    ///
    /// The repeating source is held for the life of the coordinator, which the
    /// app holds for the life of the process. A `DispatchSourceTimer` rather than
    /// a `Timer` because there is no run loop on `queue` to schedule one on.
    public func start() {
        guard policy.checksAutomatically else { return }
        checkNow()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + policy.interval, repeating: policy.interval)
        source.setEventHandler { [weak self] in self?.checkNow() }
        source.resume()
        timer = source
    }

    /// What the "업데이트 확인" button does. Safe to call at any time; a check
    /// already in flight simply wins.
    public func checkNow() {
        queue.async { [weak self] in
            guard let self, !self.isWorking else { return }
            self.isWorking = true
            defer { self.isWorking = false }

            self.publish(.checking)
            do {
                let decision = try self.installer.check(
                    feed: self.feed, assetName: self.assetName, current: self.current
                )
                guard case .available(let release) = decision else {
                    self.publish(.upToDate)
                    return
                }
                guard self.policy.downloadsAutomatically else {
                    self.publish(.available(release.version))
                    return
                }
                self.publish(.downloading(release.version))
                try self.download()
            } catch {
                self.publish(self.statusFor(error))
            }
        }
    }

    /// Fetches and verifies, leaving the copy beside the installation.
    private func download() throws {
        let staged = try installer.stage(
            feed: feed, assetName: assetName, current: current, layout: layout
        )
        guard let staged else {
            // The release vanished between the check and the download. Rare, but
            // the honest answer is the one the next check will give anyway.
            publish(.upToDate)
            return
        }
        self.staged = staged
        if policy.installsAutomatically {
            try installer.commit(staged)
            self.staged = nil
        }
        publish(.downloaded(staged.version))
    }

    /// Swaps the staged copy in. Returns the version installed, or nil when
    /// nothing was waiting.
    ///
    /// Synchronous and main-thread: it is a rename of an already-verified copy,
    /// so there is no network in it, and the caller usually wants to relaunch on
    /// the very next line.
    @discardableResult
    public func installStaged() throws -> SemanticVersion? {
        guard let staged else { return nil }
        try installer.commit(staged)
        self.staged = nil
        status = .upToDate
        onChange?(status)
        return staged.version
    }

    /// Drops a verified download without installing it. Call on the way out --
    /// see `UpdateInstaller.discard`.
    public func discardStaged() {
        guard let staged else { return }
        installer.discard(staged)
        self.staged = nil
    }

    /// "아직 배포된 릴리스가 없다" is a normal state, not a failure.
    ///
    /// Before the first release the feed answers 404, and a first-run user would
    /// otherwise be shown a red error for the software working exactly as
    /// intended. Measured: `trolley update --check` against the empty feed exits
    /// 1 with `Error:` today, which is the thing this converts.
    private func statusFor(_ error: Error) -> UpdateStatus {
        if let updateError = error as? UpdateError, case .noRelease = updateError {
            return .upToDate
        }
        return .failed(String(describing: error))
    }

    private func publish(_ next: UpdateStatus) {
        toMain { [weak self] in
            guard let self, self.status != next else { return }
            self.status = next
            self.onChange?(next)
        }
    }
}
