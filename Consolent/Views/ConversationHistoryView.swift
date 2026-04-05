import SwiftUI

/// 대화 히스토리 조회 윈도우.
/// 좌측: 대화 목록 (chat_key별), 우측: 필터 + 메시지 요약 목록 (클릭 시 펼침).
struct ConversationHistoryView: View {

    @State private var conversations: [(chatKey: String, messageCount: Int, lastActivity: Date)] = []
    @State private var selectedChatKey: String? = nil
    @State private var messages: [ConversationStore.Message] = []
    @State private var expandedMessageIds: Set<Int64> = []
    @State private var dbInfo: (conversations: Int, messages: Int, sizeBytes: Int64) = (0, 0, 0)

    // 필터 상태
    @State private var searchText: String = ""
    @State private var filterSource: String = ""       // "", "api", "mcp", "messenger"
    @State private var filterRole: String = ""          // "", "user", "assistant"
    @State private var filterDateFrom: Date? = nil
    @State private var filterDateTo: Date? = nil
    @State private var showDateFilter = false
    private let store = ConversationStore.shared
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || !filterSource.isEmpty || !filterRole.isEmpty ||
        filterDateFrom != nil || filterDateTo != nil
    }

    var body: some View {
        HSplitView {
            conversationList
                .frame(minWidth: 220, maxWidth: 300)

            messageDetail
                .frame(minWidth: 450)
        }
        .frame(minWidth: 750, minHeight: 500)
        .onAppear {
            loadConversations()
        }
    }

    // MARK: - 대화 목록

    private var conversationList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("대화 목록")
                    .font(.headline)
                Spacer()
                Text("\(conversations.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if conversations.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("저장된 대화가 없습니다")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(selection: $selectedChatKey) {
                    ForEach(conversations, id: \.chatKey) { conv in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(for: conv.chatKey))
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)

                            HStack {
                                Text("\(conv.messageCount)개 메시지")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(dateFormatter.string(from: conv.lastActivity))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(conv.chatKey)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedChatKey) { _, _ in
                    expandedMessageIds = []
                    performSearch()
                }
            }

            Divider()

            VStack(spacing: 4) {
                HStack {
                    Text("DB: \(formatSize(dbInfo.sizeBytes))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("(\(dbInfo.messages)건)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                HStack {
                    Button {
                        loadConversations()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("새로고침")

                    Spacer()

                    if selectedChatKey != nil {
                        Button(role: .destructive) {
                            if let key = selectedChatKey {
                                store.clearHistory(chatKey: key)
                                selectedChatKey = nil
                                messages = []
                                loadConversations()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("선택된 대화 삭제")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 메시지 상세

    private var messageDetail: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                if let chatKey = selectedChatKey {
                    Text(displayName(for: chatKey))
                        .font(.headline)
                } else {
                    Text(hasActiveFilters ? "검색 결과" : "전체")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !messages.isEmpty {
                    Text("\(messages.count)개 메시지")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 검색 + 필터 바
            filterBar

            Divider()

            // 메시지 목록
            if messages.isEmpty && !hasActiveFilters && selectedChatKey == nil {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.bubble")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("대화를 선택하거나 검색/필터를 사용하세요")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if messages.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("검색 결과 없음")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages, id: \.id) { message in
                            messageRow(message, showChatKey: selectedChatKey == nil)
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 필터 바

    private var filterBar: some View {
        VStack(spacing: 6) {
            // 1행: 키워드 검색
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(selectedChatKey != nil ? "선택된 대화에서 검색" : "전체 대화에서 검색",
                          text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                    .onChange(of: searchText) { _, _ in performSearch() }
                if hasActiveFilters {
                    Button {
                        clearAllFilters()
                    } label: {
                        Text("초기화")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 2행: 필터 칩
            HStack(spacing: 6) {
                // 소스 필터
                Picker("", selection: $filterSource) {
                    Text("전체 소스").tag("")
                    Text("API").tag("api")
                    Text("MCP").tag("mcp")
                    Text("Messenger").tag("messenger")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 120)
                .controlSize(.small)
                .onChange(of: filterSource) { _, _ in performSearch() }

                // Role 필터
                Picker("", selection: $filterRole) {
                    Text("전체 역할").tag("")
                    Text("사용자").tag("user")
                    Text("어시스턴트").tag("assistant")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 110)
                .controlSize(.small)
                .onChange(of: filterRole) { _, _ in performSearch() }

                // 기간 필터 토글
                Button {
                    withAnimation { showDateFilter.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "calendar")
                        if filterDateFrom != nil || filterDateTo != nil {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(showDateFilter ? .accentColor : .secondary)

                Spacer()
            }

            // 3행: 기간 선택 (접기/펼치기)
            if showDateFilter {
                HStack(spacing: 8) {
                    DatePicker("시작",
                               selection: Binding(
                                   get: { filterDateFrom ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())! },
                                   set: { filterDateFrom = $0; performSearch() }
                               ),
                               displayedComponents: [.date])
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 120)

                    Text("~")
                        .foregroundColor(.secondary)

                    DatePicker("종료",
                               selection: Binding(
                                   get: { filterDateTo ?? Date() },
                                   set: { filterDateTo = $0; performSearch() }
                               ),
                               displayedComponents: [.date])
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 120)

                    if filterDateFrom != nil || filterDateTo != nil {
                        Button {
                            filterDateFrom = nil
                            filterDateTo = nil
                            performSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 메시지 행

    private func messageRow(_ message: ConversationStore.Message, showChatKey: Bool = false) -> some View {
        let isExpanded = expandedMessageIds.contains(message.id)
        let msgId = message.id

        return VStack(alignment: .leading, spacing: 0) {
            // 헤더 + 1줄 미리보기 (더블 클릭으로 펼침/접기)
            HStack(spacing: 8) {
                Image(systemName: roleIcon(message.role))
                    .font(.caption)
                    .foregroundColor(roleColor(message.role))
                    .frame(width: 20)

                Text(roleLabel(message.role))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(roleColor(message.role))

                if let source = extractSource(from: message.metadata) {
                    tagView(source, color: .secondary)
                }

                if showChatKey {
                    tagView(displayName(for: message.chatKey), color: .blue)
                }

                if !isExpanded {
                    Text(message.content)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                Text(dateFormatter.string(from: message.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedMessageIds.remove(msgId)
                    } else {
                        expandedMessageIds.insert(msgId)
                    }
                }
            }

            // 펼쳐진 내용 (텍스트 선택 가능)
            if isExpanded {
                Text(message.content)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.05) : Color.clear)
    }

    private func tagView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    // MARK: - 검색/필터 실행

    private func performSearch() {
        expandedMessageIds = []

        // 필터가 하나라도 있으면 필터 검색
        if hasActiveFilters {
            // dateTo에 하루의 끝 시간 추가 (해당 날짜 전체 포함)
            var adjustedDateTo = filterDateTo
            if let dt = filterDateTo {
                adjustedDateTo = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: dt)
            }

            messages = store.searchWithFilter(
                chatKey: selectedChatKey,
                keyword: searchText.isEmpty ? nil : searchText,
                source: filterSource.isEmpty ? nil : filterSource,
                role: filterRole.isEmpty ? nil : filterRole,
                dateFrom: filterDateFrom,
                dateTo: adjustedDateTo
            )
        } else if let key = selectedChatKey {
            messages = store.getMessages(chatKey: key, limit: 500)
        } else {
            messages = []
        }
    }

    private func clearAllFilters() {
        searchText = ""
        filterSource = ""
        filterRole = ""
        filterDateFrom = nil
        filterDateTo = nil
        showDateFilter = false
        performSearch()
    }

    private func loadConversations() {
        conversations = store.allConversations()
        dbInfo = (
            conversations: store.conversationCount,
            messages: store.totalMessageCount,
            sizeBytes: store.databaseSize
        )
    }

    // MARK: - 헬퍼

    private func displayName(for chatKey: String) -> String {
        let parts = chatKey.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            return String(parts[1])
        }
        return chatKey
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private func roleIcon(_ role: String) -> String {
        switch role {
        case "user": return "person.fill"
        case "assistant": return "cpu"
        case "system": return "gearshape"
        case "context": return "arrow.right.circle"
        default: return "questionmark.circle"
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return .blue
        case "assistant": return .green
        case "system": return .orange
        case "context": return .purple
        default: return .secondary
        }
    }

    private func extractSource(from metadata: String?) -> String? {
        guard let metadata, let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? String else { return nil }
        switch source {
        case "api": return "API"
        case "mcp": return "MCP"
        case "messenger": return "Messenger"
        default: return source.uppercased()
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "user": return "사용자"
        case "assistant": return "어시스턴트"
        case "system": return "시스템"
        case "context": return "컨텍스트"
        default: return role
        }
    }
}
