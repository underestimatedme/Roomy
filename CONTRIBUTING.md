# Contributing

Use macOS 14 or later and Apple Command Line Tools. Build with `bash app/tools/build-cli.sh` and run `python3 app/tests/run-reliability.py --core-only`. Tests must use generated private fixtures; never test deletion against personal files. Preserve default preview, explicit scope selection, shared operation locks, protection checks, and recovery records.

Contributions are licensed under GPL-3.0-only.
