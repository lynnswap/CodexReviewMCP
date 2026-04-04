# CodexReviewMCP Repo Notes

- This repository is pre-release. Breaking changes to internal discovery files, cleanup-ticket layout, and other non-public implementation details are allowed when they simplify the design.
- Do not preserve backward compatibility for older discovery schemas or file locations unless the user explicitly asks for it.
- Prefer replacing a bad lifecycle/state model over layering compatibility fallbacks on top of it.
- Keep restart and cleanup behavior deterministic in tests. Do not add time-tuned tests when a controllable clock or explicit synchronization can be used instead.
