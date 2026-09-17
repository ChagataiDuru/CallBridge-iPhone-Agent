# Privacy and sharing

The raw call evidence in this project contains real phone numbers and real conversation audio.

- The entire `evidence/` tree is covered by `.gitignore` and stays local. Nothing under it is
  published from this repository — not even the masked logs.
- `evidence/private/` holds the original files and is for local review only.
- `evidence/sanitized/` holds text logs in which phone numbers are replaced with
  `[REDACTED_PHONE]`. They exist so that a specific log can be shared deliberately and by hand,
  not so that they are published automatically.
- CAF/WAV/M4A files are never shared in any form.
- Logs must be re-checked before any public issue, commit or artifact is created.
- Future agent logs must mask the number by default; the full number should only appear in an
  explicitly enabled diagnostic mode.

Test identifiers and call UUIDs can also be correlated across sessions. They should be replaced
with random values when preparing a shareable diagnostic bundle.
