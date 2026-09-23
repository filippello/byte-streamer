#!/bin/bash
# Arranca el watchdog de la run y VERIFICA que haya quedado vivo.
#
# Existe como archivo aparte a proposito. Cuando el pkill viajaba en la linea
# de comandos de SSH, el patron matcheaba el propio shell remoto (que nombra
# /root/watch-run.sh en el chmod y en el setsid) y se mataba solo antes de
# arrancar nada — sin imprimir un error, dejando el stream sin vigilancia con
# el orquestador diciendo "vigilando". El corchete tampoco alcanza: es un
# regex, y matchea igual las otras apariciones del nombre en la misma linea.
# Aca adentro la linea de comandos es este script y no contiene el patron.
PAT='/bin/bash /root/watch-run.sh'
pkill -f -x "$PAT" 2>/dev/null
sleep 1
setsid nohup /root/watch-run.sh >/root/watch-run.log 2>&1 </dev/null &
sleep 3
PID="$(pgrep -f -x "$PAT" | head -1)"
if [ -n "$PID" ]; then echo "watchdog del pod OK (pid $PID)"
else echo "WATCHDOG DEL POD NO ARRANCO"; tail -3 /root/watch-run.log 2>/dev/null; exit 1; fi
