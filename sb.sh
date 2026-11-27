#!/usr/bin/env bash
# 通用 sing-box 管理工具，面向 Debian/Ubuntu systemd, sing-box 1.14.x
set -uo pipefail
umask 077
VERSION=2.2.22
C=/etc/sing-box/config.json
D=/var/lib/sing-box
B=/root/sb-backups
META=/etc/sing-box/sb-host
BASE=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite

# Color is presentation only; prompts must not contaminate captured values.
ui_color(){ [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; }
paint(){ local c=$1; shift; if ui_color; then printf '\033[%sm%s\033[0m' "$c" "$*"; else printf '%s' "$*"; fi; }
ui_title(){ printf '\n'; paint '1;36' "==== $* ===="; printf '\n'; }
ui_prompt(){ if [[ -t 2 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then printf '\033[1;36m%s\033[0m' "$1"; else printf '%s' "$1"; fi; }
msg(){ printf '\n[%s] %s\n' "$1" "$2"; }
err(){ msg ERROR "$*" >&2; return 1; }
ask(){ local a; read -rp "$1 [$2]: " a || return 1; printf '%s' "${a:-$2}"; }
secret(){ local a; read -rsp "$1: " a; echo >&2; printf '%s' "$a"; }
confirm(){ local a; read -rp "$1 [y/N]: " a; [[ $a == y || $a == Y ]]; }
need(){ local x; for x in "$@"; do command -v "$x" >/dev/null || { err "缺少 $x，请先安装依赖"; return 1; }; done; }
port(){ [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
virt(){ systemd-detect-virt 2>/dev/null || :; }
# Architecture and host capability detection; no configuration changes.
env_arch(){ case $(uname -m) in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) uname -m;; esac; }
env_os(){ ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-未知 Linux}" ); }
env_preflight(){
 local a os da
 a=$(env_arch); os=$( . /etc/os-release 2>/dev/null; echo "${ID:-unknown}" )
 [[ $a == amd64 || $a == arm64 ]] || { err "未验证的 CPU 架构: $a"; return 1; }
 [[ $os == debian || $os == ubuntu ]] || { err "仅支持 Debian/Ubuntu: $os"; return 1; }
 need apt-get dpkg systemctl || return 1
 da=$(dpkg --print-architecture) || return 1
 [[ $da == "$a" ]] || { err "内核与软件包架构不一致: $a / $da"; return 1; }
 [[ -d /run/systemd/system ]] && systemctl show --property=Version --value >/dev/null 2>&1 || { err 'systemd 不可用'; return 1; }
}
env_report(){
 local x a
 a=$(env_arch)
 ui_title '系统环境检测'
 printf '操作系统：%s\nCPU 架构：%s (%s)\n内核：%s\n虚拟化：%s\n' "$(env_os)" "$a" "$(uname -m)" "$(uname -r)" "$(virt)"
 printf '软件包架构：%s\n' "$(dpkg --print-architecture 2>/dev/null || echo unknown)"
 if [[ -d /run/systemd/system ]] && systemctl show --property=Version --value >/dev/null 2>&1; then echo 'systemd：可用'; else echo 'systemd：不可用'; fi
 free -h 2>/dev/null || :; df -h / /var/lib 2>/dev/null || :
 for x in curl jq openssl python3 ip ss systemctl sing-box cloudflared; do
  if command -v "$x" >/dev/null; then printf '%s: OK\n' "$x"; else printf '%s: 未安装\n' "$x"; fi
 done
 if command -v sing-box >/dev/null; then sing-box version; fi
 bbr_status || :
 printf 'Argo 服务：%s\n' "$(systemctl is-active sb-argo.service 2>/dev/null || :)"
}
ARGO_UNIT=/etc/systemd/system/sb-argo.service
ARGO_DIR=/etc/sb-argo
ARGO_DROP=/etc/systemd/system/sb-argo.service.d
ARGO_NET=$ARGO_DROP/network.conf
# A registration log is historical evidence, not a live connection count.
argo_metrics(){
 local pid log addr
 pid=$(systemctl show sb-argo.service -p MainPID --value 2>/dev/null) || return 1
 [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
 log=$(journalctl -u sb-argo.service "_PID=$pid" -b --no-pager -o cat 2>/dev/null) || return 1
 addr=$(sed -nE 's/.*Starting metrics server on (127\.0\.0\.1:[0-9]+)\/metrics.*/\1/p' <<< "$log" | tail -1)
 [[ -n $addr ]] || return 1
 printf '%s\n' "$addr"
}
argo_ready(){
 local addr
 systemctl is-active --quiet sb-argo.service || return 1
 addr=$(argo_metrics) || return 1
 curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 "http://$addr/ready" >/dev/null 2>&1
}
argo_health(){
 local pid log n addr live execargs ipver proto
 if ! systemctl is-active --quiet sb-argo.service; then echo '连接器：未运行'; return 1; fi
 pid=$(systemctl show sb-argo.service -p MainPID --value 2>/dev/null) || return 1
 log=$(journalctl -u sb-argo.service "_PID=$pid" -b --no-pager -o cat 2>/dev/null) || log=''
 n=$(sed -nE '/Registered tunnel connection/s/.*connIndex=([0-9]+).*/\1/p' <<< "$log" | sort -u | wc -l)
 execargs=$(systemctl show sb-argo.service -p ExecStart --value 2>/dev/null)
 ipver=$(sed -nE 's/.*--edge-ip-version[ =]+(auto|4|6)([ ;]|$).*/\1/p' <<< "$execargs"); ipver=${ipver:-默认}
 proto=$(sed -nE 's/.*--protocol[ =]+(auto|quic|http2)([ ;]|$).*/\1/p' <<< "$execargs"); proto=${proto:-auto}
 printf '连接器：运行中 | IP 版本：%s | 配置协议：%s\n' "$ipver" "$proto"
 printf '本次进程曾注册连接：%s / 4（非实时数量）\n' "$n"
 if addr=$(argo_metrics); then
  live=$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 "http://$addr/metrics" 2>/dev/null | awk '$1=="cloudflared_tunnel_ha_connections"{print $2;exit}') || live=''
  [[ -z $live ]] || printf '当前活动连接指标：%s\n' "$live"
 fi
 if [[ -s $C ]]; then jq -r '.inbounds[]|select(.tag=="argo-vless-in")|"本地入站：\(.listen):\(.listen_port)"' "$C" 2>/dev/null; fi
 if argo_ready; then msg OK '隧道实时 readiness 检查通过'; return 0; fi
 echo '隧道实时健康尚未确认（可能仍在注册，或 metrics 不可用）'
 return 1
}
argo_wait(){
 local i
 for ((i=0;i<30;i++)); do
  systemctl is-active --quiet sb-argo.service || return 1
  argo_ready && return 0
  sleep 1
 done
 return 1
}
argo_status(){ systemctl status sb-argo.service --no-pager -l; argo_health; }
argo_network_set() (
 local field=${1:-both} bin current ipver proto w other
 [[ -s $ARGO_UNIT && -s $ARGO_DIR/token ]] || { err '请先配置 Argo'; exit 1; }
 bin=$(command -v cloudflared) || exit 1
 [[ $bin =~ ^/[A-Za-z0-9_./-]+$ ]] || exit 1
 current=$(systemctl show sb-argo.service -p ExecStart --value) || exit 1
 ipver=$(sed -nE 's/.*--edge-ip-version[ =]+(auto|4|6)([ ;]|$).*/\1/p' <<< "$current"); ipver=${ipver:-4}
 proto=$(sed -nE 's/.*--protocol[ =]+(auto|quic|http2)([ ;]|$).*/\1/p' <<< "$current"); proto=${proto:-auto}
 for other in "$ARGO_DROP"/*.conf; do
  [[ -f $other && $other != "$ARGO_NET" ]] || continue
  if grep -Eq '^[[:space:]]*ExecStart[[:space:]]*=' "$other"; then err "存在其他 ExecStart 覆盖：$other，请手动处理"; exit 1; fi
 done
 if [[ -f $ARGO_NET ]]; then
  if grep -Evq '^[[:space:]]*(#.*|;.*|\[Service\]|ExecStart=|ExecStart=/[^[:space:]]+/cloudflared tunnel --no-autoupdate( --edge-ip-version (auto|4|6)| --protocol (auto|quic|http2)| --metrics 127\.0\.0\.1:[0-9]+)* run --token-file /etc/sb-argo/token|)$' "$ARGO_NET"; then err 'network.conf 含自定义内容，拒绝覆盖'; exit 1; fi
 fi
 case $field in
 ip) ipver=$(ask '边缘 IP 版本 auto/4/6' "$ipver") || exit 1;;
 protocol) proto=$(ask '传输协议 auto/quic/http2' "$proto") || exit 1;;
 repair) ipver=4; proto=auto;;
 *) exit 1;;
 esac
 [[ $ipver == auto || $ipver == 4 || $ipver == 6 ]] && [[ $proto == auto || $proto == quic || $proto == http2 ]] || { err '参数无效'; exit 1; }
 confirm "设置 IP 版本 $ipver / $proto，重启 Argo 并验证实时健康，失败恢复旧配置?" || exit 0
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 local active=0 had=0
 systemctl is-active --quiet sb-argo.service && active=1
 if [[ -f $ARGO_NET ]]; then cp -a "$ARGO_NET" "$w/old" || exit 1; had=1; fi
 mkdir -p "$ARGO_DROP" || exit 1
 cat > "$w/new" <<UNIT
[Service]
ExecStart=
ExecStart=$bin tunnel --no-autoupdate --edge-ip-version $ipver --protocol $proto run --token-file $ARGO_DIR/token
UNIT
 install -m 644 "$w/new" "$ARGO_NET" || exit 1
 if systemctl daemon-reload && systemctl restart sb-argo.service && argo_wait; then msg OK '网络参数已应用，隧道实时健康检查通过'; argo_health; exit 0; fi
 echo '新配置未通过实时健康检查，恢复原配置。'
 if ((had)); then cp -a "$w/old" "$ARGO_NET" || exit 1; else rm -f "$ARGO_NET" || exit 1; fi
 systemctl daemon-reload || exit 1
 if ((active)); then systemctl restart sb-argo.service || exit 1; else systemctl stop sb-argo.service || exit 1; fi
 err '新配置未确认成功，已尝试恢复旧设置'
)
argo_network_test(){
 local region addr
 need getent nc || return 1
 for region in region1 region2; do
  printf '\n=== %s IPv4 TCP 7844 ===\n' "$region"
  while IFS= read -r addr; do
   [[ -n $addr ]] || continue
   nc -4 -z -w 3 "$addr" 7844 && printf '%s: OK\n' "$addr" || printf '%s: FAIL\n' "$addr"
  done < <(getent ahostsv4 "$region.v2.argotunnel.com" | awk '{print $1}' | sort -u)
 done
 echo 'UDP/QUIC 是否成功以 cloudflared 当前进程预检查和注册日志为准：'
 local pid; pid=$(systemctl show sb-argo.service -p MainPID --value 2>/dev/null) || return 1
 journalctl -u sb-argo.service "_PID=$pid" -b --no-pager -o cat | grep -Ei 'UDP Connectivity|TCP Connectivity|precheck complete|Registered tunnel connection' | tail -30 || :
}
argo_public_test() (
 local w host
 [[ -s $ARGO_DIR/meta.json && -s $C ]] || { err '未配置 Argo'; exit 1; }
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 host=$(jq -er '.hostname' "$ARGO_DIR/meta.json") || exit 1
 jq -e --arg h "$host" '.inbounds[]|select(.tag=="argo-vless-in" and .transport.type=="ws")|{type:"vless",tag:"argo-public-test",server:$h,server_port:443,uuid:.users[0].uuid,tls:{enabled:true,server_name:$h},transport:{type:"ws",path:.transport.path,headers:{Host:$h}}}' "$C" > "$w/o" || exit 1
 echo '通过公网域名建立真实 VLESS WS TLS 连接并查询出口 IP；不修改正式配置。'
 probe "$w/o"
)
argo_start_checked(){
 local action=$1
 systemctl "$action" sb-argo.service || return 1
 if argo_wait; then argo_health; else err '连接器已启动，但隧道实时健康未确认'; return 1; fi
}
argo_install_core(){
 env_preflight || return 1
 command -v cloudflared >/dev/null && { cloudflared --version; return; }
 confirm '添加 Cloudflare 官方 APT 仓库并安装 cloudflared?' || return 1
 apt-get update && apt-get install -y ca-certificates curl || return 1
 local k; k=$(mktemp) || return 1
 if ! curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o "$k"; then rm -f "$k"; return 1; fi
 install -m 644 "$k" /usr/share/keyrings/sb-cloudflare.gpg && rm -f "$k" || return 1
 local list=/etc/apt/sources.list.d/sb-cloudflared.list
 if [[ -e $list ]]; then
  grep -Fxq 'deb [signed-by=/usr/share/keyrings/sb-cloudflare.gpg] https://pkg.cloudflare.com/cloudflared any main' "$list" || { err 'APT 配置已存在且不同'; return 1; }
 else
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/sb-cloudflare.gpg] https://pkg.cloudflare.com/cloudflared any main' > "$list" || return 1
 fi
 apt-get update && apt-get install -y cloudflared && { install -d -m 700 /var/lib/sb-manager && touch /var/lib/sb-manager/cloudflared-installed; }
}
argo_setup() (
 local w p host path uuid token bin
 [[ -s $C ]] || { err '请先安装 sing-box 服务'; exit 1; }
 [[ ! -e $ARGO_UNIT && ! -e $ARGO_DIR ]] || { err '已存在 Argo 管理配置，拒绝覆盖'; exit 1; }
 jq -e 'any(.inbounds[];.tag=="argo-vless-in")' "$C" >/dev/null && { err 'argo-vless-in 已存在'; exit 1; }
 argo_install_core || exit 1
 bin=$(command -v cloudflared) || exit 1
 [[ $bin =~ ^/[A-Za-z0-9_./-]+$ ]] || exit 1
 cloudflared tunnel run --help 2>&1 | grep -q -- '--token-file' || { err 'cloudflared 不支持 token-file，请升级'; exit 1; }
 p=$(ask '本地 WS TCP 端口' 18080) || exit 1; port "$p" || exit 1; p=$((10#$p))
 jq -e --argjson p "$p" 'any(.inbounds[];.listen_port==$p and .type!="hysteria2")' "$C" >/dev/null && { err '端口冲突'; exit 1; }
 [[ -z $(ss -H -lnt "sport = :$p") ]] || { err '端口已被占用'; exit 1; }
 host=$(ask 'Cloudflare 已配置的公网域名' '') || exit 1
 [[ $host =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err '域名无效'; exit 1; }
 path=$(ask 'WebSocket 路径' "/$(openssl rand -hex 12)") || exit 1
 [[ $path =~ ^/[A-Za-z0-9_/-]+$ ]] || { err '路径无效'; exit 1; }
 printf '请在 Cloudflare Tunnel 控制台设置公开应用：%s → HTTP http://127.0.0.1:%s\n' "$host" "$p"
 read -rs -p '粘贴 Tunnel connector token（不回显）: ' token || exit 1; echo
 [[ $token =~ ^[A-Za-z0-9_+/=-]+$ ]] || { err '令牌格式无效'; exit 1; }
 uuid=$(sing-box generate uuid) || exit 1
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 jq --argjson p "$p" --arg path "$path" --arg u "$uuid" '.inbounds += [{type:"vless",tag:"argo-vless-in",listen:"127.0.0.1",listen_port:$p,users:[{name:"client",uuid:$u}],transport:{type:"ws",path:$path}}]' "$C" > "$w/new" || exit 1
 confirm '添加独立 VLESS WS 入站并启动固定 Argo 隧道？sing-box 将重启' || exit 0
 mkdir -m 700 "$ARGO_DIR" || exit 1
 printf '%s' "$token" > "$ARGO_DIR/token"; unset token
 chmod 600 "$ARGO_DIR/token" || exit 1
 jq -n --arg host "$host" '{hostname:$host}' > "$ARGO_DIR/meta.json" || exit 1
 cat > "$ARGO_UNIT" <<UNIT
[Unit]
Description=sb-manager Cloudflare Tunnel
After=network-online.target sing-box.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=$bin tunnel --no-autoupdate --edge-ip-version 4 --protocol auto run --token-file $ARGO_DIR/token
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
 if ! apply "$w/new"; then rm -f "$ARGO_UNIT" "$ARGO_DIR/token" "$ARGO_DIR/meta.json"; rmdir "$ARGO_DIR"; exit 1; fi
 if systemctl daemon-reload && systemctl enable --now sb-argo.service; then
  if argo_wait; then msg OK '隧道实时健康检查通过'; else echo '警告：连接器已启动，但隧道实时健康尚未确认'; fi
  argo_info
 else err '连接器启动失败；入站已添加，请检查日志或使用删除功能'; exit 1; fi
)
argo_info(){
 [[ -s $ARGO_DIR/meta.json ]] || { err '未配置 Argo'; return 1; }
 python3 - "$C" "$ARGO_DIR/meta.json" <<'PYARGO'
import json,sys
from urllib.parse import urlencode
c=json.load(open(sys.argv[1])); h=json.load(open(sys.argv[2]))["hostname"]
for i in c["inbounds"]:
 if i.get("tag")=="argo-vless-in":
  for u in i["users"]:
   q=urlencode(dict(encryption="none",security="tls",type="ws",sni=h,host=h,path=i["transport"]["path"]))
   print("vless://"+u["uuid"]+"@"+h+":443?"+q+"#argo-vless")
PYARGO
}
argo_remove(){
 [[ -f $ARGO_UNIT ]] || { err '未安装本工具管理的 Argo'; return 1; }
 if jq -e 'any(.inbounds[];.tag=="argo-vless-in")' "$C" >/dev/null; then
  [[ $(jq '.inbounds|length' "$C") -gt 1 ]] || { err '至少保留一个入站'; return 1; }
  if jq -e 'del(.inbounds[]|select(.tag=="argo-vless-in"))|any(..|strings;.=="argo-vless-in")' "$C" >/dev/null || { [[ -s $POLICY ]] && jq -e 'any(..|strings;.=="argo-vless-in")' "$POLICY" >/dev/null; }; then err 'Argo 入站仍被配置引用'; return 1; fi
  confirm '删除本地 Argo 入站及连接器服务？不删除 Cloudflare 云端隧道' || return 0
  edit '.inbounds |= map(select(.tag!="argo-vless-in"))' || return 1
 else confirm '删除本地连接器服务?' || return 0; fi
 systemctl disable --now sb-argo.service || return 1
 rm -f "$ARGO_UNIT" "$ARGO_DIR/token" "$ARGO_DIR/meta.json" "$ARGO_NET" || return 1; rmdir "$ARGO_DIR" "$ARGO_DROP" 2>/dev/null || :
 systemctl daemon-reload
}
# Read-only stability diagnostics; no automatic tuning of kernel or live services.
argo_log_stats(){
 local period log
 period=$(ask '统计最近多少分钟（1-1440）' 30) || return 1
 [[ $period =~ ^[0-9]{1,4}$ ]] && ((10#$period>=1 && 10#$period<=1440)) || { err '时间范围无效'; return 1; }
 log=$(journalctl -u sb-argo.service --since "$((10#$period)) minutes ago" --no-pager -o cat) || return 1
 printf '最近 %s 分钟 Cloudflared 日志事件（非实际断线次数）：\n' "$period"
 printf '隧道注册：%s\n' "$(grep -ic 'Registered tunnel connection' <<< "$log" || :)"
 printf '连接服务失败：%s\n' "$(grep -icE 'failed to serve tunnel connection|serve tunnel error' <<< "$log" || :)"
 printf '超时：%s\n' "$(grep -icE 'timeout|no recent network activity' <<< "$log" || :)"
 printf '重试：%s\n' "$(grep -icE 'retrying connection|retrying in' <<< "$log" || :)"
 printf '错误/警告：%s\n' "$(grep -icE ' (ERR|WRN) ' <<< "$log" || :)"
 echo '最近相关日志：'
 grep -Ei ' (ERR|WRN) |timeout|retrying|registered tunnel connection' <<< "$log" | tail -40 || :
}
argo_tcp_quality(){
 local seconds before after
 need nstat ss || return 1
 seconds=$(ask '采样间隔秒数（1-60）' 10) || return 1
 [[ $seconds =~ ^[0-9]{1,2}$ ]] && ((10#$seconds>=1 && 10#$seconds<=60)) || return 1
 sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
 ss -s
 before=$(nstat -asz) || return 1
 sleep "$((10#$seconds))"
 after=$(nstat -asz) || return 1
 python3 -c 'import sys
def parse(s):
 return {x[0]:int(x[1]) for l in s.splitlines() if len(x:=l.split())>=2 and x[1].isdigit()}
a,b=map(parse,sys.argv[1:])
keys=["TcpOutSegs","TcpRetransSegs","TcpExtTCPTimeouts"]
for k in keys:
 print(k, b[k]-a[k] if k in a and k in b and b[k]>=a[k] else "N/A")
if all(k in a and k in b for k in keys[:2]) and b["TcpOutSegs"]>a["TcpOutSegs"] and b["TcpRetransSegs"]>=a["TcpRetransSegs"]:
 print("TCP 重传段/发送段近似比率：%.2f%%"%(100*(b["TcpRetransSegs"]-a["TcpRetransSegs"])/(b["TcpOutSegs"]-a["TcpOutSegs"])))' "$before" "$after"
 echo '以上是整个系统 TCP 统计，不是 QUIC 丢包率，也不是单个 YouTube 连接。'
}
argo_video_diagnose(){
 local log host
 log=$(journalctl -u sing-box --since '30 minutes ago' --no-pager -o cat) || return 1
 echo '最近 30 分钟视频相关日志（最多 40 行）：'
 grep -Ei 'googlevideo\.com|youtube\.com' <<< "$log" | tail -40 || :
 echo '近期视频域名 VPS 直连 HTTPS 测试（不经过 Argo）：'
 while IFS= read -r host; do
  [[ $host =~ ^[A-Za-z0-9.-]+\.googlevideo\.com$ ]] || continue
  printf '%s ' "$host"
  curl -4 --noproxy '*' -sS -o /dev/null --connect-timeout 5 --max-time 12 -w 'HTTP %{http_code} DNS %{time_namelookup}s TCP %{time_connect}s TLS %{time_appconnect}s 总计 %{time_total}s\n' "https://$host/" || :
 done < <(grep -Eo '[A-Za-z0-9.-]+\.googlevideo\.com' <<< "$log" | sort -u | head -5)
 echo 'CDN 根路径返回 403/404 不代表视频播放失败；此测试不验证真实视频分片。'
 echo '同期 sing-box 错误（可能包含其他客户端）：'
 grep -Ei 'ERROR|broken pipe|reset by peer|i/o timeout' <<< "$log" | tail -25 || :
}
argo_repeat_probe(){
 local n i ok=0 fail=0
 n=$(ask '重复公网节点测试次数（1-10）' 3) || return 1
 [[ $n =~ ^[0-9]{1,2}$ ]] && ((10#$n>=1 && 10#$n<=10)) || return 1
 for ((i=1;i<=10#$n;i++)); do
  printf '\n=== 公网端到端测试 %s/%s ===\n' "$i" "$n"
  if argo_public_test; then ((ok+=1)); else ((fail+=1)); fi
  if ((i<10#$n)); then sleep 2; fi
 done
 printf '成功：%s 失败：%s\n' "$ok" "$fail"
 echo '重复短请求不等于持续视频长连接测试。'
 ((fail==0))
}
argo_stability_monitor(){
 echo '同时显示 Argo 与 sing-box 实时日志；Ctrl+C 退出。'
 journalctl -u sb-argo.service -u sing-box.service -n 20 -f -o short-iso | grep --line-buffered -Ei 'googlevideo|youtube|ERR|WRN|timeout|reset|broken pipe|EOF|closed|registered|retry'
}
argo_stability_menu(){
 local n
 while true; do
 ui_title 'Argo 稳定性诊断'
 columns '01 查看隧道日志统计|02 YouTube CDN 诊断|03 TCP 网络质量' '04 重复公网节点测试|05 双服务实时日志|06 切换 QUIC/HTTP2'
 echo '00 返回'
 read -rp "$(ui_prompt '请选择操作：')" n || return
 case $n in
  1|01) argo_log_stats;; 2|02) argo_video_diagnose;; 3|03) argo_tcp_quality;; 4|04) argo_repeat_probe;; 5|05) argo_stability_monitor;; 6|06) argo_network_set protocol;; 0|00) return;; *) err '无效选项';;
 esac
 done
}
argo_menu(){
 local n
 while true; do ui_title 'Argo 固定隧道管理'
 argo_health || :
 columns '01 安装连接器|02 配置固定隧道及 WS 入站|03 查看隧道状态|04 查看分享链接|05 启动连接器|06 停止连接器|07 实时日志' '08 删除本地隧道|09 重启连接器|10 设置传输协议|11 设置 IP 版本|12 网络环境检测|13 公网节点测试|14 IPv4 自动修复'
 columns '15 稳定性诊断' '00 返回'
 read -rp "$(ui_prompt '请选择操作：')" n || return
 case $n in
  1|01) argo_install_core;; 2|02) argo_setup;; 3|03) argo_status;; 4|04) argo_info;;
  5|05) argo_start_checked start;; 6|06) systemctl stop sb-argo.service;; 7|07) journalctl -u sb-argo.service -n 30 -f;; 8|08) argo_remove;;
  9|09) argo_start_checked restart;; 10) argo_network_set protocol;; 11) argo_network_set ip;; 12) argo_network_test;; 13) argo_public_test;; 14) argo_network_set repair;; 15) argo_stability_menu;;
  0|00) return;; *) err '无效选项';;
 esac
 done
}

install_core(){
 env_preflight || return 1
 apt-get update && apt-get install -y --no-install-recommends ca-certificates curl jq openssl iproute2 netcat-openbsd python3 procps || return 1
 local f; f=$(mktemp); curl -fsSL https://sing-box.app/install.sh -o "$f" && bash "$f"; local rc=$?; rm -f "$f"; ((rc==0)) || return "$rc"
 sing-box version; systemctl enable sing-box
}
backup(){ mkdir -p "$B"; local f; f=$(mktemp -d "$B/$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1; cp -a /etc/sing-box "$f/" || return 1; if [[ -f $POLICY ]]; then cp -a "$POLICY" "$f/sb-policy.json" || return 1; fi; printf '%s\n' "$f"; }
check(){ sing-box check -c "$1"; }
permissions(){
 local u g; u=$(systemctl show sing-box -p User --value); u=${u:-root}; g=$(systemctl show sing-box -p Group --value); g=${g:-$(id -gn "$u")}
 mkdir -p "$D" /etc/sing-box; chown "$u:$g" "$D"; chmod 750 "$D"; chown root:"$g" /etc/sing-box; chmod 750 /etc/sing-box
 if [[ -f $C ]]; then chown root:"$g" "$C"; chmod 640 "$C"; fi
 if [[ -d /etc/sing-box/cert ]]; then chown root:"$g" /etc/sing-box/cert; chmod 750 /etc/sing-box/cert; find /etc/sing-box/cert -maxdepth 1 -type f \( -name '*.key' -o -name 'privkey.pem' \) -exec chown root:"$g" {} + -exec chmod 640 {} +; find /etc/sing-box/cert -maxdepth 1 -type f -name fullchain.pem -exec chmod 644 {} +; fi
}
apply(){
 local new=$1 old='' stage was=0; policy_migrate || return 1; check "$new" || return 1; systemctl is-active --quiet sing-box && was=1
 if [[ -f $C ]]; then old=$(backup) || return 1; fi
 mkdir -p /etc/sing-box; stage=$(mktemp /etc/sing-box/.config.XXXXXX) || return 1; cp "$new" "$stage" && mv "$stage" "$C" || return 1
 if permissions && sing-box check -C /etc/sing-box && systemctl restart sing-box && sleep 2 && systemctl is-active --quiet sing-box; then msg OK "配置已应用，备份 ${old:-无（首次安装）}"; return 0; fi
 journalctl -u sing-box -n 25 --no-pager; if [[ -n $old ]]; then cp -a "$old/sing-box/config.json" "$C"; else rm -f "$C"; fi
 if ((was)); then systemctl restart sing-box || :; else systemctl stop sing-box || :; fi; err '应用失败，已尝试回滚'
}
edit(){ local f rc; f=$(mktemp); jq "$@" "$C" > "$f" && apply "$f"; rc=$?; rm -f "$f"; return "$rc"; }
cert(){
 local p=/etc/sing-box/cert; mkdir -p "$p"; if [[ -s $p/fullchain.pem && -s $p/privkey.pem && ! -e $p/server.key ]]; then err "检测到旧证书 privkey.pem；请使用维护菜单，不要重新初始化，或先备份并迁移证书"; return 1; fi; if [[ -s $p/fullchain.pem && -s $p/server.key ]]; then return 0; fi
 if [[ -e $p/fullchain.pem || -e $p/server.key ]]; then err '证书文件不完整，拒绝覆盖'; return 1; fi
 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 -subj "/CN=$1" -addext "subjectAltName=DNS:$1" -keyout "$p/server.key" -out "$p/fullchain.pem" || return 1; permissions
}
pin(){ openssl x509 -in "$1" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A; }
public_key(){ python3 - "$1" <<'PY'
import sys,base64,subprocess
s=sys.argv[1]; raw=base64.urlsafe_b64decode(s+'='*(-len(s)%4)); assert len(raw)==32
p=subprocess.check_output(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=bytes.fromhex('302e020100300506032b656e04220420')+raw)
print(base64.urlsafe_b64encode(p[-32:]).decode().rstrip('='))
PY
}
rules(){ jq -n --arg base "$BASE" '{http_clients:[{tag:"rule-download"}],route:{default_http_client:"rule-download",default_domain_resolver:"local-dns",rule_set:([ ["geosite-ai","category-ai-!cn"],["geosite-crypto","category-cryptocurrency"],["geosite-tiktok","tiktok"] ]|map({type:"remote",tag:.[0],format:"binary",url:($base+"/"+.[1]+".srs"),update_interval:"24h"})),rules:[{action:"sniff"},{ip_is_private:true,action:"reject"},{rule_set:["geosite-ai","geosite-crypto","geosite-tiktok"],outbound:"relay-out"},{domain_suffix:["openai.com","chatgpt.com","oaistatic.com","oaiusercontent.com","claude.ai","anthropic.com","gemini.google.com","aistudio.google.com","generativelanguage.googleapis.com","grok.com","perplexity.ai","poe.com","binance.com","okx.com","bybit.com","bitget.com","coinbase.com","metamask.io","etherscan.io","tiktok.com","tiktokcdn.com"],outbound:"relay-out"},{action:"resolve"},{ip_is_private:true,action:"reject"}],final:"direct"}}'; }
# VLESS TCP, with REALITY or verified TLS. Never require a shared password.
make_vless(){
 local f=$1 host=$2 p=$3 old=$4 uuid flow security sni pub sid fp prior='{}' default_security=reality
 if [[ -f $old ]] && jq -e '.type=="vless"' "$old" >/dev/null; then
  prior=$(cat "$old") || return 1
  if jq -e '.transport != null and .transport.type != "tcp"' <<< "$prior" >/dev/null; then err '现有 VLESS 非 TCP 传输暂不支持编辑'; return 1; fi
  if jq -e '.tls.enabled==true and .tls.reality.enabled!=true' <<< "$prior" >/dev/null; then default_security=tls; fi
 fi
 uuid=$(secret 'VLESS UUID（编辑同协议时回车保留）') || return 1
 [[ -n $uuid ]] || uuid=$(jq -r '.uuid // ""' <<< "$prior")
 [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { err 'UUID 格式不正确'; return 1; }
 security=$(ask '安全类型 reality/tls' "$default_security") || return 1
 case $security in reality|tls) ;; *) err '安全类型不支持'; return 1;; esac
 local default_flow=none
 [[ $security == reality ]] && default_flow=xtls-rprx-vision
 flow=$(ask 'Flow xtls-rprx-vision/none' "$(jq -r --arg d "$default_flow" 'if has("flow") then (if .flow=="" then "none" else .flow end) else $d end' <<< "$prior")") || return 1
 case $flow in none) flow='';; xtls-rprx-vision) ;; *) err 'Flow 不支持'; return 1;; esac
 sni=$(ask 'TLS SNI / server_name' "$(jq -r '.tls.server_name // ""' <<< "$prior")") || return 1
 [[ -n $sni ]] || { err 'SNI 必填'; return 1; }
 if [[ $security == reality ]]; then
  pub=$(ask 'REALITY PublicKey（公钥）' "$(jq -r '.tls.reality.public_key // ""' <<< "$prior")") || return 1
  [[ $pub =~ ^[A-Za-z0-9_-]{43}$ ]] || { err 'REALITY 公钥格式不正确'; return 1; }
  sid=$(ask 'REALITY Short ID（十六进制，可为空；输入 none 清空）' "$(jq -r '.tls.reality.short_id // ""' <<< "$prior")") || return 1
  [[ $sid != none ]] || sid=''
  [[ $sid =~ ^[[:xdigit:]]{0,16}$ ]] && (( ${#sid} % 2 == 0 )) || { err 'Short ID 必须为偶数长度的十六进制字符串，最多16字符'; return 1; }
  fp=$(ask 'uTLS 指纹' "$(jq -r '.tls.utls.fingerprint // "chrome"' <<< "$prior")") || return 1
  [[ -n $fp ]] || return 1
  jq -n --arg h "$host" --argjson p "$p" --arg id "$uuid" --arg flow "$flow" --arg s "$sni" --arg k "$pub" --arg sid "$sid" --arg fp "$fp" '{type:"vless",tag:"relay-out",server:$h,server_port:$p,uuid:$id,flow:$flow,domain_resolver:{server:"local-dns",strategy:"ipv4_only"},tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:$fp},reality:{enabled:true,public_key:$k,short_id:$sid}}}' > "$f"
 else
  jq -n --arg h "$host" --argjson p "$p" --arg id "$uuid" --arg flow "$flow" --arg s "$sni" '{type:"vless",tag:"relay-out",server:$h,server_port:$p,uuid:$id,flow:$flow,domain_resolver:{server:"local-dns",strategy:"ipv4_only"},tls:{enabled:true,server_name:$s,insecure:false}}' > "$f"
 fi
}
make_snell(){
 local f=$1 host=$2 p=$3 old=$4 prior='{}' v psk userkey mode obfs oh reuse
 if [[ -f $old ]] && jq -e '.type=="snell"' "$old" >/dev/null; then prior=$(cat "$old") || return 1; fi
 v=$(ask 'Snell 客户端版本 4/6（v5 服务端使用 4）' "$(jq -r '.version // 6' <<< "$prior")") || return 1
 [[ $v == 4 || $v == 6 ]] || { err '仅支持官方核心出站版本 4/6'; return 1; }
 psk=$(secret 'Snell PSK（编辑时回车保留）') || return 1
 [[ -n $psk ]] || psk=$(jq -r '.psk // ""' <<< "$prior")
 [[ -n $psk ]] || { err 'PSK 必填'; return 1; }
 if [[ $v == 6 ]]; then
  local bytes; bytes=$(printf '%s' "$psk" | wc -c)
  ((bytes>=12 && bytes<=255)) || { err 'v6 PSK 长度必须为12至255字节'; return 1; }
 fi
 userkey=$(secret '多用户 userkey（可选，回车保留，none 清除）') || return 1
 [[ -n $userkey ]] || userkey=$(jq -r '.userkey // ""' <<< "$prior")
 [[ $userkey != none ]] || userkey=''
 reuse=$(ask '连接复用 true/false' "$(jq -r '.reuse // false' <<< "$prior")") || return 1
 [[ $reuse == true || $reuse == false ]] || return 1
 if [[ $v == 6 ]]; then
  mode=$(ask '流量整形 default/unshaped' "$(jq -r '.mode // "default"' <<< "$prior")") || return 1
  [[ $mode == default || $mode == unshaped ]] || { err '不支持该整形模式'; return 1; }
  jq -n --arg h "$host" --argjson p "$p" --arg psk "$psk" --arg u "$userkey" --arg mode "$mode" --argjson reuse "$reuse" '{type:"snell",tag:"relay-out",server:$h,server_port:$p,version:6,psk:$psk,mode:$mode,reuse:$reuse,domain_resolver:{server:"local-dns",strategy:"ipv4_only"}}+ (if $u=="" then {} else {userkey:$u} end)' > "$f"
 else
  obfs=$(ask 'HTTP 混淆 none/http' "$(jq -r '.obfs_mode // "none"' <<< "$prior")") || return 1
  [[ $obfs == none || $obfs == http ]] || return 1
  oh=''; if [[ $obfs == http ]]; then oh=$(ask '混淆 Host' "$(jq -r '.obfs_host // "bing.com"' <<< "$prior")") || return 1; fi
  jq -n --arg h "$host" --argjson p "$p" --arg psk "$psk" --arg u "$userkey" --arg obfs "$obfs" --arg oh "$oh" --argjson reuse "$reuse" '{type:"snell",tag:"relay-out",server:$h,server_port:$p,version:4,psk:$psk,obfs_mode:$obfs,reuse:$reuse,domain_resolver:{server:"local-dns",strategy:"ipv4_only"}}+(if $u=="" then {} else {userkey:$u} end)+(if $oh=="" then {} else {obfs_host:$oh} end)' > "$f"
 fi
}
snell_inbound(){
 local cfg=$1 out=$2 p v psk mode obfs
 p=$(ask 'Snell TCP 监听端口' 8443) || return 1; port "$p" || return 1; p=$((10#$p))
 jq -e --argjson p "$p" 'any(.inbounds[];.listen_port==$p and .type!="hysteria2")' "$cfg" >/dev/null && { err 'Snell TCP 端口与现有入站冲突'; return 1; }
 v=$(ask 'Snell 服务端版本 5/6' 6) || return 1
 [[ $v == 5 || $v == 6 ]] || { err '服务端仅支持5/6'; return 1; }
 psk=$(openssl rand -hex 24) || return 1
 if [[ $v == 6 ]]; then
  mode=$(ask '流量整形 default/unshaped' default) || return 1
  [[ $mode == default || $mode == unshaped ]] || return 1
  jq --argjson p "$p" --arg k "$psk" --arg m "$mode" '.inbounds += [{type:"snell",tag:"snell-in",listen:"0.0.0.0",listen_port:$p,version:6,psk:$k,mode:$m}]' "$cfg" > "$out"
 else
  obfs=$(ask 'HTTP 混淆 none/http' none) || return 1
  [[ $obfs == none || $obfs == http ]] || return 1
  jq --argjson p "$p" --arg k "$psk" --arg m "$obfs" '.inbounds += [{type:"snell",tag:"snell-in",listen:"0.0.0.0",listen_port:$p,version:5,psk:$k,obfs_mode:$m}]' "$cfg" > "$out"
 fi
}
add_snell() (
 local w; [[ -s $C ]] || { err '请先初始化'; exit 1; }
 jq -e 'any(.inbounds[];.tag=="snell-in")' "$C" >/dev/null && { err 'snell-in 已存在'; exit 1; }
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 snell_inbound "$C" "$w/config.json" || exit 1
 confirm '添加 Snell 入站（将检查配置并重启服务）?' || exit 0
 apply "$w/config.json" && info
)
make_relay(){
 local f=$1 type host p pw sni key method old=${2:-} default=anytls
 [[ -f $old ]] && default=$(jq -r '.type' "$old")
 type=$(ask '协议 anytls/shadowsocks/hysteria2/vless/snell' "$default") || return 1
 case $type in anytls) p=59007;; shadowsocks) p=18834;; hysteria2) p=21196;; vless) p=443;; snell) p=8443;; *) err '协议错误'; return 1;; esac
 host=$(ask '落地公网域名/IP' "$( [[ -f $old ]] && jq -r '.server' "$old" || echo landing.example.com )") || return 1
 if [[ -f $old && $(jq -r '.type' "$old") == "$type" ]]; then p=$(jq -r '.server_port' "$old"); fi
 p=$(ask '公网端口' "$p"); port "$p" || return 1; p=$((10#$p))
 if [[ $type == snell ]]; then
  make_snell "$f" "$host" "$p" "$old"
  return $?
 fi
 if [[ $type == vless ]]; then
  make_vless "$f" "$host" "$p" "$old"
  return $?
 fi
 pw=$(secret '中转密码（同协议回车保留）'); if [[ -z $pw && -f $old && $(jq -r '.type' "$old") == "$type" ]]; then pw=$(jq -r '.password' "$old"); fi; [[ -n $pw ]] || return 1
 if [[ $type == shadowsocks ]]; then
 method=$(ask '加密算法' '2022-blake3-aes-128-gcm'); jq -n --arg h "$host" --argjson p "$p" --arg pw "$pw" --arg m "$method" '{type:"shadowsocks",tag:"relay-out",server:$h,server_port:$p,password:$pw,method:$m,domain_resolver:{server:"local-dns",strategy:"ipv4_only"}}' > "$f"
 else
 sni=$(ask 'TLS SNI' "$( [[ -f $old ]] && jq -r '.tls.server_name // "landing-proxy.example.com"' "$old" || echo landing-proxy.example.com )"); key=$(ask '证书公钥 SHA256 Base64' "$( [[ -f $old ]] && jq -r '.tls.certificate_public_key_sha256[0] // ""' "$old" || : )"); [[ $key =~ ^[A-Za-z0-9+/]{43}=$ ]] || { err '指纹格式不正确'; return 1; }
 jq -n --arg t "$type" --arg h "$host" --argjson p "$p" --arg pw "$pw" --arg s "$sni" --arg k "$key" '{type:$t,tag:"relay-out",server:$h,server_port:$p,password:$pw,domain_resolver:{server:"local-dns",strategy:"ipv4_only"},tls:{enabled:true,server_name:$s,certificate_public_key_sha256:[$k]}}' > "$f"
 if [[ $type == hysteria2 ]]; then
 local obfs tmp; obfs=$(secret 'Salamander 混淆密码（无则回车，同协议保留旧值）'); if [[ -z $obfs && -f $old && $(jq -r '.type' "$old") == hysteria2 ]]; then obfs=$(jq -r '.obfs.password // ""' "$old"); fi; if [[ -n $obfs ]]; then tmp=$(mktemp); jq --arg pw "$obfs" '.obfs={type:"salamander",password:$pw}' "$f" > "$tmp" && mv "$tmp" "$f" || return 1; fi
 fi
 fi
}
probe() (
 local ob=$1 expected=${2:-} w pid='' p ip; w=$(mktemp -d); trap '[[ -z $pid ]] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; rm -rf "$w"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
 for p in 10889 10890 10891 10892; do [[ -z $(ss -H -lnt "sport = :$p") ]] && break; done; [[ -z $(ss -H -lnt "sport = :$p") ]] || exit 1
 jq -n --slurpfile o "$ob" --argjson p "$p" '{log:{level:"debug"},dns:{servers:[{type:"local",tag:"local-dns"}],final:"local-dns"},inbounds:[{type:"mixed",tag:"test-in",listen:"127.0.0.1",listen_port:$p}],outbounds:[$o[0]],route:{default_domain_resolver:"local-dns",final:$o[0].tag}}' > "$w/config.json" || exit 1
 check "$w/config.json" || exit 1; sing-box run -D "$w" -c "$w/config.json" > "$w/log" 2>&1 & pid=$!; sleep 2; kill -0 "$pid" || { cat "$w/log"; exit 1; }
 for url in https://api.ipify.org https://ipinfo.io/ip; do
 ip=$(curl -fsS --noproxy '' --proxy "socks5h://127.0.0.1:$p" --connect-timeout 12 --max-time 25 "$url") || continue; ip=$(tr -d '[:space:]' <<< "$ip"); echo "出口IP: $ip"; if [[ -z $expected || $expected == "$ip" ]]; then python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$ip" && exit 0; fi
 done; cat "$w/log"; exit 1
)
legacy_change_relay() (
 local w expected tag; tag=$(relay_tag) || { err "未配置中转出站"; exit 1; }; w=$(mktemp -d); trap 'rm -rf "$w"' EXIT; jq -e --arg tag "$tag" '.outbounds[]|select(.tag==$tag)' "$C" > "$w/old" || exit 1; make_relay "$w/new" "$w/old" || exit 1; jq --slurpfile old "$w/old" '.tag=$old[0].tag' "$w/new" > "$w/tagged" && mv "$w/tagged" "$w/new" || exit 1; expected=$(ask '预期落地出口IP（必填）' ''); [[ -n $expected ]] || exit 1; probe "$w/new" "$expected" || exit 1; confirm '测试成功，应用配置?' || exit 0; edit --slurpfile o "$w/new" '(.outbounds[]|select(.tag==$o[0].tag))=$o[0]'
)
legacy_relay() ( local w tag; tag=$(relay_tag) || { err "未配置中转出站"; exit 1; }; w=$(mktemp -d); trap 'rm -rf "$w"' EXIT; jq -e --arg tag "$tag" '.outbounds[]|select(.tag==$tag)' "$C" > "$w/o" && probe "$w/o" "${1:-}"; )
# Detect the VPS egress IP directly, without using shell proxy variables.
detect_public_ip(){
 local family url ip
 command -v curl >/dev/null && command -v python3 >/dev/null || return 1
 for family in 4 6; do
  if [[ $family == 4 ]]; then
   local -a urls=(https://api.ipify.org https://ipv4.icanhazip.com)
  else
   local -a urls=(https://api6.ipify.org https://ipv6.icanhazip.com)
  fi
  for url in "${urls[@]}"; do
   ip=$(curl -"$family" --noproxy '*' -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null) || continue
   ip=$(printf '%s' "$ip" | python3 -c 'import sys,ipaddress
try:
 a=ipaddress.ip_address(sys.stdin.read().strip())
 assert a.is_global and not a.is_multicast
 print(a)
except (ValueError,AssertionError): sys.exit(1)') || continue
   printf '%s\n' "$ip"; return 0
  done
 done
 return 1
}
public_address_prompt(){
 local saved='' detected='' default='' h
 if [[ -s $META ]]; then IFS= read -r saved < "$META" || :; fi
 printf '正在检测 VPS 公网出口 IP（优先 IPv4）...\n' >&2
 detected=$(detect_public_ip) || :
 if [[ -n $detected ]]; then printf '检测到公网出口 IP：%s\n' "$detected" >&2; else printf '公网 IP 检测失败，可手动填写。\n' >&2; fi
 if [[ -n $saved ]]; then
  default=$saved
  printf '保留已保存的连接地址：%s；输入 auto 使用本次检测结果。\n' "$saved" >&2
 else default=$detected; fi
 printf '注意：NAT VPS 的出口 IP 不一定等于入站连接地址。\n' >&2
 h=$(ask '本机对外连接地址（公网IP/域名，auto 自动获取）' "$default") || return 1
 if [[ $h == auto ]]; then h=$detected; fi
 [[ -n $h ]] || { err '无法获取公网地址，请手动填写'; return 1; }
 h=$(printf '%s' "$h" | python3 -c 'import sys,ipaddress,re
s=sys.stdin.read().strip()
if s.startswith("[") and s.endswith("]"): s=s[1:-1]
try:
 print(ipaddress.ip_address(s))
except ValueError:
 if len(s)>253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?",p) for p in s.rstrip(".").split(".")) or "." not in s or re.fullmatch(r"[0-9.]+",s): sys.exit(1)
 print(s.rstrip("."))') || { err '公网地址格式无效'; return 1; }
 printf '%s\n' "$h"
}
set_public_address(){
 local h
 h=$(public_address_prompt) || return 1
 mkdir -p "$(dirname "$META")" || return 1
 printf '%s\n' "$h" > "$META" || return 1
 msg OK "公网连接地址已设置为 $h"
}
init_role() (
 local role=$1 w host sni hp ap rp ssport hy any relaypw sskey reality keys priv pub uuid sid; w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
 need sing-box jq openssl python3 || exit 1
 if [[ -f $C ]]; then confirm '已有配置，重新初始化将替换入站及密码，确认?' || exit 0; fi
 host=$(public_address_prompt) || exit 1
 if [[ $role != landing ]]; then hp=443; ap=59007; else hp=21196; ap=59007; fi
 hp=$(ask 'HY2 UDP 监听端口' "$hp"); ap=$(ask 'AnyTLS TCP 监听端口' "$ap"); port "$hp" && port "$ap" || exit 1; hp=$((10#$hp)); ap=$((10#$ap))
 sni=$(ask '自签证书 SNI' "$role-proxy.example.com"); [[ $sni =~ ^[A-Za-z0-9.-]+$ ]] || exit 1; cert "$sni" || exit 1
 hy=$(openssl rand -hex 24); any=$(openssl rand -hex 24); relaypw=$(openssl rand -hex 24)
 jq -n --arg s "$sni" --arg h "$hy" --arg a "$any" --arg r "$relaypw" --arg role "$role" --argjson hp "$hp" --argjson ap "$ap" '{log:{level:"info",timestamp:true},dns:{servers:[{type:"local",tag:"local-dns"}],final:"local-dns"},inbounds:[{type:"hysteria2",tag:"hy2-in",listen:"0.0.0.0",listen_port:$hp,users:[{name:"client",password:$h}],tls:{enabled:true,server_name:$s,certificate_path:"/etc/sing-box/cert/fullchain.pem",key_path:"/etc/sing-box/cert/server.key"}},{type:"anytls",tag:"anytls-in",listen:"0.0.0.0",listen_port:$ap,users:([{name:"client",password:$a}]+(if $role=="landing" then [{name:"relay-client",password:$r}] else [] end)),tls:{enabled:true,server_name:$s,certificate_path:"/etc/sing-box/cert/fullchain.pem",key_path:"/etc/sing-box/cert/server.key"}}],outbounds:[{type:"direct",tag:"direct"}],route:{default_domain_resolver:"local-dns",rules:[{action:"sniff"},{ip_is_private:true,action:"reject"},{action:"resolve"},{ip_is_private:true,action:"reject"}],final:"direct"},experimental:{cache_file:{enabled:true,path:"/var/lib/sing-box/cache.db"}}}' > "$w/base" || exit 1
 if [[ $role != landing ]]; then
 rp=$(ask 'REALITY TCP 监听端口' 443); port "$rp" || exit 1; rp=$((10#$rp)); [[ $rp != "$ap" ]] || { err 'TCP端口冲突'; exit 1; }; reality=$(ask 'REALITY TLS目标域名' www.apple.com); keys=$(sing-box generate reality-keypair) || exit 1; priv=$(awk '/PrivateKey/{print $NF}' <<< "$keys"); pub=$(awk '/PublicKey/{print $NF}' <<< "$keys"); [[ -n $priv && -n $pub ]] || exit 1; uuid=$(sing-box generate uuid); sid=$(openssl rand -hex 8)
 if [[ $role == entry ]] && confirm '现在配置落地中转?（否：仅本机直连）'; then
 make_relay "$w/relay" || exit 1; local exp; exp=$(ask '预期落地出口IP' ''); [[ -n $exp ]] || exit 1; probe "$w/relay" "$exp" || exit 1; if confirm '启用预设 AI/Crypto/Web3/TikTok 分流?'; then rules > "$w/rules" || exit 1; else jq -n '{}' > "$w/rules"; fi
 else jq -n '{}' > "$w/rules"; : > "$w/relay"; fi
 jq --slurpfile r "$w/rules" --slurpfile o "$w/relay" --arg target "$reality" --arg key "$priv" --arg uuid "$uuid" --arg sid "$sid" --argjson p "$rp" '. * $r[0] | .outbounds += $o | .inbounds += [{type:"vless",tag:"vless-reality-in",listen:"0.0.0.0",listen_port:$p,users:[{name:"client",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$key,short_id:[$sid]}}}]' "$w/base" > "$w/final" || exit 1
 else
 cp "$w/base" "$w/final"; if confirm '额外启用 SS2022（可选，需上游访问限制）?'; then ssport=$(ask 'SS2022 TCP/UDP 监听端口' 18834); port "$ssport" || exit 1; ssport=$((10#$ssport)); [[ $ssport != "$ap" && $ssport != "$hp" ]] || exit 1; sskey=$(openssl rand -base64 16); jq --arg k "$sskey" --argjson p "$ssport" '.inbounds += [{type:"shadowsocks",tag:"relay-ss-in",listen:"0.0.0.0",listen_port:$p,method:"2022-blake3-aes-128-gcm",password:$k}]' "$w/base" > "$w/final" || exit 1; fi
 fi
 local choice t
 for t in hy2-in anytls-in vless-reality-in; do
   if jq -e --arg t "$t" 'any(.inbounds[];.tag==$t)' "$w/final" >/dev/null; then
     choice=$(ask "启用 $t (y/n)" y) || exit 1
     if [[ $choice == n ]]; then jq --arg t "$t" '.inbounds |= map(select(.tag!=$t))' "$w/final" > "$w/next" && mv "$w/next" "$w/final" || exit 1; fi
   fi
 done
 if confirm '额外启用 Snell 入站?'; then snell_inbound "$w/final" "$w/next" && mv "$w/next" "$w/final" || exit 1; fi
 jq -e '.inbounds|length>0' "$w/final" >/dev/null || { err '至少启用一个入站'; exit 1; }
 apply "$w/final" || exit 1; rm -f "$POLICY"; printf '%s\n' "$host" > "$META"; systemctl enable sing-box; info
)
info(){
 local h; h=$(cat "$META" 2>/dev/null || echo '未设置公网地址'); echo "公网连接地址: $h"; jq -r '.inbounds[]|{type,tag,listen_port,users,password,method,version,psk,mode,obfs_mode,tls:(.tls|if . then {server_name,certificate_path,reality:(.reality|if . then {short_id,handshake} else null end)} else null end)}' "$C"
 local certpath; certpath=$(jq -r '[.inbounds[]|.tls.certificate_path // empty][0] // empty' "$C"); [[ -z $certpath ]] || { printf 'TLS SPKI SHA256 Base64: '; pin "$certpath"; echo; }
 local k; k=$(jq -r '.inbounds[]|.tls.reality.private_key // empty' "$C"); [[ -z $k ]] || { printf 'REALITY PublicKey: '; public_key "$k"; }
 if [[ $h != '未设置公网地址' ]]; then
 python3 - "$C" "$h" <<'PYLINK'
import json,sys,urllib.parse as u,base64,subprocess
c=json.load(open(sys.argv[1])); h=sys.argv[2]; h=f'[{h}]' if ':' in h and not h.startswith('[') else h
for i in c['inbounds']:
 t=i['type']; p=i.get('listen_port'); tls=i.get('tls',{}); s=tls.get('server_name','')
 if t in ('anytls','hysteria2'):
  for user in i.get('users',[]):
   if user.get('name') in ('hk-relay','relay-client'): continue
   print(f"{t}://{u.quote(user['password'],safe='')}@{h}:{p}?{u.urlencode({'sni':s,'insecure':1})}#{i['tag']}")
 elif t=='vless' and tls.get('reality',{}).get('enabled'):
  reality=tls['reality']
  try:
   key=reality['private_key']
   raw=base64.urlsafe_b64decode(key+'='*(-len(key)%4))
   if len(raw)!=32: raise ValueError('invalid X25519 key length')
   der=subprocess.check_output(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],input=bytes.fromhex('302e020100300506032b656e04220420')+raw,stderr=subprocess.DEVNULL)
   pub=base64.urlsafe_b64encode(der[-32:]).decode().rstrip('=')
  except (KeyError,ValueError,OSError,subprocess.CalledProcessError):
   print('警告：无法计算 REALITY 公钥，跳过 VLESS 分享链接',file=sys.stderr)
   continue
  transport=i.get('transport') or {}
  if transport.get('type','tcp')!='tcp':
   print('警告：非 TCP REALITY 入站暂不生成分享链接',file=sys.stderr)
   continue
  ids=reality.get('short_id') or ['']
  for user in i.get('users',[]):
   uuid=user.get('uuid')
   if not uuid: continue
   q={'encryption':'none','security':'reality','sni':s or reality.get('handshake',{}).get('server',''),'fp':'chrome','pbk':pub,'sid':ids[0],'type':'tcp'}
   if user.get('flow'): q['flow']=user['flow']
   name=i.get('tag','vless-reality')+'-'+(user.get('name') or 'client')
   print(f"vless://{u.quote(uuid,safe='')}@{h}:{p}?{u.urlencode(q)}#{u.quote(name,safe='')}")
 elif t=='snell':
  version=4 if i.get('version')==5 else i.get('version',6)
  endpoint=h
  params=[f"snell, {endpoint}, {p}",f"psk={i.get('psk','')}",f"version={version}"]
  if version==4 and i.get('obfs_mode')=='http': params.extend(['obfs=http','obfs-host=bing.com'])
  if version==6: params.append("mode="+i.get('mode','default'))
  print("Snell 参数（Surge 风格，客户端字段可能不同）: "+', '.join(params))
 elif t=='shadowsocks':
  auth=base64.urlsafe_b64encode((i['method']+':'+i['password']).encode()).decode().rstrip('=')
  print(f"ss://{auth}@{h}:{p}#{i['tag']}")
PYLINK
 echo '自签链接中的 insecure=1 仅为兼容部分客户端；优先手动设置上面的公钥指纹。'
 fi
}
reality_test() ( local w key pub; w=$(mktemp -d); trap 'rm -rf "$w"' EXIT; key=$(jq -er '.inbounds[]|select(.tag=="vless-reality-in")|.tls.reality.private_key' "$C") || exit 1; pub=$(public_key "$key") || exit 1; jq --arg pub "$pub" '.inbounds[]|select(.tag=="vless-reality-in")|{type:"vless",tag:"reality-test",server:"127.0.0.1",server_port:.listen_port,uuid:.users[0].uuid,flow:.users[0].flow,tls:{enabled:true,server_name:.tls.server_name,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$pub,short_id:.tls.reality.short_id[0]}}}' "$C" > "$w/o" && probe "$w/o"; )
fix_rules(){ local f; f=$(mktemp); rules > "$f"; edit --slurpfile r "$f" '.http_clients=((.http_clients // [])|map(select(.tag!="rule-download")))+$r[0].http_clients|.route.default_http_client="rule-download"|.route.rule_set |= map(if .type=="remote" and (.http_client == null or .http_client == "rule-download") then del(.download_detour,.http_client) else . end)'; local rc=$?; rm -f "$f"; return "$rc"; }
route_test() (
 local w pid='' p=10895 domain expect actual code before logs domains; w=$(mktemp -d); trap '[[ -z $pid ]] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; rm -rf "$w"' EXIT; trap 'exit 130' INT
 [[ -z $(ss -H -lnt "sport = :$p") ]] || exit 1
 jq --argjson p "$p" --arg cache "$w/cache.db" '.log={level:"debug"}|.inbounds=[{type:"mixed",tag:"route-test-in",listen:"127.0.0.1",listen_port:$p}]|.experimental={cache_file:{enabled:true,path:$cache}}' "$C" > "$w/config.json" || exit 1; check "$w/config.json" || exit 1; sing-box run -D "$w" -c "$w/config.json" > "$w/log" 2>&1 & pid=$!; for i in {1..45}; do kill -0 "$pid" || { cat "$w/log"; exit 1; }; [[ -n $(ss -H -lnt "sport = :$p") ]] && break; sleep 1; done
 [[ -n $(ss -H -lnt "sport = :$p") ]] || { cat "$w/log"; exit 1; }
 domains=$(ask '测试域名（空格分隔）' 'chatgpt.com api.openai.com claude.ai gemini.google.com binance.com tiktok.com github.com api.ipify.org') || exit 1
 local -a domain_list; read -ra domain_list <<< "$domains"
 for domain in "${domain_list[@]}"; do
 [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || continue
 expect=custom
 before=$(wc -l < "$w/log"); code=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:$p" --max-time 15 -o /dev/null -w '%{http_code}' "https://$domain/" 2>/dev/null || :); sleep .2; logs=$(tail -n "+$((before+1))" "$w/log"); actual=$(grep -F "$domain:443" <<< "$logs" | sed -n 's/.*outbound\/[^[]*\[\([^]]*\)\]: outbound connection to.*/\1/p' | head -1); printf '%-36s policy=%-12s actual=%-12s HTTP=%s\n' "$domain" "$expect" "${actual:-unknown}" "${code:-000}"
 done
)
monitor(){ local filter; filter=$(ask '日志筛选（all/ai/crypto/tiktok/anytls/relay-client）' all); case $filter in relay-client|hk-relay) filter="relay-client|hk-relay";; ai) filter='openai|chatgpt|claude|anthropic|gemini|grok|perplexity|aistudio';; crypto) filter='binance|okx|bybit|bitget|metamask|etherscan';; tiktok) filter='tiktok|byteoversea';; all) filter='.';; esac; journalctl -u sing-box -n 0 -f -o cat | grep --line-buffered -Ei "$filter"; }
restore(){ local f; ls -1d "$B"/* 2>/dev/null; f=$(ask '输入完整备份目录' ''); [[ -f $f/sing-box/config.json ]] || return 1; confirm '恢复 JSON（证书需与备份一致）?' && apply "$f/sing-box/config.json"; }
change_port(){ local tag p; jq -r '.inbounds[]|"\(.tag) \(.listen_port)"' "$C"; tag=$(ask '入站标签' anytls-in); jq -e --arg t "$tag" 'any(.inbounds[];.tag==$t)' "$C" >/dev/null || return 1; p=$(ask '内部监听端口' ''); port "$p" || return 1; edit --arg t "$tag" --argjson p "$((10#$p))" '(.inbounds[]|select(.tag==$t)|.listen_port)=$p'; }
ntp(){ case $(virt) in podman|docker|lxc|openvz|container*) echo '容器时间由宿主机管理'; date -u;; *) local existed=0; dpkg-query -W -f='${db:Status-Status}' systemd-timesyncd 2>/dev/null | grep -qx installed && existed=1; apt-get install -y systemd-timesyncd || return 1; if (( ! existed )); then install -d -m 700 /var/lib/sb-manager && touch /var/lib/sb-manager/timesyncd-installed || return 1; fi; systemctl enable --now systemd-timesyncd; timedatectl status;; esac; }
diagnose(){ cat /etc/os-release; virt; date -u; sing-box version; systemctl status sing-box --no-pager; ss -lntup; df -h /; jq '.outbounds[]|select(.type=="anytls" or .type=="shadowsocks" or .type=="hysteria2" or .type=="vless" or .type=="snell")|del(.password,.obfs.password,.uuid,.psk,.userkey)' "$C"; journalctl -u sing-box -n 20 --no-pager; }
tls_target(){ local t; t=$(ask 'REALITY目标域名' www.apple.com); timeout 10 openssl s_client -connect "$t:443" -servername "$t" -tls1_3 -brief </dev/null; if confirm '修改 REALITY 目标?'; then edit --arg t "$t" '(.inbounds[]|select(.tag=="vless-reality-in")|.tls.server_name)=$t|(.inbounds[]|select(.tag=="vless-reality-in")|.tls.reality.handshake.server)=$t'; fi; }
foreground() ( confirm '停止正式服务并前台调试?' || exit 0; local active=0; systemctl is-active --quiet sing-box && active=1; trap '((active==0)) || systemctl start sing-box' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; systemctl stop sing-box && sing-box run -D "$D" -c "$C"; )
disk(){ df -h /; du -sh /var/log/journal /var/cache/apt /usr/lib/modules /boot /var/lib/apt/lists 2>/dev/null; }
clean(){ confirm '清理APT缓存、压缩旧日志至100MB（不删除内核）?' && apt-get clean && journalctl --vacuum-size=100M; }
limit_logs(){ confirm '设置 journald 最大100MB（影响全系统）?' || return; mkdir -p /etc/systemd/journald.conf.d; printf '[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\n' > /etc/systemd/journald.conf.d/90-sb.conf; systemctl restart systemd-journald; }
# 保留旧版 taiwan-out 标签用于无损升级；新配置使用 relay-out。
relay_tag(){ jq -er '[.outbounds[]? | select(.tag=="relay-out" or .tag=="taiwan-out")][0].tag' "$C"; }
init_menu(){ local n; echo '1. 入口中转（智能分流）'; echo '2. 落地服务（独立节点及中转接收）'; echo '0. 返回'; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in 1) init_role entry;; 2) init_role landing;; 0) return 0;; *) err '无效选项';; esac; }
route_list(){ jq -r '"默认出站: \(.route.final // "未设置")", "--- 路由规则（索引从0开始，按顺序匹配） ---", ((.route.rules // [])|to_entries[]|"\(.key): \(.value|tojson)"), "--- 规则集 ---", ((.route.rule_set // [])[]|"\(.tag): \(.type) \(.url // .path // "")"), "--- 出站 ---", (.outbounds[]|"\(.tag) [\(.type)]")' "$C"; }
route_index(){ [[ $1 =~ ^(0|[1-9][0-9]{0,6})$ ]] && (( $1 < $(jq '.route.rules // [] | length' "$C") )); }
route_target(){ local t; jq -r '.outbounds[]|"\(.tag) [\(.type)]"' "$C" >&2; t=$(ask '目标出站标签（或 reject）' direct) || return 1; if [[ $t != reject ]]; then jq -e --arg t "$t" 'any(.outbounds[]; .tag==$t)' "$C" >/dev/null || return 1; fi; printf '%s' "$t"; }
route_build(){ local k v t a; k=$(ask '匹配类型 domain/domain_suffix/domain_keyword/domain_regex/ip_cidr/rule_set' domain_suffix) || return 1; case $k in domain|domain_suffix|domain_keyword|domain_regex|ip_cidr|rule_set) ;; *) err '不支持的匹配类型'; return 1;; esac; v=$(ask '匹配值，多个用英文逗号分隔' '') || return 1; a=$(jq -cn --arg v "$v" '$v|split(",")|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))') || return 1; [[ $a != '[]' ]] || return 1; if [[ $k == ip_cidr ]]; then python3 -c 'import ipaddress,json,sys; [ipaddress.ip_network(x,strict=False) for x in json.loads(sys.argv[1])]' "$a" || return 1; fi; if [[ $k == rule_set ]]; then jq -e --argjson a "$a" '(.route.rule_set // [] | map(.tag)) as $tags | all($a[]; . as $x | $tags|index($x)!=null)' "$C" >/dev/null || { err '规则集不存在'; return 1; }; fi; t=$(route_target) || return 1; jq -cn --arg k "$k" --argjson a "$a" --arg t "$t" '{($k):$a} + (if $t=="reject" then {action:"reject"} else {action:"route",outbound:$t} end)'; }
legacy_route_manage(){ local n i j r t url fmt interval; [[ -s $C ]] || { err '请先初始化'; return 1; }; while true; do echo; ui_title '分流规则管理'; columns '1 查看规则及出站|2 添加规则|3 修改规则|4 删除规则|5 调整规则顺序' '6 添加远程规则集|7 删除未引用规则集|8 设置默认出站|0 返回'; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in
1) route_list;;
2) route_list; r=$(route_build) || continue; i=$(ask '插入索引（在指定规则之前）' "$(jq '(.route.rules // []) | ([to_entries[] | select(.value.action!="sniff" and (.value.ip_is_private!=true or .value.action!="reject")) | .key][0] // length)' "$C")") || continue; [[ $i =~ ^(0|[1-9][0-9]{0,6})$ ]] && ((i <= $(jq '.route.rules // [] | length' "$C"))) || { err '索引无效'; continue; }; confirm '应用新规则（将重启服务）?' && edit --argjson i "$i" --argjson r "$r" '.route.rules=((.route.rules // [])| .[:$i]+[$r]+.[$i:])';;
3|4) route_list; i=$(ask '规则索引' '') || continue; route_index "$i" || { err '索引无效'; continue; }; if jq -e --argjson i "$i" '.route.rules[$i]|(.action=="sniff" or .action=="resolve" or .ip_is_private==true)' "$C" >/dev/null; then confirm '这是基础安全/解析规则，仍然修改或删除?' || continue; fi; if [[ $n == 3 ]]; then r=$(route_build) || continue; confirm '替换该规则?' && edit --argjson i "$i" --argjson r "$r" '.route.rules[$i]=$r'; else confirm '删除该规则?' && edit --argjson i "$i" 'del(.route.rules[$i])'; fi;;
5) route_list; i=$(ask '原索引' '') || continue; j=$(ask '移动后索引' '') || continue; route_index "$i" && route_index "$j" || { err '索引无效'; continue; }; confirm '调整顺序（可能改变安全策略及匹配结果）?' && edit --argjson i "$i" --argjson j "$j" '.route.rules |= (.[$i] as $r | del(.[$i]) | .[:$j]+[$r]+.[$j:])';;
6) t=$(ask '规则集唯一标签' '') || continue; [[ $t =~ ^[a-zA-Z0-9_.-]+$ ]] || continue; jq -e --arg t "$t" 'any(.route.rule_set[]?; .tag==$t)' "$C" >/dev/null && { err '标签已存在'; continue; }; url=$(ask 'HTTPS 规则集 URL' '') || continue; [[ $url == https://* ]] || continue; fmt=$(ask '格式 binary/source' binary) || continue; [[ $fmt == binary || $fmt == source ]] || continue; interval=$(ask '更新周期' 24h) || continue; confirm '添加规则集（之后使用添加规则绑定出站）?' && edit --arg t "$t" --arg u "$url" --arg f "$fmt" --arg d "$interval" '.http_clients=((.http_clients // []) | if any(.[]; .tag=="rule-download") then . else .+[{tag:"rule-download"}] end) | .route.default_http_client=(.route.default_http_client // "rule-download") | .route.rule_set=((.route.rule_set // [])+[{type:"remote",tag:$t,url:$u,format:$f,update_interval:$d}])';;
7) route_list; t=$(ask '待删除规则集标签' '') || continue; jq -e --arg t "$t" 'any(.route.rule_set[]?; .tag==$t)' "$C" >/dev/null || continue; if { [[ -s $POLICY ]] && jq -e --arg t "$t" 'any(..|strings;.==$t)' "$POLICY" >/dev/null; } || jq -e --arg t "$t" 'any((.route.rules,.dns.rules)|..|objects|.rule_set? // empty; if type=="array" then index($t)!=null else .==$t end)' "$C" >/dev/null; then err '规则集仍被引用，请先删除或修改引用规则'; continue; fi; confirm '删除规则集?' && edit --arg t "$t" '.route.rule_set |= map(select(.tag!=$t))';;
8) t=$(route_target) || continue; [[ $t != reject ]] || { err '默认出站必须是已有标签'; continue; }; confirm '修改默认出站（所有未匹配流量）?' && edit --arg t "$t" '.route.final=$t';;
0) return 0;; *) err '无效选项';; esac; done; }

legacy_menu(){ while true; do cat <<MENU
==== sb 通用管理 v$VERSION ====
1 安装/更新核心     02 初始化 sing-box 服务     3 启动
4 停止             5 重启           6 状态
7 日志             8 节点信息       9 修改端口
10 修改中转        11 修复规则下载  12 中转测试
13 日志级别        14 REALITY测试   15 REALITY公钥
16 TLS目标         17 时间同步      18 系统诊断
19 前台调试        20 修复权限      21 备份
22 恢复JSON        23 磁盘检查      24 安全清理
25 限制日志        26 BBR状态       27 开机启动
28 分流规则管理      29 分流测试      30 实时监控
31 域名统计        32 AnyTLS连接    33 网卡速率
34 设置公网地址    0 退出
MENU
 local n; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in 0) return;; *) dispatch "$n";; esac; read -rp '回车继续...' _ || return; done; }
legacy_dispatch(){ case ${1:-} in
1|update) install_core;; 2|02|init) init_menu;; init-entry|init-hk) init_role entry;; init-landing|init-tw) init_role landing;; 28|rules) route_manage;; 3|start) systemctl start sing-box;; 4|stop) systemctl stop sing-box;; 5|restart) systemctl restart sing-box;; 6|status) systemctl status sing-box --no-pager -l;; 7|logs) journalctl -u sing-box -n 30 -f -o cat;; 8|info) info;; 9|port) change_port;; 10|change-relay) change_relay;; 11|fix-rules) fix_rules;; 12|relay) relay "${2:-}";; 13) local l; l=$(ask '日志级别' info); edit --arg l "$l" '.log.level=$l';; 14|test) reality_test;; 15) local k; k=$(jq -er '.inbounds[]|select(.tag=="vless-reality-in")|.tls.reality.private_key' "$C") && public_key "$k";; 16) tls_target;; 17) ntp;; 18|diagnose) diagnose;; 19) foreground;; 20|fix-perm) permissions;; 21|backup) backup;; 22|restore) restore;; 23|disk) disk;; 24|clean) clean;; 25) limit_logs;; 26) sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc;; 27) local a; a=$(ask 'enable/disable' enable); case $a in enable|disable) systemctl "$a" sing-box;; esac;; 29|test-route) route_test;; 30|monitor) monitor;; 31) local period; period=$(ask '统计时间（1 hour/24 hours）' '1 hour'); journalctl -u sing-box --since "$period ago" -o cat --no-pager | sed -n 's/.*inbound connection to //p' | sort | uniq -c | sort -nr | head -50;; 32) local p; p=$(jq -r '.inbounds[]|select(.tag=="anytls-in")|.listen_port' "$C"); watch -n 1 "ss -tinp 'sport = :$p'";; 33) command -v nload >/dev/null || apt-get install -y nload; nload;; 34|public-address) set_public_address;; install-manager) if [[ $(readlink -f "$0") == /usr/local/bin/sb ]]; then return 0; fi; if [[ -e /usr/local/bin/sb ]]; then confirm "备份并替换旧 sb?" || return 0; cp -a /usr/local/bin/sb "/usr/local/bin/sb.bak.$(date +%s)" || return 1; fi; install -m 755 "$0" /usr/local/bin/sb;; '') menu;; *) err '未知命令';; esac; }
# v2.2: use screen-cell width rather than byte width for Chinese menus.
columns(){
 local width color=0; width=$(tput cols 2>/dev/null || echo 80); [[ $width =~ ^[0-9]+$ ]] || width=80; ui_color && color=1
 if ! command -v python3 >/dev/null; then printf '%s\n' "$1" "$2" | tr '|' '\n'; return; fi
 python3 -c 'import sys,unicodedata as u,re
w=int(sys.argv[1]); a,b=sys.argv[2].split("|"),sys.argv[3].split("|"); color=sys.argv[4]=="1"
def cells(s): return sum(0 if u.combining(c) else 2 if u.east_asian_width(c) in "WF" else 1 for c in s)
def p(s,c): return "\033["+c+"m"+s+"\033[0m" if color else s
def fmt(s):
 if s.startswith("◆"): return p(s,"1;36")
 m=re.match(r"^(\d+)(\s+)(.*)$",s)
 if not m: return s
 n,sp,label=m.groups()
 if int(n) in (0,99): return p(s,"1;31")
 c=""
 if any(x in label for x in ("停止","退出")): c="1;31"
 elif any(x in label for x in ("初始化","恢复","重启","清理","删除","更新核心")): c="1;33"
 elif any(x in label for x in ("分流","中转","出站")): c="1;34"
 return p(n,"1;32")+sp+(p(label,c) if c else label)
n=max(36,max(map(cells,a))+4)
if w<90 or n+max(map(cells,b))>w:
 for x in a+b:
  if x: print(fmt(x))
else:
 for i in range(max(len(a),len(b))):
  l=a[i] if i<len(a) else ""; r=b[i] if i<len(b) else ""; print(fmt(l)+(" "*max(0,n-cells(l))+fmt(r) if r else ""))' "$width" "$1" "$2" "$color"
}
init_menu(){ local n; ui_title '初始化 sing-box 服务'; columns '01 独立代理（单 VPS）|02 入口中转|03 落地服务|00 返回' ''; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in 1|01) init_role standalone;; 2|02) init_role entry;; 3|03) init_role landing;; 0|00) return;; *) err '无效选项';; esac; }
proxy_list(){ jq -r '.outbounds[]|[.tag,.type,(.server // "-"),(.server_port // "-")]|@tsv' "$C"; }
select_proxy(){ local t; proxy_list >&2; t=$(ask '出站标签' "${1:-relay-out}") || return 1; jq -e --arg t "$t" 'any(.outbounds[];.tag==$t and (.type=="anytls" or .type=="shadowsocks" or .type=="hysteria2" or .type=="vless" or .type=="snell" or .type=="direct"))' "$C" >/dev/null || { err '出站不存在或类型不支持'; return 1; }; printf '%s' "$t"; }
proxy_test() ( local t=$1 w; w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT; jq -e --arg t "$t" '.outbounds[]|select(.tag==$t)' "$C" > "$w/o" || exit 1; if jq -e 'has("detour")' "$w/o" >/dev/null; then err '链式 detour 出站暂不支持独立测试'; exit 1; fi; jq 'if .server then .domain_resolver={server:"local-dns",strategy:"ipv4_only"} else . end' "$w/o" > "$w/test" || exit 1; probe "$w/test" "${2:-}"; )
relay(){ local t; t=$(relay_tag 2>/dev/null) || t=$(select_proxy) || return 1; proxy_test "$t" "${1:-}"; }
proxy_change() ( local op=$1 t w exp; w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT; if [[ $op == add ]]; then t=$(ask '新出站唯一标签' relay-out) || exit 1; [[ $t =~ ^[A-Za-z0-9_.-]+$ && $t != direct && $t != reject ]] || exit 1; jq -e --arg t "$t" 'any(.outbounds[];.tag==$t)' "$C" >/dev/null && { err '标签重复'; exit 1; }; make_relay "$w/new" || exit 1; else t=$(select_proxy) || exit 1; jq -e --arg t "$t" '.outbounds[]|select(.tag==$t and .type!="direct")' "$C" > "$w/old" || exit 1; make_relay "$w/new" "$w/old" || exit 1; fi; jq --arg t "$t" '.tag=$t' "$w/new" > "$w/tagged" || exit 1; exp=$(ask '预期出口 IP（回车仅验证连通性）' '') || exit 1; probe "$w/tagged" "$exp" || exit 1; confirm '应用出站配置?' || exit 0; edit --arg t "$t" --slurpfile o "$w/tagged" '.outbounds |= (if any(.[];.tag==$t) then map(if .tag==$t then $o[0] else . end) else .+$o end)'; )
proxy_delete(){ local t; t=$(select_proxy) || return 1; [[ $t != direct ]] || { err '不能删除直连出站'; return 1; }; # conservative reference check, includes saved policies
 if jq -e --arg t "$t" 'del(.outbounds[]|select(.tag==$t)) | any(..|strings; .==$t)' "$C" >/dev/null || { [[ -s $POLICY ]] && jq -e --arg t "$t" 'any(..|strings;.==$t)' "$POLICY" >/dev/null; }; then err '仍被配置或已保存策略引用'; return 1; fi; confirm '删除出站?' && edit --arg t "$t" '.outbounds |= map(select(.tag!=$t))'; }
set_final(){ local t; t=$(route_target) || return 1; [[ $t != reject ]] || return 1; confirm '修改默认出站?' && edit --arg t "$t" '.route.final=$t'; }
# Parse supported share URLs from stdin. Credentials are not command arguments.
parse_share_link(){
 python3 -c '
import sys,json,re,base64,uuid
from urllib.parse import urlsplit,parse_qs,unquote
class Invalid(Exception): pass
def check(ok,msg):
 if not ok: raise Invalid(msg)
def b64(s):
 return base64.b64decode(s+"="*(-len(s)%4),altchars=b"-_",validate=True)
def boolean(s):
 check(s.lower() in ("0","1","true","false"),"布尔参数无效")
 return s.lower() in ("1","true")
def parse(raw,tag):
 raw=raw.strip()
 check(0<len(raw)<=16384 and not re.search(r"\s",raw),"请输入单条完整分享链接")
 scheme,sep,body=raw.partition("://")
 scheme=scheme.lower()
 check(sep and scheme in ("vless","anytls","hy2","hysteria2","ss"),"不支持的分享链接协议")
 if scheme=="ss" and "@" not in body.split("#",1)[0].split("?",1)[0]:
  check("?" not in body.split("#",1)[0],"旧式 SS 链接不支持扩展参数")
  raw="ss://"+b64(unquote(body.split("#",1)[0])).decode()
 x=urlsplit(raw)
 q=parse_qs(x.query,keep_blank_values=True,strict_parsing=True)
 check(all(len(v)==1 for v in q.values()),"查询参数重复")
 def g(k,d=""): return q.get(k,[d])[0]
 def only(keys): check(set(q)<=set(keys.split()),"包含暂不支持的扩展参数")
 host=x.hostname; port=x.port
 check(host and port and 1<=port<=65535 and not any(c in host for c in "/\\\x00"),"服务器地址或端口无效")
 check(x.path in ("","/"),"不支持此链接路径")
 user=unquote(x.username or "")
 pw=user+(":"+unquote(x.password) if x.password is not None else "")
 o={"type":{"hy2":"hysteria2","ss":"shadowsocks"}.get(scheme,scheme),"tag":tag,"server":host,"server_port":port,"domain_resolver":{"server":"local-dns","strategy":"ipv4_only"}}
 def tls():
  sni=g("sni"); peer=g("peer")
  check(not(sni and peer and sni!=peer),"SNI 参数冲突")
  t={"enabled":True,"server_name":sni or peer or host}
  flags=[boolean(g(k)) for k in ("insecure","allowInsecure") if g(k)]
  check(not flags or all(v==flags[0] for v in flags),"证书校验参数冲突")
  if flags: t["insecure"]=flags[0]
  pins=[b64(g(k)) for k in ("pinSHA256","certificate_public_key_sha256") if g(k)]
  if pins:
   check(all(len(p)==32 and p==pins[0] for p in pins),"公钥指纹格式无效或冲突")
   t["certificate_public_key_sha256"]=[base64.b64encode(pins[0]).decode()]
  if g("alpn"): t["alpn"]=g("alpn").split(",")
  return t
 if scheme=="vless":
  only("encryption security type flow sni peer fp pbk sid spx headerType alpn insecure allowInsecure")
  check(x.password is None,"VLESS 用户信息无效")
  o["uuid"]=str(uuid.UUID(user))
  check(g("encryption","none")=="none","不支持 VLESS 加密扩展")
  check(g("type","tcp") in ("tcp","raw") and g("headerType","none")=="none","仅支持 TCP/RAW VLESS")
  check(g("flow") in ("","xtls-rprx-vision"),"不支持的 Flow")
  if g("flow"): o["flow"]=g("flow")
  sec=g("security","none")
  check(sec in ("reality","tls"),"仅支持 VLESS REALITY 或 TLS")
  t=tls()
  check(not t.get("insecure"),"VLESS 不允许关闭证书验证")
  if sec=="reality":
   pbk=g("pbk"); sid=g("sid")
   check(bool(re.fullmatch(r"[A-Za-z0-9_-]{43}",pbk)) and len(b64(pbk))==32,"REALITY 公钥无效")
   check(bool(re.fullmatch(r"(?:[0-9A-Fa-f]{2}){0,8}",sid)),"REALITY Short ID 无效")
   check(g("spx") in ("","/"),"不支持自定义 spiderX")
   t["utls"]={"enabled":True,"fingerprint":g("fp") or "chrome"}
   t["reality"]={"enabled":True,"public_key":pbk,"short_id":sid}
  else:
   check(not any(g(k) for k in ("pbk","sid","spx")),"TLS 链接包含 REALITY 参数")
   if g("fp"): t["utls"]={"enabled":True,"fingerprint":g("fp")}
  o["tls"]=t
 elif scheme in ("anytls","hy2","hysteria2"):
  only("sni peer insecure allowInsecure pinSHA256 certificate_public_key_sha256 alpn obfs obfs-password")
  check(pw,"缺少节点密码")
  o.update(password=pw,tls=tls())
  if scheme=="anytls":
   check(not g("obfs") and not g("obfs-password"),"AnyTLS 不支持此混淆")
  elif g("obfs"):
   check(g("obfs")=="salamander" and g("obfs-password"),"仅支持带密码的 Salamander 混淆")
   o["obfs"]={"type":"salamander","password":g("obfs-password")}
  else: check(not g("obfs-password"),"缺少混淆类型")
 else:
  only("")
  auth=pw if ":" in pw else b64(pw).decode()
  method,sep,key=auth.partition(":")
  check(sep and key,"SS 认证信息无效")
  check(method in ("2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm","2022-blake3-chacha20-poly1305","aes-128-gcm","aes-192-gcm","aes-256-gcm","chacha20-ietf-poly1305","xchacha20-ietf-poly1305"),"不支持此 SS 加密算法")
  if method.startswith("2022-"):
   n=16 if method=="2022-blake3-aes-128-gcm" else 32
   check(all(len(b64(k))==n for k in key.split(":")),"SS2022 密钥长度无效")
  o.update(method=method,password=key)
 return o
try:
 print(json.dumps(parse(sys.stdin.read(),sys.argv[1]),ensure_ascii=False))
except Invalid as e:
 print("导入失败："+str(e),file=sys.stderr); sys.exit(1)
except Exception:
 print("导入失败：链接格式或参数无效",file=sys.stderr); sys.exit(1)
' "$1"
}
proxy_import() (
 local w link t exp pin
 [[ -s $C ]] || { err '请先初始化'; exit 1; }
 need python3 jq curl sing-box || exit 1
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 t=$(ask '新出站唯一标签' relay-import) || exit 1
 [[ $t =~ ^[A-Za-z0-9_.-]+$ && $t != direct && $t != reject ]] || { err '标签无效'; exit 1; }
 jq -e --arg t "$t" 'any(.outbounds[];.tag==$t)' "$C" >/dev/null && { err '标签重复'; exit 1; }
 read -rs -p '粘贴单条分享链接（不回显）: ' link || exit 1
 echo
 printf '%s' "$link" | parse_share_link "$t" > "$w/o" || exit 1
 unset link
 if jq -e '.type=="anytls" or .type=="hysteria2"' "$w/o" >/dev/null; then
  pin=$(ask 'TLS SPKI SHA256 Base64（可选，回车保留链接设置）' '') || exit 1
  if [[ -n $pin ]]; then
   [[ $pin =~ ^[A-Za-z0-9+/]{43}=$ ]] || { err '指纹格式不正确'; exit 1; }
   jq --arg pin "$pin" '.tls.certificate_public_key_sha256=[$pin]|.tls.insecure=false' "$w/o" > "$w/next" && mv "$w/next" "$w/o" || exit 1
  fi
 fi
 if jq -e '.tls.insecure==true' "$w/o" >/dev/null; then
  confirm '警告：链接关闭证书验证，存在中间人风险，仍继续?' || exit 0
 fi
 msg OK '链接解析成功（隐藏认证信息）'
 jq 'del(.password,.uuid,.obfs.password,.psk,.userkey)' "$w/o" || exit 1
 exp=$(ask '预期出口 IP（回车仅验证连通性）' '') || exit 1
 probe "$w/o" "$exp" || exit 1
 confirm '测试通过，添加出站配置?' || exit 0
 jq -e --arg t "$t" 'any(.outbounds[];.tag==$t)' "$C" >/dev/null && { err '标签已存在'; exit 1; }
 edit --slurpfile o "$w/o" '.outbounds += $o'
)
# Export native JSON without losing protocol-specific settings. Never overwrite a file.
# Build a candidate URI; verify it with the importer before exporting.
outbound_share_candidate(){
 python3 -c '
import sys,json,base64,ipaddress
from urllib.parse import quote,urlencode
try:
 o=json.load(sys.stdin); t=o["type"]; host=o["server"]; port=o["server_port"]
 if ":" in host: host="["+str(ipaddress.IPv6Address(host))+"]"
 tag=quote(o["tag"],safe="")
 q={}
 if t=="shadowsocks":
  auth=base64.urlsafe_b64encode((o["method"]+":"+o["password"]).encode()).decode().rstrip("=")
  scheme="ss"
 elif t in ("vless","anytls","hysteria2"):
  tls=o["tls"]
  if not tls.get("enabled"): raise ValueError()
  if tls.get("server_name"): q["sni"]=tls["server_name"]
  if "insecure" in tls: q["insecure"]=int(tls["insecure"])
  if tls.get("alpn"): q["alpn"]=",".join(tls["alpn"])
  pins=tls.get("certificate_public_key_sha256",[])
  if pins:
   if len(pins)!=1 or t=="vless": raise ValueError()
   q["certificate_public_key_sha256"]=pins[0]
  if t=="vless":
   auth=quote(o["uuid"],safe=""); scheme="vless"
   q.update(encryption="none",type="tcp",security="tls")
   if o.get("flow"): q["flow"]=o["flow"]
   utls=tls.get("utls",{})
   if utls.get("enabled"): q["fp"]=utls.get("fingerprint","chrome")
   r=tls.get("reality",{})
   if r.get("enabled"):
    q.update(security="reality",pbk=r["public_key"],sid=r.get("short_id",""),fp=utls.get("fingerprint","chrome"))
  else:
   auth=quote(o["password"],safe=""); scheme=t
   if t=="hysteria2" and o.get("obfs"):
    q["obfs"]=o["obfs"]["type"]; q["obfs-password"]=o["obfs"]["password"]
 else: raise ValueError()
 print(scheme+"://"+auth+"@"+host+":"+str(port)+("?" + urlencode(q) if q else "")+"#"+tag)
except Exception: sys.exit(1)
'
}
# Ignore only well-defined equivalent defaults; all other fields must survive.
outbound_share_equivalent(){
 jq -e -s '
 def norm:
  (if .type=="vless" and .flow=="" then del(.flow) else . end)
  | (if .type=="vless" and .transport=={"type":"tcp"} then del(.transport) else . end)
  | (if .tls.insecure==false then del(.tls.insecure) else . end)
  | (if .tls.alpn==[] then del(.tls.alpn) else . end)
  | (if .tls.certificate_public_key_sha256==[] then del(.tls.certificate_public_key_sha256) else . end)
  | (if .tls.server_name==null or .tls.server_name=="" then
       if .tls.enabled==true then .tls.server_name=.server else . end
     else . end);
 length==2 and ((.[0]|norm)==(.[1]|norm))
 ' "$1" "$2" >/dev/null
}
proxy_export() (
 local scope tag prefix w link n links=0 fallback=0
 [[ -s $C ]] || { err '请先安装服务'; exit 1; }
 need jq python3 || exit 1
 scope=$(ask '导出范围 single/all' single) || exit 1
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 case $scope in
 single)
  proxy_list; tag=$(ask '出站标签' '') || exit 1
  jq -e --arg t "$tag" '[.outbounds[]|select(.tag==$t)]|select(length==1)' "$C" > "$w/selected" || { err '出站不存在或标签不唯一'; exit 1; };;
 all) jq -e '.outbounds|select(type=="array" and length>0)' "$C" > "$w/selected" || exit 1;;
 *) err '无效范围'; exit 1;;
 esac
 : > "$w/links.txt"; : > "$w/fallback.ndjson"
 n=$(jq 'length' "$w/selected") || exit 1
 for ((i=0;i<n;i++)); do
  jq --argjson i "$i" '.[$i]' "$w/selected" > "$w/node" || exit 1
  tag=$(jq -er '.tag' "$w/node") || exit 1
  if link=$(outbound_share_candidate < "$w/node") &&
    printf '%s' "$link" | parse_share_link "$tag" > "$w/parsed" 2>/dev/null &&
    outbound_share_equivalent "$w/node" "$w/parsed"; then
   printf '%s\n' "$link" >> "$w/links.txt"; ((links+=1))
   printf '%s: 分享链接\n' "$tag"
  else
   jq -c . "$w/node" >> "$w/fallback.ndjson" || exit 1; ((fallback+=1))
   printf '%s: 原生 JSON（协议或参数无法无损转换）\n' "$tag"
  fi
 done
 unset link
 jq -s '{outbounds:.}' "$w/fallback.ndjson" > "$w/fallback.json" || exit 1
 printf '分享链接: %s  JSON 回退: %s\n' "$links" "$fallback"
 echo '导出包含完整认证信息，请勿公开。'
 prefix=$(ask '导出路径前缀（不带扩展名）' "/root/sb-outbounds-$(date +%Y%m%d-%H%M%S)") || exit 1
 [[ -n $prefix ]] || exit 1
 confirm '确认导出敏感配置到文件?' || exit 0
 # Exclusive creation; on failure remove only files created by this invocation.
 python3 - "$prefix" "$w" "$links" "$fallback" <<'PYEXPORT'
import sys,os
prefix,w,links,fallback=sys.argv[1:]
items=[]
if int(links): items.append((w+"/links.txt",prefix+".txt"))
if int(fallback): items.append((w+"/fallback.json",prefix+".json"))
created=[]
try:
 for src,dst in items:
  fd=os.open(dst,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  created.append(dst)
  with os.fdopen(fd,"wb") as f,open(src,"rb") as r: f.write(r.read())
except OSError:
 for p in created:
  try: os.unlink(p)
  except OSError: pass
 print("导出失败：文件已存在或路径不可写",file=sys.stderr); sys.exit(1)
for p in created: print("已导出："+p)
PYEXPORT
 [[ $? == 0 ]] || exit 1
 if ((links)) && confirm '在终端显示分享链接（包含认证信息）?'; then cat "$w/links.txt"; fi
)
# Full removal of the managed proxy stack. Keep unrelated/shared OS components.
purge_service_package(){
 local pkg=$1 plan name
 dpkg-query -W "$pkg" >/dev/null 2>&1 || return 0
 plan=$(LC_ALL=C apt-get -s purge "$pkg") || return 1
 while read -r name; do
  [[ -z $name || $name == "$pkg" || $name == "$pkg":* ]] || { err "卸载 $pkg 将影响其他软件包 $name，拒绝自动卸载"; return 1; }
 done < <(awk '/^(Remv|Purg) /{print $2}' <<< "$plan")
 apt-get -y purge "$pkg"
}
stop_managed_unit(){
 local unit=$1 load
 load=$(systemctl show -p LoadState --value "$unit" 2>/dev/null) || :
 if [[ $load == not-found || -z $load ]]; then
  if systemctl is-active --quiet "$unit"; then systemctl stop "$unit" || return 1; fi
  return 0
 fi
 systemctl stop "$unit" || return 1
 systemctl disable "$unit" || return 1
 ! systemctl is-active --quiet "$unit"
}
uninstall_service(){
 local answer pkg old q p owner cloud_owned=0 keep_cloud=0
 local -a leftovers=()
 need systemctl dpkg-query apt-get sysctl pgrep || return 1
 [[ -d /run/systemd/system ]] && systemctl show -p Version --value >/dev/null 2>&1 || { err 'systemd 不可用，无法安全停止服务'; return 1; }
 echo '彻底卸载将停止 sing-box 和 sb-argo，删除核心、节点、证书、规则、缓存、管理器及其备份。'
 echo '删除 /root/sb-backups 和默认路径的节点/规则导出文件；无法恢复。请先另行保存需要的数据。'
 echo '恢复本工具保存的 BBR 参数，移除本工具的 journald 限额。共用系统依赖及其他应用不强制删除。'
 echo 'Cloudflare 云端 Tunnel/DNS 不会删除。若 SSH 依赖代理或隧道，请先切换至独立连接。'
 read -r -p "$(ui_prompt '确认彻底卸载请输入 PURGE：')" answer || return 2
 [[ $answer == PURGE ]] || { echo '已取消卸载'; return 2; }
 [[ -f /etc/apt/sources.list.d/sb-cloudflared.list || -f /var/lib/sb-manager/cloudflared-installed ]] && cloud_owned=1
 stop_managed_unit sb-argo.service && stop_managed_unit sing-box.service || { err '停止服务失败，未继续删除'; return 1; }
 # Do not remove a connector used by another service or manually running process.
 if command -v cloudflared >/dev/null || dpkg-query -W cloudflared >/dev/null 2>&1; then
  if pgrep -x cloudflared >/dev/null 2>&1 ||
    systemctl list-unit-files --no-legend 'cloudflared*.service' 2>/dev/null | grep -q '^cloudflared' ||
    [[ -e /etc/cloudflared || -e /root/.cloudflared ]]; then
   keep_cloud=1
  elif (( ! cloud_owned )); then
   if ! confirm '检测到来源不明的 cloudflared，确认仅供本管理器使用并卸载?'; then keep_cloud=1; fi
  fi
  if (( ! keep_cloud )); then
   purge_service_package cloudflared || return 1
   if command -v cloudflared >/dev/null; then
    p=$(command -v cloudflared)
    if [[ $p == /usr/local/bin/cloudflared || $p == /usr/bin/cloudflared ]]; then
     if ! dpkg-query -S "$p" >/dev/null 2>&1; then rm -f -- "$p" || return 1; fi
    fi
   fi
  fi
 fi
 for pkg in sing-box sing-box-beta sing-box-alpha; do purge_service_package "$pkg" || return 1; done
 # Official package purge removes packaged files; clean known manual installations too.
 for p in /usr/local/bin/sing-box /usr/bin/sing-box /etc/systemd/system/sing-box.service /usr/lib/systemd/system/sing-box.service /lib/systemd/system/sing-box.service; do
  if [[ -e $p || -L $p ]]; then
   if dpkg-query -S "$p" >/dev/null 2>&1; then leftovers+=("$p (其他软件包所有)"); else rm -f -- "$p" || return 1; fi
  fi
 done
 if [[ -e $IPV6_STATE ]]; then ipv6_restore purge || return 1; elif [[ -e $IPV6_CONF ]]; then echo "IPv6 配置来源不明，保留 $IPV6_CONF，请手动处理"; fi
 if [[ -e $BBR_CONF || -e $BBR_STATE ]]; then
  if [[ -s $BBR_STATE ]]; then
   { read -r old; read -r q; } < "$BBR_STATE"
   [[ $old =~ ^[A-Za-z0-9_]+$ && $q =~ ^[A-Za-z0-9_]+$ ]] || { err 'BBR 原值记录无效，请手动恢复后重试'; return 1; }
   sysctl -w "net.ipv4.tcp_congestion_control=$old" "net.core.default_qdisc=$q" || { err 'BBR 恢复失败，保留记录，请处理后重试'; return 1; }
  else echo '未找到 BBR 原值记录，仅移除持久化文件；当前内核运行值需手动检查。'; fi
  rm -f -- "$BBR_CONF" "$BBR_STATE" || return 1
 fi
 if [[ -f /etc/systemd/journald.conf.d/90-sb.conf ]]; then
  rm -f /etc/systemd/journald.conf.d/90-sb.conf || return 1
  systemctl restart systemd-journald || { err 'journald 重新加载失败'; return 1; }
 fi
 # Time sync is a system service, not proxy-exclusive. Remove only if ownership is known
 # and the operator explicitly agrees, or explicitly confirms an older untracked install.
 if dpkg-query -W -f='${db:Status-Status}' systemd-timesyncd 2>/dev/null | grep -qx installed; then
  if [[ -f /var/lib/sb-manager/timesyncd-installed ]]; then
   if confirm '本工具曾安装 systemd-timesyncd，是否一并卸载（影响全系统时间同步）?'; then
    stop_managed_unit systemd-timesyncd.service && purge_service_package systemd-timesyncd || return 1
   fi
  else
   echo 'systemd-timesyncd 来源未记录，默认保留。'
   if confirm '确认时间同步服务仅由本工具安装且不再需要，是否卸载?'; then
    stop_managed_unit systemd-timesyncd.service && purge_service_package systemd-timesyncd || return 1
   fi
  fi
 fi
 rm -f -- "$ARGO_UNIT" "$ARGO_NET" || return 1
 rmdir "$ARGO_DROP" 2>/dev/null || :
 if (( ! keep_cloud )); then rm -f -- /etc/apt/sources.list.d/sb-cloudflared.list || return 1; fi
 # Do not remove a signing key still referenced by another repository.
 if ! grep -RqsF /usr/share/keyrings/sb-cloudflare.gpg /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  rm -f /usr/share/keyrings/sb-cloudflare.gpg || return 1
 fi
 rm -rf --one-file-system -- /etc/sing-box /var/lib/sing-box /var/cache/sing-box /var/log/sing-box /etc/sb-argo /var/lib/sb-manager /etc/systemd/system/sing-box.service.d /root/sb-backups || return 1
 # Only remove files matching the manager's default generated names.
 for p in /root/sb-outbounds-*.txt /root/sb-outbounds-*.json /root/sb-routing-*.json /usr/local/bin/sb.bak.*; do
  [[ -f $p || -L $p ]] || continue
  rm -f -- "$p" || return 1
 done
 systemctl daemon-reload || return 1
 systemctl reset-failed sing-box.service sb-argo.service 2>/dev/null || :
 if systemctl is-active --quiet sing-box.service || systemctl is-active --quiet sb-argo.service; then err '服务仍在运行，保留管理器供排查'; return 1; fi
 hash -r
 if command -v sing-box >/dev/null; then leftovers+=("$(command -v sing-box) (未识别的核心路径)"); fi
 if ((keep_cloud)); then echo '检测到其他用途或来源不明的 cloudflared，已保留。'; fi
 if ((${#leftovers[@]} > 0)); then printf '未自动清除：%s\n' "${leftovers[@]}"; err '请检查残留项后重试；管理器已保留'; return 1; fi
 rm -f -- /usr/local/bin/sb || return 1
 hash -r
 msg OK '本工具管理的代理服务和已知配置已卸载；共用组件、系统日志及云端资源不强制清除。'
}
uninstall_manager(){ uninstall_service; }
uninstall_manager_cli(){
 local rc=0
 uninstall_service || rc=$?
 [[ $rc == 2 ]] && return 0
 return "$rc"
}
show_help(){
 cat <<HELP
sing-box Manager v$VERSION
用法：sb [命令] [参数]
      sb [菜单编号]
      sb -h | --help
      sb -v | --version

不带参数：打开交互式菜单。
除帮助和版本查询外，管理命令需要 root 权限。

安装及更新
  install-manager        安装当前脚本到 /usr/local/bin/sb
  self-update            从 GitHub 更新管理器（不更新核心）
  uninstall-service      彻底卸载代理服务及管理器（删除配置和备份）
  uninstall-manager      同上（兼容旧命令，行为已变更）
  update                 安装/更新 sing-box 核心
  init / install-service / inbounds
                         安装服务及入站管理菜单
  init-standalone        独立代理初始化
  init-entry             入口初始化（旧别名 init-hk）
  init-landing           落地初始化（旧别名 init-tw）
  add-inbound [协议]     添加入站（交互选择）
  delete-inbound         删除指定入站
  add-snell              Snell 入站快捷入口
  注意：已有服务不要直接执行初始化命令。

服务及节点
  start | stop | restart | status
                         启动、停止、重启、查看状态
  logs                   实时服务日志
  info                   仅查看入站信息及客户端链接
  port                   修改入站监听端口
  outbounds              出站管理菜单
  change-relay           修改中转出站
  import-node            导入分享链接（别名 import-outbound）
  export-outbound        优先导出分享链接，不可无损转换则导出 JSON
  relay [出口IP]         测试中转
  test-outbound 标签 [出口IP]
                         测试指定出站
  test                   REALITY 本机测试

分流及维护
  rules                  分流规则管理
  test-route             域名分流测试
  fix-rules              修复规则下载
  monitor                实时日志筛选
  diagnose               综合诊断
  fix-perm               修复文件权限
  backup | restore       备份 / 恢复配置 JSON
  disk | clean           磁盘检查 / 清理
  bbr                    BBR 管理
  public-address         自动检测或设置公网连接地址
  env                    系统环境检测
  argo                   固定 Argo 隧道管理
  argo-stability         Argo 稳定性诊断
  dns                    DNS 与 IPv6 管理（含系统级 IPv6 启停）
  01-37                  对应主菜单编号
  99                     彻底卸载服务
  部分维护功能仅提供数字菜单入口。

示例：
  sb add-inbound snell
  sb test-outbound relay-jp
  sb export-outbound
  sb self-update
HELP
}
proxy_menu(){ local n t; [[ -s $C ]] || return 1; while true; do ui_title '出站节点管理'; proxy_list; columns '01 查看出站详情|02 添加出站|03 修改出站|04 删除出站' '05 测试指定出站|06 设置默认出站|07 测试全部出站|08 分享链接导入|09 导出出站节点|00 返回'; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in 1|01) t=$(select_proxy) && jq --arg t "$t" '.outbounds[]|select(.tag==$t)|del(.password,.obfs.password,.uuid,.psk,.userkey)' "$C";; 2|02) proxy_change add;; 3|03) proxy_change edit;; 4|04) proxy_delete;; 5|05) t=$(select_proxy) && proxy_test "$t";; 6|06) set_final;; 7|07) while IFS= read -r t; do echo "==== $t ===="; proxy_test "$t" || echo '[FAIL]'; done < <(jq -r '.outbounds[]|select(.type=="direct" or .type=="anytls" or .type=="hysteria2" or .type=="shadowsocks" or .type=="vless" or .type=="snell")|.tag' "$C");; 8|08) proxy_import;; 9|09) proxy_export;; 0|00) return;; esac; done; }
# Store disabled rules and mode snapshots outside the native config.
POLICY=/var/lib/sb-manager/sb-policy.json
policy_migrate(){
 local old=/etc/sing-box/sb-policy.json
 [[ -e $old ]] || return 0
 install -d -m 700 /var/lib/sb-manager || return 1
 if [[ -e $POLICY ]]; then
  if cmp -s "$old" "$POLICY"; then
   rm -- "$old" || return 1
  else
   err "新旧策略文件内容不同；请先备份并手动处理 $old 与 $POLICY，拒绝覆盖"
   return 1
  fi
 else
  mv -- "$old" "$POLICY" || return 1
 fi
 chmod 600 "$POLICY" || return 1
 msg OK "旧策略文件已迁移至 $POLICY（未重启服务）"
}
policy_ready(){ policy_migrate || return 1; install -d -m 700 "${POLICY%/*}" || return 1; if [[ ! -e $POLICY ]]; then printf '{"disabled":[],"saved":null}\n' > "$POLICY"; fi; jq -e 'type=="object" and (.disabled|type=="array")' "$POLICY" >/dev/null; }
policy_edit(){ local f; f=$(mktemp "${POLICY%/*}/.policy.XXXXXX") || return 1; if jq "$@" "$POLICY" > "$f"; then mv "$f" "$POLICY"; else rm -f "$f"; return 1; fi; }
policy_normal(){ policy_ready && jq -e '.saved==null' "$POLICY" >/dev/null || { err '请先切回智能分流模式'; return 1; }; }
rule_toggle(){ local i r; policy_normal || return 1; route_list; jq -r '.disabled|to_entries[]|"禁用索引 \(.key): \(.value.rule|tojson)"' "$POLICY"; local action; action=$(ask 'disable/enable' disable) || return 1; i=$(ask '规则索引' '') || return 1; [[ $i =~ ^(0|[1-9][0-9]{0,6})$ ]] || return 1; if [[ $action == disable ]]; then route_index "$i" || return 1; r=$(jq -c --argjson i "$i" '.route.rules[$i]' "$C") || return 1; jq -e '(.action=="sniff" or .action=="resolve" or .ip_is_private==true)|not' <<< "$r" >/dev/null || { err '基础规则不可禁用'; return 1; }; confirm '禁用规则?' || return 0; policy_edit --argjson r "$r" --argjson i "$i" '.disabled += [{rule:$r,index:$i}]' || return 1; if ! edit --argjson i "$i" 'del(.route.rules[$i])'; then policy_edit '.disabled |= .[:-1]'; return 1; fi; elif [[ $action == enable ]]; then r=$(jq -ce --argjson i "$i" '.disabled[$i]' "$POLICY") || return 1; confirm '恢复规则（请检查优先级）?' || return 0; edit --argjson r "$r" '.route.rules |= (.[:$r.index]+[$r.rule]+.[$r.index:])' && policy_edit --argjson i "$i" 'del(.disabled[$i])'; fi; }
mode_switch(){ local m t snapshot; policy_ready || return 1; m=$(ask '模式 smart/direct/relay' smart) || return 1; case $m in smart) jq -e '.saved!=null' "$POLICY" >/dev/null || return 0; confirm '恢复原智能分流规则?' && edit --slurpfile p "$POLICY" '.route.rules=$p[0].saved.rules|.route.final=$p[0].saved.final' && policy_edit '.saved=null';; direct|relay) t=direct; [[ $m == direct ]] || { t=$(select_proxy) || return 1; [[ $t != direct ]] || return 1; }; confirm '切换全局模式（保留基础嗅探、解析及私网拒绝）?' || return 0; if jq -e '.saved==null' "$POLICY" >/dev/null; then snapshot=$(jq -c '.route|{rules,final}' "$C") || return 1; policy_edit --argjson r "$snapshot" '.saved=$r' || return 1; if ! edit --arg t "$t" '.route.rules |= map(select(.action=="sniff" or .action=="resolve" or (.ip_is_private==true and .action=="reject") or .=={"ip_version":6,"action":"reject","method":"default","no_drop":true}))|.route.final=$t'; then policy_edit '.saved=null'; return 1; fi; else edit --arg t "$t" '.route.final=$t'; fi;; *) err '无效模式';; esac; }
route_export(){ local f; policy_ready || return 1; f=$(ask '导出文件路径' "/root/sb-routing-$(date +%s).json") || return 1; [[ ! -e $f ]] || { err '文件已存在'; return 1; }; jq --slurpfile p "$POLICY" '{route:{rules:.route.rules,rule_set:(.route.rule_set // []),final:.route.final},policy:$p[0]}' "$C" > "$f" && echo "已导出 $f（规则 URL 可能包含令牌，请保密）"; }
route_import(){ local f; policy_normal || return 1; f=$(ask '导入文件路径' '') || return 1; jq -e '.route.rules|type=="array"' "$f" >/dev/null || return 1; # only active rules imported; metadata is intentionally not imported
 confirm '替换当前活动分流规则及规则集？保留本机 DNS/出站，不导入禁用规则' || return 0; edit --slurpfile p "$f" '.route.rules=$p[0].route.rules|.route.rule_set=$p[0].route.rule_set|.route.final=$p[0].route.final'; }
add_preset(){ local n name tag target url w; policy_normal || return 1; ui_title '预设规则集管理'; columns '01 AI 全部|02 OpenAI|03 Claude|04 Gemini|05 Crypto 全部|06 Binance|07 OKX|08 Web3|09 TikTok|10 Netflix|11 YouTube|12 Disney+|13 Spotify|14 Twitch' '15 Telegram|16 Twitter/X|17 Discord|18 GitHub|19 Google|20 Microsoft|21 Apple|22 Cloudflare|23 国外游戏|24 Speedtest|25 广告拦截|26 中国大陆域名|27 中国大陆IP'; echo '支持逗号多选；每个规则集先下载检测'; n=$(ask '编号' '') || return 1; target=$(route_target) || return 1; local -a names=(none 'category-ai-!cn' openai anthropic google-gemini category-cryptocurrency binance okx web3 tiktok netflix youtube disney spotify twitch telegram twitter discord github google microsoft apple cloudflare category-games-!cn speedtest category-ads-all cn cn); local -a picks; IFS=, read -ra picks <<< "$n"; for n in "${picks[@]}"; do [[ $n =~ ^[0-9]{1,2}$ ]] || return 1; n=$((10#$n)); ((n>=1 && n<=27)) || return 1; name=${names[n]}; tag="preset-$name"; url="$BASE/$name.srs"; if ((n==27)); then tag=preset-geoip-cn; url="${BASE%/geosite}/geoip/cn.srs"; fi; if ! curl -fsSL --max-time 25 -o /dev/null "$url"; then err "上游规则集不可用: $name，跳过"; continue; fi; confirm "添加 $tag → $target?" || continue; edit --arg tag "$tag" --arg url "$url" --arg t "$target" '.http_clients=((.http_clients // [])|if any(.[];.tag=="rule-download") then . else .+[{tag:"rule-download"}] end)|.route.default_http_client=(.route.default_http_client // "rule-download")|.route.rule_set=((.route.rule_set // [])|if any(.[];.tag==$tag) then . else .+[{type:"remote",tag:$tag,format:"binary",url:$url,update_interval:"24h"}] end)|.route.rules |= (([to_entries[]|select(.value.action=="resolve")|.key][0] // length) as $i | .[:$i]+[({rule_set:[$tag]}+(if $t=="reject" then {action:"reject"} else {action:"route",outbound:$t} end))]+.[$i:])' || return 1; done; }
route_manage(){ local n; [[ -s $C ]] || return 1; policy_ready || return 1; while true; do ui_title '分流规则管理'; jq -r '"默认出站: \(.route.final) | 活动规则: \(.route.rules|length)"' "$C"; columns '01 查看规则|02 添加/修改/删除/排序规则|05 启用/禁用规则|07 添加预设规则集|08 自定义规则集管理' '13 设置默认出站|14 切换分流模式|15 测试域名/IP|16 实时日志|17 导入配置|18 导出配置|00 返回'; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in 1|01) route_list; jq '.disabled' "$POLICY";; 2|02|8|08) policy_normal && legacy_route_manage;; 5|05) rule_toggle;; 7|07) add_preset;; 13) policy_normal && set_final;; 14) mode_switch;; 15) route_test;; 16) monitor;; 17) route_import;; 18) route_export;; 0|00) return;; esac; done; }
# Append/remove only the selected inbound; never regenerate other credentials.
inbound_list(){ jq -r '.inbounds[]|[.tag,.type,(.listen_port // "-")]|@tsv' "$C"; }
inbound_add() (
 local w type tag p pw sni cp kp keys priv uuid sid target
 [[ -s $C ]] || { err '请先安装服务'; exit 1; }
 need jq openssl sing-box || exit 1
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 inbound_list
 type=$(ask '协议 hysteria2/anytls/vless/shadowsocks/snell' "${1:-anytls}") || exit 1
 case $type in hysteria2) p=443;; anytls) p=59007;; vless) p=443;; shadowsocks) p=18834;; snell) p=8443;; *) err '不支持的协议'; exit 1;; esac
 tag=$(ask '新入站唯一标签' "$type-in") || exit 1
 [[ $tag =~ ^[A-Za-z0-9_.-]+$ ]] || { err '标签无效'; exit 1; }
 jq -e --arg t "$tag" 'any(.inbounds[];.tag==$t)' "$C" >/dev/null && { err '标签重复'; exit 1; }
 if [[ $type == snell ]]; then
  snell_inbound "$C" "$w/raw" || exit 1
  jq --arg t "$tag" '.inbounds[-1].tag=$t' "$w/raw" > "$w/new" || exit 1
 else
  p=$(ask '内部监听端口' "$p") || exit 1; port "$p" || exit 1; p=$((10#$p))
  # HY2 uses UDP; AnyTLS/VLESS use TCP; SS uses both.
  if jq -e --argjson p "$p" --arg t "$type" 'any(.inbounds[]; .listen_port==$p and (if $t=="hysteria2" then (.type!="anytls" and .type!="vless" and .type!="snell") elif $t=="shadowsocks" then true else .type!="hysteria2" end))' "$C" >/dev/null; then err '监听端口冲突'; exit 1; fi
  case $type in
   hysteria2|anytls)
    cp=$(jq -r '[.inbounds[]|select(.tls.certificate_path != null and .tls.key_path != null)|.tls.certificate_path][0] // empty' "$C")
    kp=$(jq -r '[.inbounds[]|select(.tls.certificate_path != null and .tls.key_path != null)|.tls.key_path][0] // empty' "$C")
    sni=$(ask 'TLS SNI' "$(jq -r '[.inbounds[]|select(.tls.certificate_path != null and .tls.key_path != null)|.tls.server_name][0] // "proxy.example.com"' "$C")") || exit 1
    [[ $sni =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
    if [[ -z $cp && -z $kp ]]; then
     # Keep existing certificates untouched, including legacy layouts.
     local cd="/etc/sing-box/cert/inbound-$tag"; [[ ! -e $cd ]] || { err '证书目录已存在，请检查后重试'; exit 1; }
     mkdir -p "$cd" || exit 1
     cp="$cd/fullchain.pem"; kp="$cd/server.key"
     openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" -keyout "$kp" -out "$cp" || exit 1
     local u g; u=$(systemctl show sing-box -p User --value); u=${u:-root}; g=$(systemctl show sing-box -p Group --value); g=${g:-$(id -gn "$u")}
     chown root:"$g" "$cd" "$kp" "$cp" && chmod 750 "$cd" && chmod 640 "$kp" && chmod 644 "$cp" || exit 1
    fi
    [[ -s $cp && -s $kp ]] || { err '现有证书不完整，拒绝覆盖'; exit 1; }
    pw=$(openssl rand -hex 24) || exit 1
    jq --arg t "$tag" --arg type "$type" --argjson p "$p" --arg pw "$pw" --arg s "$sni" --arg cp "$cp" --arg kp "$kp" '.inbounds += [{type:$type,tag:$t,listen:"0.0.0.0",listen_port:$p,users:[{name:"client",password:$pw}],tls:{enabled:true,server_name:$s,certificate_path:$cp,key_path:$kp}}]' "$C" > "$w/new" || exit 1;;
   vless)
    target=$(ask 'REALITY TLS 目标域名' www.apple.com) || exit 1
    [[ $target =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
    keys=$(sing-box generate reality-keypair) || exit 1; priv=$(awk '/PrivateKey/{print $NF}' <<< "$keys"); [[ -n $priv ]] || exit 1
    uuid=$(sing-box generate uuid) || exit 1; sid=$(openssl rand -hex 8) || exit 1
    jq --arg t "$tag" --argjson p "$p" --arg s "$target" --arg k "$priv" --arg u "$uuid" --arg sid "$sid" '.inbounds += [{type:"vless",tag:$t,listen:"0.0.0.0",listen_port:$p,users:[{name:"client",uuid:$u,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$s,reality:{enabled:true,handshake:{server:$s,server_port:443},private_key:$k,short_id:[$sid]}}}]' "$C" > "$w/new" || exit 1;;
   shadowsocks)
    pw=$(openssl rand -base64 16) || exit 1
    jq --arg t "$tag" --argjson p "$p" --arg k "$pw" '.inbounds += [{type:"shadowsocks",tag:$t,listen:"0.0.0.0",listen_port:$p,method:"2022-blake3-aes-128-gcm",password:$k}]' "$C" > "$w/new" || exit 1;;
  esac
 fi
 confirm '仅添加该入站，保留其他配置；应用时将重启服务，继续?' || exit 0
 apply "$w/new" && info
)
inbound_delete(){
 local t
 [[ -s $C ]] || return 1
 inbound_list
 t=$(ask '待删除入站标签' '') || return 1
 jq -e --arg t "$t" 'any(.inbounds[];.tag==$t)' "$C" >/dev/null || { err '入站不存在'; return 1; }
 [[ $(jq '.inbounds|length' "$C") -gt 1 ]] || { err '至少保留一个入站'; return 1; }
 if jq -e --arg t "$t" 'del(.inbounds[]|select(.tag==$t))|any(..|strings;.==$t)' "$C" >/dev/null || { [[ -s $POLICY ]] && jq -e --arg t "$t" 'any(..|strings;.==$t)' "$POLICY" >/dev/null; }; then err '入站仍被规则或其他配置引用，请先解除引用'; return 1; fi
 confirm "仅删除 $t（保留证书及其他节点，服务将重启）?" || return 0
 edit --arg t "$t" '.inbounds |= map(select(.tag!=$t))'
}
service_menu(){
 local n
 while true; do
  ui_title '安装服务 / 入站管理'
  columns '01 独立代理（首次安装）|02 入口中转（首次安装）|03 落地服务（首次安装）' '04 查看现有入站|05 添加协议入站|06 删除指定入站|00 返回'
  read -rp "$(ui_prompt '请选择操作：')" n || return
  case $n in
   1|01|2|02|3|03)
    if [[ -s $C ]] && jq -e '(.inbounds // [])|length>0' "$C" >/dev/null 2>&1; then err '已有入站，请使用05/06；拒绝重新初始化以保护节点'; continue; fi
    case $n in 1|01) init_role standalone;; 2|02) init_role entry;; *) init_role landing;; esac;;
   4|04) [[ -s $C ]] && inbound_list;;
   5|05) inbound_add;;
   6|06) inbound_delete;;
   0|00) return;;
   *) err '无效选项';;
  esac
 done
}
BBR_CONF=/etc/sysctl.d/99-sb-bbr.conf
BBR_STATE=/var/lib/sb-manager/bbr-original
bbr_status(){
 sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc 2>/dev/null
}
bbr_enable(){
 local old q tmp
 if [[ -e $BBR_CONF || -e $BBR_STATE ]]; then err '已有 BBR 管理记录，请先查看或恢复'; return 1; fi
 old=$(sysctl -n net.ipv4.tcp_congestion_control) && q=$(sysctl -n net.core.default_qdisc) || return 1
 if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
  command -v modprobe >/dev/null && modprobe tcp_bbr 2>/dev/null || :
 fi
 sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || { err '内核未提供 BBR；容器可能需要宿主机支持'; return 1; }
 confirm '启用 BBR + fq，并写入持久化 sysctl 配置?' || return 0
 mkdir -p "${BBR_STATE%/*}" || return 1
 printf '%s\n%s\n' "$old" "$q" > "$BBR_STATE" || return 1
 tmp=$(mktemp /etc/sysctl.d/.sb-bbr.XXXXXX) || { rm -f "$BBR_STATE"; return 1; }
 printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$tmp"
 if sysctl -p "$tmp" && mv "$tmp" "$BBR_CONF"; then msg OK 'BBR 已启用'; bbr_status; else
  sysctl -w "net.ipv4.tcp_congestion_control=$old" "net.core.default_qdisc=$q" || :
  rm -f "$tmp"; err '启用失败，已尝试恢复；保留原设置记录'; return 1
 fi
}
bbr_restore(){
 local old q
 [[ -s $BBR_STATE ]] || { err '没有本工具保存的原设置'; return 1; }
 { read -r old; read -r q; } < "$BBR_STATE"
 [[ $old =~ ^[A-Za-z0-9_]+$ && $q =~ ^[A-Za-z0-9_]+$ ]] || return 1
 confirm '恢复启用前的 TCP 拥塞控制和默认队列?' || return 0
 sysctl -w "net.ipv4.tcp_congestion_control=$old" "net.core.default_qdisc=$q" || return 1
 rm -f "$BBR_CONF" "$BBR_STATE"; msg OK '已恢复原运行时设置'; bbr_status
}
bbr_menu(){
 local n
 while true; do ui_title 'BBR 管理'; bbr_status
 columns '01 查看 BBR 状态|02 启用 BBR + fq' '03 恢复原设置|00 返回'
 read -rp "$(ui_prompt '请选择操作：')" n || return
 case $n in 1|01) bbr_status;; 2|02) bbr_enable;; 3|03) bbr_restore;; 0|00) return;; *) err '无效选项';; esac
 done
}
DNS_STATE=/var/lib/sb-manager/dns-original.json
dns_show(){
 [[ -s $C ]] || { err '请先初始化服务'; return 1; }
 jq '{dns,default_domain_resolver:.route.default_domain_resolver,resolve_rules:[.route.rules[]?|select(.action=="resolve")],outbound_resolvers:[.outbounds[]?|select(has("domain_resolver"))|{tag,domain_resolver}]}' "$C"
}
dns_family_test(){
 local family=$1 url ip
 if [[ $family == 4 ]]; then url=https://api.ipify.org; else url=https://api6.ipify.org; fi
 ip=$(curl -"$family" --noproxy '*' -fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null) || return 1
 printf '%s' "$ip" | python3 -c 'import ipaddress,sys
try:
 a=ipaddress.ip_address(sys.stdin.read().strip())
 assert a.version==int(sys.argv[1]) and a.is_global and not a.is_multicast
 print(a)
except (ValueError,AssertionError): sys.exit(1)' "$family"
}
dns_network(){
 local v4 v6
 ip -6 addr show scope global; ip -6 route
 v4=$(dns_family_test 4) || v4='不可达或检测接口失败'
 v6=$(dns_family_test 6) || v6='不可达或检测接口失败'
 printf 'IPv4 HTTPS：%s\nIPv6 HTTPS：%s\n' "$v4" "$v6"
}
# Save only DNS-related fields, never passwords or the entire configuration.
# Resolve rules are keyed by their contents excluding strategy, not by array index.
dns_snapshot(){
 [[ -s $DNS_STATE ]] && return 0
 install -d -m 700 /var/lib/sb-manager || return 1
 local t; t=$(mktemp /var/lib/sb-manager/.dns-original.XXXXXX) || return 1
 jq '{dns_present:has("dns"),dns:.dns,default_present:(.route|has("default_domain_resolver")),default_resolver:.route.default_domain_resolver,resolve:[.route.rules[]?|select(.action=="resolve")|{key:del(.strategy),present:has("strategy"),strategy}],outbounds:[.outbounds[]?|select(has("domain_resolver"))|{tag,domain_resolver}]}' "$C" > "$t" && chmod 600 "$t" && mv "$t" "$DNS_STATE" || { rm -f "$t"; return 1; }
}
dns_strategy(){
 local strategy=$1
 [[ -s $C ]] || { err '请先初始化服务'; return 1; }
 case $strategy in ipv4_only|prefer_ipv4|ipv6_only|prefer_ipv6) ;; *) err '无效策略'; return 1;; esac
 echo "将设置 DNS 默认策略及显式 resolve 动作为 $strategy；保留出站节点专用 resolver、DNS 规则及其他配置。"
 echo '此设置不会禁用系统 IPv6，也不会拦截直接请求 IPv6 地址。'
 confirm '备份并应用？sing-box 将短暂重启' || return 0
 dns_snapshot || return 1
 edit --arg s "$strategy" '.dns.strategy=$s | (.route.rules[]?|select(.action=="resolve")|.strategy)=$s | if (.route.default_domain_resolver|type)=="object" then .route.default_domain_resolver.strategy=$s else . end'
}
dns_auto(){
 local v4='' v6='' strategy
 echo '检测 VPS 直连 IPv4 / IPv6 HTTPS（不使用 shell 代理）...'
 v4=$(dns_family_test 4) || :
 v6=$(dns_family_test 6) || :
 printf 'IPv4：%s\nIPv6：%s\n' "$v4" "$v6"
 if [[ -n $v4 && -n $v6 ]]; then strategy=prefer_ipv4
 elif [[ -n $v4 ]]; then strategy=ipv4_only
 elif [[ -n $v6 ]]; then strategy=ipv6_only
 else err '两个检测接口均不可达，无法可靠判断，不修改配置'; return 1; fi
 printf '建议策略：%s（检测结果仅代表当前 HTTPS 可达性）\n' "$strategy"
 dns_strategy "$strategy"
}
# Build modern DNS server objects with literal IP bootstrap and verified TLS SNI.
dns_build_server(){
 local t=$1 a=$2 name=$3 p=$4 path=$5 tag=$6
 jq -n --arg t "$t" --arg a "$a" --arg n "$name" --argjson p "$p" --arg path "$path" --arg tag "$tag" '
 if $t=="local" then {type:"local",tag:$tag}
 else {type:$t,tag:$tag,server:$a,server_port:$p}
 + (if (["tls","https","quic","h3"]|index($t))!=null then {tls:{enabled:true,server_name:$n}} else {} end)
 + (if $t=="https" or $t=="h3" then {path:$path} else {} end) end'
}
dns_server_set() (
 local choice protocol t address secondary='' name='' p=53 path=/dns-query w add='' custom=0
 [[ -s $C ]] || { err '请先初始化服务'; exit 1; }
 ui_title 'DNS 服务商预设'
 columns '01 系统默认 DNS|02 Cloudflare|03 Google|04 Quad9' '05 AdGuard|06 阿里云 DNS|07 DNSPod|08 自定义 DNS'
 echo '00 返回'
 read -rp "$(ui_prompt '请选择服务商：')" choice || exit 1
 case $choice in
  0|00) exit 0;;
  1|01) t=local; address='';;
  2|02) address=1.1.1.1; secondary=1.0.0.1; name=cloudflare-dns.com;;
  3|03) address=8.8.8.8; secondary=8.8.4.4; name=dns.google;;
  4|04) address=9.9.9.9; secondary=149.112.112.112; name=dns.quad9.net;;
  5|05) address=94.140.14.14; secondary=94.140.15.15; name=dns.adguard-dns.com;;
  6|06) address=223.5.5.5; secondary=223.6.6.6; name=dns.alidns.com;;
  7|07) address=119.29.29.29; secondary=''; name='';;
  8|08) custom=1; address='';;
  *) err '无效选项'; exit 1;;
 esac
 if [[ $choice != 1 && $choice != 01 ]]; then
  echo '01 UDP | 02 TCP | 03 DoH | 04 DoT | 05 DoQ | 06 DoH3'
  protocol=$(ask '选择协议（部分服务商不支持所有协议）' 03) || exit 1
  case $protocol in 1|01) t=udp;; 2|02) t=tcp;; 3|03) t=https; p=443;; 4|04) t=tls; p=853;; 5|05) t=quic; p=853;; 6|06) t=h3; p=443;; *) err '无效协议'; exit 1;; esac
  # Conservative verified presets: other combinations require custom input.
  case "$choice:$t" in
   2:quic|02:quic|3:quic|03:quic|4:quic|04:quic|7:https|07:https|7:tls|07:tls|7:quic|07:quic|7:h3|07:h3|4:h3|04:h3|6:h3|06:h3|3:h3|03:h3)
    err '该预设未确认支持此协议，请选择其他协议或自定义'; exit 1;;
  esac
  if ((custom)); then
   address=$(ask 'DNS 服务器 IP（IPv4/IPv6，不含端口或 URL）' 1.1.1.1) || exit 1
   p=$(ask '端口' "$p") || exit 1
   [[ $p =~ ^[0-9]{1,5}$ ]] && ((10#$p>=1 && 10#$p<=65535)) || { err '端口无效'; exit 1; }
   p=$((10#$p))
   if [[ $t == https || $t == h3 || $t == tls || $t == quic ]]; then
    name=$(ask 'TLS 证书域名（SNI）' '') || exit 1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && $name == *.* ]] || { err '请输入证书域名'; exit 1; }
   fi
   if [[ $t == https || $t == h3 ]]; then path=$(ask 'HTTPS 查询路径' /dns-query) || exit 1; [[ $path == /* && $path != *[[:space:]]* ]] || exit 1; fi
  fi
  address=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]))' "$address" 2>/dev/null) || { err 'DNS IP 无效'; exit 1; }
  # Secondary is explicitly selectable, not a fictitious automatic failover.
  if [[ -n $secondary ]] && confirm "同时保存备用服务器 $secondary（仅供手动切换，不自动故障转移）?"; then add=$secondary; fi
 fi
 jq -e '[.dns.servers[]?|select(.tag=="local-dns")]|length==1' "$C" >/dev/null || { err '未找到唯一 local-dns，拒绝修改'; exit 1; }
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 dns_build_server "$t" "$address" "$name" "$p" "$path" local-dns > "$w/main" || exit 1
 jq . "$w/main"
 if [[ -n $add ]]; then
  if jq -e 'any(.dns.servers[]?;.tag=="sb-dns-secondary")' "$C" >/dev/null; then err '备用标签已存在，请先通过备用切换或恢复原始 DNS 处理'; exit 1; fi
  dns_build_server "$t" "$add" "$name" "$p" "$path" sb-dns-secondary > "$w/secondary" || exit 1
 else echo null > "$w/secondary"; fi
 confirm '备份并应用 DNS 配置？sing-box 将短暂重启' || exit 0
 dns_snapshot || exit 1
 edit --slurpfile a "$w/main" --slurpfile b "$w/secondary" '(.dns.servers[]|select(.tag=="local-dns"))=$a[0] | if $b[0]!=null then .dns.servers += [$b[0]] else . end'
)
dns_swap(){
 jq -e '([.dns.servers[]?|select(.tag=="local-dns")]|length)==1 and ([.dns.servers[]?|select(.tag=="sb-dns-secondary")]|length)==1' "$C" >/dev/null || { err '未配置唯一主备 DNS'; return 1; }
 confirm '交换主备 DNS 地址（保留标签引用），重启 sing-box?' || return 0
 dns_snapshot || return 1
 edit '(.dns.servers[]|select(.tag=="local-dns")) as $a | (.dns.servers[]|select(.tag=="sb-dns-secondary")) as $b | .dns.servers |= map(if .tag=="local-dns" then ($b|.tag="local-dns") elif .tag=="sb-dns-secondary" then ($a|.tag="sb-dns-secondary") else . end)'
}
# Isolated sing-box instance: use a temporary SOCKS listener and a DNS resolve
# rule, then measure HTTPS success. This is end-to-end latency, not DNS RTT.
dns_probe_configured() (
 local w tag p pid='' url result
 [[ -s $C ]] || exit 1
 w=$(mktemp -d) || exit 1
 trap '[[ -z $pid ]] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; rm -rf "$w"' EXIT
 trap 'exit 130' INT; trap 'exit 143' TERM
 for p in 10896 10897 10898; do [[ -z $(ss -H -lnt "sport = :$p") ]] && break; done
 [[ -z $(ss -H -lnt "sport = :$p") ]] || exit 1
 for tag in local-dns sb-dns-secondary; do
  jq -e --arg t "$tag" 'any(.dns.servers[]?;.tag==$t)' "$C" >/dev/null || continue
  jq --arg t "$tag" --argjson p "$p" '{log:{level:"debug"},dns:{servers:[.dns.servers[]|select(.tag==$t)],final:$t},inbounds:[{type:"mixed",tag:"test-in",listen:"127.0.0.1",listen_port:$p}],outbounds:[{type:"direct",tag:"direct"}],route:{default_domain_resolver:$t,rules:[{action:"resolve",server:$t}],final:"direct"}}' "$C" > "$w/config.json" || exit 1
  printf '\n=== %s ===\n' "$tag"
  if ! sing-box check -c "$w/config.json"; then echo '独立测试配置不兼容（可能依赖其他 DNS/出站）'; continue; fi
  sing-box run -D "$w" -c "$w/config.json" > "$w/log" 2>&1 & pid=$!
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
   for url in https://www.cloudflare.com/ https://www.google.com/; do
    if result=$(curl --noproxy '' --proxy "socks5h://127.0.0.1:$p" -sS -o /dev/null --connect-timeout 5 --max-time 10 -w 'HTTP %{http_code} | 总耗时 %{time_total}s' "$url"); then printf '%s %s\n' "$url" "$result"; else echo "$url 请求失败"; fi
   done
  fi
  kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; pid=''
  grep -Ei 'dns:.*(lookup|exchange)|ERROR' "$w/log" | tail -15 || :
 done
 echo '总耗时包含 DNS、TCP、TLS 和 HTTP；不是纯 DNS 延迟。'
)
dns_lookup_test(){
 local host
 host=$(ask '测试域名' www.cloudflare.com) || return 1
 [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { err '无效域名'; return 1; }
 echo '系统解析器测试（不是 sing-box 内部 DNS）'
 if command -v dig >/dev/null; then
  dig +time=3 +tries=1 "$host" A; dig +time=3 +tries=1 "$host" AAAA
 else
  timeout 8 getent ahostsv4 "$host" || :
  timeout 8 getent ahostsv6 "$host" || :
 fi
 echo 'sing-box 近期 DNS 错误：'
 journalctl -u sing-box -n 300 --no-pager -o cat | grep -Ei 'dns:.*(failed|SERVFAIL)|router: lookup' | tail -20 || :
}
dns_restore(){
 [[ -s $DNS_STATE && -s $C ]] || { err '无 DNS 原始快照'; return 1; }
 echo '恢复首次 DNS 管理前的 DNS 段、默认 resolver 及仍匹配的 resolve 规则策略；不恢复整个配置。'
 confirm '恢复原始 DNS 设置并重启 sing-box?' || return 0
 edit --slurpfile b "$DNS_STATE" '
 $b[0] as $o |
 (if $o.dns_present then .dns=$o.dns else del(.dns) end) |
 (if $o.default_present then .route.default_domain_resolver=$o.default_resolver else del(.route.default_domain_resolver) end) |
 (.route.rules[]?|select(.action=="resolve")) |= (
  . as $r | [$o.resolve[]|select(.key==($r|del(.strategy)))] as $m |
  if ($m|length)==1 then if $m[0].present then .strategy=$m[0].strategy else del(.strategy) end else . end
 )' || return 1
 rm -f "$DNS_STATE"
}
IPV6_CONF=/etc/sysctl.d/99-sb-ipv6.conf
IPV6_STATE=/var/lib/sb-manager/ipv6-original.json
ipv6_status(){
 local p
 echo '系统 IPv6 接口状态（1=禁用，0=启用）：'
 for p in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  [[ -r $p ]] || continue
  printf '%-20s %s\n' "$(basename "$(dirname "$p")")" "$(cat "$p")"
 done
 ip -6 addr show; ip -6 route show
 [[ ! -e $IPV6_CONF ]] || printf '持久化配置：%s\n' "$IPV6_CONF"
 [[ ! -e $IPV6_STATE ]] || printf '原始状态记录：%s\n' "$IPV6_STATE"
}
ipv6_capture(){
 python3 -c 'import glob,json
d={p.split("/")[-2]:int(open(p).read().strip()) for p in glob.glob("/proc/sys/net/ipv6/conf/*/disable_ipv6")}
assert "all" in d and "default" in d and all(v in (0,1) for v in d.values())
print(json.dumps(d))'
}
ipv6_restore_runtime(){
 python3 - "$1" <<'PYIP6'
import json,sys,pathlib
d=json.load(open(sys.argv[1]))
assert isinstance(d,dict) and "all" in d and "default" in d
assert all(k not in (".","..") and "/" not in k and v in (0,1) for k,v in d.items())
base=pathlib.Path("/proc/sys/net/ipv6/conf")
for k in ["all","default"]+[p.name for p in base.iterdir() if p.name not in ("all","default")]:
 p=base/k/"disable_ipv6"
 if p.exists():
  v=d.get(k,d["default"])
  if int(p.read_text())!=v: p.write_text(str(v)+"\n")
PYIP6
}
ipv6_restore(){
 [[ -s $IPV6_STATE ]] || { err '没有本工具保存的 IPv6 原始状态'; return 1; }
 if [[ "${1:-}" != purge ]]; then
  confirm '恢复原始 IPv6 接口状态并移除本工具的持久化设置？可能影响网络连接' || return 0
 fi
 ipv6_restore_runtime "$IPV6_STATE" || { err '恢复失败，保留记录'; return 1; }
 rm -f -- "$IPV6_CONF" "$IPV6_STATE" || return 1
 msg OK '已恢复记录的 IPv6 状态；地址与路由可能需网络管理器重新获取'
}
ipv6_change() (
 local v=$1 answer w had=0
 [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || { err '内核 IPv6 sysctl 不可用'; exit 1; }
 [[ ! -e $IPV6_CONF || -s $IPV6_STATE ]] || { err '已存在无原始记录的 IPv6 配置，请先手动处理'; exit 1; }
 echo '系统级操作影响所有网卡、IPv6 回环地址及依赖 IPv6 的服务。请使用 IPv4 SSH；容器可能无权限。'
 if [[ $v == 1 ]]; then
  read -rp '确认禁用请输入 DISABLE：' answer || exit 1
  [[ $answer == DISABLE ]] || exit 0
 else
  confirm '启用所有接口 IPv6 并持久化？' || exit 0
 fi
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 ipv6_capture > "$w/before" || exit 1
 if [[ -e $IPV6_CONF ]]; then cp -a "$IPV6_CONF" "$w/old" || exit 1; had=1; fi
 install -d -m 700 /var/lib/sb-manager || exit 1
 if [[ ! -s $IPV6_STATE ]]; then install -m 600 "$w/before" "$IPV6_STATE" || exit 1; fi
 printf 'net.ipv6.conf.all.disable_ipv6 = %s\nnet.ipv6.conf.default.disable_ipv6 = %s\nnet.ipv6.conf.lo.disable_ipv6 = %s\n' "$v" "$v" "$v" > "$w/new" || exit 1
 local p ok=1
 for p in /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6 /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  [[ -e $p ]] || continue
  if [[ $(cat "$p") != "$v" ]]; then printf '%s\n' "$v" > "$p" || { ok=0; break; }; fi
 done
 if ((ok)) && install -m 644 "$w/new" "$IPV6_CONF"; then msg OK '系统 IPv6 设置已应用'; ipv6_status; exit 0; fi
 err '设置失败，尝试恢复操作前的状态'
 ipv6_restore_runtime "$w/before" || err '运行时恢复失败，请检查权限'
 if ((had)); then cp -a "$w/old" "$IPV6_CONF" || :; else rm -f "$IPV6_CONF" || :; fi
 exit 1
)
IPV6_BLOCK_RULE='{"ip_version":6,"action":"reject","method":"default","no_drop":true}'
ipv6_block_status(){
 [[ -s $C ]] || { err '请先初始化服务'; return 1; }
 jq --argjson r "$IPV6_BLOCK_RULE" '{managed_rule_first:(.route.rules[0]==$r),ipv6_reject_rules:[.route.rules[]?|select(.ip_version==6 and .action=="reject")],dns_strategy:(.dns.strategy//"核心默认")}' "$C"
}
ipv6_block(){
 [[ -s $C ]] || { err '请先初始化服务'; return 1; }
 local op=$1
 if [[ $op == on ]]; then
  confirm '在路由最前面拒绝 IPv6 目标（影响所有入站及中转），重启 sing-box?' || return 0
  edit --argjson r "$IPV6_BLOCK_RULE" '.route.rules=([$r]+[(.route.rules//[])[]|select(.!=$r)])'
 else
  confirm '删除本功能使用的 IPv6 拒绝规则，重启 sing-box？不改变系统 IPv6 或 DNS' || return 0
  edit --argjson r "$IPV6_BLOCK_RULE" '.route.rules |= map(select(.!=$r))'
 fi
}
ipv4_only_mode() (
 local answer w had=0 newstate=0 p ok=1 current
 [[ -s $C ]] || { err '请先初始化服务'; exit 1; }
 [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || { err '内核 IPv6 sysctl 不可用，请分别管理 DNS 和路由'; exit 1; }
 [[ ! -e $IPV6_CONF || -s $IPV6_STATE ]] || { err '已有来源不明的 IPv6 配置，请先手动处理'; exit 1; }
 if [[ -s $POLICY ]] && jq -e '.saved!=null' "$POLICY" >/dev/null; then err '请先恢复智能分流，再启用一键模式'; exit 1; fi
 echo '将设置 DNS 为 ipv4_only、拒绝 IPv6 目标、禁用系统 IPv6。影响所有入站与中转。请使用 IPv4 SSH；IPv6 专用节点可能不可用。'
 echo 'Argo 已配置时另行检查并确认 IPv4 网络修复；不会无条件覆盖现有隧道配置。'
 read -rp '确认请输入 IPV4ONLY：' answer || exit 1
 [[ $answer == IPV4ONLY ]] || exit 0
 w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 ipv6_capture > "$w/before" || exit 1
 if [[ -e $IPV6_CONF ]]; then cp -a "$IPV6_CONF" "$w/old" || exit 1; had=1; fi
 jq --argjson r "$IPV6_BLOCK_RULE" '
 .dns.strategy="ipv4_only" |
 (.route.rules[]?|select(.action=="resolve")|.strategy)="ipv4_only" |
 (if (.route.default_domain_resolver|type)=="object" then .route.default_domain_resolver.strategy="ipv4_only" else . end) |
 .route.rules=([$r]+[(.route.rules//[])[]|select(.!=$r)])' "$C" > "$w/new" || exit 1
 check "$w/new" || exit 1
 dns_snapshot || exit 1
 install -d -m 700 /var/lib/sb-manager || exit 1
 if [[ ! -s $IPV6_STATE ]]; then install -m 600 "$w/before" "$IPV6_STATE" || exit 1; newstate=1; fi
 printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' > "$w/sysctl"
 for p in /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6 /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  [[ -e $p ]] || continue
  if [[ $(cat "$p") != 1 ]]; then printf '1\n' > "$p" || { ok=0; break; }; fi
 done
 if ! ((ok)) || ! install -m 644 "$w/sysctl" "$IPV6_CONF" || ! apply "$w/new"; then
  err '一键模式应用失败，尝试恢复操作前的系统 IPv6 状态'
  if ipv6_restore_runtime "$w/before"; then
   if ((had)); then cp -a "$w/old" "$IPV6_CONF" || exit 1; else rm -f "$IPV6_CONF" || exit 1; fi
   if ((newstate)); then rm -f "$IPV6_STATE"; fi
  else err '系统恢复失败，保留原始状态记录'; fi
  exit 1
 fi
 msg OK '系统 IPv6、DNS 和路由设置已应用'
 if [[ -s $ARGO_UNIT ]]; then
  current=$(systemctl show sb-argo.service -p ExecStart --value 2>/dev/null) || current=''
  if grep -Eq -- '--edge-ip-version[ =]+4([ ;]|$)' <<< "$current"; then echo 'Argo 已配置 IPv4，无需修改'; argo_health || :
  else echo 'Argo 尚未显式设置 IPv4；可确认执行 IPv4 自动修复'; argo_network_set repair || { err 'Argo 修复未成功；其余三项已应用，请单独检查'; exit 1; }; fi
 fi
 echo '恢复方法：19 解除路由拦截、10 恢复 DNS、15 恢复系统 IPv6；Argo 网络参数在菜单 36 单独管理。'
)
dns_menu(){
 local n
 while true; do
 ui_title 'DNS 与 IPv6 管理'
 if [[ -s $C ]]; then jq -r '"默认 DNS 策略："+(.dns.strategy//"核心默认")' "$C"; fi
 columns '01 查看当前 DNS 配置|02 检测 IPv4 / IPv6|03 自动选择解析策略|04 仅使用 IPv4|05 优先使用 IPv4|06 仅使用 IPv6' '07 优先使用 IPv6|08 设置 DNS 服务器|09 DNS 解析测试|10 恢复原始 DNS 配置|11 主备 DNS 切换|12 DNS 连通及耗时测试'
 columns '13 系统 IPv6 状态|14 禁用系统 IPv6' '15 恢复系统 IPv6|16 启用系统 IPv6'
 columns '17 IPv6 拦截状态|18 拦截 IPv6 流量' '19 解除 IPv6 拦截|20 一键 IPv4-only 模式'
 echo '00 返回'
 read -rp "$(ui_prompt '请选择操作：')" n || return
 case $n in
  1|01) dns_show;; 2|02) dns_network;; 3|03) dns_auto;; 4|04) dns_strategy ipv4_only;; 5|05) dns_strategy prefer_ipv4;;
  6|06) dns_strategy ipv6_only;; 7|07) dns_strategy prefer_ipv6;; 8|08) dns_server_set;; 9|09) dns_lookup_test;; 10) dns_restore;; 11) dns_swap;; 12) dns_probe_configured;; 13) ipv6_status;; 14) ipv6_change 1;; 15) ipv6_restore;; 16) ipv6_change 0;; 17) ipv6_block_status;; 18) ipv6_block on;; 19) ipv6_block off;; 20) ipv4_only_mode;;
  0|00) return;; *) err '无效选项';;
 esac
 done
}
manager_status(){
 local st core final mode
 printf '系统：%s | 架构：%s | 虚拟化：%s\n' "$(env_os)" "$(env_arch)" "$(virt)"
 printf 'Argo：%s\n' "$(systemctl is-active sb-argo.service 2>/dev/null || :)"
 st=$(systemctl is-active sing-box 2>/dev/null || :)
 core=$(sing-box version 2>/dev/null | head -n 1); core=${core#sing-box version }; core=${core:-未安装}
 printf '服务状态：'; case $st in active) paint '1;32' '● 运行中';; activating|deactivating) paint '1;33' "$st";; *) paint '1;31' "未运行 (${st:-unknown})";; esac
 printf '    核心版本：%s\n' "$core"
 if [[ -s $C ]] && command -v jq >/dev/null; then
  jq -r '"入站节点：\(.inbounds|length)    出站节点：\(.outbounds|length)    活动规则：\(.route.rules // [] | length)"' "$C" 2>/dev/null || :
  final=$(jq -r '.route.final // "(未设置)"' "$C" 2>/dev/null)
  mode='智能分流/自定义'
  if [[ -s $POLICY ]] && jq -e '.saved != null' "$POLICY" >/dev/null 2>&1; then
   if [[ $final == direct ]]; then mode='全局直连'; else mode='全局中转'; fi
  elif jq -e 'all(.outbounds[]; .type=="direct")' "$C" >/dev/null 2>&1; then mode='仅本机出口'; fi
  printf '默认出口：'; paint '1;32' "$final"; printf '    分流模式：'; paint '1;34' "$mode"; printf '\n'
 else printf '配置状态：未初始化或缺少 jq\n'; fi
}
# Return 10 only when new bytes have actually been installed.
# Return 0 for unchanged/cancelled, 1 for errors. The parent menu reloads on 10.
self_update() (
 local w v stage='' backup_file target=/usr/local/bin/sb
 w=$(mktemp -d) || exit 1
 trap 'rm -rf "$w"; [[ -z $stage ]] || rm -f "$stage"' EXIT
 need curl bash cmp install mktemp mv || exit 1
 curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/xiaoxya/sb-manager/main/sb.sh -o "$w/sb.sh" || { err '下载失败，保留当前版本'; exit 1; }
 bash -n "$w/sb.sh" || { err '下载脚本语法检查失败，保留当前版本'; exit 1; }
 v=$(sed -n 's/^VERSION=\([0-9][0-9.]*\)$/\1/p' "$w/sb.sh")
 [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err '下载文件版本标识无效'; exit 1; }
 printf '当前运行版本：%s  仓库版本：%s\n' "$VERSION" "$v"
 if [[ -f $target ]] && cmp -s "$w/sb.sh" "$target"; then
  if [[ $v != "$VERSION" ]]; then msg OK '磁盘已有新版，重新加载即可'; exit 10; fi
  msg OK '管理器已是最新版本'; exit 0
 fi
 echo '仅替换管理器，不更新核心、不重启服务。'
 confirm '备份并更新管理器?' || { echo '已取消更新'; exit 0; }
 [[ ! -L $target && ( ! -e $target || -f $target ) ]] || { err '安装路径不是普通文件，拒绝替换'; exit 1; }
 stage=$(mktemp /usr/local/bin/.sb-update.XXXXXX) || exit 1
 install -m 755 "$w/sb.sh" "$stage" && bash -n "$stage" && cmp -s "$stage" "$w/sb.sh" || { err '暂存检查失败'; exit 1; }
 if [[ -f $target ]]; then
  backup_file=$(mktemp /usr/local/bin/sb.bak.XXXXXXXX) || exit 1
  if ! cp -a "$target" "$backup_file"; then rm -f "$backup_file"; err '备份失败，拒绝更新'; exit 1; fi
  printf '旧版备份：%s\n' "$backup_file"
 fi
 mv -fT "$stage" "$target" || { err '替换失败'; exit 1; }
 stage=''
 msg OK "已更新至 v$v"
 exit 10
)
self_update_cli(){
 local rc=0
 self_update || rc=$?
 if ((rc==10)); then
  if [[ -t 0 && -t 1 ]]; then exec /bin/bash /usr/local/bin/sb; fi
  return 0
 fi
 return "$rc"
}

menu(){ local n; while true; do
 if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then tput clear 2>/dev/null || :; fi
 ui_title "sing-box Manager v$VERSION"; manager_status
 paint '36' '--------------------------------------------------------'; printf '\n'
 columns '◆ 服务与节点管理|01 安装/更新核心|02 安装服务|03 启动服务|04 停止服务|05 重启服务|06 服务状态|07 实时日志|08 节点信息|09 修改监听端口|10 出站节点管理|11 修复规则下载|12 中转测试|13 日志级别|14 REALITY 测试|15 REALITY 公钥|16 TLS 目标管理|27 开机启动|35 更新管理器|' '◆ 系统维护与分流|17 时间同步|18 系统诊断|19 前台调试|20 修复权限|21 备份配置|22 恢复 JSON|23 磁盘检查|24 安全清理|25 限制日志|26 BBR 管理|28 分流规则管理|29 智能分流测试|30 实时流量监控|31 域名访问统计|32 AnyTLS 连接|33 网卡实时速率|34 设置公网地址|36 Argo 隧道管理|37 DNS 与 IPv6 管理'
 paint '36' '--------------------------------------------------------'; printf '\n'
 columns '00 退出管理工具' '99 彻底卸载服务'
 read -rp "$(ui_prompt '请输入功能编号：')" n || return
 [[ $n == 0 || $n == 00 ]] && return
 if [[ $n == 99 || $n == uninstall-manager || $n == uninstall-service ]]; then
  if uninstall_manager; then return 0; fi
  read -rp "$(ui_prompt '回车继续...')" _ || return
  continue
 fi
 if [[ $n == 35 || $n == self-update ]]; then
  local rc=0
  self_update || rc=$?
  if ((rc==10)); then
   exec /bin/bash /usr/local/bin/sb
   err '新版菜单启动失败，请检查安装文件'
   return 1
  fi
 else dispatch "$n"; fi
 read -rp "$(ui_prompt '回车继续...')" _ || return
 done; }

dispatch(){ local n=${1:-}; if [[ $n =~ ^0[0-9]$ ]]; then n=$((10#$n)); fi; case $n in '') menu;; 35|self-update) self_update_cli;; 99|uninstall-service|uninstall-manager) uninstall_manager_cli;; 36|argo) argo_menu;; argo-stability) argo_stability_menu;; 37|dns) dns_menu;; env) env_report;; 18|diagnose) env_report; diagnose;; add-snell) inbound_add snell;; 2|init|install-service|inbounds) service_menu;; add-inbound) inbound_add "${2:-anytls}";; delete-inbound) inbound_delete;; 26|bbr) bbr_menu;; init-standalone) init_role standalone;; 10|outbounds) proxy_menu;; import-node|import-outbound) proxy_import;; export-outbound|export-node) proxy_export;; change-relay) proxy_change edit;; test-outbound) [[ -n ${2:-} ]] && proxy_test "$2" "${3:-}";; *) legacy_dispatch "$n" "${@:2}";; esac; }

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then case ${1:-} in -h|--help|help) show_help; exit 0;; -v|--version|version) printf "sb v%s\n" "$VERSION"; exit 0;; esac; [[ $EUID == 0 ]] || { err '请使用 root'; exit 1; }; case ${1:-} in install-manager|self-update|35|uninstall-manager|uninstall-service|99) ;; *) policy_migrate || exit 1;; esac; dispatch "$@"; fi
