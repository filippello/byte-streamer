#!/bin/bash
POD="${1:?falta podId}"; K=$(cat ~/.runpod/key)
curl -s -X DELETE -H "Authorization: Bearer $K" "https://rest.runpod.io/v1/pods/$POD" -w "\nHTTP %{http_code}\n"
curl -s -H "Authorization: Bearer $K" https://rest.runpod.io/v1/pods | python3 -c "
import sys,json; d=json.load(sys.stdin); print('sin pods' if not d else [p.get('id') for p in d])"
