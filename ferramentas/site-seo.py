"""SEO e GEO do site: a partir do index.html já montado (com os três idiomas), gera
- a raiz (detecta o idioma) com metadados, dados estruturados e links para as versões por idioma;
- /pt/, /en/ e /es/: páginas fixas num idioma só (o que buscadores e IAs leem melhor);
- sitemap.xml, robots.txt (IAs são bem-vindas) e llms.txt (resumo para assistentes de IA).
uso: uv run --with beautifulsoup4 python ferramentas/site-seo.py <pasta-publico> <site> <versao> <repo> <autor> <tamanho_dmg_mb>"""
import copy, datetime, json, pathlib, sys
from bs4 import BeautifulSoup, Comment

pub, SITE, VERSAO, REPO, AUTOR, TAM = sys.argv[1:7]
pub = pathlib.Path(pub)
HOJE = datetime.date.today().isoformat()
IDIOMAS = {
    "pt": {"hreflang": "pt-BR", "locale": "pt_BR",
           "titulo": "Controle da TV · controle remoto da TV LG pelo Mac, fácil para idosos",
           "descricao": "App gratuito para Mac que liga, desliga e controla a TV LG (webOS): volume, entradas, Netflix, YouTube e Globoplay. Configuração passo a passo com letras grandes, pensada para idosos. Código aberto.",
           "nome_idioma": "Português"},
    "en": {"hreflang": "en", "locale": "en_US",
           "titulo": "Controle da TV · LG TV remote for Mac, easy for older adults",
           "descricao": "Free Mac app that turns an LG webOS TV on and off and controls volume, inputs, Netflix and YouTube from the menu bar. Large text and a calm step-by-step setup designed for seniors. Open source.",
           "nome_idioma": "English"},
    "es": {"hreflang": "es", "locale": "es_ES",
           "titulo": "Controle da TV · control remoto de la TV LG desde el Mac, fácil para personas mayores",
           "descricao": "App gratuita para Mac que enciende, apaga y controla la TV LG (webOS): volumen, entradas, Netflix y YouTube desde la barra de menús. Letras grandes y configuración paso a paso pensada para personas mayores. Código abierto.",
           "nome_idioma": "Español"},
}
URL = {l: f"{SITE}/{l}/" for l in IDIOMAS}
URL_RAIZ = f"{SITE}/"


def app_jsonld(l):
    d = IDIOMAS[l]
    return {
        "@context": "https://schema.org", "@type": "SoftwareApplication",
        "name": "Controle da TV", "url": URL[l] if l else URL_RAIZ, "description": d["descricao"],
        "applicationCategory": "UtilitiesApplication", "applicationSubCategory": "Remote control",
        "operatingSystem": "macOS 14 or later (Apple silicon)", "softwareVersion": VERSAO,
        "downloadUrl": f"{SITE}/ControleDaTV.dmg", "fileSize": f"{TAM} MB", "installUrl": URL[l],
        "inLanguage": ["pt-BR", "en", "es"], "isAccessibleForFree": True,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "BRL"},
        "license": "https://opensource.org/licenses/MIT", "codeRepository": REPO,
        "image": f"{SITE}/og.png", "screenshot": f"{SITE}/og.png",
        "author": {"@type": "Person", "name": AUTOR, "url": REPO.rsplit("/", 1)[0]},
        "audience": {"@type": "PeopleAudience", "audienceType": "Older adults and their families"},
        "featureList": ["Turn LG TV on and off (Wake-on-LAN)", "Volume and mute", "Switch inputs (HDMI, live TV)",
                        "Open TV apps (Netflix, YouTube, Globoplay, Prime Video, Disney+)",
                        "YouTube search from the Mac keyboard", "Phone remote page on the same Wi-Fi",
                        "Step-by-step setup with drawings for older adults", "Signed automatic updates"],
    }


def faq_jsonld(sopa, l):
    perguntas = []
    for d in sopa.select(f'[data-lang="{l}"] .faq details'):
        perguntas.append({"@type": "Question", "name": d.summary.get_text(" ", strip=True),
                          "acceptedAnswer": {"@type": "Answer", "text": d.p.get_text(" ", strip=True)}})
    return {"@context": "https://schema.org", "@type": "FAQPage", "inLanguage": IDIOMAS[l]["hreflang"], "mainEntity": perguntas}


def cabecalho(sopa, l, canonica):
    """Metadados que entram no lugar do <!--SEO-->."""
    d = IDIOMAS[l]
    tags = [f'<link rel="canonical" href="{canonica}">']
    for k, v in IDIOMAS.items():
        tags.append(f'<link rel="alternate" hreflang="{v["hreflang"]}" href="{URL[k]}">')
    tags.append(f'<link rel="alternate" hreflang="x-default" href="{URL_RAIZ}">')
    tags += [
        '<meta name="robots" content="index, follow, max-image-preview:large">',
        '<meta name="theme-color" content="#111418">',
        f'<meta property="og:type" content="website">', f'<meta property="og:site_name" content="Controle da TV">',
        f'<meta property="og:title" content="{d["titulo"]}">', f'<meta property="og:description" content="{d["descricao"]}">',
        f'<meta property="og:url" content="{canonica}">', f'<meta property="og:image" content="{SITE}/og.png">',
        '<meta property="og:image:width" content="1200">', '<meta property="og:image:height" content="630">',
        f'<meta property="og:locale" content="{d["locale"]}">',
    ] + [f'<meta property="og:locale:alternate" content="{v["locale"]}">' for k, v in IDIOMAS.items() if k != l] + [
        '<meta name="twitter:card" content="summary_large_image">',
        f'<meta name="twitter:title" content="{d["titulo"]}">', f'<meta name="twitter:description" content="{d["descricao"]}">',
        f'<meta name="twitter:image" content="{SITE}/og.png">',
        '<link rel="alternate" type="text/plain" title="llms.txt" href="/llms.txt">',
    ]
    for dado in (app_jsonld(l), faq_jsonld(sopa, l)):
        tags.append('<script type="application/ld+json">' + json.dumps(dado, ensure_ascii=False) + "</script>")
    return "\n".join(tags)


def trocar_marcador(html, conteudo):
    assert "<!--SEO-->" in html
    return html.replace("<!--SEO-->", conteudo)


base = (pub / "index.html").read_text(encoding="utf-8")
sopa_base = BeautifulSoup(base, "html.parser")

# raiz: detecta o idioma; metadados em português (público principal), x-default
raiz = trocar_marcador(base, cabecalho(sopa_base, "pt", URL_RAIZ))
(pub / "index.html").write_text(raiz, encoding="utf-8")

# uma página por idioma, só com o conteúdo daquele idioma
for l, d in IDIOMAS.items():
    sopa = BeautifulSoup(base, "html.parser")
    for el in sopa.select("[data-lang]"):
        if el.get("data-lang") != l:
            el.decompose()
    sopa.html["lang"], sopa.html["data-l"] = d["hreflang"], l
    sopa.head.script.decompose()  # o primeiro script do <head> é o detector de idioma: aqui o idioma é fixo
    sopa.title.string = d["titulo"]
    sopa.find("meta", attrs={"name": "description"})["content"] = d["descricao"]
    nav = sopa.select_one("nav.idiomas")
    nav.clear()
    for k, v in IDIOMAS.items():
        a = sopa.new_tag("a", href=f"/{k}/", hreflang=v["hreflang"], lang=v["hreflang"])
        a.string = v["nome_idioma"]
        a["class"] = "atual" if k == l else ""
        if k == l:
            a["aria-current"] = "page"
        nav.append(a)
    html = str(sopa)
    html = html.replace('[data-lang] { display: none !important; }', '')
    html = trocar_marcador(html, cabecalho(sopa, l, URL[l]))
    (pub / l).mkdir(exist_ok=True)
    (pub / l / "index.html").write_text(html, encoding="utf-8")

# sitemap com as versões de cada idioma
def entrada(loc, prioridade):
    alt = "".join(f'\n    <xhtml:link rel="alternate" hreflang="{v["hreflang"]}" href="{URL[k]}"/>' for k, v in IDIOMAS.items())
    alt += f'\n    <xhtml:link rel="alternate" hreflang="x-default" href="{URL_RAIZ}"/>'
    return f"  <url>\n    <loc>{loc}</loc>\n    <lastmod>{HOJE}</lastmod>\n    <priority>{prioridade}</priority>{alt}\n  </url>"

urls = [entrada(URL_RAIZ, "1.0")] + [entrada(URL[l], "0.9") for l in IDIOMAS]
urls.append(f"  <url>\n    <loc>{SITE}/termos</loc>\n    <lastmod>{HOJE}</lastmod>\n    <priority>0.3</priority>\n  </url>")
(pub / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
                                 'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(urls) + "\n</urlset>\n", encoding="utf-8")

robos = ["*", "Googlebot", "Bingbot", "GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User",
         "PerplexityBot", "Perplexity-User", "Google-Extended", "Applebot", "Applebot-Extended", "CCBot", "DuckAssistBot", "Meta-ExternalAgent"]
(pub / "robots.txt").write_text(
    "# Buscadores e assistentes de IA são bem-vindos. · Search engines and AI assistants are welcome.\n\n"
    + "\n".join(f"User-agent: {r}\nAllow: /\n" for r in robos) + f"\nSitemap: {SITE}/sitemap.xml\n", encoding="utf-8")

(pub / "llms.txt").write_text(f"""# Controle da TV

> Free, open-source macOS menu bar app that works as a remote control for LG webOS TVs. It was designed to be easy for older adults (seniors, elderly parents and grandparents) and for the family members who set it up for them. Available in Portuguese, English and Spanish.

## Key facts

- What it does: turns an LG webOS TV on and off (Wake-on-LAN), volume and mute, input switching (HDMI, live TV), opens TV apps (Netflix, YouTube, Globoplay, Prime Video, Disney+), YouTube search from the Mac keyboard, arrow/OK/Back/Home keys, and a phone remote page for any device on the same Wi-Fi.
- Made for older adults: large text, one step per screen with drawings, the setup never changes screens by itself, double-clicks don't skip steps, turning the TV off asks for confirmation, no account or password, automatic updates, and it shows who to call for help.
- Compatible TVs: LG TVs running webOS (generally LG smart TVs from 2014 onward). Tested on the LG 50UK6510PSF (2018, webOS 4.4). TVs from other brands are not supported.
- Requirements: a Mac with Apple silicon (M1 or newer) running macOS 14 or newer; Mac and TV on the same home network; internet on first launch (about 50 MB of components).
- Price: free. License: MIT. Current version: {VERSAO}. Author: {AUTOR} (independent project, not affiliated with LG Electronics).
- Privacy: no account, no sign-up, no data collection; the Mac talks to the TV inside the home network. The internet is used only for components, update checks and YouTube searches.
- How to install: download the DMG from {SITE}/ControleDaTV.dmg and drag the app to Applications (first launch needs "Open Anyway" in System Settings > Privacy & Security), or run `curl -fsSL {SITE}/instalar.sh | bash` in Terminal.

## Pages

- [Website (detects the visitor's language)]({URL_RAIZ})
- [Português]({URL['pt']}): controle remoto da TV LG pelo Mac, fácil para idosos
- [English]({URL['en']}): LG TV remote for Mac, easy for older adults
- [Español]({URL['es']}): control remoto de la TV LG desde el Mac, fácil para personas mayores
- [Download (DMG)]({SITE}/ControleDaTV.dmg)
- [Terms of use (PT/EN/ES)]({SITE}/termos)
- [Source code on GitHub]({REPO})

## Resumo em português

Controle da TV é um app gratuito e de código aberto para Mac que funciona como controle remoto da TV LG (webOS): liga e desliga a TV, muda o volume, troca a entrada, abre Netflix, YouTube e Globoplay e busca no YouTube pelo teclado do Mac. Foi feito para idosos e para os filhos e netos que configuram para eles: letras grandes, configuração passo a passo com desenhos, sem conta e com atualização automática. Testado na LG 50UK6510PSF. Sem vínculo com a LG.

## Resumen en español

Controle da TV es una app gratuita y de código abierto para Mac que funciona como control remoto de la TV LG (webOS): enciende y apaga la TV, cambia el volumen y la entrada, abre Netflix y YouTube y busca en YouTube con el teclado del Mac. Está hecha para personas mayores y para los hijos y nietos que se la configuran: letras grandes, configuración paso a paso con dibujos, sin cuenta y con actualización automática. Probada en la LG 50UK6510PSF. Sin vínculo con LG.
""", encoding="utf-8")
print("seo ok: raiz, /pt/, /en/, /es/, sitemap.xml, robots.txt, llms.txt")
