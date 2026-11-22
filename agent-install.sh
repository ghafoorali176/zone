#!/usr/bin/env bash
set -Eeuo pipefail

# Mining Fleet Agent installer (compatible with Mining Fleet Control Panel v1)
# Usage: bash mining-agent-install-v2.sh http://PANEL_IP:8443 ENROLLMENT_TOKEN

[[ ${EUID} -eq 0 ]] || { echo "ERROR: Run as root: sudo bash $0 PANEL_URL TOKEN" >&2; exit 1; }
PANEL="${1:-}"
ENROLL="${2:-}"
[[ -n "$PANEL" && -n "$ENROLL" ]] || { echo "Usage: bash $0 http://PANEL_IP:8443 ENROLLMENT_TOKEN"; exit 1; }
PANEL="${PANEL%/}"
command -v apt-get >/dev/null || { echo "ERROR: This installer supports Ubuntu/Debian only." >&2; exit 1; }

# Verify the central panel can be reached before modifying the miner.
if ! command -v curl >/dev/null 2>&1; then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl; fi
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$PANEL/" || true)"
[[ "$HTTP_CODE" =~ ^(200|302|307|401|403|404|405)$ ]] || {
  echo "ERROR: Cannot reach panel at $PANEL (HTTP=${HTTP_CODE:-no response}). Check panel URL/outbound network." >&2
  exit 1
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip curl

# Detect the config used by the live XMRig process. Never overwrite an unknown config.
CFG="$(python3 - <<'PY'
import glob, os
for f in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        raw=open(f,'rb').read().split(b'\0')
        args=[x.decode(errors='ignore') for x in raw if x]
        if not args or os.path.basename(args[0]).lower() not in ('xmrig','xmrig.exe'): continue
        for i,a in enumerate(args):
            if a.startswith('--config='):
                p=a.split('=',1)[1]
                if os.path.isfile(p): print(p); raise SystemExit
            if a in ('--config','-c') and i+1<len(args) and os.path.isfile(args[i+1]):
                print(args[i+1]); raise SystemExit
    except (OSError, ProcessLookupError): pass
for p in ('/etc/xmrig/config.json','/root/xmrig/build/config.json','/opt/xmrig/config.json','/root/.xmrig/config.json'):
    if os.path.isfile(p): print(p); break
PY
)"
[[ -n "$CFG" && -f "$CFG" ]] || {
  echo "ERROR: Could not safely locate XMRig config. No mining config was changed." >&2
  echo "Check the running command with: pgrep -a xmrig" >&2
  exit 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
cp -a "$CFG" "$CFG.backup-fleet-$STAMP"
# Merge only API settings. Preserve pool, wallet, worker, threads, algo, and all other keys.
python3 - "$CFG" <<'PY'
import json, os, sys, tempfile
p=sys.argv[1]
with open(p, encoding='utf-8') as f: data=json.load(f)
http=data.get('http')
if http is None: http={}
if not isinstance(http, dict): raise SystemExit('ERROR: config http field is not an object; refusing to overwrite it')
http=dict(http)
http.update({'enabled': True, 'host': '127.0.0.1', 'port': 18088, 'access-token': None, 'restricted': True})
data['http']=http
directory=os.path.dirname(p) or '.'
fd,tmp=tempfile.mkstemp(prefix='.xmrig-config-', suffix='.json', dir=directory)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(data,f,indent=4); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, os.stat(p).st_mode & 0o777)
    os.replace(tmp,p)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
print('Enabled XMRig API on 127.0.0.1:18088; other config keys preserved.')
PY

mkdir -p /opt/mining-fleet-agent
base64 -d >/opt/mining-fleet-agent/agent.py <<'B64_AGENT'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwppbXBvcnQgb3MsIHRpbWUsIGpzb24sIHBsYXRmb3JtLCBzdWJwcm9jZXNzLCB1cmxsaWIucmVxdWVzdCwgdXVpZApmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKUEFORUw9b3MuZW52aXJvblsiUEFORUxfVVJMIl0ucnN0cmlwKCIvIikKVE9LRU5fRklMRT1QYXRoKCIvZXRjL21pbmluZy1mbGVldC1hZ2VudC50b2tlbiIpClBDSURfRklMRT1QYXRoKCIvZXRjL21pbmluZy1mbGVldC1hZ2VudC5pZCIpClhNUklHX1VSTD0iaHR0cDovLzEyNy4wLjAuMToxODA4OC8yL3N1bW1hcnkiCgpkZWYgcmVxdWVzdCh1cmwsIGRhdGE9Tm9uZSwgdG9rZW49Tm9uZSwgbWV0aG9kPU5vbmUpOgogICAgcmF3PU5vbmUgaWYgZGF0YSBpcyBOb25lIGVsc2UganNvbi5kdW1wcyhkYXRhKS5lbmNvZGUoKQogICAgaGVhZGVycz17IkNvbnRlbnQtVHlwZSI6ImFwcGxpY2F0aW9uL2pzb24ifQogICAgaWYgdG9rZW46IGhlYWRlcnNbIkF1dGhvcml6YXRpb24iXT0iQmVhcmVyICIrdG9rZW4KICAgIHJlcT11cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCxkYXRhPXJhdyxoZWFkZXJzPWhlYWRlcnMsbWV0aG9kPW1ldGhvZCkKICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3BlbihyZXEsdGltZW91dD01KSBhcyByOgogICAgICAgIGJvZHk9ci5yZWFkKCkKICAgICAgICByZXR1cm4ganNvbi5sb2Fkcyhib2R5KSBpZiBib2R5IGVsc2Uge30KCmRlZiBydW4oY21kLCB0aW1lb3V0PTE1KToKICAgIHRyeToKICAgICAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oY21kLHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsc3RkZXJyPXN1YnByb2Nlc3MuU1RET1VULHRleHQ9VHJ1ZSx0aW1lb3V0PXRpbWVvdXQpLnN0ZG91dC5zdHJpcCgpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgcmV0dXJuIHN0cihlKQoKZGVmIHJlYWRfeG1yaWcoKToKICAgIHRyeToKICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4oWE1SSUdfVVJMLHRpbWVvdXQ9MikgYXMgcjogZD1qc29uLmxvYWRzKHIucmVhZCgpKQogICAgICAgIGhzPWQuZ2V0KCJoYXNocmF0ZSIse30pLmdldCgidG90YWwiLFswLDAsMF0pCiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UoaHMsbGlzdCk6IGhzPVswLDAsMF0KICAgICAgICByZXN1bHRzPWQuZ2V0KCJyZXN1bHRzIix7fSkKICAgICAgICBnb29kPWludChyZXN1bHRzLmdldCgic2hhcmVzX2dvb2QiLDApIG9yIDApCiAgICAgICAgdG90YWw9aW50KHJlc3VsdHMuZ2V0KCJzaGFyZXNfdG90YWwiLGdvb2QpIG9yIGdvb2QpCiAgICAgICAgY29ubj1kLmdldCgiY29ubmVjdGlvbiIse30pCiAgICAgICAgcmV0dXJuIHsiaGFzaHJhdGUiOmhzWzFdIGlmIGxlbihocyk+MSBlbHNlIChoc1swXSBpZiBocyBlbHNlIDApLAogICAgICAgICAgICAgICAgImhhc2hyYXRlMTAiOmhzWzBdIGlmIGxlbihocyk+MCBlbHNlIDAsCiAgICAgICAgICAgICAgICAiaGFzaHJhdGU2MCI6aHNbMV0gaWYgbGVuKGhzKT4xIGVsc2UgMCwKICAgICAgICAgICAgICAgICJoYXNocmF0ZTE1bSI6aHNbMl0gaWYgbGVuKGhzKT4yIGVsc2UgMCwKICAgICAgICAgICAgICAgICJhY2NlcHRlZCI6Z29vZCwicmVqZWN0ZWQiOm1heCgwLHRvdGFsLWdvb2QpLAogICAgICAgICAgICAgICAgIm1pbmluZyI6Ym9vbChjb25uLmdldCgidXB0aW1lIiwwKSBvciAoaHMgYW5kIG1heChocyk+MCkpfQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4geyJoYXNocmF0ZSI6MCwiaGFzaHJhdGUxMCI6MCwiaGFzaHJhdGU2MCI6MCwiaGFzaHJhdGUxNW0iOjAsCiAgICAgICAgICAgICAgICAiYWNjZXB0ZWQiOjAsInJlamVjdGVkIjowLCJtaW5pbmciOkZhbHNlfQoKZGVmIGNvbGxlY3Rfc3RhdHMoKToKICAgIHM9cmVhZF94bXJpZygpCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IHBzdXRpbAogICAgICAgIHNbImNwdSJdPXBzdXRpbC5jcHVfcGVyY2VudChpbnRlcnZhbD1Ob25lKQogICAgICAgIHZtPXBzdXRpbC52aXJ0dWFsX21lbW9yeSgpCiAgICAgICAgc1sicmFtX3VzZWQiXT1yb3VuZCh2bS51c2VkLzEwMjQqKjMsMSkKICAgICAgICBzWyJyYW1fdG90YWwiXT1yb3VuZCh2bS50b3RhbC8xMDI0KiozLDEpCiAgICAgICAgc1sidXB0aW1lIl09c3RyKGludCh0aW1lLnRpbWUoKS1wc3V0aWwuYm9vdF90aW1lKCkpKSsiIHNlYyIKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcy51cGRhdGUoeyJjcHUiOjAsInJhbV91c2VkIjowLCJyYW1fdG90YWwiOjAsInVwdGltZSI6InVua25vd24ifSkKICAgIHJldHVybiBzCgpkZWYgbWFpbigpOgogICAgcGNpZD1QQ0lEX0ZJTEUucmVhZF90ZXh0KCkuc3RyaXAoKSBpZiBQQ0lEX0ZJTEUuZXhpc3RzKCkgZWxzZSBzdHIodXVpZC51dWlkNCgpKQogICAgUENJRF9GSUxFLndyaXRlX3RleHQocGNpZCkKICAgIHRva2VuPVRPS0VOX0ZJTEUucmVhZF90ZXh0KCkuc3RyaXAoKSBpZiBUT0tFTl9GSUxFLmV4aXN0cygpIGVsc2UgIiIKICAgIGlmIG5vdCB0b2tlbjoKICAgICAgICBkPXJlcXVlc3QoUEFORUwrIi9hZ2VudC9yZWdpc3RlciIseyJlbnJvbGxfdG9rZW4iOm9zLmVudmlyb25bIkVOUk9MTF9UT0tFTiJdLAogICAgICAgICAgICAgICAgICAgImlkIjpwY2lkLCJuYW1lIjpwbGF0Zm9ybS5ub2RlKCl9LG1ldGhvZD0iUE9TVCIpCiAgICAgICAgdG9rZW49ZFsidG9rZW4iXQogICAgICAgIFRPS0VOX0ZJTEUud3JpdGVfdGV4dCh0b2tlbik7IFRPS0VOX0ZJTEUuY2htb2QoMG82MDApCiAgICBwcmludCgiTWluaW5nIGZsZWV0IGFnZW50IHN0YXJ0ZWQgZm9yIixwY2lkLGZsdXNoPVRydWUpCiAgICBsYXN0X2xvZ3M9W10KICAgIHdoaWxlIFRydWU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzdGF0cz1jb2xsZWN0X3N0YXRzKCkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgY21kX2RhdGE9cmVxdWVzdChQQU5FTCsiL2FnZW50L2NvbW1hbmQiLHRva2VuPXRva2VuLG1ldGhvZD0iR0VUIikKICAgICAgICAgICAgICAgIGNtZD1jbWRfZGF0YS5nZXQoImNvbW1hbmQiKQogICAgICAgICAgICAgICAgaWYgY21kOgogICAgICAgICAgICAgICAgICAgIG1hcHBpbmc9eyJzdGFydCI6WyJzeXN0ZW1jdGwiLCJzdGFydCIsInhtcmlnIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgInN0b3AiOlsic3lzdGVtY3RsIiwic3RvcCIsInhtcmlnIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgInJlc3RhcnQiOlsic3lzdGVtY3RsIiwicmVzdGFydCIsInhtcmlnIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgInJlYm9vdCI6WyJzeXN0ZW1jdGwiLCJyZWJvb3QiXX0KICAgICAgICAgICAgICAgICAgICBpZiBjbWQgaW4gbWFwcGluZzoKICAgICAgICAgICAgICAgICAgICAgICAgcmVzdWx0PXJ1bihtYXBwaW5nW2NtZF0pCiAgICAgICAgICAgICAgICAgICAgICAgIHJlcXVlc3QoUEFORUwrIi9hZ2VudC9jb21tYW5kLXJlc3VsdCIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgeyJpZCI6Y21kX2RhdGEuZ2V0KCJpZCIpLCJjb21tYW5kIjpjbWQsInN0YXR1cyI6InNlbnQiLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAicmVzdWx0IjpyZXN1bHQgb3IgImNvbW1hbmQgZXhlY3V0ZWQifSx0b2tlbixtZXRob2Q9IlBPU1QiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgICAgICBwcmludCgiQ29tbWFuZCBjaGFubmVsOiIsZSxmbHVzaD1UcnVlKQogICAgICAgICAgICBuZXdfbG9ncz1bXQogICAgICAgICAgICByYXc9cnVuKFsiam91cm5hbGN0bCIsIi11IiwieG1yaWciLCItbiIsIjUiLCItLW5vLXBhZ2VyIiwiLW8iLCJjYXQiXSkKICAgICAgICAgICAgbGluZXM9W3guc3RyaXAoKSBmb3IgeCBpbiByYXcuc3BsaXRsaW5lcygpIGlmIHguc3RyaXAoKV0KICAgICAgICAgICAgZm9yIGxpbmUgaW4gbGluZXM6CiAgICAgICAgICAgICAgICBpZiBsaW5lIG5vdCBpbiBsYXN0X2xvZ3M6IG5ld19sb2dzLmFwcGVuZCh7ImxldmVsIjoiWE1SSUciLCJtZXNzYWdlIjpsaW5lWy0yODA6XX0pCiAgICAgICAgICAgIGxhc3RfbG9ncz1saW5lc1stNTpdCiAgICAgICAgICAgIHJlcXVlc3QoUEFORUwrIi9hZ2VudC9oZWFydGJlYXQiLHsic3RhdHMiOnN0YXRzLCJsb2dzIjpuZXdfbG9nc1stNTpdfSx0b2tlbixtZXRob2Q9IlBPU1QiKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgcHJpbnQoIlBhbmVsIGNvbm5lY3Rpb246IixlLGZsdXNoPVRydWUpCiAgICAgICAgdGltZS5zbGVlcCg4KQoKaWYgX19uYW1lX189PSJfX21haW5fXyI6IG1haW4oKQo=
B64_AGENT
chmod 755 /opt/mining-fleet-agent/agent.py
python3 -m venv /opt/mining-fleet-agent/venv
/opt/mining-fleet-agent/venv/bin/pip install --disable-pip-version-check --upgrade psutil

cat >/etc/mining-fleet-agent.env <<EOF
PANEL_URL=$PANEL
ENROLL_TOKEN=$ENROLL
EOF
chmod 600 /etc/mining-fleet-agent.env

# Restart XMRig only if its service is installed and currently active.
if systemctl list-unit-files xmrig.service --no-legend 2>/dev/null | grep -q 'xmrig.service'; then
  if systemctl is-active --quiet xmrig.service; then systemctl restart xmrig.service; fi
fi

# The bundled agent persists its node ID/token in /etc. ProtectSystem=full caused
# /etc to be read-only on the earlier installer; disable that sandbox restriction.
cat >/etc/systemd/system/mining-fleet-agent.service <<'UNIT'
[Unit]
Description=Mining Fleet Monitoring Agent
After=network-online.target xmrig.service
Wants=network-online.target
[Service]
Type=simple
User=root
EnvironmentFile=/etc/mining-fleet-agent.env
ExecStart=/opt/mining-fleet-agent/venv/bin/python /opt/mining-fleet-agent/agent.py
Restart=always
RestartSec=5
Nice=10
CPUWeight=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=off
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable mining-fleet-agent.service
systemctl restart mining-fleet-agent.service
sleep 2
if ! systemctl is-active --quiet mining-fleet-agent.service; then
  echo "ERROR: Agent failed to stay active. Recent logs:" >&2
  journalctl -u mining-fleet-agent -n 40 --no-pager >&2 || true
  exit 1
fi

if curl -fsS --max-time 4 http://127.0.0.1:18088/2/summary >/dev/null; then
  echo "XMRig local API: OK (127.0.0.1:18088)"
else
  echo "WARNING: Agent is active, but XMRig API did not answer on 127.0.0.1:18088." >&2
  echo "Inspect XMRig service logs/config; miner pool/wallet/thread settings were not changed." >&2
fi

echo
echo "SUCCESS: Mining Fleet Agent installed; systemd service is active."
echo "Node ID: $(cat /etc/mining-fleet-agent.id 2>/dev/null || echo 'created on first start')"
echo "Panel: $PANEL"
echo "Logs: journalctl -u mining-fleet-agent -n 30 --no-pager"
echo "Agent will auto-start after reboot."
