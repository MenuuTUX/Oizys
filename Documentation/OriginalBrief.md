# MView — finish the open DisplayLink driver on this Mac

You are a coding agent with a shell on **this** Mac. The DisplayLink USB dock is plugged in. Two Dell monitors are attached to it. Your job is to make **both physical Dells show a real macOS desktop** using the open-source tree in `/Users/shib/Developer/MView`, then **prove** it from measurements — not from log lines that say “bring-up finished”.

Previous agents claimed success after USB ACKs. The user then looked at the panels: **right Dell solid black, left Dell “No HDMI”**. USB ACK ≠ picture. Do not repeat that.

---

## Mission (pass/fail)

**PASS only if both Dell P2219H panels show a live extended desktop (or a known test pattern you sent), at 1920×1080, while DisplayLink Manager is not running.**

If you cannot prove the *panels* (not the Mac virtual heads) are alive, you are **not done**. Keep iterating on this hardware.

**FAIL examples:** “No HDMI” / “No Signal” on OSD, solid black, frozen first frame, one panel only, DLM still owning USB, you “think” it worked because `H' verified`.

---

## Hardware (do not rediscover)

| | |
|---|---|
| Machine | MacBook Air M3, macOS 14+ |
| Hub | USB `17e9:6000`, product `USB TO DP HDMI`, serial `PUPR293133102069826705029` |
| Chip | Ridge (DL-6xxx). Identity GET_DESCRIPTOR type `0x40` → `RidgeDoc` |
| DL3 iface | class `ff` / subclass `00` / protocol `03` |
| Control | bulk **0x02 OUT**, **0x84 IN** (keep 0x84 queued the whole session) |
| Video | Ridge bulk **0x08** and **0x0b** OUT (do not guess `0x0a`/`0x0c`) |
| Sinks | two **Dell P2219H**, 1920×1080@60, 478×269 mm |
| Vendor stack | DisplayLink Manager 15.0.0. Exclusive IOKit owner is usually `DisplayLinkUserAgent` |

Binding is **VID 17e9 + iface ff/00/03 + type-0x40 name**, not product ID.

Gold baseline: with DLM running, both Dells already work. Save that, then replace DLM.

---

## Legal / language (non-negotiable)

- Swift CLI + C. Objective-C **only** for `IOUSBHost` and `CGVirtualDisplay`. **No Rust. No C++ unless there is no other API.**
- **Do not** decompile, disassemble, Hopper/Ghidra/IDA, or copy code from `compiled_driver/` or `/Applications/DisplayLink Manager.app`.
- **Do not** `dlopen` / link vendor blobs. **Do not** flash `*.spkg`.
- **Do not** port GPL Vino **kernel sources**. Read the **public docs**, write new MIT userspace.
- Protocol source of truth, in order:
  1. Live I/O on *this* hub (`logs/`)
  2. Public Vino docs: https://github.com/FireBurn/Vino/tree/main/docs
  3. Notes already extracted in `artifacts/vino-{usb,session,ake,video-arm}.rs.txt` (GPL excerpts — **rewrite**, do not paste)
  4. HDCP 2.2 spec (AKE/LC/SKE, HMAC-SHA256 H′/L′/V′, RSA-OAEP-SHA256)
- If a string in the vendor binary disagrees with the device, **believe the device**.

---

## Repo truth (README.md and docs/AGENT-GUIDE.md are STALE)

Ignore their “AKE not yet” tables. Live `logs/run.log` already shows:

- Exclusive IOUSBHost claim after stopping DLM
- Chimera-style preamble (`0xfe`, `0xfc`, SET_INTERFACE, `0x24` start-app, `0x22` state)
- Plaintext DL3 init ACK (39B type-4/sub-0x25)
- HDCP 2.2 AKE: cert 523B **repeater=1**, H′/L′/V′ verified, STREAM_OPEN
- Encrypted CP type-4/sub-0x24 OUT, **sub-0x45 ACK IN**
- `set_mode` both heads + “black frame sent” on 0x08 and 0x0b
- **Panels still dark.** That is the remaining problem.

Also already true:

- `swift run mview probe` / `displays` / `run --takeover`
- Logs **must** stay under `logs/` (never `/tmp`)
- `--takeover` restores DLM on Ctrl-C — keep that
- Tests: `swift test` (identity, init_0, AES-CMAC NIST empty, damage map). Add tests when you add codec/CP math.

**Real bugs / gaps (start here, do not rewrite the tree):**

1. **Decoder ARM never sent.** Vino cold pipe-arm is **1104 bytes** (mode header + 5 CODE_TABLES + QUANT_TABLE). Ridge layout word **`0x4000`**. See `artifacts/vino-video-arm.rs.txt`. Current `video.c` sends a 32-byte stub then simplified `last=0` black strips. Dock cannot decode that as a desktop.
2. **Per-head video keys missing.** Vino `configure_head` is a **9-step CP loop** with its own km/rtx/rn and a **24-byte video key** (whitened ks + per-head nonce). `mview_video_refresh` then pumps head 1 with `ks=NULL`.
3. **Encoder is a stub.** Need 64×16 integer Y/Cb/Cr, Haar/WHT, VLC, max 4096-byte records. `encode.c` is damage+YCC only. Uncompressed 1080p60×2 ≈ 750 MB/s; SuperSpeed cannot carry it — encoder is mandatory.
4. **No ScreenCaptureKit** on the two `CGVirtualDisplay` heads. Do **not** start capture until a **static unique pattern** is proven on the *physical* panels.
5. Empty-head video **resets the dock**. Never scan out a head with no EDID / not present.
6. HDCP wire **seq is always 0** on this path (Chimera). Parse IN HDCP at **body[9]** as msg_id. Persistent EP84 IN ring or you drop the 522B cert.
7. Leftover `mview` may still hold the hub (`logs/mview.pid`). Kill it before a run. Restore DLM if you brick the session:
   `swift run mview start-dlm`

---

## How you know you did it right (oracle)

You have no guaranteed camera. **Do not use Mac virtual-display screenshots as proof of HDMI.** `CGVirtualDisplay` + `screencapture -D <id>` only proves the Mac compositor. DLM also uses `CGVirtualDisplay`. Fake heads can look perfect while Dells say “No HDMI”.

### A. Gold capture (DLM running, both panels known-good)

```bash
cd /Users/shib/Developer/MView
swift run mview start-dlm
sleep 3
system_profiler SPDisplaysDataType > logs/gold-displays.txt
ioreg -lw0 | grep -E 'DisplayLink|RidgeDoc|P2219|IOUSBHost' > logs/gold-ioreg.txt
swift run mview probe | tee logs/gold-probe.txt
```

### B. After every `mview run --takeover`, write `logs/verify.json` with ALL of:

| Check | PASS |
|---|---|
| USB owner | `mview` (or this process), **not** `DisplayLinkUserAgent` |
| Identity | still `RidgeDoc` |
| AKE | log contains `H' verified`, `L' verified`, `V' verified` |
| CP | at least one EP84 frame type-4 **sub 0x45** |
| Heads | dock `probe_head_present` / EDID fetch for **both** heads (Vino `fetch_edid` / `get_edid_req_sub`) |
| EDID | both look like **P2219H** (or DEL 1920×1080). Missing EDID = that panel’s “No HDMI” |
| Video EPs | bulk writes to **0x08 and 0x0b** succeed; dock did **not** reset (identity still readable) |
| Pattern | you are sending a **unique** pattern, not silent black: **head0 solid red**, **head1 solid green**, invert every 1s so a human/camera can tell “our pixels” from “TMDS black” |

Implement `swift run mview verify` (or a C helper called from `run`) that prints PASS/FAIL per row and exits non-zero unless heads+EDID+CP ACK+video EP all pass.

### C. Fault tree (OSD → cause)

| Panel | Meaning | What to fix |
|---|---|---|
| “No HDMI” / “No Signal” | link/mode/HPD failed | preamble, `configure_head`, `set_mode`, presence; **do not tune Haar** |
| Solid black, EDID present | TMDS up, decoder/encoder/keys wrong | **1104B ARM**, per-head video keys, then codec |
| Tile garbage / colorspace junk | encoder bitstream | Haar/WHT/VLC vs Vino `docs/protocol/video.md` |
| One panel only | that head’s EP/key/mode | do not “finish” with one head |
| Desktop / your red-green pattern on **both** Dells | **PASS** | then ScreenCaptureKit → real desktop |

If you have a webcam / Continuity Camera, photograph the two panels and OCR “No HDMI” vs desktop. If you do not, **stop claiming PASS** until EDID+pattern is solid **and** you have a one-line user confirm: “both Dells show red/green (or desktop)”. USB logs alone are never PASS.

### D. Compare to DLM, don’t cargo-cult it

Diff `logs/gold-displays.txt` vs mview. Matching extra `CGDirectDisplayID`s is **necessary and not sufficient**. Matching **dock EDID/HPD** is the hardware signal DLM has and you currently do not.

---

## Work order (one change per hardware run)

Do not rewrite the CLI. Do not add Rust. Do not build a capture pipeline first.

1. Kill stale mview, restore a clean USB claim.
2. Port **decoder ARM 1104B** (Ridge `0x4000`) onto both video EPs **before** strips.
3. Port **`configure_head` 9-step** + per-head 24-byte video keys from `artifacts/vino-session.rs.txt` + Vino hdcp/control docs. Wait for 0x45 ACKs.
4. `probe_head_present` + `fetch_edid` both heads. Gate scanout on presence.
5. Replace `black_strip` with a **real** 64×16 encoder. First picture: full-frame red vs green (damage map should emit every strip once). Add **one** golden test against a Vino/doc vector or a recorded strip — no giant fixture framework.
6. Hardware run. Read `logs/run.log` + `verify.json`. Use the fault table. Repeat.
7. **Only after** the physical pattern is proven: ScreenCaptureKit on the two virtual 1080p heads → damage → encode → 0x08/0x0b. Static desktop must send nothing.
8. Keep CPU below DLM’s (~40%). That is a bonus, not the PASS condition.

Loop:

```text
change one thing → swift test → kill old mview → swift run mview run --takeover
→ verify.json → if dock reset: start-dlm, stop guessing
→ next smallest fix
```

Timeouts: first `DeviceCapture` open often fails once; retry. SET_INTERFACE iface 1 without DFU claim fails; logged, non-fatal.

---

## Commands

```bash
cd /Users/shib/Developer/MView
swift test
swift run mview probe
swift run mview run --takeover    # Ctrl-C restores DLM
swift run mview start-dlm
```

If USB is stuck: `kill $(cat logs/mview.pid)` then `swift run mview start-dlm`.

---

## Done when

- [ ] DLM is **not** running
- [ ] Both P2219H show **your** pattern, then a **real desktop**
- [ ] `logs/verify.json` PASS on USB owner, AKE, CP 0x45, **both EDIDs**, both video EPs
- [ ] `swift test` green
- [ ] README updated to the **measured** table (not hopes)
- [ ] Ctrl-C still restores DLM

Until the Dells light, you are not finished. Research on the public Vino docs is allowed. Inventing a new protocol is not. Asking the user “do you see a picture?” is allowed **once per iteration** after you have EDID+pattern evidence; do not ask them to debug USB for you.
