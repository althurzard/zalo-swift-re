import Darwin
import Foundation
import Security

/// Checks of the native call helper before Olaz runs it.
enum CallHelperSignature {
    /// Zalo's Developer ID team (VNG ONLINE CO.,LTD) and the helper's bundle identifier.
    static let requirement = #"anchor apple generic and identifier "com.vng.zalo.zalocall" and certificate leaf[subject.OU] = "CVB6BX97VM""#

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `ZaloHelper.app` containing `executable` (`…/ZaloHelper.app/Contents/MacOS/ZaloCall`).
    static func bundleURL(forExecutable executable: URL) -> URL {
        executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Full static validation of the helper bundle (all architectures) against `requirement`.
    static func verify(executable: URL, requirement: String = requirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL(forExecutable: executable) as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure(message: "Không đọc được chữ ký của trình gọi Zalo.")
        }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            throw Failure(message: "Yêu cầu chữ ký không hợp lệ.")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), parsed)
        guard status == errSecSuccess else {
            throw Failure(message: "Trình gọi của Zalo không có chữ ký hợp lệ của VNG nên ứng dụng không chạy nó (mã \(status)).")
        }
    }
}

/// Helpers left behind by an Olaz that crashed or was force-quit: identified by their argv, which points
/// into one of our `olaz-call-<pid>-…` / `szc-<pid>-…` socket directories whose owner pid is dead.
/// Other ZaloCall processes (for example the official Zalo's, which uses `/tmp/socketzalorecv2021`) never match.
enum CallOrphans {
    static let directoryPrefixes = ["olaz-call-", "swiftzalo-call-", "szc-"]

    /// The pid encoded in a socket directory name (`olaz-call-<pid>-XXXXXX`, legacy `…-<pid>`).
    static func ownerPID(ofDirectoryNamed name: String) -> pid_t? {
        for prefix in directoryPrefixes where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            return pid_t(rest.prefix { $0.isNumber })
        }
        return nil
    }

    /// For helper argv `[exe, recvPath, sendPath]`: the dead owner's pid when it is one of our stale directories.
    static func staleOwner(argv: [String]) -> pid_t? {
        guard argv.count >= 3 else { return nil }
        let recv = URL(fileURLWithPath: argv[1]), send = URL(fileURLWithPath: argv[2])
        guard recv.lastPathComponent == "recv", send.lastPathComponent == "send",
              recv.deletingLastPathComponent() == send.deletingLastPathComponent(),
              let owner = ownerPID(ofDirectoryNamed: recv.deletingLastPathComponent().lastPathComponent),
              owner != getpid(), kill(owner, 0) != 0, errno == ESRCH else { return nil }
        return owner
    }

    /// Terminates our orphaned helpers; returns their pids.
    @discardableResult
    static func reap(helperExecutable: URL) -> [pid_t] {
        let helperPath = helperExecutable.resolvingSymlinksInPath().path
        var reaped: [pid_t] = []
        for pid in allPIDs() where pid != getpid() {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path == helperPath,
                  owner(of: pid) == getuid(),
                  let argv = arguments(of: pid), staleOwner(argv: argv) != nil else { continue }
            kill(pid, SIGTERM)
            reaped.append(pid)
        }
        if !reaped.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                for pid in reaped where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        return reaped
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(filled)))).filter { $0 > 0 }
    }

    private static func owner(of pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }

    /// `KERN_PROCARGS2`: argv of a process of this user (including argv[0]).
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Data(data.prefix(size)))
    }

    /// Layout: `int argc`, executable path, NUL padding, `argc` NUL-terminated arguments, environment.
    static func parseProcArgs(_ data: Data) -> [String]? {
        guard data.count > 4 else { return nil }
        let argc = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 1024 else { return nil }
        var index = data.startIndex + 4
        while index < data.endIndex, data[index] != 0 { index += 1 }      // executable path
        while index < data.endIndex, data[index] == 0 { index += 1 }      // padding
        var args: [String] = []
        while args.count < Int(argc), index < data.endIndex {
            var end = index
            while end < data.endIndex, data[end] != 0 { end += 1 }
            args.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end + 1
        }
        return args.count == Int(argc) ? args : nil
    }
}
