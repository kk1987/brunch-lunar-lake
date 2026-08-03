# ARCVM no-seccomp shim

`brunch-noseccomp-shim.c` is an `LD_PRELOAD` shim that neutralizes the stale
embedded seccomp filters the ChromeOS crosvm binary installs on its device
workers. See the header comment in the source for the full rationale; in
short, those build-time BPFs SIGSYS-kill workers on recvfrom/recvmsg on
Lunar Lake (ARCVM: virtio-fs/gpu at startup; termina: virtio-wl as soon as a
GUI app connects through sommelier), and `--seccomp-policy-dir` does not
override them in the shipped build.

`87-arcvm_seccomp.sh` preloads it into crosvm for concierge-managed VMs
(ARCVM and termina, matched by their `ARCVM(n)`/`VM(n)` syslog tags), turning
just the seccomp filter installation into a no-op while leaving every other
minijail jailing (namespaces, ugid map, caps, rlimits) intact. It also normalizes the mojo `memfd_create`/`eventfd2` capability probes
that otherwise abort once the filter is gone.

## Rebuilding the package

The compiled shim ships in `../packages/arcvm-noseccomp-shim.tar.gz`. To rebuild
it from this source:

```sh
gcc -O2 -fPIC -shared -Wall -o brunch-noseccomp-shim.so brunch-noseccomp-shim.c
tar zcf ../packages/arcvm-noseccomp-shim.tar.gz brunch-noseccomp-shim.so --owner=0 --group=0
```

The shim only references glibc symbols up to `GLIBC_2.4` (verify with
`objdump -T brunch-noseccomp-shim.so`), so a host-built `.so` runs on the
ChromeOS glibc unchanged. It is architecture-specific x86_64 (raw `syscall`
inline asm).

## Testing

`objdump -T` for the symbol-version check above, plus a filter-installation
smoke test: preload the shim around a program that installs a getpid-blocking
seccomp filter and confirm getpid still succeeds (filter inert), that a normal
failing syscall still returns -1 with the right errno, and that
`memfd_create("", ~0)` / `eventfd2(0, ~0)` fail with EINVAL/ENOSYS/EPERM rather
than EAGAIN.
