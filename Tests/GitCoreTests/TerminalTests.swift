import XCTest
import Foundation
import Darwin
import SwiftTerm
@testable import GitCore

final class TerminalTests: XCTestCase {
    func testLaunchConfigurationKeepsPathOutOfShellArguments() throws {
        let path = URL(fileURLWithPath: "/tmp/repo with space; $(touch unsafe)")
        let config = TerminalConfiguration(directory: path, inheritedEnvironment: ["HOME": "/tmp/home", "CUSTOM": "preserved"], userShell: "/missing/shell")
        XCTAssertEqual(config.executable, "/bin/zsh")
        XCTAssertEqual(config.arguments, ["-l", "-i"])
        XCTAssertTrue(config.environment.contains("PWD=\(path.path)"))
        XCTAssertTrue(config.environment.contains("CUSTOM=preserved"))
        XCTAssertTrue(config.environment.contains("TERM=xterm-256color"))
        XCTAssertFalse(ShortcutRules.isValid("`"))
        XCTAssertTrue(ShortcutRules.reserved.contains("`"))
    }

    @MainActor
    func testPTYWorkingDirectoryAndInteractiveInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit terminal \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = Probe()
        let process = LocalProcess(delegate: delegate)
        defer { stop(process) }
        let output = expectation(description: "PTY and literal cwd")
        delegate.onOutput = { text in if text.contains(directory.path), text.contains("PTY_OK") { output.fulfill(); delegate.onOutput = nil } }
        let config = TerminalConfiguration(directory: directory, userShell: "/bin/sh")
        process.startProcess(executable: config.executable, args: ["-i"], environment: config.environment, currentDirectory: config.directory.path)
        XCTAssertTrue(process.running)
        process.send(data: Array("pwd; if test -t 0 && test -t 1; then printf 'PTY_%s\\n' OK; fi\n".utf8)[...])
        await fulfillment(of: [output], timeout: 5)
        let exit = expectation(description: "Shell exits")
        delegate.onExit = { _ in exit.fulfill() }
        process.send(data: Array("exit 7\n".utf8)[...])
        await fulfillment(of: [exit], timeout: 5)
        XCTAssertFalse(process.running)
    }

    @MainActor
    func testControlCInterruptsForegroundJobAndShellSurvives() async throws {
        let delegate = Probe()
        let process = LocalProcess(delegate: delegate)
        defer { stop(process) }
        process.startProcess(executable: "/bin/sh", args: ["-i"], currentDirectory: "/tmp")
        process.send(data: Array("sleep 30\n".utf8)[...])
        var foregroundGroup: pid_t = 0
        for _ in 0..<100 {
            if process.childfd >= 0 {
                let group = tcgetpgrp(process.childfd)
                if group > 0, group != process.shellPid { foregroundGroup = group; break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // A PTY that has not acquired a foreground group can return 0 or -1.
        // Sending Ctrl-C then interrupts shell initialization rather than sleep.
        guard foregroundGroup > 0, foregroundGroup != process.shellPid else {
            XCTFail("The sleep job did not acquire the foreground process group")
            return
        }
        process.send(data: [3][...])
        let output = expectation(description: "Shell still accepts commands after Ctrl-C")
        delegate.onOutput = { text in if text.contains("AFTER_INTERRUPT") { output.fulfill(); delegate.onOutput = nil } }
        process.send(data: Array("printf 'AFTER_%s\\n' INTERRUPT\n".utf8)[...])
        await fulfillment(of: [output], timeout: 5)
        XCTAssertTrue(process.running)
    }

    @MainActor
    func testClosingSessionStopsShellAndBackgroundChild() async throws {
        let delegate = Probe()
        let process = LocalProcess(delegate: delegate)
        defer { stop(process) }
        let output = expectation(description: "Background child PID")
        delegate.onOutput = { text in if text.range(of: #"CHILD:\d+\s"#, options: .regularExpression) != nil { output.fulfill(); delegate.onOutput = nil } }
        process.startProcess(executable: "/bin/sh", args: ["-c", "sleep 30 & printf 'CHILD:%s\\n' \"$!\"; wait"], currentDirectory: "/tmp")
        await fulfillment(of: [output], timeout: 5)
        let token = try XCTUnwrap(delegate.output.components(separatedBy: "CHILD:").last?.split(whereSeparator: { $0.isWhitespace }).first)
        let child = try XCTUnwrap(pid_t(token))
        let shell = process.shellPid
        stop(process)
        for _ in 0..<100 {
            if !isLive(shell), !isLive(child) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(isLive(shell), "Shell survived cleanup")
        XCTAssertFalse(isLive(child), "Background job survived cleanup")
    }

    @MainActor private func stop(_ process: LocalProcess) {
        guard process.running else { return }
        TerminalProcessShutdown.terminate(shellPID: process.shellPid, foregroundGroup: process.childfd >= 0 ? tcgetpgrp(process.childfd) : 0, immediately: true)
        process.terminate()
    }
    private func isLive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return info.pbi_status != SZOMB
    }
    private final class Probe: LocalProcessDelegate {
        var output = ""
        var onOutput: ((String) -> Void)?
        var onExit: ((Int32?) -> Void)?
        func dataReceived(slice: ArraySlice<UInt8>) { output += String(decoding: slice, as: UTF8.self); onOutput?(output) }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) { onExit?(exitCode) }
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    }
}
