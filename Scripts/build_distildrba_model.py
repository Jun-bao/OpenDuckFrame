#!/usr/bin/env python3
"""Convert pinned DistilDRBA V1 to a fixed 720p midpoint Core ML model.

Run with the task-local torch/coremltools environment. The output directory must
not already exist; the script never installs packages or modifies the upstream.
"""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
source, output = args.source.resolve(), args.output.resolve()
commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
if commit != 'db51bdeb452685cba9aee227c6dba42e67753b55':
    raise SystemExit('unexpected DistilDRBA source revision')
if subprocess.run(['git', '-C', str(source), 'diff', '--quiet', 'HEAD', '--'], check=False).returncode:
    raise SystemExit('DistilDRBA tracked source has local changes')
weights = source / 'weights/v1.pkl'
if hashlib.sha256(weights.read_bytes()).hexdigest() != '3096c7228f2159628184ab9dc78484e29b1c031eb68ff7c17ebb23f72726a96f':
    raise SystemExit('unexpected DistilDRBA V1 weights')
if output.exists():
    raise SystemExit('output already exists')
import numpy as np
import torch
import coremltools as ct
sys.path.insert(0, str(source))
import models.drba.warplayer as warp
from models.drba.distilDRBA import IFNet
warp.device = torch.device('cpu')
torch.set_num_threads(4)
net = IFNet().eval()
net.load_state_dict(torch.load(weights, map_location='cpu', weights_only=True), strict=True)
class Midpoint(torch.nn.Module):
    def __init__(self, network):
        super().__init__()
        self.network = network
    def forward(self, a, b, c):
        return self.network(a, b, c, None, None, None, 1.5, [16, 8, 4, 2, 1])[0]

torch.manual_seed(8)
inputs = tuple(torch.rand((1, 3, 768, 1280)) for _ in range(3))
model = Midpoint(net).eval()
with torch.inference_mode():
    expected = model(*inputs).numpy()
    warp.backwarp_tenGrid.clear()
    trace = torch.jit.trace(model, inputs, check_trace=False)
converted = ct.convert(trace, inputs=[ct.TensorType(name=name, shape=t.shape) for name, t in zip(('previous', 'current', 'next'), inputs)], convert_to='mlprogram', minimum_deployment_target=ct.target.macOS14, compute_units=ct.ComputeUnit.CPU_ONLY, compute_precision=ct.precision.FLOAT32)
prediction = np.asarray(next(iter(converted.predict({n: t.numpy() for n, t in zip(('previous', 'current', 'next'), inputs)}).values())))
mean_error = float(np.mean(np.abs(prediction - expected)))
max_error = float(np.max(np.abs(prediction - expected)))
if mean_error >= .01 or not np.isfinite(prediction).all():
    raise SystemExit(f'Core ML validation failed: mean={mean_error}, max={max_error}')
output.parent.mkdir(parents=True, exist_ok=True)
converted.save(str(output))
print(json.dumps({'revision': commit, 'torch': torch.__version__, 'coremltools': ct.__version__, 'mean_abs_error': mean_error, 'max_abs_error': max_error, 'output': str(output)}))
