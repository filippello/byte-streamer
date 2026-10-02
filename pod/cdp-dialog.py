#!/usr/bin/env python3
"""Cierra un dialogo modal de JS que haya quedado bloqueando la pagina.

Para que existe: al navegar fuera de una arena viva, byte dispara el
beforeunload del juego y Chrome muestra "Leave site? Changes you made may not be
saved.". Un modal de esos FRENA EL RENDERER ENTERO: todo Runtime.evaluate queda
colgado hasta el timeout, y desde afuera parece que Chrome se murio o que el pod
no da abasto. No es ninguna de las dos.

Uso: cdp-dialog.py [accept|dismiss]   (default: accept = "Leave")
"""
import json, sys, urllib.request
from websocket import create_connection

accept = (sys.argv[1] if len(sys.argv) > 1 else "accept") == "accept"
tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
pages = [t for t in tabs if t["type"] == "page"]
page = next((t for t in pages if "bytearena" in t["url"]), pages[0] if pages else None)
if not page:
    print("no hay pagina"); sys.exit(1)

ws = create_connection(page["webSocketDebuggerUrl"], timeout=20)
_id = [0]
def send(method, params=None):
    _id[0] += 1
    ws.send(json.dumps({"id": _id[0], "method": method, "params": params or {}}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == _id[0]:
            return r

# Page.enable primero: sin el dominio habilitado el handle no aplica.
send("Page.enable")
r = send("Page.handleJavaScriptDialog", {"accept": accept})
err = r.get("error", {}).get("message", "")
if err:
    print("no habia dialogo abierto" if "No dialog" in err else "error: " + err)
else:
    print("dialogo cerrado con " + ("Leave/OK" if accept else "Cancel"))
ws.close()
