# Fail2ban notify

Fail2ban notify 基于 [fail2ban](https://github.com/fail2ban/fail2ban) 项目的 telegram bot 通知功能

特点：运行一个独立服务，监控 fail2ban 日志判断封禁情况，不需要修改 'jail.local' ，与 fail2ban 服务完全隔离，即使通知程序出现问题，也不会影响 fail2ban 封IP操作

支持通知 `服务启动` `服务停止` `IP封禁` `IP解封` 以及 `重启后恢复封禁IP的数量`

查询 api 获取 IP 归属地

## 快速安装

```bash
cd /etc/systemd/system/
wget https://raw.githubusercontent.com/Zhengyscla/fail2_telegram/refs/heads/master/fail2ban-notify.service
cd /usr/local/bin/
wget https://raw.githubusercontent.com/Zhengyscla/fail2_telegram/refs/heads/master/fail2ban-telegram-notify.sh
```

## 写入配置

在你的 telegram 里打开 [BotFather](https://telegram.me/botfather) ， 输入命令 `/newbot` 来创建机器人

> 第一次输入的名字是 机器人的名字 ，随意命名，能记住就行
> 第二次是 telegram 认的名字 ， 后面要带 `bot`
> 创建好后，需要给你的机器人发送一条（任意）消息

然后复制你的 API TOKEN

然后打开 [GetUserID](https://t.me/userinfobot) ，直接开始就可以看到你的 Chat ID ，手动复制`ID`后面的数字

打开 `fail2ban-telegram-notify.sh` 修改以下变量

```
TELEGRAM_TOKEN="你的Telegram Bot Token"
CHAT_ID="你的Telegram Chat ID"
```

退出并保存

## 启用服务

```
systemctl start fail2ban-notify.service
systemctl enable fail2ban-notify.service
systemctl staatus fail2ban-notify.service  # 验证服务正常运行
```

效果图：

<img width="322" height="93" alt="image" src="https://github.com/user-attachments/assets/04e1a1bf-7ce9-499c-8812-0c6b75f2687a" />



# 项目佛系维护，不接受 issus 以及 bug 反馈。项目若有问题，自行解决
