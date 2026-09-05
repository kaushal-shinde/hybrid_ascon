#!/usr/bin/env python3
"""Merge raw_results.csv (latency/throughput/legacy stack col), size_results.csv
(ROM/RAM), stack_results.json (real static stack), and hand-verified spec facts
(rate/rounds, checked directly against the C references and this project's own
Verilog headers) into one final results.csv for the software analysis."""
import csv, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = "/home/nesec/Desktop/projects/ascon hybrid/software/results.csv"

raw = {}
with open(os.path.join(HERE, "raw_results.csv")) as f:
    for row in csv.DictReader(f):
        raw[row["label"]] = row

sizes = {}
with open(os.path.join(HERE, "size_results.csv")) as f:
    for row in csv.reader(f):
        label, text, data, bss = row
        sizes[label] = (int(text), int(data), int(bss))

sections = {}
with open(os.path.join(HERE, "section_results.csv")) as f:
    for row in csv.reader(f):
        label, dot_text, dot_rodata = row
        sections[label] = (int(dot_text), int(dot_rodata))

stack = json.load(open(os.path.join(HERE, "stack_results.json")))

# display name, input rate (bytes absorbed per core op -- see notes.md),
# rounds (as documented, verified against the C reference / this project's
# own Verilog transliterations written and checked earlier this session)
SPEC = {
    "ascon":        ("Ascon-AEAD128",       16, "12 init/final + 8 per block"),
    "hybrid_r128":  ("hybrid r=128",         16, "12 init/final + 8 per block"),
    "hybrid_r64":   ("hybrid r=64",           8, "12 init/final + 8 per block"),
    "tinyjambu":    ("TinyJAMBU-128",         4, "1024 (key setup) + 640/1152 (frame)"),
    "xoodyak":      ("Xoodyak",              16, "12 (fixed, every call)"),
    "giftcofb":     ("GIFT-COFB",            16, "40 (GIFT-128)"),
    "grain":        ("Grain-128AEAD",         1, "320 (init) + 256 (key/acc load)"),
    "sparkle":      ("SPARKLE",              32, "7 (slim) / 11 (big)"),
    "elephant":     ("Elephant (Dumbo)",     20, "80 (Spongent-pi[160])"),
    "isap":         ("ISAP (ISAP-A-128A)",    8, "sH=12 sB=1 sE=6 sK=12 (phase-dependent)"),
    "photonbeetle": ("PHOTON-Beetle",        16, "12 (PHOTON256)"),
    "romulus":      ("Romulus (Romulus-N)",  16, "40 (SKINNY-128-384+)"),
}

rows = []
for label, r in raw.items():
    text, data, bss = sizes[label]
    dot_text, dot_rodata = sections[label]
    st = stack[label]
    name, rate, rounds = SPEC[label]
    rows.append({
        "design": name,
        "key_bytes": r["keybytes"],
        "npub_bytes": r["npubbytes"],
        "tag_bytes": r["abytes"],
        "input_rate_bytes": rate,
        "rounds": rounds,
        "rom_bytes": text,
        "rom_dot_text_bytes": dot_text,
        "rom_dot_rodata_bytes": dot_rodata,
        "ram_bytes": data + bss,
        "stack_bytes": st["static_stack_bytes"],
        "latency_cycles": r["latency_cycles"],
        "cycles_per_byte": r["cycles_per_byte"],
        "throughput_MBps": r["MBps"],
        "dec_latency_cycles": r["dec_latency_cycles"],
        "dec_cycles_per_byte": r["dec_cycles_per_byte"],
        "dec_throughput_MBps": r["dec_MBps"],
        "dec_roundtrip_ok": r["dec_ok"],
    })

# stable order matching the hardware report's designs-first-then-finalists
order = ["ascon","hybrid_r128","hybrid_r64","tinyjambu","xoodyak","giftcofb",
         "grain","sparkle","elephant","isap","photonbeetle","romulus"]
rows_by_label = dict(zip(raw.keys(), rows))
ordered = [rows_by_label[l] for l in order]

fields = ["design","key_bytes","npub_bytes","tag_bytes","input_rate_bytes","rounds",
          "rom_bytes","rom_dot_text_bytes","rom_dot_rodata_bytes","ram_bytes","stack_bytes",
          "latency_cycles","cycles_per_byte","throughput_MBps",
          "dec_latency_cycles","dec_cycles_per_byte","dec_throughput_MBps","dec_roundtrip_ok"]
with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    for row in ordered:
        w.writerow(row)

print("wrote", OUT)

# throughput curve: same display names as SPEC above, copied alongside
# results.csv so it has one home next to the dataset it complements
CURVE_OUT = "/home/nesec/Desktop/projects/ascon hybrid/software/curve_results.csv"
name_by_label = {label: spec[0] for label, spec in SPEC.items()}
with open(os.path.join(HERE, "curve_results.csv")) as f, \
     open(CURVE_OUT, "w", newline="") as out:
    r = csv.DictReader(f)
    w = csv.DictWriter(out, fieldnames=["design", "size_bytes", "cycles_per_byte"])
    w.writeheader()
    for row in r:
        w.writerow({
            "design": name_by_label[row["label"]],
            "size_bytes": row["size_bytes"],
            "cycles_per_byte": row["cycles_per_byte"],
        })
print("wrote", CURVE_OUT)
