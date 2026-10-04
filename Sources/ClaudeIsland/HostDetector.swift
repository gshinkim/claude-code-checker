import Foundation

struct Proc {
    var ppid: Int32
    var tty: String
    var comm: String
}

enum HostDetector {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    private static func baseName(_ comm: String) -> String {
        let name = comm.split(separator: "/").last.map(String.init) ?? comm
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    static func resolve(start: Int32, table: [Int32: Proc]) -> (pid: Int32, tty: String?, appPath: String?) {
        var pid = start
        while let p = table[pid], shells.contains(baseName(p.comm)), p.ppid > 1 { pid = p.ppid }

        let rawTTY = table[pid]?.tty ?? "??"
        let tty = rawTTY.hasPrefix("tty") ? "/dev/" + rawTTY : nil

        // Start at the parent: Claude Code's own binary can live in a claude.app bundle.
        var cur = table[pid]?.ppid ?? 0, hops = 0
        while let p = table[cur], hops < 32 {
            if let r = p.comm.range(of: ".app/") {
                return (pid, tty, String(p.comm[..<r.lowerBound]) + ".app")
            }
            cur = p.ppid
            hops += 1
        }
        return (pid, tty, nil)
    }

    static func processTable() -> [Int32: Proc] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,tty=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [:] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var table: [Int32: Proc] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            table[pid] = Proc(ppid: ppid, tty: String(f[2]), comm: f[3].trimmingCharacters(in: .whitespaces))
        }
        return table
    }

    static func detect() -> Host {
        let r = resolve(start: getppid(), table: processTable())
        let name = r.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? ProcessInfo.processInfo.environment["TERM_PROGRAM"]
        return Host(pid: r.pid, tty: r.tty,
                    bundleId: r.appPath.flatMap { Bundle(path: $0)?.bundleIdentifier },
                    name: name)
    }
}
