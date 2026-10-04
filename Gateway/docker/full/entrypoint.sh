#!/bin/sh

# Sway 配置 (仅在安装了 seatd 的 Full 版本中生效)
if command -v seatd >/dev/null 2>&1; then
    export WLR_RENDERER_ALLOW_SOFTWARE=1
    export SWAY_NO_UNSUPPORTED_GPU_CHECK=1
    # ==========================================
    # 伪造 systemd-logind 行为，手动创建 Wayland 运行时目录
    # ==========================================
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    # 用 sudo 创建目录
    sudo mkdir -p "$XDG_RUNTIME_DIR"
    # 将目录所有权交给当前用户
    sudo chown $(id -u):$(id -g) "$XDG_RUNTIME_DIR"
    # Wayland 强制要求该目录权限必须是 0700，否则会拒绝启动
    sudo chmod 0700 "$XDG_RUNTIME_DIR"

    # 将 tty 设备开放权限，解决普通用户下 Xorg headless (dummy) 无法访问 /dev/tty0 初始化导致的错误
    # 由于我们在 Docker 内并没有实体键盘连接真实的 TTY 显示器，且已经设置了 -sharevts 参数，放开权限也是安全的。
    if [ -c /dev/tty0 ]; then
        sudo chmod 666 /dev/tty0
    fi
    if [ -c /dev/tty7 ]; then
        sudo chmod 666 /dev/tty7
    fi

    # 1. 动态配置 /dev/uinput 权限
    if [ -c /dev/uinput ]; then
        sudo chmod 666 /dev/uinput
    fi

    # 启动 udevd 以支持热插拔输入设备 (Wayland/libinput 需要)
    # if command -v systemd-udevd >/dev/null 2>&1; then
    #     sudo /lib/systemd/systemd-udevd --daemon
    # elif command -v udevd >/dev/null 2>&1; then
    #     sudo udevd --daemon
    # fi

    echo "[Init] Starting seatd daemon..."
    # 使用 sudo 启动 seatd，绑定给 video 组（appuser 所在的组）
    # 默认创建 socket 位于 /run/seatd.sock
    sudo seatd -g video &
    
    # 将 socket 路径告诉未来的 Wayland 进程 (如 Sway)
    export SEATD_SOCK=/run/seatd.sock
    
    # 给 seatd 一点时间启动并建立 socket
    sleep 1
    sudo chmod 777 /run/seatd.sock
fi


# 4. 启动你的主程序 webscreen
echo "[Init] Starting webscreen on port $PORT..."
# exec 替换当前 shell 进程，接收停止信号
exec ./webscreen -port "${PORT}" -pin "${PIN}"