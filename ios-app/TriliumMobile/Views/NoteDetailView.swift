import SwiftUI
import WebKit
import Photos

/// 笔记详情（原生阅读页）：ETAPI 拿内容，按类型原生渲染。
/// text → 富文本 HTML；code → 代码；image → 图片；file → 附件；其他 → 降级提示。
/// 编辑统一用原生编辑（text/code 用 TextEditor 改标题+正文；复杂类型给「用网页编辑器」兜底）。
struct NoteDetailView: View {
    let note: Note
    @EnvironmentObject private var settings: AppSettings

    @State private var textContent: String = ""
    @State private var imageData: Data?
    @State private var loading = true
    @State private var hasLoadedOnce = false
    @State private var errorMsg = ""
    @State private var showEditor = false
    @State private var showWebEditor = false
    @State private var showEditChoice = false
    @State private var shareURL: URL?
    /// 笔记内链接点击后打开的目标笔记（sheet(item:)）
    @State private var linkedNote: Note?
    /// 大纲目录：JS 上报的 h1~h3；点击条目 → outlineJump 驱动 ContentWebView 滚动
    @State private var outlineItems: [OutlineItem] = []
    @State private var showOutline = false
    @State private var outlineJump: Int?
    // 附件预览状态
    @State private var fileDownloading = false
    @State private var fileProgress: Double = 0
    @State private var previewURL: URL?
    @State private var fileErrorMsg = ""
    /// 编辑改标题后的最新标题（note 是 let，PATCH 后靠这里刷新显示）
    @State private var freshTitle: String = ""
    @State private var freshType: String = ""
    // 同层兄弟导航（底部条：上一篇/下一篇 + 父路径）
    @State private var siblings: [Note] = []
    @State private var parentTitle: String = ""
    @State private var isLoadingSiblings = true

    /// 同层上一篇 / 下一篇（依赖 siblings 的服务端 childNoteIds 顺序）
    private var prevSibling: Note? {
        guard let i = siblings.firstIndex(where: { $0.noteId == note.noteId }), i > 0 else { return nil }
        return siblings[i - 1]
    }
    private var nextSibling: Note? {
        guard let i = siblings.firstIndex(where: { $0.noteId == note.noteId }),
              i + 1 < siblings.count else { return nil }
        return siblings[i + 1]
    }

    private var siblingBar: some View {
        HStack(spacing: 0) {
            if let p = prevSibling {
                NavigationLink(destination: NoteDetailView(note: p)) {
                    Label("上一篇", systemImage: "chevron.left").font(.footnote)
                }
            }
            Spacer()
            if !parentTitle.isEmpty {
                Text(parentTitle)
                    .font(.caption2)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .lineLimit(1)
            }
            Spacer()
            if let n = nextSibling {
                NavigationLink(destination: NoteDetailView(note: n)) {
                    Label("下一篇", systemImage: "chevron.right").font(.footnote)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var displayTitle: String { freshTitle.isEmpty ? note.title : freshTitle }

    /// 阅读字号档位（⚠️ 别用 tuple 数组 + id:\.0 —— Swift keypath 不支持 tuple 元素，编译炸）
    private struct FontOption: Identifiable {
        let scale: Double
        let label: String
        var id: Double { scale }
    }
    private static let fontOptions = [
        FontOption(scale: 0.85, label: "小"),
        FontOption(scale: 1.0, label: "标准"),
        FontOption(scale: 1.2, label: "大"),
        FontOption(scale: 1.4, label: "特大"),
    ]

    var body: some View {
        Group {
            if loading && !hasLoadedOnce { // 编辑返回的静默刷新不闪全屏 loading
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !errorMsg.isEmpty {
                VStack(spacing: 12) {
                    Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                    Button("重试") { Task { await load(force: true) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle(displayTitle.isEmpty ? "笔记" : displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // 底部操作条：上一篇 / 父路径 / 下一篇（拇指区，不用回列表再点）
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isLoadingSiblings && (prevSibling != nil || nextSibling != nil || !parentTitle.isEmpty) {
                siblingBar
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if note.type == "text" || note.type == "code" || note.type == "render" {
                    // 大纲目录：JS 提取 h1~h3 上报，非空才显示入口
                    if !outlineItems.isEmpty {
                        Button { showOutline = true } label: {
                            Image(systemName: "list.bullet.indent")
                        }
                        .accessibilityLabel("大纲目录")
                    }
                    // 阅读字号：四档缩放，持久化，改动即生效（html diff 自动重载）
                    Menu {
                        ForEach(Self.fontOptions) { opt in
                            Button {
                                settings.readerFontScale = opt.scale
                            } label: {
                                if settings.readerFontScale == opt.scale {
                                    Label(opt.label, systemImage: "checkmark")
                                } else {
                                    Text(opt.label)
                                }
                            }
                        }
                    } label: {
                        Text("Aa").font(.callout.weight(.medium))
                    }
                    .accessibilityLabel("阅读字号")

                    Button {
                        shareNote()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享笔记")
                }
                if note.type == "text" || note.type == "code" {
                    Button("编辑") { showEditChoice = true }
                }
            }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil },
                                    set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        // ⚠️ 编辑返回必须 force 刷新：普通 load() 会命中本地缓存显示**旧内容**（编辑白改）
        .sheet(isPresented: $showEditor, onDismiss: { Task { await load(force: true) } }) {
            NativeEditorView(note: note, initialContent: textContent)
        }
        // 网页编辑器（CKEditor 完整格式：表格/公式/图片），返回同样 force 刷新
        .sheet(isPresented: $showWebEditor, onDismiss: { Task { await load(force: true) } }) {
            WebEditorView(note: note)
        }
        .confirmationDialog("选择编辑方式", isPresented: $showEditChoice, titleVisibility: .visible) {
            Button("原生编辑（简洁快速）") { showEditor = true }
            Button("网页编辑（完整格式：表格/公式/图片）") { showWebEditor = true }
            Button("取消", role: .cancel) {}
        }
        // 笔记内链接：App 内新开一层阅读页（点返回关闭）
        .sheet(item: $linkedNote) { linked in
            NavigationView {
                NoteDetailView(note: linked)
            }
            .navigationViewStyle(.stack)
        }
        // 大纲目录：点击条目关闭面板并跳到对应标题
        .sheet(isPresented: $showOutline) {
            NavigationView {
                List(outlineItems) { item in
                    Button {
                        showOutline = false
                        outlineJump = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { outlineJump = item.id }
                    } label: {
                        Text(item.text)
                            .font(item.level == 1 ? .body.weight(.medium) : .subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(item.level - 1) * 14)
                    }
                }
                .listStyle(.plain)
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showOutline = false }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
        .task {
            await load()
            await loadSiblings()
            // file 类型的笔记（PDF/Office/压缩包…）直接打开，不要再让用户多按一次「预览附件」
            if note.type == "file" {
                await previewFile()
            }
        }
        // 阅读页出现即广播：首页收到后收起抽屉。
        // 抽屉是 ZStack 覆盖层（不在导航栈里），从树里 push 阅读页时它不会自己消失。
        .onAppear {
            NotificationCenter.default.post(name: .noteDetailAppeared, object: nil)
        }
    }

    private func openLinkedNote(_ noteId: String) {
        guard noteId != note.noteId else { return }
        Task {
            do {
                linkedNote = try await ETAPIClient.shared.getNote(noteId)
            } catch {
                AppLogger.shared.log("打开笔记链接失败: \(error.localizedDescription)")
            }
        }
    }

    /// 导出为 HTML 文件分享（AirDrop / 备忘录 / 其他 App 均可收）
    private func shareNote() {
        let html = NoteHTML.wrap(title: displayTitle, raw: textContent,
                                 noteType: note.type, fontScale: settings.readerFontScale)
        let safeName = displayTitle
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
        let name = safeName.isEmpty ? "note" : safeName
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).html")
        do {
            try html.data(using: .utf8)?.write(to: url)
            shareURL = url
        } catch {
            AppLogger.shared.log("导出失败: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch note.type {
        case "image":
            if let data = imageData, let img = UIImage(data: data) {
                ZoomableImageView(image: img)
            } else {
                fallback(typeName: "图片", icon: "photo")
            }
        case "file":
            fileView
        case "code":
            ContentWebView(html: NoteHTML.wrap(title: displayTitle, raw: textContent, noteType: "code", fontScale: settings.readerFontScale), noteId: note.noteId, onOpenNote: openLinkedNote, onOutline: { items in outlineItems = items }, jumpToIndex: outlineJump)
        case "mermaid":
            ContentWebView(html: NoteHTML.wrapMermaid(title: displayTitle, code: textContent), noteId: note.noteId, onOpenNote: openLinkedNote, onOutline: { items in outlineItems = items }, jumpToIndex: outlineJump)
        case "render":
            ContentWebView(html: NoteHTML.wrap(title: displayTitle, raw: textContent, noteType: "render", fontScale: settings.readerFontScale), noteId: note.noteId, onOpenNote: openLinkedNote, onOutline: { items in outlineItems = items }, jumpToIndex: outlineJump)
        case "text":
            ContentWebView(html: NoteHTML.wrap(title: displayTitle, raw: textContent, noteType: "text", fontScale: settings.readerFontScale), noteId: note.noteId, onOpenNote: openLinkedNote, onOutline: { items in outlineItems = items }, jumpToIndex: outlineJump)
        default:
            fallback(typeName: note.type, icon: "doc.text")
        }
    }

    private var fileView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.system(size: 48)).foregroundColor(.blue)
            Text(note.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("\(Self.friendlyKind(note.mime))\(note.mime.map { " · \($0)" } ?? "")")
                .font(.footnote).foregroundColor(.secondary)

            if fileDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: fileProgress)
                        .frame(width: 180)
                    Text("下载中…").font(.caption).foregroundColor(.secondary)
                }
            } else {
                Button {
                    Task { await previewFile() }
                } label: {
                    Label(previewURL == nil ? "预览附件" : "重新打开", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
            }

            if !fileErrorMsg.isEmpty {
                Text(fileErrorMsg).font(.caption).foregroundColor(.red)
            }

            Link("在网页端打开", destination: AppSettings.shared.serverURL)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⚠️ 不在这里用 .sheet 包 QuickLook：见 QuickLookPresenter 的说明
        //   （嵌进 sheet 会没有「完成」按钮、且内部滚动和 sheet 下拉手势打架）
    }

    /// 下载附件到稳定缓存目录 → QuickLook 原生预览（PDF/Office/图片通吃）
    /// ⚠️ 缓存必须落在 Caches 而不是 temporaryDirectory：iOS 会随时清临时目录，
    ///   导致「退出回来又重新下载」。已缓存则秒开。
    /// ⚠️ **必须带正确的扩展名**：QuickLook 靠扩展名判 UTI，没有扩展名的 PDF 只会显示
    ///   「data / 25.2 MB」的空白页（用户实测「打不开」就是这个）。旧版直接用标题当文件名。
    private func previewFile() async {
        fileErrorMsg = ""
        var base = note.title.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "attachment" }

        // 稳定缓存目录（跨会话保留）
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TriliumAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let ext = Self.fileExtension(mime: note.mime, name: base)
        let fileName = ext.isEmpty ? base : "\(base).\(ext)"
        let url = cacheDir.appendingPathComponent(fileName)

        // 兼容旧缓存：以前不带扩展名，QuickLook 认不出来 → 直接改名复用，不重新下 25MB
        let legacyURL = cacheDir.appendingPathComponent(base)
        if url != legacyURL, FileManager.default.fileExists(atPath: legacyURL.path),
           !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: legacyURL, to: url)
        }

        // 1. 已缓存 → 秒开
        if FileManager.default.fileExists(atPath: url.path) {
            openPreview(url)
            return
        }
        // 2. NoteCache blob 有数据 → 落盘后秒开
        if let cached = NoteCache.shared.loadBlob(note.noteId) {
            do {
                try cached.write(to: url)
                openPreview(url)
                return
            } catch {}
        }
        // 3. 下载（带进度）
        fileDownloading = true
        fileProgress = 0
        do {
            let data = try await ETAPIClient.shared.getContentData(note.noteId) { received, total in
                if let total, total > 0 {
                    Task { @MainActor in self.fileProgress = Double(received) / Double(total) }
                }
            }
            // mime 也不认识时，用文件头兜底判断类型（PDF / 图片 / zip 系）
            var finalURL = url
            if ext.isEmpty, let sniffed = Self.sniffExtension(data) {
                finalURL = cacheDir.appendingPathComponent("\(base).\(sniffed)")
            }
            try data.write(to: finalURL, options: .atomic) // 原子写，防中断留半截文件被误判为缓存
            NoteCache.shared.saveBlob(note.noteId, data: data)
            fileDownloading = false
            AppLogger.shared.log("附件下载完成: \(finalURL.lastPathComponent) \(data.count)字节")
            openPreview(finalURL)
        } catch {
            fileDownloading = false
            fileErrorMsg = "下载失败：\(error.localizedDescription)"
            AppLogger.shared.log("附件下载失败[\(note.title)]: \(error.localizedDescription)")
        }
    }

    /// 交给 UIKit 原生 present（自带完成按钮 / 滚动 / 缩放 / 分享）
    private func openPreview(_ url: URL) {
        previewURL = url                      // 只用来切换按钮文案「重新打开」
        QuickLookPresenter.shared.present(url)
    }

    /// 文件类型的中文说明（比裸 mime 好读）
    private static func friendlyKind(_ mime: String?) -> String {
        guard let m = mime?.lowercased() else { return "附件" }
        if m.hasPrefix("image/") { return "图片" }
        if m.hasPrefix("audio/") { return "音频" }
        if m.hasPrefix("video/") { return "视频" }
        if m.contains("pdf") { return "PDF 文档" }
        if m.contains("word") || m.contains("msword") { return "Word 文档" }
        if m.contains("sheet") || m.contains("excel") { return "Excel 表格" }
        if m.contains("presentation") || m.contains("powerpoint") { return "PPT 演示" }
        if m.contains("zip") || m.contains("rar") || m.contains("7z") { return "压缩包" }
        if m.hasPrefix("text/") { return "文本" }
        return "附件"
    }

    /// mime → 扩展名。QuickLook 完全依赖扩展名，这一步不能省。
    private static func fileExtension(mime: String?, name: String) -> String {
        if let m = mime?.lowercased() {
            if let ext = extByMime[m] { return ext }
            // 形如 image/png; charset=utf-8 之类带参数的
            if let semi = m.split(separator: ";").first, let ext = extByMime[String(semi)] { return ext }
        }
        // 标题里本来就带后缀（用户自己命名的 .pdf 等）
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 5 { return ext }
        return ""
    }

    /// 文件头魔数兜底
    private static func sniffExtension(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }   // %PDF
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }         // JPEG
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }   // PNG
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }   // GIF8
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }  // RIFF（webp 常见）
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }   // PK（zip/docx/xlsx）
        return nil
    }

    private static let extByMime: [String: String] = [
        "application/pdf": "pdf",
        "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png",
        "image/gif": "gif", "image/webp": "webp", "image/heic": "heic",
        "image/svg+xml": "svg", "image/bmp": "bmp", "image/tiff": "tiff",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/zip": "zip", "application/x-zip-compressed": "zip",
        "application/x-rar-compressed": "rar", "application/x-7z-compressed": "7z",
        "application/json": "json", "text/plain": "txt", "text/markdown": "md",
        "text/csv": "csv", "application/rtf": "rtf",
        "audio/mpeg": "mp3", "audio/mp4": "m4a", "video/mp4": "mp4",
    ]

    private func fallback(typeName: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundColor(.secondary)
            Text("「\(typeName)」类型暂不支持原生展示")
                .font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 拉同层兄弟（底部条上/下篇）+ 父笔记标题（面包屑）。
    /// 依赖 note.parentNoteIds（搜索接口可能不填充，为空就静默不显示底部条）
    private func loadSiblings() async {
        isLoadingSiblings = true
        defer { isLoadingSiblings = false }
        guard let pid = note.parentNoteIds?.first else { return }
        if let p = try? await ETAPIClient.shared.getNote(pid) {
            parentTitle = p.title
        }
        if let list = try? await ETAPIClient.shared.childNotes(of: pid) {
            siblings = list
        }
    }

    /// force=true：跳过缓存直拉网络（编辑保存后必须用，否则读到旧缓存）
    private func load(force: Bool = false) async {
        if !force { loading = true } // 静默刷新不置 loading，保留屏上旧内容
        do {
            if force {
                // 顺带拉最新元数据：编辑器里改过标题/类型时同步显示
                let fresh = try await ETAPIClient.shared.getNote(note.noteId)
                freshTitle = fresh.title
                freshType = fresh.type
            }
            switch note.type {
            case "image":
                if !force, let cached = NoteCache.shared.loadBlob(note.noteId) {
                    imageData = cached
                } else if let data = try? await ETAPIClient.shared.getContentData(note.noteId) {
                    imageData = data
                    NoteCache.shared.saveBlob(note.noteId, data: data)
                }
            case "text", "code", "render":
                if !force, let cached = NoteCache.shared.loadContent(note.noteId) {
                    textContent = cached
                } else {
                    let raw = try await ETAPIClient.shared.getContent(note.noteId)
                    textContent = raw
                    NoteCache.shared.saveContent(note.noteId, text: raw)
                }
            default:
                break
            }
            errorMsg = ""
        } catch {
            // 静默刷新失败且屏上已有内容：不打断阅读，只记日志
            let hasContent = !textContent.isEmpty || imageData != nil
            if !(force && hasContent) {
                errorMsg = "加载失败：\(error.localizedDescription)"
            }
            AppLogger.shared.log("阅读[\(note.title)]加载失败: \(error.localizedDescription)")
        }
        hasLoadedOnce = true
        loading = false
    }
}

/// 原生编辑器：text/code 笔记直接改标题 + 正文（纯 SwiftUI，不再依赖网页编辑器）
struct NativeEditorView: View {
    let note: Note
    let initialContent: String

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var saving = false
    @State private var errorMsg = ""

    var body: some View {
        NavigationView {
            Form {
                Section("标题") {
                    TextField("标题", text: $title)
                }
                Section("内容") {
                    if note.type == "code" {
                        TextEditor(text: $content)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 300)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } else {
                        // text 笔记正文是 HTML，纯文本编辑会破坏格式；
                        // 这里给一个说明 + 用网页编辑器兜底
                        Text("富文本笔记建议用网页编辑器编辑（保留格式）。\n如需纯文本编辑可切 code 类型。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                if !errorMsg.isEmpty {
                    Section { Text(errorMsg).font(.footnote).foregroundColor(.red) }
                }
            }
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(saving)
                }
            }
            .onAppear {
                title = note.title
                content = initialContent
            }
        }
    }

    private func save() {
        saving = true
        Task {
            let titleChanged = title != note.title
            let contentChanged = note.type == "code" && content != initialContent
            do {
                // 标题变化 → PATCH；正文变化（code 类型）→ PUT content
                if titleChanged {
                    _ = try await ETAPIClient.shared.patchNote(note.noteId, fields: ["title": title])
                }
                if contentChanged {
                    try await ETAPIClient.shared.putContent(note.noteId, content: content)
                }
            } catch {
                // 断网/失败：入离线队列，联网后自动补交（队列保序，先标题后正文）
                if titleChanged {
                    NoteCache.shared.enqueue(PendingOp(kind: "patchTitle", id: UUID().uuidString,
                        noteId: note.noteId, title: title, content: nil, parentNoteId: nil,
                        createdAt: Date()))
                }
                if contentChanged {
                    NoteCache.shared.enqueue(PendingOp(kind: "putContent", id: UUID().uuidString,
                        noteId: note.noteId, title: nil, content: content, parentNoteId: nil,
                        createdAt: Date()))
                }
            }
            // 无论在线离线都更新本地缓存并关闭（离线队列保证最终一致）
            NoteCache.shared.saveContent(note.noteId, text: content)
            if titleChanged {
                NotificationCenter.default.post(name: .noteMetaChanged, object: nil)
            }
            if !NoteCache.shared.pendingOps.isEmpty {
                Task { await NoteCache.shared.flushPendingOps() }  // 顺手补交旧积压
            }
            dismiss()
            saving = false
        }
    }
}

extension Notification.Name {
    /// 笔记标题等元数据被修改（编辑器保存后广播，首页列表就地刷新）
    static let noteMetaChanged = Notification.Name("trilium.noteMetaChanged")
    /// 阅读页出现（从抽屉树点笔记后，首页据此收起抽屉，避免树盖在阅读页上）
    static let noteDetailAppeared = Notification.Name("trilium.noteDetailAppeared")
}

/// HTML 包装工具（抽离，供阅读页复用）
enum NoteHTML {

/// 代码块增强：给每个 pre 动态包一层 + 右上角「复制」按钮（纯 JS，无需原生桥）。
    /// clipboard API 不可用时降级 execCommand；完整 HTML 文档分支同样注入。
    private static let codeEnhance = """
    <style>
      .code-wrap { position: relative; }
      .code-wrap .copy-btn {
        position: absolute; top: 6px; right: 6px; z-index: 5;
        font-size: 12px; padding: 2px 8px; border-radius: 6px;
        border: 1px solid rgba(120,120,128,0.3);
        background: rgba(255,255,255,0.88); color: #333; opacity: 0.85;
      }
      @media (prefers-color-scheme: dark) {
        .code-wrap .copy-btn { background: rgba(60,60,67,0.88); color: #ddd; }
      }
      img { -webkit-touch-callout: none; }
      /* 回到顶部：长文翻到下面就懒得往回滑了，滚动过一屏才浮出来 */
      #to-top-btn {
        position: fixed; right: 14px; bottom: calc(24px + env(safe-area-inset-bottom));
        width: 40px; height: 40px; border-radius: 20px;
        border: 1px solid rgba(120,120,128,0.28);
        background: rgba(255,255,255,0.94); color: #333;
        font-size: 18px; line-height: 38px; text-align: center;
        opacity: 0; pointer-events: none; z-index: 9999;
        transition: opacity .2s ease; box-shadow: 0 2px 10px rgba(0,0,0,0.14);
      }
      #to-top-btn.show { opacity: 1; pointer-events: auto; }
      @media (prefers-color-scheme: dark) {
        #to-top-btn { background: rgba(58,58,60,0.94); color: #eee; }
      }
    </style>
    <script>
    // 长按图片 600ms → 通知原生保存到相册（禁掉系统 callout，统一走自家流程）
    (function() {
      var timer;
      document.addEventListener('touchstart', function(e) {
        var img = e.target.closest ? e.target.closest('img') : null;
        if (!img || !img.src) return;
        timer = setTimeout(function() {
          window.webkit && window.webkit.messageHandlers.imgsave &&
            window.webkit.messageHandlers.imgsave.postMessage(img.src);
        }, 600);
      }, { passive: true });
      ['touchend', 'touchmove', 'touchcancel'].forEach(function(ev) {
        document.addEventListener(ev, function() { clearTimeout(timer); }, { passive: true });
      });
    })();
    // 大纲上报：收集 h1~h3 发给原生（大纲目录入口用）
    document.addEventListener('DOMContentLoaded', function() {
      var out = [];
      document.querySelectorAll('h1,h2,h3').forEach(function(h) {
        out.push([parseInt(h.tagName.substring(1), 10), h.textContent.trim()]);
      });
      window.webkit && window.webkit.messageHandlers.outline &&
        window.webkit.messageHandlers.outline.postMessage(out);
    });
    </script>
    <script>
    document.addEventListener('DOMContentLoaded', function() {
      document.querySelectorAll('pre').forEach(function(pre) {
        if (pre.parentElement && pre.parentElement.className === 'code-wrap') return;
        var wrap = document.createElement('div');
        wrap.className = 'code-wrap';
        pre.parentNode.insertBefore(wrap, pre);
        wrap.appendChild(pre);
        var btn = document.createElement('button');
        btn.className = 'copy-btn'; btn.type = 'button'; btn.textContent = '复制';
        wrap.appendChild(btn);
      });
    });
    document.addEventListener('click', function(e) {
      var btn = e.target.closest ? e.target.closest('.copy-btn') : null;
      if (!btn) return;
      var pre = btn.parentElement.querySelector('pre');
      var text = pre ? pre.innerText : '';
      var done = function() {
        btn.textContent = '已复制';
        setTimeout(function() { btn.textContent = '复制'; }, 1500);
      };
      var fallback = function() {
        var ta = document.createElement('textarea');
        ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); done(); } catch (err) {}
        document.body.removeChild(ta);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(fallback);
      } else { fallback(); }
    });
    <script>
    // 回到顶部按钮：纯前端，不经过原生桥；页面没有滚动时自动隐藏
    (function() {
      function makeBtn() {
        if (document.getElementById('to-top-btn')) return;
        var b = document.createElement('div');
        b.id = 'to-top-btn';
        b.textContent = '↑';
        b.addEventListener('click', function() {
          window.scrollTo({ top: 0, behavior: 'smooth' });
        });
        document.body.appendChild(b);
        window.addEventListener('scroll', function() {
          if (window.scrollY > 600) b.classList.add('show');
          else b.classList.remove('show');
        }, { passive: true });
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', makeBtn);
      } else { makeBtn(); }
    })();
    </script>
    """

    /// mermaid.min.js 全文（Bundle 内联，~2.6MB；只加载一次）
    private static let mermaidJS: String = {
        guard let url = Bundle.main.url(forResource: "mermaid", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            AppLogger.shared.log("mermaid.js 资源缺失")
            return ""
        }
        // 保险：防止 JS 字符串中出现的 </script> 截断 HTML
        return s.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }()

    /// mermaid 类型笔记：代码 → 本地渲染图表（无外网也能看，官方移动端没有的能力）
    static func wrapMermaid(title: String, code: String) -> String {
        guard !mermaidJS.isEmpty else {
            return wrap(title: title, raw: "<pre>\(code)</pre>", noteType: "code")
        }
        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
          body { font-family: -apple-system, "PingFang SC", sans-serif;
                 margin: 0; padding: 16px 18px 60px; word-wrap: break-word;
                 -webkit-text-size-adjust: 100%; background: #fff; }
          @media (prefers-color-scheme: dark) { body { background: #000; } }
          h1 { font-size: 24px; margin: 8px 0 16px; }
          .mermaid { display: flex; justify-content: center; }
          .mermaid svg { max-width: 100%; height: auto; }
          .err { color: #c0392b; font-size: 13px; white-space: pre-wrap; }
        </style>
        </head><body>
        <h1>\(title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</h1>
        <pre class="mermaid">
        \(escaped)
        </pre>
        <script>\(mermaidJS)</script>
        <script>
        mermaid.initialize({
          startOnLoad: true,
          theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
          securityLevel: 'loose'
        });
        mermaid.parseError = function(err) {
          var el = document.querySelector('.mermaid');
          if (el) { el.className = 'err'; el.textContent = '图表语法错误：' + err; }
        };
        </script>
        </body></html>
        """
    }

    /// 给任意 HTML 注入代码块增强（有 </head> 插头部，否则放开头）
    private static func injectEnhance(_ html: String) -> String {
        if html.lowercased().contains("</head>") {
            return html.replacingOccurrences(of: "</head>", with: codeEnhance + "</head>", options: .caseInsensitive)
        }
        return codeEnhance + html
    }

    /// fontScale：阅读页字号缩放（1.0 = 17px 标准）
    static func wrap(title: String, raw: String, noteType: String, fontScale: Double = 1.0) -> String {
        let fontSize = Int((17 * fontScale).rounded())
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let bodyContent: String
        if noteType == "code" {
            let escaped = raw
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            bodyContent = "<pre>\(escaped)</pre>"
        } else {
            bodyContent = raw
        }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if noteType != "code" && (trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html")) {
            let mobileCSS = """
            <style>
              body { font-family: -apple-system, "PingFang SC", sans-serif;
                     font-size: \(fontSize)px; line-height: 1.75; color: #1c1c1e;
                     padding: 16px 18px 60px;
                     word-wrap: break-word; -webkit-text-size-adjust: 100%; }
              @media (prefers-color-scheme: dark) {
                body { background: #000; color: #e5e5e7; }
                a { color: #6bb3ff; }
                img { background: #1c1c1e; }
                blockquote { color: #98989d; }
              }
              h1 { font-size: 24px; line-height: 1.3; margin: 8px 0 16px; }
              h2 { font-size: 20px; margin: 24px 0 10px; }
              h3 { font-size: 18px; margin: 20px 0 8px; }
              p { margin: 10px 0; }
              img { max-width: 100%; height: auto; border-radius: 8px; }
              pre {
                background: rgba(120,120,128,0.12); border-radius: 8px;
                padding: 12px; overflow-x: auto; font-size: 14px; line-height: 1.5;
              }
              code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
              p code, li code {
                background: rgba(120,120,128,0.12); border-radius: 4px; padding: 1px 5px;
              }
              blockquote {
                border-left: 3px solid rgba(120,120,128,0.4);
                margin: 12px 0; padding: 2px 0 2px 14px; color: #6e6e73;
              }
              table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 15px; }
              th, td { border: 1px solid rgba(120,120,128,0.35); padding: 7px 10px; text-align: left; }
              ul, ol { padding-left: 24px; }
              a { color: #0a66c2; }
              hr { border: none; border-top: 1px solid rgba(120,120,128,0.3); margin: 20px 0; }
            </style>
            """
            if raw.lowercased().contains("</head>") {
                return injectEnhance(raw.replacingOccurrences(of: "</head>", with: mobileCSS + "</head>", options: .caseInsensitive))
            }
            return injectEnhance(raw)
        }

        let template = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, "PingFang SC", sans-serif;
            font-size: \(fontSize)px; line-height: 1.75; color: #1c1c1e;
            margin: 0; padding: 16px 18px 60px;
            word-wrap: break-word; -webkit-text-size-adjust: 100%;
          }
          @media (prefers-color-scheme: dark) {
            body { background: #000; color: #e5e5e7; }
            a { color: #6bb3ff; }
            img { background: #1c1c1e; }
            blockquote { color: #98989d; }
          }
          h1 { font-size: 24px; line-height: 1.3; margin: 8px 0 16px; }
          h2 { font-size: 20px; margin: 24px 0 10px; }
          h3 { font-size: 18px; margin: 20px 0 8px; }
          p { margin: 10px 0; }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          pre {
            background: rgba(120,120,128,0.12); border-radius: 8px;
            padding: 12px; overflow-x: auto; font-size: 14px; line-height: 1.5;
          }
          code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
          p code, li code {
            background: rgba(120,120,128,0.12); border-radius: 4px; padding: 1px 5px;
          }
          blockquote {
            border-left: 3px solid rgba(120,120,128,0.4);
            margin: 12px 0; padding: 2px 0 2px 14px; color: #6e6e73;
          }
          table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 15px; }
          th, td { border: 1px solid rgba(120,120,128,0.35); padding: 7px 10px; text-align: left; }
          ul, ol { padding-left: 24px; }
          a { color: #0a66c2; }
          hr { border: none; border-top: 1px solid rgba(120,120,128,0.3); margin: 20px 0; }
        </style>
        </head><body>
        <h1>\(escapedTitle)</h1>
        \(bodyContent)
        </body></html>
        """
        return injectEnhance(template)
    }
}

/// 本地 HTML 渲染（loadHTMLString，不加载 Trilium 桌面页）。
/// baseURL 指向服务器：笔记里的相对路径图片/附件才能加载。
/// 传 noteId 时记忆阅读进度：重进笔记自动滚到上次位置。
struct ContentWebView: UIViewRepresentable {
    let html: String
    var noteId: String = ""
    /// 点击笔记内链接时回调（Trilium 链接 → App 内打开该笔记）
    var onOpenNote: ((String) -> Void)? = nil
    /// JS 上报的大纲（h1~h3）
    var onOutline: (([OutlineItem]) -> Void)? = nil
    /// 跳转到大纲第 index 项（变化时驱动 evaluateJavaScript 滚动）
    var jumpToIndex: Int? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(noteId: noteId, onOpenNote: onOpenNote, onOutline: onOutline)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        let noteId: String
        let onOpenNote: ((String) -> Void)?
        let onOutline: (([OutlineItem]) -> Void)?
        var lastHTML = ""
        var hasRestored = false
        var lastSaveTime: TimeInterval = 0
        var lastJump: Int?
        weak var webView: WKWebView?

        init(noteId: String, onOpenNote: ((String) -> Void)?, onOutline: (([OutlineItem]) -> Void)?) {
            self.noteId = noteId
            self.onOpenNote = onOpenNote
            self.onOutline = onOutline
        }

        /// JS 长按图片 → postMessage("imgsave") → 下载 → 存相册；"outline" → 大纲上报
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "imgsave":
                guard let src = message.body as? String, !src.isEmpty else { return }
                saveImageToPhotos(src: src)
            case "outline":
                guard let arr = message.body as? [[Any]] else { return }
                var items: [OutlineItem] = []
                for (i, row) in arr.enumerated() {
                    if row.count >= 2, let lvl = row[0] as? Int, let txt = row[1] as? String, !txt.isEmpty {
                        items.append(OutlineItem(id: i, level: lvl, text: txt))
                    }
                }
                DispatchQueue.main.async { [onOutline] in onOutline?(items) }
            default:
                break
            }
        }

        private func saveImageToPhotos(src: String) {
            let url: URL?
            if src.hasPrefix("http://") || src.hasPrefix("https://") {
                url = URL(string: src)
            } else {
                url = URL(string: src, relativeTo: AppSettings.shared.serverURL)
            }
            guard let target = url else { return }
            URLSession.shared.dataTask(with: target) { data, _, _ in
                guard let data, let img = UIImage(data: data) else {
                    DispatchQueue.main.async {
                        AppLogger.shared.log("图片下载失败: \(target.absoluteString.prefix(80))")
                    }
                    return
                }
                // .addOnly：只需「添加到相册」权限，不请求读相册
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        DispatchQueue.main.async { AppLogger.shared.log("无相册写入权限，保存取消") }
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }, completionHandler: { ok, err in
                        DispatchQueue.main.async {
                            if ok {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                AppLogger.shared.log("图片已保存到相册")
                            } else {
                                AppLogger.shared.log("保存失败: \(err?.localizedDescription ?? "?")")
                            }
                        }
                    })
                }
            }.resume()
        }

        private var posKey: String { "trilium.readpos.\(noteId)" }

        /// 链接拦截（loadHTMLString 的 baseURL 指向服务器，不拦的话点链接
        /// 会把整个阅读页导航到 Trilium 桌面页/外部站点，阅读进度全丢）：
        ///   - 站内笔记链接（#root/…=noteId）→ 回调 App 内打开
        ///   - 其他 http/https 外链 → Safari 打开
        ///   - 其余（初始 loadHTMLString、子资源加载）→ 放行
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)

            // 站内笔记链接：形如 <server>/#root/xxx=noteId 或 <server>/xxx?noteId=yyy
            if let nid = Self.noteId(from: url, base: AppSettings.shared.serverURL), !nid.isEmpty {
                DispatchQueue.main.async { [onOpenNote] in onOpenNote?(nid) }
                return
            }

            // 外链交 Safari
            if url.scheme == "http" || url.scheme == "https" {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
        }

        /// 从 Trilium 链接 URL 中提取 noteId（桌面端链接格式 #root/父=noteId）。
        private static func noteId(from url: URL, base: URL) -> String? {
            guard url.host == base.host, url.port == base.port else { return nil }
            // 优先 query 参数 noteId=
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let q = comps.queryItems?.first(where: { $0.name == "noteId" })?.value, !q.isEmpty {
                return q
            }
            // fragment "#root/a/b=noteId"：取最后一段 = 后面的部分
            if let frag = url.fragment?.split(separator: "/").last {
                let s = String(frag)
                if let eq = s.lastIndex(of: "=") {
                    return String(s[s.index(after: eq)...])
                }
                return s
            }
            // path 末段兜底
            if let last = url.pathComponents.last, last != "/" {
                return last.contains("=") ? last.split(separator: "=").last.map(String.init) : last
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 首次加载完成：恢复上次的阅读位置（需等内容布局出高度）
            guard !hasRestored, !noteId.isEmpty else { return }
            hasRestored = true
            let y = UserDefaults.standard.double(forKey: posKey)
            guard y > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak webView] in
                guard let sv = webView?.scrollView else { return }
                guard sv.contentSize.height > sv.frame.height else { return }
                let maxY = sv.contentSize.height - sv.frame.height
                sv.setContentOffset(CGPoint(x: 0, y: min(y, maxY)), animated: false)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 节流保存阅读进度（0.5s 一次，避免滚动时高频写盘）
            guard hasRestored, !noteId.isEmpty else { return }
            let now = Date().timeIntervalSince1970
            guard now - lastSaveTime > 0.5 else { return }
            lastSaveTime = now
            UserDefaults.standard.set(scrollView.contentOffset.y, forKey: posKey)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "imgsave")
        ucc.add(context.coordinator, name: "outline")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.webView = wv
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.navigationDelegate = context.coordinator
        wv.scrollView.delegate = context.coordinator
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 跳转索引被重置为 nil 时（同一条目可重复点击）同步清记录
        if jumpToIndex == nil { context.coordinator.lastJump = nil }
        // 大纲跳转：索引变化时驱动 WebView 滚动到对应标题
        if let idx = jumpToIndex, context.coordinator.lastJump != idx {
            context.coordinator.lastJump = idx
            uiView.evaluateJavaScript(
                "document.querySelectorAll('h1,h2,h3')[\(idx)].scrollIntoView({behavior:'smooth'})",
                completionHandler: nil)
        }
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        uiView.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
    }
}

/// 大纲目录条目（id = h1~h3 NodeList 中的下标，跳转时按同序查询）
struct OutlineItem: Identifiable {
    let id: Int
    let level: Int
    let text: String
}

/// 系统分享面板（UIActivityViewController 包装）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 网页编辑器兜底：加载服务端 Trilium 页面（#root/<noteId>），完整 CKEditor 能力
/// （表格/LaTeX/图片插入/格式刷）。首次使用需在页面里登录一次（密码+验证码），
/// cookie 由 WKWebsiteDataStore 持久化，之后免登录。
struct WebEditorView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            FullWebView(url: editorURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("网页编辑")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    private var editorURL: URL {
        let base = AppSettings.shared.serverURL
        return URL(string: base.absoluteString + "/#root/" + note.noteId) ?? base
    }
}

/// 完整网页视图（共享进程池，cookie/登录态跨打开复用）
struct FullWebView: UIViewRepresentable {
    static let sharedProcessPool = WKProcessPool()
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = FullWebView.sharedProcessPool
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 图片查看：双指捏合缩放（1x~6x）+ 双击 1x/2x 切换；放大后可拖动平移，缩回 1x 自动复位
struct ZoomableImageView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private func reset() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = min(max(lastScale * v, 1), 6) }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.01 { reset() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    if scale > 1 { reset() } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scale = 2; lastScale = 2 }
                    }
                }
        }
    }
}
