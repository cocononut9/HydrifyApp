//
//  HydraApp.swift
//  iOS 16+/SwiftUI 单文件可运行示例
//
//  功能点：
//  - 多模态采集（时间+量 / 仅量长按 / 仅时间待补）
//  - 杯型预设 + 动态排序（最近使用 + 使用次数）
//  - 进度跑道（应到 vs 实际） + 建议一杯量
//  - 巨大💧按钮 → 下拉面板（快捷量/滑杆/时间偏移/仅时间）
//  - 最近 3 条记录（撤销 + 待补量快捷补）
//  - UserDefaults 持久化（轻量）
//
//  说明：为了便于你“直接跑”，我把所有内容放在一个文件里，并加了详细注释。
//  上线前建议按 Model/Views/Components 拆分、补单测与无障碍细节。
//

import SwiftUI

// MARK: - 数据模型

/// 一条喝水记录：可只有时间（待补量）或时间+量
struct DrinkEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var timestamp: Date
    var amountML: Double?   // nil 表示“仅时间，待补量”
    var presetID: UUID?     // 记录来自哪个杯型预设（用于统计/排序）

    init(id: UUID = UUID(), timestamp: Date, amountML: Double?, presetID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.amountML = amountML
        self.presetID = presetID
    }

    /// 是否待补量
    var isPending: Bool { amountML == nil }
}

/// 杯型预设（容量+标签），带“使用次数/最近使用时间”方便动态排序
struct CupPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var amountML: Double
    var iced: Bool
    var warm: Bool
    var usageCount: Int
    var lastUsedAt: Date?

    init(id: UUID = UUID(), name: String, amountML: Double, iced: Bool = false, warm: Bool = false, usageCount: Int = 0, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.amountML = amountML
        self.iced = iced
        self.warm = warm
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
    }
}

/// 用户偏好：每日目标 & 活跃时段（用于“应到进度”）
struct UserPrefs: Codable {
    var dailyGoalML: Double = 2000
    var dayStartHour: Int = 8   // 起床时间（用于进度跑道起点）
    var dayEndHour: Int = 22    // 就寝时间（用于进度跑道终点）
    var quickAmountsML: [Double] = [200, 300, 500] // 备用：若没杯型预设可直接显示
}

// MARK: - ViewModel

final class DrinkModel: ObservableObject {
    // 公共状态
    @Published var entries: [DrinkEntry] = [] { didSet { save() } }
    @Published var presets: [CupPreset] = [] { didSet { save() } }
    @Published var prefs: UserPrefs = .init() { didSet { save() } }

    // 撤销支持：记住“最近一次新增的记录 id”
    @Published var lastAddedID: UUID? = nil
    @Published var showUndoBanner: Bool = false

    private let keyEntries = "hydra.entries.v1"
    private let keyPresets = "hydra.presets.v1"
    private let keyPrefs = "hydra.prefs.v1"

    init() {
        load()
        seedIfNeeded()
    }

    // MARK: CRUD

    /// 添加记录（可传 amount=nil 代表“仅时间”）
    @discardableResult
    func add(amountML: Double?, at date: Date = Date(), presetID: UUID? = nil) -> DrinkEntry {
        let entry = DrinkEntry(timestamp: date, amountML: amountML, presetID: presetID)
        entries.insert(entry, at: 0) // 倒序显示：新记录置顶
        lastAddedID = entry.id
        showUndoBanner = true

        // 更新预设统计（用于动态排序）
        if let pid = presetID, let idx = presets.firstIndex(where: { $0.id == pid }) {
            presets[idx].usageCount += 1
            presets[idx].lastUsedAt = Date()
        }
        return entry
    }

    /// 删除记录
    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// 撤销最近一次新增
    func undoLastAdd() {
        guard let id = lastAddedID else { return }
        remove(id: id)
        lastAddedID = nil
        showUndoBanner = false
    }

    /// 为“待补量”的记录补上容量
    func fillAmount(for id: UUID, amountML: Double) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].amountML = amountML
    }

    // MARK: 统计 & 进度

    /// 今日已喝（毫升）
    func consumedTodayML(now: Date = Date()) -> Double {
        let cal = Calendar.current
        return entries
            .filter { cal.isDate($0.timestamp, inSameDayAs: now) }
            .compactMap { $0.amountML }
            .reduce(0, +)
    }

    /// 截止当前时间，按“起床-就寝”的活动时段线性分布，计算“应到喝水量”
    func expectedByNowML(now: Date = Date()) -> Double {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: prefs.dayStartHour, minute: 0, second: 0, of: now)!
        let end = cal.date(bySettingHour: prefs.dayEndHour, minute: 0, second: 0, of: now)!
        guard now >= start else { return 0 }
        guard now <= end else { return prefs.dailyGoalML }
        let total = end.timeIntervalSince(start)
        let elapsed = now.timeIntervalSince(start)
        let ratio = max(0, min(1, elapsed / total))
        return prefs.dailyGoalML * ratio
    }

    /// 建议一杯量：剩余的 1/3，四舍五入到 50 ml（最小 150，最大 500）
    func suggestedSipML(now: Date = Date()) -> Double {
        let remaining = max(0, prefs.dailyGoalML - consumedTodayML(now: now))
        let raw = max(150, min(500, remaining / 3))
        // 四舍五入到 50 的倍数
        let stepped = (raw / 50).rounded() * 50
        return stepped
    }

    /// 过去 3 条（用于底部“最近”）
    var recentThree: [DrinkEntry] { Array(entries.prefix(3)) }

    /// 按“最近使用优先 + 使用次数其次”对预设排序
    var sortedPresets: [CupPreset] {
        presets.sorted {
            switch ($0.lastUsedAt, $1.lastUsedAt) {
            case let (a?, b?): return a > b   // 最近使用优先
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return $0.usageCount > $1.usageCount // 次级：使用次数
            }
        }
    }

    // MARK: 持久化（UserDefaults 简易存储）

    private func save() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(entries)  { UserDefaults.standard.set(d, forKey: keyEntries) }
        if let d = try? enc.encode(presets)  { UserDefaults.standard.set(d, forKey: keyPresets) }
        if let d = try? enc.encode(prefs)    { UserDefaults.standard.set(d, forKey: keyPrefs) }
    }

    private func load() {
        let dec = JSONDecoder()
        if let d = UserDefaults.standard.data(forKey: keyEntries),
           let arr = try? dec.decode([DrinkEntry].self, from: d) { entries = arr }
        if let d = UserDefaults.standard.data(forKey: keyPresets),
           let arr = try? dec.decode([CupPreset].self, from: d)  { presets = arr }
        if let d = UserDefaults.standard.data(forKey: keyPrefs),
           let val = try? dec.decode(UserPrefs.self, from: d)    { prefs = val }
    }

    /// 首次启动：播种几个预设
    private func seedIfNeeded() {
        if presets.isEmpty {
            presets = [
                CupPreset(name: "纸杯", amountML: 200, iced: false, warm: true),
                CupPreset(name: "矿泉水瓶", amountML: 300),
                CupPreset(name: "运动水壶", amountML: 500, iced: true)
            ]
        }
    }
}

// MARK: - App 入口

@main
struct HydraApp: App {
    @StateObject private var model = DrinkModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack { TodayView() }
                .environmentObject(model)
        }
    }
}

// MARK: - Tab1｜今天

struct TodayView: View {
    @EnvironmentObject var model: DrinkModel
    @State private var now = Date()
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 16) {
            // 顶部：进度跑道
            ProgressLane(now: now)
                .environmentObject(model)
                .padding(.top, 8)

            // 中部：巨大 💧 按钮
            Spacer(minLength: 24)
            Button {
                showSheet = true
            } label: {
                Text("💧")
                    .font(.system(size: 140))
                    .shadow(radius: 8)
                    .padding(20)
                    .contentShape(Circle())
                    .accessibilityLabel("记录一杯水")
            }
            .buttonStyle(.plain)

            // 建议一杯
            Text("建议一杯：\(Int(model.suggestedSipML())) ml")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            // 底部：最近 3 条 + 撤销
            RecentEntriesSection()
                .environmentObject(model)
        }
        .padding(.horizontal)
        .navigationTitle("今天")
        .sheet(isPresented: $showSheet) {
            QuickLogSheet(dismiss: { showSheet = false })
                .environmentObject(model)
                .presentationDetents([.height(420), .large])
        }
        .onAppear {
            // 每 10 秒刷新一次“应到/已喝/建议一杯”
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                now = Date()
            }
        }
        .overlay(alignment: .bottom) {
            if model.showUndoBanner {
                UndoBanner()
                    .environmentObject(model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.showUndoBanner)
    }
}

// MARK: 进度跑道（应到 vs 实际）

struct ProgressLane: View {
    @EnvironmentObject var model: DrinkModel
    var now: Date

    var body: some View {
        let consumed = model.consumedTodayML(now: now)
        let expected = model.expectedByNowML(now: now)
        let goal = model.prefs.dailyGoalML

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日目标：\(Int(goal)) ml")
                    .font(.headline)
                Spacer()
                Text("已喝：\(Int(consumed)) ml")
                    .foregroundStyle(.primary)
            }
            // 背景条（目标）
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.2))
                    .frame(height: 12)
                // 应到进度（淡色）
                Capsule().fill(Color.blue.opacity(0.25))
                    .frame(width: max(0, min(1, expected / goal)) * UIScreen.main.bounds.width * 0.86, height: 12)
                // 实际进度（实色）
                Capsule().fill(Color.blue)
                    .frame(width: max(0, min(1, consumed / goal)) * UIScreen.main.bounds.width * 0.86, height: 12)
            }
            .clipShape(Capsule())

            HStack {
                Text("应到：\(Int(expected)) ml")
                    .foregroundStyle(.secondary)
                Spacer()
                let diff = Int(consumed - expected)
                Text(diff >= 0 ? "超前 \(diff) ml" : "落后 \(abs(diff)) ml")
                    .foregroundStyle(diff >= 0 ? .green : .orange)
            }
            .font(.footnote.monospacedDigit())
        }
    }
}

// MARK: 快速记录面板（巨大💧弹出）

struct QuickLogSheet: View {
    @EnvironmentObject var model: DrinkModel
    let dismiss: () -> Void

    @State private var selectedPresetID: UUID? = nil
    @State private var sliderAmount: Double = 300
    @State private var timeOffsetMin: Int = 0 // 0/5/15

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("快速记录")
                    .font(.headline)

                // 预设（动态排序）—— 点选=填充滑杆；长按=直接入账（仅量）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.sortedPresets) { p in
                            let isSel = (p.id == selectedPresetID)
                            Text("\(p.name) \(Int(p.amountML))ml")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(isSel ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                                .clipShape(Capsule())
                                .onTapGesture {
                                    selectedPresetID = p.id
                                    sliderAmount = p.amountML
                                }
                                .onLongPressGesture(minimumDuration: 0.35) {
                                    // 仅量：长按直接入账（时间=现在）
                                    _ = model.add(amountML: p.amountML, at: Date(), presetID: p.id)
                                    dismiss()
                                }
                        }
                    }
                }

                // 量：滑杆（50ml 步进）
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("本次用量")
                        Spacer()
                        Text("\(Int(sliderAmount)) ml").bold()
                    }
                    Slider(value: $sliderAmount, in: 50...1000, step: 50)
                }

                // 时间：现在 / -5 分钟 / -15 分钟
                HStack(spacing: 10) {
                    Text("时间")
                    Spacer()
                    Picker("时间", selection: $timeOffsetMin) {
                        Text("现在").tag(0)
                        Text("-5 分钟").tag(5)
                        Text("-15 分钟").tag(15)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }

                // 操作：记一杯 / 仅记时间
                HStack(spacing: 12) {
                    Button {
                        let ts = Date().addingTimeInterval(TimeInterval(-timeOffsetMin * 60))
                        _ = model.add(amountML: sliderAmount, at: ts, presetID: selectedPresetID)
                        dismiss()
                    } label: {
                        Label("记一杯", systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        let ts = Date().addingTimeInterval(TimeInterval(-timeOffsetMin * 60))
                        _ = model.add(amountML: nil, at: ts) // 仅时间，待补量
                        dismiss()
                    } label: {
                        Label("仅时间", systemImage: "clock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 6)

                Spacer(minLength: 6)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: 最近 3 条（含撤销 / 待补量）

struct RecentEntriesSection: View {
    @EnvironmentObject var model: DrinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近")
                .font(.headline)
            ForEach(model.recentThree) { e in
                HStack {
                    Image(systemName: e.isPending ? "clock" : "drop.fill")
                        .foregroundStyle(e.isPending ? .orange : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.isPending ? "仅时间（待补量）" :
                             "喝了 \(Int(e.amountML ?? 0)) ml")
                        .font(.subheadline)
                        Text(e.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Spacer()

                    if e.isPending {
                        // 快捷补量
                        HStack(spacing: 6) {
                            ForEach([200, 300, 500], id: \.self) { ml in
                                Button("\(ml)") {
                                    model.fillAmount(for: e.id, amountML: Double(ml))
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: 撤销 Banner

struct UndoBanner: View {
    @EnvironmentObject var model: DrinkModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
            Text("已记录")
            Spacer()
            Button("撤销") { model.undoLastAdd() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 3)
        .onAppear {
            // 6 秒后自动收起（若未手动撤销）
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                withAnimation { model.showUndoBanner = false }
            }
        }
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environmentObject(DrinkModel())
}
