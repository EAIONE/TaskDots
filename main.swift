import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement


// MARK: - Models

enum Priority: Int, Codable, CaseIterable, Identifiable {
    case urgentImportant, importantNotUrgent, urgentNotImportant, notUrgentNotImportant
    var id: Int { rawValue }
    var shortLabel: String { ["紧急重要", "重要不急", "紧急不重", "不急不重"][rawValue] }
    var label: String {
        switch self {
        case .urgentImportant: return "紧急重要"
        case .importantNotUrgent: return "重要不紧急"
        case .urgentNotImportant: return "紧急不重要"
        case .notUrgentNotImportant: return "不重要不紧急"
        }
    }
    var color: Color {
        switch self {
        case .urgentImportant: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .importantNotUrgent: return Color(red: 1.0, green: 0.58, blue: 0.0)
        case .urgentNotImportant: return Color(red: 1.0, green: 0.84, blue: 0.10)
        case .notUrgentNotImportant: return Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }
}

struct TaskItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var priority: Priority
    var createdAt: Date = Date()
    var dueDate: Date?
    var remindOffsetDays: Int? = nil   // 0=当天 1=提前1天 2=提前2天
    var reminded: Bool = false
    var completedAt: Date? = nil
    var notes: String? = nil
    var revisionCountValue: Int? = nil
    var lastSubmittedAt: Date? = nil
    var revisionCount: Int { revisionCountValue ?? 0 }
    func showsSubmissionBorder(at date: Date) -> Bool {
        guard let submitted = lastSubmittedAt else { return false }
        return date < submitted.addingTimeInterval(4 * 60 * 60)
    }
    var isDone: Bool { completedAt != nil }
}

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case daily = "每天"
    case workdays = "工作日"
    case weekly = "每周指定"
    case monthlyLast = "每月最后一个"
    var id: String { rawValue }
}

struct RecurRule: Codable, Identifiable {
    var id = UUID()
    var name: String
    var kind: RuleKind
    var hour: Int = 10
    var minute: Int = 0
    var weekday: Int = 5              // monthlyLast 用：1=周日 ... 5=周四 ... 7=周六
    var weekdays: Set<Int> = [2]      // weekly 用
    var lastFired: Date? = nil
}

struct AppSettings: Codable {
    var docked: Bool = false
    var edge: Int = 1                 // 0=左边缘 1=右边缘
    var dockY: CGFloat = 420
    var lastX: CGFloat = 700
    var lastY: CGFloat = 420
    var launchAtLogin: Bool = false
    var sortMode: String = "manual"
    var reminderHour: Int = 10
    var collapsed: Bool = false       // 兼容旧数据，已不再使用

    enum CodingKeys: String, CodingKey { case docked, edge, dockY, lastX, lastY, launchAtLogin, collapsed, sortMode, reminderHour }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docked = try c.decodeIfPresent(Bool.self, forKey: .docked) ?? false
        edge = try c.decodeIfPresent(Int.self, forKey: .edge) ?? 1
        dockY = try c.decodeIfPresent(CGFloat.self, forKey: .dockY) ?? 420
        lastX = try c.decodeIfPresent(CGFloat.self, forKey: .lastX) ?? 700
        lastY = try c.decodeIfPresent(CGFloat.self, forKey: .lastY) ?? 420
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        sortMode = try c.decodeIfPresent(String.self, forKey: .sortMode) ?? "manual"
        reminderHour = min(16, max(10, try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? 10))
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

struct SaveData: Codable {
    var tasks: [TaskItem]
    var rules: [RecurRule]
    var settings: AppSettings
}

// MARK: - Helpers

func weekdayName(_ w: Int) -> String { ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, w - 1))] }

let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M月d日"
    f.locale = Locale(identifier: "zh_CN")
    return f
}()
let dateWeekFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M月d日 EEE"
    f.locale = Locale(identifier: "zh_CN")
    return f
}()
let dateTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy年M月d日 HH:mm"
    f.locale = Locale(identifier: "zh_CN")
    return f
}()
let keyFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "zh_CN")
    return f
}()

func dueBadgeText(_ d: Date) -> String {
    let cal = Calendar.current
    if d < cal.startOfDay(for: Date()) {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 1
        return "逾期 \(days) 天"
    }
    if cal.isDateInToday(d) { return "今天" }
    if cal.isDateInTomorrow(d) { return "明天" }
    if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
        return dateWeekFmt.string(from: d)
    }
    let f = DateFormatter()
    f.dateFormat = "yyyy年M月d日"
    f.locale = Locale(identifier: "zh_CN")
    return f.string(from: d)
}

func dueText(_ t: TaskItem) -> String? {
    guard let d = t.dueDate else { return nil }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "今天截止" }
    if cal.isDateInTomorrow(d) { return "明天截止" }
    return "截止 " + dateFmt.string(from: d)
}
func isDueToday(_ t: TaskItem) -> Bool {
    t.dueDate.map { Calendar.current.isDateInToday($0) } ?? false
}
func isOverdue(_ t: TaskItem) -> Bool {
    t.dueDate.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false
}
func remindText(_ t: TaskItem) -> String {
    guard let off = t.remindOffsetDays, (0...2).contains(off), t.dueDate != nil else { return "不提醒" }
    switch off {
    case 0: return "当天"
    case 1: return "提前1天"
    case 2: return "提前2天"
    default: return "不提醒"
    }
}
func scheduleText(_ r: RecurRule) -> String {
    let t = String(format: "%02d:%02d", r.hour, r.minute)
    switch r.kind {
    case .daily: return "每天 " + t
    case .workdays: return "工作日(周一至周五) " + t
    case .weekly: return "每周" + r.weekdays.sorted().map(weekdayName).joined(separator: "、") + " " + t
    case .monthlyLast: return "每月最后一个周" + weekdayName(r.weekday) + " " + t + "（遇节假日提前）"
    }
}

// MARK: - Store

final class Store: ObservableObject {
    static let maxTasks = 30
    @Published var tasks: [TaskItem] = [] { didSet { persistIfReady() } }
    @Published var rules: [RecurRule] = [] { didSet { persistIfReady() } }
    @Published var settings = AppSettings() { didSet { persistIfReady() } }
    @Published var quote: String = ""
    @Published var searchText: String = ""
    @Published var filterPriorities: Set<Priority> = []
    var taskFrames: [UUID: CGRect] = [:]
    @Published var draggedTaskID: UUID?
    @Published var focusRequest = 0
    var isReadOnly: Bool { loadFailed }
    @Published var expandedTaskID: UUID?
    private var statusDismissWorkItem: DispatchWorkItem?
    @Published var statusMessage: String? {
        didSet {
            statusDismissWorkItem?.cancel()
            guard statusMessage != nil else { return }
            let item = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
            statusDismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
        }
    }
    @Published private(set) var saveError: String?
    struct UndoEntry { let task: TaskItem; let index: Int; let title: String }
    @Published private(set) var undoEntries: [UndoEntry] = []
    private var readyToSave = false
    private var loadFailed = false
    private var quoteLoadFailed = false
    var quoteLibraryReadOnly: Bool { quoteLoadFailed }
    weak var panel: DockPanel?
    let holiday = HolidayService()

    @Published private(set) var workQuotes = WorkQuoteLibrary()
    @Published var collapseComposerRequest = 0
    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var dataURL: URL { supportDir.appendingPathComponent("data.json") }
    private var poolURL: URL { supportDir.appendingPathComponent("work-quotes.json") }

    init() {
        if FileManager.default.fileExists(atPath: dataURL.path) {
            do {
                let data = try Data(contentsOf: dataURL)
                let saved = try JSONDecoder().decode(SaveData.self, from: data)
                tasks = saved.tasks
                rules = saved.rules
                for i in rules.indices {
                    if rules[i].hour < 10 { rules[i].hour = 10; rules[i].minute = 0 }
                    if rules[i].hour > 16 || (rules[i].hour == 16 && rules[i].minute > 0) {
                        rules[i].hour = 16; rules[i].minute = 0
                    }
                }
                settings = saved.settings
                // Migrate the old “no reminder” sentinel without changing the JSON schema.
                for i in tasks.indices {
                    if tasks[i].dueDate == nil || !(0...2).contains(tasks[i].remindOffsetDays ?? -1) {
                        tasks[i].remindOffsetDays = nil
                    }
                }
            } catch {
                loadFailed = true
                saveError = "数据读取失败，原文件已保留。请在设置中打开数据文件夹检查。"
            }
        }
        readyToSave = true
        loadPoolCache()
        nextQuote()
        fetchOnlineQuotesIfNeeded()
    }

    private func persistIfReady() {
        if readyToSave { save() }
    }

    func save() {
        guard !loadFailed else { return }
        do {
            let data = try JSONEncoder().encode(SaveData(tasks: tasks, rules: rules, settings: settings))
            try data.write(to: dataURL, options: .atomic)
            if saveError != nil { saveError = nil }
        } catch {
            let message = "保存失败，请检查磁盘空间或数据文件夹权限。"
            if saveError != message { saveError = message }
        }
    }

    // MARK: 语录
    func nextQuote() {
        workQuotes.refresh(day: keyFmt.string(from: Date()))
        quote = workQuotes.next()
        saveQuotes()
    }

    func refreshQuotesIfNeeded() {
        fetchOnlineQuotesIfNeeded()
        guard workQuotes.day != keyFmt.string(from: Date()) else { return }
        nextQuote()
    }

    @Published private(set) var onlineQuoteStatus = "每日联网更新 · 断网使用本地语录"
    private var onlineQuotesLoading = false
    private var lastOnlineAttempt = Date.distantPast
    func fetchOnlineQuotesIfNeeded(force: Bool = false) {
        let day = keyFmt.string(from: Date())
        guard !quoteLoadFailed, !onlineQuotesLoading,
              force || (workQuotes.onlineDay != day && Date().timeIntervalSince(lastOnlineAttempt) > 3600) else { return }
        onlineQuotesLoading = true
        onlineQuoteStatus = "正在联网筛选语录…"
        lastOnlineAttempt = Date()
        OnlineQuoteService.fetch { [weak self] values, reachedServer in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.onlineQuotesLoading = false
                guard !self.quoteLoadFailed else { return }
                self.onlineQuoteStatus = reachedServer
                    ? (values.isEmpty ? "接口已连接 · 暂无符合打工主题的新语录，可重试" : "今日联网筛选到\(values.count)条 · 不足由本地补足")
                    : "暂时无法联网 · 正在使用本地语录"
                if !values.isEmpty {
                    self.workQuotes.onlineDay = day
                    self.workQuotes.mergeOnline(values)
                    self.quote = self.workQuotes.next()
                    self.saveQuotes()
                }
            }
        }
    }

    func likeQuote() {
        guard !quoteLoadFailed else { return }
        workQuotes.favorite(quote)
        saveQuotes()
    }

    func dislikeQuote() {
        guard !quoteLoadFailed else { return }
        workQuotes.reject(quote)
        quote = workQuotes.next()
        saveQuotes()
    }

    func removeFavorite(_ value: String) {
        workQuotes.favorites.removeAll { $0 == value }
        saveQuotes()
    }

    private func saveQuotes() {
        guard !quoteLoadFailed else { return }
        do { try JSONEncoder().encode(workQuotes).write(to: poolURL, options: .atomic) }
        catch { statusMessage = "语录保存失败，请检查数据文件夹权限" }
    }

    private func loadPoolCache() {
        guard FileManager.default.fileExists(atPath: poolURL.path) else { return }
        do {
            workQuotes = try JSONDecoder().decode(WorkQuoteLibrary.self, from: Data(contentsOf: poolURL))
            workQuotes.quotes = Array(workQuotes.quotes.filter { !workQuotes.rejected.contains($0) }.suffix(100))
        } catch {
            quoteLoadFailed = true
            statusMessage = "语录库读取失败，收藏和删除记录的原文件已保留"
        }
    }

    // MARK: 查询/筛选
    var activeCount: Int { tasks.filter { !$0.isDone }.count }

    var allActive: [TaskItem] {
        let active = tasks.filter { !$0.isDone }
        guard settings.sortMode == "priority" else { return active }
        return active.sorted {
            if $0.priority != $1.priority { return $0.priority.rawValue < $1.priority.rawValue }
            return $0.createdAt > $1.createdAt
        }
    }

    func moveTask(id: UUID, before target: UUID) {
        guard !loadFailed, id != target else { return }
        var ordered = allActive
        guard let source = ordered.firstIndex(where: { $0.id == id }), ordered.contains(where: { $0.id == target }) else { return }
        let task = ordered.remove(at: source)
        let destination = ordered.firstIndex(where: { $0.id == target })!
        ordered.insert(task, at: destination)
        settings.sortMode = "manual"
        tasks = ordered + tasks.filter { $0.isDone }
    }

    func moveTaskToY(id: UUID, y: CGFloat) {
        let order = allActive
        guard let from = order.firstIndex(where: { $0.id == id }) else { return }
        let candidates = order.filter { $0.id != id && taskFrames[$0.id] != nil }
        guard let nearest = candidates.min(by: { abs(taskFrames[$0.id]!.midY - y) < abs(taskFrames[$1.id]!.midY - y) }),
              let to = order.firstIndex(where: { $0.id == nearest.id }) else { return }
        shiftTask(id: id, by: to - from)
    }

    func shiftTask(id: UUID, by delta: Int) {
        var ordered = allActive
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(ordered.count - 1, from + delta))
        guard from != to else { return }
        let task = ordered.remove(at: from)
        ordered.insert(task, at: to)
        settings.sortMode = "manual"
        tasks = ordered + tasks.filter { $0.isDone }
    }

    var typeCounts: [Priority: Int] {
        var c: [Priority: Int] = [:]
        for t in tasks where !t.isDone { c[t.priority, default: 0] += 1 }
        return c
    }

    func matches(_ t: TaskItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty && !t.name.localizedCaseInsensitiveContains(query) { return false }
        if !filterPriorities.isEmpty && !filterPriorities.contains(t.priority) { return false }
        return true
    }
    var activeTasks: [TaskItem] { allActive.filter(matches) }
    var completedTasks: [TaskItem] {
        tasks.filter { $0.isDone && matches($0) }.sorted { ($0.completedAt ?? Date()) > ($1.completedAt ?? Date()) }
    }
    var hasFilter: Bool { !searchText.isEmpty || !filterPriorities.isEmpty }
    func clearFilter() {
        searchText = ""
        filterPriorities = []
    }
    func openWithFilter(_ p: Priority?) {
        if let p {
            searchText = ""
            filterPriorities = [p]
        } else {
            clearFilter()
        }
    }

    // MARK: 任务操作
    @discardableResult
    func addTask(name: String, priority: Priority, due: Date?, offset: Int?, notes: String = "") -> Bool {
        guard !loadFailed else { return false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        guard activeCount < Self.maxTasks else { return false }
        tasks.insert(TaskItem(name: n, priority: priority, dueDate: due,
                              remindOffsetDays: due != nil && (0...2).contains(offset ?? -1) ? offset : nil,
                              notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)), at: 0)
        settings.sortMode = "manual"
        return true
    }
    func editTask(id: UUID, resetReminder: Bool = false, _ mutate: (inout TaskItem) -> Void) {
        guard !loadFailed else { return }
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            mutate(&tasks[i])
            if resetReminder { tasks[i].reminded = false }
        }
    }
    @discardableResult
    func renameTask(id: UUID, name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[i].name = clean
        return true
    }

    func incrementRevision(id: UUID) {
        editTask(id: id) {
            $0.revisionCountValue = $0.revisionCount + 1
            $0.lastSubmittedAt = Date()
        }
    }

    func updateNotes(id: UUID, notes: String) {
        guard !loadFailed, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = clean.isEmpty ? nil : clean
        guard tasks[index].notes != value else { return }
        tasks[index].notes = value
    }

    private func remember(_ task: TaskItem, index: Int, title: String) {
        undoEntries.append(UndoEntry(task: task, index: index, title: title))
        if undoEntries.count > 20 { undoEntries.removeFirst() }
    }

    func complete(_ t: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == t.id }), !tasks[i].isDone else { return }
        remember(tasks[i], index: i, title: "完成")
        tasks[i].completedAt = Date()
        statusMessage = "已完成「\(t.name)」"
    }

    func delete(_ t: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        remember(tasks[i], index: i, title: "删除")
        tasks.remove(at: i)
        statusMessage = "已删除「\(t.name)」"
    }

    func undoLastAction() {
        guard let entry = undoEntries.last else { return }
        let existing = tasks.firstIndex(where: { $0.id == entry.task.id })
        let addsActive = !entry.task.isDone && (existing == nil || tasks[existing!].isDone)
        guard !addsActive || activeCount < Self.maxTasks else {
            statusMessage = "待办已满，请先腾出一条再撤销"
            return
        }
        undoEntries.removeLast()
        let restored = entry.task
        if let i = existing { tasks[i] = restored }
        else { tasks.insert(restored, at: min(entry.index, tasks.count)) }
        statusMessage = "已撤销\(entry.title)"
    }

    @discardableResult
    func duplicateFromCompleted(_ t: TaskItem) -> Bool {
        let date = t.dueDate.flatMap { $0 < Calendar.current.startOfDay(for: Date()) ? nil : $0 }
        let ok = addTask(name: t.name, priority: t.priority, due: date, offset: date == nil ? nil : t.remindOffsetDays, notes: t.notes ?? "")
        statusMessage = ok ? "已加入待办" : "待办已达 \(Self.maxTasks) 条，请先完成部分任务"
        return ok
    }
    func addRule(_ r: RecurRule) { guard !loadFailed else { return }; rules.append(r) }
    func updateRule(_ rule: RecurRule) {
        guard !loadFailed, let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var updated = rule
        // Editing an already-fired rule does not send a second notification that day.
        updated.lastFired = rules[i].lastFired
        rules[i] = updated
    }
    func deleteRule(_ r: RecurRule) { rules.removeAll { $0.id == r.id } }

    func dockToSidebar() {
        panel?.dock(edge: settings.edge)
    }
}

// MARK: - Work quotes: daily local refresh, favorites and permanent exclusions.

struct WorkQuoteLibrary: Codable {
    var onlineDay: String? = nil
    var day = ""
    var quotes: [String] = []
    var favorites: [String] = []
    var rejected: Set<String> = []
    var cursor = 0

    mutating func refresh(day key: String) {
        guard day != key else { return }
        let eligible = QuoteService.quotes.filter { !rejected.contains($0) }
        let fresh = eligible.filter { !quotes.contains($0) }.shuffled()
        let existing = eligible.filter { quotes.contains($0) }.shuffled()
        let batch = Array((fresh + existing).prefix(30))
        quotes.removeAll { batch.contains($0) || rejected.contains($0) }
        quotes.append(contentsOf: batch)
        quotes = Array(quotes.suffix(100))
        cursor = max(0, quotes.count - batch.count)
        day = key
    }

    mutating func mergeOnline(_ values: [String]) {
        let fresh = Array(Set(values)).filter { !rejected.contains($0) && !quotes.contains($0) }
        guard !fresh.isEmpty else { return }
        quotes.removeLast(min(fresh.count, quotes.count))
        quotes.append(contentsOf: fresh)
        quotes = Array(quotes.suffix(100))
        cursor = max(0, quotes.count - fresh.count)
    }

    mutating func next() -> String {
        guard !quotes.isEmpty else { return "语录已清空，今天先安心摸鱼。" }
        let value = quotes[cursor % quotes.count]
        cursor = (cursor + 1) % quotes.count
        return value
    }

    mutating func favorite(_ value: String) {
        guard quotes.contains(value), !favorites.contains(value) else { return }
        favorites.append(value)
    }

    mutating func reject(_ value: String) {
        if let index = quotes.firstIndex(of: value), index < cursor { cursor -= 1 }
        quotes.removeAll { $0 == value }
        favorites.removeAll { $0 == value }
        rejected.insert(value)
        if quotes.isEmpty { cursor = 0 } else { cursor %= quotes.count }
    }
}

enum OnlineQuoteService {
    // Public humor feed. Only short work-related text is eligible for this app.
    static func parse(_ data: Data) -> String? {
        guard data.count < 16384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 200,
              let raw = object["text"] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let topics = ["上班", "下班", "打工", "老板", "同事", "甲方", "改稿", "加班", "工资", "工位", "开会", "会议", "需求", "设计师", "摸鱼", "周一", "周五", "绩效", "打卡"]
        let excluded = ["http", "www.", "微信", "加群", "上我", "做爱", "傻逼", "色情", "自杀", "去死"]
        guard (6...80).contains(text.count), topics.contains(where: text.contains),
              !excluded.contains(where: text.lowercased().contains),
              !text.contains("<"), !text.contains(">") else { return nil }
        return text
    }

    static func fetch(completion: @escaping ([String], Bool) -> Void) {
        let url = URL(string: "https://xiaoapi.cn/v1/zs_yulu.php?type=%E6%90%9E%E7%AC%91")!
        func request(_ remaining: Int, _ values: [String], _ reached: Bool) {
            guard remaining > 0 else { completion(values, reached); return }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "_", value: UUID().uuidString)]
            var req = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            req.setValue("TaskDots/1.9", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, response, error in
                guard error == nil, let response = response as? HTTPURLResponse,
                      response.statusCode == 200, let data = data else {
                    completion(values, reached); return
                }
                var next = values
                if let value = parse(data), !next.contains(value) { next.append(value) }
                request(remaining - 1, next, true)
            }.resume()
        }
        request(30, [], false)
    }
}

enum QuoteService {
    static let quotes: [String] = [
"上班是不可能上班的，但不上班就没有饭吃。",
        "生活不止眼前的苟且，还有明天和后天的苟且。",
        "打工人的快乐是下班的快乐，悲伤是明早的闹钟。",
        "公司是我家，可惜我家里不给发工资。",
        "我上班是为了钱，别谈理想，我的理想是不上班。",
        "累吗？累就对了，舒服是留给有钱人的。",
        "今天的班先上着，明天的事明天再崩溃。",
        "别人在人生巅峰，我在工资低谷。",
        "摸鱼一时爽，一直摸鱼一直爽，直到老板出现。",
        "辞职的勇气没有，续命的咖啡还有。",
        "我不是在上班，我是在给自己的花呗打工。",
        "工位是我的第二个家——因为加班比在家还久。",
        "别人靠梦想支撑，我靠工资到账提醒。",
        "老板画的饼太大，我的胃太小。",
        "愿你的工资和你的头发一样，只增不减。",
        "上班的心情，比上坟还沉重。",
        "打工打工，打完这个工还有下一个工。",
        "周一综合症，周复一周，药不能停。",
        "领导一句话，我跑断两条腿。",
        "我不想努力了，但房租想。",
        "努力不一定成功，但不努力真的好舒服。",
        "人间不值得，但全勤奖值得。",
        "熬过这个项目，还有下个项目等我。",
        "工资像大姨妈，一月一次，一周就没了。",
        "上班使我快乐——这句是真的吗？",
        "别问，问就是在改需求。",
        "甲方虐我千百遍，我待甲方如初恋。",
        "我不是社恐，我只是上班上的。",
        "带薪如厕，打工人最后的倔强。",
        "今天也是元气满满（并没有）地上班。",
        "别人下班我下班，别人加班我还加班。",
        "打工不能致富，但能防止提前退休。",
        "梦想还是要有的，万一老板给你画个更大的饼。",
        "我的 Schedule 排得比我的命还满。",
        "只要我够穷，老板就剥削不到我——可惜不够。",
        "成年人最大的自律：把不想干的活也干完。",
        "我的工位不是工位，是精神状态观测站。",
        "人在工位坐，灵魂在排队下班。",
        "今天没有发疯，只是系统提示内存不足。",
        "工资还没到账，灵魂已经欠费。",
        "我的情绪很稳定，稳定地想下班。",
        "上班全靠演技，工资全靠忍耐。",
        "别给我画饼了，我的工位放不下烤箱。",
        "需求改了八版，我进化出了八个人格。",
        "文件可以另存为，我想另存一个自己。",
        "咖啡负责清醒，我负责假装热情。",
        "我不是摸鱼，我在给大脑做节能优化。",
        "这班上得很好，下次不要再上了。",
        "工作使我充实，具体充实了我的待办。",
        "今天的我，是昨天崩溃后自动恢复的备份。",
        "这份工作唯一的弹性，是我的忍耐极限。",
        "老板说要有主人翁精神，我先找一下房产证。",
        "工牌是我的身份，发疯是我的天赋。",
        "我不是反应慢，我的灵魂还在打卡路上。",
        "每天都在突破极限，主要是精神极限。",
        "别问进度，问就是在和需求互相理解。",
        "我的人生规划：十点盼午饭，三点盼下班。",
        "一边说收到，一边收到内伤。",
        "活是做不完的，但班是可以下的。",
        "工作群一响，我的快乐当场下线。",
        "我和周末之间，隔着一场漫长的例会。",
        "会议没有结论，我的人生倒是有了疑问。",
        "我的工作态度：能做，但先让我叹口气。",
        "我只是来赚钱的，怎么还考验起了人性。",
        "今天的精神状态：表格开着，人已散架。",
        "打工人的超能力：笑着说好的，心里放烟花。",
        "周一不是一天，是一种精神天气。",
        "我的理想很朴素：工资上涨，会议下降。",
        "身体在上班，脑子在申请离线。",
        "别人沉淀经验，我沉淀工伤文学。",
        "这不是待办清单，这是我的连载苦难史。",
        "消息已读，灵魂未读。",
        "我不是拖延，我在等待最后一刻的神迹。",
        "不怕困难多，就怕又有人拉我开会。",
        "每次打开电脑，都像打开一份续命合同。",
        "我的笑容已上线，但服务暂不可用。",
        "今日电量：上班前百分之八，下班后满格。",
        "今天也在认真工作，认真计算离下班多久。",
        "我把热情交给工作，工作把问号还给了我。",
        "老板说要向前看，我看到了下一个截止日。",
        "心里有火，手里有活，脸上有礼貌。",
        "工位虽小，装得下我全部的无语。",
        "我已经不是昨天的我了，昨天还没这么困。",
        "只要我回复够快，崩溃就追不上我。",
        "工作没有把我打倒，因为我一直坐着。",
        "想开了不是想通了，是又打开了一个表格。",
        "这哪是多线程工作，是多人格轮流值班。",
        "谁说我没有执行力，我每天准时执行下班。",
        "下午的我像旧打印机，有动静但不一定出活。",
        "我和工作的关系：它不放过我，我不理解它。",
        "打工人的浪漫，是今天没有临时需求。",
        "我的情绪价值，都拿去补贴项目了。",
        "今天也是带着问号来，带着省略号走。",
        "请勿打扰，我正在与现实进行兼容性测试。",
        "会议开完了，待办繁殖了。",
        "比余额更少的，是我对工作的耐心。",
        "生活给我一拳，我回它一句收到。",
        "不是我不够积极，是积极也需要预算。",
        "我在工位上修行，主要修复我的表情。",
        "别催，我的灵感正在安检。",
        "说好的轻松工作，轻的是工资，松的是头发。",
        "有些班上着上着，人就成了表情包。",
        "我的工作日志：打开、沉默、保存、下班。",
        "每一个好的背后，都有一个濒临掉线的我。",
        "我允许事情发生，但最好别发生在下班前。",
        "不是我不想成长，是今天的会已经长够了。",
        "我不是在发呆，我在后台处理人生。",
        "工资是月结的，崩溃是日更的。",
        "进度条正在加载，耐心条已经清空。",
        "今天的我很完整，完整地不想上班。",
        "我可以扛事，但请别把整座山搬过来。",
        "我把工作当回事，工作把我当多核处理器。",
        "如果沉默有声音，我的工位就是演唱会。",
        "上班是一场冒险，每天随机刷新需求。",
        "活着不一定有意义，但打卡一定有记录。",
        "我的心态很好，好到只剩心跳。",
        "工位上的水杯，见过我最多的叹息。",
        "人可以低电量，消息不能不回复。",
        "我正在努力，努力维持人类的基本礼貌。",
        "上班像开盲盒，拆出来全是待办。",
        "人生建议：先保存文件，再放飞灵魂。",
        "下班之前的临时需求，是今日终极彩蛋。",
        "我的快乐很简单：没有新消息。",
        "今天的情绪像网速，时好时坏但一直在连。",
        "没什么能打败我，除非需求说再改一下。",
        "我的梦想没有缩水，只是暂存在周末。",
        "打工人的清醒：先吃饭，再和世界较劲。",
        "我不是摆烂，我在保护剩余的可用资源。",
        "如果努力有声音，我的键盘早就报警了。",
        "上午给自己打气，下午给自己充电。",
        "我的职业规划，暂时精确到了今天下班。",
        "这班我先上着，灵魂的意见稍后处理。",
        "我与工作的距离，取决于还有多久发工资。",
        "今日成就：没有把心里话发到工作群。",
        "人生没有撤销键，幸好文件还有上一版。",
        "我不是无话可说，我是怕说完就得写检讨。",
        "上班可以没有掌声，下班必须准时起身。",
        "甲方说再大气一点，我把文件放大到了200%。",
        "改稿改到第十八版，文件名比正文还长。",
        "我的设计理念：先让甲方选中，再让甲方放过。",
        "今天最有层次感的，是我的黑眼圈。",
        "老板让我跳出框架，我看了一眼离职申请。",
        "方案要年轻化，负责方案的人已经老了。",
        "我做的是平面设计，过的是立体受罪。",
        "这稿没有问题，有问题的是它还没到第十版。",
        "甲方要五彩斑斓，我只剩两眼一黑。",
        "排版讲究留白，我的日程不配拥有。",
        "字号可以加大，预算也可以试试。",
        "对齐了所有元素，没对齐我的生物钟。",
        "导出的是PDF，耗尽的是我的CPU。",
        "今天的审美：只要能过，都挺好看。",
        "稿子已转曲，我的人生也拐了个弯。",
        "图片分辨率不够，甲方的想象力倒是高清。",
        "项目进入收尾阶段，尾巴又长出了三个项目。",
        "老板问我有没有想法，我有，不能当面说。",
        "我不是不合群，我是不想再进一个工作群。",
        "今天最大的运动量，是把消息往上翻。",
        "会前没有议题，会后全是我的问题。",
        "这个会很短，短到只占了我的一整个下午。",
        "会议纪要：大家说了很多，我又多了很多活。",
        "我提议提高效率，于是多开了一个效率会。",
        "老板让我畅所欲言，我把麦克风关了。",
        "会议室的门一关，下班的门也关了。",
        "午饭吃什么还没定，下午的会已经定了。",
        "我说我没空，他们说那就占用你十分钟。",
        "收到不是咒语，念完工作不会自动完成。",
        "消息不用撤回，我的血压已经收到了。",
        "我的时间管理：先着急，再同时着急。",
        "今天完成了三件事：开机、叹气、等下班。",
        "我的待办有自己的繁殖计划。",
        "清空了回收站，没清空工作量。",
        "我想暂停一下，工作给我点了续播。",
        "别人穿搭有松弛感，我的裤腰有紧迫感。",
        "我的工位风水很好，活从四面八方来。",
        "水杯空了可以接水，我空了只能接活。",
        "我的耳机没有声音，主要负责劝退聊天。",
        "今天的我像Excel：表面有序，内部报错。",
        "人已经加载完毕，工作意愿加载失败。",
        "我不是没有目标，我一直盯着右下角的时间。",
        "周五下午的消息，最好是外卖到了。",
        "距离下班还有五分钟，距离新需求只有一秒钟。",
        "下班路上走得快，是怕工作追出来。",
        "电梯关门那一刻，我才真正打开自己。",
        "我与公司的时差：身体到了，心还在周末。",
        "闹钟响的时候，我和梦想一起按了稍后提醒。",
        "周一的咖啡加不了糖，因为生活已经够粘牙。",
        "周末过得像试用版，刚熟悉就到期。",
        "周日晚上不叫失眠，叫提前登录工作状态。",
        "工资到账三秒，房租开始自动分赃。",
        "我的工资很懂事，从不在账户里过夜。",
        "理财第一步：查余额，然后保持原样。",
        "老板说公司扁平化，我的钱包先响应了。",
        "绩效要有突破，我的发际线已经突破了。",
        "我也想做长期主义者，可午休只有一小时。",
        "今天没有情绪输出，因为正在省电。",
        "我看起来很平静，是因为心里弹窗太多卡住了。",
        "人生要有边界感，比如六点之后的我。",
        "我可以接受挑战，但能不能先接受我的休假申请。",
        "工作让我学会了换位思考：我想换个工位躺着。",
        "我的抗压能力，是靠不断忘记刚才发生了什么。",
        "别再给我加油了，我这不是发动机，是快熟了。",
        "我没有消极怠工，我是在积极等饭。",
        "上班带的饭还没热，我先被需求气热了。",
        "同事说我状态不错，可能是显示器反光。",
        "这不是黑眼圈，是职场限定烟熏妆。",
        "我的礼貌由工资赞助，余额不足时请谅解。",
        "今天也有在发光，主要是屏幕照的。"
    ]
}

// MARK: - Holiday (法定节假日，haoshenqi 接口，timor.tech 备用)

final class HolidayService {
    private(set) var cache: [String: Bool] = [:]
    private var pending = Set<String>()

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("holidays.json")
    }

    init() {
        if let d = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode([String: Bool].self, from: d) {
            cache = c
        }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(cache) {
            try? d.write(to: cacheURL, options: .atomic)
        }
    }

    func isKnownHoliday(_ d: Date) -> Bool? { cache[keyFmt.string(from: d)] }

    func request(_ d: Date) {
        let k = keyFmt.string(from: d)
        guard cache[k] == nil, !pending.contains(k) else { return }
        pending.insert(k)
        fetchHaoShenQi(k)
    }

    // status: 0=工作日 1=普通周末 2=调休补班 3=法定节假日(放假)
    private func fetchHaoShenQi(_ k: String) {
        guard let url = URL(string: "https://api.haoshenqi.top/holiday?date=\(k)") else {
            pending.remove(k); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data,
               let arr = try? JSONDecoder().decode([HolidayItem].self, from: data),
               let item = arr.first {
                DispatchQueue.main.async {
                    self.cache[k] = (item.status == 3)
                    self.pending.remove(k)
                    self.save()
                }
            } else {
                self.fetchTimor(k)
            }
        }.resume()
    }

    private func fetchTimor(_ k: String) {
        guard let url = URL(string: "https://timor.tech/api/holiday/info/\(k)") else {
            pending.remove(k); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var result: Bool? = nil
            if let data, let r = try? JSONDecoder().decode(HolidayResp.self, from: data) {
                if let h = r.holiday { result = (h.holiday != false) }
            }
            DispatchQueue.main.async {
                if let result { self.cache[k] = result }
                self.pending.remove(k)
                self.save()
            }
        }.resume()
    }
}

struct HolidayItem: Decodable { let status: Int }
struct HolidayResp: Decodable { let holiday: HolidayObj? }
struct HolidayObj: Decodable { let holiday: Bool? }

// MARK: - Notifications & Reminders

func postNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            DispatchQueue.main.async {
                let esc = body.replacingOccurrences(of: "\"", with: "\\\"")
                let script = "display notification \"\(esc)\" with title \"\(title)\""
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        }
    }
}

final class ReminderEngine {
    let store: Store
    private var timer: Timer?
    init(store: Store) { self.store = store }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    private func remindDate(_ t: TaskItem) -> Date? {
        guard let due = t.dueDate, let off = t.remindOffsetDays, (0...2).contains(off) else { return nil }
        let cal = Calendar.current
        guard var day = cal.date(byAdding: .day, value: -off, to: cal.startOfDay(for: due)) else { return nil }
        while cal.isDateInWeekend(day) {
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return cal.date(bySettingHour: store.settings.reminderHour, minute: 0, second: 0, of: day)
    }

    func isOfficeTime(_ date: Date) -> Bool {
        let cal = Calendar.current
        guard !cal.isDateInWeekend(date) else { return false }
        return isReminderHour(date)
    }

    func isReminderHour(_ date: Date) -> Bool {
        let cal = Calendar.current
        let minute = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return minute >= 600 && minute <= 960
    }

    private func lastWeekdayDate(_ weekday: Int, now: Date, cal: Calendar) -> Date? {
        guard let interval = cal.dateInterval(of: .month, for: now) else { return nil }
        var d = cal.startOfDay(for: interval.end.addingTimeInterval(-86400))
        while cal.component(.weekday, from: d) != weekday {
            guard let prev = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
            d = prev
        }
        return d
    }

    private func nextFire(_ r: RecurRule, now: Date) -> Date? {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: now)
        guard let at = cal.date(byAdding: DateComponents(hour: r.hour, minute: r.minute), to: sod) else { return nil }
        let wd = cal.component(.weekday, from: now)
        switch r.kind {
        case .daily: return at
        case .workdays: return (2...6).contains(wd) ? at : nil
        case .weekly: return r.weekdays.contains(wd) ? at : nil
        case .monthlyLast:
            guard var d = lastWeekdayDate(r.weekday, now: now, cal: cal) else { return nil }
            var steps = 0
            while store.holiday.isKnownHoliday(d) == true, steps < 15 {
                guard let pd = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
                d = pd
                steps += 1
            }
            store.holiday.request(d)
            return d == sod ? at : nil
        }
    }

    func check() {
        let now = Date()
        store.refreshQuotesIfNeeded()
        for i in store.tasks.indices where !store.tasks[i].isDone && !store.tasks[i].reminded {
            if isOfficeTime(now), let rd = remindDate(store.tasks[i]), now >= rd {
                let name = store.tasks[i].name
                let due = dueText(store.tasks[i]) ?? ""
                postNotification(title: "📋 任务提醒", body: "\(name)（\(due)）")
                store.tasks[i].reminded = true
            }
        }
        for i in store.rules.indices {
            let r = store.rules[i]
            if isReminderHour(now), let fire = nextFire(r, now: now), now >= fire,
               r.lastFired.map({ !Calendar.current.isDate($0, inSameDayAs: now) }) ?? true {
                postNotification(title: "⏰ 日常提醒", body: r.name)
                store.rules[i].lastFired = now
            }
        }
        store.save()
    }
}

// MARK: - Login Launch

enum LaunchLogin {
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            let s = SMAppService.mainApp
            do {
                if on {
                    // 已注册则不重复调用 register()，避免系统反复弹"后台项目"提醒
                    if s.status == .enabled { return true }
                    try s.register()
                } else {
                    try s.unregister()
                }
                return true
            } catch {
                if on && s.status == .enabled { return true }
            }
        }
        return setLaunchAgent(on)
    }
    /// 迁移：清除旧版 LaunchAgent 自启方式，改用系统正规登录项（SMAppService）。
    /// 旧方式每次开机都会触发"后台项目"系统提醒；正规登录项只在首次添加时提醒一次。
    static func migrateLegacyAgent(enabled: Bool) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.eai.taskdots.plist")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        guard enabled, #available(macOS 13.0, *) else { return }
        if SMAppService.mainApp.status == .enabled { return }
        try? SMAppService.mainApp.register()
    }
    private static func setLaunchAgent(_ on: Bool) -> Bool {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let url = dir.appendingPathComponent("com.eai.taskdots.plist")
        if !on {
            try? fm.removeItem(at: url)
            return true
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TaskDots").path
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>com.eai.taskdots</string>
            <key>ProgramArguments</key><array><string>\(bin)</string></array>
            <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try plist.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}

// MARK: - Panel (draggable + magnetic dock)

final class DockPanel: NSPanel {
    static let mainSize = NSSize(width: 392, height: 620)
    static let dockWidth: CGFloat = 56
    static let edgeMargin: CGFloat = 0
    static let magneticDistance: CGFloat = 36

    let store: Store
    var typographyPanel: TypographyPanel?
    var isDockDragging = false
    var isMainDragging = false
    private var autoDockTimer: Timer?
    private var lastPointerPresence = Date()
    private var keyboardMonitor: Any?

    static func shouldAutoDock(now: Date, lastPresence: Date, pointerInside: Bool, interacting: Bool) -> Bool {
        !pointerInside && !interacting && now.timeIntervalSince(lastPresence) >= 5
    }

    private func checkAutoDock() {
        let now = Date()
        guard isVisible, !store.settings.docked else { lastPointerPresence = now; return }
        let point = NSEvent.mouseLocation
        let helperVisible = typographyPanel?.isVisible == true
        let pointerInside = frame.contains(point)
        let busy = isMainDragging || isDockDragging || store.draggedTaskID != nil
            || NSEvent.pressedMouseButtons != 0 || attachedSheet != nil
            || helperVisible || NSApp.windows.contains { $0 !== self && $0.isVisible && $0.level == .popUpMenu }
        if pointerInside || busy { lastPointerPresence = now; return }
        if Self.shouldAutoDock(now: now, lastPresence: lastPointerPresence, pointerInside: pointerInside, interacting: busy),
           let screen = currentScreen {
            let vf = screen.visibleFrame
            // Dock to the nearest edge, keeping the handle beside the current window.
            store.settings.dockY = max(vf.minY, min(vf.maxY - dockHeight, frame.midY - dockHeight / 2))
            dock(edge: frame.midX < vf.midX ? 0 : 1)
        }
    }

    deinit {
        autoDockTimer?.invalidate()
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor) }
    }

    /// 隐蔽的固定高度边缘抓手
    var dockHeight: CGFloat { 104 }

    init(store: Store) {
        self.store = store
        let s = store.settings
        let initial = NSRect(x: s.lastX, y: s.lastY,
                             width: Self.mainSize.width, height: Self.mainSize.height)
        super.init(contentRect: initial,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = !s.docked
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = NSHostingView(rootView: RootView(store: store))
        store.panel = self
        autoDockTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkAutoDock() }
        if let timer = autoDockTimer { RunLoop.main.add(timer, forMode: .common) }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.lastPointerPresence = Date()
            return event
        }
        if s.docked { applyDockedFrame(animated: false) }
        else { applyMainFrame(animated: false) }
    }

    override var canBecomeKey: Bool { true }

    private var currentScreen: NSScreen? {
        NSScreen.screens.max { a, b in
            let ar = a.frame.intersection(frame), br = b.frame.intersection(frame)
            return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
        } ?? NSScreen.main
    }

    static func edgeForRelease(frame: NSRect, visible: NSRect) -> Int? {
        let left = frame.minX - visible.minX
        let right = visible.maxX - frame.maxX
        if left <= magneticDistance && left <= right { return 0 }
        if right <= magneticDistance { return 1 }
        return nil
    }

    func finishMainDrag() {
        lastPointerPresence = Date()
        isMainDragging = false
        guard !store.settings.docked, let screen = currentScreen else { return }
        if let edge = Self.edgeForRelease(frame: frame, visible: screen.visibleFrame) {
            dock(edge: edge)
        } else {
            var saved = store.settings
            saved.lastX = frame.minX
            saved.lastY = frame.minY
            store.settings = saved
        }
    }

    func finishSidebarDrag() {
        isDockDragging = false
        guard let screen = currentScreen else { return }
        let visible = screen.visibleFrame
        let left = abs(frame.minX - visible.minX)
        let right = abs(visible.maxX - frame.maxX)
        if min(left, right) > 56 { undockToDragPosition() }
        else {
            var saved = store.settings
            saved.dockY = max(visible.minY, min(visible.maxY - dockHeight, frame.minY))
            store.settings = saved
            snapBackDocked()
        }
    }

    private func dockedX(_ vf: NSRect) -> CGFloat {
        store.settings.edge == 0
            ? vf.minX + Self.edgeMargin
            : vf.maxX - Self.dockWidth - Self.edgeMargin
    }

    private func clampDockedPosition() {
        guard let scr = currentScreen else { return }
        let vf = scr.visibleFrame
        let x = dockedX(vf)
        var y = frame.minY
        y = max(vf.minY, min(vf.maxY - dockHeight, y))
        if abs(frame.minX - x) > 0.5 || abs(frame.minY - y) > 0.5 {
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        if abs(store.settings.dockY - y) > 0.5 { store.settings.dockY = y }
    }

    /// 磁吸靠边
    func dock(edge: Int) {
        endEditing(for: nil)
        makeFirstResponder(nil)
        typographyPanel?.orderOut(nil)
        if !store.settings.docked {
            store.settings.lastX = frame.minX
            store.settings.lastY = frame.minY
        }
        store.settings.edge = edge
        store.settings.docked = true
        hasShadow = false
        store.clearFilter()
        applyDockedFrame(animated: true)
    }

    /// 从侧边栏展开主界面（换一条语录）
    func undock(filter: Priority? = nil) {
        lastPointerPresence = Date()
        store.nextQuote()
        store.openWithFilter(filter)
        store.settings.docked = false
        hasShadow = true
        applyMainFrame(animated: true)
    }

    /// 从停靠态拖拽直接展开整个界面（窗口出现在当前拖拽位置）
    func undockToDragPosition() {
        lastPointerPresence = Date()
        let origin = frame.origin
        store.nextQuote()
        store.clearFilter()
        store.settings.docked = false
        hasShadow = true
        guard let scr = currentScreen else { return }
        let vf = scr.visibleFrame
        var x = origin.x
        var y = origin.y + dockHeight / 2 - 60
        x = max(vf.minX, min(vf.maxX - Self.mainSize.width - 8, x))
        y = max(vf.minY, min(vf.maxY - Self.mainSize.height, y))
        store.settings.lastX = x
        store.settings.lastY = y
        setFrame(NSRect(x: x, y: y, width: Self.mainSize.width, height: Self.mainSize.height), display: true)
    }

    func applyMainFrame(animated: Bool) {
        guard let scr = currentScreen else { return }
        let vf = scr.visibleFrame
        var x = frame.minX
        if x < vf.minX || x > vf.maxX - Self.mainSize.width {
            x = store.settings.lastX
        }
        if x < vf.minX || x > vf.maxX - Self.mainSize.width {
            x = vf.maxX - Self.mainSize.width - 40
        }
        let y = max(vf.minY, min(vf.maxY - Self.mainSize.height, frame.minY))
        let target = NSRect(x: x, y: y, width: Self.mainSize.width, height: Self.mainSize.height)
        if animated {
            animator().setFrame(target, display: true, animate: true)
        } else {
            setFrame(target, display: true)
        }
    }

    private func applyDockedFrame(animated: Bool) {
        guard let scr = currentScreen else { return }
        let vf = scr.visibleFrame
        let x = dockedX(vf)
        var y = store.settings.dockY
        if y <= vf.minY || y >= vf.maxY - dockHeight { y = vf.midY - dockHeight / 2 }
        y = max(vf.minY, min(vf.maxY - dockHeight, y))
        let target = NSRect(x: x, y: y, width: Self.dockWidth, height: dockHeight)
        if animated {
            animator().setFrame(target, display: true, animate: true)
        } else {
            setFrame(target, display: true)
        }
    }
}

// MARK: - Root View

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeWindowDragView { NativeWindowDragView() }
    func updateNSView(_ nsView: NativeWindowDragView, context: Context) {}
}

final class NativeWindowDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("拖动窗口")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 30) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !isHidden && bounds.contains(local) ? self : nil
    }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    static func screenPoint(for event: NSEvent) -> NSPoint {
        if let cg = event.cgEvent {
            let point = cg.location
            return NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        }
        return event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? DockPanel else { return }
        let wasDocked = panel.store.settings.docked
        if wasDocked && event.clickCount >= 2 { panel.undock(); return }
        let origin = panel.frame.origin
        let start = Self.screenPoint(for: event)
        var moved = false
        panel.isDockDragging = wasDocked
        panel.isMainDragging = !wasDocked
        // Track in screen coordinates: moving this view cannot feed back into the drag delta.
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let mouse = Self.screenPoint(for: next)
            let delta = NSPoint(x: mouse.x - start.x, y: mouse.y - start.y)
            if hypot(delta.x, delta.y) > 1 { moved = true }
            panel.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
            if next.type == .leftMouseUp { break }
        }
        panel.isDockDragging = false
        panel.isMainDragging = false
        guard moved else { return }
        if wasDocked { panel.finishSidebarDrag() }
        else { panel.finishMainDrag() }
    }

}

struct RootView: View {
    @ObservedObject var store: Store
    @State private var showCompleted = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Keep form state alive while the window is temporarily folded.
            MainView(store: store, showCompleted: $showCompleted, showSettings: $showSettings)
                .frame(width: DockPanel.mainSize.width, height: DockPanel.mainSize.height)
                .opacity(store.settings.docked ? 0 : 1)
                .allowsHitTesting(!store.settings.docked)
                .accessibilityHidden(store.settings.docked)
                .frame(width: store.settings.docked ? 0 : DockPanel.mainSize.width,
                       height: store.settings.docked ? 0 : DockPanel.mainSize.height)
                .clipped()
            if store.settings.docked { DockedStackView(store: store) }
        }
        .ignoresSafeArea()
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: store.settings.docked ? 12 : 18, style: .continuous))
        .tint(Color(red: 0.25, green: 0.36, blue: 0.88))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .sheet(isPresented: $showCompleted) { CompletedSheet(store: store) }
        .sheet(isPresented: $showSettings) { SettingsSheet(store: store) }
    }
}

// MARK: - Docked Stack（按类型分色的数字条，整块可点，高度自适应）

struct DockedStackView: View {
    @ObservedObject var store: Store

    private var pillData: [(Priority, Int)] {
        let counts = store.typeCounts
        return Priority.allCases.compactMap { p in
            guard let c = counts[p], c > 0 else { return nil }
            return (p, c)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Priority.allCases) { priority in
                HStack(spacing: 5) {
                    Circle().fill(priority.color).frame(width: 6, height: 6)
                    Text("\(store.typeCounts[priority] ?? 0)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor((store.typeCounts[priority] ?? 0) == 0 ? .secondary : .primary)
                }
                .frame(maxWidth: .infinity).frame(height: 20)
                .background(Color.primary.opacity(0.035), in: Capsule())
            }
        }
        .padding(6).frame(width: DockPanel.dockWidth, height: 104)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .help("双击展开任务 · 拖离边缘展开")
        .accessibilityLabel("侧边任务数量，双击展开")
        .overlay(WindowDragHandle().frame(maxWidth: .infinity, maxHeight: .infinity))
    }

}

extension DockPanel {
    func snapBackDocked() {
        guard let scr = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return }
        let vf = scr.visibleFrame
        let dl = abs(frame.minX - vf.minX)
        let dr = abs(vf.maxX - frame.maxX)
        if dl < dr { store.settings.edge = 0 } else { store.settings.edge = 1 }
        applyDockedFrame(animated: true)
    }
}

// MARK: - Filter Bar（名称搜索 + 四色筛选：默认全亮=全部，点选点亮）

struct FilterBar: View {
    @State private var showPriorityFilter = false
    @Binding var query: String
    @Binding var priorities: Set<Priority>

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索任务", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索任务")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("清除搜索")
                }
            }
            .font(.system(size: 12))
            .padding(9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            Button { showPriorityFilter.toggle() } label: {
                HStack(spacing: 5) {
                    if let priority = priorities.first {
                        RoundedRectangle(cornerRadius: 1).fill(priority.color).frame(width: 3, height: 13)
                    }
                    Text(priorities.first?.shortLabel ?? "全部")
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                }.font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain).fixedSize().help("按重要度筛选")
            .popover(isPresented: $showPriorityFilter, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("重要度筛选").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 3)
                    Button {
                        priorities = []; showPriorityFilter = false
                    } label: {
                        HStack {
                            Text("全部重要度").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(priorities.isEmpty ? 1 : 0)
                        }.padding(.horizontal, 10).frame(height: 31)
                            .background(priorities.isEmpty ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Divider().padding(.vertical, 3)
                    ForEach(Priority.allCases) { priority in
                        Button {
                            priorities = [priority]; showPriorityFilter = false
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 1).fill(priority.color).frame(width: 4, height: 17)
                                Text(priority.label).font(.system(size: 12))
                                Spacer()
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    .frame(width: 12).opacity(priorities.contains(priority) ? 1 : 0)
                            }.padding(.horizontal, 10).frame(height: 32)
                                .background(priorities.contains(priority) ? priority.color.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.buttonStyle(.plain).padding(8).frame(width: 192)
            }

        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

// Kept the component name for the single-file build; the choices now occupy one line.
struct PriorityGrid: View {
    @Binding var selection: Priority
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Priority.allCases) { priority in
                Button { selection = priority } label: {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(priority.color).frame(width: 3, height: 11)
                        Text(priority.shortLabel).font(.system(size: compact ? 9 : 10, weight: selection == priority ? .semibold : .regular)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: compact ? 22 : 27)
                    .foregroundColor(selection == priority ? .primary : .secondary)
                    .background(selection == priority ? priority.color.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection == priority ? priority.color.opacity(0.6) : .clear))
                }.buttonStyle(.plain).help(priority.label).accessibilityLabel(priority.label)
                    .accessibilityAddTraits(selection == priority ? .isSelected : [])
            }
        }
    }
}

struct TaskNotesEditor: View {
    @Binding var text: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "note.text")
                    Text("备注")
                    if !text.isEmpty && !expanded { Text(text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundColor(.secondary) }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }.font(.system(size: 11)).foregroundColor(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("展开或收起备注")
            if expanded {
                TextEditor(text: $text).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(4).frame(height: 62)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
                    .accessibilityLabel("任务备注")
            }
        }
    }
}

struct ToolbarIcon: View {
    let symbol: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundColor(.secondary).help(title).accessibilityLabel(title)
    }
}

struct FeedbackBar: View {
    @ObservedObject var store: Store
    var body: some View {
        if let error = store.saveError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundColor(.red)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07))
        } else if let message = store.statusMessage {
            HStack(spacing: 8) {
                Text(message).font(.system(size: 11)).lineLimit(2)
                Spacer(minLength: 0)
                if let entry = store.undoEntries.last {
                    Button("撤销" + entry.title) { store.undoLastAction() }
                        .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain).foregroundColor(.accentColor)
                }
                Button { store.statusMessage = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("关闭提示")
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.07))
        }
    }
}

struct CompactCalendar: View {
    @Binding var selected: Date?
    let onSelect: () -> Void
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private var offset: Int { cal.component(.weekday, from: month) - 1 }
    private var cellCount: Int { ((offset + (cal.range(of: .day, in: .month, for: month)?.count ?? 30) + 6) / 7) * 7 }
    private var currentMonth: Date { cal.date(from: cal.dateComponents([.year, .month], from: today))! }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(String(cal.component(.year, from: month)) + "年" + String(cal.component(.month, from: month)) + "月")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 23, height: 24) }
                    .disabled(month <= currentMonth).accessibilityLabel("上个月")
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 23, height: 24) }
                    .accessibilityLabel("下个月")
            }.buttonStyle(.plain)
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(["日", "一", "二", "三", "四", "五", "六"][index])
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 17)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<cellCount, id: \.self) { index in
                    dayCell(index)
                }
            }
        }
        .padding(12).frame(width: 300)
        .onAppear {
            let base = max(selected ?? today, today)
            month = cal.date(from: cal.dateComponents([.year, .month], from: base))!
        }
    }

    private func step(_ value: Int) { month = cal.date(byAdding: .month, value: value, to: month)! }

    private func dayCell(_ index: Int) -> some View {
        let day = cal.date(byAdding: .day, value: index - offset, to: month)!
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let enabled = inMonth && day >= today
        let chosen = selected.map { cal.isDate($0, inSameDayAs: day) } ?? false
        return Button {
            selected = day
            onSelect()
        } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 24)
                .foregroundColor(chosen ? .white : enabled ? .primary : .secondary.opacity(0.35))
                .background(chosen ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(cal.isDateInToday(day) && !chosen ? Color.accentColor.opacity(0.45) : .clear))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(dateFmt.string(from: day))
    }
}

struct FavoriteQuotesSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("喜欢的语录").font(.system(size: 17, weight: .semibold))
                Spacer()
                ToolbarIcon(symbol: "xmark", title: "关闭收藏语录") { dismiss() }
            }.padding(16)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.workQuotes.favorites.isEmpty {
                        Text("喜欢的句子会留在这里").font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 40)
                    }
                    ForEach(store.workQuotes.favorites, id: \.self) { value in
                        HStack(alignment: .top, spacing: 12) {
                            Text(value).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            Button { store.removeFavorite(value) } label: { Image(systemName: "heart.slash").font(.system(size: 12)) }
                                .buttonStyle(.plain).foregroundColor(.secondary).help("取消喜欢")
                        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(12)
            }
            Text("日常库 \(store.workQuotes.quotes.count)/100 · 收藏 \(store.workQuotes.favorites.count)")
                .font(.system(size: 10)).foregroundColor(.secondary).padding(12)
        }.frame(width: 368, height: 430)
    }
}

// MARK: - Due Date Picker（1天/2天/3天/本周/下周，工作日+节假日感知）

struct DueDatePicker: View {
    let holiday: HolidayService?
    @Binding var date: Date?
    var compact = false
    var showQuickChoices = true
    var showDateControl = true
    @State private var showCal = false

    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var label: String {
        date.map { dueBadgeText($0) } ?? "选择日期"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showQuickChoices {
            HStack(spacing: 5) {
                offsetChip("今天", offset: 0)
                offsetChip("明天", offset: 1)
                offsetChip("后天", offset: 2)
                quickChip("本周", target: lastWorkdayOfWeek())
                quickChip("下周", target: firstWorkdayOfNextWeek())
            }
            }
            if showDateControl {
            HStack(spacing: 4) {
                Button { showCal = true } label: {
                    Label(label, systemImage: "calendar")
                        .font(.system(size: compact ? 10 : 12, weight: .medium)).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundColor(.accentColor)
                .popover(isPresented: $showCal, arrowEdge: .bottom) {
                    CompactCalendar(selected: $date) { showCal = false }

                }
                Spacer(minLength: 0)
                if date != nil {
                    Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("清除截止日期")
                }
            }
            .padding(.vertical, compact ? 0 : 3)
            }
        }
    }

    // 本周最后一个工作日（周一~周五，剔除法定节假日）
    private func lastWorkdayOfWeek() -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let wd = cal.component(.weekday, from: today)      // 1=周日
        let toSunday = (8 - wd) % 7
        var result: Date? = nil
        for off in 0...toSunday {
            if let d = cal.date(byAdding: .day, value: off, to: today) {
                let w = cal.component(.weekday, from: d)
                if (2...6).contains(w) && holiday?.isKnownHoliday(d) != true {
                    result = d
                    holiday?.request(d)
                }
            }
        }
        return result ?? today
    }

    // 下周第一个工作日
    private func firstWorkdayOfNextWeek() -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let wd = cal.component(.weekday, from: today)
        let toSunday = (8 - wd) % 7
        guard let nextMonday = cal.date(byAdding: .day, value: toSunday + 1, to: today) else { return nil }
        for off in 0..<7 {
            if let d = cal.date(byAdding: .day, value: off, to: nextMonday) {
                let w = cal.component(.weekday, from: d)
                if (2...6).contains(w) && holiday?.isKnownHoliday(d) != true {
                    holiday?.request(d)
                    return d
                }
            }
        }
        return nextMonday
    }

    private func offsetChip(_ title: String, offset: Int) -> some View {
        let target = Calendar.current.date(byAdding: .day, value: offset, to: todayStart)
        return quickChip(title, target: target)
    }

    private func quickChip(_ title: String, target: Date?) -> some View {
        let active = date != nil && target != nil && Calendar.current.isDate(date!, inSameDayAs: target!)
        return Button {
            date = target
        } label: {
            Text(title)
                .font(.system(size: compact ? 10 : 11))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 3 : 6)
                .background(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main View

struct MainView: View {
    @ObservedObject var store: Store
    @Binding var showCompleted: Bool
    @Binding var showSettings: Bool
    @State private var showFavorites = false

    var body: some View {
        VStack(spacing: 0) {
            header
            FilterBar(query: $store.searchText, priorities: $store.filterPriorities)
            AddSection(store: store)
                .disabled(store.isReadOnly)
                .padding(.horizontal, 12).padding(.bottom, 12)
            HStack {
                Text(store.hasFilter ? "筛选结果 · \(store.activeTasks.count)" : "待办 · \(store.activeCount)")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                if store.hasFilter {
                    Button("重置筛选") { store.clearFilter() }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.accentColor)
                } else {
                    Menu {
                        Button("手动排序") { store.settings.sortMode = "manual" }
                        Button("默认排序") { store.settings.sortMode = "priority" }
                    } label: {
                        Label(store.settings.sortMode == "priority" ? "默认排序" : "手动排序", systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 10))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }.padding(.horizontal, 16).padding(.bottom, 8)
            taskList
            FeedbackBar(store: store)
            HStack(spacing: 5) {
                Image(systemName: "hand.draw")
                Text("拖动标题靠边收纳 · 任务可拖动排序")
                Spacer()
                Text("\(store.activeCount)/\(Store.maxTasks)").monospacedDigit()
            }
            .font(.system(size: 10)).foregroundColor(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(WindowDragHandle().frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        .frame(width: DockPanel.mainSize.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showFavorites) { FavoriteQuotesSheet(store: store) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(nsImage: NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")!)!)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .accessibilityLabel("任务圆点")
                    Text("TaskDots").font(.system(size: 19, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(WindowDragHandle().frame(maxWidth: .infinity, maxHeight: .infinity))
                Menu {
                    Button("书籍尺寸 · 字号对照") { store.collapseComposerRequest += 1; store.panel?.showTypography(.reference) }
                    Button("字号倍率表") { store.collapseComposerRequest += 1; store.panel?.showTypography(.scale) }
                } label: {
                    Image(systemName: "ruler").font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundColor(.secondary).help("排版小工具").accessibilityLabel("排版小工具")
                ToolbarIcon(symbol: "checkmark.circle", title: "已完成任务") { showCompleted = true }
                ToolbarIcon(symbol: "gearshape", title: "设置") { showSettings = true }
                ToolbarIcon(symbol: store.settings.edge == 0 ? "sidebar.left" : "sidebar.right", title: "收纳到屏幕侧边") { store.dockToSidebar() }
            }
            Menu {
                Button(store.workQuotes.favorites.contains(store.quote) ? "已喜欢" : "喜欢，收藏") { store.likeQuote() }
                    .disabled(store.workQuotes.favorites.contains(store.quote) || store.quoteLibraryReadOnly)
                Button("不喜欢，删除", role: .destructive) { store.dislikeQuote() }.disabled(store.quoteLibraryReadOnly)
                Divider()
                Text(store.onlineQuoteStatus)
                Button("重新联网筛选") { store.fetchOnlineQuotesIfNeeded(force: true) }
                Button("换一句") { store.nextQuote() }
                Button("喜欢的语录（\(store.workQuotes.favorites.count)）") { showFavorites = true }
            } label: {
                Text(store.quote).font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("点击喜欢或不喜欢这句打工语录")

        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 1)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if store.activeTasks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: store.hasFilter ? "magnifyingglass" : "checkmark.seal")
                            .font(.system(size: 30, weight: .light)).foregroundColor(.accentColor.opacity(0.55))
                        Text(store.hasFilter ? "没有找到相关任务" : "暂时没有待办")
                            .font(.system(size: 14, weight: .medium))
                        Text(store.hasFilter ? "试试其他关键词，或重置筛选" : "在上方写下第一件要做的事")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 36)
                } else {
                    ForEach(store.activeTasks) { task in
                        TaskRow(store: store, task: task)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TaskFramePreference.self, value: [task.id: geometry.frame(in: .named("taskList"))])
                            })
                    }
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .coordinateSpace(name: "taskList")
        .simultaneousGesture(TapGesture().onEnded { store.collapseComposerRequest += 1 })
        .onPreferenceChange(TaskFramePreference.self) { store.taskFrames = $0 }
    }
}

struct TaskFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Task Row

struct TaskRow: View {
    @ObservedObject var store: Store
    let task: TaskItem
    private var expanded: Bool { store.expandedTaskID == task.id }
    @State private var draftName = ""
    @State private var draftNotes = ""
    @State private var completeHovered = false
    @State private var nameError = false
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var dragStartFrame: CGRect?

    private var urgent: Bool { isDueToday(task) || isOverdue(task) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    store.collapseComposerRequest += 1
                    store.complete(task)
                } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(completeHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(completeHovered ? Color.accentColor : Color.primary.opacity(0.18)))
                        .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.accentColor).opacity(completeHovered ? 1 : 0).accessibilityHidden(true))
                        .frame(width: 19, height: 19).frame(width: 26, height: 29)
                }
                .onHover { completeHovered = $0 }
                .buttonStyle(.plain).help("标记完成").accessibilityLabel("完成任务：" + task.name)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top) {
                        if expanded {
                            TextField("任务名称", text: $draftName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.accentColor)
                                .onTapGesture { }
                                .onSubmit(saveName)
                                .onChange(of: draftName) { value in
                                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        _ = store.renameTask(id: task.id, name: value)
                                        nameError = false
                                    }
                                }
                        } else {
                            Button(action: toggleEditor) {
                                Text(task.name).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("编辑任务：" + task.name)
                        }
                        Button(action: toggleEditor) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold)).foregroundColor(expanded ? .accentColor : .secondary)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起任务" : "展开任务")
                    }
                    HStack(spacing: 6) {
                        Button { store.incrementRevision(id: task.id) } label: {
                            HStack(spacing: 5) {
                                Text("返修次数").font(.system(size: 10, weight: .medium))
                                Text("\(task.revisionCount)").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                            }
                            .foregroundColor(.primary.opacity(0.85))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(task.priority.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(task.priority.color.opacity(0.32)))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(store.isReadOnly)
                            .help("点击记录一次提交，返修次数加 1，绿色边框保留 4 小时")
                            .accessibilityLabel("返修次数 \(task.revisionCount)，点击加一次")
                        if let date = task.dueDate {
                            Text(dueBadgeText(date)).font(.system(size: 10, weight: .medium))
                                .foregroundColor(urgent ? .red : Color.primary.opacity(0.7))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(task.priority.color.opacity(urgent ? 0.16 : 0.10), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if task.notes != nil { Image(systemName: "note.text").font(.system(size: 10)).foregroundColor(.secondary).help("有备注") }
                        if task.dueDate != nil && (0...2).contains(task.remindOffsetDays ?? -1) {
                            Image(systemName: "bell").font(.system(size: 10)).foregroundColor(.secondary).help(remindText(task))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleEditor)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 16, height: 30).contentShape(Rectangle())
                    .help("拖动调整位置").accessibilityLabel("拖动调整任务位置")
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("taskList"))
                        .updating($dragTranslation) { value, state, _ in state = value.translation.height }
                        .onChanged { _ in
                            if dragStartFrame == nil { dragStartFrame = store.taskFrames[task.id] }
                            store.draggedTaskID = task.id
                        }
                        .onEnded { value in
                            if let frame = dragStartFrame, value.location.y < frame.minY || value.location.y > frame.maxY {
                                withAnimation(.easeInOut(duration: 0.15)) { store.moveTaskToY(id: task.id, y: value.location.y) }
                            }
                            dragStartFrame = nil
                            store.draggedTaskID = nil
                        })

            }.padding(.horizontal, 10).padding(.vertical, 7)
            .overlay {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if task.showsSubmissionBorder(at: Date()) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(red: 0.46, green: 0.73, blue: 0.08),
                                      style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 3]))
                        .padding(.leading, 38)
                        .padding(.trailing, 2).padding(.vertical, 2)
                }
            }.allowsHitTesting(false)
            }

            if expanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    if nameError { Text("任务名称不能为空").font(.system(size: 11)).foregroundColor(.red) }
                    TaskNotesEditor(text: $draftNotes)
                        .onChange(of: draftNotes) { store.updateNotes(id: task.id, notes: $0) }
                    PriorityGrid(selection: Binding(get: { task.priority }, set: { value in
                        store.editTask(id: task.id) { $0.priority = value }
                    }), compact: true)
                    DueDatePicker(holiday: store.holiday, date: Binding(get: { task.dueDate }, set: { value in
                        store.editTask(id: task.id, resetReminder: true) {
                            $0.dueDate = value
                            if value == nil { $0.remindOffsetDays = nil }
                        }
                    }), compact: true, showDateControl: false)
                    HStack(spacing: 7) {
                        DueDatePicker(holiday: store.holiday, date: Binding(get: { task.dueDate }, set: { value in
                            store.editTask(id: task.id, resetReminder: true) {
                                $0.dueDate = value
                                if value == nil { $0.remindOffsetDays = nil }
                            }
                        }), compact: true, showQuickChoices: false)
                        Image(systemName: "bell").font(.system(size: 10)).foregroundColor(.secondary).help("提醒")
                        Picker("提醒方式", selection: Binding(get: { task.remindOffsetDays ?? -1 }, set: { value in
                            store.editTask(id: task.id, resetReminder: true) { $0.remindOffsetDays = value >= 0 ? value : nil }
                        })) {
                            Text("不提醒").tag(-1)
                            Text("当天").tag(0)
                            Text("提前1天").tag(1)
                            Text("提前2天").tag(2)
                        }.labelsHidden().controlSize(.small).font(.system(size: 10)).frame(width: 96).disabled(task.dueDate == nil)
                        Button(role: .destructive) { store.delete(task) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).frame(width: 20, height: 22)
                        }.buttonStyle(.plain).foregroundColor(.red).help("删除任务（可撤销）").accessibilityLabel("删除任务")
                    }
                }.padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) { task.priority.color.frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(expanded ? 0.12 : 0.05))

        }
        .offset(y: dragTranslation)
        .zIndex(dragTranslation == 0 ? 0 : 1)
        .shadow(color: .black.opacity(dragTranslation == 0 ? 0 : 0.12), radius: 5)
        .contextMenu {
            Button("置顶") { store.shiftTask(id: task.id, by: -Store.maxTasks) }
            Button("上移") { store.shiftTask(id: task.id, by: -1) }
            Button("下移") { store.shiftTask(id: task.id, by: 1) }
            Divider()
            Button("标记完成") { store.complete(task) }
        }

    }

    private func toggleEditor() {
        store.collapseComposerRequest += 1
        if expanded { saveName() }
        else { draftName = task.name; draftNotes = task.notes ?? ""; nameError = false }
        withAnimation(.easeInOut(duration: 0.16)) {
            store.expandedTaskID = expanded ? nil : task.id
        }
    }

    private func saveName() {
        nameError = !store.renameTask(id: task.id, name: draftName)
        if !nameError { draftName = draftName.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

// MARK: - Add Section

struct AddSection: View {
    @ObservedObject var store: Store
    @State private var name = ""
    @State private var notes = ""
    @State private var priority: Priority = .importantNotUrgent
    @State private var due: Date?
    @State private var showDetails = false
    @State private var editorOpen = false
    @State private var offset = -1
    @State private var errMsg: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("接下来要做什么？", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($nameFocused)
                    .onSubmit(add).accessibilityLabel("新任务名称")
                    .onChange(of: store.settings.docked) { docked in
                        if docked { nameFocused = false }
                    }
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 29, height: 29)
                        .foregroundColor(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("添加任务（回车）").accessibilityLabel("添加任务")
            }
            if editorOpen {
            HStack {
                Text("新建任务").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("取消") { cancelDraft() }.font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.secondary)
                Button { editorOpen = false; showDetails = false; nameFocused = false } label: {
                    Image(systemName: "chevron.up").frame(width: 24, height: 20)
                }.buttonStyle(.plain).help("收起填写区域")
            }
            PriorityGrid(selection: $priority)
            TaskNotesEditor(text: $notes)
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                } label: {
                    Label(due.map { dueBadgeText($0) + "截止" } ?? "添加截止日期", systemImage: "calendar.badge.plus")
                        .font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(due == nil ? .secondary : .accentColor)
                Spacer()
                if store.activeCount >= Store.maxTasks {
                    Text("待办已满").font(.system(size: 11)).foregroundColor(.orange)
                } else {
                    Text("回车添加").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            if showDetails {
                Divider()
                DueDatePicker(holiday: store.holiday, date: $due)
                HStack {
                    Text("提醒").font(.system(size: 11)).foregroundColor(.secondary)
                    Picker("提醒方式", selection: $offset) {
                        Text("不提醒").tag(-1)
                        Text("当天").tag(0)
                        Text("提前1天").tag(1)
                        Text("提前2天").tag(2)
                    }.labelsHidden().frame(width: 150).disabled(due == nil)
                    Spacer()
                }
            }
            if let error = errMsg { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.12)))
        .onChange(of: nameFocused) { focused in if focused { editorOpen = true } }
        .onChange(of: store.collapseComposerRequest) { _ in
            guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            editorOpen = false; showDetails = false; errMsg = nil; nameFocused = false
        }
        .onExitCommand { cancelDraft() }
        .onChange(of: store.focusRequest) { _ in editorOpen = true; nameFocused = true }
        .onAppear { if store.focusRequest > 0 { nameFocused = true } }
    }

    private func cancelDraft() {
        name = ""; notes = ""; due = nil; offset = -1; errMsg = nil
        showDetails = false; editorOpen = false; nameFocused = false
    }

    private func add() {
        editorOpen = true
        errMsg = nil
        let ok = store.addTask(name: name, priority: priority, due: due, offset: offset, notes: notes)
        if ok {
            name = ""
            notes = ""
            due = nil
            offset = -1
            showDetails = false
            nameFocused = true
            if store.hasFilter { store.clearFilter() }
            store.statusMessage = "已添加任务"
        } else {
            errMsg = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "先写下任务名称" : "待办已达 \(Store.maxTasks) 条，请先完成部分任务"
            nameFocused = true
        }
    }
}

// MARK: - Completed Sheet

struct CompletedSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var priorities: Set<Priority> = []

    private var filtered: [TaskItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.tasks.filter { $0.isDone && (clean.isEmpty || $0.name.localizedCaseInsensitiveContains(clean)) && (priorities.isEmpty || priorities.contains($0.priority)) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已完成").font(.system(size: 19, weight: .bold))
                    Text("记录每一件做完的事").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                ToolbarIcon(symbol: "xmark", title: "关闭已完成任务") { dismiss() }
            }.padding(16)
            FilterBar(query: $query, priorities: $priorities)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundColor(.secondary)
                            Text("没有符合条件的完成记录").font(.system(size: 12)).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        ForEach(filtered) { task in CompletedRow(store: store, task: task) }
                    }
                }.padding(12)
            }
            FeedbackBar(store: store)
        }
        .frame(width: 368, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CompletedRow: View {
    @ObservedObject var store: Store
    let task: TaskItem
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(task.priority.color)
                Text(task.name).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle()).onTapGesture { expanded.toggle() }
            if expanded {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.priority.label + " · " + remindText(task))
                if let notes = task.notes { Text(notes).fixedSize(horizontal: false, vertical: true) }
                Text("创建 " + dateTimeFmt.string(from: task.createdAt))
                if let date = task.completedAt { Text("完成 " + dateTimeFmt.string(from: date)) }
                if let date = task.dueDate { Text("原截止 " + dateTimeFmt.string(from: date)) }
            }.font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Button { _ = store.duplicateFromCompleted(task) } label: {
                    Label("再做一次", systemImage: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.bordered).help("复制到待办，过期的截止日期会清除")
                Spacer()
                Button(role: .destructive) { store.delete(task) } label: {
                    Image(systemName: "trash").frame(width: 28, height: 28)
                }.buttonStyle(.plain).foregroundColor(.secondary).help("删除记录（可撤销）").accessibilityLabel("删除完成记录")
            }
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var rname = ""
    @State private var kind: RuleKind = .workdays
    @State private var reminderEditID: UUID?
    @State private var rhour = 10
    @State private var rminute = 0
    @State private var monthlyWeekday = 5
    @State private var weeklyDays: Set<Int> = [2]
    @State private var loginErrMsg: String?
    @State private var ruleError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox {
                        Toggle("开机自动启动", isOn: Binding(
                            get: { store.settings.launchAtLogin },
                            set: { on in
                                guard !store.isReadOnly else { return }
                                let ok = LaunchLogin.set(on)
                                store.settings.launchAtLogin = ok ? on : false
                                loginErrMsg = ok ? nil : "设置开机启动失败，请手动操作"
                            }))
                        .font(.system(size: 12))
                        if let e = loginErrMsg {
                            Text(e).font(.system(size: 11)).foregroundColor(.red)
                        }
                    }
                    .frame(width: 328)

                    GroupBox("截止任务提醒") {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("工作日提醒时间").font(.system(size: 12))
                                Spacer()
                                Picker("提醒时间", selection: Binding(get: { store.settings.reminderHour }, set: { value in
                                    store.settings.reminderHour = value
                                })) {
                                    ForEach(10...16, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                                }.labelsHidden().frame(width: 100).disabled(store.isReadOnly)
                            }
                            Text("系统通知横幅＋提示音；仅周一至周五 10:00–16:00 发送截止提醒。周末顺延周一，错过时间会在下个允许时段补发。")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Text("请保持应用运行，并在系统设置中允许 TaskDots 通知；横幅是否显示、声音及专注模式由 macOS 控制。")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }.padding(4)
                    }.frame(width: 328)
                    Text("日常提醒").font(.system(size: 12, weight: .semibold))
                    Text("默认工作日 10:00，可修改名称、周期与时间。每天/每周规则遵循所选日期，通知只在 10:00–16:00 发出。每月节假日提前仍依赖缓存。")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    ForEach(store.rules) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.system(size: 12, weight: .medium))
                                Text(scheduleText(r)).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("修改") { editRule(r) }.buttonStyle(.plain).foregroundColor(.accentColor)
                            Button {
                                store.deleteRule(r)
                                if reminderEditID == r.id { cancelRuleEdit() }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(7)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    GroupBox {
                        VStack(spacing: 7) {
                            TextField("提醒名称（如：写周报）", text: $rname)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(5)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(6)
                            HStack {
                                Picker("", selection: $kind) {
                                    ForEach(RuleKind.allCases) { k in Text(k.rawValue).tag(k) }
                                }
                                .labelsHidden()
                                .font(.system(size: 11))
                                .frame(width: 104)
                                Picker("小时", selection: $rhour) {
                                    ForEach(10...16, id: \.self) { h in Text(String(format: "%02d", h)).tag(h) }
                                }.labelsHidden().frame(width: 65)
                                Text(":")
                                Picker("分钟", selection: $rminute) {
                                    ForEach(rhour == 16 ? [0] : Array(Set([0, 15, 30, 45, rminute])).sorted(), id: \.self) { m in
                                        Text(String(format: "%02d", m)).tag(m)
                                    }
                                }.labelsHidden().frame(width: 65)
                                .onChange(of: rhour) { value in if value == 16 { rminute = 0 } }
                                    
                            }
                            if kind == .weekly {
                                HStack(spacing: 4) {
                                    ForEach(1...7, id: \.self) { d in
                                        let on = weeklyDays.contains(d)
                                        Button {
                                            if on { weeklyDays.remove(d) } else { weeklyDays.insert(d) }
                                        } label: {
                                            Text(weekdayName(d))
                                                .font(.system(size: 11))
                                                .frame(width: 20, height: 20)
                                                .background(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                                                .cornerRadius(5)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if kind == .monthlyLast {
                                Picker("星期", selection: $monthlyWeekday) {
                                    ForEach(1...7, id: \.self) { d in
                                        Text("周" + weekdayName(d)).tag(d)
                                    }
                                }
                                .font(.system(size: 11))
                                .labelsHidden()
                            }
                            if let error = ruleError { Text(error).font(.system(size: 11)).foregroundColor(.red) }
                            Button(action: addRule) {
                                Label(reminderEditID == nil ? "添加日常提醒" : "保存修改", systemImage: reminderEditID == nil ? "plus" : "checkmark")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isReadOnly)
                            if reminderEditID != nil {
                                Button("取消修改") { cancelRuleEdit() }.buttonStyle(.plain).foregroundColor(.secondary)
                            }
                        }
                        .padding(4)
                    }
                    .frame(width: 328)

                    Text("关于").font(.system(size: 12, weight: .semibold))
                    GroupBox {
                        VStack(spacing: 8) {
                            Button {
                                openDesignDoc()
                            } label: {
                                Label("查看设计文档", systemImage: "doc.text")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            Button {
                                NSWorkspace.shared.open(FileManager.default.urls(
                                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                    .appendingPathComponent("TaskDots", isDirectory: true))
                            } label: {
                                Label("打开数据文件夹", systemImage: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            Text("TaskDots v1.8 · 数据：~/Library/Application Support/TaskDots/")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        .padding(4)
                    }
                    .frame(width: 328)

                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("退出 TaskDots", systemImage: "power")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red.opacity(0.85))
                    .padding(.bottom, 14)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }
        }
        .frame(width: 368, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func editRule(_ rule: RecurRule) {
        reminderEditID = rule.id
        rname = rule.name
        kind = rule.kind
        rhour = min(16, max(10, rule.hour))
        rminute = rhour == 16 ? 0 : rule.minute
        monthlyWeekday = rule.weekday
        weeklyDays = rule.weekdays
        ruleError = nil
    }

    private func cancelRuleEdit() {
        reminderEditID = nil; rname = ""; rhour = 10; rminute = 0
        kind = .workdays; weeklyDays = [2]; monthlyWeekday = 5; ruleError = nil
    }

    private func addRule() {
        let clean = rname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { ruleError = "请输入提醒名称"; return }
        guard kind != .weekly || !weeklyDays.isEmpty else { ruleError = "请至少选择一个星期"; return }
        var rule = RecurRule(name: clean, kind: kind, hour: rhour, minute: rhour == 16 ? 0 : rminute)
        rule.weekdays = weeklyDays
        rule.weekday = monthlyWeekday
        if let id = reminderEditID {
            rule.id = id
            store.updateRule(rule)
        } else {
            store.addRule(rule)
        }
        cancelRuleEdit()
    }

}

extension SettingsSheet {
    /// 打开打包在 App 内的设计文档（浏览器渲染）
    fileprivate func openDesignDoc() {
        if let url = Bundle.main.url(forResource: "设计文档", withExtension: "html") {
            NSWorkspace.shared.open(url)
        } else {
            // 兜底：源码目录下的设计文档
            let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WorkBuddy/2026-10-26-10-08-12/TaskDots/设计文档.html")
            NSWorkspace.shared.open(p)
        }
    }
}

// MARK: - Compact typography tools

enum TypographyTool: String, CaseIterable, Identifiable {
    case reference = "尺寸 · 字号"
    case scale = "字号倍率"
    var id: String { rawValue }
}

final class TypographyToolModel: ObservableObject {
    @Published var tool: TypographyTool
    init(_ tool: TypographyTool) { self.tool = tool }
}

enum TypeScale {
    static let multipliers = (11...20).map { Double($0) / 10 }
    static let baseSizes = Array(Set((2...86).map(Double.init) + [5.5, 6.5, 7.5, 10.5])).sorted()
    static func result(base: Double, multiplier: Double) -> Double? {
        guard base.isFinite, multiplier.isFinite, base > 0, multiplier > 0 else { return nil }
        let scaled = base * multiplier * 100
        guard scaled.isFinite else { return nil }
        return scaled.rounded() / 100
    }
    static func text(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }
}

final class TypographyPanel: NSPanel {
    static let panelWidth: CGFloat = 352
    static let panelHeight: CGFloat = 536
    let model: TypographyToolModel
    init(tool: TypographyTool) {
        model = TypographyToolModel(tool)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "TaskDots 排版小工具"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: TypographyToolsView(model: model, onClose: { [weak self] in self?.orderOut(nil) }))
    }
    override var canBecomeKey: Bool { true }
}

extension DockPanel {
    func showTypography(_ tool: TypographyTool) {
        if typographyPanel == nil { typographyPanel = TypographyPanel(tool: tool) }
        guard let helper = typographyPanel, let screen = currentScreen else { return }
        helper.model.tool = tool
        let visible = screen.visibleFrame
        let width = TypographyPanel.panelWidth
        let height = min(TypographyPanel.panelHeight, visible.height - 16)
        // Make room on the left only when opening the helper, never during dragging.
        if frame.minX - width - 12 < visible.minX + 8 {
            let x = min(visible.maxX - frame.width - 8, visible.minX + width + 20)
            setFrameOrigin(NSPoint(x: x, y: frame.minY))
            var saved = store.settings
            saved.lastX = frame.minX
            saved.lastY = frame.minY
            store.settings = saved
        }
        let x = max(visible.minX + 8, frame.minX - width - 12)
        let y = max(visible.minY + 8, min(visible.maxY - height - 8, frame.maxY - height))
        helper.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        helper.makeKeyAndOrderFront(nil)
    }
}

struct TypographyToolsView: View {
    @ObservedObject var model: TypographyToolModel
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("排版小工具", systemImage: "ruler").font(.system(size: 15, weight: .semibold))
                Spacer()
                ToolbarIcon(symbol: "xmark", title: "关闭排版小工具", action: onClose)
            }
            Picker("工具", selection: $model.tool) {
                ForEach(TypographyTool.allCases) { tool in Text(tool.rawValue).tag(tool) }
            }.pickerStyle(.segmented).labelsHidden()
            if model.tool == .reference { BookTypeReferenceView() }
            else { TypeScaleView() }
        }
        .padding(14).frame(width: TypographyPanel.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .tint(Color(red: 0.25, green: 0.36, blue: 0.88))
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onExitCommand(perform: onClose)
    }
}

struct BookFormatGroup {
    let title: String
    let rows: [(String, String)]
}

enum TypographyReference {
    // Transcribed from the user's image. Distinct source groups are preserved even where names repeat.
    static let books = [
        BookFormatGroup(title: "大开本", rows: [("大4开", "420 × 570"), ("大8开", "285 × 420"), ("大16开", "210 × 285"), ("大32开", "140 × 203")]),
        BookFormatGroup(title: "正度", rows: [("4开", "370 × 520"), ("8开", "260 × 370"), ("16开", "185 × 260"), ("32开", "130 × 185"), ("64开", "92 × 185")]),
        BookFormatGroup(title: "另一组常见尺寸", rows: [("大16开", "210 × 297"), ("大32开", "148 × 210"), ("大64开", "105 × 144")]),
        BookFormatGroup(title: "常用异形", rows: [("异形", "170 × 240"), ("异形", "170 × 230")])
    ]
    static let fonts: [(String, Double)] = [("初号", 42), ("小初", 36), ("一号", 26), ("小一", 24), ("二号", 22), ("小二", 18), ("三号", 16), ("小三", 15), ("四号", 14), ("小四", 12), ("五号", 10.5), ("小五", 9), ("六号", 7.5), ("小六", 6.5), ("七号", 5.5), ("八号", 5)]
}

enum ClipboardCopy {
    @discardableResult static func write(_ value: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(value, forType: .string)
    }
}

struct BookTypeReferenceView: View {
    @State private var copyFeedback = "点击尺寸或磅数复制；右键可单独复制宽、高。"
    private func copy(_ value: String) {
        copyFeedback = ClipboardCopy.write(value) ? "已复制：" + value : "复制失败，请重试"
    }
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("成品尺寸 · mm").font(.system(size: 11, weight: .semibold)).padding(.bottom, 3)
                    ForEach(TypographyReference.books.indices, id: \.self) { index in
                        let group = TypographyReference.books[index]
                        Text(group.title).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            .padding(.top, index == 0 ? 1 : 6).padding(.bottom, 2)
                        ForEach(group.rows.indices, id: \.self) { row in
                            let item = group.rows[row]
                            let parts = item.1.components(separatedBy: "×").map { $0.trimmingCharacters(in: .whitespaces) }
                            Button { copy(item.1) } label: {
                                HStack(spacing: 4) {
                                    Text(item.0).frame(width: 48, alignment: .leading)
                                    Text(item.1).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                                }.font(.system(size: 11)).padding(.horizontal, 4).frame(height: 19)
                                    .background(row % 2 == 0 ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help("点击复制尺寸；右键复制宽、高")
                                .accessibilityLabel("复制 " + item.0 + " " + item.1)
                                .contextMenu {
                                    Button("复制尺寸") { copy(item.1) }
                                    if parts.count == 2 {
                                        Button("复制宽度：" + parts[0]) { copy(parts[0]) }
                                        Button("复制高度：" + parts[1]) { copy(parts[1]) }
                                    }
                                }
                        }
                    }
                }.frame(width: 188)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 374)
                VStack(spacing: 1) {
                    HStack { Text("字号"); Spacer(); Text("pt") }
                        .font(.system(size: 11, weight: .semibold)).padding(.bottom, 3)
                    ForEach(TypographyReference.fonts.indices, id: \.self) { index in
                        let font = TypographyReference.fonts[index]
                        Button { copy(TypeScale.text(font.1)) } label: {
                            HStack { Text(font.0); Spacer(); Text(TypeScale.text(font.1)).monospacedDigit() }
                                .font(.system(size: 11)).padding(.horizontal, 4).frame(height: 19)
                                .background(index % 2 == 0 ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help("复制磅数").accessibilityLabel("复制 " + font.0 + " " + TypeScale.text(font.1) + " 磅")
                    }
                }.frame(width: 92)
            }.padding(.horizontal, 2)
        }
        Text(copyFeedback).font(.system(size: 10)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
    }
}

struct TypeScaleView: View {
    @AppStorage("TaskDotsTypographyMultiplier") private var storedMultiplier = 1.5
    @State private var multiplierInput = ""
    @AppStorage("TaskDotsTypographyBaseInput") private var baseInput = "12"
    @State private var copyFeedback = ""
    private var base: Double? { Double(baseInput.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var multiplier: Double? {
        guard let value = Double(multiplierInput.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value > 0 else { return nil }
        return value
    }
    private var result: Double? {
        guard let base, let multiplier else { return nil }
        return TypeScale.result(base: base, multiplier: multiplier)
    }
    private func copy(_ value: Double) {
        let text = TypeScale.text(value)
        copyFeedback = ClipboardCopy.write(text) ? "已复制 " + text : "复制失败"
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("原字号 · pt").font(.system(size: 10)).foregroundColor(.secondary)
                    TextField("例如 12", text: $baseInput).textFieldStyle(.roundedBorder).accessibilityLabel("原字号")
                }
                Image(systemName: "multiply").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 16)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("倍率").font(.system(size: 10)).foregroundColor(.secondary)
                        Spacer()
                        Menu("常用") {
                            ForEach(TypeScale.multipliers, id: \.self) { value in
                                Button(String(format: "× %.1f", value)) { multiplierInput = String(format: "%.1f", value) }
                            }
                        }.font(.system(size: 10)).menuStyle(.borderlessButton).fixedSize()
                    }
                    TextField("例如 1.6", text: $multiplierInput).textFieldStyle(.roundedBorder).accessibilityLabel("输入倍率")
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("换算结果").font(.system(size: 10)).foregroundColor(.secondary)
                    if let result {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(TypeScale.text(result)).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("pt").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    } else { Text("请输入有效数字").font(.system(size: 12)).foregroundColor(.secondary) }
                }
                Spacer()
                Button { if let result { copy(result) } } label: { Label("复制", systemImage: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.bordered).disabled(result == nil)
            }.padding(10).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack(alignment: .top, spacing: 8) {
                Text(copyFeedback.isEmpty ? "原字号 × 倍率。例如 12pt × 1.6 = 19.2pt，可作字号缩放或倍数行距换算。" : copyFeedback)
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if let url = Bundle.main.url(forResource: "字号倍率表", withExtension: "pdf") { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "doc.text").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("打开原始倍率表")
                    .accessibilityLabel("打开原始倍率表")
                    .disabled(Bundle.main.url(forResource: "字号倍率表", withExtension: "pdf") == nil)
            }
            HStack {
                Text("原字号 · pt")
                Spacer()
                Text("换算后 · pt")
            }.font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 6)
            ScrollView {
                LazyVStack(spacing: 1) {
                    if let multiplier {
                        ForEach(TypeScale.baseSizes, id: \.self) { value in
                            if let output = TypeScale.result(base: value, multiplier: multiplier) {
                                Button { copy(output) } label: {
                                    HStack { Text(TypeScale.text(value)); Spacer(); Text(TypeScale.text(output)).fontWeight(.medium) }
                                        .font(.system(size: 12)).monospacedDigit().padding(.horizontal, 10).frame(height: 25)
                                        .background(base == value ? Color.accentColor.opacity(0.09) : Color.primary.opacity(Int(value) % 2 == 0 ? 0.025 : 0), in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help("点击复制换算结果")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { multiplierInput = String(storedMultiplier) }
        .onChange(of: multiplierInput) { _ in
            if let multiplier { storedMultiplier = multiplier }
            copyFeedback = ""
        }
        .onChange(of: baseInput) { _ in copyFeedback = "" }
    }
}

// MARK: - App Entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store!
    var panel: DockPanel!
    var engine: ReminderEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()
        store = Store()
        LaunchLogin.migrateLegacyAgent(enabled: store.settings.launchAtLogin)
        panel = DockPanel(store: store)
        panel.orderFrontRegardless()
        engine = ReminderEngine(store: store)
        engine.start()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func newTask() {
        if store.settings.docked { panel.undock() }
        panel.makeKeyAndOrderFront(nil)
        store.focusRequest += 1
    }

    func applicationWillTerminate(_ notification: Notification) { store?.save() }

    /// 编辑菜单：让输入框支持 Cmd+V 粘贴 / Cmd+C 拷贝 / Cmd+A 全选
    private func setupMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "新建任务", action: #selector(newTask), keyEquivalent: "n")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TaskDots",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
