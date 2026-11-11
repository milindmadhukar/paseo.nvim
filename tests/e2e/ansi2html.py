"""tmux `capture-pane -e` output -> a standalone HTML page, for a screenshot.

Handles what Neovim actually emits into a tmux pane: SGR resets, bold, italic,
underline, reverse, 16/256-colour and 24-bit foreground and background. Each
cell is one monospace character, so the page lines up with the terminal grid.

    python3 -I ansi2html.py in.ansi out.html [cols]
"""

import html
import re
import sys

BASE16 = [
    "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
    "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
]


def xterm256(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        levels = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (levels[n // 36], levels[(n // 6) % 6], levels[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


def apply(codes, st):
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            st.clear()
        elif c == 1:
            st["bold"] = True
        elif c == 3:
            st["italic"] = True
        elif c in (4, 21):
            st["underline"] = True
        elif c == 7:
            st["reverse"] = True
        elif c == 22:
            st.pop("bold", None)
        elif c == 23:
            st.pop("italic", None)
        elif c == 24:
            st.pop("underline", None)
        elif c == 27:
            st.pop("reverse", None)
        elif 30 <= c <= 37:
            st["fg"] = BASE16[c - 30]
        elif 90 <= c <= 97:
            st["fg"] = BASE16[c - 90 + 8]
        elif 40 <= c <= 47:
            st["bg"] = BASE16[c - 40]
        elif 100 <= c <= 107:
            st["bg"] = BASE16[c - 100 + 8]
        elif c == 39:
            st.pop("fg", None)
        elif c == 49:
            st.pop("bg", None)
        elif c in (38, 48) and i + 1 < len(codes):
            key = "fg" if c == 38 else "bg"
            if codes[i + 1] == 5 and i + 2 < len(codes):
                st[key] = xterm256(codes[i + 2])
                i += 2
            elif codes[i + 1] == 2 and i + 4 < len(codes):
                st[key] = "#%02x%02x%02x" % tuple(codes[i + 2 : i + 5])
                i += 4
        i += 1


def style(st):
    fg, bg = st.get("fg", "#d0d0d0"), st.get("bg")
    if st.get("reverse"):
        fg, bg = (bg or "#1c1c1c"), fg
    out = ["color:" + fg]
    if bg:
        out.append("background:" + bg)
    if st.get("bold"):
        out.append("font-weight:bold")
    if st.get("italic"):
        out.append("font-style:italic")
    if st.get("underline"):
        out.append("text-decoration:underline")
    return ";".join(out)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8", errors="replace").read()
    st, parts = {}, []
    for token in re.split(r"(\x1b\[[0-9;:]*m)", text):
        if token.startswith("\x1b["):
            raw = token[2:-1].replace(":", ";")
            apply([int(x) if x else 0 for x in raw.split(";")] if raw else [0], st)
        elif token:
            parts.append('<span style="%s">%s</span>' % (style(st), html.escape(token)))
    page = (
        "<!doctype html><meta charset=utf-8><style>"
        "body{margin:0;background:#1c1c1c}"
        "pre{margin:0;font:15px/19px 'JetBrainsMono Nerd Font','Symbols Nerd Font',monospace}"
        "</style><pre>" + "".join(parts) + "</pre>"
    )
    open(dst, "w", encoding="utf-8").write(page)


if __name__ == "__main__":
    main()
