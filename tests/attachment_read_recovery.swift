import AppKit
import Security
import WebKit

/// Replay the signed bundle's read command in a fresh, nonpersistent WKWebView.
/// WebKit supplies the fixed conversation URL locally; it sends no site request.
@main
struct AttachmentReadRecoveryCheck {
    @MainActor
    static func main() async throws {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw NSError(domain: "QA could not disable keychain interaction", code: 1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        let driver = try String(contentsOf: files[0], encoding: .utf8)
        let page = try String(contentsOf: files[1], encoding: .utf8)
        let message = try JSONSerialization.jsonObject(with: Data(contentsOf: files[2])) as! [String: Any]
        let scope = message["scope"] as! [String: Any]
        let binding = URL(string: scope["href"] as! String)!
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 650), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        web.loadSimulatedRequest(URLRequest(url: binding), responseHTML: page)
        let loaded = Date().addingTimeInterval(12)
        while web.isLoading && Date() < loaded { try await Task.sleep(nanoseconds: 50_000_000) }
        guard web.url == binding else { throw NSError(domain: "simulated URL", code: 1) }
        _ = try await web.evaluateJavaScript(driver)
        let response = try await web.callAsyncJavaScript("""
            await Promise.all(Array.from(document.images, image => image.decode()));
            let result;
            for(let i=0;i<5;i++){
                result=await window.__arenaWebDriver.handle(message);
                if(result.status!=='pending')break;
                await new Promise(resolve=>setTimeout(resolve,160));
            }
            return JSON.stringify({result,clicks:window.fixtureClicks||0});
            """, arguments: ["message": message], in: nil, contentWorld: .page)
        guard let json = response as? String else { throw NSError(domain: "driver response", code: 2) }
        print(json)
    }
}
