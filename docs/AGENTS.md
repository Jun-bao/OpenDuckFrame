# User documentation and evidence

[quick-start.md](quick-start.md) covers normal use and permissions.
[features.md](features.md) explains capabilities and conditions.
[workbench-status.md](workbench-status.md) explicitly preserves historical development observations and gaps.
[performance-simulation.md](performance-simulation.md) documents exploratory timing profiles.
Use current source and the actual tested artifact to determine present product behavior.

## Keep user-facing facts current

The normal workbench exposes ODF-VFI, a four-stage structural reduction of RIFE 4.25 using upstream weights without retraining. Earlier visible model names and references to additional engines can be historical.
Continuous caching defaults on, window output follows the source, and the normal delay defaults to 3 seconds.
Automatic hardware/configuration detection remains deferred.
When a task changes shipping behavior, update relevant English guides and README.md together with README.zh-CN.md.
Keep technical experiment records separate from the user's normal workflow.
The production website is maintained in the repository linked from [Website/AGENTS.md](../Website/AGENTS.md).

## Claims and checks

State source dimensions, engine/model, quality tier, hardware, display and duration for performance comparisons.
Keep capture callback rate, source-content cadence, requested target, generated frames and presented FPS distinct.
A multiplier, simulation profile or old Air result does not guarantee performance on another Mac.
Retain missing observations and first failures rather than rewriting them as acceptance.
Distinguish build/bundle checks, offscreen tests and real native visual/audio acceptance.
Check changed links and command paths against the current tree.
`./Scripts/check_public_repo.sh` validates repository resources and metadata; it does not validate every prose claim.
