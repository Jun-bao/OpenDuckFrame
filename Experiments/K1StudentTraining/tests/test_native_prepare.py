"""CPU-only checks of the actual native loader; no Metal device or graph is made."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


LAB = Path(__file__).resolve().parents[1]
REPO = LAB.parents[1]
PRODUCT = REPO / "ThirdParty/rife-metal/runtime"
BASE = PRODUCT / "Sources/RifeMetal/Resources/rife-v4.25.rmw"
SPEC = importlib.util.spec_from_file_location("student_native_preparer", LAB / "prepare_native.py")
PREPARER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARER)


def student_header(base, graph, ranks):
    """Derive fixtures from the real packaged dense header, replacing only b3/b4."""
    header = copy.deepcopy(base)
    header.update(model=graph, graph_id=graph, mask_update="accumulate")
    tensors = []
    for entry in header["tensors"]:
        name = entry["name"]
        stage = int(name[5]) if name.startswith("block") else -1
        if stage >= 3 and ".convblock." in name:
            if not name.endswith(".conv.weight"):
                continue
            prefix = name.removesuffix("conv.weight")
            c, rank = entry["shape"][-1], ranks[stage - 3]
            tensors.extend([
                dict(name=prefix + "conv_a.weight", dtype="f16", shape=[3, 3, c, rank]),
                dict(name=prefix + "conv_b.weight", dtype="f16", shape=[1, 1, rank, c]),
                dict(name=prefix + "conv_b.bias", dtype="f16", shape=[c]),
            ])
        else:
            tensors.append(entry)
    offset = 0
    for entry in tensors:
        size = 2
        for d in entry["shape"]:
            size *= d
        entry.update(offset=offset, size=size)
        offset += size
    header["tensors"] = tensors
    return header


def rmw(header, version=2, alignment=0, payload_delta=0):
    encoded = json.dumps(header, sort_keys=True).encode()
    # Guarantee a nonempty alignment range for the alignment rejection case.
    if alignment and (12 + len(encoded)) % 16 == 0:
        encoded += b" "
    prefix = b"RMW1" + struct.pack("<II", version, len(encoded)) + encoded
    padding = bytes([alignment]) * (-len(prefix) % 16)
    payload = sum(e["size"] for e in header["tensors"]) + payload_delta
    return prefix + padding + bytes(payload)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "requires macOS Swift compiler")
class NativeLoaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="k1-student-loader-")
        cls.out = Path(cls.temporary.name)
        cls.validator = cls.out / "validate-weights"
        (cls.out / "main.swift").write_text('''import Foundation
for path in CommandLine.arguments.dropFirst() {
    var row: [String: Any] = ["path": path]
    do {
        let store = try WeightStore(url: URL(fileURLWithPath: path))
        row["accepted"] = true
        row["graph_id"] = store.graphID
        row["mask_update"] = store.maskUpdate
        row["version"] = store.containerVersion
        row["tensors"] = store.header.tensors.count
        row["first_size"] = try store.tensorBytes(named: store.header.tensors.first!.name).count
        row["last_size"] = try store.tensorBytes(named: store.header.tensors.last!.name).count
    } catch {
        row["accepted"] = false
        row["error"] = String(describing: error)
    }
    print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
}
''')
        env = os.environ.copy()
        if "DEVELOPER_DIR" not in env and Path("/Applications/Xcode.app").exists():
            env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        subprocess.run([
            "swiftc", str(PRODUCT / "Sources/RifeMetalCore/WeightHeader.swift"),
            str(LAB / "native/StudentGraphContract.swift"), str(LAB / "native/WeightStore.swift"),
            str(cls.out / "main.swift"), "-o", str(cls.validator),
        ], check=True, capture_output=True, text=True, env=env)
        data = BASE.read_bytes()
        cls.base_header = json.loads(data[12:12 + struct.unpack_from("<I", data, 8)[0]])
        cls.primary = student_header(cls.base_header, PREPARER.GRAPH_ID, (32, 16))
        cls.diag = student_header(cls.base_header, PREPARER.DIAGNOSTIC_GRAPH_ID, (64, 32))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def validate(self, data):
        path = self.out / "case.rmw"
        path.write_bytes(data)
        result = subprocess.run([str(self.validator), str(path)], check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def test_original_packaged_d0_is_accepted_unchanged(self):
        row = self.validate(BASE.read_bytes())
        self.assertTrue(row["accepted"], row)
        self.assertEqual((row["graph_id"], row["version"], row["tensors"]), ("rife-v4.25", 1, 158))
        self.assertEqual((row["mask_update"], row["first_size"], row["last_size"]), ("accumulate", 864, 104))

    def test_explicit_student_and_full_rank_diagnostic_are_accepted(self):
        for header in (self.primary, self.diag):
            with self.subTest(graph=header["graph_id"]):
                row = self.validate(rmw(header))
                self.assertTrue(row["accepted"], row)
                self.assertEqual((row["graph_id"], row["mask_update"], row["version"], row["tensors"]),
                                 (header["graph_id"], "accumulate", 2, 158))

    def test_mask_graph_and_legacy_version_contracts_are_rejected(self):
        changes = [
            dict(mask_update="replace"),
            dict(graph_id="odf-ifnet425-b3r32-b4r16-betafold-v1",
                 model="odf-ifnet425-b3r32-b4r16-betafold-v1"),
            dict(model="rife-v4.25"), dict(graph_id="unknown"),
            dict(input_layout="NCHW"), dict(ifblock_channels=[192, 128, 96, 64, 16]),
            dict(scale_list=[8, 4, 2, 1]), dict(extra="unrecognized"),
        ]
        for change in changes:
            with self.subTest(change=change):
                header = dict(self.primary, **change)
                self.assertFalse(self.validate(rmw(header))["accepted"])
        self.assertFalse(self.validate(rmw(self.primary, version=1))["accepted"])
        legacy = dict(self.base_header, graph_id="rife-v4.25", mask_update="replace")
        self.assertFalse(self.validate(rmw(legacy, version=1))["accepted"])

    def test_tensor_layout_dtype_order_and_extra_fields_are_rejected(self):
        def changed_tensor(tensor_name, **values):
            header = copy.deepcopy(self.primary)
            next(entry for entry in header["tensors"] if entry["name"] == tensor_name).update(values)
            return header

        malformed = [
            changed_tensor("block3.convblock.0.conv_a.weight", shape=[32, 64, 3, 3]),
            changed_tensor("block0.convblock.0.beta", shape=[1, 192, 1, 1]),
            changed_tensor("block3.convblock.0.conv_b.weight", dtype="f32"),
            changed_tensor("block3.convblock.0.conv_b.bias", extra=True),
            changed_tensor("block3.convblock.0.conv_b.bias", offset=0),
            changed_tensor("block3.convblock.0.conv_b.bias", name="block3.convblock.0.beta"),
            changed_tensor("block3.convblock.0.conv_a.weight", name="block3.convblock.0.conv_a.bias"),
        ]
        swapped = copy.deepcopy(self.primary)
        swapped["tensors"][0], swapped["tensors"][1] = swapped["tensors"][1], swapped["tensors"][0]
        malformed.append(swapped)
        for i, header in enumerate(malformed):
            with self.subTest(case=i):
                self.assertFalse(self.validate(rmw(header))["accepted"])

    def test_alignment_truncated_and_trailing_payload_are_rejected(self):
        for kwargs in (dict(alignment=1), dict(payload_delta=-2), dict(payload_delta=2)):
            with self.subTest(kwargs=kwargs):
                self.assertFalse(self.validate(rmw(self.primary, **kwargs))["accepted"])
        self.assertFalse(self.validate(b"RMW1\x02")["accepted"])
        self.assertFalse(self.validate(rmw(self.primary, version=3))["accepted"])


class PreparationTests(unittest.TestCase):
    def test_branch_patch_retains_dense_skip_activation_and_has_bias_free_a(self):
        builder = (PRODUCT / "Sources/RifeMetalCore/IFBlockBuilder.swift").read_text()
        patched = PREPARER.patch_builder(builder)
        self.assertIn("g.convolution2D(x, weights: down", patched)
        self.assertIn("weight: up, bias: bias, stride: 1, padding: 0", patched)
        self.assertEqual(patched.count('let residual = g.addition(scaled, x,'), 1)
        tail = '            let residual = g.addition(scaled, x,'
        self.assertEqual(builder.split(tail, 1)[1], patched.split(tail, 1)[1])
        self.assertIn('let beta = try loadConst(name: "convblock.\\(j).beta")', patched)
        self.assertNotIn('conv_a.bias', patched)

    def test_changed_branch_anchor_fails(self):
        with self.assertRaises(ValueError):
            PREPARER.patch_builder("an unrelated graph")


if __name__ == "__main__":
    unittest.main()
