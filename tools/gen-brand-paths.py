"""Génère BrandPaths.swift : tracés SVG (viewBox 24 × 24) des marques, d'après Simple Icons (CC0)."""
import sys
src, dst = sys.argv[1], sys.argv[2]
names = {
    "claude": "claude", "notion": "notion", "gmail": "gmail", "googlecalendar": "googleCalendar",
    "googlemeet": "googleMeet", "zoom": "zoom", "webex": "webex", "obsidian": "obsidian",
    "googledrive": "googleDrive", "dropbox": "dropbox", "icloud": "icloud", "whatsapp": "whatsapp",
    "todoist": "todoist", "linear": "linear", "asana": "asana", "trello": "trello", "evernote": "evernote",
}
out = ["import Foundation", "",
       "/// Tracés SVG des marques (grille 24 × 24, remplissage), d'après Simple Icons (domaine public, CC0) ;",
       "/// rendus en monochrome par `BrandShape`. Fichier généré par tools/gen-brand-paths.py, ne pas retoucher à la main.",
       "enum BrandPaths {"]
for line in open(src, encoding="utf-8"):
    name, _, d = line.rstrip("\n").partition("|")
    if name in names and d:
        out.append(f'    static let {names[name]} = "{d}"')
# Slack n'est plus distribué par Simple Icons : quatre « pilules » et quatre lobes, grille 24 × 24.
out.append('    static let slack = "M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"')
out.append("}")
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("écrit", dst, len(out) - 6, "tracés")
