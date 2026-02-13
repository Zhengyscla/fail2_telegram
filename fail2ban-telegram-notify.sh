#!/usr/bin/env bash

### ========= 配置 =========
TELEGRAM_TOKEN="你的Telegram Bot Token"
CHAT_ID="你的Telegram Chat ID"
HOSTNAME=$(hostname)
LOGFILE="/var/log/fail2ban.log"

# Restore 聚合时间（秒）
RESTORE_WAIT=10

# 临时缓存
RESTORE_FILE="/tmp/f2b_restore_cache.txt"
RESTORE_TIMER="/tmp/f2b_restore_timer.flag"

### ========= 发送函数 =========
send_msg() {
    local message="$1"
    curl -s --max-time 5 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="Markdown" > /dev/null
}

### ========= IP国家查询 =========
get_country() {
    local ip="$1"
    curl -s --max-time 3 "https://api.country.is/${ip}" \
    | grep -oP '"country":"\K[^"]+' || echo "??"
}

### ========= Restore 批量发送 =========
flush_restore() {
    if [ -f "${RESTORE_FILE}" ]; then
        COUNT=$(wc -l < "${RESTORE_FILE}")
        if [ "$COUNT" -gt 0 ]; then
            MSG="🔄 *Fail2Ban Restore Summary* on ${HOSTNAME}
Restored ${COUNT} IP bans after service restart."
            send_msg "${MSG}"
        fi
        rm -f "${RESTORE_FILE}" "${RESTORE_TIMER}"
    fi
}

### ========= 实时监控 =========
tail -F "${LOGFILE}" | while read -r line; do

    # 1️⃣ Ban
    if echo "$line" | grep -q "NOTICE.* Ban "; then
        IP=$(echo "$line" | awk '{print $NF}')
        TIME=$(echo "$line" | awk '{print $1 " " $2}')
        COUNTRY=$(get_country "$IP")

        MSG="🚫 *Ban* on ${HOSTNAME}
Time: ${TIME}
IP: \`${IP}\`
Country: ${COUNTRY}"

        send_msg "$MSG"
    fi

    # 2️⃣ Unban
    if echo "$line" | grep -q "NOTICE.*Unban "; then
        IP=$(echo "$line" | awk '{print $NF}')
        TIME=$(echo "$line" | awk '{print $1 " " $2}')
        COUNTRY=$(get_country "$IP")

        MSG="✅ *Unban* on ${HOSTNAME}
Time: ${TIME}
IP: \`${IP}\`
Country: ${COUNTRY}"

        send_msg "$MSG"
    fi

    # 3️⃣ Restore Ban
    if echo "$line" | grep -q "Restore Ban"; then
        IP=$(echo "$line" | awk '{print $NF}')
        echo "$IP" >> "${RESTORE_FILE}"

        # 启动延迟计时器（只启动一次）
        if [ ! -f "${RESTORE_TIMER}" ]; then
            touch "${RESTORE_TIMER}"
            (
                sleep "${RESTORE_WAIT}"
                flush_restore
            ) &
        fi
    fi

    # 4️⃣ 服务启动
    if echo "$line" | grep -q "Starting Fail2ban"; then
        send_msg "🟢 *Fail2Ban Started* on ${HOSTNAME}"
    fi

    # 5️⃣ 服务停止
    if echo "$line" | grep -q "Exiting Fail2ban"; then
        send_msg "🔴 *Fail2Ban Stopped* on ${HOSTNAME}"
    fi

done
