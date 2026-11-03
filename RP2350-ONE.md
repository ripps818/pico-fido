# pico-fido on the Waveshare RP2350-One

This fork adds only files (`build-rp2350-one.sh`, `.gitignore` entries and these notes). No upstream
source is modified, so `git merge upstream/main` stays conflict-free.

## Build

```sh
export PATH=/data/tools/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin:$PATH   # arm-none-eabi-gcc 14.x
export PICO_SDK_PATH=/data/repos/raspberrypi/pico-sdk                                 # tag 2.3.1
SIGNING_KEY=/path/to/primary.pem ./build-rp2350-one.sh    # signed
./build-rp2350-one.sh                                     # unsigned, prints a warning
```

Needs `cmake`, `ninja`, `git`, `openssl` and `arm-none-eabi-gcc` (on Arch these are all in the
official repos). picotool is **not** needed on the host: the SDK builds a pinned, libusb-less copy
into `.deps/picotool` for sealing and `picotool info`. Output goes to
`/data/out/pico-fido-rp2350-one/` (`OUT_DIR` overrides it): `pico_fido.uf2`, `.elf`, `.elf.map`,
`pico_fido.otp.json` (signed only) and `build-info.txt` (commits, tool versions, options, hashes).

## What is pinned

| Setting | Value | Why |
|---|---|---|
| `PICO_BOARD` | `waveshare_rp2350_one` | Ships with pico-sdk 2.3.1: RP2350A, 4 MiB, `PICO_DEFAULT_WS2812_PIN 16` |
| `PICO_PLATFORM` | `rp2350-arm-s` | |
| pico-sdk | tag `2.3.1` | The version upstream CI uses; the script refuses anything else unless `ALLOW_SDK_MISMATCH=1` |
| `FORCE_BUTTON_WAIT` | `1` | User presence requires a BOOT press; `FORCE_BUTTON_WAIT=0` for upstream behaviour |
| submodule | must match the recorded gitlink | |

Credential storage is not set by a board define or cmake option. It comes from
`pico-keys-sdk/config/rp2350/pt.json` (data partition `0x102000`-`0x400000`, clamped to the detected
flash size). `build-info.txt` records the hash of that file; if it changes after a merge, the data
location may have moved, so read the upstream change before flashing over a device you care about.

## Button and LED

- **Button:** BOOT is the BOOTSEL line (QSPI chip-select), read by `pico-keys-sdk/src/button.c`. It is
  not a GPIO. Upstream grants user presence automatically unless `FORCE_BUTTON_WAIT` (compile time)
  or the PHY `up_btn` option (PicoKey App) is set.
- **LED:** `src/led/led.c` picks the WS2812 driver when the board header defines
  `PICO_DEFAULT_WS2812_PIN`. This one defines 16, so the LED works with no extra code. Colours:
  red = not mounted, green = mounted, blue = suspended, fast green = processing, yellow = waiting
  for the button.

## Norvix7z/PicoFido-RP2350-One (reference only, not used)

- GitHub fork of upstream, 4 real commits, based on upstream `d124ab7` (v7.6 era, now 68 commits behind).
- Net change: a README disclaimer and about 26 lines at the end of `src/fido/defs.c` defining
  `CONFIG_PRESENCE_BUTTON_PIN 45`, `CONFIG_RGB_LED_PIN 16` and similar. **Nothing in the firmware or in
  pico-keys-sdk reads those macros**, so they have no effect. The submodule is unchanged.
- "GPIO 45" does not exist on RP2350A (GPIO 0-29). The BOOT button is the QSPI_CS/BOOTSEL line,
  which the SDK reads through `ioqspi_hw`/`SIO_GPIO_HI_IN_QSPI_CSN_BITS`; the number looks invented.
- Its release UF2 (`v7.6_FW_RP2350-One.uf2`) was built as `PICO_BOARD=pico2`, which has a plain LED on
  GPIO25 and no WS2812. No crypto, attestation, or OTP source changes were found, but the binary
  cannot be verified against the source.

## Merging upstream

```sh
git fetch upstream
git merge upstream/main
git submodule update --init --recursive
./build-rp2350-one.sh          # then diff build-info.txt against the previous one (pt.json hash!)
```

Candidate improvements from other forks and open PRs are in `UPSTREAM_NOTES.md`.
Secure boot steps are in `SECURE_BOOT.md`.

License: AGPL-3.0, same as upstream. Keep the source public.
