# Air RIFE service trace

此目录为自有窗口测试增加有界、逐任务的 CPU/GPU 记录，用来拆分转换、缓存初始化和正式推理的耗时。它不修改模型、缓存命中规则、MPS 编码、提交/等待次数、预算或呈现调度，也不代表产品帧率或画质验收。

## 生成与启用

从仓库根目录执行，输出必须是源目录之外、尚不存在的新目录：

```sh
python3 -B Experiments/AirServiceTrace/prepare_runtime.py \
  --source ThirdParty/rife-metal/runtime \
  --output .build/air-service-trace-runtime-new
```

生成器复制 package、模型资源、Shaders plugin 和许可文件，只在新副本插入观测代码；不写回 canonical runtime，不构建，不启动 GPU。输出的 `air-service-trace-source.json` 保存输入文件、生成器与 support 的 SHA256，以及源级变换数量。其 `built=false` / `gpuExecuted=false` 描述生成器自身，不能代替后续构建和运行记录。

独立诊断构建将本地 `RifeMetal` package 路径指向该副本，并保留原有资源打包方式。不要修改正常工程的永久 package 路径。构建条件如下：

| 层 | 条件 |
| --- | --- |
| App Swift | 在原有 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 中追加 `ODF_AIR_SERVICE_TRACE`，保留原有条件 |
| App ObjC++ | 保留当前诊断构建的 `ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC=1`；该构建也定义 `ODF_AIR_SERVICE_TRACE=1` |
| 进程环境 | 显式设置 `ODF_AIR_SERVICE_TRACE=1`，且在 bridge / runtime context 初始化前生效 |

Swift 条件未定义时，App 不引用新增 runtime API，可继续使用 canonical package。进程环境未启用时，bridge 不分配新增环或读取新增时钟，生成副本使用原 `MPSCommandBuffer` 类。启用环境本身不启动任务；native collector 还需显式 `airServiceTraceBegin(jobID:stage:)`。

profile、deferred commit、fused stage、trim 等实验保持原状态关闭。不要为收集时间启用 `RIFE_VERBOSE`、`RIFE_DUMP_DIR`、`ODF_K1_PROFILE` 或性能模拟；这些会改变观察条件或增加输出。构建、运行时环境和实际模型身份须随各次结果留痕。

本生成器只提供原模型的只读身份。可选的四阶段模型组合由 [Air24Training 的独立 preparer](../Air24Training/prepare_app_runtime.py) 在另一个新副本中完成。区分 package 生成身份、实际加载的模型身份和运行环境，不能仅凭文件名认定模型。

## 独立的尺寸／延迟取舍诊断

App 的 guard 诊断构建还支持两个显式开关：`ODF_AIR_TRUE_SOURCE_INTERVAL_DIAGNOSTIC=1` 仅移除 delay 公式的 1/30 上限；`ODF_AIR_INTERACTIVE_CAP_125MS_DIAGNOSTIC=1` 仅将交互档逻辑 cap 改为 125ms。正常构建、开关未启用时的 90ms 默认值及 quality cap 均不变；P、预算和呈现契约不因这两个开关改变。

实际启用请求记录在 `airCadenceCausalTrace.delayAlignment` 的 `trueSourceIntervalRequested`／`interactiveCap125msRequested`，每次重算保留真实 `intervalNs`／`capNs`。启动尚无有效源估计时仍可使用原 1/30 fallback。它们属于另行说明的探索诊断，不是 service trace 本身的行为，也不能用较小源窗口或 125ms 结果宣称原尺寸／90ms 目标通过。

## 记录与导出

[SPRifeBridge](../../Apps/Mac/Capture/SPRifeEngine.swift) 在原有 `exec` 路径记录，使用原有 `state` 锁保护自己的预分配标量环；native collector 由原有同步推理路径串行访问。没有新增锁对象、队列、GPU 等待、GPU completion handler 或热路径文件/日志输出。

| 环/存储 | 容量 | 内容 |
| --- | ---: | --- |
| `jobs` | 4096 | jobID、ordinary/probe、probe index/round、A/B identity 与 PTS、generation、clock/config/measurement/bridge epoch |
| `events` | 65536 | enqueue 请求、exec、各次 ownedBGRA、建流/reset、prime/main/fallback、输出池、包装和原 latency finish 边界 |
| `gpu` | 32768 | native root 的带采样时间副本、commit/wait 区间、实际 Metal 时间、有效性与覆盖标志 |
| native collector | 每个 context 128 槽 | 当前 stage 的 root 引用与标量；异常未终结的旧 root 也占容量 |

jobID 复用 processor 无条件递增的 `diagnosticID`，普通任务和恢复探测共用该序列，不依赖开启 R7/R8。标签只描述原任务，不新增推理。native stage 为 `1=stream-create`、`2=cache-prime`、`3=main-push`、`4=stateless-fallback`。`ownedBGRARoles` 区分 previous/current 和 fallback 的两次输入；reset reason 也单独记录。

这些环不会随 config 或 measurement epoch 清空。旧 stateless submit 没有完整的源 identity/PTS，记为 `unsupported-stateless-submit`，不猜造关联字段。

导出位于既有 `presentationOrderDiagnostics.airServiceTrace`，不会出现在周期 `streamDiagnostics` 或 stats 中。受控 SelfProbe 在 SCK stop 完成后、processor.stop 前调用一次；该方法自身不验证采集已经停止，不等待 `exec`/GPU，也不 flush。`exportOrdinal` 可识别额外导出。

导出只覆盖当前 bridge 实例。记录按 `exportCutoffHostTicks` 过滤，计数与状态副本属于另一个明确的 `sampleHostTicks`；不要把两者视为原子同一时刻。停止采集仍可能留下未完成任务、尚未复制的 GPU 时间及回调尾部，这些是 unknown，不应补成 0 或已完成。

## job/root 关联与去重

先固定 run、bridge 实例和实际模型身份，再用 jobID 关联 jobs/events/GPU。ordinary 与 probe 分开统计；不能把每次周期快照的 recent tail 当作独立任务累加。

GPU root 的身份键为 `(run, bridge, jobID, stage, rootIndex)`。native 每次 begin 清理已完成 root；如果前一次推理在原有 wait 前抛错，仍持有的旧 root 会保留，之后可能再次返回其更新记录。对同一键保留 cutoff 内 `sequence` 较后的观察，不能把重复行当成新的 command buffer。若完整时间字段互相冲突，应保留并报告冲突。

`commitKind=1` 为原有显式 commit，`2` 为 MPS 隐式 split。主推理可以包含多个 root；只取最终 root 的时间不能代表整个推理。计算总 GPU 区间时也应区分 interval sum 与 union，避免把重叠时间重复相加。

有效性位为 `1=create observation`、`2=commit bracket`、`4=wait bracket`、`8=status`、`16=GPU interval`、`32=kernel interval`；覆盖位为 `1=tracked`、`2=unobserved root`、`4=incomplete/error`、`8=capacity overflow`。无有效位或未取得的时间导出为 `null`，不是实测 0 耗时。隐式提交的 root 通常没有自己的显式 wait，因此 wait 为 null 本身不等于 GPU 时间无效；必须结合实际 completed 状态、GPU 有效位和覆盖位判断。

`overflowCount`、各环 `dropped`、`runtimeOverflowCount`、序列边界和导出条数都需保留。任意溢出都会使全量证据不完整。`ringsComplete=true` 仅表示环没有溢出；还要检查 metadata mismatch、无效时间、unobserved/incomplete root、unsupported submit 和未知尾部，不能据此单独宣称完整 GPU 覆盖。

## 时间含义

CPU `HostTicks` 使用 `mach_absolute_time()`，换算纳秒须乘本次 `machTimebase.numer / denom`，不能直接把 ticks 当纳秒。enqueue 标记是调用 `dispatch_async` 前的提交请求边界，不是私有队列内部的入队时刻；CPU 标记都是 wall time，包含正常等待和调度，不等于 CPU 在核执行时间。

`createHostTicks` 是首次观察该 root 的时刻，不是 Apple 内部的精确分配时刻。对于隐式提交，`commitBeginHostTicks` / `commitEndHostTicks` 包围一次原样的 `super.commitAndContinue()`，包含其创建替代 root 的工作；它们不是底层私有 `MTLCommandBuffer.commit` 的精确调用时刻。encode 前后的 root identity 哨兵只会把绕过观察点的变化标成 incomplete，无法重建不可见的内部提交。

Metal SDK 将 GPUStart/End 定义为 host seconds；kernelStart/End 只有 `CFTimeInterval` 声明，本次本地 SDK 未证明其时钟域或语义等同 GPU 区间。保留 kernel 原始秒值，不用它作跨域相减。也不能无条件假定 Metal GPU 秒与 CPU mach 秒的 origin 相同。

GPUStart/End 来自实际 command buffer，在运行时原有 wait 返回后读取，不是 CPU completed-handler 抵达时间。`gpuEnd-gpuStart` 是该 root 的 GPU residency 区间，不等于 active shader cycles 或 GPU 占用率。跨 CPU/GPU 域的 commit→start 分析只能在明确的 offset/时钟假设和因果边界下给出范围；不能把它直接称为外部争用或独占硬件队列等待，也不能将 CPU、排队和 GPU 重叠区间直接相加成互斥占比。

## 真实 VT 转换计数

`measuredBGRA` 和旧 `convertCalls` 统计的是 wrapper 调用；BGRA 快返回仍经过该 wrapper，不能据此判断发生了颜色转换。

真实 `VTPixelTransferSessionTransferImage` 调用前有唯一 `vt-transfer-call` 事件，携带 jobID、role 和实际输入 `sourceFourCC`。原 BGRA/RGBA fast return 在该点之前，所以这些输入的 live ordinary/probe 任务应没有此事件。按测量窗口内、可关联到相应普通或 probe job 的事件计数；失败的 VT 调用也属于调用次数。

prepare/warmup 没有 live job identity，使用默认 token/role 0，导出的 jobID 为 null；无身份的旧 stateless 路径也可能使用这个默认值。因此不能将所有 null jobID 都认定为普通测量任务，或仅靠 VT 事件总数判 BGRA 失败。旧 wrapper 调用数与计时字段保持原义。

## 已有验证与边界（2026-11-09）

以下是已有证据，不是读取本 README 时重新执行的测试；`.build` 是本地运行产物，不是随仓库分发的固定输入。

| 证据 | 已确认范围 | 未确认范围 |
| --- | --- | --- |
| 生成器源级检查 | 7 个 MPS 构造点、9 对原 commit/wait、13 个 encode 前后哨兵；3 个注入文件可反变换为原文，其他复制文件及 canonical 输入哈希保持 | 不替代类型编译或 GPU 执行 |
| [正常 Release 检查](../../.build/AirServiceTraceNormalCheck-20261109/result.json) | canonical runtime、未开 service/guard 条件的完整编译和链接成功 | 没有启动 App 或 GPU，不是正常产品回归 |
| [四进程动态 QA](../../.build/air-service-trace-smoke-20261109/result/summary.json) / [receipt](../../.build/air-service-trace-smoke-20261109/final-receipt.json) | 256×256 合成输入，D0/C4 各自 trace on/off 输出逐字节一致；实际模型身份和观察到的 root 时间有效 | 该 QA 没触发自动 split；不是性能、holdout 或画质验收 |
| [Air D0 60 秒 trace 复核](../../.build/air-diagnosis-20261108/timing-math-review/d0-service-trace-review.json) | 生命周期内 1067 个 job、11827 个唯一 root，其中 10715 implicit / 1112 explicit；溢出、无效 root、unsupported 均为 0，实际触发了 split 路径 | 只覆盖该包装路径可观察的 root；不证明 Metal 内部隐藏调度、active cycles 或产品 24→48 达标 |

上述 D0 run 使用旧的 `c451…` 库，早于 `vt-transfer-call` 补充；不能用它验证新增 VT 事件或 BGRA 采集。后续运行必须绑定各自 source/library/driver/model 哈希，保留最初失败和新证据，不能把这张表转移为所有未来构建通过。

标量 trace **有非零开销**：时钟读取、固定环写入、原 state 锁的额外短临界区、root 引用保留、子类转发和有界扫描都可能影响耗时；导出时还有停止采集后的复制与 JSON 分配。源代码未增加 GPU 工作或等待，合成输入的输出一致也不证明性能零扰动。性能结论应明确来自同条件的诊断运行，不能将 trace 收集成功外推为稳定帧率、外部窗口/Safari 兼容或人工画质通过。
