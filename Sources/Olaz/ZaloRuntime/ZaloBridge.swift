import Foundation
import WebKit
import os

private let bridgeLog = Logger(subsystem: "app.olaz", category: "bridge")

/// Swift implementation of the Electron preload bridge (`$zelectron`, `$znode`,
/// `$zlogin`, …) that the official renderer calls. See `HostScripts/bridge.js`
/// and `reanalysis/bridge-spec.md` for the member semantics.
@MainActor
final class ZaloBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "zbridge"

    enum Mode: String {
        case async, sync, event, off, noop, value
        case noopAsync = "noop-async"
    }

    typealias AsyncHandler = @MainActor ([Any]) async throws -> Any?
    typealias SyncHandler = @MainActor ([Any]) throws -> Any?

    struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var globals: Set<String> = []
    private var modes: [String: Mode] = [:]
    private var values: [String: Any] = [:]
    private var asyncHandlers: [String: AsyncHandler] = [:]
    private var syncHandlers: [String: SyncHandler] = [:]
    private(set) var subscriptions: Set<String> = []
    weak var webView: WKWebView?

    // Electron IPC emulation: Swift plays the main process.
    /// Preload member → (channel, type), generated from the official preload.
    private var ipcTable: [String: [String: String]] = [:]
    private var channelHandlers: [String: AsyncHandler] = [:]
    private var channelSyncHandlers: [String: SyncHandler] = [:]
    private(set) var subscribedChannels: Set<String> = []
    private(set) var providedChannels: Set<String> = []
    /// Invoked/sent channels with no Swift handler yet (diagnostics).
    private(set) var unhandledChannels: [String: Int] = [:]

    /// Called for every bridge call (path or `ipc:<channel>`, args) — diagnostics.
    var trace: ((String, [Any]) -> Void)?
    /// Handler failures (key, error) — diagnostics.
    var onHandlerError: ((String, Error) -> Void)?
    /// Fires when the renderer starts listening on a channel or provides a handler.
    var onChannelActivity: ((String) -> Void)?

    // MARK: Registration — path-keyed members (implemented directly in the preload)

    func declareGlobal(_ name: String) { globals.insert(name) }

    func value(_ path: String, _ value: Any) {
        register(path, .value)
        values[path] = value
    }

    func async(_ path: String, _ handler: @escaping AsyncHandler) {
        register(path, .async)
        asyncHandlers[path] = handler
    }

    func sync(_ path: String, _ handler: @escaping SyncHandler) {
        register(path, .sync)
        syncHandlers[path] = handler
    }

    func event(_ path: String) { register(path, .event) }
    func off(_ path: String) { register(path, .off) }
    func noop(_ paths: String...) { paths.forEach { register($0, .noop) } }
    func noopAsync(_ paths: String...) { paths.forEach { register($0, .noopAsync) } }

    private func register(_ path: String, _ mode: Mode) {
        modes[path] = mode
        if let global = path.split(separator: ".").first { globals.insert(String(global)) }
    }

    // MARK: Registration — IPC channels (table-driven preload members)

    func loadIPCTable(_ table: [String: [String: String]]) {
        ipcTable.merge(table) { _, new in new }
        for path in table.keys {
            if let global = path.split(separator: ".").first { globals.insert(String(global)) }
        }
    }

    /// `ipcMain.handle(channel)` — answers REQUEST/NOTIFY (invoke) and REQUEST_SYNC.
    func handle(_ channel: String, _ handler: @escaping AsyncHandler) { channelHandlers[channel] = handler }
    func handleSync(_ channel: String, _ handler: @escaping SyncHandler) { channelSyncHandlers[channel] = handler }
    /// Channels that are fine to acknowledge with `undefined` (telemetry, window chrome…).
    func acknowledge(_ channels: [String]) {
        for channel in channels where channelHandlers[channel] == nil && channelSyncHandlers[channel] == nil {
            channelSyncHandlers[channel] = { _ in nil }
        }
    }

    /// `window.__zaloBridgeSpec`, injected before `bridge.js`.
    func specScript() -> String {
        let spec: [String: Any] = [
            "globals": globals.sorted(),
            "members": modes.mapValues(\.rawValue),
            "values": values.mapValues { Self.toJS($0) },
            "ipc": ipcTable,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: spec)) ?? Data("{}".utf8)
        return "window.__zaloBridgeSpec = \(String(decoding: data, as: UTF8.self));"
    }

    // MARK: Swift → JS

    /// `webContents.send(channel, ...args)`.
    @discardableResult
    func send(_ channel: String, _ args: [Any] = []) -> Bool {
        guard let webView else { return false }
        webView.callAsyncJavaScript(
            "return window.__zaloBridge.ipcEmit(channel, args)",
            arguments: ["channel": channel, "args": args.map(Self.toJS)],
            in: nil, in: .page, completionHandler: nil
        )
        return subscribedChannels.contains(channel)
    }

    /// Zalo's `webContents.invoke(channel, ...args)` — main asks a renderer PROVIDE handler.
    func invokeRenderer(_ channel: String, _ args: [Any] = []) async throws -> Any? {
        guard let webView else { throw BridgeError(message: "no renderer") }
        let result = try await webView.callAsyncJavaScript(
            "return await window.__zaloBridge.ipcInvokeRenderer(channel, args)",
            arguments: ["channel": channel, "args": args.map(Self.toJS)],
            in: nil, contentWorld: .page
        )
        return result.map(Self.fromJS)
    }

    /// Events for path-keyed members.
    @discardableResult
    func emit(_ path: String, _ args: [Any] = [], withEvent: Bool = true) -> Bool {
        guard subscriptions.contains(path), let webView else { return false }
        webView.callAsyncJavaScript(
            withEvent ? "window.__zaloBridge.emit(path, args)" : "window.__zaloBridge.emitRaw(path, args)",
            arguments: ["path": path, "args": args.map(Self.toJS)],
            in: nil, in: .page, completionHandler: nil
        )
        return true
    }

    // MARK: JS → Swift

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        // Issue #1: only the renderer's own frames (app origin) reach main-process handlers. `OfficialClientHost`
        // already registers this handler behind the same gate; checked again here so no registration can skip it.
        guard OfficialClientHost.admits(message) else {
            replyHandler(nil, "EACCES: native bridge not available in this frame")
            return
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "bad bridge message")
            return
        }
        let args = (body["args"] as? [Any] ?? []).map(Self.fromJS)

        if let channel = body["channel"] as? String {
            switch kind {
            case "subscribe":
                subscribedChannels.insert(channel)
                onChannelActivity?(channel)
                replyHandler(nil, nil)
            case "provide":
                providedChannels.insert(channel)
                onChannelActivity?(channel)
                replyHandler(nil, nil)
            default: // invoke / send
                trace?("ipc:\(channel)", args)
                if let handler = channelHandlers[channel] {
                    Task {
                        do { replyHandler(Self.toJS(try await handler(args)), nil) }
                        catch {
                            self.onHandlerError?("ipc:\(channel)", error)
                            replyHandler(nil, error.localizedDescription)
                        }
                    }
                } else if let handler = channelSyncHandlers[channel] {
                    do { replyHandler(Self.toJS(try handler(args)), nil) } catch {
                        onHandlerError?("ipc:\(channel)", error)
                        replyHandler(nil, error.localizedDescription)
                    }
                } else {
                    unhandledChannels[channel, default: 0] += 1
                    bridgeLog.notice("unhandled ipc \(kind, privacy: .public) \(channel, privacy: .public)")
                    replyHandler(Self.toJS(nil), nil)
                }
            }
            return
        }

        guard let path = body["path"] as? String else {
            replyHandler(nil, "bad bridge message")
            return
        }
        if kind == "subscribe" {
            subscriptions.insert(path)
            replyHandler(nil, nil)
            return
        }
        trace?(path, args)
        if let handler = asyncHandlers[path] {
            Task {
                do {
                    replyHandler(Self.toJS(try await handler(args)), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        } else if let handler = syncHandlers[path] {
            // An async call to a sync member: answer immediately.
            do { replyHandler(Self.toJS(try handler(args)), nil) } catch { replyHandler(nil, error.localizedDescription) }
        } else {
            bridgeLog.notice("unhandled async bridge call \(path, privacy: .public)")
            replyHandler(Self.toJS(nil), nil)
        }
    }

    /// Synchronous calls arrive as a blocking XHR to `zalo-app://bridge/sync`.
    func handleSyncRequest(_ body: Data) -> Data {
        var response: [String: Any] = [:]
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            response["error"] = "bad sync request"
            return (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        }
        let args = (json["args"] as? [Any] ?? []).map(Self.fromJS)
        let handler: SyncHandler?
        let key: String
        if let channel = json["channel"] as? String {
            key = "ipc:\(channel)"
            handler = channelSyncHandlers[channel]
            if handler == nil { unhandledChannels[channel, default: 0] += 1 }
        } else {
            key = json["path"] as? String ?? "?"
            handler = syncHandlers[key]
        }
        trace?(key, args)
        if let handler {
            do { response["value"] = Self.toJS(try handler(args)) } catch {
                onHandlerError?(key, error)
                response["error"] = error.localizedDescription
            }
        } else {
            bridgeLog.notice("unhandled sync bridge call \(key, privacy: .public)")
            response["value"] = Self.toJS(nil)
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
    }

    // MARK: Value conversion (binary travels as {__bytes: base64})

    static func fromJS(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            if let b64 = dict["__bytes"] as? String { return Data(base64Encoded: b64) ?? Data() }
            return dict.mapValues(fromJS)
        }
        if let array = value as? [Any] { return array.map(fromJS) }
        return value
    }

    static func toJS(_ value: Any?) -> Any {
        switch value {
        case nil: return ["__undefined": true]
        case let data as Data: return ["__bytes": data.base64EncodedString()]
        case let buffer as CryptoBridge.ArrayBufferValue: return ["__bytes": buffer.data.base64EncodedString(), "__arraybuffer": true]
        case let url as URL: return url.path
        case let date as Date: return date.timeIntervalSince1970 * 1000
        case let dict as [String: Any?]: return dict.mapValues { toJS($0) }
        case let array as [Any?]: return array.map { toJS($0) }
        case let some?: return some
        }
    }
}

extension Array where Element == Any {
    func string(_ i: Int) -> String? { i < count ? self[i] as? String : nil }
    func dict(_ i: Int) -> [String: Any]? { i < count ? self[i] as? [String: Any] : nil }
    func int(_ i: Int) -> Int? { i < count ? (self[i] as? NSNumber)?.intValue : nil }
    func bool(_ i: Int) -> Bool? { i < count ? (self[i] as? NSNumber)?.boolValue : nil }
    func data(_ i: Int) -> Data? {
        guard i < count else { return nil }
        if let d = self[i] as? Data { return d }
        if let s = self[i] as? String { return Data(s.utf8) }
        return nil
    }
}
