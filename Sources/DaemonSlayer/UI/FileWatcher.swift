import Foundation

/// A minimal DispatchSource file watcher that survives atomic-rename replacement
/// (the StateStore writes state.json via tmp + rename, so our fd points at the old
/// inode after each write). On a delete/rename event it closes, re-opens the path
/// — with a short retry while the rename is momentarily mid-flight — and re-arms,
/// then fires `onChange`. Same self-healing pattern as ConfigStore.armSource.
///
/// All work happens on the caller-supplied serial `queue`; `onChange` fires there.
final class FileWatcher {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var cancelled = false

    private static let reopenRetryMillis = 80

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    deinit { cancel() }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.cancelled = true
            self.source?.cancel()
            self.source = nil
        }
    }

    private func arm() {
        guard !cancelled else { return }
        source?.cancel()
        source = nil

        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            // Path momentarily absent (rename in flight) or never written yet. Retry
            // shortly; a missing state.json is normal before the agent's first poll.
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.reopenRetryMillis)) { [weak self] in
                self?.arm()
            }
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Inode swapped out by the atomic rename — re-open the path and re-arm,
                // then report the change so the reader picks up the new file.
                self.arm()
            }
            self.onChange()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
}
