"""Fresh four-stage quality-only state probe, reusing the existing dump patch.

No previously measured cost source, binary or package is modified. The sole
expected accumulated state is final stage3; no nonexistent stage4 is requested.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import shutil

import model
import prepare_native


def prepare(source, output):
    output=prepare_native.prepare(source,output)
    prior=Path(__file__).resolve().parent.parent/"K1StudentTraining/numerical_probe.py"
    spec=importlib.util.spec_from_file_location("_odf_existing_state_patch",prior)
    patch=importlib.util.module_from_spec(spec);spec.loader.exec_module(patch)
    main=output/"Sources/k1-runtime/main.swift";graph=output/"Sources/RifeMetalCore/IFNetGraph.swift"
    original_hashes={str(p.relative_to(output)):model.sha(p) for p in (main,graph)}
    main.write_text(patch.patch_main(main.read_text()))
    graph.write_text(patch.patch_graph(graph.read_text()).replace("i == 3 || i == 4","i == 3"))
    helper=prior.parent/"native/StudentStateDump.swift"
    text=helper.read_text()
    old='["stage3_flow.npy", "stage3_mask.npy", "stage4_flow.npy", "stage4_mask.npy"]'
    if text.count(old)!=1:raise ValueError("expected one existing state-file contract")
    text=text.replace(old,'["stage3_flow.npy", "stage3_mask.npy"]')
    text=text.replace("block3/4 accumulated flow", "final four-stage block3 accumulated flow")
    destination=output/"Sources/RifeMetalCore/StudentStateDump.swift";destination.write_text(text)
    report=dict(scope="Quality-only fresh source copy, no GPU; invalid for timing/cost",final_stage=3,
                source_origin_sha256=model.sha(output/"source-origin.json"),
                prior_patch_sha256=model.sha(prior),prior_helper_sha256=model.sha(helper),
                uninstrumented_sources_sha256=original_hashes,
                generated_sources_sha256={str(p.relative_to(output)):model.sha(p) for p in (main,graph,destination)},
                source_preparer_sha256=model.sha(__file__),cost_binary_or_package_modified=False,
                environment_switch="ODF_STUDENT_STATE_DUMP_DIR",dtype="native FP16 to lossless float32 NPY")
    (output/"probe-source-origin.json").write_text(json.dumps(report,indent=2)+"\n")
    return output


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source",type=Path,required=True);ap.add_argument("--output",type=Path,required=True)
    args=ap.parse_args();print(prepare(args.source,args.output))
