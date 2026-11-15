import AppKit
import SwiftUI
import Testing
@testable import Olaz

@Suite struct BankQRTests {
    @Test func detectsPhoneShapedAccountWithBankName() throws {
        let text = "0886123456 ocb"
        let matches = BankEntityDetector.detect(in: text)
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        #expect(match.bank.shortName == "OCB")
        #expect(match.bank.bin == "970448")
        #expect(match.accountNumber == "0886123456")
        #expect(String(text[match.accountRange]) == "0886123456")
        #expect(String(text[match.bankRange]) == "ocb")
    }

    @Test func detectsReversedVietnameseAndSpacedFormats() throws {
        let m1 = try #require(BankEntityDetector.detect(in: "ocb 0886123456").first)
        #expect(m1.bank.bin == "970448")
        #expect(m1.accountNumber == "0886123456")

        let spaced = "Ngân hàng Phương Đông: 0886 123 456"
        let m2 = try #require(BankEntityDetector.detect(in: spaced).first)
        #expect(m2.bank.shortName == "OCB")
        #expect(m2.accountNumber == "0886123456")
        #expect(String(spaced[m2.accountRange]) == "0886 123 456")

        let m3 = try #require(BankEntityDetector.detect(in: "stk 19035123456789 tcb").first)
        #expect(m3.bank.shortName == "Techcombank")
        #expect(m3.bank.bin == "970407")
        #expect(m3.accountNumber == "19035123456789")
        #expect(m3.confidence == .high)
    }

    @Test func detectsMultipleBanksAcrossLines() {
        let text = "0886123456 ocb\n19035123456789 vcb"
        let matches = BankEntityDetector.detect(in: text)
        #expect(matches.count == 2)
        #expect(matches.map(\.bank.shortName) == ["OCB", "Vietcombank"])
        #expect(matches.map(\.accountNumber) == ["0886123456", "19035123456789"])
    }

    @Test func rejectsPhoneContextMoneyIdentityAndURLs() {
        let negatives = [
            "sdt 0886123456 ocb",
            "zalo 0886123456 ocb",
            "gọi 0912345678 trước khi ck mb",
            "chuyển 500.000 vnd qua ocb",
            "số tiền 1000000 đồng vcb",
            "cccd 079099001234 acb",
            "https://ocb.com.vn/12345678",
            "1234 ocb",
            "12345678901234567 ocb",
            "12-3456 ocb",
        ]
        for text in negatives {
            #expect(BankEntityDetector.detect(in: text).isEmpty, "Unexpected match for: \(text)")
        }
    }

    @Test func buildsStaticVietQRWithValidCRC16() throws {
        #expect(VietQRPayloadBuilder.crc16CCITT("123456789") == 0x29B1)

        let payload = try #require(VietQRPayloadBuilder.build(for: VietQRRequest(
            bankBIN: "970448",
            accountNumber: "0886123456"
        )))
        #expect(payload.hasPrefix("000201010211"))
        #expect(payload.contains("0010A000000727"))
        #expect(payload.contains("0006970448"))
        #expect(payload.contains("01100886123456"))
        #expect(payload.contains("0208QRIBFTTA"))
        #expect(payload.contains("53037045802VN"))

        let prefixWithoutCRC = String(payload.dropLast(4))
        #expect(prefixWithoutCRC.hasSuffix("6304"))
        let expectedCRC = String(format: "%04X", VietQRPayloadBuilder.crc16CCITT(prefixWithoutCRC))
        #expect(payload.hasSuffix(expectedCRC))
    }

    @Test func buildsDynamicVietQRWithAmountAndSanitizedMemo() throws {
        let payload = try #require(VietQRPayloadBuilder.build(for: VietQRRequest(
            bankBIN: "970448",
            accountNumber: "0886123456",
            amount: 50_000,
            memo: "Chuyển tiền ăn trưa hôm nay nhé"
        )))
        #expect(payload.hasPrefix("000201010212"))
        #expect(payload.contains("540550000"))
        #expect(payload.contains("62290825Chuyen tien an trua hom n"))

        let prefixWithoutCRC = String(payload.dropLast(4))
        let expectedCRC = String(format: "%04X", VietQRPayloadBuilder.crc16CCITT(prefixWithoutCRC))
        #expect(payload.hasSuffix(expectedCRC))
    }

    @Test func rejectsInvalidVietQRInputs() {
        #expect(VietQRPayloadBuilder.build(for: VietQRRequest(bankBIN: "9704", accountNumber: "0886123456")) == nil)
        #expect(VietQRPayloadBuilder.build(for: VietQRRequest(bankBIN: "ABCDEF", accountNumber: "0886123456")) == nil)
        #expect(VietQRPayloadBuilder.build(for: VietQRRequest(bankBIN: "970448", accountNumber: "")) == nil)
        #expect(VietQRPayloadBuilder.build(for: VietQRRequest(bankBIN: "970448", accountNumber: String(repeating: "1", count: 20))) == nil)
    }

    @Test func rendersCrispQRImage() throws {
        let payload = try #require(VietQRPayloadBuilder.build(for: VietQRRequest(
            bankBIN: "970448",
            accountNumber: "0886123456"
        )))
        let image = try #require(VietQRImageRenderer.render(payload: payload, pixelSize: 440))
        #expect(image.size.width > 0)
        #expect(image.size.height == image.size.width)
    }

    @Test func chatFormatHighlightsBankWithoutClobberingMentionsOrURLs() throws {
        let text = "@Lan xem https://example.com ck 0886123456 ocb"
        let mentions = [Mention(uid: "u123", pos: 0, len: 4)]
        let matches = BankEntityDetector.detect(in: text)
        #expect(matches.count == 1)

        let formatted = ChatFormat.formattedText(
            text,
            mentions: mentions,
            bankMatches: matches,
            mine: false,
            myId: "me"
        )
        let links = formatted.runs.compactMap { run -> String? in
            guard let link = run.link else { return nil }
            let slice = String(formatted[run.range].characters)
            return "\(slice)->\(link.absoluteString)"
        }
        #expect(links.contains("@Lan->zalomention:u123"))
        #expect(links.contains("https://example.com->https://example.com"))
        #expect(links.contains("0886123456->olazbank:0"))
        #expect(links.contains("ocb->olazbank:0"))
    }
}
