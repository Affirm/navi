import Foundation

/// Run tmux with the given args directly via Process(), bypassing /bin/sh so
/// session names and other tmux arguments cannot be interpreted as shell
/// metacharacters. Returns trimmed stdout, or nil on failure / empty output.
///
/// Resolution order: `NAVI_TMUX_PATH` env var (escape hatch for MacPorts,
/// Nix, or custom Homebrew prefixes), then the standard install locations.
private func runTmux(_ args: [String]) -> String? {
    var candidatePaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    if let override = ProcessInfo.processInfo.environment["NAVI_TMUX_PATH"], !override.isEmpty {
        candidatePaths.insert(override, at: 0)
    }
    guard let path = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return nil
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    } catch {
        return nil
    }
}

/// The tmux coordinates needed to focus a pane: the session name, the
/// window target ("session:window"), the pane target ("session:window.pane"),
/// and the TTY of a client we can use to reach it (the host terminal emulator).
/// Keeping the three levels separate lets `focusTerminal` issue an explicit
/// session → window → pane sequence (see `focusTerminal`).
private struct TmuxPaneTarget {
    let session: String
    let window: String   // "session:window_index"
    let pane: String     // "session:window_index.pane_index"
    let clientTTY: String
}

/// Resolve a client TTY we can drive to reach `session`. Prefers a client
/// already attached to the target session; otherwise falls back to any
/// attached client, since `tmux switch-client -c X -t session:...` moves X to
/// the target session even if X is currently attached to a different session.
/// Returns nil when no client is attached at all.
private func tmuxClientTTY(forSession session: String) -> String? {
    if let attached = runTmux(["list-clients", "-t", session, "-F", "#{client_tty}"]),
       let clientTTY = attached.split(separator: "\n").first.map(String.init),
       !clientTTY.isEmpty {
        return clientTTY
    }
    return runTmux(["list-clients", "-F", "#{client_tty}"])?
        .split(separator: "\n").first.map(String.init)
        .flatMap { $0.isEmpty ? nil : $0 }
}

/// If `paneTTY` matches a tmux pane, return its `TmuxPaneTarget`. Returns nil
/// when tmux isn't installed, the TTY isn't a pane, or no client is attached.
private func tmuxTargetForPane(_ paneTTY: String) -> TmuxPaneTarget? {
    guard !paneTTY.isEmpty,
          let panes = runTmux(["list-panes", "-a", "-F", "#{pane_tty}|#{session_name}|#{window_index}|#{pane_index}"])
    else { return nil }
    for line in panes.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, String(parts[0]) == paneTTY else { continue }
        let session = String(parts[1])
        guard let clientTTY = tmuxClientTTY(forSession: session) else { return nil }
        return TmuxPaneTarget(
            session: session,
            window: "\(session):\(parts[2])",
            pane: "\(session):\(parts[2]).\(parts[3])",
            clientTTY: clientTTY)
    }
    return nil
}

/// One-shot snapshot of pid → ppid for the whole system, so the ancestor walk
/// runs in-process instead of spawning `ps` per hop.
private func buildPPIDMap() -> [pid_t: pid_t] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-A", "-o", "pid=,ppid="]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return [:] }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let out = String(data: data, encoding: .utf8) else { return [:] }
    var map: [pid_t: pid_t] = [:]
    for line in out.split(separator: "\n") {
        let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard cols.count >= 2, let pid = pid_t(cols[0]), let ppid = pid_t(cols[1]) else { continue }
        map[pid] = ppid
    }
    return map
}

/// Resolve the tmux pane that owns `pid` by walking its parent-process chain
/// (up to `maxHops`) until an ancestor matches a pane's shell pid. This is the
/// fallback for when Navi has no usable TTY for a session — e.g. `ps -o tty`
/// reported `??` (piped stdin) at discovery — since process ancestry works
/// regardless of the controlling terminal. Mirrors triage's `find_owning_pane`.
private func tmuxTargetForPID(_ pid: pid_t, maxHops: Int = 8) -> TmuxPaneTarget? {
    guard pid > 0,
          let panes = runTmux(["list-panes", "-a", "-F", "#{pane_pid}|#{session_name}|#{window_index}|#{pane_index}"])
    else { return nil }
    var paneByPID: [pid_t: (session: String, window: String, pane: String)] = [:]
    for line in panes.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let panePID = pid_t(parts[0]) else { continue }
        let session = String(parts[1])
        paneByPID[panePID] = (session, "\(session):\(parts[2])", "\(session):\(parts[2]).\(parts[3])")
    }
    guard !paneByPID.isEmpty else { return nil }
    let ppidMap = buildPPIDMap()
    var cur = pid
    for _ in 0..<maxHops {
        guard let ppid = ppidMap[cur], ppid > 1 else { break }
        if let m = paneByPID[ppid] {
            guard let clientTTY = tmuxClientTTY(forSession: m.session) else { return nil }
            return TmuxPaneTarget(session: m.session, window: m.window, pane: m.pane, clientTTY: clientTTY)
        }
        cur = ppid
    }
    return nil
}

/// Activate the terminal emulator tab/session that owns `tty` via AppleScript
/// (iTerm2 or Terminal.app).
private func activateTerminalApp(tty: String) {
    let iTermScript = """
    tell application "System Events"
        if not (exists process "iTerm2") then return false
    end tell
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                        select t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return false
    """

    let terminalScript = """
    tell application "System Events"
        if not (exists process "Terminal") then return false
    end tell
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
    end tell
    return false
    """

    for source in [iTermScript, terminalScript] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if out == "true" {
                naviLog("activateTerminalApp: activated tty=%@", tty)
                return
            }
        } catch {
            naviLog("activateTerminalApp: osascript error: %@", error.localizedDescription)
        }
    }
    naviLog("activateTerminalApp: no terminal found for tty=%@", tty)
}

/// Activate the terminal owning a session. If the session lives in a tmux pane,
/// first switch the attached tmux client to that pane, then focus the terminal
/// emulator that hosts the client.
///
/// Pane resolution tries the TTY first, then falls back to a parent-process
/// walk from `pid` (for sessions where Navi never captured a usable TTY, e.g.
/// piped stdin reported as `??`). Pass `pid: 0` to skip the fallback.
public func focusTerminal(tty: String, pid: pid_t = 0) {
    let ttyValid = !tty.isEmpty
        && tty.range(of: #"^/dev/tty[a-zA-Z0-9]+$"#, options: .regularExpression) != nil
    if !tty.isEmpty && !ttyValid {
        naviLog("focusTerminal: invalid tty format: %@", tty)
    }
    naviLog("focusTerminal: looking for tty=%@ pid=%d", tty, Int(pid))

    // Three-step pin: session via switch-client, window via select-window,
    // pane via select-pane. switch-client alone doesn't reliably change the
    // client's *active window* when the target window differs from the one the
    // client is currently on — so "Jump to Terminal" could land on the right
    // session but the wrong window. Being explicit at all three levels
    // guarantees the pane is focused.
    let target = (ttyValid ? tmuxTargetForPane(tty) : nil) ?? tmuxTargetForPID(pid)
    if let t = target {
        naviLog("focusTerminal: tmux pane → %@ via client %@", t.pane, t.clientTTY)
        _ = runTmux(["switch-client", "-c", t.clientTTY, "-t", t.session])
        _ = runTmux(["select-window", "-t", t.window])
        _ = runTmux(["select-pane", "-t", t.pane])
        activateTerminalApp(tty: t.clientTTY)
        return
    }

    // No tmux pane — focus the terminal emulator directly by TTY.
    if ttyValid {
        activateTerminalApp(tty: tty)
    }
}
