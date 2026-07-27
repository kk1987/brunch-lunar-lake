# mesa-patches — Mesa 25.3.6 sources for the Lunar Lake userspace package

These are the source-level changes behind `packages/mesa-lnl.tar.gz`. ChromeOS R149
ships Mesa < 25.2.0, which has no Lunar Lake (Xe2) support: iris lacks
`I915_FORMAT_MOD_4_TILED_LNL_CCS` and minigbm has no `xe` backend. The package
replaces libgallium (iris), libEGL/libGLES, libvulkan_intel (ANV) and **libgbm**.

Replacing libgbm is the awkward part: on ChromeOS `libgbm.so.1` *is* minigbm, and
Chrome, crosvm, virglrenderer and libcros_camera are all compiled against minigbm's
`gbm.h`. Mesa's own libgbm is not ABI-compatible with it. The files here bridge that
gap.

## Contents

| File | Applies to | Purpose |
|---|---|---|
| `brunch_minigbm_compat.c` | copy to `src/gbm/main/` | minigbm private API that Mesa's libgbm does not implement: `minigbm_create_default_device`, `gbm_detect_device_info(_path)`, `gbm_bo_get_map_info`, `gbm_bo_map2`. Ported from `platform/minigbm` `minigbm_helpers.c` with an `xe` driver entry added. |
| `0001-gbm-minigbm-abi-compat.patch` | `patch -p1` in the Mesa source root | minigbm ABI shims in `gbm.c` + adds the compat file to `src/gbm/meson.build`. |
| `0002-anv-honor-host-cached-on-exported-bo.patch` | `patch -p1` in the Mesa source root | ANV: stop dropping `HOST_CACHED` when a bo is exportable. Without it every ARCVM app draws uninitialised memory (see below). |
| `0003-isl-do-not-advertise-xe2-ccs-modifiers.patch` | `patch -p1` in the Mesa source root | ISL: never advertise `4_TILED_LNL_CCS` / `4_TILED_BMG_CCS` **to ANV**. Without it every ARC window renders as stripe noise (see below). |
| `0004-iris-do-not-advertise-xe2-ccs-modifiers.patch` | `patch -p1` in the Mesa source root | The same for **iris**, which has its own independent modifier filter. `0003` does nothing for the GL path. |
| `0005-glsl-bind-atan2f-to-baseline-glibc-symver.patch` | `patch -p1` in the Mesa source root | Packaging fix: keeps libgallium's glibc symbol floor at 2.38 so the R149 image can load it. |
| `0006-anv-never-use-compressed-pat-memory.patch` | `patch -p1` in the Mesa source root | ANV: never place a bo in compressed PAT memory. This is what `INTEL_DEBUG=noccs` was actually buying; with it the wrapper no longer needs noccs at all. |

## Applying

```sh
tar xf mesa-25.3.6.tar.xz && cd mesa-25.3.6
cp ../mesa-patches/brunch_minigbm_compat.c src/gbm/main/
patch -p1 --fuzz=0 < ../mesa-patches/0001-gbm-minigbm-abi-compat.patch
patch -p1 --fuzz=0 < ../mesa-patches/0002-anv-honor-host-cached-on-exported-bo.patch
patch -p1 --fuzz=0 < ../mesa-patches/0003-isl-do-not-advertise-xe2-ccs-modifiers.patch
patch -p1 --fuzz=0 < ../mesa-patches/0004-iris-do-not-advertise-xe2-ccs-modifiers.patch
patch -p1 --fuzz=0 < ../mesa-patches/0005-glsl-bind-atan2f-to-baseline-glibc-symver.patch
patch -p1 --fuzz=0 < ../mesa-patches/0006-anv-never-use-compressed-pat-memory.patch
```

Both steps are required: the new file is kept standalone (readable and editable),
and the patch only registers it in `src/gbm/meson.build` plus edits `gbm.c`.

Verified: applies with `--fuzz=0` against a pristine `mesa-25.3.6.tar.xz`; after the
copy and the patch, a full `diff -rq` against the tree `packages/mesa-lnl.tar.gz` was
built from reports **no** differences, so these two files capture the entire source
drift — `src/gbm/main/gbm.c`, `src/gbm/meson.build` and
`src/gbm/main/brunch_minigbm_compat.c` are the only touched files in the whole tree.

## What `0001-gbm-minigbm-abi-compat.patch` does

1. **Missing exports** — `gbm_bo_get_plane_fd` / `gbm_bo_get_plane_size` forwarders,
   without which Chrome fails to start with `undefined symbol: gbm_bo_get_plane_fd`.

2. **Usage-flag translation** (`brunch_minigbm_to_mesa_flags`) — minigbm and Mesa
   agree on bits 0-4 and then diverge: minigbm bit5 is `TEXTURING` while Mesa bit5 is
   `PROTECTED`. Without translation a texturing request is imported as a protected
   buffer.

3. **Import-constant remap** — minigbm's `GBM_BO_IMPORT_FD_MODIFIER` is `0x5505`,
   Mesa's is `0x5504`. `struct gbm_import_fd_modifier_data` is byte-identical on both
   sides, so remapping the type constant is enough. `0x5504` is deliberately *not*
   remapped: for a pure-Mesa caller that is the native `FD_MODIFIER`.

4. **`BRUNCHGBM` tracing, off by default** — build the library with
   `-DBRUNCH_GBM_DEBUG` and every `bo_create` / `bo_import` logs to stderr: requested
   flags, translated flags and the modifier actually returned. This is how the
   `gbm_create_device => NULL` backend-path bug was found. It sits on a hot path, so
   it is a compile-time option rather than something shipped enabled. To use it, add
   `#define BRUNCH_GBM_DEBUG 1` at the top of `src/gbm/main/gbm.c` and rebuild just
   that library (`ninja -C build-lnl src/gbm/libgbm.so.1.0.0`, a few seconds), then add
   `--enable-logging=stderr --disable-logging-redirect` to `/etc/chrome_dev.conf` so
   the lines reach `/var/log/ui/`.

## What `brunch_minigbm_compat.c` provides

The minigbm-private APIs ChromeOS userspace link against at load time, which Mesa's
libgbm does not have:

| symbol | linked by |
|---|---|
| `minigbm_create_default_device` | crosvm, libvirglrenderer, virgl_render_server, libcros_camera |
| `gbm_detect_device_info` / `_path` | libvirglrenderer, runtime_probe |
| `gbm_bo_get_map_info` | libvirglrenderer, crosvm |
| `gbm_bo_map2` | libcros_camera |

Without `minigbm_create_default_device` crosvm dies at `symbol lookup error`, which
takes down both Crostini and ARCVM. The device-detection helpers are ported from
`chromiumos/platform/minigbm/minigbm_helpers.c` (BSD) with the amdgpu/radeon
dGPU-vs-iGPU refinement dropped (this package installs only on Lunar Lake) and an
`xe` driver entry added. `gbm_bo_get_map_info` is hardcoded to
`GBM_BO_MAP_CACHE_WC`; `gbm_bo_map2` refuses non-zero planes rather than returning
a wrong mapping (Mesa can only map plane 0).

`crosvm.bin` on R149 volteer has `libgbm.so.1` in its `DT_NEEDED` and imports
`gbm_bo_create`, `gbm_bo_get_map_info`, `gbm_bo_get_modifier`,
`gbm_bo_get_stride_for_plane`, `gbm_bo_get_offset`, `gbm_bo_get_fd`,
`gbm_bo_get_plane_count` — i.e. **every ARCVM host-side buffer allocation goes
through this shim**. Note it uses plain `gbm_bo_create` (no modifier list), so the
layout is chosen entirely from the translated usage flags.

## What `0002-anv-honor-host-cached-on-exported-bo.patch` does

On Xe2, an allocation from a Vulkan memory type that advertises `HOST_CACHED`
silently loses that property as soon as the bo is exportable — and every buffer
venus hands to an ARCVM guest is exportable. Two places conspire:

1. `anv_AllocateMemory()` takes an early `EXTERNAL|SCANOUT` branch that sets only
   `ANV_BO_ALLOC_HOST_COHERENT` and never consults the memory type's
   `VK_MEMORY_PROPERTY_HOST_CACHED_BIT`.
2. `anv_device_get_pat_entry()` matches `EXTERNAL|SCANOUT` *before* the
   integrated-platform host-caching rules and returns `pat.scanout`, which on Xe2
   is `PAT_ENTRY(6, WC)` — CPU write-combining, GPU PAT 6 = XD, not snooped
   (BSpec 71582). On pre-Xe2 integrated parts the scanout entry was still
   coherent, which is why taking it unconditionally was harmless.

So the exporter uses the memory uncached while the importer — told `HOST_CACHED`
by the same memory type — maps it write-back. Neither side sees the other's
writes. In ARCVM that surfaces as apps drawing uninitialised memory: glyph
atlases rendered as white noise where text belongs, and stray geometry
rasterised as thin diagonal streaks across the scene.

Measured on `8086:64a0` with a QEMU venus guest, sweeping every host-visible
memory type with a staging→image→readback / buffer→buffer / GPU-fill round trip:

| host backend | memory type | unpatched | patched |
|---|---|---|---|
| ANV (xe) | `DEVICE_LOCAL HOST_VISIBLE HOST_COHERENT` | pass | pass |
| ANV (xe) | + `HOST_CACHED` | **fail every iteration, ~95% of bytes wrong, both directions** | pass 24/24 |
| lavapipe | + `HOST_CACHED` | pass | pass |

lavapipe passing either way places the fault in ANV, not in the venus protocol.
The same Mesa tree built with and without the patch is the A/B: 4/8 lanes failed
before, 0/8 after.

The sharpest lane is the draw one: a grid of indexed quads whose vertex and index
buffers live in host-visible memory and are rewritten by the CPU every frame —
the shape ANGLE uses for streamed geometry. Unpatched, on memory type 2, the
whole 512x512 target comes back **black**: the vertex data never reaches the GPU
at all. That is what the corruption actually was — not damaged pixels but
garbage geometry rasterised over an otherwise correct frame.

The fix was then re-run against the real component stack rather than QEMU: the
image's own `crosvm.bin` and `virgl_render_server` driving the installed
`mesa-lnl`, inside `unshare -m` + `pivot_root` into ROOT-A. All lanes clean.
That needs guest PAT honoured, which crosvm has no flag for — an `LD_PRELOAD`
shim that calls `KVM_ENABLE_CAP(KVM_CAP_DISABLE_QUIRKS2,
KVM_X86_QUIRK_IGNORE_GUEST_PAT)` on each new VM fd substitutes for a host kernel
patch. Without that, KVM forces everything write-back and masks the very
behaviour under test.

Confirmed on the target machine 2026-07-26: with this patch deployed, the
residual in-game corruption (Clash Royale) is gone.

This is an upstream Mesa bug, not a brunch one — worth sending to Mesa.

## What `0003-isl-do-not-advertise-xe2-ccs-modifiers.patch` does

Separate bug, same family, different symptom: every ARC window rendering as
vertical stripe noise with the coarse layout still recognisable — the Play Store
and Android Settings were unusable. (The `0002` bug hit *inside* apps; this one
hits the window as a whole.)

ISL advertises `I915_FORMAT_MOD_4_TILED_LNL_CCS` on Xe2. The consumer here is a
ChromeOS R149 image whose minigbm predates Lunar Lake and has no entry for that
modifier, so when the guest negotiates it for a buffer it exports, Chrome
imports the buffer as plain 4-tiled and reads the compressed bytes as if they
were pixels. The kernel side of this is already handled —
`kernel-patches/7.1/chromeos/0002-lnl_bmg_ccs_deadvertise.patch` removes the
same two modifiers from the i915 display planes — and this is its userspace
counterpart.

This replaces an `INTEL_DEBUG=noccs` that `brunch-patches/87-arcvm_seccomp.sh`
used to export into the crosvm process tree. That worked, but it was far broader
than needed. `DEBUG_NO_CCS` has exactly three effects:

| site | effect | load-bearing here? |
|---|---|---|
| `isl.c:3902` | disables aux surfaces everywhere | no — pure loss |
| `anv_device.c:1554` | disables PAT-memtype compression | no — unreachable, see below |
| `isl_drm.c` | removes CCS modifiers from the advertised list | **yes** |

The middle one cannot apply to a bo that will be shared:
`anv_image_is_pat_compressible()` returns false for any image with
`external_handle_types` or DRM-modifier tiling, so a compressed memory type is
never even offered for one. Confirmed empirically by aggregating every host-side
`vkAllocateMemory` under a venus guest — compressed and exported never co-occur.
(On LNL only memory type 0, `DEVICE_LOCAL` alone, is `compressed`.)

Measured by enumerating `VkDrmFormatModifierPropertiesListEXT` on `8086:64a0`
(`venustest/modlist.c`):

| build | advertised modifiers | CCS |
|---|---|---|
| stock, no `noccs` | LINEAR, X_TILED, 4_TILED, **4_TILED_LNL_CCS** | 1 of 4 |
| stock, `noccs` | LINEAR, X_TILED, 4_TILED | 0 of 3 |
| patched, no `noccs` | LINEAR, X_TILED, 4_TILED | 0 of 3 |

So the patch reproduces exactly the modifier list `noccs` produced, while leaving
render target compression, fast clears and sampler decompression alone.

**`0003` on its own is not enough — see `0004`.** It only covers the Vulkan
path, and the first deployment of it without `noccs` left the GL path still
corrupted.

## What `0004-iris-do-not-advertise-xe2-ccs-modifiers.patch` does

The same de-advertisement for iris. There are **three** independent places that
decide whether a Xe2 CCS modifier is offered, and all three have to be patched:

| component | decision site | patch |
|---|---|---|
| i915 display planes | `intel_fb.c` modifier table | `kernel-patches/7.1/chromeos/0002-lnl_bmg_ccs_deadvertise.patch` |
| ANV | `isl_drm.c` `isl_drm_modifier_get_score()` | `0003` |
| iris | `iris_resource.c` `modifier_is_supported()` | `0004` |

iris does **not** consult `isl_drm_modifier_get_score()` for its modifier list;
it has its own switch that gates the Xe2 modifiers only on
`INTEL_DEBUG(DEBUG_NO_CCS)`. That asymmetry is what made `INTEL_DEBUG=noccs`
look like a single knob: it is an environment variable, so it reached both
drivers at once, while `0003` reached only one.

The symptom split cleanly along the driver boundary. With `0003` deployed and
`noccs` removed, on the target machine:

| surface | API path | result |
|---|---|---|
| game main surface | Vulkan → venus → ANV | correct |
| Play Store | GLES → virgl → iris | stripe noise |
| Play badge splash | GLES → virgl → iris | stripe noise |
| layers over a resized window | GLES → virgl → iris | stripe noise over a correct frame |

Measured with `venustest/glmodlist.c` (`eglQueryDmaBufModifiersEXT`, the GL
counterpart of `modlist.c`), for each of AR24 / XR24 / AB24 / NV12:

| build | advertised modifiers | CCS |
|---|---|---|
| the binary shipped before this patch | LINEAR, X_TILED, 4_TILED, **4_TILED_LNL_CCS** | 1 of 4 |
| that same binary + `INTEL_DEBUG=noccs` | LINEAR, X_TILED, 4_TILED | 0 of 3 |
| patched, no `noccs` | LINEAR, X_TILED, 4_TILED | 0 of 3 |

`venustest/glcheck.c` then renders a pattern into a bo of each advertised
modifier, exports it as a dma-buf and reads it back through a second gbm device
and EGL context: 0 of 3 fail. (It cannot reproduce the corruption itself —
both ends are the same iris, and the mismatched importer is ChromeOS's minigbm.
It is a smoke test that the rebuilt binary renders and round-trips at all.)

## What `0005-glsl-bind-atan2f-to-baseline-glibc-symver.patch` does

Purely a packaging fix. glibc 2.43 added a correctly-rounded `atan2f` under a
new symbol version, and `src/compiler/glsl/ir_constant_expression.cpp` is the
only translation unit in the tree that references `atan2f` — so on a 2.43 build
host that one symbol raises libgallium's requirement to `GLIBC_2.43`, above
what the R149 image provides, and it fails to load outright. The patch binds
the reference to the x86-64 baseline version.

This used to be done by hand as a post-link binary edit, which is exactly why
the packaged `libgallium_dri.so` was not reproducible from the build tree.

## What `0006-anv-never-use-compressed-pat-memory.patch` does

The end of the `INTEL_DEBUG=noccs` story. With `0006` in place
`brunch-patches/87-arcvm_seccomp.sh` no longer exports noccs at all, and the
file is byte-identical to what it was before noccs was ever added.

Every ARC window rendered as vertical stripe noise with the coarse layout still
recognisable. `DEBUG_NO_CCS` has four kinds of effect; three real-machine A/B
rounds, one variable each, narrowed it to exactly one:

| # | what was changed | result | conclusion |
|---|---|---|---|
| 1 | `0003` + `0004`: de-advertise the Xe2 CCS modifiers in both drivers, drop noccs | still corrupt | the **declared layout** is not what matters |
| 2 | ANV alone made to ignore noccs, iris still honouring it | corruption returns | it is **ANV**, not iris |
| 3 | ANV ignores noccs everywhere **except** the `mem_type->compressed` branch | clean | it is **that branch**, not `isl.c:3902`'s aux/CCS_E |

Step 2 is possible without touching the environment because ANV and iris are
separate shared objects and `intel_debug` is not an exported dynamic symbol in
either (`readelf --dyn-syms | grep -cw intel_debug` is 0 for both), so each has
a private copy and can be made to honour or ignore the flag independently.
That trick is worth remembering: it turns "which driver?" into one boot.

**What this does not mean.** The obvious story — compressed bytes exported
under a modifier that says nothing about compression, then read as pixels — is
ruled out. `anv_image_is_pat_compressible()` (`anv_image.c:2517`) returns false
for any image that is external or DRM-modifier tiled, so the compressed memory
type is only ever offered to images that are **never exported**. The bo is
already wrong to the guest's own rendering; what reaches the window is a
faithful copy of that garbage. Why compressed PAT memory misbehaves for a VM
guest on this kernel is **not established** — only that it does.

The host reproduction environment cannot show it. With no VM in the picture,
compression round-trips cleanly through every test in `venustest/`: `texcheck`
0/16 on all three lanes, `ccscheck` 0/8, `dmabufcheck` 0/8 both directions,
`glcheck` 0/3, `glexport` clean. That is why this took three real-machine
rounds and not one host experiment, and it is the strongest argument for
reporting it upstream rather than carrying it forever.

**What is kept.** Render target compression, fast clears and sampler
decompression, in ANV *and* in iris. noccs threw all of that away in both
drivers, measured at +50% to +83% frame time on bandwidth-bound work
(`venustest/ccsbench.c`, 2880x1800):

| lane | CCS on | noccs | cost |
|---|---|---|---|
| fill (pure RT writes) | 14.6 ms | 26.7 ms | +83% |
| sample (read+write ping-pong) | 31.3 ms | 46.8 ms | +50% |
| blend (RT read-modify-write) | 14.8 ms | 23.9 ms | +62% |

Those are worst-case numbers — trivial shaders, full screen, smooth-gradient
content that compresses well — but they are the reason narrowing was worth
three rounds.

## Dropped usage-flag bits (measured, benign so far)

`brunch_minigbm_to_mesa_flags()` translates only minigbm bits 0-4, 5, 8 and 16. It
**drops** bit6/7 (`CAMERA_WRITE`/`CAMERA_READ`), bits 9-12 (`SW_READ_OFTEN`/`RARELY`,
`SW_WRITE_OFTEN`/`RARELY`) and bit15 (`GPU_DATA_BUFFER`). Real minigbm forces a
**linear** layout for anything in `BO_USE_SW_MASK`, so in principle dropping those
bits would leave Mesa free to pick Tile4 / Tile4+CCS on Xe2, and a consumer mapping
the buffer as linear would see garbage.

Measured on the target GPU (`8086:64a0`, `xe`, Mesa 25.3.6 with this patch, probing
`gbm_bo_create` at 2880x1800 XR24/AR24 across eight flag combinations): **every
`gbm_bo_create` returns `modifier = 0` (LINEAR), stride 11520**, with or without the
SW bits, with or without `SCANOUT`. The modifier-less `gbm_bo_create` path never
selects a tiled layout here, so the dropped bits do **not** cause a tiling mismatch
on this hardware, and this is *not* the cause of the ARCVM Play Store corruption
(vertical stripe noise with partially intact image regions).

Still worth fixing for correctness — a future Mesa or a different consumer could
behave differently — but it is not load-bearing, so it is left alone until the real
corruption cause is found, to keep that experiment single-variable.

## Build

```
meson setup build-lnl \
  -Dbuildtype=release -Dgallium-drivers=iris -Dvulkan-drivers=intel \
  -Dgbm=enabled -Degl=enabled -Dgles2=enabled -Dopengl=true -Dglx=disabled \
  -Dplatforms= -Dmesa-clc=enabled -Dllvm=enabled -Dvideo-codecs= \
  -Dc_std=gnu17 -Dlmsensors=disabled -Ddraw-use-llvm=false \
  -Dgbm-backends-path=/usr/lib64/gbm
```

`-Dgbm-backends-path=/usr/lib64/gbm` is **required**: meson's default is
`/usr/local/lib/gbm`, where the ChromeOS image has no `dri_gbm.so`, so
`gbm_create_device()` returns NULL and the GPU process crash-loops every ~30s with a
blank screen. (The originally shipped libgbm only had the right path because of a
manual binary string patch.)

Check the result before packaging: max glibc symbol version must be **≤ 2.38** (the
image's libc provides 2.41, but ChromeOS binaries are built against an older one),
`SONAME` must stay `libgbm.so.1`, and the minigbm symbols above must all be exported.

`libgbm.so.1.0.0` is only ~28 KB and can be rebuilt on its own with
`ninja -C build-lnl src/gbm/libgbm.so.1.0.0` — but remember to refresh the copy inside
`packages/mesa-lnl.tar.gz`, or the next brunch rebuild will put the old one back.

`libvulkan_intel.so` likewise rebuilds on its own with
`ninja -C build-lnl src/intel/vulkan/libvulkan_intel.so` (~1 min, 4 targets), which
makes A/B testing an ANV change cheap: point a throwaway ICD json's `library_path`
straight at the build tree and set `VK_ICD_FILENAMES`.

`libgallium_dri.so` takes ~20 min for a full build but relinks in seconds after a
single-file change; plain `ninja -C build-lnl` is enough (the meson target is
named `libgallium-25.3.6.so`, and asking for `libgallium_dri.so` is an "unknown
target" error that aborts the whole invocation without building anything).

**Reproducibility (was a known gap, closed 2026-07-26).** Every binary in
`packages/mesa-lnl.tar.gz` rebuilds from `build-lnl` with the patches above.
`libvulkan_intel.so` and `libgallium_dri.so` are refreshed whenever a patch
changes them; the other three (`libgbm.so.1.0.0`, `gbm/dri_gbm.so`,
`libEGL_mesa.so.0.0.0`) are carried forward and compare equal in `.text`, but
not byte-for-byte across a host toolchain upgrade — a gcc bump leaves two
strings in `.comment` instead of one (24 bytes). Compare `.text` with
`objcopy -O binary --only-section=.text`, not the whole file.

Before that, the packaged `libgallium_dri.so` came from an earlier staging build
(33917016 bytes vs 33757752 from `build-lnl`) and could not be reproduced,
because it carried two manual post-processing steps that are now patches or
build options: the `atan2f` symbol-version edit (`0005`) and a link against a
static libstdc++ (dropped — the package bundles `libstdc++.so.6.0.35` and
`libvulkan_intel.so` already depends on it dynamically).

That gap is what hid the `0004` bug for a round: a patch to shared code (ISL)
reached only ANV in the shipped package, so it was tempting to assume iris was
uninvolved. It was not — the shipped iris advertised `4_TILED_LNL_CCS`, and
measuring the binary straight out of the tarball is what settled it.

**Copy the artefact out of the build tree at the moment you deploy it.** A stale
side copy of an earlier build is indistinguishable from the current one by name
alone, and deploying it silently invalidates the next round of testing. The same
ICD-json trick verifies what is actually installed: point `library_path` at
`/mnt/p3/usr/lib64/libvulkan_intel.so` and run the tests against that.
