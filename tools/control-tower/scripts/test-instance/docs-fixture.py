#!/usr/bin/env python3
"""The test instance's team documents (T185): $T/my-team/docs/example-team/index.md and the files it lists.

Usage: docs-fixture.py <T>. CT_TEST_DOCS=none writes no index (the "no index file" state), CT_TEST_DOCS=empty one
without lines. Every title is made up and every link is example.com.

  index.md                       groups of lines: Markdown files, an .html file, web links, a file that is not
                                 there, and lines that must not open (a path out of the folder, a symbolic link
                                 out of it, a file:// address, a line without a link, a script, a folder), an .svg file
  design/, reports/              the files the lines open
  ../../outside.md               what the lines that leave the folder point at
  reports/, review/, tickets/    documents the index does not list (T197): 30 reports, reviews, tickets (one
  design/, example-notes.md      without a heading), an .html file nobody listed, a .pdf, a file right in the folder,
                                 and what is no document (a .txt, a .png, a hidden file)

With CT_TEST_DOCS=none or empty the folder holds no document.
"""
import os
import sys

T = sys.argv[1]
TEAM = "example-team"
DOCS = f"{T}/my-team/docs/{TEAM}"
mode = os.environ.get("CT_TEST_DOCS", "")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


os.makedirs(DOCS, exist_ok=True)
if mode == "none":
    sys.exit(0)
if mode == "empty":
    write(f"{DOCS}/index.md", "# example-team documents\n\nNothing listed yet.\n")
    sys.exit(0)

reports = "".join(
    f"- [Example report {n}](reports/example-report-{n}.md): what example step {n} checked\n" for n in range(2, 10)
)
write(f"{DOCS}/index.md", f"""# example-team documents

An example note for whoever edits this list. It is not a document and is not shown.

## Example designs

- [Example design](design/example-design.md): shapes, sizes and an **example** table (T5)
- [Example mock](design/example-mock.html): an .html file, opened by its default app
- [Example canvas](https://example.com/canvas): an example web link
- [Example design with a long title that does not fit on one line of a narrow list](design/example-design.md): and a long example note that is cut at the end of the line

## Example reports

- [Example report](reports/example-report.md): what the example checked
- [Report not written yet](reports/later.md): no file there
{reports}
## Does not open

- [Outside the folder](../../outside.md): a path that leaves the team's documents
- [Link out of the folder](escape.md): a symbolic link to a file outside
- [A file address](file:///etc/hosts): not a web link
- an example line without a link
- [Example script](tools/example.command): a script, never run by a click
- [Example folder](reports): a folder
- [Example picture](design/example-picture.svg): an .svg file, opened only by an editor
""")

write(f"{DOCS}/design/example-design.md", """# Example design

An example document with **bold**, `code` and a [link](https://example.com).

## Shapes

- an example circle
- an example square
  - [x] drawn
  - [ ] measured

| shape | size |
| --- | --- |
| circle | 12 |
| square | 16 |

> [!NOTE]
> An example note.

```swift
let example = 1
```
""")
write(f"{DOCS}/design/example-picture.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>\n')
write(f"{DOCS}/design/example-mock.html", "<!doctype html><title>Example mock</title><p>An example mock.</p>\n")
write(f"{DOCS}/reports/example-report.md", "# Example report\n\nWhat the example checked, in one paragraph.\n")
for n in range(2, 10):
    write(f"{DOCS}/reports/example-report-{n}.md", f"# Example report {n}\n\nWhat example step {n} checked.\n")
write(f"{T}/my-team/outside.md", "# Outside\n\nA file outside the team's documents. The app must not open it.\n")
os.symlink(f"{T}/my-team/outside.md", f"{DOCS}/escape.md")
write(f"{DOCS}/tools/example.command", "#!/bin/sh\necho example\n")
os.chmod(f"{DOCS}/tools/example.command", 0o755)

for n in range(10, 31):
    write(f"{DOCS}/reports/example-report-{n}.md", f"# Example report {n}\n\nWhat example step {n} checked.\n")
for n in range(1, 4):
    write(f"{DOCS}/review/example-review-{n}.md", f"# Example review {n}\n\nWhat example reviewer {n} found.\n")
for n in range(1, 5):
    write(f"{DOCS}/tickets/example-ticket-{n}.md", f"# Example ticket {n}\n\nWhat example task {n} asks for.\n")
write(f"{DOCS}/tickets/example-ticket-without-a-heading.md", "An example ticket that starts with a paragraph.\n")
write(f"{DOCS}/design/example-draft.html", "<!doctype html><title>Example draft</title><p>An example draft nobody listed.</p>\n")
write(f"{DOCS}/design/example-paper.pdf", "%PDF-1.4\n% an example file that only has the name of a PDF\n")
write(f"{DOCS}/example-notes.md", "# Example notes\n\nAn example file right in the documents folder.\n")
write(f"{DOCS}/reports/example-output.txt", "example output a report points at\n")
write(f"{DOCS}/reports/example-shot.png", "not a picture\n")
write(f"{DOCS}/reports/.example-hidden.md", "# Hidden\n")

def set_times_an_hour_apart_reports_newest():
    files = sorted(
        (os.path.join(folder, name) for folder, _, names in os.walk(DOCS) for name in names),
        key=lambda p: (not p.startswith(f"{DOCS}/reports/"), p),
    )
    now = int(os.path.getmtime(f"{DOCS}/index.md"))
    for hours, path in enumerate(files):
        os.utime(path, (now - 3600 * hours, now - 3600 * hours), follow_symlinks=False)


set_times_an_hour_apart_reports_newest()
