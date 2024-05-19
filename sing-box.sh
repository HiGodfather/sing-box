#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义常量
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LOG_FILE="/var/log/singbox.log"
SERVICE_NAME="sing-box"
CLIENT_CONFIG_FILE="${CONFIG_DIR}/client.txt"

# 检查 root 权限
check_root() {
   if [ "$(id -u)" != "0" ]; then
       echo -e "${RED}请使用 root 权限执行此脚本！${RESET}"
       exit 1
   fi
}

# 检查 sing-box 是否已安装
is_sing_box_installed() {
   if [ -x "$(command -v sing-box)" ]; then
       return 0
   else
       return 1
   fi
}

# 安装 sing-box
install_sing_box() {
   echo -e "${CYAN}正在安装 sing-box${RESET}"
   bash <(curl -fsSL https://sing-box.app/deb-install.sh) || {
       echo -e "${RED}sing-box 安装失败！请检查网络连接或安装脚本来源。${RESET}"
       exit 1
   }

   # 生成随机端口和密码
   hport=$(shuf -i 1025-65535 -n 1)
   vport=$(shuf -i 1025-65535 -n 1)
   password=$(tr -dc A-Za-z < /dev/urandom | head -c 6)

   # 生成 UUID 和 Reality 密钥对
   uuid=$(sing-box generate uuid)
   reality_output=$(sing-box generate reality-keypair)
   private_key=$(echo "${reality_output}" | grep -oP 'PrivateKey:\s*\K.*')
   public_key=$(echo "${reality_output}" | grep -oP 'PublicKey:\s*\K.*')

   # 生成自签名证书
   openssl ecparam -genkey -name prime256v1 -out "${CONFIG_DIR}/private.key"
   openssl req -new -x509 -days 3650 -key "${CONFIG_DIR}/private.key" -out "${CONFIG_DIR}/cert.pem" -subj "/CN=bing.com"

   # 获取本机 IP 地址和所在国家
   host_ip=$(curl -s http://checkip.amazonaws.com)
   ip_country=$(curl -s http://ipinfo.io/${host_ip}/country)

   # 确保目录存在
   mkdir -p "${CONFIG_DIR}"

   # 生成配置文件
   cat > "${CONFIG_FILE}" << EOF
{
 "log": {
   "level": "info",
   "timestamp": true,
   "output": "${LOG_FILE}"
 },
 "inbounds": [
   {
     "type": "hysteria2",
     "tag": "hysteria-in",
     "listen": "::",
     "listen_port": ${hport},
     "users": [
         {
             "password": "${password}"
         }
     ],
     "masquerade": "https://bing.com",
     "tls": {
         "enabled": true,
         "alpn": [
             "h3"
         ],
         "certificate_path": "${CONFIG_DIR}/cert.pem",
         "key_path": "${CONFIG_DIR}/private.key"
     }
   },
   {
     "type": "vless",
     "tag": "vless-in",
     "listen": "::",
     "listen_port": ${vport},
     "users": [
         {
             "uuid": "${uuid}",
             "flow": "xtls-rprx-vision"
         }
     ],
     "tls": {
         "enabled": true,
         "server_name": "www.tesla.com",
         "reality": {
             "enabled": true,
             "handshake": {
                 "server": "www.tesla.com",
                 "server_port": 443
             },
             "private_key": "${private_key}",
             "short_id": [
                 "123abc"
               ]
             }
         }
     }
 ],
 "outbounds": [
   {
     "type": "direct",
     "tag": "direct-out"
   }
 ]
}
EOF

   # 启用并启动 sing-box 服务
   systemctl enable "${SERVICE_NAME}" || {
       echo -e "${RED}无法启用 ${SERVICE_NAME} 服务！${RESET}"
       exit 1
   }

   systemctl start "${SERVICE_NAME}" || {
       echo -e "${RED}无法启动 ${SERVICE_NAME} 服务！${RESET}"
       exit 1
   }

   # 检查服务状态
   if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
       echo -e "${RED}${SERVICE_NAME} 服务未成功启动！${RESET}"
       systemctl status "${SERVICE_NAME}"
       exit 1
   fi

   # 输出客户端配置到文件
   {
       cat << EOF
- name: ${ip_country}
  type: hysteria2
  server: ${host_ip}
  port: ${hport}
  password: ${password}
  alpn:
   - h3
  sni: www.bing.com
  skip-cert-verify: true
  fast-open: true
- name: ${ip_country}
  type: vless
  server: ${host_ip}
  port: ${vport}
  uuid: ${uuid}
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: www.tesla.com
  reality-opts:
    public-key: ${public_key}
    short-id: 123abc
  client-fingerprint: chrome
EOF
       echo
       echo "hy2://${password}@${host_ip}:${hport}?insecure=1&sni=www.bing.com#${ip_country}"
       echo
       echo "${ip_country} = hysteria2, ${host_ip}, ${hport}, password = ${password}, skip-cert-verify=true, sni=www.bing.com"
       echo
       echo "vless://${uuid}@${host_ip}:${vport}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.tesla.com&fp=chrome&pbk=${public_key}&sid=123abc&type=tcp&headerType=none#${ip_country}"
       echo
   } > "${CLIENT_CONFIG_FILE}"

   echo -e "${GREEN}sing-box 安装成功${RESET}"
   cat "${CLIENT_CONFIG_FILE}"
}

# 卸载 sing-box
uninstall_sing_box() {
   read -p "$(echo -e "${RED}确定要卸载 sing-box 吗? (y/n) ${RESET}")" choice
   case "${choice}" in
       y|Y)
           echo -e "${CYAN}正在卸载 sing-box${RESET}"

           # 停止 sing-box 服务
           systemctl stop "${SERVICE_NAME}"

           # 禁用 sing-box 服务
           systemctl disable "${SERVICE_NAME}"

           # 卸载 sing-box 服务
           dpkg --purge sing-box || true

           # 删除配置文件和日志
           rm -rf "${CONFIG_DIR}" || true
           rm -f "${LOG_FILE}" || true

           # 重新加载 systemd
           systemctl daemon-reload || true

           echo -e "${GREEN}sing-box 卸载成功${RESET}"
           ;;
       *)
           echo -e "${YELLOW}已取消卸载操作${RESET}"
           ;;
   esac
}

# 启动 sing-box
start_sing_box() {
   echo -e "${CYAN}正在启动 ${SERVICE_NAME} 服务${RESET}"
   systemctl start "${SERVICE_NAME}"
   if [ $? -eq 0 ]; then
       echo -e "${GREEN}${SERVICE_NAME} 服务已成功启动${RESET}"
   else
       echo -e "${RED}${SERVICE_NAME} 服务启动失败${RESET}"
   fi
}

# 停止 sing-box
stop_sing_box() {
   echo -e "${CYAN}正在停止 ${SERVICE_NAME} 服务${RESET}"
   systemctl stop "${SERVICE_NAME}"
   if [ $? -eq 0 ]; then
       echo -e "${GREEN}${SERVICE_NAME} 服务已成功停止${RESET}"
   else
       echo -e "${RED}${SERVICE_NAME} 服务停止失败${RESET}"
   fi
}

# 重启 sing-box
restart_sing_box() {
   echo -e "${CYAN}正在重启 ${SERVICE_NAME} 服务${RESET}"
   systemctl restart "${SERVICE_NAME}"
   if [ $? -eq 0 ]; then
       echo -e "${GREEN}${SERVICE_NAME} 服务已成功重启${RESET}"
   else
       echo -e "${RED}${SERVICE_NAME} 服务重启失败${RESET}"
   fi
}

# 查看 sing-box 状态
status_sing_box() {
   systemctl status "${SERVICE_NAME}"
}

# 查看 sing-box 日志
log_sing_box() {
   tail -n 20 "${LOG_FILE}"
}

# 查看 sing-box 配置
check_sing_box() {
   cat "${CLIENT_CONFIG_FILE}"
}

# 显示菜单
show_menu() {
   is_sing_box_installed
   sing_box_installed=$?

   clear
   echo -e "${GREEN}=== sing-box 管理工具 ===${RESET}"
   echo -e "${GREEN}sing-box 状态: $(if [ ${sing_box_installed} -eq 0 ]; then echo "${GREEN}已安装${RESET}"; else echo "${RED}未安装${RESET}"; fi)${RESET}"
   echo "1. 安装 sing-box 服务"
   echo "2. 卸载 sing-box 服务"
   echo "3. 启动 sing-box 服务"
   echo "4. 停止 sing-box 服务"
   echo "5. 重启 sing-box 服务"
   echo "6. 查看 sing-box 状态"
   echo "7. 查看 sing-box 日志"
   echo "8. 查看 sing-box 配置"
   echo "0. 退出 sing-box 脚本"
   echo -e "${GREEN}=========================${RESET}"
   read -p "请输入选项编号(0-8): " choice
   echo ""
}

# 捕获 Ctrl+C 信号
trap 'echo "已取消操作"; exit' INT

# 检查 root 权限
check_root

# 主循环
while true; do
   show_menu
   case "${choice}" in
       1)
           if [ ${sing_box_installed} -eq 0 ]; then
               echo -e "${YELLOW}sing-box 已经安装！${RESET}"
           else
               install_sing_box
           fi
           ;;
       2)
           if [ ${sing_box_installed} -eq 0 ]; then
               uninstall_sing_box
           else
               echo -e "${YELLOW}sing-box 尚未安装！${RESET}"
           fi
           ;;
       3)
           start_sing_box
           ;;
       4)
           stop_sing_box
           ;;
       5)
           restart_sing_box
           ;;
       6)
           status_sing_box
           ;;
       7)
           log_sing_box
           ;;
       8)
           check_sing_box
           ;;
       0)
           echo -e "${GREEN}已退出 sing-box${RESET}"
           exit 0
           ;;
       *)
           echo -e "${RED}无效的选项，请输入 0 到 8${RESET}"
           ;;
   esac
   read -p "按 enter 键继续..."
done
