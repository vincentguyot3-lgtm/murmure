#!/usr/bin/env python3 -I
"""Corpus du banc « réunion » : fabrique une conversation à plusieurs voix à partir d'un dialogue écrit.

Usage : python3 -I tools/corpus-reunion.py dialogue.txt dossier [--court N]
Le dialogue est un texte avec une réplique par ligne, « Nom : texte ». Chaque nom reçoit une voix de synthèse
(Amélie, Thomas, Thomas grave par rééchantillonnage) ; la première voix est « au téléphone » (bande étroite 8 kHz,
niveau plus faible). Les répliques s'enchaînent avec des pauses, et une sur huit empiète sur la précédente.
Le dossier reçoit `reunion.wav` (16 kHz mono) et `reunion.json` (répliques de référence : voix, texte, début, fin).
Banc : Murmure --bench-reunion dossier.

Avec `--deux-pistes Nom` (après le dossier), la réunion est enregistrée comme dans Murmure pendant une visio : les
répliques de `Nom` (l'utilisateur, sur place, sans bande étroite) vont au micro (`micro.wav`), les autres au son de
l'ordinateur (`ordinateur.wav`). `--echo G` (0,5 par défaut, 0 pour un casque) ajoute au micro l'écho des
haut-parleurs : le son de l'ordinateur retardé de 70 ms (`--retard ms`) et réverbéré par la pièce, au niveau G.
"""
import array
import json
import os
import random
import re
import subprocess
import sys
import wave

args = [a for a in sys.argv[1:] if not a.startswith("--")]
short = int(sys.argv[sys.argv.index("--court") + 1]) if "--court" in sys.argv else None
if len(args) < 2:
    sys.exit(__doc__)
dialogue, out = args[0], args[1]
tmp = os.path.join(out, "tmp")
os.makedirs(tmp, exist_ok=True)
RATE = 16000
random.seed(7)

lines = []
for raw in open(dialogue, encoding="utf-8"):
    m = re.match(r"^([^:]{1,40}):\s*(.+)$", raw.strip())
    if m:
        lines.append((m.group(1).strip(), m.group(2).strip()))
if short:
    lines = lines[:short]
names = []
for name, _ in lines:
    if name not in names:
        names.append(name)
# (voix, facteur de hauteur, bande étroite) ; un facteur < 1 rend la voix plus grave et un peu plus lente.
VOICES = [("Thomas", 1.0, True), ("Amelie", 1.0, False), ("Thomas", 0.88, False), ("Amelie", 0.9, True)]
if "--large-bande" in sys.argv:  # toutes les voix sur place, sans bande étroite
    VOICES = [(v, p, False) for v, p, _ in VOICES]
assignment = {name: VOICES[i % len(VOICES)] for i, name in enumerate(names)}
local = sys.argv[sys.argv.index("--deux-pistes") + 1] if "--deux-pistes" in sys.argv else None
echo_gain = float(sys.argv[sys.argv.index("--echo") + 1]) if "--echo" in sys.argv else 0.5
echo_delay = float(sys.argv[sys.argv.index("--retard") + 1]) / 1000 if "--retard" in sys.argv else 0.070
# Part des répliques qui empiètent sur la précédente (`--chevauchement P`, une sur huit par défaut), de 0,3 s
# (`--empiete S`).
overlap = float(sys.argv[sys.argv.index("--chevauchement") + 1]) if "--chevauchement" in sys.argv else 0.125
overlap_length = float(sys.argv[sys.argv.index("--empiete") + 1]) if "--empiete" in sys.argv else 0.3
if local:
    # L'utilisateur parle sur place (vraie voix ou voix de synthèse sans bande étroite) ; les autres à distance.
    remote = [v for v in VOICES if v[0] != "Amelie" or v[2]]
    others = [n for n in names if n != local]
    assignment = {name: remote[i % len(remote)] for i, name in enumerate(others)}
    assignment[local] = ("Amelie", 1.0, False)


def synthesize(text, voice, pitch, narrow, path):
    """Voix de synthèse en 16 kHz mono 16 bits, après bande étroite et changement de hauteur éventuels.
    Une réplique « @fichier.wav|texte » prend l'audio du fichier (vraie voix) au lieu de la synthèse."""
    rate = 8000 if narrow else RATE
    aiff, wav, final = path + ".aiff", path + ".wav", path + "-16k.wav"
    if text.startswith("@"):
        aiff = text[1:].split("|", 1)[0]
    else:
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    # Bande étroite : rééchantillonnage à 8 kHz (comme un téléphone), puis retour à 16 kHz.
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@%d" % rate, aiff, wav], check=True)
    if pitch != 1.0:
        # Les mêmes échantillons déclarés à une fréquence plus basse : afconvert rééchantillonne ensuite.
        with wave.open(wav, "rb") as w:
            samples = w.readframes(w.getnframes())
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(int(rate * pitch))
            w.writeframes(samples)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@%d" % RATE, wav, final], check=True)
    with wave.open(final, "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return array.array("h", w.readframes(w.getnframes()))


mix = array.array("h")
tracks = {"micro": [], "ordinateur": []}  # en flottants, pour l'écho
reference = []
cursor = 0  # en échantillons
previous = None
for i, (name, text) in enumerate(lines):
    voice, pitch, narrow = assignment[name]
    samples = synthesize(text, voice, pitch, narrow, os.path.join(tmp, "%03d" % i))
    gain = 0.45 if narrow else 0.8
    samples = array.array("h", (max(-32768, min(32767, int(s * gain))) for s in samples))
    # Pause : 0,2–0,6 s entre deux voix, 0,5–1 s pour la même voix ; une réplique sur huit empiète de 0,3 s.
    if previous is None:
        gap = RATE // 2
    elif previous == name:
        gap = int(RATE * random.uniform(0.5, 1.0))
    elif random.random() < overlap:
        gap = -int(RATE * overlap_length)
    else:
        gap = int(RATE * random.uniform(0.2, 0.6))
    start = max(0, cursor + gap)
    end = start + len(samples)
    if end > len(mix):
        mix.extend([0] * (end - len(mix)))
    for k, s in enumerate(samples):
        mix[start + k] = max(-32768, min(32767, mix[start + k] + s))
    if local:
        track = tracks["micro" if name == local else "ordinateur"]
        if end > len(track):
            track.extend([0.0] * (end - len(track)))
        for k, s in enumerate(samples):
            track[start + k] += s
    spoken = text.split("|", 1)[1] if text.startswith("@") else text
    reference.append({"speaker": name, "text": spoken, "start": start / RATE, "end": end / RATE})
    cursor = end
    previous = name
    print("%3d/%d %-20s %6.1f s" % (i + 1, len(lines), name, end / RATE), file=sys.stderr)

mix.extend([0] * (RATE // 2))
with wave.open(os.path.join(out, "reunion.wav"), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(mix.tobytes())
if local:
    length = len(mix)
    mic = tracks["micro"] + [0.0] * (length - len(tracks["micro"]))
    system = tracks["ordinateur"] + [0.0] * (length - len(tracks["ordinateur"]))
    if echo_gain > 0:
        # Réponse de la pièce : trajet direct au retard (70 ms par défaut), puis 24 réflexions éteintes en 0,3 s.
        taps = [(int(RATE * echo_delay), echo_gain)]
        for _ in range(24):
            delay = random.uniform(0.005, 0.300)
            taps.append((int(RATE * (echo_delay + delay)), echo_gain * 0.6 * 2.718 ** (-delay / 0.08) * random.choice((-1, 1))))
        spans = [(int(line["start"] * RATE), int(line["end"] * RATE)) for line in reference if line["speaker"] != local]
        for d, a in taps:
            for s0, s1 in spans:
                for k in range(s0, min(s1, length - d)):
                    mic[k + d] += a * system[k]
    # Souffle du micro (-60 dBFS) : un vrai micro n'est jamais muet.
    mic = [x + random.gauss(0, 30) for x in mic]
    for track_name, samples in (("micro", mic), ("ordinateur", system)):
        with wave.open(os.path.join(out, track_name + ".wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(array.array("h", (max(-32768, min(32767, int(x))) for x in samples)).tobytes())
voices = {n: {"voice": v[0], "pitch": v[1], "narrowband": v[2]} for n, v in assignment.items()}
with open(os.path.join(out, "reunion.json"), "w", encoding="utf-8") as f:
    json.dump({"voices": voices, "lines": reference, **({"local": local} if local else {})}, f, ensure_ascii=False, indent=1)
print("%s : %d répliques, %d voix, %.1f min" % (out, len(reference), len(names), len(mix) / RATE / 60))
