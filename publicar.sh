#!/bin/bash
# Publica uma versão do Controle da TV no site configurado em publicar.conf (SITE).
#   ./publicar.sh 1.0.3 "o que mudou"
#   ./publicar.sh --so-site          só a página, os termos e o instalador (mesma versão do app)
# Sobe a versão (compilação +1), compila e assina, gera o zip (atualização automática), o DMG (download
# pelo site), o versao.json assinado com a chave Ed25519 e publica tudo num Worker da Cloudflare
# (só arquivos estáticos, com domínio próprio). Precisa do wrangler (npm i -g wrangler) com login feito.
set -euo pipefail
cd "$(dirname "$0")"
source ferramentas/config.sh
SO_SITE=0
[ "${1:-}" = "--so-site" ] && SO_SITE=1
NOVA=${1:?uso: ./publicar.sh <versão> "o que mudou"  |  ./publicar.sh --so-site}
NOTAS=${2:-}
[ -n "$SITE" ] && [ -n "$CLOUDFLARE_CONTA" ] || { echo "Configure SITE e CLOUDFLARE_CONTA no publicar.conf (modelo: publicar.conf.exemplo)"; exit 1; }
[ -f "$SEGREDOS/atualizacao-ed25519.key" ] || {
  swiftc -O ferramentas/assinar.swift -o "$SAIDA/assinar" 2>/dev/null
  echo "chave de atualização nova (guarde a pasta $SEGREDOS em lugar seguro):"
  "$SAIDA/assinar" gerar "$SEGREDOS/atualizacao-ed25519.key"
}
WRANGLER=$(command -v wrangler || echo "$HOME/.local/bin/wrangler")

APP="$SAIDA/Controle da TV.app"
PUB="$SAIDA/publico"
if [ "$SO_SITE" = 1 ]; then
  [ -f "$PUB/versao.json" ] && [ -f "$PUB/ControleDaTV.dmg" ] && [ -d "$APP" ] || { echo "rode uma publicação completa antes"; exit 1; }
  NOVA=$(plutil -extract versao raw -o - "$PUB/versao.json")
  BUILD=$(plutil -extract build raw -o - "$PUB/versao.json")
  ZIP="ControleDaTV-$NOVA.zip"
  echo "== só o site (app continua na $NOVA, compilação $BUILD)"
else
  ATUAL=$(cat VERSAO 2>/dev/null || true)
  if [ "$NOVA" != "$ATUAL" ]; then
    echo "$NOVA" > VERSAO
    echo $(( $(cat COMPILACAO 2>/dev/null || echo 0) + 1 )) > COMPILACAO
  fi
  BUILD=$(cat COMPILACAO)
  echo "== versão $NOVA (compilação $BUILD)"

  ./build.sh
  [ -x "$SAIDA/assinar" ] && [ "$SAIDA/assinar" -nt ferramentas/assinar.swift ] || swiftc -O ferramentas/assinar.swift -o "$SAIDA/assinar" 2>/dev/null
  rm -rf "$PUB"; mkdir -p "$PUB"

  # zip da atualização automática + manifesto assinado
  ZIP="ControleDaTV-$NOVA.zip"
  ditto -c -k --keepParent "$APP" "$PUB/$ZIP"
  SHA=$(shasum -a 256 "$PUB/$ZIP" | cut -d' ' -f1)
  TAM=$(stat -f %z "$PUB/$ZIP")
  "$SAIDA/assinar" manifesto "$SEGREDOS/atualizacao-ed25519.key" "$NOVA" "$BUILD" "$SITE/$ZIP" "$SHA" "$TAM" "$NOTAS" > "$PUB/versao.json"

  # DMG com as instruções (pt, en, es) desenhadas no fundo
  "$SAIDA/icone" fundo "$SAIDA/fundo-dmg.png" 1
  "$SAIDA/icone" fundo "$SAIDA/fundo-dmg@2x.png" 2
  tiffutil -cathidpicheck "$SAIDA/fundo-dmg.png" "$SAIDA/fundo-dmg@2x.png" -out "$SAIDA/fundo-dmg.tiff" 2>/dev/null
  uv run -q --no-project --with dmgbuild==1.6.7 dmgbuild -s ferramentas/dmg.py \
    -D app="$APP" -D icone="$SAIDA/AppIcon.icns" -D fundo="$SAIDA/fundo-dmg.tiff" \
    "Controle da TV" "$PUB/ControleDaTV.dmg" 2>&1 | grep -v "hdiutil: WARNING" || true
  [ -f "$PUB/ControleDaTV.dmg" ] || { echo "o DMG não foi gerado"; exit 1; }
fi
TAM_DMG=$(awk "BEGIN { printf \"%.0f\", $(stat -f %z "$PUB/ControleDaTV.dmg") / 1048576 }")

# site (pt, en, es) e termos de uso
REQUISITO=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/.*certificate root = H"\([0-9a-f]*\)".*/\1/p')
[ -n "$REQUISITO" ] || { echo "não li o requisito da assinatura"; exit 1; }
trocar() {  # substitui os {{CAMPOS}} sem quebrar com / ou & nos valores
  python3 - "$1" "$2" <<PY
import sys
ent, sai = sys.argv[1], sys.argv[2]
v = {"VERSAO": "$NOVA", "TAMANHO_DMG": "$TAM_DMG", "SITE": "$SITE", "REPO": "$REPO", "REQUISITO": "$REQUISITO",
     "AJUDA_PT": """$AJUDA_PT""" or "Peça ajuda a quem indicou o app.",
     "AJUDA_EN": """$AJUDA_EN""" or "Ask whoever recommended the app.",
     "AJUDA_ES": """$AJUDA_ES""" or "Pide ayuda a quien te recomendó la app."}
t = open(ent, encoding="utf-8").read()
for k, val in v.items():
    t = t.replace("{{" + k + "}}", val)
open(sai, "w", encoding="utf-8").write(t)
PY
}
trocar site/index.html "$PUB/index.html"
trocar site/instalar.sh "$PUB/instalar.sh"
cp site/404.html site/_headers "$PUB/"
uv run -q --no-project --with markdown python -I ferramentas/termos-html.py TERMOS.md "$REPO" "$PUB/termos.html"
sips -z 256 256 "$SAIDA/icone-1024.png" --out "$PUB/icone.png" >/dev/null
if grep -l "{{" "$PUB"/*.html "$PUB"/instalar.sh; then echo "sobrou {{campo}} sem valor"; exit 1; fi

# Worker só com arquivos estáticos, no domínio do SITE
cat > "$SAIDA/wrangler.toml" <<TOML
name = "$WORKER"
compatibility_date = "2026-10-01"
workers_dev = false
preview_urls = false
routes = [{ pattern = "$DOMINIO", custom_domain = true }]

[assets]
directory = "./publico"
not_found_handling = "404-page"
html_handling = "auto-trailing-slash"
TOML
for f in "$PUB"/*; do
  t=$(stat -f %z "$f"); [ "$t" -lt 26000000 ] || { echo "arquivo grande demais para o Worker: $f ($t)"; exit 1; }
done
echo "== publicando"
(cd "$SAIDA" && env -u CLOUDFLARE_API_TOKEN -u CF_API_TOKEN CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_CONTA" \
   WRANGLER_SEND_METRICS=false WRANGLER_SEND_ERROR_REPORTS=false \
   "$WRANGLER" deploy --config wrangler.toml 2>&1 | grep -vE "^\s*$" | tail -6)

echo "== conferindo"
# Se o DNS do provedor ainda guarda um "não existe" antigo, pergunta direto à Cloudflare.
RESOLVE=()
if ! host -W 3 "$DOMINIO" >/dev/null 2>&1; then
  IP=$(dig +short "$DOMINIO" @1.1.1.1 | head -1)
  [ -n "$IP" ] && RESOLVE=(--resolve "$DOMINIO:443:$IP")
fi
V=""
for _ in $(seq 1 20); do
  V=$(curl -fsS ${RESOLVE[@]+"${RESOLVE[@]}"} "$SITE/versao.json?t=$(date +%s)" 2>/dev/null | plutil -extract build raw -o - - 2>/dev/null || true)
  [ "$V" = "$BUILD" ] && break; sleep 3
done
[ "$V" = "$BUILD" ] || { echo "versao.json ainda não mostra a compilação $BUILD"; exit 1; }
for caminho in "/" "/termos" "/$ZIP" "/ControleDaTV.dmg" "/instalar.sh" "/icone.png"; do
  echo "$(curl -s ${RESOLVE[@]+"${RESOLVE[@]}"} -o /dev/null -w '%{http_code}' "$SITE$caminho") $caminho"
done
echo "$(curl -s ${RESOLVE[@]+"${RESOLVE[@]}"} -o /dev/null -w '%{http_code}' "$SITE/nao-existe") /nao-existe (tem que ser 404)"
echo "ok: $NOVA publicada em $SITE"
