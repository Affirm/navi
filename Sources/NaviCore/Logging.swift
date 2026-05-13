import Foundation

private let naviDebug = ProcessInfo.processInfo.environment["NAVI_DEBUG"] == "1"

public func naviLog(_ message: String, _ args: CVarArg...) {
    guard naviDebug else { return }
    let formatted = String(format: message, arguments: args)
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(formatted)\n"
    let path = "/tmp/navi/debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}
