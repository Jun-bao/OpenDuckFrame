#!/usr/bin/env python3
"""Reproduce bundled ArtCNN models from pinned original ONNX coefficients.

Export only: Python 3.12, torch 2.7.0, coremltools 9.0, onnx 1.23.2,
numpy 2.2.6. Ordinary Xcode builds use the exported packages, without Python ML.
"""
from pathlib import Path
import hashlib
import json
import os
os.environ.setdefault('OMP_NUM_THREADS', '2')
import numpy as np
import onnx
from onnx import numpy_helper
import torch
from torch import nn
import torch.nn.functional as F
import coremltools as ct

ROOT = Path(__file__).resolve().parents[1]
REVISION = '0837e5326e710f49e2ab0a8d995da0708047442e'

class ArtCNN(nn.Module):
    def __init__(self, graph):
        super().__init__()
        arrays = {x.name: numpy_helper.to_array(x).copy() for x in graph.graph.initializer}
        layers = []
        for i in range(7):
            weight = torch.from_numpy(arrays['kernel_oih_' + str(i)])
            bias = torch.from_numpy(arrays['const_' + str(2*i + 1)])
            layer = nn.Conv2d(weight.shape[1], weight.shape[0], 3, padding=1)
            layer.weight.data.copy_(weight)
            layer.bias.data.copy_(bias)
            layers.append(layer)
        self.convs = nn.ModuleList(layers)

    def forward(self, x):
        head = self.convs[0](x)
        y = head
        for i in range(1, 5):
            y = F.relu(self.convs[i](y))
        return F.pixel_shuffle(self.convs[6](self.convs[5](y) + head), 2).clamp(0, 1)


def main():
    torch.set_num_threads(2)
    records = []
    origin = ROOT / 'ThirdParty/artcnn/source-origin.json'
    pins = json.loads(origin.read_text())
    for features in (16, 32):
        name = f'ArtCNN_C4F{features}'
        source = ROOT / 'ThirdParty/artcnn' / (name + '.onnx')
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if digest != pins['models'][name]['originalONNXSHA256']:
            raise ValueError(f'Original ONNX hash mismatch: {name}')
        model = ArtCNN(onnx.load(source)).eval()
        with torch.no_grad():
            traced = torch.jit.trace(model, torch.zeros(1, 1, 24, 32))
        shape = ct.Shape((1, 1, ct.RangeDim(2, 1080, default=540), ct.RangeDim(2, 1920, default=960)))
        converted = ct.convert(traced, source='pytorch', convert_to='mlprogram',
            inputs=[ct.TensorType(name='input', shape=shape, dtype=np.float16)],
            outputs=[ct.TensorType(name='output', dtype=np.float16)],
            minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT16, skip_model_load=True)
        converted.author = 'João Chrisóstomo / Artoriuz; OpenDuckFrame format conversion'
        converted.license = 'MIT; see ArtCNN-MIT.txt'
        converted.short_description = name + ': original weights, normalized SDR luma, native 2x'
        converted.user_defined_metadata['upstream_revision'] = REVISION
        converted.user_defined_metadata['original_onnx_sha256'] = digest
        converted.user_defined_metadata['training_performed'] = 'false'
        out = ROOT / 'Apps/Mac/Resources/Models' / (name + '.mlpackage')
        converted.save(str(out))
        records.append({'name': name, 'originalONNXSHA256': digest,
                        'input': 'N1HW float16; H2..1080 W2..1920; default540x960',
                        'output': 'N1(2H)(2W) float16', 'trainingPerformed': False})
        print(name, 'exported', flush=True)
    print(json.dumps(records, indent=2))

if __name__ == '__main__':
    main()
