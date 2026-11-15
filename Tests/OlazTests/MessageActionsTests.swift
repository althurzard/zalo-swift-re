import Testing
import Foundation
@testable import Olaz

// Message context-menu actions: the Swift decoding (menu, outcomes, pins, copy text) and the real `message-actions-adapter.js` in
// JavaScriptCore against fake official modules (dm9D predicates, forward / recall / delete / star services, pin managers).
// Every fixture is synthetic: no real names, ids or URLs.

@Suite struct MessageActionModelTests {
    private func message(_ kind: ChatMessage.Kind, text: String = "", id: String = "m1") -> ChatMessage {
        ChatMessage(id: id, conversationId: "c1", senderId: "u1", senderName: "Test User", senderAvatar: nil, isMine: false, kind: kind, text: text,
                    date: Date(timeIntervalSince1970: 1), status: .sent, quote: nil, reactions: [], isE2EE: false)
    }

    @Test func decodesTheMenu() {
        let menu = MessageMenu(json: ["forward": "blocked", "recall": true, "delete": "forMe", "pin": true, "star": "unstar", "starred": true,
                                      "protected": true, "pinned": true])
        #expect(menu.forward == .blocked && menu.recall && menu.delete == .forMe && menu.pin && menu.star == .unstar)
        #expect(menu.starred && menu.isProtected && menu.pinned)
        let empty = MessageMenu(json: ["forward": "", "delete": "", "star": ""])
        #expect(empty == MessageMenu())
        #expect(MessageMenu(json: NSNull()) == MessageMenu())
        // Parsed from a whole message, and absent for messages that have none (shared media).
        let parsed = ChatMessage(json: ["id": "1", "kind": ["type": "text"], "menu": ["forward": "ok", "delete": "plain", "star": "star"]], fallbackConversation: "c")
        #expect(parsed?.menu.forward == .available && parsed?.menu.delete == .plain && parsed?.menu.star == .star)
        #expect(ChatMessage(json: ["id": "1", "kind": ["type": "text"]], fallbackConversation: "c")?.menu == MessageMenu())
    }

    @Test func decodesOutcomes() {
        #expect(MessageActionOutcome(json: ["status": "done"], failure: "x") == .done(text: nil))
        #expect(MessageActionOutcome(json: ["status": "done", "text": "Đã bỏ đánh dấu tin nhắn"], failure: "x") == .done(text: "Đã bỏ đánh dấu tin nhắn"))
        #expect(MessageActionOutcome(json: ["status": "denied", "text": "Bị chặn"], failure: "x") == .failed("Bị chặn"))
        #expect(MessageActionOutcome(json: ["status": "error"], failure: "Lỗi") == .failed("Lỗi"))
        #expect(MessageActionOutcome(json: nil, failure: "Lỗi") == .failed("Lỗi"))
        #expect(MessageActionOutcome(json: ["status": "pending"], failure: "x") == .pending(CardActionOutcome.defaultPending))
        let confirm = MessageActionOutcome(json: ["status": "confirm", "title": "T", "message": "M", "ok": "Xác nhận", "cancel": "Hủy", "ref": "2:9"], failure: "x")
        #expect(confirm == .confirm(title: "T", message: "M", ok: "Xác nhận", cancel: "Hủy", ref: "2:9"))
    }

    @Test func decodesPinsAndFindsTheirMessages() {
        let list = PinnedList(json: ["ready": true, "canPin": true, "items": [
            ["ref": "2:a", "kind": "message", "title": "[Hình ảnh]", "sender": "Bạn", "thumb": "https://cdn.example.test/t.jpg", "msgId": "900", "cliMsgId": "500"],
            ["ref": "3:77", "kind": "poll", "title": "Ăn gì?"],
            ["ref": "", "kind": "note"],
            ["ref": "0:n", "kind": "weird", "title": "Ghi chú"],
        ]])
        #expect(list.ready && list.canPin && list.items.map(\.ref) == ["2:a", "3:77", "0:n"])
        #expect(list.items[0].thumbnail == URL(string: "https://cdn.example.test/t.jpg") && list.items[2].kind == .note)
        #expect(list.items[0].label == "Tin nhắn" && list.items[1].label == "Bình chọn")
        // Own messages are keyed by the client id, others by the server id.
        let mine = message(.text, id: "500"), theirs = message(.text, id: "900")
        #expect(list.items[0].message(in: [mine])?.id == "500" && list.items[0].message(in: [theirs])?.id == "900")
        #expect(list.items[0].message(in: [message(.text, id: "x")]) == nil && list.items[1].message(in: [mine]) == nil)
    }

    @Test func copyTextFollowsTheKind() {
        #expect(message(.text, text: "Xin chào").copyableText == "Xin chào")
        #expect(message(.text).copyableText == nil)
        #expect(message(.link(title: "T", url: URL(string: "https://site.example.test/a"), thumbnail: nil), text: "[Link] x").copyableText == "https://site.example.test/a")
        #expect(message(.link(title: "T", url: nil, thumbnail: nil), text: "xem nè").copyableText == "xem nè")
        #expect(message(.photo(url: nil, width: 1, height: 1), text: "[Hình ảnh]").copyableText == nil)
        #expect(message(.photo(url: nil, width: 1, height: 1), text: "[Hình ảnh]").caption == nil)
        #expect(message(.photo(url: nil, width: 1, height: 1), text: "Biển").caption == "Biển")
        #expect(message(.file(name: "a.pdf", size: 1, url: nil), text: "[Tệp]").copyableText == nil)
    }
}

// MARK: - message-actions-adapter.js (JavaScriptCore, fake official modules)

@Suite struct MessageActionsScriptTests {
    /// `protectedConv`: "Chặn chia sẻ" on in u2. `popupDel`: `enable_popup_confim_del`. `overMax`: the 1:1 board is full until a pin is dropped.
    /// `groupFull`: the group board holds `pin_limit` (2) topics. `undoError`: what `undoMessage` rejects with.
    /// `multiLazy`: `unpinMultiTopics` resolves but the board changes only later (the sync event). `fullBoard11`: the 1:1 board already holds
    /// the official limit of 3 pins. `partialShare`: the forward reaches only the first conversation.
    private func harness(protectedConv: Bool = false, popupDel: Bool = false, overMax: Bool = false, groupFull: Bool = false,
                         undoError: String = "null", setTopicOnly: Int = 0, multiLazy: Bool = false, fullBoard11: Bool = false,
                         partialShare: Bool = false) -> ScriptHarness {
        let h = ScriptHarness(prelude: """
        var performance = { now: function () { return __now; } };
        var calls = [];
        var NOW = Date.now();
        var C = { MSG_TOPIC: 2, POLL_TOPIC: 3, REMINDER_TOPIC: 4, LINK_TOPIC: 1, TEXT_TOPIC: 0, CONVERSATION_TYPE: { UNKNOWN: 0, CLOUD: 1, GROUP: 2, FRIEND: 3 },
          MSG_TEXT: 1, MSG_PHOTO: 2, MSG_VOICE: 3, MSG_STICKER: 4, MSG_DOODLE: 5, MSG_CONTACT: 6, MSG_GIF: 7, MSG_LOCATION: 17, MSG_VIDEO: 18, MSG_FILE: 19,
          MSG_UNDO: 20, MSG_POLL: 26, MSG_DEL_EVERYONE: -27, MSG_STICKER_GROUP: 2502, MSG_PHOTO_GROUP: 2503, MSG_ZINSTANT: 52, MSG_ZINSTANT_V2: 53,
          MSG_ZINSTANT_OLD: 27, MSG_FAIL: -2, MSG_LOCAL: 10, MSG_E2EE: 3000, MSG_BUBBLE_LAYOUT_TYPE_NO_BORDER: 3,
          CLI_MSG_TYPE_TEXT: 1, CLI_MSG_TYPE_PHOTO: 32, CLI_MSG_TYPE_CONTACT: 38, CLI_MSG_TYPE_FILE: 46, CLI_MSG_TYPE_VIDEO: 44, CLI_MSG_TYPE_GIF: 49,
          CLI_MSG_TYPE_VOICE: 31, CLI_MSG_TYPE_STICKER: 36, CLI_MSG_TYPE_DOODLE: 37, CLI_MSG_TYPE_LOCATION: 43,
          SHARE_FROM_MESSAGE: 'SHARE_FROM_MESSAGE', SHARE_FROM_MESSAGE_RIGHT_ACTION: 'SHARE_FROM_MESSAGE_RIGHT_ACTION' };
        var P = {
          u: function (m) { return m.msgType === 20 || m.msgType === -27 || m.status === -2; }, O: function (m) { return m.status === 10; },
          h: function (m) { return !!m.isCall; }, E: function (m) { return m.msgType === 21; }, G: function (m) { return P.u(m) || P.O(m); },
          S: function () { return false; }, cb: function (m) { return m.msgType === 52 || m.msgType === 53; }, db: function () { return false; },
          P: function (m) { return !!m.staredDttm || (m.msgType === 2503 && m.message.some(function (x) { return !!x.staredDttm; })); },
          o: function (m) { return m.status === -2; }, r: function (m) { return m.msgType === 2503; }, s: function (m) { return m.msgType === 2502; },
          F: function (m) { return m.msgType === 2502 && m.message.length === 1; }, l: function () { return false; }, I: function () { return false; }, R: function () { return false; }
        };
        var cfg = { sendToMeId: 'cloud1', stickerUrl: '', recallMessageMaxTime: 86400000, undo_delete: { enable: 1, timeout: 5600 }, enable_popup_confim_del: \(popupDel), forward_conv_limit: 3,
          settings: { group: { topic_colors: [-14540254] } }, group_topics: { enable: 1, enable_pin_limit: 1, pin_limit: 2 } };
        var types = { cloud1: 1, g9: 2 };
        var groups = { g9: { userId: 'g9', creatorId: 'u5', setting: { setTopicOnly: \(setTopicOnly) }, topMember: [{ id: 'u5' }, { id: 'u6', isAdmin: true }] } };
        var text = function (id, from, to, ts, extra) { var m = { msgId: id, cliMsgId: String(Number(id) - 400), fromUid: from, toUid: to, msgType: 1, status: 1, message: 'tin ' + id, sendDttm: ts || NOW - 1000 }; for (var k in extra || {}) m[k] = extra[k]; return m; };
        var convs = {
          u2: { messages: [
            text('900', '0', 'u2'), text('901', 'u2', 'me1'), text('902', '0', 'u2', NOW - 2 * 86400000), text('903', '0', 'u2', null, { status: -2 }),
            { msgId: '910', cliMsgId: '510', fromUid: '0', toUid: 'u2', msgType: 2503, status: 1, sendDttm: NOW - 1000, message: [
              { msgId: '911', cliMsgId: '511', fromUid: '0', toUid: 'u2', msgType: 2, status: 1, staredDttm: 5, sendDttm: NOW - 1000, message: { thumbUrl: 'https://cdn.example.test/t1.jpg' } },
              { msgId: '912', cliMsgId: '512', fromUid: '0', toUid: 'u2', msgType: 2, status: 1, sendDttm: NOW - 1000, message: { thumbUrl: 'https://cdn.example.test/t2.jpg' } }
            ] },
            text('904', 'u2', 'me1', null, { isCall: true })
          ] },
          cloud1: { messages: [text('800', '0', 'cloud1')] },
          // A member's message whose client id is the same as my next one (client ids are per sender).
          g9: { messages: [text('700', 'u5', 'g9'), { msgId: '705', cliMsgId: '301', fromUid: 'u6', toUid: 'g9', msgType: 1, status: 1, message: 'trùng', sendDttm: NOW - 1000 }, text('701', '0', 'g9')] }
        };
        var pins11 = \(overMax ? "[{ id: 'p1', type: 2, params: { title: 'cũ nhất', msg_type: 1, senderUid: 'u2' } }, { id: 'p0', type: 0, params: { title: 'ghi chú' } }]"
          : fullBoard11 ? "[{ id: 'p3', type: 0, params: { title: 'ba' } }, { id: 'p2', type: 0, params: { title: 'hai' } }, { id: 'p1', type: 0, params: { title: 'một' } }]" : "[]");
        var listeners = [], dropped = false;
        var mgr = {
          isEnablePinTopicOneOnOneFeature: function () { return true; },
          addEventListener: function (e, cb) { listeners.push(e); },
          loadPinTopics: async function (c) { return { conversationId: c, topics: pins11.slice() }; },
          createPinTopic: async function (c, t) {
            calls.push(['create11', c, t.type, t.params.client_msg_id, t.params.global_msg_id, t.params.senderUid, t.params.title, t.params.msg_type, t.color]);
            if (\(overMax) && !dropped) throw { code: 268, data: { cache: { topics: pins11.slice() } } };
            pins11.unshift({ id: 'new', type: 2, params: t.params });
            return { conversationId: c, topics: pins11 };
          },
          unpinPinTopics: async function (c, ts) { calls.push(['unpin11', c, ts.map(function (t) { return t.id; }).join(',')]); dropped = true; pins11 = pins11.filter(function (x) { return ts.indexOf(x) < 0; }); }
        };
        var boardTopics = { g9: \(groupFull ? "[{ id: 't2', type: 3, params: { question: 'Ăn gì?' } }, { id: 't1', type: 2, params: { title: 'tin cũ', msg_type: 1, global_msg_id: '1', senderUid: 'u5' } }]" : "[]") };
        var board = {
          pinLimit: 2,
          topicStore: { getTopics: function (c) { return (boardTopics[c] || []).slice(); }, hasGroup: function (c) { return !!boardTopics[c]; },
            setTopic: function () {}, setTopics: function () {}, removeTopic: function () {}, resetGroup: function () {} },
          loadTopics: async function () {},
          callCreateOrPinTopic: function (c, t, pre, ok) { calls.push(['pinGroup', c, t.type, t.params.global_msg_id, t.pinAct, t.isCreated]); boardTopics[c].unshift({ id: 'tn', type: 2, params: t.params }); ok({}); },
          callUnpinTopic: async function (c, t) { calls.push(['unpinGroup', c, t.id, t.type]); boardTopics[c] = boardTopics[c].filter(function (x) { return x.id !== t.id; }); },
          unpinMultiTopics: async function (c, ts) {
            calls.push(['multi', c, ts.map(function (x) { return x.id; }).join(',')]);
            var drop = function () { boardTopics[c] = boardTopics[c].filter(function (x) { return ts.indexOf(x) < 0; }); };
            if (\(multiLazy)) setTimeout(drop, 10000); else drop();
          }
        };
        var findIn = function (to, id) { return (convs[to] || { messages: [] }).messages.find(function (m) { return m.msgId === id; }); };
        var mods = {
          dm9D: P, '1pet': C, NDmK: { default: cfg },
          c51z: { default: { str: function () { return ''; }, trans: function () { return ''; } } },
          bUXd: { default: { getTimeNow: function () { return Date.now(); } } },
          jSEC: { a: function (c) { return types[c] === undefined ? 3 : types[c]; } },
          czzM: { ConversationPrivacy: { GetModule: function () { return { isContentProtected: function (c) { return \(protectedConv) && c === 'u2'; } }; } } },
          UiPd: { default: { isOA: function () { return false; } } },
          Gm1y: { default: { getGroupByIdSync: function (c) { return groups[c]; } } },
          ymth: { a: function () { return true; } },
          z0WU: { default: { getUnicodeCorrMSGType: function () { return '💬'; } } },
          smi1: { a: { getStringTime: function () { return ' 24 giờ'; },
            deleteMsgs: async function (c, ms) { calls.push(['deleteMsgs', c, ms.map(function (m) { return m.cliMsgId; }).join(',')]); return { ok: true, value: { id: 77, msgsDel: [{ msgId: ms[0].msgId }], canUndoMsgs: ms, expireAt: performance.now() + 5600 } }; },
            deleteMsgsNotUndo: async function () { return []; } } },
          m89U: { a: function (x) { calls.push(['apply', JSON.stringify(x)]); }, c: function (id) { calls.push(['commit', id]); }, d: async function (id) { calls.push(['restore', id]); return true; } },
          XS0u: { default: {
            addStarMessages: async function (ms, t) { calls.push(['star', ms.map(function (m) { return m.cliMsgId; }).join(','), t]); },
            unstaredMessages: async function (ms) { calls.push(['unstar', ms.map(function (m) { return m.cliMsgId; }).join(',')]); },
            shouldSaveTsStarMsgSchemaChanged: function () {}, getMessage: async function (id, to) { return findIn(to, id); } } },
          PoHQ: { n: { dispatch: function (a) { calls.push(['dispatch', a.type, a.payload.conversationId, a.payload.updateMsgs.length]); } } },
          '97kL': { MessageActions: { ADD_STAR: 515, DELETE_STAR: 518 } },
          dThN: { default: { undoMessage: async function (id, to, next, cli, e2ee) { calls.push(['undo', id, to, next, cli, e2ee]); var err = \(undoError); if (err) throw err; } } },
          NMlV: { a: { next: function () { return 42; } } },
          sg3c: { f: function () { return -1; } },
          YYsv: { c: { PINBOARD_OVER_MAXIMUM: 268, FULL_THREAD_PIN_TOPIC: 287 }, b: { CONTEXT_MENU: 1 }, j: { GetManager: function () { return mgr; } } },
          jnJr: { a: { getInstance: function () { return board; } } }
        };
        window.__zaloRequire = { c: {} };
        Object.keys(mods).forEach(function (k) { window.__zaloRequire.c[k] = { exports: mods[k] }; });
        window.__zaloChat = { __core: {
          safe: function (fn, d) { try { var v = fn(); return v === undefined ? d : v; } catch (e) { return d; } },
          str: function (v) { return typeof v === 'string' ? v : ''; }, scrubErr: function (e) { return String(e); },
          isGroupId: function (id) { return typeof id === 'string' && id.charAt(0) === 'g'; }, meNow: function () { return 'me1'; },
          nameOf: function (u) { return u === 'u2' ? 'Test Friend' : u === 'u5' ? 'Test Owner' : ''; },
          absUrl: function (v) { return typeof v === 'string' && /^https:\\/\\//.test(v) ? v : ''; },
          parseJSON: function (v) { if (v && typeof v === 'object') return v; try { return JSON.parse(v) || {}; } catch (e) { return {}; } },
          waitFor: async function (fn, ms) { var end = Date.now() + (ms || 4000); while (Date.now() < end) { var v = fn(); if (v) return v; await new Promise(function (r) { setTimeout(r, 80); }); } return null; },
          convOf: function (id) { return convs[id] || null; }, ready: async function () { return true; }, refresh: function () {}, diag: function () {},
          boxFor: async function () { return { cc: { _shareMessage: async function (raw, ids, cb, src, opts) { calls.push(['share', raw.cliMsgId, ids.join(','), src, opts.actualEntry]); cb(\(partialShare) ? ids.slice(0, 1) : ids.slice()); } }, info: {}, direct: false }; }
        } };
        """)
        h.load("message-actions-adapter.js")
        return h
    }

    private func calls(_ h: ScriptHarness) -> [[Any]] {
        (try? JSONSerialization.jsonObject(with: Data(h.text("JSON.stringify(calls)").utf8))) as? [[Any]] ?? []
    }

    private func menu(_ h: ScriptHarness, _ conv: String, _ index: Int) -> [String: Any] {
        h.run("m\(conv)\(index)", "window.__zaloMsgActions.describe(convs.\(conv).messages[\(index)], '\(conv)')") ?? [:]
    }

    @Test func theMenuFollowsTheOfficialBuilder() {
        let h = harness()
        #expect(h.failures.isEmpty, "\(h.failures)")
        let mine = menu(h, "u2", 0)
        #expect(mine["forward"] as? String == "ok" && mine["recall"] as? Bool == true && mine["delete"] as? String == "forMe")
        #expect(mine["pin"] as? Bool == true && mine["star"] as? String == "star" && mine["starred"] as? Bool == false)
        // Someone else's message: no recall. A call log: no forward / pin / star.
        #expect(menu(h, "u2", 1)["recall"] as? Bool == false)
        let call = menu(h, "u2", 5)
        #expect(call["forward"] as? String == "" && call["pin"] as? Bool == false && call["star"] as? String == "")
        // A failed message: plain "Xóa", nothing else of the common actions.
        let failed = menu(h, "u2", 3)
        #expect(failed["delete"] as? String == "plain" && failed["recall"] as? Bool == false && failed["star"] as? String == "")
        // An album photo has its own menu (as chat-adapter.js maps it: the photo over its group): the starred one reads as starred, the
        // other does not, and both may be pinned.
        let photo = { (i: Int) -> [String: Any] in
            h.run("ph\(i)", "(function () { var g = convs.u2.messages[4]; return window.__zaloMsgActions.describe(Object.assign({}, g, g.message[\(i)], { msgType: 2 }), 'u2'); })()") ?? [:]
        }
        #expect(photo(0)["star"] as? String == "unstar" && photo(0)["recall"] as? Bool == true && photo(0)["pin"] as? Bool == true)
        #expect(photo(1)["star"] as? String == "star" && photo(1)["starred"] as? Bool == false)
        // My Cloud: no recall, no pin, "Xóa".
        let cloud = menu(h, "cloud1", 0)
        #expect(cloud["recall"] as? Bool == false && cloud["pin"] as? Bool == false && cloud["delete"] as? String == "plain" && cloud["forward"] as? String == "ok")
        // A group where anyone may pin.
        #expect(menu(h, "g9", 0)["pin"] as? Bool == true)
    }

    @Test func groupPinsNeedTheAllowanceAndBlockedSharingDisablesForwardAndStar() {
        let restricted = harness(setTopicOnly: 1)
        #expect(menu(restricted, "g9", 0)["pin"] as? Bool == false, "only the owner / deputies pin when setTopicOnly is on")
        let blocked = harness(protectedConv: true)
        let m = menu(blocked, "u2", 0)
        #expect(m["forward"] as? String == "blocked" && m["star"] as? String == "blocked" && m["protected"] as? Bool == true)
        let refused = blocked.run("f", "window.__zaloMsgActions.forward('u2', '500', ['u3'])")
        #expect(refused?["status"] as? String == "denied" && refused?["text"] as? String == "Trò chuyện này đã bật Chặn chia sẻ")
        #expect(calls(blocked).isEmpty)
    }

    @Test func forwardGoesThroughTheOfficialShareWithTheMenuEntry() throws {
        let h = harness()
        let done = h.run("f", "window.__zaloMsgActions.forward('u2', '500', ['u3', 'u3', 'g9'])")
        #expect(done?["status"] as? String == "done" && done?["sent"] as? Int == 2 && done?["text"] as? String == "Đã chia sẻ tin nhắn")
        let share = try #require(calls(h).first)
        #expect(share as? [String] == ["share", "500", "u3,g9", "SHARE_FROM_MESSAGE", "SHARE_FROM_MESSAGE_RIGHT_ACTION"])
        // Over `forward_conv_limit` (3 here): refused with the official wording, nothing sent.
        let tooMany = h.run("f2", "window.__zaloMsgActions.forward('u2', '500', ['a', 'b', 'c', 'd'])")
        #expect(tooMany?["status"] as? String == "invalid" && tooMany?["text"] as? String == "Bạn chỉ có thể chia sẻ cho 3 hội thoại khác")
        #expect(h.run("f3", "window.__zaloMsgActions.forward('u2', 'nope', ['u3'])")?["text"] as? String == "Tin nhắn gốc không còn tồn tại")
        // An album photo is forwarded alone.
        _ = h.run("f4", "window.__zaloMsgActions.forward('u2', '512', ['u3'])")
        #expect(calls(h).last?[1] as? String == "512")
        // Only some conversations got it: says so.
        let partial = harness(partialShare: true).run("f", "window.__zaloMsgActions.forward('u2', '500', ['u3', 'g9'])")
        #expect(partial?["status"] as? String == "done" && partial?["text"] as? String == "Đã chia sẻ tin nhắn tới 1/2 hội thoại")
    }

    @Test func aRowIsFoundByItsOwnIdNotAnotherSendersClientId() throws {
        let h = harness()
        // My message "701" (row id = its client id "301") comes after a member's message carrying the same client id.
        #expect(h.run("r", "window.__zaloMsgActions.recall('g9', '301')")?["status"] as? String == "done")
        #expect(try #require(calls(h).first)[1] as? String == "701")
        // A member's message is found by its server id.
        #expect(h.run("s", "window.__zaloMsgActions.star('g9', '705', true)")?["status"] as? String == "done")
        // An album photo by `<group>#<index>`, as chat-adapter.js keys a photo without ids of its own.
        _ = h.run("d", "window.__zaloMsgActions.deleteForMe('u2', '510#1', false)")
        #expect(calls(h).last(where: { $0.first as? String == "deleteMsgs" }) as? [String] == ["deleteMsgs", "u2", "512"])
    }

    @Test func recallChecksTheWindowAndCallsUndoMessage() throws {
        let h = harness()
        let done = h.run("r", "window.__zaloMsgActions.recall('u2', '500')")
        #expect(done?["status"] as? String == "done")
        let undo = try #require(calls(h).first)
        #expect(undo.count == 6 && undo[1] as? String == "900" && undo[2] as? String == "u2" && undo[3] as? Int == 42 && undo[4] as? String == "500" && undo[5] as? Bool == false)
        // Older than `recallMessageMaxTime`: the official toast text, nothing sent.
        let old = h.run("r2", "window.__zaloMsgActions.recall('u2', '502')")
        #expect(old?["status"] as? String == "denied" && old?["text"] as? String == "Bạn chỉ có thể thu hồi tin nhắn trong vòng 24 giờ")
        #expect(calls(h).count == 1)
        // Someone else's message is not recalled.
        #expect(h.run("r3", "window.__zaloMsgActions.recall('u2', '901')")?["status"] as? String == "invalid")
        // An album photo is recalled alone; being starred, it is unstarred after its recall, as the official client does.
        _ = h.run("r4", "window.__zaloMsgActions.recall('u2', '511')")
        #expect(calls(h).dropFirst().filter { $0.first as? String == "undo" }.compactMap { $0[1] as? String } == ["911"])
        #expect(calls(h).contains { $0 as? [String] == ["unstar", "511"] })
    }

    @Test func recallErrorsUseTheOfficialTexts() {
        let old = harness(undoError: "{ error_code: 211 }").run("r", "window.__zaloMsgActions.recall('u2', '500')")
        #expect(old?["status"] as? String == "error" && old?["text"] as? String == "Phiên bản Zalo bên người nhận chưa hỗ trợ thu hồi tin nhắn")
        let other = harness(undoError: "{ error_code: 9 }").run("r", "window.__zaloMsgActions.recall('u2', '500')")
        #expect(other?["text"] as? String == "Thu hồi tin nhắn không thành công (9)")
        let offline = harness(undoError: "{ code: 'ERR_NO_NETWORK' }").run("r", "window.__zaloMsgActions.recall('u2', '500')")
        #expect(offline?["text"] as? String == "Vui lòng kiểm tra lại kết nối mạng của bạn.")
    }

    @Test func deleteForMeReplaysTheOfficialFlowWithItsUndo() throws {
        let h = harness()
        let done = try #require(h.run("d", "window.__zaloMsgActions.deleteForMe('u2', '500', false)"))
        #expect(done["status"] as? String == "done")
        let undo = try #require(done["undo"] as? [String: Any])
        #expect(undo["id"] as? String == "77" && undo["count"] as? Int == 1 && (undo["ms"] as? Int ?? 0) > 5000)
        #expect(calls(h).map { $0.first as? String } == ["deleteMsgs", "apply"])
        #expect(calls(h).first as? [String] == ["deleteMsgs", "u2", "500"])
        // "Khôi phục" hands the official id back once.
        #expect(h.run("u", "window.__zaloMsgActions.undoDelete('77')")?["status"] as? String == "done")
        #expect(calls(h).last?.first as? String == "restore" && calls(h).last?.last as? Int == 77)
        #expect(h.run("u2", "window.__zaloMsgActions.undoDelete('77')")?["status"] as? String == "invalid")
        // The close button deletes for good.
        _ = h.run("d2", "window.__zaloMsgActions.deleteForMe('u2', '901', false)")
        #expect(h.text("String(window.__zaloMsgActions.commitDelete('77'))") == "true")
        #expect(calls(h).last?.first as? String == "commit")
    }

    @Test func deleteAsksFirstWhenTheOfficialConfirmIsOn() {
        let h = harness(popupDel: true)
        let ask = h.run("d", "window.__zaloMsgActions.deleteForMe('u2', '500', false)")
        #expect(ask?["status"] as? String == "confirm" && ask?["ok"] as? String == "Xóa tin nhắn" && ask?["cancel"] as? String == "Đóng")
        #expect(calls(h).isEmpty)
        #expect(h.run("d2", "window.__zaloMsgActions.deleteForMe('u2', '500', true)")?["status"] as? String == "done")
        // Someone else's message needs no confirm.
        #expect(h.run("d3", "window.__zaloMsgActions.deleteForMe('u2', '901', false)")?["status"] as? String == "done")
    }

    @Test func starAndUnstarUpdateTheStore() {
        let h = harness()
        #expect(h.run("s", "window.__zaloMsgActions.star('u2', '500', true)")?["status"] as? String == "done")
        let unstar = h.run("s2", "window.__zaloMsgActions.star('u2', '511', false)")
        #expect(unstar?["status"] as? String == "done" && unstar?["text"] as? String == "Đã bỏ đánh dấu tin nhắn")
        let log = calls(h)
        #expect(log.count == 4)
        #expect(log[0][0] as? String == "star" && log[0][1] as? String == "500")
        #expect(log[1] as? [AnyHashable] == ["dispatch", 515, "u2", 1])
        // An album photo unstars alone.
        #expect(log[2] as? [String] == ["unstar", "511"])
        #expect(log[3] as? [AnyHashable] == ["dispatch", 518, "u2", 1])
        // "Chặn chia sẻ" read fresh for native Copy.
        #expect(harness(protectedConv: true).run("p", "window.__zaloMsgActions.isProtected('u2').then(function (v) { return { v: v }; })")?["v"] as? Bool == true)
        #expect(h.run("p2", "window.__zaloMsgActions.isProtected('u2').then(function (v) { return { v: v }; })")?["v"] as? Bool == false)
    }

    @Test func oneOnOnePinBuildsTheOfficialTopic() throws {
        let h = harness()
        #expect(h.run("p", "window.__zaloMsgActions.pin('u2', '500')")?["status"] as? String == "done")
        let create = try #require(calls(h).first)
        #expect(create[0] as? String == "create11" && create[1] as? String == "u2" && create[2] as? Int == 2)
        #expect(create[3] as? String == "500" && create[4] as? String == "900" && create[5] as? String == "me1" && create[6] as? String == "tin 900")
        #expect(create[7] as? Int == 1 && create[8] as? Int == -14540254)
        // The pinned list follows, newest first, and the message reads as pinned.
        h.pump(steps: 4)
        let pins = try #require(h.run("l", "window.__zaloMsgActions.pins('u2')"))
        let items = try #require(pins["items"] as? [[String: Any]])
        #expect(pins["ready"] as? Bool == true && items.first?["title"] as? String == "tin 900" && items.first?["sender"] as? String == "Bạn")
        #expect(menu(h, "u2", 0)["pinned"] as? Bool == true)
    }

    @Test func aFullOneOnOneBoardAsksToReplaceTheOldestPin() throws {
        let h = harness(overMax: true)
        let ask = try #require(h.run("p", "window.__zaloMsgActions.pin('u2', '500')"))
        #expect(ask["status"] as? String == "confirm" && ask["ref"] as? String == "0:p0")
        #expect((ask["message"] as? String ?? "").contains("ghi chú"))
        let done = h.run("p2", "window.__zaloMsgActions.pin('u2', '500', '0:p0')")
        #expect(done?["status"] as? String == "done")
        #expect(calls(h).map { $0.first as? String } == ["create11", "unpin11", "create11"])
        #expect(calls(h)[1] as? [String] == ["unpin11", "u2", "p0"])
    }

    @Test func theOneOnOneLimitIsCheckedBeforeAskingTheManager() throws {
        // At the official limit (3) the replace question comes first: the manager is not asked (its "onexceed" opens a hidden dialog).
        let h = harness(fullBoard11: true)
        let ask = try #require(h.run("p", "window.__zaloMsgActions.pin('u2', '500')"))
        #expect(ask["status"] as? String == "confirm" && ask["ref"] as? String == "0:p1" && calls(h).isEmpty)
        #expect(h.run("p2", "window.__zaloMsgActions.pin('u2', '500', '0:p1')")?["status"] as? String == "done")
        #expect(calls(h).map { $0.first as? String } == ["unpin11", "create11"])
    }

    @Test func aGroupPinGoesOnOnceTheOldestIsUnpinnedEvenBeforeTheBoardSyncs() throws {
        let h = harness(groupFull: true, multiLazy: true)
        _ = h.run("p", "window.__zaloMsgActions.pin('g9', '700')")
        #expect(h.run("p2", "window.__zaloMsgActions.pin('g9', '700', '2:t1')")?["status"] as? String == "done")
        #expect(calls(h).map { $0.first as? String } == ["multi", "pinGroup"])
    }

    @Test func aFullGroupBoardReplacesTheOldestOnlyAfterConfirmation() throws {
        let h = harness(groupFull: true)
        let ask = try #require(h.run("p", "window.__zaloMsgActions.pin('g9', '700')"))
        #expect(ask["status"] as? String == "confirm" && ask["ref"] as? String == "2:t1" && ask["title"] as? String == "Cập nhật danh sách ghim")
        #expect(calls(h).isEmpty)
        #expect(h.run("p2", "window.__zaloMsgActions.pin('g9', '700', '2:t1')")?["status"] as? String == "done")
        #expect(calls(h).first as? [String] == ["multi", "g9", "t1"])
        let pin = try #require(calls(h).last)
        #expect(pin[0] as? String == "pinGroup" && pin[2] as? Int == 2 && pin[3] as? String == "700" && pin[4] as? Int == 1 && pin[5] as? Bool == true)
        // Unpinning from the bar goes through the board.
        _ = h.run("l", "window.__zaloMsgActions.pins('g9')")
        #expect(h.run("u", "window.__zaloMsgActions.unpin('g9', '3:t2')")?["status"] as? String == "done")
        #expect(calls(h).last as? [AnyHashable] == ["unpinGroup", "g9", "t2", 3])
    }

    @Test func pinsAreNotReadInMyCloud() {
        let h = harness()
        let pins = h.run("l", "window.__zaloMsgActions.pins('cloud1')")
        #expect(pins?["ready"] as? Bool == false && (pins?["items"] as? [Any])?.isEmpty == true)
    }
}

// MARK: - Cleanup of a deleted photo's cached copies (`$znode.nativelibs.fileUtilitiesAddon.detectHardlinksAsync`)

@Suite struct HardlinkLookupTests {
    @Test func findsTheLinksOfAFileUnderAFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("olaz-hardlinks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let picture = root.appendingPathComponent("picture"), cache = root.appendingPathComponent("Cache/sub")
        try fm.createDirectory(at: picture, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let original = picture.appendingPathComponent("a.jpg"), lonely = picture.appendingPathComponent("b.jpg")
        try Data("photo".utf8).write(to: original)
        try Data("other".utf8).write(to: lonely)
        let link = cache.appendingPathComponent("a-copy.jpg")
        try fm.linkItem(at: original, to: link)

        let found = try FileSystemBridge.hardlinks(of: original.path, under: root.appendingPathComponent("Cache").path)
        #expect(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [link.resolvingSymlinksInPath().path])
        // Under the whole folder the file itself is one of its links.
        #expect(try FileSystemBridge.hardlinks(of: original.path, under: root.path).count == 2)
        // A single-link file, a missing file or a missing folder: no links.
        #expect(try FileSystemBridge.hardlinks(of: lonely.path, under: root.path).isEmpty)
        #expect(try FileSystemBridge.hardlinks(of: root.appendingPathComponent("none.jpg").path, under: root.path).isEmpty)
        #expect(try FileSystemBridge.hardlinks(of: original.path, under: root.appendingPathComponent("missing").path).isEmpty)
    }
}
