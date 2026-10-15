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
# El label del boton cambio: era "Authorize Byte" y el 2026-10-13 paso a ser
# solo "Authorize" (al lado hay un "Accept"). El matcher viejo no lo encontraba
# y el login quedaba a medias. Se aceptan las tres variantes, y se excluyen
# explicitamente "Reject" y "Cancel", que estan en la misma pantalla.
print("  ", ev("""(()=>{const b=Array.from(document.querySelectorAll("button,a"))
        .filter(x=>{const t=(x.innerText||"").trim();
          return /^(authorize|accept)$|authorize byte/i.test(t) && !/reject|cancel/i.test(t);});
        if(!b.length) return "no hay boton de autorizar";
        b[0].click(); return "click en " + JSON.stringify(b[0].innerText.trim());})()""", wait=12))

# El chequeo viejo buscaba "log out" en la pagina del callback, que todavia no
# habia cargado el dashboard: daba SI con la sesion sin establecer. Ahora se va
# al dashboard y se comprueba lo CONTRARIO —que no haya boton de "log in"— que
# es la señal que de verdad distingue.
ev("location.href='https://app.bytearena.fun/dashboard'", wait=12)
print("3) logueado:", ev("""(()=>{const t=document.body.innerText;
      return (!/\\blog in\\b/i.test(t) && /log out/i.test(t)) ? 'SI' : 'NO';})()"""))
