# brunch-unstable — Intel Lunar Lake (Xe2) fork

A fork of [sebanc/brunch-unstable](https://github.com/sebanc/brunch-unstable) that adds
support for **Intel Lunar Lake** (Core Ultra 200V, Xe2 graphics) laptops.

Upstream brunch ships kernels 6.6 / 6.12 and the graphics userspace that comes inside
the ChromeOS recovery image. Neither knows about Lunar Lake: the ChromeOS image carries
Mesa < 25.2.0 (iris has no `I915_FORMAT_MOD_4_TILED_LNL_CCS`, minigbm has no `xe`
backend), and the brunch kernel configs disable the Intel IOMMU, which these machines
cannot boot without. This fork adds a 7.1 kernel and a Mesa 25.3.6 userspace override
that fill both gaps, plus the ARCVM and audio fixes that fall out of them.

Everything here is additive: on any non-Lunar-Lake machine the 7.1 kernel is simply one
more entry in the kernel list and none of the LNL patches activate (each one checks the
iGPU PCI id first). Upstream behaviour on 6.6 / 6.12 is unchanged, with one exception:
the external drivers were brought forward so they also build on 7.1 (see *External
drivers*), and the 6.6 / 6.12 builds compile the updated driver sources too.

**Status: it works.** OOBE, login, reboot, re-login, Play Store, Android apps and games,
Crostini, audio and suspend all run on the reference machine. See *Known limitations*
before you rely on it.

## Reference hardware

Developed and tested on an **HP OmniBook X Flip**, Core Ultra 9 288V, Xe2 `8086:64A0`,
against the **ChromeOS R149 volteer** recovery image. Other Lunar Lake machines should
work — the patches key off the iGPU PCI id (`8086:6420`, `8086:64a0`, `8086:64b0`), not
off the laptop model — but nothing else has been tried.

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
6.6 / 6.12 builds keep working (CI exercises them). On 7.1 the in-tree rtw89 already
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

`87-arcvm_seccomp.sh` additionally replaces the crosvm seccomp policies: the R149 crosvm
binary embeds volteer-era policies that predate glibc 2.41 and Mesa 25.3.6, and
SIGSYS-kill crosvm workers on `fcntl(F_DUPFD_QUERY)`, `newfstatat` and friends before
the Play Store can start.

### Audio (`86-lnl_audio_fw.sh`, `packages/lnl-audio-fw.tar.gz`)

ChromeOS recovery images only ship SOF **IPC3** firmware. Lunar Lake needs the IPC4 set
(`intel/sof-ipc4/lnl`, `sof-ipc4-lib/lnl`, `sof-ipc4-tplg`), so without this there is no
sound at all. Files come from upstream linux-firmware.

## Building

Same as upstream:

```sh
./prepare_kernels.sh                       # downloads and patches the kernel trees
./build_kernels.sh                         # or ./build_kernels.sh 7.1 for just this one
sudo bash build_brunch.sh <recovery_image.bin>
```

`prepare_kernels.sh` prepares `6.6 6.12 7.1` by default; override with
`BRUNCH_KERNELS="7.1" ./prepare_kernels.sh` to save a lot of time while iterating.

GitHub Actions builds the whole thing on push (`.github/workflows/build.yml`) and picks
up 7.1 automatically. A fork without the `BRUNCH_PRIV` / `BRUNCH_PEM` secrets set will
produce **unsigned** kernels, which boot fine but cannot be used with Secure Boot.

Pick `7.1` in `brunch-setup` at install time. The Lunar Lake patches then activate on
their own; `no_lnl_mesa`, `no_lnl_audio_fw` and `no_arcvm_seccomp` turn them off
individually.

## Known limitations

- **ChromeOS R150: ARCVM does not start.** Everything here was developed against R149.
  Upgrading the reference machine to R150 works — hardware, login, Crostini and the Mesa
  override all behave — except Android, which hangs at "Starting Play Store…": the
  crosvm seccomp policy replacement (`87-arcvm_seccomp.sh`) is generated against the
  R149 image and needs revisiting for R150's crosvm.
- **One machine.** Verified on a single laptop model. The 7.1 kernel config comes from
  an Arch baseline, so hardware Arch does not enable is not covered.
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
