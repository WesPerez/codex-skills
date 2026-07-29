#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit


class AssetParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.references: list[tuple[str, str, str, int, int, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attribute = "src" if tag == "script" else "href" if tag == "link" else None
        if attribute is None:
            return
        for name, value in attrs:
            if name == attribute and value:
                line, column = self.getpos()
                self.references.append(
                    (tag, attribute, value, line, column, self.get_starttag_text())
                )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inventory script and link asset URLs from a saved HTML page"
    )
    parser.add_argument("html", type=Path)
    parser.add_argument("--page-url", required=True)
    return parser.parse_args()


def source_location(source: str, offset: int) -> tuple[int, int]:
    line = source.count("\n", 0, offset) + 1
    previous_newline = source.rfind("\n", 0, offset)
    return line, offset - previous_newline


def main() -> int:
    args = parse_args()
    page_parts = urlsplit(args.page_url)
    if page_parts.scheme not in {"http", "https"} or not page_parts.netloc:
        raise SystemExit("--page-url must be an absolute HTTP(S) URL")
    if not args.html.is_file():
        raise SystemExit(f"not a file: {args.html}")
    if args.html.stat().st_size > 10 * 1024 * 1024:
        raise SystemExit("HTML exceeds 10 MiB limit")

    raw = args.html.read_bytes()
    source = raw.decode("utf-8", errors="replace")
    parser = AssetParser()
    parser.feed(source)

    lines = source.splitlines(keepends=True)
    references: list[dict[str, object]] = []
    for tag, attribute, value, tag_line, tag_column, raw_tag in parser.references:
        value_in_tag = raw_tag.find(value)
        if value_in_tag < 0:
            raise SystemExit(f"could not locate parsed asset value: {value}")
        tag_offset = sum(len(part) for part in lines[: tag_line - 1]) + tag_column
        offset = tag_offset + value_in_tag
        if not source.startswith(value, offset):
            raise SystemExit(f"parsed asset location did not match source: {value}")
        line, column = source_location(source, offset)
        references.append(
            {
                "tag": tag,
                "attribute": attribute,
                "value": value,
                "resolved_url": urljoin(args.page_url, value),
                "line": line,
                "column": column,
                "character_offset": offset,
            }
        )

    print(
        json.dumps(
            {
                "page_url": args.page_url,
                "html": {
                    "file": str(args.html),
                    "size": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest(),
                },
                "assets": references,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
