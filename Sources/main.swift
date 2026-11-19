import AppKit
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

  var upscaleOn = true, frameGenOn = true
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

  func attach(_ v: MTKView) {
    view = v
    v.device = device; v.delegate = self
    v.colorPixelFormat = .bgra8Unorm; v.framebufferOnly = true
    v.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
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
    lock.lock(); pending = pb; pendingAt = CACurrentMediaTime(); lock.unlock()
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
    cb.commit()
    lastT = interpolating ? t : 1

    let fps = "\(Int((1 / streamInterval).rounded()))->\(Int((1 / displayInterval).rounded()))fps"
    status = "METALFX \(upscaleOn ? "on" : "off")  FRAMEGEN " + (!frameGenOn ? "off" : fgActive ? "on \(fps)" : "idle \(fps)")
  }
}

// MARK: - App

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
  var win: KeyWindow!, web: WKWebView!, overlay: NSWindow!, mtk: MTKView!
  let renderer = Renderer()
  var stream: SCStream?
  var locked = false, moveDX = 0.0, moveDY = 0.0, moveInFlight = false
  var savedFrame: NSRect?

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

    win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "Turbine"; win.backgroundColor = .black; win.contentView = web
    win.collectionBehavior = [.fullScreenNone] // Cmd+F does a borderless fullscreen so the overlay can follow
    win.center(); win.makeKeyAndOrderFront(nil)
    web.load(URLRequest(url: URL(string: "https://play.xbox.com/")!))

    overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    overlay.ignoresMouseEvents = true; overlay.isOpaque = true; overlay.backgroundColor = .black; overlay.hasShadow = false
    mtk = MTKView(frame: .zero, device: renderer.device)
    renderer.attach(mtk)
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

  func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu(); appItem.submenu = appMenu
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
    c.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    c.queueDepth = 4; c.showsCursor = false
    return c
  }

  func startCapture() async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let w = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) }) else { return }
      let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: captureConfig(), delegate: nil)
      try s.addStreamOutput(renderer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "turbine.capture", qos: .userInteractive))
      try await s.startCapture()
      stream = s
    } catch {
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
    web.evaluateJavaScript("window.__turbineLock && __turbineLock(\(on))")
  }

  // Coalesce mouse deltas so at most one JS call is in flight.
  func queueMove(_ dx: Double, _ dy: Double) {
    moveDX += dx; moveDY += dy
    guard !moveInFlight else { return }
    moveInFlight = true
    let x = moveDX, y = moveDY; moveDX = 0; moveDY = 0
    web.evaluateJavaScript("__turbineMove(\(x),\(y))") { [weak self] _, _ in
      guard let self else { return }
      self.moveInFlight = false
      if self.moveDX != 0 || self.moveDY != 0 { self.queueMove(0, 0) }
    }
  }

  func installMonitors() {
    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] e in
      if let self, self.locked { self.queueMove(e.deltaX, e.deltaY) }
      return e
    }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self else { return e }
      switch e.keyCode {
      case 53 where self.locked: self.setLock(false); return nil               // Esc
      case 98: self.renderer.frameGenOn.toggle(); self.updateOverlay()           // F7
      case 109: self.renderer.upscaleOn.toggle(); self.updateOverlay()           // F10
      default:
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "f" { self.toggleFullscreen(); return nil }
      }
      return e
    }
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

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
