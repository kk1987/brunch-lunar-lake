# Install an up-to-date crosvm seccomp policy set for ARCVM on Lunar Lake.
#
# The R149 crosvm binary embeds volteer-era (i915) seccomp policies that predate
# glibc 2.41 / Mesa 25.3.6 and SIGSYS-kill crosvm worker processes on modern
# syscalls (fcntl F_DUPFD_QUERY, newfstatat, ...), tearing down ARCVM before the
# Play Store can start. This wraps /usr/bin/crosvm so every `run` invocation is
# given --seccomp-policy-dir pointing at a maximally-permissive allowlist
# (every syscall name the image libminijail recognizes), which keeps minijail's
# namespace/mount/caps jailing while dropping only the stale syscall filter.
#
# Applied automatically when a Lunar Lake iGPU is detected on the PCI bus.
# The option "arcvm_seccomp" forces it on, "no_arcvm_seccomp" forces it off.

arcvm_seccomp=0

# Lunar Lake iGPU PCI device ids (vendor 0x8086)
for dev in /sys/bus/pci/devices/*; do
	[ -f "$dev/vendor" ] || continue
	if [ "$(cat "$dev/vendor")" == "0x8086" ]; then
		case "$(cat "$dev/device")" in
			0x6420|0x64a0|0x64b0) arcvm_seccomp=1 ;;
		esac
	fi
done

for i in $(echo "$1" | sed 's#,# #g')
do
	if [ "$i" == "arcvm_seccomp" ]; then arcvm_seccomp=1; fi
	if [ "$i" == "no_arcvm_seccomp" ]; then arcvm_seccomp=0; fi
done

ret=0
if [ "$arcvm_seccomp" -eq 1 ]; then
	echo "brunch: $0 arcvm_seccomp enabled" > /dev/kmsg

	# Install the policy directory (crosvm/*.policy + constants.json + frequency).
	mkdir -p /roota/usr/share/policy
	tar zxf /rootc/packages/arcvm-seccomp-policy.tar.gz -C /roota/usr/share/policy
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

	# Wrap the crosvm binary so `run` gets --seccomp-policy-dir. Idempotent: the
	# real binary is moved aside to crosvm.bin only once (rebuild starts from a
	# clean ROOT so crosvm.bin normally does not exist yet).
	if [ ! -f /roota/usr/bin/crosvm.bin ]; then
		mv /roota/usr/bin/crosvm /roota/usr/bin/crosvm.bin
		if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi
	fi
	cat > /roota/usr/bin/crosvm <<'CROSVMWRAP'
#!/bin/bash
# brunch-lnl: inject an up-to-date seccomp policy dir for every crosvm `run`
# (see brunch 87-arcvm_seccomp.sh). The R149 embedded policies SIGSYS-kill
# workers on modern syscalls, which tears down ARCVM.
new=()
injected=0
for a in "$@"; do
  new+=("$a")
  if [[ "$a" == run && $injected == 0 ]]; then
    new+=(--seccomp-policy-dir /usr/share/policy/crosvm)
    injected=1
  fi
done
exec /usr/bin/crosvm.bin "${new[@]}"
CROSVMWRAP
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 2))); fi
	chmod 0755 /roota/usr/bin/crosvm
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 3))); fi
fi
exit $ret
