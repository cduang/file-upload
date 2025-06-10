#!/bin/bash

# ==============================================================================
# Redroid 一键搭建脚本 (Ubuntu) v2.2 - Android 版本 & 菜单选择版
# ==============================================================================
#
# 功能:
# ... (同前) ...
# 新增: 允许用户通过菜单选择要安装的 Android 版本。
# 改动: 使用交互式菜单选择 Android 版本和 ADB 端口。
#
# 使用方法:
# 1. 保存脚本: `nano setup_redroid_menu_v2.2.sh`
# 2. 赋予执行权限: `chmod +x setup_redroid_menu_v2.2.sh`
# 3. 使用 sudo 运行: `sudo ./setup_redroid_menu_v2.2.sh`
# 4. 按照菜单提示操作。
#
# ==============================================================================

# --- 配置变量 ---
# 默认值，会被用户选择覆盖
DEFAULT_REDROID_IMAGE="redroid/redroid:11.0.0_64only-latest" # 默认 Android 11 64bit
CONTAINER_NAME="my-redroid-instance"
DEFAULT_HOST_ADB_PORT="5555" # 默认端口
DATA_VOLUME_HOST_PATH="$HOME/redroid_data"

# --- Android 版本列表 ---
# 格式: "显示名称|镜像标签"
# 注意: -latest 标签可能会随时间更新，如果需要固定版本，请去掉 -latest
ANDROID_VERSIONS=(
    "Android 15 (64bit only)|redroid/redroid:15.0.0_64only-latest"
    "Android 15|redroid/redroid:15.0.0-latest"
    "Android 14 (64bit only)|redroid/redroid:14.0.0_64only-latest"
    "Android 14|redroid/redroid:14.0.0-latest"
    "Android 13 (64bit only)|redroid/redroid:13.0.0_64only-latest"
    "Android 13|redroid/redroid:13.0.0-latest"
    "Android 12 (64bit only)|redroid/redroid:12.0.0_64only-latest"
    "Android 12|redroid/redroid:12.0.0-latest"
    "Android 11 (64bit only)|redroid/redroid:11.0.0_64only-latest" # 默认选项标记
    "Android 11|redroid/redroid:11.0.0-latest"
    "Android 10|redroid/redroid:10.0.0-latest"
    "Android 9|redroid/redroid:9.0.0-latest"
    "Android 8.1|redroid/redroid:8.1.0-latest"
)

# --- 脚本变量 ---
REDROID_IMAGE="" # 最终选择的镜像
HOST_ADB_PORT="" # 最终使用的端口

# --- 函数定义 ---

# 检查端口是否可用 (未被监听 TCP)
is_port_available() {
  local port=$1
  if ss -tlpn | grep -q ":${port}\b"; then return 1; else return 0; fi
}

# 查找一个随机的可用端口
find_random_free_port() {
  local min_port=10000; local max_port=65535; local random_port; local max_attempts=20
  echo "正在查找随机可用端口 (范围 ${min_port}-${max_port})..."
  for (( i=0; i<max_attempts; i++ )); do
    random_port=$(( RANDOM % (max_port - min_port + 1) + min_port ))
    if is_port_available "$random_port"; then echo "$random_port"; return 0; fi
    sleep 0.1
  done
  echo "错误: 无法在 ${max_attempts} 次尝试内找到可用的随机端口。" >&2; return 1
}

# --- 脚本主体 ---

set -e; set -u; set -o pipefail

if [[ $EUID -ne 0 ]]; then
   echo "错误: 此脚本需要使用 root 权限运行 (sudo ./setup_redroid_menu_v2.2.sh)"
   exit 1
fi

SUDO_USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
if [[ -z "$SUDO_USER_NAME" ]] || [[ "$SUDO_USER_NAME" == "root" ]]; then
    potential_user=$(basename "$(eval echo ~$(whoami))")
    echo "警告: 无法可靠确定发起 sudo 的用户名，将尝试使用 '$potential_user' 或 'root'。"
    SUDO_USER_NAME="${potential_user:-root}"
fi
echo "检测到操作用户为: ${SUDO_USER_NAME}"

USER_HOME_DIR=$(getent passwd "$SUDO_USER_NAME" | cut -d: -f6)
if [[ -z "$USER_HOME_DIR" ]]; then
    echo "错误: 无法获取用户 ${SUDO_USER_NAME} 的家目录。" >&2
    USER_HOME_DIR="/tmp"; echo "将使用 /tmp 作为数据目录的基础。" >&2
fi
if [[ ${DATA_VOLUME_HOST_PATH:0:1} == "~" ]]; then
     DATA_VOLUME_HOST_PATH="${USER_HOME_DIR}/${DATA_VOLUME_HOST_PATH:2}"
elif [[ ${DATA_VOLUME_HOST_PATH:0:1} != "/" ]]; then
     echo "警告: 数据目录路径 '${DATA_VOLUME_HOST_PATH}' 是相对路径，将放置在用户 ${SUDO_USER_NAME} 的家目录下: ${USER_HOME_DIR}/${DATA_VOLUME_HOST_PATH}"
     DATA_VOLUME_HOST_PATH="${USER_HOME_DIR}/${DATA_VOLUME_HOST_PATH}"
fi

echo "======================================="
echo " Redroid 搭建脚本启动 (v2.2)"
echo "======================================="

# --- Android 版本选择菜单 ---
while true; do
  echo ""
  echo "请选择要安装的 Android 版本:"
  for i in "${!ANDROID_VERSIONS[@]}"; do
    # 从 "显示名称|镜像标签" 中提取显示名称
    display_name=$(echo "${ANDROID_VERSIONS[$i]}" | cut -d'|' -f1)
    image_tag=$(echo "${ANDROID_VERSIONS[$i]}" | cut -d'|' -f2)
    # 标记默认选项
    default_marker=""
    if [[ "$image_tag" == "$DEFAULT_REDROID_IMAGE" ]]; then
        default_marker=" (默认)"
    fi
    printf "  %2d) %s%s\n" $((i+1)) "$display_name" "$default_marker"
  done
  echo "   q) 退出脚本"
  echo ""
  read -p "请输入选项数字 [1-${#ANDROID_VERSIONS[@]} 或 q]: " version_choice

  if [[ "$version_choice" =~ ^[Qq]$ ]]; then
      echo "操作已取消。"
      exit 0
  fi

  # 验证输入是否为有效数字且在范围内
  if [[ "$version_choice" =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le ${#ANDROID_VERSIONS[@]} ]; then
    # 获取选择的镜像标签 (数组索引从0开始，所以要减1)
    REDROID_IMAGE=$(echo "${ANDROID_VERSIONS[$((version_choice-1))]}" | cut -d'|' -f2)
    display_name=$(echo "${ANDROID_VERSIONS[$((version_choice-1))]}" | cut -d'|' -f1)
    echo "已选择 Android 版本: ${display_name} (镜像: ${REDROID_IMAGE})"
    break # 跳出循环
  else
    echo "无效的选择，请输入列表中的数字或 q。"
  fi
done

# --- 端口选择菜单 ---
while true; do
  echo ""
  echo "请选择 ADB 端口映射方式:"
  echo "  1) 使用默认端口 (${DEFAULT_HOST_ADB_PORT})"
  echo "  2) 指定一个端口 (1025-65535)"
  echo "  3) 使用随机端口 (10000-65535)"
  echo "  4) 返回上一步 (重新选择 Android 版本)"
  echo "  5) 退出脚本"
  echo ""
  read -p "请输入选项数字 [1-5]: " menu_choice

  case $menu_choice in
    1)
      HOST_ADB_PORT=$DEFAULT_HOST_ADB_PORT
      echo "已选择默认端口: ${HOST_ADB_PORT}"
      if ! is_port_available "$HOST_ADB_PORT"; then
          echo "警告: 默认端口 ${HOST_ADB_PORT} 当前似乎已被监听。Docker 启动时可能会失败。" >&2
          read -p "是否继续? (y/N): " confirm_continue
          if [[ ! "$confirm_continue" =~ ^[Yy]$ ]]; then continue; fi
      fi
      break # 跳出端口选择循环
      ;;
    2)
      read -p "请输入要使用的主机端口 (1025-65535): " SPECIFIED_PORT
      if ! [[ "$SPECIFIED_PORT" =~ ^[0-9]+$ ]] || [ "$SPECIFIED_PORT" -le 1024 ] || [ "$SPECIFIED_PORT" -gt 65535 ]; then
        echo "错误: 无效的端口号 '$SPECIFIED_PORT'。" >&2; continue
      fi
      HOST_ADB_PORT=$SPECIFIED_PORT
      echo "已选择指定端口: ${HOST_ADB_PORT}"
      if ! is_port_available "$HOST_ADB_PORT"; then
          echo "警告: 指定的端口 ${HOST_ADB_PORT} 当前似乎已被监听。" >&2
          read -p "是否继续? (y/N): " confirm_continue
          if [[ ! "$confirm_continue" =~ ^[Yy]$ ]]; then continue; fi
      fi
      break # 跳出端口选择循环
      ;;
    3)
      RANDOM_PORT_FOUND=$(find_random_free_port)
      if [[ $? -ne 0 ]]; then echo "$RANDOM_PORT_FOUND"; continue; fi
      HOST_ADB_PORT=$RANDOM_PORT_FOUND
      echo "已选择随机端口: ${HOST_ADB_PORT}"
      break # 跳出端口选择循环
      ;;
    4)
      # 通过 continue 跳到最外层 while true 的开头，重新选择 Android 版本
      echo "返回 Android 版本选择..."
      # 需要重置 REDROID_IMAGE 吗？这里选择不重置，直接回到版本选择菜单
      # REDROID_IMAGE="" # 取消这行，允许用户修改端口后继续
      exec "$0" "$@" # 重新执行脚本是更干净的方法来返回顶部菜单
      # 或者使用 continue 2 跳出两层循环，但这依赖于循环结构
      # 或者设置一个标志位，在外面检查
      # 为了简单和清晰，这里使用 exec 重新执行脚本
      ;;
    5)
      echo "操作已取消。"
      exit 0
      ;;
    *)
      echo "无效的选择，请输入数字 1-5。"
      ;;
  esac
done


echo "---------------------------------------"
echo "配置信息确认:"
echo "  Android 版本 (镜像): ${REDROID_IMAGE}" # 显示选择的镜像
echo "  容器名称: ${CONTAINER_NAME}"
echo "  主机 ADB 端口: ${HOST_ADB_PORT}"
echo "  主机数据目录: ${DATA_VOLUME_HOST_PATH}"
echo "---------------------------------------"
read -p "确认以上信息并开始安装吗? (Y/n): " confirm_install
if [[ "$confirm_install" =~ ^[Nn]$ ]]; then
    echo "安装已取消。"
    exit 0
fi
echo "---------------------------------------"

# --- 开始执行安装步骤 ---

# 步骤 1: 更新包列表和安装依赖
echo "[步骤 1/7] 更新系统包列表并安装依赖 (ss 命令需要 iproute2)..."
apt-get update
apt-get install -y curl wget gnupg lsb-release ca-certificates apt-transport-https iproute2
echo "依赖安装完成。"
echo "---------------------------------------"

# 步骤 2: 安装 Docker Engine
echo "[步骤 2/7] 安装 Docker Engine..."
# (Docker 安装代码同前)
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，开始安装..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker 安装完成。"
else
    echo "Docker 已安装，跳过安装步骤。"
fi
systemctl enable docker --now
echo "Docker 服务已启动并设置为开机自启。"
echo "---------------------------------------"

# 步骤 3: 将用户添加到 docker 组
echo "[步骤 3/7] 将用户 ${SUDO_USER_NAME} 添加到 docker 组..."
# (代码同前)
if getent group docker > /dev/null; then
    if ! groups "$SUDO_USER_NAME" | grep -q '\bdocker\b'; then
        usermod -aG docker "$SUDO_USER_NAME"
        echo "用户 ${SUDO_USER_NAME} 已添加到 docker 组。您可能需要重新登录或运行 'newgrp docker' 使更改生效。"
    else
        echo "用户 ${SUDO_USER_NAME} 已在 docker 组中。"
    fi
else
    echo "警告: 未找到 docker 组，跳过添加用户步骤。"
fi
echo "---------------------------------------"

# 步骤 4: 拉取 Redroid 镜像 (使用选择的镜像)
echo "[步骤 4/7] 拉取 Redroid 镜像 (${REDROID_IMAGE})..."
docker pull "${REDROID_IMAGE}" # 使用变量
echo "Redroid 镜像拉取完成。"
echo "---------------------------------------"

# 步骤 5: 创建数据目录
echo "[步骤 5/7] 准备主机数据目录 (${DATA_VOLUME_HOST_PATH})..."
# (代码同前)
mkdir -p "${DATA_VOLUME_HOST_PATH}"
echo "尝试将数据目录所有权设置为 ${SUDO_USER_NAME}..."
chown "${SUDO_USER_NAME}":"$(id -gn "$SUDO_USER_NAME")" "${DATA_VOLUME_HOST_PATH}" || echo "警告: 设置数据目录所有权失败，权限可能不正确。"
chmod 770 "${DATA_VOLUME_HOST_PATH}"
echo "数据目录准备完成。"
echo "---------------------------------------"

# 步骤 6: 启动 Redroid 容器 (使用选择的镜像)
echo "[步骤 6/7] 启动 Redroid 容器 (${CONTAINER_NAME})..."
# (代码同前)
docker stop "${CONTAINER_NAME}" > /dev/null 2>&1 || true
docker rm "${CONTAINER_NAME}" > /dev/null 2>&1 || true
echo "正在启动新容器..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    --privileged \
    -v "${DATA_VOLUME_HOST_PATH}:/data" \
    -p "${HOST_ADB_PORT}:5555" \
    "${REDROID_IMAGE}" # 使用变量
echo "---------------------------------------"

# 步骤 7: 检查容器状态和显示信息
echo "[步骤 7/7] 检查容器状态并显示连接信息..."
# (代码同前)
sleep 5
if docker ps -f name="^/${CONTAINER_NAME}$" --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo "Redroid 容器 (${CONTAINER_NAME}) 已成功启动！"
else
    echo "错误: Redroid 容器未能成功启动。请检查日志: docker logs ${CONTAINER_NAME}"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(ip -4 addr show $(ip route | grep default | awk '{print $5}') | grep inet | awk '{print $2}' | cut -d/ -f1)
fi
if [ -z "$SERVER_IP" ]; then SERVER_IP="<你的服务器IP地址>"; fi

echo "======================================="
echo " Redroid 环境搭建完成！"
echo "======================================="
echo ""
echo "下一步操作 (在你的 **客户端** 电脑上):"
echo ""
echo "1.  **安装 adb 和 scrcpy:** (如果尚未安装)"
echo "    - Debian/Ubuntu: sudo apt update && sudo apt install -y adb scrcpy"
echo "    - macOS: brew install android-platform-tools scrcpy"
echo "    - Windows: 下载 platform-tools (adb) 和 scrcpy"
echo ""
echo "2.  **连接到 Redroid 容器:**"
echo "    adb connect ${SERVER_IP}:${HOST_ADB_PORT}"
echo "    (防火墙需允许访问端口 ${HOST_ADB_PORT})"
echo ""
echo "3.  **启动 scrcpy:**"
echo "    scrcpy --adb-port ${HOST_ADB_PORT}"
# echo "    scrcpy -s ${SERVER_IP}:${HOST_ADB_PORT}" # 另一种方式
echo ""
echo "--- 服务器端 Docker 管理命令 ---"
echo "查看容器状态: docker ps -f name=${CONTAINER_NAME}"
echo "停止容器:     docker stop ${CONTAINER_NAME}"
echo "启动容器:     docker start ${CONTAINER_NAME}"
echo "查看容器日志: docker logs ${CONTAINER_NAME}"
echo "移除容器:     docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
echo "              (数据在 ${DATA_VOLUME_HOST_PATH})"
echo ""
echo "安全提醒: 请勿将 ADB 端口 (${HOST_ADB_PORT}) 直接暴露于公网！"
echo "======================================="

exit 0
