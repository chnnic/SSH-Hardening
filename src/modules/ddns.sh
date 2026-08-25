# ══════════════════════════════════════════════════════════
#  DDNS 模块
# ══════════════════════════════════════════════════════════

DDNS_SCRIPT="/root/ddns.sh"
DDNS_TOKEN_FILE="/root/.cf_token"
DDNS_HUAWEI_KEY_FILE="/root/.hw_dns_aksk"
DDNS_LOG="/var/log/ddns.log"
DDNS_ZONE_FILE="/root/.cf_zone"
DDNS_TG_FILE="/root/.cf_tg"    # Telegram 通知配置
DDNS_STATE_DIR="/root"
DDNS_CRON_MARKER="# VPS_TOOLS_DDNS"

ddns_cfg_get() {
    local key="$1"
    [ -f "$DDNS_ZONE_FILE" ] || return 1
    grep "^${key}=" "$DDNS_ZONE_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

ddns_provider() {
    local provider
    provider=$(ddns_cfg_get PROVIDER 2>/dev/null || true)
    [ -n "$provider" ] || provider="cloudflare"
    echo "$provider"
}

ddns_provider_label() {
    case "$(ddns_provider)" in
        huawei) echo "华为云 DNS" ;;
        *) echo "Cloudflare" ;;
    esac
}

ddns_sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

ddns_domain_normalize() {
    local value="$1"
    DDNS_DOMAIN_VALUE="$value" python3 <<'PY'
import os
import re

value = os.environ.get("DDNS_DOMAIN_VALUE", "").strip().rstrip(".")
try:
    value = value.encode("idna").decode("ascii").lower()
except (UnicodeError, UnicodeDecodeError):
    raise SystemExit(1)
if not value or len(value) > 253:
    raise SystemExit(1)
labels = value.split(".")
if any(
    not label
    or len(label) > 63
    or label.startswith("-")
    or label.endswith("-")
    or re.fullmatch(r"[a-z0-9-]+", label) is None
    for label in labels
):
    raise SystemExit(1)
print(value)
PY
}

ddns_domain_in_zone() {
    local domain="${1%.}" zone="${2%.}"
    [ "$domain" = "$zone" ] || [[ "$domain" = *."$zone" ]]
}

ddns_huawei_endpoint_normalize() {
    local value="${1:-https://dns.myhuaweicloud.com}"
    DDNS_ENDPOINT_VALUE="$value" python3 <<'PY'
import os
import re
import urllib.parse

value = os.environ.get("DDNS_ENDPOINT_VALUE", "").strip()
if "://" not in value:
    value = "https://" + value
parts = urllib.parse.urlsplit(value)
host = (parts.hostname or "").lower().rstrip(".")
if (
    parts.scheme != "https"
    or parts.username is not None
    or parts.password is not None
    or parts.port is not None
    or parts.path not in ("", "/")
    or parts.query
    or parts.fragment
    or re.fullmatch(r"dns(?:\.[a-z0-9-]+)?\.myhuaweicloud\.com", host) is None
):
    raise SystemExit(1)
print("https://" + host)
PY
}

ddns_cf_ttl_normalize() {
    local value="${1:-60}"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    value=$(printf '%s' "$value" | sed 's/^0*//')
    [ -n "$value" ] || value=0
    [ "${#value}" -le 5 ] || return 1
    if [ "$value" -eq 1 ] || { [ "$value" -ge 60 ] && [ "$value" -le 86400 ]; }; then
        echo "$value"
        return 0
    fi
    return 1
}

ddns_huawei_ttl_normalize() {
    local value="${1:-300}"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    value=$(printf '%s' "$value" | sed 's/^0*//')
    [ -n "$value" ] || value=0
    [ "${#value}" -le 10 ] || return 1
    [ "$value" -ge 300 ] && [ "$value" -le 2147483647 ] || return 1
    echo "$value"
}

ddns_install_tx_begin() {
    DDNS_INSTALL_TX_DIR=$(mktemp -d /tmp/vps-tools-ddns.XXXXXX) || return 1
    local index=0 path
    for path in "$DDNS_SCRIPT" "$DDNS_TOKEN_FILE" "$DDNS_HUAWEI_KEY_FILE" "$DDNS_ZONE_FILE"; do
        index=$((index + 1))
        if [ -e "$path" ]; then
            cp -a -- "$path" "$DDNS_INSTALL_TX_DIR/file.$index" || {
                rm -rf -- "$DDNS_INSTALL_TX_DIR"
                DDNS_INSTALL_TX_DIR=""
                return 1
            }
            : > "$DDNS_INSTALL_TX_DIR/present.$index"
        fi
    done
    if command -v crontab >/dev/null 2>&1; then
        crontab -l > "$DDNS_INSTALL_TX_DIR/crontab" 2>/dev/null || : > "$DDNS_INSTALL_TX_DIR/crontab"
        : > "$DDNS_INSTALL_TX_DIR/has-crontab"
    fi
}

ddns_install_tx_restore() {
    local dir="${DDNS_INSTALL_TX_DIR:-}" index=0 path failed=0
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    for path in "$DDNS_SCRIPT" "$DDNS_TOKEN_FILE" "$DDNS_HUAWEI_KEY_FILE" "$DDNS_ZONE_FILE"; do
        index=$((index + 1))
        if [ -f "$dir/present.$index" ]; then
            cp -a -- "$dir/file.$index" "$path" || failed=1
        else
            rm -f -- "$path" || failed=1
        fi
    done
    if [ -f "$dir/has-crontab" ]; then
        crontab "$dir/crontab" >/dev/null 2>&1 || failed=1
    fi
    if [ "$failed" -eq 0 ]; then
        rm -rf -- "$dir"
        DDNS_INSTALL_TX_DIR=""
        return 0
    fi
    warn "DDNS 回滚未完整完成，快照保留在 ${dir}"
    return 1
}

ddns_install_tx_commit() {
    [ -z "${DDNS_INSTALL_TX_DIR:-}" ] || rm -rf -- "$DDNS_INSTALL_TX_DIR"
    DDNS_INSTALL_TX_DIR=""
}

ddns_domain_dot() {
    local domain="$1"
    case "$domain" in
        *.) echo "$domain" ;;
        *) echo "${domain}." ;;
    esac
}

ddns_interval_normalize() {
    local value="${1:-5}"
    echo "$value" | grep -qE '^[0-9]+$' || { echo 5; return; }
    if [ "$value" -ge 1 ] && [ "$value" -le 59 ]; then
        echo "$value"
    else
        echo 5
    fi
}

ddns_interval_min() {
    local value
    value=$(ddns_cfg_get INTERVAL_MIN 2>/dev/null || true)
    ddns_interval_normalize "${value:-5}"
}

ddns_cron_expr() {
    local interval
    interval=$(ddns_interval_normalize "${1:-$(ddns_interval_min)}")
    if [ "$interval" -eq 1 ]; then
        echo "* * * * *"
    else
        printf '*/%s * * * *\n' "$interval"
    fi
}

ddns_cron_without_managed() {
    grep -Fv -- "$DDNS_CRON_MARKER" | grep -Fv -- "$DDNS_SCRIPT"
}

ddns_prompt_interval() {
    local default="${1:-5}" input
    default=$(ddns_interval_normalize "$default")
    read -rp "  检测间隔分钟（1-59，默认${default}，常用 1/2/5）: " input
    ddns_interval_normalize "${input:-$default}"
}

ddns_log_path() {
    local log_path
    log_path=$(ddns_cfg_get LOG 2>/dev/null)
    if [ -n "$log_path" ]; then
        echo "$log_path"
    elif [ -f "$DDNS_LOG" ]; then
        echo "$DDNS_LOG"
    else
        echo "$HOME/ddns.log"
    fi
}

ddns_truthy() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

ddns_cfg_enable_a() {
    local enabled mode
    enabled=$(ddns_cfg_get ENABLE_A 2>/dev/null || true)
    if [ -n "$enabled" ]; then
        ddns_truthy "$enabled"
        return
    fi
    mode=$(ddns_cfg_get MODE 2>/dev/null || true)
    [ "$mode" != "ipv6" ] && [ "$mode" != "aaaa" ]
}

ddns_cfg_enable_aaaa() {
    local enabled mode
    enabled=$(ddns_cfg_get ENABLE_AAAA 2>/dev/null || true)
    if [ -n "$enabled" ]; then
        ddns_truthy "$enabled"
        return
    fi
    mode=$(ddns_cfg_get MODE 2>/dev/null || true)
    [ "$mode" = "dual" ] || [ "$mode" = "ipv6" ] || [ "$mode" = "aaaa" ]
}

ddns_cfg_domain4() {
    local domain
    domain=$(ddns_cfg_get DOMAIN4 2>/dev/null || true)
    [ -n "$domain" ] || domain=$(ddns_cfg_get DOMAIN 2>/dev/null || true)
    echo "$domain"
}

ddns_cfg_domain6() {
    local domain mode
    domain=$(ddns_cfg_get DOMAIN6 2>/dev/null || true)
    if [ -z "$domain" ]; then
        mode=$(ddns_cfg_get MODE 2>/dev/null || true)
        if [ "$mode" = "dual" ] || [ "$mode" = "ipv6" ] || [ "$mode" = "aaaa" ]; then
            domain=$(ddns_cfg_get DOMAIN 2>/dev/null || true)
        fi
    fi
    echo "$domain"
}

ddns_primary_domain() {
    local domain
    if ddns_cfg_enable_a; then
        domain=$(ddns_cfg_domain4)
        [ -n "$domain" ] && { echo "$domain"; return; }
    fi
    if ddns_cfg_enable_aaaa; then
        domain=$(ddns_cfg_domain6)
        [ -n "$domain" ] && { echo "$domain"; return; }
    fi
    ddns_cfg_get DOMAIN 2>/dev/null || true
}

ddns_mode_label() {
    local domain4 domain6 has_a="false" has_aaaa="false"
    ddns_cfg_enable_a && has_a="true"
    ddns_cfg_enable_aaaa && has_aaaa="true"
    domain4=$(ddns_cfg_domain4)
    domain6=$(ddns_cfg_domain6)
    if [ "$has_a" = "true" ] && [ "$has_aaaa" = "true" ]; then
        if [ "$domain4" = "$domain6" ]; then
            echo "IPv4 + IPv6（同域名）"
        else
            echo "IPv4 + IPv6（分别设置）"
        fi
    elif [ "$has_aaaa" = "true" ]; then
        echo "仅 IPv6"
    else
        echo "仅 IPv4"
    fi
}

ddns_build_domain() {
    local sub="$1" zone="$2"
    case "$sub" in
        @) echo "$zone" ;;
        *."$zone") echo "$sub" ;;
        *) echo "${sub}.${zone}" ;;
    esac
}

ddns_ipv6_subdomain_default() {
    local sub4="${1:-}"
    case "$sub4" in
        ""|@)   echo "v6" ;;
        *ipv4)  echo "${sub4%ipv4}ipv6" ;;
        *IPv4)  echo "${sub4%IPv4}IPv6" ;;
        *v4)    echo "${sub4%v4}v6" ;;
        *V4)    echo "${sub4%V4}V6" ;;
        *-4)    echo "${sub4%-4}-6" ;;
        *)      echo "${sub4}-v6" ;;
    esac
}

ddns_replace_link_host() {
    local link="$1" domain="$2"
    python3 - "$domain" 3<<<"$link" <<'PY'
import base64
import json
import os
import re
import sys
import urllib.parse


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def decode_base64(value):
    try:
        raw = value.encode("ascii")
        raw += b"=" * (-len(raw) % 4)
        return base64.b64decode(raw, altchars=b"-_", validate=True)
    except Exception:
        fail("链接中的 Base64 内容无效")


def encode_base64(value, original):
    encoder = base64.urlsafe_b64encode if "-" in original or "_" in original else base64.b64encode
    encoded = encoder(value).decode("ascii")
    return encoded if original.endswith("=") else encoded.rstrip("=")


def valid_domain(value):
    try:
        ascii_value = value.rstrip(".").encode("idna").decode("ascii")
    except UnicodeError:
        fail("DDNS 域名格式无效")
    labels = ascii_value.split(".")
    if len(ascii_value) > 253 or any(
        not label
        or len(label) > 63
        or label.startswith("-")
        or label.endswith("-")
        or re.fullmatch(r"[A-Za-z0-9-]+", label) is None
        for label in labels
    ):
        fail("DDNS 域名格式无效")
    return ascii_value


def replace_vmess(value, target):
    payload = value[len("vmess://"):]
    fragment = ""
    if "#" in payload:
        payload, fragment = payload.split("#", 1)
        fragment = "#" + fragment
    if not payload or "?" in payload:
        fail("无法识别 VMess 分享链接")
    try:
        data = json.loads(decode_base64(payload).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("VMess 分享链接中的 JSON 无效")
    if not isinstance(data, dict) or not str(data.get("add") or "").strip():
        fail("VMess 分享链接缺少服务器地址")
    data["add"] = target
    rendered = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return "vmess://" + encode_base64(rendered, payload) + fragment


def replace_legacy_ss(value, target):
    payload = value[len("ss://"):]
    fragment = ""
    if "#" in payload:
        payload, fragment = payload.split("#", 1)
        fragment = "#" + fragment
    try:
        decoded = decode_base64(payload).decode("utf-8")
    except UnicodeDecodeError:
        fail("Shadowsocks 分享链接内容无效")
    if "@" not in decoded:
        fail("Shadowsocks 分享链接缺少服务器地址")
    credentials, endpoint = decoded.rsplit("@", 1)
    if endpoint.startswith("["):
        match = re.fullmatch(r"\[[^]]+\]:(\d+)", endpoint)
        port = match.group(1) if match else ""
    else:
        host, separator, port = endpoint.rpartition(":")
        if not separator or not host:
            port = ""
    if not port or not port.isdigit() or not 1 <= int(port) <= 65535:
        fail("Shadowsocks 分享链接端口无效")
    rendered = f"{credentials}@{target}:{port}".encode("utf-8")
    return "ss://" + encode_base64(rendered, payload) + fragment


domain = valid_domain(sys.argv[1].strip())
with os.fdopen(3, "r", encoding="utf-8") as stream:
    link = stream.read().rstrip("\r\n")
if not link or "://" not in link:
    fail("请输入完整的分享链接")

scheme = link.split(":", 1)[0].lower()
if scheme == "vmess":
    print(replace_vmess(link, domain))
    raise SystemExit(0)

# Legacy Shadowsocks encodes credentials and endpoint together, so no @ is visible in the URI.
if scheme == "ss" and "@" not in link.split("#", 1)[0]:
    print(replace_legacy_ss(link, domain))
    raise SystemExit(0)

try:
    parts = urllib.parse.urlsplit(link)
    port = parts.port
except ValueError:
    fail("分享链接中的服务器端口无效")
if not parts.scheme or not parts.netloc or not parts.hostname:
    fail("无法识别分享链接中的服务器地址")

userinfo, separator, unused_endpoint = parts.netloc.rpartition("@")
del unused_endpoint
new_netloc = (userinfo + separator if separator else "") + domain
if port is not None:
    if not 1 <= port <= 65535:
        fail("分享链接中的服务器端口无效")
    new_netloc += f":{port}"
print(urllib.parse.urlunsplit((parts.scheme, new_netloc, parts.path, parts.query, parts.fragment)))
PY
}

ddns_share_link_tool() {
    print_header "替换分享链接地址"
    [ ! -f "$DDNS_ZONE_FILE" ] && { error "DDNS 未配置"; return 1; }
    command -v python3 >/dev/null 2>&1 || { error "缺少 python3，无法解析分享链接"; return 1; }

    local domain4="" domain6="" original_link="" link4="" link6=""
    ddns_cfg_enable_a && domain4=$(ddns_cfg_domain4)
    ddns_cfg_enable_aaaa && domain6=$(ddns_cfg_domain6)
    if [ -z "$domain4" ] && [ -z "$domain6" ]; then
        error "当前配置没有可用的 IPv4 或 IPv6 DDNS 域名"
        return 1
    fi

    echo -e "  ${DIM}保留协议、密钥、端口、参数和备注，仅将服务器地址换成 DDNS 域名。${NC}"
    echo -e "  ${DIM}支持 SS / VMess / VLESS / Trojan / Hysteria2 / TUIC 等分享 URI。${NC}"
    echo ""
    [ -n "$domain4" ] && echo -e "  IPv4 DDNS : ${BOLD}${domain4}${NC}"
    [ -n "$domain6" ] && echo -e "  IPv6 DDNS : ${BOLD}${domain6}${NC}"
    echo ""
    menu_div
    read -rp "  粘贴现有分享链接: " original_link
    [ -z "$original_link" ] && { warn "已取消"; return; }

    if [ -n "$domain4" ]; then
        link4=$(ddns_replace_link_host "$original_link" "$domain4") || {
            error "分享链接解析失败，未生成新链接"
            return 1
        }
    fi
    if [ -n "$domain6" ]; then
        if [ "$domain6" = "$domain4" ]; then
            link6="$link4"
        else
            link6=$(ddns_replace_link_host "$original_link" "$domain6") || {
                error "分享链接解析失败，未生成新链接"
                return 1
            }
        fi
    fi

    echo ""
    menu_div
    if [ -n "$link4" ] && [ "$domain4" = "$domain6" ]; then
        echo -e "  ${GREEN}${BOLD}双栈 DDNS 链接${NC}"
        printf '  %s\n' "$link4"
    else
        if [ -n "$link4" ]; then
            echo -e "  ${GREEN}${BOLD}IPv4 DDNS 链接${NC}"
            printf '  %s\n' "$link4"
        fi
        if [ -n "$link6" ]; then
            [ -n "$link4" ] && echo ""
            echo -e "  ${GREEN}${BOLD}IPv6 DDNS 链接${NC}"
            printf '  %s\n' "$link6"
        fi
    fi
    menu_div
    echo -e "  ${DIM}新链接包含原节点凭据，请按密码同等保护。原链接和服务端配置未被修改。${NC}"
}

ddns_fetch_public_ip() {
    local FAMILY="$1" VALUE
    case "$FAMILY" in
        4) VALUE=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://api.ip.sb/ip 2>/dev/null) ;;
        6) VALUE=$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || curl -6 -fsS --max-time 8 https://api.ip.sb/ip 2>/dev/null) ;;
        *) return 1 ;;
    esac
    VALUE=${VALUE//$'\r'/}
    VALUE=${VALUE//$'\n'/}
    DDNS_IP_VALUE="$VALUE" python3 - "$FAMILY" <<'PY'
import ipaddress
import os
import sys

value = os.environ.get("DDNS_IP_VALUE", "")
try:
    address = ipaddress.ip_address(value)
except ValueError:
    raise SystemExit(1)
if address.version != int(sys.argv[1]) or not address.is_global:
    raise SystemExit(1)
print(address.compressed)
PY
}

ddns_cf_exact_records() {
    local type="$1" domain="$2"
    DDNS_CF_JSON=$(cat) python3 - "$type" "$domain" <<'PY'
import json
import os
import sys

rtype = sys.argv[1].upper()
target = sys.argv[2].rstrip(".").lower()
try:
    data = json.loads(os.environ.get("DDNS_CF_JSON", "{}"))
except Exception:
    raise SystemExit(1)
if data.get("success") is not True or not isinstance(data.get("result"), list):
    raise SystemExit(1)
for record in data["result"]:
    name = str(record.get("name") or "").rstrip(".").lower()
    if name == target and str(record.get("type") or "").upper() == rtype:
        record_id = str(record.get("id") or "").replace("\t", " ").replace("\n", " ")
        content = str(record.get("content") or "").replace("\t", " ").replace("\n", " ")
        if record_id:
            print(f"{record_id}\t{content}")
PY
}

ddns_install_cron_job() {
    local CRON_JOB="$1"
    if ! (crontab -l 2>/dev/null | ddns_cron_without_managed; echo "$CRON_JOB") | crontab -; then
        error "写入 DDNS crontab 失败"
        return 1
    fi
    if ! ddns_start_cron_service >/dev/null 2>&1; then
        if ddns_remove_cron_job >/dev/null 2>&1; then
            error "cron 服务无法启动，已撤销 DDNS 定时任务"
        else
            error "cron 服务无法启动，且定时任务撤销失败，请手动检查 crontab -l"
        fi
        return 1
    fi
}

ddns_remove_cron_job() {
    command -v crontab >/dev/null 2>&1 || return 0
    if ! (crontab -l 2>/dev/null | ddns_cron_without_managed) | crontab -; then
        error "移除 DDNS crontab 失败"
        return 1
    fi
}

ddns_cf_record_ensure() {
    local zone_id="$1" token="$2" type="$3" domain="$4" placeholder="$5" ttl="$6" proxied="$7"
    local record_resp exact_records record_count create_body create_resp create_ok
    record_resp=$(curl -s --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${domain}&type=${type}" \
        -H "Authorization: Bearer ${token}")
    if ! exact_records=$(printf '%s' "$record_resp" | ddns_cf_exact_records "$type" "$domain"); then
        error "查询 ${type} 记录失败，请检查网络和 Token 权限"
        return 1
    fi
    record_count=$(printf '%s\n' "$exact_records" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$record_count" -gt 1 ]; then
        error "检测到 ${record_count} 条重复的 ${type} 记录 ${domain}，为避免更新错误已停止"
        echo -e "  ${DIM}请在 DNS 控制台仅保留一条同名同类型记录后重试${NC}"
        return 1
    fi
    if [ "$record_count" = "0" ]; then
        warn "未找到 ${type} 记录 ${domain}，正在自动创建..."
        create_body=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
            "$type" "$domain" "$placeholder" "$ttl" "$proxied")
        create_resp=$(curl -s -X POST --max-time 10 \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "$create_body")
        create_ok=$(echo "$create_resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
        if [ "$create_ok" = "True" ]; then
            info "${type} 记录已创建 ✓"
        else
            error "创建 ${type} 记录失败"
            return 1
        fi
    else
        info "${type} 记录 ${domain} 已存在 ✓"
    fi
}

ddns_cf_cleanup_cross_record() {
    local zone_id="$1" token="$2" type="$3" domain="$4" reason="$5"
    local record_resp exact_records record_count choice record_id content delete_resp delete_ok failed=0
    record_resp=$(curl -s --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${domain}&type=${type}" \
        -H "Authorization: Bearer ${token}")
    if ! exact_records=$(printf '%s' "$record_resp" | ddns_cf_exact_records "$type" "$domain"); then
        warn "无法检查可能残留的 ${type} 记录 ${domain}"
        return 0
    fi
    record_count=$(printf '%s\n' "$exact_records" | awk 'NF { count++ } END { print count + 0 }')
    [ "$record_count" -gt 0 ] || return 0

    echo ""
    warn "检测到${reason}：${type} ${domain}（${record_count} 条）"
    while IFS=$'\t' read -r record_id content; do
        [ -n "$record_id" ] && echo -e "  ${DIM}${type} ${domain} → ${content:-空值}  ID: ${record_id}${NC}"
    done <<< "$exact_records"
    read -rp "  是否删除上述交叉记录？(Y/n，默认Y): " choice
    [ -z "$choice" ] && choice="y"
    echo "$choice" | grep -qiE '^y(es)?$' || { warn "已保留上述记录"; return 0; }

    while IFS=$'\t' read -r record_id content; do
        [ -n "$record_id" ] || continue
        delete_resp=$(curl -s -X DELETE --max-time 10 \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${token}")
        delete_ok=$(printf '%s' "$delete_resp" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
        if [ "$delete_ok" = "True" ]; then
            info "已删除 ${type} ${domain}（${content:-空值}）✓"
        else
            error "删除 ${type} ${domain} 失败，记录 ID: ${record_id}"
            failed=1
        fi
    done <<< "$exact_records"
    return "$failed"
}

ddns_type_status_file() {
    case "$1" in
        A|AAAA) echo "${DDNS_STATE_DIR:-/root}/.cf_last_status_$1" ;;
        *) echo "${DDNS_STATE_DIR:-/root}/.cf_last_status" ;;
    esac
}

ddns_type_change_file() {
    case "$1" in
        A|AAAA) echo "${DDNS_STATE_DIR:-/root}/.cf_last_change_$1" ;;
        *) echo "${DDNS_STATE_DIR:-/root}/.cf_last_change" ;;
    esac
}

ddns_line_from_state_file() {
    local type="$1" domain_filter="${2:-}" file ts record_type domain state old_ip new_ip
    file=$(ddns_type_status_file "$type")
    [ -f "$file" ] || return 1
    IFS='|' read -r ts record_type domain state old_ip new_ip < "$file"
    [ -n "$ts" ] && [ -n "$record_type" ] && [ -n "$domain" ] || return 1
    [ -z "$domain_filter" ] || [ "$domain" = "$domain_filter" ] || return 1
    case "$state" in
        unchanged) printf '[%s] OK: %s %s 未变化 %s\n' "$ts" "$record_type" "$domain" "${new_ip:-$old_ip}" ;;
        updated) printf '[%s] OK: %s %s 更新成功 %s → %s\n' "$ts" "$record_type" "$domain" "${old_ip:-?}" "${new_ip:-?}" ;;
        fetch_failed) printf '[%s] ERROR: %s %s 无法获取公网 IP\n' "$ts" "$record_type" "$domain" ;;
        invalid_ip) printf '[%s] ERROR: %s %s 获取到的 IP 非法：%s\n' "$ts" "$record_type" "$domain" "${new_ip:-?}" ;;
        missing) printf '[%s] ERROR: %s 记录不存在 %s\n' "$ts" "$record_type" "$domain" ;;
        duplicate) printf '[%s] ERROR: %s %s 存在 %s 条重复记录\n' "$ts" "$record_type" "$domain" "${old_ip:-?}" ;;
        query_failed) printf '[%s] WARN: %s %s 无法获取当前记录值\n' "$ts" "$record_type" "$domain" ;;
        verify_skipped) printf '[%s] WARN: %s %s 二次校验异常，跳过更新\n' "$ts" "$record_type" "$domain" ;;
        update_failed) printf '[%s] ERROR: %s %s 更新失败 %s → %s\n' "$ts" "$record_type" "$domain" "${old_ip:-?}" "${new_ip:-?}" ;;
        *) printf '[%s] %s: %s %s %s → %s\n' "$ts" "$state" "$record_type" "$domain" "${old_ip:-?}" "${new_ip:-?}" ;;
    esac
}

ddns_line_from_change_file() {
    local type="$1" domain_filter="${2:-}" file ts record_type domain old_ip new_ip kind line
    file=$(ddns_type_change_file "$type")
    if [ ! -f "$file" ] && [ -f "${DDNS_STATE_DIR:-/root}/.cf_last_change" ]; then
        line=$(cat "${DDNS_STATE_DIR:-/root}/.cf_last_change" 2>/dev/null)
        record_type=$(echo "$line" | cut -d'|' -f2)
        domain=$(echo "$line" | cut -d'|' -f5)
        if [ "$record_type" = "$type" ] && { [ -z "$domain_filter" ] || [ "$domain" = "$domain_filter" ]; }; then
            file="${DDNS_STATE_DIR:-/root}/.cf_last_change"
        fi
    fi
    [ -f "$file" ] || return 1
    IFS='|' read -r ts record_type old_ip new_ip domain kind < "$file"
    [ -n "$ts" ] && [ "$record_type" = "$type" ] || return 1
    [ -z "$domain_filter" ] || [ "$domain" = "$domain_filter" ] || return 1
    if [ "$kind" = "synced" ]; then
        printf '[%s] OK: %s %s IP变化 %s → %s（DNS已同步）\n' "$ts" "$record_type" "${domain:-?}" "${old_ip:-?}" "${new_ip:-?}"
    else
        printf '[%s] OK: %s %s 更新成功 %s → %s\n' "$ts" "$record_type" "${domain:-?}" "${old_ip:-?}" "${new_ip:-?}"
    fi
}

ddns_latest_log_line() {
    local type="$1" domain="$2" log="$3"
    [ -n "$domain" ] && [ -f "$log" ] || return 1
    grep -F "OK: ${type} ${domain} " "$log" 2>/dev/null | tail -1
}

ddns_latest_change_log_line() {
    local type="$1" domain="$2" log="$3"
    [ -n "$domain" ] && [ -f "$log" ] || return 1
    grep -F "OK: ${type} ${domain} " "$log" 2>/dev/null | grep -E "更新成功|IP变化" | tail -1
}

ddns_line_time() {
    local line="$1"
    case "$line" in
        \[*\]*)
            line=${line#\[}
            echo "${line%%\]*}"
            ;;
    esac
}

ddns_line_ip_tail() {
    local ip="$1"
    ip=${ip%% *}
    ip=${ip%%（*}
    echo "$ip"
}

ddns_line_result_ip() {
    local line="$1" ip
    case "$line" in
        *" → "*)
            ip=${line##* → }
            ddns_line_ip_tail "$ip"
            ;;
        *"未变化 "*)
            ip=${line##*未变化 }
            ddns_line_ip_tail "$ip"
            ;;
        *"创建成功 "*)
            ip=${line##*创建成功 }
            ddns_line_ip_tail "$ip"
            ;;
    esac
}

ddns_newer_line() {
    local first="$1" second="$2" first_time second_time
    [ -n "$first" ] || [ -n "$second" ] || return 1
    [ -n "$first" ] || { echo "$second"; return 0; }
    [ -n "$second" ] || { echo "$first"; return 0; }
    first_time=$(ddns_line_time "$first")
    second_time=$(ddns_line_time "$second")
    if [ -z "$first_time" ] && [ -n "$second_time" ]; then
        echo "$second"
    elif [ -n "$first_time" ] && [ -n "$second_time" ] && [[ "$second_time" > "$first_time" ]]; then
        echo "$second"
    else
        echo "$first"
    fi
}

ddns_change_matches_status() {
    local change_line="$1" status_ip="$2" change_ip
    [ -n "$change_line" ] || return 1
    [ -n "$status_ip" ] || return 0
    change_ip=$(ddns_line_result_ip "$change_line")
    [ -z "$change_ip" ] || [ "$change_ip" = "$status_ip" ]
}

ddns_record_status_line() {
    local type="$1" domain="$2" log="$3" state_line log_line
    state_line=$(ddns_line_from_state_file "$type" "$domain" 2>/dev/null || true)
    log_line=$(ddns_latest_log_line "$type" "$domain" "$log" 2>/dev/null || true)
    ddns_newer_line "$state_line" "$log_line"
}

ddns_record_change_line() {
    local type="$1" domain="$2" log="$3" status_line status_ip state_line log_line state_match log_match line
    state_match=""
    log_match=""
    status_line=$(ddns_record_status_line "$type" "$domain" "$log" 2>/dev/null || true)
    status_ip=$(ddns_line_result_ip "$status_line")
    state_line=$(ddns_line_from_change_file "$type" "$domain" 2>/dev/null || true)
    log_line=$(ddns_latest_change_log_line "$type" "$domain" "$log" 2>/dev/null || true)
    if ddns_change_matches_status "$state_line" "$status_ip"; then
        state_match="$state_line"
    fi
    if ddns_change_matches_status "$log_line" "$status_ip"; then
        log_match="$log_line"
    fi
    line=$(ddns_newer_line "$state_match" "$log_match" 2>/dev/null || true)
    [ -n "$line" ] || return 1
    echo "$line"
}

ddns_print_record_summary() {
    local label="$1" type="$2" domain="$3" log="$4" status_line change_line
    [ -n "$domain" ] || return 0
    status_line=$(ddns_record_status_line "$type" "$domain" "$log" 2>/dev/null || true)
    if [ -n "$status_line" ]; then
        echo -e "  最新 ${label}: ${DIM}${status_line}${NC}"
    else
        echo -e "  最新 ${label}: ${DIM}等待下一次更新${NC}"
    fi
    change_line=$(ddns_record_change_line "$type" "$domain" "$log" 2>/dev/null || true)
    if [ -n "$change_line" ]; then
        echo -e "  变更 ${label}: ${DIM}${change_line}${NC}"
    else
        echo -e "  变更 ${label}: ${DIM}暂无当前 IP 变更记录${NC}"
    fi
}

ddns_ensure_cron() {
    if command -v crontab &>/dev/null; then
        ddns_start_cron_service
        return $?
    fi
    info "未检测到 crontab，正在安装 cron..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y cron 2>/dev/null || apt-get install -y cronie 2>/dev/null || return 1
    elif command -v apk &>/dev/null; then
        apk add --no-cache dcron 2>/dev/null || apk add --no-cache cronie 2>/dev/null || return 1
    elif command -v yum &>/dev/null; then
        yum install -y cronie 2>/dev/null || return 1
    elif command -v dnf &>/dev/null; then
        dnf install -y cronie 2>/dev/null || return 1
    else
        error "找不到包管理器，请手动安装 cron：apt-get install -y cron"
        return 1
    fi
    # 安装后立即启动服务
    ddns_start_cron_service >/dev/null 2>&1 || true
    sleep 1
    if command -v crontab &>/dev/null && ddns_cron_service_running; then
        info "cron 安装并启动成功 ✓"
        return 0
    else
        error "cron 安装后仍无法使用或服务未运行"
        return 1
    fi
}

ddns_start_cron_service() {
    for svc in cron crond dcron; do
        if systemd_available; then
            systemctl enable "$svc" --quiet 2>/dev/null || true
            systemctl start "$svc" 2>/dev/null || true
        fi
        if command -v rc-service &>/dev/null; then
            rc-service "$svc" start 2>/dev/null || true
        fi
        if command -v service &>/dev/null; then
            service "$svc" start >/dev/null 2>&1 || true
        fi
    done
    ddns_cron_service_running
}

ddns_cron_service_running() {
    local svc
    for svc in cron crond dcron; do
        if systemd_available && systemctl is-active --quiet "$svc" 2>/dev/null; then
            return 0
        fi
        if command -v rc-service &>/dev/null && rc-service "$svc" status >/dev/null 2>&1; then
            return 0
        fi
        if command -v service &>/dev/null && service "$svc" status >/dev/null 2>&1; then
            return 0
        fi
    done
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 || pgrep -x dcron >/dev/null 2>&1
}

# ── 检测 DDNS 安装状态 ────────────────────────────────────
ddns_status() {
    if [ ! -f "$DDNS_SCRIPT" ]; then
        echo "not_installed"
    elif ! command -v crontab &>/dev/null; then
        echo "no_cron"
    elif ! crontab -l 2>/dev/null | grep -Fq -e "$DDNS_CRON_MARKER" -e "$DDNS_SCRIPT"; then
        echo "stopped"
    elif ! ddns_cron_service_running; then
        echo "cron_stopped"
    else
        echo "running"
    fi
}

# ── 安装/配置 DDNS ────────────────────────────────────────
ddns_install_cloudflare() {
    print_header "Cloudflare DDNS 配置"
    echo -e "  ${DIM}动态 DNS：可分别将 A / AAAA 记录更新为本机公网 IP${NC}"
    echo ""

    for cmd in curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            info "安装依赖 $cmd..."
            pkg_install "$cmd" &>/dev/null || true
            if ! command -v "$cmd" &>/dev/null; then
                error "依赖 ${cmd} 安装失败，请手动安装后重试"
                return 1
            fi
        fi
    done
    if ! ddns_ensure_cron; then
        error "无法安装或启用 crontab/cron，请先手动安装 cron 后重试"
        return
    fi
    if ! ddns_start_cron_service >/dev/null 2>&1; then
        error "cron 服务无法启动，请修复后重试"
        return 1
    fi

    menu_div
    read -rp "  根域名（如 example.com）: " DDNS_ZONE_NAME
    [ -z "$DDNS_ZONE_NAME" ] && { warn "已取消"; return; }
    if ! DDNS_ZONE_NAME=$(ddns_domain_normalize "$DDNS_ZONE_NAME"); then
        error "根域名格式无效"
        return 1
    fi

    local DDNS_ENABLE_A="true" DDNS_ENABLE_AAAA="false"
    local DDNS_SUB4="" DDNS_SUB6="" DDNS_DOMAIN4="" DDNS_DOMAIN6=""

    read -rp "  启用 IPv4 A 记录？(Y/n，默认Y): " DDNS_A_CH
    if echo "$DDNS_A_CH" | grep -qiE '^n(o)?$'; then
        DDNS_ENABLE_A="false"
    else
        read -rp "  IPv4 子域名（A，如 home；@ 表示根域）: " DDNS_SUB4
        [ -z "$DDNS_SUB4" ] && { warn "已取消"; return; }
        DDNS_DOMAIN4=$(ddns_build_domain "$DDNS_SUB4" "$DDNS_ZONE_NAME")
    fi

    local V6_DEFAULT="N"
    [ "$DDNS_ENABLE_A" = "false" ] && V6_DEFAULT="Y"
    read -rp "  启用 IPv6 AAAA 记录？($([ "$V6_DEFAULT" = "Y" ] && echo 'Y/n' || echo 'y/N')，默认${V6_DEFAULT}): " DDNS_AAAA_CH
    case "$DDNS_AAAA_CH" in
        "")
            [ "$V6_DEFAULT" = "Y" ] && DDNS_ENABLE_AAAA="true" || DDNS_ENABLE_AAAA="false"
            ;;
        y|Y|yes|YES) DDNS_ENABLE_AAAA="true" ;;
        *) DDNS_ENABLE_AAAA="false" ;;
    esac

    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        local DDNS_SUB6_DEFAULT DDNS_SHARE_DOMAIN=""
        if [ "$DDNS_ENABLE_A" = "true" ]; then
            read -rp "  A 与 AAAA 共用同一个域名 ${DDNS_DOMAIN4}？(y/N，默认N): " DDNS_SHARE_DOMAIN
        fi
        if echo "$DDNS_SHARE_DOMAIN" | grep -qiE '^y(es)?$'; then
            DDNS_SUB6="$DDNS_SUB4"
        else
            if [ "$DDNS_ENABLE_A" = "true" ]; then
                DDNS_SUB6_DEFAULT=$(ddns_ipv6_subdomain_default "$DDNS_SUB4")
            else
                DDNS_SUB6_DEFAULT="home"
            fi
            read -rp "  IPv6 子域名（AAAA，默认 ${DDNS_SUB6_DEFAULT}；@ 表示根域）: " DDNS_SUB6
            [ -z "$DDNS_SUB6" ] && DDNS_SUB6="$DDNS_SUB6_DEFAULT"
            if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_SUB6" = "$DDNS_SUB4" ]; then
                error "已选择独立域名，但 A 与 AAAA 子域名相同；如需共用请在上一项选择 y"
                return 1
            fi
        fi
        DDNS_DOMAIN6=$(ddns_build_domain "$DDNS_SUB6" "$DDNS_ZONE_NAME")
    fi

    if [ "$DDNS_ENABLE_A" != "true" ] && [ "$DDNS_ENABLE_AAAA" != "true" ]; then
        error "至少需要启用 IPv4 A 或 IPv6 AAAA 其中一种记录"
        return
    fi
    if [ "$DDNS_ENABLE_A" = "true" ]; then
        if ! DDNS_DOMAIN4=$(ddns_domain_normalize "$DDNS_DOMAIN4") || ! ddns_domain_in_zone "$DDNS_DOMAIN4" "$DDNS_ZONE_NAME"; then
            error "IPv4 域名格式无效或不属于根域名 ${DDNS_ZONE_NAME}"
            return 1
        fi
    fi
    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        if ! DDNS_DOMAIN6=$(ddns_domain_normalize "$DDNS_DOMAIN6") || ! ddns_domain_in_zone "$DDNS_DOMAIN6" "$DDNS_ZONE_NAME"; then
            error "IPv6 域名格式无效或不属于根域名 ${DDNS_ZONE_NAME}"
            return 1
        fi
    fi

    read -rp "  Cloudflare API Token（输入可见）: " DDNS_TOKEN
    [ -z "$DDNS_TOKEN" ] && { warn "已取消"; return; }

    local DDNS_MODE="ipv4"
    if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        DDNS_MODE="dual"
    elif [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        DDNS_MODE="ipv6"
    fi

    local DDNS_PROXIED="false"
    read -rp "  是否开启 Cloudflare 代理（橙云）？(y/N，默认N): " DDNS_PROXY_CH
    echo "$DDNS_PROXY_CH" | grep -qiE '^y(es)?$' && DDNS_PROXIED="true"

    local DDNS_TTL="60"
    read -rp "  TTL 秒数（默认60）: " DDNS_TTL_IN
    if ! DDNS_TTL=$(ddns_cf_ttl_normalize "${DDNS_TTL_IN:-60}"); then
        error "Cloudflare TTL 必须为 1（自动）或 60-86400 秒"
        return 1
    fi
    if [ "$DDNS_PROXIED" = "true" ] && [ "$DDNS_TTL" != "1" ]; then
        warn "Cloudflare 代理记录使用自动 TTL，已调整为 1"
        DDNS_TTL=1
    fi
    local DDNS_INTERVAL_MIN
    DDNS_INTERVAL_MIN=$(ddns_prompt_interval 5)

    echo ""
    menu_div
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 A : ${BOLD}${DDNS_DOMAIN4}${NC}" || echo -e "  IPv4 A : ${DIM}未启用${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 AAAA : ${BOLD}${DDNS_DOMAIN6}${NC}" || echo -e "  IPv6 AAAA : ${DIM}未启用${NC}"
    if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        [ "$DDNS_DOMAIN4" = "$DDNS_DOMAIN6" ] \
            && echo -e "  记录方式 : ${BOLD}共用域名（同一域名各 1 条 A / AAAA）${NC}" \
            || {
                echo -e "  记录方式 : ${BOLD}独立域名（IPv4 / IPv6 各 1 条）${NC}"
                echo -e "  交叉清理 : ${BOLD}默认删除 IPv4 域名上的 AAAA 与 IPv6 域名上的 A（输入 n 保留）${NC}"
            }
    fi
    echo -e "  代理   : ${BOLD}$([ "$DDNS_PROXIED" = "true" ] && echo '开启' || echo '关闭')${NC}"
    echo -e "  TTL    : ${BOLD}${DDNS_TTL}${NC}"
    echo -e "  间隔   : ${BOLD}${DDNS_INTERVAL_MIN} 分钟${NC}"
    echo -e "  Token  : ${BOLD}${DDNS_TOKEN:0:8}…${NC}"
    menu_div
    echo ""
    read -rp "  确认安装？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    echo ""
    info "验证 Token 和域名..."
    local ZONE_RESP ZONE_OK ZONE_COUNT ZONE_ID
    ZONE_RESP=$(curl -s --max-time 10         "https://api.cloudflare.com/client/v4/zones?name=${DDNS_ZONE_NAME}"         -H "Authorization: Bearer ${DDNS_TOKEN}")
    ZONE_OK=$(echo "$ZONE_RESP" | python3 -c         "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null)
    if [ "$ZONE_OK" != "True" ]; then
        error "Token 验证失败，请检查 Token 权限（需要 Zone:DNS:Edit）"
        return
    fi
    ZONE_COUNT=$(echo "$ZONE_RESP" | python3 -c         "import sys,json; print(len(json.load(sys.stdin)['result']))" 2>/dev/null)
    if [ "$ZONE_COUNT" = "0" ]; then
        error "找不到域名 ${DDNS_ZONE_NAME}，请确认已托管到此 Cloudflare 账号"
        return
    fi
    ZONE_ID=$(echo "$ZONE_RESP" | python3 -c         "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")
    info "Token 有效，Zone ID: ${ZONE_ID} ✓"

    local DDNS_INITIAL_IP4="" DDNS_INITIAL_IP6=""
    if [ "$DDNS_ENABLE_A" = "true" ]; then
        DDNS_INITIAL_IP4=$(ddns_fetch_public_ip 4) || { error "无法获取有效公网 IPv4，未创建或修改 A 记录"; return 1; }
        ddns_cf_record_ensure "$ZONE_ID" "$DDNS_TOKEN" A "$DDNS_DOMAIN4" "$DDNS_INITIAL_IP4" "$DDNS_TTL" "$DDNS_PROXIED" || return
    fi
    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        DDNS_INITIAL_IP6=$(ddns_fetch_public_ip 6) || { error "无法获取有效公网 IPv6，未创建或修改 AAAA 记录"; return 1; }
        ddns_cf_record_ensure "$ZONE_ID" "$DDNS_TOKEN" AAAA "$DDNS_DOMAIN6" "$DDNS_INITIAL_IP6" "$DDNS_TTL" "$DDNS_PROXIED" || return
    fi
    if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ] && [ "$DDNS_DOMAIN4" != "$DDNS_DOMAIN6" ]; then
        ddns_cf_cleanup_cross_record "$ZONE_ID" "$DDNS_TOKEN" AAAA "$DDNS_DOMAIN4" "IPv4 域名上的额外 AAAA 记录" || true
        ddns_cf_cleanup_cross_record "$ZONE_ID" "$DDNS_TOKEN" A "$DDNS_DOMAIN6" "IPv6 域名上的额外 A 记录" || true
    fi

    if ! ddns_install_tx_begin; then
        error "无法创建 DDNS 配置回滚快照"
        return 1
    fi

    # 保存配置
    if ! printf '%s\n' "$DDNS_TOKEN" > "$DDNS_TOKEN_FILE" || ! chmod 600 "$DDNS_TOKEN_FILE"; then
        error "无法保存 Cloudflare Token"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi
    if ! touch "$DDNS_LOG" 2>/dev/null; then
        DDNS_LOG="$HOME/ddns.log"
        if ! touch "$DDNS_LOG" 2>/dev/null; then
            error "无法创建 DDNS 日志文件"
            ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
            return 1
        fi
    fi
    chmod 644 "$DDNS_LOG" 2>/dev/null || true
    local DDNS_PRIMARY_DOMAIN="${DDNS_DOMAIN4:-$DDNS_DOMAIN6}"
    {
        echo "PROVIDER=cloudflare"
        echo "DOMAIN=${DDNS_PRIMARY_DOMAIN}"
        echo "DOMAIN4=${DDNS_DOMAIN4}"
        echo "DOMAIN6=${DDNS_DOMAIN6}"
        echo "ZONE=${DDNS_ZONE_NAME}"
        echo "MODE=${DDNS_MODE}"
        echo "ENABLE_A=${DDNS_ENABLE_A}"
        echo "ENABLE_AAAA=${DDNS_ENABLE_AAAA}"
        echo "PROXIED=${DDNS_PROXIED}"
        echo "TTL=${DDNS_TTL}"
        echo "INTERVAL_MIN=${DDNS_INTERVAL_MIN}"
        echo "LOG=${DDNS_LOG}"
    } > "$DDNS_ZONE_FILE" || {
        error "无法保存 DDNS 配置"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    }

    # 生成 DDNS 执行脚本
    if ! cat > "$DDNS_SCRIPT" << 'DDNS_INNER'
#!/bin/bash
# 注入 PATH，确保 crontab 环境下能找到 curl / python3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN4="__DOMAIN4__"
DOMAIN6="__DOMAIN6__"
ZONE="__ZONE__"
ENABLE_A="__ENABLE_A__"
ENABLE_AAAA="__ENABLE_AAAA__"
PROXIED="__PROXIED__"
TTL="__TTL__"
TOKEN_FILE="/root/.cf_token"
LOG_FILE="__LOG__"
STATE_DIR="${DDNS_STATE_DIR:-/root}"
LOCK_FILE="/run/vps-tools-ddns.lockfile"
LOCK_DIR="/run/vps-tools-ddns.lock"

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE" || return 1
        flock -n 9 || return 75
        return 0
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf -- "$LOCK_DIR"' EXIT
        return 0
    fi
    local LOCK_PID=""
    [ -f "$LOCK_DIR/pid" ] && read -r LOCK_PID < "$LOCK_DIR/pid"
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        return 75
    fi
    rm -rf -- "$LOCK_DIR" 2>/dev/null || return 1
    mkdir "$LOCK_DIR" 2>/dev/null || return 75
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf -- "$LOCK_DIR"' EXIT
}

acquire_lock || exit $?

API_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
[ -z "$API_TOKEN" ] && exit 1

# 日志轮转：最多保留 500 条记录（每次运行检查）
if [ -f "$LOG_FILE" ]; then
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_LINES" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

log_line() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
}

record_status_file() {
    case "$1" in
        A|AAAA) echo "${STATE_DIR}/.cf_last_status_$1" ;;
        *) echo "${STATE_DIR}/.cf_last_status" ;;
    esac
}

record_change_file() {
    case "$1" in
        A|AAAA) echo "${STATE_DIR}/.cf_last_change_$1" ;;
        *) echo "${STATE_DIR}/.cf_last_change" ;;
    esac
}

record_ip_file() {
    case "$1" in
        A|AAAA) echo "${STATE_DIR}/.cf_last_ip_$1" ;;
        *) echo "${STATE_DIR}/.cf_last_ip" ;;
    esac
}

write_record_status() {
    local TYPE="$1" DOMAIN_NAME="$2" STATE="$3" OLD_IP="${4:-}" NEW_IP="${5:-}" FILE
    FILE=$(record_status_file "$TYPE")
    printf '%s|%s|%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TYPE" "$DOMAIN_NAME" "$STATE" "$OLD_IP" "$NEW_IP" > "$FILE" 2>/dev/null || return 0
    chmod 600 "$FILE" 2>/dev/null || true
}

previous_record_ip() {
    local TYPE="$1" DOMAIN_NAME="$2" FILE _TS RECORD_TYPE RECORD_DOMAIN STATE OLD_IP NEW_IP IP
    FILE=$(record_ip_file "$TYPE")
    if [ -f "$FILE" ]; then
        IFS='|' read -r _TS RECORD_TYPE RECORD_DOMAIN IP < "$FILE"
        if [ "$RECORD_TYPE" = "$TYPE" ] && [ "$RECORD_DOMAIN" = "$DOMAIN_NAME" ] && [ -n "$IP" ]; then
            printf '%s\n' "$IP"
            return 0
        fi
    fi

    # 升级兼容：首次运行时从旧状态文件迁移最后一次成功 IP。
    FILE=$(record_status_file "$TYPE")
    [ -f "$FILE" ] || return 0
    IFS='|' read -r _TS RECORD_TYPE RECORD_DOMAIN STATE OLD_IP NEW_IP < "$FILE"
    [ "$RECORD_TYPE" = "$TYPE" ] && [ "$RECORD_DOMAIN" = "$DOMAIN_NAME" ] || return 0
    case "$STATE" in
        unchanged|updated) printf '%s\n' "${NEW_IP:-$OLD_IP}" ;;
    esac
}

write_record_ip() {
    local TYPE="$1" DOMAIN_NAME="$2" IP="$3" FILE
    [ -n "$IP" ] || return 0
    FILE=$(record_ip_file "$TYPE")
    printf '%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TYPE" "$DOMAIN_NAME" "$IP" > "$FILE" 2>/dev/null || return 0
    chmod 600 "$FILE" 2>/dev/null || true
}

write_record_change() {
    local TYPE="$1" DOMAIN_NAME="$2" OLD_IP="$3" NEW_IP="$4" KIND="${5:-updated}" LINE FILE
    LINE="$(date '+%Y-%m-%d %H:%M:%S')|${TYPE}|${OLD_IP}|${NEW_IP}|${DOMAIN_NAME}|${KIND}"
    FILE=$(record_change_file "$TYPE")
    printf '%s\n' "$LINE" > "$FILE" 2>/dev/null || true
    chmod 600 "$FILE" 2>/dev/null || true
    printf '%s\n' "$LINE" > "${STATE_DIR}/.cf_last_change" 2>/dev/null || true
    chmod 600 "${STATE_DIR}/.cf_last_change" 2>/dev/null || true
}

# 发送 Telegram 通知（每次调用时实时读取配置文件，避免 crontab 变量丢失）
tg_notify() {
    local MSG="$1"
    local TG_FILE="/root/.cf_tg"
    [ -f "$TG_FILE" ] || return 0
    local B_TOKEN C_ID RESP DESCRIPTION
    B_TOKEN=$(grep "^BOT_TOKEN=" "$TG_FILE" | cut -d= -f2-)
    C_ID=$(grep "^CHAT_ID=" "$TG_FILE" | cut -d= -f2-)
    [ -z "$B_TOKEN" ] || [ -z "$C_ID" ] && return 0
    if ! RESP=$(curl -fsS --max-time 15 \
        "https://api.telegram.org/bot${B_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${C_ID}" \
        --data-urlencode "text=${MSG}" \
        --data-urlencode "parse_mode=HTML" 2>/dev/null); then
        log_line WARN "Telegram 通知发送失败：网络或 HTTP 错误"
        return 0
    fi
    if ! printf '%s' "$RESP" | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null; then
        DESCRIPTION=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("description") or "API 返回异常").replace("\n", " "))' 2>/dev/null || echo "API 返回异常")
        log_line WARN "Telegram 通知发送失败：${DESCRIPTION}"
    fi
}

fetch_ip4() {
    (
        curl -4 -fsS --max-time 5 https://api.ipify.org ||
        curl -4 -fsS --max-time 5 https://ifconfig.me/ip ||
        curl -4 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n'
}

fetch_ip6() {
    local IP
    IP=$( (
        curl -6 -fsS --max-time 5 https://api64.ipify.org ||
        curl -6 -fsS --max-time 5 https://ipv6.icanhazip.com ||
        curl -6 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n')
    [ -n "$IP" ] && { echo "$IP"; return 0; }
    fetch_ip6_local
}

fetch_ip6_local() {
    command -v ip >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local ROUTE
    ROUTE=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null) || return 0
    printf '%s\n' "$ROUTE" | python3 -c '
import ipaddress
import sys
for line in sys.stdin:
    parts = line.split()
    if "src" not in parts:
        continue
    try:
        addr = parts[parts.index("src") + 1].split("/")[0]
        ip = ipaddress.ip_address(addr)
    except Exception:
        continue
    if ip.version == 6 and ip.is_global:
        print(ip.compressed)
        break
'
}

valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && \
    echo "$1" | awk -F. '{for(i=1;i<=4;i++) if($i<0||$i>255) exit 1}'
}

valid_ipv6() {
    python3 -c "import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == 6 and ip.is_global else 1)" "$1" 2>/dev/null
}

cf_record_info() {
    local TYPE="$1" DOMAIN_NAME="$2"
    JSON_INPUT=$(cat) python3 - "$TYPE" "$DOMAIN_NAME" <<'PY'
import json
import os
import sys

rtype = sys.argv[1].upper()
target = sys.argv[2].rstrip(".").lower()
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    raise SystemExit(0)
if data.get("success") is not True or not isinstance(data.get("result"), list):
    raise SystemExit(0)
matches = []
for record in data["result"]:
    name = str(record.get("name") or "").rstrip(".").lower()
    if name == target and str(record.get("type") or "").upper() == rtype and record.get("id"):
        matches.append(record)
if len(matches) > 1:
    print(f"DUPLICATE|{len(matches)}")
elif matches:
    content = str(matches[0].get("content") or "").replace("\n", " ").replace("|", " ")
    print(f"{matches[0]['id']}|{content}")
PY
}

if { is_true "$ENABLE_A" && [ -z "$DOMAIN4" ]; } || { is_true "$ENABLE_AAAA" && [ -z "$DOMAIN6" ]; }; then
    log_line ERROR "启用的 A / AAAA 记录缺少域名，请重新生成 DDNS 配置"
    exit 1
fi

ZONE_ID=$(curl -s --max-time 8 "https://api.cloudflare.com/client/v4/zones?name=${ZONE}"     -H "Authorization: Bearer ${API_TOKEN}" |     python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
[ -z "$ZONE_ID" ] && {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取 Zone ID 失败" >> "$LOG_FILE"
    exit 1
}

update_record() {
    local TYPE="$1" DOMAIN_NAME="$2" NEW_IP="$3"
    [ -z "$NEW_IP" ] && return 0
    [ -z "$DOMAIN_NAME" ] && return 0
    local RECORD_INFO RECORD_ID RECORD_COUNT OLD_IP RESULT SUCCESS
    RECORD_INFO=$(curl -s --max-time 8 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN_NAME}&type=${TYPE}" \
        -H "Authorization: Bearer ${API_TOKEN}" | cf_record_info "$TYPE" "$DOMAIN_NAME")
    case "$RECORD_INFO" in
        DUPLICATE\|*)
            RECORD_COUNT=${RECORD_INFO#*|}
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} ${DOMAIN_NAME} 存在 ${RECORD_COUNT} 条重复记录，已停止更新" >> "$LOG_FILE"
            write_record_status "$TYPE" "$DOMAIN_NAME" duplicate "$RECORD_COUNT" "$NEW_IP"
            return 1
            ;;
    esac
    RECORD_ID=${RECORD_INFO%%|*}
    [ -z "$RECORD_ID" ] && {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 记录不存在 ${DOMAIN_NAME}" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" missing "" "$NEW_IP"
        return 1
    }
    OLD_IP=$(curl -s --max-time 8         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}"         -H "Authorization: Bearer ${API_TOKEN}" |         python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)
    # OLD_IP 为空说明查询失败，跳过本次更新避免误推 Telegram
    if [ -z "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${TYPE} 无法获取当前记录值，跳过更新" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" query_failed "" "$NEW_IP"
        return 0
    fi
    if [ "$NEW_IP" = "$OLD_IP" ]; then
        local PREV_IP
        PREV_IP=$(previous_record_ip "$TYPE" "$DOMAIN_NAME")
        write_record_ip "$TYPE" "$DOMAIN_NAME" "$NEW_IP"
        if [ -n "$PREV_IP" ] && [ "$PREV_IP" != "$NEW_IP" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} IP变化 ${PREV_IP} → ${NEW_IP}（DNS已同步）" >> "$LOG_FILE"
            write_record_change "$TYPE" "$DOMAIN_NAME" "$PREV_IP" "$NEW_IP" synced
            tg_notify "🌐 <b>DDNS IP 已变化</b>
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${PREV_IP}</code>
新IP：<code>${NEW_IP}</code>
状态：DNS 已同步
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} 未变化 ${NEW_IP}" >> "$LOG_FILE"
        fi
        write_record_status "$TYPE" "$DOMAIN_NAME" unchanged "$OLD_IP" "$NEW_IP"
        return 0
    fi
    # 二次校验：再次查询确认 OLD_IP 是否真的不一样（防止偶发查询返回错误数据）
    local VERIFY_IP
    VERIFY_IP=$(curl -s --max-time 8 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'])" 2>/dev/null)
    if [ "$NEW_IP" = "$VERIFY_IP" ]; then
        local PREV_IP
        PREV_IP=$(previous_record_ip "$TYPE" "$DOMAIN_NAME")
        write_record_ip "$TYPE" "$DOMAIN_NAME" "$NEW_IP"
        if [ -n "$PREV_IP" ] && [ "$PREV_IP" != "$NEW_IP" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} IP变化 ${PREV_IP} → ${NEW_IP}（DNS已同步，二次确认）" >> "$LOG_FILE"
            write_record_change "$TYPE" "$DOMAIN_NAME" "$PREV_IP" "$NEW_IP" synced
            tg_notify "🌐 <b>DDNS IP 已变化</b>
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${PREV_IP}</code>
新IP：<code>${NEW_IP}</code>
状态：DNS 已同步（二次确认）
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} 未变化 ${NEW_IP}（二次确认）" >> "$LOG_FILE"
        fi
        write_record_status "$TYPE" "$DOMAIN_NAME" unchanged "$VERIFY_IP" "$NEW_IP"
        return 0
    fi
    if [ -z "$VERIFY_IP" ] || [ "$VERIFY_IP" != "$OLD_IP" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: ${TYPE} 二次校验异常 (1st:${OLD_IP} 2nd:${VERIFY_IP})，跳过更新" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" verify_skipped "$OLD_IP" "$NEW_IP"
        return 0
    fi
    local JSON_BODY
    JSON_BODY=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
        "$TYPE" "$DOMAIN_NAME" "$NEW_IP" "$TTL" "$PROXIED")
    RESULT=$(curl -s -X PUT --max-time 10 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$JSON_BODY")
    SUCCESS=$(echo "$RESULT" | python3 -c         "import sys,json; print(json.load(sys.stdin).get('success'))" 2>/dev/null)
    if [ "$SUCCESS" = "True" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: ${TYPE} ${DOMAIN_NAME} 更新成功 ${OLD_IP} → ${NEW_IP}" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" updated "$OLD_IP" "$NEW_IP"
        write_record_change "$TYPE" "$DOMAIN_NAME" "$OLD_IP" "$NEW_IP"
        write_record_ip "$TYPE" "$DOMAIN_NAME" "$NEW_IP"
        tg_notify "🌐 <b>DDNS IP 已更新</b>
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${OLD_IP}</code>
新IP：<code>${NEW_IP}</code>
时间：$(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: ${TYPE} 更新失败 $RESULT" >> "$LOG_FILE"
        write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "$OLD_IP" "$NEW_IP"
        return 1
    fi
}

EXIT_CODE=0

if is_true "$ENABLE_A"; then
    CURRENT_IP4=$(fetch_ip4)
    if [ -z "$CURRENT_IP4" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 无法获取公网 IPv4" >> "$LOG_FILE"
        write_record_status A "$DOMAIN4" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv4 "$CURRENT_IP4"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取到的 IPv4 非法：${CURRENT_IP4}" >> "$LOG_FILE"
        write_record_status A "$DOMAIN4" invalid_ip "" "$CURRENT_IP4"
        EXIT_CODE=1
    else
        update_record A "$DOMAIN4" "$CURRENT_IP4" || EXIT_CODE=1
    fi
fi

if is_true "$ENABLE_AAAA"; then
    CURRENT_IP6=$(fetch_ip6)
    if [ -z "$CURRENT_IP6" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 无法获取公网 IPv6" >> "$LOG_FILE"
        write_record_status AAAA "$DOMAIN6" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv6 "$CURRENT_IP6"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: 获取到的 IPv6 非法：${CURRENT_IP6}" >> "$LOG_FILE"
        write_record_status AAAA "$DOMAIN6" invalid_ip "" "$CURRENT_IP6"
        EXIT_CODE=1
    else
        update_record AAAA "$DOMAIN6" "$CURRENT_IP6" || EXIT_CODE=1
    fi
fi

exit "$EXIT_CODE"
DDNS_INNER
    then
        error "无法生成 DDNS 执行脚本"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi

    local DDNS_DOMAIN4_ESC DDNS_DOMAIN6_ESC DDNS_ZONE_ESC DDNS_LOG_ESC
    DDNS_DOMAIN4_ESC=$(ddns_sed_escape "$DDNS_DOMAIN4")
    DDNS_DOMAIN6_ESC=$(ddns_sed_escape "$DDNS_DOMAIN6")
    DDNS_ZONE_ESC=$(ddns_sed_escape "$DDNS_ZONE_NAME")
    DDNS_LOG_ESC=$(ddns_sed_escape "$DDNS_LOG")
    if ! sed -i \
        -e "s|__DOMAIN4__|${DDNS_DOMAIN4_ESC}|g" \
        -e "s|__DOMAIN6__|${DDNS_DOMAIN6_ESC}|g" \
        -e "s|__ZONE__|${DDNS_ZONE_ESC}|g" \
        -e "s|__ENABLE_A__|${DDNS_ENABLE_A}|g" \
        -e "s|__ENABLE_AAAA__|${DDNS_ENABLE_AAAA}|g" \
        -e "s|__PROXIED__|${DDNS_PROXIED}|g" \
        -e "s|__TTL__|${DDNS_TTL}|g" \
        -e "s|__LOG__|${DDNS_LOG_ESC}|g" "$DDNS_SCRIPT" \
        || ! chmod 700 "$DDNS_SCRIPT" \
        || ! bash -n "$DDNS_SCRIPT"; then
        error "生成的 DDNS 脚本校验失败"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi

    echo ""
    info "立即执行一次测试..."
    if bash "$DDNS_SCRIPT"; then
        tail -1 "$DDNS_LOG" 2>/dev/null | while IFS= read -r l; do echo -e "  ${GREEN}$l${NC}"; done
    else
        error "执行失败，请查看日志"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi
    local CRON_JOB; CRON_JOB="$(ddns_cron_expr "$DDNS_INTERVAL_MIN") ${DDNS_SCRIPT} >> ${DDNS_LOG} 2>&1 ${DDNS_CRON_MARKER}"
    if ! ddns_install_cron_job "$CRON_JOB"; then
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi
    ddns_install_tx_commit
    rm -f "$DDNS_HUAWEI_KEY_FILE" || warn "旧华为云凭据文件无法删除，请手动检查 ${DDNS_HUAWEI_KEY_FILE}"
    info "crontab 已设置（每 ${DDNS_INTERVAL_MIN} 分钟自动更新）✓"
    echo ""
    info "DDNS 配置完成 ✓"
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 : ${BOLD}${DDNS_DOMAIN4}${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 : ${BOLD}${DDNS_DOMAIN6}${NC}"
    echo -e "  日志 : ${DIM}${DDNS_LOG}${NC}"
}

ddns_install_huawei() {
    print_header "华为云 DDNS 配置"
    echo -e "  ${DIM}动态 DNS：通过华为云 DNS API 更新 A / AAAA 记录${NC}"
    echo ""

    for cmd in curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            info "安装依赖 $cmd..."
            pkg_install "$cmd" &>/dev/null || true
            if ! command -v "$cmd" &>/dev/null; then
                error "依赖 ${cmd} 安装失败，请手动安装后重试"
                return 1
            fi
        fi
    done
    if ! ddns_ensure_cron; then
        error "无法安装或启用 crontab/cron，请先手动安装 cron 后重试"
        return
    fi
    if ! ddns_start_cron_service >/dev/null 2>&1; then
        error "cron 服务无法启动，请修复后重试"
        return 1
    fi

    menu_div
    read -rp "  根域名（如 example.com，需已托管到华为云 DNS）: " DDNS_ZONE_NAME
    [ -z "$DDNS_ZONE_NAME" ] && { warn "已取消"; return; }
    if ! DDNS_ZONE_NAME=$(ddns_domain_normalize "$DDNS_ZONE_NAME"); then
        error "根域名格式无效"
        return 1
    fi

    local DDNS_ENDPOINT="https://dns.myhuaweicloud.com"
    read -rp "  API Endpoint（默认 ${DDNS_ENDPOINT}）: " DDNS_ENDPOINT_IN
    if ! DDNS_ENDPOINT=$(ddns_huawei_endpoint_normalize "${DDNS_ENDPOINT_IN:-$DDNS_ENDPOINT}"); then
        error "Endpoint 必须是华为云官方 HTTPS 地址，例如 dns.cn-north-4.myhuaweicloud.com"
        return 1
    fi

    local DDNS_ENABLE_A="true" DDNS_ENABLE_AAAA="false"
    local DDNS_SUB4="" DDNS_SUB6="" DDNS_DOMAIN4="" DDNS_DOMAIN6=""

    read -rp "  启用 IPv4 A 记录？(Y/n，默认Y): " DDNS_A_CH
    if echo "$DDNS_A_CH" | grep -qiE '^n(o)?$'; then
        DDNS_ENABLE_A="false"
    else
        read -rp "  IPv4 子域名（A，如 home；@ 表示根域）: " DDNS_SUB4
        [ -z "$DDNS_SUB4" ] && { warn "已取消"; return; }
        DDNS_DOMAIN4=$(ddns_build_domain "$DDNS_SUB4" "$DDNS_ZONE_NAME")
    fi

    local V6_DEFAULT="N"
    [ "$DDNS_ENABLE_A" = "false" ] && V6_DEFAULT="Y"
    read -rp "  启用 IPv6 AAAA 记录？($([ "$V6_DEFAULT" = "Y" ] && echo 'Y/n' || echo 'y/N')，默认${V6_DEFAULT}): " DDNS_AAAA_CH
    case "$DDNS_AAAA_CH" in
        "")
            [ "$V6_DEFAULT" = "Y" ] && DDNS_ENABLE_AAAA="true" || DDNS_ENABLE_AAAA="false"
            ;;
        y|Y|yes|YES) DDNS_ENABLE_AAAA="true" ;;
        *) DDNS_ENABLE_AAAA="false" ;;
    esac

    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        local DDNS_SUB6_DEFAULT DDNS_SHARE_DOMAIN=""
        if [ "$DDNS_ENABLE_A" = "true" ]; then
            read -rp "  A 与 AAAA 共用同一个域名 ${DDNS_DOMAIN4}？(y/N，默认N): " DDNS_SHARE_DOMAIN
        fi
        if echo "$DDNS_SHARE_DOMAIN" | grep -qiE '^y(es)?$'; then
            DDNS_SUB6="$DDNS_SUB4"
        else
            if [ "$DDNS_ENABLE_A" = "true" ]; then
                DDNS_SUB6_DEFAULT=$(ddns_ipv6_subdomain_default "$DDNS_SUB4")
            else
                DDNS_SUB6_DEFAULT="home"
            fi
            read -rp "  IPv6 子域名（AAAA，默认 ${DDNS_SUB6_DEFAULT}；@ 表示根域）: " DDNS_SUB6
            [ -z "$DDNS_SUB6" ] && DDNS_SUB6="$DDNS_SUB6_DEFAULT"
            if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_SUB6" = "$DDNS_SUB4" ]; then
                error "已选择独立域名，但 A 与 AAAA 子域名相同；如需共用请在上一项选择 y"
                return 1
            fi
        fi
        DDNS_DOMAIN6=$(ddns_build_domain "$DDNS_SUB6" "$DDNS_ZONE_NAME")
    fi

    if [ "$DDNS_ENABLE_A" != "true" ] && [ "$DDNS_ENABLE_AAAA" != "true" ]; then
        error "至少需要启用 IPv4 A 或 IPv6 AAAA 其中一种记录"
        return
    fi
    if [ "$DDNS_ENABLE_A" = "true" ]; then
        if ! DDNS_DOMAIN4=$(ddns_domain_normalize "$DDNS_DOMAIN4") || ! ddns_domain_in_zone "$DDNS_DOMAIN4" "$DDNS_ZONE_NAME"; then
            error "IPv4 域名格式无效或不属于根域名 ${DDNS_ZONE_NAME}"
            return 1
        fi
    fi
    if [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        if ! DDNS_DOMAIN6=$(ddns_domain_normalize "$DDNS_DOMAIN6") || ! ddns_domain_in_zone "$DDNS_DOMAIN6" "$DDNS_ZONE_NAME"; then
            error "IPv6 域名格式无效或不属于根域名 ${DDNS_ZONE_NAME}"
            return 1
        fi
    fi

    read -rp "  华为云 Access Key ID（AK）: " DDNS_HW_AK
    [ -z "$DDNS_HW_AK" ] && { warn "已取消"; return; }
    read -rp "  华为云 Secret Access Key（SK，输入可见）: " DDNS_HW_SK
    [ -z "$DDNS_HW_SK" ] && { warn "已取消"; return; }

    local DDNS_TTL="300"
    read -rp "  TTL 秒数（默认300）: " DDNS_TTL_IN
    if ! DDNS_TTL=$(ddns_huawei_ttl_normalize "${DDNS_TTL_IN:-300}"); then
        error "华为云 TTL 必须为 300-2147483647 秒"
        return 1
    fi
    local DDNS_INTERVAL_MIN
    DDNS_INTERVAL_MIN=$(ddns_prompt_interval 5)

    echo ""
    menu_div
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 A    : ${BOLD}${DDNS_DOMAIN4}${NC}" || echo -e "  IPv4 A    : ${DIM}未启用${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 AAAA : ${BOLD}${DDNS_DOMAIN6}${NC}" || echo -e "  IPv6 AAAA : ${DIM}未启用${NC}"
    if [ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ]; then
        [ "$DDNS_DOMAIN4" = "$DDNS_DOMAIN6" ] \
            && echo -e "  记录方式  : ${BOLD}共用域名（同一域名各 1 条 A / AAAA）${NC}" \
            || echo -e "  记录方式  : ${BOLD}独立域名（IPv4 / IPv6 各 1 条）${NC}"
    fi
    echo -e "  Endpoint  : ${BOLD}${DDNS_ENDPOINT}${NC}"
    echo -e "  TTL       : ${BOLD}${DDNS_TTL}${NC}"
    echo -e "  间隔      : ${BOLD}${DDNS_INTERVAL_MIN} 分钟${NC}"
    echo -e "  AK        : ${BOLD}${DDNS_HW_AK:0:8}…${NC}"
    menu_div
    echo ""
    read -rp "  确认安装？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    if ! ddns_install_tx_begin; then
        error "无法创建 DDNS 配置回滚快照"
        return 1
    fi

    {
        echo "AK=${DDNS_HW_AK}"
        echo "SK=${DDNS_HW_SK}"
    } > "$DDNS_HUAWEI_KEY_FILE" || {
        error "无法保存华为云 AK/SK"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    }
    if ! chmod 600 "$DDNS_HUAWEI_KEY_FILE"; then
        error "无法保护华为云 AK/SK 文件权限"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi

    if ! touch "$DDNS_LOG" 2>/dev/null; then
        DDNS_LOG="$HOME/ddns.log"
        if ! touch "$DDNS_LOG" 2>/dev/null; then
            error "无法创建 DDNS 日志文件"
            ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
            return 1
        fi
    fi
    chmod 644 "$DDNS_LOG" 2>/dev/null || true
    local DDNS_PRIMARY_DOMAIN="${DDNS_DOMAIN4:-$DDNS_DOMAIN6}"
    {
        echo "PROVIDER=huawei"
        echo "DOMAIN=${DDNS_PRIMARY_DOMAIN}"
        echo "DOMAIN4=${DDNS_DOMAIN4}"
        echo "DOMAIN6=${DDNS_DOMAIN6}"
        echo "ZONE=${DDNS_ZONE_NAME}"
        echo "MODE=$([ "$DDNS_ENABLE_A" = "true" ] && [ "$DDNS_ENABLE_AAAA" = "true" ] && echo dual || { [ "$DDNS_ENABLE_AAAA" = "true" ] && echo ipv6 || echo ipv4; })"
        echo "ENABLE_A=${DDNS_ENABLE_A}"
        echo "ENABLE_AAAA=${DDNS_ENABLE_AAAA}"
        echo "ENDPOINT=${DDNS_ENDPOINT}"
        echo "TTL=${DDNS_TTL}"
        echo "INTERVAL_MIN=${DDNS_INTERVAL_MIN}"
        echo "LOG=${DDNS_LOG}"
    } > "$DDNS_ZONE_FILE" || {
        error "无法保存 DDNS 配置"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    }

    if ! cat > "$DDNS_SCRIPT" << 'DDNS_HUAWEI_INNER'
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DOMAIN4="__DOMAIN4__"
DOMAIN6="__DOMAIN6__"
ZONE="__ZONE__"
ENDPOINT="__ENDPOINT__"
ENABLE_A="__ENABLE_A__"
ENABLE_AAAA="__ENABLE_AAAA__"
TTL="__TTL__"
KEY_FILE="/root/.hw_dns_aksk"
LOG_FILE="__LOG__"
STATE_DIR="${DDNS_STATE_DIR:-/root}"
LOCK_FILE="/run/vps-tools-ddns.lockfile"
LOCK_DIR="/run/vps-tools-ddns.lock"

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE" || return 1
        flock -n 9 || return 75
        return 0
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf -- "$LOCK_DIR"' EXIT
        return 0
    fi
    local LOCK_PID=""
    [ -f "$LOCK_DIR/pid" ] && read -r LOCK_PID < "$LOCK_DIR/pid"
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        return 75
    fi
    rm -rf -- "$LOCK_DIR" 2>/dev/null || return 1
    mkdir "$LOCK_DIR" 2>/dev/null || return 75
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf -- "$LOCK_DIR"' EXIT
}

acquire_lock || exit $?

ENDPOINT=${ENDPOINT%/}
ZONE_DOT="${ZONE%.}."
AK=$(grep "^AK=" "$KEY_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
SK=$(grep "^SK=" "$KEY_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [ -z "$AK" ] || [ -z "$SK" ]; then
    exit 1
fi

if [ -f "$LOG_FILE" ]; then
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_LINES" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

fqdn_dot() {
    local NAME="$1"
    case "$NAME" in
        *.) echo "$NAME" ;;
        *) echo "${NAME}." ;;
    esac
}

log_line() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"
}

record_status_file() {
    case "$1" in
        A|AAAA) echo "${STATE_DIR}/.cf_last_status_$1" ;;
        *) echo "${STATE_DIR}/.cf_last_status" ;;
    esac
}

record_change_file() {
    case "$1" in
        A|AAAA) echo "${STATE_DIR}/.cf_last_change_$1" ;;
        *) echo "${STATE_DIR}/.cf_last_change" ;;
    esac
}

record_ip_file() {
    case "$1" in
        A|AAAA) echo "${STATE_DIR}/.cf_last_ip_$1" ;;
        *) echo "${STATE_DIR}/.cf_last_ip" ;;
    esac
}

write_record_status() {
    local TYPE="$1" DOMAIN_NAME="$2" STATE="$3" OLD_IP="${4:-}" NEW_IP="${5:-}" FILE
    FILE=$(record_status_file "$TYPE")
    printf '%s|%s|%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TYPE" "$DOMAIN_NAME" "$STATE" "$OLD_IP" "$NEW_IP" > "$FILE" 2>/dev/null || return 0
    chmod 600 "$FILE" 2>/dev/null || true
}

previous_record_ip() {
    local TYPE="$1" DOMAIN_NAME="$2" FILE _TS RECORD_TYPE RECORD_DOMAIN STATE OLD_IP NEW_IP IP
    FILE=$(record_ip_file "$TYPE")
    if [ -f "$FILE" ]; then
        IFS='|' read -r _TS RECORD_TYPE RECORD_DOMAIN IP < "$FILE"
        if [ "$RECORD_TYPE" = "$TYPE" ] && [ "$RECORD_DOMAIN" = "$DOMAIN_NAME" ] && [ -n "$IP" ]; then
            printf '%s\n' "$IP"
            return 0
        fi
    fi

    # 升级兼容：首次运行时从旧状态文件迁移最后一次成功 IP。
    FILE=$(record_status_file "$TYPE")
    [ -f "$FILE" ] || return 0
    IFS='|' read -r _TS RECORD_TYPE RECORD_DOMAIN STATE OLD_IP NEW_IP < "$FILE"
    [ "$RECORD_TYPE" = "$TYPE" ] && [ "$RECORD_DOMAIN" = "$DOMAIN_NAME" ] || return 0
    case "$STATE" in
        unchanged|updated) printf '%s\n' "${NEW_IP:-$OLD_IP}" ;;
    esac
}

write_record_ip() {
    local TYPE="$1" DOMAIN_NAME="$2" IP="$3" FILE
    [ -n "$IP" ] || return 0
    FILE=$(record_ip_file "$TYPE")
    printf '%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TYPE" "$DOMAIN_NAME" "$IP" > "$FILE" 2>/dev/null || return 0
    chmod 600 "$FILE" 2>/dev/null || true
}

write_record_change() {
    local TYPE="$1" DOMAIN_NAME="$2" OLD_IP="$3" NEW_IP="$4" KIND="${5:-updated}" LINE FILE
    LINE="$(date '+%Y-%m-%d %H:%M:%S')|${TYPE}|${OLD_IP}|${NEW_IP}|${DOMAIN_NAME}|${KIND}"
    FILE=$(record_change_file "$TYPE")
    printf '%s\n' "$LINE" > "$FILE" 2>/dev/null || true
    chmod 600 "$FILE" 2>/dev/null || true
    printf '%s\n' "$LINE" > "${STATE_DIR}/.cf_last_change" 2>/dev/null || true
    chmod 600 "${STATE_DIR}/.cf_last_change" 2>/dev/null || true
}

tg_notify() {
    local MSG="$1"
    local TG_FILE="/root/.cf_tg"
    [ -f "$TG_FILE" ] || return 0
    local B_TOKEN C_ID RESP DESCRIPTION
    B_TOKEN=$(grep "^BOT_TOKEN=" "$TG_FILE" | cut -d= -f2-)
    C_ID=$(grep "^CHAT_ID=" "$TG_FILE" | cut -d= -f2-)
    [ -z "$B_TOKEN" ] || [ -z "$C_ID" ] && return 0
    if ! RESP=$(curl -fsS --max-time 15 \
        "https://api.telegram.org/bot${B_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${C_ID}" \
        --data-urlencode "text=${MSG}" \
        --data-urlencode "parse_mode=HTML" 2>/dev/null); then
        log_line WARN "Telegram 通知发送失败：网络或 HTTP 错误"
        return 0
    fi
    if ! printf '%s' "$RESP" | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null; then
        DESCRIPTION=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("description") or "API 返回异常").replace("\n", " "))' 2>/dev/null || echo "API 返回异常")
        log_line WARN "Telegram 通知发送失败：${DESCRIPTION}"
    fi
}

fetch_ip4() {
    (
        curl -4 -fsS --max-time 5 https://api.ipify.org ||
        curl -4 -fsS --max-time 5 https://ifconfig.me/ip ||
        curl -4 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n'
}

fetch_ip6() {
    local IP
    IP=$( (
        curl -6 -fsS --max-time 5 https://api64.ipify.org ||
        curl -6 -fsS --max-time 5 https://ipv6.icanhazip.com ||
        curl -6 -fsS --max-time 5 https://ip.sb
    ) 2>/dev/null | tr -d ' \r\n')
    [ -n "$IP" ] && { echo "$IP"; return 0; }
    fetch_ip6_local
}

fetch_ip6_local() {
    command -v ip >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local ROUTE
    ROUTE=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null) || return 0
    printf '%s\n' "$ROUTE" | python3 -c '
import ipaddress
import sys
for line in sys.stdin:
    parts = line.split()
    if "src" not in parts:
        continue
    try:
        addr = parts[parts.index("src") + 1].split("/")[0]
        ip = ipaddress.ip_address(addr)
    except Exception:
        continue
    if ip.version == 6 and ip.is_global:
        print(ip.compressed)
        break
'
}

valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && \
    echo "$1" | awk -F. '{for(i=1;i<=4;i++) if($i<0||$i>255) exit 1}'
}

valid_ipv6() {
    python3 -c "import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == 6 and ip.is_global else 1)" "$1" 2>/dev/null
}

huawei_api() {
    local METHOD="$1" API_PATH="$2" QUERY="${3:-}" BODY="${4:-}"
    HUAWEI_AK="$AK" HUAWEI_SK="$SK" HUAWEI_ENDPOINT="$ENDPOINT" \
    HUAWEI_METHOD="$METHOD" HUAWEI_PATH="$API_PATH" HUAWEI_QUERY="$QUERY" HUAWEI_BODY="$BODY" \
    python3 <<'PY'
import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ak = os.environ["HUAWEI_AK"]
sk = os.environ["HUAWEI_SK"].encode()
endpoint = os.environ["HUAWEI_ENDPOINT"].rstrip("/")
if "://" not in endpoint:
    endpoint = "https://" + endpoint
method = os.environ["HUAWEI_METHOD"].upper()
api_path = os.environ["HUAWEI_PATH"]
query = os.environ.get("HUAWEI_QUERY", "")
body = os.environ.get("HUAWEI_BODY", "")

parts = urllib.parse.urlsplit(endpoint)
base_path = parts.path.rstrip("/")
path = base_path + (api_path if api_path.startswith("/") else "/" + api_path)
host = parts.netloc
sdk_date = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

params = urllib.parse.parse_qsl(query, keep_blank_values=True)
canonical_query = urllib.parse.urlencode(sorted(params), doseq=True, safe="-_.~")
canonical_uri = urllib.parse.quote(path, safe="/-_.~")
if not canonical_uri.endswith("/"):
    canonical_uri += "/"
payload_hash = hashlib.sha256(body.encode()).hexdigest()
signed_headers = "content-type;host;x-sdk-date"
canonical_headers = (
    "content-type:application/json\n"
    f"host:{host}\n"
    f"x-sdk-date:{sdk_date}\n"
)
canonical_request = "\n".join([
    method,
    canonical_uri,
    canonical_query,
    canonical_headers,
    signed_headers,
    payload_hash,
])
algorithm = "SDK-HMAC-SHA256"
hashed_request = hashlib.sha256(canonical_request.encode()).hexdigest()
string_to_sign = "\n".join([algorithm, sdk_date, hashed_request])
signature = hmac.new(sk, string_to_sign.encode(), hashlib.sha256).hexdigest()
authorization = f"{algorithm} Access={ak}, SignedHeaders={signed_headers}, Signature={signature}"

url = f"{parts.scheme}://{host}{path}"
if canonical_query:
    url += "?" + canonical_query
data = body.encode() if method not in ("GET", "HEAD") else None
headers = {
    "Content-Type": "application/json",
    "Host": host,
    "X-Sdk-Date": sdk_date,
    "Authorization": authorization,
}
req = urllib.request.Request(url, data=data, headers=headers, method=method)
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        sys.stdout.write(resp.read().decode())
except urllib.error.HTTPError as exc:
    sys.stdout.write(exc.read().decode())
    sys.exit(1)
except Exception:
    sys.exit(1)
PY
}

json_zone_id() {
    JSON_INPUT=$(cat) python3 - "$ZONE_DOT" <<'PY'
import json
import os
import sys
target = sys.argv[1].rstrip(".") + "."
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    sys.exit(0)
for zone in data.get("zones", []):
    name = (zone.get("name") or "").rstrip(".") + "."
    if name == target and zone.get("zone_type", "public") == "public":
        print(zone.get("id", ""))
        break
PY
}

json_record_info() {
    local TYPE="$1" DOMAIN_NAME="$2"
    JSON_INPUT=$(cat) python3 - "$TYPE" "$DOMAIN_NAME" <<'PY'
import json
import os
import sys
rtype = sys.argv[1]
target = sys.argv[2].rstrip(".") + "."
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    sys.exit(0)
for record in data.get("recordsets", []):
    name = (record.get("name") or "").rstrip(".") + "."
    if name == target and record.get("type") == rtype:
        records = record.get("records") or []
        print(f"{record.get('id', '')}|{records[0] if records else ''}")
        break
PY
}

json_top_record() {
    JSON_INPUT=$(cat) python3 <<'PY'
import json
import os
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    raise SystemExit(0)
records = data.get("records") or []
print(records[0] if records else "")
PY
}

json_top_id() {
    JSON_INPUT=$(cat) python3 <<'PY'
import json
import os
try:
    data = json.loads(os.environ.get("JSON_INPUT", "{}"))
except Exception:
    raise SystemExit(0)
print(data.get("id", ""))
PY
}

record_body() {
    local TYPE="$1" DOMAIN_NAME="$2" NEW_IP="$3"
    python3 - "$TYPE" "$DOMAIN_NAME" "$TTL" "$NEW_IP" <<'PY'
import json
import sys
rtype, name, ttl, value = sys.argv[1:]
body = {
    "name": name.rstrip(".") + ".",
    "type": rtype,
    "ttl": int(ttl),
    "records": [value],
    "description": "VPS TOOLS DDNS",
}
print(json.dumps(body, separators=(",", ":")))
PY
}

if { is_true "$ENABLE_A" && [ -z "$DOMAIN4" ]; } || { is_true "$ENABLE_AAAA" && [ -z "$DOMAIN6" ]; }; then
    log_line ERROR "启用的 A / AAAA 记录缺少域名，请重新生成 DDNS 配置"
    exit 1
fi

if ! ZONE_RESP=$(huawei_api GET "/v2/zones" "type=public&limit=500" ""); then
    log_line ERROR "查询华为云 Zone 失败，请检查网络、AK/SK 和 Endpoint"
    exit 1
fi
ZONE_ID=$(printf '%s' "$ZONE_RESP" | json_zone_id)
[ -z "$ZONE_ID" ] && {
    log_line ERROR "获取华为云 Zone ID 失败，请检查 AK/SK、Endpoint 和域名 ${ZONE}"
    exit 1
}

update_record() {
    local TYPE="$1" DOMAIN_NAME="$2" NEW_IP="$3"
    [ -z "$NEW_IP" ] && return 0
    [ -z "$DOMAIN_NAME" ] && return 0
    local DOMAIN_DOT RECORD_RESP RECORD_INFO RECORD_ID OLD_IP BODY RESULT UPDATED_IP CREATED_ID
    DOMAIN_DOT=$(fqdn_dot "$DOMAIN_NAME")
    if ! RECORD_RESP=$(huawei_api GET "/v2/zones/${ZONE_ID}/recordsets" "search_mode=equal&type=${TYPE}&name=${DOMAIN_DOT}&limit=100" ""); then
        log_line ERROR "${TYPE} ${DOMAIN_NAME} 查询记录失败"
        write_record_status "$TYPE" "$DOMAIN_NAME" query_failed "" "$NEW_IP"
        return 1
    fi
    RECORD_INFO=$(printf '%s' "$RECORD_RESP" | json_record_info "$TYPE" "$DOMAIN_DOT")
    RECORD_ID=${RECORD_INFO%%|*}
    OLD_IP=${RECORD_INFO#*|}
    if [ -z "$RECORD_ID" ]; then
        BODY=$(record_body "$TYPE" "$DOMAIN_DOT" "$NEW_IP")
        if ! RESULT=$(huawei_api POST "/v2/zones/${ZONE_ID}/recordsets" "" "$BODY"); then
            log_line ERROR "${TYPE} ${DOMAIN_NAME} 创建失败 ${RESULT}"
            write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "" "$NEW_IP"
            return 1
        fi
        CREATED_ID=$(printf '%s' "$RESULT" | json_top_id)
        if [ -n "$CREATED_ID" ]; then
            log_line OK "${TYPE} ${DOMAIN_NAME} 创建成功 ${NEW_IP}"
            write_record_status "$TYPE" "$DOMAIN_NAME" updated "" "$NEW_IP"
            write_record_change "$TYPE" "$DOMAIN_NAME" "" "$NEW_IP"
            write_record_ip "$TYPE" "$DOMAIN_NAME" "$NEW_IP"
            return 0
        fi
        log_line ERROR "${TYPE} ${DOMAIN_NAME} 创建失败 ${RESULT}"
        write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "" "$NEW_IP"
        return 1
    fi
    if [ -z "$OLD_IP" ]; then
        log_line WARN "${TYPE} ${DOMAIN_NAME} 无法获取当前记录值，跳过更新"
        write_record_status "$TYPE" "$DOMAIN_NAME" query_failed "" "$NEW_IP"
        return 0
    fi
    if [ "$NEW_IP" = "$OLD_IP" ]; then
        local PREV_IP
        PREV_IP=$(previous_record_ip "$TYPE" "$DOMAIN_NAME")
        write_record_ip "$TYPE" "$DOMAIN_NAME" "$NEW_IP"
        if [ -n "$PREV_IP" ] && [ "$PREV_IP" != "$NEW_IP" ]; then
            log_line OK "${TYPE} ${DOMAIN_NAME} IP变化 ${PREV_IP} → ${NEW_IP}（DNS已同步）"
            write_record_change "$TYPE" "$DOMAIN_NAME" "$PREV_IP" "$NEW_IP" synced
            tg_notify "🌐 <b>DDNS IP 已变化</b>
服务商：华为云 DNS
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${PREV_IP}</code>
新IP：<code>${NEW_IP}</code>
状态：DNS 已同步
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        else
            log_line OK "${TYPE} ${DOMAIN_NAME} 未变化 ${NEW_IP}"
        fi
        write_record_status "$TYPE" "$DOMAIN_NAME" unchanged "$OLD_IP" "$NEW_IP"
        return 0
    fi
    BODY=$(record_body "$TYPE" "$DOMAIN_DOT" "$NEW_IP")
    if ! RESULT=$(huawei_api PUT "/v2.1/zones/${ZONE_ID}/recordsets/${RECORD_ID}" "" "$BODY"); then
        log_line ERROR "${TYPE} ${DOMAIN_NAME} 更新失败 ${RESULT}"
        write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "$OLD_IP" "$NEW_IP"
        return 1
    fi
    UPDATED_IP=$(printf '%s' "$RESULT" | json_top_record)
    if [ "$UPDATED_IP" = "$NEW_IP" ]; then
        log_line OK "${TYPE} ${DOMAIN_NAME} 更新成功 ${OLD_IP} → ${NEW_IP}"
        write_record_status "$TYPE" "$DOMAIN_NAME" updated "$OLD_IP" "$NEW_IP"
        write_record_change "$TYPE" "$DOMAIN_NAME" "$OLD_IP" "$NEW_IP"
        write_record_ip "$TYPE" "$DOMAIN_NAME" "$NEW_IP"
        tg_notify "🌐 <b>DDNS IP 已更新</b>
服务商：华为云 DNS
域名：<code>${DOMAIN_NAME}</code>
类型：${TYPE}
旧IP：<code>${OLD_IP}</code>
新IP：<code>${NEW_IP}</code>
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        return 0
    fi
    log_line ERROR "${TYPE} ${DOMAIN_NAME} 更新失败 ${RESULT}"
    write_record_status "$TYPE" "$DOMAIN_NAME" update_failed "$OLD_IP" "$NEW_IP"
    return 1
}

EXIT_CODE=0

if is_true "$ENABLE_A"; then
    CURRENT_IP4=$(fetch_ip4)
    if [ -z "$CURRENT_IP4" ]; then
        log_line ERROR "A ${DOMAIN4} 无法获取公网 IPv4"
        write_record_status A "$DOMAIN4" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv4 "$CURRENT_IP4"; then
        log_line ERROR "A ${DOMAIN4} 获取到的 IPv4 非法：${CURRENT_IP4}"
        write_record_status A "$DOMAIN4" invalid_ip "" "$CURRENT_IP4"
        EXIT_CODE=1
    else
        update_record A "$DOMAIN4" "$CURRENT_IP4" || EXIT_CODE=1
    fi
fi

if is_true "$ENABLE_AAAA"; then
    CURRENT_IP6=$(fetch_ip6)
    if [ -z "$CURRENT_IP6" ]; then
        log_line ERROR "AAAA ${DOMAIN6} 无法获取公网 IPv6"
        write_record_status AAAA "$DOMAIN6" fetch_failed "" ""
        EXIT_CODE=1
    elif ! valid_ipv6 "$CURRENT_IP6"; then
        log_line ERROR "AAAA ${DOMAIN6} 获取到的 IPv6 非法：${CURRENT_IP6}"
        write_record_status AAAA "$DOMAIN6" invalid_ip "" "$CURRENT_IP6"
        EXIT_CODE=1
    else
        update_record AAAA "$DOMAIN6" "$CURRENT_IP6" || EXIT_CODE=1
    fi
fi

exit "$EXIT_CODE"
DDNS_HUAWEI_INNER
    then
        error "无法生成 DDNS 执行脚本"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi

    local DDNS_DOMAIN4_ESC DDNS_DOMAIN6_ESC DDNS_ZONE_ESC DDNS_ENDPOINT_ESC DDNS_LOG_ESC
    DDNS_DOMAIN4_ESC=$(ddns_sed_escape "$DDNS_DOMAIN4")
    DDNS_DOMAIN6_ESC=$(ddns_sed_escape "$DDNS_DOMAIN6")
    DDNS_ZONE_ESC=$(ddns_sed_escape "$DDNS_ZONE_NAME")
    DDNS_ENDPOINT_ESC=$(ddns_sed_escape "$DDNS_ENDPOINT")
    DDNS_LOG_ESC=$(ddns_sed_escape "$DDNS_LOG")
    if ! sed -i \
        -e "s|__DOMAIN4__|${DDNS_DOMAIN4_ESC}|g" \
        -e "s|__DOMAIN6__|${DDNS_DOMAIN6_ESC}|g" \
        -e "s|__ZONE__|${DDNS_ZONE_ESC}|g" \
        -e "s|__ENDPOINT__|${DDNS_ENDPOINT_ESC}|g" \
        -e "s|__ENABLE_A__|${DDNS_ENABLE_A}|g" \
        -e "s|__ENABLE_AAAA__|${DDNS_ENABLE_AAAA}|g" \
        -e "s|__TTL__|${DDNS_TTL}|g" \
        -e "s|__LOG__|${DDNS_LOG_ESC}|g" "$DDNS_SCRIPT" \
        || ! chmod 700 "$DDNS_SCRIPT" \
        || ! bash -n "$DDNS_SCRIPT"; then
        error "生成的 DDNS 脚本校验失败"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi

    echo ""
    info "立即执行一次测试..."
    if bash "$DDNS_SCRIPT"; then
        tail -1 "$DDNS_LOG" 2>/dev/null | while IFS= read -r l; do echo -e "  ${GREEN}$l${NC}"; done
    else
        error "执行失败，请查看日志"
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi
    local CRON_JOB; CRON_JOB="$(ddns_cron_expr "$DDNS_INTERVAL_MIN") ${DDNS_SCRIPT} >> ${DDNS_LOG} 2>&1 ${DDNS_CRON_MARKER}"
    if ! ddns_install_cron_job "$CRON_JOB"; then
        ddns_install_tx_restore || error "恢复原 DDNS 配置失败，请立即检查"
        return 1
    fi
    ddns_install_tx_commit
    rm -f "$DDNS_TOKEN_FILE" || warn "旧 Cloudflare Token 文件无法删除，请手动检查 ${DDNS_TOKEN_FILE}"
    info "crontab 已设置（每 ${DDNS_INTERVAL_MIN} 分钟自动更新）✓"
    echo ""
    info "华为云 DDNS 配置完成 ✓"
    [ "$DDNS_ENABLE_A" = "true" ] && echo -e "  IPv4 : ${BOLD}${DDNS_DOMAIN4}${NC}"
    [ "$DDNS_ENABLE_AAAA" = "true" ] && echo -e "  IPv6 : ${BOLD}${DDNS_DOMAIN6}${NC}"
    echo -e "  日志 : ${DIM}${DDNS_LOG}${NC}"
}

ddns_install() {
    print_header "DDNS 服务商"
    echo -e "  ${DIM}选择要使用的 DNS 服务商。已有 Cloudflare 配置不会自动迁移。${NC}"
    echo ""
    menu_div
    menu_item "1" "Cloudflare"
    menu_item "2" "华为云 DNS"
    menu_item "0" "返回上级" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择服务商 [1-2]: ')" PROVIDER_CH
    case "$PROVIDER_CH" in
        1|"") ddns_install_cloudflare ;;
        2) ddns_install_huawei ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

# ── 暂停/恢复 DDNS ────────────────────────────────────────
ddns_pause() {
    [ ! -f "$DDNS_SCRIPT" ] && { error "DDNS 未安装"; return; }
    if ! ddns_remove_cron_job; then
        error "暂停失败，原定时任务未可靠移除"
        return 1
    fi
    info "DDNS 自动更新已暂停 ✓"
}

ddns_resume() {
    [ ! -f "$DDNS_SCRIPT" ] && { error "DDNS 未安装"; return; }
    if ! command -v crontab &>/dev/null; then
        info "检测到 cron 未安装，正在自动安装..."
        if ! ddns_ensure_cron; then
            error "cron 安装失败，请手动执行：apt-get install -y cron"
            return
        fi
    fi
    local LOG INTERVAL_MIN CRON_JOB
    LOG=$(ddns_log_path)
    INTERVAL_MIN=$(ddns_interval_min)
    CRON_JOB="$(ddns_cron_expr "$INTERVAL_MIN") ${DDNS_SCRIPT} >> ${LOG} 2>&1 ${DDNS_CRON_MARKER}"
    ddns_install_cron_job "$CRON_JOB" || return 1
    info "DDNS 自动更新已恢复（每 ${INTERVAL_MIN} 分钟）✓"
}

# ── 卸载 DDNS ─────────────────────────────────────────────
# ── Telegram 通知配置 ─────────────────────────────────────
ddns_tg_config() {
    print_header "Telegram 通知配置"
    echo -e "  ${DIM}IP 变化时自动发送 Telegram 通知${NC}"
    echo ""

    if [ -f "$DDNS_TG_FILE" ]; then
        local CUR_BOT CUR_CHAT
        CUR_BOT=$(grep "^BOT_TOKEN=" "$DDNS_TG_FILE" | cut -d= -f2-)
        CUR_CHAT=$(grep "^CHAT_ID=" "$DDNS_TG_FILE" | cut -d= -f2-)
        echo -e "  当前状态：${GREEN}${BOLD}已配置${NC}"
        echo -e "  Bot Token：${DIM}${CUR_BOT:0:10}…${NC}"
        echo -e "  Chat ID  ：${BOLD}${CUR_CHAT}${NC}"
    else
        echo -e "  当前状态：${YELLOW}未配置${NC}"
    fi

    echo ""
    menu_div
    echo -e "  ${DIM}如何获取：${NC}"
    echo -e "  ${DIM}① Telegram 搜索 @BotFather → /newbot 创建机器人${NC}"
    echo -e "  ${DIM}② 获取 Bot Token（格式：123456:ABC-xxx）${NC}"
    echo -e "  ${DIM}③ 与机器人发一条消息，再访问：${NC}"
    echo -e "  ${DIM}   https://api.telegram.org/bot<TOKEN>/getUpdates${NC}"
    echo -e "  ${DIM}④ 从返回的 chat.id 字段获取 Chat ID${NC}"
    menu_div
    echo ""
    menu_pair "1" "配置 Telegram 通知" "2" "发送测试消息"
    [ -f "$DDNS_TG_FILE" ] && menu_item "3" "关闭 Telegram 通知" "$YELLOW"
    menu_item "0" "返回上级" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择操作: ')" CH

    case "$CH" in
        1)
            echo ""
            read -rp "  Bot Token（输入可见）: " TG_BOT
            [ -z "$TG_BOT" ] && { warn "已取消"; return; }
            read -rp "  Chat ID: " TG_CHAT
            [ -z "$TG_CHAT" ] && { warn "已取消"; return; }
            {
                echo "BOT_TOKEN=${TG_BOT}"
                echo "CHAT_ID=${TG_CHAT}"
            } > "$DDNS_TG_FILE"
            chmod 600 "$DDNS_TG_FILE"
            info "Telegram 通知已配置 ✓"
            ;;
        2)
            if [ ! -f "$DDNS_TG_FILE" ]; then
                error "请先配置 Telegram 通知"; return
            fi
            local BOT CHAT
            BOT=$(grep "^BOT_TOKEN=" "$DDNS_TG_FILE" | cut -d= -f2-)
            CHAT=$(grep "^CHAT_ID=" "$DDNS_TG_FILE" | cut -d= -f2-)
            info "发送测试消息..."
            local RESP
            local TG_DOMAIN_TEXT
            TG_DOMAIN_TEXT="服务商：$(ddns_provider_label)
模式：$(ddns_mode_label)"
            if ddns_cfg_enable_a; then
                TG_DOMAIN_TEXT="${TG_DOMAIN_TEXT}
IPv4：$(ddns_cfg_domain4)"
            fi
            if ddns_cfg_enable_aaaa; then
                TG_DOMAIN_TEXT="${TG_DOMAIN_TEXT}
IPv6：$(ddns_cfg_domain6)"
            fi
            if ! RESP=$(curl -fsS --max-time 10 \
                "https://api.telegram.org/bot${BOT}/sendMessage" \
                --data-urlencode "chat_id=${CHAT}" \
                --data-urlencode "text=🔔 DDNS 通知测试
${TG_DOMAIN_TEXT}
时间：$(date '+%Y-%m-%d %H:%M:%S')
✅ 通知配置成功！" \
                --data-urlencode "parse_mode=HTML" 2>/dev/null); then
                error "发送失败：网络或 HTTP 错误"
                return 1
            fi
            if echo "$RESP" | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null; then
                info "发送成功 ✓"
            else
                local TG_DESC
                TG_DESC=$(echo "$RESP" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("description") or "API 返回异常").replace("\n", " "))' 2>/dev/null || echo "API 返回异常")
                error "发送失败：${TG_DESC}"
                return 1
            fi
            ;;
        3)
            rm -f "$DDNS_TG_FILE" && info "Telegram 通知已关闭 ✓"
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

ddns_uninstall() {
    print_header "卸载 DDNS"
    warn "将移除 crontab 定时任务、DDNS 脚本和 API 凭据文件"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    if ! ddns_remove_cron_job; then
        error "卸载已中止：定时任务移除失败，脚本和凭据均未删除"
        return 1
    fi
    info "crontab 定时任务已移除 ✓"
    rm -f "$DDNS_SCRIPT" && info "DDNS 脚本已删除 ✓"
    rm -f "$DDNS_TOKEN_FILE" && info "Token 文件已删除 ✓"
    rm -f "$DDNS_HUAWEI_KEY_FILE" && info "华为云 AK/SK 文件已删除 ✓"
    rm -f "$DDNS_ZONE_FILE"
    rm -f "${DDNS_STATE_DIR:-/root}/.cf_last_change" "${DDNS_STATE_DIR:-/root}/.cf_last_change_A" "${DDNS_STATE_DIR:-/root}/.cf_last_change_AAAA"
    rm -f "${DDNS_STATE_DIR:-/root}/.cf_last_status_A" "${DDNS_STATE_DIR:-/root}/.cf_last_status_AAAA"
    rm -f "${DDNS_STATE_DIR:-/root}/.cf_last_ip" "${DDNS_STATE_DIR:-/root}/.cf_last_ip_A" "${DDNS_STATE_DIR:-/root}/.cf_last_ip_AAAA"
    warn "日志文件保留：${DDNS_LOG}"
}

# ── 查看日志 ──────────────────────────────────────────────
ddns_view_logs() {
    while true; do
        print_header "DDNS 日志"
        local LOG; LOG=$(ddns_log_path)
        if [ ! -f "$LOG" ]; then warn "日志文件不存在"; return; fi
        echo -e "  ${DIM}${LOG}${NC}"
        menu_div
        tail -20 "$LOG" | while IFS= read -r line; do
            if echo "$line" | grep -q "ERROR"; then
                echo -e "  ${RED}$line${NC}"
            elif echo "$line" | grep -q "OK:.*更新成功"; then
                echo -e "  ${GREEN}$line${NC}"
            else
                echo -e "  ${DIM}$line${NC}"
            fi
        done
        echo ""
        menu_div
        menu_item "1" "实时跟踪  ${DIM}Ctrl+C 返回${NC}"
        menu_item "2" "查看完整日志"
        menu_item "0" "返回上级" "$RED"
        echo ""
        read -rp "$(ui_prompt '选择查看方式: ')" CH
        case "$CH" in
            1)
                # 设置 trap 后再 tail -f；trap 仅在 tail 进程内生效
                trap "echo ''; info '已退出实时跟踪'" INT
                tail -f "$LOG"
                trap - INT
                ;;
            2)
                LANG=C.UTF-8 LESSCHARSET=utf-8 less -R "$LOG"
                ;;
            0|"")
                return
                ;;
            *)
                warn "无效选项"; sleep 1
                ;;
        esac
    done
}

ddns_runtime_cfg_get() {
    local key="$1"
    [ -f "$DDNS_SCRIPT" ] || return 1
    sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$DDNS_SCRIPT" 2>/dev/null | head -1
}

ddns_runtime_config_matches() {
    local expected_a="false" expected_aaaa="false"
    local runtime_a runtime_aaaa expected_domain runtime_domain
    ddns_cfg_enable_a && expected_a="true"
    ddns_cfg_enable_aaaa && expected_aaaa="true"
    runtime_a=$(ddns_runtime_cfg_get ENABLE_A 2>/dev/null || true)
    runtime_aaaa=$(ddns_runtime_cfg_get ENABLE_AAAA 2>/dev/null || true)
    ddns_truthy "$runtime_a" && runtime_a="true" || runtime_a="false"
    ddns_truthy "$runtime_aaaa" && runtime_aaaa="true" || runtime_aaaa="false"
    [ "$runtime_a" = "$expected_a" ] && [ "$runtime_aaaa" = "$expected_aaaa" ] || return 1
    if [ "$expected_a" = "true" ]; then
        expected_domain=$(ddns_cfg_domain4)
        runtime_domain=$(ddns_runtime_cfg_get DOMAIN4 2>/dev/null || true)
        [ -n "$expected_domain" ] && [ "$runtime_domain" = "$expected_domain" ] || return 1
    fi
    if [ "$expected_aaaa" = "true" ]; then
        expected_domain=$(ddns_cfg_domain6)
        runtime_domain=$(ddns_runtime_cfg_get DOMAIN6 2>/dev/null || true)
        [ -n "$expected_domain" ] && [ "$runtime_domain" = "$expected_domain" ] || return 1
    fi
}

ddns_print_run_result() {
    local marker="$1" label="$2" type="$3" domain="$4"
    local state_file line
    state_file=$(ddns_type_status_file "$type")
    if [ ! -f "$state_file" ] || [ ! "$state_file" -nt "$marker" ]; then
        echo -e "  ${YELLOW}本次 ${label}: 未执行或状态写入失败${NC}"
        return 1
    fi
    line=$(ddns_line_from_state_file "$type" "$domain" 2>/dev/null || true)
    if [ -z "$line" ]; then
        echo -e "  ${YELLOW}本次 ${label}: 状态与当前域名不匹配${NC}"
        return 1
    fi
    case "$line" in
        *" ERROR: "*) echo -e "  ${RED}本次 ${label}: ${line}${NC}" ;;
        *" WARN: "*)  echo -e "  ${YELLOW}本次 ${label}: ${line}${NC}" ;;
        *)             echo -e "  ${GREEN}本次 ${label}: ${line}${NC}" ;;
    esac
}

ddns_print_run_results() {
    local marker="$1" failed=0 domain
    if ddns_cfg_enable_a; then
        domain=$(ddns_cfg_domain4)
        ddns_print_run_result "$marker" "IPv4" A "$domain" || failed=1
    fi
    if ddns_cfg_enable_aaaa; then
        domain=$(ddns_cfg_domain6)
        ddns_print_run_result "$marker" "IPv6" AAAA "$domain" || failed=1
    fi
    return "$failed"
}

# ── 手动立即更新 ──────────────────────────────────────────
ddns_run_now() {
    print_header "手动更新 DDNS"
    [ ! -f "$DDNS_SCRIPT" ] && { error "DDNS 未安装"; return; }
    if ! ddns_runtime_config_matches; then
        error "DDNS 运行脚本与当前配置不一致，已停止更新"
        echo -e "  ${DIM}请进入修改配置，重新确认并生成 A / AAAA 更新脚本${NC}"
        return 1
    fi
    local RUN_MARK
    RUN_MARK=$(mktemp /tmp/vps-tools-ddns-run.XXXXXX) || {
        error "无法创建 DDNS 运行状态标记"
        return 1
    }
    info "正在更新..."
    local RC
    if bash "$DDNS_SCRIPT"; then
        RC=0
    else
        RC=$?
    fi
    if [ "$RC" -eq 0 ]; then
        if ! ddns_print_run_results "$RUN_MARK"; then
            error "未检测到全部启用记录的本次状态，请重新生成 DDNS 配置"
            rm -f "$RUN_MARK"
            return 1
        fi
    elif [ "$RC" -eq 75 ]; then
        warn "已有一次 DDNS 更新正在运行，请稍后再试"
    else
        ddns_print_run_results "$RUN_MARK" || true
        error "更新失败，请查看日志"
    fi
    rm -f "$RUN_MARK"
}

# ── DDNS 主菜单 ───────────────────────────────────────────
ddns_menu() {
    while true; do
        local D_ST; D_ST=$(ddns_status)
        local D_COLOR D_LABEL
        case "$D_ST" in
            running)       D_COLOR="$GREEN";  D_LABEL="运行中" ;;
            stopped)       D_COLOR="$RED";    D_LABEL="已停止（cron任务未设置）" ;;
            no_cron)       D_COLOR="$RED";    D_LABEL="已停止（cron未安装）" ;;
            cron_stopped)  D_COLOR="$RED";    D_LABEL="已停止（cron服务未运行）" ;;
            not_installed) D_COLOR="$YELLOW"; D_LABEL="未安装" ;;
        esac

        local D_PROVIDER_LABEL D_TITLE
        if [ -f "$DDNS_ZONE_FILE" ]; then
            D_PROVIDER_LABEL=$(ddns_provider_label)
            D_TITLE="${D_PROVIDER_LABEL} DDNS"
        else
            D_PROVIDER_LABEL="DDNS"
            D_TITLE="DDNS"
        fi
        print_header "$D_TITLE"

        if [ "$D_ST" != "not_installed" ] && [ -f "$DDNS_ZONE_FILE" ]; then
            local D_DOMAIN4 D_DOMAIN6 D_MODE_LABEL D_PROVIDER D_PROXIED D_ENDPOINT D_TTL D_INTERVAL D_LOG
            D_DOMAIN4=$(ddns_cfg_domain4)
            D_DOMAIN6=$(ddns_cfg_domain6)
            D_MODE_LABEL=$(ddns_mode_label)
            D_PROVIDER=$(ddns_provider)
            D_PROXIED=$(ddns_cfg_get PROXIED)
            D_ENDPOINT=$(ddns_cfg_get ENDPOINT)
            D_TTL=$(ddns_cfg_get TTL)
            D_INTERVAL=$(ddns_interval_min)
            D_LOG=$(ddns_log_path)
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo -e "  服务商 : ${BOLD}${D_PROVIDER_LABEL}${NC}"
            echo -e "  模式 : ${BOLD}${D_MODE_LABEL}${NC}"
            if ddns_cfg_enable_a; then
                echo -e "  IPv4 : ${BOLD}${D_DOMAIN4:-未配置}${NC} ${DIM}(A)${NC}"
            else
                echo -e "  IPv4 : ${DIM}未启用${NC}"
            fi
            if ddns_cfg_enable_aaaa; then
                echo -e "  IPv6 : ${BOLD}${D_DOMAIN6:-未配置}${NC} ${DIM}(AAAA)${NC}"
            else
                echo -e "  IPv6 : ${DIM}未启用${NC}"
            fi
            if [ "$D_PROVIDER" = "huawei" ]; then
                echo -e "  Endpoint : ${BOLD}${D_ENDPOINT:-https://dns.myhuaweicloud.com}${NC}"
            else
                echo -e "  代理 : ${BOLD}$([ "$D_PROXIED" = "true" ] && echo '开启' || echo '关闭')${NC}"
            fi
            echo -e "  TTL  : ${BOLD}${D_TTL:-60}${NC}"
            echo -e "  定时 : ${DIM}每 ${D_INTERVAL} 分钟自动更新${NC}"
            ddns_cfg_enable_a && ddns_print_record_summary "IPv4" A "$D_DOMAIN4" "$D_LOG"
            ddns_cfg_enable_aaaa && ddns_print_record_summary "IPv6" AAAA "$D_DOMAIN6" "$D_LOG"
        elif [ -f "$DDNS_ZONE_FILE" ]; then
            local D_DOMAIN4 D_DOMAIN6 D_MODE_LABEL D_PROVIDER D_TOKEN_HINT
            D_DOMAIN4=$(ddns_cfg_domain4)
            D_DOMAIN6=$(ddns_cfg_domain6)
            D_MODE_LABEL=$(ddns_mode_label)
            D_PROVIDER=$(ddns_provider)
            if [ "$D_PROVIDER" = "huawei" ]; then
                [ -f "$DDNS_HUAWEI_KEY_FILE" ] && D_TOKEN_HINT="${DIM}AK/SK 已保存${NC}" || D_TOKEN_HINT="${YELLOW}AK/SK 未找到${NC}"
            else
                [ -f "$DDNS_TOKEN_FILE" ] && D_TOKEN_HINT="${DIM}Token 已保存${NC}" || D_TOKEN_HINT="${YELLOW}Token 未找到${NC}"
            fi
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo -e "  服务商 : ${BOLD}${D_PROVIDER_LABEL}${NC}"
            echo -e "  模式 : ${BOLD}${D_MODE_LABEL}${NC}"
            ddns_cfg_enable_a && echo -e "  IPv4 : ${BOLD}${D_DOMAIN4:-未配置}${NC} ${DIM}(A)${NC}"
            ddns_cfg_enable_aaaa && echo -e "  IPv6 : ${BOLD}${D_DOMAIN6:-未配置}${NC} ${DIM}(AAAA)${NC}"
            echo -e "  凭据 : $D_TOKEN_HINT"
            echo ""
            echo -e "  ${DIM}检测到历史配置，可重新安装恢复定时任务${NC}"
        else
            echo -e "  状态 : ${D_COLOR}${BOLD}${D_LABEL}${NC}"
            echo ""
            echo -e "  ${DIM}将动态 DNS 解析到本机 IP，适合家宽/动态 IP 场景${NC}"
            echo ""
            echo -e "  ${BOLD}安装前准备：${NC}"
            menu_div
            echo -e "  ${GREEN}①${NC} 域名已托管到 Cloudflare 或华为云 DNS"
            echo -e "     将域名 NS 记录指向对应服务商提供的 nameserver"
            echo ""
            echo -e "  ${GREEN}②${NC} 准备 API 凭据"
            echo -e "     ${DIM}Cloudflare：API Token，权限 Zone / DNS / Edit${NC}"
            echo -e "     ${DIM}华为云：Access Key ID（AK）和 Secret Access Key（SK），账号需有 DNS 写权限${NC}"
            echo ""
            echo -e "  ${GREEN}③${NC} 准备子域名（如 home.example.com 的 home 部分）"
            menu_div
        fi

        echo ""
        menu_div
        if [ "$D_ST" = "not_installed" ]; then
            menu_item "1" "开始安装并配置 DDNS"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        else
            menu_pair "1" "立即更新" "2" "查看日志"
            menu_pair "3" "修改配置" "6" "Telegram 通知"
            if [ "$D_ST" = "running" ]; then
                menu_pair "4" "暂停自动更新" "5" "卸载 DDNS" "$YELLOW" "$YELLOW"
            elif [ "$D_ST" = "no_cron" ]; then
                menu_pair "4" "安装 cron 并恢复" "5" "卸载 DDNS" "$GREEN" "$YELLOW"
            else
                menu_pair "4" "恢复自动更新" "5" "卸载 DDNS" "$GREEN" "$YELLOW"
            fi
            menu_item "7" "替换分享链接地址"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        fi
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作: ')" CH

        if [ "$D_ST" = "not_installed" ]; then
            case "$CH" in
                1) ddns_install ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1; continue ;;
            esac
        else
            case "$CH" in
                1) ddns_run_now ;;
                2) ddns_view_logs ;;
                3) warn "修改配置将重新安装 DDNS"
                   read -rp "  确认继续？(Y/n，默认Y): " C
                   [ -z "$C" ] && C="y"
                   if echo "$C" | grep -qiE '^y(es)?$'; then
                       ddns_install
                   else
                       warn "已取消"
                   fi ;;
                4)
                   if [ "$D_ST" = "running" ]; then
                       ddns_pause
                   else
                       ddns_resume
                   fi ;;
                5) ddns_uninstall ;;
                6) ddns_tg_config ;;
                7) ddns_share_link_tool ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1; continue ;;
            esac
        fi

        # 日志查看后不需要再 Enter 一次（内部已有循环）
        if [ "$CH" != "0" ] && [ "$CH" != "2" ]; then
            ui_pause
        fi
    done
}
