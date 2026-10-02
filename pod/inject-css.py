#!/usr/bin/env python3
"""Inyecta el CSS de /root/.cinema-css en la pagina de la arena.

Para que existe: byte no expone ninguna perilla para el tamaño del iframe del
juego (byte.present solo maneja el avatar y la escena). Lo unico que queda es
CSS desde la pagina padre, que SI se puede tocar porque es same-origin — el
contenido de adentro del iframe no, eso es otro origen.

Se vuelve a aplicar despues de cada redeploy del modo keep: una inyeccion en
runtime no sobrevive a la navegacion, asi que sin esto el zoom se perdia en la
primera corrida encadenada y nadie se enteraba hasta mirar el stream.

Es idempotente: reemplaza el <style> si ya estaba.
"""
import json, sys, urllib.request
from websocket import create_connection

CONF = "/root/.cinema-css"
try:
    css = open(CONF).read().strip()
except OSError:
    print("sin %s, nada que inyectar" % CONF); sys.exit(0)
if not css:
    print("%s vacio, nada que inyectar" % CONF); sys.exit(0)

tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
pages = [t for t in tabs if t["type"] == "page"]
page = next((t for t in pages if "bytearena" in t["url"]), pages[0] if pages else None)
if not page:
    print("no hay pagina"); sys.exit(1)

expr = """(()=>{const id="byte-remote-css";let e=document.getElementById(id);
if(!e){e=document.createElement("style");e.id=id;document.head.appendChild(e);}
e.textContent=%s;return "css aplicado ("+e.textContent.length+" chars)";})()""" % json.dumps(css)

ws = create_connection(page["webSocketDebuggerUrl"], timeout=30)
_id = [0]
def send(method, params=None):
    _id[0] += 1
    mio = _id[0]
    ws.send(json.dumps({"id": mio, "method": method, "params": params or {}}))
    while True:
        r = json.loads(ws.recv())
        # Mismo motivo que en cdp.py: un dialogo abierto congela el renderer.
        if r.get("method") == "Page.javascriptDialogOpening":
            _id[0] += 1
            ws.send(json.dumps({"id": _id[0], "method": "Page.handleJavaScriptDialog",
                                "params": {"accept": True}}))
            continue
        if r.get("id") == mio:
            return r

send("Page.enable")
r = send("Runtime.evaluate", {"expression": expr, "returnByValue": True})
print(r.get("result", {}).get("result", {}).get("value") or r.get("error", {}).get("message", "?"))
ws.close()
