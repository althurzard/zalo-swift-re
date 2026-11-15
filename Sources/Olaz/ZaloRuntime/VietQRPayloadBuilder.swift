import AppKit
import CoreImage
import Foundation

/// Input parameters for generating an EMVCo / NAPAS 247 VietQR transfer payload.
struct VietQRRequest: Hashable, Sendable {
    let bankBIN: String
    let accountNumber: String
    var amount: Int?
    var memo: String?
}

/// Pure-Swift EMVCo Merchant Presented Mode QR payload builder for VietQR (NAPAS 247).
enum VietQRPayloadBuilder {
    private static let napasAID = "A000000727"
    private static let accountTransferService = "QRIBFTTA"
    private static let currencyVND = "704"
    private static let countryVN = "VN"
    private static let maxAmountVND = 999_999_999_999
    private static let maxMemoLength = 25

    /// Builds a VietQR TLV string ending with Tag `63` (CRC-16/CCITT-FALSE), or `nil` if inputs are invalid.
    static func build(for request: VietQRRequest) -> String? {
        let bin = request.bankBIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bin.count == 6, bin.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else {
            return nil
        }

        let cleanAccount = String(request.accountNumber.unicodeScalars.filter {
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
        })
        guard !cleanAccount.isEmpty, cleanAccount.count <= 19 else {
            return nil
        }

        let validAmount: Int? = if let amount = request.amount, amount > 0 {
            min(amount, maxAmountVND)
        } else {
            nil
        }

        let beneficiary = tlv("00", bin) + tlv("01", cleanAccount)
        let merchantAccountInfo = tlv("00", napasAID)
            + tlv("01", beneficiary)
            + tlv("02", accountTransferService)

        var payload = ""
        payload += tlv("00", "01")
        payload += tlv("01", validAmount != nil ? "12" : "11")
        payload += tlv("38", merchantAccountInfo)
        payload += tlv("53", currencyVND)
        if let validAmount {
            payload += tlv("54", String(validAmount))
        }
        payload += tlv("58", countryVN)

        if let rawMemo = request.memo {
            let cleanMemo = sanitizeMemo(rawMemo)
            if !cleanMemo.isEmpty {
                payload += tlv("62", tlv("08", cleanMemo))
            }
        }

        let bodyForCRC = payload + "6304"
        let crc = crc16CCITT(bodyForCRC)
        return bodyForCRC + String(format: "%04X", crc)
    }

    /// Strips Vietnamese diacritics and restricts `memo` to 25 printable ASCII characters per NAPAS 247.
    static func sanitizeMemo(_ raw: String) -> String {
        let replacedD = raw
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
        let folded = replacedD.folding(
            options: [.diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let ascii = String(folded.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E })
        let collapsed = ascii
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maxMemoLength))
    }

    /// Computes CRC-16/CCITT-FALSE (`poly = 0x1021`, `init = 0xFFFF`, `xorOut = 0x0000`).
    static func crc16CCITT(_ string: String) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in string.utf8 {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }

    private static func tlv(_ tag: String, _ value: String) -> String {
        let length = value.utf8.count
        return "\(tag)\(String(format: "%02d", length))\(value)"
    }
}

/// Renders crisp nearest-neighbor QR images from VietQR payloads using CoreImage.
enum VietQRImageRenderer {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func render(payload: String, pixelSize: Int = 440) -> NSImage? {
        guard !payload.isEmpty, pixelSize > 0 else { return nil }
        let key = "\(pixelSize)|\(payload)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage,
              let cgQR = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        let moduleCount = max(1, Int(outputImage.extent.width))
        let quietModules = 2
        let totalModules = moduleCount + quietModules * 2
        let scale = max(1, pixelSize / totalModules)
        let finalSide = totalModules * scale

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: finalSide,
            height: finalSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: finalSide, height: finalSide))
        ctx.interpolationQuality = .none
        let inset = quietModules * scale
        ctx.draw(
            cgQR,
            in: CGRect(x: inset, y: inset, width: moduleCount * scale, height: moduleCount * scale)
        )

        guard let finalCG = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: finalCG, size: NSSize(width: finalSide, height: finalSide))
        cache.setObject(image, forKey: key)
        return image
    }
}
