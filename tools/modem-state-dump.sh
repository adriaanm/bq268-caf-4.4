#!/bin/sh
# Dump SMD/SMSM/IPC Router state for 3.18 vs 4.4 comparison.
# Run on device after modem is booted:
#   sleep 999999 < /dev/subsys_modem &
#   sleep 20  # wait for modem to init
#   sh /tmp/modem-state-dump.sh > /tmp/modem-state.txt 2>&1

echo "=== KERNEL VERSION ==="
uname -r

echo ""
echo "=== SMD CHANNELS ==="
cat /sys/kernel/debug/smd/ch 2>/dev/null || echo "(not available)"

echo ""
echo "=== SMSM STATE ==="
cat /sys/kernel/debug/smsm/state 2>/dev/null || echo "(not available)"

echo ""
echo "=== SMSM INTR MASK ==="
cat /sys/kernel/debug/smsm/intr_mask 2>/dev/null || echo "(not available)"

echo ""
echo "=== IPC ROUTER SERVERS ==="
cat /sys/kernel/debug/msm_ipc_router/dump_servers 2>/dev/null || echo "(not available)"

echo ""
echo "=== IPC ROUTER XPRT INFO ==="
cat /sys/kernel/debug/msm_ipc_router/dump_xprt_info 2>/dev/null || echo "(not available)"

echo ""
echo "=== IPC ROUTER REMOTE PORTS ==="
cat /sys/kernel/debug/msm_ipc_router/dump_remote_ports 2>/dev/null || echo "(not available)"

echo ""
echo "=== SUBSYS STATE ==="
for f in /sys/bus/msm_subsys/devices/subsys*/name; do
    dir=$(dirname "$f")
    name=$(cat "$f" 2>/dev/null)
    state=$(cat "$dir/state" 2>/dev/null)
    echo "$name: $state"
done

echo ""
echo "=== DIAG SMD CHANNELS ==="
ls /dev/diag 2>/dev/null && echo "diag device exists" || echo "no /dev/diag"

echo ""
echo "=== SMD PKT DEVICES ==="
ls /dev/smd* 2>/dev/null || echo "no smd_pkt devices"

echo ""
echo "=== SMD TTY DEVICES ==="
ls /dev/smd_tty* 2>/dev/null || echo "no smd_tty devices (may be /dev/ttyHSL*)"
ls /dev/ttyHSL* 2>/dev/null || true

echo ""
echo "=== DMESG MODEM LINES ==="
dmesg | grep -iE 'modem|pil|subsys|smd.*open|smd.*close|apr|qmi|diag|smd_pkt|bam_dmux|memshare|smsm' | tail -100

echo ""
echo "=== DONE ==="
