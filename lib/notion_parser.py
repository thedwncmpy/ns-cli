import sys
import json
import re

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
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        # Table of Contents placeholder
        if line == "[TOC]":
            blocks.append({
                "object": "block",
                "type": "table_of_contents",
                "table_of_contents": {}
            })
            continue

        # Headers
        if line.startswith("# "):
            blocks.append({
                "object": "block",
                "type": "heading_1",
                "heading_1": {"rich_text": parse_inline_text(line[2:])}
            })
        elif line.startswith("## "):
            blocks.append({
                "object": "block",
                "type": "heading_2",
                "heading_2": {"rich_text": parse_inline_text(line[3:])}
            })
        elif line.startswith("### "):
            blocks.append({
                "object": "block",
                "type": "heading_3",
                "heading_3": {"rich_text": parse_inline_text(line[4:])}
            })
            
        # Checklists
        elif line.startswith("- [ ] "):
            blocks.append({
                "object": "block",
                "type": "to_do",
                "to_do": {"rich_text": parse_inline_text(line[6:]), "checked": False}
            })
        elif line.startswith("- [x] ") or line.startswith("- [X] "):
            blocks.append({
                "object": "block",
                "type": "to_do",
                "to_do": {"rich_text": parse_inline_text(line[6:]), "checked": True}
            })
            
        # Bulleted Lists
        elif line.startswith("- ") or line.startswith("* "):
            blocks.append({
                "object": "block",
                "type": "bulleted_list_item",
                "bulleted_list_item": {"rich_text": parse_inline_text(line[2:])}
            })
            
        # Callouts
        elif line.startswith("> "):
            content = line[2:]
            icon = "💡"
            alert_match = re.match(r'^\[!(.*?)\]\s*(.*)', content)
            if alert_match:
                alert_type = alert_match.group(1).upper()
                content = alert_match.group(2)
                if "WARN" in alert_type: icon = "⚠️"
                elif "ERROR" in alert_type or "DANGER" in alert_type: icon = "🚨"
                elif "INFO" in alert_type: icon = "ℹ️"
                elif "SUCCESS" in alert_type: icon = "✅"
            
            blocks.append({
                "object": "block",
                "type": "callout",
                "callout": {
                    "rich_text": parse_inline_text(content),
                    "icon": {"emoji": icon}
                }
            })
            
        # Paragraph
        else:
            blocks.append({
                "object": "block",
                "type": "paragraph",
                "paragraph": {"rich_text": parse_inline_text(line)}
            })
            
    return blocks[:100]

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
                prefix = "> "
                if icon == "⚠️": prefix += "[!WARNING] "
                elif icon == "🚨": prefix += "[!ERROR] "
                elif icon == "ℹ️": prefix += "[!INFO] "
                elif icon == "✅": prefix += "[!SUCCESS] "
                md_lines.append(f"{prefix}{text}")
            elif b_type == "paragraph":
                md_lines.append(text)
        
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
