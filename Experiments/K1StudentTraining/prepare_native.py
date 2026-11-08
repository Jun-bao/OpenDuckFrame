"""Prepare an isolated accumulated-mask student on the actual product runtime.

Starts from the unchanged K1Execution product preparer, retaining its native I/O,
accumulated masks, quality/controlled CLI, licensing, and source manifest. Only
the new copy receives the strict student loader and b3/b4 residual factorization.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


SOURCE_COMMIT = "ac6408022eb6bc1a53181f5b2716a9f5ded507c2"
GRAPH_ID = "odf-ifnet425-acc-b3r32-b4r16-v1"
DIAGNOSTIC_GRAPH_ID = "odf-ifnet425-acc-b3r64-b4r32-diag-v1"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one product source anchor: {old[:70]!r}")
    return text.replace(old, new)


def verify_source(source):
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if commit != SOURCE_COMMIT:
        raise ValueError(f"expected raw product source {SOURCE_COMMIT}, got {commit}")
    changed = subprocess.check_output([
        "git", "-C", str(source), "status", "--porcelain", "--untracked-files=all", "--",
        "Sources/RifeMetal", "Sources/RifeMetalCore", "Plugins", "LICENSE",
    ], text=True)
    if changed:
        raise ValueError("raw product source has local changes in the copied scope")


def patch_builder(text):
    start = '            let w = try loadConst(name: "convblock.\\(j).conv.weight")'
    end = '            let residual = g.addition(scaled, x, name: "\\(prefix)convblock.\\(j).add")'
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("expected one original product ResConv branch")
    a, b = text.index(start), text.index(end)
    dense = text[a:b].replace("            let scaled = ", "            scaled = ")
    dense = "\n".join("    " + line if line else line for line in dense.rstrip().splitlines())
    branch = '''            let scaled: MPSGraphTensor
            if StudentGraphContract.ranks[weights.header.model] != nil,
               prefix == "block3." || prefix == "block4." {
                let down = try loadConst(name: "convblock.\\(j).conv_a.weight")
                let up = try loadConst(name: "convblock.\\(j).conv_b.weight")
                let bias = try loadConst(name: "convblock.\\(j).conv_b.bias")
                let descriptor = MPSGraphConvolution2DOpDescriptor(
                    strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1,
                    groups: 1, paddingLeft: 1, paddingRight: 1, paddingTop: 1, paddingBottom: 1,
                    paddingStyle: .explicit, dataLayout: .NHWC, weightsLayout: .HWIO)!
                // A is a genuine bias-free 3x3 convolution. Beta is already folded
                // into B and its bias; the original skip and LeakyReLU follow below.
                let reduced = g.convolution2D(x, weights: down, descriptor: descriptor,
                    name: "\\(prefix)convblock.\\(j).conv_a")
                scaled = g.rifeConv2D(input: reduced, weight: up, bias: bias, stride: 1, padding: 0,
                    name: "\\(prefix)convblock.\\(j).conv_b")
            } else {
'''
    return text[:a] + branch + dense + "\n            }\n" + text[b:]


def prepare(source, output):
    source, output = source.resolve(), output.resolve()
    if output.exists():
        raise FileExistsError(output)
    verify_source(source)
    here = Path(__file__).resolve().parent
    product_preparer = here.parent / "K1Execution/prepare_product_native.py"
    subprocess.run([sys.executable, "-B", str(product_preparer), "--source", str(source),
                    "--output", str(output)], check=True, stdout=subprocess.PIPE, text=True)
    origin_path = output / "source-origin.json"
    product_origin = json.loads(origin_path.read_text())
    core = output / "Sources/RifeMetalCore"
    for name in ("StudentGraphContract.swift", "WeightStore.swift"):
        shutil.copyfile(here / "native" / name, core / name)
    # The old narrow-student contract belongs to K1Execution, not this experiment.
    (core / "NarrowGraphContract.swift").unlink()
    builder = core / "IFBlockBuilder.swift"
    builder.write_text(patch_builder(builder.read_text()))
    weights = Path("Sources/RifeMetal/Resources/rife-v4.25.rmw")
    if sha(source / weights) != sha(output / weights) or sha(source / "LICENSE") != sha(output / "LICENSE"):
        raise ValueError("packaged original weights or licensing changed")
    origin = dict(
        source=str(source), source_commit=SOURCE_COMMIT,
        product_preparation=product_origin, product_preparer_sha256=sha(product_preparer),
        student_preparer_sha256=sha(Path(__file__)),
        student_sources_sha256={name: sha(here / "native" / name)
                               for name in ("StudentGraphContract.swift", "WeightStore.swift")},
        generated={str(p.relative_to(output)): sha(p) for p in (output / "Sources").rglob("*") if p.is_file()},
        package_sha256=sha(output / "Package.swift"), license_sha256=sha(output / "LICENSE"),
        packaged_weights_sha256=sha(output / weights), weights_unchanged=True,
        graph_contracts={GRAPH_ID: [32, 16], DIAGNOSTIC_GRAPH_ID: [64, 32]},
        mask_update="accumulate", input_layout="NHWC",
        cli="k1-runtime CONFIG.json", base_product_math_unchanged=True,
        note="Only generated loader and b3/b4 ResConv branch differ from the product preparation. "
             "GPU input padding/direct crop are per-variant flags and must match in both comparison arms.")
    origin_path.write_text(json.dumps(origin, indent=2) + "\n")
    return output


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, required=True, help="raw pinned upstream checkout")
    ap.add_argument("--output", type=Path, required=True, help="new isolated native directory")
    args = ap.parse_args()
    print(prepare(args.source, args.output))


if __name__ == "__main__":
    main()
