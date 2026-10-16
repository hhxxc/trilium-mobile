import SwiftUI

/// 登录页：服务器地址 + 密码 → 换 ETAPI token
struct LoginView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var server: String = AppSettings.shared.server
    @State private var password: String = ""
    @State private var status: String = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section("连接") {
                    TextField("服务器地址", text: $server)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.URL)
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
                    .disabled(busy || password.isEmpty)
                }
                if !status.isEmpty {
                    Section { Text(status).font(.footnote).foregroundColor(.secondary) }
                }
                Section(footer: Text("默认走 ddnsto 公网，家内外通用；在家可改内网 http://192.168.31.198:18190 更快。")) {
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
        Task {
            do {
                let token = try await ETAPIClient.shared.login(password: password)
                settings.save(token: token, server: server)
                password = ""
                status = ""
            } catch {
                let hint: String
                if let api = error as? APIError {
                    switch api {
                    case .http(let code):
                        hint = code == 401 ? "（密码不对）"
                            : code == 429 ? "（失败次数过多，稍后再试）" : ""
                    default: hint = ""
                    }
                    status = "登录失败：\(api.localizedDescription)\(hint)"
                } else {
                    status = "登录失败：\(error.localizedDescription)（连不上服务器）"
                }
            }
            busy = false
        }
    }
}
