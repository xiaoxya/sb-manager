#!/usr/bin/env bash
# 通用 sing-box 管理工具，面向 Debian/Ubuntu systemd, sing-box 1.14.x
set -uo pipefail
umask 077
VERSION=2.2.8
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
install_core(){
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
init_role() (
 local role=$1 w host sni hp ap rp ssport hy any relaypw sskey reality keys priv pub uuid sid; w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
 need sing-box jq openssl python3 || exit 1
 if [[ -f $C ]]; then confirm '已有配置，重新初始化将替换入站及密码，确认?' || exit 0; fi
 host=$(ask '本机对外连接地址（公网IP/域名）' ''); [[ -n $host ]] || exit 1
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
 jq '.outbounds[]|select(.type=="anytls" or .type=="shadowsocks" or .type=="hysteria2" or .type=="vless" or .type=="snell")|del(.password,.obfs.password,.uuid,.psk,.userkey)' "$C"
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
ntp(){ case $(virt) in podman|docker|lxc|openvz|container*) echo '容器时间由宿主机管理'; date -u;; *) apt-get install -y systemd-timesyncd && systemctl enable --now systemd-timesyncd; timedatectl status;; esac; }
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
1|update) install_core;; 2|02|init) init_menu;; init-entry|init-hk) init_role entry;; init-landing|init-tw) init_role landing;; 28|rules) route_manage;; 3|start) systemctl start sing-box;; 4|stop) systemctl stop sing-box;; 5|restart) systemctl restart sing-box;; 6|status) systemctl status sing-box --no-pager -l;; 7|logs) journalctl -u sing-box -n 30 -f -o cat;; 8|info) info;; 9|port) change_port;; 10|change-relay) change_relay;; 11|fix-rules) fix_rules;; 12|relay) relay "${2:-}";; 13) local l; l=$(ask '日志级别' info); edit --arg l "$l" '.log.level=$l';; 14|test) reality_test;; 15) local k; k=$(jq -er '.inbounds[]|select(.tag=="vless-reality-in")|.tls.reality.private_key' "$C") && public_key "$k";; 16) tls_target;; 17) ntp;; 18|diagnose) diagnose;; 19) foreground;; 20|fix-perm) permissions;; 21|backup) backup;; 22|restore) restore;; 23|disk) disk;; 24|clean) clean;; 25) limit_logs;; 26) sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc;; 27) local a; a=$(ask 'enable/disable' enable); case $a in enable|disable) systemctl "$a" sing-box;; esac;; 29|test-route) route_test;; 30|monitor) monitor;; 31) local period; period=$(ask '统计时间（1 hour/24 hours）' '1 hour'); journalctl -u sing-box --since "$period ago" -o cat --no-pager | sed -n 's/.*inbound connection to //p' | sort | uniq -c | sort -nr | head -50;; 32) local p; p=$(jq -r '.inbounds[]|select(.tag=="anytls-in")|.listen_port' "$C"); watch -n 1 "ss -tinp 'sport = :$p'";; 33) command -v nload >/dev/null || apt-get install -y nload; nload;; 34) local h; h=$(ask '公网地址' ''); [[ -n $h ]] && printf '%s\n' "$h" > "$META";; install-manager) if [[ $(readlink -f "$0") == /usr/local/bin/sb ]]; then return 0; fi; if [[ -e /usr/local/bin/sb ]]; then confirm "备份并替换旧 sb?" || return 0; cp -a /usr/local/bin/sb "/usr/local/bin/sb.bak.$(date +%s)" || return 1; fi; install -m 755 "$0" /usr/local/bin/sb;; '') menu;; *) err '未知命令';; esac; }
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
 if int(n)==0: return p(s,"1;31")
 c=""
 if any(x in label for x in ("停止","退出")): c="1;31"
 elif any(x in label for x in ("初始化","恢复","重启","清理","删除","更新核心")): c="1;33"
 elif any(x in label for x in ("分流","中转","出站")): c="1;34"
 return p(n,"1;32")+sp+(p(label,c) if c else label)
if w<90 or max(map(cells,a))+max(map(cells,b))+4>w:
 for x in a+b:
  if x: print(fmt(x))
else:
 n=max(map(cells,a))+4
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
proxy_menu(){ local n t; [[ -s $C ]] || return 1; while true; do ui_title '出站节点管理'; proxy_list; columns '01 查看出站详情|02 添加出站|03 修改出站|04 删除出站' '05 测试指定出站|06 设置默认出站|07 测试全部出站|08 分享链接导入|00 返回'; read -rp "$(ui_prompt '请选择操作：')" n || return; case $n in 1|01) t=$(select_proxy) && jq --arg t "$t" '.outbounds[]|select(.tag==$t)|del(.password,.obfs.password,.uuid,.psk,.userkey)' "$C";; 2|02) proxy_change add;; 3|03) proxy_change edit;; 4|04) proxy_delete;; 5|05) t=$(select_proxy) && proxy_test "$t";; 6|06) set_final;; 7|07) while IFS= read -r t; do echo "==== $t ===="; proxy_test "$t" || echo '[FAIL]'; done < <(jq -r '.outbounds[]|select(.type=="direct" or .type=="anytls" or .type=="hysteria2" or .type=="shadowsocks" or .type=="vless" or .type=="snell")|.tag' "$C");; 8|08) proxy_import;; 0|00) return;; esac; done; }
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
mode_switch(){ local m t snapshot; policy_ready || return 1; m=$(ask '模式 smart/direct/relay' smart) || return 1; case $m in smart) jq -e '.saved!=null' "$POLICY" >/dev/null || return 0; confirm '恢复原智能分流规则?' && edit --slurpfile p "$POLICY" '.route.rules=$p[0].saved.rules|.route.final=$p[0].saved.final' && policy_edit '.saved=null';; direct|relay) t=direct; [[ $m == direct ]] || { t=$(select_proxy) || return 1; [[ $t != direct ]] || return 1; }; confirm '切换全局模式（保留基础嗅探、解析及私网拒绝）?' || return 0; if jq -e '.saved==null' "$POLICY" >/dev/null; then snapshot=$(jq -c '.route|{rules,final}' "$C") || return 1; policy_edit --argjson r "$snapshot" '.saved=$r' || return 1; if ! edit --arg t "$t" '.route.rules |= map(select(.action=="sniff" or .action=="resolve" or (.ip_is_private==true and .action=="reject")))|.route.final=$t'; then policy_edit '.saved=null'; return 1; fi; else edit --arg t "$t" '.route.final=$t'; fi;; *) err '无效模式';; esac; }
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
manager_status(){
 local st core final mode
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
self_update() (
 local w v; w=$(mktemp -d) || exit 1; trap 'rm -rf "$w"' EXIT
 need curl bash || exit 1
 curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/xiaoxya/sb-manager/main/sb.sh -o "$w/sb.sh" || exit 1
 bash -n "$w/sb.sh" || { err '下载脚本语法检查失败'; exit 1; }
 v=$(sed -n 's/^VERSION=\([0-9][0-9.]*\)$/\1/p' "$w/sb.sh")
 [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err '下载文件版本标识无效'; exit 1; }
 printf '当前版本：%s  仓库版本：%s\n' "$VERSION" "$v"
 if [[ -f /usr/local/bin/sb ]] && cmp -s "$w/sb.sh" /usr/local/bin/sb; then msg OK '管理器已是最新版本'; exit 0; fi
 echo '仅替换管理器，不更新核心、不重启服务；安装器将询问备份确认。'
 bash "$w/sb.sh" install-manager
)
menu(){ local n; while true; do
 if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then tput clear 2>/dev/null || :; fi
 ui_title "sing-box Manager v$VERSION"; manager_status
 paint '36' '--------------------------------------------------------'; printf '\n'
 columns '◆ 服务与节点管理|01 安装/更新核心|02 安装服务|03 启动服务|04 停止服务|05 重启服务|06 服务状态|07 实时日志|08 节点信息|09 修改监听端口|10 出站节点管理|11 修复规则下载|12 中转测试|13 日志级别|14 REALITY 测试|15 REALITY 公钥|16 TLS 目标管理|27 开机启动' '◆ 系统维护与分流|17 时间同步|18 系统诊断|19 前台调试|20 修复权限|21 备份配置|22 恢复 JSON|23 磁盘检查|24 安全清理|25 限制日志|26 BBR 管理|28 分流规则管理|29 智能分流测试|30 实时流量监控|31 域名访问统计|32 AnyTLS 连接|33 网卡实时速率|34 设置公网地址'
 paint '36' '--------------------------------------------------------'; printf '\n'
 columns '35 更新管理器' '00 退出管理工具'
 read -rp "$(ui_prompt '请输入功能编号：')" n || return
 [[ $n == 0 || $n == 00 ]] && return
 dispatch "$n"; read -rp "$(ui_prompt '回车继续...')" _ || return
 done; }

dispatch(){ local n=${1:-}; if [[ $n =~ ^0[0-9]$ ]]; then n=$((10#$n)); fi; case $n in '') menu;; 35|self-update) self_update;; add-snell) inbound_add snell;; 2|init|install-service|inbounds) service_menu;; add-inbound) inbound_add "${2:-anytls}";; delete-inbound) inbound_delete;; 26|bbr) bbr_menu;; init-standalone) init_role standalone;; 10|outbounds) proxy_menu;; import-node|import-outbound) proxy_import;; change-relay) proxy_change edit;; test-outbound) [[ -n ${2:-} ]] && proxy_test "$2" "${3:-}";; *) legacy_dispatch "$n" "${@:2}";; esac; }

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then [[ $EUID == 0 ]] || { err '请使用 root'; exit 1; }; if [[ ${1:-} != install-manager && ${1:-} != self-update ]]; then policy_migrate || exit 1; fi; dispatch "$@"; fi
