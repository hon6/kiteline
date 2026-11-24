import Foundation

/// 网页版（11-24 重新开放，只走 HTTPS）：手机用浏览器打开 https://电脑IP:8766/app/ 就能用，不用装 App。
/// 页面是微信小程序原样编译成的网页（web-app/build.py，打包时拷进 Resources/webapp）；数据不走这里的 /api，
/// 而是和小程序一样走端到端加密隧道（MPGate 的加密入口 wss://IP:8769/mp）。
/// 手机相机扫「手机访问」里的配对二维码，打开的是 /pair?t=…&mk=…，这里转到 /app/?t=…，网页版自己完成配对。
enum WebApp {
    static var folder: URL? { Bundle.main.url(forResource: "webapp", withExtension: nil) }
    static var available: Bool { folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false }

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "json": "application/json", "webmanifest": "application/manifest+json", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp", "mp3": "audio/mpeg",
        "wav": "audio/wav", "m4a": "audio/mp4", "woff2": "font/woff2", "ttf": "font/ttf",
    ]

    /// 只连这台电脑（加密隧道）和官方中继（订阅状态、经中继远程），不加载任何外部脚本
    static let csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://tars.betac.cn; "
        + "media-src 'self' blob: data:; connect-src 'self' wss: https://tars.betac.cn; worker-src 'self' blob:; "
        + "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    /// GET /app/…：静态文件。路径里不许有 ..，只给 webapp 目录里的文件
    static func serve(_ path: String) -> HTTPResponse {
        guard let root = folder else { return .text("网页版未包含在这个版本中", status: 404) }
        var rel = String(path.dropFirst("/app".count))
        if rel.isEmpty { return .redirect("/app/") }
        rel = rel.removingPercentEncoding ?? rel
        if rel.hasSuffix("/") { rel += "index.html" }
        let parts = rel.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else {
            return .text("not found", status: 404)
        }
        let url = parts.reduce(root) { $0.appendingPathComponent($1) }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: url) else { return .text("not found", status: 404) }
        let ext = url.pathExtension.lowercased()
        return HTTPResponse(status: 200, headers: [
            "Content-Type": types[ext] ?? "application/octet-stream",
            // 网页版随 Kiteline 一起更新：每次都向电脑确认一下（本机网络，几乎没有开销）
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": csp,
            "Referrer-Policy": "no-referrer",
            "X-Robots-Tag": "noindex, nofollow",
        ], body: data)
    }

    /// 配对二维码被手机相机直接打开（GET /?t=…&mk=…，或 /pair?t=…，不带配对码）：转到网页版，带着原参数
    static func pairRedirect(_ request: HTTPRequest) -> HTTPResponse? {
        guard available, request.method == "GET", request.query["code"] == nil,
              request.query["t"] != nil, request.query["mk"] != nil else { return nil }
        let query = request.query.map { key, value in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            return (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.sorted().joined(separator: "&")
        return .redirect("/app/?" + query, headers: ["Cache-Control": "no-store", "Referrer-Policy": "no-referrer"])
    }
}
