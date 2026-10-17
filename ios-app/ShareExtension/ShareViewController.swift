import UIKit

/// 分享扩展：系统分享菜单里的「Trilium」入口。
/// 把文本/链接收进宿主的速记通道（宿主注册了 trilium:// scheme，
/// 通过 URL 把内容带回宿主 → 走离线写入队列，断网也能收）。
/// 不用 storyboard：NSExtensionPrincipalClass 直接指定本类。
final class ShareViewController: UIViewController {

    private let textView = UITextView()
    private let statusLabel = UILabel()

    /// 从 extensionContext 里收集的文本（网页 URL / 选中文本 / 备注文字）
    private var sharedText = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        collectItems()
    }

    private func buildUI() {
        let title = UILabel()
        title.text = "存入 Trilium"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "square.and.arrow.down"))
        icon.tintColor = UIColor(red: 0.17, green: 0.61, blue: 0.56)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        textView.font = .systemFont(ofSize: 15)
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 1
        textView.layer.cornerRadius = 10
        textView.isEditable = true
        textView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let save = UIButton(type: .system)
        save.setTitle("存入收件箱", for: .normal)
        save.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        save.backgroundColor = UIColor(red: 0.17, green: 0.61, blue: 0.56)
        save.setTitleColor(.white, for: .normal)
        save.layer.cornerRadius = 12
        save.translatesAutoresizingMaskIntoConstraints = false
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        view.addSubview(icon)
        view.addSubview(title)
        view.addSubview(textView)
        view.addSubview(statusLabel)
        view.addSubview(save)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            textView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            textView.heightAnchor.constraint(equalToConstant: 160),

            statusLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            save.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            save.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            save.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            save.heightAnchor.constraint(equalToConstant: 48),

            cancel.topAnchor.constraint(equalTo: save.bottomAnchor, constant: 10),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    /// 提取分享内容：优先正文文本，其次 URL；纯图片暂不支持（需 App Group 传二进制）
    private func collectItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            statusLabel.text = "无法读取分享内容"
            return
        }
        var found = false
        func handle(_ item: Any?) {
            if let s = item as? String, !s.isEmpty { append(s) }
            else if let url = item as? URL { append(url.absoluteString) }
        }
        func append(_ s: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                found = true
                // 多个 provider 回调按行拼进文本框（可编辑）
                let cur = self.textView.text ?? ""
                self.textView.text = cur.isEmpty ? s : cur + "\n" + s
            }
        }
        for item in items {
            for provider in (item.attachments ?? []) {
                if provider.hasItemConformingToTypeIdentifier("public.text") {
                    provider.loadItem(forTypeIdentifier: "public.text", options: nil) { handle($0) }
                } else if provider.hasItemConformingToTypeIdentifier("public.url") {
                    provider.loadItem(forTypeIdentifier: "public.url", options: nil) { handle($0) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !found, (self.textView.text ?? "").isEmpty else { return }
            self.statusLabel.text = "未发现可收存的文本/链接（图片暂不支持）"
        }
    }

    @objc private func saveTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusLabel.text = "内容为空"
            return
        }
        // 经宿主 URL scheme 带回内容（长度限制内；速记场景足够）
        var comps = URLComponents(string: "trilium://quick-note")
        comps?.queryItems = [URLQueryItem(name: "text", value: String(text.prefix(6000)))]
        guard let url = comps?.url else {
            statusLabel.text = "内容编码失败"
            return
        }
        extensionContext?.open(url, completionHandler: { ok in
            DispatchQueue.main.async {
                if ok {
                    self.finish()
                } else {
                    self.statusLabel.text = "无法回传主 App，请确认已安装 Trilium"
                }
            }
        })
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: "trilium.share", code: NSUserCancelledError))
    }
}
