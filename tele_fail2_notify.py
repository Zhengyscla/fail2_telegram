import re
import time
import requests
import socket

# 获取主机名（启动时只取一次）
HOSTNAME = socket.gethostname()

# 用于收集 restore ban 的 IP 列表（在重启检测期间使用）
restore_ips = []
restore_jail = None          # 假设重启时所有 restore 都在同一个 jail（通常是）
is_restarting = False        # 标记是否处于“重启窗口”

# Configuration - Replace with your actual Telegram Bot Token and Chat ID
TELEGRAM_BOT_TOKEN = ''  # e.g., '123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11'
TELEGRAM_CHAT_ID = ''     # e.g., '123456789' or '@channelname'

# Telegram API endpoint for sending messages
TELEGRAM_API_URL = f'https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage'

# Log file path
LOG_FILE = '/var/log/fail2ban.log'

# Patterns to match - 更鲁棒的版本，只依赖 [jail] Ban/Unban/Restore Ban IP
BAN_PATTERN = re.compile(r'\[([^\]]+)\]\s*Ban\s*(\S+)')
UNBAN_PATTERN = re.compile(r'\[([^\]]+)\]\s*Unban\s*(\S+)')
RESTORE_BAN_PATTERN = re.compile(r'\[([^\]]+)\]\s*Restore Ban\s*(\S+)')
RESTART_PATTERNS = [
    re.compile(r'Exiting Fail2ban'),
    re.compile(r'Starting Fail2ban'),
    re.compile(r'Daemon started'),
    re.compile(r'Observer start...'),
    # Add more if needed based on logs
]

def get_country_code(ip):
    """查询 IP 归属国家代码，失败返回 '--' """
    try:
        url = f"https://api.country.is/{ip}"
        r = requests.get(url, timeout=5)
        if r.status_code == 200:
            data = r.json()
            return data.get('country', '--')
        return '--'
    except Exception:
        return '--'

def send_telegram_message(message):
    """Send a message to Telegram bot."""
    payload = {
        'chat_id': TELEGRAM_CHAT_ID,
        'text': message,
        'parse_mode': 'Markdown'  # Optional: for better formatting
    }
    try:
        response = requests.post(TELEGRAM_API_URL, json=payload)
        response.raise_for_status()
        print(f"Message sent: {message}")
    except requests.RequestException as e:
        print(f"Failed to send message: {e}")

def tail_log(file_path):
    """Generator to tail the log file like 'tail -f'."""
    with open(file_path, 'r') as f:
        # Seek to the end of the file
        f.seek(0, 2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.1)  # Sleep briefly to avoid high CPU usage
                continue
            yield line.strip()

def monitor_log():
    global is_restarting, restore_ips, restore_jail

    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Starting monitoring of {LOG_FILE} on {HOSTNAME}")
    print("监控已启动。Ban/Unban 实时推送，重启时的 Restore Ban 会聚合\n")

    restart_line_count = 0  # 用于强制结束收集窗口，防止永久卡住

    for line in tail_log(LOG_FILE):
        line_lower = line.lower()
        ts = ' '.join(line.split()[:2])

        # ─── 优先处理 Ban 和 Unban（最高优先级） ───
        ban_match = BAN_PATTERN.search(line)
        # Ban
        if ban_match:
            jail, ip = ban_match.groups()
            country = get_country_code(ip)
            message = (
                f"🚫 *Ban Notification* - {HOSTNAME}\n"
                f"Jail: {jail}\n"
                f"IP: `{ip}` ({country})\n"   # ← 这里加反引号
                f"时间: {ts}"
            )
            print("MATCH BAN → Sending:", message)
            send_telegram_message(message)
            continue

        # Unban
        unban_match = UNBAN_PATTERN.search(line)
        
        if unban_match:
            jail, ip = unban_match.groups()
            country = get_country_code(ip)
            message = (
                f"✅ *Unban Notification* - {HOSTNAME}\n"
                f"Jail: {jail}\n"
                f"IP: `{ip}` ({country})\n"   # ← 这里加反引号
                f"时间: {ts}"
            )
            print("MATCH UNBAN → Sending:", message)
            send_telegram_message(message)
            continue

        # ─── 重启开始 ───
        if any(kw in line_lower for kw in ['exiting fail2ban', 'shutdown in progress']):
            is_restarting = True
            restore_ips.clear()
            restore_jail = None
            globals()['in_restore_phase'] = False
            message = f"🔧 *{HOSTNAME}* - Fail2ban 服务正在停止/重启\n时间: {ts}\n日志: {line.strip()}"
            print("SERVICE STOP/RESTART DETECTED → Sending:", message)
            send_telegram_message(message)
            continue

        # ─── 如果在重启窗口内，收集 Restore Ban ───
        if is_restarting:
            restore_match = RESTORE_BAN_PATTERN.search(line)
            if restore_match:
                jail, ip = restore_match.groups()
                if restore_jail is None:
                    restore_jail = jail
                if ip not in restore_ips:
                    restore_ips.append(ip)
                print(f"[收集 Restore] {ip} (当前 {len(restore_ips)} 个)")
                globals()['in_restore_phase'] = True
                continue   # 继续收集，不要让 Restore 行被其他分支处理

            # 非 Restore 行 + 之前已经看到过 Restore → 认为恢复阶段结束
            if globals().get('in_restore_phase', False):
                is_restarting = False
                del globals()['in_restore_phase']

                message_complete = f"🔄 *{HOSTNAME}* - Fail2ban 服务重启完成（Restore 阶段结束）\n时间: {ts}\n日志: {line.strip()}"
                print("SERVICE RESTART COMPLETE → Sending:", message_complete)
                send_telegram_message(message_complete)

                if restore_ips:
                    summary = f"🔄 *{HOSTNAME}* - 重启后从数据库恢复的封禁 IP（共 **{len(restore_ips)}** 个）\n"
                    summary += f"Jail: {restore_jail or '未知'}\n"
                    summary += "\n".join(f"• `{ip}`" for ip in sorted(restore_ips))
                    print("SENDING RESTORE SUMMARY →", summary)
                    send_telegram_message(summary)
                    restore_ips.clear()
                    restore_jail = None
                else:
                    print("本次重启未收集到任何 Restore Ban")

                # 重要：不加 continue，让这行非 Restore 日志继续往下匹配 Ban/Unban 等
                # （如果它是 Ban/Unban 就会被上面的优先分支捕获）

        # 非重启窗口的 Restore Ban（单条发送）
        restore_match = RESTORE_BAN_PATTERN.search(line)
        if restore_match:
            jail, ip = restore_match.groups()
            message = f"🔄 *Restore Ban* - {HOSTNAME}\nJail: {jail}\nIP: {ip}\n时间: {ts}"
            print("MATCH RESTORE (normal) → Sending:", message)
            send_telegram_message(message)
            continue

        # 可选：其他事件通知（已注释，避免轰炸）
        # if 'fail2ban' in line_lower and ('info' in line_lower or 'notice' in line_lower):
        #     event_part = line.split(']: ', 1)[1].strip() if ']: ' in line else line.strip()
        #     message = f"🔧 *{HOSTNAME}* - Fail2ban 服务事件\n事件: {event_part}\n时间: {ts}"
        #     print("OTHER EVENT → Sending:", message)
        #     send_telegram_message(message)

if __name__ == '__main__':
    monitor_log()
