// brunch-lnl: neutralize crosvm's stale embedded seccomp filters for ARCVM.
//
// The ChromeOS crosvm binary embeds pre-compiled seccomp BPFs generated at
// build time for the volteer image. On Lunar Lake / recent ChromeOS these lag
// crosvm's own tube code and SIGSYS-kill the virtio-fs and virtio-gpu device
// worker processes on recvfrom/recvmsg -- the tube's primary syscalls --
// tearing ARCVM down before the Play Store can start. Neither
// --seccomp-policy-dir nor --seccomp-log-failures takes over these workers in
// the shipped build, and --disable-sandbox is not usable because virtio-fs
// needs minijail's namespace setup.
//
// Preloaded into crosvm (ARCVM and termina) by 87-arcvm_seccomp.sh, this turns
// *only* the seccomp filter installation into a no-op: minijail's namespace,
// mount, ugid-map, capability and rlimit jailing all run untouched. Only the
// syscall filter is dropped -- the same trade the previous maximally-permissive
// policy approach made, done in the one place that actually sticks. termina
// needs it too: its virtio-wl worker dies on recvfrom the moment a GUI app
// connects through sommelier, tearing the VM down.
//
// Two mojo capability probes (mojo/core/channel_linux.cc) call memfd_create
// and eventfd2 with a bogus ~0 flag and PCHECK that the failure is one of
// EINVAL/ENOSYS/EPERM -- EPERM being the "seccomp rejected it" outcome they
// normally observe. With the filter gone the kernel actually runs the probe
// and can return EAGAIN (the MFD_HUGETLB path), which would abort the device
// process; we normalize any unexpected failure on those two probes to EPERM.
//
// Forwarding uses a raw inline-asm syscall (never dlsym, which could re-enter
// this wrapper) and faithfully reproduces glibc's syscall() contract:
// -1 with errno set on failure.
//
// Build (see this directory's README.md):
//   gcc -O2 -fPIC -shared -Wall -o brunch-noseccomp-shim.so brunch-noseccomp-shim.c
#define _GNU_SOURCE
#include <errno.h>
#include <linux/seccomp.h>
#include <stdarg.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

static long raw_syscall(long n, long a, long b, long c, long d, long e, long f)
{
	long ret;
	register long r10 __asm__("r10") = d;
	register long r8 __asm__("r8") = e;
	register long r9 __asm__("r9") = f;
	__asm__ volatile("syscall"
	                 : "=a"(ret)
	                 : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
	                 : "rcx", "r11", "memory");
	return ret;
}

// Reproduce glibc's syscall() error contract: the kernel returns -errno in the
// [-4095, -1] band; translate that to -1 with errno set.
static long ret_errno(long ret)
{
	if ((unsigned long)ret > (unsigned long)-4096) {
		errno = (int)(-ret);
		return -1;
	}
	return ret;
}

int prctl(int option, ...)
{
	va_list ap;
	va_start(ap, option);
	long a = va_arg(ap, long);
	long b = va_arg(ap, long);
	long c = va_arg(ap, long);
	long d = va_arg(ap, long);
	va_end(ap);

	if (option == PR_SET_SECCOMP && a == SECCOMP_MODE_FILTER)
		return 0;
	return (int)ret_errno(raw_syscall(SYS_prctl, option, a, b, c, d, 0));
}

long syscall(long number, ...)
{
	va_list ap;
	va_start(ap, number);
	long a = va_arg(ap, long);
	long b = va_arg(ap, long);
	long c = va_arg(ap, long);
	long d = va_arg(ap, long);
	long e = va_arg(ap, long);
	long f = va_arg(ap, long);
	va_end(ap);

	if (number == SYS_seccomp && a == SECCOMP_SET_MODE_FILTER)
		return 0;
	if (number == SYS_prctl && a == PR_SET_SECCOMP && b == SECCOMP_MODE_FILTER)
		return 0;

	long ret = raw_syscall(number, a, b, c, d, e, f);

	if ((number == SYS_memfd_create || number == SYS_eventfd2) &&
	    (unsigned long)ret > (unsigned long)-4096) {
		long err = -ret;
		if (err != EINVAL && err != ENOSYS && err != EPERM) {
			errno = EPERM;
			return -1;
		}
	}
	return ret_errno(ret);
}
