# brunch-unstable — Intel Lunar Lake (Xe2) fork

A fork of [sebanc/brunch-unstable](https://github.com/sebanc/brunch-unstable) for recent
Intel laptops that upstream brunch cannot run:

| platform | what this fork provides | tested |
|---|---|---|
| **Lunar Lake** (Core Ultra 200V, Xe2) | 7.1 kernel, Mesa 25.3.6 graphics, ARCVM fixes, SOF audio firmware | yes, one machine |
| **Meteor Lake** (Core Ultra 100), **Arrow Lake** (Core Ultra 200H / U / S) | 7.1 kernel, SOF audio firmware — graphics already work with the ChromeOS image's own Mesa | no |

Everyone else is better served by upstream brunch.

**Status on Lunar Lake: it works.** OOBE, login, reboot, re-login, Play Store, Android
apps and games, Crostini, audio and suspend all run on the reference machine, an
**HP OmniBook X Flip** (Core Ultra 9 288V, Xe2 `8086:64A0`), with the **ChromeOS R149,
R150 and R151 volteer** recovery images. Other Lunar Lake machines should work — the
Lunar Lake patches key off the iGPU PCI id (`8086:6420`, `8086:64a0`, `8086:64b0`), not
off the laptop model — but none has been tried. See *Known limitations*.

## Why upstream brunch does not run here

Upstream ships kernels 6.6 / 6.12 (plus an experimental 6.18) and the graphics userspace
inside the ChromeOS recovery image. Neither knows about Lunar Lake: the image carries Mesa older than
25.2 (iris has no `I915_FORMAT_MOD_4_TILED_LNL_CCS`, minigbm has no `xe` backend), and
brunch's kernel configs disable the Intel IOMMU, without which these machines do not
boot. On all three platforms, no ChromeOS image carries IPC4 audio firmware recent and
complete enough to give sound (see *Audio firmware*).

## Installing

Install as with upstream brunch and pick `7.1` in `brunch-setup` — release builds ship
only that kernel, so it is the only entry. The patches activate on their own by iGPU
PCI id; these options override them:

| option | patch | default |
|---|---|---|
| `no_lnl_mesa` / `lnl_mesa` | Mesa override (`85-mesa_lnl.sh`) | on for Lunar Lake |
| `no_sof_firmware` / `sof_firmware` | SOF firmware (`86-intel_sof_fw.sh`) | on for Lunar / Meteor / Arrow Lake |
| `no_arcvm_seccomp` / `arcvm_seccomp` | crosvm seccomp shim (`87-arcvm_seccomp.sh`) | on for Lunar Lake |

`no_lnl_audio_fw` / `lnl_audio_fw`, the names the firmware patch had while it covered only
Lunar Lake, still work.

## What this fork adds

### 7.1 kernel (`kernel-patches/7.1/`, `kernel-patches/7.1_*config`)

No ChromiumOS 7.1 branch exists, so this kernel is built from a **vanilla kernel.org
tree**, with its config assembled from a vendored Arch Linux baseline
(`7.1_base_config`), brunch's `brunch_configs` and the additions in
`7.1_extra_configs`. Besides the forward-ported brunch patches it carries four
ChromeOS kernel behaviours that ChromeOS userspace depends on:

| patch | why |
|---|---|
| `mglru_sysfs_admin.patch` | `vm_concierge` writes the CrOS-private MGLRU sysfs admin interface. Without it concierge dies at startup, no VM starts, and chrome takes a SIGSEGV at login. |
| `dm_verity_chromeos_table.patch` | `imageloader` mounts DLCs with a CrOS-private dm-verity table format (`payload=`/`hashtree=`/`alg=`/…). Without it every DLC mount fails — Crostini reports "error downloading", cras noise cancellation retries forever. |
| `drm_master_relax.patch` | ChromeOS relies on relaxed DRM master handover between frecon and chrome. |
| `kvm_honor_guest_pat.patch` | See *ARCVM graphics*. |

Config changes worth knowing (all commented in `7.1_extra_configs`): the Intel IOMMU is
re-enabled, because firmware that hands the CPU over in locked x2APIC mode panics the
kernel before any console exists unless DMAR interrupt remapping is available; and the
boot console uses sysfb/simpledrm instead of efifb, which on these machines maps the
framebuffer uncached and takes seconds per printk line.

### External drivers (`external-drivers/`)

Upstream builds its 13 out-of-tree modules (Realtek Wi-Fi, broadcom-wl, acpi_call, ipts,
ithc) only for 6.6 / 6.12. They are ported to 7.1: kbuild dropping `EXTRA_CFLAGS`, the
`del_timer*` / `from_timer` removals, the 6.14 `link_id` and 6.17 `radio_idx` cfg80211
arguments, 7.1's `struct wireless_dev *` in the key/station ops, and 7.1 hiding the
pppoe flexible-array members. Where an active upstream already had the fixes, the copy
was synced to it (rtl8192eu → Mange, rtl8812au / rtl8821cu → morrownr, rtl885xxx →
morrownr/rtw89); provenance is in the commit messages. The changes are version-guarded
or version-neutral, so 6.6 / 6.12 still build, but CI no longer builds them — run a
`BRUNCH_KERNELS="6.6 6.12 7.1"` build before sending any of it upstream. They are
compile-tested only.

### Mesa 25.3.6 (`mesa-patches/`, `packages/mesa-lnl.tar.gz`, `85-mesa_lnl.sh`)

Replaces libgallium (iris), libEGL, libvulkan_intel (ANV) and **libgbm** in the running
image. libgbm is the awkward one: on ChromeOS `libgbm.so.1` *is* minigbm, and Chrome,
crosvm, virglrenderer and libcros_camera are compiled against minigbm's `gbm.h`, which
is not ABI-compatible with Mesa's. `mesa-patches/` carries the shim that bridges the two;
[`mesa-patches/README.md`](mesa-patches/README.md) documents each patch, the bug it
fixes and how it was measured. The package rebuilds from a pristine
`mesa-25.3.6.tar.xz`, the six patches and `brunch_minigbm_compat.c` with no
differences (`diff -rq`).

### ARCVM graphics

Three bugs, all upstream rather than brunch ones, had to be fixed before Android apps
rendered correctly:

1. **venus fences never complete** → SurfaceFlinger hangs, Play Store restart-loops.
   KVM's `KVM_X86_QUIRK_IGNORE_GUEST_PAT` forces write-back, so the guest's
   write-combining mappings never see host fence writes. QEMU has
   `-accel kvm,honor-guest-pat=on`; crosvm has no such switch, hence
   `kvm_honor_guest_pat.patch`.
2. **Stray geometry over an otherwise correct frame** — on Xe2, ANV drops `HOST_CACHED`
   for any exportable bo and hands out an uncached scanout PAT entry, while the importer
   maps the same memory write-back. Every buffer venus gives a guest is exportable.
   (`mesa-patches/0002`)
3. **Every ARC window rendered as vertical stripe noise** — ANV placing bos in
   compressed PAT memory, which is broken inside an ARCVM guest. (`mesa-patches/0006`)

`87-arcvm_seccomp.sh` additionally disables crosvm's seccomp filters. The crosvm binary
in the volteer image embeds pre-compiled BPFs that lag crosvm's own code: they SIGSYS-kill
the virtio-fs / virtio-gpu workers on `recvfrom` / `recvmsg` before the Play Store can
start, and kill termina's virtio-wl worker the moment a Crostini GUI app connects (the
terminal survives because vsh runs over vsock). `--seccomp-policy-dir` does not override
the embedded filters for device workers, so the patch preloads a shim
(`arcvm-noseccomp/`) into crosvm for ARCVM and termina that makes seccomp filter
installation a no-op and leaves the rest of the minijail sandbox — namespaces, ugid map,
caps, rlimits — intact.

### Audio firmware (`86-intel_sof_fw.sh`, `packages/intel-sof-fw.tar.gz`)

Lunar, Meteor and Arrow Lake are IPC4-only, and `snd-intel-dspcfg` picks SOF over the
legacy HDA driver whenever a machine has digital mics or SoundWire links — nearly every
laptop. brunch's Intel SOF files come only from the ChromeOS rootfs it builds against
(linux-firmware no longer carries any), and none of those is enough:

- the ChromeOS Flex (reven) rootfs used by CI has an old IPC4 set — SOF 2.12, March
  2025, as of R150 — without the newer topologies (`sof-lnl-dmic-*`, `sof-sdca-*`, …);
- a volteer recovery image has IPC3 only, so Lunar Lake has no sound;
- even a Meteor Lake Chromebook image (rex) does not help: it keeps its firmware in
  per-model directories (`intel/sof-ipc4/mtl/{community,karis}/`), its topologies in
  `intel/sof-ace-tplg`, and only the four topologies that board uses.

`86-intel_sof_fw.sh` therefore overlays, after `50-add_generic_firmwares.sh`,
`intel/sof-ipc4/{lnl,mtl,arl,arl-s}`, `intel/sof-ipc4-lib/lnl` and the whole
`intel/sof-ipc4-tplg` directory of
[sof-bin v2025.12.2](https://github.com/thesofproject/sof-bin/releases/tag/v2025.12.2)
(SOF 2.14.1), byte-for-byte as released. To regenerate the package:

```sh
curl -LO https://github.com/thesofproject/sof-bin/releases/download/v2025.12.2/sof-bin-2025.12.2.tar.gz
tar xzf sof-bin-2025.12.2.tar.gz
mkdir -p stage/lib/firmware/intel/sof-ipc4 stage/lib/firmware/intel/sof-ipc4-lib
for p in lnl mtl arl arl-s; do
    cp -a sof-bin-2025.12.2/sof-ipc4/"$p" stage/lib/firmware/intel/sof-ipc4/
done
cp -a sof-bin-2025.12.2/sof-ipc4-lib/lnl stage/lib/firmware/intel/sof-ipc4-lib/
cp -a sof-bin-2025.12.2/sof-ipc4-tplg    stage/lib/firmware/intel/
tar -C stage --sort=name -czf packages/intel-sof-fw.tar.gz lib --owner=0 --group=0
```

### SoundWire UCM profiles (`alsa-ucm-conf/ucm2/sof-soundwire/`)

Many recent Intel laptops connect their audio codecs over SoundWire instead of HDA:
a Cirrus Logic **cs42l43** headset codec with **cs35l56** amplifiers (the Meteor and
Arrow Lake Dell XPS models, for instance), or Realtek parts such as rt711 / rt712 /
rt722 with rt13xx amplifiers. The kernel registers these as the `sof-soundwire` card,
which probes fine and still produces no sound: the alsa-ucm-conf release brunch ships
must match ChromeOS's alsa-lib (1.2.8 through R151), and that release has no profile for
these codecs. Without a UCM, cras guesses its nodes from mixer control names, which on
these codecs are all prefixed, and ends up with a phantom "Speaker" on the headphone PCM.

The overlay adds cras profiles for the Cirrus combinations and for every Realtek
SoundWire part in the 7.1 Intel machine tables, written from the 7.1 drivers and the
upstream alsa-ucm-conf 1.2.16 profiles and parse-tested against alsa-lib 1.2.8. Other
cards keep the stock behaviour. The reference laptop has an HDA codec, so none of these
profiles has run on hardware. Details:
[`alsa-ucm-conf/ucm2/sof-soundwire/cras/README.md`](alsa-ucm-conf/ucm2/sof-soundwire/cras/README.md).

### `chromeos-update` (`99-updater.sh`)

`-r` no longer goes through a loop device: it copies the recovery image's ROOT-A
straight from the file at the offset `cgpt` reports, and marks the update as pending
only after the copy succeeded. Previously a failed copy still flipped the partition
priorities, and the next boot rebuilt ROOT-A from the stale ROOT-B. `-f` checks its
writes too.

## Meteor Lake and Arrow Lake

These need far less than Lunar Lake, because ChromeOS itself supports them. Both run on
**i915** (7.1's `xe` still marks them `require_force_probe`, and brunch sets
`CONFIG_DRM_I915_FORCE_PROBE="*"`), and the Mesa 24.2.3 in a volteer R149 image already
lists `Intel(R) Arc(tm) Graphics (MTL)` and `Intel(R) Graphics (ARL)`. So the Mesa
override stays off; do not force it with `lnl_mesa`, since its minigbm shim and chrome
flags were built and measured for Xe2 only. What carries over is the audio: the SOF
firmware patch triggers on their iGPU ids, and the SoundWire profiles are installed on
every machine.

Before trying it:

- **The IOMMU is enabled in this kernel**, as on Lunar Lake. Whether a machine needs it
  is a firmware property, not a generational one: `sudo rdmsr 0xBD` (msr-tools, from any
  Linux) with bit 0 set means legacy xAPIC is disabled and the IOMMU is required.
- **ARCVM may need `arcvm_seccomp`.** The stale crosvm filters belong to the ChromeOS
  image, not the CPU, but have only been observed on Lunar Lake, so the shim is gated on
  Lunar Lake ids. If ARCVM hangs at "Starting Play Store..." or Crostini dies when a GUI
  app opens, add the option.
- **If there is still no sound**, add `snd_intel_dspcfg.dsp_driver=1` to the kernel
  command line in GRUB. That forces the legacy HDA driver, which needs no firmware: a
  machine with an analog HDA codec gets speakers and headphones back, but not the
  digital mic array. A SoundWire-only machine has nothing to fall back to.

Nothing here has run on Meteor or Arrow Lake hardware. What is verified is that the
firmware and topologies ship and which iGPU ids enable the patch (tested against a
synthetic `/sys` tree).

## Building

Same as upstream:

```sh
./prepare_kernels.sh                       # downloads and patches the kernel trees
./build_kernels.sh                         # or ./build_kernels.sh 7.1 for just this one
sudo bash build_brunch.sh <recovery_image.bin>
```

`prepare_kernels.sh` prepares only `7.1` by default, and the CI kernel matrix follows
it, so releases are 7.1-only. `BRUNCH_KERNELS="6.6 6.12 6.18 7.1" ./prepare_kernels.sh`
gives a full upstream-style build; the `brunch-setup` kernel menu is generated from the
kernels the build actually ships.

GitHub Actions builds and publishes a release on every push
(`.github/workflows/build.yml`). Release kernels are signed with this fork's key; a fork
without the `BRUNCH_PRIV` / `BRUNCH_PEM` secrets produces **unsigned** kernels, which
boot fine but not under Secure Boot.

## Secure Boot

The chain is: Microsoft-signed Debian shim (`bootx64.efi`) → GRUB, signed by upstream
brunch's key → kernel, signed by **this fork's** key (upstream cannot share its private
key). Both certificates ship at the root of the EFI partition and both must be enrolled
in MOK:

- `brunch.der` — upstream's certificate, verifies GRUB
- `brunch-lnl.der` — this fork's certificate, verifies the kernels

Either from Linux:

```sh
sudo mokutil --import brunch.der
sudo mokutil --import brunch-lnl.der
```

or at the blue "Verification failed" screen on the first Secure Boot boot: OK → Enroll
key from disk → EFI-SYSTEM → select each `.der` in turn → Continue, reboot. With Secure
Boot disabled none of this matters.

## Known limitations

- **One machine.** Only the reference laptop has run this. The kernel config comes from
  an Arch baseline, so hardware Arch does not enable is not covered.
- **Meteor Lake, Arrow Lake and the SoundWire profiles are untested on hardware.**
  Reports help — for audio, the `cras` lines in `/var/log/messages` and
  `amixer -c0 controls`.
- **"Sign in with your Android phone" does not work** at OOBE; use a password. Not
  investigated, and not known to be Lunar Lake specific.
- **The Play Store can crash once after suspend/resume.** The VM survives; a venus GPU
  context can enter a fatal state on the first resume and the app using it is dropped.
  Re-opening it recovers. Timing-dependent and not reliably reproducible.
- `mesa-patches/0003` and `0004` hide the Xe2 CCS DRM modifiers from importers. They did
  not fix the stripe noise (`0006` did) but are kept, because a consumer built against a
  pre-Lunar Lake minigbm cannot interpret those modifiers.
- Log noise not chased down: `unknown rutabaga path` from crosvm, ~60 virglrenderer
  `GL error (1282)` lines during ARCVM startup, and NV12 128×128 `bo_create` failures
  believed to come from the ARC camera stack.

## Upstream bugs found here

- **Mesa/ANV** — `HOST_CACHED` dropped for exportable bos on Xe2 (`0002`).
- **Mesa/ANV** — bos in compressed PAT memory are corrupt inside a VM guest (`0006`).
  Only the location is established, not the mechanism: on the host, compression round
  trips cleanly in every test.
- **Mesa/ANV and Mesa/iris** — both advertise the Xe2 CCS modifiers to importers that
  cannot decode them, and each has its own modifier filter, so a fix in the shared ISL
  code reaches only ANV (`0003`, `0004`).
- **brunch** — `brunch-patches/82-features.sh:31` writes
  `--enable-hardware-overlays="single-fullscreen,single-on-top"`; the quotes end up
  inside the flag value, Chrome rejects both strategies (`overlay_strategy.cc`), and
  hardware overlays are silently off. Left as upstream wrote it.
- **brunch** — `chromeos-update -r` flips the partition priorities even when copying
  the recovery image failed (fixed here, see *`chromeos-update`*).

## Credit

All of brunch is [sebanc](https://github.com/sebanc)'s work; this fork only adds
platforms. Please send general brunch issues and pull requests upstream, and file
issues here only for what is specific to this fork.

The releases in this repository are experimental. Use at your own risk.
