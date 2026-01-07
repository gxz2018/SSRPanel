#!/bin/bash
# =========================================================
# 🚀 Ubuntu 20.04 SSRPanel + Teddysun SSR 高并发 + 智能守护部署
# =========================================================

set -e
echo -e "\033[36m🔧 开始部署 SSRPanel + Teddysun SSR（高并发 + 智能守护版）...\033[0m"

# --- 用户输入 ---
read -p "请输入前端 MySQL 地址: " mysqla
read -p "请输入前端 MySQL 用户名: " mysqlu
read -p "请输入前端 MySQL 密码: " mysqlp
read -p "请输入前端 MySQL 数据库名: " mysqld
read -p "请输入节点 ID: " node

# --- 常量设置 ---
SSR_HOME="/home/shadowsocksr"
SSR_PANEL_PORT=44499
SSR_TEDDYSUN_PORT=443
SSR_TEDDYSUN_PASS="teddysun.com"

# --- 检查 root ---
if [[ "$EUID" -ne 0 ]]; then
    echo "❌ 请以 root 用户执行"
    exit 1
fi

# ========================
# 系统更新 + 依赖
# ========================
apt update -y
apt install -y git python3 python3-pip build-essential net-tools iptables curl libffi-dev libsodium-dev openssl supervisor wget unzip
pip3 install --upgrade pip
pip3 install cymysql pycryptodome requests pynacl

# ========================
# 核心系统优化
# ========================
echo -e "\033[33m⚙️ 内核优化 + 高并发优化...\033[0m"

# 检查并启用 BBR
echo -e "\033[36m🚀 检查 BBR 支持...\033[0m"
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

if [ "$KERNEL_MAJOR" -gt 4 ] || ([ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]); then
    echo "✅ 内核版本 $KERNEL_VERSION 支持 BBR"
    
    # 启用 BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    
    # 验证 BBR 是否启用
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "\033[32m✅ BBR 加速已启用\033[0m"
    else
        echo -e "\033[33m⚠️ BBR 启用失败，请检查内核配置\033[0m"
    fi
else
    echo -e "\033[33m⚠️ 内核版本 $KERNEL_VERSION 不支持 BBR（需要 4.9+）\033[0m"
    echo -e "\033[33m💡 建议升级内核以获得更好的网络性能\033[0m"
fi

# 强制启用 nf_conntrack 并设置最大连接数
if lsmod | grep -q '^nf_conntrack'; then sysctl -w net.netfilter.nf_conntrack_max=1048576 && echo "net.netfilter.nf_conntrack_max=1048576" >> /etc/sysctl.conf && sysctl -p; else echo "⚠️ nf_conntrack 模块不存在，跳过 nf_conntrack_max 设置"; fi

# 文件句柄限制
ulimit -n 1048576
cat >> /etc/security/limits.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
EOF

# TCP 内核参数
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

# systemd 高并发 + 自动重启
cat > /etc/systemd/system/ssrpanel.service <<EOF
[Unit]
Description=SSRPanel 后端服务（高并发 + 自动重启）
After=network.target mysql.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /home/shadowsocksr/server.py
WorkingDirectory=/home/shadowsocksr
Restart=always
RestartSec=5
LimitNOFILE=1048576
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
# 智能 SSR 守护脚本（优化版）
# ========================
echo -e "\033[33m🛡️ 部署智能守护（优化版）...\033[0m"
cat > /usr/local/bin/ssr_guard.sh <<'EOF'
#!/bin/bash
# =========================================================
# 🛡️ SSR 智能守护脚本（优化版）
# =========================================================

LOG="/var/log/ssr_guard.log"
SERVICE="/etc/init.d/shadowsocks"
LOCK_FILE="/var/run/ssr_guard.lock"
MAX_LOG_SIZE=10485760  # 10MB

# 配置参数
CHECK_INTERVAL=10       # 检查间隔（秒）
MAX_RESTART_COUNT=3     # 最大连续重启次数
RESTART_WINDOW=60       # 重启计数窗口（秒）
COOLDOWN_TIME=300       # 冷却时间（秒）
PROCESS_CHECK_TIMEOUT=3 # 进程检查超时（秒）

# 状态变量
RESTART_TIMES=()
IS_COOLDOWN=false

# ========================
# 日志管理
# ========================
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG"
    
    # 日志轮转
    if [ -f "$LOG" ]; then
        local log_size=$(stat -c%s "$LOG" 2>/dev/null || stat -f%z "$LOG" 2>/dev/null || echo 0)
        if [ "$log_size" -gt $MAX_LOG_SIZE ]; then
            mv "$LOG" "${LOG}.old"
            log_message "INFO" "日志文件已轮转"
        fi
    fi
}

# ========================
# 锁机制（防止多实例）
# ========================
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_message "ERROR" "守护进程已在运行 (PID: $pid)"
            exit 1
        else
            log_message "WARN" "清理过期锁文件 (PID: $pid)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# ========================
# 精确的进程检查
# ========================
check_ssr_process() {
    # 使用更精确的进程匹配，避免误报
    timeout $PROCESS_CHECK_TIMEOUT pgrep -f "python.*ssserver" > /dev/null 2>&1
    return $?
}

# ========================
# 端口监听检查（双重验证）
# ========================
check_ssr_port() {
    # 检查 SSR 是否真正在监听端口
    if command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":.*LISTEN" && return 0
    elif command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q "LISTEN" && return 0
    fi
    return 1
}

# ========================
# 重启频率控制
# ========================
should_restart() {
    local current_time=$(date +%s)
    
    # 清理过期的重启记录
    local temp_times=()
    for time in "${RESTART_TIMES[@]}"; do
        if [ $((current_time - time)) -lt $RESTART_WINDOW ]; then
            temp_times+=("$time")
        fi
    done
    RESTART_TIMES=("${temp_times[@]}")
    
    # 检查是否处于冷却期
    if [ "$IS_COOLDOWN" = true ]; then
        local last_restart=${RESTART_TIMES[-1]:-0}
        if [ $((current_time - last_restart)) -gt $COOLDOWN_TIME ]; then
            IS_COOLDOWN=false
            RESTART_TIMES=()
            log_message "INFO" "冷却期结束，重置计数器"
        else
            return 1
        fi
    fi
    
    # 检查重启频率
    if [ ${#RESTART_TIMES[@]} -ge $MAX_RESTART_COUNT ]; then
        IS_COOLDOWN=true
        log_message "WARN" "重启过于频繁，进入 ${COOLDOWN_TIME}s 冷却期"
        return 1
    fi
    
    return 0
}

# ========================
# SSR 重启逻辑
# ========================
restart_ssr() {
    log_message "WARN" "检测到 SSR 服务异常，准备重启..."
    
    # 记录重启时间
    RESTART_TIMES+=($(date +%s))
    
    # 尝试优雅停止
    if [ -f "$SERVICE" ]; then
        log_message "INFO" "执行优雅停止..."
        timeout 10 $SERVICE stop >> "$LOG" 2>&1 || {
            log_message "WARN" "优雅停止超时，强制终止进程"
            pkill -9 -f "python.*ssserver"
        }
    fi
    
    sleep 2
    
    # 启动服务
    log_message "INFO" "正在启动 SSR 服务..."
    $SERVICE start >> "$LOG" 2>&1
    
    sleep 3
    
    # 验证启动结果
    if check_ssr_process && check_ssr_port; then
        log_message "INFO" "✅ SSR 服务重启成功"
        return 0
    else
        log_message "ERROR" "❌ SSR 服务重启失败"
        return 1
    fi
}

# ========================
# 信号处理
# ========================
cleanup() {
    log_message "INFO" "守护进程收到终止信号，正在退出..."
    release_lock
    exit 0
}

trap cleanup SIGTERM SIGINT

# ========================
# 主循环
# ========================
main() {
    acquire_lock
    log_message "INFO" "🛡️ SSR 智能守护服务启动 (PID: $$)"
    log_message "INFO" "配置: 检查间隔=${CHECK_INTERVAL}s, 重启窗口=${RESTART_WINDOW}s, 最大重启=${MAX_RESTART_COUNT}次"
    
    while true; do
        # 检查进程和端口
        if ! check_ssr_process; then
            log_message "WARN" "⚠️ SSR 进程未运行"
            
            if should_restart; then
                restart_ssr
            else
                log_message "WARN" "⏸️ 处于冷却期，跳过重启"
            fi
        elif ! check_ssr_port; then
            log_message "WARN" "⚠️ SSR 进程存在但未监听端口"
            
            if should_restart; then
                restart_ssr
            fi
        fi
        
        # 动态调整检查间隔
        if [ "$IS_COOLDOWN" = true ]; then
            sleep 30  # 冷却期降低检查频率
        else
            sleep $CHECK_INTERVAL
        fi
    done
}

# 启动守护
main
EOF

chmod +x /usr/local/bin/ssr_guard.sh

# systemd 服务守护
cat > /etc/systemd/system/ssr-guard.service <<EOF
[Unit]
Description=SSR 智能守护服务
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
# 防火墙规则
# ========================
echo -e "\033[33m🔥 配置防火墙规则...\033[0m"

# 保留 SSH 端口(防止被锁)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 允许已建立的连接
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 允许本地回环
iptables -A INPUT -i lo -j ACCEPT

# SSR 端口规则
iptables -A INPUT -p tcp --dport $SSR_PANEL_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SSR_PANEL_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SSR_TEDDYSUN_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SSR_TEDDYSUN_PORT -j ACCEPT

# 保存规则
iptables-save > /etc/iptables.rules

# 根据系统选择持久化方法
if [ -d /etc/network/if-pre-up.d ]; then
    # 传统 Debian/Ubuntu 系统
    cat > /etc/network/if-pre-up.d/iptables <<'EOFF'
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOFF
    chmod +x /etc/network/if-pre-up.d/iptables
elif command -v systemctl &> /dev/null; then
    # systemd 系统
    cat > /etc/systemd/system/iptables-restore.service <<'EOFF'
[Unit]
Description=Restore iptables rules
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.rules

[Install]
WantedBy=multi-user.target
EOFF
    systemctl enable iptables-restore.service
fi

# ========================
# 部署完成
# ========================
echo ""
echo -e "\033[32m================================================\033[0m"
echo -e "\033[32m✅ 部署完成！\033[0m"
echo -e "\033[32m================================================\033[0m"
echo ""
echo -e "\033[33m📋 服务管理命令：\033[0m"
echo "  SSRPanel 服务:     systemctl status ssrpanel"
echo "  Teddysun SSR 服务: /etc/init.d/shadowsocks status"
echo "  智能守护服务:      systemctl status ssr-guard"
echo ""
echo -e "\033[33m📊 日志查看：\033[0m"
echo "  守护日志: tail -f /var/log/ssr_guard.log"
echo "  SSRPanel: journalctl -u ssrpanel -f"
echo ""
echo -e "\033[33m🔧 配置信息：\033[0m"
echo "  节点 ID: $node"
echo "  SSR Panel 端口: $SSR_PANEL_PORT"
echo "  Teddysun SSR 端口: $SSR_TEDDYSUN_PORT"
echo ""
echo -e "\033[33m🚀 BBR 状态：\033[0m"
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo -e "  \033[32m✅ BBR 加速已启用\033[0m"
else
    echo -e "  \033[31m❌ BBR 未启用（内核版本过低或配置失败）\033[0m"
fi
echo ""
echo -e "\033[36m🛡️ 智能守护已启用（自动重启 + 频率控制 + 冷却机制）\033[0m"
echo ""
