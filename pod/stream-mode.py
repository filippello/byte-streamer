#!/usr/bin/env python3
"""Modo transmision: agranda el juego y esconde la UI de operador."""
import json, urllib.request
from websocket import create_connection
DOCK_W = 300
JS = r"""
(() => {
  const ID='byte-stream-mode', DOCK=__DOCK__;
  const apply=()=>{
    let st=document.getElementById(ID);
    if(!st){st=document.createElement('style');st.id=ID;document.documentElement.appendChild(st);}
    st.textContent=`
      header.site-topbar, header.byte-header,
      .hud-actions-section, .hud-actions,
      .hud-right-section, .hud-info-panel, .game-hud,
      [class*="feedback" i], [id*="feedback" i] { display:none !important; }
      html, body { overflow:hidden !important; margin:0 !important; }
      .arena-shell, .body-grid { display:block !important; height:100vh !important; padding:0 !important; margin:0 !important; }
      .main-col { position:fixed !important; left:0 !important; top:0 !important;
        width:calc(100vw - ${DOCK}px) !important; height:100vh !important;
        padding:0 !important; margin:0 !important; z-index:10 !important; }
      .player-wrap, .player-wrap.cab-bezel { width:100% !important; height:100% !important;
        margin:0 !important; padding:0 !important; border-radius:0 !important; }
      .panel.game-panel { width:100% !important; height:100% !important; margin:0 !important; border-radius:0 !important; }
      .game-iframe { width:100% !important; height:100% !important; border:0 !important; }
      .avatar-cell, .avatar-cell.stage-scene { position:fixed !important; left:18px !important;
        bottom:18px !important; width:330px !important; height:330px !important;
        z-index:60 !important; pointer-events:none !important;
        border-radius:50% !important; overflow:hidden !important;
        border:3px solid rgba(140,150,255,.55) !important;
        box-shadow:0 0 26px rgba(90,110,255,.45) !important; }
      .avatar-cell .panel { background:transparent !important; border:0 !important; box-shadow:none !important; height:100% !important; }
      .avatar-cell canvas { transform:scale(1.35) translateY(6%) !important; transform-origin:center center !important; }
      .dock { position:fixed !important; right:0 !important; top:0 !important;
        width:${DOCK}px !important; height:100vh !important; z-index:50 !important; }
      .dock-body, .dock-pane { height:calc(100vh - 44px) !important; }`;
    const RE=/full body|^\s*scene\s*$|^\s*voice\s*$|^\s*1\.\d/i;
    document.querySelectorAll('button').forEach(b=>{
      const t=(b.innerText||'').trim();
      if(t.length<14 && RE.test(t)){
        const box=b.closest('div');
        if(box && box.offsetWidth<340) box.style.setProperty('display','none','important');
        else b.style.setProperty('display','none','important');
      }});
  };
  apply();
  if(!window.__byteStreamObs){window.__byteStreamObs=new MutationObserver(()=>apply());
    window.__byteStreamObs.observe(document.body,{childList:true,subtree:true});}
  const f=document.querySelector('.game-iframe');
  return 'ok — iframe: '+(f?Math.round(f.getBoundingClientRect().width)+'x'+Math.round(f.getBoundingClientRect().height):'no hay');
})()
""".replace("__DOCK__", str(DOCK_W))
tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
pages = [t for t in tabs if t["type"] == "page"]
page = next((t for t in pages if "bytearena" in t["url"]), pages[0])
ws = create_connection(page["webSocketDebuggerUrl"], timeout=90)
ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{"expression":JS,"returnByValue":True}}))
while True:
    m = json.loads(ws.recv())
    if m.get("id") == 1:
        print(m.get("result",{}).get("result",{}).get("value") or m); break
ws.close()
