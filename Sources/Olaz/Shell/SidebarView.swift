import SwiftUI

/// Source list: mailboxes, storage and Danh bạ. Tahoe draws `.sidebar` lists as floating glass. The "Phân loại" labels
/// are not listed here: they filter "Tin nhắn" from the label button of the list column.
struct SidebarView: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    private var extras: ConversationExtras { engine.conversationExtras }

    /// "Cloud của tôi" is not a destination of its own: it is the inbox with the self conversation open, so that is what the
    /// sidebar highlights then (and the inbox row is not highlighted). A label filter keeps the inbox row highlighted.
    private var highlighted: SidebarDestination {
        if shell.destination == .myCloud { return .myCloud }
        if shell.destination == .inbox, let id = engine.selfConversationId, shell.selection == id { return .myCloud }
        return shell.destination.sidebarRow
    }

    private var isLabelFiltered: Bool {
        if case .label = shell.destination { true } else { false }
    }

    private var selection: Binding<SidebarDestination?> {
        Binding(get: { highlighted }, set: { if let new = $0 { select(new) } })
    }

    var body: some View {
        let counts = UnreadCounts(engine: engine)
        List(selection: selection) {
            mailboxes(counts)
            storage
            assistant
            contacts
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) { SidebarAccountFooter() }
        // Something else (a menu command) asked for the transient destination: resolve it the way a click does.
        .onChange(of: shell.destination) { _, destination in
            if destination == .myCloud { select(.myCloud) }
        }
    }

    // MARK: Sections

    @ViewBuilder private func mailboxes(_ counts: UnreadCounts) -> some View {
        Section {
            // The tour points at the first row: a popover on the section itself would repeat on every row.
            Label(ConversationExtras.inboxTitle, systemImage: "tray")
                // The row stays highlighted under a label filter, so clicking it changes no selection: clear the filter by
                // hand. Inert otherwise (`.subviews`), so it can never get in the way of the list's own row selection.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { clearLabelFilter() }, including: isLabelFiltered ? .all : .subviews)
                .badge(counts.inbox)
                .tag(SidebarDestination.inbox)
                .tourAnchor(.mailboxes)
            if extras.archivedEnabled {
                Label(ConversationTypeFilter.other.title, systemImage: "archivebox")
                    .badge(counts.other)
                    .tag(SidebarDestination.other)
            }
            Label(ConversationTypeFilter.unread.title, systemImage: "bubble.left.and.text.bubble.right")
                .tag(SidebarDestination.unread)
            Label("Người lạ", systemImage: "person.crop.circle.badge.questionmark")
                .badge(counts.strangers)
                .tag(SidebarDestination.strangers)
            if engine.conversationActions.hiddenEnabled {
                HStack {
                    Label("Trò chuyện ẩn", systemImage: "eye.slash")
                    Spacer(minLength: 4)
                    if shell.unlockedHiddenIds == nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Đang khoá")
                    }
                }
                .tag(SidebarDestination.hidden)
            }
        }
    }

    @ViewBuilder private var storage: some View {
        Section("Lưu trữ") {
            if engine.selfConversationId != nil {
                Label("Cloud của tôi", systemImage: "cloud").tag(SidebarDestination.myCloud)
            }
            Label("zCloud", systemImage: "externaldrive").tag(SidebarDestination.zcloud)
            if let plan = engine.cloud.plan, plan.quota > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Đã dùng \(CloudFormat.size(plan.usage + plan.family)) trên \(CloudFormat.size(plan.quota))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    CloudUsageBar(plan: plan, height: 4)
                }
                .padding(.top, 2)
                .selectionDisabled()
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "Trợ lý AI": opens the draft review window (a window of its own, not a list destination).
    @ViewBuilder private var assistant: some View {
        let desk = engine.assistant
        if desk.isListening || !desk.drafts.isEmpty {
            Section("Trợ lý AI") {
                Button { desk.reveal(draftId: nil) } label: {
                    Label("Duyệt nháp", systemImage: "text.bubble")
                }
                .buttonStyle(.plain)
                .badge(desk.pendingCount)
                .selectionDisabled()
            }
        }
    }

    @ViewBuilder private var contacts: some View {
        Section("Danh bạ") {
            Label("Bạn bè", systemImage: "person")
                .badge(engine.visibleFriends.count)
                .tag(SidebarDestination.friends)
            Label("Nhóm và cộng đồng", systemImage: "person.2")
                .tag(SidebarDestination.groups)
            Label("Lời mời kết bạn", systemImage: "person.badge.plus")
                .badge(engine.contacts.pendingRequestCount)
                .tag(SidebarDestination.requests)
        }
    }

    // MARK: Selection

    /// Back to the unfiltered inbox when a label filter is active (a click on the highlighted "Tin nhắn" row).
    private func clearLabelFilter() {
        guard case .label = shell.destination else { return }
        if !shell.search.isEmpty { shell.search = "" }
        shell.destination = .inbox
    }

    private func select(_ destination: SidebarDestination) {
        // Like Mail, picking a mailbox ends the search of the previous one.
        if !shell.search.isEmpty { shell.search = "" }
        switch destination {
        case .myCloud:
            guard let id = engine.selfConversationId else { return }
            shell.destination = .inbox
            shell.selection = id
        case .inbox:
            // Leaving "Cloud của tôi" for the inbox: close that chat so the highlight really moves.
            if highlighted == .myCloud { shell.selection = nil }
            shell.destination = .inbox
        default:
            shell.destination = destination
        }
    }
}
