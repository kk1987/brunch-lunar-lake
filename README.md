# brunch-unstable — Intel Lunar Lake (Xe2) fork

A fork of [sebanc/brunch-unstable](https://github.com/sebanc/brunch-unstable) that adds
support for **Intel Lunar Lake** (Core Ultra 200V, Xe2 graphics) laptops.

Upstream brunch ships kernels 6.6 / 6.12 and the graphics userspace that comes inside
the ChromeOS recovery image. Neither knows about Lunar Lake: the ChromeOS image carries
Mesa < 25.2.0 (iris has no `I915_FORMAT_MOD_4_TILED_LNL_CCS`, minigbm has no `xe`
backend), and the brunch kernel configs disable the Intel IOMMU, which these machines
cannot boot without. This fork adds a 7.1 kernel and a Mesa 25.3.6 userspace override
that fill both gaps, plus the ARCVM and audio fixes that fall out of them.

Everything here is additive: the 6.6 / 6.12 kernels and their patches are still in the
tree, upstream behaviour on them is unchanged (with one exception: the external drivers
were brought forward so they also build on 7.1 — see *External drivers* — and the
6.6 / 6.12 builds compile the updated driver sources too), and none of the LNL patches
activate on other hardware (each one checks the iGPU PCI id first). **Releases,
however, only ship the 7.1 kernel**: the upstream kernels cannot boot a Lunar Lake
machine (their configs disable the IOMMU), so building them here would only spend CI
time on kernels this fork's audience cannot use. Anyone on non-LNL hardware is better
served by upstream brunch; a full multi-kernel build remains one environment variable
away (see *Building*).

**Status: it works.** OOBE, login, reboot, re-login, Play Store, Android apps and games,
Crostini, audio and suspend all run on the reference machine. See *Known limitations*
before you rely on it.

## Reference hardware

Developed and tested on an **HP OmniBook X Flip**, Core Ultra 9 288V, Xe2 `8086:64A0`,
against the **ChromeOS R149, R150 and R151 volteer** recovery images. Other Lunar Lake
machines should work — the patches key off the iGPU PCI id (`8086:6420`, `8086:64a0`,
`8086:64b0`), not off the laptop model — but nothing else has been tried.

## What this fork adds

### 7.1 kernel (`kernel-patches/7.1/`, `kernel-patches/7.1_*config`)

No ChromiumOS 7.1 branch exists, so this kernel is built from a **vanilla kernel.org
tree**. `prepare_kernels.sh` learned to fetch one and to take its config from a vendored
baseline instead of the flex/CrOS assembly; the ChromeOS config fragments the build still
needs are vendored in `kernel-patches/7.1-cros-configs/`.

The brunch patch set was forward-ported, plus four ChromeOS kernel behaviours that
ChromeOS userspace depends on and vanilla does not have:

| patch | why |
|---|---|
| `mglru_sysfs_admin.patch` | ChromeOS `vm_concierge` writes the CrOS-private MGLRU sysfs admin interface. Without it concierge dies at startup, no VM starts at all, and chrome takes a SIGSEGV at login. |
| `dm_verity_chromeos_table.patch` | `imageloader` mounts DLCs with a CrOS-private dm-verity table format (`payload=`/`hashtree=`/`alg=`/…). Vanilla dm-verity only parses upstream positional arguments, so every DLC mount fails — Crostini reports "error downloading", cras noise cancellation retries forever. |
| `drm_master_relax.patch` | ChromeOS relies on relaxed DRM master handover between frecon and chrome. |
| `kvm_honor_guest_pat.patch` | See *ARCVM graphics* below. |

Config highlights (`kernel-patches/7.1_extra_configs`, all commented in place): the
Intel IOMMU is re-enabled over the upstream `brunch_configs` disable — Lunar Lake
firmware hands the CPU over in locked-x2APIC mode and the kernel panics before any
console exists without DMAR interrupt remapping — and the boot console uses
sysfb/simpledrm rather than efifb, which on these machines maps the GOP framebuffer
uncached and takes seconds per printk line.

### External drivers (`external-drivers/`)

Upstream brunch builds its 13 out-of-tree modules (Realtek Wi-Fi, broadcom-wl,
acpi_call, ipts, ithc) only for kernels 6.6 / 6.12, so on 7.1 they were skipped
entirely. This fork ports all of them to the vanilla 7.1 tree. The recurring breakage:
kbuild dropped `EXTRA_CFLAGS`, the `del_timer*` / `from_timer` removals, the 6.14
`link_id` and 6.17 `radio_idx` cfg80211 arguments, 7.1 passing `struct wireless_dev *`
to the cfg80211 key/station ops, and 7.1 hiding the pppoe flexible-array members from
kernel code. Where an active upstream already carried the fixes, the vendored copy was
synced to it (rtl8192eu → Mange, rtl8812au / rtl8821cu → morrownr, rtl885xxx →
morrownr/rtw89); the rest is version-guarded compat, with per-change provenance in the
commit messages. All changes are kernel-version-guarded or version-neutral, so the
6.6 / 6.12 builds keep working — but since the default build went 7.1-only, CI no
longer exercises them; verify with a `BRUNCH_KERNELS="6.6 6.12 7.1"` build before
sending any of this upstream. On 7.1 the in-tree rtw89 already
covers the rtl885xxx hardware; the external copy is kept so every kernel ships the
same module set.

### Mesa 25.3.6 userspace (`mesa-patches/`, `packages/mesa-lnl.tar.gz`, `85-mesa_lnl.sh`)

Replaces libgallium (iris), libEGL, libvulkan_intel (ANV) and **libgbm** in the running
image. libgbm is the awkward one: on ChromeOS `libgbm.so.1` *is* minigbm, and Chrome,
crosvm, virglrenderer and libcros_camera are all compiled against minigbm's `gbm.h`,
which is not ABI-compatible with Mesa's. `mesa-patches/` carries the shim that bridges
that, and [`mesa-patches/README.md`](mesa-patches/README.md) documents each patch, the
bug it fixes and how it was measured.

The package rebuilds from the six patches plus `brunch_minigbm_compat.c` against a
pristine `mesa-25.3.6.tar.xz`; `diff -rq` against the tree it was built from reports no
differences.

### ARCVM graphics

Three separate bugs had to be fixed before Android apps rendered correctly. All three
are upstream bugs, not brunch ones:

1. **venus fences never complete** → SurfaceFlinger hangs, Play Store restart-loops.
   KVM's `KVM_X86_QUIRK_IGNORE_GUEST_PAT` forces write-back and the guest's
   write-combining mappings never see host fence writes. QEMU has
   `-accel kvm,honor-guest-pat=on`; crosvm has no such switch, so this is a kernel
   patch (`kvm_honor_guest_pat.patch`).
2. **Stray geometry drawn over an otherwise correct frame** — on Xe2, ANV silently drops
   `HOST_CACHED` for any exportable bo and hands out an uncached scanout PAT entry,
   while the importer maps the same memory type write-back. Every buffer venus gives a
   guest is exportable. (`mesa-patches/0002`)
3. **Every ARC window rendered as vertical stripe noise** — ANV placing bos in
   compressed PAT memory, which is broken under an ARCVM guest. (`mesa-patches/0006`)

`87-arcvm_seccomp.sh` additionally neutralizes the crosvm seccomp filters. The ChromeOS
crosvm binary embeds pre-compiled seccomp BPFs built for the volteer image; they lag
crosvm's own tube code and SIGSYS-kill the virtio-fs/gpu device workers on
`recvfrom`/`recvmsg`, tearing ARCVM down before the Play Store can start.
The same stale filters also kill termina/Crostini: its virtio-wl worker dies on
`recvfrom` the moment a GUI app connects through sommelier, taking the whole VM down
(the terminal is unaffected because vsh runs over vsock, never touching virtio-wl).
`--seccomp-policy-dir` does not override these embedded filters for the device workers
in the shipped build, so the patch preloads a small shim (`arcvm-noseccomp/`) into
crosvm for concierge-managed VMs (ARCVM and termina) that no-ops the seccomp filter
installation while leaving every other minijail jailing — namespaces, ugid map, caps,
rlimits — intact.

### Audio (`86-lnl_audio_fw.sh`, `packages/lnl-audio-fw.tar.gz`)

`build_brunch.sh` assembles brunch's firmware package from a linux-firmware checkout
plus the `lib/firmware/intel/sof*` directories of the ChromeOS rootfs it builds against.
linux-firmware no longer carries any Intel SOF firmware (its WHENCE lists none), so the
Intel SOF files in `packages/firmwares.tar.gz` come from the ChromeOS rootfs alone:

- CI builds use the ChromeOS Flex (reven) rootfs, which ships an IPC4 set, but an old
  one: SOF 2.12 (March 2025) as of R150, with a thinner topology set (no
  `sof-lnl-dmic-*`, `sof-sdca-*`, `sof-ptl-*`, ...).
- A build against a Chromebook recovery image (volteer etc.) gets IPC3 only
  (`intel/sof`, `intel/sof-tplg`): no `intel/sof-ipc4` at all, and Lunar Lake has no
  sound.

`86-lnl_audio_fw.sh` therefore overlays a current sof-bin release on Lunar Lake
machines, after `50-add_generic_firmwares.sh` so its files replace the rootfs copy:
`intel/sof-ipc4/lnl`, `intel/sof-ipc4-lib/lnl` and the whole `intel/sof-ipc4-tplg`
directory of [sof-bin v2025.12.2](https://github.com/thesofproject/sof-bin/releases/tag/v2025.12.2)
(SOF 2.14.1), uncompressed and byte-for-byte as released. Only the `lnl` firmware is
included and the patch only triggers on Lunar Lake PCI ids; the topology directory
happens to cover MTL / ARL / PTL / WCL as well. To regenerate the package from a sof-bin
release:

```sh
curl -LO https://github.com/thesofproject/sof-bin/releases/download/v2025.12.2/sof-bin-2025.12.2.tar.gz
tar xzf sof-bin-2025.12.2.tar.gz
mkdir -p stage/lib/firmware/intel/sof-ipc4 stage/lib/firmware/intel/sof-ipc4-lib
cp -a sof-bin-2025.12.2/sof-ipc4/lnl     stage/lib/firmware/intel/sof-ipc4/
cp -a sof-bin-2025.12.2/sof-ipc4-lib/lnl stage/lib/firmware/intel/sof-ipc4-lib/
cp -a sof-bin-2025.12.2/sof-ipc4-tplg    stage/lib/firmware/intel/
tar -C stage -czf packages/lnl-audio-fw.tar.gz lib --owner=0 --group=0
```

#### SoundWire codecs (`alsa-ucm-conf/ucm2/sof-soundwire/`)

Most Lunar Lake laptops (and the Meteor/Arrow Lake Dell XPS line) do not use an HDA
codec: audio is a SoundWire **cs42l43** headset codec plus **cs35l56** amplifiers,
registered by the kernel as the `sof-soundwire` card. The card probes fine and still
produces no sound, because the alsa-ucm-conf release brunch has to ship (1.2.8, the
one ChromeOS's alsa-lib can parse) has no profile for these codecs — the UCM fails to
load, and without one cras guesses nodes from mixer control names, which are all
prefixed on these codecs, so it ends up with a phantom "Speaker" on the headphone PCM.
The overlay adds cras-specific profiles (fully specified PCM numbers, jack input
devices, amplifier switches) for the Cirrus SoundWire combinations and for every Realtek
SoundWire part in the 7.1 Intel machine tables (rt711, rt712, rt713, rt721, rt722, the
rt1308 / rt1316 / rt1318 / rt1320 amplifiers, the rt715 / rt1712 / rt1713 microphone
parts), written against the 7.1 kernel drivers and the upstream alsa-ucm-conf 1.2.16
profiles and parse-tested against alsa-lib 1.2.8. Anything else keeps the upstream 1.2.8
behaviour.
See [`alsa-ucm-conf/ucm2/sof-soundwire/cras/README.md`](alsa-ucm-conf/ucm2/sof-soundwire/cras/README.md).

## Building

Same as upstream:

```sh
./prepare_kernels.sh                       # downloads and patches the kernel trees
./build_kernels.sh                         # or ./build_kernels.sh 7.1 for just this one
sudo bash build_brunch.sh <recovery_image.bin>
```

`prepare_kernels.sh` prepares only `7.1` by default — the kernel this fork is about.
Run `BRUNCH_KERNELS="6.6 6.12 6.18 7.1" ./prepare_kernels.sh` for a full upstream-style
build; 6.6 / 6.12 support has not been removed, it is just not built by default.

GitHub Actions builds on push (`.github/workflows/build.yml`); its kernel matrix comes
from whatever `prepare_kernels.sh` prepared, so CI and releases are 7.1-only too.
Release kernels are signed with this fork's own key (see *Secure
Boot* below); a fork without the `BRUNCH_PRIV` / `BRUNCH_PEM` secrets set will produce
**unsigned** kernels, which boot fine but cannot be used with Secure Boot.

Pick `7.1` in `brunch-setup` at install time — in a 7.1-only build it is the only
entry and already preselected, since the menu is generated from the kernels the build
actually ships. The Lunar Lake patches then activate on their own; `no_lnl_mesa`,
`no_lnl_audio_fw` and `no_arcvm_seccomp` turn them off individually.

## Secure Boot

The boot chain is: Microsoft-signed Debian shim (`bootx64.efi`) → GRUB, signed by
upstream brunch's key → kernel, signed by **this fork's** key (upstream cannot share its
private key, so forks sign kernels themselves). Two certificates therefore have to be
enrolled in MOK, and both ship at the root of the EFI partition:

- `brunch.der` — upstream brunch's certificate, verifies GRUB
- `brunch-lnl.der` — this fork's certificate, verifies the kernels

Enroll them either from a Linux system:

```sh
sudo mokutil --import brunch.der
sudo mokutil --import brunch-lnl.der
```

or directly at the blue "Verification failed" screen on the first Secure Boot boot:
OK → Enroll key from disk → EFI-SYSTEM → select each `.der` in turn → Continue, reboot.

With Secure Boot disabled none of this matters — unsigned or differently-signed kernels
boot normally.

## Known limitations

- **"Sign in with your Android phone" does not work** at OOBE. Sign in with a
  password instead. Not chased down, and not established as Lunar Lake specific.
- **ARCVM Play Store can crash once after suspend/resume.** The VM survives (crosvm
  keeps running); a venus GPU context can enter a fatal state on the first resume and
  the Android app using it is dropped, so re-opening it recovers. Timing-dependent and
  not reliably reproducible. Same family as the ARCVM graphics bugs above (venus/ANV on
  Xe2 under a VM).
- **One machine.** Verified on a single laptop model. The 7.1 kernel config comes from
  an Arch baseline, so hardware Arch does not enable is not covered.
- **The SoundWire audio profiles are untested on hardware.** The reference laptop has an
  HDA codec; the `sof-soundwire` cras profiles were written from the kernel driver and
  upstream UCM sources and only parse-tested. Reports from cs42l43 / cs35l56 and Realtek
  SoundWire machines (`cras` messages in `/var/log/messages`, `amixer -c0 controls`) are
  what they need.
- `mesa-patches/0003` and `0004` de-advertise the Xe2 CCS DRM modifiers to any importer.
  They are not what fixed the stripe-noise bug (`0006` was), but they are kept: any
  consumer using a minigbm older than Lunar Lake cannot interpret those modifiers.
- Cosmetic leftovers seen in logs and not chased down: `unknown rutabaga path` from
  crosvm, ~60 virglrenderer `GL error (1282)` lines during ARCVM startup, and NV12
  128×128 `bo_create` failures believed to come from the ARC camera stack.

## Upstream bugs found here

Worth reporting, and worth knowing about if you hit them elsewhere:

- **Mesa/ANV** — `HOST_CACHED` dropped for exportable bos on Xe2 (`0002`).
- **Mesa/ANV** — bos in compressed PAT memory are corrupt inside a VM guest (`0006`).
  Only the location is established, not the mechanism: on the host, compression round
  trips cleanly in every test.
- **Mesa/ANV and Mesa/iris** — both advertise the Xe2 CCS modifiers to importers that
  cannot decode them, and each has its own independent modifier filter, so a fix to the
  shared ISL code reaches only ANV (`0003`, `0004`).
- **brunch** — `brunch-patches/82-features.sh:31` writes
  `--enable-hardware-overlays="single-fullscreen,single-on-top"`; the quotes end up
  inside the flag value, so Chrome rejects both strategies (`overlay_strategy.cc`) and
  hardware overlays are silently off. Left as upstream wrote it, so this fork stays
  comparable.

## Credit

All of brunch is [sebanc](https://github.com/sebanc)'s work; this fork only adds a
platform. Please send general brunch issues and pull requests upstream — file things
here only if they are Lunar Lake specific.

The releases in this repository are experimental. Use at your own risk.
