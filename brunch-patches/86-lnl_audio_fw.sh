# Install Intel SOF IPC4 audio DSP firmware and topologies for Lunar Lake.
#
# brunch's firmware package (packages/firmwares.tar.gz, unpacked over
# /lib/firmware by 50-add_generic_firmwares.sh) gets its Intel SOF files from
# exactly one place: the lib/firmware/intel/sof* directories of the ChromeOS
# rootfs build_brunch.sh builds against. linux-firmware no longer carries any
# Intel SOF file (its WHENCE lists none), so the linux-firmware checkout
# contributes nothing there. Two cases follow:
#  - ChromeOS Flex (reven) rootfs, what CI builds use: ships an IPC4 set, but
#    an old one (SOF 2.12, March 2025, as of R150) with a thinner topology
#    set (no sof-lnl-dmic-*, sof-sdca-*, sof-ptl-*, ...).
#  - Chromebook recovery images (volteer, ...): IPC3 only (intel/sof,
#    intel/sof-tplg). No intel/sof-ipc4 at all, snd-sof-pci-intel-lnl has
#    nothing to load, no sound.
#
# packages/lnl-audio-fw.tar.gz overlays a current sof-bin release on top:
# intel/sof-ipc4/lnl, intel/sof-ipc4-lib/lnl and the whole intel/sof-ipc4-tplg
# directory of sof-bin v2025.12.2 (SOF 2.14.1), uncompressed and byte-for-byte
# as released. This runs after 50-add_generic_firmwares.sh, so these files
# replace the rootfs copy. README.md (Audio) records how to regenerate it.
#
# Applied automatically when a Lunar Lake iGPU is detected on the PCI bus.
# The option "lnl_audio_fw" forces it on, "no_lnl_audio_fw" forces it off.

lnl_audio_fw=0

# Lunar Lake iGPU PCI device ids (vendor 0x8086)
for dev in /sys/bus/pci/devices/*; do
	[ -f "$dev/vendor" ] || continue
	if [ "$(cat "$dev/vendor")" == "0x8086" ]; then
		case "$(cat "$dev/device")" in
			0x6420|0x64a0|0x64b0) lnl_audio_fw=1 ;;
		esac
	fi
done

for i in $(echo "$1" | sed 's#,# #g')
do
	if [ "$i" == "lnl_audio_fw" ]; then lnl_audio_fw=1; fi
	if [ "$i" == "no_lnl_audio_fw" ]; then lnl_audio_fw=0; fi
done

ret=0
if [ "$lnl_audio_fw" -eq 1 ]; then
	echo "brunch: $0 lnl_audio_fw enabled" > /dev/kmsg
	tar zxf /rootc/packages/lnl-audio-fw.tar.gz -C /roota
	if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi
fi
exit $ret
