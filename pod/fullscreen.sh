#!/bin/bash
# Pone Chrome a pantalla completa. Sin esto la barra de direcciones sale AL AIRE.
#
# Va por CDP (Browser.setWindowBounds) y NO por xdotool/F11. El pod corre Xvfb
# PELADO, sin window manager, asi que xdotool no tiene a quien pedirle que active
# la ventana: el log venia escupiendo "Your windowmanager claims not to support
# _NET_ACTIVE_WINDOW" y "xdo_activate_window reported an error", el F11 se
# mandaba al vacio y el script igual decia "fullscreen enviado". Pasaba sobre
# todo despues de cada cambio de juego del carrusel.
#
# CDP se lo pide al propio Chrome, que no necesita WM para ponerse fullscreen.
export DISPLAY=:1
python3 - <<'PY'
import json, sys, urllib.request
from websocket import create_connection

try:
    ver = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/version"))
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
except Exception as e:
    print("no pude hablar con CDP: %s" % e); sys.exit(1)

pages = [t for t in tabs if t.get("type") == "page"]
page = next((t for t in pages if "bytearena" in t.get("url", "")), pages[0] if pages else None)
if not page:
    print("no hay pagina"); sys.exit(1)

# El endpoint del BROWSER, no el de la pagina: setWindowBounds vive ahi.
ws = create_connection(ver["webSocketDebuggerUrl"], timeout=20)
_id = [0]
def send(method, params=None):
    _id[0] += 1
    mio = _id[0]
    ws.send(json.dumps({"id": mio, "method": method, "params": params or {}}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == mio:
            return r

r = send("Browser.getWindowForTarget", {"targetId": page["id"]})
win = r.get("result", {}).get("windowId")
if win is None:
    print("no encontre la ventana: %s" % r.get("error")); sys.exit(1)

# Normal primero: si ya estaba en fullscreen, volver a pedirlo no hace nada y
# un estado raro (minimized) no deja aplicar el cambio.
send("Browser.setWindowBounds", {"windowId": win, "bounds": {"windowState": "normal"}})
r = send("Browser.setWindowBounds", {"windowId": win, "bounds": {"windowState": "fullscreen"}})
if r.get("error"):
    print("no pude poner fullscreen: %s" % r["error"]); sys.exit(1)

b = send("Browser.getWindowBounds", {"windowId": win}).get("result", {}).get("bounds", {})
print("fullscreen OK — %sx%s estado=%s" % (b.get("width"), b.get("height"), b.get("windowState")))
ws.close()
PY
