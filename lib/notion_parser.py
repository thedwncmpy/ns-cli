import sys
import json
import re

NOTION_CODE_LANGUAGES = {
    "abap", "abc", "agda", "arduino", "ascii art", "assembly", "bash", "basic", "bnf", "c", "c#",
    "c++", "clojure", "coffeescript", "coq", "css", "dart", "dhall", "diff", "docker", "ebnf",
    "elixir", "elm", "erlang", "f#", "flow", "fortran", "gherkin", "glsl", "go", "graphql",
    "groovy", "haskell", "hcl", "html", "idris", "java", "javascript", "json", "julia", "kotlin",
    "latex", "less", "lisp", "livescript", "llvm ir", "lua", "makefile", "markdown", "markup",
    "matlab", "mathematica", "mermaid", "nix", "notion formula", "objective-c", "ocaml", "pascal",
    "perl", "php", "plain text", "powershell", "prolog", "protobuf", "purescript", "python", "r",
    "racket", "reason", "ruby", "rust", "sass", "scala", "scheme", "scss", "shell", "smalltalk",
    "solidity", "sql", "swift", "toml", "typescript", "vb.net", "verilog", "vhdl", "visual basic",
    "webassembly", "xml", "yaml", "java/c/c++/c#"
}

LANGUAGE_ALIASES = {
    "plain_text": "plain text",
    "plaintext": "plain text",
    "text": "plain text",
    "sh": "shell",
    "zsh": "shell",
    "py": "python",
    "js": "javascript",
    "ts": "typescript",
    "yml": "yaml",
    "md": "markdown",
    "csv": "plain text"
}

TOGGLEABLE_HEADING_PREFIX = "[toggle] "
INDENT_WIDTH = 2


def normalize_code_language(language):
    if not language:
        return "plain text"
    normalized = language.strip().lower()
    normalized = LANGUAGE_ALIASES.get(normalized, normalized)
    return normalized if normalized in NOTION_CODE_LANGUAGES else "plain text"


def parse_inline_text(text):
    parts = []
    remaining = text
    flags = re.DOTALL
    while remaining:
        bi_match = re.match(r'^(\*\*\*|___)(.*?)\1(.*)', remaining, flags)
        if bi_match:
            parts.append({
                "text": {"content": bi_match.group(2)},
                "annotations": {"bold": True, "italic": True}
            })
            remaining = bi_match.group(3)
            continue

        bold_match = re.match(r'^(\*\*|__)(.*?)\1(.*)', remaining, flags)
        if bold_match:
            parts.append({
                "text": {"content": bold_match.group(2)},
                "annotations": {"bold": True}
            })
            remaining = bold_match.group(3)
            continue

        italic_match = re.match(r'^(\*|_)(.*?)\1(.*)', remaining, flags)
        if italic_match:
            parts.append({
                "text": {"content": italic_match.group(2)},
                "annotations": {"italic": True}
            })
            remaining = italic_match.group(3)
            continue

        plain_match = re.match(r'^([^*_]+)(.*)', remaining, flags)
        if plain_match:
            parts.append({"text": {"content": plain_match.group(1)}})
            remaining = plain_match.group(2)
        else:
            parts.append({"text": {"content": remaining[0]}})
            remaining = remaining[1:]

    return parts


def rich_text_to_md(rich_text_list):
    md = ""
    for rt in rich_text_list:
        text = rt.get("plain_text")
        if text is None:
            text = rt.get("text", {}).get("content", "")
        ann = rt.get("annotations", {})

        if ann.get("bold") and ann.get("italic"):
            text = f"***{text}***"
        elif ann.get("bold"):
            text = f"**{text}**"
        elif ann.get("italic"):
            text = f"*{text}*"

        md += text
    return md


def parse_heading(text):
    is_toggleable = False
    if text.lower().startswith(TOGGLEABLE_HEADING_PREFIX):
        is_toggleable = True
        text = text[len(TOGGLEABLE_HEADING_PREFIX):]
    return {
        "rich_text": parse_inline_text(text),
        "is_toggleable": is_toggleable
    }


def indentation_units(line):
    units = 0
    for char in line:
        if char == " ":
            units += 1
        elif char == "\t":
            units += INDENT_WIDTH
        else:
            break
    return units


def strip_indent(line, indent_units):
    if not line:
        return line
    consumed_units = 0
    consumed_chars = 0
    for char in line:
        if char == " ":
            if consumed_units + 1 > indent_units:
                break
            consumed_units += 1
            consumed_chars += 1
        elif char == "\t":
            if consumed_units + INDENT_WIDTH > indent_units:
                break
            consumed_units += INDENT_WIDTH
            consumed_chars += 1
        else:
            break
    return line[consumed_chars:]


def parse_single_block(line):
    stripped = line.strip()

    if stripped == "[TOC]":
        return {
            "object": "block",
            "type": "table_of_contents",
            "table_of_contents": {}
        }
    if stripped.startswith("# "):
        return {
            "object": "block",
            "type": "heading_1",
            "heading_1": parse_heading(stripped[2:])
        }
    if stripped.startswith("## "):
        return {
            "object": "block",
            "type": "heading_2",
            "heading_2": parse_heading(stripped[3:])
        }
    if stripped.startswith("### "):
        return {
            "object": "block",
            "type": "heading_3",
            "heading_3": parse_heading(stripped[4:])
        }
    if stripped.startswith("- [ ] "):
        return {
            "object": "block",
            "type": "to_do",
            "to_do": {"rich_text": parse_inline_text(stripped[6:]), "checked": False}
        }
    if stripped.startswith("- [x] ") or stripped.startswith("- [X] "):
        return {
            "object": "block",
            "type": "to_do",
            "to_do": {"rich_text": parse_inline_text(stripped[6:]), "checked": True}
        }
    if stripped.startswith("- ") or stripped.startswith("* "):
        return {
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": {"rich_text": parse_inline_text(stripped[2:])}
        }
    if stripped.startswith("> "):
        content = stripped[2:]
        alert_match = re.match(r'^\[!(.*?)\]\s*(.*)', content)
        if alert_match:
            icon = "💡"
            alert_type = alert_match.group(1).upper()
            content = alert_match.group(2)
            if "WARN" in alert_type:
                icon = "⚠️"
            elif "ERROR" in alert_type or "DANGER" in alert_type:
                icon = "🚨"
            elif "INFO" in alert_type:
                icon = "ℹ️"
            elif "SUCCESS" in alert_type:
                icon = "✅"
            return {
                "object": "block",
                "type": "callout",
                "callout": {
                    "rich_text": parse_inline_text(content),
                    "icon": {"emoji": icon}
                }
            }
        return {
            "object": "block",
            "type": "quote",
            "quote": {"rich_text": parse_inline_text(content)}
        }
    return {
        "object": "block",
        "type": "paragraph",
        "paragraph": {"rich_text": parse_inline_text(stripped)}
    }


def parse_blocks(lines, start=0, base_indent=0):
    blocks = []
    i = start

    while i < len(lines):
        raw_line = lines[i]
        if not raw_line.strip():
            i += 1
            continue

        current_indent = indentation_units(raw_line)
        if current_indent < base_indent:
            break
        if current_indent > base_indent:
            break

        line = strip_indent(raw_line, base_indent)

        if line.strip().startswith("```"):
            lang = line.strip()[3:].strip()
            code_lang = normalize_code_language(lang)
            code_lines = []
            i += 1
            while i < len(lines):
                next_line = lines[i]
                if indentation_units(next_line) < base_indent:
                    break
                candidate = strip_indent(next_line, base_indent)
                if candidate.strip().startswith("```"):
                    i += 1
                    break
                code_lines.append(candidate)
                i += 1
            blocks.append({
                "object": "block",
                "type": "code",
                "code": {
                    "rich_text": [{"text": {"content": "\n".join(code_lines)}}],
                    "language": code_lang
                }
            })
            continue

        if line.strip().startswith("> "):
            content_lines = []
            icon = None
            block_type = None
            while i < len(lines):
                next_line = lines[i]
                if not next_line.strip():
                    break
                if indentation_units(next_line) != base_indent:
                    break
                candidate = strip_indent(next_line, base_indent)
                if not candidate.strip().startswith("> "):
                    break
                content = candidate.strip()[2:]
                alert_match = re.match(r'^\[!(.*?)\]\s*(.*)', content)
                if alert_match and block_type is None:
                    block_type = "callout"
                    alert_type = alert_match.group(1).upper()
                    content = alert_match.group(2)
                    icon = "💡"
                    if "WARN" in alert_type:
                        icon = "⚠️"
                    elif "ERROR" in alert_type or "DANGER" in alert_type:
                        icon = "🚨"
                    elif "INFO" in alert_type:
                        icon = "ℹ️"
                    elif "SUCCESS" in alert_type:
                        icon = "✅"
                elif alert_match and block_type == "callout":
                    content = alert_match.group(2)
                elif block_type is None:
                    block_type = "quote"
                content_lines.append(content)
                i += 1

            if block_type == "callout":
                blocks.append({
                    "object": "block",
                    "type": "callout",
                    "callout": {
                        "rich_text": parse_inline_text("\n".join(content_lines)),
                        "icon": {"emoji": icon or "💡"}
                    }
                })
            else:
                blocks.append({
                    "object": "block",
                    "type": "quote",
                    "quote": {"rich_text": parse_inline_text("\n".join(content_lines))}
                })
            continue

        block = parse_single_block(line)
        i += 1

        if block["type"] == "table_of_contents":
            blocks.append(block)
            blocks.append({
                "object": "block",
                "type": "divider",
                "divider": {}
            })
            continue

        if block["type"] in ["heading_1", "heading_2", "heading_3"] and block[block["type"]].get("is_toggleable"):
            child_start = i
            child_indent = None
            while child_start < len(lines):
                candidate = lines[child_start]
                if not candidate.strip():
                    child_start += 1
                    continue
                candidate_indent = indentation_units(candidate)
                if candidate_indent <= base_indent:
                    break
                child_indent = candidate_indent
                break

            if child_indent is not None:
                children, i = parse_blocks(lines, child_start, child_indent)
                if children:
                    block[block["type"]]["children"] = children

        blocks.append(block)

    return blocks, i


def md_to_notion_blocks(md_text):
    blocks, _ = parse_blocks(md_text.splitlines(), 0, 0)
    return blocks


def render_block(block, indent=0):
    b_type = block.get("type")
    if not b_type:
        return []

    content = block.get(b_type, {})
    rich_text = content.get("rich_text", [])
    text = rich_text_to_md(rich_text)
    prefix = " " * indent

    if b_type == "table_of_contents":
        lines = [f"{prefix}[TOC]", "", f"{prefix}---"]
    elif b_type == "heading_1":
        toggle_prefix = TOGGLEABLE_HEADING_PREFIX if content.get("is_toggleable", False) else ""
        lines = [f"{prefix}# {toggle_prefix}{text}"]
    elif b_type == "heading_2":
        toggle_prefix = TOGGLEABLE_HEADING_PREFIX if content.get("is_toggleable", False) else ""
        lines = [f"{prefix}## {toggle_prefix}{text}"]
    elif b_type == "heading_3":
        toggle_prefix = TOGGLEABLE_HEADING_PREFIX if content.get("is_toggleable", False) else ""
        lines = [f"{prefix}### {toggle_prefix}{text}"]
    elif b_type == "bulleted_list_item":
        lines = [f"{prefix}- {text}"]
    elif b_type == "to_do":
        mark = "x" if content.get("checked", False) else " "
        lines = [f"{prefix}- [{mark}] {text}"]
    elif b_type == "callout":
        icon = content.get("icon", {}).get("emoji", "💡")
        marker = "[!NOTE]"
        if icon == "⚠️":
            marker = "[!WARNING]"
        elif icon == "🚨":
            marker = "[!ERROR]"
        elif icon == "ℹ️":
            marker = "[!INFO]"
        elif icon == "✅":
            marker = "[!SUCCESS]"
        text_lines = text.split("\n") if text else [""]
        lines = [f"{prefix}> {marker} {text_lines[0]}".rstrip()]
        for line in text_lines[1:]:
            lines.append(f"{prefix}> {line}")
    elif b_type == "quote":
        text_lines = text.split("\n") if text else [""]
        lines = [f"{prefix}> {line}".rstrip() for line in text_lines]
    elif b_type == "paragraph":
        lines = [f"{prefix}{text}"]
    elif b_type == "code":
        language = content.get("language", "plain text")
        lang_suffix = "" if language in ["plain text", "plain_text"] else language
        code_text = text
        lines = [f"{prefix}```{lang_suffix}"]
        if code_text:
            for line in code_text.split("\n"):
                lines.append(f"{prefix}{line}")
        lines.append(f"{prefix}```")
    else:
        return []

    children = content.get("children", [])
    if children:
        for child in children:
            lines.append("")
            lines.extend(render_block(child, indent + INDENT_WIDTH))
    return lines


def notion_blocks_to_md(blocks):
    md_lines = []
    prev_type = None

    for block in blocks:
        b_type = block.get("type")
        if not b_type:
            continue

        if prev_type is not None:
            is_list = b_type in ["bulleted_list_item", "to_do"]
            is_same_list = is_list and b_type == prev_type
            if not is_same_list:
                md_lines.append("")

        md_lines.extend(render_block(block, 0))
        prev_type = b_type

    return "\n".join(md_lines)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)

    if sys.argv[1] == "--reverse":
        try:
            data = sys.stdin.read()
            if not data:
                sys.exit(0)
            blocks = json.loads(data)
            print(notion_blocks_to_md(blocks))
        except Exception as e:
            sys.stderr.write(f"Error in reverse parsing: {str(e)}\n")
            sys.exit(1)
    else:
        file_path = sys.argv[1]
        try:
            with open(file_path, "r") as f:
                content = f.read()
            print(json.dumps(md_to_notion_blocks(content)))
        except Exception as e:
            sys.stderr.write(f"Error in forward parsing: {str(e)}\n")
            sys.exit(1)
