# Install the Mesa 25.3.6 graphics stack override for Intel Lunar Lake (Xe2) GPUs.
#
# ChromeOS ships Mesa < 25.2.0 which does not support Lunar Lake (iris lacks
# I915_FORMAT_MOD_4_TILED_LNL_CCS, minigbm has no xe backend). This installs:
# - libgallium (iris) / libEGL_mesa / libvulkan_intel (ANV) from Mesa 25.3.6
# - a Mesa libgbm carrying the minigbm ABI translation layer (flag encoding,
#   private symbol shims, gbm_bo_import type remap 0x5505->0x5504)
# - bundled libstdc++ / libdisplay-info (ANV deps absent from ChromeOS)
# and sets the chrome flags required for the GL/iris compositing path.
#
# Applied automatically when a Lunar Lake iGPU is detected on the PCI bus.
# The option "lnl_mesa" forces it on, "no_lnl_mesa" forces it off.

lnl_mesa=0

# Lunar Lake iGPU PCI device ids (vendor 0x8086)
for dev in /sys/bus/pci/devices/*; do
	[ -f "$dev/vendor" ] || continue
	if [ "$(cat "$dev/vendor")" == "0x8086" ]; then
		case "$(cat "$dev/device")" in
			0x6420|0x64a0|0x64b0) lnl_mesa=1 ;;
		esac
	fi
done

for i in $(echo "$1" | sed 's#,# #g')
do
	if [ "$i" == "lnl_mesa" ]; then lnl_mesa=1; fi
	if [ "$i" == "no_lnl_mesa" ]; then lnl_mesa=0; fi
done

ret=0
if [ "$lnl_mesa" -eq 1 ]; then
	echo "brunch: $0 lnl_mesa enabled" > /dev/kmsg
	tar zxf /rootc/packages/mesa-lnl.tar.gz -C /roota
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi
	# ChromeOS defaults to ANGLE-on-Vulkan; on this stack that path fails to bring
	# up a GPU context and chrome falls back to software compositing (FATAL).
	# --use-angle=gl routes ANGLE through native GL (iris) instead.
	#
	# If you need to debug the graphics stack, append to /etc/chrome_dev.conf:
	#   --enable-logging=stderr --v=1 --disable-logging-redirect
	# --disable-logging-redirect is mandatory alongside --enable-logging=stderr:
	# with stderr logging chrome never opens a post-login log file, but the
	# session log redirect path still calls fileno() on the NULL log handle and
	# the browser process segfaults on every login (including guest).
	# --disable-gpu-sandbox is required: inside the sandbox Mesa 25.3.6 cannot
	# bring up EGL (ui.LATEST: "Display::initialize error 12289: Failed to get
	# system egl display") and chrome crash-loops before login. 82-features.sh's
	# --gpu-sandbox-failures-fatal=no does not cover this: it tolerates sandbox
	# *setup* failures, not EGL failing inside an established sandbox.
	cat >>/roota/etc/chrome_dev.conf <<CHROMEFLAGS

# mesa-lnl (Lunar Lake): force ANGLE on native GL (iris), see brunch 85-mesa_lnl.sh
--use-angle=gl
--use-cmd-decoder=passthrough
--ignore-gpu-blocklist
--disable-gpu-sandbox
CHROMEFLAGS
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi
fi
exit $ret
