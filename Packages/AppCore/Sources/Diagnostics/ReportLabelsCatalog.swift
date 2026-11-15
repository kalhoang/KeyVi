// SPDX-License-Identifier: GPL-3.0-or-later

extension ReportLabels {
    static let vietnamese = ReportLabels(
        title: "Báo cáo chẩn đoán", generatedAt: "Tạo lúc", yes: "có", no: "không", none: "không có",
        unknown: "chưa rõ", app: "Ứng dụng", version: "Phiên bản", build: "Bản dựng", channel: "Kênh cập nhật",
        system: "Hệ thống", architecture: "Kiến trúc", model: "Mẫu máy", systemLanguage: "Ngôn ngữ hệ thống",
        state: "Trạng thái", keyboard: "Bàn phím", layout: "Bố cục bàn phím", sourceKind: "Loại nguồn nhập",
        enabledSources: "Nguồn nhập đang bật", permissions: "Quyền", accessibility: "Trợ năng",
        postEvent: "Gửi sự kiện bàn phím", inputMonitoring: "Theo dõi nhập liệu", health: "Tình trạng",
        tap: "Bộ nhận phím", enabled: "Đang bật", location: "Vị trí",
        timeouts: "Số lần quá thời gian trong 24 giờ", userInputDisables: "Số lần bị tắt do nhập liệu trong 24 giờ",
        lastReenable: "Lý do bật lại gần nhất", secureInput: "Nhập bảo mật",
        likelyHolder: "Ứng dụng có thể đang giữ", holderKind: "Loại", focus: "Ô đang nhập", engine: "Công nghệ",
        axData: "Dữ liệu trợ năng", role: "Vai trò", subrole: "Vai trò phụ", identifier: "Định danh",
        domClasses: "Lớp DOM", editable: "Sửa được", secureField: "Ô bảo mật", appSource: "Nhận ra ứng dụng qua",
        rule: "Quy tắc tương thích",
        ruleID: "Mã quy tắc", source: "Nguồn", specificity: "Độ cụ thể", strategy: "Cách chèn chữ",
        parameters: "Tham số", isUserOverride: "Quy tắc riêng của bạn", userOverride: "Quy tắc riêng (JSON)",
        omittedFields: "Trường không đưa vào báo cáo", settings: "Cài đặt", typingMethod: "Kiểu gõ",
        tonePlacement: "Vị trí dấu", englishRestore: "Tự khôi phục từ tiếng Anh", standaloneW: "W đứng riêng",
        bracketKeys: "Phím [ ]", macros: "Viết tắt", macroCount: "Số mục viết tắt",
        macrosInEnglish: "Viết tắt ở chế độ tiếng Anh", rememberPerApp: "Nhớ chế độ theo ứng dụng",
        toggleHotkey: "Phím chuyển chế độ", restoreHotkey: "Có phím khôi phục từ",
        interfaceLanguage: "Ngôn ngữ giao diện", changedSettings: "Cài đặt đã đổi",
        appMode: "Chế độ của ứng dụng được báo", perAppRule: "Quy tắc theo ứng dụng",
        rememberedMode: "Chế độ đã nhớ", latency: "Độ trễ", samples: "mẫu", counters: "Bộ đếm",
        latencyTest: "Kiểm tra độ trễ", events: "Sự kiện gần đây", conflicts: "Ứng dụng nhập liệu có thể xung đột",
        userReport: "Báo lỗi", symptom: "Triệu chứng", reportedApp: "Ứng dụng được báo",
        practiceField: "Lỗi xảy ra cả trong ô thử",
        symptoms: [
            .lostLetters: "Mất chữ", .duplicatedLetters: "Lặp chữ", .lettersOutOfOrder: "Chữ sai thứ tự",
            .wrongTone: "Sai dấu", .cannotTypeVietnamese: "Không gõ được tiếng Việt",
            .nothingTyped: "Không ra chữ nào", .lag: "Chậm / giật", .other: "Khác",
        ],
        notices: [
            .secureInputBursts: HealthNoticeText(
                label: "Chế độ nhập bảo mật bật tắt liên tục",
                explanation:
                    "Có ứng dụng liên tục bật rồi tắt chế độ nhập bảo mật (Secure Input) trong lúc bạn gõ, nên vài phím "
                    + "có thể không tới được %@. Hãy thử thoát các bộ gõ khác, trình quản lý mật khẩu hoặc ứng dụng "
                    + "chạy nền mới cài để tìm ra ứng dụng đó.")
        ])

    static let english = ReportLabels(
        title: "Diagnostics report", generatedAt: "Generated at", yes: "yes", no: "no", none: "none",
        unknown: "unknown", app: "App", version: "Version", build: "Build", channel: "Update channel",
        system: "System", architecture: "Architecture", model: "Model", systemLanguage: "System language",
        state: "State", keyboard: "Keyboard", layout: "Keyboard layout", sourceKind: "Input source type",
        enabledSources: "Enabled input sources", permissions: "Permissions", accessibility: "Accessibility",
        postEvent: "Post keyboard events", inputMonitoring: "Input Monitoring", health: "Health",
        tap: "Event tap", enabled: "Enabled", location: "Location", timeouts: "Timeouts in the last 24 hours",
        userInputDisables: "Disabled by user input in the last 24 hours", lastReenable: "Last re-enable reason",
        secureInput: "Secure input", likelyHolder: "Likely holder", holderKind: "Kind", focus: "Focused field",
        engine: "Engine", axData: "Accessibility data", role: "Role", subrole: "Subrole", identifier: "Identifier",
        domClasses: "DOM classes", editable: "Editable", secureField: "Secure field", appSource: "App identified by",
        rule: "Compatibility rule",
        ruleID: "Rule ID", source: "Source", specificity: "Specificity", strategy: "Strategy",
        parameters: "Parameters", isUserOverride: "Your own rule", userOverride: "Your own rule (JSON)",
        omittedFields: "Fields left out of the report", settings: "Settings", typingMethod: "Typing method",
        tonePlacement: "Tone placement", englishRestore: "Restore English words", standaloneW: "Standalone W",
        bracketKeys: "[ ] keys", macros: "Macros", macroCount: "Macro count",
        macrosInEnglish: "Macros in English mode", rememberPerApp: "Remember mode per app",
        toggleHotkey: "Mode toggle hotkey", restoreHotkey: "Restore-word hotkey set",
        interfaceLanguage: "Interface language", changedSettings: "Changed settings",
        appMode: "Mode of the reported app", perAppRule: "Per-app rule", rememberedMode: "Remembered mode",
        latency: "Latency", samples: "samples", counters: "Counters", latencyTest: "Latency test",
        events: "Recent events", conflicts: "Possibly conflicting input apps", userReport: "Problem report",
        symptom: "Symptom", reportedApp: "Reported app", practiceField: "Also happens in the practice field",
        symptoms: [
            .lostLetters: "Missing letters", .duplicatedLetters: "Duplicated letters",
            .lettersOutOfOrder: "Letters out of order", .wrongTone: "Wrong tone",
            .cannotTypeVietnamese: "Cannot type Vietnamese", .nothingTyped: "Nothing typed", .lag: "Lag",
            .other: "Other",
        ],
        notices: [
            .secureInputBursts: HealthNoticeText(
                label: "Secure Input keeps turning on and off",
                explanation:
                    "An app keeps turning Secure Input on and off while you type, so some keys may not reach %@. Try "
                    + "quitting other input methods, password managers or recently installed background apps to find "
                    + "it.")
        ])
}
