# brunch cras profiles for SoundWire cards

`build_brunch.sh` clones the alsa-ucm-conf release matching the ChromeOS
image's alsa-lib (1.2.8 for R149–R151), copies the ChromeOS `ucm/` tree over
it, and then copies the repository's `alsa-ucm-conf/` directory on top, so
`sof-soundwire/sof-soundwire.conf` and `sof-soundwire/HiFi.conf` replace the
upstream files of the same path in `packages/alsa-ucm-conf.tar.gz`, and this
`cras/` directory is added next to them.

## Cirrus Logic SoundWire codecs under cras

Laptops whose audio is a SoundWire `cs42l43` headset codec with `cs35l56`
amplifiers (most Lunar Lake designs, Meteor/Arrow Lake Dell XPS, …) probe fine
in the kernel — SOF firmware boots, `sof-soundwire` registers its PCMs and
jacks — and still have no sound on brunch. Two things go wrong in userspace:

1. **alsa-ucm-conf 1.2.8 has no profile for these codecs.** Its
   `sof-soundwire/HiFi.conf` includes `/sof-soundwire/<codec>-<amps>.conf` for
   whatever `spk:` / `hs:` / `mic:` the card reports; for `cs35l56` /
   `cs42l43` that file does not exist, alsa-lib refuses to load the UCM, and
   cras logs `No ucm config on internal card sof-soundwire`. The profiles were
   added in alsa-ucm-conf 1.2.11, but from 1.2.13 the sof-soundwire profile is
   UCM Syntax 7+, which alsa-lib 1.2.8 rejects (`SYNTAX_VERSION_MAX` is 6), so
   the upstream files cannot simply be dropped in.
2. **Without a UCM, cras guesses nodes from mixer control names** — it looks
   for simple mixer elements called `Headphone`, `Speaker`, `HDMI`, `Mic`, …
   and puts every node it finds on the first PCM of the card. On these codecs
   every control is prefixed (`cs42l43 Headphone Digital`, `AMP1 Speaker`), so
   nothing matches, and cras invents a phantom `Speaker` node on PCM 0 — the
   headphone path. The real speakers sit on PCM 2 and are never opened, and
   the amplifiers' `AMPn Speaker Switch` is never turned on.

The overlay keeps the 1.2.8 profile's behaviour for every other codec and,
when *all* codecs on the card are Cirrus (or the PCH DMIC), switches to the
`cras/` device profiles and sets `FullySpecifiedUCM "1"`, the ChromeOS mode in
which cras builds its nodes from the UCM `SectionDevice`s instead of guessing:

| device | PCM | what it does |
|---|---|---|
| `Speaker` | 2 | turns on each `AMPn Speaker Switch` that exists, hands cras the `AMPn Speaker` volume elements as coupled mixers (`cs35l56`), or routes DP6 into the cs42l43's own speaker amp (`cs42l43-spk`) |
| `Headphone` | 0 | routes DP5 to the headphone amp; plug state from the `<card> Jack` input device |
| `Mic` (headset) | 1 | ADC1 → Decimator 1 → DP2; plug state from the same input device |
| `Internal Mic` | 4 | cs42l43 DMICs (Decimators 3/4, or 5/6/3/4 on CS42L43B) → DP1 |
| `Internal Mic` | by name | PCH DMIC (`DMIC Raw` PCM) when the card reports `mic:dmic` |
| `HDMI1..3` | 5..7 | as upstream, but jacks via `JackDev` |

### Realtek rt722

The same treatment for the rt722, the SDCA codec most non-Cirrus Lunar Lake
laptops use: one SoundWire peripheral carrying the headset codec, the speaker
amplifier and the DMICs, reported as `hs:rt722 spk:rt722 mic:rt722`. Upstream
1.2.8 fails on it the same way (it would include `rt722-1.conf`, which does not
exist). `cras/rt722.conf` covers all three functions from one file — Headphone
on PCM 0 / headset Mic on PCM 1 (`<card> Headset Jack` input device), Speaker on
PCM 2, Internal Mic on PCM 4 — using the machine driver's `Headphone Switch` /
`Headset Mic Switch` / `Speaker Switch` pin switches and the codec's `rt722 FU05`
/ `FU0F` / `FU06` / `FU1E` volume elements. The ADC mux and volume settings
upstream applies from a `BootSequence` (which cras never runs) are folded into
the device enable sequences. With the PCH DMICs present (`mic:dmic`) the
rt722 microphone section is skipped and `cras/dmic.conf` supplies the node.
Mixed designs such as rt722 + rt1320 amplifiers are not covered and keep the
upstream 1.2.8 behaviour.

Rules the files follow, all forced by how cras (R150 `cras_alsa_card.c` /
`cras_alsa_ucm.c` / `cras_alsa_jack.c`) consumes a fully specified UCM:

- Node names are cras's: `Speaker` and `Internal Mic` are internal (always
  plugged); `Headphone`, `Mic` and `HDMIn` are external and need a jack.
- `PlaybackMixerElem` / `CaptureMixerElem` / `CoupledMixers` are declared only
  behind `ControlExists`, because cras aborts the whole card when a declared
  element is missing. The amplifier count is discovered the same way rather
  than trusting `cfg-amp:`.
- Jacks use `JackDev` (the jack's input device) rather than `JackControl`: in
  this mode cras looks a `JackControl` up with the PCM number as the ALSA
  control's device field, but the kernel registers jack controls with device
  0, and a missing hctl jack is fatal for the card while a missing input
  device only costs plug detection.
- Everything is UCM Syntax 6 and uses only alsa-lib 1.2.8 features (nested
  `If` instead of sibling blocks appending to a variable, no `LibraryConfig`
  remaps). Multi-channel switches and volumes are written one value per
  channel for clarity; alsa-lib applies a single value to every channel too.
- The PCM numbers and control names come from the kernel 7.1 tree
  (`sound/soc/sdw_utils/`, `sound/soc/codecs/cs42l43.c`, `cs35l56.c`) and the
  upstream alsa-ucm-conf 1.2.16 profiles, which are what desktop distros run
  on this hardware.

Status: written against source and the shipped topologies, not yet
confirmed on a SoundWire machine — the reference laptop is HDA. First report
that motivated it: Dell XPS 14 9440 (cs42l43 + 2× cs35l56). The rt722 profile
has had no report at all yet.
