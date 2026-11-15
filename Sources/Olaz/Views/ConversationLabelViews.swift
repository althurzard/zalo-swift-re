import SwiftUI
import AppKit

// "Phân loại" (conversation labels): row indicator, context menu and the label manager (the list column filters by label).
// All data and writes go through the official label manager (see ZaloEngine+Conversations.swift).

/// Non-template colored dot usable as a menu item image.
enum LabelDot {
    static func image(hex: String, size: CGFloat = 11) -> NSImage {
        let color = NSColor(Color(hex: hex) ?? ZaloTheme.blue)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Menu item content: colored dot + name, with the unread chat count when there is one (the list's label filter).
struct LabelMenuTitle: View {
    let label: ConversationExtras.Label
    var unread = 0
    var body: some View {
        Label { Text(unread > 0 ? "\(label.name) (\(unread))" : label.name) } icon: { Image(nsImage: LabelDot.image(hex: label.colorHex)) }
    }
}

/// Small colored dot beside a conversation's name (its "Phân loại"); the name is the tooltip.
struct LabelTag: View {
    let label: ConversationExtras.Label
    var body: some View {
        Circle()
            .fill(label.color)
            .frame(width: 7, height: 7)
            .help(label.name)
            .accessibilityLabel("Phân loại \(label.name)")
    }
}

// MARK: - Row context menu

/// "Phân loại" submenu for a conversation row.
struct ConversationLabelMenu: View {
    @Environment(ZaloEngine.self) private var engine
    let conversationId: String
    @Binding var showLabelManager: Bool

    var body: some View {
        let extras = engine.conversationExtras
        if extras.loaded {
            Menu {
                Picker("Phân loại", selection: Binding(
                    get: { extras.labelByConversation[conversationId] },
                    set: { engine.setConversationLabel(conversationId, labelId: $0) })) {
                    Label("Không có phân loại", systemImage: "tag.slash").tag(String?.none)
                    ForEach(extras.labels) { label in
                        LabelMenuTitle(label: label).tag(Optional(label.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Quản lý thẻ phân loại…", systemImage: "slider.horizontal.3") { showLabelManager = true }
            } label: {
                Label("Phân loại", systemImage: "tag")
            }
        }
    }
}

// MARK: - Manager

/// "Quản lý thẻ phân loại": create, rename, recolor, reorder, delete — via the official label manager.
struct LabelManagerView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var pendingDelete: ConversationExtras.Label?
    @State private var error: String?
    @State private var baseSeq = 0

    enum EditTarget: Identifiable {
        case new, existing(ConversationExtras.Label)
        var id: String { switch self { case .new: "new"; case .existing(let l): l.id } }
    }

    private var extras: ConversationExtras { engine.conversationExtras }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quản lý thẻ phân loại").font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
                Text("\(extras.labels.count)/\(extras.limits.maxLabels)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Thêm phân loại", systemImage: "plus") { editing = .new }
                    .buttonStyle(.glassProminent)
                    .disabled(extras.labels.count >= extras.limits.maxLabels)
                Button("Xong") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.defaultAction)
            }
            .padding(16)

            if extras.labels.isEmpty {
                ContentUnavailableView("Chưa có phân loại", systemImage: "tag",
                                       description: Text("Tạo thẻ phân loại để ghi nhớ & nhận biết hội thoại dễ dàng hơn"))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(extras.labels) { label in
                        HStack(spacing: 10) {
                            Circle().fill(label.color).frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label.name).font(.system(size: 13.5, weight: .medium))
                                Text("\(label.convIds.count) hội thoại").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { editing = .existing(label) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Sửa phân loại")
                            Button { pendingDelete = label } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(.red).help("Xóa phân loại")
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { source, destination in
                        var ids = extras.labels.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        engine.reorderConversationLabels(ids)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .frame(width: 460, height: 440)
        .onAppear { baseSeq = extras.notice?.seq ?? 0 }
        // Deletes / reorders report here; create and rename report through their editor.
        .onChange(of: extras.notice?.seq) { _, _ in
            guard editing == nil, let notice = extras.notice, notice.seq > baseSeq else { return }
            baseSeq = notice.seq
            error = notice.ok ? nil : notice.text
        }
        .sheet(item: $editing) { target in
            LabelEditor(target: target)
        }
        .confirmationDialog("Xóa thẻ phân loại?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { label in
            Button("Xóa phân loại", role: .destructive) { engine.deleteConversationLabel(label.id) }
            Button("Không", role: .cancel) {}
        } message: { label in
            Text("Phân loại \"\(label.name)\" sẽ bị xóa khỏi mọi hội thoại.")
        }
    }
}

private struct LabelEditor: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let target: LabelManagerView.EditTarget
    @State private var name = ""
    @State private var colorHex = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var baseSeq = 0
    @FocusState private var focused: Bool

    private var extras: ConversationExtras { engine.conversationExtras }
    private var existing: ConversationExtras.Label? { if case .existing(let l) = target { l } else { nil } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Thêm mới thẻ phân loại" : "Sửa thẻ phân loại").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Tên thẻ phân loại").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Nhập tên thẻ phân loại", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .onChange(of: name) { _, value in
                        // UTF-16 units, like the official limit (an emoji counts 2).
                        if value.utf16.count > extras.limits.maxNameLength { name = value.limitedUTF16(extras.limits.maxNameLength) }
                        error = nil
                    }
                Text("\(name.utf16.count)/\(extras.limits.maxNameLength)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Màu").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(extras.limits.palette, id: \.self) { hex in
                        Button { colorHex = hex } label: {
                            Circle().fill(Color(hex: hex) ?? .gray).frame(width: 24, height: 24)
                                .overlay { if hex.caseInsensitiveCompare(colorHex) == .orderedSame { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Thêm" : "Lưu", action: submit)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty || submitting)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = existing?.name ?? ""
            colorHex = existing?.colorHex ?? extras.limits.palette.first ?? "#0068FF"
            baseSeq = extras.notice?.seq ?? 0
            focused = true
        }
        .onChange(of: extras.notice?.seq) { _, _ in
            guard submitting, let notice = extras.notice, notice.seq > baseSeq else { return }
            if notice.ok { dismiss() } else { error = notice.text; submitting = false }
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !submitting else { return }
        submitting = true
        baseSeq = extras.notice?.seq ?? 0
        // The field may still be over the limit if it was left while composing.
        let clamped = trimmed.prefixUTF16(extras.limits.maxNameLength)
        if let existing { engine.updateConversationLabel(existing.id, name: clamped, colorHex: colorHex) }
        else { engine.createConversationLabel(name: clamped, colorHex: colorHex) }
    }
}
