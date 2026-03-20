#!/bin/bash
# Build minimal initramfs with busybox + USB serial console
# Output: output/initramfs.cpio.gz
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUT="$ROOT_DIR/output"
INITRAMFS="$OUT/initramfs"
BUSYBOX_APK="$ROOT_DIR/tools/usb-test-init/busybox-static.apk"

echo "=== Building minimal initramfs ==="

mkdir -p "$OUT"

# --- Build initramfs directory ---
echo "Creating initramfs layout..."
rm -rf "$INITRAMFS"
mkdir -p "$INITRAMFS"/{bin,sbin,dev,proc,sys,tmp,etc,lib/modules}
mkdir -p "$INITRAMFS/sys/kernel/config"

# Static device nodes needed before devtmpfs mounts
sudo mknod "$INITRAMFS/dev/console" c 5 1
sudo mknod "$INITRAMFS/dev/null" c 1 3
sudo chmod 622 "$INITRAMFS/dev/console"
sudo chmod 666 "$INITRAMFS/dev/null"

# Extract busybox binary
echo "Extracting busybox..."
gzip -dc "$BUSYBOX_APK" | tar xf - -C "$OUT" bin/busybox.static 2>/dev/null
cp "$OUT/bin/busybox.static" "$INITRAMFS/bin/busybox"
chmod 755 "$INITRAMFS/bin/busybox"

# Create busybox symlinks
echo "Creating busybox applet symlinks..."
for applet in sh ash ls cat echo mkdir mount umount sleep \
    cp mv rm ln chmod chown grep sed awk cut head tail \
    ps kill dmesg reboot poweroff halt \
    ifconfig ip route ping \
    insmod rmmod lsmod modprobe modinfo \
    vi less more wc sort uniq tr tee \
    devmem hexdump dd free uptime hostname \
    find xargs printf test expr seq \
    tar gzip gunzip df du stat id whoami \
    setsid cttyhack; do
    ln -sf busybox "$INITRAMFS/bin/$applet"
done

# /init
cp "$ROOT_DIR/rootfs/init" "$INITRAMFS/init"
chmod 755 "$INITRAMFS/init"

# /etc/profile
cat > "$INITRAMFS/etc/profile" << 'PROF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='bq268# '
alias ll='ls -la'
alias log='dmesg | tail -40'
PROF

# --- Pack cpio ---
echo "Packing initramfs..."
cd "$INITRAMFS"
find . | cpio -o -H newc 2>/dev/null | gzip > "$OUT/initramfs.cpio.gz"
echo "Built: $OUT/initramfs.cpio.gz ($(du -h "$OUT/initramfs.cpio.gz" | cut -f1))"
