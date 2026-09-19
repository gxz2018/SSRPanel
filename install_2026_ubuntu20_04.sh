#!/bin/bash
#=================================================================#
#   SSR + IP盾构机一键部署脚本                                     #
#   适配 Debian 11 / Ubuntu 20.04 / 22.04                        #
#=================================================================#

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

if readlink /proc/$$/exe | grep -q "dash"; then
    echo -e "${red}请使用 bash 运行此脚本${plain}"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${red}错误: 必须使用 root 用户运行!${plain}"
    exit 1
fi

OS_ID=""
OS_VER=""

detect_os(){
    OS_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    OS_VER=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
}

check_system(){
    detect_os
    if grep -qs "14.04" /etc/os-release || grep -qs "jessie" /etc/os-release; then
        echo -e "${red}不支持 Ubuntu 14.04 或 Debian 8${plain}"; exit 1
    fi
}

pip3_install(){
    local py_ver
    py_ver=$(python3 -c "import sys; print(sys.version_info.minor)")
    if [ "$py_ver" -ge 11 ] \
       || [[ "$OS_ID" == "ubuntu" && "$OS_VER" > "21.99" ]] \
       || [[ "$OS_ID" == "debian" && "$OS_VER" -ge 12 ]]; then
        pip3 install --break-system-packages "$@"
    else
        pip3 install "$@"
    fi
}

get_ip(){
    local IP
    IP=$(ip addr | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
        | grep -vE "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." \
        | head -n 1)
    [ -z "$IP" ] && IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$IP" ] && IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)
    echo "${IP:-未知}"
}

#=================================================================#
# 修复 openssl.py
# 关键：用独立 Python 文件 + sys.argv 传参，彻底避免 heredoc 嵌套
#=================================================================#
fix_python310_compat(){
    local ssr_dir="$1"
    echo -e "${cyan}修复 Python 3.10+ 兼容性...${plain}"

    # 修复 collections.MutableMapping
    grep -rl "collections\.MutableMapping" "$ssr_dir" 2>/dev/null \
        | xargs sed -i 's/collections\.MutableMapping/collections.abc.MutableMapping/g'

    local openssl_py="$ssr_dir/shadowsocks/crypto/openssl.py"
    [ -f "$openssl_py" ] || return

    # 检测系统 libcrypto 版本
    local libcrypto_so
    libcrypto_so=$(ldconfig -p 2>/dev/null \
        | grep "libcrypto\.so\." \
        | awk '{print $NF}' \
        | head -1)
    libcrypto_so=$(basename "${libcrypto_so:-libcrypto.so}")

    # 写独立 Python 修复脚本（单引号 heredoc，bash 不展开任何变量）
    cat > /tmp/_fix_openssl.py << 'PYEOF'
import sys

path = sys.argv[1]
libcrypto_so = sys.argv[2]

with open(path) as f:
    lines = f.readlines()

# 找到 EVP_get_cipherbyname.restype 行，保留它及之后所有内容
start = 0
for i, line in enumerate(lines):
    if 'EVP_get_cipherbyname.restype' in line:
        start = i
        break

tail = ''.join(lines[start:])

# 重写整个文件头部，干净无污染
header = (
    '#!/usr/bin/env python\n'
    '# -*- coding: utf-8 -*-\n'
    'from __future__ import absolute_import, division, print_function, \\\n'
    '    with_statement\n'
    'import ctypes\n'
    'from ctypes import c_char_p, c_int, c_long, byref, \\\n'
    '    create_string_buffer, c_void_p\n'
    'from shadowsocks import common\n'
    'from shadowsocks.crypto import util\n'
    '\n'
    'libcrypto = None\n'
    'buf_size = 2048\n'
    'loaded = False\n'
    'buf = None\n'
    '\n'
    'def load_openssl():\n'
    '    global loaded, libcrypto, buf\n'
    '    libcrypto = ctypes.CDLL("' + libcrypto_so + '")\n'
)

with open(path, 'w') as f:
    f.write(header + tail)

print('openssl.py fixed, libcrypto =', libcrypto_so)
PYEOF

    # 通过 sys.argv 传参，和 bash 变量完全隔离
    python3 /tmp/_fix_openssl.py "$openssl_py" "$libcrypto_so"
    rm -f /tmp/_fix_openssl.py

    echo -e "${green}✓ Python 兼容性修复完成${plain}"
}

#=================================================================#
#                           主菜单
#=================================================================#
show_menu(){
    check_system
    clear
    echo -e "${cyan}"
    echo "============================================================"
    echo "  SSR + IP盾构机 一键部署脚本"
    echo "  适配 Debian 11 / Ubuntu 20.04 / 22.04"
    echo "============================================================"
    echo -e "${plain}"
    echo "【SSR 服务】"
    echo -e "${green}1.${plain} SSR 独立模式"
    echo -e "${green}2.${plain} SSR 面板模式 (对接 SSRPanel)"
    echo -e "${green}3.${plain} 卸载 SSR 独立模式"
    echo -e "${green}4.${plain} 卸载 SSR 面板模式"
    echo ""
    echo "【IP盾构机】"
    echo -e "${green}5.${plain} 落地机初始化"
    echo ""
    echo -e "${green}0.${plain} 退出"
    echo ""
    read -p "请输入选项 [0-5]: " choice
    case "$choice" in
        1) install_standalone ;;
        2) install_panel ;;
        3) uninstall_standalone ;;
        4) uninstall_panel ;;
        5) ip_landing_init ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选项${plain}" && sleep 2 && show_menu ;;
    esac
}

#=================================================================#
#                        落地机
#=================================================================#
ip_landing_init(){
    echo -e "\n${cyan}=== 落地机初始化 ===${plain}\n"
    echo -e "${yellow}注意: 请提前手动放行防火墙端口!${plain}\n"

    apt-get update && apt-get install -y wget curl ca-certificates

    read -p "是否下载被控端文件? [y/N]: " down_files_1
    if [[ "$down_files_1" =~ ^[yY]$ ]]; then
        wget -q --show-progress http://eltty.elttycn.com/gost -O /usr/bin/gost
        chmod +x /usr/bin/gost
        wget -q --show-progress http://eltty.elttycn.com/iptables_gost -O /usr/bin/iptables_gost
        chmod +x /usr/bin/iptables_gost
        echo -e "${green}✓ 文件下载完成${plain}"
    fi

    echo -e "\n${green}✅ 落地机初始化完成${plain}"
    echo "工具路径: /usr/bin/gost  /usr/bin/iptables_gost"
    read -p "按 Enter 返回主菜单..." && show_menu
}

#=================================================================#
#                        SSR 独立模式
#=================================================================#
libsodium_file="libsodium-1.0.18"
libsodium_url="https://github.com/jedisct1/libsodium/releases/download/1.0.18-RELEASE/libsodium-1.0.18.tar.gz"
shadowsocks_r_url="https://github.com/shadowsocksrr/shadowsocksr/archive/3.2.2.tar.gz"
cur_dir=$(pwd)

ciphers=(none aes-256-cfb aes-192-cfb aes-128-cfb aes-256-cfb8 aes-192-cfb8 aes-128-cfb8
         aes-256-ctr aes-192-ctr aes-128-ctr chacha20-ietf chacha20 salsa20
         xchacha20 xsalsa20 rc4-md5)
protocols=(origin verify_deflate auth_sha1_v4 auth_sha1_v4_compatible
           auth_aes128_md5 auth_aes128_sha1 auth_chain_a auth_chain_b
           auth_chain_c auth_chain_d auth_chain_e auth_chain_f)
obfs=(plain http_simple http_simple_compatible http_post http_post_compatible
      tls1.2_ticket_auth tls1.2_ticket_auth_compatible
      tls1.2_ticket_fastauth tls1.2_ticket_fastauth_compatible)

libsodium_installed(){
    find /usr/lib -name "libsodium.a" 2>/dev/null | grep -q . \
    || [ -f "/usr/local/lib/libsodium.a" ]
}

install_standalone(){
    echo -e "\n${cyan}=== SSR 独立模式 ===${plain}\n"

    read -p "SSR 密码 (默认: teddysun.com): " shadowsockspwd
    [ -z "$shadowsockspwd" ] && shadowsockspwd="teddysun.com"

    dport=$(shuf -i 9000-19999 -n 1)
    read -p "端口 (默认: ${dport}): " shadowsocksport
    [ -z "$shadowsocksport" ] && shadowsocksport=$dport

    echo -e "\n加密方式:"; for ((i=1;i<=${#ciphers[@]};i++)); do echo -e "${green}${i})${plain} ${ciphers[$i-1]}"; done
    read -p "选择 (默认 2): " pick; [ -z "$pick" ] && pick=2
    shadowsockscipher=${ciphers[$pick-1]}

    echo -e "\n协议:"; for ((i=1;i<=${#protocols[@]};i++)); do echo -e "${green}${i})${plain} ${protocols[$i-1]}"; done
    read -p "选择 (默认 1): " protocol; [ -z "$protocol" ] && protocol=1
    shadowsockprotocol=${protocols[$protocol-1]}

    echo -e "\n混淆:"; for ((i=1;i<=${#obfs[@]};i++)); do echo -e "${green}${i})${plain} ${obfs[$i-1]}"; done
    read -p "选择 (默认 1): " r_obfs; [ -z "$r_obfs" ] && r_obfs=1
    shadowsockobfs=${obfs[$r_obfs-1]}

    echo -e "\n${cyan}确认: 密码=$shadowsockspwd 端口=$shadowsocksport 加密=$shadowsockscipher${plain}"
    read -p "按 Enter 开始安装..."

    # 安装依赖
    DEBIAN_FRONTEND=noninteractive apt-get -y update
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        python3 python3-dev python3-setuptools python3-pip \
        openssl libssl-dev curl wget unzip gcc automake autoconf make libtool libsodium-dev

    # 下载安装
    cd "${cur_dir}"
    if ! libsodium_installed; then
        wget --no-check-certificate -O "${libsodium_file}.tar.gz" "${libsodium_url}" || exit 1
        tar zxf "${libsodium_file}.tar.gz"
        cd "${libsodium_file}" && ./configure --prefix=/usr && make && make install || exit 1
        cd "${cur_dir}"
    fi
    ldconfig

    wget --no-check-certificate -O ssr.tar.gz "${shadowsocks_r_url}" || exit 1
    tar zxf ssr.tar.gz
    mv shadowsocksr-3.2.2/shadowsocks /usr/local/
    rm -rf shadowsocksr-3.2.2 ssr.tar.gz "${libsodium_file}.tar.gz" "${libsodium_file}"

    # 修复 Python 兼容性
    fix_python310_compat "/usr/local"

    # 写配置
    cat > /etc/shadowsocks.json << EOF
{
    "server":"0.0.0.0",
    "server_ipv6":"[::]",
    "server_port":${shadowsocksport},
    "local_address":"127.0.0.1",
    "local_port":1080,
    "password":"${shadowsockspwd}",
    "timeout":120,
    "method":"${shadowsockscipher}",
    "protocol":"${shadowsockprotocol}",
    "protocol_param":"",
    "obfs":"${shadowsockobfs}",
    "obfs_param":"",
    "redirect":"",
    "dns_ipv6":false,
    "fast_open":false,
    "workers":1
}
EOF

    # 写 systemd
    cat > /etc/systemd/system/shadowsocks-standalone.service << EOF
[Unit]
Description=ShadowsocksR Server (Standalone)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/shadowsocks/server.py -c /etc/shadowsocks.json
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowsocks-standalone
    systemctl start shadowsocks-standalone
    sleep 2

    if systemctl is-active --quiet shadowsocks-standalone; then
        clear
        echo -e "${green}✅ SSR 独立模式部署成功!${plain}"
        echo "=========================================="
        echo -e "IP:   ${cyan}$(get_ip)${plain}"
        echo -e "端口: ${cyan}${shadowsocksport}${plain}"
        echo -e "密码: ${cyan}${shadowsockspwd}${plain}"
        echo -e "协议: ${cyan}${shadowsockprotocol}${plain}"
        echo -e "混淆: ${cyan}${shadowsockobfs}${plain}"
        echo -e "加密: ${cyan}${shadowsockscipher}${plain}"
        echo "=========================================="
    else
        echo -e "${red}启动失败: journalctl -u shadowsocks-standalone${plain}"
        exit 1
    fi

    read -p "按 Enter 返回主菜单..." && show_menu
}

uninstall_standalone(){
    read -p "确定卸载 SSR 独立模式? (y/n): " answer
    if [[ "$answer" =~ ^[yY]$ ]]; then
        systemctl stop shadowsocks-standalone 2>/dev/null
        systemctl disable shadowsocks-standalone 2>/dev/null
        rm -f /etc/shadowsocks.json /etc/systemd/system/shadowsocks-standalone.service
        rm -rf /usr/local/shadowsocks
        systemctl daemon-reload
        echo -e "${green}✅ 卸载成功${plain}"
    fi
    read -p "按 Enter 返回主菜单..." && show_menu
}

#=================================================================#
#                        SSR 面板模式
#=================================================================#
install_panel(){
    echo -e "\n${cyan}=== SSR 面板模式 ===${plain}\n"
    echo "请确保已完成前端部署并知道节点 ID"
    echo ""

    read -p "MySQL 地址: " mysqla
    read -p "MySQL 用户名: " mysqlu
    read -p "MySQL 密码: " mysqlp
    read -p "MySQL 数据库名: " mysqld
    read -p "节点 ID: " node

    echo -e "\n${cyan}确认: ${mysqla}/${mysqld} 用户=${mysqlu} 节点=${node}${plain}"
    read -p "按 Enter 开始安装..."

    # 安装依赖
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git python3 python3-pip python3-dev net-tools \
        build-essential iptables iptables-persistent supervisor curl \
        libffi-dev libsodium-dev openssl libssl-dev

    pip3_install --upgrade pip
    pip3_install cymysql==0.9.1 pycryptodome

    # 防火墙
    iptables -F
    iptables -I INPUT -p tcp --dport 1:65535 -j ACCEPT
    iptables -I INPUT -p udp --dport 1:65535 -j ACCEPT
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive netfilter-persistent save

    # BBR
    local kernel_major kernel_minor
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2 | cut -d- -f1)
    if [ "$kernel_major" -gt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -ge 9 ]; }; then
        modprobe tcp_bbr 2>/dev/null || true
        grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl -p >/dev/null 2>&1
        echo -e "${green}✓ BBR 已启用${plain}"
    fi

    # 克隆 SSR
    cd /home
    [ -d "shadowsocksr" ] && rm -rf shadowsocksr
    git clone https://github.com/gxz2018/shadowsocksr-backup.git shadowsocksr
    cd shadowsocksr
    bash setup_cymysql.sh
    bash initcfg.sh

    # 写配置
    sed -i 's/sspanelv2/glzjinmod/g' userapiconfig.py
    sed -i "s/\"127.0.0.1\"/\"${mysqla}\"/g" usermysql.json
    sed -i "s/\"user\": \"ss\"/\"user\": \"${mysqlu}\"/g" usermysql.json
    sed -i "s/\"password\": \"pass\"/\"password\": \"${mysqlp}\"/g" usermysql.json
    sed -i "s/\"db\": \"sspanel\"/\"db\": \"${mysqld}\"/g" usermysql.json
    sed -i "s/\"node_id\": 0/\"node_id\": ${node}/g" usermysql.json
    sed -i 's/"server": "127.0.0.1"/"server": "0.0.0.0"/g' user-config.json 2>/dev/null || true

    # 修复 Python 兼容性
    fix_python310_compat "/home/shadowsocksr"

    # Supervisor 配置
    mkdir -p /etc/supervisor/conf.d /var/log/supervisor
    grep -q "\[include\]" /etc/supervisor/supervisord.conf 2>/dev/null || \
        echo -e "\n[include]\nfiles = /etc/supervisor/conf.d/*.conf" >> /etc/supervisor/supervisord.conf

    cat > /etc/supervisor/conf.d/ssr.conf << EOF
[program:ssr]
command=/usr/bin/python3 /home/shadowsocksr/server.py
directory=/home/shadowsocksr
autostart=true
autorestart=true
user=root
stdout_logfile=/var/log/supervisor/ssr.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=2
stderr_logfile=/var/log/supervisor/ssr_error.log
stderr_logfile_maxbytes=50MB
stderr_logfile_backups=2
startsecs=5
stopwaitsecs=10
EOF

    # systemd supervisor 单元
    cat > /etc/systemd/system/supervisor.service << EOF
[Unit]
Description=Supervisor process control system
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/supervisord -c /etc/supervisor/supervisord.conf
ExecStop=/usr/bin/supervisorctl shutdown
ExecReload=/usr/bin/supervisorctl reload
KillMode=process
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable supervisor
    systemctl restart supervisor
    sleep 3
    supervisorctl reread
    supervisorctl update
    supervisorctl start ssr 2>/dev/null || true
    sleep 3

    # 日志清理
    cat > /usr/local/bin/cleanup-ssr-logs.sh << 'EOF'
#!/bin/bash
find /var/log/supervisor -name "ssr*.log.*" -mtime +7 -delete
EOF
    chmod +x /usr/local/bin/cleanup-ssr-logs.sh
    crontab -l 2>/dev/null | grep -q "cleanup-ssr-logs" || \
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/cleanup-ssr-logs.sh >/dev/null 2>&1") | crontab -

    clear
    echo -e "${green}✅ SSR 面板模式部署成功!${plain}"
    echo "=========================================="
    echo "配置: /home/shadowsocksr/usermysql.json"
    echo ""
    echo "常用命令:"
    echo "  supervisorctl status ssr"
    echo "  supervisorctl restart ssr"
    echo "  tail -f /var/log/supervisor/ssr_error.log"
    echo "=========================================="

    read -p "按 Enter 返回主菜单..." && show_menu
}

uninstall_panel(){
    read -p "确定卸载 SSR 面板模式? (y/n): " answer
    if [[ "$answer" =~ ^[yY]$ ]]; then
        supervisorctl stop ssr 2>/dev/null || true
        systemctl stop supervisor 2>/dev/null || true
        systemctl disable supervisor 2>/dev/null || true
        rm -f /etc/supervisor/conf.d/ssr.conf
        rm -rf /home/shadowsocksr
        rm -f /usr/local/bin/cleanup-ssr-logs.sh
        crontab -l 2>/dev/null | grep -v "cleanup-ssr-logs" | crontab -
        systemctl daemon-reload
        echo -e "${green}✅ 卸载成功${plain}"
    fi
    read -p "按 Enter 返回主菜单..." && show_menu
}

#=================================================================#
show_menu
