/*
 * reboot-bootloader.c — Reboot into fastboot/bootloader mode
 * Calls reboot(RESTART2, "bootloader") so the MSM restart handler
 * writes the IMEM magic (0x77665500) and does a warm reset.
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -static -o reboot-bootloader reboot-bootloader.c
 */
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>
#include <stdio.h>

int main(void)
{
	sync();
	syscall(__NR_reboot,
		LINUX_REBOOT_MAGIC1,
		LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2,
		"bootloader");
	perror("reboot");
	return 1;
}
