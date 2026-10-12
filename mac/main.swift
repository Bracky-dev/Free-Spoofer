import AppKit
import WebKit

let python = "/usr/bin/python3"
let uiURL = URL(string: "http://127.0.0.1:8765/")!
let tunneldURL = URL(string: "http://127.0.0.1:49151/")!

func shell(_ args: [String], env: [String: String] = [:]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func get(_ url: URL) -> String? {
    var req = URLRequest(url: url)
    req.timeoutInterval = 2
    let sem = DispatchSemaphore(value: 0)
    var body: String?
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data { body = String(data: data, encoding: .utf8) }
        sem.signal()
    }.resume()
    sem.wait()
    return body
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var server: Process?
    let userSite = shell([python, "-m", "site", "--user-site"])

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.uiDelegate = self
        web.navigationDelegate = self
        web.loadHTMLString(statusPage("Starting…"), baseURL: nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Free Spoofer"
        window.contentView = web
        window.setFrameAutosaveName("main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global().async { self.boot() }
    }

    func boot() {
        let env = ["PYTHONWARNINGS": "ignore", "PYTHONPATH": userSite]
        if shell([python, "-c", "import pymobiledevice3, fastapi, uvicorn"], env: env).contains("Error") {
            return show("Missing Python packages. In Terminal run:<br><code>pip3 install --user pymobiledevice3 fastapi uvicorn</code>")
        }
        if get(tunneldURL) == nil {
            show("Starting device tunnel — enter your Mac password…")
            let cmd = "PYTHONPATH='\(userSite)' PYTHONWARNINGS=ignore \(python) -m pymobiledevice3 remote tunneld -d >/dev/null 2>&1"
            var err: NSDictionary?
            DispatchQueue.main.sync {
                _ = NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?.executeAndReturnError(&err)
            }
            if err != nil { return show("The tunnel needs admin rights to talk to the iPhone. Quit and reopen to try again.") }
            for _ in 0..<20 where get(tunneldURL) == nil { sleep(1) }
        }
        show("Looking for your iPhone (USB or same Wi-Fi)…")
        for _ in 0..<20 where (get(tunneldURL) ?? "{}") == "{}" { sleep(1) }
        show("Mounting Developer Disk Image…")
        _ = shell([python, "-m", "pymobiledevice3", "mounter", "auto-mount", "--tunnel", ""], env: env)

        if get(uiURL.appendingPathComponent("api/status")) == nil {
            let script = Bundle.main.resourceURL!.appendingPathComponent("spoofer.py").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [script]
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            try? p.run()
            server = p
            for _ in 0..<30 where get(uiURL.appendingPathComponent("api/status")) == nil { usleep(300_000) }
        }
        _ = shell(["/usr/bin/curl", "-s", "-m", "15", "-X", "POST", uiURL.appendingPathComponent("api/connect").absoluteString])
        DispatchQueue.main.async { self.web.load(URLRequest(url: uiURL)) }
    }

    func show(_ msg: String) {
        DispatchQueue.main.async { self.web.loadHTMLString(self.statusPage(msg), baseURL: nil) }
    }

    func statusPage(_ msg: String) -> String {
        """
        <html><head><style>
          body{margin:0;font:15px -apple-system;color:#888;background:Canvas;height:100vh;display:flex;flex-direction:column}
          main{flex:1;display:flex;align-items:center;justify-content:center;text-align:center;padding:0 24px}
          footer{padding:14px;text-align:center;font-size:12px}
          a{color:CanvasText;font-weight:600;text-decoration:none;display:inline-flex;align-items:center;gap:5px;vertical-align:middle}
          a:hover{color:#2563eb} svg{width:16px;height:16px;fill:currentColor}
        </style></head><body>
          <main><div style="max-width:520px">\(msg)</div></main>
          <footer>Made by <a href="https://github.com/bracky-dev"><svg viewBox="0 0 16 16"><path d="\(githubPath)"/></svg>bracky-dev</a></footer>
        </body></html>
        """
    }

    let githubPath = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"

    // Clicked links (e.g. the GitHub credit) open in the default browser
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url, url.host != "127.0.0.1" {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // GPX import uses <input type=file>
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        _ = shell(["/usr/bin/curl", "-s", "-m", "3", "-X", "POST", uiURL.appendingPathComponent("api/clear").absoluteString])
        server?.terminate()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Free Spoofer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc func reload() { web.load(URLRequest(url: uiURL)) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
