import SwiftUI
import Foundation

/// 登录页：服务器地址 + 密码 → 换 ETAPI token
struct LoginView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var server: String = AppSettings.shared.server
    @State private var password: String = ""
    @State private var status: String = ""
    @State private var busy = false
    /// 证书/网络类失败时给一个「切内网地址」的快捷入口
    @State private var showLANShortcut = false

    var body: some View {
        NavigationView {
            Form {
                Section("连接") {
                    TextField("服务器地址", text: $server)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.URL)
                    // 粘贴混入全角括号/空格时肉眼看不见，但 DNS 会整个解析失败（10-20 事故）→ 提前亮出来
                    if AppSettings.serverAddressHasJunk(server) {
                        Text("地址里混入了全角符号（粘贴带入的），登录时会自动清洗")
                            .font(.footnote).foregroundColor(.orange)
                    }
                    if !AppSettings.isValidServerAddress(server) {
                        Text("地址无效：需要 http:// 或 https:// 开头的完整地址")
                            .font(.footnote).foregroundColor(.red)
                    }
                    SecureField("Trilium 登录密码", text: $password)
                }
                Section {
                    Button(action: doLogin) {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("登录").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(busy || password.isEmpty || !AppSettings.isValidServerAddress(server))
                }
                if !status.isEmpty {
                    Section { Text(status).font(.footnote).foregroundColor(.secondary) }
                }
                if showLANShortcut {
                    Section {
                        Button {
                            let backup = AppSettings.shared.serverBackup
                            server = backup.isEmpty ? AppConfig.defaultBackupServer : backup
                            status = "已切到备用地址，点「登录」重试（内网地址需与 NAS 在同一 Wi-Fi）"
                            showLANShortcut = false
                        } label: {
                            Label("改用备用地址", systemImage: "wifi")
                        }
                    }
                }
                Section(footer: Text("默认走 ddnsto 公网，家内外通用；公网连不上会自动切到备用地址（内网 http://192.168.31.198:18190），切回来不用重新登录。")) {
                    EmptyView()
                }
            }
            .navigationTitle("连接 Trilium")
            .onAppear { server = settings.server }
        }
        .navigationViewStyle(.stack)
    }

    private func doLogin() {
        busy = true
        status = "连接中…"
        // 先清洗再登录：脏字符（全角括号等）会让 DNS 直接解析失败
        let cleaned = AppSettings.sanitizeServerAddress(server)
        server = cleaned
        AppLogger.shared.log("点击登录：服务器 \(cleaned)")
        Task {
            do {
                // 登录打到输入框里的地址（不是存储里的旧地址）
                let token = try await ETAPIClient.shared.login(password: password, at: URL(string: cleaned))
                settings.save(token: token, server: cleaned)
                AppLogger.shared.log("登录成功：token 长度 \(token.count)")
                password = ""
                status = ""
            } catch {
                showLANShortcut = false
                let ns = error as NSError
                if let api = error as? APIError {
                    let hint: String
                    switch api {
                    case .http(let code):
                        hint = code == 401 ? "（密码不对）"
                            : code == 429 ? "（失败次数过多，稍后再试）" : ""
                    default: hint = ""
                    }
                    status = "登录失败：\(api.localizedDescription)\(hint)"
                } else if ns.domain == NSURLErrorDomain {
                    // 证书类错误单独说清楚：内网穿透的证书到期时，报错原文是
                    // "An SSL error has occurred…"，用户根本看不懂发生了什么
                    switch URLError.Code(rawValue: ns.code) {
                    case .secureConnectionFailed, .serverCertificateHasBadDate,
                         .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                         .serverCertificateNotYetValid:
                        status = "登录失败：服务器证书无效或已过期（内网穿透证书到期时会这样）。可以先用内网地址登录，或等证书续期后再切回公网地址。"
                        showLANShortcut = true
                    case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                         .notConnectedToInternet, .dnsLookupFailed:
                        status = "登录失败：连不上服务器（检查网络，或改用内网地址）"
                        showLANShortcut = true
                    case .timedOut:
                        status = "登录失败：连接超时，服务端没有响应"
                    default:
                        status = "登录失败：\(error.localizedDescription)"
                    }
                } else {
                    status = "登录失败：\(error.localizedDescription)"
                }
            }
            busy = false
        }
    }
}
