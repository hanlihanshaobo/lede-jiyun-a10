/*
 * rboot - reboot into a Rockchip boot mode.
 *
 * The mode string is handed to the kernel via reboot(RESTART2, mode).  The
 * syscon-reboot-mode driver matches it against the mode-* properties in the
 * PMU GRF reboot-mode node and writes the corresponding magic value; the
 * stock RK U-Boot reads that register on the next boot.
 *
 * Supported modes (must exist in the DTS reboot-mode node):
 *   normal, loader, bootloader, maskrom, recovery, fastboot, ums
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

static const char *modes[] = {
	"normal", "loader", "bootloader", "maskrom",
	"recovery", "fastboot", "ums", NULL
};

static void usage(const char *prog)
{
	fprintf(stderr, "usage: %s <normal|loader|maskrom|recovery|fastboot|ums>\n", prog);
}

int main(int argc, char **argv)
{
	const char *mode;
	int i;

	if (argc != 2) {
		usage(argv[0]);
		return 1;
	}
	mode = argv[1];

	for (i = 0; modes[i]; i++) {
		if (!strcmp(mode, modes[i]))
			break;
	}
	if (!modes[i]) {
		fprintf(stderr, "%s: unknown boot mode '%s'\n", argv[0], mode);
		usage(argv[0]);
		return 1;
	}

	sync();

	/* RESTART2 carries the command string to the reboot notifiers. */
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, mode);

	fprintf(stderr, "%s: reboot(%s) failed: %s\n", argv[0], mode,
		strerror(errno));
	return 1;
}
