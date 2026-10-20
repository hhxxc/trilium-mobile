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
    static func fileExtension(mime: String?, name: String) -> String {
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
    static func sniffExtension(_ data: Data) -> String? {
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
        do {
            parentTitle = try await ETAPIClient.shared.getNote(pid).title
        } catch {
            AppLogger.shared.log("面包屑父标题加载失败[\(note.title)]: \(error.localizedDescription)")
        }
        do {
            siblings = try await ETAPIClient.shared.childNotes(of: pid)
        } catch {
            AppLogger.shared.log("上下篇兄弟加载失败[\(note.title)]: \(error.localizedDescription)")
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
                } else {
                    // 不 try? 吞错：失败让它抛到下面 catch，记日志 + 显示错误
                    let data = try await ETAPIClient.shared.getContentData(note.noteId)
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
    /// 进入编辑时服务端的版本戳（保存前拿它比对，别处改过就先问用户再写）
    @State private var baseStamp: String?
    @State private var showConflict = false
    @State private var loadingServer = false

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
                if loadingServer {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("载入服务端版本…").font(.footnote).foregroundColor(.secondary)
                        }
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
                baseStamp = note.versionStamp
            }
            // 保存前发现「别处改过这篇」→ 让用户裁决，不静默覆盖
            .confirmationDialog("这篇笔记在别处被修改过", isPresented: $showConflict, titleVisibility: .visible) {
                Button("用我的改动覆盖") {
                    Task { await commit() }
                }
                Button("放弃我的改动，载入服务端最新版", role: .destructive) {
                    Task { await loadServerVersion() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("你编辑期间这篇笔记在别处（桌面端/网页）被改过。直接保存会覆盖对方的改动。")
            }
        }
    }

    private var titleChanged: Bool { title != note.title }
    private var contentChanged: Bool { note.type == "code" && content != initialContent }

    private func save() {
        saving = true
        Task {
            guard titleChanged || contentChanged else {
                dismiss()          // 没改动就别写，省一次网络往返
                saving = false
                return
            }
            // 在线且拿得到服务端版本戳 → 先比对，防覆盖
            // ⚠️ 拆两步写：versionStamp 是 String?，`try? await ...versionStamp`
            //    会叠成 String??（Swift try? 嵌套可选），后面 isEmpty 编译不过
            let fresh: Note? = try? await ETAPIClient.shared.getNote(note.noteId)
            if let base = baseStamp, !base.isEmpty,
               let cur = fresh?.versionStamp, !cur.isEmpty, cur != base {
                AppLogger.shared.log("保存前发现冲突[\(note.noteId)]：服务端 \(cur) ≠ 基准 \(base)")
                saving = false
                showConflict = true
                return
            }
            await commit()
        }
    }

    /// 真正落库：在线直写，失败进离线队列（带上版本戳，补交时再比对一次）
    private func commit() async {
        let t = titleChanged, c = contentChanged
        do {
            // 标题变化 → PATCH；正文变化（code 类型）→ PUT content
            if t {
                _ = try await ETAPIClient.shared.patchNote(note.noteId, fields: ["title": title])
            }
            if c {
                try await ETAPIClient.shared.putContent(note.noteId, content: content)
            }
        } catch {
            // 断网/失败：入离线队列，联网后自动补交（队列保序，先标题后正文）
            if t {
                NoteCache.shared.enqueue(PendingOp(kind: "patchTitle", id: UUID().uuidString,
                    noteId: note.noteId, title: title, content: nil, parentNoteId: nil,
                    createdAt: Date(), baseStamp: baseStamp))
            }
            if c {
                NoteCache.shared.enqueue(PendingOp(kind: "putContent", id: UUID().uuidString,
                    noteId: note.noteId, title: nil, content: content, parentNoteId: nil,
                    createdAt: Date(), baseStamp: baseStamp))
            }
        }
        // 无论在线离线都更新本地缓存并关闭（离线队列保证最终一致）
        NoteCache.shared.saveContent(note.noteId, text: content)
        if t {
            NotificationCenter.default.post(name: .noteMetaChanged, object: nil)
        }
        if !NoteCache.shared.pendingOps.isEmpty {
            Task { await NoteCache.shared.flushPendingOps() }  // 顺手补交旧积压
        }
        dismiss()
        saving = false
    }

    /// 放弃本地改动：拉服务端最新标题+正文回填，编辑基准同步更新（编辑器不关，用户接着看）
    private func loadServerVersion() async {
        loadingServer = true
        do {
            let fresh = try await ETAPIClient.shared.getNote(note.noteId)
            let freshContent = try? await ETAPIClient.shared.getContent(note.noteId)
            title = fresh.title
            if let fc = freshContent { content = fc }
            baseStamp = fresh.versionStamp
            NoteCache.shared.saveContent(note.noteId, text: content)
            AppLogger.shared.log("冲突裁决：已载入服务端版本 \(note.noteId)")
            errorMsg = "已载入服务端最新版本"
        } catch {
            errorMsg = "载入服务端版本失败：\(error.localizedDescription)"
        }
        loadingServer = false
    }
}

extension Notification.Name {
    /// 笔记标题等元数据被修改（编辑器保存后广播，首页列表就地刷新）
    static let noteMetaChanged = Notification.Name("trilium.noteMetaChanged")
    /// 阅读页出现（从抽屉树点笔记后，首页据此收起抽屉，避免树盖在阅读页上）
    static let noteDetailAppeared = Notification.Name("trilium.noteDetailAppeared")
}
