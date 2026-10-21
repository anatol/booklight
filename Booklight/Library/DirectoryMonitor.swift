import Foundation

/// Watches directories for entries being added, removed or renamed.
///
/// Atomic writes (ours, and those of sync tools like Syncthing) replace files
/// via rename, which shows up as a write to the containing directory, so this
/// catches progress updates from other devices without polling. Events are
/// coalesced and delivered on the main actor.
@MainActor
final class DirectoryMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?
    private let onChange: @MainActor () -> Void
    private let debounce: Duration

    /// True while every watched directory still exists under its original name.
    /// A monitor whose directory was deleted or moved stops receiving events and
    /// should be recreated.
    private(set) var isValid = true

    init(directories: [URL], debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.debounce = debounce

        for directory in directories {
            let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else {
                isValid = false
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                let events = source?.data ?? []
                MainActor.assumeIsolated {
                    self?.handle(events)
                }
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
    }

    func cancel() {
        debounceTask?.cancel()
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            isValid = false
        }

        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
