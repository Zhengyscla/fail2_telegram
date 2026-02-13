#!/usr/bin/env bash

### ========= 基础配置 =========
TELEGRAM_TOKEN="你的BOT_TOKEN"
CHAT_ID="你的CHAT_ID"
HOSTNAME=$(hostname)
LOGFILE="/var/log/fail2ban.log"

RESTORE_WAIT=10
BAN_WINDOW=30
BAN_THRESHOLD=5

CACHE_FILE="/tmp/f2b_country_cache.db"
RESTORE_FILE="/tmp/f2b_restore.tmp"
BAN_FILE="/tmp/f2b_ban.tmp"

mkdir -p /tmp

### ========= 发送消息 =========
send_msg() {
    local message="$1"
    curl -s --max-time 5 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="Markdown" > /dev/null
}

### ========= 国家缓存查询 =========
get_country() {
    local ip="$1"

    if grep -q "^${ip} " "$CACHE_FILE" 2>/dev/null; then
        grep "^${ip} " "$CACHE_FILE" | awk '{print $2}'
        return
    fi

    COUNTRY=$(curl -s --max-time 3 "https://api.country.is/${ip}" \
        | grep -oP '"country":"\K[^"]+')

    [ -z "$COUNTRY" ] && COUNTRY="??"

    echo "${ip} ${COUNTRY}" >> "$CACHE_FILE"
    echo "$COUNTRY"
}

### ========= Restore 聚合 =========
flush_restore() {
    COUNT=$(wc -l < "$RESTORE_FILE" 2>/dev/null)
    if [ "$COUNT" -gt 0 ]; then
        send_msg "🔄 *Fail2Ban Restart Detected*
Restored ${COUNT} bans on ${HOSTNAME}"
    fi
    rm -f "$RESTORE_FILE"
}

### ========= Ban 聚合 =========
flush_ban_summary() {
    COUNT=$(wc -l < "$BAN_FILE" 2>/dev/null)

    if [ "$COUNT" -ge "$BAN_THRESHOLD" ]; then
        send_msg "⚠ *High Attack Activity*
${COUNT} bans in last ${BAN_WINDOW}s on ${HOSTNAME}"
        rm -f "$BAN_FILE"
    fi
}

start_ban_timer() {
    (
        sleep "$BAN_WINDOW"
        flush_ban_summary
    ) &
}

### ========= 主监听 =========
tail -F "$LOGFILE" | while read -r line; do

    case "$line" in

        *"Starting Fail2ban"*)
            send_msg "🟢 *Fail2Ban Started* on ${HOSTNAME}"
            ;;

        *"Exiting Fail2ban"*)
            send_msg "🔴 *Fail2Ban Stopped* on ${HOSTNAME}"
            ;;

        *"NOTICE"*Restore\ Ban*)
            IP=$(echo "$line" | awk '{print $NF}')
            echo "$IP" >> "$RESTORE_FILE"

            if [ ! -f /tmp/f2b_restore_timer.flag ]; then
                touch /tmp/f2b_restore_timer.flag
                (
                    sleep "$RESTORE_WAIT"
                    flush_restore
                    rm -f /tmp/f2b_restore_timer.flag
                ) &
            fi
            ;;

        *"NOTICE"*Unban*)
            IP=$(echo "$line" | awk '{print $NF}')
            COUNTRY=$(get_country "$IP")

            send_msg "✅ *Unban*
IP: \`${IP}\`
Country: ${COUNTRY}
Host: ${HOSTNAME}"
            ;;

        *"NOTICE"*Ban*)
            # 排除 Restore
            if echo "$line" | grep -q "Restore"; then
                continue
            fi

            IP=$(echo "$line" | awk '{print $NF}')
            COUNTRY=$(get_country "$IP")

            echo "$IP" >> "$BAN_FILE"

            COUNT=$(wc -l < "$BAN_FILE")

            if [ "$COUNT" -eq 1 ]; then
                start_ban_timer
            fi

            # 低频攻击 → 单条发送
            if [ "$COUNT" -lt "$BAN_THRESHOLD" ]; then
                send_msg "🚫 *Ban*
IP: \`${IP}\`
Country: ${COUNTRY}
Host: ${HOSTNAME}"
            fi
            ;;

    esac

done
