import SwiftUI
import WebKit

struct GoogleLoginView: View {
    var token: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在 Google 页面完成登录；凭据仅保存于本机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red).padding() }
                GoogleWebView(token: { value in dismiss(); token(value) }, failed: { error = $0 })
            }
            .navigationTitle("连接 Google").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct GoogleWebView: UIViewRepresentable {
    let token: (String) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        web.load(URLRequest(url: URL(string: "https://accounts.google.com/EmbeddedSetup")!))
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak coordinator = context.coordinator] _ in
            coordinator?.capture()
        }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.finished = true
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: GoogleWebView
        weak var web: WKWebView?
        var timer: Timer?
        var finished = false
        init(_ parent: GoogleWebView) { self.parent = parent }
        func capture() {
            guard !finished else { return }
            web?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished,
                      let cookie = cookies.first(where: {
                          let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                          return $0.name == "oauth_token" && (domain == "google.com" || domain.hasSuffix(".google.com")) && $0.value.count >= 16 && $0.value.count <= 8192
                      }) else { return }
                self.finished = true
                self.timer?.invalidate()
                self.web?.stopLoading()
                self.parent.token(cookie.value)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let host = url.host?.lowercased() ?? ""
            let allowed = url.scheme == "https" && (host == "google.com" || host.hasSuffix(".google.com"))
            if url.query?.contains("disallowed_useragent") == true {
                parent.failed(HarborError("WEB_LOGIN_REJECTED").localizedDescription)
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { capture() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                parent.failed("Google 页面加载失败，请检查网络后重新打开。")
            }
        }
    }
}
