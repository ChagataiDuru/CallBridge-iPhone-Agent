# Research directory

This directory holds third-party application content extracted for static analysis:

- `TrollRecorderStatic/`: a copy of the bundle taken from the installed TrollRecorder app
- `upstream-trollrecorder-app/`: content extracted from the upstream application archive

The content is **not tracked by Git**. `.gitignore` tracks only this README, so that third-party
binaries and sources are not redistributed, the repository stays a reasonable size, and review
output stays local. Findings are summarized in `docs/RESEARCH.md` and under `reports/`.
