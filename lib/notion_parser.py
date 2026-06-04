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

def normalize_code_language(language):
    if not language:
        return "plain text"
    normalized = language.strip().lower()
    normalized = LANGUAGE_ALIASES.get(normalized, normalized)
    return normalized if normalized in NOTION_CODE_LANGUAGES else "plain text"

def parse_inline_text(text):
    """
    Parses bold and italics in a string and returns Notion rich_text objects.
    """
    parts = []
    remaining = text
    while remaining:
        # Bold + Italic (***text***)
        bi_match = re.match(r'^(\*\*\*|___)(.*?)\1(.*)', remaining)
        if bi_match:
            parts.append({
                "text": {"content": bi_match.group(2)},
                "annotations": {"bold": True, "italic": True}
            })
            remaining = bi_match.group(3)
            continue

        # Bold (**text**)
        bold_match = re.match(r'^(\*\*|__)(.*?)\1(.*)', remaining)
        if bold_match:
            parts.append({
                "text": {"content": bold_match.group(2)},
                "annotations": {"bold": True}
            })
            remaining = bold_match.group(3)
            continue

        # Italic (*text*)
        italic_match = re.match(r'^(\*|_)(.*?)\1(.*)', remaining)
        if italic_match:
            parts.append({
                "text": {"content": italic_match.group(2)},
                "annotations": {"italic": True}
            })
            remaining = italic_match.group(3)
            continue
            
        # Plain text
        plain_match = re.match(r'^([^*_]+)(.*)', remaining)
        if plain_match:
            parts.append({"text": {"content": plain_match.group(1)}})
            remaining = plain_match.group(2)
        else:
            parts.append({"text": {"content": remaining[0]}})
            remaining = remaining[1:]

    return parts

def rich_text_to_md(rich_text_list):
    """
    Converts Notion rich_text objects back to Markdown string.
    """
    md = ""
    for rt in rich_text_list:
        text = rt.get("plain_text", "")
        ann = rt.get("annotations", {})
        
        if ann.get("bold") and ann.get("italic"):
            text = f"***{text}***"
        elif ann.get("bold"):
            text = f"**{text}**"
        elif ann.get("italic"):
            text = f"*{text}*"
        
        md += text
    return md

def md_to_notion_blocks(md_text):
    blocks = []
    lines = md_text.splitlines()
    in_code_block = False
    code_lang = "plain text"
    code_lines = []
    quote_lines = []
    callout_lines = []
    callout_icon = None

    def flush_quote_lines():
        nonlocal quote_lines
        if not quote_lines:
            return
        blocks.append({
            "object": "block",
            "type": "quote",
            "quote": {"rich_text": parse_inline_text("\n".join(quote_lines))}
        })
        quote_lines = []

    def flush_callout_lines():
        nonlocal callout_lines, callout_icon
        if not callout_lines:
            return
        blocks.append({
            "object": "block",
            "type": "callout",
            "callout": {
                "rich_text": parse_inline_text("\n".join(callout_lines)),
                "icon": {"emoji": callout_icon or "💡"}
            }
        })
        callout_lines = []
        callout_icon = None
    
    for line in lines:
        if in_code_block:
            if line.strip().startswith("```"):
                flush_quote_lines()
                flush_callout_lines()
                blocks.append({
                    "object": "block",
                    "type": "code",
                    "code": {
                        "rich_text": [{"text": {"content": "\n".join(code_lines)}}],
                        "language": code_lang
                    }
                })
                in_code_block = False
                code_lang = "plain text"
                code_lines = []
            else:
                code_lines.append(line)
            continue

        stripped = line.strip()
        if stripped.startswith("```"):
            flush_quote_lines()
            flush_callout_lines()
            in_code_block = True
            lang = stripped[3:].strip()
            code_lang = normalize_code_language(lang)
            code_lines = []
            continue

        if not stripped:
            flush_quote_lines()
            flush_callout_lines()
            continue
            
        line = stripped
            
        # Table of Contents placeholder
        if line == "[TOC]":
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "table_of_contents",
                "table_of_contents": {}
            })
            continue

        # Headers
        if line.startswith("# "):
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "heading_1",
                "heading_1": {"rich_text": parse_inline_text(line[2:])}
            })
        elif line.startswith("## "):
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "heading_2",
                "heading_2": {"rich_text": parse_inline_text(line[3:])}
            })
        elif line.startswith("### "):
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "heading_3",
                "heading_3": {"rich_text": parse_inline_text(line[4:])}
            })
            
        # Checklists
        elif line.startswith("- [ ] "):
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "to_do",
                "to_do": {"rich_text": parse_inline_text(line[6:]), "checked": False}
            })
        elif line.startswith("- [x] ") or line.startswith("- [X] "):
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "to_do",
                "to_do": {"rich_text": parse_inline_text(line[6:]), "checked": True}
            })
            
        # Bulleted Lists
        elif line.startswith("- ") or line.startswith("* "):
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "bulleted_list_item",
                "bulleted_list_item": {"rich_text": parse_inline_text(line[2:])}
            })
            
        # Callouts and quotes
        elif line.startswith("> "):
            content = line[2:]
            alert_match = re.match(r'^\[!(.*?)\]\s*(.*)', content)
            if alert_match:
                flush_quote_lines()
                flush_callout_lines()
                icon = "💡"
                alert_type = alert_match.group(1).upper()
                content = alert_match.group(2)
                if "WARN" in alert_type: icon = "⚠️"
                elif "ERROR" in alert_type or "DANGER" in alert_type: icon = "🚨"
                elif "INFO" in alert_type: icon = "ℹ️"
                elif "SUCCESS" in alert_type: icon = "✅"
                callout_icon = icon
                callout_lines.append(content)
            else:
                if callout_lines:
                    callout_lines.append(content)
                else:
                    quote_lines.append(content)
            
        # Paragraph
        else:
            flush_quote_lines()
            flush_callout_lines()
            blocks.append({
                "object": "block",
                "type": "paragraph",
                "paragraph": {"rich_text": parse_inline_text(line)}
            })

    flush_quote_lines()
    flush_callout_lines()

    if in_code_block:
        blocks.append({
            "object": "block",
            "type": "code",
            "code": {
                "rich_text": [{"text": {"content": "\n".join(code_lines)}}],
                "language": code_lang
            }
        })
            
    return blocks

def notion_blocks_to_md(blocks):
    """
    Converts Notion block objects back to Markdown string with improved spacing.
    """
    md_lines = []
    prev_type = None
    
    for block in blocks:
        b_type = block.get("type")
        if not b_type: continue
        
        # Add a blank line between different block types, 
        # but keep list items of the same type together.
        if prev_type is not None:
            is_list = b_type in ["bulleted_list_item", "to_do"]
            is_same_list = is_list and b_type == prev_type
            if not is_same_list:
                md_lines.append("")

        if b_type == "table_of_contents":
            md_lines.append("[TOC]")
        else:
            content = block.get(b_type, {})
            rich_text = content.get("rich_text", [])
            text = rich_text_to_md(rich_text)
            
            if b_type == "heading_1":
                md_lines.append(f"# {text}")
            elif b_type == "heading_2":
                md_lines.append(f"## {text}")
            elif b_type == "heading_3":
                md_lines.append(f"### {text}")
            elif b_type == "bulleted_list_item":
                md_lines.append(f"- {text}")
            elif b_type == "to_do":
                checked = content.get("checked", False)
                mark = "x" if checked else " "
                md_lines.append(f"- [{mark}] {text}")
            elif b_type == "callout":
                icon = content.get("icon", {}).get("emoji", "💡")
                prefix = "[!NOTE]"
                if icon == "⚠️": prefix = "[!WARNING]"
                elif icon == "🚨": prefix = "[!ERROR]"
                elif icon == "ℹ️": prefix = "[!INFO]"
                elif icon == "✅": prefix = "[!SUCCESS]"
                lines = text.split("\n") if text else [""]
                md_lines.append(f"> {prefix} {lines[0]}".rstrip())
                for line in lines[1:]:
                    md_lines.append(f"> {line}")
            elif b_type == "quote":
                if text:
                    md_lines.extend([f"> {line}" for line in text.split("\n")])
                else:
                    md_lines.append("> ")
            elif b_type == "paragraph":
                md_lines.append(text)
            elif b_type == "code":
                code_text = text
                language = content.get("language", "plain text")
                lang_suffix = "" if language in ["plain text", "plain_text"] else language
                md_lines.append(f"```{lang_suffix}")
                if code_text:
                    md_lines.extend(code_text.split("\n"))
                md_lines.append("```")
        
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
            with open(file_path, 'r') as f:
                content = f.read()
            print(json.dumps(md_to_notion_blocks(content)))
        except Exception as e:
            sys.stderr.write(f"Error: {str(e)}\n")
            sys.exit(1)
