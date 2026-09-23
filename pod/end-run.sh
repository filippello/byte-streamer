#!/bin/bash
# Cierra la run activa. Byte permite UNA sola, asi que sin esto el proximo
# deploy no hace nada. El boton "END RUN" dispara un confirm() NATIVO que
# bloquea CDP -> se destraba con xdotool sobre el OK.
export DISPLAY=:1
python3 /opt/streamer/cdp.py nav https://app.bytearena.fun/dashboard >/dev/null 2>&1
sleep 8
python3 /opt/streamer/cdp.py eval '(()=>{const b=Array.from(document.querySelectorAll("button")).find(x=>/END RUN|DISMISS/i.test(x.innerText)); if(!b) return "no hay run abierta"; b.click(); return "END RUN clickeado";})()' 2>/dev/null
sleep 3
# OK del confirm nativo (coords del dialogo en 1920x1080)
xdotool mousemove 1121 264 click 1
sleep 8
python3 /opt/streamer/cdp.py eval '(()=>{const s=(document.body.innerText.match(/resume session[\s\S]{0,40}/i)||["(ninguna)"])[0]; return s.replace(/\n/g," | ");})()' 2>/dev/null
