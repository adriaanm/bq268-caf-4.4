# BQ268 CAF 4.4 — MSM8909 port from 3.18
# Phase 0: repo setup, toolchain verification

toolchain := "/opt/toolchains/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf/bin/arm-linux-gnueabihf-"
out := "output"
mkbootimg := "tools/mkbootimg/mkbootimg.py"
defconfig := "msm8909_defconfig"
cmdline := "androidboot.hardware=qcom msm_rtb.filter=0x237 ehci-hcd.park=3 androidboot.bootdevice=7824900.sdhci lpm_levels.sleep_disabled=1 earlyprintk panic=5 ramoops.mem_address=0x9ff00000 ramoops.mem_size=0x40000 ramoops.console_size=0x20000 ramoops.record_size=0x10000 ramoops.pmsg_size=0x10000 console=tty0 console=ttyHSL0,115200 fbcon=rotate:3 consoleblank=0 root=/dev/mmcblk0p36 rootfstype=ext4 rootwait rw"
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

# assemble boot.img from existing build artifacts
bootimg-assemble:
    cat {{out}}/zImage {{out}}/msm8909-bq268.dtb > {{out}}/zImage-dtb
    python3 {{mkbootimg}} {{out}}/zImage-dtb /dev/null /dev/null {{out}}/boot.img "{{cmdline}}"
    cp {{out}}/boot.img {{out}}/boot-$(git rev-parse --short HEAD).img
    @ls -lh {{out}}/boot-$(git rev-parse --short HEAD).img

# full build: kernel + boot.img (no initramfs)
bootimg: build bootimg-assemble

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
    for i in $(seq 1 30); do
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
    bash scripts/serial-cmd.sh "{{cmd}}" "{{timeout}}"

# reboot device into fastboot via serial console
dev-reboot:
    #!/usr/bin/env bash
    if [ ! -e "{{serial_tty}}" ]; then
        echo "No serial device — already in fastboot?"
        exit 0
    fi
    stty -F "{{serial_tty}}" 115200 raw -echo -echoe -echok
    echo "Sending reboot-bootloader..."
    printf 'reboot-bootloader\n' > "{{serial_tty}}"
    sleep 3
    if [ -e "{{serial_tty}}" ]; then
        echo "WARNING: serial still present, device may not have rebooted"
        exit 1
    fi
    echo "Device rebooting to fastboot..."
    just wait-fastboot

# ── Iteration cycle ────────────────────────────────────

# full cycle: build → boot → wait for serial → grab dmesg
cycle: bootimg
    #!/usr/bin/env bash
    echo "=== Booting device ==="
    just boot
    just wait-serial
    echo "=== Device booted, grabbing dmesg ==="
    just serial "dmesg" "15" | tee {{out}}/dmesg-$(git rev-parse --short HEAD).txt
    echo "=== dmesg saved to {{out}}/dmesg-$(git rev-parse --short HEAD).txt ==="

# reboot device and start a new cycle
recycle:
    just dev-reboot
    just cycle

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

# clean build output
clean:
    rm -rf {{out}}
