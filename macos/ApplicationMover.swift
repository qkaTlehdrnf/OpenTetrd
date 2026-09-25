import AppKit
import Darwin
import Foundation

/// Offers to move the app into /Applications when it is launched from somewhere else
/// (a mounted disk image, Downloads, the Desktop), like most downloaded Mac apps do.
enum ApplicationMover {
    private static let skipKey = "OpenTetrdSkipMoveToApplications"

    /// Returns true when the app is being moved and relaunched; the caller should stop setting up.
    static func offerMoveIfNeeded() -> Bool {
        // A quarantined app opened from a disk image or Downloads runs from a random
        // translocation path; resolve where the bundle really lives first.
        let source = originalLocation(of: Bundle.main.bundleURL).resolvingSymlinksInPath()
        guard source.pathExtension == "app",
              !isInApplicationsFolder(source),
              !UserDefaults.standard.bool(forKey: skipKey) else { return false }

        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        let diskImageVolume = readOnlyVolume(of: source)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Applications 폴더로 옮길까요?"
        alert.informativeText = diskImageVolume != nil
            ? "지금 디스크 이미지에서 OpenTetrd를 실행하고 있습니다. Applications 폴더로 복사하면 디스크 이미지를 꺼낸 뒤에도 Launchpad와 Spotlight에서 바로 실행할 수 있습니다."
            : "OpenTetrd를 Applications 폴더에 두면 Launchpad와 Spotlight에서 바로 실행할 수 있습니다."
        alert.addButton(withTitle: "Applications로 이동")
        alert.addButton(withTitle: "나중에")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "다시 묻지 않기"

        guard alert.runModal() == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: skipKey)
            }
            return false
        }

        do {
            if isRunning(at: destination) {
                throw AppError.message("Applications 폴더의 OpenTetrd가 실행 중입니다. 종료한 뒤 다시 시도하세요.")
            }
            try install(from: source, to: destination)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Applications 폴더로 옮기지 못했습니다"
            failure.informativeText = "\(error.localizedDescription)\n\nFinder에서 OpenTetrd를 Applications 폴더로 직접 드래그해도 됩니다."
            failure.runModal()
            return false
        }

        // Leave the original only where it cannot or should not be removed:
        // a read-only disk image, or a Gatekeeper-translocated copy whose real location is hidden.
        if diskImageVolume == nil && !source.path.contains("/AppTranslocation/") {
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
        relaunch(destination, ejecting: diskImageVolume)
        return true
    }

    private typealias IsTranslocatedFunction = @convention(c)
        (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
    private typealias OriginalPathFunction = @convention(c)
        (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// Maps an App Translocation path back to the bundle the user actually opened.
    private static func originalLocation(of url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        else { return url }
        defer { dlclose(security) }
        guard let isTranslocatedSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalPathSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return url }
        let isTranslocated = unsafeBitCast(isTranslocatedSymbol, to: IsTranslocatedFunction.self)
        let originalPath = unsafeBitCast(originalPathSymbol, to: OriginalPathFunction.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil) != 0, translocated,
              let original = originalPath(url as CFURL, nil) else { return url }
        return original.takeRetainedValue() as URL
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.path
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        return folders.contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    private static func readOnlyVolume(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey])
        guard values?.volumeIsReadOnly == true, let volume = values?.volumeURL,
              volume.path.hasPrefix("/Volumes/") else { return nil }
        return volume
    }

    private static func isRunning(at url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath().path == target
        }
    }

    private static func install(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        do {
            if files.fileExists(atPath: destination.path) {
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            try files.copyItem(at: source, to: destination)
        } catch {
            // Standard users cannot write to /Applications; ask for an administrator once.
            try installAsAdministrator(from: source, to: destination)
        }
        // Finder clears the quarantine flag on the bundle folder when the user drags an app
        // out of a disk image; without it macOS keeps running the copy from a translocation path.
        removexattr(destination.path, "com.apple.quarantine", 0)
    }

    private static func installAsAdministrator(from source: URL, to destination: URL) throws {
        func quoted(_ path: String) -> String {
            "quoted form of \"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = "\"/bin/rm -rf \" & \(quoted(destination.path)) & \" && /usr/bin/ditto \" & "
            + "\(quoted(source.path)) & \" \" & \(quoted(destination.path)) & "
            + "\" && /usr/sbin/chown -R \(getuid()):\(getgid()) \" & \(quoted(destination.path))"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(command) with administrator privileges")?
            .executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "관리자 권한으로 복사하지 못했습니다"
            throw AppError.message(message)
        }
    }

    private static func relaunch(_ app: URL, ejecting volume: URL?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$1"
        if [ -n "$2" ]; then /usr/bin/hdiutil detach "$2" -quiet || true; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "opentetrd-relaunch", app.path, volume?.path ?? ""]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(app)
        }
        NSApp.terminate(nil)
    }
}
