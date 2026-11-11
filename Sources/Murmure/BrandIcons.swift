import SwiftUI

// Icônes des connecteurs, toutes en monochrome (la couleur du texte), dans l'esprit des pictogrammes maison :
// la marque est reconnaissable, mais aucune couleur de marque ne vient dans la fenêtre.
// Trois familles : les tracés de marque (`BrandPaths`, grille 24 × 24, Claude, Notion, Gmail…), les symboles SF pour
// les applications d'Apple (Mail, Calendrier, Rappels, Notes), et des pastilles-lettres pour les marques dont le
// logo n'est pas libre (Outlook, Teams, Word : un « O », un « T », un « W » dans un carré arrondi).

/// Icône d'un connecteur.
enum BrandIcon: Hashable {
    /// Tracé SVG rempli (grille 24 × 24).
    case path(String)
    /// Symbole SF.
    case symbol(String)
    /// Lettre dans un carré arrondi.
    case letter(String)

    static let claude = BrandIcon.path(BrandPaths.claude)
    static let notion = BrandIcon.path(BrandPaths.notion)
    static let gmail = BrandIcon.path(BrandPaths.gmail)
    static let googleCalendar = BrandIcon.path(BrandPaths.googleCalendar)
    static let googleMeet = BrandIcon.path(BrandPaths.googleMeet)
    static let googleDrive = BrandIcon.path(BrandPaths.googleDrive)
    static let zoom = BrandIcon.path(BrandPaths.zoom)
    static let webex = BrandIcon.path(BrandPaths.webex)
    static let obsidian = BrandIcon.path(BrandPaths.obsidian)
    static let dropbox = BrandIcon.path(BrandPaths.dropbox)
    static let icloud = BrandIcon.path(BrandPaths.icloud)
    static let whatsapp = BrandIcon.path(BrandPaths.whatsapp)
    static let todoist = BrandIcon.path(BrandPaths.todoist)
    static let slack = BrandIcon.path(BrandPaths.slack)
    static let outlook = BrandIcon.letter("O")
    static let teams = BrandIcon.letter("T")
    static let word = BrandIcon.letter("W")
    static let oneNote = BrandIcon.letter("N")
    static let mail = BrandIcon.symbol("envelope")
    static let calendar = BrandIcon.symbol("calendar")
    static let reminders = BrandIcon.symbol("checklist")
    static let notes = BrandIcon.symbol("note.text")
    static let faceTime = BrandIcon.symbol("video")
    static let folder = BrandIcon.symbol("folder")
    static let claudeCode = BrandIcon.symbol("chevron.left.forwardslash.chevron.right")
    static let webhook = BrandIcon.symbol("arrow.up.forward.app")
}

/// Rend une `BrandIcon` dans un carré de `size` points, en monochrome.
struct BrandIconView: View {
    let icon: BrandIcon
    var size: CGFloat = 18
    var color: Color = Theme.fg

    var body: some View {
        let side = size * Settings.uiScale
        Group {
            switch icon {
            case .path(let data):
                BrandShape(data: data)
                    .fill(color, style: FillStyle(eoFill: true))
                    .frame(width: side * 0.86, height: side * 0.86)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: side * 0.78, weight: .regular))
                    .foregroundStyle(color)
            case .letter(let letter):
                // La lettre seule : c'est le cadre de la ligne qui fait la pastille.
                Text(letter)
                    .font(.system(size: side * 0.72, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Tracé SVG (`d="…"`) ramené dans un rectangle : les commandes M, L, H, V, C, S, Q, T, A et Z, absolues et relatives,
/// comme les écrivent les icônes Simple Icons. Les arcs sont convertis en courbes de Bézier.
struct BrandShape: Shape {
    let data: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        var path = SVGPath.parse(data)
        let transform = CGAffineTransform(translationX: rect.midX - viewBox * scale / 2, y: rect.midY - viewBox * scale / 2)
            .scaledBy(x: scale, y: scale)
        path = path.applying(transform)
        return path
    }
}

/// Lecteur minimal de l'attribut `d` d'un chemin SVG.
enum SVGPath {
    private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func parse(_ data: String) -> Path {
        lock.lock()
        if let cached = cache[data] { lock.unlock(); return cached }
        lock.unlock()
        let path = build(data)
        lock.lock()
        cache[data] = path
        lock.unlock()
        return path
    }

    private static func build(_ data: String) -> Path {
        var path = Path()
        let tokens = tokenize(data)
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastCommand: Character = "M"

        func number() -> CGFloat? {
            guard index < tokens.count, case .number(let value) = tokens[index] else { return nil }
            index += 1
            return value
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while index < tokens.count {
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
            }
            let relative = command.isLowercase
            let upper = Character(command.uppercased())
            switch upper {
            case "M":
                guard let p = point(relative: relative) else { index = tokens.count; break }
                path.move(to: p)
                current = p; start = p
                // Les paires suivantes d'un M sont des L implicites.
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let p = point(relative: relative) else { index = tokens.count; break }
                path.addLine(to: p); current = p; lastControl = nil
            case "H":
                guard let x = number() else { index = tokens.count; break }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = number() else { index = tokens.count; break }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case "C":
                guard let c1 = point(relative: relative), let c2 = point(relative: relative), let p = point(relative: relative) else { index = tokens.count; break }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "S":
                guard let c2 = point(relative: relative), let p = point(relative: relative) else { index = tokens.count; break }
                let c1 = ["C", "S"].contains(lastCommand.uppercased()) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "Q":
                guard let c = point(relative: relative), let p = point(relative: relative) else { index = tokens.count; break }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case "T":
                guard let p = point(relative: relative) else { index = tokens.count; break }
                let c = ["Q", "T"].contains(lastCommand.uppercased()) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case "A":
                guard let rx = number(), let ry = number(), let rotation = number(), let large = number(), let sweep = number(),
                      let p = point(relative: relative) else { index = tokens.count; break }
                arc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large != 0, sweep: sweep != 0)
                current = p; lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                index = tokens.count
            }
            lastCommand = upper
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    /// Découpe « M4.5-2.3l.5.5 » en commandes et nombres (les nombres peuvent se suivre sans séparateur).
    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var number = ""
        func flush() {
            if let value = Double(number) { tokens.append(.number(CGFloat(value))) }
            number = ""
        }
        for char in data {
            if char.isLetter && char != "e" && char != "E" {
                flush()
                tokens.append(.command(char))
            } else if char == "-" || char == "+" {
                // Un signe commence un nouveau nombre, sauf après un exposant.
                if number.hasSuffix("e") || number.hasSuffix("E") { number.append(char) } else { flush(); number = String(char) }
            } else if char == "." {
                // Un second point commence un nouveau nombre (« .5.5 »).
                if number.contains(".") || number.contains("e") { flush() }
                number.append(char)
            } else if char.isNumber || char == "e" || char == "E" {
                number.append(char)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Arc elliptique SVG → courbes de Bézier (algorithme de l'annexe « implementation notes » de SVG 1.1).
    private static func arc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint, rx: CGFloat, ry: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        guard rx != 0, ry != 0 else { path.addLine(to: p2); return }
        var rx = abs(rx), ry = abs(ry)
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if large == sweep { coefficient = -coefficient }
        let cx1 = coefficient * rx * y1 / ry, cy1 = -coefficient * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / length)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + step), sin2 = sin(theta + step)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cosPhi * rx * x - sinPhi * ry * y + cx, y: sinPhi * rx * x + cosPhi * ry * y + cy)
            }
            let c1 = map(cos1 - t * sin1, sin1 + t * cos1)
            let c2 = map(cos2 + t * sin2, sin2 - t * cos2)
            let end = map(cos2, sin2)
            path.addCurve(to: end, control1: c1, control2: c2)
            theta += step
        }
    }
}
