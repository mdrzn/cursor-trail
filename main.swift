// CursorTrail: scia del puntatore per macOS, ispirata al mod Windhawk "Cursor Trail".
// Finestre trasparenti sopra tutti gli schermi, che ignorano i clic. La scia e' fatta di
// livelli Core Animation (niente bitmap ridisegnate dalla CPU) e il disegno si ferma
// quando non c'e' niente da animare.
import AppKit
import SwiftUI
import QuartzCore
import Carbon.HIToolbox

// ================================================================ configurazione
enum Style: String, Codable, CaseIterable { case line, ghost }
enum TrailMode: String, Codable, CaseIterable { case time, size }
enum ReplaceMode: String, Codable, CaseIterable { case auto, whole, custom }

// Valori predefiniti = quelli del mod Windhawk (tranne lo stile, che parte da "fantasmi")
struct Config: Codable, Equatable {
    var enabled = true
    var style: Style = .ghost
    // Linea
    var lineMode: TrailMode = .time
    var lineDuration = 500.0          // ms
    var lineLength = 2000.0           // punti (modalita' lunghezza)
    var lineTimeout = 2000.0          // ms di inattivita' prima di sfumare (0 = sempre visibile)
    var lineWidths = "2,1"            // testa -> coda
    var lineColors = ["00A2FF", "8B00FF"]
    var lineBlend = 100.0             // % di sfumatura tra un colore e l'altro
    var lineOpacities = "100,80"
    // Copie fantasma
    var ghostMode: TrailMode = .time
    var ghostDuration = 300.0
    var ghostCount = 20.0
    var ghostTimeout = 2000.0
    var ghostSpacing = 10.0           // 0 = automatica
    var ghostSizes = "1,0"
    var ghostOpacities = "50,20"
    var ghostColors: [String] = []    // vuoto = colori originali del cursore
    var ghostBlend = 100.0
    var ghostReplace: ReplaceMode = .auto
    var ghostCustomColor = "FFFFFF"
    // Effetti
    var rainbow = false
    var rainbowSpeed = 0.5            // giri di colore al secondo
    var minSpeed = 0.0                // punti/secondo sotto cui la scia non cresce
    // Generale
    var offsetX = 0.0, offsetY = 0.0
    var alwaysOnTop = true
    var fps = 0.0                     // 0 = frequenza dello schermo
    var hotkeyEnabled = false
    var hotkeyKey = "T"
    var hotkeyCtrl = true, hotkeyOpt = true, hotkeyShift = false, hotkeyCmd = false
    var hotkeyAnimate = true

    // Carica unendo il salvato ai predefiniti: le chiavi nuove non azzerano il resto
    static func load() -> Config {
        let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))) as? [String: Any] ?? [:]
        let saved = UserDefaults.standard.data(forKey: "config")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let merged = base.merging(saved) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "config") } }
}

final class Store: ObservableObject {
    static let shared = Store()
    @Published var c = Config.load() {
        didSet { if c != oldValue { c.save(); onChange?(oldValue) } }
    }
    @Published var launchAtLogin = LoginItem.isOn {
        didSet { LoginItem.set(launchAtLogin) }
    }
    var onChange: ((Config) -> Void)?
}

// Avvio al login tramite LaunchAgent utente (non serve copiare l'app in /Applicazioni)
enum LoginItem {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.cursortrail.plist")
    static var isOn: Bool { FileManager.default.fileExists(atPath: url.path) }
    static func set(_ on: Bool) {
        if on, let exe = Bundle.main.executablePath {
            let plist: [String: Any] = ["Label": "local.cursortrail", "ProgramArguments": [exe],
                                        "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// ================================================================ colori e rampe
struct RGB: Equatable {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 6, let v = UInt32(s, radix: 16) {
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else { self.init(0, 0, 0) }            // come il mod: valore non valido = nero
    }
    static func hue(_ h: Double) -> RGB {
        let c = NSColor(hue: CGFloat(h - floor(h)), saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        return RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
    func mix(_ o: RGB, _ f: Double) -> RGB { RGB(r + (o.r - r) * f, g + (o.g - g) * f, b + (o.b - b) * f) }
    func cg(_ a: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5)) }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// Valori "testa -> coda" a quote uguali, come nel mod: il valore i sta a i/(n-1).
// blend = % di ogni passaggio dedicata alla sfumatura (0 = fasce nette).
func rampIndex(_ n: Int, _ t: Double, blend: Double = 100) -> (Int, Int, Double) {
    guard n > 1 else { return (0, 0, 0) }
    let x = min(max(t, 0), 1) * Double(n - 1)
    let i = min(Int(x), n - 2), u = x - Double(i), w = blend / 100
    let f = w <= 0 ? (u < 0.5 ? 0 : 1) : min(max((u - (1 - w) / 2) / w, 0), 1)
    return (i, i + 1, f)
}
func ramp(_ v: [Double], _ t: Double) -> Double {
    guard !v.isEmpty else { return 0 }
    let (i, j, f) = rampIndex(v.count, t); return lerp(v[i], v[j], f)
}
func ramp(_ v: [RGB], _ t: Double, blend: Double) -> RGB {
    guard !v.isEmpty else { return RGB(0, 0, 0) }
    let (i, j, f) = rampIndex(v.count, t, blend: blend); return v[i].mix(v[j], f)
}
func numbers(_ s: String, scale: Double = 1, lo: Double = 0, hi: Double = .infinity, fallback: [Double]) -> [Double] {
    let v = s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
        .compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.map { min(max($0 * scale, lo), hi) }
    return v.isEmpty ? fallback : v
}

// ================================================================ cursore ricolorato
// Prepara in anticipo le varianti colorate della freccia (come il mod, max 64), cosi'
// a ogni frame si cambia solo l'immagine del livello.
enum CursorArt {
    static let cursor = NSCursor.arrow
    static var size: CGSize { cursor.image.size }
    static var hotSpot: NSPoint { cursor.hotSpot }

    static func bitmap() -> (ctx: CGContext, w: Int, h: Int)? {
        let s = size, scale = 2.0
        let w = Int(s.width * scale), h = Int(s.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)
        cursor.image.draw(in: NSRect(origin: .zero, size: s))
        NSGraphicsContext.restoreGraphicsState()
        return (ctx, w, h)
    }

    static var original: CGImage? { bitmap()?.ctx.makeImage() }

    // tints: un colore per variante. Ritorna le immagini nello stesso ordine.
    static func baked(_ tints: [RGB], mode: ReplaceMode, custom: RGB) -> [CGImage] {
        guard let (ctx0, w, h) = bitmap(), let base = ctx0.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let n = w * h
        func px(_ i: Int) -> (RGB, Double) {
            let a = Double(base[i * 4 + 3]) / 255
            guard a > 0 else { return (RGB(0, 0, 0), 0) }
            return (RGB(Double(base[i * 4]) / 255 / a, Double(base[i * 4 + 1]) / 255 / a, Double(base[i * 4 + 2]) / 255 / a), a)
        }
        // Peso di sostituzione per ogni pixel (0..1)
        var weight = [Double](repeating: 0, count: n)
        func similar(to target: RGB) {
            for i in 0..<n {
                let (c, a) = px(i); guard a > 0 else { continue }
                let d = sqrt(pow(c.r - target.r, 2) + pow(c.g - target.g, 2) + pow(c.b - target.b, 2)) / sqrt(3)
                weight[i] = min(max(1 - d / 0.3, 0), 1)
            }
        }
        switch mode {
        case .whole:
            for i in 0..<n where base[i * 4 + 3] > 0 { weight[i] = 1 }
        case .custom:
            similar(to: custom)
        case .auto:
            // Contorno = colore piu' frequente sui pixel che toccano il trasparente;
            // riempimento = colore interno piu' frequente diverso dal contorno.
            func key(_ c: RGB) -> Int { Int(c.r * 7.99) << 6 | Int(c.g * 7.99) << 3 | Int(c.b * 7.99) }
            func opaque(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && base[(y * w + x) * 4 + 3] >= 128 }
            var edge = [Int: Int](), inner = [Int: Int](), all = [Int: Int](), sum = [Int: (RGB, Int)]()
            for y in 0..<h { for x in 0..<w where opaque(x, y) {
                let (c, _) = px(y * w + x), k = key(c)
                let isEdge = !opaque(x - 1, y) || !opaque(x + 1, y) || !opaque(x, y - 1) || !opaque(x, y + 1)
                if isEdge { edge[k, default: 0] += 1 } else { inner[k, default: 0] += 1 }
                all[k, default: 0] += 1
                let s = sum[k] ?? (RGB(0, 0, 0), 0)
                sum[k] = (RGB(s.0.r + c.r, s.0.g + c.g, s.0.b + c.b), s.1 + 1)
            } }
            let outline = edge.max { $0.value < $1.value }?.key
            let fill = inner.filter { $0.key != outline }.max { $0.value < $1.value }?.key
                ?? all.max { $0.value < $1.value }?.key
            if let f = fill, let (s, cnt) = sum[f] { similar(to: RGB(s.r / Double(cnt), s.g / Double(cnt), s.b / Double(cnt))) }
        }
        return tints.compactMap { tint in
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let out = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for i in 0..<n {
                let (c, a) = px(i); let wt = weight[i]
                let m = c.mix(tint, wt)
                out[i * 4] = UInt8(min(255, m.r * a * 255)); out[i * 4 + 1] = UInt8(min(255, m.g * a * 255))
                out[i * 4 + 2] = UInt8(min(255, m.b * a * 255)); out[i * 4 + 3] = base[i * 4 + 3]
            }
            return ctx.makeImage()
        }
    }
}

// ================================================================ dati pronti per il disegno
// Ricalcolati solo quando cambiano le impostazioni, non a ogni frame.
struct Derived {
    var lineW: [Double] = [], lineO: [Double] = [], lineC: [RGB] = []
    var ghostS: [Double] = [], ghostO: [Double] = []
    var ghostImages: [CGImage] = []     // varianti: lungo la scia (colori) o lungo la ruota (arcobaleno)
    var ghostRainbow = false

    init() {}
    init(_ c: Config) {
        lineW = numbers(c.lineWidths, lo: 0.5, fallback: [2, 1])
        lineO = numbers(c.lineOpacities, scale: 0.01, lo: 0, hi: 1, fallback: [1, 0.8])
        lineC = c.lineColors.isEmpty ? [RGB(hex: "00A2FF")] : c.lineColors.map { RGB(hex: $0) }
        ghostS = numbers(c.ghostSizes, lo: 0, hi: 4, fallback: [1, 0])
        ghostO = numbers(c.ghostOpacities, scale: 0.01, lo: 0, hi: 1, fallback: [0.5, 0.2])
        ghostRainbow = c.rainbow
        let custom = RGB(hex: c.ghostCustomColor)
        if c.rainbow {
            ghostImages = CursorArt.baked((0..<32).map { RGB.hue(Double($0) / 32) }, mode: c.ghostReplace, custom: custom)
        } else if c.ghostColors.isEmpty {
            ghostImages = CursorArt.original.map { [$0] } ?? []
        } else {
            let cols = c.ghostColors.map { RGB(hex: $0) }
            let k = cols.count == 1 ? 1 : 32
            ghostImages = CursorArt.baked((0..<k).map { ramp(cols, k == 1 ? 0 : Double($0) / Double(k - 1), blend: c.ghostBlend) },
                                          mode: c.ghostReplace, custom: custom)
        }
    }
}

// ================================================================ modello della scia
struct Sample { let p: CGPoint; let t: CFTimeInterval; var breakBefore = false }

// Cio' che le viste devono disegnare in questo frame (coordinate globali)
struct FrameData {
    var segments: [(CGPoint, CGPoint, Double)] = []   // (da, a, t) con t 0 = testa, 1 = coda
    var ghosts: [(CGPoint, Double)] = []
    var fade = 1.0
    var bounds: CGRect? = nil
    var now: CFTimeInterval = 0
}

// ================================================================ disegno (una vista per schermo)
final class TrailView: NSView {
    static let bands = 48                 // fasce del gradiente della linea
    var lineLayers: [CAShapeLayer] = []
    var ghostLayers: [CALayer] = []
    var ghostVariant: [Int] = []
    var lineWasVisible = false
    var screenFrame: CGRect = .zero       // rettangolo globale coperto da questa vista

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()                 // vista "layer-hosting": il contenuto lo gestiamo noi
        wantsLayer = true
        for _ in 0..<Self.bands {
            let l = CAShapeLayer()
            l.fillColor = nil; l.lineCap = .butt; l.lineJoin = .round
            layer?.addSublayer(l); lineLayers.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY)
    }

    func render(_ f: FrameData, _ c: Config, _ d: Derived) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let here = f.bounds.map { $0.intersects(screenFrame) } ?? false
        renderLine(here && c.style == .line ? f : nil, c, d)
        renderGhosts(here && c.style == .ghost ? f : nil, c, d)
    }

    func renderLine(_ f: FrameData?, _ c: Config, _ d: Derived) {
        guard let f, !f.segments.isEmpty else {
            if lineWasVisible { lineLayers.forEach { $0.path = nil }; lineWasVisible = false }
            return
        }
        lineWasVisible = true
        let n = Self.bands
        let paths = (0..<n).map { _ in CGMutablePath() }
        // Ogni fascia e' una polilinea continua: niente estremita' sovrapposte che,
        // con colori semitrasparenti, lascerebbero "puntini" piu' scuri.
        var tip = [CGPoint?](repeating: nil, count: n)
        for (a, b, t) in f.segments {               // dalla testa verso la coda: b del segmento = a del precedente
            let k = min(n - 1, Int(t * Double(n)))
            let pa = local(a), pb = local(b)
            if tip[k] != pb { paths[k].move(to: pb) }
            paths[k].addLine(to: pa); tip[k] = pa
        }
        for (k, l) in lineLayers.enumerated() {
            guard !paths[k].isEmpty else { if l.path != nil { l.path = nil }; continue }
            let t = (Double(k) + 0.5) / Double(n)
            let col = c.rainbow ? RGB.hue(f.now * c.rainbowSpeed - t) : ramp(d.lineC, t, blend: c.lineBlend)
            l.strokeColor = col.cg(ramp(d.lineO, t) * f.fade)
            l.lineWidth = ramp(d.lineW, t)
            l.path = paths[k]
        }
    }

    func renderGhosts(_ f: FrameData?, _ c: Config, _ d: Derived) {
        let g = f?.ghosts ?? []
        let size = CursorArt.size, hs = CursorArt.hotSpot
        while ghostLayers.count < g.count {
            let l = CALayer()
            l.bounds = CGRect(origin: .zero, size: size)
            // ancoraggio sulla punta della freccia (l'hotspot e' misurato dall'alto)
            l.anchorPoint = CGPoint(x: hs.x / size.width, y: 1 - hs.y / size.height)
            layer?.addSublayer(l); ghostLayers.append(l); ghostVariant.append(-1)
        }
        let imgs = d.ghostImages
        for (i, l) in ghostLayers.enumerated() {
            guard i < g.count, !imgs.isEmpty, let f else { if !l.isHidden { l.isHidden = true }; continue }
            let (p, t) = g[i]
            let k = max(0.001, ramp(d.ghostS, t))
            let v: Int
            if d.ghostRainbow {
                let h = f.now * c.rainbowSpeed - t
                v = Int((h - floor(h)) * Double(imgs.count)) % imgs.count
            } else {
                v = imgs.count == 1 ? 0 : Int(t * Double(imgs.count - 1) + 0.5)
            }
            if ghostVariant[i] != v { l.contents = imgs[v]; ghostVariant[i] = v }
            l.isHidden = false
            l.position = local(p)
            l.transform = CATransform3DMakeScale(k, k, 1)
            l.opacity = Float(ramp(d.ghostO, t) * f.fade)
        }
    }

    // Cerchio che si espande (spegnimento) o si restringe (accensione), come nel mod
    func toggleAnimation(at p: CGPoint, on: Bool, color: CGColor) {
        let l = CAShapeLayer()
        l.path = CGPath(ellipseIn: CGRect(x: -20, y: -20, width: 40, height: 40), transform: nil)
        l.fillColor = nil; l.strokeColor = color; l.lineWidth = 2
        l.position = local(p)
        layer?.addSublayer(l)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = on ? 1.0 : 0.05; scale.toValue = on ? 0.05 : 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = on ? 0.0 : 1.0; fade.toValue = on ? 1.0 : 0.0
        let g = CAAnimationGroup(); g.animations = [scale, fade]; g.duration = 0.35
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "toggle")
        CATransaction.commit()
    }
}

// ================================================================ motore della scia
// Stato e logica, senza finestre: lo usano sia l'app sia il generatore di GIF.
final class TrailEngine {
    var cfg: Config { didSet { derived = Derived(cfg) } }
    private(set) var derived: Derived
    var samples: [Sample] = []
    var ghosts: [Sample] = []
    var lastGhostAt: CGPoint?
    var lastMouse: CGPoint
    var lastFrameAt: CFTimeInterval = 0
    var lastMoveAt: CFTimeInterval = 0
    var slowBreak = false

    init(_ c: Config, mouse: CGPoint) { cfg = c; derived = Derived(c); lastMouse = mouse }

    func clear() { samples.removeAll(); ghosts.removeAll(); lastGhostAt = nil }

    // Avanza di un frame con il mouse in `raw` (coordinate globali) all'istante `now`
    func step(raw: CGPoint, now: CFTimeInterval) -> FrameData {
        let c = cfg
        let p = CGPoint(x: raw.x + c.offsetX, y: raw.y - c.offsetY)    // y positivo = verso il basso
        let moved = raw != lastMouse
        let dt = max(now - lastFrameAt, 1.0 / 240)
        let speed = hypot(raw.x - lastMouse.x, raw.y - lastMouse.y) / dt
        if moved { lastMoveAt = now }
        lastMouse = raw; lastFrameAt = now

        if c.enabled && moved {
            if speed >= c.minSpeed { addSample(p, now, c) } else { slowBreak = true }
        }
        var f = FrameData(now: now)
        let idle = now - lastMoveAt
        if c.style == .line { buildLine(&f, c, idle) } else { buildGhosts(&f, c, idle) }
        return f
    }

    func addSample(_ p: CGPoint, _ now: CFTimeInterval, _ c: Config) {
        if c.style == .ghost {
            var spacing = c.ghostSpacing
            if spacing <= 0 { spacing = c.ghostMode == .size ? max(2, 300 / c.ghostCount) : 6 }
            if slowBreak { lastGhostAt = nil; slowBreak = false }
            if let last = lastGhostAt, hypot(p.x - last.x, p.y - last.y) < spacing { return }
            ghosts.append(Sample(p: p, t: now)); lastGhostAt = p
        } else {
            samples.append(Sample(p: p, t: now, breakBefore: slowBreak)); slowBreak = false
        }
    }

    // Sfumatura dopo il timeout di inattivita' (modalita' lunghezza)
    func idleFade(_ idle: Double, timeoutMs: Double, durationMs: Double) -> Double {
        guard timeoutMs > 0 else { return 1 }
        let over = idle - timeoutMs / 1000
        return over <= 0 ? 1 : max(0, 1 - over / (durationMs / 1000))
    }

    func buildLine(_ f: inout FrameData, _ c: Config, _ idle: Double) {
        if c.lineMode == .time {
            samples.removeAll { f.now - $0.t > c.lineDuration / 1000 }
        } else {
            f.fade = idleFade(idle, timeoutMs: c.lineTimeout, durationMs: c.lineDuration)
            if f.fade <= 0 { samples.removeAll() }
        }
        guard samples.count >= 2 else { if samples.count == 1 && f.fade <= 0 { samples.removeAll() }; return }
        var cum = 0.0, cut = 0
        var segs: [(CGPoint, CGPoint, Double)] = []
        segs.reserveCapacity(samples.count)
        for i in stride(from: samples.count - 1, to: 0, by: -1) {
            let a = samples[i - 1], b = samples[i]
            if c.lineMode == .size {
                if cum > c.lineLength { cut = i; break }
                cum += hypot(b.p.x - a.p.x, b.p.y - a.p.y)
            }
            if b.breakBefore { continue }
            let t = c.lineMode == .time ? (f.now - b.t) / (c.lineDuration / 1000) : cum / c.lineLength
            segs.append((a.p, b.p, min(t, 1)))
        }
        if cut > 0 { samples.removeFirst(cut) }
        f.segments = segs
        f.bounds = box(samples.map(\.p), margin: (derived.lineW.max() ?? 2) + 2)
    }

    func buildGhosts(_ f: inout FrameData, _ c: Config, _ idle: Double) {
        let dur = c.ghostDuration / 1000
        if c.ghostMode == .time {
            ghosts.removeAll { f.now - $0.t > dur }
            f.ghosts = ghosts.map { ($0.p, min(1, (f.now - $0.t) / dur)) }
        } else {
            let n = Int(c.ghostCount)
            if ghosts.count > n { ghosts.removeFirst(ghosts.count - n) }
            f.fade = idleFade(idle, timeoutMs: c.ghostTimeout, durationMs: c.ghostDuration)
            if f.fade <= 0 { ghosts.removeAll() }
            let last = Double(max(n - 1, 1))
            f.ghosts = ghosts.enumerated().map { ($1.p, Double(ghosts.count - 1 - $0) / last) }
        }
        if ghosts.isEmpty { lastGhostAt = nil }
        let s = CursorArt.size
        f.bounds = box(ghosts.map(\.p), margin: max(s.width, s.height) * max(1, derived.ghostS.max() ?? 1))
    }

    func box(_ pts: [CGPoint], margin: Double) -> CGRect? {
        guard let first = pts.first else { return nil }
        var r = CGRect(origin: first, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -margin, dy: -margin)
    }

    // Colore del cerchio di attivazione/disattivazione
    var accentColor: CGColor {
        cfg.style == .line
            ? (cfg.rainbow ? RGB.hue(0) : derived.lineC.first ?? RGB(1, 1, 1)).cg(1)
            : (cfg.ghostColors.first.map { RGB(hex: $0) } ?? RGB(1, 1, 1)).cg(1)
    }
}

// ================================================================ app
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store.shared
    var cfg: Config { store.c }
    lazy var engine = TrailEngine(store.c, mouse: NSEvent.mouseLocation)
    var views: [TrailView] = []
    var windows: [NSWindow] = []
    var link: CADisplayLink?
    var idleTimer: Timer?, wakeTimer: Timer?
    var monitors: [Any] = []
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildWindows()
        buildMenu()
        installHotKeyHandler(); registerHotKey()
        store.onChange = { [weak self] old in self?.configChanged(from: old) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Risveglio: eventi globali del mouse + controllo lento di riserva
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.wake() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.wake(); return e }) { monitors.append(m) }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NSEvent.mouseLocation != self.engine.lastMouse { self.wake() }
        }
    }

    // ------------------------------------------------------------ finestre
    var overlayLevel: NSWindow.Level {
        cfg.alwaysOnTop ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow))) : .floating
    }

    func buildWindows() {
        link?.invalidate(); link = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); views.removeAll()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = overlayLevel
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)
            let v = TrailView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenFrame = screen.frame
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w); views.append(v)
        }
        if let v = views.first {
            link = v.displayLink(target: self, selector: #selector(frame(_:)))
            applyFps()
            link?.add(to: .main, forMode: .common)
            link?.isPaused = true
        }
    }

    func applyFps() {
        let f = Float(cfg.fps)
        link?.preferredFrameRateRange = f > 0 ? CAFrameRateRange(minimum: f, maximum: f, preferred: f) : .default
    }

    @objc func screensChanged() { clearTrail(); buildWindows() }

    func configChanged(from old: Config) {
        engine.cfg = cfg
        if old.alwaysOnTop != cfg.alwaysOnTop { windows.forEach { $0.level = overlayLevel } }
        if old.fps != cfg.fps { applyFps() }
        if old.style != cfg.style || old.lineMode != cfg.lineMode || old.ghostMode != cfg.ghostMode { clearTrail() }
        if old.enabled != cfg.enabled { clearTrail() }
        if (old.hotkeyEnabled, old.hotkeyKey, old.hotkeyCtrl, old.hotkeyOpt, old.hotkeyShift, old.hotkeyCmd)
            != (cfg.hotkeyEnabled, cfg.hotkeyKey, cfg.hotkeyCtrl, cfg.hotkeyOpt, cfg.hotkeyShift, cfg.hotkeyCmd) { registerHotKey() }
        updateMenu()
        redraw()
    }

    func clearTrail() { engine.clear(); redraw() }

    func wake() {
        guard let link, link.isPaused else { return }
        link.isPaused = false
    }

    func redraw() { views.forEach { $0.render(FrameData(now: CACurrentMediaTime()), cfg, engine.derived) }; wake() }

    // ------------------------------------------------------------ un frame
    @objc func frame(_ l: CADisplayLink) {
        let c = cfg, now = CACurrentMediaTime()
        let f = engine.step(raw: NSEvent.mouseLocation, now: now)
        views.forEach { $0.render(f, c, engine.derived) }

        // Pausa: niente da animare. In modalita' "lunghezza" la scia resta ferma a schermo
        // e il disegno riparte allo scadere del timeout (per sfumarla) o al primo movimento.
        let idle = now - engine.lastMoveAt
        guard idle > 0.2 else { return }
        let empty = f.segments.isEmpty && f.ghosts.isEmpty
        let mode = c.style == .line ? c.lineMode : c.ghostMode
        let timeout = (c.style == .line ? c.lineTimeout : c.ghostTimeout) / 1000
        let still = mode == .size && f.fade >= 1 && !c.rainbow
        if empty || still {
            l.isPaused = true
            wakeTimer?.invalidate()
            if still && timeout > 0 {
                let wait = engine.lastMoveAt + timeout - now
                wakeTimer = Timer.scheduledTimer(withTimeInterval: max(wait, 0.01), repeats: false) { [weak self] _ in self?.wake() }
            }
        }
    }

    // ------------------------------------------------------------ attiva/disattiva
    @objc func toggle() {
        store.c.enabled.toggle()
        guard cfg.hotkeyAnimate else { return }
        let p = NSEvent.mouseLocation
        for v in views where v.screenFrame.contains(p) {
            v.toggleAnimation(at: p, on: cfg.enabled, color: engine.accentColor)
        }
    }

    // ------------------------------------------------------------ scorciatoia globale (Carbon: nessun permesso richiesto)
    static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { appDelegate.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func registerHotKey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        let c = cfg
        guard c.hotkeyEnabled, let code = Self.keyCodes[c.hotkeyKey.uppercased()] else { return }
        var mods: UInt32 = 0
        if c.hotkeyCtrl { mods |= UInt32(controlKey) }
        if c.hotkeyOpt { mods |= UInt32(optionKey) }
        if c.hotkeyShift { mods |= UInt32(shiftKey) }
        if c.hotkeyCmd { mods |= UInt32(cmdKey) }
        guard mods != 0 else { return }       // come il mod: serve almeno un modificatore
        RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: OSType(0x43545231), id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // ------------------------------------------------------------ barra dei menu
    var enableItem: NSMenuItem!, lineItem: NSMenuItem!, ghostItem: NSMenuItem!

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "Scia cursore")
        let m = NSMenu()
        enableItem = m.addItem(withTitle: "Scia attiva", action: #selector(toggle), keyEquivalent: "")
        m.addItem(.separator())
        lineItem = m.addItem(withTitle: "Stile: linea", action: #selector(setLine), keyEquivalent: "")
        ghostItem = m.addItem(withTitle: "Stile: copie fantasma", action: #selector(setGhost), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Impostazioni…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(withTitle: "Informazioni su CursorTrail", action: #selector(about), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = m
        updateMenu()
    }

    func updateMenu() {
        enableItem.state = cfg.enabled ? .on : .off
        lineItem.state = cfg.style == .line ? .on : .off
        ghostItem.state = cfg.style == .ghost ? .on : .off
        statusItem.button?.appearsDisabled = !cfg.enabled
    }

    @objc func setLine() { store.c.style = .line }
    @objc func setGhost() { store.c.style = .ghost }

    @objc func about() {
        let credits = NSMutableAttributedString(string: "Made by mdrzn\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 11)])
        credits.append(NSAttributedString(string: Credits.repo + "\n\n", attributes: [.link: URL(string: Credits.repo)!, .font: NSFont.systemFont(ofSize: 11)]))
        credits.append(NSAttributedString(string: "Ispirato al mod \"Cursor Trail\" per Windhawk di Ulrizza (MIT).",
                                          attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "CursorTrail"])
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "CursorTrail – Impostazioni"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        // App senza Dock: la si porta in primo piano solo mentre le impostazioni sono aperte
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) == settingsWindow { NSApp.setActivationPolicy(.accessory) }
    }
}

enum Credits {
    static let repo = "https://github.com/mdrzn/cursor-trail"
    static let author = "https://github.com/mdrzn"
}

// ================================================================ GIF dimostrative
// CursorTrail --demo <cartella>: disegna fuori schermo, con lo stesso motore dell'app,
// il cursore che percorre una traiettoria; salva i fotogrammi PNG di ogni scena.
enum Demo {
    static let size = CGSize(width: 720, height: 405), scale = 2.0, fps = 50.0, seconds = 3.0

    static var scenes: [(String, Config)] {
        var ghost = Config(); ghost.style = .ghost
        var line = Config(); line.style = .line; line.lineWidths = "5,1"
        var rainbow = Config(); rainbow.style = .line; rainbow.rainbow = true; rainbow.rainbowSpeed = 0.6
        rainbow.lineWidths = "10,6,1"; rainbow.lineDuration = 700; rainbow.lineOpacities = "100,60"
        var tinted = Config(); tinted.style = .ghost; tinted.ghostColors = ["00A2FF", "8B00FF", "FF2D95"]
        tinted.ghostSpacing = 16; tinted.ghostDuration = 450; tinted.ghostOpacities = "80,30"
        return [("fantasmi", ghost), ("linea", line), ("arcobaleno", rainbow), ("fantasmi-colorati", tinted)]
    }

    // Traiettoria a otto con accelerazioni (anello di 3 s, si ripete senza stacchi)
    static func path(_ t: Double) -> CGPoint {
        let u = t / seconds * 2 * .pi
        let w = u + 0.25 * sin(2 * u)                 // velocita' variabile
        return CGPoint(x: size.width / 2 + size.width * 0.36 * sin(w),
                       y: size.height / 2 + size.height * 0.32 * sin(2 * w))
    }

    static func run(_ out: URL) {
        let fm = FileManager.default
        let W = Int(size.width * scale), H = Int(size.height * scale)
        let hs = CursorArt.hotSpot, cs = CursorArt.size
        guard let cursorImg = CursorArt.original else { return }
        for (name, cfg) in scenes {
            let dir = out.appendingPathComponent(name)
            try? fm.removeItem(at: dir); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let engine = TrailEngine(cfg, mouse: path(0))
            let view = TrailView(frame: NSRect(origin: .zero, size: size))
            view.screenFrame = CGRect(origin: .zero, size: size)
            let n = Int(seconds * fps)
            // un giro "a vuoto" prima di registrare, cosi' la GIF si ripete senza stacchi
            for i in 0..<(2 * n) {
                let t = Double(i) / fps
                let p = path(t)
                let f = engine.step(raw: p, now: t)
                view.render(f, cfg, engine.derived)
                guard i >= n else { continue }
                let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.scaleBy(x: scale, y: scale)
                background(ctx)
                view.layer?.render(in: ctx)
                ctx.draw(cursorImg, in: CGRect(x: p.x - hs.x, y: p.y - (cs.height - hs.y), width: cs.width, height: cs.height))
                caption(ctx)
                let url = dir.appendingPathComponent(String(format: "%04d.png", i - n))
                if let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
            }
            print("ok \(name)")
        }
    }

    static func background(_ ctx: CGContext) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [RGB(hex: "2B2D42").cg(1), RGB(hex: "14151F").cg(1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    }

    static func caption(_ ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.45)]
        let s = NSAttributedString(string: "CursorTrail · made by mdrzn", attributes: attrs)
        s.draw(at: CGPoint(x: size.width - s.size().width - 14, y: 12))
        NSGraphicsContext.restoreGraphicsState()
    }
}

// ================================================================ finestra impostazioni
struct SettingsView: View {
    @ObservedObject var s = Store.shared

    var body: some View {
        TabView {
            general.tabItem { Label("Generale", systemImage: "gearshape") }
            line.tabItem { Label("Linea", systemImage: "scribble") }
            ghost.tabItem { Label("Fantasmi", systemImage: "cursorarrow.rays") }
            effects.tabItem { Label("Effetti", systemImage: "sparkles") }
        }
        .padding()
        .frame(width: 560, height: 640)
    }

    // ---------------------------------------------------------------- generale
    var general: some View {
        Form {
            Section {
                Toggle("Scia attiva", isOn: $s.c.enabled)
                Picker("Stile", selection: $s.c.style) {
                    Text("Linea").tag(Style.line)
                    Text("Copie fantasma").tag(Style.ghost)
                }.pickerStyle(.segmented)
            }
            Section("Scorciatoia da tastiera") {
                Toggle("Attiva/disattiva la scia con una scorciatoia", isOn: $s.c.hotkeyEnabled)
                HStack {
                    Toggle("⌃", isOn: $s.c.hotkeyCtrl).toggleStyle(.button)
                    Toggle("⌥", isOn: $s.c.hotkeyOpt).toggleStyle(.button)
                    Toggle("⇧", isOn: $s.c.hotkeyShift).toggleStyle(.button)
                    Toggle("⌘", isOn: $s.c.hotkeyCmd).toggleStyle(.button)
                    Text("+")
                    TextField("", text: Binding(get: { s.c.hotkeyKey },
                                                set: { s.c.hotkeyKey = String($0.uppercased().suffix(1)) }))
                        .frame(width: 34).multilineTextAlignment(.center)
                    Spacer()
                    if !hotkeyValid { Text("lettera/cifra + almeno un modificatore").font(.caption).foregroundStyle(.red) }
                }.disabled(!s.c.hotkeyEnabled)
                Toggle("Animazione quando si attiva/disattiva", isOn: $s.c.hotkeyAnimate)
            }
            Section("Posizione e livello") {
                slider("Spostamento orizzontale", $s.c.offsetX, -50...50, unit: "pt")
                slider("Spostamento verticale", $s.c.offsetY, -50...50, unit: "pt")
                Toggle("Sopra barra dei menu e Dock", isOn: $s.c.alwaysOnTop)
            }
            Section("Sistema") {
                Toggle("Avvia al login", isOn: $s.launchAtLogin)
                HStack {
                    Spacer()
                    Button("Ripristina valori predefiniti") { s.c = Config() }
                }
            }
            Section {
                HStack {
                    Text("Made by \(Text("mdrzn").bold())")
                    Spacer()
                    Link("GitHub", destination: URL(string: Credits.repo)!)
                }
                Text("Ispirato al mod \"Cursor Trail\" per Windhawk di Ulrizza.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    var hotkeyValid: Bool {
        App.keyCodes[s.c.hotkeyKey.uppercased()] != nil && (s.c.hotkeyCtrl || s.c.hotkeyOpt || s.c.hotkeyShift || s.c.hotkeyCmd)
    }

    // ---------------------------------------------------------------- linea
    var line: some View {
        Form {
            Section("Lunghezza") {
                modePicker($s.c.lineMode, time: "A tempo", size: "A lunghezza fissa")
                if s.c.lineMode == .time {
                    slider("Durata della coda", $s.c.lineDuration, 20...5000, step: 10, unit: "ms")
                } else {
                    slider("Lunghezza massima", $s.c.lineLength, 20...5000, step: 10, unit: "pt")
                    slider("Sparisce dopo (0 = mai)", $s.c.lineTimeout, 0...10000, step: 100, unit: "ms")
                    slider("Durata della dissolvenza", $s.c.lineDuration, 20...5000, step: 10, unit: "ms")
                }
            }
            Section {
                listField("Spessore", $s.c.lineWidths, hint: "punti, dalla testa alla coda — es. 2,1 oppure 6,3,1")
                listField("Opacità", $s.c.lineOpacities, hint: "% dalla testa alla coda — es. 100,80 oppure 100,0")
            } header: { Text("Forma") } footer: {
                Text("Ogni valore occupa una parte uguale della scia; ripeterlo ne allarga la parte (es. 4,4,1).").font(.caption)
            }
            Section("Colore") {
                ColorListEditor(hexes: $s.c.lineColors, minCount: 1)
                    .disabled(s.c.rainbow)
                slider("Sfumatura tra i colori", $s.c.lineBlend, 0...100, unit: "%")
                if s.c.rainbow { Text("L'arcobaleno (scheda Effetti) sostituisce questi colori.").font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }

    // ---------------------------------------------------------------- fantasmi
    var ghost: some View {
        Form {
            Section("Quantità") {
                modePicker($s.c.ghostMode, time: "A tempo", size: "Numero fisso")
                if s.c.ghostMode == .time {
                    slider("Durata della coda", $s.c.ghostDuration, 20...5000, step: 10, unit: "ms")
                } else {
                    slider("Numero di copie", $s.c.ghostCount, 2...512, unit: "")
                    slider("Sparisce dopo (0 = mai)", $s.c.ghostTimeout, 0...10000, step: 100, unit: "ms")
                    slider("Durata della dissolvenza", $s.c.ghostDuration, 20...5000, step: 10, unit: "ms")
                }
                slider("Distanza tra le copie (0 = auto)", $s.c.ghostSpacing, 0...200, unit: "pt")
            }
            Section {
                listField("Dimensione", $s.c.ghostSizes, hint: "1 = come il cursore — es. 1,0 oppure 1,1,0.5")
                listField("Opacità", $s.c.ghostOpacities, hint: "% dalla testa alla coda — es. 50,20")
            } header: { Text("Forma") } footer: {
                Text("Valori sopra 1 nella dimensione rendono le copie sgranate.").font(.caption)
            }
            Section("Colore") {
                ColorListEditor(hexes: $s.c.ghostColors, minCount: 0)
                    .disabled(s.c.rainbow)
                if s.c.ghostColors.isEmpty && !s.c.rainbow {
                    Text("Nessun colore: le copie mantengono i colori del cursore.").font(.caption).foregroundStyle(.secondary)
                }
                slider("Sfumatura tra i colori", $s.c.ghostBlend, 0...100, unit: "%")
                Picker("Cosa ricolorare", selection: $s.c.ghostReplace) {
                    Text("Automatico (interno, non il bordo)").tag(ReplaceMode.auto)
                    Text("Tutto il cursore").tag(ReplaceMode.whole)
                    Text("Solo un colore specifico").tag(ReplaceMode.custom)
                }
                if s.c.ghostReplace == .custom {
                    ColorPicker("Colore da sostituire", selection: hexColor($s.c.ghostCustomColor), supportsOpacity: false)
                }
            }
        }.formStyle(.grouped)
    }

    // ---------------------------------------------------------------- effetti
    var effects: some View {
        Form {
            Section {
                Toggle("Arcobaleno animato", isOn: $s.c.rainbow)
                slider("Velocità dell'arcobaleno", $s.c.rainbowSpeed, 0.05...3, step: 0.05, unit: "giri/s", decimals: 2)
                    .disabled(!s.c.rainbow)
            } header: { Text("Colore") } footer: {
                Text("Vale sia per la linea sia per i fantasmi e sostituisce i colori scelti.").font(.caption)
            }
            Section {
                slider("Velocità minima", $s.c.minSpeed, 0...3000, step: 50, unit: "pt/s")
            } header: { Text("Movimento") } footer: {
                Text("La scia compare solo quando il mouse si muove più veloce di così (0 = sempre).").font(.caption)
            }
            Section {
                Picker("Aggiornamenti al secondo", selection: $s.c.fps) {
                    Text("Come lo schermo").tag(0.0)
                    Text("60").tag(60.0)
                    Text("30").tag(30.0)
                }.pickerStyle(.segmented)
            } header: { Text("Prestazioni") } footer: {
                Text("Meno aggiornamenti = meno consumo, ma scia meno fluida.").font(.caption)
            }
        }.formStyle(.grouped)
    }

    // ---------------------------------------------------------------- componenti
    func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double = 1,
                unit: String, decimals: Int = 0) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: v, in: r, step: step)
                Text("\(v.wrappedValue, specifier: "%.\(decimals)f") \(unit)")
                    .monospacedDigit().frame(width: 84, alignment: .trailing)
            }
        }
    }

    func modePicker(_ v: Binding<TrailMode>, time: String, size: String) -> some View {
        Picker("Modalità", selection: v) {
            Text(time).tag(TrailMode.time)
            Text(size).tag(TrailMode.size)
        }.pickerStyle(.segmented)
    }

    func listField(_ title: String, _ v: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) { TextField("", text: v).multilineTextAlignment(.trailing) }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

func hexColor(_ b: Binding<String>) -> Binding<Color> {
    Binding(get: { let c = RGB(hex: b.wrappedValue); return Color(.sRGB, red: c.r, green: c.g, blue: c.b) },
            set: { if let n = NSColor($0).usingColorSpace(.sRGB) {
                b.wrappedValue = RGB(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)).hex } })
}

// Lista di colori dalla testa alla coda, con aggiunta/rimozione
struct ColorListEditor: View {
    @Binding var hexes: [String]
    let minCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(hexes.enumerated()), id: \.offset) { i, hex in
                HStack {
                    Text(i == 0 ? "Testa" : i == hexes.count - 1 ? "Coda" : "\(i + 1)°")
                        .frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
                    ColorPicker("", selection: hexColor(Binding(
                        get: { i < hexes.count ? hexes[i] : hex },
                        set: { if i < hexes.count { hexes[i] = $0 } })), supportsOpacity: false).labelsHidden()
                    Text("#" + hex).monospaced()
                    Spacer()
                    Button { hexes.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(hexes.count <= minCount)
                }
            }
            Button { hexes.append(hexes.last ?? "FFFFFF") } label: { Label("Aggiungi colore", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
        }
    }
}

// ================================================================ avvio
let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
    Demo.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
let appDelegate = App()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
