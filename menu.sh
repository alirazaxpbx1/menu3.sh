#!/bin/bash
# ==============================================================================
# ALIRAZA SSH Management Panel - one-shot installer (built on ARTRICKS menu.sh)
# Created by ALIRAZA | Support: https://t.me/ar_tricks
# v2: fixed custom Dropbear build, IPv6-safe nginx, install self-check
# ==============================================================================
G='\033[1;92m';R='\033[1;31m';Y='\033[1;93m';N='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${R}Run as root: sudo -i${N}" && exit 1
command -v apt-get >/dev/null || { echo -e "${R}Only Debian/Ubuntu (apt) is supported${N}"; exit 1; }
echo -e "${G}=== ALIRAZA SSH Panel Installer ===${N}"
read -rp "Domain (A record must point to this VPS): " DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo -e "${R}Invalid domain${N}"; exit 1; }
read -rp "Panel port [2083]: " PP; PP=${PP:-2083}
read -rp "SSH port [8443]: " SP; SP=${SP:-8443}
[[ "$PP" =~ ^[0-9]+$ && "$SP" =~ ^[0-9]+$ && "$PP" != "$SP" ]] || { echo -e "${R}Invalid ports${N}"; exit 1; }
for _p in $PP $SP; do
  case $_p in 22|80|443|109|447|2082|12026) echo -e "${R}Port $_p is reserved, choose another${N}"; exit 1;; esac
  [[ $_p -ge 1 && $_p -le 65535 ]] || { echo -e "${R}Invalid port $_p${N}"; exit 1; }
done
read -rp "Panel username [admin]: " AU; AU=${AU:-admin}
read -rsp "Panel password (blank = random): " AP; echo
[[ -z "$AP" ]] && AP=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
export DEBIAN_FRONTEND=noninteractive
echo -e "${Y}[1/6] Installing packages...${N}"
(apt-get update -y || apt-get update -y) && apt-get install -y curl wget jq openssl nginx dropbear certbot python3 python3-venv python3-pip python3-dev lsof iptables net-tools psmisc build-essential zlib1g-dev bzip2 ca-certificates logrotate || { echo -e "${R}Package install failed - check internet/apt and re-run${N}"; exit 1; }
mkdir -p /etc/artricks/users /etc/artricks/ssl /opt/aliraza-panel
# ---- AliRaza banner (always shown on login; old Ubuntu/Debian issue.net is backed up) ----
if ! grep -qi 'aliraza' /etc/issue.net 2>/dev/null; then
[[ -s /etc/issue.net ]] && cp -n /etc/issue.net /etc/issue.net.orig
cat > /etc/issue.net <<'BN'
<font color="green">==========================================</font><br>
<font color="yellow"><b>WELCOME TO ALIRAZA VIP VPN</b></font><br>
<font color="cyan"><b>SSH 2.0 | AliRaza-server | By ALIRAZA</b></font><br>
<font color="red"><b>- NO TORRENT / NO MULTILOGIN</b></font><br>
<font color="green">==========================================</font><br>
BN
fi
# ---- OpenSSH tuning (stability + speed) ----
sed -i 's/#Banner none/Banner \/etc\/issue.net/g' /etc/ssh/sshd_config 2>/dev/null
if [[ -f /etc/ssh/sshd_config ]]; then
SSHD_TUNE='# ALIRAZA tuning
Banner /etc/issue.net
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
UseDNS no
GSSAPIAuthentication no
Compression no
LoginGraceTime 30
MaxStartups 100:30:200
MaxSessions 100'
if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config; then
  printf '%s\n' "$SSHD_TUNE" > /etc/ssh/sshd_config.d/00-aliraza.conf; SSHD_MODE=dropin
else
  cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.aliraza.bak
  grep -q 'ALIRAZA tuning' /etc/ssh/sshd_config || printf '\n%s\n' "$SSHD_TUNE" >> /etc/ssh/sshd_config; SSHD_MODE=inline
fi
if command -v sshd >/dev/null && ! sshd -t 2>/dev/null; then
  echo -e "${R}sshd config test failed - reverting SSH tuning${N}"
  rm -f /etc/ssh/sshd_config.d/00-aliraza.conf
  [[ -f /etc/ssh/sshd_config.aliraza.bak ]] && cp /etc/ssh/sshd_config.aliraza.bak /etc/ssh/sshd_config
fi
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

# ---- Build Dropbear with custom identification: SSH-2.0-AliRaza-server ----
echo -e "${Y}[1b/6] Building AliRaza-server SSH (Dropbear)...${N}"
build_dropbear() {
  local IDENT="SSH-2.0-AliRaza-server" W=/tmp/aliraza-dropbear LOG=/var/log/aliraza-dropbear-build.log v ok=0
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || return 1
  for v in 2025.88 2024.86 2022.83; do
    wget -q -T 25 -O db.tar.bz2 "https://matt.ucc.asn.au/dropbear/releases/dropbear-$v.tar.bz2" \
    || wget -q -T 25 -O db.tar.bz2 "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_$v.tar.gz" || continue
    rm -rf src; mkdir src; tar -xf db.tar.bz2 -C src --strip-components=1 2>/dev/null || tar -xzf db.tar.bz2 -C src --strip-components=1 2>/dev/null || continue
    [[ -f src/configure ]] && ok=1 && break
  done
  [[ $ok -eq 1 ]] || { echo "download failed"; return 1; }
  cd src || return 1
  # Dropbear >= 2025.87 keeps its headers in src/, older releases in the top folder: locate them
  local HD; HD=$(dirname "$(find . -name sysoptions.h 2>/dev/null | head -1)")
  [[ -f "$HD/sysoptions.h" ]] || { echo "sysoptions.h not found"; return 1; }
  printf '#define DROPBEAR_SMALL_CODE 0\n' > localoptions.h
  # force the custom identification directly in sysoptions.h (whitespace tolerant), then verify
  sed -i -E "s|^[[:space:]]*#[[:space:]]*define[[:space:]]+LOCAL_IDENT[[:space:]].*|#define LOCAL_IDENT \"$IDENT\"|" "$HD/sysoptions.h"
  grep -q "LOCAL_IDENT \"$IDENT\"" "$HD/sysoptions.h" || { echo "ident patch failed: $(grep -n LOCAL_IDENT "$HD/sysoptions.h" | head -2)"; return 1; }
  sed -i 's|^#define DROPBEAR_SMALL_CODE .*|#define DROPBEAR_SMALL_CODE 0|; s|^#define MAX_UNAUTH_CLIENTS .*|#define MAX_UNAUTH_CLIENTS 100|' "$HD/default_options.h" "$HD/options.h" 2>/dev/null
  # many users behind one mobile/CGNAT IP: do not cap unauthenticated connections per IP at 5
  sed -i 's|^#define MAX_UNAUTH_PER_IP .*|#define MAX_UNAUTH_PER_IP 100|' "$HD/default_options.h" 2>/dev/null
  # never force a re-key (every 1h / 1GB): some mobile SSH clients freeze or drop during re-key
  sed -i 's|^#define KEX_REKEY_TIMEOUT .*|#define KEX_REKEY_TIMEOUT (3600*24*30)|; s|^#define KEX_REKEY_DATA .*|#define KEX_REKEY_DATA 4294967295U|' "$HD/sysoptions.h" 2>/dev/null
  : > "$LOG"
  # no utmp/wtmp/lastlog writes (faster logins, no ever-growing wtmp); -O3 build; bundled crypto
  ./configure --prefix=/usr/local --enable-bundled-libtom --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx --disable-loginfunc CFLAGS="-O3 -pipe -fomit-frame-pointer" >>"$LOG" 2>&1 || { echo "configure failed (see $LOG)"; return 1; }
  make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" >>"$LOG" 2>&1 || { echo "compile failed (see $LOG)"; return 1; }
  grep -aq "$IDENT" dropbear || { echo "ident check failed"; return 1; }
  # smoke test: the new binary must start and announce the custom identification before it is installed
  ./dropbearkey -t ed25519 -f "$W/test_key" >/dev/null 2>&1 || { echo "keygen failed"; return 1; }
  ./dropbear -F -E -r "$W/test_key" -p 127.0.0.1:22999 >/dev/null 2>&1 &
  local DP=$! BL
  sleep 1
  BL=$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22999; head -n1 <&3' 2>/dev/null | tr -d '\r')
  kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
  [[ "$BL" == "$IDENT" ]] || { echo "smoke test failed (got: ${BL:-nothing})"; return 1; }
  install -m 755 dropbear /usr/local/sbin/dropbear
}
if ( build_dropbear ); then
  echo -e "${G}Dropbear built: SSH-2.0-AliRaza-server${N}"
else
  echo -e "${R}Custom Dropbear build failed - falling back to stock Dropbear (name stays 'dropbear'). Log: /var/log/aliraza-dropbear-build.log${N}"
  rm -f /usr/local/sbin/dropbear
fi
cd /root 2>/dev/null || cd /
# nginx: more connections (safe - reverted if nginx -t fails)
if [[ -f /etc/nginx/nginx.conf ]]; then
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.aliraza.bak
  grep -q worker_rlimit_nofile /etc/nginx/nginx.conf || sed -i '1i worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
  sed -i 's/worker_connections [0-9]*;/worker_connections 8192;/' /etc/nginx/nginx.conf
  nginx -t >/dev/null 2>&1 || cp /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf
fi
# nginx http-level tuning (reverted automatically if nginx -t fails)
cat > /etc/nginx/conf.d/00-aliraza-tune.conf <<'NT'
tcp_nodelay on;
tcp_nopush on;
reset_timedout_connection on;
keepalive_timeout 120s;
keepalive_requests 10000;
server_tokens off;
ssl_session_cache shared:SSL:20m;
ssl_session_timeout 1d;
NT
nginx -t >/dev/null 2>&1 || rm -f /etc/nginx/conf.d/00-aliraza-tune.conf
if [[ -f /etc/nginx/nginx.conf ]] && ! grep -Eq '^\s*multi_accept on' /etc/nginx/nginx.conf; then
  sed -i '0,/worker_connections 8192;/s//worker_connections 8192;\n    multi_accept on;\n    use epoll;/' /etc/nginx/nginx.conf
  nginx -t >/dev/null 2>&1 || cp /etc/nginx/nginx.conf.aliraza.bak /etc/nginx/nginx.conf
fi
# keep logs from filling the disk
cat > /etc/logrotate.d/aliraza <<'LR'
/var/log/ws-proxy.log {
    weekly
    rotate 2
    size 20M
    missingok
    notifempty
    copytruncate
    compress
}
LR
mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\nSystemMaxUse=200M\nRateLimitIntervalSec=0\n' > /etc/systemd/journald.conf.d/aliraza.conf
systemctl restart systemd-journald 2>/dev/null
# ---- swap: avoids OOM-kills (random disconnects) on small VPS ----
if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
  if [[ $MEM_MB -le 2048 && $FREE_MB -gt 4096 ]]; then
    if { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; } \
       && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo -e "${G}1G swap enabled${N}"
    else
      rm -f /swapfile
    fi
  fi
fi
# ---- file-descriptor limits ----
cat > /etc/security/limits.d/99-aliraza.conf <<'LIM'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIM
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/aliraza.conf
# ---- nginx: auto-restart + limits ----
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/aliraza.conf <<'NGD'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=2
LimitNOFILE=1048576
OOMScoreAdjust=-300
NGD
echo -e "${Y}[2/6] Core services (WebSocket, auto-kill, tuning)...${N}"
cat > /etc/sysctl.d/99-artricks-ssh.conf <<'SYSCTL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 🚀 EXTREME SPEED TUNING (Read/Write Buffers)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# Stability / many connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 200000
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 1000000
fs.nr_open = 1048576

# Latency / stability extras
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_max_orphans = 65536
net.core.optmem_max = 65536
kernel.pid_max = 4194304
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL_EOF
modprobe tcp_bbr 2>/dev/null; echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl -p /etc/sysctl.d/99-artricks-ssh.conf &>/dev/null
cat > /usr/local/bin/ws-proxy.py <<'WS_EOF'
import socket, threading, select, time, os
PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'
MAP_DIR = '/run/aliraza/ws'
BUF = 131072
WORKERS = max(1, min(4, os.cpu_count() or 1))
def log_client_ip(ip):
    try:
        with open(LOG_FILE, 'a') as f: f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\n")
    except Exception: pass
def tune(s):
    try:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 20)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except Exception: pass
def handle_client(client_socket, client_addr):
    real_ip = client_addr[0]
    target_socket = None
    lport = None
    try:
        client_socket.settimeout(10)
        tune(client_socket)
        request = client_socket.recv(4096).decode('utf-8', errors='ignore')
        if not request: return
        for line in request.split('\r\n'):
            if line.lower().startswith('x-forwarded-for:') or line.lower().startswith('x-real-ip:'):
                real_ip = line.split(':')[1].strip().split(',')[0].strip()
                break
        log_client_ip(real_ip)
        response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        client_socket.sendall(response.encode('utf-8'))
        target_socket = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10)
        tune(target_socket)
        try:
            lport = target_socket.getsockname()[1]
            with open(f"{MAP_DIR}/{lport}", "w") as mf: mf.write(real_ip)
        except Exception: lport = None
        client_socket.settimeout(None); target_socket.settimeout(None)
        poller = select.poll()
        poller.register(client_socket, select.POLLIN)
        poller.register(target_socket, select.POLLIN)
        fdmap = {client_socket.fileno(): (client_socket, target_socket),
                 target_socket.fileno(): (target_socket, client_socket)}
        while True:
            for fd, _ev in poller.poll():
                s, other = fdmap[fd]
                data = s.recv(BUF)
                if not data: return
                other.sendall(data)
    except Exception: pass
    finally:
        for s in (client_socket, target_socket):
            try:
                if s: s.close()
            except Exception: pass
        if lport:
            try: os.remove(f"{MAP_DIR}/{lport}")
            except Exception: pass
def init_map():
    try:
        os.makedirs(MAP_DIR, exist_ok=True)
        for f in os.listdir(MAP_DIR): os.remove(os.path.join(MAP_DIR, f))
    except Exception: pass
def serve():
    threading.stack_size(256 * 1024)
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if WORKERS > 1:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    server.bind(('0.0.0.0', PORT))
    server.listen(4096)
    while True:
        try:
            client, addr = server.accept()
            threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
        except Exception:
            time.sleep(0.1)
def supervise():
    kids = set()
    while True:
        while len(kids) < WORKERS:
            pid = os.fork()
            if pid == 0:
                try: serve()
                finally: os._exit(1)
            kids.add(pid)
        try: pid, _ = os.wait()
        except ChildProcessError:
            kids.clear(); continue
        kids.discard(pid); time.sleep(0.5)
init_map()
if WORKERS > 1: supervise()
else: serve()
WS_EOF
cat > /usr/local/bin/autokill.py <<'PY_EOF'
import os
import time
import subprocess
import re

USER_DIR = "/etc/artricks/users"

def get_auth_logs():
    raw = ""
    for cmd in (["journalctl", "-u", "dropbear", "--no-pager", "-g", "auth succeeded", "-n", "5000"],
                ["journalctl", "-u", "dropbear", "--no-pager", "-n", "2000"]):
        try:
            raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore")
            break
        except Exception:
            continue
    if os.path.exists("/var/log/auth.log"):
        try:
            with open("/var/log/auth.log", "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 2097152))
                raw += "\n" + f.read().decode("utf-8", errors="ignore")
        except Exception:
            pass
    return raw

RE_A = re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'?")
RE_B = re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'?")

def get_active_users_and_pids(raw_logs):
    user_pids = {}
    last = {}
    for line in raw_logs.splitlines():
        m = RE_A.search(line) or RE_B.search(line)
        if m:
            last[m.group(1)] = m.group(2)
    try:
        ps_out = subprocess.check_output(["ps", "-eo", "pid=,comm="], stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore")
        for line in ps_out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "dropbear" and parts[0] in last:
                user_pids.setdefault(last[parts[0]], []).append(parts[0])
    except Exception:
        pass
    return user_pids

def get_pid_io_bytes(pid):
    io_file = f"/proc/{pid}/io"
    total_bytes = 0
    if os.path.exists(io_file):
        try:
            with open(io_file, "r") as f:
                for line in f:
                    if line.startswith("rchar:") or line.startswith("wchar:"):
                        total_bytes += int(line.split(":")[1].strip())
        except Exception:
            pass
    return total_bytes

last_pid_bytes = {}

while True:
    try:
        raw_logs = get_auth_logs()
        user_pids_map = get_active_users_and_pids(raw_logs)

        if os.path.exists(USER_DIR):
            for fname in os.listdir(USER_DIR):
                if not fname.endswith(".conf"):
                    continue

                uname = fname[:-5]
                conf_path = os.path.join(USER_DIR, fname)

                ip_limit = 0
                gb_limit = "Unlimited"
                used_mb = 0.0

                with open(conf_path, "r") as f:
                    lines = f.readlines()

                for line in lines:
                    if line.startswith("IP_LIMIT="):
                        try: ip_limit = int(line.strip().split("=")[1])
                        except Exception: pass
                    elif line.startswith("GB_LIMIT="):
                        gb_limit = line.strip().split("=")[1]
                    elif line.startswith("USED_MB="):
                        try: used_mb = float(line.strip().split("=")[1])
                        except Exception: pass

                active_pids = user_pids_map.get(uname, [])

                for pid in active_pids:
                    current_b = get_pid_io_bytes(pid)
                    if pid in last_pid_bytes:
                        diff = current_b - last_pid_bytes[pid]
                        if diff > 0:
                            used_mb += (diff / (1024.0 * 1024.0))
                    last_pid_bytes[pid] = current_b

                new_lines = []
                for line in lines:
                    if line.startswith("USED_MB="):
                        new_lines.append(f"USED_MB={used_mb:.2f}\n")
                    else:
                        new_lines.append(line)
                if active_pids:
                    new_lines = [l for l in new_lines if not l.startswith("LAST_SEEN=")]
                    new_lines.append(f"LAST_SEEN={int(time.time())}\n")

                with open(conf_path, "w") as f:
                    f.writelines(new_lines)

                if gb_limit != "Unlimited":
                    try:
                        max_mb = float(gb_limit) * 1024.0
                        if used_mb >= max_mb:
                            subprocess.call(["passwd", "-l", uname], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            for pid in active_pids:
                                subprocess.call(["kill", "-9", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except Exception:
                        pass

                if ip_limit > 0 and len(active_pids) > ip_limit:
                    subprocess.call(["passwd", "-l", uname], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    for pid in active_pids:
                        subprocess.call(["kill", "-9", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    except Exception:
        pass

    time.sleep(10)
PY_EOF
cat > /usr/local/bin/tgbot.py <<'TG_EOF'
import os
import re
import json
import asyncio
import subprocess
from datetime import datetime, timedelta

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, ContextTypes, filters,
)

PANEL_NAME = "ALIRAZA VPN Panel"
CONFIG_FILE = "/etc/artricks/tgbot/config.json"
ADMINS_FILE = "/etc/artricks/tgbot/admins.json"
USERS_DIR = "/etc/artricks/users"
DOMAIN_FILE = "/etc/artricks/domain.conf"
BANNER_FILE = "/etc/issue.net"

NGINX_TEMPLATE = """server {{
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name {dom} _;
    location / {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
    location /artricks {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
}}
server {{
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name {dom} _;
    ssl_certificate /etc/letsencrypt/live/{dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{dom}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
    location /artricks {{
        proxy_redirect off;
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        tcp_nodelay on;
        access_log off;
    }}
}}
"""

FLOWS = {
    "add_user": [
        ("username", "\U0001F464 Username enter karein:"),
        ("password", "\U0001F511 Password enter karein:"),
        ("days", "\U0001F4C5 Expiry days enter karein (e.g. 30):"),
        ("ip_limit", "\U0001F310 Max IP Limit enter karein (e.g. 1):"),
        ("gb_limit", "\U0001F4BE Data Limit GB enter karein (e.g. 5, ya Unlimited):"),
    ],
    "del_user": [("username", "\U0001F464 Delete karne ke liye Username enter karein:")],
    "renew_user": [
        ("username", "\U0001F464 Username enter karein jise renew karna hai:"),
        ("days", "\U0001F4C5 Kitne additional days add karne hain?"),
    ],
    "ip_limit": [
        ("username", "\U0001F464 Username enter karein:"),
        ("value", "\U0001F310 Naya IP Limit enter karein:"),
    ],
    "gb_limit": [
        ("username", "\U0001F464 Username enter karein:"),
        ("value", "\U0001F4BE Naya GB Limit enter karein:"),
    ],
    "domain": [("value", "\U0001F30D Naya domain enter karein (e.g. sub.example.com):")],
    "banner": [("value", "\U0001F4E2 Naya SSH banner text bhejein:")],
    "add_admin": [("value", "\U0001F451 Naye Admin ka Telegram User ID enter karein:")],
    "remove_admin": [("value", "\U0001F5D1 Remove karne ke liye Admin ka Telegram User ID enter karein:")],
}

def load_config():
    with open(CONFIG_FILE) as f: return json.load(f)
def load_admins():
    if not os.path.exists(ADMINS_FILE): return []
    with open(ADMINS_FILE) as f: return json.load(f)
def save_admins(admins):
    with open(ADMINS_FILE, "w") as f: json.dump(admins, f)
def is_admin(uid): return uid in load_admins()
def is_super(uid): return uid == load_config().get("super_admin")
def sh(cmd_list, input_data=None): return subprocess.run(cmd_list, capture_output=True, text=True, input=input_data)
def run(cmd_str): return subprocess.run(cmd_str, shell=True, capture_output=True, text=True)

def get_domain():
    if os.path.exists(DOMAIN_FILE):
        with open(DOMAIN_FILE) as f:
            d = f.read().strip()
            return d if d else "No Domain Set"
    return "No Domain Set"

PANEL_DIR = "/opt/aliraza-panel"
PANEL_PY = PANEL_DIR + "/venv/bin/python"

def panel_call(code):
    if not os.path.exists(PANEL_PY): return False
    r = sh(["bash", "-c", f"cd {PANEL_DIR} && {PANEL_PY} -c 'import app; {code}'"])
    return r.returncode == 0

def apply_nginx_config():
    dom = get_domain()
    if dom == "No Domain Set": return
    if panel_call("app.apply_nginx()"): return
    os.makedirs("/etc/nginx/conf.d", exist_ok=True)
    conf = NGINX_TEMPLATE.format(dom=dom)
    if not os.path.exists(f"/etc/letsencrypt/live/{dom}/fullchain.pem"):
        conf = conf.replace(f"/etc/letsencrypt/live/{dom}/fullchain.pem", "/etc/artricks/ssl/self.crt").replace(f"/etc/letsencrypt/live/{dom}/privkey.pem", "/etc/artricks/ssl/self.key")
    with open("/etc/nginx/conf.d/vpn.conf", "w") as f:
        f.write(conf)
    sh(["rm", "-f", "/etc/nginx/sites-enabled/default"])
    if sh(["nginx", "-t"]).returncode == 0:
        sh(["systemctl", "restart", "nginx"])

def valid_username(u): return bool(u) and len(u)<=32 and u not in (".","..") and u[0]!="-" and not re.search(r"[\s:/\\\x00-\x1f\x7f]", u)

def add_user(username, password, days, ip_limit, gb_limit):
    if not valid_username(username): return False, "Invalid username."
    try: exp_date = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
    except ValueError: return False, "Invalid days value."
    r = sh(["useradd", "-M", "-s", "/bin/bash", "-e", exp_date, "--", username])
    if r.returncode != 0: r = sh(["useradd", "--badname", "-M", "-s", "/bin/bash", "-e", exp_date, "--", username])
    if r.returncode != 0: return False, (r.stderr.strip() or "User create failed.")
    sh(["chpasswd"], input_data=f"{username}:{password}\n")
    os.makedirs(USERS_DIR, exist_ok=True)
    with open(f"{USERS_DIR}/{username}.conf", "w") as f:
        f.write(f"IP_LIMIT={ip_limit}\nGB_LIMIT={gb_limit}\nUSED_MB=0.0\n")
    return True, exp_date

def delete_user(username):
    sh(["userdel", "-f", username])
    try: os.remove(f"{USERS_DIR}/{username}.conf")
    except FileNotFoundError: pass

def renew_user(username, days):
    if sh(["id", username]).returncode != 0: return False
    try: new_exp = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")
    except ValueError: return False
    sh(["usermod", "-e", new_exp, username])
    sh(["passwd", "-u", username])
    return True

def update_conf_field(username, field, value):
    path = f"{USERS_DIR}/{username}.conf"
    if not os.path.exists(path): return False
    lines = open(path).readlines()
    new_lines = []
    found = False
    for line in lines:
        if line.startswith(f"{field}="):
            new_lines.append(f"{field}={value}\n")
            found = True
        else: new_lines.append(line)
    if not found: new_lines.append(f"{field}={value}\n")
    with open(path, "w") as f: f.writelines(new_lines)
    sh(["passwd", "-u", username])
    return True

def list_users_text():
    if not os.path.isdir(USERS_DIR): return "Koi user nahi mila."
    entries = []
    for fname in sorted(os.listdir(USERS_DIR)):
        if not fname.endswith(".conf"): continue
        uname = fname[:-5]
        data = {}
        for l in open(f"{USERS_DIR}/{fname}"):
            if "=" in l:
                k, v = l.strip().split("=", 1)
                data[k] = v
        exists = sh(["id", uname]).returncode == 0
        status = "Deleted"
        if exists:
            p = sh(["passwd", "-S", uname])
            status = "LOCKED" if " L " in f" {p.stdout} " else "Active"
        used_mb = 0.0
        try: used_mb = float(data.get("USED_MB", "0") or 0)
        except ValueError: pass
        used_gb = round(used_mb / 1024, 2)
        entries.append(f"\U0001F464 {uname} | IP:{data.get('IP_LIMIT', '?')} | Used:{used_gb}GB / {data.get('GB_LIMIT', '?')}GB | {status}")
    return "\n".join(entries) if entries else "Koi user nahi mila."

def connected_ips_text():
    r = sh(["ss", "-tnp"])
    ports = {"109", "447", "22"}
    try: ports.add(str(json.load(open("/etc/artricks/panel.json")).get("ssh_port")))
    except Exception: pass
    lines = [l for l in r.stdout.splitlines() if "ESTAB" in l and len(l.split()) > 3 and l.split()[3].rsplit(":", 1)[-1] in ports]
    return f"\U0001F50C Active SSH/WS sessions (approx): {len(lines)}"

def status_text():
    def st(svc):
        r = sh(["systemctl", "is-active", svc])
        return "\U0001F7E2 ACTIVE" if r.stdout.strip() == "active" else "\U0001F534 INACTIVE"
    return f"\U0001F30D Domain: {get_domain()}\n\nNginx: {st('nginx')}\nDropbear: {st('dropbear')}\nWS Proxy: {st('ws-proxy')}\nAuto-Kill: {st('autokill')}"

def set_domain(new_domain):
    os.makedirs("/etc/artricks", exist_ok=True)
    with open(DOMAIN_FILE, "w") as f: f.write(new_domain)
    try:
        pj = "/etc/artricks/panel.json"
        c = json.load(open(pj)) if os.path.exists(pj) else {}
        c["domain"] = new_domain
        with open(pj, "w") as f: json.dump(c, f)
    except Exception: pass
    apply_nginx_config()

def setup_ssl():
    dom = get_domain()
    if dom == "No Domain Set": return False, "Pehle domain set karein."
    sh(["systemctl", "stop", "nginx"])
    sh(["certbot", "certonly", "-n", "--standalone", "--preferred-challenges", "http", "--agree-tos", "--register-unsafely-without-email", "-d", dom])
    if os.path.exists(f"/etc/letsencrypt/live/{dom}/fullchain.pem"):
        apply_nginx_config()
        sh(["systemctl", "start", "nginx"])
        return True, "SSL issued successfully."
    sh(["systemctl", "start", "nginx"])
    return False, "SSL fail ho gaya."

def fix_websocket():
    sh(["systemctl", "restart", "dropbear"])
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "restart", "ws-proxy"])
    sh(["systemctl", "restart", "autokill"])
    apply_nginx_config()
    return "WebSocket & Bandwidth engine restarted."

WS_PROXY_SRC = """import socket, threading, select, time
PORT = 2082
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 109
LOG_FILE = '/var/log/ws-proxy.log'
def log_client_ip(ip):
    try:
        with open(LOG_FILE, 'a') as f: f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} - REAL_IP:{ip}\\n")
    except Exception: pass
def handle_client(client_socket, client_addr):
    real_ip = client_addr[0]
    try:
        client_socket.settimeout(10)
        client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        request = client_socket.recv(4096).decode('utf-8', errors='ignore')
        if not request:
            client_socket.close()
            return
        for line in request.split('\\r\\n'):
            if line.lower().startswith('x-forwarded-for:') or line.lower().startswith('x-real-ip:'):
                real_ip = line.split(':')[1].strip().split(',')[0].strip()
                break
        log_client_ip(real_ip)
        response = "HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n"
        client_socket.sendall(response.encode('utf-8'))
        target_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        target_socket.connect((TARGET_HOST, TARGET_PORT))
        sockets = [client_socket, target_socket]
        client_socket.settimeout(None)
        while True:
            readable, _, _ = select.select(sockets, [], [])
            for s in readable:
                other = target_socket if s is client_socket else client_socket
                data = s.recv(65536)
                if not data: return
                other.sendall(data)
    except Exception: pass
    finally: client_socket.close()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', PORT))
server.listen(200)
while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
"""

WS_PROXY_SERVICE = """[Unit]
Description=ALIRAZA WebSocket Proxy Service
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
Nice=-5
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
"""

AUTOKILL_SRC = open("/usr/local/bin/autokill.py").read() if os.path.exists("/usr/local/bin/autokill.py") else ""

AUTOKILL_SERVICE = """[Unit]
Description=ARTRICKS Auto-Kill & Bandwidth Tracking Service
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always
[Install]
WantedBy=multi-user.target
"""

DEFAULT_BANNER = (
    '<font color="green">==========================================</font><br>\n'
    '<font color="yellow"><b>WELCOME TO ALIRAZA VIP VPN</b></font><br>\n'
    '<font color="red"><b>- NO TORRENT / NO MULTILOGIN</b></font><br>\n'
    '<font color="green">==========================================</font><br>\n'
)

def install_components_sync():
    sh(["apt-get", "update", "-y"])
    sh(["apt-get", "install", "-y", "curl", "wget", "unzip", "tar", "net-tools", "socat", "jq", "openssl", "nginx", "dropbear", "certbot", "python3", "python3-pip", "lsof", "iptables"])
    if not os.path.exists(BANNER_FILE) or os.path.getsize(BANNER_FILE) == 0:
        with open(BANNER_FILE, "w") as f: f.write(DEFAULT_BANNER)
    panel_call("app.apply_dropbear()")
    run("sed -i 's/#Banner none/Banner \\/etc\\/issue.net/g' /etc/ssh/sshd_config")
    sh(["systemctl", "restart", "ssh"])
    if not os.path.exists("/usr/local/bin/ws-proxy.py"):
        with open("/usr/local/bin/ws-proxy.py", "w") as f: f.write(WS_PROXY_SRC)
    sh(["chmod", "+x", "/usr/local/bin/ws-proxy.py"])
    with open("/etc/systemd/system/ws-proxy.service", "w") as f: f.write(WS_PROXY_SERVICE)
    with open("/usr/local/bin/autokill.py", "w") as f: f.write(AUTOKILL_SRC)
    sh(["chmod", "+x", "/usr/local/bin/autokill.py"])
    with open("/etc/systemd/system/autokill.service", "w") as f: f.write(AUTOKILL_SERVICE)
    sh(["systemctl", "daemon-reload"])
    sh(["systemctl", "enable", "ws-proxy"])
    sh(["systemctl", "restart", "ws-proxy"])
    sh(["systemctl", "enable", "autokill"])
    sh(["systemctl", "restart", "autokill"])
    apply_nginx_config()

def uninstall_all():
    sh(["systemctl", "stop", "aliraza-panel"]); sh(["systemctl", "disable", "aliraza-panel"])
    sh(["systemctl", "stop", "ws-proxy"]); sh(["systemctl", "stop", "autokill"]); sh(["systemctl", "stop", "dropbear"])
    sh(["systemctl", "disable", "ws-proxy"]); sh(["systemctl", "disable", "autokill"])
    for f in ["/etc/systemd/system/ws-proxy.service", "/etc/systemd/system/autokill.service", "/etc/systemd/system/dropbear.service.d/override.conf", "/usr/local/bin/ws-proxy.py", "/usr/local/bin/autokill.py", "/etc/nginx/conf.d/vpn.conf", "/etc/nginx/conf.d/panel.conf", "/etc/systemd/system/aliraza-panel.service"]:
        try: os.remove(f)
        except FileNotFoundError: pass
    sh(["systemctl", "daemon-reload"]); sh(["systemctl", "restart", "nginx"])
    if os.path.isdir(USERS_DIR):
        for fname in os.listdir(USERS_DIR):
            if fname.endswith(".conf"): sh(["userdel", "-f", fname[:-5]])
    sh(["rm", "-rf", "/etc/artricks"]); sh(["rm", "-rf", "/opt/rr-tgbot-venv"]); sh(["rm", "-rf", "/opt/aliraza-panel"])
    for f in ["/usr/local/bin/menu", "/usr/bin/menu"]:
        try: os.remove(f)
        except FileNotFoundError: pass

def schedule_self_removal():
    subprocess.Popen(["bash", "-c", "sleep 3 && systemctl disable tgbot 2>/dev/null; systemctl stop tgbot 2>/dev/null; rm -f /etc/systemd/system/tgbot.service /usr/local/bin/tgbot.py; systemctl daemon-reload"])

def back_keyboard(): return InlineKeyboardMarkup([[InlineKeyboardButton("\u2B05\uFE0F Back to Menu", callback_data="back_main")]])
def main_menu_keyboard(uid):
    rows = [
        [InlineKeyboardButton("\u2795 Add User", callback_data="add_user"), InlineKeyboardButton("\U0001F5D1 Delete User", callback_data="del_user")],
        [InlineKeyboardButton("\U0001F4CB User List", callback_data="list_users"), InlineKeyboardButton("\u23F3 Renew User", callback_data="renew_user")],
        [InlineKeyboardButton("\U0001F310 IP Limit", callback_data="ip_limit"), InlineKeyboardButton("\U0001F4BE GB Limit", callback_data="gb_limit")],
        [InlineKeyboardButton("\U0001F50C Connected IPs", callback_data="conn_ips"), InlineKeyboardButton("\u2699\uFE0F Status", callback_data="sys_status")],
        [InlineKeyboardButton("\U0001F30D Domain", callback_data="domain"), InlineKeyboardButton("\U0001F512 SSL", callback_data="ssl")],
        [InlineKeyboardButton("\U0001F4E2 Banner", callback_data="banner"), InlineKeyboardButton("\U0001F6E0 Fix WebSocket", callback_data="fix_ws")],
        [InlineKeyboardButton("\U0001F4E6 Install Components", callback_data="install"), InlineKeyboardButton("\U0001F9E8 Uninstall Panel", callback_data="uninstall")],
    ]
    if is_super(uid): rows.append([InlineKeyboardButton("\U0001F451 Admin Management", callback_data="admin_mgmt")])
    return InlineKeyboardMarkup(rows)

def admins_text():
    admins = load_admins()
    lines = ["\U0001F451 *Admin Management*\n"]
    for a in admins:
        tag = " (Super Admin)" if a == load_config().get("super_admin") else ""
        lines.append(f"\u2022 `{a}`{tag}")
    return "\n".join(lines)

def admin_menu_keyboard():
    return InlineKeyboardMarkup([[InlineKeyboardButton("\u2795 Add Admin", callback_data="add_admin"), InlineKeyboardButton("\u2796 Remove Admin", callback_data="remove_admin")], [InlineKeyboardButton("\u2B05\uFE0F Back", callback_data="back_main")]])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if not is_admin(uid):
        await update.message.reply_text("\u26D4 Access Denied. Aap authorized admin nahi hain.")
        return
    context.user_data['flow'] = None
    await update.message.reply_text(f"\U0001F44B Welcome to {PANEL_NAME}\n\nApna option chunein:", reply_markup=main_menu_keyboard(uid))

async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    context.user_data['flow'] = None
    await update.message.reply_text("Cancelled.")

async def execute_flow(flow, data, update: Update):
    if flow == "add_user":
        ok, info = add_user(data["username"], data["password"], data["days"], data["ip_limit"], data["gb_limit"])
        if ok:
            dom = get_domain()
            payload = f"GET /artricks HTTP/1.1[crlf]Host: {dom}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
            msg = f"\u2705 *Account Created*\n\nDomain: `{dom}`\nUsername: `{data['username']}`\nPassword: `{data['password']}`\nExpiry: `{info}`\nIP Limit: `{data['ip_limit']}`\nGB Limit: `{data['gb_limit']}`\n\nSSH Direct: 22, 109, 447\nSSH WS (HTTP): 80\nSSH WS (SSL): 443\n\nPayload:\n`{payload}`"
        else: msg = f"\u274C User create fail: {info}"
        await update.message.reply_text(msg, parse_mode="Markdown", reply_markup=back_keyboard())
    elif flow == "renew_user":
        ok = renew_user(data["username"], data["days"])
        await update.message.reply_text("\u2705 Renewed." if ok else "\u274C User not found.", reply_markup=back_keyboard())
    elif flow == "ip_limit":
        ok = update_conf_field(data["username"], "IP_LIMIT", data["value"])
        await update.message.reply_text("\u2705 IP limit updated." if ok else "\u274C User config not found.", reply_markup=back_keyboard())
    elif flow == "gb_limit":
        ok = update_conf_field(data["username"], "GB_LIMIT", data["value"])
        await update.message.reply_text("\u2705 GB limit updated." if ok else "\u274C User config not found.", reply_markup=back_keyboard())
    elif flow == "domain":
        if not re.match(r"^[A-Za-z0-9.-]+$", data["value"]):
            await update.message.reply_text("❌ Invalid domain.", reply_markup=back_keyboard())
            return
        set_domain(data["value"])
        await update.message.reply_text(f"\u2705 Domain set to {data['value']}", reply_markup=back_keyboard())
    elif flow == "banner":
        with open(BANNER_FILE, "w") as f: f.write(data["value"])
        sh(["systemctl", "restart", "dropbear"]); sh(["systemctl", "restart", "ssh"])
        await update.message.reply_text("\u2705 Banner updated.", reply_markup=back_keyboard())
    elif flow == "add_admin":
        try: new_id = int(data["value"])
        except ValueError: 
            await update.message.reply_text("\u274C Invalid ID.")
            return
        admins = load_admins()
        if new_id in admins: await update.message.reply_text("\u26A0\uFE0F Already an admin.")
        else:
            admins.append(new_id)
            save_admins(admins)
            await update.message.reply_text(f"\u2705 Admin {new_id} added.", reply_markup=admin_menu_keyboard())

async def text_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if not is_admin(uid): return
    flow = context.user_data.get('flow')
    if not flow: return
    step = context.user_data.get('step', 0)
    field, _ = FLOWS[flow][step]
    context.user_data.setdefault('data', {})[field] = update.message.text.strip()
    step += 1
    if step < len(FLOWS[flow]):
        context.user_data['step'] = step
        await update.message.reply_text(FLOWS[flow][step][1])
        return
    data = context.user_data['data']
    context.user_data['flow'] = None
    if flow == "del_user":
        username = data["username"]
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Confirm Delete", callback_data=f"do_del:{username}"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await update.message.reply_text(f"\u26A0\uFE0F '{username}' delete karna confirm karein:", reply_markup=kb)
        return
    if flow == "remove_admin":
        try: target = int(data["value"])
        except ValueError: 
            await update.message.reply_text("\u274C Invalid ID.")
            return
        if target == load_config().get("super_admin"):
            await update.message.reply_text("\u274C Super admin remove nahi ho sakta.")
            return
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Confirm Remove", callback_data=f"rm_admin:{target}"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await update.message.reply_text(f"\u26A0\uFE0F Admin {target} remove karna confirm karein:", reply_markup=kb)
        return
    await execute_flow(flow, data, update)

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    uid = q.from_user.id
    if not is_admin(uid):
        await q.answer("Access denied.", show_alert=True)
        return
    data = q.data
    await q.answer()
    if data == "back_main":
        context.user_data['flow'] = None
        await q.edit_message_text("\U0001F4CB Main Menu", reply_markup=main_menu_keyboard(uid))
    elif data in FLOWS:
        context.user_data['flow'] = data
        context.user_data['step'] = 0
        context.user_data['data'] = {}
        await q.edit_message_text(FLOWS[data][0][1])
    elif data == "list_users": await q.edit_message_text(list_users_text(), reply_markup=back_keyboard())
    elif data == "conn_ips": await q.edit_message_text(connected_ips_text(), reply_markup=back_keyboard())
    elif data == "sys_status": await q.edit_message_text(status_text(), reply_markup=back_keyboard())
    elif data == "ssl":
        await q.edit_message_text("\U0001F512 SSL issue ho raha hai, wait karein...")
        ok, msg = await asyncio.to_thread(setup_ssl)
        await q.message.reply_text(("\u2705 " if ok else "\u274C ") + msg, reply_markup=back_keyboard())
    elif data == "fix_ws":
        msg = fix_websocket()
        await q.edit_message_text(f"\u2705 {msg}", reply_markup=back_keyboard())
    elif data == "install":
        await q.edit_message_text("\U0001F4E6 Poora system install ho raha hai, 2-5 min lagega...")
        await asyncio.to_thread(install_components_sync)
        await q.message.reply_text("\u2705 Installation complete!", reply_markup=back_keyboard())
    elif data == "uninstall":
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("\u2705 Haan, Uninstall karein", callback_data="do_uninstall"), InlineKeyboardButton("\u274C Cancel", callback_data="back_main")]])
        await q.edit_message_text("\u26A0\uFE0F Yeh sab kuch permanently remove kar dega. Confirm karein:", reply_markup=kb)
    elif data == "do_uninstall":
        await q.edit_message_text("\U0001F9E8 Uninstalling...")
        await asyncio.to_thread(uninstall_all)
        await q.message.reply_text("\u2705 Uninstall complete.")
        schedule_self_removal()
    elif data == "admin_mgmt":
        if not is_super(uid):
            await q.answer("Sirf Super Admin ke liye.", show_alert=True)
            return
        await q.edit_message_text(admins_text(), parse_mode="Markdown", reply_markup=admin_menu_keyboard())
    elif data.startswith("do_del:"):
        delete_user(data.split(":", 1)[1])
        await q.edit_message_text("\u2705 User deleted.", reply_markup=back_keyboard())
    elif data.startswith("rm_admin:"):
        target = int(data.split(":", 1)[1])
        admins = load_admins()
        if target in admins:
            admins.remove(target)
            save_admins(admins)
        await q.edit_message_text(admins_text(), parse_mode="Markdown", reply_markup=admin_menu_keyboard())

def main():
    app = Application.builder().token(load_config()["token"]).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("cancel", cancel))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text_handler))
    app.run_polling()

if __name__ == "__main__":
    main()
TG_EOF
cat > /etc/systemd/system/ws-proxy.service <<'U1'
[Unit]
Description=ALIRAZA WebSocket Proxy
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
TasksMax=infinity
Nice=-5
OOMScoreAdjust=-500
[Install]
WantedBy=multi-user.target
U1
cat > /etc/systemd/system/autokill.service <<'U2'
[Unit]
Description=ALIRAZA Auto-Kill & Bandwidth
After=network.target
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/autokill.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U2
cat > /etc/systemd/system/tgbot.service <<'U3'
[Unit]
Description=ALIRAZA Telegram Bot
After=network.target
[Service]
ExecStart=/opt/rr-tgbot-venv/bin/python3 /usr/local/bin/tgbot.py
Restart=always
[Install]
WantedBy=multi-user.target
U3
cat > /etc/systemd/system/aliraza-panel.service <<'U4'
[Unit]
Description=ALIRAZA SSH Panel
After=network.target
StartLimitIntervalSec=0
[Service]
WorkingDirectory=/opt/aliraza-panel
ExecStart=/opt/aliraza-panel/venv/bin/gunicorn -k gthread -w 1 --threads 64 --timeout 120 -b 127.0.0.1:12026 --chdir /opt/aliraza-panel app:app
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U4
echo -e "${Y}[3/6] Panel app...${N}"
cat > /opt/aliraza-panel/app.py <<'APP_EOF'
# ALIRAZA SSH Panel backend | Support: @ar_tricks
import os,re,json,time,sqlite3,subprocess,secrets,threading,pty,select,struct,fcntl,termios,codecs,datetime,socket
import psutil
from flask import Flask,request,session,jsonify,send_file
from flask_sock import Sock
from werkzeug.security import generate_password_hash,check_password_hash
D="/etc/artricks";UD=D+"/users";CFG=D+"/panel.json";DB=D+"/panel.db";BANNER="/etc/issue.net"
DEF={"domain":"","panel_port":2083,"ssh_port":8443}
def cfg():
    try: return {**DEF,**json.load(open(CFG))}
    except Exception: return dict(DEF)
def savecfg(c):
    os.makedirs(D,exist_ok=True);json.dump(c,open(CFG,"w"))
    open(D+"/domain.conf","w").write(c["domain"])
def sh(a,inp=None,t=60):
    try:
        r=subprocess.run(a,input=inp,capture_output=True,text=True,timeout=t);return r.returncode==0,(r.stdout+r.stderr).strip()
    except Exception as e: return False,str(e)
def later(f,s=1.5): threading.Timer(s,f).start()
def ufw(p):
    if sh(["ufw","status"])[1].startswith("Status: active"): sh(["ufw","allow",f"{p}/tcp"])
PROXY="""        proxy_pass http://127.0.0.1:%s;proxy_http_version 1.1;proxy_set_header Upgrade $http_upgrade;proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;proxy_set_header X-Real-IP $remote_addr;proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;proxy_send_timeout 86400s;proxy_buffering off;proxy_socket_keepalive on;"""
def apply_nginx():
    c=cfg();d=c["domain"];le=f"/etc/letsencrypt/live/{d}"
    crt,key=(le+"/fullchain.pem",le+"/privkey.pem") if os.path.exists(le+"/fullchain.pem") else (D+"/ssl/self.crt",D+"/ssl/self.key")
    v6=os.path.exists("/proc/net/if_inet6")
    def L(port,extra=""):
        x=" ".join(t for t in ("listen",str(port),extra) if t)+";"
        return x+(x.replace("listen "+str(port),"listen [::]:"+str(port),1) if v6 else "")
    ws=PROXY%2082
    open("/etc/nginx/conf.d/vpn.conf","w").write(f"""server{{{L(80,"default_server backlog=4096")}server_name {d} _;
 location /{{\n{ws}\n }}\n location /artricks{{\n{ws}\n }}}}
server{{{L(443,"ssl http2 default_server backlog=4096")}server_name {d} _;ssl_certificate {crt};ssl_certificate_key {key};ssl_protocols TLSv1.2 TLSv1.3;
 location /{{\n{ws}\n }}\n location /artricks{{\n{ws}\n }}}}""")
    open("/etc/nginx/conf.d/panel.conf","w").write(f"""server{{{L(c['panel_port'],"ssl http2")}server_name _;ssl_certificate {crt};ssl_certificate_key {key};ssl_protocols TLSv1.2 TLSv1.3;
 location /{{\n{PROXY%12026}\n }}}}""")
    try: os.remove("/etc/nginx/sites-enabled/default")
    except Exception: pass
    ok,o=sh(["nginx","-t"])
    if ok: ok,o=sh(["systemctl","restart","nginx"])
    return ok,o
def apply_dropbear():
    c=cfg();os.makedirs("/etc/dropbear",exist_ok=True)
    W=1048576 if psutil.virtual_memory().total>=1900*2**20 else 524288
    for k in("rsa","ecdsa","ed25519"):
        f=f"/etc/dropbear/dropbear_{k}_host_key"
        if not os.path.exists(f): sh(["dropbearkey","-t",k,"-f",f])
    os.makedirs("/etc/systemd/system/dropbear.service.d",exist_ok=True)
    sp=int(c["ssh_port"]);ports=list(dict.fromkeys([sp,109,447]))
    binp="/usr/local/sbin/dropbear" if os.path.exists("/usr/local/sbin/dropbear") else "/usr/sbin/dropbear"
    args="-F "+" ".join(f"-p {p}" for p in ports)+f" -b {BANNER} -W {W} -K 60"
    open("/etc/systemd/system/dropbear.service.d/override.conf","w").write("[Unit]\nStartLimitIntervalSec=0\n[Service]\nType=simple\nPIDFile=\nRemainAfterExit=no\nExecStart=\nExecStop=\nExecReload=\nExecStart="+binp+" "+args+"\nLimitNOFILE=1048576\nTasksMax=infinity\nNice=-5\nRestart=always\nRestartSec=3\nOOMScoreAdjust=-300\n")
    open("/etc/default/dropbear","w").write(f'NO_START=0\nDROPBEAR_PORT={sp}\nDROPBEAR_BANNER="{BANNER}"\nDROPBEAR_RECEIVE_WINDOW={W}\nDROPBEAR_EXTRA_ARGS="-p 109 -p 447 -b {BANNER} -W {W} -K 60"\n')
    ufw(sp);sh(["systemctl","daemon-reload"]);sh(["systemctl","enable","dropbear"]);return sh(["systemctl","restart","dropbear"])
app=Flask(__name__);sock=Sock(app)
def key():
    f=D+"/secret.key"
    if not os.path.exists(f): open(f,"w").write(secrets.token_hex(32));os.chmod(f,0o600)
    return open(f).read()
app.secret_key=key();app.config.update(SESSION_COOKIE_SAMESITE="Strict",SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SECURE=True,PERMANENT_SESSION_LIFETIME=86400)
def db():
    c=sqlite3.connect(DB);c.execute("create table if not exists admins(u text primary key,p text,role text default 'admin')")
    try: c.execute("alter table admins add column role text default 'admin'");c.commit()
    except Exception: pass
    try: os.chmod(DB,0o600)
    except Exception: pass
    return c
def api(f):
    def w(*a,**k):
        if not session.get("u"): return jsonify(error="login"),401
        if request.method!="GET" and request.headers.get("X-Panel")!="1": return jsonify(error="bad request"),403
        if session.get("r")!="admin" and (request.method!="GET" or request.path not in("/api/overview","/api/accounts","/api/sessions")): return jsonify(error="View-only login: sirf admin yeh kar sakta hai"),403
        try: return f(*a,**k)
        except Exception as e: return jsonify(error=str(e)),400
    w.__name__=f.__name__;return w
fails={}
@app.route("/")
def index(): return send_file("/opt/aliraza-panel/index.html")
@app.post("/api/login")
def login():
    ip=request.headers.get("X-Real-IP",request.remote_addr);n,t=fails.get(ip,(0,0))
    if n>=5 and time.time()-t<300: return jsonify(error="Too many attempts. Wait 5 minutes."),429
    j=request.get_json(silent=True) or {};r=db().execute("select p,role from admins where u=?",(j.get("u",""),)).fetchone()
    want="admin" if j.get("role")=="admin" else "user"
    if r and (r[1] or "admin")==want and check_password_hash(r[0],j.get("p","")): fails.pop(ip,None);session.clear();session.permanent=True;session["u"]=j["u"];session["r"]=want;return jsonify(ok=1)
    fails[ip]=(n+1,time.time());return jsonify(error="Wrong username or password"),401
@app.post("/api/logout")
def logout(): session.clear();return jsonify(ok=1)
@app.get("/api/me")
def me(): return jsonify(u=session.get("u"),role=session.get("r"))
def pub_ip():
    try: return subprocess.check_output(["curl","-4","-s","--max-time","3","ifconfig.me"],text=True).strip()
    except Exception: return ""
IP=[0,""]
def readconf(u):
    d={"IP_LIMIT":"1","GB_LIMIT":"Unlimited","USED_MB":"0"}
    try:
        for l in open(f"{UD}/{u}.conf"):
            if "=" in l: a,b=l.strip().split("=",1);d[a]=b
    except Exception: pass
    return d
def writeconf(u,d): os.makedirs(UD,exist_ok=True);open(f"{UD}/{u}.conf","w").write("".join(f"{k}={v}\n" for k,v in d.items()))
WSMAP="/run/aliraza/ws"
RE_A=re.compile(r"\]: \[(\d+)\] .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
RE_B=re.compile(r"dropbear\[(\d+)\]: .*?auth succeeded for '?([\w.-]+)'? from (\S+)")
_SC=[0,[]]
def kill_pid(pid):
    try: os.kill(int(pid),9);return True
    except Exception: return False
def get_sessions(force=False):
    if not force and time.time()-_SC[0]<2: return _SC[1]
    last={}
    r=sh(["journalctl","-u","dropbear","--no-pager","-g","auth succeeded","-n","5000"])
    if not r[0] and not r[1].strip().startswith("-- No entries"): r=sh(["journalctl","-u","dropbear","--no-pager","-n","2000"])
    for l in r[1].splitlines():
        m=RE_A.search(l) or RE_B.search(l)
        if m: last[m.group(1)]=(m.group(2),m.group(3))
    out=[]
    for l in sh(["ps","-eo","pid=,etimes=,comm="])[1].splitlines():
        p=l.split()
        if len(p)<3 or p[2]!="dropbear" or p[0] not in last: continue
        u,frm=last[p[0]];ip,_,port=frm.rpartition(":");ip=ip.strip("[]");real,via=ip,"ssh"
        if ip in("127.0.0.1","::1","::ffff:127.0.0.1"):
            via="ws"
            if port.isdigit():
                try: real=open(f"{WSMAP}/{port}").read().strip() or ip
                except Exception: pass
        out.append(dict(pid=p[0],u=u,ip=real,via=via,secs=int(p[1]) if p[1].isdigit() else 0))
    out.sort(key=lambda x:(x["u"],x["ip"]))
    _SC[0]=time.time();_SC[1]=out;return out
def online():
    m={}
    for x in get_sessions(): m[x["u"]]=m.get(x["u"],0)+1
    return m
def shadow():
    m={}
    for l in open("/etc/shadow"):
        p=l.split(":")
        if len(p)>7: m[p[0]]=(p[1].startswith("!"),p[7])
    return m
@app.get("/api/overview")
@api
def overview():
    c=cfg();v=psutil.virtual_memory();dk=psutil.disk_usage("/");n=psutil.net_io_counters()
    if time.time()-IP[0]>600: IP[1]=pub_ip();IP[0]=time.time()
    svc={s:sh(["systemctl","is-active",s])[1]=="active" for s in("nginx","dropbear","ws-proxy","autokill","tgbot")}
    try: os_=[l.split("=",1)[1].strip().strip('"') for l in open("/etc/os-release") if l.startswith("PRETTY_NAME")][0]
    except Exception: os_=""
    return jsonify(host=socket.gethostname(),os=os_,kernel=os.uname().release,ip=IP[1],cpu=psutil.cpu_percent(0.3),cores=psutil.cpu_count(),ram=[v.used,v.total],disk=[dk.used,dk.total],
      up=int(time.time()-psutil.boot_time()),load=os.getloadavg(),rx=n.bytes_recv,tx=n.bytes_sent,svc=svc,cfg=c,users=len(os.listdir(UD)) if os.path.isdir(UD) else 0,online=sum(online().values()))
@app.get("/api/accounts")
@api
def accounts():
    by={}
    for x in get_sessions(): by.setdefault(x["u"],[]).append(x)
    sd=shadow();out=[];today=datetime.date.today()
    for f in sorted(os.listdir(UD) if os.path.isdir(UD) else []):
        if not f.endswith(".conf"): continue
        u=f[:-5];d=readconf(u);lk,ex=sd.get(u,(False,""))
        ed=(datetime.date(1970,1,1)+datetime.timedelta(days=int(ex))) if ex.isdigit() else None
        ss=by.get(u,[])
        try: ls=int(float(d.get("LAST_SEEN","0") or 0))
        except Exception: ls=0
        out.append(dict(u=u,ip=d["IP_LIMIT"],gb=d["GB_LIMIT"],used=round(float(d["USED_MB"] or 0)/1024,2),exp=ed.isoformat() if ed else "never",days=(ed-today).days if ed else None,expired=bool(ed and ed<today),locked=lk,online=len(ss),ips=sorted({x["ip"] for x in ss}),last=ls,exists=u in sd))
    return jsonify(out)
@app.get("/api/sessions")
@api
def sessions_api():
    ss=get_sessions(True)
    return jsonify(sessions=ss,users=len({x["u"] for x in ss}),ips=len({x["ip"] for x in ss}))
@app.post("/api/kick")
@api
def kick():
    j=request.get_json() or {};n=0
    if not (j.get("pid") or j.get("u") or j.get("ip")): raise ValueError("Nothing to kick")
    for x in get_sessions(True):
        if (j.get("pid") and str(j["pid"])==x["pid"]) or (j.get("u") and j["u"]==x["u"]) or (j.get("ip") and j["ip"]==x["ip"]):
            if kill_pid(x["pid"]): n+=1
    _SC[0]=0
    return jsonify(ok=1,killed=n)
@app.post("/api/accounts/cleanup")
@api
def cleanup():
    sd=shadow();today=datetime.date.today();n=0
    for f in (os.listdir(UD) if os.path.isdir(UD) else []):
        if not f.endswith(".conf"): continue
        u=f[:-5];ex=sd.get(u,(False,""))[1]
        if UN.match(u) and ex.isdigit() and datetime.date(1970,1,1)+datetime.timedelta(days=int(ex))<today:
            sh(["pkill","-KILL","-u",u]);sh(["userdel","-f",u])
            try: os.remove(f"{UD}/{u}.conf")
            except Exception: pass
            n+=1
    return jsonify(ok=1,deleted=n)
def uname(j):
    u=str(j.get("u","")).strip()
    # sirf wo cheezein roki hain jo Linux/system ko tor sakti hain
    if not u or len(u)>32 or u in(".","..") or u[0]=="-" or re.search(r"[\s:/\\\x00-\x1f\x7f]",u): raise ValueError("Username khali na ho, max 32 chars, space / : \\ allowed nahi")
    return u
def pw(p):
    p=str(p)
    if not p or "\n" in p or "\r" in p or "\x00" in p: raise ValueError("Password khali nahi ho sakta")
    return p
def setexp(u,days): sh(["usermod","-e",(datetime.date.today()+datetime.timedelta(days=int(days))).isoformat(),u])
@app.post("/api/accounts")
@api
def acc_add():
    j=request.get_json();u=uname(j);p=pw(j.get("p",""));days=int(j.get("days",30))
    ok,o=sh(["useradd","-M","-s","/bin/bash","--",u])
    if not ok: ok,o=sh(["useradd","--badname","-M","-s","/bin/bash","--",u])
    if not ok: raise ValueError(o)
    sh(["chpasswd"],f"{u}:{p}\n");setexp(u,days)
    writeconf(u,{"IP_LIMIT":int(j.get("ip",1)),"GB_LIMIT":j.get("gb") or "Unlimited","USED_MB":"0.0"});return jsonify(ok=1)
@app.put("/api/accounts/<u>")
@api
def acc_edit(u):
    j=request.get_json();d=readconf(u)
    if not os.path.exists(f"{UD}/{u}.conf"): raise ValueError("Account not found")
    if j.get("p"): sh(["chpasswd"],f"{u}:{pw(j['p'])}\n")
    if j.get("days") not in(None,""): setexp(u,j["days"])
    if j.get("ip") not in(None,""): d["IP_LIMIT"]=int(j["ip"])
    if j.get("gb") not in(None,""): d["GB_LIMIT"]=j["gb"]
    if j.get("reset"): d["USED_MB"]="0.0"
    writeconf(u,d)
    if j.get("lock") is True:
        sh(["passwd","-l",u])
        for x in get_sessions(True):
            if x["u"]==u: kill_pid(x["pid"])
    else: sh(["passwd","-u",u])
    return jsonify(ok=1)
@app.delete("/api/accounts/<u>")
@api
def acc_del(u):
    if not UN.match(u): raise ValueError("bad name")
    sh(["pkill","-KILL","-u",u]);sh(["userdel","-f",u])
    try: os.remove(f"{UD}/{u}.conf")
    except Exception: pass
    return jsonify(ok=1)
@app.route("/api/banner",methods=["GET","PUT"])
@api
def banner():
    if request.method=="PUT": open(BANNER,"w").write(request.get_json().get("t",""));return jsonify(ok=1)
    return jsonify(t=open(BANNER).read() if os.path.exists(BANNER) else "")
TB=D+"/tgbot"
@app.route("/api/tg",methods=["GET","POST"])
@api
def tg():
    if request.method=="POST":
        j=request.get_json();t=j.get("token","").strip();a=int(j.get("admin"))
        if not re.match(r"^\d+:[\w-]{20,}$",t): raise ValueError("Invalid bot token")
        os.makedirs(TB,exist_ok=True);json.dump({"token":t,"super_admin":a},open(TB+"/config.json","w"));json.dump([a],open(TB+"/admins.json","w"));os.chmod(TB+"/config.json",0o600)
        sh(["systemctl","enable","tgbot"]);ok,o=sh(["systemctl","restart","tgbot"]);return jsonify(ok=ok,msg=o)
    if request.args.get("act") in("start","stop","restart"): sh(["systemctl",request.args["act"],"tgbot"])
    try: c=json.load(open(TB+"/config.json"));tok=c["token"][:6]+"…"+c["token"][-4:];adm=c["super_admin"]
    except Exception: tok=adm=None
    return jsonify(active=sh(["systemctl","is-active","tgbot"])[1]=="active",token=tok,admin=adm)
@app.post("/api/service/<s>/<act>")
@api
def service(s,act):
    if s not in("nginx","dropbear","ws-proxy","autokill","tgbot") or act not in("start","stop","restart"): raise ValueError("bad")
    ok,o=sh(["systemctl",act,s]);return jsonify(ok=ok,msg=o)
@app.post("/api/fix")
@api
def fix(): apply_dropbear();sh(["systemctl","restart","ws-proxy"]);sh(["systemctl","restart","autokill"]);return jsonify(ok=1,msg=apply_nginx()[1])
def freeport(p,own):
    if p in(80,443,109,447,2082,12026) or not 1<=p<=65535: raise ValueError("Port reserved/invalid")
    if p!=own and sh(["ss","-ltn",f"sport = :{p}"])[1].count("\n")>=1: raise ValueError(f"Port {p} is already in use")
@app.post("/api/settings")
@api
def settings():
    j=request.get_json();c=cfg();msg=[];nw=dict(c)
    if j.get("panel_port"): p=int(j["panel_port"]);freeport(p,c["panel_port"]);nw["panel_port"]=p
    if j.get("ssh_port"): p=int(j["ssh_port"]);freeport(p,c["ssh_port"]);nw["ssh_port"]=p
    if nw["panel_port"]==nw["ssh_port"]: raise ValueError("Panel and SSH port must differ")
    if j.get("domain"):
        d=j["domain"].strip().lower()
        if not re.match(r"^[a-z0-9.-]+$",d): raise ValueError("Invalid domain")
        nw["domain"]=d
    savecfg(nw)
    if nw["domain"]!=c["domain"] and j.get("ssl"):
        sh(["systemctl","stop","nginx"]);ok,o=sh(["certbot","certonly","-n","--standalone","--agree-tos","--register-unsafely-without-email","-d",nw["domain"]],t=180);msg.append("SSL issued" if ok else "SSL failed (self-signed kept): "+o[-200:])
    ufw(nw["panel_port"])
    if nw["ssh_port"]!=c["ssh_port"]: later(apply_dropbear)
    later(apply_nginx);return jsonify(ok=1,msg=" | ".join(msg),cfg=nw)
@app.post("/api/admin")
@api
def admin():
    j=request.get_json();c=db();a=j.get("act");u=j.get("u","").strip()
    if not u or len(u)>64: raise ValueError("Username khali ya bohat lamba")
    if a=="create":
        rl="admin" if j.get("role")=="admin" else "user"
        c.execute("insert into admins(u,p,role) values(?,?,?)",(u,generate_password_hash(pw(j.get("p",""))),rl))
    elif a=="password": c.execute("update admins set p=? where u=?",(generate_password_hash(pw(j.get("p",""))),u))
    elif a=="rename":
        n=j.get("new","").strip()
        if not n or len(n)>64: raise ValueError("Username khali ya bohat lamba")
        c.execute("update admins set u=? where u=?",(n,u));session["u"]=n if session["u"]==u else session["u"]
    elif a=="delete":
        tr=c.execute("select role from admins where u=?",(u,)).fetchone()
        if u==session["u"] or (tr and (tr[0] or "admin")=="admin" and c.execute("select count(*) from admins where role='admin' or role is null").fetchone()[0]<2): raise ValueError("Cannot delete this admin")
        c.execute("delete from admins where u=?",(u,))
    c.commit();return jsonify(ok=1,admins=[r[0] for r in c.execute("select u from admins")])
@app.get("/api/admins")
@api
def admins(): return jsonify([{"u":r[0],"role":r[1] or "admin"} for r in db().execute("select u,role from admins")])

APP_EOF
cat > /opt/aliraza-panel/index.html <<'UI_EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#080604"><title>ALIRAZA SSH Panel</title>
<link href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@500;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{--bg:#080604;--card:#14100a;--line:#3d3014;--g:#ffc83d;--g2:#b8860b;--tx:#fff4d6;--mu:#b3a37a;--f1:#b45309;--f2:#ffb300;--f3:#fff1b8;--bad:#ff5a4d}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.5 "IBM Plex Mono",monospace}
h1,h2,h3,.brand,button,nav a{font-family:"Chakra Petch",sans-serif}
.flames{position:fixed;left:0;right:0;bottom:0;height:140px;display:flex;justify-content:space-around;pointer-events:none;z-index:0;opacity:.75}
.flames i{width:14%;height:100%;background:radial-gradient(ellipse at 50% 100%,var(--f3) 0,var(--f2) 25%,var(--f1) 50%,transparent 72%);filter:blur(7px);transform-origin:50% 100%;animation:fl 2.4s ease-in-out infinite alternate;border-radius:50% 50% 0 0}
.flames i:nth-child(2n){animation-duration:3.1s;animation-delay:-.7s}.flames i:nth-child(3n){animation-duration:1.9s;animation-delay:-1.3s}
@keyframes fl{0%{transform:scale(.8,.55)}50%{transform:scale(1,.9) skewX(4deg)}100%{transform:scale(.9,.7) skewX(-4deg)}}
.logo{display:inline-block;animation:fl 1.6s ease-in-out infinite alternate;transform-origin:50% 100%}
.flames s{position:absolute;bottom:0;background:var(--f3);border-radius:50%;box-shadow:0 0 6px var(--f2);animation:up 4s linear infinite;opacity:0}
@keyframes up{0%{transform:translate(0,0);opacity:0}10%{opacity:1}100%{transform:translate(14px,-230px);opacity:0}}
.brand{letter-spacing:2px}header{border-bottom-color:var(--g2)!important}.card{box-shadow:inset 0 0 0 1px #000,inset 0 0 26px #ffc83d0d}.card:hover{border-color:var(--g2)}
@media(prefers-reduced-motion:reduce){.flames i,.flames s,.logo{animation:none}}
#app{position:relative;z-index:1;min-height:100vh;padding-bottom:160px}
body.ro .wr{display:none!important}.rt{display:flex;gap:8px;margin-bottom:14px}.rt button{flex:1;background:transparent;color:var(--mu);border:1px solid var(--line)}.rt button.on{background:linear-gradient(90deg,var(--f1),var(--f2));color:#1a0e00;border-color:transparent}
/* ===== ALIRAZA extra animations ===== */
body::before{content:"";position:fixed;inset:0;z-index:0;pointer-events:none;background-image:linear-gradient(#ffc83d0a 1px,transparent 1px),linear-gradient(90deg,#ffc83d0a 1px,transparent 1px);background-size:42px 42px;animation:grid 22s linear infinite}
@keyframes grid{to{background-position:42px 42px}}
body::after{content:"";position:fixed;left:0;right:0;top:-20%;height:18%;z-index:0;pointer-events:none;background:linear-gradient(180deg,transparent,#ffc83d0d,transparent);animation:scan 9s linear infinite}
@keyframes scan{to{top:110%}}
@keyframes rise{from{opacity:0;transform:translateY(18px) scale(.98)}to{opacity:1;transform:none}}
@keyframes pop{0%{opacity:0;transform:scale(.6)}70%{transform:scale(1.06)}100%{opacity:1;transform:none}}
@keyframes glow{0%,100%{text-shadow:0 0 10px #ffc83d55,0 0 22px #ffb30022}50%{text-shadow:0 0 18px #ffc83d,0 0 38px #ffb30088}}
@keyframes pulse{0%{box-shadow:0 0 0 0 #ffc83d88}100%{box-shadow:0 0 0 12px #ffc83d00}}
@keyframes sweep{0%{background-position:0 50%}100%{background-position:200% 50%}}
@keyframes slidein{from{opacity:0;transform:translateX(40px)}to{opacity:1;transform:none}}
@keyframes drop{from{opacity:0;transform:translateY(-100%)}to{opacity:1;transform:none}}
main>.card,.login .card{animation:rise .55s cubic-bezier(.2,.8,.2,1) both}
main>.card:nth-child(2){animation-delay:.08s}main>.card:nth-child(3){animation-delay:.16s}main>.card:nth-child(4){animation-delay:.24s}main>.card:nth-child(5){animation-delay:.32s}
.grid>div{animation:pop .5s ease both}.grid>div:nth-child(2){animation-delay:.07s}.grid>div:nth-child(3){animation-delay:.14s}.grid>div:nth-child(4){animation-delay:.21s}
.brand{animation:glow 3s ease-in-out infinite}
header{animation:drop .6s ease both}header::after{content:"";position:absolute;left:0;right:0;bottom:-1px;height:2px;background:linear-gradient(90deg,transparent,var(--f2),var(--f3),var(--f2),transparent);background-size:200% 100%;animation:sweep 3s linear infinite}
nav a{transition:all .25s}nav a:hover{color:var(--g);transform:translateY(-2px);border-color:var(--line)}nav a.on{animation:pulse 1.8s infinite}
.card{transition:transform .25s,border-color .25s,box-shadow .25s}.card:hover{transform:translateY(-3px);box-shadow:0 8px 28px #ffb30022,inset 0 0 26px #ffc83d12}
.login .card{position:relative}.login .card::before{content:"";position:absolute;inset:-2px;border-radius:14px;z-index:-1;background:linear-gradient(90deg,var(--f1),var(--f3),var(--f2),var(--f1));background-size:300% 100%;animation:sweep 4s linear infinite;filter:blur(6px);opacity:.7}
button{position:relative;overflow:hidden;transition:transform .15s,box-shadow .25s,background .25s}button:hover{transform:translateY(-2px);box-shadow:0 6px 18px #ffb30044}button:active{transform:scale(.95)}
button::after{content:"";position:absolute;top:0;left:-70%;width:50%;height:100%;background:linear-gradient(100deg,transparent,#fff7,transparent);transform:skewX(-20deg)}button:hover::after{left:130%;transition:left .6s}
button.f{background-size:200% 100%;animation:sweep 3s linear infinite}
input,select,textarea{transition:border-color .25s,box-shadow .25s}input:focus,select:focus,textarea:focus{border-color:var(--f2);box-shadow:0 0 0 3px #ffb30026,0 0 16px #ffb30033}
tr{transition:background .2s}tbody tr:hover,table tr:hover td{background:#ffc83d0d}table tr{animation:rise .4s ease both}
.b.on1{animation:pulse 1.6s infinite}
.bar i{animation:sweep 2.5s linear infinite;background-size:200% 100%;transition:width 1s ease}
#toast{animation:slidein .35s ease both}
.v{animation:glow 4s ease-in-out infinite}
@media(prefers-reduced-motion:reduce){body::before,body::after,main>.card,.login .card,.grid>div,.brand,header,header::after,nav a.on,button.f,.b.on1,.bar i,.v,table tr,#toast,.login .card::before{animation:none!important}}

header{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--line);background:#0d0a05ee;position:sticky;top:0;z-index:5}
.brand{font-size:22px;font-weight:700;color:var(--g);letter-spacing:.5px;text-shadow:0 0 14px #ffc83d66}.brand small{display:block;font-size:11px;color:var(--f2);font-weight:500;letter-spacing:0}
header .sp{flex:1}
nav{display:flex;gap:6px;overflow-x:auto;padding:10px 12px;border-bottom:1px solid var(--line)}
nav a{color:var(--mu);padding:7px 14px;border:1px solid transparent;border-radius:8px;cursor:pointer;white-space:nowrap}
nav a.on{color:var(--g);border-color:var(--g2);background:#2a2008;box-shadow:0 0 12px #ffc83d22}
main{max-width:1000px;margin:0 auto;padding:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}
.k{color:var(--mu);font-size:12px}.v{font-size:20px;color:var(--g);font-family:"Chakra Petch"}
h2{margin:0 0 12px;font-size:19px;color:var(--g)}h3{margin:0 0 8px;color:var(--f2)}
button{background:var(--g2);color:#1a1100;border:0;border-radius:8px;padding:8px 14px;font-weight:700;cursor:pointer;font-size:14px}
button:hover{background:var(--g)}button.f{background:linear-gradient(90deg,var(--f1),var(--f2));color:#1a0e00}button.s{background:transparent;color:var(--g);border:1px solid var(--g2)}button.d{background:var(--bad);color:#fff}button:focus-visible,input:focus-visible,nav a:focus-visible,textarea:focus-visible{outline:2px solid var(--f2);outline-offset:2px}
input,textarea,select{background:#060402;border:1px solid var(--line);color:var(--tx);padding:9px 10px;border-radius:8px;font:inherit;width:100%}
label{display:block;margin:8px 0 3px;color:var(--mu);font-size:13px}.row{display:flex;gap:10px;flex-wrap:wrap}.row>*{flex:1;min-width:140px}
table{width:100%;border-collapse:collapse}td,th{padding:8px 6px;border-bottom:1px solid var(--line);text-align:left;font-size:13px}th{color:var(--mu);font-weight:500}.tw{overflow-x:auto}
.b{padding:2px 8px;border-radius:20px;font-size:12px}.on1{background:#3a2c08;color:var(--g)}.off1{background:#401410;color:var(--bad)}.mu1{background:#241b08;color:var(--mu)}
.bar{height:8px;background:#241b08;border-radius:6px;overflow:hidden;margin-top:6px}.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--g2),var(--g))}
pre.c{background:#060402;border:1px solid var(--line);padding:10px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;word-break:break-all;margin:6px 0;color:var(--f3)}
#toast{position:fixed;top:70px;right:12px;z-index:20;background:#2a2008;border:1px solid var(--g);padding:10px 14px;border-radius:10px;display:none;max-width:80vw}
footer{text-align:center;color:var(--mu);font-size:12px;margin-top:20px}footer a{color:var(--f2)}
.login{max-width:360px;margin:12vh auto;padding:0 16px;text-align:center}
.ov{position:fixed;inset:0;z-index:50;background:#000c;display:flex;align-items:center;justify-content:center;padding:14px}
.ov .card{width:100%;max-width:520px;max-height:92vh;overflow-y:auto;margin:0;border-color:var(--g2)}
.ov .ir{display:flex;justify-content:space-between;gap:10px;padding:7px 0;border-bottom:1px solid var(--line);word-break:break-all}.ov .ir b{color:var(--g);font-weight:500;text-align:right}
</style></head><body><div class="flames"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><s style="left:60%;animation-delay:3.5s;animation-duration:4.7s;width:3px;height:3px"></s><s style="left:68%;animation-delay:3.4s;animation-duration:3.1s;width:4px;height:3px"></s><s style="left:83%;animation-delay:2.5s;animation-duration:3.0s;width:3px;height:3px"></s><s style="left:21%;animation-delay:0.4s;animation-duration:4.5s;width:4px;height:4px"></s><s style="left:8%;animation-delay:2.4s;animation-duration:3.6s;width:3px;height:4px"></s><s style="left:81%;animation-delay:2.6s;animation-duration:4.1s;width:4px;height:2px"></s><s style="left:10%;animation-delay:0.1s;animation-duration:4.7s;width:4px;height:2px"></s><s style="left:62%;animation-delay:1.3s;animation-duration:4.0s;width:2px;height:4px"></s><s style="left:32%;animation-delay:2.6s;animation-duration:3.8s;width:4px;height:2px"></s><s style="left:61%;animation-delay:2.6s;animation-duration:3.6s;width:4px;height:2px"></s><s style="left:93%;animation-delay:1.0s;animation-duration:4.4s;width:4px;height:3px"></s><s style="left:6%;animation-delay:0.3s;animation-duration:4.4s;width:3px;height:2px"></s><s style="left:40%;animation-delay:1.5s;animation-duration:4.9s;width:4px;height:2px"></s><s style="left:30%;animation-delay:0.8s;animation-duration:4.8s;width:3px;height:3px"></s></div><div id="toast"></div><div id="app"></div>
<script>
const $=s=>document.querySelector(s),A=$("#app");let tab="core",me=null,role="user",lrole="admin",ws=null,timer=null;
const e=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function toast(m,bad){const t=$("#toast");t.textContent=m;t.style.borderColor=bad?"var(--bad)":"var(--g)";t.style.display="block";setTimeout(()=>t.style.display="none",3500)}
async function api(p,m="GET",b){const r=await fetch("/api/"+p,{method:m,headers:{"Content-Type":"application/json","X-Panel":"1"},body:b?JSON.stringify(b):undefined});const j=await r.json().catch(()=>({}));if(r.status==401&&p!="login"){me=null;return boot()}if(!r.ok)throw new Error(j.error||"Error");return j}
const go=f=>async(...a)=>{try{await f(...a)}catch(x){toast(x.message,1)}};
const gb=b=>(b/1073741824).toFixed(1)+" GB",val=id=>$("#"+id).value;
const dur=s=>s>=86400?Math.floor(s/86400)+"d "+Math.floor(s%86400/3600)+"h":s>=3600?Math.floor(s/3600)+"h "+Math.floor(s%3600/60)+"m":Math.max(0,Math.floor(s/60))+"m "+(s%60)+"s";
const seen=t=>t?new Date(t*1000).toLocaleString():"never";
const foot=`<footer>Created by <b style="color:var(--g)">ALIRAZA</b> &nbsp;|&nbsp; Support: <a href="https://t.me/ar_tricks" target="_blank" rel="noopener">@ar_tricks</a></footer>`;
const copyTxt=async t=>{try{await navigator.clipboard.writeText(t)}catch(_){const a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();document.execCommand("copy");a.remove()}toast("Copied")};
async function showInfo(x){const o=await api("overview"),c=o.cfg,h=c.domain||o.ip,gbl=x.gb||"Unlimited",
pl=`GET /artricks HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`,
all=`Domain: ${h}\nUsername: ${x.u}\nPassword: ${x.p}\nSSH Port: ${c.ssh_port} (also 109, 447)\nWS (HTTP): 80\nWS+SSL: 443\nExpiry: ${x.exp||"-"}\nIP Limit: ${x.ip}\nData Limit: ${gbl}\n\nPayload:\n${pl}`,
r=(k,v)=>`<div class="ir"><span class="k">${k}</span><b>${e(v)}</b></div>`;
document.querySelectorAll(".ov").forEach(n=>n.remove());
const d=document.createElement("div");d.className="ov";
d.innerHTML=`<div class="card"><h2>&#9989; Account created</h2>${r("Username",x.u)}${r("Domain",h)}${r("Expires",x.exp||"-")}
<div id="fi" style="display:none">${r("Password",x.p)}${r("SSH port",c.ssh_port+" (also 109, 447)")}${r("WS (HTTP)","80")}${r("WS + SSL","443")}${r("IP limit",x.ip)}${r("Data limit",gbl)}<div class="k" style="margin-top:10px">Payload</div><pre class="c">${e(pl)}</pre></div>
<br><div class="row" style="justify-content:flex-start"><button class="f" id="fb">Full info</button><button class="s" id="cb">Copy all</button><button class="s" id="xb">Close</button></div></div>`;
document.body.appendChild(d);
const close=()=>{d.remove();document.removeEventListener("keydown",esc)},esc=ev=>{if(ev.key=="Escape")close()};document.addEventListener("keydown",esc);
d.onclick=ev=>{if(ev.target===d)close()};$("#xb").onclick=close;$("#cb").onclick=()=>copyTxt(all);
$("#fb").onclick=()=>{const f=$("#fi"),on=f.style.display=="none";f.style.display=on?"block":"none";$("#fb").textContent=on?"Hide info":"Full info"}}
async function boot(){const j=await fetch("/api/me").then(r=>r.json());me=j.u;role=j.role||"user";document.body.classList.toggle("ro",role!="admin");if(role!="admin"&&!["core","on","acc"].includes(tab))tab="core";me?shell():loginView()}
function loginView(){A.innerHTML=`<div class="login"><div class="brand" style="font-size:34px"><span class="logo">🔥</span> ALIRAZA</div><div style="color:var(--f2);margin-bottom:18px">SSH Management Panel</div><div class="card" style="text-align:left"><div class="rt"><button type="button" id="ra" class="${lrole=="admin"?"on":""}">Admin</button><button type="button" id="ru" class="${lrole=="user"?"on":""}">User (view only)</button></div><label>Username</label><input id="lu" autocomplete="username"><label>Password</label><input id="lp" type="password" autocomplete="current-password"><br><br><button class="f" style="width:100%" id="lb">Sign in</button></div>${foot}</div>`;
$("#ra").onclick=()=>{lrole="admin";loginView()};$("#ru").onclick=()=>{lrole="user";loginView()};$("#lb").onclick=go(async()=>{await api("login","POST",{u:val("lu"),p:val("lp"),role:lrole});boot()});$("#lp").onkeydown=ev=>{if(ev.key=="Enter")$("#lb").click()}}
const TABS={core:"Core",on:"Online",acc:"Accounts",ban:"Banner",tg:"Telegram Bot",set:"Settings"};
function shell(){A.innerHTML=`<header><div class="brand"><span class="logo">🔥</span> ALIRAZA<small>SSH Management Panel</small></div><div class="sp"></div><span class="b ${role=="admin"?"on1":"mu1"}">${role=="admin"?"ADMIN":"VIEW ONLY"}</span><button class="s" id="lo">Logout (${e(me)})</button></header><nav>${Object.entries(TABS).filter(([k])=>role=="admin"||["core","on","acc"].includes(k)).map(([k,v])=>`<a tabindex="0" data-t="${k}">${v}</a>`).join("")}</nav><main id="m"></main>`;
document.querySelectorAll("nav a").forEach(a=>{a.onclick=()=>{tab=a.dataset.t;view()};a.onkeydown=ev=>{if(ev.key=="Enter")a.click()}});$("#lo").onclick=async()=>{await api("logout","POST");boot()};view()}
function view(){clearInterval(timer);if(ws){ws.close();ws=null}document.querySelectorAll("nav a").forEach(a=>a.classList.toggle("on",a.dataset.t==tab));const m=$("#m");m.innerHTML="";go(V[tab])(m)}
const V={
async core(m){const draw=async()=>{const o=await api("overview"),c=o.cfg,h=c.domain||o.ip;const pct=(a)=>Math.round(a[0]/a[1]*100);
m.innerHTML=`<div class="card"><h2>VPS info</h2><div class="grid"><div><div class="k">Host / OS</div>${e(o.host)}<br>${e(o.os)}</div><div><div class="k">Public IP</div><div class="v">${e(o.ip||"-")}</div></div><div><div class="k">Uptime</div><div class="v">${Math.floor(o.up/86400)}d ${Math.floor(o.up%86400/3600)}h</div></div><div><div class="k">Load</div><div class="v">${o.load.map(x=>x.toFixed(2)).join(" ")}</div></div>
<div><div class="k">CPU (${o.cores} cores)</div><div class="v">${o.cpu}%</div><div class="bar"><i style="width:${o.cpu}%"></i></div></div><div><div class="k">RAM ${gb(o.ram[0])} / ${gb(o.ram[1])}</div><div class="v">${pct(o.ram)}%</div><div class="bar"><i style="width:${pct(o.ram)}%"></i></div></div><div><div class="k">Disk ${gb(o.disk[0])} / ${gb(o.disk[1])}</div><div class="v">${pct(o.disk)}%</div><div class="bar"><i style="width:${pct(o.disk)}%"></i></div></div><div><div class="k">Traffic in / out</div>${gb(o.rx)} / ${gb(o.tx)}</div></div></div>
<div class="card"><h2>SSH account info</h2><div class="grid"><div><div class="k">Host</div>${e(h)}</div><div><div class="k">SSH port</div><div class="v">${c.ssh_port}</div></div><div><div class="k">WS / WS+SSL</div>80 / 443</div><div><div class="k">Accounts / online</div><div class="v">${o.users} / ${o.online}</div></div></div><div class="k" style="margin-top:10px">Payload</div><pre class="c">GET /artricks HTTP/1.1[crlf]Host: ${e(h)}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]</pre></div>
<div class="card"><h2>Services</h2><div class="tw"><table>${Object.entries(o.svc).map(([s,a])=>`<tr><td>${s}</td><td><span class="b ${a?"on1":"off1"}">${a?"running":"stopped"}</span></td><td class="wr"><button class="s" data-s="${s}">Restart</button></td></tr>`).join("")}</table></div><br><button class="f wr" id="fx">Fix SSH / WS connection</button></div>${foot}`;
m.querySelectorAll("[data-s]").forEach(b=>b.onclick=go(async()=>{await api(`service/${b.dataset.s}/restart`,"POST");toast("Restarted "+b.dataset.s);draw()}));$("#fx").onclick=go(async()=>{await api("fix","POST");toast("Connection fixed");draw()})};await draw();timer=setInterval(()=>go(draw)(),8000)},
async acc(m){m.innerHTML=`<div class="card wr"><h2>Add account</h2><div class="row"><div><label>Username (kuch bhi likho)</label><input id="au" autocomplete="off" placeholder="any name / symbols"></div><div><label>Password (kuch bhi likho)</label><input id="ap" autocomplete="off" placeholder="any password"></div><div><label>Days</label><input id="ad" type="number" value="30"></div><div><label>IP limit</label><input id="ai" type="number" value="1"></div><div><label>Data limit GB (blank = unlimited)</label><input id="ag"></div></div><br><button class="f" id="aa">Create account</button></div>
<div class="card"><h2>Accounts <span class="k" id="cnt"></span></h2><div class="row"><div><input id="q" placeholder="Search username or IP"></div><div><select id="f"><option value="all">All</option><option value="on">Online</option><option value="off">Offline</option><option value="lock">Locked</option><option value="exp">Expired</option></select></div><div class="wr" style="flex:0 0 auto;min-width:0"><button class="s" id="cx">Delete expired</button></div></div><div class="tw"><table id="tb"></table></div></div>
<div class="card wr" id="ed" style="display:none"><h2>Edit <span id="en"></span></h2><div class="row"><div><label>New password</label><input id="ep"></div><div><label>Renew (days from today)</label><input id="ey" type="number"></div><div><label>IP limit</label><input id="ei" type="number"></div><div><label>Data limit GB</label><input id="eg"></div></div><br><div class="row" style="justify-content:flex-start"><button id="es">Save &amp; unlock</button><button class="s" id="el">Lock</button><button class="s" id="er">Reset usage</button></div></div>`;
let L=[];
const status=a=>!a.exists?"missing":a.locked?"locked":a.expired?"expired":a.online?"online":"offline";
const cls={online:"on1",offline:"mu1",locked:"off1",expired:"off1",missing:"off1"};
const paint=()=>{const q=val("q").toLowerCase(),f=val("f");
const rows=L.filter(a=>(!q||a.u.toLowerCase().includes(q)||a.ips.some(i=>i.includes(q)))&&(f=="all"||(f=="on"&&a.online)||(f=="off"&&!a.online)||(f=="lock"&&a.locked)||(f=="exp"&&a.expired)));
$("#cnt").textContent=`(${rows.length}/${L.length} shown, ${L.filter(a=>a.online).length} online)`;
$("#tb").innerHTML=`<tr><th>User</th><th>Status</th><th>Online IPs</th><th>Expires</th><th>Data</th><th>Last seen</th><th class="wr"></th></tr>`+(rows.map(a=>{const s=status(a);return `<tr data-u="${e(a.u)}"><td>${e(a.u)}</td><td><span class="b ${cls[s]}">${s}</span></td><td>${a.ips.map(e).join("<br>")||"-"}<div class="k">${a.online}/${e(a.ip)} sessions</div></td><td>${e(a.exp)}${a.days!=null?` (${a.days<0?"expired":a.days+"d left"})`:""}</td><td>${a.used}/${e(a.gb)} GB</td><td>${a.online?"now":seen(a.last)}</td><td class="wr" style="white-space:nowrap"><button class="s" data-a="e">Edit</button> ${a.online?`<button class="s" data-a="k">Kick</button> `:""}<button class="s" data-a="l" data-v="${a.locked?0:1}">${a.locked?"Unlock":"Lock"}</button> <button class="d" data-a="d">Delete</button></td></tr>`}).join("")||`<tr><td colspan="7">No accounts match.</td></tr>`)};
const load=async()=>{L=await api("accounts");paint()};
const edit=u=>{const a=L.find(x=>x.u==u)||{};$("#ed").style.display="block";$("#en").textContent=u;$("#ep").value="";$("#ey").value="";$("#ei").value=a.ip??"";$("#eg").value=a.gb=="Unlimited"?"":(a.gb??"");$("#ed").scrollIntoView();const body=x=>({p:val("ep"),days:val("ey"),ip:val("ei"),gb:val("eg"),...x});
$("#es").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({lock:false}));toast("Saved");load()});$("#el").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({lock:true}));toast("Locked");load()});$("#er").onclick=go(async()=>{await api("accounts/"+u,"PUT",body({reset:true,lock:false}));toast("Usage reset");load()})};
$("#aa").onclick=go(async()=>{const x={u:val("au"),p:val("ap"),days:val("ad"),ip:val("ai"),gb:val("ag")};await api("accounts","POST",x);toast("Account created");await load();const a=L.find(r=>r.u==x.u)||{};["au","ap","ag"].forEach(i=>$("#"+i).value="");await showInfo({...x,exp:a.exp})});
$("#q").oninput=paint;$("#f").onchange=paint;
$("#cx").onclick=go(async()=>{if(confirm("Delete ALL expired accounts?")){const r=await api("accounts/cleanup","POST");toast("Deleted "+r.deleted+" account(s)");load()}});
$("#tb").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const u=b.closest("tr").dataset.u,k=b.dataset.a;
if(k=="e")return edit(u);
if(k=="k"){await api("kick","POST",{u});toast("Kicked "+u);return load()}
if(k=="l"){await api("accounts/"+u,"PUT",{lock:b.dataset.v=="1"});toast(b.dataset.v=="1"?"Locked "+u:"Unlocked "+u);return load()}
if(k=="d"&&confirm("Delete "+u+"?")){await api("accounts/"+u,"DELETE");toast("Deleted "+u);load()}});
await load();timer=setInterval(()=>go(load)(),6000)},
async on(m){m.innerHTML=`<div class="card"><h2>Online sessions <span class="k" id="oc"></span></h2><div class="row"><div><input id="oq" placeholder="Filter by username or IP"></div><div style="flex:0 0 auto;min-width:0"><button class="s" id="orf">Refresh now</button></div></div><div class="tw"><table id="ot"></table></div><div class="k" style="margin-top:8px">Updates every 5 seconds. Kick ends a session; lock the account in the Accounts tab to stop reconnects.</div></div>`;
let S=[];
const paint=()=>{const q=val("oq").toLowerCase(),r=S.filter(x=>!q||x.u.includes(q)||x.ip.includes(q));
$("#ot").innerHTML=`<tr><th>User</th><th>Client IP</th><th>Via</th><th>Connected</th><th>PID</th><th class="wr"></th></tr>`+(r.map(x=>`<tr data-p="${e(x.pid)}" data-u="${e(x.u)}" data-i="${e(x.ip)}"><td>${e(x.u)}</td><td>${e(x.ip)}</td><td>${x.via=="ws"?"WebSocket":"SSH direct"}</td><td>${dur(x.secs)}</td><td>${e(x.pid)}</td><td class="wr" style="white-space:nowrap"><button class="s" data-a="p">Kick session</button> <button class="s" data-a="u">Kick user</button> <button class="d" data-a="i">Kick IP</button></td></tr>`).join("")||`<tr><td colspan="6">Nobody is online right now.</td></tr>`)};
const load=async()=>{const r=await api("sessions");S=r.sessions;$("#oc").textContent=`(${r.sessions.length} sessions, ${r.users} users, ${r.ips} IPs)`;paint()};
$("#oq").oninput=paint;$("#orf").onclick=go(load);
$("#ot").onclick=go(async ev=>{const b=ev.target.closest("button");if(!b)return;const t=b.closest("tr"),k=b.dataset.a,body=k=="p"?{pid:t.dataset.p}:k=="u"?{u:t.dataset.u}:{ip:t.dataset.i};if(k!="p"&&!confirm("Kick all matching sessions?"))return;const r=await api("kick","POST",body);toast("Kicked "+r.killed+" session(s)");load()});
await load();timer=setInterval(()=>go(load)(),5000)},
async ban(m){const b=await api("banner");m.innerHTML=`<div class="card"><h2>SSH banner</h2><div class="k">HTML is allowed (for example &lt;font color="green"&gt;). Applies to new connections.</div><textarea id="bt" rows="10">${e(b.t)}</textarea><br><br><button class="f" id="bs">Save banner</button> <button class="s" id="bc">Clear</button></div>${foot}`;$("#bs").onclick=go(async()=>{await api("banner","PUT",{t:val("bt")});toast("Banner saved")});$("#bc").onclick=go(async()=>{$("#bt").value="";await api("banner","PUT",{t:""});toast("Banner cleared")})},
async tg(m){const draw=async(a)=>{const t=await api("tg"+(a?"?act="+a:""));m.innerHTML=`<div class="card"><h2>Telegram bot</h2><span class="b ${t.active?"on1":"off1"}">${t.active?"running":"stopped"}</span> ${t.token?`&nbsp; token ${e(t.token)} &nbsp; admin ${e(t.admin)}`:""}<div class="row" style="margin-top:12px;justify-content:flex-start"><button class="s" data-a="restart">Restart</button><button class="s" data-a="stop">Stop</button><button class="s" data-a="start">Start</button></div></div><div class="card"><h3>Connect bot</h3><label>Bot token (from @BotFather)</label><input id="tt"><label>Super admin Telegram ID</label><input id="ta" type="number"><br><br><button class="f" id="tc">Connect &amp; start</button></div>${foot}`;
m.querySelectorAll("[data-a]").forEach(b=>b.onclick=go(()=>draw(b.dataset.a)));$("#tc").onclick=go(async()=>{const r=await api("tg","POST",{token:val("tt"),admin:val("ta")});toast(r.ok?"Bot connected":"Failed: "+r.msg,!r.ok);draw()})};await draw()},
async set(m){const[o,ad]=await Promise.all([api("overview"),api("admins")]),c=o.cfg;m.innerHTML=`<div class="card"><h2>Ports &amp; domain</h2><div class="row"><div><label>Panel port</label><input id="sp" type="number" value="${c.panel_port}"></div><div><label>SSH port</label><input id="ss" type="number" value="${c.ssh_port}"></div><div><label>Domain</label><input id="sd" value="${e(c.domain)}"></div></div><label><input type="checkbox" id="sl" style="width:auto"> Issue Let's Encrypt SSL for a changed domain (DNS must point here)</label><br><button class="f" id="sv">Apply</button><div class="k" style="margin-top:8px">Changing the SSH port restarts Dropbear and disconnects live sessions. After a panel-port change, open the new port.</div></div>
<div class="card"><h2>Panel logins</h2><div class="tw"><table>${ad.map(a=>`<tr><td>${e(a.u)}</td><td><span class="b ${a.role=="admin"?"on1":"mu1"}">${a.role=="admin"?"admin":"user (view only)"}</span></td><td><button class="s" data-p="${e(a.u)}">Change password</button> <button class="d" data-x="${e(a.u)}">Delete</button></td></tr>`).join("")}</table></div><div class="row"><div><label>Username</label><input id="nu"></div><div><label>Password</label><input id="np" type="password"></div><div><label>Type</label><select id="nr"><option value="user">User (view only)</option><option value="admin">Admin (full access)</option></select></div></div><br><button id="nc">Create login</button> <button class="s" id="nn">Change my username</button></div>${foot}`;
$("#sv").onclick=go(async()=>{const r=await api("settings","POST",{panel_port:val("sp"),ssh_port:val("ss"),domain:val("sd"),ssl:$("#sl").checked});toast("Applied. "+r.msg);if(r.cfg.panel_port!=location.port*1&&location.port)setTimeout(()=>location.port=r.cfg.panel_port,4000)});
const ad_=go(async(b)=>{const r=await api("admin","POST",b);toast("Done");view()});$("#nc").onclick=()=>ad_({act:"create",u:val("nu"),p:val("np"),role:val("nr")});
$("#nn").onclick=()=>ad_({act:"rename",u:me,new:val("nu")});m.querySelectorAll("[data-p]").forEach(b=>b.onclick=()=>{const p=prompt("New password for "+b.dataset.p);p&&ad_({act:"password",u:b.dataset.p,p})});m.querySelectorAll("[data-x]").forEach(b=>b.onclick=()=>confirm("Delete login?")&&ad_({act:"delete",u:b.dataset.x}))}};
boot();
</script></body></html>
UI_EOF
python3 -m venv /opt/aliraza-panel/venv && /opt/aliraza-panel/venv/bin/pip install -q flask flask-sock gunicorn psutil || { echo -e "${R}Panel libraries failed to install (pip). Check internet and re-run.${N}"; exit 1; }
echo -e "${Y}[4/6] Telegram bot libraries (background)...${N}"
( python3 -m venv /opt/rr-tgbot-venv && /opt/rr-tgbot-venv/bin/pip install -q "python-telegram-bot==20.7" ) &>/var/log/aliraza-tgvenv.log &
echo -e "${Y}[5/6] Config, SSL and Dropbear...${N}"
echo "{\"domain\":\"$DOMAIN\",\"panel_port\":$PP,\"ssh_port\":$SP}" > /etc/artricks/panel.json; echo "$DOMAIN" > /etc/artricks/domain.conf
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=$DOMAIN" -keyout /etc/artricks/ssl/self.key -out /etc/artricks/ssl/self.crt 2>/dev/null
systemctl stop nginx 2>/dev/null
certbot certonly --standalone --preferred-challenges http --agree-tos --register-unsafely-without-email -n -d "$DOMAIN" || echo -e "${R}SSL failed - using self-signed (browser warning). Retry later from Settings.${N}"
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
printf '#!/bin/sh\nsystemctl stop nginx\n' > /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh
printf '#!/bin/sh\nsystemctl start nginx\n' > /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/pre/aliraza-nginx.sh /etc/letsencrypt/renewal-hooks/post/aliraza-nginx.sh
cd /opt/aliraza-panel
ADMIN_U="$AU" ADMIN_P="$AP" ./venv/bin/python - <<'PYI'
import os,app
from werkzeug.security import generate_password_hash as g
c=app.db();c.execute("delete from admins");c.execute("insert into admins(u,p,role) values(?,?,'admin')",(os.environ["ADMIN_U"],g(os.environ["ADMIN_P"])));c.commit()
print(app.apply_dropbear());print(app.apply_nginx())
PYI
echo -e "${Y}[6/6] Starting services...${N}"
if command -v ufw >/dev/null && ufw status | grep -q active; then for p in 80 443 $PP $SP 109 447; do ufw allow $p/tcp; done; fi
systemctl daemon-reload; systemctl enable --now ws-proxy autokill aliraza-panel; systemctl restart nginx
echo -e "${Y}Waiting for Telegram bot libraries to finish...${N}"; wait
echo -e "\n${G}==================== INSTALLED ====================${N}"
echo -e " Panel URL : ${Y}https://$DOMAIN:$PP${N}"
echo -e " Username  : ${Y}$AU${N}"
echo -e " Password  : ${Y}$AP${N}   (login on the 'Admin' tab)"
echo -e " View-only users: Settings > Panel logins > Type 'User (view only)', they log in on the 'User' tab"
echo -e " SSH port  : ${Y}$SP${N} (also 109, 447) | WS 80 | WS+SSL 443"
sleep 2
echo -e "\n${Y}--- Self-check ---${N}"
BAD=0
for svc in nginx dropbear ws-proxy autokill aliraza-panel; do
  if systemctl is-active --quiet $svc; then echo -e " ${G}[OK]${N}   service $svc"; else echo -e " ${R}[FAIL]${N} service $svc"; BAD=1; journalctl -u $svc -n 8 --no-pager 2>/dev/null | cut -c1-160; fi
done
for prt in $PP $SP 109 447 80 443 12026 2082; do
  if ss -tln 2>/dev/null | grep -q ":$prt "; then echo -e " ${G}[OK]${N}   port $prt listening"; else echo -e " ${R}[FAIL]${N} port $prt not listening"; BAD=1; fi
done
CODE=$(curl -sk -o /dev/null -m 6 -w '%{http_code}' "https://127.0.0.1:$PP/" 2>/dev/null)
if [[ "$CODE" == "200" ]]; then echo -e " ${G}[OK]${N}   panel answers locally (HTTP 200)"; else echo -e " ${R}[FAIL]${N} panel local test (HTTP ${CODE:-none})"; BAD=1; fi
IDENT=$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/109; head -n1 <&3' 2>/dev/null | tr -d '\r')
if [[ "$IDENT" == "SSH-2.0-AliRaza-server" ]]; then echo -e " ${G}[OK]${N}   SSH ident: $IDENT"; else echo -e " ${R}[WARN]${N} SSH ident: ${IDENT:-unknown} (custom build missing, see /var/log/aliraza-dropbear-build.log)"; fi
echo -e "${Y}Open in your VPS provider's cloud firewall (TCP): 80, 443, $PP, $SP, 109, 447${N}"
[[ $BAD -eq 0 ]] && echo -e "${G}All checks passed.${N}" || echo -e "${R}Some checks failed - send the lines above to support.${N}"
echo -e " Created by ALIRAZA | Support: https://t.me/ar_tricks"
echo -e "${G}===================================================${N}"
