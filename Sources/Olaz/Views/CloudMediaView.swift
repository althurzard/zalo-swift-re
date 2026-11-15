import SwiftUI

/// Which cloud data a browse screen shows (official screens MEDIA / CONV→MEDIA / MY_CLOUD).
enum CloudScope: Hashable {
    /// "Tin nhắn media": everything except My Cloud.
    case all
    case conversation(id: String, name: String)
    /// "Cloud của tôi" documents.
    case myCloud(id: String)

    var conversationId: String? {
        switch self {
        case .all: nil
        case .conversation(let id, _): id
        case .myCloud(let id): id
        }
    }
}

enum CloudSort: String, CaseIterable, Identifiable {
    case newest, oldest, largest, smallest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Thời gian gửi (mới → cũ)"
        case .oldest: "Thời gian gửi (cũ → mới)"
        case .largest: "Dung lượng giảm dần"
        case .smallest: "Dung lượng tăng dần"
        }
    }
    var bySize: Bool { self == .largest || self == .smallest }
    var ascending: Bool { self == .oldest || self == .smallest }
}

/// Paged list state for one browse screen.
@MainActor @Observable
final class CloudListModel {
    let scope: CloudScope
    var kind: CloudItemKind?
    var sort: CloudSort = .newest
    private(set) var items: [CloudItem] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var didLoad = false
    var selection: Set<String> = []
    var isSelecting = false {
        didSet { if !isSelecting, pendingRefresh { pendingRefresh = false; Task { await refreshInPlace() } } }
    }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private weak var engine: ZaloEngine?

    init(scope: CloudScope) { self.scope = scope }

    func attach(_ engine: ZaloEngine) { self.engine = engine }

    func reload() async {
        guard let engine else { return }
        generation += 1
        let mine = generation
        isLoading = true
        error = nil
        let page = await engine.cloudList(conversationId: scope.conversationId, kind: kind, sortBySize: sort.bySize,
                                          ascending: sort.ascending, offset: 0)
        guard mine == generation else { return }
        items = page.items
        hasMore = page.hasMore
        error = page.error
        isLoading = false
        didLoad = true
        selection.formIntersection(Set(items.map(\.id)))
    }

    /// The server changed something: re-read what is already loaded without resetting paging or selection.
    /// Deferred while the user is selecting (a re-read would shuffle the items under their cursor).
    func refreshInPlace() async {
        guard didLoad, let engine else { await reload(); return }
        if isSelecting { pendingRefresh = true; return }
        generation += 1
        let mine = generation
        let wanted = max(items.count, 60)
        var fresh: [CloudItem] = []
        var more = false
        var failure: String?
        while fresh.count < wanted {
            let page = await engine.cloudList(conversationId: scope.conversationId, kind: kind, sortBySize: sort.bySize,
                                              ascending: sort.ascending, offset: fresh.count, limit: min(200, wanted - fresh.count))
            guard mine == generation else { return }
            if let message = page.error { failure = message; break }
            var seen = Set(fresh.map(\.id))
            fresh += page.items.filter { seen.insert($0.id).inserted }
            more = page.hasMore
            if page.items.isEmpty || !page.hasMore { break }
        }
        guard failure == nil else { return }       // keep what is on screen
        items = fresh
        hasMore = more
        selection.formIntersection(Set(items.map(\.id)))
    }

    func loadMoreIfNeeded(current: CloudItem) async {
        guard hasMore, !isLoading, let engine, items.suffix(12).contains(where: { $0.id == current.id }) else { return }
        generation += 1
        let mine = generation
        isLoading = true
        let page = await engine.cloudList(conversationId: scope.conversationId, kind: kind, sortBySize: sort.bySize,
                                          ascending: sort.ascending, offset: items.count)
        guard mine == generation else { return }
        var seen = Set(items.map(\.id))
        items += page.items.filter { seen.insert($0.id).inserted }
        hasMore = page.hasMore
        if let message = page.error { error = message }
        isLoading = false
    }

    func remove(_ keys: Set<String>) {
        items.removeAll { keys.contains($0.id) }
        selection.subtract(keys)
    }
}

struct CloudMediaView: View {
    @Environment(ZaloEngine.self) private var engine
    let scope: CloudScope
    @State private var model: CloudListModel
    @State private var asGrid = true
    @State private var preview: CloudItem?
    @State private var deleteTargets: [CloudItem] = []
    @State private var deleting = false
    @State private var notice: String?
    /// `engine.cloud.changed` bursts (an upload or a delete fires several) coalesce into one refresh at a time.
    @State private var refreshTask: Task<Void, Never>?
    @State private var changeGeneration = 0

    init(scope: CloudScope) {
        self.scope = scope
        _model = State(initialValue: CloudListModel(scope: scope))
    }

    private var title: String {
        switch scope {
        case .all: "Tin nhắn media"
        case .conversation(_, let name): name.isEmpty ? "Trò chuyện" : name
        case .myCloud: "Cloud của tôi"
        }
    }

    private var subtitle: String? {
        let plan = engine.cloud.plan
        switch scope {
        case .all:
            let bytes = model.kind.map { engine.cloud.media.bytes($0) } ?? engine.cloud.media.total
            return bytes > 0 ? CloudFormat.size(bytes) : nil
        case .myCloud:
            let bytes = model.kind.map { engine.cloud.myCloudTypes.bytes($0) } ?? engine.cloud.myCloudTypes.total
            return bytes > 0 ? CloudFormat.size(bytes) : plan.map { CloudFormat.size($0.myCloud) }
        case .conversation(let id, _):
            return engine.cloud.conversations.first { $0.id == id }.map { CloudFormat.size($0.total) }
        }
    }

    var body: some View {
        content
            .safeAreaBar(edge: .top) { kindFilter }
            .safeAreaInset(edge: .bottom) { selectionBar }
            .overlay(alignment: .bottom) { noticeView }
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar { toolbarItems }
            .task(id: "\(model.kind?.rawValue ?? "all")|\(model.sort.rawValue)") {
                model.attach(engine)
                await model.reload()
            }
            .onChange(of: engine.cloud.changed) { _, _ in scheduleRefresh() }
            .onDisappear { refreshTask?.cancel() }   // the task clears `refreshTask` itself; `.task(id:)` reloads on return
            .sheet(item: $preview) { item in CloudPreviewSheet(item: item) }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } }),
                                titleVisibility: .visible) {
                Button("Xoá dữ liệu", role: .destructive) { performDelete() }
                Button("Huỷ", role: .cancel) { deleteTargets = [] }
            } message: {
                Text("\(CloudFormat.size(deleteTargets.reduce(0) { $0 + $1.size })) dữ liệu sẽ được xoá và không thể khôi phục. Tin nhắn tương ứng cũng được xoá đồng bộ trên các thiết bị của bạn.")
            }
    }

    /// Debounced: refreshes 1 s after the last change, never two refreshes at once; a change during a refresh runs one more.
    private func scheduleRefresh() {
        changeGeneration += 1
        guard refreshTask == nil else { return }
        refreshTask = Task {
            var handled = -1
            while handled != changeGeneration, !Task.isCancelled {
                let target = changeGeneration
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                if target != changeGeneration { continue }   // still changing: wait for it to settle
                await model.refreshInPlace()
                handled = target
            }
            refreshTask = nil
        }
    }

    private var deleteTitle: String { deleteTargets.count == 1 ? "Xoá dữ liệu này?" : "Xoá \(deleteTargets.count) mục?" }

    // MARK: Toolbar & filter

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Kiểu xem", selection: $asGrid) {
                Label("Lưới", systemImage: "square.grid.2x2").tag(true)
                Label("Danh sách", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Kiểu xem")
            Menu {
                Picker("Sắp xếp", selection: $model.sort) {
                    ForEach(CloudSort.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("Sắp xếp", systemImage: "arrow.up.arrow.down")
            }
            .help("Sắp xếp")
        }
        ToolbarItem {
            Button(model.isSelecting ? "Xong" : "Chọn") {
                withAnimation(.snappy) { model.isSelecting.toggle(); if !model.isSelecting { model.selection = [] } }
            }
            .disabled(model.items.isEmpty)
        }
    }

    /// The official screens filter by media type (Tất cả / Ảnh / Video / File / Tin nhắn thoại).
    private var kindFilter: some View {
        Picker("Loại nội dung", selection: $model.kind) {
            Text("Tất cả").tag(CloudItemKind?.none)
            Text("Ảnh").tag(CloudItemKind?.some(.photo))
            Text("Video").tag(CloudItemKind?.some(.video))
            Text("File").tag(CloudItemKind?.some(.file))
            Text("Tin nhắn thoại").tag(CloudItemKind?.some(.voice))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !model.didLoad {
            ProgressView("Đang tải dữ liệu zCloud…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Không đọc được dữ liệu", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(error)
                } actions: {
                    Button("Thử lại") { Task { await model.reload() } }
                }
                .fillColumn()
            } else {
                ContentUnavailableView("Không có mục nào", systemImage: "tray",
                                       description: Text(model.kind == nil ? "Chưa có nội dung nào được lưu trong mục này." : "Không có \(model.kind?.title.lowercased() ?? "nội dung") nào."))
                    .fillColumn()
            }
        } else if asGrid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 12, alignment: .top)], spacing: 14) {
                    ForEach(model.items) { item in
                        // A real button: reachable with the keyboard (Space / Return open the preview) and by VoiceOver.
                        Button { tap(item) } label: {
                            CloudGridCell(item: item, selecting: model.isSelecting, selected: model.selection.contains(item.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.displayName), \(CloudFormat.size(item.size))")
                        .contextMenu { menu(item) }
                        .task { await model.loadMoreIfNeeded(current: item) }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                loadingFooter
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            List {
                ForEach(model.items) { item in
                    CloudListRow(item: item, selecting: model.isSelecting, selected: model.selection.contains(item.id))
                        .contentShape(Rectangle())
                        .onTapGesture { tap(item) }
                        .contextMenu { menu(item) }
                        .task { await model.loadMoreIfNeeded(current: item) }
                        .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
                }
                loadingFooter.listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private var loadingFooter: some View {
        if model.isLoading && model.didLoad {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    @ViewBuilder private func menu(_ item: CloudItem) -> some View {
        Button("Xem", systemImage: "eye") { preview = item }
        Button("Lưu về máy…", systemImage: "square.and.arrow.down") { save(item) }
        Divider()
        Button(model.selection.contains(item.id) ? "Bỏ chọn" : "Chọn", systemImage: "checkmark.circle") {
            model.isSelecting = true
            if !model.selection.insert(item.id).inserted { model.selection.remove(item.id) }
        }
        Divider()
        Button("Xoá dữ liệu…", systemImage: "trash", role: .destructive) { deleteTargets = [item] }
            .disabled(deleting)
    }

    private func tap(_ item: CloudItem) {
        if model.isSelecting {
            if !model.selection.insert(item.id).inserted { model.selection.remove(item.id) }
        } else {
            preview = item
        }
    }

    // MARK: Selection bar

    @ViewBuilder private var selectionBar: some View {
        if model.isSelecting {
            HStack(spacing: 12) {
                let chosen = model.items.filter { model.selection.contains($0.id) }
                Text(chosen.isEmpty ? "Chọn các mục để xoá" : "Đã chọn \(chosen.count) • \(CloudFormat.size(chosen.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Chọn tất cả") { model.selection = Set(model.items.map(\.id)) }.buttonStyle(.glass)
                Button("Xoá…", role: .destructive) { deleteTargets = chosen }
                    .buttonStyle(.glassProminent).tint(.red)
                    .disabled(chosen.isEmpty || deleting)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 20).padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var noticeView: some View {
        if let notice {
            Text(notice).font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation(.snappy) { if notice == text { notice = nil } }
        }
    }

    // MARK: Actions

    private func save(_ item: CloudItem) {
        show("Đang tải về…")
        Task {
            switch await engine.cloudFetch(item.id) {
            case .ready(let file):
                switch await CloudSaver.save(file, item: item) {
                case .saved: show("Đã lưu về máy.")
                case .cancelled: withAnimation(.snappy) { notice = nil }
                case .failed(let message): show(message)
                }
            case .expired: show("Nội dung đã hết hạn trên zCloud.")
            case .failed(let message): show(message)
            }
        }
    }

    /// Mirrors the official sequence: optimistic removal + clear selection, then the delete itself; only what
    /// the official client actually deleted stays removed.
    private func performDelete() {
        guard !deleting else { return }
        let targets = deleteTargets
        deleteTargets = []
        deleting = true
        let keys = Set(targets.map(\.id))
        model.remove(keys)
        if model.selection.isEmpty { model.isSelecting = false }
        Task {
            let result = await engine.cloudDelete(targets.map(\.id))
            deleting = false
            if result.failed.isEmpty && result.ok {
                show("Đã xoá dữ liệu")
            } else {
                let done = result.deleted.count
                show(done > 0 ? "Đã xoá \(done)/\(targets.count) mục. \(result.error ?? "Một số mục không xoá được.")"
                              : (result.error ?? "Xoá không thành công"))
                await model.reload()             // bring back what was not deleted
            }
        }
    }
}

// MARK: - Tiles & rows

/// Finder-style grid cell: square preview, then the name and "size • date" underneath.
private struct CloudGridCell: View {
    let item: CloudItem
    let selecting: Bool
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { CloudGridTile(item: item, selecting: selecting, selected: selected) }
            Text(item.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Text("\(CloudFormat.size(item.size)) • \(CloudFormat.date(item.date))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct CloudGridTile: View {
    let item: CloudItem
    let selecting: Bool
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch item.kind {
            case .photo, .video:
                CloudThumbnailView(item: item)
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(.white.opacity(0.92)).shadow(radius: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if item.duration > 0 { badge(CloudFormat.duration(item.duration)) }
                }
            case .voice:
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 30, weight: .semibold)).foregroundStyle(.tint)
                    Text(item.duration > 0 ? CloudFormat.duration(item.duration) : "Tin nhắn thoại").font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5))
            default:
                VStack(spacing: 6) {
                    Image(systemName: item.fileSymbol).font(.system(size: 34)).foregroundStyle(.tint)
                    if !item.ext.isEmpty {
                        Text(item.ext.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5))
            }
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                    .background(Circle().fill(.black.opacity(selected ? 0 : 0.25)))
                    .shadow(radius: 2)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.tint, lineWidth: selected ? 2.5 : 0))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(6)
    }
}

private struct CloudListRow: View {
    let item: CloudItem
    let selecting: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            thumb.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.conversationLabel).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
            Text(CloudFormat.size(item.size)).font(.system(size: 12.5, weight: .medium)).frame(width: 78, alignment: .trailing)
            Text(CloudFormat.date(item.date)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 82, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if (item.kind == .video || item.kind == .voice) && item.duration > 0 {
            return "\(item.kind.title) • \(CloudFormat.duration(item.duration))"
        }
        if item.kind == .file { return item.ext.isEmpty ? item.kind.title : item.ext.uppercased() }
        return item.kind.title
    }

    @ViewBuilder private var thumb: some View {
        switch item.kind {
        case .photo, .video: CloudThumbnailView(item: item, pixelSize: 140)
        case .voice: Image(systemName: "waveform").font(.system(size: 18, weight: .semibold)).foregroundStyle(.tint).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.5))
        default: Image(systemName: item.fileSymbol).font(.system(size: 20)).foregroundStyle(.tint).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.5))
        }
    }
}
