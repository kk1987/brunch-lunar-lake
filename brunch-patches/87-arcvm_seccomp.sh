# Neutralize the stale crosvm seccomp filters that kill ARCVM on Lunar Lake.
#
# The ChromeOS crosvm binary embeds pre-compiled seccomp BPFs built for the
# volteer image. They lag crosvm's own tube code and SIGSYS-kill the virtio-fs
# and virtio-gpu device workers on recvfrom/recvmsg, tearing ARCVM down before
# the Play Store can start. --seccomp-policy-dir does not override these
# embedded filters for the device workers in the shipped build, and
# --disable-sandbox is unusable because virtio-fs needs minijail's namespaces.
#
# This preloads brunch-noseccomp-shim.so into crosvm for ARCVM `run` only,
# which turns the seccomp filter installation into a no-op while leaving every
# other minijail jailing (namespaces, ugid map, caps, rlimits) intact. termina
# is never wrapped and keeps its stock sandbox. See arcvm-noseccomp/ for the
# shim source and rationale.
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

	# Install the preload shim.
	mkdir -p /roota/usr/lib64
	tar zxf /rootc/packages/arcvm-noseccomp-shim.tar.gz -C /roota/usr/lib64
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi
	chmod 0644 /roota/usr/lib64/brunch-noseccomp-shim.so
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi

	# Wrap the crosvm binary so ARCVM `run` gets the shim preloaded. Idempotent:
	# the real binary is moved aside to crosvm.bin only once (rebuild starts from
	# a clean ROOT so crosvm.bin normally does not exist yet).
	if [ ! -f /roota/usr/bin/crosvm.bin ]; then
		mv /roota/usr/bin/crosvm /roota/usr/bin/crosvm.bin
		if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 2))); fi
	fi
	cat > /roota/usr/bin/crosvm <<'CROSVMWRAP'
#!/bin/bash
# brunch-lnl: preload the no-seccomp shim for ARCVM only (see brunch
# 87-arcvm_seccomp.sh). The embedded seccomp BPFs SIGSYS-kill ARCVM device
# workers on recvfrom/recvmsg; the shim no-ops filter installation while
# keeping minijail's namespace/caps jailing. termina keeps its stock sandbox.
arcvm=0
for a in "$@"; do
  case "$a" in ARCVM*) arcvm=1 ;; esac
done
if [[ $arcvm == 1 ]]; then
  export LD_PRELOAD="/usr/lib64/brunch-noseccomp-shim.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec /usr/bin/crosvm.bin "$@"
CROSVMWRAP
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 3))); fi
	chmod 0755 /roota/usr/bin/crosvm
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 4))); fi
fi
exit $ret
