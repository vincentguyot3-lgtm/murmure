#!/usr/bin/env python3
"""Faux serveur de l'API Claude pour les essais de Murmure, sans clé ni jeton dépensé.

    python3 tools/faux-claude.py [port] [mode]
    MURMURE_CLAUDE_URL=http://127.0.0.1:18791 MURMURE_CLAUDE_KEY=essai Murmure --essai-claude

Modes : « ok » (relit la dictée : noms du contexte, « non pardon » retirés), « 401 » (clé refusée),
« 529 » (saturé), « lent » (répond après 8 s), « refus » (arrêt « refusal »). Chaque demande reçue est
décrite sur la sortie d'erreur (modèle, en-têtes, taille des consignes, début du message).
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18791
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"


def relire(message: str) -> str:
    """Imite grossièrement une relecture : la dictée brute, corrigée avec les noms du contexte."""
    brut = message.split("Transcription brute :\n", 1)[-1]
    texte = brut
    texte = re.sub(r", non pardon, à Maître Lefèvre", " à Maître Lefebvre", texte)
    texte = texte.replace("Maître Durand à Maître Lefebvre", "Maître Lefebvre")
    texte = texte.replace("Kervoa Len", "Kervoalen").replace("a été assigné ", "a été assignée ")
    texte = texte.replace("de Nanterre, de Versailles pardon,", "de Versailles")
    texte = re.sub(r"\bJe, je\b", "Je", texte)
    texte = texte.replace(", enfin non, il l'accepte", "").replace("5 000 euros, enfin 7 000 euros", "7 000 euros")
    return texte


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence le journal par défaut
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        system = body.get("system", [])
        system_text = system[0]["text"] if isinstance(system, list) and system else str(system)
        user = body["messages"][0]["content"]
        print(f"[faux-claude] {self.path} · modèle {body.get('model')} · max_tokens {body.get('max_tokens')} · "
              f"effort {body.get('output_config', {}).get('effort')} · fallbacks {body.get('fallbacks')} · "
              f"clé {self.headers.get('x-api-key')!r} · version {self.headers.get('anthropic-version')} · "
              f"beta {self.headers.get('anthropic-beta')} · consignes {len(system_text)} car. · "
              f"cache {system[0].get('cache_control') if isinstance(system, list) and system else None}",
              file=sys.stderr)
        print(f"[faux-claude] message ({len(user)} car.) : {user[:160]!r}…", file=sys.stderr)

        if MODE == "401":
            return self.erreur(401, "authentication_error", "invalid x-api-key")
        if MODE == "529":
            return self.erreur(529, "overloaded_error", "Overloaded")
        if MODE == "lent":
            time.sleep(8)

        texte = relire(user) if "Transcription brute" in user else "OK"
        stop = "refusal" if MODE == "refus" else "end_turn"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.event("message_start", {"type": "message_start", "message": {"id": "msg_faux", "usage": {
            "input_tokens": len(user) // 4, "cache_read_input_tokens": len(system_text) // 4, "cache_creation_input_tokens": 0}}})
        self.event("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
        for morceau in re.findall(r".{1,12}", texte, flags=re.S):
            self.event("content_block_delta", {"type": "content_block_delta", "index": 0,
                                               "delta": {"type": "text_delta", "text": morceau}})
        self.event("content_block_stop", {"type": "content_block_stop", "index": 0})
        self.event("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop}, "usage": {"output_tokens": len(texte) // 4}})
        self.event("message_stop", {"type": "message_stop"})

    def event(self, name, data):
        self.wfile.write(f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode())
        self.wfile.flush()

    def erreur(self, status, kind, message):
        payload = json.dumps({"type": "error", "error": {"type": kind, "message": message}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    print(f"[faux-claude] mode « {MODE} » sur http://127.0.0.1:{PORT}", file=sys.stderr)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
