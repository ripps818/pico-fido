# Upstream and fork notes (reference only, nothing here is applied)

Survey of the 248 forks of pico-fido and 108 forks of pico-keys-sdk, plus open upstream PRs, as of
2026-11-03. Everything was read through the GitHub API only; none of it was built or run. Treat all
fork code as untrusted. Re-derive anything you want against current upstream rather than merging a fork.

## Worth reimplementing or cherry-picking

| Item | What it does | Notes |
|---|---|---|
| upstream [PR #273](https://github.com/polhenarejos/pico-fido/pull/273) (open) | Calls `init_fido()` before USB enumeration. The first CTAPHID_INIT otherwise triggers a flash commit that blocks USB IRQs for 50-150 ms and can hang the host. | Real bug report. Touches upstream source, so apply it as its own commit. |
| [lazysaltyfish/pico2350-yubikey](https://github.com/lazysaltyfish/pico2350-yubikey) `ec16d02` | `picok_board_button_read()` (BOOTSEL/QSPI_CS read) must run inside `multicore_lockout`; otherwise core 0 disables QSPI CS while core 1 executes from XIP flash. | Directly relevant to a BOOT-button build. Check whether upstream already handles it. |
| same, `f4c4b17` | Fixes deadlocks between core 1's synchronous flash commits and USB event waits on core 0. | |
| same, `c49267f`, `c8ed08c` | Flash journal recovery after an interrupted commit; RP2350 OTP key migration that resumes safely across power loss. | Upstream has since added its own flash redo journal; compare first. |
| same, `543a33a` | Raises RP2350 core 0 and core 1 stacks to 8 KB / 16 KB (custom linker script), citing overflow in deep CTAP2/X.509 chains. | Measure stack headroom before copying. |
| same, `8a68796` | Derives the expected secure-boot key hash from the signing key instead of the hard-coded maintainer hash. | See `SECURE_BOOT.md`, section 6. |
| same, `5a773b3` | Commit retry and signature counters synchronously before reporting success. | Idea only; the commit is large. |
| [yusoofsh/pico-fido](https://github.com/yusoofsh/pico-fido) / [pico-keys-sdk](https://github.com/yusoofsh/pico-keys-sdk) | CTAPHID_CANCEL and stale-touch fixes (SDK `5c2ea87`, `462660a`). | Mostly RP2040 and test infrastructure. Ignore the SRAM PUF root key. It is RP2040-specific and security-sensitive, and the fork repoints the submodule. |
| upstream [#308](https://github.com/polhenarejos/pico-fido/pull/308) (open) | Reduces the derived scalar mod the group order. | Crypto correctness; watch for the merge. |
| upstream [#267](https://github.com/polhenarejos/pico-fido/pull/267) (open) | Sets the AAGUID at compile time. | Useful for a personal fork. |

Not worth taking: [jeffpeng3/pico-keys-sdk](https://github.com/jeffpeng3/pico-keys-sdk) `222959a`
(`PICO_AIO_FORCE_WS2812`, redundant with this board's header) and its flash-namespace change (alters
the on-flash format). Upstream PR #239 / SDK #19 (RP2350-One LED driver) is superseded by
`led_ws2812.c`. #295 (overridable fastest clock) is an RP2040 issue.

## Avoid

- Forks that change VID/PID or USB strings to impersonate Yubico, or that weaken PIN, UV or
  button requirements: Garrysoon, token2, and similar.
- [lone-sailor/pico-fido](https://github.com/lone-sailor/pico-fido): its `waveshare_rp2350_zero_cm.h`
  is a PowerShell wrapper pasted into the header, and it repoints the submodule to the author's fork.
- [rodmcastro/pico-fido](https://github.com/rodmcastro/pico-fido): trial-and-error CI and a stray
  `src/led/led.c` in the fido repo.
- Fork-built UF2 binaries (including Norvix7z's) that cannot be reproduced from source.

## Upstream state when this fork was cut

- pico-fido `99337e12` (v8.2, 2026-11-02), pico-keys-sdk submodule `d8fce97c`.
- Recent upstream merges worth knowing: button enforcement for FIDO and OATH, hardened backup restore
  authorization, U2F key-handle length validation, Brainpool fixes.
