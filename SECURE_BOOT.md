# Secure boot plan for the RP2350-One build (documentation only)

Nothing in this repo burns OTP or enables secure boot. This is a plan to follow by hand.
**Everything marked IRREVERSIBLE cannot be undone.** Nothing below was run against hardware
when this was written, so dry-run the key/JSON steps and read each command's `--help` first.

Sources: `pico-keys-sdk/src/otp/otp_rp2350.c`, `pico-keys-sdk/src/rescue.c`,
`pico-keys-sdk/config/rp2350/secure_boot.json`, pico-sdk 2.3.1 `otp_data.h`, picotool 2.3.1,
and https://docs.picokeys.com/production/otp-fuses/.

## 0. What is already irreversible (before you touch secure boot)

On the first boot of **any** pico-fido build on RP2350, signed or not, the firmware
(`otp_platform_init`):

- writes a random 32-byte **MKEK** to OTP row `0xE90` and a generated secp256k1 **DEVK** to `0xE80`;
- writes bitwise-complement "chaff" copies at `0xEB0` / `0xEA0`;
- locks OTP page 58 (rows `0xE80`-`0xEBF`) so only Secure code can read it.

Credentials are encrypted under keys derived from that MKEK. Without secure boot, anyone who can
flash firmware to the stick can run Secure code and read it. Secure boot is what closes that hole.

Credential storage placement is not an OTP matter: it comes from `config/rp2350/pt.json` in the
firmware, and `build-info.txt` records its hash.

## 1. Trust model: your key plus the maintainer's

pico-fido's own status check (`otp_platform_is_secure_boot_enabled`) looks for the **maintainer's**
hard-coded boot-key hash (`E1D16BA764ABD712D4EF6E3EDD744ED5638C260B771CF98151110BAFAC9BC871`) in
any slot. To keep PicoKey App working and to be able to run official signed builds, enroll:

| Slot | Contents | Purpose |
|---|---|---|
| bootkey0 | your primary key | your builds |
| bootkey1 | maintainer's hash | official builds; PicoKey App reports "secure boot enabled" |
| bootkey2 | your backup key (optional) | recovery if the primary key is lost or compromised |
| bootkey3 | CI signing key (GitHub secret `SIGNING_KEY_PEM`) | lets you flash the signed GitHub release |

Trade-off: whoever holds the maintainer's private key can boot code that reads your MKEK. You can
revoke slot 1 later by setting its `KEY_INVALID` bit (also irreversible; PicoKey App will then show
secure boot as disabled).

RP2350 has four boot-key slots (`BOOT_FLAGS1.KEY_VALID` is 4 bits). The firmware loops over six,
but only 0-3 exist.

**CI key (slot 3).** The release workflow signs with a dedicated key stored only as the repo secret
`SIGNING_KEY_PEM`; no copy exists elsewhere, and it cannot be read back from GitHub. To enroll it,
build a key-only JSON the same way as in step 4 from any CI-signed build's `pico_fido.otp.json`
(use `bootkey3`), then include it in step 5 and add `0x8` to the `KEY_VALID` mask in step 6
(`0xF` for all four slots). If you would rather not trust CI at all, skip slot 3 and sign locally.
Because slot 3 is used, the step 8 hardening should not invalidate it. Rotating the secret later means
a new key that needs a new slot, so only do that before burning, or accept losing slot 3.

## 2. Generate keys (you do this, offline)

```sh
openssl ecparam -name secp256k1 -genkey -noout -out primary.pem
openssl ecparam -name secp256k1 -genkey -noout -out backup.pem
chmod 600 *.pem
```

Store them somewhere that is not this repo and is backed up. `*.pem` and `*.key` are git-ignored,
and `build-rp2350-one.sh` refuses a key that is tracked by git.

## 3. picotool for the device-side steps (no AUR)

`build-rp2350-one.sh` builds a libusb-less picotool (via the SDK) that can seal and inspect but
cannot talk to a device. For device steps, build picotool from source with official packages:

```sh
sudo pacman -S --needed cmake libusb gcc git     # official repos
git clone --branch 2.3.1 --depth 1 https://github.com/raspberrypi/picotool
cmake -S picotool -B picotool/build -DPICO_SDK_PATH=/path/to/pico-sdk   # pico-sdk tag 2.3.1
cmake --build picotool/build
sudo install picotool/build/picotool /usr/local/bin/   # or run it in place
```

Run it as root or install the udev rules from `picotool/udev/99-picotool.rules`.
Put the stick in BOOTSEL (hold BOOT while plugging in).

## 4. Order of operations

1. **Build signed** with your primary key and keep the output:
   `SIGNING_KEY=/safe/place/primary.pem ./build-rp2350-one.sh`
2. **Flash and test with secure boot still off.** Copy `pico_fido.uf2` to the BOOTSEL drive.
   Confirm it enumerates, the LED works, registration works with a BOOT press, and that the first
   boot wrote the MKEK (`picotool otp get 0xE90` is *not* readable by design; judge by it working).
3. **Check the signing output.** `picotool info -a pico_fido.uf2` should show
   `signature: verified` and `rollback version: 5`.
4. **Create key-only OTP JSON files.** `picotool seal` writes `pico_fido.otp.json` and
   `pico-keys-sdk/config/rp2350/secure_boot.json` ships one, but **both also contain
   `crit1.secure_boot_enable: 1`, which would turn secure boot on the moment they are loaded.**
   Strip everything except the key:

```sh
python3 -I - <<'EOF'
import json
def keyonly(src, slot, dst):
    d = json.load(open(src))
    json.dump({"bootkey%d" % slot: d["bootkey0"]}, open(dst, "w"), indent=4)
keyonly("pico_fido.otp.json", 0, "slot0-primary.json")
keyonly("pico-keys-sdk/config/rp2350/secure_boot.json", 1, "slot1-maintainer.json")
EOF
```

   For the backup key, build or seal once with `SIGNING_KEY=backup.pem` (e.g. into a different
   `OUT_DIR`) and run `keyonly(..., 2, "slot2-backup.json")` on its `pico_fido.otp.json`.
   Check that `slot1-maintainer.json`'s bytes spell `E1D16BA7...C871`.
5. **Load the key hashes (IRREVERSIBLE per slot):**

   ```sh
   picotool otp load slot0-primary.json
   picotool otp load slot1-maintainer.json
   picotool otp load slot2-backup.json      # optional
   ```

   `otp load` takes JSON and writes the key rows with ECC. Verify each with `picotool otp list -p`
   or `picotool otp get BOOTKEY0_0` (same for 1 and 2) and compare against the hashes.
6. **Mark the slots valid (IRREVERSIBLE):** with all of slots 0, 1 and 2 enrolled,
   `picotool otp set BOOT_FLAGS1.KEY_VALID 0x7`. (Slots 0+1 only: `0x3`.) This field is stored with
   3 redundant raw copies; picotool handles that. Read it back with
   `picotool otp get BOOT_FLAGS1`.
7. **Enable secure boot (IRREVERSIBLE):** `picotool otp set CRIT1.SECURE_BOOT_ENABLE 1`.
   From now on the boot ROM only runs images signed by a valid slot. Do this **only after** step 2
   proved your signed image boots and step 6 read back correctly. An unsigned image, or one signed
   by an unenrolled key, will not boot (the chip stays in BOOTSEL, where you can still load a signed
   UF2).
8. **Optional hardening (IRREVERSIBLE), only after steps 1-7 are verified:**
   - Retire unused slots: `picotool otp set BOOT_FLAGS1.KEY_INVALID 0x8` (slot 3 here, `0xC` for 2 and 3).
     Do **not** invalidate slots you enrolled.
   - Disable debug access: `picotool otp set CRIT1.DEBUG_DISABLE 1`.
   - Glitch detector: `picotool otp set CRIT1.GLITCH_DETECTOR_ENABLE 1` and
     `picotool otp set CRIT1.GLITCH_DETECTOR_SENS 3`.
   - Optionally set the page 1 and 2 `LOCK_BL` bits read-only, as PicoKey App's secure lock does.
     Check `picotool otp permissions --help` first.
9. **Verify:** reboot, flash a signed build (works) and an unsigned or other-key build
   (should be rejected). Confirm PicoKey App reports secure boot enabled.

`CRIT1.*` and `BOOT_FLAGS1.*` field names come from pico-sdk 2.3.1 `otp_data.h`; picotool derives its
selector names from that file. If a name is rejected, run `picotool otp list -z <fragment>`
(fuzzy) to find the current spelling before writing anything.

## 5. Things not to do

- **Do not use PicoKey App's secure lock** (rescue `INS 0x1D`, `P2=1`). It sets `KEY_INVALID` on every
  slot except the one it enrolls, which would invalidate your own key.
- Its plain "enable" (`P2=0`, `P1=1`) is harmless once slot 1 already holds the maintainer's hash, but
  enrolling by hand is clearer and avoids surprises.
- Do not enable secure boot while running an unsigned build, or before you have verified a signed
  build boots. The firmware does not check this for you.
- Do not commit `*.pem`, `pico_fido.otp.json` or the `slot*.json` files. They contain only public
  hashes, but they are git-ignored anyway.
- Do not flash firmware older than the 2025-10-06 pico-keys-sdk OTP migration commits (`e14a12b`,
  `a7e1cf0`) after running current firmware: the old MKEK/DEVK rows are overwritten with `0xFF`
  during migration.

## 6. Status, rollback and later options

- **PicoKey App status.** "Enabled" requires the maintainer's hash in a valid slot (slot 1 above).
  "Locked" additionally requires every *other* slot invalidated plus the debug and glitch bits, so
  with your own key enrolled it will never read "locked". The device is still protected by the OTP
  bits themselves.
- **Rollback.** Signed images embed `ROLLBACK 5` (`cmake/version.cmake`). That is image metadata; the
  firmware never burns the anti-rollback floor. Raising it is a separate OTP decision, see
  https://docs.picokeys.com/production/anti-rollback/ . Burning it prevents loading older signed images.
- **Alternative: patch the firmware** to derive the expected hash from `SECURE_BOOT_PKEY` instead of
  hard-coding the maintainer's (lazysaltyfish/pico2350-yubikey commit `8a68796` does this). It touches
  `pico-keys-sdk/src/otp/otp_rp2350.c`, so it was left out to keep upstream merges clean.
