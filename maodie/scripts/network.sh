#!/system/bin/sh
# Maodie network controller
#
# This is the single owner of the module's firewall and TUN health checks.
# Keep it compatible with Android /system/bin/sh (mksh) and avoid sourcing
# values from the user-editable YAML configuration.

umask 077

MOD_DIR="${MAODIE_MOD_DIR:-/data/adb/modules/Maodie-Launcher}"
CONFIG_FILE="$MOD_DIR/maodie/config/config.yaml"
RUN_DIR="$MOD_DIR/maodie/run"
WAIT_CACHE="$RUN_DIR/network.wait.cache"
LOCK_DIR="$RUN_DIR/network.lock"
CHAIN_NAME="MAODIE_FWD"

TUN_ENABLE="false"
TUN_DEVICE="Meta"
TUN_AUTO_ROUTE="false"
IPV6_ENABLE="false"
WAIT_READY=""
IPT4_WAIT_MODE="none"
IPT6_WAIT_MODE="none"

ensure_run_dir() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 1
    chmod 700 "$RUN_DIR" 2>/dev/null
}

strip_scalar() {
    printf '%s' "$1" | sed \
        -e 's/\r$//' \
        -e 's/[[:space:]]*#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' \
        -e 's/^"//' -e 's/"$//' \
        -e "s/^'//" -e "s/'$//"
}

normalize_bool() {
    value=$(strip_scalar "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        true|yes|on|1) printf 'true\n' ;;
        false|no|off|0|null|'~'|'') printf 'false\n' ;;
        *) return 1 ;;
    esac
}

load_config() {
    [ -r "$CONFIG_FILE" ] || return 1

    parsed=$(awk '
        BEGIN {
            in_tun = 0
            tun_indent = -1
            tun_seen = 0
            tun_enable = ""
            tun_device = ""
            tun_auto_route = ""
            ipv6 = ""
            tun_parse = "ok"
        }
        {
            line = $0
            sub(/\r$/, "", line)

            if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) {
                next
            }

            if (line !~ /^[[:space:]]/) {
                in_tun = 0
                if (line ~ /^tun[[:space:]]*:/) {
                    tun_seen = 1
                    # Avoid an optional ERE group here. Android vendor awk
                    # implementations differ in how they handle `( ... )?`,
                    # which can reject a plain `tun:` block header.
                    tun_value = line
                    sub(/^tun[[:space:]]*:[[:space:]]*/, "", tun_value)
                    if (tun_value == "" || tun_value ~ /^#/) {
                        in_tun = 1
                        tun_indent = -1
                    } else {
                        tun_parse = "unsupported"
                    }
                    next
                }
                if (line ~ /^ipv6[[:space:]]*:[[:space:]]*/) {
                    value = line
                    sub(/^ipv6[[:space:]]*:[[:space:]]*/, "", value)
                    ipv6 = value
                }
                next
            }

            if (in_tun) {
                indent_text = line
                sub(/[^[:space:]].*$/, "", indent_text)
                indent = length(indent_text)
                if (tun_indent < 0) {
                    tun_indent = indent
                }
                # Only direct children belong to the tun mapping. A nested
                # `enable` key must not override tun.enable.
                if (indent != tun_indent) {
                    next
                }
                value = line
                if (line ~ /^[[:space:]]+<<[[:space:]]*:/) {
                    tun_parse = "unsupported"
                } else if (line ~ /^[[:space:]]+enable[[:space:]]*:[[:space:]]*/) {
                    sub(/^[[:space:]]+enable[[:space:]]*:[[:space:]]*/, "", value)
                    tun_enable = value
                } else if (line ~ /^[[:space:]]+device[[:space:]]*:[[:space:]]*/) {
                    sub(/^[[:space:]]+device[[:space:]]*:[[:space:]]*/, "", value)
                    tun_device = value
                } else if (line ~ /^[[:space:]]+auto-route[[:space:]]*:[[:space:]]*/) {
                    sub(/^[[:space:]]+auto-route[[:space:]]*:[[:space:]]*/, "", value)
                    tun_auto_route = value
                }
            }
        }
        END {
            if (!tun_seen) {
                tun_enable = "false"
            }
            printf "%s|%s|%s|%s|%s\n", tun_enable, tun_device, tun_auto_route, ipv6, tun_parse
        }
    ' "$CONFIG_FILE") || return 1

    # Do not split this with ${value%%|*}: Android's mksh treats `|` as an
    # extended-pattern operator in parameter expansion, unlike dash/bash.
    # `read` with a non-whitespace IFS also preserves an empty device field.
    saved_ifs=$IFS
    IFS='|'
    read -r raw_tun_enable raw_tun_device raw_auto_route raw_ipv6 tun_parse_status <<EOF
$parsed
EOF
    IFS=$saved_ifs

    if [ "$tun_parse_status" != "ok" ]; then
        printf 'Error: unsupported top-level tun YAML; use a block-style tun mapping.\n' >&2
        return 1
    fi

    if ! TUN_ENABLE=$(normalize_bool "$raw_tun_enable"); then
        printf 'Error: invalid tun.enable boolean: %s\n' "$(strip_scalar "$raw_tun_enable")" >&2
        return 1
    fi
    if ! TUN_AUTO_ROUTE=$(normalize_bool "$raw_auto_route"); then
        printf 'Error: invalid tun.auto-route boolean: %s\n' "$(strip_scalar "$raw_auto_route")" >&2
        return 1
    fi
    if ! IPV6_ENABLE=$(normalize_bool "$raw_ipv6"); then
        printf 'Error: invalid top-level ipv6 boolean: %s\n' "$(strip_scalar "$raw_ipv6")" >&2
        return 1
    fi
    TUN_DEVICE=$(strip_scalar "$raw_tun_device")
    # Mihomo's default TUN name is "Meta" when device is omitted. Linux
    # interface names are case-sensitive, so keep the upstream capitalization.
    [ -n "$TUN_DEVICE" ] || TUN_DEVICE="Meta"

    # Linux interface names are at most 15 bytes. Reject option-looking or
    # otherwise unsafe values before passing the name to ip/iptables.
    if ! printf '%s\n' "$TUN_DEVICE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$'; then
        printf 'Error: invalid TUN device in config: %s\n' "$TUN_DEVICE" >&2
        return 1
    fi
}

current_boot_id() {
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        cat /proc/sys/kernel/random/boot_id 2>/dev/null
        return
    fi
    stat -c '%Y' /proc/1 2>/dev/null
}

probe_wait_mode() {
    command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'missing\n'
        return
    fi

    if "$command_name" -w 2 -L >/dev/null 2>&1; then
        printf 'interval\n'
    elif "$command_name" -w -L >/dev/null 2>&1; then
        printf 'wait\n'
    else
        printf 'none\n'
    fi
}

cache_value() {
    key="$1"
    sed -n "s/^${key}=//p" "$WAIT_CACHE" 2>/dev/null | head -n 1
}

init_wait_modes() {
    [ -n "$WAIT_READY" ] && return 0
    ensure_run_dir || return 1
    WAIT_READY=1

    boot_id=$(current_boot_id)
    cached_boot=$(cache_value boot_id)
    if [ -n "$boot_id" ] && [ "$cached_boot" = "$boot_id" ]; then
        cached_v4=$(cache_value iptables)
        cached_v6=$(cache_value ip6tables)
        case "$cached_v4" in interval|wait|none|missing) IPT4_WAIT_MODE="$cached_v4" ;; *) cached_v4="" ;; esac
        case "$cached_v6" in interval|wait|none|missing) IPT6_WAIT_MODE="$cached_v6" ;; *) cached_v6="" ;; esac
        [ -n "$cached_v4" ] && [ -n "$cached_v6" ] && return 0
    fi

    IPT4_WAIT_MODE=$(probe_wait_mode iptables)
    IPT6_WAIT_MODE=$(probe_wait_mode ip6tables)

    cache_tmp="$WAIT_CACHE.tmp.$$"
    {
        printf 'boot_id=%s\n' "$boot_id"
        printf 'iptables=%s\n' "$IPT4_WAIT_MODE"
        printf 'ip6tables=%s\n' "$IPT6_WAIT_MODE"
    } > "$cache_tmp" 2>/dev/null && {
        chmod 600 "$cache_tmp" 2>/dev/null
        mv -f "$cache_tmp" "$WAIT_CACHE" 2>/dev/null
    }
    rm -f "$cache_tmp" 2>/dev/null
}

ipt4() {
    case "$IPT4_WAIT_MODE" in
        interval) iptables -w 2 "$@" ;;
        wait) iptables -w "$@" ;;
        missing) return 127 ;;
        *) iptables "$@" ;;
    esac
}

ipt6() {
    case "$IPT6_WAIT_MODE" in
        interval) ip6tables -w 2 "$@" ;;
        wait) ip6tables -w "$@" ;;
        missing) return 127 ;;
        *) ip6tables "$@" ;;
    esac
}

run_family() {
    family="$1"
    shift
    if [ "$family" = "6" ]; then
        ipt6 "$@"
    else
        ipt4 "$@"
    fi
}

family_available() {
    family="$1"
    if [ "$family" = "6" ]; then
        [ "$IPT6_WAIT_MODE" != "missing" ]
    else
        [ "$IPT4_WAIT_MODE" != "missing" ]
    fi
}

clear_family() {
    family="$1"
    family_available "$family" || return 0
    rules_snapshot=""

    while run_family "$family" -C FORWARD -j "$CHAIN_NAME" >/dev/null 2>&1; do
        run_family "$family" -D FORWARD -j "$CHAIN_NAME" >/dev/null 2>&1 || break
    done
    run_family "$family" -F "$CHAIN_NAME" >/dev/null 2>&1
    run_family "$family" -X "$CHAIN_NAME" >/dev/null 2>&1

    # A failed `-C`/`-L` can mean either "absent" or a backend/permission
    # error. Only a successful full ruleset snapshot can prove cleanup.
    rules_snapshot=$(run_family "$family" -S 2>/dev/null) || return 1
    if printf '%s\n' "$rules_snapshot" \
        | grep -Eq "(^-N ${CHAIN_NAME}([[:space:]]|$)|-j ${CHAIN_NAME}([[:space:]]|$))"; then
        return 1
    fi
    return 0
}

apply_family() {
    family="$1"
    family_available "$family" || return 1

    run_family "$family" -N "$CHAIN_NAME" >/dev/null 2>&1 || true
    run_family "$family" -F "$CHAIN_NAME" >/dev/null 2>&1 || return 1
    run_family "$family" -A "$CHAIN_NAME" -i "$TUN_DEVICE" -j ACCEPT >/dev/null 2>&1 || return 1
    run_family "$family" -A "$CHAIN_NAME" -o "$TUN_DEVICE" -j ACCEPT >/dev/null 2>&1 || return 1

    # Keep exactly one jump owned by this controller. Older versions could
    # leave duplicates behind when reapplying after a partial restart; each
    # duplicate costs a rule traversal and makes cleanup ambiguous.
    while run_family "$family" -C FORWARD -j "$CHAIN_NAME" >/dev/null 2>&1; do
        run_family "$family" -D FORWARD -j "$CHAIN_NAME" >/dev/null 2>&1 || return 1
    done
    run_family "$family" -I FORWARD 1 -j "$CHAIN_NAME" >/dev/null 2>&1 || return 1
}

tun_device_exists() {
    [ -d "/sys/class/net/$TUN_DEVICE" ] && return 0
    command -v ip >/dev/null 2>&1 && ip link show "$TUN_DEVICE" >/dev/null 2>&1 && return 0
    command -v ifconfig >/dev/null 2>&1 && ifconfig "$TUN_DEVICE" >/dev/null 2>&1
}

tun_has_ipv6_address() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 addr show dev "$TUN_DEVICE" 2>/dev/null | grep -q 'inet6[[:space:]]'
}

wait_tun_device() {
    timeout_seconds="${MAODIE_TUN_WAIT_SECONDS:-12}"
    elapsed=0
    case "$timeout_seconds" in *[!0-9]*|'') timeout_seconds=12 ;; esac

    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        tun_device_exists && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    tun_device_exists
}

apply_all() {
    load_config || {
        printf 'Error: unable to read network settings from %s.\n' "$CONFIG_FILE" >&2
        return 1
    }
    init_wait_modes || return 1

    if [ "$TUN_ENABLE" != "true" ]; then
        disabled_clear_failed=0
        clear_family 4 >/dev/null 2>&1 || disabled_clear_failed=1
        clear_family 6 >/dev/null 2>&1 || disabled_clear_failed=1
        [ "$disabled_clear_failed" -eq 0 ] || return 1
        printf 'TUN is disabled; module firewall rules were cleared.\n'
        return 0
    fi

    if ! wait_tun_device; then
        printf 'Warning: TUN device %s was not ready before firewall apply.\n' "$TUN_DEVICE" >&2
    fi

    if ! apply_family 4; then
        printf 'Error: failed to apply IPv4 firewall rules.\n' >&2
        clear_family 4 >/dev/null 2>&1
        return 1
    fi

    if [ "$IPV6_ENABLE" = "true" ] && [ -f /proc/net/if_inet6 ]; then
        if ! family_available 6; then
            printf 'Error: IPv6 is enabled but ip6tables is unavailable.\n' >&2
            clear_family 4 >/dev/null 2>&1
            return 1
        fi
        if ! apply_family 6; then
            printf 'Error: failed to apply IPv6 firewall rules.\n' >&2
            clear_family 6 >/dev/null 2>&1
            clear_family 4 >/dev/null 2>&1
            return 1
        fi
    else
        if ! clear_family 6 >/dev/null 2>&1; then
            printf 'Error: failed to clear stale IPv6 firewall rules.\n' >&2
            clear_family 4 >/dev/null 2>&1
            return 1
        fi
    fi

    printf 'Firewall rules applied for TUN device %s (IPv6=%s).\n' "$TUN_DEVICE" "$IPV6_ENABLE"
}

clear_all() {
    init_wait_modes || return 1
    failed=0
    clear_family 4 || failed=1
    clear_family 6 || failed=1
    [ "$failed" -eq 0 ]
}

check_family() {
    family="$1"
    family_available "$family" || return 1
    run_family "$family" -L "$CHAIN_NAME" >/dev/null 2>&1 || return 1
    run_family "$family" -C "$CHAIN_NAME" -i "$TUN_DEVICE" -j ACCEPT >/dev/null 2>&1 || return 1
    run_family "$family" -C "$CHAIN_NAME" -o "$TUN_DEVICE" -j ACCEPT >/dev/null 2>&1 || return 1
    run_family "$family" -C FORWARD -j "$CHAIN_NAME" >/dev/null 2>&1 || return 1

    # Treat duplicate jumps as unhealthy too; this gives the watchdog a chance
    # to converge old/partially-applied state back to one deterministic jump.
    rules_snapshot=$(run_family "$family" -S 2>/dev/null) || return 1
    jump_count=$(printf '%s\n' "$rules_snapshot" | awk -v chain="$CHAIN_NAME" '
        $1 == "-A" && $2 == "FORWARD" {
            for (i = 3; i < NF; i++) {
                if ($i == "-j" && $(i + 1) == chain) {
                    count++
                }
            }
        }
        END { print count + 0 }
    ')
    [ "$jump_count" = "1" ]
}

family_absent() {
    family="$1"
    family_available "$family" || return 0

    # `-C`/`-L` return the same non-zero status for an absent chain and for a
    # backend/permission error. Require a successful snapshot before declaring
    # the module state clean, otherwise a disabled module can mask a broken
    # iptables backend and the watchdog will never retry cleanup.
    rules_snapshot=$(run_family "$family" -S 2>/dev/null) || return 1
    if printf '%s\n' "$rules_snapshot" \
        | grep -Eq "(^-N ${CHAIN_NAME}([[:space:]]|$)|-j ${CHAIN_NAME}([[:space:]]|$))"; then
        return 1
    fi
    return 0
}

check_all() {
    load_config || return 1
    init_wait_modes || return 1

    if [ "$TUN_ENABLE" != "true" ]; then
        family_absent 4 && family_absent 6
        return
    fi

    check_family 4 || return 1
    if [ "$IPV6_ENABLE" = "true" ] && [ -f /proc/net/if_inet6 ]; then
        check_family 6 || return 1
    else
        family_absent 6 || return 1
    fi
}

family_rules() {
    family="$1"
    if [ "$family" = "6" ]; then
        ip -6 rule show 2>/dev/null
    else
        ip -4 rule show 2>/dev/null || ip rule show 2>/dev/null
    fi
}

family_routes() {
    family="$1"
    table_name="$2"
    if [ "$family" = "6" ]; then
        ip -6 route show table "$table_name" 2>/dev/null
    else
        ip -4 route show table "$table_name" 2>/dev/null || ip route show table "$table_name" 2>/dev/null
    fi
}

route_output_has_default() {
    awk -v device="$TUN_DEVICE" '
        $1 == "default" {
            for (i = 1; i < NF; i++) {
                if ($i == "dev" && $(i + 1) == device) {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

family_route_healthy() {
    family="$1"
    rules=$(family_rules "$family") || return 1
    tables=$(printf '%s\n' "$rules" | awk '
        {
            for (i = 1; i < NF; i++) {
                if ($i == "lookup") {
                    print $(i + 1)
                }
            }
        }
    ' | sort -u)

    for table_name in $tables; do
        if ! printf '%s\n' "$table_name" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
            continue
        fi
        family_routes "$family" "$table_name" | route_output_has_default && return 0
    done

    # Some vendor ip tools omit the lookup token or render a table alias
    # differently. Only use table-all when no lookup table could be parsed;
    # otherwise a stale route without its matching rule must remain unhealthy.
    [ -z "$tables" ] || return 1
    if [ "$family" = "6" ]; then
        ip -6 route show table all 2>/dev/null | route_output_has_default
    else
        (ip -4 route show table all 2>/dev/null || ip route show table all 2>/dev/null) | route_output_has_default
    fi
}

route_check() {
    load_config || return 1
    [ "$TUN_ENABLE" = "true" ] || return 0
    [ "$TUN_AUTO_ROUTE" = "true" ] || return 0
    # With auto-route disabled, no kernel route is owned by Mihomo and the
    # absence of the TUN interface is not a health failure. Check the device
    # only when route health is actually expected.
    tun_device_exists || return 1
    command -v ip >/dev/null 2>&1 || return 1

    family_route_healthy 4 || return 1
    if [ "$IPV6_ENABLE" = "true" ] && [ -f /proc/net/if_inet6 ] && tun_has_ipv6_address; then
        family_route_healthy 6 || return 1
    fi
}

lock_owner_alive() {
    owner_pid="$1"
    [ -n "$owner_pid" ] || return 1
    kill -0 "$owner_pid" 2>/dev/null || return 1
    [ -r "/proc/$owner_pid/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$owner_pid/cmdline" 2>/dev/null \
        | grep -Fxq -- "$MOD_DIR/maodie/scripts/network.sh"
}

acquire_lock() {
    ensure_run_dir || return 1
    attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if lock_owner_alive "$owner_pid"; then
            attempts=$((attempts + 1))
            [ "$attempts" -ge 15 ] && return 1
            sleep 1
            continue
        fi

        # Do not steal a freshly-created lock during its mkdir -> pid window.
        if [ -z "$owner_pid" ] && [ "$attempts" -lt 2 ]; then
            attempts=$((attempts + 1))
            sleep 1
            continue
        fi
        rm -rf "$LOCK_DIR" 2>/dev/null
    done
    if ! printf '%s\n' $$ > "$LOCK_DIR/pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        return 1
    fi
}

release_lock() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null
}

show_config() {
    load_config || return 1
    printf 'tun_enable=%s\n' "$TUN_ENABLE"
    printf 'tun_device=%s\n' "$TUN_DEVICE"
    printf 'tun_auto_route=%s\n' "$TUN_AUTO_ROUTE"
    printf 'ipv6=%s\n' "$IPV6_ENABLE"
}

case "$1" in
    apply|clear)
        if ! acquire_lock; then
            printf 'Error: another network operation is still running.\n' >&2
            exit 1
        fi
        trap release_lock EXIT
        trap 'release_lock; exit 1' HUP INT TERM
        ;;
esac

case "$1" in
    apply) apply_all ;;
    clear) clear_all ;;
    check) check_all ;;
    route-check) route_check ;;
    config) show_config ;;
    *)
        printf 'Usage: %s {apply|clear|check|route-check|config}\n' "$0" >&2
        exit 1
        ;;
esac
