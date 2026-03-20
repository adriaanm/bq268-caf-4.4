/*
 * reboot-bootloader.c — Reboot into fastboot/bootloader mode
 *
 * Writes the IMEM magic (0x77665500) directly via /dev/mem, then
 * calls reboot(RESTART2, "bootloader"). This bypasses the PMIC PON
 * driver which may not be probed on 4.4.
 *
 * IMEM restart_reason is at physical 0x08600000 + 0x65c = 0x0860065c
 * (from msm8909.dtsi: qcom,msm-imem@8600000 / restart_reason@65c)
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -static -o reboot-bootloader reboot-bootloader.c
 */
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdint.h>

#define IMEM_BASE       0x08600000
#define RESTART_REASON  0x65c
#define BOOTLOADER_MAGIC 0x77665500
#define PAGE_SIZE       4096

int main(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}

	void *map = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE,
			 MAP_SHARED, fd, IMEM_BASE);
	if (map == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	volatile uint32_t *restart_reason =
		(volatile uint32_t *)((char *)map + RESTART_REASON);

	*restart_reason = BOOTLOADER_MAGIC;
	printf("Wrote 0x%08x to IMEM restart_reason\n", *restart_reason);

	munmap(map, PAGE_SIZE);
	close(fd);

	sync();
	syscall(__NR_reboot,
		LINUX_REBOOT_MAGIC1,
		LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2,
		"bootloader");
	perror("reboot");
	return 1;
}
