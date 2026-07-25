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
/// `proc_pidinfo` requires the target to be owned by the same user, which the
/// pane's shell is: Ghostty spawns it through `login -flp`, which drops root.
/// baia is unsandboxed, so no entitlement is involved.
public enum ProcessWorkingDirectory {
    public static func url(ofProcess pid: pid_t) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let string = String(cString: base.assumingMemoryBound(to: CChar.self))
            return string.isEmpty ? nil : string
        }
        guard let path else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
