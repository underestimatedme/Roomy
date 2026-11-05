# Scanner correctness fixture

`tools/make-scan-fixture.swift` creates this fixture under `build/fixtures/correctness`.
It includes regular and sparse files, a cross-directory hard link, a symlink cycle,
an app package, AI/media/document names, a denied directory, a disappearing directory,
and an APFS clone when `clonefile` is supported. The generated manifest is the test oracle;
fixture data is never committed.
