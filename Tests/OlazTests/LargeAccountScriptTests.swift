import Testing
import Foundation
@testable import Olaz

// What the adapters cost per tick on a large account (thousands of conversations, long loaded histories): the real
// `chat-adapter.js` and `state-adapter.js` in JavaScriptCore against a fake official store. Every fixture is synthetic.

/// `posts` collects what the scripts send to Swift through `zstate`.
private let postsPrelude = """
var posts = [];
var webkit = { messageHandlers: { zstate: { postMessage: function (s) { posts.push(JSON.parse(JSON.stringify(s))); } }, zlog: { postMessage: function () {} } } };
"""

// MARK: - chat-adapter.js: the open conversation is re-mapped only where it changed

@Suite struct ChatFlushScriptTests {
    private func harness() -> ScriptHarness {
        let h = ScriptHarness(prelude: postsPrelude + """
        var NOW = Date.now();
        var text = function (id, from, extra) { var m = { msgId: id, cliMsgId: String(Number(id) - 400), fromUid: from, toUid: 'u2', msgType: 1, status: 1, message: 'tin ' + id, sendDttm: NOW - 1000 }; for (var k in extra || {}) m[k] = extra[k]; return m; };
        var convs = { u2: { messages: [text('900', '0'), text('901', 'u2'), text('902', 'u2'), text('903', '0', { status: 10 })], msgList: { hasMoreLocal: true } } };
        var subs = [], describeCalls = 0, reactListeners = [];
        var tick = function () { subs.forEach(function (f) { f(); }); };
        var replace = function (messages) { convs.u2 = Object.assign({}, convs.u2, { messages: messages }); tick(); };
        window.__zaloStore = { getState: function () { return { user: { userId: 'me1', displayName: 'Tôi', avatar: '' }, conversations: { alls: convs } }; }, subscribe: function (f) { subs.push(f); }, dispatch: function () {} };
        var loader = { cacheMessageLoader: new Map([['u2', { active: function () {}, deActive: function () {} }]]), getLastMessagesForConversation: async function () {} };
        var typing = { mapIdTyping: {}, addItemTyping: function () {}, removeItemTyping: function () {} };
        var reactCache = { generateReactMsg: function () {}, updateReactionListener: null, addUpdateReactListener: function (f) { reactListeners.push(f); }, getMessageReactions: async function () { return {}; }, getIconMap: function () { return {}; } };
        var reactSender = { sendQueue: [], sendReaction: function () {} };
        var cfg = { stickerUrl: 'https://s/', sendToMeId: 'cloud1' };
        var chat = { broadCastMessage: function () {}, chatboxController: { convId: 'u2' } };
        var opener = { openConversation: async function () {}, conversationWillOpen: function () {}, closeConversation: async function () {}, sidebar: { getSelectedId: function () { return 'u2'; } } };
        var io = { getFriendManagerModule: async function () { return { default: { getDName: function (u) { return u === 'u2' ? 'Bạn Hai' : ''; }, getAvatar: function () { return 'https://a/x.jpg'; } } }; }, getGroupManagerModule: async function () { return { default: {} }; } };
        window.__zaloRequire = { c: {} };
        window.__zaloDI = function () { return [{ instance: chat }, { instance: opener }, { instance: io }]; };
        window.__zaloEachExport = function (req, visit) { [loader, typing, reactCache, reactSender, cfg].forEach(function (ex) { visit(ex, 'x'); }); };
        window.__zaloMsgActions = { describe: function () { describeCalls++; return { forward: 'ok', recall: false, delete: 'forMe', pin: false, star: 'star', starred: false, protected: false, pinned: false }; } };
        window.__zaloCardActions = { describe: function () { return null; } };
        var changedIds = function () { return posts.filter(function (p) { return p.chat; }).map(function (p) { return p.chat.messages.map(function (m) { return m.id; }); }).reduce(function (a, b) { return a.concat(b); }, []); };
        """)
        h.load("chat-adapter.js")
        return h
    }

    /// Runs the fake clock a little: the 150 ms flush fires, the 10 s periodic full map does not.
    private func settle(_ h: ScriptHarness) { h.pump(steps: 3, step: 200) }

    @Test func aTickPostsOnlyTheRowsThatChangedAndMapsOnlyChangedMessages() {
        let h = harness()
        _ = h.runUntilSettled("open", "window.__zaloChat.open('u2')", step: 200)
        settle(h)
        #expect(h.failures.isEmpty, "\(h.failures)")
        #expect(h.text("String(posts.some(function (p) { return p.chat && p.chat.reset && p.chat.messages.length === 4; }))") == "true")

        // A store tick that changes nothing: nothing posted, nothing mapped.
        h.ctx.evaluateScript("posts = []; var base = describeCalls; tick();")
        settle(h)
        #expect(h.number("posts.length") == 0 && h.number("describeCalls - base") == 0)

        // One message appended (the array is replaced, the other objects are kept): only it is mapped and posted.
        h.ctx.evaluateScript("posts = []; base = describeCalls; replace(convs.u2.messages.concat([text('904', 'u2')]));")
        settle(h)
        #expect(h.text("JSON.stringify(changedIds())") == #"["904"]"#)
        #expect(h.number("describeCalls - base") == 1)
        #expect(h.text("String(posts[0].chat.reset)") == "false")

        // The official store may update a message in place: a status change on the same object is still noticed.
        h.ctx.evaluateScript("posts = []; convs.u2.messages[3].status = 1; replace(convs.u2.messages.slice());")
        settle(h)
        #expect(h.text("JSON.stringify(posts.map(function (p) { return p.chat.messages.map(function (m) { return m.id + ':' + m.status; }); }))") == #"[["503:sent"]]"#)

        // A message that left the list is reported as removed.
        h.ctx.evaluateScript("posts = []; replace(convs.u2.messages.filter(function (m) { return m.msgId !== '902'; }));")
        settle(h)
        #expect(h.text("JSON.stringify(posts.map(function (p) { return p.chat.removed; }))") == #"[["902"]]"#)
    }

    @Test func reactionsElsewhereDoNotFlushTheOpenConversation() {
        let h = harness()
        _ = h.runUntilSettled("open", "window.__zaloChat.open('u2')", step: 200)
        settle(h)
        // A reaction on a message of another conversation: no flush at all.
        h.ctx.evaluateScript("posts = []; reactListeners.forEach(function (f) { f({ rMsgId: '77777', reactions: { '0': { 3: 1 } } }); });")
        settle(h)
        #expect(h.number("posts.length") == 0)
        // A reaction on a loaded message: that message is posted with its chip.
        h.ctx.evaluateScript("posts = []; reactListeners.forEach(function (f) { f({ rMsgId: '901', reactions: { u2: { 3: 1 } } }); });")
        settle(h)
        #expect(h.text("JSON.stringify(posts.map(function (p) { return p.chat.messages.map(function (m) { return m.id + ':' + m.reactions.length; }); }))") == #"[["901:1"]]"#)
    }
}

// MARK: - state-adapter.js: the conversation list goes to Swift as deltas

@Suite struct ConversationListDeltaScriptTests {
    private func harness() -> ScriptHarness {
        let h = ScriptHarness(prelude: postsPrelude + """
        var __intervals = [];
        setInterval = function (f) { __intervals.push(f); return __intervals.length; };
        var runIntervals = function () { __intervals.forEach(function (f) { f(); }); };
        var document = { body: {} };
        var previews = new Map(), convs = new Map(), unread = new Map(), formatCalls = 0;
        var io = { getFriendManagerModule: async function () { return { default: { getDName: function (id) { return 'Bạn ' + id; }, getAvatar: function (id) { return 'https://a/' + id; } } }; }, getGroupManagerModule: async function () { return { default: { getDName: function (id) { return 'Nhóm ' + id; }, getAvatarGroup: function () { return ''; }, getTotalMember: function () { return 3; } } }; } };
        var convMgr = { getConvByIdSync: function () {}, addOrUpdateConv: function () {}, data: convs };
        var unreadMgr = { getUnreadByConvIdSync: function (id) { return { smsUnreadCount: unread.get(id) || 0 }; } };
        var previewMgr = { convertDBMessageToPreviewItem: function () {}, data: previews };
        var container = { resolve: function () {}, _registry: { _registryMap: new Map([['a', [{ instance: io }, { instance: convMgr }, { instance: unreadMgr }, { instance: previewMgr }]]]) } };
        var store = { getState: function () { return { user: { userId: 'me1', displayName: 'Tôi' }, conversations: {} }; }, dispatch: function () {}, subscribe: function () {} };
        // The official preview formatter is found by its source: the signature strings sit in this comment.
        var fmt = { a: function (p) { formatCalls++; /* STR_VIDEO_MSG_NO_BRACKET computedMessage */ return { message: p.computedMessage || p.message, icon: '' }; } };
        var req = { c: { store: { exports: store }, di: { exports: container }, fmt: { exports: fmt } }, m: {} };
        var webpackJsonp = { push: function (chunk) { chunk[1][chunk[0][0]]({}, {}, req); } };
        for (var i = 0; i < 300; i++) { convs.set('u' + i, { isGroup: false }); previews.set('u' + i, { message: 'xin chào ' + i, messageTime: Date.now() - i * 1000, fromUid: 'u' + i, messageType: 1, msgId: 'm' + i }); }
        var listPosts = function () { return posts.filter(function (p) { return p.conversations; }); };
        var changed = function () { return listPosts().map(function (p) { return p.conversations.map(function (r) { return r.id + ':' + (r.preview ? r.preview.text : '') + ':' + r.unread; }); }).reduce(function (a, b) { return a.concat(b); }, []); };
        """)
        h.load("state-adapter.js")
        return h
    }

    /// One publish tick: the 1.5 s interval runs and its promise settles.
    private func tick(_ h: ScriptHarness) {
        h.ctx.evaluateScript("runIntervals();")
        h.pump(steps: 2, step: 10)
    }

    @Test func theFirstPostResetsAndLaterPostsCarryOnlyChanges() {
        let h = harness()
        tick(h); tick(h)
        #expect(h.failures.isEmpty, "\(h.failures)")
        #expect(h.text("String(listPosts()[0].reset)") == "true" && h.number("listPosts()[0].conversations.length") == 300)
        #expect(h.number("formatCalls") == 300)

        // A quiet tick posts nothing and formats nothing (the preview memo).
        h.ctx.evaluateScript("posts = []; var base = formatCalls;")
        tick(h)
        #expect(h.number("listPosts().length") == 0 && h.number("formatCalls - base") == 0)

        // A new message in one conversation and an unread bump in another: two rows, one formatter call.
        h.ctx.evaluateScript("posts = []; base = formatCalls; previews.set('u7', { message: 'tin mới', messageTime: Date.now(), fromUid: 'u7', messageType: 1, msgId: 'm7b' }); unread.set('u9', 2);")
        tick(h)
        #expect(h.text("JSON.stringify(changed())") == #"["u7:tin mới:0","u9:xin chào 9:2"]"#)
        #expect(h.text("String(listPosts()[0].reset)") == "false" && h.number("formatCalls - base") == 1)

        // A preview item updated in place (same object) is noticed by its time / id.
        h.ctx.evaluateScript("posts = []; var p = previews.get('u8'); p.message = 'sửa tại chỗ'; p.messageTime = Date.now(); p.msgId = 'm8b';")
        tick(h)
        #expect(h.text("JSON.stringify(changed())") == #"["u8:sửa tại chỗ:0"]"#)

        // A conversation that left the index is reported as removed.
        h.ctx.evaluateScript("posts = []; convs.delete('u5');")
        tick(h)
        #expect(h.text("JSON.stringify(listPosts().map(function (p) { return p.removed; }))") == #"[["u5"]]"#)
    }
}
