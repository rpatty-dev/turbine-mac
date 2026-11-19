import AppKit
import CoreImage
import CoreMedia
import MetalFX
import MetalKit
import ScreenCaptureKit
import WebKit

// Turbine for Mac: plays play.xbox.com in a web view with the Turbine controls injected, captures that
// window with ScreenCaptureKit, upscales it with MetalFX and generates in-between frames on the GPU.

let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

// MARK: - Shaders

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vtx(uint id [[vertex_id]]) {
  float2 p = float2((id << 1) & 2, id & 2);
  V o; o.p = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;
}
constexpr sampler ls(filter::linear, address::clamp_to_edge);
fragment float4 luma(V i [[stage_in]], texture2d<float> t [[texture(0)]]) {
  return float4(dot(t.sample(ls, i.uv).rgb, float3(0.299, 0.587, 0.114)));
}
// Block matching: offset d (uv units) where prev(x) ~ cur(x + d).
fragment float4 flow(V i [[stage_in]], texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]],
                     constant float2 &lpx [[buffer(0)]]) {
  const int R = 10; float pa[9]; float2 q[9];
  for (int j = 0; j < 3; j++) for (int k = 0; k < 3; k++) {
    int n = j * 3 + k; q[n] = i.uv + float2(k - 1, j - 1) * lpx * 1.5; pa[n] = a.sample(ls, q[n]).r;
  }
  float best = 1e9; float2 bd = 0;
  for (int y = -R; y <= R; y++) for (int x = -R; x <= R; x++) {
    float2 d = float2(x, y); float c = 0.004 * length(d);
    for (int n = 0; n < 9; n++) c += abs(pa[n] - b.sample(ls, q[n] + d * lpx).r);
    if (c < best) { best = c; bd = d; }
  }
  return float4(bd * lpx, 0, 1);
}
// Warp prev and cur toward time t along the motion field and blend.
fragment float4 present(V i [[stage_in]], texture2d<float> prev [[texture(0)]], texture2d<float> cur [[texture(1)]],
                        texture2d<float> fl [[texture(2)]], constant float &t [[buffer(0)]]) {
  float2 f = fl.sample(ls, i.uv).rg;
  return float4(mix(prev.sample(ls, i.uv - f * t).rgb, cur.sample(ls, i.uv + f * (1 - t)).rgb, t), 1);
}
"""

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate, SCStreamOutput {
  let device = MTLCreateSystemDefaultDevice()!
  lazy var queue = device.makeCommandQueue()!
  var cache: CVMetalTextureCache!
  var pLuma: MTLRenderPipelineState!, pFlow: MTLRenderPipelineState!, pPresent: MTLRenderPipelineState!
  weak var view: MTKView?

  var upscaleOn = ProcessInfo.processInfo.environment["TURBINE_NOFX"] == nil, frameGenOn = true
  var scaler: MTLFXSpatialScaler?
  var sizeKey = ""
  var ups: [MTLTexture] = [], lumas: [MTLTexture] = []
  var flowTex: MTLTexture!
  var prevLuma = false, haveFrame = false

  // Newest captured frame, handed from the capture queue to the draw loop.
  let lock = NSLock()
  var pending: CVPixelBuffer?
  var pendingAt = 0.0

  var arrival = 0.0, streamInterval = 1 / 60.0, displayInterval = 1 / 60.0, lastDraw = 0.0
  var lastT = 1.0, interpolating = false
  var fgActive = false, flipSince = 0.0
  var status = "METALFX on  FRAMEGEN starting"
  var dumped = false
  let startTime = CACurrentMediaTime()
  var onFirstFrame: (() -> Void)? // reveals the overlay once there is a real frame to show

  // Duplicate detection: xCloud pads a 30 fps game to a 60 fps stream by repeating frames.
  // Dropping the repeats makes the pipeline see the real 30 fps motion, so frame gen engages.
  var lastSample = [UInt8](), lastUniqueAt = 0.0
  func isDuplicate(_ pb: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let cols = 32, rows = 18, n = cols * rows
    var s = [UInt8](repeating: 0, count: n)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var idx = 0
    for ry in 0..<rows { let y = (h * ry) / rows
      for rx in 0..<cols { let x = (w * rx) / cols; s[idx] = p[y * bpr + x * 4 + 1]; idx += 1 } } // G channel ≈ luma
    defer { lastSample = s }
    guard lastSample.count == n else { return false }
    var sad = 0; for i in 0..<n { sad += abs(Int(s[i]) - Int(lastSample[i])) }
    return sad < n * 3 // average difference < 3/255 => same frame
  }

  func attach(_ v: MTKView) {
    view = v
    v.device = device; v.delegate = self
    v.colorPixelFormat = .bgra8Unorm; v.framebufferOnly = true
    v.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
    v.presentsWithTransaction = false // present immediately, don't sync with Core Animation commit
    let lib = try! device.makeLibrary(source: shaderSource, options: nil)
    func pipe(_ name: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = lib.makeFunction(name: "vtx"); d.fragmentFunction = lib.makeFunction(name: name)
      d.colorAttachments[0].pixelFormat = fmt
      return try! device.makeRenderPipelineState(descriptor: d)
    }
    pLuma = pipe("luma", .r16Float); pFlow = pipe("flow", .rg16Float); pPresent = pipe("present", .bgra8Unorm)
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, let pb = sb.imageBuffer,
          let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
          (info[.status] as? Int) == SCFrameStatus.complete.rawValue else { return }
    if ProcessInfo.processInfo.environment["TURBINE_DUMP"] != nil, !dumped, CACurrentMediaTime() - startTime > 8 { // debug: save one captured frame
      dumped = true
      let ci = CIImage(cvPixelBuffer: pb)
      if let cg = CIContext().createCGImage(ci, from: ci.extent) {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "turbine-frame.png"))
      }
    }
    let now = CACurrentMediaTime()
    // Drop padded duplicates (only with frame gen on); keep going on static scenes so nothing freezes.
    if frameGenOn, isDuplicate(pb), now - lastUniqueAt < 0.12 { return }
    lastUniqueAt = now
    lock.lock(); pending = pb; pendingAt = now; lock.unlock()
  }

  func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat, _ extra: MTLTextureUsage = []) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h), mipmapped: false)
    d.usage = MTLTextureUsage([.renderTarget, .shaderRead]).union(extra); d.storageMode = .private
    return device.makeTexture(descriptor: d)!
  }

  func pass(_ cb: MTLCommandBuffer, _ ps: MTLRenderPipelineState, _ target: MTLTexture, _ texs: [MTLTexture], _ consts: [Float] = []) {
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
    let e = cb.makeRenderCommandEncoder(descriptor: rp)!
    e.setRenderPipelineState(ps)
    for (i, t) in texs.enumerated() { e.setFragmentTexture(t, index: i) }
    if !consts.isEmpty { var c = consts; e.setFragmentBytes(&c, length: c.count * 4, index: 0) }
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    e.endEncoding()
  }

  func ensure(_ w: Int, _ h: Int, _ ow: Int, _ oh: Int, _ cb: MTLCommandBuffer) {
    let key = "\(w)x\(h)>\(ow)x\(oh)"
    guard key != sizeKey else { return }
    sizeKey = key
    let sd = MTLFXSpatialScalerDescriptor()
    sd.inputWidth = w; sd.inputHeight = h; sd.outputWidth = ow; sd.outputHeight = oh
    sd.colorTextureFormat = .bgra8Unorm; sd.outputTextureFormat = .bgra8Unorm; sd.colorProcessingMode = .perceptual
    scaler = (ow >= w && oh >= h) ? sd.makeSpatialScaler(device: device) : nil
    let ou = scaler?.outputTextureUsage ?? []
    ups = [tex(ow, oh, .bgra8Unorm, ou), tex(ow, oh, .bgra8Unorm, ou)]
    lumas = [tex(w / 4, h / 4, .r16Float), tex(w / 4, h / 4, .r16Float)]
    flowTex = tex(w / 16, h / 16, .rg16Float)
    let rp = MTLRenderPassDescriptor() // zero motion
    rp.colorAttachments[0].texture = flowTex; rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); rp.colorAttachments[0].storeAction = .store
    cb.makeRenderCommandEncoder(descriptor: rp)!.endEncoding()
    prevLuma = false; haveFrame = false
  }

  // Upscale the new frame and, with frame gen on, estimate motion from the previous one.
  func process(_ pb: CVPixelBuffer, _ cb: MTLCommandBuffer, _ v: MTKView) -> Bool {
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var cvt: CVMetalTexture?
    guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvt) == kCVReturnSuccess,
          let cvt, let src = CVMetalTextureGetTexture(cvt) else { return false }
    ensure(w, h, Int(v.drawableSize.width), Int(v.drawableSize.height), cb)
    ups.swapAt(0, 1); lumas.swapAt(0, 1)
    if upscaleOn, let sc = scaler {
      sc.colorTexture = src; sc.outputTexture = ups[1]; sc.encode(commandBuffer: cb)
    } else {
      pass(cb, pPresent, ups[1], [src, src, flowTex], [1])
    }
    let doFg = frameGenOn && fgActive
    if doFg {
      pass(cb, pLuma, lumas[1], [src])
      if prevLuma { pass(cb, pFlow, flowTex, [lumas[0], lumas[1]], [1 / Float(lumas[1].width), 1 / Float(lumas[1].height)]) }
    }
    let interp = doFg && prevLuma && haveFrame
    prevLuma = doFg; haveFrame = true
    cb.addCompletedHandler { _ in _ = cvt } // keep the capture texture alive until the GPU is done
    return interp
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in v: MTKView) {
    let now = CACurrentMediaTime()
    if lastDraw > 0 { let d = now - lastDraw; if d > 0.002 && d < 0.1 { displayInterval = displayInterval * 0.9 + d * 0.1 } }
    lastDraw = now

    lock.lock(); let pb = pending; let at = pendingAt; pending = nil; lock.unlock()
    if pb == nil && (!interpolating || lastT >= 1) { return } // nothing new to show

    let cb = queue.makeCommandBuffer()!
    var t = 1.0
    if let pb {
      let dt = at - arrival
      if arrival > 0 && dt > 0.004 && dt < 0.1 { streamInterval = streamInterval * 0.95 + dt * 0.05 }
      arrival = at
      // Frame gen only when the display is clearly faster than the stream; hysteresis + 1 s hold.
      let ratio = displayInterval / streamInterval
      let want = fgActive ? ratio < 0.85 : ratio < 0.7
      if want == fgActive { flipSince = 0 } else if flipSince == 0 { flipSince = now } else if now - flipSince > 1 { fgActive = want; flipSince = 0 }
      interpolating = process(pb, cb, v)
      t = interpolating ? 0.5 : 1 // halfway frame now, the following refreshes finish the move
    } else {
      t = min(1, 0.5 + (now - arrival) / streamInterval)
      if t <= lastT { cb.commit(); return }
    }
    guard ups.count == 2, let drawable = v.currentDrawable else { cb.commit(); return }
    pass(cb, pPresent, drawable.texture, [ups[interpolating ? 0 : 1], ups[1], flowTex], [Float(interpolating ? t : 1)])
    cb.present(drawable)
    if let f = onFirstFrame { onFirstFrame = nil; cb.addScheduledHandler { _ in DispatchQueue.main.async(execute: f) } }
    cb.commit()
    lastT = interpolating ? t : 1

    let fps = "\(Int((1 / streamInterval).rounded()))->\(Int((1 / displayInterval).rounded()))fps"
    status = "METALFX \(upscaleOn ? "on" : "off")  FRAMEGEN " + (!frameGenOn ? "off" : fgActive ? "on \(fps)" : "idle \(fps)")
  }
}

// MARK: - App

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
  var win: KeyWindow!, web: WKWebView!, overlay: NSWindow!, mtk: MTKView!, splash: SplashView!
  let renderer = Renderer()
  var stream: SCStream?
  var locked = false
  var accumX = 0.0, accumY = 0.0            // mouse delta since last flush
  var sensitivity = 0.05                     // stick units per pixel of mouse motion
  var invertY = false
  var flushTimer: Timer?
  var savedFrame: NSRect?
  var didLoad = false

  func applicationDidFinishLaunching(_ n: Notification) {
    buildMenu()
    let cfg = WKWebViewConfiguration()
    cfg.mediaTypesRequiringUserActionForPlayback = []
    let uc = cfg.userContentController
    uc.addUserScript(WKUserScript(source: "window.__TURBINE_NATIVE = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if let url = Bundle.main.url(forResource: "turbine.user", withExtension: "js"), let js = try? String(contentsOf: url, encoding: .utf8) {
      uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    uc.add(self, name: "turbine")
    web = WKWebView(frame: .zero, configuration: cfg)
    web.customUserAgent = safariUA
    web.isInspectable = true
    web.navigationDelegate = self
    let occl = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:") // keep painting even when covered
    if web.responds(to: occl) { web.perform(occl, with: false) }

    win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "Turbine"; win.backgroundColor = NSColor(red: 0.106, green: 0.039, blue: 0.165, alpha: 1)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
    container.autoresizesSubviews = true
    web.frame = container.bounds; web.autoresizingMask = [.width, .height]
    splash = SplashView(frame: container.bounds); splash.autoresizingMask = [.width, .height]
    container.addSubview(web); container.addSubview(splash)
    win.contentView = container
    win.collectionBehavior = [.fullScreenNone] // Cmd+F does a borderless fullscreen so the overlay can follow
    win.center(); win.makeKeyAndOrderFront(nil)

    // Import the user's own Chrome login for the Xbox domains. Load right away so a Keychain prompt
    // never blocks the stream; if cookies come in, reload so the page picks up the session.
    splash.setStatus("Grabbing your browser login")
    var loaded = false
    let load = { [weak self] in guard let self, !loaded else { return }; loaded = true
      self.web.load(URLRequest(url: URL(string: "https://play.xbox.com/")!)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { load() } // fall back if a prompt stalls the import
    CookieImporter.importInto(cfg.websiteDataStore.httpCookieStore) { [weak self] r in
      guard let self else { return }
      switch r {
      case let .ok(n, br): self.splash.setStatus("Signed in from \(br) (\(n))"); if loaded { self.web.reload() } else { load() }
      case .noData: self.splash.setStatus("Sign in once to save it"); if !loaded { load() }
      case .denied: self.splash.setStatus("Allow browser access to auto-sign-in"); if !loaded { load() }; self.offerGrant()
      }
    }

    overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    // Non-opaque so macOS doesn't treat the web view as covered (WebKit stops painting covered windows).
    overlay.ignoresMouseEvents = true; overlay.isOpaque = false; overlay.alphaValue = 0; overlay.backgroundColor = .clear; overlay.hasShadow = false
    mtk = MTKView(frame: .zero, device: renderer.device)
    renderer.attach(mtk)
    renderer.onFirstFrame = { [weak self] in self?.overlay.alphaValue = 1; NSLog("Turbine: first frame shown") }
    overlay.contentView = mtk
    win.addChildWindow(overlay, ordered: .above)

    for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
      NotificationCenter.default.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in self?.layout() }
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in self?.setLock(false) }
    layout()
    installMonitors()
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.web.evaluateJavaScript("window.__turbineStatus && __turbineStatus(\(self.jsString(self.renderer.status)))")
    }
    NSApp.activate(ignoringOtherApps: true)
    Task { await startCapture() }
  }

  func jsString(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }

  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

  // Fade the themed splash once the page's first screen is up.
  func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
    guard !didLoad else { return }
    didLoad = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.splash.fadeOut() }
  }

  // Re-import browser cookies on demand (menu / after signing in to the browser).
  @objc func importChrome() {
    splash.isHidden = false; splash.alphaValue = 1; splash.setStatus("Grabbing your browser login")
    didLoad = false
    CookieImporter.importInto(web.configuration.websiteDataStore.httpCookieStore) { [weak self] r in
      guard let self else { return }
      switch r {
      case let .ok(n, br): self.splash.setStatus("Signed in from \(br) (\(n))"); self.web.reload()
      case .noData: self.splash.setStatus("No Xbox login found in your browsers"); self.splash.fadeOut()
      case .denied: self.splash.setStatus("Allow browser access to continue"); self.offerGrant()
      }
    }
  }

  // Compact mode: a small always-on-top window in the corner with the HUD hidden, for playing at a desk.
  var compact = false
  var savedNormal: NSRect?
  @objc func toggleCompact() {
    compact.toggle()
    if compact {
      savedNormal = win.frame
      if let s = win.screen {
        let w: CGFloat = 480, h: CGFloat = 270
        win.setFrame(NSRect(x: s.visibleFrame.maxX - w - 16, y: s.visibleFrame.minY + 16, width: w, height: h), display: true)
      }
      win.level = .floating
      web.evaluateJavaScript("window.__turbineHud && __turbineHud(false)")
    } else {
      if let f = savedNormal { win.setFrame(f, display: true) }
      win.level = .normal
      web.evaluateJavaScript("window.__turbineHud && __turbineHud(true)")
    }
    layout()
  }

  // Shown once if macOS blocked reading the browser's data folder.
  var offeredGrant = false
  func offerGrant() {
    guard !offeredGrant else { return }
    offeredGrant = true
    let a = NSAlert()
    a.messageText = "Let Turbine read your browser login"
    a.informativeText = "To sign in automatically, Turbine needs to read your browser's saved Xbox cookies. macOS asks for this the first time.\n\n1. Click “Allow” on the “Turbine wants to access data from…” and Keychain prompts.\n2. If you don't see a prompt, open System Settings and add Turbine under Privacy & Security, or just sign in once in the window — Turbine remembers it after that."
    a.addButton(withTitle: "Open Privacy Settings")
    a.addButton(withTitle: "I'll sign in manually")
    if a.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }
  }

  func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu(); appItem.submenu = appMenu
    appMenu.addItem(withTitle: "Import Chrome Login", action: #selector(importChrome), keyEquivalent: "i").target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Compact / Corner", action: #selector(toggleCompact), keyEquivalent: "k").target = self
    appMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    appMenu.addItem(withTitle: "Hide Turbine", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Turbine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let editItem = NSMenuItem(); main.addItem(editItem)
    let edit = NSMenu(title: "Edit"); editItem.submenu = edit
    for (t, a, k) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
      edit.addItem(withTitle: t, action: Selector(a), keyEquivalent: k)
    }
    NSApp.mainMenu = main
  }

  // Overlay sits exactly over the web view; capture size follows it.
  func layout() {
    let r = win.contentLayoutRect
    overlay.setFrame(win.convertToScreen(r), display: true)
    stream?.updateConfiguration(captureConfig()) { _ in }
  }

  func captureConfig() -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    let r = win.contentLayoutRect, full = win.frame.size
    // Capture near the stream's own resolution (1080p); MetalFX upscales to the display.
    let scale = min(win.backingScaleFactor, max(0.5, 1080 / max(1, r.height)))
    c.sourceRect = CGRect(x: r.minX, y: full.height - r.maxY, width: r.width, height: r.height)
    c.width = Int(r.width * scale) & ~1; c.height = Int(r.height * scale) & ~1
    c.pixelFormat = kCVPixelFormatType_32BGRA
    // Match the display refresh so frames arrive as fast as they can be shown; shallow queue = low latency.
    c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(NSScreen.main?.maximumFramesPerSecond ?? 120))
    c.queueDepth = 3; c.showsCursor = false
    if #available(macOS 14.0, *) { c.captureResolution = .best }
    return c
  }

  func startCapture() async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let w = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) }) else {
        NSLog("Turbine: own window \(win.windowNumber) not in shareable content (\(content.windows.count) windows)"); return
      }
      let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: captureConfig(), delegate: nil)
      try s.addStreamOutput(renderer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "turbine.capture", qos: .userInteractive))
      try await s.startCapture()
      stream = s
      NSLog("Turbine: capture started")
    } catch {
      NSLog("Turbine: capture failed: \(error)")
      let a = NSAlert()
      a.messageText = "Turbine needs Screen Recording permission"
      a.informativeText = "Allow Turbine in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Turbine. Until then the stream shows without upscaling or frame generation."
      a.runModal()
      overlay.orderOut(nil)
    }
  }

  // MARK: Mouse lock + input

  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    if let s = m.body as? String { setLock(s == "lock") }
  }

  func setLock(_ on: Bool) {
    guard on != locked else { return }
    locked = on
    CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
    on ? NSCursor.hide() : NSCursor.unhide()
    accumX = 0; accumY = 0
    if on {
      recenterCursor()
      // Flush at the display rate: steady velocity from mouse speed, and 0 when the mouse is still.
      let t = Timer(timeInterval: 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 120), repeats: true) { [weak self] _ in self?.flushLook() }
      RunLoop.main.add(t, forMode: .common); flushTimer = t
    } else {
      flushTimer?.invalidate(); flushTimer = nil
      web.evaluateJavaScript("window.__turbineStick && __turbineStick(0,0)")
    }
    web.evaluateJavaScript("window.__turbineLock && __turbineLock(\(on))")
  }

  // Keep the (hidden) cursor at screen centre so hitting an edge can't bias the look (the "stuck looking down" bug).
  func recenterCursor() {
    guard let s = win.screen else { return }
    let c = CGPoint(x: s.frame.midX, y: s.frame.height - s.frame.midY)
    CGWarpMouseCursorPosition(c)
  }

  // Send the right stick straight from accumulated mouse motion, then clear it. Camera stops the moment the mouse does.
  func flushLook() {
    guard locked else { return }
    let clamp = { (v: Double) in max(-1, min(1, v)) }
    let rx = clamp(accumX * sensitivity)
    let ry = clamp(accumY * sensitivity * (invertY ? -1 : 1))
    accumX = 0; accumY = 0
    web.evaluateJavaScript("window.__turbineStick && __turbineStick(\(rx),\(ry))")
  }

  func installMonitors() {
    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] e in
      if let self, self.locked { self.accumX += e.deltaX; self.accumY += e.deltaY }
      return e
    }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self else { return e }
      switch e.keyCode {
      case 53 where self.locked: self.setLock(false); return nil               // Esc
      case 98: self.renderer.frameGenOn.toggle(); self.updateOverlay()           // F7
      case 109: self.renderer.upscaleOn.toggle(); self.updateOverlay()           // F10
      case 96: self.invertY.toggle(); self.flashSens("INVERT Y \(self.invertY ? "ON" : "OFF")")  // F5
      case 27 where self.locked: self.sensitivity = max(0.01, self.sensitivity - 0.01); self.flashSens()  // minus: slower
      case 24 where self.locked: self.sensitivity = min(0.3, self.sensitivity + 0.01); self.flashSens()   // equals: faster
      default:
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "f" { self.toggleFullscreen(); return nil }
      }
      return e
    }
  }

  // Briefly show a sensitivity/invert message in the HUD.
  func flashSens(_ msg: String? = nil) {
    let text = msg ?? "SENS \(Int((sensitivity * 100).rounded()))"
    web.evaluateJavaScript("window.__turbineStatus && __turbineStatus(\(jsString(text)))")
  }

  func updateOverlay() {
    let on = renderer.upscaleOn || renderer.frameGenOn
    mtk.isPaused = !on
    if on { win.addChildWindow(overlay, ordered: .above); layout() } else { overlay.orderOut(nil) }
  }

  func toggleFullscreen() {
    if let f = savedFrame {
      win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
      win.setFrame(f, display: true); savedFrame = nil
      NSApp.presentationOptions = []
    } else if let screen = win.screen {
      savedFrame = win.frame
      win.styleMask = [.borderless]
      win.setFrame(screen.frame, display: true)
      NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
    }
    win.makeKeyAndOrderFront(nil)
    layout()
  }
}

// MARK: - Themed splash

// GTA VI inspired launch screen: deep violet with a sunset gradient and the spinning Turbine logo.
final class SplashView: NSView {
  let gradient = CAGradientLayer()
  let glow = CALayer()
  let rotor = CALayer()
  let wordmark = CATextLayer()
  let status = CATextLayer()
  let accentTop = NSColor(red: 1.0, green: 0.70, blue: 0.28, alpha: 1)
  let accentMid = NSColor(red: 1.0, green: 0.31, blue: 0.60, alpha: 1)
  let accentBot = NSColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor(red: 0.106, green: 0.039, blue: 0.165, alpha: 1).cgColor

    gradient.colors = [NSColor(red: 0.16, green: 0.05, blue: 0.22, alpha: 1).cgColor,
                       NSColor(red: 0.30, green: 0.08, blue: 0.28, alpha: 1).cgColor,
                       NSColor(red: 0.11, green: 0.04, blue: 0.17, alpha: 1).cgColor]
    gradient.startPoint = CGPoint(x: 0, y: 1); gradient.endPoint = CGPoint(x: 1, y: 0)
    layer?.addSublayer(gradient)

    glow.backgroundColor = accentMid.withAlphaComponent(0.28).cgColor
    layer?.addSublayer(glow)

    rotor.contents = Self.rotorImage(accentTop, accentMid, accentBot)
    rotor.contentsGravity = .resizeAspect
    layer?.addSublayer(rotor)
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0; spin.toValue = -Double.pi * 2; spin.duration = 6; spin.repeatCount = .infinity
    rotor.add(spin, forKey: "spin")

    let font = NSFont(name: "SFProDisplay-Bold", size: 64) ?? NSFont.systemFont(ofSize: 64, weight: .bold)
    wordmark.string = "TURBINE"; wordmark.font = font; wordmark.fontSize = 64
    wordmark.foregroundColor = NSColor.white.cgColor
    wordmark.alignmentMode = .center
    layer?.addSublayer(wordmark)

    status.string = ""; status.fontSize = 15
    status.font = NSFont.systemFont(ofSize: 15, weight: .medium)
    status.foregroundColor = accentMid.cgColor; status.alignmentMode = .center
    layer?.addSublayer(status)
    needsLayout = true
  }
  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    let sc = window?.backingScaleFactor ?? 2
    for l in [gradient, glow, rotor, wordmark, status] { l.contentsScale = sc; l.rasterizationScale = sc }
    gradient.frame = bounds
    let cx = bounds.midX, cy = bounds.midY + 40
    let g: CGFloat = 360; glow.frame = CGRect(x: cx - g / 2, y: cy - g / 2, width: g, height: g); glow.cornerRadius = g / 2
    let r: CGFloat = 150; rotor.frame = CGRect(x: cx - r / 2, y: cy - r / 2, width: r, height: r)
    wordmark.frame = CGRect(x: 0, y: cy - r / 2 - 92, width: bounds.width, height: 76)
    status.frame = CGRect(x: 0, y: cy - r / 2 - 120, width: bounds.width, height: 22)
    CATransaction.commit()
  }

  func setStatus(_ s: String) {
    DispatchQueue.main.async { CATransaction.begin(); CATransaction.setDisableActions(true); self.status.string = s; CATransaction.commit() }
  }

  func fadeOut() {
    let a = CABasicAnimation(keyPath: "opacity")
    a.fromValue = 1; a.toValue = 0; a.duration = 0.5; a.fillMode = .forwards; a.isRemovedOnCompletion = false
    layer?.add(a, forKey: "fade")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.isHidden = true; self.layer?.removeAnimation(forKey: "fade") }
  }

  // Seven-blade turbine rotor drawn once into an image.
  static func rotorImage(_ top: NSColor, _ mid: NSColor, _ bot: NSColor) -> CGImage {
    let px = 300
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 150, y: 150); ctx.scaleBy(x: 1.3, y: 1.3)
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [top.cgColor, mid.cgColor, bot.cgColor] as CFArray, locations: [0, 0.5, 1])!
    let ring = CGMutablePath(); ring.addArc(center: .zero, radius: 100, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.addPath(ring); ctx.setLineWidth(6); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: -100, y: 100), end: CGPoint(x: 100, y: -100), options: [])
    NSGraphicsContext.current!.cgContext.resetClip()
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 0, y: 20))
    blade.addCurve(to: CGPoint(x: 30, y: 96), control1: CGPoint(x: 26, y: 28), control2: CGPoint(x: 54, y: 58))
    blade.addCurve(to: CGPoint(x: -8, y: 22), control1: CGPoint(x: 16, y: 74), control2: CGPoint(x: 2, y: 48))
    blade.closeSubpath()
    for i in 0..<7 {
      ctx.saveGState(); ctx.rotate(by: CGFloat(i) * .pi * 2 / 7)
      ctx.addPath(blade); ctx.clip()
      ctx.drawLinearGradient(grad, start: CGPoint(x: -50, y: 0), end: CGPoint(x: 50, y: 96), options: [])
      ctx.restoreGState()
    }
    ctx.setFillColor(NSColor(red: 0.106, green: 0.039, blue: 0.165, alpha: 1).cgColor)
    ctx.addArc(center: .zero, radius: 18, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
