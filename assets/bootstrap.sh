#!/system/bin/sh
# bootstrap.sh - Xây dựng rootfs Termux-style

ROOTFS_DIR="/data/data/com.yourcompany.tunnel_controller/files/rootfs"
TMP_DIR="/data/local/tmp"

echo "📦 Starting Termux-style bootstrap..."

# Tạo thư mục rootfs
mkdir -p "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR/bin"
mkdir -p "$ROOTFS_DIR/lib"
mkdir -p "$ROOTFS_DIR/etc"
mkdir -p "$ROOTFS_DIR/tmp"
mkdir -p "$ROOTFS_DIR/proc"
mkdir -p "$ROOTFS_DIR/dev"
mkdir -p "$ROOTFS_DIR/root"
mkdir -p "$ROOTFS_DIR/usr/bin"
mkdir -p "$ROOTFS_DIR/usr/lib"

# Tạo /etc/resolv.conf
echo "nameserver 1.1.1.1" > "$ROOTFS_DIR/etc/resolv.conf"
echo "nameserver 8.8.8.8" >> "$ROOTFS_DIR/etc/resolv.conf"
echo "127.0.0.1 localhost" > "$ROOTFS_DIR/etc/hosts"

# Copy busybox (static binary) để có shell và các công cụ cơ bản
# Nếu chưa có busybox, thử tải từ Termux
BUSYBOX_PATH="/data/data/com.termux/files/usr/bin/busybox"
if [ -f "$BUSYBOX_PATH" ]; then
    cp "$BUSYBOX_PATH" "$ROOTFS_DIR/bin/busybox"
else
    # Nếu không có Termux, dùng busybox từ assets
    cp /data/data/com.yourcompany.tunnel_controller/files/busybox "$ROOTFS_DIR/bin/busybox" 2>/dev/null || echo "⚠️ Busybox not found"
fi

# Nếu busybox có sẵn, tạo symlinks
if [ -f "$ROOTFS_DIR/bin/busybox" ]; then
    chmod 755 "$ROOTFS_DIR/bin/busybox"
    cd "$ROOTFS_DIR/bin"
    ./busybox --list | while read cmd; do
        ln -sf busybox "$cmd"
    done
    cd -
    echo "✅ Busybox installed with symlinks"
fi

# Tạo /bin/sh symlink
if [ -f "$ROOTFS_DIR/bin/sh" ]; then
    echo "✅ /bin/sh exists"
else
    # Thử copy sh từ hệ thống
    if [ -f "/system/bin/sh" ]; then
        cp "/system/bin/sh" "$ROOTFS_DIR/bin/sh"
        chmod 755 "$ROOTFS_DIR/bin/sh"
        echo "✅ /bin/sh copied from /system/bin/sh"
    fi
fi

# Tạo thư mục lib và copy các thư viện cần thiết
cp /data/data/com.yourcompany.tunnel_controller/files/libtalloc.so "$ROOTFS_DIR/lib/libtalloc.so" 2>/dev/null || echo "⚠️ libtalloc not found"
cp /data/data/com.yourcompany.tunnel_controller/files/libandroid-shmem.so "$ROOTFS_DIR/lib/libandroid-shmem.so" 2>/dev/null || echo "⚠️ libandroid-shmem not found"

# Tạo script run-in-rootfs
cat > "/data/data/com.yourcompany.tunnel_controller/files/run-in-rootfs.sh" << 'EOF'
#!/system/bin/sh
PROOT="/data/data/com.yourcompany.tunnel_controller/files/proot"
ROOTFS="/data/data/com.yourcompany.tunnel_controller/files/rootfs"
LOADER="/data/data/com.yourcompany.tunnel_controller/files/proot_loader"
TMPDIR="/data/local/tmp"
export PROOT_TMP_DIR="$TMPDIR"
export PROOT_UNBUNDLE_LOADER="$LOADER"
export PROOT_NO_SECCOMP=1
export LD_LIBRARY_PATH="/lib:/data/data/com.yourcompany.tunnel_controller/files:/system/lib64:/vendor/lib64"
export PATH="/usr/bin:/bin:/system/bin:/system/xbin:/vendor/bin"
export TMPDIR="$TMPDIR"

$PROOT \
    -r "$ROOTFS" \
    -b /system:/system \
    -b /vendor:/vendor \
    -b /proc:/proc \
    -b /dev:/dev \
    -b "$TMPDIR:/tmp" \
    -w /root \
    /bin/sh -c "$@"
EOF
chmod 755 "/data/data/com.yourcompany.tunnel_controller/files/run-in-rootfs.sh"

echo "✅ Bootstrap completed! Rootfs at $ROOTFS_DIR"
