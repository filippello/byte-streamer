#!/usr/bin/env python3
"""Deploya el agente a un juego desde el dashboard.

Uso: deploy-game.py "Infinite Cinema" | "Backrooms" | "Solana Gaming Event" | ...

OJO: byte permite UNA run activa. Si hay otra abierta el deploy no hace nada —
cerrarla antes con end-run.py. Y el boton hay que ubicarlo acotando al card
(subir por parentElement hasta el primer ancestro con el nombre Y <420 chars),
porque si no se agarra el DEPLOY del juego de al lado.
"""
import json, sys, time, urllib.request
from websocket import create_connection
GAME = sys.argv[1] if len(sys.argv) > 1 else "Infinite Cinema"

def ev(expr, wait=0):
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
    ps = [t for t in tabs if t["type"] == "page"]
    p = next((t for t in ps if "bytearena" in t["url"]), ps[0])
    ws = create_connection(p["webSocketDebuggerUrl"], timeout=90)
    ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                        "params":{"expression":expr,"returnByValue":True,"awaitPromise":True}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == 1:
            ws.close()
            if wait: time.sleep(wait)
            return m.get("result",{}).get("result",{}).get("value")

ev("location.href='https://app.bytearena.fun/dashboard'", wait=10)
r = ev("""(()=>{const btns=Array.from(document.querySelectorAll("button"))
  .filter(x=>/DEPLOY AGENT|ENTER EVENT|FREE SEAT/i.test(x.innerText));
  for(const b of btns){let p=b;
    for(let i=0;i<10&&p;i++){p=p.parentElement; if(!p) break;
      const t=p.innerText||"";
      if(t.includes(%s) && t.length<420){b.click(); return "click -> "+%s;}}}
  return "NO ENCONTRADO: "+%s;})()""" % (json.dumps(GAME), json.dumps(GAME), json.dumps(GAME)), wait=28)
print(r)
print("url:", ev("location.href"))
print("estado:", ev("(document.body.innerText.match(/status: [a-z]+/i)||['?'])[0]"))
