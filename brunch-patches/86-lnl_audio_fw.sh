# Install Intel SOF IPC4 audio DSP firmware for Lunar Lake.
#
# ChromeOS recovery images only ship SOF IPC3 firmware (intel/sof) for the
# platforms Chromebooks actually used; Lunar Lake audio needs the IPC4 set
# (intel/sof-ipc4/lnl + sof-ipc4-lib/lnl + sof-ipc4-tplg) which is absent,
# leaving snd-sof-pci-intel-lnl without firmware (no sound at all).
# Firmware files come from upstream linux-firmware (zstd-compressed, the
# brunch kernels enable CONFIG_FW_LOADER_COMPRESS_ZSTD).
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
