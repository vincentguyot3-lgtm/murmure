#!/usr/bin/env python3
"""Faux serveur de transcription (API de type AssemblyAI) pour les essais de Murmure, sans clé ni coût.

    python3 -I tools/faux-transcription.py [port] [mode] [reunion.json]
    MURMURE_TRANSCRIPTION_URL=http://127.0.0.1:18792 MURMURE_TRANSCRIPTION_KEY=essai \
        MURMURE_METHODE=enligne Murmure --bench-reunion dossier

Avec un `reunion.json` de tools/corpus-reunion.py, la transcription rendue est la référence du corpus (mots
répartis sur chaque réplique, une voix par locuteur) : le banc vérifie alors toute la chaîne (codage, envoi,
attente, tours de parole, « Moi ») sans juger la qualité du service. Sans fichier, un petit dialogue fixe.
Modes : « ok », « 401 » (clé refusée), « solde » (400, solde négatif), « erreur » (transcription en erreur),
« lent » (reste « processing » 20 s), « 429 » (premier sondage refusé, Retry-After 1 s). La création vérifie les
contraintes documentées des paramètres (400 sinon). Chaque demande est décrite sur la sortie d'erreur.
"""
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18792
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"
CORPUS = sys.argv[3] if len(sys.argv) > 3 else None
JOBS = {}


def words_for(lines):
    letters = "ABCDEFGHIJ"
    names = []
    out = []
    for line in lines:
        if line["speaker"] not in names:
            names.append(line["speaker"])
        speaker = letters[names.index(line["speaker"]) % len(letters)]
        tokens = line["text"].split()
        if not tokens:
            continue
        start, end = line["start"] * 1000, line["end"] * 1000
        step = (end - start) / len(tokens)
        for i, token in enumerate(tokens):
            out.append({"text": token, "start": int(start + i * step), "end": int(start + (i + 1) * step),
                        "confidence": 0.9, "speaker": speaker})
    return out


def reference():
    if CORPUS:
        return words_for(json.load(open(CORPUS, encoding="utf-8"))["lines"])
    return words_for([
        {"speaker": "Inspectrice", "text": "Bonjour Maître, j'ai bien reçu les déclarations 2042 et 3916.", "start": 0.5, "end": 4.0},
        {"speaker": "Conseil", "text": "Parfait, la déclaration 2047 suivra cette semaine pour monsieur Eriksson.", "start": 4.4, "end": 8.5},
        {"speaker": "Inspectrice", "text": "Très bien, je vous remercie.", "start": 9.0, "end": 10.5},
    ])


def invalid(body):
    """Contraintes de la documentation (03/11/2026) que le vrai service fait respecter par un 400."""
    if "speech_model" in body:
        return "speech_model (singulier) est déprécié : utiliser speech_models"
    if body.get("language_code") and "language_detection" in body:
        return "`language_detection` is not available when `language_code` is specified."
    if body.get("speaker_labels") and body.get("punctuate") is False:
        return "speaker_labels exige punctuate"
    options = body.get("speaker_options") or {}
    if options and "speakers_expected" in body:
        return "speaker_options et speakers_expected sont incompatibles"
    if options.get("min_speakers_expected", 1) > options.get("max_speakers_expected", 99):
        return "min_speakers_expected > max_speakers_expected"
    terms = body.get("keyterms_prompt", [])
    if any(len(t.split()) > 6 for t in terms) or sum(len(t.split()) for t in terms) > 1000:
        return "keyterms_prompt : 6 mots par expression et 1000 mots en tout au plus"
    if terms and body.get("prompt"):
        return "prompt et keyterms_prompt ne peuvent pas être envoyés ensemble"
    for item in body.get("custom_spelling", []):
        if not item.get("to") or len(item["to"].split()) != 1 or any(len(f.split()) > 5 or not f for f in item.get("from", [])):
            return "custom_spelling : « to » d'un seul mot, « from » de 5 mots au plus"
    return None


RATE_LIMITED = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if MODE == "401" or not self.headers.get("Authorization"):
            self.reply(401, {"error": "Authentication error, API token missing/invalid"})
            return False
        if MODE == "solde" and self.command == "POST" and self.path == "/v2/transcript":
            self.reply(400, {"error": "Your current account balance is negative. Please top up to continue using the API."})
            return False
        return True

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        if not self.authorized():
            return
        if self.path == "/v2/upload":
            print("[faux] envoi : %d octets (%s), début %r" % (len(raw), self.headers.get("Content-Type"), raw[4:12]), file=sys.stderr)
            self.reply(200, {"upload_url": "https://cdn.example/upload/%s" % uuid.uuid4()})
        elif self.path == "/v2/transcript":
            body = json.loads(raw or b"{}")
            problem = invalid(body)
            if problem:
                print("[faux] requête refusée : %s" % problem, file=sys.stderr)
                self.reply(400, {"error": problem})
                return
            print("[faux] création : %s" % json.dumps({k: v for k, v in body.items() if k != "keyterms_prompt"}, ensure_ascii=False),
                  "· %d termes" % len(body.get("keyterms_prompt", [])), file=sys.stderr)
            job = str(uuid.uuid4())
            JOBS[job] = time.time()
            self.reply(200, {"id": job, "status": "queued"})
        else:
            self.reply(404, {"error": "not found"})

    def do_GET(self):
        if not self.authorized():
            return
        if self.path.startswith("/v2/transcript?"):
            self.reply(200, {"transcripts": []})
            return
        job = self.path.rsplit("/", 1)[-1]
        if job not in JOBS:
            self.reply(404, {"error": "Transcript not found"})
            return
        elapsed = time.time() - JOBS[job]
        if MODE == "429" and job not in RATE_LIMITED:
            RATE_LIMITED.add(job)
            data = json.dumps({"error": "Too Many Requests"}).encode()
            self.send_response(429)
            self.send_header("Retry-After", "1")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if MODE == "erreur":
            self.reply(200, {"id": job, "status": "error", "error": "Audio file could not be decoded"})
        elif elapsed < (20 if MODE == "lent" else 2):
            self.reply(200, {"id": job, "status": "processing"})
        else:
            words = reference()
            self.reply(200, {"id": job, "status": "completed", "language_code": "fr", "words": words,
                             "text": " ".join(w["text"] for w in words)})

    def do_DELETE(self):
        if not self.authorized():
            return
        job = self.path.rsplit("/", 1)[-1]
        print("[faux] suppression de %s" % job, file=sys.stderr)
        JOBS.pop(job, None)
        self.reply(200, {"id": job, "status": "completed", "text": "Deleted by user."})


if __name__ == "__main__":
    print("Faux service de transcription sur http://127.0.0.1:%d (mode %s)" % (PORT, MODE), file=sys.stderr)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
