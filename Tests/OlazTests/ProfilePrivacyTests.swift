import Foundation
import JavaScriptCore
import Testing
@testable import Olaz

@Suite struct ProfilePrivacyTests {
    private var vnCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return cal
    }

    // MARK: - ZaloEngine.Profile parsing & formatting

    @Test func parsesCompleteUserSnapshotIncludingZeroGenderAndStatus() {
        let user: [String: Any] = [
            "userId": "u1001",
            "displayName": "Minh Anh",
            "zaloName": "minhanh",
            "avatar": "https://cdn.example/a.jpg",
            "phoneNumber": "+84901234567",
            "gender": 0,
            "dob": 800_000_000,
            "status": "Đang làm việc",
        ]

        let profile = ZaloEngine.Profile.parse(user: user)
        #expect(profile == ZaloEngine.Profile(
            userId: "u1001",
            displayName: "Minh Anh",
            avatar: URL(string: "https://cdn.example/a.jpg"),
            phone: "+84901234567",
            gender: 0,
            dob: 800_000_000,
            status: "Đang làm việc"
        ))
    }

    @Test func normalizesDobMillisecondsNegativeTimestampsAndFallbacks() {
        let existing = ZaloEngine.Profile(
            userId: "u42",
            displayName: "Lan",
            avatar: URL(string: "https://cdn.example/old.jpg"),
            phone: "+84988888888",
            gender: 1,
            dob: -315_619_200,
            status: "Xin chào"
        )

        // Partial Redux tick for same user: keeps phone/gender/dob/status and falls back displayName -> zaloName.
        let partialSameUser: [String: Any] = [
            "userId": "u42",
            "displayName": "",
            "zaloName": "Lan Nguyễn",
            "avatar": "",
            "status": "",
        ]
        let merged = ZaloEngine.Profile.parse(user: partialSameUser, fallback: existing)
        #expect(merged?.displayName == "Lan Nguyễn")
        #expect(merged?.avatar == URL(string: "https://cdn.example/old.jpg"))
        #expect(merged?.phone == "+84988888888")
        #expect(merged?.gender == 1)
        #expect(merged?.dob == -315_619_200)
        #expect(merged?.status == "Xin chào")

        // Millisecond dob (positive and negative pre-1970) converts to seconds cleanly.
        let msUser: [String: Any] = [
            "userId": "u99",
            "displayName": "Hùng",
            "gender": 0,
            "dob": 900_000_000_000.0,
        ]
        let parsedMs = ZaloEngine.Profile.parse(user: msUser, fallback: existing)
        #expect(parsedMs?.dob == 900_000_000.0)
        #expect(parsedMs?.phone == nil)
        #expect(parsedMs?.status == nil)

        let pre1970Ms: [String: Any] = [
            "userId": "u100",
            "displayName": "Bình",
            "dob": -315_619_200_000.0,
        ]
        #expect(ZaloEngine.Profile.parse(user: pre1970Ms)?.dob == -315_619_200.0)

        // Missing or empty userId returns nil.
        #expect(ZaloEngine.Profile.parse(user: ["displayName": "No ID"]) == nil)
        #expect(ZaloEngine.Profile.parse(user: ["userId": ""]) == nil)
    }

    @Test func formatsDobAsOfficialYYYYMMDD() {
        let components = DateComponents(year: 1995, month: 3, day: 9, hour: 10)
        let date = vnCalendar.date(from: components)!
        #expect(ZaloEngine.Profile.formatDOB(date, calendar: vnCalendar) == "1995-03-09")
    }

    // MARK: - PrivacySettings & BlockedUser mappings

    @Test func privacySettingsDefaultsMatchOfficialClient() {
        let defaults = PrivacySettings()
        #expect(defaults.viewBirthday == .hidden)
        #expect(defaults.showOnlineStatus == true)
        #expect(defaults.displaySeenStatus == true)
        #expect(defaults.receiveMessage == .everyone)
        #expect(defaults.acceptStrangerCall == .friendsOnly)
        #expect(defaults.addFriendViaPhone == true)
        #expect(defaults.addFriendViaQR == true)
        #expect(defaults.addFriendViaGroup == true)
        #expect(defaults.addFriendViaContact == true)
        #expect(defaults.displayOnRecommendFriend == true)
    }

    @Test func parsesAllTenPrivacyKeysAndNonMonotonicCallEnum() {
        let raw: [String: Any] = [
            "view_birthday": 2,
            "show_online_status": 0,
            "display_seen_status": false,
            "receive_message": 2,
            "accept_stranger_call": 4,
            "add_friend_via_phone": 0,
            "add_friend_via_qr": 1,
            "add_friend_via_group": false,
            "add_friend_via_contact": 0,
            "display_on_recommend_friend": 0,
        ]

        let parsed = PrivacySettings.parse(raw)
        #expect(parsed.viewBirthday == .monthAndDayOnly)
        #expect(parsed.showOnlineStatus == false)
        #expect(parsed.displaySeenStatus == false)
        #expect(parsed.receiveMessage == .friendsOnly)
        #expect(parsed.acceptStrangerCall == .friendsAndContactedStrangers)
        #expect(parsed.addFriendViaPhone == false)
        #expect(parsed.addFriendViaQR == true)
        #expect(parsed.addFriendViaGroup == false)
        #expect(parsed.addFriendViaContact == false)
        #expect(parsed.displayOnRecommendFriend == false)

        // Verify CallStrangerOption raw values match Zalo's non-sequential constants: 2 (friends), 4 (contacted), 3 (everyone).
        #expect(CallStrangerOption.parse(2) == .friendsOnly)
        #expect(CallStrangerOption.parse(4) == .friendsAndContactedStrangers)
        #expect(CallStrangerOption.parse(3) == .everyone)
        #expect(CallStrangerOption.parse(999) == .friendsOnly)

        #expect(BirthdayVisibility.parse(0) == .hidden)
        #expect(BirthdayVisibility.parse(1) == .fullDate)
        #expect(BirthdayVisibility.parse(2) == .monthAndDayOnly)

        #expect(MessageStrangerOption.parse(1) == .everyone)
        #expect(MessageStrangerOption.parse(2) == .friendsOnly)
    }

    @Test func applyAndWireValueRoundTripAcrossAllPrivacyKeys() {
        var settings = PrivacySettings()
        let testValues: [(PrivacySettingKey, Int)] = [
            (.viewBirthday, 1),
            (.showOnlineStatus, 0),
            (.displaySeenStatus, 0),
            (.receiveMessage, 2),
            (.acceptStrangerCall, 3),
            (.addFriendViaPhone, 0),
            (.addFriendViaQR, 0),
            (.addFriendViaGroup, 0),
            (.addFriendViaContact, 0),
            (.displayOnRecommendFriend, 0),
        ]

        for (key, value) in testValues {
            settings.apply(key: key, wireValue: value)
            #expect(settings.wireValue(for: key) == value)
        }
        #expect(settings.viewBirthday == .fullDate)
        #expect(settings.acceptStrangerCall == .everyone)
        #expect(settings.receiveMessage == .friendsOnly)
        #expect(settings.showOnlineStatus == false)
    }

    @Test func parsesBlockedUserShapesWithFallbacks() {
        let a = BlockedUser(json: [
            "userId": "u1",
            "displayName": "Người A",
            "zaloName": "a_zalo",
            "avatar": "https://cdn.example/1.jpg",
        ])
        #expect(a == BlockedUser(
            userId: "u1",
            displayName: "Người A",
            zaloName: "a_zalo",
            avatar: URL(string: "https://cdn.example/1.jpg")
        ))
        #expect(a?.resolvedName == "Người A")

        let b = BlockedUser(json: [
            "id": "u2",
            "dName": "",
            "zName": "Zalo B",
            "avatar": "",
        ])
        #expect(b?.userId == "u2")
        #expect(b?.resolvedName == "Zalo B")
        #expect(b?.avatar == nil)

        #expect(BlockedUser(json: ["displayName": "No ID"]) == nil)
    }

    // MARK: - Logout reset

    @MainActor
    @Test func logoutResetsProfilePrivacySettingsAndBlockedUsers() {
        let engine = ZaloEngine()
        engine.handle(state: [
            "page": "main",
            "user": [
                "userId": "u77",
                "displayName": "Tài khoản A",
                "gender": 1,
                "dob": 850_000_000,
                "status": "Bio",
            ],
        ])
        engine.privacySettings = PrivacySettings(
            viewBirthday: .fullDate,
            showOnlineStatus: false,
            displaySeenStatus: false,
            receiveMessage: .friendsOnly,
            acceptStrangerCall: .everyone,
            addFriendViaPhone: false
        )
        engine.privacyError = "Old error"
        engine.blockedUsers = [BlockedUser(userId: "u9", displayName: "Bị chặn")]
        engine.blockedUsersLoaded = true

        #expect(engine.profile?.userId == "u77")
        #expect(engine.privacySettings != nil)
        #expect(engine.blockedUsers.count == 1)

        engine.handle(.loggedOut)

        #expect(engine.profile == nil)
        #expect(engine.privacySettings == nil)
        #expect(engine.privacyError == nil)
        #expect(engine.privacyLoading == false)
        #expect(engine.blockedUsers.isEmpty)
        #expect(engine.blockedUsersLoaded == false)
    }

    // MARK: - JavaScriptCore adapter contract tests

    @MainActor
    @Test func profileAdapterContractGetUpdateStatusAndAvatar() throws {
        let h = ScriptHarness(prelude: """
        var logs = [];
        var profileCalls = [];
        var statusCalls = [];
        window.webkit = { messageHandlers: { zlog: { postMessage: function (m) { logs.push(m); } } } };
        var serverMe = {
          userId: 'me1',
          displayName: 'Cũ',
          zaloName: 'cu.zalo',
          avatar: 'https://cdn.example/old.jpg',
          phoneNumber: '+84900000001',
          gender: 0,
          dob: 820454400,
          status: 'Trạng thái cũ'
        };
        var uiPd = {
          getProfileMe: function (force) {
            profileCalls.push(['getProfileMe', Boolean(force)]);
            return Promise.resolve(Object.assign({}, serverMe));
          },
          updateProfileMe: function (payload) {
            profileCalls.push(['updateProfileMe', payload.name, payload.gender, payload.dob]);
            serverMe.displayName = payload.name;
            serverMe.gender = payload.gender;
            return Promise.resolve({});
          },
          updateMyAvatar: function (size, cid, file, meta) {
            profileCalls.push(['updateMyAvatar', size, file.name, file.type, file.parts[0].length, meta.origin.width, meta.origin.height, meta.processed.size]);
            serverMe.avatar = 'https://cdn.example/new.jpg';
            return Promise.resolve({});
          }
        };
        var fBUP = {
          updateStatus: function (escaped) {
            statusCalls.push(escaped);
            // Official fBUP interpolates '{"status":"'+e+'"}'; ensure JSON remains valid.
            var parsed = JSON.parse('{"status":"' + escaped + '"}');
            serverMe.status = parsed.status;
            return Promise.resolve({ error_code: 0 });
          },
          getSettings: function () { return Promise.resolve({}); },
          setSettings: function () { return Promise.resolve({}); }
        };
        // Proxy trap simulating $capp uninitialized export that must be skipped cleanly.
        var badProxy = new Proxy({}, { get: function (_t, p) { if (p === '__olaz_not_a_member__') return true; return function () {}; } });
        window.__zaloRequire = {
          c: {
            PROXY: { exports: badProxy },
            UiPd: { exports: { default: uiPd } },
            lazyApi: { exports: null }
          },
          m: {
            fBUP: function () {}
          }
        };
        window.__zaloRequire = Object.assign(function (id) {
          if (id === 'fBUP') return { default: fBUP };
          return null;
        }, window.__zaloRequire);
        var atob = function (s) { return s === 'AQI=' ? '\\u0001\\u0002' : ''; };
        var Blob = function (parts, opts) { this.parts = parts; this.type = opts.type; };
        """)
        h.load("profile-adapter.js")

        // 1. getProfileMe preserves gender 0 and normalizes fields
        let me = try #require(h.run("me", "window.__olazProfile.getProfileMe(true)"))
        #expect(me["ok"] as? Bool == true)
        let profile = try #require(me["profile"] as? [String: Any])
        #expect(profile["userId"] as? String == "me1")
        #expect(profile["gender"] as? Int == 0)
        #expect(profile["dob"] as? Int == 820_454_400)
        #expect(profile["status"] as? String == "Trạng thái cũ")

        // 2. Invalid updateProfile fails before hitting UiPd
        let invalid = try #require(h.run("bad", "window.__olazProfile.updateProfile({ name: '   ', gender: 1, dob: '1999-01-01' })"))
        #expect(invalid["ok"] as? Bool == false)
        let badDob = try #require(h.run("badDob", "window.__olazProfile.updateProfile({ name: 'An', gender: 2, dob: '1999/01/01' })"))
        #expect(badDob["ok"] as? Bool == false)

        // 3. Valid updateProfile trims name and sends YYYY-MM-DD
        let updated = try #require(h.run("upd", "window.__olazProfile.updateProfile({ name: '  Minh Anh  ', gender: 1, dob: '1998-04-05' })"))
        #expect(updated["ok"] as? Bool == true)
        let updProf = try #require(updated["profile"] as? [String: Any])
        #expect(updProf["displayName"] as? String == "Minh Anh")
        #expect(updProf["gender"] as? Int == 1)
        #expect(h.text("JSON.stringify(profileCalls.filter(function(c){return c[0]==='updateProfileMe';}))") == #"[["updateProfileMe","Minh Anh",1,"1998-04-05"]]"#)

        // 4. updateStatus resolves lazy module via req.m and escapes quotes & newlines safely
        let statusRes = try #require(h.run("st", #"window.__olazProfile.updateStatus('Xin "chào"\nZalo')"#))
        #expect(statusRes["ok"] as? Bool == true)
        #expect(statusRes["status"] as? String == "Xin \"chào\"\nZalo")
        let stProf = try #require(statusRes["profile"] as? [String: Any])
        #expect(stProf["status"] as? String == "Xin \"chào\"\nZalo")

        // 5. updateAvatar decodes base64, passes size 160 + file metadata + refreshed URL
        let avatarRes = try #require(h.runUntilSettled("avt", "window.__olazProfile.updateAvatar('AQI=', 320, 320)"))
        #expect(avatarRes["ok"] as? Bool == true)
        #expect(avatarRes["avatar"] as? String == "https://cdn.example/new.jpg")
        #expect(h.text("JSON.stringify(profileCalls.filter(function(c){return c[0]==='updateMyAvatar';}))") == #"[["updateMyAvatar",160,"avatar.jpg","image/jpeg",2,320,320,2]]"#)
        #expect(h.failures.isEmpty)
    }

    @MainActor
    @Test func profileAdapterFallsBackToSubmittedDobWhenRefreshFails() throws {
        let h = ScriptHarness(prelude: """
        window.webkit = { messageHandlers: { zlog: { postMessage: function () {} } } };
        window.__zaloStore = {
          getState: function () {
            return {
              user: {
                userId: 'me1',
                displayName: 'Tên Cũ',
                gender: 0,
                dob: 820454400,
                status: 'Bio cũ'
              }
            };
          }
        };
        var uiPd = {
          getProfileMe: function () { return Promise.reject({ error_code: 500 }); },
          updateProfileMe: function () { return Promise.resolve({}); },
          updateMyAvatar: function () { return Promise.resolve({}); }
        };
        window.__zaloRequire = { c: { UiPd: { exports: { default: uiPd } } } };
        """)
        h.load("profile-adapter.js")

        let res = try #require(h.run("upd", "window.__olazProfile.updateProfile({ name: 'Tên Mới', gender: 1, dob: '2000-06-15' })"))
        #expect(res["ok"] as? Bool == true)
        let profDict = try #require(res["profile"] as? [String: Any])
        #expect(profDict["displayName"] as? String == "Tên Mới")
        #expect(profDict["gender"] as? Int == 1)
        let dobSeconds = try #require((profDict["dob"] as? NSNumber)?.doubleValue)
        #expect(dobSeconds != 820_454_400)

        let parsed = try #require(ZaloEngine.Profile.parse(user: profDict))
        let dobDate = try #require(parsed.dobDate)
        #expect(ZaloEngine.Profile.formatDOB(dobDate) == "2000-06-15")
        #expect(h.failures.isEmpty)
    }

    @MainActor
    @Test func privacyAdapterContractSettingsBlocklistAndBlockToggle() throws {
        let h = ScriptHarness(prelude: """
        var logs = [];
        var calls = [];
        window.webkit = { messageHandlers: { zlog: { postMessage: function (m) { logs.push(m); } } } };
        var blockedSet = { u10: true };
        var storeSettings = {};
        var privacySvc = {
          settings: storeSettings,
          fetchSetting: function () {
            calls.push(['fetchSetting']);
            setTimeout(function () {
              storeSettings.view_birthday = 2;
              storeSettings.show_online_status = 1;
              storeSettings.display_seen_status = 0;
              storeSettings.receive_message = 2;
              storeSettings.accept_stranger_call = 4;
              storeSettings.add_friend_via_phone = 0;
              storeSettings.add_friend_via_qr = 1;
              storeSettings.add_friend_via_group = 1;
              storeSettings.add_friend_via_contact = 0;
              storeSettings.display_on_recommend_friend = 1;
            }, 150);
          },
          getSetting: function (k) {
            return Object.prototype.hasOwnProperty.call(storeSettings, k) ? storeSettings[k] : null;
          },
          setSetting: function (k, v) {
            calls.push(['setSetting', k, v]);
            storeSettings[k] = v;
          },
          updateSettings: function (obj, onOk, onErr) {
            calls.push(['updateSettings', obj]);
            if (obj.view_birthday === -1) { onErr({ rawError: { error_code: 500 } }); return; }
            onOk({ error_code: 0 });
          }
        };
        var friendMgr = {
          fetchBlockedFriendList: function () {
            calls.push(['fetchBlockedFriendList']);
            return Promise.resolve([
              { userId: 'u10', displayName: 'Chặn Một', zaloName: 'c1', avatar: 'https://a/10.jpg' },
              { id: 'u11', dName: '', zName: '', avatar: '' },
              { userId: 'u10', displayName: 'Duplicate' }
            ]);
          }
        };
        var profileSvc = {
          getProfileMe: function () { return Promise.resolve({}); },
          getMiniInfo: function (uid) { return uid === 'u11' ? { dName: 'Minh Từ Cache', zName: 'minh.z', avatar: 'https://a/11.jpg' } : null; },
          isBlocked: function (uid) { return Boolean(blockedSet[uid]); },
          blockFriend: function (uid, action) {
            calls.push(['blockFriend', uid, action]);
            if (uid === 'already' && action === 1) return Promise.reject({ error_code: 215 });
            blockedSet[uid] = (action === 1);
            return Promise.resolve({});
          }
        };
        var consts = { SET_BLOCK: 1, UNSET_BLOCK: 2, ALREADY_BLOCK_ERROR_CODE: 215 };
        window.__zaloRequire = {
          c: {
            uWWm: { exports: { default: privacySvc } },
            dSSf: { exports: { default: friendMgr } },
            UiPd: { exports: { default: profileSvc } },
            '1pet': { exports: consts }
          }
        };
        """)
        h.load("privacy-adapter.js")

        // 1. Cold settings triggers fetchSetting() and returns all 10 keys
        let loaded = try #require(h.runUntilSettled("get", "window.__olazPrivacy.getSettings(false)"))
        #expect(loaded["ok"] as? Bool == true)
        let s = try #require(loaded["settings"] as? [String: Any])
        #expect(s["view_birthday"] as? Int == 2)
        #expect(s["display_seen_status"] as? Int == 0)
        #expect(s["accept_stranger_call"] as? Int == 4)
        #expect(s["receive_message"] as? Int == 2)
        #expect(s["add_friend_via_phone"] as? Int == 0)

        // 2. updateSetting updates server, propagates to setSetting, and blocks unknown keys
        let updBool = try #require(h.run("upd1", "window.__olazPrivacy.updateSetting('show_online_status', false)"))
        #expect(updBool["ok"] as? Bool == true)
        #expect(updBool["value"] as? Int == 0)
        #expect(h.number("storeSettings.show_online_status") == 0)

        let badKey = try #require(h.run("badKey", "window.__olazPrivacy.updateSetting('not_a_real_key', 1)"))
        #expect(badKey["ok"] as? Bool == false)

        // 3. getBlockedUsers deduplicates and enriches missing names via getMiniInfo
        let listRes = try #require(h.run("blk", "window.__olazPrivacy.getBlockedUsers()"))
        #expect(listRes["ok"] as? Bool == true)
        let users = try #require(listRes["users"] as? [[String: Any]])
        #expect(users.count == 2)
        #expect(users[0]["userId"] as? String == "u10")
        #expect(users[1]["userId"] as? String == "u11")
        #expect(users[1]["displayName"] as? String == "Minh Từ Cache")

        // 4. setBlocked uses SET_BLOCK (1) / UNSET_BLOCK (2) and updates isBlocked; 215 already-blocked succeeds idempotently
        #expect(h.ctx.evaluateScript("window.__olazPrivacy.isBlocked('u10')")?.toBool() == true)
        let unblockRes = try #require(h.run("ub", "window.__olazPrivacy.setBlocked('u10', false)"))
        #expect(unblockRes["ok"] as? Bool == true)
        #expect(h.ctx.evaluateScript("window.__olazPrivacy.isBlocked('u10')")?.toBool() == false)

        let blockRes = try #require(h.run("bl", "window.__olazPrivacy.setBlocked('u12', true)"))
        #expect(blockRes["ok"] as? Bool == true)
        #expect(h.ctx.evaluateScript("window.__olazPrivacy.isBlocked('u12')")?.toBool() == true)

        let alreadyRes = try #require(h.run("alr", "window.__olazPrivacy.setBlocked('already', true)"))
        #expect(alreadyRes["ok"] as? Bool == true)
        #expect(h.failures.isEmpty)
    }
}
