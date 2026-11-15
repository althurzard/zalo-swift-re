import AppKit
import SwiftUI

/// Compact action bar rendered below a text message bubble when a bank account + bank name pair is detected.
struct BankTransferChipStrip: View {
    let matches: [BankTransferMatch]
    let mine: Bool
    @Binding var selectedMatch: BankTransferMatch?

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            ForEach(matches) { match in
                BankTransferChipRow(match: match) {
                    selectedMatch = match
                }
            }
        }
    }
}

private struct BankTransferChipRow: View {
    let match: BankTransferMatch
    let onOpenQR: () -> Void
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TintShapeStyle())
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(TintShapeStyle().opacity(0.14)))

            VStack(alignment: .leading, spacing: 1) {
                Text(match.bank.shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(match.accountNumber)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                copyAccountNumber()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.secondary))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Đã sao chép số tài khoản" : "Sao chép số tài khoản")
            .accessibilityLabel("Sao chép số tài khoản \(match.accountNumber)")

            Button(action: onOpenQR) {
                HStack(spacing: 4) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("Mã QR")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(TintShapeStyle()))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Hiển thị mã QR chuyển khoản VietQR")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 220, maxWidth: 280)
        .cardChrome(radius: 12)
        .onDisappear { resetTask?.cancel() }
    }

    private func copyAccountNumber() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(match.accountNumber, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// Popover showing the generated VietQR transfer code with optional amount and transfer memo inputs.
struct BankQRPopoverView: View {
    let match: BankTransferMatch

    @State private var amountText = ""
    @State private var memoText = ""
    @State private var copiedState: CopiedKind?
    @State private var resetTask: Task<Void, Never>?

    private enum CopiedKind {
        case account
        case image
    }

    private var parsedAmount: Int? {
        let digits = amountText.filter(\.isNumber)
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    private var payload: String? {
        VietQRPayloadBuilder.build(for: VietQRRequest(
            bankBIN: match.bank.bin,
            accountNumber: match.accountNumber,
            amount: parsedAmount,
            memo: memoText.isEmpty ? nil : memoText
        ))
    }

    private var qrImage: NSImage? {
        guard let payload else { return nil }
        return VietQRImageRenderer.render(payload: payload, pixelSize: 440)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.bank.shortName)
                        .font(.system(size: 15, weight: .bold))
                    Text("VietQR · NAPAS 247")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("BIN \(match.bank.bin)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }

            Group {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 216, height: 216)
                        .overlay {
                            Text("Không thể tạo mã QR")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Số tài khoản")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(match.accountNumber)
                        .font(.system(size: 14.5, weight: .semibold).monospacedDigit())
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    copyAccount()
                } label: {
                    Label(copiedState == .account ? "Đã chép" : "Chép STK", systemImage: copiedState == .account ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                TextField("Số tiền (VND, tùy chọn)", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5).monospacedDigit())
                TextField("Nội dung chuyển khoản (tối đa 25 ký tự)", text: $memoText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
            }

            Button {
                copyQRImage()
            } label: {
                Label(
                    copiedState == .image ? "Đã sao chép ảnh QR" : "Sao chép ảnh QR",
                    systemImage: copiedState == .image ? "checkmark.circle.fill" : "photo.on.rectangle"
                )
                .font(.system(size: 12.5, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(qrImage == nil)
        }
        .padding(16)
        .frame(width: 280)
        .onDisappear { resetTask?.cancel() }
    }

    private func copyAccount() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(match.accountNumber, forType: .string)
        showCopied(.account)
    }

    private func copyQRImage() {
        guard let qrImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([qrImage])
        showCopied(.image)
    }

    private func showCopied(_ kind: CopiedKind) {
        copiedState = kind
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedState = nil
        }
    }
}
