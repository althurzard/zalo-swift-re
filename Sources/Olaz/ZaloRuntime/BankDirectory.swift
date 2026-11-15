import Foundation

/// A Vietnamese bank supported for NAPAS 247 / VietQR transfers.
struct BankEntry: Identifiable, Hashable, Codable, Sendable {
    let id: Int
    let shortName: String
    let bin: String
    let aliases: [String]
}

/// A bank account + bank keyword pair detected in a plain-text chat message.
struct BankTransferMatch: Identifiable, Hashable, Sendable {
    enum Confidence: Hashable, Sendable {
        case high
        case medium
    }

    let bank: BankEntry
    /// Digits-only account number (5...16 digits).
    let accountNumber: String
    let accountRange: Range<String.Index>
    let bankRange: Range<String.Index>
    let confidence: Confidence

    var id: String { "\(bank.bin):\(accountNumber)" }
}

/// Catalog of NAPAS member banks and context labels extracted from the official client's bank parser.
enum BankDirectory {
    enum ContextKind: Hashable, Sendable {
        case phone
        case identityCard
        case forbiddenNumber
        case paymentSupport
    }

    static let allBanks: [BankEntry] = [
        BankEntry(id: 6, shortName: "BIDV", bin: "970418", aliases: ["bidv", "dau tu phat trien", "dau tu va phat trien", "dt pt", "tmcp bidv"]),
        BankEntry(id: 7, shortName: "VietinBank", bin: "970415", aliases: ["ngan hang cong thuong", "ngan hang tmcp cong thuong", "nh cong thuong", "nh tmcp cong thuong", "tmcp cong thuong", "viet tin bank", "vietin bank", "vietinbank", "viettibank", "viettin bank", "viettinbank", "vtinbank"]),
        BankEntry(id: 8, shortName: "Vietcombank", bin: "970436", aliases: ["ngan hang ngoai thuong", "ngan hang thuong mai co phan ngoai thuong", "ngan hang tmcp ngoai thuong", "nh ngoai thuong", "nh thuong mai co phan ngoai thuong", "nh tmcp ngoai thuong", "thuong mai co phan ngoai thuong", "tmcp ngoai thuong", "vcb", "vcbbank", "viet com bank", "viet combank", "vietcom", "vietcom bank", "vietcombanh", "vietcombank"]),
        BankEntry(id: 9, shortName: "VPBank", bin: "970432", aliases: ["viet nam thinh vuong", "vn thinh vuong", "vp", "vp bank", "vpbank"]),
        BankEntry(id: 10, shortName: "MBBank", bin: "970422", aliases: ["mb", "mb bank", "mb quan doi", "mbank", "mbb", "mbbank", "ngan hang mb", "ngan hang quan doi", "ngan hang tmcp mb", "ngan hang tmcp quan doi", "nh mb", "nh quan doi", "nh tmcp mb", "nh tmcp quan doi", "nhmb", "quan doi mb", "tmcp mb", "tmcp quan doi"]),
        BankEntry(id: 11, shortName: "Techcombank", bin: "970407", aliases: ["ngan hang ky thuong", "ngan hang tmcp ky thuong", "nh ky thuong", "nh tmcp ky thuong", "tcb", "teachcombank", "teccokbank", "teccomebank", "tech", "techcom", "techcom bank", "techcombank", "techcomebank", "techconbank", "techombank", "teck", "teck combank", "teckcombank", "teckconbank", "tecombank", "tetcombank", "tmcp ky thuong"]),
        BankEntry(id: 12, shortName: "Agribank", bin: "970405", aliases: ["agibank", "agiribank", "agri bank", "agriabank", "agribak", "agribank", "ariabank", "aribank", "arigbank", "gribank", "hanggribank", "ngan hang nong nghiep", "nn pt", "nn pt nong thon", "nnptnt", "nong nghiep nong thon", "nong nghiep phat trien", "nong nghiep phat trien nong thon", "nong nghiep va phat trien"]),
        BankEntry(id: 13, shortName: "ACB", bin: "970416", aliases: ["abc bank", "acb", "acp", "ngan hang a chau", "ngan hang tmcp a chau", "nh a chau", "nh tmcp a chau", "thuong mai a chau", "tmcp a chau"]),
        BankEntry(id: 14, shortName: "HDBank", bin: "970437", aliases: ["hd bank", "hdbank", "ngan hang hd"]),
        BankEntry(id: 15, shortName: "SHB", bin: "970443", aliases: ["sai gon ha noi", "shb", "shbvn"]),
        BankEntry(id: 16, shortName: "Sacombank", bin: "970403", aliases: ["saccombank", "sacom", "sacom bank", "sacombank", "sacomdank", "sai gon thuong tin", "samcombank", "saocombank"]),
        BankEntry(id: 17, shortName: "VIB", bin: "970441", aliases: ["ngan hang quoc te", "ngan hang tmcp quoc te", "nh tmcp quoc te", "vib"]),
        BankEntry(id: 18, shortName: "MSB", bin: "970426", aliases: ["maritime", "msb", "ngan hang hang hai", "ngan hang tmcp hang hai", "nh hang hai", "nh tmcp hang hai", "tmcp hang hai"]),
        BankEntry(id: 19, shortName: "SCB", bin: "970429", aliases: ["scb", "tmcp sai gon"]),
        BankEntry(id: 20, shortName: "SeABank", bin: "970440", aliases: ["ngan hang dong nam a", "seabank", "tmcp dong nam a"]),
        BankEntry(id: 21, shortName: "OCB", bin: "970448", aliases: ["ngan hang phuong dong", "ocb", "ocb bank"]),
        BankEntry(id: 22, shortName: "Eximbank", bin: "970431", aliases: ["eximbank", "ngan hang xuat nhap khau"]),
        BankEntry(id: 23, shortName: "LienVietPostBank", bin: "970449", aliases: ["buu dien lien viet", "lien viet post bank", "lienviet", "lienvietpostbank", "lpb", "lpbank", "lvpb", "vietpostbank"]),
        BankEntry(id: 24, shortName: "TPBank", bin: "970423", aliases: ["ngan hang tien phong", "ngan hang tmcp tien phong", "nh tien phong", "nh tmcp tien phong", "nhtmcp tien phong", "tien phong bank", "tienphong bank", "tmcp tien phong", "tp bank", "tpbank"]),
        BankEntry(id: 25, shortName: "PVcomBank", bin: "970412", aliases: ["dai chung viet nam", "pv com bank", "pvcom bank", "pvcombank", "tmcp dai chung"]),
        BankEntry(id: 26, shortName: "Woori", bin: "970457", aliases: ["mtv woori", "woori"]),
        BankEntry(id: 27, shortName: "BacABank", bin: "970409", aliases: ["bac a bank", "baca bank", "ngan hang bac a", "ngan hang tmcp bac a", "nh bac a", "nh tmcp bac a", "tmcp bac a"]),
        BankEntry(id: 28, shortName: "HSBC", bin: "458761", aliases: ["hsbc", "mtv hsbc"]),
        BankEntry(id: 29, shortName: "ABBANK", bin: "970425", aliases: ["ab bank", "abbank", "an binh bank", "ngan hang an binh", "ngan hang tmcp an binh", "nh an binh", "nh tmcp an binh"]),
        BankEntry(id: 30, shortName: "VietABank", bin: "970427", aliases: ["ngan hang tmcp viet a", "ngan hang viet a", "nh tmcp viet a", "nh viet a", "tmcp viet a", "viet a bank", "vieta bank", "vietabank"]),
        BankEntry(id: 31, shortName: "DongABank", bin: "970406", aliases: ["dong a bank", "donga bank", "dongabank", "ngan hang dong a", "ngan hang tmcp dong a", "nh dong a", "nh tmcp dong a"]),
        BankEntry(id: 32, shortName: "UnitedOverseas", bin: "970458", aliases: ["mtv uob", "united oversea", "united overseas", "unitedoversea", "unitedoverseas", "uob", "uobbank"]),
        BankEntry(id: 33, shortName: "VietBank", bin: "970433", aliases: ["viet bank", "viet nam thuong tin", "vietbank"]),
        BankEntry(id: 34, shortName: "NamABank", bin: "970428", aliases: ["nam a bank", "namabank", "ngan hang nam a", "ngan hang tmcp nam a", "nh nam a", "nh tmcp nam a", "tmcp nam a"]),
        BankEntry(id: 35, shortName: "NCB", bin: "970419", aliases: ["ncb", "ncb bank", "ngan hang quoc dan", "ngan hang tmcp quoc dan", "nh quoc dan", "nh tmcp quoc dan", "tmcp quoc dan"]),
        BankEntry(id: 36, shortName: "MBV", bin: "970414", aliases: ["mbv", "modern bank", "modern bank vietnam", "mtv dai duong", "ngan hang viet nam hien dai", "ngan hang vietnam hien dai", "ngan hang vn hien dai"]),
        BankEntry(id: 37, shortName: "CIMB", bin: "422589", aliases: ["cimb", "mtv cimb"]),
        BankEntry(id: 38, shortName: "BVBank", bin: "970454", aliases: ["ban viet bank", "banviet bank", "banvietbank", "bvbank", "ngan hang ban viet", "ngan hang tmcp ban viet", "nh ban viet", "nh tmcp ban viet", "tmcp ban viet", "viet capital bank", "vietcapital bank"]),
        BankEntry(id: 39, shortName: "KienLongBank", bin: "970452", aliases: ["kien long", "kien long bank", "kienlongbank"]),
        BankEntry(id: 40, shortName: "BaoVietBank", bin: "970438", aliases: ["bao viet bank", "baoviet bank", "ngan hang bao viet", "ngan hang tmcp bao viet", "nh bao viet", "nh tmcp bao viet", "tmcp bao viet"]),
        BankEntry(id: 41, shortName: "SaigonBank", bin: "970400", aliases: ["sai gon bank", "sai gon cong thuong", "saigon bank", "saigonbank"]),
        BankEntry(id: 42, shortName: "COOPBANK", bin: "970446", aliases: ["co-opbank", "coop bank", "coopbank", "hop tac xa viet nam"]),
        BankEntry(id: 43, shortName: "GPBank", bin: "970408", aliases: ["dau khi toan cau", "gp bank", "gpbank"]),
        BankEntry(id: 44, shortName: "VRB", bin: "970421", aliases: ["lien doanh viet nga", "vrb"]),
        BankEntry(id: 45, shortName: "PGBank", bin: "970430", aliases: ["ngan hang thinh vuong phat trien", "ngan hang thinh vuong va phat trien", "nh thinh vuong phat trien", "nh thinh vuong va phat trien", "nhtmcp thinh vuong phat trien", "nhtmcp thinh vuong va phat trien", "pg bank", "pgbank", "tmcp thinh vuong phat trien", "tmcp thinh vuong va phat trien", "xang dau petrolimex"]),
        BankEntry(id: 46, shortName: "HongLeong", bin: "970442", aliases: ["hlbvn", "hong leong bank", "mtv hong leong"]),
        BankEntry(id: 47, shortName: "ShinhanBank", bin: "970424", aliases: ["mtv shinhan", "shin han", "shin han bank", "shinhan", "shinhan bank", "shinhanbank"]),
        BankEntry(id: 48, shortName: "CAKE", bin: "546034", aliases: ["cake by vpbank", "cake vpbank", "ngan hang cake", "ngan hang so cake", "vpbank cake"]),
        BankEntry(id: 49, shortName: "Ubank", bin: "546035", aliases: ["ngan hang so ubank", "ngan hang ubank", "u bank", "ubank", "ubank by vpbank", "ubank vpbank", "vpbank ubank"]),
        BankEntry(id: 50, shortName: "VCBNeo", bin: "970444", aliases: ["ngan hang ngoai thuong cong nghe so", "vcb neo", "vcbneo"]),
        BankEntry(id: 51, shortName: "DBSBank", bin: "796500", aliases: ["dbs", "dbsbank"]),
        BankEntry(id: 52, shortName: "IBK HCM", bin: "970456", aliases: ["cong nghiep han quoc hcm", "cong nghiep han quoc ho chi minh", "cong nghiep hq hcm", "cong nghiep hq ho chi minh", "ibk hcm", "ibk ho chi minh"]),
        BankEntry(id: 53, shortName: "IBK HN", bin: "970455", aliases: ["cong nghiep han quoc", "cong nghiep han quoc ha noi", "cong nghiep han quoc hn", "cong nghiep hq", "cong nghiep hq ha noi", "cong nghiep hq hn", "ibk", "ibk ha noi", "ibk hn"]),
        BankEntry(id: 54, shortName: "IndovinaBank", bin: "970434", aliases: ["indovinabank"]),
        BankEntry(id: 55, shortName: "KBank", bin: "668888", aliases: ["k bank", "ka si korn", "kasi korn", "kasikorn", "kbank"]),
        BankEntry(id: 56, shortName: "KookminHCM", bin: "970463", aliases: ["kook min hcm", "kook min ho chi minh", "kookmin bank hcm", "kookmin bank ho chi minh", "kookmin hcm", "kookmin ho chi minh", "kookminbank hcm", "kookminhcm", "koomin hcm", "koomin ho chi minh", "koominhcm"]),
        BankEntry(id: 57, shortName: "KookminHN", bin: "970462", aliases: ["kook min", "kook min ha noi", "kook min hn", "kookmin", "kookmin bank ha noi", "kookmin bank hn", "kookmin ha noi", "kookmin hn", "kookminbank", "kookminbank hn", "kookminhn", "koomin ha noi", "koomin hn", "koominhn"]),
        BankEntry(id: 58, shortName: "Nonghyup", bin: "801011", aliases: ["nonghyup"]),
        BankEntry(id: 59, shortName: "PublicBank", bin: "970439", aliases: ["ngan hang public", "public bank", "publicbank"]),
        BankEntry(id: 60, shortName: "StandardChartered", bin: "970410", aliases: ["standard chartered", "standardchartered"]),
        BankEntry(id: 61, shortName: "TNEX", bin: "963326", aliases: ["tnex", "tnexbank"]),
        BankEntry(id: 62, shortName: "Timo", bin: "963388", aliases: ["timo"]),
    ]

    static let phoneContextPhrases: [String] = [
        "call", "contact", "goi", "goi dien", "goi lai", "goi t", "goi toi", "goi vao",
        "hotline", "l h", "lh", "lh so", "lien he", "lien he so", "lien lac", "lien lac qua",
        "lien lac so", "momo", "phone", "sdt", "so dien thoai", "so dt", "so zalo",
        "tong dai", "vi momo", "viettel money", "viettel pay", "viettelpay", "vimomo",
        "vtmoney", "vtmony", "vtpay", "zalo", "zalo pay", "zalopay", "zlp", "zlpay",
    ]

    static let identityCardPhrases: [String] = [
        "can cuoc cd", "cc", "cc cong dan", "cccd", "chung minh nd", "chung minh nhan dan",
        "chung minh thu", "chung minh thu nhan dan", "cm nd", "cm nhan dan", "cmnd", "cmt",
        "so can cuoc", "so cc", "so chung minh", "so chung minh thu", "so cm", "so cmnd",
        "so cmt", "so the cc", "so the cccd",
    ]

    static let forbiddenNumberPhrases: [String] = [
        "atm", "d c", "dc", "dia chi", "hieu luc", "id", "imei", "len den", "ma don hang",
        "ma nganh", "ma so", "ma so thue", "ma xac minh", "ma xac nhan", "ma xac thuc",
        "ngay gd", "ngay giao dich", "otp", "sdt banking", "sdt momo", "so hieu", "so id",
        "so the", "stk momo", "stk zalopay", "thoi gian", "toa", "toa nha", "verification code",
    ]

    static let paymentSupportPhrases: [String] = [
        "bank", "banking", "chuyen khoan", "chuyen tien", "gui tien", "ngan hang",
        "ngan hang thuong mai co phan", "ngan hang tmcp", "nh", "nh thuong mai co phan",
        "nh tmcp", "nhan tien", "nhtmcp", "so tai khoan", "so tk", "stk", "tai khoan",
        "thanh toan", "thong tin chuyen khoan", "tk", "tra tien",
    ]

    private static let byBIN: [String: BankEntry] = Dictionary(
        uniqueKeysWithValues: allBanks.map { ($0.bin, $0) }
    )

    static func bank(forBIN bin: String) -> BankEntry? {
        byBIN[bin]
    }
}
