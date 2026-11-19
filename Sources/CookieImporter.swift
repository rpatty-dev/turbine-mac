import CommonCrypto
import Foundation
import SQLite3
import WebKit

// Grabs the user's own Xbox login cookies from whichever Chromium browser they're signed into
// (Chrome, Brave, Edge, Arc, Vivaldi, Opera, Chromium) and drops them into the app's web view so
// Remote Play opens already signed in. Local only, auth domains only. Two one-time macOS prompts:
// "Turbine wants to access data from <browser>" and a Keychain allow for the browser's Safe Storage key.

struct BrowserProfile {
  let name: String       // e.g. "Google Chrome"
  let dir: String        // user data dir
  let keychainService: String  // e.g. "Chrome Safe Storage"
  let keychainAccount: String  // e.g. "Chrome"
}

enum ImportResult { case ok(Int, String), noData, denied }

enum CookieImporter {
  static let domains = ["xbox.com", "live.com", "microsoft.com", "microsoftonline.com", "office.com", "xboxlive.com"]
  static let authNames = ["RPSSecAuth", "RPSAuth", "WLSSC", "MSPAuth", "MSPProf", "__Host-MSAAUTHP", "ANON", "MUID"]

  static func wanted(_ host: String) -> Bool {
    let h = host.hasPrefix(".") ? String(host.dropFirst()) : host
    return domains.contains { h == $0 || h.hasSuffix("." + $0) }
  }

  static func browsers() -> [BrowserProfile] {
    let base = ("~/Library/Application Support" as NSString).expandingTildeInPath
    let defs: [(String, String, String, String)] = [
      ("Google Chrome", "Google/Chrome", "Chrome Safe Storage", "Chrome"),
      ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage", "Brave"),
      ("Microsoft Edge", "Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
      ("Arc", "Arc", "Arc Safe Storage", "Arc"),
      ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage", "Vivaldi"),
      ("Opera", "com.operasoftware.Opera", "Opera Safe Storage", "Opera"),
      ("Chromium", "Chromium", "Chromium Safe Storage", "Chromium"),
    ]
    return defs.compactMap { (name, sub, svc, acct) in
      let d = "\(base)/\(sub)"
      return FileManager.default.fileExists(atPath: d) ? BrowserProfile(name: name, dir: d, keychainService: svc, keychainAccount: acct) : nil
    }
  }

  static func cookieDBs(_ b: BrowserProfile) -> [String] {
    var out: [String] = []
    let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: b.dir)) ?? [])
      .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
    for p in (profiles.isEmpty ? ["Default"] : profiles) {
      for c in ["\(b.dir)/\(p)/Cookies", "\(b.dir)/\(p)/Network/Cookies"] where FileManager.default.fileExists(atPath: c) { out.append(c) }
    }
    return out
  }

  // Safe Storage key: PBKDF2-SHA1(keychain password, "saltysalt", 1003 iters, 16 bytes).
  static func key(_ b: BrowserProfile) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-wa", b.keychainAccount, "-s", b.keychainService]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let out = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0,
          let pw = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !pw.isEmpty else { return nil }
    var out16 = Data(count: 16); let salt = Array("saltysalt".utf8)
    let ok = out16.withUnsafeMutableBytes { ob in
      pw.withCString { pc in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pc, strlen(pc), salt, salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, ob.bindMemory(to: UInt8.self).baseAddress, 16)
      }
    }
    return ok == kCCSuccess ? out16 : nil
  }

  // AES-128-CBC, IV = 16 spaces; modern Chrome prepends a 32-byte domain-hash to the plaintext.
  static func decrypt(_ enc: Data, _ key: Data) -> String? {
    guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return String(data: enc, encoding: .utf8) }
    let body = enc.dropFirst(3); let iv = [UInt8](repeating: 0x20, count: 16)
    var out = Data(count: body.count + kCCBlockSizeAES128); var moved = 0
    let st = out.withUnsafeMutableBytes { ob in body.withUnsafeBytes { bb in key.withUnsafeBytes { kb in
      CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
        kb.baseAddress, 16, iv, bb.baseAddress, body.count, ob.baseAddress, ob.count, &moved)
    } } }
    guard st == kCCSuccess else { return nil }
    out.removeSubrange(moved..<out.count)
    if out.count >= 32 { out.removeFirst(32) }
    return String(data: out, encoding: .utf8)
  }

  // Reads one DB (copied first so a running browser's lock doesn't block us). permDenied flips true on TCC denial.
  static func read(_ path: String, _ key: Data, _ permDenied: inout Bool) -> [HTTPCookie] {
    let tmp = NSTemporaryDirectory() + "turbine-\(abs(path.hashValue)).sqlite"
    try? FileManager.default.removeItem(atPath: tmp)
    do { try FileManager.default.copyItem(atPath: path, toPath: tmp) }
    catch { if (error as NSError).code == 257 || (error as NSError).code == 1 { permDenied = true }; return [] }
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var db: OpaquePointer?
    guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT host_key,name,encrypted_value,path,expires_utc,is_secure FROM cookies", -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    var result: [HTTPCookie] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let hc = sqlite3_column_text(stmt, 0), let nc = sqlite3_column_text(stmt, 1) else { continue }
      let host = String(cString: hc); guard wanted(host) else { continue }
      let name = String(cString: nc)
      guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
      let enc = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
      guard let value = decrypt(enc, key), !value.isEmpty else { continue }
      let cpath = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "/"
      let ce = sqlite3_column_int64(stmt, 4)
      let exp = ce > 0 ? Date(timeIntervalSince1970: Double(ce) / 1_000_000 - 11_644_473_600) : Date().addingTimeInterval(86400 * 30)
      var props: [HTTPCookiePropertyKey: Any] = [.domain: host, .path: cpath, .name: name, .value: value, .expires: exp]
      if sqlite3_column_int(stmt, 5) != 0 { props[.secure] = "TRUE" }
      if let c = HTTPCookie(properties: props) { result.append(c) }
    }
    return result
  }

  // Scans every browser; picks cookies from the one actually signed into Xbox (most auth cookies).
  static func collect() -> (ImportResult, [HTTPCookie]) {
    var anyData = false, denied = false, best: [HTTPCookie] = [], bestBrowser = "", bestScore = -1
    for b in browsers() {
      let dbs = cookieDBs(b)
      if dbs.isEmpty { continue }
      guard let k = key(b) else { continue } // Keychain denied/absent for this browser
      for db in dbs {
        var perm = false
        let cs = read(db, k, &perm)
        if perm { denied = true; continue }
        if !cs.isEmpty { anyData = true }
        let score = cs.filter { authNames.contains($0.name) }.count
        if score > bestScore || (score == bestScore && cs.count > best.count) { bestScore = score; best = cs; bestBrowser = b.name }
      }
    }
    if !best.isEmpty { return (.ok(best.count, bestBrowser), best) }
    if denied && !anyData { return (.denied, []) }
    return (.noData, [])
  }

  static func importInto(_ store: WKHTTPCookieStore, done: @escaping (ImportResult) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let (r, cs) = collect()
      DispatchQueue.main.async {
        guard !cs.isEmpty else { done(r); return }
        var left = cs.count
        for c in cs { store.setCookie(c) { left -= 1; if left == 0 { done(r) } } }
      }
    }
  }
}
