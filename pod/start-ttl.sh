#!/bin/bash
# Arranca ttl.sh detachado. Existe como archivo aparte por la misma razon que
# start-watchdog.sh: si el pkill viaja en la linea de comandos del ssh, el
# patron matchea la PROPIA shell del ssh y el proceso se mata a si mismo.
PAT='/bin/bash /root/ttl.sh'
pkill -f -x "$PAT" 2>/dev/null
sleep 1
setsid nohup /root/ttl.sh >/root/ttl.boot.log 2>&1 </dev/null &
sleep 3
PID="$(pgrep -f -x "$PAT" | head -1)"
if [ -n "$PID" ]; then
  . /root/.ttl 2>/dev/null
  echo "TTL del pod OK (pid $PID) — vence $(date -Is -d @"${DEADLINE:-0}" 2>/dev/null)"
else
  echo "EL TTL DEL POD NO ARRANCO"; tail -3 /root/ttl.boot.log 2>/dev/null; exit 1
fi
