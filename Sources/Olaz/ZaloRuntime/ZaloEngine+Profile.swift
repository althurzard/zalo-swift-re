import Foundation
import ImageIO

// Self profile viewing & editing (`UiPd.getProfileMe`, `updateProfileMe`, `updateMyAvatar`, `fBUP.updateStatus`).
// Bridged to `HostScripts/profile-adapter.js` (`window.__olazProfile`).

enum ProfileGender: Int, CaseIterable, Identifiable, Sendable {
    case male = 0
    case female = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .male: "Nam"
        case .female: "Nữ"
        }
    }
}

enum ProfileMutationResult: Equatable, Sendable {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }
}

extension ZaloEngine.Profile {
    /// Parses a user profile payload from `state-adapter.js` or `profile-adapter.js`, preserving any already-known
    /// extended fields across partial Redux ticks for the same user.
    static func parse(user: [String: Any], fallback: ZaloEngine.Profile? = nil) -> ZaloEngine.Profile? {
        guard let id = user["userId"] as? String, !id.isEmpty else { return nil }
        let sameUser = fallback?.userId == id

        let rawDisplay = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rawZalo = (user["zaloName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let displayName = rawDisplay ?? rawZalo ?? (sameUser ? fallback?.displayName : nil) ?? ""

        let parsedAvatar = (user["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let avatar = parsedAvatar ?? (sameUser ? fallback?.avatar : nil)

        let parsedPhone = (user["phoneNumber"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let phone = parsedPhone ?? (sameUser ? fallback?.phone : nil)

        let rawGender = (user["gender"] as? NSNumber)?.intValue
            ?? (user["gender"] as? String).flatMap(Int.init)
        let gender: Int? = if let rawGender, rawGender == 0 || rawGender == 1 {
            rawGender
        } else {
            sameUser ? fallback?.gender : nil
        }

        let parsedDob: TimeInterval? = {
            let num = (user["dob"] as? NSNumber)?.doubleValue
                ?? (user["dob"] as? String).flatMap(Double.init)
            guard let num else { return sameUser ? fallback?.dob : nil }
            // Official `UiPd` / Redux uses Unix seconds; normalize millisecond timestamps if encountered.
            return abs(num) > 1e11 ? num / 1000.0 : num
        }()

        let parsedStatus: String? = {
            if let s = user["status"] as? String {
                if !s.isEmpty { return s }
                return sameUser ? fallback?.status : ""
            }
            return sameUser ? fallback?.status : nil
        }()

        return ZaloEngine.Profile(
            userId: id,
            displayName: displayName,
            avatar: avatar,
            phone: phone,
            gender: gender,
            dob: parsedDob,
            status: parsedStatus
        )
    }

    var dobDate: Date? {
        dob.map { Date(timeIntervalSince1970: $0) }
    }

    /// Official `updateProfileMe` expects `"YYYY-MM-DD"`.
    static func formatDOB(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 2000
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension ZaloEngine {
    @discardableResult
    func refreshMyProfile() async -> Profile? {
        guard let dict = await callProfile("getProfileMe", timeout: 12, true) else {
            EngineLog.shared.write("profile refresh no_answer")
            return profile
        }
        guard (dict["ok"] as? Bool) == true else {
            let code = (dict["errorCode"] as? NSNumber)?.stringValue ?? "none"
            EngineLog.shared.write("profile refresh fail code=\(code)")
            return profile
        }
        if let userDict = dict["profile"] as? [String: Any],
           let parsed = Profile.parse(user: userDict, fallback: profile) {
            applyProfile(parsed)
        }
        EngineLog.shared.write("profile refresh ok")
        return profile
    }

    func updateMyProfile(name: String, gender: Int, dob: Date) async -> ProfileMutationResult {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return .failure("Tên hiển thị không được để trống.") }
        guard gender == 0 || gender == 1 else { return .failure("Giới tính không hợp lệ.") }

        let dobString = Profile.formatDOB(dob)
        let payload: [String: Any] = [
            "name": cleanName,
            "gender": gender,
            "dob": dobString,
        ]
        guard let dict = await callProfile("updateProfile", timeout: 15, payload) else {
            EngineLog.shared.write("profile update timeout")
            return .failure("Không nhận được phản hồi từ Zalo.")
        }
        guard (dict["ok"] as? Bool) == true else {
            let code = (dict["errorCode"] as? NSNumber)?.stringValue ?? "none"
            EngineLog.shared.write("profile update fail code=\(code)")
            return .failure(dict["error"] as? String ?? "Cập nhật hồ sơ thất bại.")
        }
        if let userDict = dict["profile"] as? [String: Any],
           let parsed = Profile.parse(user: userDict, fallback: profile) {
            applyProfile(parsed)
        } else if var current = profile {
            current.displayName = cleanName
            current.gender = gender
            current.dob = dob.timeIntervalSince1970
            applyProfile(current)
        }
        EngineLog.shared.write("profile update ok")
        return .success
    }

    func updateMyStatus(_ text: String) async -> ProfileMutationResult {
        guard let dict = await callProfile("updateStatus", timeout: 15, text) else {
            EngineLog.shared.write("profile updateStatus timeout")
            return .failure("Không nhận được phản hồi từ Zalo.")
        }
        guard (dict["ok"] as? Bool) == true else {
            let code = (dict["errorCode"] as? NSNumber)?.stringValue ?? "none"
            EngineLog.shared.write("profile updateStatus fail code=\(code)")
            return .failure(dict["error"] as? String ?? "Cập nhật lời giới thiệu thất bại.")
        }
        if let userDict = dict["profile"] as? [String: Any],
           var parsed = Profile.parse(user: userDict, fallback: profile) {
            parsed.status = text
            applyProfile(parsed)
        } else if var current = profile {
            current.status = text
            applyProfile(current)
        }
        EngineLog.shared.write("profile updateStatus ok")
        return .success
    }

    func updateMyAvatar(jpegData: Data, width: Int = 0, height: Int = 0) async -> ProfileMutationResult {
        guard !jpegData.isEmpty else { return .failure("Ảnh đại diện không hợp lệ.") }
        let dims = (width > 0 && height > 0) ? (width, height) : Self.jpegPixelSize(jpegData)
        guard let dict = await callProfile("updateAvatar", timeout: 25, jpegData.base64EncodedString(), dims.0, dims.1) else {
            EngineLog.shared.write("profile updateAvatar timeout")
            return .failure("Tải ảnh đại diện lên quá thời gian chờ.")
        }
        guard (dict["ok"] as? Bool) == true else {
            let code = (dict["errorCode"] as? NSNumber)?.stringValue ?? "none"
            EngineLog.shared.write("profile updateAvatar fail code=\(code)")
            return .failure(dict["error"] as? String ?? "Cập nhật ảnh đại diện thất bại.")
        }
        if let userDict = dict["profile"] as? [String: Any],
           let parsed = Profile.parse(user: userDict, fallback: profile) {
            applyProfile(parsed)
        } else if let urlStr = dict["avatar"] as? String, !urlStr.isEmpty, let url = URL(string: urlStr), var current = profile {
            current.avatar = url
            applyProfile(current)
        }
        EngineLog.shared.write("profile updateAvatar ok")
        return .success
    }

    private func callProfile(_ method: String, timeout: Double, _ args: Any...) async -> [String: Any]? {
        guard let host,
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let script = "const p = window.__olazProfile; if (!p || !p.\(method)) return null; return await p.\(method)(...\(json));"
        let boxed = await raceTimeout(timeout) { JSBox(value: await host.evaluate(script)) }
        return boxed?.value as? [String: Any]
    }

    private static func jpegPixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return (0, 0)
        }
        return (w, h)
    }
}
