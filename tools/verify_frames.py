#!/usr/bin/env python3
"""Check that the firmware's frame builder matches the published Broadlink codes.

Re-implements the C++ in esphome/bedroom-ac-ir.yaml (script electra_send) in
Python and compares its half-bit stream with every frame electra_ir.py
generates, plus the captured power-toggle frame.

    git clone https://github.com/danielrosehill/electra-central-ac-ir-codes
    python3 tools/verify_frames.py path/to/electra-central-ac-ir-codes

Result on 2026-11-13: 0/120 state-frame mismatches, toggle frame identical.
"""
import os
import sys

codes_repo = sys.argv[1] if len(sys.argv) > 1 else "../electra-central-ac-ir-codes"
sys.path.insert(0, codes_repo)
import electra_ir as e  # noqa: E402

FAN = {"low": 0, "med": 1, "high": 2, "auto": 3}


def firmware_stream(toggle, mode, temp, fan):
    mv = 2 if mode == "heat" else 1
    fv, tv = FAN[fan], temp - 15
    b = [0] * 34
    b[0] = int(toggle)
    b[2], b[3] = mv >> 1 & 1, mv & 1
    b[4], b[5] = fv >> 1 & 1, fv & 1
    b[11], b[12], b[13], b[14] = tv >> 3 & 1, tv >> 2 & 1, tv >> 1 & 1, tv & 1
    b[32] = 1
    s = []
    for _ in range(3):
        s += [1, 1, 1, 0, 0, 0]
        for x in b:
            s += [0, 1] if x else [1, 0]
    return s + [1, 1, 1, 1]


template = e._template()
bad = 0
for m in e.MODE:
    for c in range(16, 31):
        for f in FAN:
            if e.to_samples(e.parse(e.generate(template, m, c, f))) != firmware_stream(False, m, c, f):
                bad += 1
                print("MISMATCH", m, c, f)
toggle = open(os.path.join(codes_repo, "raw_captures", "power_toggle.b64")).read().strip()
ok = e.to_samples(e.parse(toggle)) == firmware_stream(True, "cool", 19, "high")
print(f"state-frame mismatches: {bad}/120; power toggle identical: {ok}")
sys.exit(1 if bad or not ok else 0)
