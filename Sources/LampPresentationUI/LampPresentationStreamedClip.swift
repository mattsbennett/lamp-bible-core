import Foundation
import LampCore
import Network
import SwiftUI
import WebKit

/// A clip streamed from YouTube or Vimeo (`LampPresentationClip`), played in
/// that site's own embedded player, as its terms ask: the video is never
/// taken out of it. Lamp only tells the player to play, pause and go back
/// to the start, through the messages the player itself listens for, and
/// loads nothing of the site's beyond the player.
///
/// It needs the internet while the deck is presented. Without it, or until
/// the clip is first played, the picture's still is what the room sees.
struct LampPresentationStreamedClip: View {
    let origin: LampPresentationClip.Origin
    let start: Double?
    let end: Double?
    /// Whether the presenter has reached the clip's step.
    let reached: Bool
    /// Whether the presenter has paused it.
    let paused: Bool

    @State private var online = LampPresentationConnection.shared.isOnline

    var body: some View {
        ZStack {
            if online {
                LampPresentationEmbeddedPlayer(
                    origin: origin, start: start, end: end, playing: reached && !paused, reached: reached
                )
                // The still stays in view until the clip is first played,
                // rather than the site's own picture of it.
                .opacity(reached ? 1 : 0)
            } else if reached {
                Label("This clip needs an internet connection", systemImage: "wifi.slash")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
            }
        }
        .task {
            for await status in LampPresentationConnection.shared.updates() {
                online = status
            }
        }
    }

    /// The page the player is embedded in, and the site it is embedded from.
    ///
    /// The clip's start and end are kept by the page, not the address, which
    /// takes whole seconds and would play words the author cut: it seeks to
    /// the start before the first play, and pauses at the end by watching
    /// the time, a little before the video's own end, so the site's end
    /// screen never shows. Going back to the still reloads a YouTube player:
    /// seeking one that has finished starts it playing again.
    static func page(for origin: LampPresentationClip.Origin, start: Double?, end: Double?) -> String? {
        let from = start.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let to = end.flatMap { $0.isFinite && $0 > from ? $0 : nil }
        let address: String
        let kind: String
        switch origin {
        case .youtube(let id):
            // The privacy-enhanced address: no cookies until it plays.
            let query = [
                "enablejsapi=1", "controls=0", "rel=0", "playsinline=1", "iv_load_policy=3",
                "disablekb=1", "fs=0", "origin=\(embedOrigin.absoluteString)",
            ]
            address = "https://www.youtube-nocookie.com/embed/\(id)?\(query.joined(separator: "&"))"
            kind = "youtube"
        case .vimeo(let id, let hash):
            var query = ["controls=0", "dnt=1", "playsinline=1", "title=0", "byline=0", "portrait=0", "keyboard=0"]
            if let hash { query.append("h=\(hash)") }
            address = "https://player.vimeo.com/video/\(id)?\(query.joined(separator: "&"))"
            kind = "vimeo"
        case .file, .unplayable:
            return nil
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><iframe id="player" src="\(address)" allow="autoplay; encrypted-media"></iframe>
        <script>
        const player = document.getElementById("player");
        const address = player.src;
        const kind = "\(kind)";
        const start = \(from);
        const end = \(to.map { String($0) } ?? "null");
        let started = false, playing = false, held = false, stalled = false, duration = null, listening = null, stopping = null;
        const send = message => player.contentWindow && player.contentWindow.postMessage(JSON.stringify(message), "*");
        const seek = seconds => kind === "youtube"
          ? send({ event: "command", func: "seekTo", args: [seconds, true] })
          : send({ method: "setCurrentTime", value: seconds });
        const pause = () => kind === "youtube"
          ? send({ event: "command", func: "pauseVideo", args: [] })
          : send({ method: "pause" });
        window.lampPlay = () => {
          if (held) return;
          playing = true;
          if (!started) { started = true; seek(start); }
          if (kind === "youtube") send({ event: "command", func: "playVideo", args: [] });
          else send({ method: "play" });
        };
        window.lampPause = () => { playing = false; clearTimeout(stopping); stopping = null; pause(); };
        window.lampRewind = () => {
          clearTimeout(stopping);
          stopping = null;
          playing = false;
          held = false;
          if (!started) return;
          started = false;
          if (kind === "youtube") {
            // Seeking a finished YouTube player plays it; a fresh one waits.
            window.lampReady = false;
            player.src = address;
          } else {
            pause();
            seek(start);
          }
        };
        const ready = () => {
          if (window.lampReady) return;
          window.lampReady = true;
          clearInterval(listening);
          // Run once: a command left here must not run again after a reload.
          const wanted = window.lampWanted;
          window.lampWanted = null;
          if (wanted) wanted();
        };
        // Stops at the clip's end, or just short of the video's, and holds
        // that frame. The players say where they are only every quarter
        // second or so, so near the end a timer is set for the time left.
        const hold = () => {
          clearTimeout(stopping);
          stopping = null;
          if (!held) { held = true; playing = false; pause(); }
        };
        // While the player waits for the network the clip is not moving, so
        // a timer set for the time left would stop it early: it is dropped,
        // and set again from the next time the player reports.
        const buffering = () => { stalled = true; clearTimeout(stopping); stopping = null; };
        const moving = () => { stalled = false; };
        const reached = seconds => {
          // The clip's end, but never past just short of the video's own,
          // where the site's end screen would show.
          const natural = duration ? duration - 0.3 : null;
          const stop = end !== null && natural !== null ? Math.min(end, natural) : (end !== null ? end : natural);
          if (stop === null || held || !playing || stalled || typeof seconds !== "number") return;
          const left = stop - seconds;
          // Close enough that the next word would be past the cut: stop now.
          // A timer can run late in a window that is not on screen, so the
          // cut errs a moment early rather than ever late.
          if (left <= 0.15) { hold(); return; }
          if (left < 0.75) {
            clearTimeout(stopping);
            stopping = setTimeout(hold, left * 1000);
          }
        };
        addEventListener("message", event => {
          let data; try { data = typeof event.data === "string" ? JSON.parse(event.data) : event.data; } catch { return; }
          if (!data) return;
          if (kind === "youtube") {
            if (data.event === "onReady") ready();
            const info = data.info || {};
            if (info.playerState === 3) buffering();
            if (info.playerState === 1) moving();
            if (typeof info.duration === "number" && info.duration > 0) duration = info.duration;
            if (typeof info.currentTime === "number") reached(info.currentTime);
          } else {
            // Vimeo takes no command until it says it is ready.
            if (data.event === "ready") {
              send({ method: "addEventListener", value: "timeupdate" });
              send({ method: "addEventListener", value: "bufferstart" });
              send({ method: "addEventListener", value: "bufferend" });
              ready();
            }
            if (data.event === "bufferstart") buffering();
            if (data.event === "bufferend") moving();
            // "playProgress" is the name its player sends the time under.
            if ((data.event === "timeupdate" || data.event === "playProgress") && data.data) {
              if (typeof data.data.duration === "number") duration = data.data.duration;
              reached(data.data.seconds);
            }
          }
        });
        player.addEventListener("load", () => {
          if (kind !== "youtube") return;
          // YouTube answers "listening" with onReady once its player is up;
          // asked until it does.
          clearInterval(listening);
          send({ event: "listening", id: "lamp" });
          listening = setInterval(() => send({ event: "listening", id: "lamp" }), 250);
        });
        </script></body></html>
        """
    }

    /// The address the page claims to be from: the players check where they
    /// are embedded, and refuse a page from nowhere.
    static let embedOrigin = URL(string: "https://lampbible.com")!
}

/// Whether this device can reach the internet, watched.
@MainActor
final class LampPresentationConnection {
    static let shared = LampPresentationConnection()

    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    private var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in LampPresentationConnection.shared.update(online) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func update(_ online: Bool) {
        isOnline = online
        listeners.values.forEach { $0.yield(online) }
    }

    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            listeners[id] = continuation
            continuation.yield(isOnline)
            continuation.onTermination = { _ in
                Task { @MainActor in LampPresentationConnection.shared.listeners[id] = nil }
            }
        }
    }
}

#if canImport(AppKit)
typealias LampPlatformViewRepresentable = NSViewRepresentable
#else
typealias LampPlatformViewRepresentable = UIViewRepresentable
#endif

/// The site's player in a web view of its own, told to play, pause or go
/// back to the start as the presenter moves.
struct LampPresentationEmbeddedPlayer: LampPlatformViewRepresentable {
    let origin: LampPresentationClip.Origin
    let start: Double?
    let end: Double?
    let playing: Bool
    let reached: Bool

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        /// For a test: called when the page has loaded.
        var onReady: (() -> Void)?
        /// The page has loaded, so a command reaches it, not the blank page
        /// before it.
        var pageReady = false
        var wanted = "lampRewind"
        var sent: String?

        /// Sends the wanted command once, when the page can take it; the
        /// page runs it when its player is ready.
        func send(_ view: WKWebView) {
            guard pageReady, wanted != sent else { return }
            sent = wanted
            view.evaluateJavaScript("""
                (function () {
                  const run = () => window.\(wanted) && window.\(wanted)();
                  // The latest command only: one sent while the player was
                  // not ready is replaced, and cleared when run.
                  if (window.lampReady) { window.lampWanted = null; run(); } else window.lampWanted = run;
                })();
                """)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            onReady?()
            send(webView)
        }

        /// Nothing in the player opens another page in this one.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            Self.allows(navigationAction.request.url, inMainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
                ? .allow : .cancel
        }

        /// The page itself (which WebKit names with a trailing slash, so a
        /// comparison of whole addresses turned it away and nothing ever
        /// played) and anything in the player's own frame; nothing else in
        /// the main frame, so a click in the player cannot take it elsewhere.
        static func allows(_ url: URL?, inMainFrame: Bool) -> Bool {
            guard inMainFrame else { return true }
            guard let url else { return false }
            if url.scheme == "about" { return true }
            let origin = LampPresentationStreamedClip.embedOrigin
            return url.scheme == origin.scheme && url.host == origin.host && (url.path.isEmpty || url.path == "/")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if canImport(UIKit)
        configuration.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        #endif
        return view
    }

    func update(_ view: WKWebView, _ coordinator: Coordinator) {
        guard let page = LampPresentationStreamedClip.page(for: origin, start: start, end: end) else { return }
        if coordinator.loaded != page {
            coordinator.loaded = page
            coordinator.pageReady = false
            coordinator.sent = nil
            view.loadHTMLString(page, baseURL: LampPresentationStreamedClip.embedOrigin)
        }
        coordinator.wanted = playing ? "lampPlay" : reached ? "lampPause" : "lampRewind"
        coordinator.send(view)
    }

    #if canImport(AppKit)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    #endif
}
