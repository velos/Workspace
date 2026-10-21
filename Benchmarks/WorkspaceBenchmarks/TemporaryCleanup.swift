#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Signal handlers run on a dispatch queue, never in an async-signal context.
/// The parent's temporary root contains child scratch trees as a fallback.
final class TemporaryCleanup: @unchecked Sendable {
    static let shared = TemporaryCleanup()
    private let lock = NSLock()
    private var roots: Set<URL> = []
    private var children: [Process] = []
    private var mainStopped = false
    private var interruptSignal: Int32?
    private var sources: [DispatchSourceSignal] = []

    private init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let state = self.lock.withLock {
                    self.interruptSignal = number
                    return (self.roots, self.children)
                }
                for child in state.1 where child.isRunning { kill(child.processIdentifier, number) }
                let deadline = Date().addingTimeInterval(1)
                while state.1.contains(where: { $0.isRunning }), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                for child in state.1 where child.isRunning { kill(child.processIdentifier, SIGKILL) }
                // Wait until the main path stops creating files. Synchronous fixture
                // generation checks the flag between files; async runs check between
                // operations. The parent forcibly stops slow children before cleanup.
                while !self.lock.withLock({ self.mainStopped }) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                let roots = self.lock.withLock { self.roots }
                for root in roots { try? FileManager.default.removeItem(at: root) }
                exit(128 + number)
            }
            source.resume()
            sources.append(source)
        }
    }

    // Keep main alive while the handler interrupts children and removes roots.
    // Otherwise a quickly exiting child can make main exit before cleanup finishes.
    func finishInterruptIfNeeded() async {
        guard
            lock.withLock({
                guard interruptSignal != nil else { return false }
                mainStopped = true
                return true
            })
        else { return }
        while true { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func checkInterrupt() throws {
        if lock.withLock({ interruptSignal != nil }) {
            throw BenchmarkError.message("interrupted")
        }
    }

    func register(_ root: URL) { lock.withLock { _ = roots.insert(root) } }
    func unregister(_ root: URL) { lock.withLock { _ = roots.remove(root) } }
    func register(_ child: Process) {
        let interrupted = lock.withLock {
            children.append(child)
            return interruptSignal != nil
        }
        if interrupted { kill(child.processIdentifier, SIGKILL) }
    }
    func unregister(_ child: Process) { lock.withLock { children.removeAll { $0 === child } } }
}

#endif
