# ══════════════════════════════════════════════════════════
#  STUN / UDP / NAT 检测
# ══════════════════════════════════════════════════════════

stun_ports_normalize() {
    local RAW="${1//,/ }" TOKEN OUT="" SEEN="," COUNT=0
    RAW="${RAW//;/ }"
    for TOKEN in $RAW; do
        case "$TOKEN" in ''|*[!0-9]*) return 1 ;; esac
        [ "$TOKEN" -ge 1 ] && [ "$TOKEN" -le 65535 ] || return 1
        case "$SEEN" in
            *",${TOKEN},"*) continue ;;
        esac
        COUNT=$((COUNT + 1))
        [ "$COUNT" -le 12 ] || return 1
        SEEN="${SEEN}${TOKEN},"
        if [ -n "$OUT" ]; then OUT="${OUT},${TOKEN}"; else OUT="$TOKEN"; fi
    done
    [ -n "$OUT" ] || return 1
    printf '%s\n' "$OUT"
}

stun_host_valid() {
    local HOST="$1"
    [ -n "$HOST" ] && [ "${#HOST}" -le 253 ] || return 1
    [[ "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$HOST" != *..* ]]
}

stun_nat_type_label() {
    case "$1" in
        open_internet)       echo "公网直连（无 NAT）" ;;
        public_udp_firewall) echo "公网直连 + UDP 过滤" ;;
        full_cone)           echo "Full Cone（全锥型）" ;;
        restricted_cone)     echo "Restricted Cone（地址限制锥型）" ;;
        port_restricted)     echo "Port-Restricted Cone（端口限制锥型）" ;;
        symmetric)           echo "Symmetric NAT（对称型倾向）" ;;
        nat_unknown)         echo "检测到 NAT（细分未知）" ;;
        udp_unavailable)     echo "UDP / STUN 无有效响应" ;;
        *)                   echo "未知" ;;
    esac
}

stun_mapping_label() {
    case "$1" in
        eim)                echo "Endpoint-Independent" ;;
        adm)                echo "Address-Dependent" ;;
        apdm)               echo "Address-and-Port-Dependent" ;;
        endpoint_dependent) echo "Endpoint-Dependent" ;;
        *)                  echo "未知（证据不足）" ;;
    esac
}

stun_filtering_label() {
    case "$1" in
        eif)  echo "Endpoint-Independent" ;;
        adf)  echo "Address-Dependent" ;;
        apdf) echo "Address-and-Port-Dependent" ;;
        *)    echo "未知（服务器不支持或响应不足）" ;;
    esac
}

stun_confidence_label() {
    case "$1" in high) echo "高" ;; medium) echo "中" ;; *) echo "低" ;; esac
}

stun_udp_explanation() {
    local OK_COUNT="$1" TOTAL_COUNT="$2"
    if [ "$OK_COUNT" -eq 0 ]; then
        echo "无节点响应，请检查 UDP 出站、防火墙或上游网络"
    elif [ "$OK_COUNT" -eq "$TOTAL_COUNT" ]; then
        echo "全部节点响应，UDP 出站和返回流量正常"
    else
        echo "${OK_COUNT}/${TOTAL_COUNT} 节点响应，UDP 可用；失败多为节点或路由差异"
    fi
}

stun_nat_explanation() {
    case "$1" in
        open_internet)       echo "本机直接使用公网 IPv4，没有上游 NAT" ;;
        public_udp_firewall) echo "没有 NAT，但 UDP 返回流量受到防火墙限制" ;;
        full_cone)           echo "固定公网映射，外部来源均可回包，P2P 条件较好" ;;
        restricted_cone)     echo "固定映射，仅已联系过的目标 IP 可以回包" ;;
        port_restricted)     echo "固定映射，仅已联系过的目标 IP:端口可以回包" ;;
        symmetric)           echo "映射随目标改变，UDP 打洞和 P2P 直连较困难" ;;
        nat_unknown)         echo "确认存在 NAT，但证据不足，无法继续细分" ;;
        udp_unavailable)     echo "没有 STUN 响应，暂时无法判定 NAT" ;;
        *)                   echo "当前证据无法判断 NAT 类型" ;;
    esac
}

stun_mapping_explanation() {
    case "$1" in
        eim)                echo "访问不同目标时保持同一公网 IP:端口" ;;
        adm)                echo "目标 IP 改变时，公网映射会改变" ;;
        apdm)               echo "目标 IP 或端口改变时，公网映射会改变" ;;
        endpoint_dependent) echo "公网映射随目标变化，依赖类型尚无法细分" ;;
        *)                  echo "响应不足，无法确定公网端口映射规律" ;;
    esac
}

stun_filtering_explanation() {
    case "$1" in
        eif)  echo "建立映射后，任意外部来源均可回包" ;;
        adf)  echo "仅已主动访问的目标 IP 可以回包" ;;
        apdf) echo "仅已主动访问的目标 IP:端口可以回包" ;;
        *)    echo "服务器缺少辅助能力，暂时无法确定回包限制" ;;
    esac
}

stun_confidence_explanation() {
    case "$1" in
        high)   echo "映射和过滤证据完整，判定可靠性较高" ;;
        medium) echo "已获得公网映射，但部分辅助证据不足" ;;
        *)      echo "有效响应或辅助证据不足，结果仅供参考" ;;
    esac
}

stun_recommendation() {
    case "$1" in
        open_internet)       echo "入站仍需确认本机防火墙和服务监听" ;;
        public_udp_firewall) echo "检查本机或上游防火墙的 UDP 入站规则" ;;
        full_cone|restricted_cone|port_restricted)
                             echo "需要公网入站时，优先配置固定端口转发" ;;
        symmetric|nat_unknown)
                             echo "入站服务需端口转发、DMZ、1:1 NAT 或公网 IP" ;;
        *)                   echo "先确认服务商是否允许 UDP，再检查本机防火墙" ;;
    esac
}

stun_ensure_python() {
    command -v python3 >/dev/null 2>&1 && return 0
    info "正在安装 Python 3..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install python3 >/dev/null 2>&1
    else
        pkg_install python3 >/dev/null 2>&1
    fi
    command -v python3 >/dev/null 2>&1 || {
        error "STUN 检测需要 Python 3"
        return 1
    }
}

stun_probe_engine() {
    local MODE="$1" HOST="${2:--}" PORTS="${3:--}"
    python3 - "$MODE" "$HOST" "$PORTS" <<'PY'
import ipaddress
import secrets
import socket
import struct
import sys
import time

COOKIE = 0x2112A442
COOKIE_BYTES = struct.pack("!I", COOKIE)


def emit(*values):
    clean = []
    for value in values:
        text = str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")
        clean.append(text if text else "-")
    print("\t".join(clean))


def decode_address(value, txid, xor_address=False):
    if len(value) < 4:
        raise ValueError("short address")
    family = value[1]
    port = struct.unpack("!H", value[2:4])[0]
    if xor_address:
        port ^= COOKIE >> 16
    if family == 0x01:
        size = 4
        af = socket.AF_INET
    elif family == 0x02:
        size = 16
        af = socket.AF_INET6
    else:
        raise ValueError("unsupported address family")
    if len(value) < 4 + size:
        raise ValueError("short address value")
    packed = value[4:4 + size]
    if xor_address:
        key = COOKIE_BYTES + txid
        packed = bytes(a ^ b for a, b in zip(packed, key[:size]))
    return socket.inet_ntop(af, packed), port


def parse_message(data, expected_txid):
    if len(data) < 20:
        raise ValueError("short STUN header")
    msg_type, msg_len, cookie, txid = struct.unpack("!HHI12s", data[:20])
    if cookie != COOKIE or txid != expected_txid or msg_len > len(data) - 20:
        raise ValueError("invalid STUN response")
    result = {"type": msg_type, "txid": txid}
    offset = 20
    end = 20 + msg_len
    while offset + 4 <= end:
        attr_type, attr_len = struct.unpack("!HH", data[offset:offset + 4])
        value_start = offset + 4
        value_end = value_start + attr_len
        if value_end > end:
            raise ValueError("invalid STUN attribute length")
        value = data[value_start:value_end]
        try:
            if attr_type == 0x0020:
                result["xor_mapped"] = decode_address(value, txid, True)
            elif attr_type == 0x0001:
                result["mapped"] = decode_address(value, txid, False)
            elif attr_type == 0x0005:
                result["changed"] = decode_address(value, txid, False)
            elif attr_type == 0x802B:
                result["response_origin"] = decode_address(value, txid, False)
            elif attr_type == 0x802C:
                result["other"] = decode_address(value, txid, False)
            elif attr_type == 0x0009 and len(value) >= 4:
                result["error"] = (value[2] & 0x07) * 100 + value[3]
        except (OSError, ValueError):
            pass
        offset = value_start + ((attr_len + 3) // 4) * 4
    result["mapped_address"] = result.get("xor_mapped") or result.get("mapped")
    return result


def binding_request(sock, address, change_flags=0, timeout=1.0, retries=2):
    txid = secrets.token_bytes(12)
    attrs = struct.pack("!HHI", 0x0003, 4, change_flags) if change_flags else b""
    packet = struct.pack("!HHI12s", 0x0001, len(attrs), COOKIE, txid) + attrs
    started = time.monotonic()
    last_error = "timeout"
    for _ in range(retries):
        try:
            sock.sendto(packet, address)
        except OSError as exc:
            return None, exc.__class__.__name__, int((time.monotonic() - started) * 1000)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, source = sock.recvfrom(4096)
            except socket.timeout:
                break
            except OSError as exc:
                last_error = exc.__class__.__name__
                break
            try:
                response = parse_message(data, txid)
            except ValueError:
                continue
            response["source"] = (source[0], source[1])
            elapsed = int((time.monotonic() - started) * 1000)
            if response.get("type") == 0x0101 and response.get("mapped_address"):
                return response, "ok", elapsed
            if response.get("type") == 0x0111:
                return response, "stun_error", elapsed
    return None, last_error, int((time.monotonic() - started) * 1000)


def route_source_ip(address):
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(address)
        return probe.getsockname()[0]
    except OSError:
        return "-"
    finally:
        probe.close()


def safe_other_address(address):
    if not address:
        return False
    try:
        ip = ipaddress.ip_address(address[0])
        return ip.version == 4 and ip.is_global and 1 <= int(address[1]) <= 65535
    except (ValueError, TypeError):
        return False


def classify_nat(success_count, has_nat, mapping, filtering):
    if success_count == 0:
        return "udp_unavailable"
    if has_nat is False:
        if filtering in ("adf", "apdf"):
            return "public_udp_firewall"
        return "open_internet"
    if mapping in ("adm", "apdm", "endpoint_dependent"):
        return "symmetric"
    if mapping == "eim":
        if filtering == "eif":
            return "full_cone"
        if filtering == "adf":
            return "restricted_cone"
        if filtering == "apdf":
            return "port_restricted"
    return "nat_unknown"


def self_test():
    txid = bytes(range(12))
    expected_ip = "203.0.113.7"
    expected_port = 54321
    raw_ip = socket.inet_pton(socket.AF_INET, expected_ip)
    encoded_ip = bytes(a ^ b for a, b in zip(raw_ip, COOKIE_BYTES))
    encoded_port = expected_port ^ (COOKIE >> 16)
    value = b"\x00\x01" + struct.pack("!H", encoded_port) + encoded_ip
    attribute = struct.pack("!HH", 0x0020, len(value)) + value
    packet = struct.pack("!HHI12s", 0x0101, len(attribute), COOKIE, txid) + attribute
    parsed = parse_message(packet, txid)
    assert parsed["mapped_address"] == (expected_ip, expected_port)
    try:
        parse_message(packet, b"wrong-tx-id!")
        raise AssertionError("transaction ID mismatch was accepted")
    except ValueError:
        pass
    assert classify_nat(2, True, "eim", "eif") == "full_cone"
    assert classify_nat(2, True, "eim", "adf") == "restricted_cone"
    assert classify_nat(2, True, "eim", "apdf") == "port_restricted"
    assert classify_nat(2, True, "apdm", "unknown") == "symmetric"
    assert classify_nat(2, False, "eim", "apdf") == "public_udp_firewall"
    assert classify_nat(0, None, "unknown", "unknown") == "udp_unavailable"
    emit("SELFTEST", "ok")


def endpoint_list(mode, host, ports):
    if mode == "quick":
        return [
            ("stun.nextcloud.com", 443),
            ("stun.nextcloud.com", 3478),
            ("stun.cloudflare.com", 3478),
            ("stun.l.google.com", 19302),
            ("stun.miwifi.com", 3478),
        ]
    return [(host, int(port)) for port in ports.split(",")]


def main(mode, host, ports):
    if mode == "selftest":
        self_test()
        return
    endpoints = endpoint_list(mode, host, ports)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    local_port = sock.getsockname()[1]
    results = []
    for endpoint_host, endpoint_port in endpoints:
        record = {"host": endpoint_host, "port": endpoint_port, "status": "dns_error"}
        try:
            answers = socket.getaddrinfo(endpoint_host, endpoint_port, socket.AF_INET, socket.SOCK_DGRAM)
            resolved_ip = answers[0][4][0]
            address = (resolved_ip, endpoint_port)
            record.update({"resolved": resolved_ip, "address": address})
            response, status, elapsed = binding_request(sock, address)
            record.update({"response": response, "status": status, "elapsed": elapsed})
            if response and response.get("mapped_address"):
                record["mapped"] = response["mapped_address"]
        except (OSError, ValueError) as exc:
            record["error"] = exc.__class__.__name__
        results.append(record)

    successful = [record for record in results if record.get("mapped")]
    local_ip = route_source_ip(successful[0]["address"]) if successful else "-"
    external = successful[0]["mapped"] if successful else None

    evidence = []
    for index, left in enumerate(successful):
        for right in successful[index + 1:]:
            if left["address"] != right["address"]:
                evidence.append((left["address"], left["mapped"], right["address"], right["mapped"]))

    for record in successful:
        other = record["response"].get("other") or record["response"].get("changed")
        if safe_other_address(other) and other != record["address"]:
            other_response, _, _ = binding_request(sock, other)
            if other_response and other_response.get("mapped_address"):
                evidence.append((record["address"], record["mapped"], other, other_response["mapped_address"]))

    same_ip_equal = same_ip_diff = cross_ip_equal = cross_ip_diff = False
    for first_address, first_mapping, second_address, second_mapping in evidence:
        same_mapping = first_mapping == second_mapping
        if first_address[0] == second_address[0] and first_address[1] != second_address[1]:
            same_ip_equal |= same_mapping
            same_ip_diff |= not same_mapping
        elif first_address[0] != second_address[0]:
            cross_ip_equal |= same_mapping
            cross_ip_diff |= not same_mapping
    if same_ip_diff:
        mapping = "apdm"
    elif cross_ip_diff:
        mapping = "adm" if same_ip_equal else "endpoint_dependent"
    elif same_ip_equal or cross_ip_equal:
        mapping = "eim"
    else:
        mapping = "unknown"

    filtering = "unknown"
    filtering_evidence = False
    for record in successful:
        response = record["response"]
        other = response.get("other") or response.get("changed")
        if not safe_other_address(other):
            continue
        origin = response.get("source")
        alternate_ip_available = bool(origin and other[0] != origin[0])
        changed, changed_status, _ = binding_request(sock, record["address"], 0x06)
        if changed and origin and changed.get("source") != origin:
            changed_source = changed["source"]
            if changed_source[0] != origin[0]:
                filtering = "eif"
                filtering_evidence = True
                break
            # A port-only source change does not prove that the server honored CHANGE-IP.
            continue
        if changed and origin and changed.get("source") == origin:
            continue
        changed_port, port_status, _ = binding_request(sock, record["address"], 0x02)
        if alternate_ip_available and changed_port and origin and changed_port.get("source") != origin:
            port_source = changed_port["source"]
            filtering = "eif" if port_source[0] != origin[0] else "adf"
            filtering_evidence = True
            break
        if changed_port and origin and changed_port.get("source") == origin:
            continue
        if alternate_ip_available and changed_status == "timeout" and port_status == "timeout":
            filtering = "apdf"
            filtering_evidence = True
            break

    has_nat = None
    if external and local_ip != "-":
        has_nat = external[0] != local_ip
    nat_type = classify_nat(len(successful), has_nat, mapping, filtering)
    if nat_type in ("open_internet", "public_udp_firewall") and filtering_evidence:
        confidence = "high"
    elif mapping != "unknown" and filtering_evidence:
        confidence = "high"
    elif len(successful) >= 2 or has_nat is not None:
        confidence = "medium"
    else:
        confidence = "low"

    for record in results:
        mapped = record.get("mapped")
        mapped_text = f"{mapped[0]}:{mapped[1]}" if mapped else "-"
        emit(
            "PROBE", record["host"], record["port"], record.get("resolved", "-"),
            "ok" if mapped else record.get("status", "error"), mapped_text,
            record.get("elapsed", "-"), record.get("error", "-"),
        )
    for port in sorted({record["port"] for record in results}):
        port_records = [record for record in results if record["port"] == port]
        ok_count = sum(1 for record in port_records if record.get("mapped"))
        emit("PORT", port, ok_count, len(port_records))
    external_text = f"{external[0]}:{external[1]}" if external else "-"
    emit(
        "SUMMARY", local_ip, local_port, external_text, mapping, filtering, nat_type,
        confidence, len(successful), len(results),
    )
    sock.close()


try:
    main(sys.argv[1], sys.argv[2], sys.argv[3])
except Exception as exc:
    emit("FATAL", exc.__class__.__name__)
    raise SystemExit(1)
PY
}

stun_render_results() {
    local OUTPUT="$1" KIND A B C D E F G H I
    local LOCAL_IP="-" LOCAL_PORT="-" EXTERNAL="-" MAPPING="unknown" FILTERING="unknown"
    local NAT_TYPE="unknown" CONFIDENCE="low" OK_COUNT=0 TOTAL_COUNT=0

    echo -e "  ${BOLD}STUN 端点${NC}"
    while IFS=$'\t' read -r KIND A B C D E F G H I; do
        case "$KIND" in
            PROBE)
                if [ "$D" = "ok" ]; then
                    echo -e "  ${GREEN}✓${NC}  ${A}:${B}  ${BOLD}${E}${NC}  ${DIM}${F}ms${NC}"
                else
                    echo -e "  ${RED}×${NC}  ${A}:${B}  ${YELLOW}${D}${NC}"
                fi
                ;;
            PORT)
                printf '  UDP/%-5s  %s/%s 响应\n' "$A" "$B" "$C"
                ;;
            SUMMARY)
                LOCAL_IP="$A"; LOCAL_PORT="$B"; EXTERNAL="$C"; MAPPING="$D"; FILTERING="$E"
                NAT_TYPE="$F"; CONFIDENCE="$G"; OK_COUNT="$H"; TOTAL_COUNT="$I"
                ;;
            FATAL)
                error "STUN 协议引擎执行失败：${A}"
                return 1
                ;;
        esac
    done <<< "$OUTPUT"

    echo ""
    menu_div
    echo -e "  本地出口 : ${BOLD}${LOCAL_IP}:${LOCAL_PORT}${NC}"
    echo -e "  公网映射 : ${BOLD}${EXTERNAL}${NC}"
    echo -e "  有效响应 : ${BOLD}${OK_COUNT}/${TOTAL_COUNT}${NC}"
    echo -e "  IPv4 NAT : ${CYAN}${BOLD}$(stun_nat_type_label "$NAT_TYPE")${NC}"
    echo -e "  映射行为 : ${BOLD}$(stun_mapping_label "$MAPPING")${NC}"
    echo -e "  过滤行为 : ${BOLD}$(stun_filtering_label "$FILTERING")${NC}"
    echo -e "  判定置信 : ${BOLD}$(stun_confidence_label "$CONFIDENCE")${NC}"
    menu_div
    echo -e "  ${BOLD}结果解释${NC}"
    echo -e "  ${CYAN}UDP${NC}  : $(stun_udp_explanation "$OK_COUNT" "$TOTAL_COUNT")"
    echo -e "  ${CYAN}NAT${NC}  : $(stun_nat_explanation "$NAT_TYPE")"
    echo -e "  ${CYAN}映射${NC} : $(stun_mapping_explanation "$MAPPING")"
    echo -e "  ${CYAN}过滤${NC} : $(stun_filtering_explanation "$FILTERING")"
    echo -e "  ${CYAN}置信${NC} : $(stun_confidence_explanation "$CONFIDENCE")"
    echo -e "  ${CYAN}建议${NC} : $(stun_recommendation "$NAT_TYPE")"
    menu_div
}

stun_probe_execute() {
    local MODE="$1" HOST="${2:--}" PORTS="${3:--}" OUTPUT
    stun_ensure_python || return 1
    info "正在执行 STUN 与多端口 UDP 探测..."
    if ! OUTPUT=$(stun_probe_engine "$MODE" "$HOST" "$PORTS"); then
        error "STUN 检测执行失败"
        return 1
    fi
    stun_render_results "$OUTPUT" || return 1
    audit_action "STUN NAT 检测 ${MODE} ${HOST} ${PORTS}" SUCCESS
}

stun_nat_quick() {
    print_header "STUN / NAT 检测"
    stun_probe_execute quick
}

stun_nat_custom() {
    print_header "自定义 STUN 多端口"
    local HOST PORT_INPUT PORTS
    read -rp "  STUN 主机（默认 stun.nextcloud.com）: " HOST
    HOST=${HOST:-stun.nextcloud.com}
    stun_host_valid "$HOST" || { error "STUN 主机格式无效"; return 1; }
    read -rp "  UDP 端口（逗号分隔，默认 443,3478）: " PORT_INPUT
    PORT_INPUT=${PORT_INPUT:-443,3478}
    PORTS=$(stun_ports_normalize "$PORT_INPUT") || {
        error "端口格式无效，仅支持 1-65535，最多 12 个"
        return 1
    }
    echo ""
    stun_probe_execute custom "$HOST" "$PORTS"
}

stun_nat_menu() {
    while true; do
        print_header "STUN / NAT 检测"
        menu_item "1" "快速检测"
        menu_item "2" "自定义 STUN 多端口" "$CYAN"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        local CH
        menu_read CH '选择操作 [0-2]: ' || return 0
        case "$CH" in
            1) stun_nat_quick; ui_pause ;;
            2) stun_nat_custom; ui_pause ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
