import Foundation
import MacExplorerCore

/// macOS runs a quarantined app that wasn't moved with Finder from a random read-only copy ("App Translocation"),
/// so the in-app updater can't replace it. The app is notarized and the user already approved it in Gatekeeper,
/// so at launch we clear the quarantine flag on the original copy and relaunch from there.
enum AppTranslocation {
    private typealias IsTranslocatedFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPathFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// Returns true when a relaunch from the original location has been scheduled; the caller must then exit
    /// without saving the session.
    static func relaunchFromOriginalIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", let original = originalURL(of: bundle),
              UpdateInfo.canReplace(app: original) else { return false }
        // In-process (not via /usr/bin/xattr) so macOS App Management attributes the change to this app,
        // which may modify its own bundle in /Applications because the team ID matches.
        removeQuarantine(original)
        // If the flag is still there, relaunching would be translocated again (and loop).
        guard getxattr(original.path, quarantine, nil, 0, 0, 0) < 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                             original.path]
        do { try process.run() } catch { return false }
        return true
    }

    private static let quarantine = "com.apple.quarantine"

    private static func removeQuarantine(_ bundle: URL) {
        removexattr(bundle.path, quarantine, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items { removexattr(item.path, quarantine, XATTR_NOFOLLOW) }
    }

    /// The original bundle URL when running translocated, otherwise nil. Uses Security.framework's
    /// SecTranslocate functions (available since macOS 10.12, not in the public headers).
    private static func originalURL(of bundle: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let originalSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocatedFn.self)
        let createOriginal = unsafeBitCast(originalSym, to: OriginalPathFn.self)
        var translocated = false
        guard isTranslocated(bundle as CFURL, &translocated, nil), translocated,
              let original = createOriginal(bundle as CFURL, nil)?.takeRetainedValue() else { return nil }
        return original as URL
    }
}
