"""Confere se todo texto T("…") do app tem tradução em macos/Traducoes.swift (inglês e espanhol)."""
import pathlib, re, sys
raiz = pathlib.Path(__file__).resolve().parent.parent / "macos"
literal = r'"((?:[^"\\]|\\.)*)"'
usadas = set()
for f in raiz.glob("*.swift"):
    if f.name != "Traducoes.swift":
        usadas.update(m.group(1) for m in re.finditer(r'\bT\(' + literal, f.read_text()))
tem = set(re.findall(r'^\s*' + literal + r':\s*\(', (raiz / "Traducoes.swift").read_text(), re.M))
faltam = sorted(usadas - tem)
if faltam:
    print("Textos sem tradução em macos/Traducoes.swift:")
    for t in faltam:
        print("  -", t)
    sys.exit(1)
print(f"traduções ok ({len(usadas)} textos)")
