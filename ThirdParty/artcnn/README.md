# ArtCNN super-resolution

Original ArtCNN C4F16/C4F32 coefficients from Artoriuz/ArtCNN, revision
`0837e5326e710f49e2ab0a8d995da0708047442e`. The upstream GLSL shaders contain
the same coefficients and the complete MIT license. Original ONNX hashes and
the coefficient-license links are in `source-origin.json`; retain `LICENSE`.

`Scripts/export_artcnn_models.py` reconstructs the exact seven-convolution
graphs from ONNX and exports the packages under `Apps/Mac/Resources/Models`.
Export uses Python 3.12, PyTorch 2.7.0, coremltools 9.0, ONNX 1.23.2 and
NumPy 2.2.6. No training, quantization or coefficient modification is performed.
Normal Xcode builds compile the packages without installing Python ML tools.

The model input is normalized SDR luma `(Y8-16)/219` for limited-range NV12
or `Y8/255` for full-range NV12. Output is native 2x luma. The adapter keeps
source color metadata/range and scales chroma with the existing Lanczos path.
BGRA capture is converted to NV12 explicitly; HDR, cropped frames, odd sizes
and input above 1920x1080 are rejected. Output is limited to 3840x2160.

Core ML input dimensions are bounded flexible shapes (default 960x540).
Each session specializes and warms its actual dimensions before admitting
frames. A single frame is in flight; invalidated results cannot be presented.
Runtime errors retain an explicit failed state while original frames remain
available. C4F16/C4F32 have separate weights and share the same family design.
