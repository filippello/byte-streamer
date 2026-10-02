#!/usr/bin/env python3
import json, sys, urllib.request
from websocket import create_connection
cmd = sys.argv[1]; arg = " ".join(sys.argv[2:])
tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
pages = [t for t in tabs if t["type"] == "page"]
page = next((t for t in pages if "bytearena" in t["url"]), pages[0] if pages else None)
if not page: print("no page"); sys.exit(1)
ws = create_connection(page["webSocketDebuggerUrl"], timeout=90)
_id = [0]
def send(m, p=None):
    _id[0] += 1
    mio = _id[0]          # el id PROPIO: contestar un dialogo consume otro id,
    ws.send(json.dumps({"id": mio, "method": m, "params": p or {}}))
    while True:
        r = json.loads(ws.recv())
        # Navegar fuera de una arena viva dispara el beforeunload del juego y
        # Chrome abre "Leave site?". Un modal asi FRENA EL RENDERER ENTERO: todo
        # Runtime.evaluate se cuelga hasta el timeout y desde afuera parece que
        # Chrome se murio. Peor: tampoco se puede cerrar desde otra conexion,
        # porque hasta el Page.enable queda bloqueado. Hay que atenderlo ACA, en
        # el mismo socket que recibe el evento. Antes este bucle tiraba todos los
        # eventos a la basura esperando su id, asi que nadie lo contestaba.
        if r.get("method") == "Page.javascriptDialogOpening":
            _id[0] += 1
            ws.send(json.dumps({"id": _id[0], "method": "Page.handleJavaScriptDialog",
                                "params": {"accept": True}}))
            continue
        if r.get("id") == mio: return r   # y sin esto no se reconoce la respuesta
def ev(e):
    r = send("Runtime.evaluate", {"expression": e, "returnByValue": True, "awaitPromise": True})
    return r.get("result", {}).get("result", {}).get("value")
# Siempre, no solo en nav: el dialogo tambien puede abrirlo un click nuestro, y
# sin el dominio habilitado el evento no llega y el cuelgue vuelve.
send("Page.enable")
if cmd == "eval": print(json.dumps(ev(arg), ensure_ascii=False))
elif cmd == "nav":
    send("Page.enable"); send("Page.navigate", {"url": arg})
    import time; time.sleep(8); print("ahora en:", ev("location.href"))
elif cmd == "text": print(ev("document.body.innerText.slice(0,2500)"))
ws.close()
