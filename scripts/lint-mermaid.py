#!/usr/bin/env python3
"""
Lightweight Mermaid Diagram & Markdown Syntax Validator
Validates all ```mermaid code blocks across repository markdown files.
Zero external browser/Puppeteer dependencies.
"""

import sys
import re
from pathlib import Path

SUPPORTED_DIAGRAM_TYPES = [
    "flowchart",
    "graph",
    "sequenceDiagram",
    "stateDiagram",
    "stateDiagram-v2",
    "classDiagram",
    "erDiagram",
    "xychart-beta",
    "journey",
    "gitGraph",
    "pie",
    "mindmap",
    "timeline",
    "quadrantChart",
    "c4Context",
    "architecture-beta"
]

def extract_mermaid_blocks(content):
    """Extract (start_line, code_lines) for each ```mermaid block."""
    blocks = []
    lines = content.splitlines()
    in_block = False
    start_line = 0
    current_code = []

    for idx, line in enumerate(lines, 1):
        stripped = line.strip()
        if not in_block:
            if stripped.startswith("```mermaid"):
                in_block = True
                start_line = idx
                current_code = []
        else:
            if stripped == "```":
                in_block = False
                blocks.append((start_line, current_code))
                current_code = []
            else:
                current_code.append((idx, line))

    if in_block:
        blocks.append((start_line, current_code)) # unclosed block
    return blocks

def validate_block(file_path, start_line, code_entries):
    errors = []
    if not code_entries:
        errors.append(f"{file_path}:{start_line}: Empty mermaid diagram block.")
        return errors

    # Filter out blank lines and comments
    content_lines = [(ln, text) for (ln, text) in code_entries if text.strip() and not text.strip().startswith("%%")]

    if not content_lines:
        errors.append(f"{file_path}:{start_line}: Mermaid block contains no valid diagram statements.")
        return errors

    header_line_num, first_line = content_lines[0]
    matched_type = any(first_line.strip().startswith(dtype) for dtype in SUPPORTED_DIAGRAM_TYPES)
    if not matched_type:
        errors.append(
            f"{file_path}:{header_line_num}: Unsupported or missing diagram header: '{first_line.strip()}'. "
            f"Must start with one of {SUPPORTED_DIAGRAM_TYPES[:8]}..."
        )

    # Check structural balance
    subgraphs_opened = 0
    subgraphs_closed = 0

    for ln, line in content_lines:
        stripped = line.strip()
        # Count subgraphs
        if re.match(r"^subgraph\b", stripped):
            subgraphs_opened += 1
        elif stripped == "end":
            subgraphs_closed += 1

        # Check for unquoted parenthesis or brackets in standard node bracket labels: e.g. Node[Label (extra)]
        # Cylinder shapes: id[("...")] or id[(...)] are valid
        # Stadium shapes: id([ ... ]) are valid
        # Circle shapes: id(( ... )) are valid
        # Standard rectangle: id[ ... ]
        # Find rectangles that are NOT cylinders [(...)] and NOT stadiums [|...|]
        # Match pattern: \w+\[(?![\(\[\/\\|])
        for match in re.finditer(r'(\b\w+\[)(?![\(\[\/\\|])([^\]]+)\]', stripped):
            label_inside = match.group(2)
            # If label contains unquoted '(' or ')', flag it!
            # Strip valid quoted strings inside label
            unquoted = re.sub(r'"[^"]*"', '', label_inside)
            if '(' in unquoted or ')' in unquoted:
                errors.append(
                    f"{file_path}:{ln}: Unquoted parentheses inside rectangle node bracket: '{match.group(0)}'. "
                    f"Labels with parentheses must be quoted: e.g. id[\"Label (extra)\"]"
                )

        # Check for unclosed double quotes on line
        # Count non-escaped double quotes
        quotes = re.findall(r'(?<!\\)"', stripped)
        if len(quotes) % 2 != 0:
            errors.append(f"{file_path}:{ln}: Unmatched double quote in line: '{stripped}'")

    if subgraphs_opened != subgraphs_closed:
        errors.append(
            f"{file_path}:{start_line}: Subgraph mismatch: opened {subgraphs_opened} subgraph(s) but closed {subgraphs_closed}."
        )

    return errors

def main():
    root = Path(__file__).resolve().parent.parent
    md_files = sorted(list(root.glob("docs/**/*.md")) + list(root.glob("*.md")))
    
    total_diagrams = 0
    all_errors = []

    for md_path in md_files:
        if "node_modules" in str(md_path) or ".direnv" in str(md_path):
            continue
        try:
            content = md_path.read_text(encoding="utf-8")
        except Exception as e:
            all_errors.append(f"Failed to read {md_path}: {e}")
            continue

        blocks = extract_mermaid_blocks(content)
        total_diagrams += len(blocks)

        for start_line, code_entries in blocks:
            errs = validate_block(md_path.relative_to(root), start_line, code_entries)
            all_errors.extend(errs)

    print("==============================================================================")
    print("📊 Mermaid Diagram Syntax Validation")
    print("==============================================================================")
    print(f"Scanned {len(md_files)} markdown files. Found {total_diagrams} Mermaid diagrams.")

    if all_errors:
        print(f"\n❌ Found {len(all_errors)} syntax error(s):")
        for err in all_errors:
            print(f"  • {err}")
        sys.exit(1)
    else:
        print("✅ All Mermaid diagrams passed syntax validation.")
        sys.exit(0)

if __name__ == "__main__":
    main()
