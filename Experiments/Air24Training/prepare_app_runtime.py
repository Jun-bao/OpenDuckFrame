"""Materialize the frozen four-stage option in a fresh private trace runtime.

Only the diagnostic self-window bundle may opt in by an explicit absolute model
path. Actual loaded bytes/header provide identity. Graph/Stream timing sources,
the original resource, canonical runtime, cost package and weights stay intact.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil


GRAPH_ID = "odf-ifnet425-fourstage-acc-v1"
ORIGINAL_SHA = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
FROZEN_SHA = "729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d"
BEGIN = "// AIR_SERVICE_MODEL_IDENTITY_BEGIN"
END = "// AIR_SERVICE_MODEL_IDENTITY_END"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one private runtime anchor:{old[:90]!r}")
    return text.replace(old, new)


def patch_interpolator(text):
    text = once(text, "import Foundation\n", "import Foundation\nimport CryptoKit\n")
    text = once(text, "    private let airDiagnosticActualModelURL: URL\n",
        "    private let airDiagnosticActualModelURL: URL\n    private let airDiagnosticOverrideApplied: Bool\n")
    text = once(text, "        self.airDiagnosticActualModelURL = configuration.modelURL\n", """        let airSelection = try airSelectDiagnosticModel(configuration: configuration)
        self.airDiagnosticActualModelURL = airSelection.url
        self.airDiagnosticOverrideApplied = airSelection.overridden
""")
    text = once(text, "            self.weights = try WeightStore(url: configuration.modelURL)", """            let loaded = try WeightStore(url: airSelection.url)
            if airSelection.overridden {
                guard loaded.airDiagnosticSourceSHA256 == "FROZEN_SHA",
                      loaded.containerVersion == 2,
                      loaded.header.graphID == "GRAPH_ID",
                      loaded.header.model == "GRAPH_ID",
                      loaded.header.maskUpdate == "accumulate",
                      loaded.header.scaleList == [16, 8, 4, 2],
                      loaded.header.ifblockChannels == [192, 128, 96, 64],
                      loaded.header.tensors.count == 128 else {
                    throw RifeError.modelLoadFailed("four-stage diagnostic actual loaded model identity mismatch")
                }
            }
            self.weights = loaded""".replace("FROZEN_SHA", FROZEN_SHA).replace("GRAPH_ID", GRAPH_ID))
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise ValueError("input must provide the single trace identity getter contract")
    a = text.rfind("\n", 0, text.index(BEGIN)) + 1
    b = text.index("\n", text.index(END)) + 1
    getter = """    // AIR_SERVICE_MODEL_IDENTITY_BEGIN
    public var airDiagnosticModelIdentity: [String: Any] {
        ["stageCount": weights.header.scaleList.count,
         "graphID": weights.header.graphID.map { $0 as Any } ?? NSNull(),
         "model": weights.header.model,
         "tensorCount": weights.header.tensors.count,
         "containerVersion": weights.containerVersion,
         "actualModelPath": airDiagnosticActualModelURL.path,
         "sha256": weights.airDiagnosticSourceSHA256,
         "overrideApplied": airDiagnosticOverrideApplied]
    }
    // AIR_SERVICE_MODEL_IDENTITY_END
"""
    text = text[:a] + getter + text[b:]
    helper = """
// AIR_FOURSTAGE_DIAGNOSTIC_OVERRIDE_BEGIN
private func airSelectDiagnosticModel(configuration: RifeConfiguration) throws -> (url: URL, overridden: Bool) {
    guard let raw = ProcessInfo.processInfo.environment["ODF_AIR_FOURSTAGE_MODEL_PATH"] else {
        return (configuration.modelURL, false)
    }
    guard Bundle.main.bundleIdentifier == "app.openduckframe.SelfWindowDiagnostic" else {
        throw RifeError.modelLoadFailed("four-stage model override requires the self-window diagnostic bundle")
    }
    guard raw.hasPrefix("/"), !raw.isEmpty, configuration.modelURL.isFileURL else {
        throw RifeError.modelLoadFailed("four-stage model override requires an absolute local file path and original local model")
    }
    let original = try Data(contentsOf: configuration.modelURL, options: .mappedIfSafe)
    let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    guard digest == "ORIGINAL_SHA" else {
        throw RifeError.modelLoadFailed("four-stage diagnostic original source is not the frozen RIFE4.25 control")
    }
    return (URL(fileURLWithPath: raw).standardizedFileURL, true)
}
// AIR_FOURSTAGE_DIAGNOSTIC_OVERRIDE_END
""".replace("ORIGINAL_SHA", ORIGINAL_SHA)
    return text + helper


def prepare(source, output):
    source, output = Path(source).resolve(), Path(output).resolve()
    if output.exists():
        raise FileExistsError(output)
    relative_interpolator = Path("Sources/RifeMetal/RifeInterpolator.swift")
    text = (source / relative_interpolator).read_text()
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise ValueError("source is not the prepared trace runtime identity API")
    resource = Path("Sources/RifeMetal/Resources/rife-v4.25.rmw")
    if sha(source / resource) != ORIGINAL_SHA:
        raise ValueError("trace runtime original bundled model differs from the frozen control")
    before = {str(p.relative_to(source)): sha(p)
              for folder in ("Sources", "Plugins") for p in (source / folder).rglob("*") if p.is_file()}
    output.mkdir(parents=True)
    for folder in ("Sources", "Plugins"):
        shutil.copytree(source / folder, output / folder)
    copied_metadata = {}
    for p in source.iterdir():
        if p.is_file() and (p.name in ("Package.swift", "LICENSE", "THIRD-PARTY.md", "NOTICE")
                            or p.suffix == ".json"):
            shutil.copyfile(p, output / p.name)
            copied_metadata[p.name] = sha(p)
    core = output / "Sources/RifeMetalCore"
    store = core / "WeightStore.swift"
    for p in (output / relative_interpolator, store, core / "StudentGraphContract.swift"):
        p.chmod(p.stat().st_mode | 0o200)
    text = once(store.read_text(), "import Foundation\n", "import Foundation\nimport CryptoKit\n")
    text = once(text, "    public let containerVersion: UInt32\n",
        "    public let containerVersion: UInt32\n    public let airDiagnosticSourceSHA256: String\n")
    text = once(text, "        self.mappedData = data\n", """        self.mappedData = data
        self.airDiagnosticSourceSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
""")
    store.write_text(text)
    contract = core / "StudentGraphContract.swift"
    anchor = "    static func validate(raw: [String: Any], alignment: Data, payloadBytes: Int) throws {\n"
    added = """        if raw["graph_id"] as? String == "GRAPH_ID" {
            try FourStageGraphContract.validate(raw: raw, alignment: alignment, payloadBytes: payloadBytes)
            return
        }
""".replace("GRAPH_ID", GRAPH_ID)
    contract.write_text(once(contract.read_text(), anchor, anchor + added))
    template = Path(__file__).resolve().parent / "native/FourStageGraphContract.swift"
    shutil.copyfile(template, core / template.name)
    interpolator = output / relative_interpolator
    interpolator.write_text(patch_interpolator(interpolator.read_text()))
    after = {str(p.relative_to(output)): sha(p)
             for folder in ("Sources", "Plugins") for p in (output / folder).rglob("*") if p.is_file()}
    changed = sorted(name for name in set(before) | set(after) if before.get(name) != after.get(name))
    expected = sorted([str(relative_interpolator), "Sources/RifeMetalCore/WeightStore.swift",
                       "Sources/RifeMetalCore/StudentGraphContract.swift",
                       "Sources/RifeMetalCore/FourStageGraphContract.swift"])
    if changed != expected:
        raise ValueError(f"unexpected combined runtime source delta:{changed}")
    receipt = dict(scope="Fresh private diagnostic runtime copy only; no compile/GPU/App modification",
        input_trace_runtime=str(source), input_metadata_sha256=copied_metadata,
        preparer_sha256=sha(__file__), fourstage_contract_sha256=sha(template),
        source_before_sha256=before, generated_source_sha256=after, changed_files=changed,
        graph_and_stream_timing_unchanged=all(before.get(name) == after.get(name) for name in
            ("Sources/RifeMetalCore/IFNetGraph.swift", "Sources/RifeMetal/RifeStream.swift")),
        original_resource_sha256=sha(output / resource), frozen_candidate_sha256=FROZEN_SHA,
        graph_id=GRAPH_ID, tensors=128, expected_stage_count=4,
        opt_in_environment="ODF_AIR_FOURSTAGE_MODEL_PATH",
        allowed_main_bundle="app.openduckframe.SelfWindowDiagnostic",
        default_model_URL_unchanged_without_opt_in=True, invalid_opt_in_throws=True,
        identity_API="RifeInterpolator.airDiagnosticModelIdentity", actual_loaded_data_SHA=True)
    (output / "air-fourstage-runtime-origin.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="fresh prepared AirServiceTrace runtime")
    parser.add_argument("--output", type=Path, required=True, help="new combined runtime directory")
    args = parser.parse_args()
    print(prepare(args.source, args.output))
