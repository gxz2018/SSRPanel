#!/bin/bash
# =========================================================
# 🚀 SSRPanel 后端 + Teddysun SSR 一键部署脚本（自动防掉线版）
# Ubuntu 20.04 / Debian 11 通用，高并发优化 + 无日志 + 自动恢复
# =========================================================

set -e
echo -e "\033[36m🔧 SSRPanel 后端 + Teddysun SSR 自动防掉线部署开始...\033[0m"

# --- 用户输入 ---
read -p "请输入前端 MySQL 地址（如 127.0.0.1）: " mysqla
read -p "请输入前端 MySQL 用户名: " mysqlu
read -p "请输入前端 MySQL 密码: " mysqlp
read -p "请输入前端 MySQL 数据库名: " mysqld
read -p "请输入节点 ID: " node

# --- 常量设置 ---
SSR_HOME="/home/shadowsocksr"
SSR_PANEL_PORT=10000
SSR_TEDDYSUN_PORT=30000
SSR_TEDDYSUN_PASS="teddysun.com"

# --- 检查 root ---
if [[ "$EUID" -ne 0 ]]; then
    echo "❌ 请以 root 用户执行"
    exit 1
fi

# --- 系统更新 + 依赖 ---
apt update -y
apt install -y git python3 python3-pip build-essential net-tools iptables curl libffi-dev libsodium-dev openssl supervisor wget unzip
pip3 install --upgrade pip
pip3 install cymysql pycryptodome requests pynacl

# ========================
# 部署 SSRPanel 后端
# ========================
echo -e "\033[33m⚙️ 部署 SSRPanel 后端...\033[0m"
cd /home
if [ ! -d "$SSR_HOME" ]; then
    git clone https://github.com/gxz2018/shadowsocksr-backup.git shadowsocksr
fi
cd $SSR_HOME
bash setup_cymysql.sh
bash initcfg.sh

# 配置数据库与节点
sed -i 's/sspanelv2/glzjinmod/g' userapiconfig.py
sed -i "s/127.0.0.1/$mysqla/g" usermysql.json
sed -i "s/\"user\": \"ss\"/\"user\": \"$mysqlu\"/g" usermysql.json
sed -i "s/\"password\": \"pass\"/\"password\": \"$mysqlp\"/g" usermysql.json
sed -i "s/\"db\": \"sspanel\"/\"db\": \"$mysqld\"/g" usermysql.json
sed -i "s/\"node_id\": 0/\"node_id\": $node/g" usermysql.json

# 高并发优化
ulimit -n 65535
cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
EOF

cat >> /etc/sysctl.conf <<EOF
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_forward = 1
EOF
sysctl -p

# systemd 服务
cat > /etc/systemd/system/ssrpanel.service <<EOF
[Unit]
Description=SSRPanel 后端服务（无日志自动重启）
After=network.target mysql.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/python3 /home/shadowsocksr/server.py
WorkingDirectory=/home/shadowsocksr
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=null
StandardError=null
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssrpanel.service
systemctl restart ssrpanel.service

# ========================
# 部署 Teddysun SSR
# ========================
echo -e "\033[33m⚙️ 部署 Teddysun SSR...\033[0m"
cd /root
wget --no-check-certificate -O shadowsocks-all.sh https://raw.githubusercontent.com/teddysun/shadowsocks_install/master/shadowsocks-all.sh
sed -i "s/DEFAULT_PORT=.*/DEFAULT_PORT=${SSR_TEDDYSUN_PORT}/" shadowsocks-all.sh
sed -i "s/DEFAULT_PASS=.*/DEFAULT_PASS=${SSR_TEDDYSUN_PASS}/" shadowsocks-all.sh
chmod +x shadowsocks-all.sh
./shadowsocks-all.sh 2>&1 | tee shadowsocks-all.log

# ========================
# 创建 SSR 自动防掉线守护进程
# ========================
echo -e "\033[33m🛡️ 启用 SSR 自动守护...\033[0m"
cat > /usr/local/bin/ssr_guard.sh <<'EOF'
#!/bin/bash
LOG="/var/log/ssr_guard.log"
SERVICE="/etc/init.d/shadowsocks"
while true; do
    if ! pgrep -f "ssserver" > /dev/null; then
        echo "$(date '+%F %T') ⚠️ SSR 掉线，正在重启..." >> $LOG
        $SERVICE restart >> $LOG 2>&1
        sleep 5
        if pgrep -f "ssserver" > /dev/null; then
            echo "$(date '+%F %T') ✅ SSR 已恢复运行。" >> $LOG
        else
            echo "$(date '+%F %T') ❌ SSR 重启失败，请检查配置。" >> $LOG
        fi
    fi
    sleep 60
done
EOF

chmod +x /usr/local/bin/ssr_guard.sh

cat > /etc/systemd/system/ssr-guard.service <<EOF
[Unit]
Description=SSR 守护进程 - 自动检测掉线并重启
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssr_guard.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssr-guard.service
systemctl start ssr-guard.service

# ========================
# 防火墙规则分离端口
# ========================
iptables -F
iptables -I INPUT -p tcp --dport ${SSR_PANEL_PORT}:20000 -j ACCEPT
iptables -I INPUT -p udp --dport ${SSR_PANEL_PORT}:20000 -j ACCEPT
iptables -I INPUT -p tcp --dport ${SSR_TEDDYSUN_PORT} -j ACCEPT
iptables -I INPUT -p udp --dport ${SSR_TEDDYSUN_PORT} -j ACCEPT
iptables-save > /etc/iptables.rules

cat > /etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-pre-up.d/iptables

echo -e "\033[32m✅ 部署完成！SSRPanel 后端 + Teddysun SSR 已安装并带防掉线守护。\033[0m"
echo "SSRPanel 服务: systemctl status ssrpanel"
echo "Teddysun SSR 服务: /etc/init.d/shadowsocks"
echo "SSR 自动守护: systemctl status ssr-guard"
echo "守护日志: tail -f /var/log/ssr_guard.log"
