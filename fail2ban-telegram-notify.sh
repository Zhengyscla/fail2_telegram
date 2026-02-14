#!/usr/bin/env bash

### ========= 基础配置 =========
TELEGRAM_TOKEN="你的BOT_TOKEN"
CHAT_ID="你的CHAT_ID"           # 如 -100xxxxxxxxxx
HOSTNAME=$(hostname)
LOGFILE="/var/log/fail2ban.log"

# 聚合参数
RESTORE_WAIT=8      # 恢复封禁聚合等待秒数
BAN_WINDOW=25       # 高频封禁判断窗口（秒）
BAN_THRESHOLD=4     # 窗口内达到多少条才发“高频攻击”而非单条
UNBAN_WINDOW=6      # 停止服务时的解封聚合等待（秒）

BAN_ACTIVE=0
STOPPING=0

CACHE_FILE="/tmp/f2b_country_cache.db"
RESTORE_FILE="/tmp/f2b_restore.tmp"
BAN_FILE="/tmp/f2b_ban.tmp"
UNBAN_FILE="/tmp/f2b_unban.tmp"

mkdir -p /tmp

### ========= 发送 Telegram 消息 =========
send_msg() {
    local message="$1"
    curl -s --max-time 6 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="Markdown" >/dev/null 2>&1
}

### ========= 获取国家（带缓存） =========
get_country() {
    local ip="$1"
    local cached

    cached=$(grep -m1 "^${ip} " "$CACHE_FILE" 2>/dev/null | awk '{print $2}')
    if [ -n "$cached" ]; then
        echo "$cached"
        return
    fi

    local country
    country=$(curl -s --connect-timeout 2 --max-time 4 "https://api.country.is/${ip}" \
        | grep -oP '(?<="country":")[^"]+' 2>/dev/null)

    [ -z "$country" ] && country="??"

    echo "${ip} ${country}" >> "$CACHE_FILE"
    echo "$country"
}

### ========= 聚合：服务重启后恢复的 ban =========
flush_restore() {
    local count=$(wc -l < "$RESTORE_FILE" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
        send_msg "🔄 *Fail2Ban 重启后恢复封禁*
已恢复 **${count}** 个 IP  
主机：${HOSTNAME}"
    fi
    rm -f "$RESTORE_FILE"
}

### ========= 聚合：短时间内大量 ban（攻击预警） =========
flush_ban_window() {
    local count=$(wc -l < "$BAN_FILE" 2>/dev/null || echo 0)
    if [ "$count" -ge "$BAN_THRESHOLD" ]; then
        send_msg "⚠️ *高频封禁警报*
过去 ${BAN_WINDOW} 秒内封禁 **${count}** 个 IP  
主机：${HOSTNAME}"
    fi
    rm -f "$BAN_FILE"
    BAN_ACTIVE=0
}

start_ban_window() {
    BAN_ACTIVE=1
    (sleep "$BAN_WINDOW"; flush_ban_window) &
}

### ========= 聚合：服务停止时的批量 unban =========
flush_unban_shutdown() {
    local count=$(wc -l < "$UNBAN_FILE" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
        send_msg "🧹 *Fail2Ban 停止服务*
自动解封 **${count}** 个 IP  
主机：${HOSTNAME}"
    fi
    rm -f "$UNBAN_FILE"
}

tail -F --retry "$LOGFILE" | while read -r line; do

    # 优先处理启动/停止（最可靠的锚点）
    if echo "$line" | grep -q "Starting Fail2ban"; then
        STOPPING=0
        send_msg "🟢 *Fail2Ban 已启动*  
主机：${HOSTNAME}"
        continue
    fi

    if echo "$line" | grep -q "Exiting Fail2ban"; then
        STOPPING=1
        send_msg "🔴 *Fail2Ban 正在停止*  
主机：${HOSTNAME}"
        # 给 unban 留出时间窗口
        (sleep "$UNBAN_WINDOW"; flush_unban_shutdown; STOPPING=0) &
        continue
    fi

    # ──────────────────────────────────────────────
    # 下面三种 NOTICE 动作
    # ──────────────────────────────────────────────

    if echo "$line" | grep -q "NOTICE.*Restore Ban"; then
        ip=$(echo "$line" | awk '{print $NF}')
        echo "$ip" >> "$RESTORE_FILE"

        [ ! -f /tmp/f2b_restore.flag ] && {
            touch /tmp/f2b_restore.flag
            (sleep "$RESTORE_WAIT"; flush_restore; rm -f /tmp/f2b_restore.flag) &
        }
        continue
    fi

    if echo "$line" | grep -q "NOTICE.*Ban " && ! echo "$line" | grep -q "Restore"; then
        ip=$(echo "$line" | awk '{print $NF}')
        country=$(get_country "$ip")

        echo "$ip" >> "$BAN_FILE"

        if [ "$BAN_ACTIVE" -eq 0 ]; then
            start_ban_window
        fi

        count=$(wc -l < "$BAN_FILE" 2>/dev/null || echo 0)

        if [ "$count" -lt "$BAN_THRESHOLD" ]; then
            send_msg "🚫 *IP 被封禁*
IP: \`${ip}\`
国家: ${country}
主机: ${HOSTNAME}"
        fi
        continue
    fi

    if echo "$line" | grep -q "NOTICE.*Unban"; then
        ip=$(echo "$line" | awk '{print $NF}')
        country=$(get_country "$ip")

        if [ "$STOPPING" -eq 1 ]; then
            # 停止服务时的 unban → 聚合
            echo "$ip" >> "$UNBAN_FILE"
        else
            # 正常超时解封 → 单条通知
            send_msg "✅ *IP 自动解封*
IP: \`${ip}\`
国家: ${country}
主机: ${HOSTNAME}"
        fi
        continue
    fi

done
