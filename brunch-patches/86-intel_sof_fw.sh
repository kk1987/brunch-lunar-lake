# Install Intel SOF IPC4 audio DSP firmware and topologies for the Intel platforms
# ChromeOS images have no usable firmware for: Lunar Lake, Meteor Lake and Arrow Lake.
#
# brunch's firmware package (packages/firmwares.tar.gz, unpacked over /lib/firmware
# by 50-add_generic_firmwares.sh) gets its Intel SOF files from exactly one place:
# the lib/firmware/intel/sof* directories of the ChromeOS rootfs build_brunch.sh
# builds against. linux-firmware no longer carries any Intel SOF file (its WHENCE
# lists none), so the linux-firmware checkout contributes nothing there. None of the
# ChromeOS rootfs variants is enough on these platforms, which are all IPC4-only:
#  - ChromeOS Flex (reven) rootfs, what CI builds use: ships an IPC4 set, but an old
#    one (SOF 2.12, March 2025, as of R150) with a thinner topology set (no
#    sof-lnl-dmic-*, sof-sdca-*, sof-ptl-*, ...).
#  - Chromebook recovery images built for an older platform (volteer, ...): IPC3 only
#    (intel/sof, intel/sof-tplg). No intel/sof-ipc4 at all, so no sound.
#  - Even a Meteor Lake Chromebook image (rex) does not help: ChromeOS keeps its
#    firmware in per-model directories (intel/sof-ipc4/mtl/{community,karis}/sof-mtl.ri
#    instead of the intel/sof-ipc4/mtl/sof-mtl.ri the driver asks for), keeps its
#    topologies in intel/sof-ace-tplg instead of intel/sof-ipc4-tplg, and ships only
#    the four topologies that board itself uses.
#
# packages/intel-sof-fw.tar.gz overlays a current sof-bin release on top:
# intel/sof-ipc4/{lnl,mtl,arl,arl-s}, intel/sof-ipc4-lib/lnl and the whole
# intel/sof-ipc4-tplg directory of sof-bin v2025.12.2 (SOF 2.14.1), uncompressed and
# byte-for-byte as released (that release carries no sof-ipc4-lib for mtl / arl, and
# arl reuses the mtl binary through symlinks). This runs after
# 50-add_generic_firmwares.sh, so these files replace the rootfs copy.
# README.md (Audio) records how to regenerate it.
#
# Applied automatically when a Lunar Lake, Meteor Lake or Arrow Lake iGPU is detected
# on the PCI bus. The option "sof_firmware" forces it on, "no_sof_firmware" forces it
# off; "lnl_audio_fw" / "no_lnl_audio_fw", the names this patch used while it only
# covered Lunar Lake, keep working.

sof_firmware=0

# Intel iGPU PCI device ids (vendor 0x8086), from INTEL_LNL_IDS / INTEL_MTL_IDS /
# INTEL_ARL_IDS in include/drm/intel/pciids.h.
for dev in /sys/bus/pci/devices/*; do
	[ -f "$dev/vendor" ] || continue
	if [ "$(cat "$dev/vendor")" == "0x8086" ]; then
		case "$(cat "$dev/device")" in
			# Lunar Lake
			0x6420|0x64a0|0x64b0) sof_firmware=1 ;;
			# Meteor Lake
			0x7d40|0x7d45|0x7d55|0x7d60|0x7dd5) sof_firmware=1 ;;
			# Arrow Lake (H, U and S)
			0x7d51|0x7dd1|0x7d41|0x7d67|0xb640) sof_firmware=1 ;;
		esac
	fi
done

for i in $(echo "$1" | sed 's#,# #g')
do
	if [ "$i" == "sof_firmware" ] || [ "$i" == "lnl_audio_fw" ]; then sof_firmware=1; fi
	if [ "$i" == "no_sof_firmware" ] || [ "$i" == "no_lnl_audio_fw" ]; then sof_firmware=0; fi
done

ret=0
if [ "$sof_firmware" -eq 1 ]; then
	echo "brunch: $0 sof_firmware enabled" > /dev/kmsg
	tar zxf /rootc/packages/intel-sof-fw.tar.gz -C /roota
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi
fi
exit $ret
