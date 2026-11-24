import AppKit
import Security
import WebKit

/// Offline WKWebView regression for Gemini's opening-image clipboard fallback.
///
/// The page below is a local synthetic Gemini composer: no file input at all
/// (matching the current menu-closed layout), the editor inside Gemini's own
/// `.xap-uploader-dropzone`, and an unnamed `gem-media-attachment` preview.
/// WebKit loads it with a simulated https://gemini.google.com URL, so no site
/// request and no account is touched.
///
/// Checked here:
///   1. clean paste: one `paste` ClipboardEvent with our DataTransfer yields
///      attachments-ready with real pixel digests, a recheck never pastes
///      again, and the final submit clicks exactly once with the receipt;
///   2. wrong attachment: a preview of a different image is refused before any
///      click, and neither the retry nor the recheck pastes again;
///   3. fresh document recheck: previews already on the page without a paste
///      record are refused with uploadAttempted=true and zero pastes.
///
/// Run from a temp directory:
///
///   xcrun swiftc -parse-as-library tests/attachment_paste_fallback.swift \
///       -o /tmp/attachment-paste-check
///   /tmp/attachment-paste-check shared/web-driver.js
///
/// Exit code 0 means every check passed. It writes nothing.

@main
struct AttachmentPasteFallbackCheck {
    static let origin = "https://gemini.google.com"
    static let href = "https://gemini.google.com/app/abc123def456"
    static let task = "opening-1:r1:independent:gemini"
    static let prompt = "请比较“先验证再扩展”和“先扩展再验证”。"
    static let imageName = "01-红.png"

    struct Handled {
        let result: [String: Any]
        let clicks: Int
        let pastes: Int
        let turns: Int
        var detail: [String: Any] { result["detail"] as? [String: Any] ?? [:] }
    }

    @MainActor
    static func main() async throws {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw NSError(domain: "QA could not disable keychain interaction", code: 1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let args = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard let driverURL = args.first else {
            throw NSError(domain: "usage: attachment-paste-check <web-driver.js>", code: 2)
        }
        let driver = try String(contentsOf: driverURL, encoding: .utf8)

        let red = png(width: 1600, height: 1462,
                      fill: NSColor(srgbRed: 0.85, green: 0.10, blue: 0.12, alpha: 1),
                      accent: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let blue = png(width: 1600, height: 1462,
                       fill: NSColor(srgbRed: 0.08, green: 0.18, blue: 0.85, alpha: 1),
                       accent: nil)
        let redURL = "data:image/png;base64," + red.base64EncodedString()
        let blueURL = "data:image/png;base64," + blue.base64EncodedString()
        let image: [String: String] = ["name": imageName, "mediaType": "image/png",
                                       "base64": red.base64EncodedString()]

        var keepAlive: [WKWebView] = []
        var keepWindows: [NSWindow] = []
        var summary: [String: Any] = [:]

        // 1) Clean paste fallback on the recognized Gemini layout.
        do {
            let web = try await makeWeb(driver: driver,
                                        config: ["previewColor": "same", "previewDelayMs": 0],
                                        redURL: redURL, blueURL: blueURL)
            keepAlive.append(web.web)
            keepWindows.append(web.window)

            // The judge/opening probe must accept this picker-less Gemini layout
            // as ready before any bytes are handed over.
            let probe = try await handle(web.web, probeMessage())
            try require(probe.result["status"] as? String == "ready",
                        "paste layout probe: \(probe.result)")
            try require((probe.detail["composer"] as? [String: Any])?["draftEmpty"] as? Bool == true,
                        "probe sees an empty composer: \(probe.result)")
            try require(probe.pastes == 0 && probe.clicks == 0, "probe is read-only")

            let prepared = try await handle(web.web, submitMessage(
                images: [image], prepare: true, recheck: false))
            try require(prepared.result["status"] as? String == "attachments-ready",
                        "clean paste prepare: \(prepared.result)")
            try require(prepared.detail["readyImageNames"] as? [String] == [imageName],
                        "clean paste ready names: \(prepared.result)")
            let pixels = prepared.detail["readyImagePixels"] as? [String] ?? []
            try require(pixels.count == 1 && pixels[0].count == 64,
                        "clean paste pixel proof: \(prepared.result)")
            try require(prepared.pastes == 1, "clean paste dispatched exactly once")
            try require(prepared.clicks == 0, "clean paste must not click")

            let recheck = try await handle(web.web, submitMessage(
                images: [image], prepare: true, recheck: true))
            try require(recheck.result["status"] as? String == "attachments-ready",
                        "clean recheck: \(recheck.result)")
            try require(recheck.detail["resumedUpload"] as? Bool == true,
                        "clean recheck resumed: \(recheck.result)")
            try require(recheck.pastes == 1, "recheck must never paste again")

            let submitted = try await handle(web.web, submitMessage(
                names: [imageName], pixels: pixels))
            try require(submitted.result["status"] as? String == "submitted",
                        "clean submit: \(submitted.result)")
            try require(submitted.detail["verifiedImageNames"] as? [String] == [imageName],
                        "clean submit receipt: \(submitted.result)")
            try require(submitted.pastes == 1, "submit must not paste again")
            try require(submitted.clicks == 1, "clean submit clicks exactly once")
            try require(submitted.turns == 1, "exactly one user turn")

            let repeated = try await handle(web.web, submitMessage(
                names: [imageName], pixels: pixels))
            try require(repeated.clicks == 1, "repeated submit never clicks twice")
            try require(repeated.pastes == 1, "repeated submit never pastes twice")
            try require(repeated.detail["deduped"] as? Bool == true,
                        "repeated submit is deduped: \(repeated.result)")
            summary["clean_paste"] = ["pastes": 1, "clicks": 1, "turns": 1]
            print("PASS clean Gemini paste fallback")
        }

        // 2) Wrong attachment: the preview is a different image.
        do {
            let web = try await makeWeb(driver: driver,
                                        config: ["previewColor": "wrong", "previewDelayMs": 0],
                                        redURL: redURL, blueURL: blueURL)
            keepAlive.append(web.web)
            keepWindows.append(web.window)

            let first = try await handle(web.web, submitMessage(
                images: [image], prepare: true, recheck: false))
            try require(first.result["status"] as? String == "error",
                        "wrong preview must not be ready: \(first.result)")
            try require(first.result["error"] as? String == "attachment-draft-conflict",
                        "wrong preview code: \(first.result)")
            try require(first.clicks == 0, "wrong preview must not click")
            try require(first.pastes == 1, "wrong preview: one attempted paste")

            let retry = try await handle(web.web, submitMessage(
                images: [image], prepare: true, recheck: false))
            try require(retry.result["error"] as? String == "attachment-draft-conflict",
                        "wrong preview retry: \(retry.result)")
            try require(retry.pastes == 1, "wrong preview retry must not paste again")

            let recheck = try await handle(web.web, submitMessage(
                images: [image], prepare: true, recheck: true))
            try require(recheck.result["error"] as? String == "attachment-draft-conflict",
                        "wrong preview recheck: \(recheck.result)")
            try require(recheck.detail["uploadAttempted"] as? Bool != false,
                        "wrong preview recheck keeps the intent: \(recheck.result)")
            try require(recheck.pastes == 1, "wrong preview recheck must not paste again")

            let submit = try await handle(web.web, submitMessage(names: [imageName]))
            try require(submit.result["status"] as? String == "error",
                        "wrong preview submit must not send: \(submit.result)")
            try require(submit.clicks == 0, "wrong preview never clicks")
            summary["wrong_attachment"] = ["pastes": 1, "clicks": 0, "turns": 0]
            print("PASS wrong Gemini attachment refused")
        }

        // 3) A fresh document already showing previews has no paste record.
        do {
            let web = try await makeWeb(driver: driver,
                                        config: ["previewColor": "same", "previewDelayMs": 0, "preMount": true],
                                        redURL: redURL, blueURL: blueURL)
            keepAlive.append(web.web)
            keepWindows.append(web.window)

            let recheck = try await handle(web.web, submitMessage(
                images: [image], prepare: true, recheck: true))
            try require(recheck.result["error"] as? String == "attachment-draft-conflict",
                        "fresh recheck: \(recheck.result)")
            try require(recheck.detail["uploadAttempted"] as? Bool == true,
                        "fresh recheck says upload attempted: \(recheck.result)")
            try require(recheck.detail["clickAttempted"] as? Bool == false,
                        "fresh recheck is pre-click: \(recheck.result)")
            try require(recheck.pastes == 0, "fresh recheck must not paste")
            try require(recheck.clicks == 0, "fresh recheck must not click")
            summary["fresh_recheck"] = ["pastes": 0, "clicks": 0]
            print("PASS fresh-document recheck refused without a paste record")
        }

        keepAlive.forEach { $0.stopLoading() }
        keepWindows.forEach { $0.orderOut(nil) }
        let out = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(data: out, encoding: .utf8) ?? "{}")
    }

    // MARK: - WebKit plumbing

    @MainActor
    static func makeWeb(driver: String, config: [String: Any], redURL: String,
                        blueURL: String) async throws -> (web: WKWebView, window: NSWindow) {
        var fixture = config
        fixture["previewDataURL"] = redURL
        fixture["wrongDataURL"] = blueURL
        let json = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let page = pageHTML(configJSON: String(data: json, encoding: .utf8) ?? "{}")
        let binding = URL(string: href)!
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: webConfig)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        web.loadSimulatedRequest(URLRequest(url: binding), responseHTML: page)
        let deadline = Date().addingTimeInterval(12)
        while web.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard web.url == binding else { throw NSError(domain: "simulated URL", code: 1) }
        _ = try await web.evaluateJavaScript(driver)
        return (web, window)
    }

    @MainActor
    static func handle(_ web: WKWebView, _ message: [String: Any]) async throws -> Handled {
        let response = try await web.callAsyncJavaScript("""
            const result = await window.__arenaWebDriver.handle(message);
            await Promise.all(Array.from(document.images, image => image.decode().catch(() => {})));
            return JSON.stringify({ result: result,
              clicks: window.clicks || 0, pasteCount: window.pasteCount || 0,
              turns: window.turns || 0 });
            """, arguments: ["message": message], in: nil, contentWorld: .page)
        guard let json = response as? String,
              let data = json.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = parsed["result"] as? [String: Any] else {
            throw NSError(domain: "driver response", code: 3)
        }
        return Handled(result: result,
                       clicks: (parsed["clicks"] as? NSNumber)?.intValue ?? -1,
                       pastes: (parsed["pasteCount"] as? NSNumber)?.intValue ?? -1,
                       turns: (parsed["turns"] as? NSNumber)?.intValue ?? -1)
    }

    static func probeMessage() -> [String: Any] {
        var message = submitMessage(names: [imageName])
        message["type"] = "arena.web.probe"
        message.removeValue(forKey: "prompt")
        return message
    }

    static func submitMessage(images: [[String: String]]? = nil, names: [String]? = nil,
                              pixels: [String]? = nil, prepare: Bool = false,
                              recheck: Bool = false) -> [String: Any] {
        var message: [String: Any] = [
            "type": "arena.web.submit",
            "taskId": task,
            "prompt": prompt,
            "selectors": [
                "input": "rich-textarea .ql-editor[contenteditable=\"true\"]",
                "send": "button[aria-label=\"Send message\"]",
                "user": "user-query",
                "answer": "model-response message-content",
                "done": "model-response gem-icon-button[data-test-id=\"regenerate-button\"]",
                "attachmentComposer": ["input-area-v2"],
            ],
            "options": ["submitTimeoutMs": 6000, "pollMs": 60, "sendEnableMs": 5000],
            "scope": ["origin": origin, "homeHref": origin + "/app", "href": href],
        ]
        if let images = images { message["images"] = images }
        if prepare { message["prepareImagesOnly"] = true }
        if recheck { message["recheckImagePreparation"] = true }
        if let names = names { message["imageNames"] = names }
        if let pixels = pixels { message["imagePixels"] = pixels }
        return message
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "attachment-paste-check", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func png(width: Int, height: Int, fill: NSColor, accent: NSColor?) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let accent = accent {
            accent.setFill()
            NSRect(x: 0, y: 0, width: 96, height: 96).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func pageHTML(configJSON: String) -> String {
        """
        <!doctype html><meta charset=utf-8>
        <style>
          rich-textarea, user-query, model-response message-content { display:block; white-space:pre-wrap; }
          .ql-editor { display:block; width:700px; min-height:32px; border:1px solid #999; }
          #previews gem-media-attachment, #previews img { display:block; }
          #previews img, user-query img { width:48px; height:48px; }
        </style>
        <input-area-v2>
          <div class="xap-uploader-dropzone">
            <rich-textarea><div id="editor" class="ql-editor" contenteditable="true"></div></rich-textarea>
          </div>
          <div id="previews"></div>
          <button aria-label="Send message">发送</button>
        </input-area-v2>
        <div id="log"></div>
        <script>
        (function () {
          'use strict';
          const cfg = Object.assign({ previewColor: 'same', previewDelayMs: 0, preMount: false },
                                    \(configJSON));
          const editor = document.getElementById('editor');
          const previews = document.getElementById('previews');
          const log = document.getElementById('log');
          const send = document.querySelector('button[aria-label="Send message"]');
          window.pasteCount = 0;
          window.clicks = 0;
          window.turns = 0;

          function mount(urls) {
            previews.replaceChildren();
            const wrap = document.createElement('gem-media-attachment');
            const image = new Image();
            image.src = cfg.previewColor === 'wrong'
              ? cfg.wrongDataURL
              : (urls.length ? urls[0] : cfg.previewDataURL);
            wrap.append(image);
            previews.append(wrap);
          }
          if (cfg.preMount) mount([]);

          editor.addEventListener('paste', (event) => {
            window.pasteCount += 1;
            const files = Array.from(event.clipboardData ? event.clipboardData.files : []);
            if (!files.length) return;
            event.preventDefault();
            const urls = files.map((file) => URL.createObjectURL(file));
            if (cfg.previewDelayMs > 0) setTimeout(() => mount(urls), cfg.previewDelayMs);
            else mount(urls);
          });

          send.addEventListener('click', () => {
            const prompt = editor.innerText || '';
            if (!prompt.trim()) return;
            window.clicks += 1;
            const turn = document.createElement('user-query');
            turn.textContent = prompt;
            for (const image of previews.querySelectorAll('img')) turn.append(image.cloneNode());
            log.append(turn);
            window.turns += 1;
            editor.replaceChildren();
            previews.replaceChildren();
          });
        })();
        </script>
        """
    }
}
