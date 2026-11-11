import SwiftUI

// Formes maison du panneau gauche et de l'accueil : tracées au trait fin, bouts ronds, dans le même esprit
// que `LogoShape`. Séparées de `DesignSystem.swift` pour ne pas mêler les pictogrammes aux contrôles.

/// Pictogrammes dessinés par Murmure (le reste du panneau garde des symboles SF : personnes, micro, corbeille).
enum Glyph: Hashable, CaseIterable {
    /// Vos Murmures : un toit en chevron et deux montants.
    case house
    /// Réglages : deux lignes horizontales, un curseur rond sur chacune.
    case sliders
    /// Dictionnaire : trois lignes de longueur décroissante et une petite marque en bas à droite.
    case dictionary
    /// Aujourd'hui : un calendrier.
    case calendar
    /// Épinglés : une étoile.
    case star
    /// Extraits : une bulle avec deux lignes.
    case bubble
    /// Cette semaine : trois barres.
    case bars
    /// Lexique : un livre ouvert, ses deux pages légèrement cintrées, et un signet sur la page de droite.
    case lexicon
}

/// Tracé d'un pictogramme dans un carré ; coordonnées sur une grille de 16 × 16.
struct GlyphShape: Shape {
    let glyph: Glyph

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * unit, y: rect.midY - 8 * unit)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }
        func line(_ path: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: p(x1, y1))
            path.addLine(to: p(x2, y2))
        }
        var path = Path()
        switch glyph {
        case .house:
            path.move(to: p(2, 8.2))
            path.addLine(to: p(8, 2.6))
            path.addLine(to: p(14, 8.2))
            line(&path, 4.2, 7.6, 4.2, 13.6)
            line(&path, 11.8, 7.6, 11.8, 13.6)
        case .sliders:
            // Chaque ligne est interrompue autour de son curseur, comme un vrai potentiomètre.
            let radius: CGFloat = 2.1
            for (y, knob) in [(CGFloat(5.3), CGFloat(10.2)), (10.7, 5.8)] {
                line(&path, 2, y, knob - radius - 0.6, y)
                line(&path, knob + radius + 0.6, y, 14, y)
                path.addEllipse(in: CGRect(x: p(knob, y).x - radius * unit, y: p(knob, y).y - radius * unit,
                                           width: radius * 2 * unit, height: radius * 2 * unit))
            }
        case .dictionary:
            line(&path, 2.5, 4, 13.5, 4)
            line(&path, 2.5, 8, 10.5, 8)
            line(&path, 2.5, 12, 7.5, 12)
            line(&path, 11.5, 12, 13.5, 12)
        case .calendar:
            path.addRoundedRect(in: CGRect(x: p(2.5, 3.5).x, y: p(2.5, 3.5).y, width: 11 * unit, height: 10.5 * unit),
                                cornerSize: CGSize(width: 2 * unit, height: 2 * unit))
            line(&path, 2.5, 7, 13.5, 7)
            line(&path, 5.5, 2, 5.5, 5)
            line(&path, 10.5, 2, 10.5, 5)
        case .star:
            let center = p(8, 8.4)
            let outer = 6.2 * unit, inner = 2.7 * unit
            for i in 0..<10 {
                let angle = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
                let radius = i.isMultiple(of: 2) ? outer : inner
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        case .bubble:
            // Bulle à coins ronds, dont le coin inférieur gauche se prolonge en queue.
            path.move(to: p(5, 2.5))
            path.addLine(to: p(11, 2.5))
            path.addQuadCurve(to: p(14, 5.5), control: p(14, 2.5))
            path.addLine(to: p(14, 8.5))
            path.addQuadCurve(to: p(11, 11.5), control: p(14, 11.5))
            path.addLine(to: p(7.5, 11.5))
            path.addLine(to: p(4.2, 14))
            path.addLine(to: p(4.2, 11))
            path.addQuadCurve(to: p(2, 8.5), control: p(2, 11))
            path.addLine(to: p(2, 5.5))
            path.addQuadCurve(to: p(5, 2.5), control: p(2, 2.5))
            line(&path, 5.2, 5.8, 10.8, 5.8)
            line(&path, 5.2, 8.3, 8.8, 8.3)
        case .bars:
            line(&path, 4, 9.5, 4, 13.5)
            line(&path, 8, 3.5, 8, 13.5)
            line(&path, 12, 6.8, 12, 13.5)
        case .lexicon:
            // Deux pages qui se creusent vers le dos, comme un livre posé ouvert.
            for side: CGFloat in [-1, 1] {
                path.move(to: p(8, 4.4))
                path.addQuadCurve(to: p(8 + side * 6, 3.4), control: p(8 + side * 3, 2.7))
                path.addLine(to: p(8 + side * 6, 12.2))
                path.addQuadCurve(to: p(8, 13.4), control: p(8 + side * 3, 11.5))
            }
            line(&path, 8, 4.4, 8, 13.4)
            // Signet : un ruban à queue d'aronde qui descend du haut de la page de droite.
            path.move(to: p(10.3, 3.3))
            path.addLine(to: p(10.3, 8))
            path.addLine(to: p(11.25, 7.1))
            path.addLine(to: p(12.2, 8))
            path.addLine(to: p(12.2, 3.25))
        }
        return path
    }
}

/// Pictogramme maison au trait, à la taille d'un symbole SF dans le même texte.
struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.3

    var body: some View {
        let side = size * Settings.uiScale
        GlyphShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * Settings.uiScale, lineCap: .round, lineJoin: .round))
            .frame(width: side, height: side)
    }
}

/// Icône d'un élément de navigation ou de la palette : symbole SF ou pictogramme maison.
enum NavIcon: Hashable {
    case symbol(String)
    case glyph(Glyph)
}

/// Rend un `NavIcon` dans un cadre de largeur fixe, pour aligner les libellés.
struct IconView: View {
    let icon: NavIcon
    var size: CGFloat = 14
    var width: CGFloat = 16

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name): Image(systemName: name)
            case .glyph(let glyph): GlyphView(glyph: glyph, size: size)
            }
        }
        .frame(width: width * Settings.uiScale)
    }
}

// MARK: - Bouton carré

/// Bouton carré au trait (28 pt) qui ne porte qu'un symbole : outils de l'en-tête de l'accueil.
struct SquareButtonStyle: ButtonStyle {
    var side: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, weight: .medium))
            .foregroundStyle(Theme.fg)
            .frame(width: side * Settings.uiScale, height: side * Settings.uiScale)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Bouton carré avec son infobulle ; `symbol` est un symbole SF.
struct SquareButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(SquareButtonStyle())
            .help(help)
    }
}

// MARK: - Dossiers teintés

/// Pastille de la couleur du dossier (7 pt) ; un dossier relié à un dossier du Mac porte en plus un petit
/// engrenage teinté, en bas à droite. `showsExport` faux : le rond seul (panneau, lignes de la liste), illisible à
/// cette taille ; la copie se lit dans le menu « … » du dossier et dans la puce de la fiche.
struct FolderDot: View {
    let folder: Folder
    var size: CGFloat = 7
    var showsExport = true

    var body: some View {
        let tint = Theme.folderTint(folder.tintIndex)
        Circle()
            .fill(tint)
            .frame(width: size * Settings.uiScale, height: size * Settings.uiScale)
            .overlay(alignment: .bottomTrailing) {
                if showsExport, folder.exportPath != nil {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 6 * Settings.uiScale, weight: .bold))
                        .foregroundStyle(tint)
                        .background(Circle().fill(Theme.bg).padding(-1))
                        .offset(x: 4.5 * Settings.uiScale, y: 4 * Settings.uiScale)
                }
            }
    }
}

/// Étiquette d'un dossier dans le tableau et la fiche : la pastille devant le nom, dans le cadre de `Tag`.
struct FolderTag: View {
    let folder: Folder

    var body: some View {
        HStack(spacing: 6) {
            FolderDot(folder: folder, size: 6)
            Text(folder.name).lineLimit(1)
        }
        .font(.ui(11))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Theme.fg)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }
}

extension NavIcon: ExpressibleByStringLiteral {
    /// Un nom de symbole SF écrit tel quel (« mic ») reste accepté partout où une icône est attendue.
    init(stringLiteral value: String) { self = .symbol(value) }
}

// MARK: - Aperçu statique

/// Aperçu en ligne de commande : `ImageRenderer` ne dessine pas les vues AppKit (menus flottants, clic droit,
/// champs de texte), qui apparaissent barrées de jaune. En mode statique, les composants de la liste les remplacent
/// par leur simple apparence.
enum StaticPreview {
    static var active = false
    /// L'aperçu dessine les champs du modèle de langage comme s'il était prêt (barre « Demander à Murmure »),
    /// pour vérifier leur état normal sur une machine où il ne tourne pas.
    static var modelePret = false
}

/// `MenuButton` qui, en aperçu statique, ne montre que son étiquette.
struct PreviewSafeMenuButton<Label: View>: View {
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: () -> Label

    var body: some View {
        if StaticPreview.active {
            label()
        } else {
            MenuButton(entries: entries, label: label)
        }
    }
}

extension View {
    /// `onRightClick`, sauf en aperçu statique.
    @ViewBuilder func previewSafeRightClick(_ entries: @escaping () -> [MenuEntry]) -> some View {
        if StaticPreview.active { self } else { onRightClick(entries) }
    }
}
