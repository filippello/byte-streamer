#!/usr/bin/env python3
"""Rehace el handshake de Notlogin -> byte.

La cookie de sesion de BYTE es una *session cookie*: vive en memoria y muere al
cerrar Chrome, asi que NO viaja en el perfil copiado. La de notlogin.com si
(es persistente, vence 2026-09-20), y con esa alcanza: no hace falta magic link.
"""
import json, time, urllib.request
from websocket import create_connection

def page():
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
    ps = [t for t in tabs if t["type"] == "page"]
    return next((t for t in ps if "bytearena" in t["url"] or "notlogin" in t["url"]), ps[0])

def ev(expr, wait=0):
    ws = create_connection(page()["webSocketDebuggerUrl"], timeout=90)
    ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                        "params":{"expression":expr,"returnByValue":True,"awaitPromise":True}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == 1:
            ws.close()
            if wait: time.sleep(wait)
            return m.get("result",{}).get("result",{}).get("value")

print("1) yendo al handshake…")
ev("location.href='https://app.bytearena.fun/auth/notlogin/start?next=%2F'", wait=10)
txt = ev("(document.body.innerText.match(/Signed in as[^\\n]{0,40}/i)||['(no reconocido)'])[0]")
print("   notlogin dice:", txt)
print("2) autorizando…")
print("  ", ev("""(()=>{const b=Array.from(document.querySelectorAll("button,a"))
        .find(x=>/authorize byte/i.test(x.innerText)); if(!b) return "no hay boton Authorize";
        b.click(); return "click Authorize Byte";})()""", wait=12))
print("3) logueado:", ev("/log out|PROFILE/i.test(document.body.innerText)?'SI':'NO'"))
