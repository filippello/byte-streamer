#!/usr/bin/env python3
"""Prende el puente de chat SIN usar el broadcast nativo de byte.

Byte solo llama a connectChat() dentro de startTwitchStream() (el boton "Go Live
on Twitch"), asi que usando ffmpeg el chat nunca arranca. Pero el puente es un
endpoint del server y se puede disparar a mano — que es lo que hace esto.

Uso:
  chat-bridge.py twitch                 # usa el token guardado en localStorage
  chat-bridge.py pump <mint|url>        # la moneda ES la sala de chat

Twitch: bidireccional (el agente lee y ESCRIBE en el chat).
Pump:   solo entrada (pump exige firma con wallet para postear) -> contesta por voz.
El bridge es POR SESION: hay que rellamarlo en cada run nueva.
"""
import json, sys, urllib.request
from websocket import create_connection

mode = sys.argv[1] if len(sys.argv) > 1 else ""
arg = sys.argv[2] if len(sys.argv) > 2 else ""
if mode not in ("twitch", "pump"):
    print(__doc__); sys.exit(1)

tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
pages = [t for t in tabs if t["type"] == "page" and "bytearena" in t["url"]]
if not pages:
    print("no hay pestaña de bytearena abierta"); sys.exit(1)
ws = create_connection(pages[0]["webSocketDebuggerUrl"], timeout=90)

if mode == "twitch":
    js = """(async () => {
      const sid = location.pathname.split("/").pop();
      const u = localStorage.getItem("byte_twitch_username");
      const t = localStorage.getItem("byte_twitch_token");
      if (!u || !t) return "FALTA el OAuth de Twitch en localStorage (reconectar por VNC)";
      const r = await fetch(location.origin + "/api/twitch-chat/start", {
        method:"POST", headers:{"Content-Type":"application/json"}, credentials:"include",
        body: JSON.stringify({sessionId:sid, channel:u, oauthToken:"oauth:"+t, username:u})});
      return JSON.stringify({session:sid, canal:u, status:r.status, resp:(await r.text()).slice(0,200)});
    })()"""
else:
    js = """(async () => {
      const sid = location.pathname.split("/").pop();
      const r = await fetch(location.origin + "/api/pumpfun-chat/start", {
        method:"POST", headers:{"Content-Type":"application/json"}, credentials:"include",
        body: JSON.stringify({sessionId:sid, mint:%s})});
      return JSON.stringify({session:sid, status:r.status, resp:(await r.text()).slice(0,200)});
    })()""" % json.dumps(arg)

ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                    "params":{"expression":js,"returnByValue":True,"awaitPromise":True}}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1:
        print(m.get("result",{}).get("result",{}).get("value") or m); break
ws.close()
