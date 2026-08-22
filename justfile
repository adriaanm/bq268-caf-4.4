# BQ268 CAF 4.4 — MSM8909 port from 3.18
# Phase 0: repo setup, toolchain verification

toolchain := "/opt/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/bin/arm-linux-gnueabihf-"
out := "output"
mkbootimg := "tools/mkbootimg/mkbootimg.py"
defconfig := "msm8909_defconfig"
cmdline := "androidboot.hardware=qcom androidboot.bootdevice=7824900.sdhci earlyprintk panic=5 panic_on_oops=1 console=tty0 root=/dev/mmcblk0p36 rootfstype=ext4 rootwait rw quiet logo.nologo vt.global_cursor_default=0"
serial_tty := "/dev/ttyACM0"

kmake := "make ARCH=arm CROSS_COMPILE=" + toolchain + " O=" + out

# list recipes
default:
    @just --list

# ── Build ──────────────────────────────────────────────

# configure kernel from defconfig
defconfig:
    mkdir -p {{out}}
    {{kmake}} {{defconfig}}

# build kernel zImage and DTBs
build: defconfig
    {{kmake}} -j$(nproc) zImage dtbs 2>&1 | tee {{out}}/build.log
    @if ! grep -q "zImage is ready" {{out}}/build.log; then echo "BUILD FAILED"; exit 1; fi
    cp {{out}}/arch/arm/boot/zImage {{out}}/zImage
    cp {{out}}/arch/arm/boot/dts/msm8909-bq268.dtb {{out}}/msm8909-bq268.dtb
    @ls -lh {{out}}/zImage {{out}}/msm8909-bq268.dtb

# build kernel modules (wlan.ko etc.)
modules: defconfig
    {{kmake}} -j$(nproc) modules

# install modules to output/modules/ (for rootfs packaging)
modules-install: modules
    {{kmake}} INSTALL_MOD_PATH={{out}}/modules modules_install

# assemble boot.img from existing build artifacts
bootimg-assemble:
    cat {{out}}/zImage {{out}}/msm8909-bq268.dtb > {{out}}/zImage-dtb
    python3 {{mkbootimg}} {{out}}/zImage-dtb /dev/null /dev/null {{out}}/boot.img "{{cmdline}}"
    cp {{out}}/boot.img {{out}}/boot-$(git rev-parse --short HEAD).img
    @ls -lh {{out}}/boot-$(git rev-parse --short HEAD).img

# full build: kernel + modules + boot.img (no initramfs)
bootimg: build modules bootimg-assemble

# boot.img with initramfs (busybox shell on ttyGS0 via USB configfs ACM)
bootimg-initramfs: build
    bash scripts/build-initramfs.sh
    cat {{out}}/zImage {{out}}/msm8909-bq268.dtb > {{out}}/zImage-dtb
    python3 {{mkbootimg}} {{out}}/zImage-dtb {{out}}/initramfs.cpio.gz /dev/null {{out}}/boot.img "androidboot.hardware=qcom earlyprintk panic=5 console=tty0 console=ttyGS0 loglevel=7"
    cp {{out}}/boot.img {{out}}/boot-initramfs.img
    @ls -lh {{out}}/boot-initramfs.img

# build with GCC 4.9 (explicit)
bootimg-gcc: bootimg

# ── Device ─────────────────────────────────────────────

# boot image via fastboot (temporary, assumes device is already in fastboot)
boot:
    fastboot boot {{out}}/boot-$(git rev-parse --short HEAD).img

# flash boot image permanently (assumes device is already in fastboot)
flash:
    fastboot flash boot {{out}}/boot-$(git rev-parse --short HEAD).img
    fastboot reboot

# wait for device to boot and serial console to appear
wait-serial:
    #!/usr/bin/env bash
    echo "Waiting for {{serial_tty}}..."
    for i in $(seq 1 180); do
        if [ -e "{{serial_tty}}" ]; then
            sleep 2
            echo "Serial console ready on {{serial_tty}}"
            exit 0
        fi
        sleep 1
    done
    echo "TIMEOUT: {{serial_tty}} never appeared"
    exit 1

# wait for fastboot device
wait-fastboot:
    #!/usr/bin/env bash
    echo "Waiting for fastboot..."
    for i in $(seq 1 30); do
        if fastboot devices 2>/dev/null | grep -q .; then
            echo "Fastboot device ready"
            exit 0
        fi
        sleep 1
    done
    echo "TIMEOUT: no fastboot device"
    exit 1

# send command to device serial console, capture output
serial cmd timeout="5":
    python3 scripts/serial-cmd.sh "{{cmd}}" "{{timeout}}"

# reboot device into fastboot via serial console
# Direct: 4.4 reboot-bootloader writes IMEM magic + warm reset → fastboot
dev-reboot:
    #!/usr/bin/env bash
    if fastboot devices 2>/dev/null | grep -q .; then
        echo "Already in fastboot"
        exit 0
    fi
    if [ ! -e "{{serial_tty}}" ]; then
        echo "No serial device and no fastboot — manual intervention needed"
        exit 1
    fi
    echo "Rebooting to fastboot..."
    python3 scripts/serial-cmd.sh "/usr/local/bin/reboot-bootloader" "2" 2>/dev/null || true
    sleep 5
    just wait-fastboot

# ── Iteration cycle ────────────────────────────────────

# grab dmesg from device via serial
grab-dmesg:
    just serial "dmesg" "15" | tee {{out}}/dmesg-$(git rev-parse --short HEAD).txt
    @echo "=== dmesg saved to {{out}}/dmesg-$(git rev-parse --short HEAD).txt ==="

# ── Interactive ────────────────────────────────────────

# interactive menuconfig
menuconfig: defconfig
    {{kmake}} menuconfig

# ── Experiments & Tasks ────────────────────────────────

# show experiment log
experiments:
    git log --oneline --notes=experiments --notes=tasks

# note an experiment outcome on HEAD
note message:
    git notes --ref=experiments append HEAD -m "{{message}}"

# show current tasks
tasks:
    @git notes --ref=tasks show HEAD 2>/dev/null || echo "No tasks on HEAD"

# add a task
task-add description:
    #!/usr/bin/env bash
    existing=$(git notes --ref=tasks show HEAD 2>/dev/null || true)
    if [ -z "$existing" ]; then
        git notes --ref=tasks add HEAD -m "[todo] {{description}}"
    else
        printf '%s\n[todo] %s' "$existing" "{{description}}" | git notes --ref=tasks add -f -F - HEAD
    fi

# mark a task done
task-done pattern:
    #!/usr/bin/env bash
    existing=$(git notes --ref=tasks show HEAD 2>/dev/null || true)
    if [ -z "$existing" ]; then
        echo "No tasks on HEAD"; exit 1
    fi
    echo "$existing" | sed '/\[todo\].*{{pattern}}/s/\[todo\]/[done]/' | \
        sed '/\[in_progress\].*{{pattern}}/s/\[in_progress\]/[done]/' | \
        git notes --ref=tasks add -f -F - HEAD
    git notes --ref=tasks show HEAD

# mark a task in-progress
task-start pattern:
    #!/usr/bin/env bash
    existing=$(git notes --ref=tasks show HEAD 2>/dev/null || true)
    if [ -z "$existing" ]; then
        echo "No tasks on HEAD"; exit 1
    fi
    echo "$existing" | sed '/\[todo\].*{{pattern}}/s/\[todo\]/[in_progress]/' | \
        git notes --ref=tasks add -f -F - HEAD
    git notes --ref=tasks show HEAD

# ── Tools ─────────────────────────────────────────────

# build diag_read (DIAG F3 message reader) for ARM
diag-build:
    {{toolchain}}gcc -static -Wall -Wextra -Os -o tools/diag_read tools/diag_read.c
    {{toolchain}}strip tools/diag_read
    @ls -lh tools/diag_read

# deploy diag_read to device via SCP
diag-deploy: diag-build
    scp tools/diag_read bq268:/usr/local/bin/diag_read

# run diag_read on device for N seconds (default 60), capture output
diag-capture seconds="60":
    ssh bq268 '/usr/local/bin/diag_read {{seconds}}' | tee {{out}}/diag-$(date +%Y%m%d-%H%M%S).txt

# clean build output
clean:
    rm -rf {{out}}
