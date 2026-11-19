// ==UserScript==
// @name         Turbine
// @namespace    https://github.com/rpatty-dev/turbine
// @version      1.1.0
// @description  Play GTA VI over Xbox Remote Play in the browser with keyboard + mouse: GTA-style controls, car mode, low-latency stream, GPU upscaler and 30-to-60 fps frame generation.
// @author       rpatty-dev
// @license      MIT
// @homepageURL  https://github.com/rpatty-dev/turbine
// @updateURL    https://raw.githubusercontent.com/rpatty-dev/turbine/main/turbine.user.js
// @downloadURL  https://raw.githubusercontent.com/rpatty-dev/turbine/main/turbine.user.js
// @match        https://play.xbox.com/*
// @match        https://www.xbox.com/*/play*
// @run-at       document-start
// @grant        none
// ==/UserScript==
(() => {
  "use strict";

  // Turbine for Mac sets this: it does pointer lock, upscaling and frame generation natively.
  const NATIVE = !!window.__TURBINE_NATIVE;
  const toNative = (msg) => { try { window.webkit.messageHandlers.turbine.postMessage(msg); } catch (e) {} };
  let nativeLocked = false, nativeStatus = "";
  const isLocked = () => (NATIVE ? nativeLocked : !!document.pointerLockElement);

  // ===================== Settings =====================

  // KeyboardEvent.code -> standard gamepad button index.
  // 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 LT, 7 RT, 8 View, 9 Menu, 10 L3, 11 R3,
  // 12 Up, 13 Down, 14 Left, 15 Right, 16 Xbox
  const BUTTONS = {
    ShiftLeft: 0, ShiftRight: 0, // A
    KeyB: 1,                     // B
    Space: 2,                    // X
    KeyY: 3,                     // Y
    KeyQ: 4, KeyF: 5,            // LB / RB
    Mouse2: 6, Mouse0: 7,        // LT = right click (aim), RT = left click (shoot)
    BracketLeft: 8, KeyP: 9,     // View (map) / Menu (pause)
    KeyX: 10, KeyC: 11,          // L3 / R3
    ArrowUp: 12, ArrowDown: 13, ArrowLeft: 14, ArrowRight: 15,
    Backquote: 16,               // Xbox button
  };
  // Stick keys: [axisIndex, direction]. Axes: 0 LX, 1 LY, 2 RX, 3 RY (down/right = +1).
  const STICKS = {
    KeyA: [0, -1], KeyD: [0, 1], KeyW: [1, -1], KeyS: [1, 1],
    KeyJ: [2, -1], KeyL: [2, 1], KeyI: [3, -1], KeyK: [3, 1],
  };

  const KEY_TOGGLE = "F8";      // controller emulation on/off
  const KEY_STATS = "F9";       // stats overlay
  const KEY_UPSCALE = "F10";    // upscaler on/off
  const KEY_FRAMEGEN = "F7";    // frame generation on/off

  // Car mode (GTA VI): W = RT (gas), S = LT (brake/reverse), A/D still steer.
  // Y (enter/exit vehicle) flips car mode automatically. G flips it manually if it gets out of sync.
  const CAR_ENTER_EXIT = "KeyY";
  const CAR_TOGGLE = "KeyG";

  // Mouse look -> right stick.
  const SENSITIVITY = 0.05;     // stick units per pixel of mouse movement
  const MIN_PUSH = 0.25;        // pushes small movements past the game's stick deadzone
  const MOUSE_STOP_MS = 40;     // camera stops this long after the mouse stops
  const INVERT_Y = false;

  // Stream latency: 0 = smallest receive buffer (lowest delay, may stutter on weak Wi-Fi).
  // null = browser default, or e.g. 30 (ms) for a little smoothing.
  const JITTER_BUFFER_MS = 0;

  // Upscaler: GPU upscale to screen resolution + AMD CAS sharpening. 0 soft .. 1 crisp.
  const UPSCALE_SHARPNESS = 0.6;
  let upscaleOn = true;

  // Frame generation: motion-estimated in-between frames. Turns a 30 fps stream into 60 fps on a 60 Hz
  // refreshes faster than the stream (e.g. 120 Hz ProMotion with a 60 fps stream).
  // Costs about half a stream frame (~8 ms at 60 fps) of extra delay.
  let frameGenOn = true;
  const FLOW_RANGE = 10;        // motion search radius in quarter-res pixels (10 = 40 px per frame, sized for 30 fps camera pans)

  // ===================== Virtual controller =====================

  const held = new Set();
  const mouse = [0, 0];
  let mouseTimer = null;
  let enabled = true;
  let carMode = false;
  let timestamp = performance.now();
  const clamp = (v) => Math.max(-1, Math.min(1, v));

  const pad = {
    id: "Xbox 360 Controller (XInput STANDARD GAMEPAD)",
    index: 0,
    connected: true,
    mapping: "standard",
    axes: [0, 0, 0, 0],
    buttons: Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 })),
    get timestamp() { return timestamp; },
    vibrationActuator: null,
    hapticActuators: [],
  };

  function refresh() {
    pad.buttons.forEach((b) => { b.pressed = b.touched = false; b.value = 0; });
    pad.axes.fill(0);
    for (const code of held) {
      if (code in BUTTONS) {
        const b = pad.buttons[BUTTONS[code]];
        b.pressed = b.touched = true; b.value = 1;
      } else if (carMode && (code === "KeyW" || code === "KeyS")) {
        const b = pad.buttons[code === "KeyW" ? 7 : 6];
        b.pressed = b.touched = true; b.value = 1;
      } else if (code in STICKS) {
        const [axis, dir] = STICKS[code];
        pad.axes[axis] = clamp(pad.axes[axis] + dir);
      }
    }
    pad.axes[2] = clamp(pad.axes[2] + mouse[0]);
    pad.axes[3] = clamp(pad.axes[3] + mouse[1]);
    timestamp = performance.now();
  }

  const nativeGetGamepads = Navigator.prototype.getGamepads;
  function getGamepads() {
    const list = Array.from((nativeGetGamepads && nativeGetGamepads.call(navigator)) || []);
    if (!enabled) return list;
    let slot = list.findIndex((g) => !g);
    if (slot < 0) slot = list.length;
    pad.index = slot;
    list[slot] = pad;
    return list;
  }
  Navigator.prototype.getGamepads = getGamepads;
  try { navigator.getGamepads = getGamepads; } catch (e) {}

  function announce(type) {
    const ev = new Event(type);
    Object.defineProperty(ev, "gamepad", { value: pad });
    window.dispatchEvent(ev);
  }

  function releaseAll() {
    held.clear(); mouse[0] = mouse[1] = 0; refresh();
  }

  function onInput(code, down, e) {
    if (code === KEY_TOGGLE) {
      if (down) return;
      enabled = !enabled;
      releaseAll();
      if (!enabled && isLocked()) NATIVE ? toNative("unlock") : document.exitPointerLock();
      announce(enabled ? "gamepadconnected" : "gamepaddisconnected");
      console.log("[turbine] controller", enabled ? "ON" : "OFF");
      e.preventDefault();
      return;
    }
    if (code === KEY_UPSCALE || code === KEY_FRAMEGEN || code === KEY_STATS) {
      e.preventDefault();
      if (down) return;
      if (code === KEY_UPSCALE) upscaleOn = !upscaleOn;
      if (code === KEY_FRAMEGEN) frameGenOn = !frameGenOn;
      if (code === KEY_STATS) showStats = !showStats;
      renderHud();
      return;
    }
    if (enabled && code === CAR_TOGGLE) {
      e.preventDefault(); e.stopImmediatePropagation();
      if (!down) setCarMode(!carMode);
      return;
    }
    if (!enabled || !(code in BUTTONS || code in STICKS)) return;
    if (!down && !held.has(code)) return; // only swallow releases of inputs we took
    // Stop the page (and the stream's native keyboard input) from also getting the key.
    e.preventDefault();
    e.stopImmediatePropagation();
    if (e.repeat) return;
    down ? held.add(code) : held.delete(code);
    if (down && code === CAR_ENTER_EXIT) setCarMode(!carMode);
    refresh();
  }

  // ===================== HUD =====================

  let hud = null;
  let statsText = "";
  let fgState = "starting";
  let showStats = true;
  function renderHud() {
    if (!hud) return;
    const lines = ["TURBINE  " + (carMode ? "CAR (W gas / S brake)" : "ON FOOT")];
    if (showStats) {
      lines.push(NATIVE ? nativeStatus : `UPSCALE ${upscaleOn ? "on" : "off"}  FRAMEGEN ${frameGenOn ? (fgState || "on") : "off"}`);
      if (statsText) lines.push(statsText);
    }
    hud.textContent = lines.join("\n");
  }
  function setCarMode(on) {
    carMode = on;
    refresh();
    renderHud();
  }
  function placeHud() {
    if (hud) (document.fullscreenElement || document.body)?.appendChild(hud);
  }
  window.addEventListener("DOMContentLoaded", () => {
    hud = document.createElement("div");
    hud.style.cssText = "position:fixed;left:12px;bottom:12px;z-index:2147483647;pointer-events:none;" +
      "font:600 12px/1.4 ui-monospace,Menlo,monospace;white-space:pre;color:#ffe4f1;background:rgba(27,10,42,.72);border-left:3px solid #ff4f9a;padding:4px 8px;border-radius:4px";
    renderHud();
    placeHud();
    announce("gamepadconnected");
  });
  document.addEventListener("fullscreenchange", placeHud);

  // ===================== Keyboard + mouse =====================

  const isStream = (t) => t instanceof HTMLVideoElement || t instanceof HTMLCanvasElement;
  const opts = { capture: true };

  window.addEventListener("keydown", (e) => onInput(e.code, true, e), opts);
  window.addEventListener("keyup", (e) => onInput(e.code, false, e), opts);

  window.addEventListener("mousedown", (e) => {
    if (!enabled || !isStream(e.target)) return;
    if (!isLocked()) {
      // First click on the video only locks the mouse; it does not shoot.
      e.preventDefault(); e.stopImmediatePropagation();
      if (NATIVE) { toNative("lock"); return; }
      try { e.target.requestPointerLock({ unadjustedMovement: true })?.catch?.(() => e.target.requestPointerLock()); }
      catch (err) { e.target.requestPointerLock(); }
      return;
    }
    onInput("Mouse" + e.button, true, e);
  }, opts);
  window.addEventListener("mouseup", (e) => onInput("Mouse" + e.button, false, e), opts);
  window.addEventListener("contextmenu", (e) => { if (enabled && isStream(e.target)) e.preventDefault(); }, opts);

  // pointerrawupdate delivers mouse movement as soon as the OS reports it (lower latency than mousemove).
  const MOVE_EVENT = "onpointerrawupdate" in window ? "pointerrawupdate" : "mousemove";
  function onMove(e) {
    if (!enabled || !isLocked()) return;
    let x = e.movementX * SENSITIVITY, y = e.movementY * SENSITIVITY * (INVERT_Y ? -1 : 1);
    const len = Math.hypot(x, y);
    if (len > 0 && len < MIN_PUSH) { x *= MIN_PUSH / len; y *= MIN_PUSH / len; }
    mouse[0] = clamp(x); mouse[1] = clamp(y);
    refresh();
    clearTimeout(mouseTimer);
    mouseTimer = setTimeout(() => { mouse[0] = mouse[1] = 0; refresh(); }, MOUSE_STOP_MS);
  }
  window.addEventListener(MOVE_EVENT, onMove, opts);

  // Native bridge (Turbine for Mac).
  window.__turbineMove = (dx, dy) => onMove({ movementX: dx, movementY: dy });
  window.__turbineLock = (on) => { nativeLocked = on; if (!on) releaseAll(); };
  window.__turbineStatus = (text) => { nativeStatus = text; renderHud(); };

  document.addEventListener("pointerlockchange", () => { if (!document.pointerLockElement) releaseAll(); });
  window.addEventListener("blur", releaseAll);

  // ===================== Low-latency stream + stats =====================

  const NativePC = window.RTCPeerConnection;
  const peers = new Set();
  function tune(receiver) {
    if (JITTER_BUFFER_MS === null || !receiver) return;
    try { if (receiver.jitterBufferTarget !== JITTER_BUFFER_MS) receiver.jitterBufferTarget = JITTER_BUFFER_MS; } catch (err) {}
    try { receiver.playoutDelayHint = JITTER_BUFFER_MS / 1000; } catch (err) {} // older Chrome name
  }
  if (NativePC) {
    const WrappedPC = function (...args) {
      const pc = new NativePC(...args);
      peers.add(pc);
      pc.addEventListener("track", (e) => tune(e.receiver));
      pc.addEventListener("connectionstatechange", () => { if (pc.connectionState === "closed") peers.delete(pc); });
      return pc;
    };
    WrappedPC.prototype = NativePC.prototype;
    Object.setPrototypeOf(WrappedPC, NativePC); // keeps static methods like generateCertificate
    window.RTCPeerConnection = WrappedPC;
  }

  let last = null;
  setInterval(async () => {
    for (const pc of peers) {
      if (pc.connectionState !== "connected") continue;
      pc.getReceivers().forEach(tune); // re-apply; the client can reset it
      if (!showStats) continue;
      let v = null, rtt = null;
      (await pc.getStats()).forEach((s) => {
        if (s.type === "inbound-rtp" && s.kind === "video") v = s;
        if (s.type === "candidate-pair" && s.nominated && s.state === "succeeded") rtt = s.currentRoundTripTime;
      });
      if (!v) continue;
      let jb = "?", dec = "?";
      if (last && last.id === v.id) {
        const n = v.jitterBufferEmittedCount - last.jitterBufferEmittedCount;
        const f = v.framesDecoded - last.framesDecoded;
        if (n > 0) jb = ((v.jitterBufferDelay - last.jitterBufferDelay) / n * 1000).toFixed(0);
        if (f > 0) dec = ((v.totalDecodeTime - last.totalDecodeTime) / f * 1000).toFixed(1);
      }
      last = v;
      statsText = `${v.frameWidth || "?"}x${v.frameHeight || "?"} ${Math.round(v.framesPerSecond || 0)}fps` +
        `  ping ${rtt != null ? Math.round(rtt * 1000) : "?"}ms  buf ${jb}ms  dec ${dec}ms  lost ${v.packetsLost ?? 0}`;
      renderHud();
      break;
    }
  }, 1000);

  // ===================== GPU renderer: upscale + sharpen + frame generation =====================

  // Full-screen triangle. VS_PLAIN: uv in GL orientation (y up), used for offscreen passes.
  // VS_VIDEO: uv in video-texture orientation (y down), used for the final pass.
  const VS = (flip) => `#version 300 es
  out vec2 uv;
  void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    uv = ${flip ? "vec2(p.x, 1.0 - p.y)" : "p"};
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
  }`;

  // Quarter-res luma (flipped to GL orientation) for motion search.
  const FS_LUMA = `#version 300 es
  precision mediump float;
  uniform sampler2D t; in vec2 uv; out vec4 o;
  void main() { float l = dot(texture(t, vec2(uv.x, 1.0 - uv.y)).rgb, vec3(0.299, 0.587, 0.114)); o = vec4(l, l, l, 1.0); }`;

  // Block-matching motion estimation: for each block find the offset d where prev(x) ~ cur(x + d).
  const FS_FLOW = `#version 300 es
  precision highp float;
  uniform sampler2D a; uniform sampler2D b; uniform vec2 lpx;
  in vec2 uv; out vec4 o;
  const int R = ${FLOW_RANGE};
  void main() {
    float pa[9]; vec2 q[9];
    for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++) {
      int n = j * 3 + i;
      q[n] = uv + vec2(float(i - 1), float(j - 1)) * lpx * 1.5;
      pa[n] = texture(a, q[n]).r;
    }
    float best = 1e9; vec2 bd = vec2(0.0);
    for (int y = -R; y <= R; y++) for (int x = -R; x <= R; x++) {
      vec2 d = vec2(float(x), float(y));
      float c = 0.004 * length(d); // prefer small motion when costs tie
      for (int n = 0; n < 9; n++) c += abs(pa[n] - texture(b, q[n] + d * lpx).r);
      if (c < best) { best = c; bd = d; }
    }
    o = vec4(bd / float(R) * 0.5 + 0.5, 0.0, 1.0);
  }`;

  // Final pass: warp prev and cur toward time t along the motion field, blend, then AMD CAS sharpen.
  const FS_OUT = `#version 300 es
  precision mediump float;
  uniform sampler2D prev; uniform sampler2D cur; uniform sampler2D flow;
  uniform vec2 px; uniform vec2 lpx; uniform float k; uniform float t;
  in vec2 uv; out vec4 o;
  vec2 f;
  vec3 s(vec2 d) {
    vec2 p = uv + px * d;
    return mix(texture(prev, p - f * t).rgb, texture(cur, p + f * (1.0 - t)).rgb, t);
  }
  void main() {
    vec2 fl = (texture(flow, vec2(uv.x, 1.0 - uv.y)).rg * 2.0 - 1.0) * float(${FLOW_RANGE}) * lpx;
    f = vec2(fl.x, -fl.y); // GL orientation -> video orientation
    vec3 a = s(vec2(-1,-1)), b = s(vec2(0,-1)), c = s(vec2(1,-1));
    vec3 d = s(vec2(-1, 0)), e = s(vec2(0, 0)), g0 = s(vec2(1, 0));
    vec3 g = s(vec2(-1, 1)), h = s(vec2(0, 1)), i = s(vec2(1, 1));
    vec3 mn = min(min(min(d, e), min(g0, b)), h); mn += min(mn, min(min(a, c), min(g, i)));
    vec3 mx = max(max(max(d, e), max(g0, b)), h); mx += max(mx, max(max(a, c), max(g, i)));
    vec3 amp = sqrt(clamp(min(mn, 2.0 - mx) / max(mx, 1e-4), 0.0, 1.0));
    vec3 w = amp * (-1.0 / mix(8.0, 5.0, k));
    o = vec4(clamp(((b + d + g0 + h) * w + e) / (1.0 + 4.0 * w), 0.0, 1.0), 1.0);
  }`;

  function attachRenderer(video) {
    video.dataset.turbine = "1";
    const canvas = document.createElement("canvas");
    canvas.style.cssText = "position:absolute;inset:0;width:100%;height:100%;pointer-events:none;z-index:1;background:#000";
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false,
      desynchronized: true, preserveDrawingBuffer: false, powerPreference: "high-performance" });
    if (!gl) { console.warn("[turbine] WebGL2 unavailable, renderer off"); return; }

    const program = (vs, fs) => {
      const sh = (type, src) => { const x = gl.createShader(type); gl.shaderSource(x, src); gl.compileShader(x);
        if (!gl.getShaderParameter(x, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(x)); return x; };
      const p = gl.createProgram();
      gl.attachShader(p, sh(gl.VERTEX_SHADER, vs)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs));
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
      const locs = {};
      return { p, u: (n) => (n in locs ? locs[n] : (locs[n] = gl.getUniformLocation(p, n))) };
    };
    let pLuma, pFlow, pOut;
    try { pLuma = program(VS(false), FS_LUMA); pFlow = program(VS(false), FS_FLOW); pOut = program(VS(true), FS_OUT); }
    catch (err) { console.warn("[turbine] shader error", err); return; }

    const newTex = () => {
      const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
      for (const [p, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
        [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, p, v);
      return t;
    };
    const target = (w, h) => {
      const tex = newTex();
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      const fb = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      gl.clearColor(0.5, 0.5, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); // 0.5 = zero motion
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      return { tex, fb, w, h };
    };
    const drop = (tg) => { if (tg) { gl.deleteTexture(tg.tex); gl.deleteFramebuffer(tg.fb); } };

    const frames = [newTex(), newTex()]; // [prev, cur]
    let lumas = null, flow = target(1, 1), vw = 0, vh = 0;
    let prevHasLuma = false, haveFrame = false;
    const alloc = () => {
      vw = video.videoWidth; vh = video.videoHeight;
      const lw = Math.max(1, vw >> 2), lh = Math.max(1, vh >> 2);
      if (lumas) lumas.forEach(drop);
      drop(flow);
      lumas = [target(lw, lh), target(lw, lh)];
      flow = target(Math.max(1, lw >> 2), Math.max(1, lh >> 2));
      prevHasLuma = haveFrame = false;
    };

    const bind = (prog, list) => list.forEach(([name, tex], i) => {
      gl.activeTexture(gl.TEXTURE0 + i); gl.bindTexture(gl.TEXTURE_2D, tex); gl.uniform1i(prog.u(name), i);
    });
    const pass = (prog, tg, list) => {
      gl.bindFramebuffer(gl.FRAMEBUFFER, tg.fb); gl.viewport(0, 0, tg.w, tg.h);
      gl.useProgram(prog.p); bind(prog, list);
    };

    const parent = video.parentElement;
    if (getComputedStyle(parent).position === "static") parent.style.position = "relative";
    video.after(canvas);
    const fit = () => {
      const r = video.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
      canvas.width = Math.max(1, Math.round(r.width * dpr)); canvas.height = Math.max(1, Math.round(r.height * dpr));
    };
    const ro = new ResizeObserver(fit); ro.observe(video); fit();

    let arrival = 0, streamInterval = 1000 / 60, displayInterval = 1000 / 60, lastRaf = 0, lastT = 1;
    let fgActive = false, fgFlipSince = 0, fgLabelAt = 0;
    const FG_ON_RATIO = 0.7, FG_OFF_RATIO = 0.85, FG_HOLD_MS = 1000;

    function present(t, interp) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      const cw = canvas.width, ch = canvas.height, sc = Math.min(cw / vw, ch / vh);
      const w = Math.round(vw * sc), h = Math.round(vh * sc);
      gl.viewport(0, 0, cw, ch); gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.viewport((cw - w) >> 1, (ch - h) >> 1, w, h);
      gl.useProgram(pOut.p);
      bind(pOut, [["prev", frames[interp ? 0 : 1]], ["cur", frames[1]], ["flow", flow.tex]]);
      gl.uniform2f(pOut.u("px"), 1 / vw, 1 / vh);
      gl.uniform2f(pOut.u("lpx"), 1 / lumas[1].w, 1 / lumas[1].h);
      gl.uniform1f(pOut.u("k"), UPSCALE_SHARPNESS);
      gl.uniform1f(pOut.u("t"), interp ? t : 1);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      lastT = interp ? t : 1;
    }

    // Runs once per decoded stream frame.
    function onFrame(now) {
      if (!video.isConnected) { ro.disconnect(); canvas.remove(); delete video.dataset.turbine; gl.getExtension("WEBGL_lose_context")?.loseContext(); return; }
      video.requestVideoFrameCallback(onFrame);
      canvas.style.display = upscaleOn ? "" : "none";
      video.style.opacity = upscaleOn ? "0" : "";
      if (!upscaleOn || !video.videoWidth) { prevHasLuma = false; return; }
      if (vw !== video.videoWidth || vh !== video.videoHeight) alloc();

      frames.reverse(); lumas.reverse();
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, frames[1]);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);

      const dt = now - arrival;
      if (arrival && dt > 4 && dt < 100) streamInterval = streamInterval * 0.95 + dt * 0.05;
      arrival = now;

      // Frame gen only helps when the display refreshes clearly faster than the stream.
      // Hysteresis + 1 s hold so stream jitter can't flip it on and off every frame.
      const ratio = displayInterval / streamInterval;
      const want = fgActive ? ratio < FG_OFF_RATIO : ratio < FG_ON_RATIO;
      if (want === fgActive) fgFlipSince = 0;
      else if (!fgFlipSince) fgFlipSince = now;
      else if (now - fgFlipSince > FG_HOLD_MS) { fgActive = want; fgFlipSince = 0; }
      if (now - fgLabelAt > 1000) { // refresh the label once a second, not every frame
        fgLabelAt = now;
        const fps = `${Math.round(1000 / streamInterval)}->${Math.round(1000 / displayInterval)}fps`;
        const state = fgActive ? `on ${fps}` : `idle ${fps} (display not faster than stream)`;
        if (state !== fgState) { fgState = state; renderHud(); }
      }
      const doFg = frameGenOn && fgActive;
      if (doFg) {
        pass(pLuma, lumas[1], [["t", frames[1]]]);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        if (prevHasLuma && haveFrame) {
          pass(pFlow, flow, [["a", lumas[0].tex], ["b", lumas[1].tex]]);
          gl.uniform2f(pFlow.u("lpx"), 1 / lumas[1].w, 1 / lumas[1].h);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
        }
      }
      const interp = doFg && prevHasLuma && haveFrame;
      prevHasLuma = doFg;
      haveFrame = true;
      // Show the halfway frame now; the rAF loop finishes the move to the real frame.
      present(0.5, interp);
      if (!interp) lastT = 1;
    }

    // Runs every display refresh: measures refresh rate and draws generated frames in between.
    function tick(now) {
      if (!video.isConnected) return;
      requestAnimationFrame(tick);
      if (lastRaf) { const d = now - lastRaf; if (d > 2 && d < 100) displayInterval = displayInterval * 0.9 + d * 0.1; }
      lastRaf = now;
      if (!upscaleOn || !frameGenOn || lastT >= 1 || !vw) return;
      const t = Math.min(1, 0.5 + (now - arrival) / streamInterval);
      if (t > lastT) present(t, true);
    }

    video.requestVideoFrameCallback(onFrame);
    requestAnimationFrame(tick);
    console.log("[turbine] renderer attached");
  }

  if (!NATIVE && "requestVideoFrameCallback" in HTMLVideoElement.prototype) {
    setInterval(() => {
      for (const v of document.querySelectorAll("video")) {
        if (v.srcObject && v.videoWidth && !v.dataset.turbine) attachRenderer(v);
      }
    }, 500);
  }

  console.log("[turbine] loaded. Click video = lock mouse, Esc = release, F8 controller, F7 framegen, F9 stats, F10 upscaler");
})();
