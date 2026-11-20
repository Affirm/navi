import Testing
import Foundation
@testable import NaviCore

/// In-memory filesystem with fnmatch-based globbing.
private struct FakeFS: SSHConfigFileSystem {
    var files: [String: String]
    func contents(of path: String) -> String? { files[path] }
    func glob(_ pattern: String) -> [String] {
        files.keys.filter { fnmatch(pattern, $0, FNM_PATHNAME) == 0 }.sorted()
    }
}

@Suite("SSHConfigParser")
struct SSHConfigParserTests {
    private let home = "/Users/me"

    @Test func listsConcreteHostsAndSkipsPatterns() {
        let fs = FakeFS(files: ["/Users/me/.ssh/config": """
        # comment
        Host devbox gpu-1
          HostName 10.0.0.5
          User me
        Host *.internal !bad * web-?
        Host=build
        Host = staging
        host "quoted-host"
        Match host devbox exec "true"
          ForwardAgent yes
        Host devbox
        """])
        #expect(SSHConfigParser.hostAliases(home: home, fs: fs) ==
                ["devbox", "gpu-1", "build", "staging", "quoted-host"])
    }

    @Test func followsIncludesRelativeAbsoluteTildeAndGlobs() {
        let fs = FakeFS(files: [
            "/Users/me/.ssh/config": "Include config.d/*\nInclude ~/other.conf\nInclude /etc/ssh/extra\nHost main",
            "/Users/me/.ssh/config.d/a.conf": "Host alpha",
            "/Users/me/.ssh/config.d/b.conf": "Host beta\nInclude nested",
            "/Users/me/.ssh/nested": "Host gamma",
            "/Users/me/other.conf": "Host delta",
            "/etc/ssh/extra": "Host epsilon",
        ])
        #expect(SSHConfigParser.hostAliases(home: home, fs: fs) ==
                ["alpha", "beta", "gamma", "delta", "epsilon", "main"])
    }

    @Test func includeCyclesTerminate() {
        let fs = FakeFS(files: [
            "/Users/me/.ssh/config": "Host a\nInclude config",
        ])
        #expect(SSHConfigParser.hostAliases(home: home, fs: fs) == ["a"])
    }

    @Test func missingConfigIsEmpty() {
        #expect(SSHConfigParser.hostAliases(home: home, fs: FakeFS(files: [:])).isEmpty)
    }

    @Test func rejectsAliasesThatLookLikeOptions() {
        let fs = FakeFS(files: ["/Users/me/.ssh/config": "Host -oProxyCommand=x ok"])
        #expect(SSHConfigParser.hostAliases(home: home, fs: fs) == ["ok"])
    }

    @Test func effectiveConfigParse() {
        let out = "user me\nhostname 10.0.0.5\nport 2222\nproxyjump bastion\nidentityfile ~/.ssh/id\n"
        let c = SSHEffectiveConfig.parse(out)
        #expect(c == SSHEffectiveConfig(hostname: "10.0.0.5", user: "me", port: "2222", proxyJump: "bastion"))
        #expect(c.summary == "me@10.0.0.5:2222 via bastion")
        #expect(SSHEffectiveConfig.parse("hostname h\nport 22\nproxyjump none").summary == "h")
        #expect(SSHEffectiveConfig.resolveSpec(alias: "devbox").arguments == ["-G", "--", "devbox"])
    }
}

@Suite("RemoteSetup")
struct RemoteSetupTests {
    @Test func probeParse() {
        let r = HostProbe.parse("claude_path=/home/me/.local/bin/claude\nclaude_version=2.1.270 (Claude Code)\npython3=/usr/bin/python3\nuser=me\n")
        #expect(r.claudePath == "/home/me/.local/bin/claude")
        #expect(r.version == ClaudeVersion(2, 1, 270))
        #expect(r.problems.isEmpty)
        #expect(r.summary == "user me · claude 2.1.270 · python3 ok")
    }

    @Test func probeReportsMissingTools() {
        let r = HostProbe.parse("claude_path=\nclaude_version=\npython3=\nuser=me\n")
        #expect(r.problems.count == 2)
        #expect(r.version == nil)
    }

    @Test func probeCommandUsesLoginShell() {
        #expect(HostProbe.remoteCommand.hasPrefix("bash -lc '"))
        #expect(HostProbe.remoteCommand.hasSuffix("'"))
    }

    @Test func versionCompare() {
        #expect(ClaudeVersion.parse("2.1.268")!.supportsInstallJSON)
        #expect(!ClaudeVersion.parse("v2.1.99")!.supportsInstallJSON)
        #expect(ClaudeVersion.parse("3.0.0")!.supportsInstallJSON)
        #expect(ClaudeVersion.parse("nope") == nil)
    }

    @Test func installStepsDependOnVersion() {
        let new = RemoteInstall.installSteps(version: ClaudeVersion(2, 1, 300))
        #expect(new.map(\.command) == [
            "claude plugin marketplace add Affirm/navi --scope user",
            "claude plugin install navi@navi --scope user --json",
        ])
        #expect(new[1].parsesJSON && new[1].fallback.isEmpty)
        let old = RemoteInstall.installSteps(version: ClaudeVersion(2, 0, 1))
        #expect(old[1].command == "claude plugin install navi@navi --scope user")
        #expect(!old[1].parsesJSON)
        let unknown = RemoteInstall.installSteps(version: nil)
        #expect(unknown[1].parsesJSON)
        #expect(unknown[1].fallback.map(\.command) == ["claude plugin install navi@navi --scope user"])
        #expect(RemoteInstall.offlineInstallSteps(version: nil)[0].command
                == "claude plugin marketplace add ~/.navi/plugin --scope user")
        #expect(RemoteInstall.uninstallSteps().map(\.command) == ["claude plugin uninstall navi@navi --scope user"])
    }

    @Test func stepCommandsNeverContainSingleQuotes() {
        let all = RemoteInstall.installSteps(version: nil) + RemoteInstall.uninstallSteps()
            + RemoteInstall.offlineInstallSteps(version: nil) + RemoteInstall.installSteps(version: nil).flatMap(\.fallback)
        for step in all { #expect(!step.command.contains("'"), "\(step.command)") }
        #expect(RemoteInstall.displayCommand(alias: "d", step: all[0])
                == "ssh d bash -lc 'claude plugin marketplace add Affirm/navi --scope user'")
    }

    private func out(_ code: Int32, _ stdout: String = "", _ stderr: String = "", timedOut: Bool = false) -> ProcessRunner.Output {
        ProcessRunner.Output(exitCode: code, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    @Test func interpretJSONOutcome() {
        let step = RemoteInstall.installSteps(version: ClaudeVersion(2, 1, 300))[1]
        let ok = RemoteInstall.interpret(step: step, alias: "d",
            output: out(0, "Installing…\n{\"outcome\":\"ok\",\"message\":\"Installed navi\"}\n"))
        #expect(ok == .init(ok: true, message: "Installed navi"))
        let failed = RemoteInstall.interpret(step: step, alias: "d",
            output: out(1, "{\"outcome\":\"failed\",\"message\":\"Plugin not found\"}"))
        #expect(failed == .init(ok: false, message: "Plugin not found"))
    }

    @Test func interpretFallsBackWhenJSONUnsupported() {
        let step = RemoteInstall.installSteps(version: nil)[1]
        let r = RemoteInstall.interpret(step: step, alias: "d",
            output: out(1, "", "error: unknown option '--json'"))
        #expect(r.needsFallback)
    }

    @Test func interpretPlainAndAlready() {
        let add = RemoteInstall.installSteps(version: nil)[0]
        #expect(RemoteInstall.interpret(step: add, alias: "d", output: out(0, "Added marketplace navi")).ok)
        let already = RemoteInstall.interpret(step: add, alias: "d",
            output: out(1, "", "Marketplace 'navi' is already installed"))
        #expect(already == .init(ok: true, message: "Already added"))
        let fail = RemoteInstall.interpret(step: add, alias: "d", output: out(1, "", "boom\nnetwork error"))
        #expect(fail == .init(ok: false, message: "network error"))
    }

    @Test func interpretSSHFailureAndTimeout() {
        let step = RemoteInstall.uninstallSteps()[0]
        let ssh = RemoteInstall.interpret(step: step, alias: "d",
            output: out(255, "", "Host key verification failed."))
        #expect(!ssh.ok && ssh.message.contains("ssh d"))
        #expect(RemoteInstall.interpret(step: step, alias: "d", output: out(0, timedOut: true)).message == "Timed out")
    }

    @Test func uploadSpecPassesPathsAsArguments() {
        let spec = RemoteInstall.uploadSpec(pluginDir: "/Users/me/my plugin; rm -rf ~", alias: "devbox")
        #expect(spec.executable.path == "/bin/sh")
        #expect(spec.arguments[0] == "-c")
        #expect(!spec.arguments[1].contains("my plugin"))
        #expect(spec.arguments[3] == "/Users/me/my plugin; rm -rf ~")
        #expect(spec.arguments[4] == "devbox")
    }

    @Test func localPluginDirDetection() {
        let present: Set<String> = ["/repo/.claude-plugin/marketplace.json", "/repo/hooks/hook.sh"]
        let exists: (String) -> Bool = { present.contains($0) }
        #expect(RemoteInstall.localPluginDir(appBundle: URL(fileURLWithPath: "/repo/Navi.app"), fileExists: exists) == "/repo")
        #expect(RemoteInstall.localPluginDir(appBundle: URL(fileURLWithPath: "/repo/out/Navi.app"), fileExists: exists) == "/repo")
        #expect(RemoteInstall.localPluginDir(appBundle: URL(fileURLWithPath: "/Applications/Navi.app"), fileExists: exists) == nil)
    }

    @Test func processRunnerCapturesOutputAndTimesOut() async {
        let ok = await ProcessRunner.run(RemoteLaunchSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                                                          arguments: ["-c", "cat; echo err >&2; exit 3"]),
                                         stdin: Data("hello".utf8))
        #expect(ok == .init(exitCode: 3, stdout: "hello", stderr: "err\n", timedOut: false))
        let slow = await ProcessRunner.run(RemoteLaunchSpec(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                            arguments: ["5"]), timeout: 0.3)
        #expect(slow.timedOut)
    }
}
