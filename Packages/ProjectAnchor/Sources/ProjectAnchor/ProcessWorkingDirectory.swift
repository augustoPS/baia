import Darwin
import Foundation

/// Reads a process's current working directory from the kernel.
///
/// The alternative is OSC 7, which the terminal cannot supply here: the bundled
/// libghostty is a trimmed build with no shell-integration resources, nothing
/// wires ZDOTDIR, and macOS gates its own OSC 7 emitter in /etc/zshrc on
/// TERM_PROGRAM=Apple_Terminal. Asking the kernel needs no shell cooperation and
/// works for any program running in the pane.
///
/// `proc_pidinfo` requires the caller to share the target's effective uid *or* to
/// be privileged, so root can inspect any process. Immaterial for baia, which
/// runs as the user and inspects the pane's shell: Ghostty spawns it through
/// `login -flp`, which drops root. baia is unsandboxed, so no entitlement is
/// involved.
public enum ProcessWorkingDirectory {
    public static func url(ofProcess pid: pid_t) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        // `vip_path` is a fixed MAXPATHLEN buffer and `String(cString:)` trusts
        // NUL termination, so an unterminated buffer would read on past the field
        // into the rest of the struct. `strnlen` bounds the read to the field.
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let length = strnlen(base.assumingMemoryBound(to: CChar.self), raw.count)
            guard length > 0 else { return nil }
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
        guard let path else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
