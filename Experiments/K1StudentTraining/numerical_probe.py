"""Prepare a copied quality-only runtime for bounded block3/4 state probes.

Preparation/build is CPU-only. The original runtime/binary stays untouched.
The new binary requires ODF_STUDENT_STATE_DUMP_DIR and an ordinary quality
CONFIG.json with one alpha per target set; root runs it later under the GPU lock.
Existing RIFE_DUMP readback is reused, adding barriers only in this copied probe.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one diagnostic patch anchor: {old[:70]!r}")
    return text.replace(old, new)


def patch_main(text):
    text = once(text, '    let mode = config["mode"] as! String', '''    let mode = config["mode"] as! String
    guard mode == "quality" else { throw BenchError.configuration("state probe only supports quality mode") }
    try StudentStateDump.requireConfigured()''')
    text = once(text, '''                    let id = variant["id"] as! String, stream = streams[id]!
                    stream.reset()''', '''                    let id = variant["id"] as! String, stream = streams[id]!
                    try StudentStateDump.begin(caseID: caseID, variant: id, targets: targets,
                        width: width, height: height, tier: config["tier"] as! String)
                    stream.reset()''')
    text = once(text, '''                    let ms = elapsed(start)
                    guard frames.count == targets.count''', '''                    let ms = elapsed(start)
                    try StudentStateDump.finish()
                    guard frames.count == targets.count''')
    return text


def patch_graph(text):
    anchor = "if let dumpDir = dumpDir {"
    if text.count(anchor) != 2:
        raise ValueError("expected existing stateless and streaming stage-dump paths")
    return text.replace(anchor, "if let dumpDir = dumpDir, i == 3 || i == 4 {")


def prepare(source, output):
    source, output = Path(source).resolve(), Path(output).resolve()
    if output.exists():
        raise FileExistsError(output)
    origin = json.loads((source / "source-origin.json").read_text())
    if origin.get("graph_contracts", {}).get("odf-ifnet425-acc-b3r32-b4r16-v1") != [32, 16]:
        raise ValueError("source must be the already prepared accumulated-mask student runtime")
    originals = {str(p.relative_to(source)): sha(p)
                 for directory in ("Sources", "Plugins") for p in (source / directory).rglob("*") if p.is_file()}
    for name, digest in origin["generated"].items():
        if originals.get(name) != digest:
            raise ValueError(f"prepared source no longer matches its source manifest: {name}")
    output.mkdir(parents=True, exist_ok=False)
    for directory in ("Sources", "Plugins"):
        shutil.copytree(source / directory, output / directory)
    for name in ("Package.swift", "LICENSE"):
        shutil.copyfile(source / name, output / name)
    main = output / "Sources/k1-runtime/main.swift"
    graph = output / "Sources/RifeMetalCore/IFNetGraph.swift"
    for path in (main, graph):
        path.chmod(path.stat().st_mode | 0o200)
    main.write_text(patch_main(main.read_text()))
    graph.write_text(patch_graph(graph.read_text()))
    helper = Path(__file__).resolve().parent / "native/StudentStateDump.swift"
    shutil.copyfile(helper, output / "Sources/RifeMetalCore/StudentStateDump.swift")
    receipt = dict(
        scope="diagnostic source copy only; no GPU/model execution by preparer",
        source=str(source), source_origin_sha256=sha(source / "source-origin.json"),
        original_sources_sha256=originals,
        generated_sources_sha256={str(p.relative_to(output)): sha(p)
            for directory in ("Sources", "Plugins") for p in (output / directory).rglob("*") if p.is_file()},
        helper_sha256=sha(helper), preparer_sha256=sha(__file__),
        package_sha256=sha(output / "Package.swift"), license_sha256=sha(output / "LICENSE"),
        environment_switch="ODF_STUDENT_STATE_DUMP_DIR", mode="quality",
        dumped_stages=[3, 4], accumulated_mask_logits=True, native_compute_dtype="FP16",
        export_dtype="float32 NPY (converted from native FP16)", layout="NHWC",
        original_binary_modified=False, performance_results_valid=False,
        note="Reuse existing synchronized RIFE_DUMP blit/readback; per-query directories avoid overwrites.")
    (output / "probe-source-origin.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="existing prepared student native directory")
    parser.add_argument("--output", type=Path, required=True, help="new isolated diagnostic runtime directory")
    args = parser.parse_args()
    print(prepare(args.source, args.output))


if __name__ == "__main__":
    main()
