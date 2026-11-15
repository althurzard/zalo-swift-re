import AppKit
import Foundation
@preconcurrency import UserNotifications

// Voice / video calls. The official renderer's call helper does the signalling (HostScripts/call-adapter.js
// drives it: `window.__zaloCall`, posts {page:'main', call:{…}}); `CallBridge` hosts the native call helper
// (ZaloCall, from Olaz's copy of Zalo.app) that draws the call window and handles mic / camera.
//
// Entry points used by the UI (chat header buttons, contact card "Gọi", call-log "Gọi lại"):
//   engine.canCall                                   calls are available
//   engine.startCall(to: uid, video: Bool)           the chat header's own action (groups: video only → participant picker,
//                                                     ZaloEngine+GroupCall.swift)

/// Calls as seen by the interface.
struct CallState: Equatable {
    struct Incoming: Equatable, Identifiable {
        let id = UUID()
        var name: String
        var avatar: URL?
        var group: Bool
        /// Group calls: who started it, when the control event says (shown under the group's name).
        var caller: String?
        var date: Date = .now
    }

    /// Short message shown over the window (call could not start, helper reported a problem).
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// The renderer's call helper was found.
    var rendererReady = false
    /// Official `isSupport()` (server config + OS) and the IPC transport.
    var supported = false
    var videoSupported = false
    /// The renderer is in a call (`isCalling()`).
    var busy = false
    /// The Zalo runtime has the native helper.
    var helperInstalled = CallBridge.isHelperInstalled()
    /// Why the native helper cannot run (missing, failed to start), nil when fine.
    var helperProblem: String?
    var nativeRunning = false
    /// pid of the helper this app started (its window is the call window).
    var nativePID: Int32?
    var nativeState: String?
    /// The open conversation and whether the official header would offer calls for it (`canMakeCallAgain`).
    var conversationId: String?
    var conversationCanCall = false
    /// The open group's call button, by the official header rule (`nil`: no button). Video only.
    var conversationGroup: GroupGate?
    /// The participant picker (the renderer's GROUP_CALL modal) waiting for the user.
    var picker: GroupCallPicker?
    var incoming: Incoming?
    var notice: Notice?
}

/// Header rule for a group, from the renderer: `disabled` = shown but off (remote config -2), `feature` =
/// `enable_group_call_for_user` (without it the official `makeCall` refuses).
struct GroupGate: Equatable {
    var disabled: Bool
    var feature: Bool
}

enum CallAvailability: Equatable {
    case available
    /// Shown disabled, with this tooltip.
    case disabled(String)
    /// Not offered at all (group, own cloud, stranger / OA — like the official header).
    case hidden
}

extension ZaloEngine {
    /// True when the app can place calls.
    var canCall: Bool { call.supported && call.helperInstalled && call.helperProblem == nil }

    /// Header button state for a conversation.
    func callAvailability(for conversation: ConversationSummary, video: Bool) -> CallAvailability {
        if conversation.id == selfConversationId { return .hidden }
        if conversation.isGroup {
            // The official header has a video button only for groups, shown by the member thresholds of the remote
            // "call" config; the renderer answers for the open conversation.
            guard video, call.conversationId == conversation.id, let gate = call.conversationGroup else { return .hidden }
            if gate.disabled { return .disabled("Cuộc gọi nhóm hiện chưa khả dụng") }
            if !gate.feature, call.supported { return .disabled("Tài khoản này chưa bật gọi nhóm") }
        } else if call.conversationId == conversation.id, !call.conversationCanCall, call.supported {
            // The official header offers calls to friends only; the renderer answers for the open conversation.
            return .hidden
        }
        if !call.helperInstalled { return .disabled("Thiếu trình gọi của Zalo — hãy mở lại \(AppBrand.name)") }
        if let problem = call.helperProblem { return .disabled(problem) }
        if !call.rendererReady { return .disabled("Đang khởi động cuộc gọi…") }
        if !call.supported { return .disabled("Tài khoản này chưa bật gọi điện trên Zalo PC") }
        if video, !call.videoSupported { return .disabled("Tài khoản này chưa bật gọi video") }
        if call.busy { return .disabled("Bạn đang trong một cuộc gọi khác") }
        return .available
    }

    /// Starts a 1-1 voice / video call to `uid`: opens the conversation (as the header buttons need it open),
    /// then runs the official chat-box action. Never places a call by itself — only on user request.
    func startCall(to uid: String, video: Bool) {
        guard !uid.isEmpty else { return }
        // Groups: the official header only offers video; the renderer then opens the participant picker.
        if uid.hasPrefix("g"), !video {
            showCallNotice("Chỉ gọi video cho nhóm", "Zalo chỉ hỗ trợ gọi video trong nhóm. Hãy chọn nút gọi video.")
            return
        }
        guard canCall else {
            showCallNotice("Chưa thể gọi", call.helperProblem ?? "Cuộc gọi chưa sẵn sàng. Hãy thử lại sau ít giây.")
            return
        }
        if call.busy {
            showCallNotice("Đang trong cuộc gọi", "Hãy kết thúc cuộc gọi hiện tại trước khi gọi tiếp.")
            return
        }
        // The renderer checks eligibility (friend, not OA / own cloud, server config) first and only then asks
        // for the conversation to be opened (`open` result below): merely tapping call never marks it read.
        CallSequence.next += 1
        callChat("start", uid, video, CallSequence.next, object: "__zaloCall")
    }

    // MARK: Hooks

    /// Wires native-helper events (CallBridge) into `call`. Called once from `start()`.
    func installCallHooks(_ mainProcess: ZaloMainProcess) {
        call.helperInstalled = CallBridge.isHelperInstalled()
        mainProcess.calls.onEvent = { [weak self] event in self?.handleCall(event: event) }
    }

    func handleCall(event: CallBridge.Event) {
        var next = call
        switch event {
        case .helperUnavailable(let reason):
            next.helperProblem = reason
            next.nativeRunning = false
            next.nativePID = nil
            next.helperInstalled = CallBridge.isHelperInstalled()
        case .helperStarted(let pid):
            next.helperProblem = nil
            next.nativeRunning = true
            next.nativePID = pid
        case .ready:
            next.helperProblem = nil
            next.nativeRunning = true
        case .exited:
            next.nativeRunning = false
            next.nativePID = nil
            next.nativeState = nil
            next.incoming = nil
        case .callState(let state):
            next.nativeState = state
            if state == "free" { next.incoming = nil }
            // Answered (or another call took over): the "đang gọi cho bạn" banner is stale. The in-app banner stays until "free".
            if state == "incall", let incoming = call.incoming { withdrawIncomingCallBanner(incoming.id) }
        case .popup(let header, let content):
            if !content.isEmpty || !header.isEmpty {
                next.notice = CallState.Notice(title: header.isEmpty ? "Cuộc gọi Zalo" : header, message: content)
            }
        }
        if next != call { call = next }
    }

    /// `{page:'main', call:{kind, …}}` from call-adapter.js.
    func handleCall(state: [String: Any]) {
        guard let json = state["call"] as? [String: Any] else { return }
        var next = call
        switch json["kind"] as? String {
        case "status":
            next.rendererReady = json["ready"] as? Bool ?? false
            next.supported = json["supported"] as? Bool ?? false
            next.videoSupported = json["video"] as? Bool ?? false
            next.busy = json["busy"] as? Bool ?? false
            if let conv = json["conv"] as? [String: Any], let id = conv["id"] as? String {
                next.conversationId = id
                next.conversationCanCall = conv["can"] as? Bool ?? false
                next.conversationGroup = (conv["group"] as? [String: Any]).map {
                    GroupGate(disabled: $0["disabled"] as? Bool ?? false, feature: $0["feature"] as? Bool ?? false)
                }
            } else {
                next.conversationId = nil
                next.conversationCanCall = false
                next.conversationGroup = nil
            }
        case "open":
            // The call is allowed: show the conversation (the chat box action needs it open).
            if let id = json["uid"] as? String, !id.isEmpty, openConversationId != id { navigationRequest = id }
        case "result":
            if let result = json["result"] as? String,
               let message = Self.callFailureMessage(result, group: json["group"] as? Bool ?? false) {
                next.notice = CallState.Notice(title: "Chưa gọi được", message: message)
            }
        case "incoming":
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let group = json["group"] as? Bool ?? false
            let busy = json["busy"] as? Bool ?? false
            guard !busy else { break } // the official client auto-declines while in a call; nothing rings
            // Only when the helper can actually ring.
            guard call.helperInstalled, call.helperProblem == nil else { break }
            let caller = (json["caller"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A group call is announced by the group's name; when only the caller is known, that name stands in.
            let incoming = CallState.Incoming(name: name ?? caller ?? (group ? "Cuộc gọi nhóm" : "Một người bạn"),
                                              avatar: (json["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                              group: group,
                                              caller: group && name != nil ? caller : nil)
            next.incoming = incoming
            announceIncomingCall(incoming)
            scheduleIncomingExpiry(incoming.id)
        case "picker":
            if let picker = GroupCallPicker(json: json) {
                next.picker = picker
                // Like the official request handler (`$zwindow.focus()`): the helper asked while its own window may be in front.
                NSApp?.activate()
            }
        case "pickerClosed":
            if next.picker?.id == json["token"] as? String { next.picker = nil }
        default:
            break
        }
        if next != call { call = next }
    }

    static func callFailureMessage(_ result: String, group: Bool = false) -> String? {
        if group, result == "unavailable" {
            return "Zalo không cho phép gọi nhóm này (nhóm có quá nhiều thành viên hoặc tài khoản chưa bật gọi nhóm)."
        }
        switch result {
        case "started": return nil
        case "busy": return "Bạn đang trong một cuộc gọi khác."
        case "offline": return "Không có kết nối mạng."
        case "unavailable": return "Zalo không cho phép gọi cho cuộc trò chuyện này (chỉ gọi được cho bạn bè)."
        case "unsupported": return "Tài khoản này chưa bật gọi điện trên Zalo PC."
        case "not-open", "not-ready": return "Cuộc trò chuyện chưa sẵn sàng. Hãy thử lại sau ít giây."
        case "invalid": return "Danh sách người tham gia không hợp lệ. Hãy chọn lại."
        default: return "Đã có lỗi khi bắt đầu cuộc gọi."
        }
    }

    func showCallNotice(_ title: String, _ message: String) {
        call.notice = CallState.Notice(title: title, message: message)
    }

    // MARK: Incoming calls

    /// The native helper shows the ringing window. This adds a banner in the app and, when the app is in the
    /// background, a macOS notification (the official renderer shows nothing for incoming calls itself).
    private func announceIncomingCall(_ incoming: CallState.Incoming) {
        guard NativeNotifier.shared.isAvailable, !(NSApp?.isActive ?? true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cuộc gọi đến"
        content.body = "\(incoming.name) đang gọi cho bạn"
        content.threadIdentifier = "zalo-call"
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            // Ended / answered / missed while authorization was read: nothing to announce.
            guard self?.call.incoming?.id == incoming.id else { return }
            try? await center.add(UNNotificationRequest(identifier: Self.incomingCallBannerId(incoming.id), content: content, trigger: nil))
            // Ended while the banner was being added: take it back.
            if self?.call.incoming?.id != incoming.id { self?.withdrawIncomingCallBanner(incoming.id) }
        }
    }

    static func incomingCallBannerId(_ id: UUID) -> String { NativeNotifier.callPrefix + id.uuidString }

    /// The call ended, was missed, answered or replaced: its macOS banner leaves Notification Center
    /// (called from `call`'s `didSet` whenever `incoming` stops being this call).
    func withdrawIncomingCallBanner(_ id: UUID) {
        NativeNotifier.shared.removeNotifications(withIdentifiers: [Self.incomingCallBannerId(id)])
    }

    private func scheduleIncomingExpiry(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.call.incoming?.id == id else { return }
            self.call.incoming = nil
        }
    }

    /// Brings the native call window to the front (ringing / in-call).
    func showCallWindow() {
        // Our own child only — never another ZaloCall (e.g. the official Zalo's).
        guard let pid = call.nativePID else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
}

/// Sequence numbers for `startCall` results (extensions cannot hold stored properties).
@MainActor
private enum CallSequence {
    static var next = 0
}
