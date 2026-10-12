"""Gera a página /termos do site a partir do TERMOS.md (uma fonte só para o repositório e o site).
uso: uv run --with markdown python ferramentas/termos-html.py TERMOS.md <repo> <saida.html>"""
import re, sys, pathlib
import markdown

origem, repo, saida = sys.argv[1], sys.argv[2], sys.argv[3]
texto = pathlib.Path(origem).read_text().replace("](LICENSE)", f"]({repo}/blob/main/LICENSE)")
partes = dict(re.findall(r"<!-- (pt|en|es) -->\n(.*?)(?=\n<!-- (?:pt|en|es) -->|\Z)", texto, re.S))
blocos = "\n".join(
    f'<article data-lang="{l}" lang="{"pt-BR" if l == "pt" else l}">\n{markdown.markdown(partes[l])}\n</article>'
    for l in ("pt", "en", "es"))
html = f'''<!doctype html>
<html lang="pt-BR" data-l="pt">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Termos de Uso · Terms of Use · Términos de uso · Controle da TV</title>
<meta name="description" content="Termos de uso do Controle da TV, projeto independente e sem vínculo com a LG. Terms of use of Controle da TV, an independent project not affiliated with LG. Términos de uso de Controle da TV.">
<link rel="icon" type="image/png" href="/icone.png">
<script>
  // Idioma: escolha feita pela pessoa (botão) > ?lang= > idiomas do navegador > inglês.
  // Roda antes de a página aparecer, para não piscar em outro idioma.
  (function () {{
    var l = new URLSearchParams(location.search).get("lang"), salvo = null;
    try {{ salvo = localStorage.getItem("idioma-escolhido"); }} catch (e) {{}}
    l = l || salvo;
    if (!l) {{
      var lista = (navigator.languages && navigator.languages.length) ? navigator.languages : [navigator.language || ""];
      for (var i = 0; i < lista.length && !l; i++) {{
        var c = String(lista[i]).toLowerCase();
        l = c.indexOf("pt") === 0 ? "pt" : c.indexOf("es") === 0 ? "es" : c.indexOf("en") === 0 ? "en" : null;
      }}
    }}
    if (["pt", "en", "es"].indexOf(l) < 0) l = "en";
    document.documentElement.setAttribute("data-l", l);
    document.documentElement.lang = l === "pt" ? "pt-BR" : l;
  }})();
</script>
<style>
  :root {{ --fundo: #f4f6f9; --cartao: #fff; --texto: #1b2230; --suave: #5b6576; --borda: #dde2ea; --azul: #1f6fe5; --sobre-azul: #fff; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --fundo: #111418; --cartao: #1a1f26; --texto: #eef1f5;
    --suave: #a3adbd; --borda: #2c333d; --azul: #5aa9ff; --sobre-azul: #0b1a2e; }} }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--fundo); color: var(--texto); font: 17px/1.65 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }}
  main {{ max-width: 780px; margin: 0 auto; padding: 24px 16px 64px; }}
  [data-lang] {{ display: none; }}
  html[data-l="pt"] [data-lang="pt"], html[data-l="en"] [data-lang="en"], html[data-l="es"] [data-lang="es"] {{ display: block; }}
  .topo {{ display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 18px; }}
  .topo a {{ color: var(--azul); font-weight: 600; text-decoration: none; }}
  .idiomas {{ display: flex; gap: 6px; }}
  .idiomas button {{ font: inherit; font-size: 15px; background: var(--cartao); color: var(--texto); border: 1px solid var(--borda); border-radius: 999px; padding: 6px 14px; cursor: pointer; }}
  .idiomas button[aria-pressed="true"] {{ background: var(--azul); color: var(--sobre-azul); border-color: var(--azul); font-weight: 700; }}
  article {{ background: var(--cartao); border: 1px solid var(--borda); border-radius: 18px; padding: 8px 24px 20px; }}
  h2 {{ font-size: 26px; line-height: 1.2; }} h3 {{ font-size: 19px; margin-top: 26px; }}
  a {{ color: var(--azul); overflow-wrap: anywhere; }}
</style>
</head>
<body>
<main>
  <div class="topo">
    <a href="/">← Controle da TV</a>
    <nav class="idiomas" aria-label="Idioma / Language / Idioma">
      <button type="button" data-escolher="pt" lang="pt-BR">Português</button>
      <button type="button" data-escolher="en" lang="en">English</button>
      <button type="button" data-escolher="es" lang="es">Español</button>
    </nav>
  </div>
{blocos}
</main>
<script>
(function () {{
  function mostrar(l) {{
    document.documentElement.dataset.l = l;
    document.documentElement.lang = l === "pt" ? "pt-BR" : l;
    document.querySelectorAll("[data-escolher]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.escolher === l)));
  }}
  mostrar(document.documentElement.dataset.l);
  document.querySelectorAll("[data-escolher]").forEach((b) => b.addEventListener("click", () => {{
    try {{ localStorage.setItem("idioma-escolhido", b.dataset.escolher); }} catch (e) {{}}
    mostrar(b.dataset.escolher);
  }}));
}})();
</script>
</body>
</html>
'''
pathlib.Path(saida).write_text(html)
print("termos:", ", ".join(f"{l} {len(partes[l])} caracteres" for l in ("pt", "en", "es")))
