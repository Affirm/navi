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

/// If `paneTTY` matches a tmux pane, return the tmux switch target
/// ("session:window.pane") and the TTY of a client we can use to reach it
/// (the TTY of the host terminal emulator). Prefers a client already attached
/// to the target session; otherwise falls back to any attached client, since
/// `tmux switch-client -c X -t session:...` moves X to the target session
/// even if X is currently attached to a different session. Returns nil when
/// tmux isn't installed, the TTY isn't a pane, or no client is attached at all.
private func tmuxTargetForPane(_ paneTTY: String) -> (target: String, clientTTY: String)? {
    guard let panes = runTmux(["list-panes", "-a", "-F", "#{pane_tty}|#{session_name}|#{window_index}.#{pane_index}"]) else {
        return nil
    }
    var session: String?
    var target: String?
    for line in panes.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, String(parts[0]) == paneTTY else { continue }
        session = String(parts[1])
        target = "\(parts[1]):\(parts[2])"
        break
    }
    guard let session = session, let target = target else { return nil }
    if let attached = runTmux(["list-clients", "-t", session, "-F", "#{client_tty}"]),
       let clientTTY = attached.split(separator: "\n").first.map(String.init),
       !clientTTY.isEmpty {
        return (target, clientTTY)
    }
    guard let anyClients = runTmux(["list-clients", "-F", "#{client_tty}"]),
          let clientTTY = anyClients.split(separator: "\n").first.map(String.init),
          !clientTTY.isEmpty
    else { return nil }
    return (target, clientTTY)
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

/// Activate the terminal owning `tty`. If the TTY is a tmux pane, first switch
/// the attached tmux client to that pane, then focus the terminal emulator
/// that hosts the client.
public func focusTerminal(tty: String) {
    guard !tty.isEmpty else { return }
    guard tty.range(of: #"^/dev/tty[a-zA-Z0-9]+$"#, options: .regularExpression) != nil else {
        naviLog("focusTerminal: invalid tty format: %@", tty)
        return
    }
    naviLog("focusTerminal: looking for tty=%@", tty)

    if let t = tmuxTargetForPane(tty) {
        naviLog("focusTerminal: tmux pane → %@ via client %@", t.target, t.clientTTY)
        _ = runTmux(["switch-client", "-c", t.clientTTY, "-t", t.target])
        activateTerminalApp(tty: t.clientTTY)
        return
    }

    activateTerminalApp(tty: tty)
}
