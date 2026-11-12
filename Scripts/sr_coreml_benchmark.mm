// Offline tensor benchmark. Input preparation and output export are outside prediction timing.
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <vector>

using Clock = std::chrono::steady_clock;
static double milliseconds(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
static NSError *failure(NSString *message) {
    return [NSError errorWithDomain:@"ODFCoreMLBenchmark" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSDictionary *errorRecord(NSError *error) {
    if (!error) return @{};
    NSMutableDictionary *record = [@{@"domain": error.domain, @"code": @(error.code),
        @"description": error.description, @"localizedDescription": error.localizedDescription,
        @"userInfoDescription": error.userInfo.description} mutableCopy];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]] && underlying != error)
        record[@"underlyingError"] = @{@"domain": underlying.domain, @"code": @(underlying.code),
            @"description": underlying.description, @"userInfoDescription": underlying.userInfo.description};
    return record;
}
static bool positiveInteger(id value, uint64_t *number) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    double n = [value doubleValue];
    if (!std::isfinite(n) || n < 1 || n > (double)std::numeric_limits<int64_t>::max() || std::floor(n) != n)
        return false;
    *number = [value unsignedLongLongValue];
    return true;
}
static bool nonnegativeInteger(id value, uint64_t *number) {
    if ([value isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && [value doubleValue] == 0) {
        *number = 0; return true;
    }
    return positiveInteger(value, number);
}
static bool dimensions(NSArray *values, std::vector<size_t> &dims, size_t *count) {
    if (![values isKindOfClass:[NSArray class]] || values.count == 0) return false;
    size_t total = 1;
    for (id value in values) {
        uint64_t n;
        if (!positiveInteger(value, &n) || n > SIZE_MAX / total) return false;
        dims.push_back((size_t)n);
        total *= (size_t)n;
    }
    *count = total;
    return true;
}
static NSString *dtypeName(MLMultiArrayDataType dtype) {
    switch (dtype) {
        case MLMultiArrayDataTypeFloat16: return @"float16";
        case MLMultiArrayDataTypeFloat32: return @"float32";
        case MLMultiArrayDataTypeDouble: return @"float64";
        case MLMultiArrayDataTypeInt32: return @"int32";
        default: return [NSString stringWithFormat:@"unsupported(%ld)", (long)dtype];
    }
}
static size_t dtypeBytes(MLMultiArrayDataType dtype) {
    switch (dtype) {
        case MLMultiArrayDataTypeFloat16: return 2;
        case MLMultiArrayDataTypeFloat32: case MLMultiArrayDataTypeInt32: return 4;
        case MLMultiArrayDataTypeDouble: return 8;
        default: return 0;
    }
}
// Copy contiguous suffixes, enumerating prefix coordinates using the actual strides.
// This preserves float16 bit patterns and also handles padded/transposed tensors.
static bool logicalCopy(void *tensorBytes, void *packedBytes, NSInteger capacityBytes,
                        NSArray *shape, NSArray *strides, size_t scalarBytes,
                        bool toTensor, NSError **error) {
    std::vector<size_t> dims, step;
    size_t count = 0;
    if (!dimensions(shape, dims, &count) || strides.count != shape.count || !scalarBytes ||
        count > SIZE_MAX / scalarBytes) {
        *error = failure(@"Invalid tensor shape, strides, or scalar type."); return false;
    }
    size_t lastOffset = 0;
    for (NSUInteger i = 0; i < strides.count; ++i) {
        uint64_t n;
        if (!nonnegativeInteger(strides[i], &n) || n > SIZE_MAX ||
            (n && (dims[i] - 1) > (SIZE_MAX - lastOffset) / (size_t)n)) {
            *error = failure(@"Invalid or overflowing tensor strides."); return false;
        }
        step.push_back((size_t)n);
        lastOffset += (dims[i] - 1) * (size_t)n;
    }
    if (capacityBytes < 0 || lastOffset > (SIZE_MAX / scalarBytes) - 1 ||
        (lastOffset + 1) * scalarBytes > (size_t)capacityBytes) {
        *error = failure(@"Tensor strides exceed its accessible buffer."); return false;
    }
    size_t suffixStart = dims.size(), runScalars = 1;
    while (suffixStart > 0 && (dims[suffixStart - 1] == 1 || step[suffixStart - 1] == runScalars)) {
        --suffixStart;
        runScalars *= dims[suffixStart];
    }
    const size_t runBytes = runScalars * scalarBytes;
    size_t runCount = count / runScalars;
    for (size_t run = 0; run < runCount; ++run) {
        size_t remaining = run, offset = 0;
        for (size_t i = suffixStart; i > 0; --i) {
            offset += (remaining % dims[i - 1]) * step[i - 1];
            remaining /= dims[i - 1];
        }
        uint8_t *tensor = (uint8_t *)tensorBytes + offset * scalarBytes;
        uint8_t *packed = (uint8_t *)packedBytes + run * runBytes;
        if (toTensor) std::memcpy(tensor, packed, runBytes);
        else std::memcpy(packed, tensor, runBytes);
    }
    return true;
}
// Scoped CPU buffer access forces output materialization even for /dev/null runs.
// Read the first and last logical scalars; no full output copy is timed here.
static volatile uint8_t materializationSink = 0;
static bool materializeTensor(MLMultiArray *tensor, NSError **error) {
    std::vector<size_t> dims;
    size_t count = 0, scalarBytes = dtypeBytes(tensor.dataType), lastOffset = 0;
    if (!scalarBytes || !dimensions(tensor.shape, dims, &count) || tensor.strides.count != dims.size()) {
        *error = failure(@"Output tensor has unsupported dtype or invalid layout."); return false;
    }
    for (size_t i = 0; i < dims.size(); ++i) {
        uint64_t stride;
        if (!nonnegativeInteger(tensor.strides[i], &stride) || stride > SIZE_MAX ||
            (stride && dims[i] - 1 > (SIZE_MAX - lastOffset) / (size_t)stride)) {
            *error = failure(@"Output strides are invalid or overflowing."); return false;
        }
        lastOffset += (dims[i] - 1) * (size_t)stride;
    }
    if (lastOffset > SIZE_MAX / scalarBytes - 1) {
        *error = failure(@"Output buffer span overflows."); return false;
    }
    const size_t requiredBytes = (lastOffset + 1) * scalarBytes;
    __block BOOL accessible = NO;
    [tensor getBytesWithHandler:^(const void *bytes, NSInteger size) {
        if (size < 0 || requiredBytes > (size_t)size) return;
        volatile const uint8_t *scalars = (volatile const uint8_t *)bytes;
        for (size_t byte = 0; byte < scalarBytes; ++byte) {
            materializationSink ^= scalars[byte];
            materializationSink ^= scalars[lastOffset * scalarBytes + byte];
        }
        accessible = YES;
    }];
    if (!accessible) *error = failure(@"Output strides exceed its CPU-accessible buffer.");
    return accessible;
}
static NSDictionary *statistics(std::vector<double> values) {
    if (values.empty()) return @{@"count": @0};
    std::sort(values.begin(), values.end());
    double sum = 0; for (double value : values) sum += value;
    auto percentile = [&](double p) {
        double i = (values.size() - 1) * p;
        size_t lower = (size_t)i, upper = std::min(lower + 1, values.size() - 1);
        return values[lower] + (values[upper] - values[lower]) * (i - lower);
    };
    return @{@"count": @(values.size()), @"meanMs": @(sum / values.size()),
        @"p50Ms": @(percentile(0.50)), @"p95Ms": @(percentile(0.95)),
        @"minMs": @(values.front()), @"maxMs": @(values.back())};
}
static bool run(NSArray<NSString *> *args, NSMutableDictionary *report, NSError **error) {
    NSString *modelPath = args[1], *configPath = args[2], *inputPath = args[3], *outputPath = args[4];
    char *end = nullptr;
    errno = 0;
    unsigned long long requestedCount = strtoull(args[6].UTF8String, &end, 10);
    if (errno || !args[6].length || args[6].UTF8String[0] == '-' || !end || *end || requestedCount == 0 || requestedCount > INT64_MAX) {
        *error = failure(@"prediction_count must be a positive integer."); return false;
    }
    MLComputeUnits units;
    NSDictionary *unitValues = @{@"all": @(MLComputeUnitsAll), @"cpuAndGPU": @(MLComputeUnitsCPUAndGPU),
        @"cpuAndNeuralEngine": @(MLComputeUnitsCPUAndNeuralEngine), @"cpuOnly": @(MLComputeUnitsCPUOnly)};
    if (!unitValues[args[7]]) {
        *error = failure(@"compute_units must be all, cpuAndGPU, cpuAndNeuralEngine, or cpuOnly."); return false;
    }
    units = (MLComputeUnits)[unitValues[args[7]] integerValue];
    report[@"requestedPredictions"] = @(requestedCount);
    report[@"computeUnitsAllowed"] = args[7];
    report[@"computeUnitsMeaning"] = @"Permitted devices only; this does not measure actual CPU/GPU/ANE placement.";
    NSData *configData = [NSData dataWithContentsOfFile:configPath options:0 error:error];
    if (!configData) return false;
    id parsedConfig = [NSJSONSerialization JSONObjectWithData:configData options:0 error:error];
    if (!parsedConfig) return false;
    if (![parsedConfig isKindOfClass:[NSDictionary class]]) {
        *error = failure(@"config.json must contain an object."); return false;
    }
    NSDictionary *config = parsedConfig;
    NSString *inputName = config[@"input_name"], *outputName = config[@"output_name"], *dtype = config[@"input_dtype"];
    std::vector<size_t> inputDimensions;
    size_t inputElements;
    uint64_t batchFrames = 1;
    if (![inputName isKindOfClass:[NSString class]] || !inputName.length ||
        ![outputName isKindOfClass:[NSString class]] || !outputName.length ||
        ![dtype isKindOfClass:[NSString class]] ||
        !dimensions(config[@"input_shape"], inputDimensions, &inputElements) ||
        (config[@"batch_frames"] && !positiveInteger(config[@"batch_frames"], &batchFrames))) {
        *error = failure(@"Config requires nonempty input_name/output_name, positive input_shape, input_dtype, and optional positive batch_frames."); return false;
    }
    if (batchFrames > UINT64_MAX / requestedCount) {
        *error = failure(@"prediction_count times batch_frames overflows."); return false;
    }
    MLMultiArrayDataType inputType;
    if ([dtype isEqual:@"float16"]) inputType = MLMultiArrayDataTypeFloat16;
    else if ([dtype isEqual:@"float32"]) inputType = MLMultiArrayDataTypeFloat32;
    else { *error = failure(@"input_dtype must be float16 or float32."); return false; }
    size_t scalarBytes = dtypeBytes(inputType);
    if (inputElements > SIZE_MAX / scalarBytes) { *error = failure(@"Input tensor byte size overflows."); return false; }
    const size_t inputBytes = inputElements * scalarBytes;
    report[@"config"] = config;
    report[@"batchFrames"] = @(batchFrames);
    report[@"timingScope"] = @"Synchronous prediction plus output feature extraction, scoped CPU-readable output buffer materialization, and volatile reads of the first and last logical scalars, including /dev/null runs. File reading, input packing, full output packing, and file export are separate. Batch frame throughput is not display FPS.";
    report[@"warmupPredictionsExcluded"] = @5;
    NSDictionary *inputAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:inputPath error:error];
    if (!inputAttributes) return false;
    unsigned long long fileBytes = [inputAttributes[NSFileSize] unsignedLongLongValue];
    if (!fileBytes || fileBytes % inputBytes) {
        *error = failure(@"Input file must contain a positive whole number of packed input tensors."); return false;
    }
    unsigned long long sourceSamples = fileBytes / inputBytes;
    report[@"inputFileBytes"] = @(fileBytes);
    report[@"inputSampleBytes"] = @(inputBytes);
    report[@"sourceSamples"] = @(sourceSamples);
    report[@"inputReadPolicy"] = @"Sequential tensors, cyclically repeated only when prediction_count exceeds sourceSamples.";
    NSURL *modelURL = [NSURL fileURLWithPath:modelPath];
    if ([modelPath.pathExtension isEqual:@"mlpackage"] || [modelPath.pathExtension isEqual:@"mlmodel"]) {
        auto start = Clock::now();
        modelURL = [MLModel compileModelAtURL:modelURL error:error];
        report[@"modelCompileMs"] = @(milliseconds(start));
        if (!modelURL) return false;
    } else if ([modelPath.pathExtension isEqual:@"mlmodelc"]) report[@"modelCompileMs"] = @0;
    else { *error = failure(@"Model path must end in .mlpackage, .mlmodel, or .mlmodelc."); return false; }
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = units;
    auto loadStart = Clock::now();
    MLModel *model = [MLModel modelWithContentsOfURL:modelURL configuration:configuration error:error];
    report[@"modelLoadMs"] = @(milliseconds(loadStart));
    if (!model) return false;
    NSDictionary<NSString *, MLFeatureDescription *> *inputs = model.modelDescription.inputDescriptionsByName;
    MLFeatureDescription *inputDescription = inputs[inputName];
    MLFeatureDescription *outputDescription = model.modelDescription.outputDescriptionsByName[outputName];
    report[@"modelInputNames"] = inputs.allKeys;
    report[@"modelOutputNames"] = model.modelDescription.outputDescriptionsByName.allKeys;
    if (inputs.count != 1 || inputDescription.type != MLFeatureTypeMultiArray || !inputDescription ||
        !outputDescription || outputDescription.type != MLFeatureTypeMultiArray) {
        *error = failure(@"This runner requires exactly one model input and the configured input/output must both be multi-arrays."); return false;
    }
    report[@"modelInputConstraint"] = @{@"defaultShape": inputDescription.multiArrayConstraint.shape,
        @"dtype": dtypeName(inputDescription.multiArrayConstraint.dataType)};
    if (inputDescription.multiArrayConstraint.dataType != inputType) {
        *error = failure(@"Configured input_dtype does not match the model input dtype."); return false;
    }
    auto allocateStart = Clock::now();
    MLMultiArray *input = [[MLMultiArray alloc] initWithShape:config[@"input_shape"] dataType:inputType error:error];
    report[@"inputAllocationMs"] = @(milliseconds(allocateStart));
    if (!input) return false;
    MLFeatureValue *inputFeature = [MLFeatureValue featureValueWithMultiArray:input];
    if (![inputDescription isAllowedValue:inputFeature]) {
        *error = failure(@"Configured input tensor is outside the model's shape/type constraints."); return false;
    }
    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{inputName: inputFeature} error:error];
    if (!provider) return false;
    using File = std::unique_ptr<FILE, decltype(&fclose)>;
    File source(fopen(inputPath.fileSystemRepresentation, "rb"), &fclose);
    if (!source) { *error = failure([NSString stringWithFormat:@"Cannot open input file: %s", strerror(errno)]); return false; }
    bool discard = [outputPath isEqual:@"/dev/null"];
    File output(discard ? nullptr : fopen(outputPath.fileSystemRepresentation, "wb"), &fclose);
    if (!discard && !output) { *error = failure([NSString stringWithFormat:@"Cannot open output file: %s", strerror(errno)]); return false; }
    report[@"outputDiscarded"] = @(discard);
    std::vector<uint8_t> packedInput(inputBytes), packedOutput;
    NSMutableArray *records = [NSMutableArray new];
    report[@"predictions"] = records;
    uint64_t exportedBytes = 0;
    NSDictionary *firstOutput = nil;
    for (unsigned long long i = 0; i < requestedCount; ++i) {
        @autoreleasepool {
            NSMutableDictionary *record = [@{@"index": @(i), @"sourceSampleIndex": @(i % sourceSamples),
                @"sourceCycle": @(i / sourceSamples)} mutableCopy];
            [records addObject:record];
            auto readStart = Clock::now();
            if (i && i % sourceSamples == 0 && fseeko(source.get(), 0, SEEK_SET) != 0) {
                *error = failure(@"Failed to rewind input file for repeated samples."); return false;
            }
            size_t readBytes = fread(packedInput.data(), 1, inputBytes, source.get());
            record[@"inputReadMs"] = @(milliseconds(readStart));
            if (readBytes != inputBytes) { *error = failure(@"Short read while reading an input tensor."); return false; }
            auto packStart = Clock::now();
            __block NSError *packingError = nil;
            __block BOOL packed = NO;
            void *packedInputBytes = packedInput.data();
            [input getMutableBytesWithHandler:^(void *bytes, NSInteger size, NSArray<NSNumber *> *strides) {
                packed = logicalCopy(bytes, packedInputBytes, size, input.shape, strides, scalarBytes, true, &packingError);
            }];
            record[@"packingMs"] = @(milliseconds(packStart));
            if (!packed) { *error = packingError; return false; }
            if (i == 0) report[@"inputTensor"] = @{@"shape": input.shape, @"strides": input.strides, @"dtype": dtypeName(input.dataType)};
            auto predictionStart = Clock::now();
            id<MLFeatureProvider> prediction = [model predictionFromFeatures:provider error:error];
            MLMultiArray *tensor = prediction ? [prediction featureValueForName:outputName].multiArrayValue : nil;
            bool materialized = false;
            if (prediction && !tensor) *error = failure(@"Prediction did not return the configured output multi-array.");
            if (tensor) materialized = materializeTensor(tensor, error);
            double predictionMs = milliseconds(predictionStart);
            record[@"predictionAttemptMs"] = @(predictionMs);
            if (!prediction || !tensor || !materialized) return false;
            record[@"predictionMs"] = @(predictionMs);
            auto exportStart = Clock::now();
            size_t outputElements;
            std::vector<size_t> outputDims;
            size_t outputScalarBytes = dtypeBytes(tensor.dataType);
            if (!dimensions(tensor.shape, outputDims, &outputElements) || !outputScalarBytes || outputElements > SIZE_MAX / outputScalarBytes) {
                *error = failure(@"Output tensor has unsupported dtype or invalid shape."); return false;
            }
            size_t outputBytes = outputElements * outputScalarBytes;
            NSDictionary *outputMetadata = @{@"shape": tensor.shape, @"strides": tensor.strides,
                @"dtype": dtypeName(tensor.dataType), @"logicalBytes": @(outputBytes)};
            record[@"outputTensor"] = outputMetadata;
            if (!firstOutput) { firstOutput = outputMetadata; report[@"outputTensor"] = firstOutput; }
            else if (![firstOutput[@"shape"] isEqual:tensor.shape] || ![firstOutput[@"dtype"] isEqual:dtypeName(tensor.dataType)]) {
                *error = failure(@"Output shape or dtype changed; a single raw output stream would be ambiguous."); return false;
            }
            if (!discard) {
                packedOutput.resize(outputBytes);
                __block NSError *exportError = nil;
                __block BOOL copied = NO;
                void *packedOutputBytes = packedOutput.data();
                [tensor getBytesWithHandler:^(const void *bytes, NSInteger size) {
                    copied = logicalCopy((void *)bytes, packedOutputBytes, size, tensor.shape, tensor.strides,
                                         outputScalarBytes, false, &exportError);
                }];
                if (!copied) { *error = exportError; return false; }
                if (fwrite(packedOutput.data(), 1, outputBytes, output.get()) != outputBytes) {
                    *error = failure(@"Short write while exporting an output tensor."); return false;
                }
                exportedBytes += outputBytes;
            }
            record[@"outputExportMs"] = @(milliseconds(exportStart));
            record[@"exportedBytes"] = @(discard ? 0 : outputBytes);
            record[@"completed"] = @YES;
            report[@"exportedBytes"] = @(exportedBytes);
        }
    }
    auto flushStart = Clock::now();
    if (output && fflush(output.get()) != 0) { *error = failure(@"Failed flushing the output file."); return false; }
    report[@"outputFlushMs"] = @(milliseconds(flushStart));
    report[@"outputRawLayout"] = @"Predictions concatenated in order; each tensor tightly packed in logical row-major order, preserving model output dtype bits.";
    return true;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 8) {
            fprintf(stderr, "Usage: %s model_path config.json input.raw output.raw result.json prediction_count compute_units\n", argv[0]);
            return 2;
        }
        NSMutableArray<NSString *> *args = [NSMutableArray new];
        for (int i = 0; i < argc; ++i) [args addObject:[NSString stringWithUTF8String:argv[i]]];
        NSMutableDictionary *report = [@{@"schemaVersion": @1, @"tool": @"sr_coreml_benchmark",
            @"modelPath": args[1], @"configPath": args[2], @"inputPath": args[3], @"outputPath": args[4]} mutableCopy];
        auto start = Clock::now();
        NSError *error = nil;
        bool succeeded = run(args, report, &error);
        report[@"elapsedMs"] = @(milliseconds(start));
        report[@"status"] = succeeded ? @"succeeded" : @"failed";
        if (!succeeded) report[@"firstError"] = errorRecord(error ?: failure(@"Unknown failure."));
        std::vector<double> predictionTimes, steadyTimes, readTimes, packingTimes, exportTimes;
        unsigned long long completed = 0, repeated = 0;
        for (NSDictionary *record in report[@"predictions"]) {
            if (record[@"predictionMs"]) {
                double ms = [record[@"predictionMs"] doubleValue];
                predictionTimes.push_back(ms);
                if ([record[@"index"] unsignedLongLongValue] >= 5) steadyTimes.push_back(ms);
            }
            if (record[@"inputReadMs"]) readTimes.push_back([record[@"inputReadMs"] doubleValue]);
            if (record[@"packingMs"]) packingTimes.push_back([record[@"packingMs"] doubleValue]);
            if (record[@"outputExportMs"]) exportTimes.push_back([record[@"outputExportMs"] doubleValue]);
            if ([record[@"completed"] boolValue]) {
                ++completed;
                if ([record[@"sourceCycle"] unsignedLongLongValue] > 0) ++repeated;
            }
        }
        report[@"successfulPredictions"] = @(predictionTimes.size());
        report[@"completedPredictions"] = @(completed);
        report[@"repeatedCompletedPredictions"] = @(repeated);
        report[@"completedBatchFrames"] = @(completed * [report[@"batchFrames"] unsignedLongLongValue]);
        report[@"predictionStatistics"] = statistics(predictionTimes);
        report[@"steadyPredictionStatistics"] = statistics(steadyTimes);
        report[@"inputReadStatistics"] = statistics(readTimes);
        report[@"packingStatistics"] = statistics(packingTimes);
        report[@"outputExportStatistics"] = statistics(exportTimes);
        if (!predictionTimes.empty()) report[@"coldPredictionMs"] = @(predictionTimes.front());
        if (!steadyTimes.empty()) {
            double total = 0; for (double ms : steadyTimes) total += ms;
            report[@"steadyModelBatchFramesPerSecond"] = @(1000.0 * steadyTimes.size() * [report[@"batchFrames"] doubleValue] / total);
        }
        NSError *jsonError = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&jsonError];
        if (!json || ![json writeToFile:args[5] options:NSDataWritingAtomic error:&jsonError]) {
            fprintf(stderr, "Cannot write result JSON: %s\n", jsonError.description.UTF8String);
            return 1;
        }
        fprintf(succeeded ? stdout : stderr, "%s: %llu completed predictions; result %s%s%s\n",
            succeeded ? "succeeded" : "failed", completed, args[5].UTF8String,
            succeeded ? "" : "; ", succeeded ? "" : error.localizedDescription.UTF8String);
        return succeeded ? 0 : 1;
    }
}
