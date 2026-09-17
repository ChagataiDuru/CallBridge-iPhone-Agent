# Privacy and sharing

The raw call evidence in this project contains real phone numbers and real conversation audio.

- `evidence/private/` is for local review only and is covered by `.gitignore`.
- Phone numbers are masked in the text logs under `evidence/sanitized/`.
- CAF/WAV/M4A files are never committed by default.
- Logs must be re-checked before any public issue, commit or artifact is created.
- Future agent logs must mask the number by default; the full number should only appear in an
  explicitly enabled diagnostic mode.

Test identifiers and call UUIDs can also be correlated across sessions. They should be replaced
with random values when preparing a shareable diagnostic bundle.
