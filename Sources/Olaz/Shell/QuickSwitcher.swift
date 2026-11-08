import SwiftUI

/// ⌘K palette over the main window (shown while `ShellModel.showQuickSwitcher`): jump to a conversation, a contact or a
/// command. It only searches what the engine lists as visible, so hidden chats never appear.
struct QuickSwitcher: View {
    @Environment(ShellModel.self) private var shell

    var body: some View {
        if shell.showQuickSwitcher {
            QuickSwitcherPanel()
                .transition(.opacity)
        }
    }
}

// MARK: - Model

/// Commands offered below the search results.
private enum QuickCommand: CaseIterable {
    case inbox, unread, contacts, zcloud, settings, tour

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .unread: "bubble.left.and.text.bubble.right"
        case .contacts: "person.2"
        case .zcloud: "externaldrive"
        case .settings: "gearshape"
        case .tour: "questionmark.circle"
        }
    }

    var shortcut: String? {
        switch self {
        case .inbox: "⌥⌘1"
        case .unread: "⌥⌘3"
        case .contacts: "⌥⌘5"
        case .zcloud: "⌥⌘6"
        case .settings: "⌘,"
        case .tour: nil
        }
    }
}

private struct QuickRow: Identifiable {
    enum Leading {
        case avatar(URL?, name: String)
        case cloud
        case symbol(String)
    }

    enum Target {
        /// A conversation of the official list.
        case conversation(String)
        /// A friend or group that may have no conversation yet; the official chat box creates it.
        case contact(String)
        case command(QuickCommand)
    }

    let id: String
    let leading: Leading
    let title: String
    var subtitle: String?
    var unread = 0
    var shortcut: String?
    let target: Target
}

private struct QuickSection: Identifiable {
    let title: String
    let rows: [QuickRow]
    var id: String { title }
}

/// Folds names once: the palette re-runs its search on every keystroke over the whole conversation list.
@MainActor
private final class FoldCache {
    private var folded: [String: String] = [:]

    func fold(_ text: String) -> String {
        if let known = folded[text] { return known }
        let value = ZaloEngine.contactFold(text)
        folded[text] = value
        return value
    }
}

// MARK: - Panel

/// `serial` makes a repeated move to the same row still count as a change.
private struct ScrollRequest: Equatable {
    let id: String
    let serial: Int
}

private struct QuickSwitcherPanel: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var highlighted: String?
    /// Set by keyboard moves so only they scroll the list (a hover must not).
    @State private var scrollRequest: ScrollRequest?
    /// A pointer resting over the list fires a hover when the panel opens or the content scrolls under it; hovers are
    /// ignored briefly after either so the first row stays highlighted.
    @State private var ignoreHoverUntil = Date.now.addingTimeInterval(0.35)
    @State private var cache = FoldCache()
    @FocusState private var fieldFocused: Bool

    private let maxConversationHits = 8
    private let maxContactHits = 5

    var body: some View {
        let sections = sections()
        let rows = sections.flatMap(\.rows)
        let current = highlighted.flatMap { id in rows.first { $0.id == id } } ?? rows.first

        ZStack(alignment: .top) {
            // Light dim; a click outside closes (the field's own area is the panel, above this layer).
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                searchField(rows: rows, current: current)
                Divider()
                results(sections, current: current)
                footer
            }
            .frame(width: 560)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
            // Clicks on the panel's own padding must not fall through to the dim layer and close it.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {}
            .padding(.top, 84)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Đi tới")
        }
        .onExitCommand(perform: close)
        .onChange(of: query) { highlighted = nil }
        .task {
            // The overlay was just inserted: focus lands once its field is in the window.
            try? await Task.sleep(for: .milliseconds(60))
            fieldFocused = true
        }
    }

    // MARK: Pieces

    private func searchField(rows: [QuickRow], current: QuickRow?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Đi tới cuộc trò chuyện, người hoặc lệnh", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($fieldFocused)
                .onSubmit { if let current { perform(current) } }
                .onKeyPress(.downArrow) { move(1, in: rows, from: current); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: rows, from: current); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Xóa")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    @ViewBuilder
    private func results(_ sections: [QuickSection], current: QuickRow?) -> some View {
        if sections.isEmpty {
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.rows) { row in
                                QuickRowView(row: row, isHighlighted: row.id == current?.id) {
                                    perform(row)
                                } onHover: {
                                    if Date.now.timeIntervalSince(ignoreHoverUntil) >= 0 { highlighted = row.id }
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .onChange(of: scrollRequest) { _, request in
                    if let request { proxy.scrollTo(request.id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Chọn")
            hint("↩", "Mở")
            hint("esc", "Đóng")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }

    private var emptyMessage: String {
        if !engine.conversationActions.hiddenKnown { return "Đang đồng bộ hội thoại…" }
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Chưa có cuộc trò chuyện" : "Không có kết quả cho “\(text)”"
    }

    // MARK: Results

    private func sections() -> [QuickSection] {
        let needle = cache.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var sections: [QuickSection] = []

        let recent = engine.visibleConversations.sorted { ($0.preview?.date ?? .distantPast) > ($1.preview?.date ?? .distantPast) }
        let conversations = needle.isEmpty
            ? Array(recent.prefix(8))
            : Array(recent.filter { cache.fold(title(of: $0)).contains(needle) }.prefix(maxConversationHits))
        if !conversations.isEmpty {
            sections.append(QuickSection(title: needle.isEmpty ? "Gần đây" : "Cuộc trò chuyện", rows: conversations.map(row(for:))))
        }

        if !needle.isEmpty {
            let listed = Set(conversations.map(\.id))
            // People and groups from Danh bạ that the conversation hits do not already cover.
            let friends = engine.visibleFriends
                .filter { !listed.contains($0.id) && $0.sortKey.contains(needle) }
                .prefix(maxContactHits)
                .map { QuickRow(id: "p:\($0.id)", leading: .avatar($0.avatar, name: $0.name), title: $0.name,
                                subtitle: "Bạn bè", target: .contact($0.id)) }
            let groups = engine.visibleGroups
                .filter { !listed.contains($0.id) && $0.sortKey.contains(needle) }
                .prefix(maxContactHits)
                .map { QuickRow(id: "p:\($0.id)", leading: .avatar($0.avatar, name: $0.name), title: $0.name,
                                subtitle: $0.members > 0 ? "\($0.members) thành viên" : "Nhóm", target: .contact($0.id)) }
            let contacts = Array((friends + groups).prefix(maxContactHits))
            if !contacts.isEmpty { sections.append(QuickSection(title: "Danh bạ", rows: contacts)) }
        }

        let commands = QuickCommand.allCases.filter { needle.isEmpty || cache.fold(title(of: $0)).contains(needle) }
        if !commands.isEmpty {
            sections.append(QuickSection(title: "Lệnh", rows: commands.map { command in
                QuickRow(id: "k:\(command)", leading: .symbol(command.symbol), title: title(of: command),
                         shortcut: command.shortcut, target: .command(command))
            }))
        }
        return sections
    }

    private func title(of conversation: ZaloEngine.ConversationSummary) -> String {
        conversation.id == engine.selfConversationId ? "Cloud của tôi" : conversation.displayName
    }

    private func title(of command: QuickCommand) -> String {
        switch command {
        case .inbox: "Đi tới \(ConversationExtras.inboxTitle)"
        case .unread: "Đi tới \(ConversationTypeFilter.unread.title)"
        case .contacts: "Đi tới Danh bạ"
        case .zcloud: "Đi tới zCloud"
        case .settings: "Mở Cài đặt…"
        case .tour: "Hướng dẫn sử dụng \(AppBrand.name)"
        }
    }

    private func row(for conversation: ZaloEngine.ConversationSummary) -> QuickRow {
        let isSelf = conversation.id == engine.selfConversationId
        var subtitle: String?
        if let preview = conversation.preview, !preview.text.isEmpty {
            subtitle = (preview.fromMe ? "Bạn: " : "") + preview.text
        } else if conversation.isGroup, conversation.members > 0 {
            subtitle = "\(conversation.members) thành viên"
        }
        return QuickRow(id: "c:\(conversation.id)",
                        leading: isSelf ? .cloud : .avatar(conversation.avatar, name: conversation.displayName),
                        title: title(of: conversation), subtitle: subtitle, unread: conversation.unread,
                        target: .conversation(conversation.id))
    }

    // MARK: Actions

    private func move(_ step: Int, in rows: [QuickRow], from current: QuickRow?) {
        guard !rows.isEmpty else { return }
        let index = current.flatMap { current in rows.firstIndex { $0.id == current.id } } ?? 0
        let next = rows[min(max(index + step, 0), rows.count - 1)].id
        ignoreHoverUntil = Date.now.addingTimeInterval(0.4)
        highlighted = next
        scrollRequest = ScrollRequest(id: next, serial: (scrollRequest?.serial ?? 0) + 1)
    }

    private func close() {
        withAnimation(.snappy(duration: 0.18)) { shell.showQuickSwitcher = false }
    }

    private func perform(_ row: QuickRow) {
        close()
        switch row.target {
        case .conversation(let id):
            shell.open(conversation: id)
        case .contact(let id):
            // The shell consumes the request: back to the inbox list with the chat open.
            engine.openContactConversation(id)
        case .command(let command):
            switch command {
            case .inbox: shell.destination = .inbox
            case .unread: shell.destination = .unread
            case .contacts: shell.destination = .friends
            case .zcloud: shell.destination = .zcloud
            case .settings: openSettings()
            case .tour: shell.startTour()
            }
        }
    }
}

// MARK: - Row

private struct QuickRowView: View {
    let row: QuickRow
    let isHighlighted: Bool
    let action: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: 13.5, weight: row.unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.unread > 0 {
                    Text(row.unread > 99 ? "99+" : "\(row.unread)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.tint), in: Capsule())
                }
                if let shortcut = row.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHighlighted { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder private var leading: some View {
        switch row.leading {
        case .avatar(let url, let name):
            // Opaque base: the avatar's translucent initials fallback would vanish on the highlighted (tint) row.
            RemoteAvatar(url: url, name: name, size: 28)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        case .cloud:
            Image(systemName: "cloud.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.tint))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(isHighlighted ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
