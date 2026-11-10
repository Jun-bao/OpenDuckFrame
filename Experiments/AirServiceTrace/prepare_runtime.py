#!/usr/bin/env python3
"""Copy the canonical package into a fresh directory and add observation only.

No build, GPU work, model changes, or canonical writes are performed. Runtime
observation is enabled only by ODF_AIR_SERVICE_TRACE=1 and an explicit stage begin.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


HERE = Path(__file__).resolve().parent
DEFAULT_SOURCE = HERE.parents[1] / "ThirdParty/rife-metal/runtime"
COPIED = ("Package.swift", "Sources", "Plugins", "LICENSE", "THIRD-PARTY.md", "source-origin.json")
COLLECTOR = "context.airServiceTraceCollector"

CONTEXT_INSERT = '''
    // Generated AirServiceTrace support; default runs retain the original MPS class.
    package let airServiceTraceCollector: AirServiceTraceCollector? = {
        guard ProcessInfo.processInfo.environment["ODF_AIR_SERVICE_TRACE"] == "1" else { return nil }
        return AirServiceTraceCollector()
    }()
'''

API_INSERT = '''
    /// Caller serializes begin/read with makeStream/interpolate/push on its existing executor.
    public func airServiceTraceBegin(jobID: UInt64, stage: UInt32) {
        context.airServiceTraceCollector?.begin(jobID: jobID, stage: stage)
    }

    public var airServiceTraceCount: Int { context.airServiceTraceCollector?.count ?? 0 }

    public func airServiceTraceRecord(at index: Int) -> AirServiceTraceRecord {
        context.airServiceTraceCollector?.record(at: index) ?? .init()
    }

    public var airServiceTraceOverflow: UInt64 { context.airServiceTraceCollector?.overflow ?? 0 }

    // AIR_SERVICE_MODEL_IDENTITY_BEGIN
    /// Read once during preparation; this dictionary is not constructed on the inference path.
    public var airDiagnosticModelIdentity: [String: Any] {
        [
            "stageCount": weights.header.scaleList.count,
            "graphID": weights.header.graphID.map { $0 as Any } ?? NSNull(),
            "tensorCount": weights.header.tensors.count,
            "containerVersion": weights.containerVersion,
            "actualModelPath": airDiagnosticActualModelURL.path,
        ]
    }
    // AIR_SERVICE_MODEL_IDENTITY_END
'''


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected one exact source anchor: {old!r}")
    return text.replace(old, new, 1)


def instrument_graph(original: str) -> tuple[str, dict[str, int]]:
    text, constructors = re.subn(
        r"MPSCommandBuffer\(commandBuffer: (\w+)\)",
        rf"airServiceTraceMakeMPSCommandBuffer(commandBuffer: \1, collector: {COLLECTOR})",
        original,
    )
    text, commits = re.subn(
        r"\b(command|mpsCB)\.commit\(\)",
        rf"airServiceTraceCommit(\1, collector: {COLLECTOR})",
        text,
    )
    text, waits = re.subn(
        r"\b(command|mpsCB)\.waitUntilCompleted\(\)",
        rf"airServiceTraceWaitUntilCompleted(\1, collector: {COLLECTOR})",
        text,
    )
    encode = re.compile(
        r"(?P<indent>^[ \t]*)(?P<call>(?:_ = )?"
        r"(?:executable|encoderExecutable|stage\.executable|addFlowExecutable|addMaskExecutable)"
        r"\.encode\(to: (?P<cb>command|mpsCB),.*?executionDescriptor: nil\))",
        re.MULTILINE | re.DOTALL,
    )

    def around_encode(match: re.Match[str]) -> str:
        indent, call, cb = match.group("indent", "call", "cb")
        observe = f"{indent}airServiceTraceObserveRoot({cb}, collector: {COLLECTOR})"
        return f"{observe}\n{indent}{call}\n{observe}"

    text, encodes = encode.subn(around_encode, text)
    counts = dict(constructors=constructors, commits=commits, waits=waits, encodes=encodes)
    if counts != dict(constructors=7, commits=9, waits=9, encodes=13):
        raise ValueError(f"canonical command-buffer sites changed; inspect before adapting: {counts}")

    # Undo every insertion/replacement in memory. Exact equality establishes that no
    # graph operations, tensor bindings, execution descriptors, or waits were changed.
    restored = re.sub(r"^[ \t]*airServiceTraceObserveRoot\([^\n]+\)\n", "", text, flags=re.MULTILINE)
    restored = re.sub(
        rf"airServiceTraceMakeMPSCommandBuffer\(commandBuffer: (\w+), collector: {re.escape(COLLECTOR)}\)",
        r"MPSCommandBuffer(commandBuffer: \1)", restored,
    )
    for helper, method in (("airServiceTraceCommit", "commit"),
                           ("airServiceTraceWaitUntilCompleted", "waitUntilCompleted")):
        restored = re.sub(
            rf"{helper}\((command|mpsCB), collector: {re.escape(COLLECTOR)}\)",
            rf"\1.{method}()", restored,
        )
    if restored != original:
        raise ValueError("graph observation transform did not reverse exactly")
    return text, counts


def prepare(source: Path, output: Path) -> dict[str, object]:
    source = source.resolve(strict=True)
    output = output.resolve()
    if output.exists() or output == source or source in output.parents or output in source.parents:
        raise ValueError("output must be a fresh directory outside the source runtime")

    graph_rel = Path("Sources/RifeMetalCore/IFNetGraph.swift")
    context_rel = Path("Sources/RifeMetalCore/InferenceContext.swift")
    interpolator_rel = Path("Sources/RifeMetal/RifeInterpolator.swift")
    graph_original = (source / graph_rel).read_bytes().decode("utf-8")
    graph, counts = instrument_graph(graph_original)
    context_original = (source / context_rel).read_bytes().decode("utf-8")
    context_anchor = "    public let mpsGraphDevice: MPSGraphDevice\n"
    context = replace_once(context_original, context_anchor, context_anchor + CONTEXT_INSERT)
    if context.replace(CONTEXT_INSERT, "", 1) != context_original:
        raise ValueError("context transform did not reverse exactly")

    interpolator_original = (source / interpolator_rel).read_bytes().decode("utf-8")
    url_property = "    private let airDiagnosticActualModelURL: URL\n"
    url_init = "        self.airDiagnosticActualModelURL = configuration.modelURL\n"
    interpolator = replace_once(
        interpolator_original, "    private let weights: WeightStore\n",
        "    private let weights: WeightStore\n" + url_property,
    )
    interpolator = replace_once(
        interpolator, "    public init(configuration: RifeConfiguration) throws {\n",
        API_INSERT + "\n    public init(configuration: RifeConfiguration) throws {\n" + url_init,
    )
    restored_interpolator = interpolator.replace(url_property, "", 1).replace(url_init, "", 1)
    restored_interpolator = restored_interpolator.replace(API_INSERT + "\n", "", 1)
    if restored_interpolator != interpolator_original:
        raise ValueError("interpolator transform did not reverse exactly")

    files = []
    for name in COPIED:
        item = source / name
        if not item.exists():
            raise ValueError(f"canonical package input missing: {item}")
        files.extend(sorted(item.rglob("*")) if item.is_dir() else [item])
    source_hashes = {
        str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in files if path.is_file()
    }
    support = (HERE / "support.swift").read_bytes()

    output.mkdir(parents=True)
    for name in COPIED:
        item = source / name
        if item.is_dir():
            shutil.copytree(item, output / name)
        else:
            shutil.copy2(item, output / name)
    for relative, text in ((graph_rel, graph), (context_rel, context), (interpolator_rel, interpolator)):
        (output / relative).write_bytes(text.encode("utf-8"))
    (output / "Sources/RifeMetalCore/AirServiceTrace.swift").write_bytes(support)

    manifest: dict[str, object] = {
        "sourceRuntime": str(source),
        "sourceSHA256": source_hashes,
        "supportSHA256": hashlib.sha256(support).hexdigest(),
        "generatorSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "sourceOnlyChecks": {"reversibleTransforms": True, **counts},
        "traceEnvironment": "ODF_AIR_SERVICE_TRACE=1",
        "capacity": 128,
        "built": False,
        "gpuExecuted": False,
    }
    (output / "air-service-trace-source.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
    )
    return {"output": str(output), "copiedSourceFiles": len(source_hashes), **counts,
            "sourceOnly": True, "built": False, "gpuExecuted": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, required=True, help="new generated package directory")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output), ensure_ascii=False))


if __name__ == "__main__":
    main()
