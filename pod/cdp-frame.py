#!/usr/bin/env python3
"""Evalua JS dentro de un TARGET puntual (iframe incluido), no solo la pestaña.

cdp.py siempre elige la pagina de bytearena. Cuando el juego vive en un iframe
cross-origin (Infinite Cinema embebe infinitecinema.vercel.app) ese iframe es un
target CDP aparte y hay que hablarle directo.

Uso:  cdp-frame.py <substring-de-url> '<expresion>'
Ej:   cdp-frame.py infinitecinema 'document.querySelector("video")?.muted'
"""
import json, sys, urllib.request
from websocket import create_connection

if len(sys.argv) < 3:
    print(__doc__); sys.exit(1)
needle, expr = sys.argv[1], " ".join(sys.argv[2:])

targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
hit = next((t for t in targets if needle in t.get("url", "") and t.get("webSocketDebuggerUrl")), None)
if not hit:
    print(f"no hay target con '{needle}'. Hay: " +
          ", ".join(f"{t['type']}:{t.get('url','')[:50]}" for t in targets))
    sys.exit(1)

ws = create_connection(hit["webSocketDebuggerUrl"], timeout=90)
ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                    "params": {"expression": expr, "returnByValue": True, "awaitPromise": True}}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1:
        r = m.get("result", {})
        if r.get("exceptionDetails"):
            print("ERROR:", r["exceptionDetails"].get("text"),
                  (r["exceptionDetails"].get("exception") or {}).get("description", ""))
        else:
            print(json.dumps(r.get("result", {}).get("value"), ensure_ascii=False))
        break
ws.close()
