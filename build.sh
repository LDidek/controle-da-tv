#!/bin/bash
# Compila e assina o Controle da TV em build/Controle da TV.app (Apple Silicon, macOS 14+).
# Precisa só das Command Line Tools (swiftc) e do uv (brew install uv), que vai embutido no app.
# O que é de cada pessoa (site, chaves, frase de ajuda) vem do publicar.conf: veja publicar.conf.exemplo.
# Assinatura com certificado próprio e estável: o Mac reconhece cada atualização como o mesmo app e
# mantém as permissões (Rede Local, abrir ao iniciar).
set -euo pipefail
cd "$(dirname "$0")"
source ferramentas/config.sh
VERSAO=$(cat VERSAO)
BUILD=$(cat COMPILACAO)
APP="$SAIDA/Controle da TV.app"
UV_CMD=$(command -v uv || true)
[ -n "$UV_CMD" ] || { echo "Falta o uv (https://docs.astral.sh/uv/): brew install uv"; exit 1; }
UV=$(readlink -f "$UV_CMD")
EXTRA=${SWIFT_EXTRA:-}

python3 ferramentas/conferir-traducoes.py
[ -f "$KC" ] || ferramentas/criar-certificado.sh
ID=$(/usr/bin/openssl x509 -in "$SEGREDOS/certificado.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)

mkdir -p "$SAIDA"
# ícone (só desenha de novo se o desenho mudou)
if [ ! -x "$SAIDA/icone" ] || [ ferramentas/icone.swift -nt "$SAIDA/icone" ]; then
  swiftc -O ferramentas/icone.swift -o "$SAIDA/icone" 2>/dev/null
fi
if [ ! -f "$SAIDA/AppIcon.icns" ] || [ ferramentas/icone.swift -nt "$SAIDA/AppIcon.icns" ]; then
  rm -rf "$SAIDA/AppIcon.iconset" && mkdir "$SAIDA/AppIcon.iconset"
  "$SAIDA/icone" icone "$SAIDA/icone-1024.png"
  for t in 16 32 128 256 512; do
    sips -z $t $t "$SAIDA/icone-1024.png" --out "$SAIDA/AppIcon.iconset/icon_${t}x${t}.png" >/dev/null
    sips -z $((t*2)) $((t*2)) "$SAIDA/icone-1024.png" --out "$SAIDA/AppIcon.iconset/icon_${t}x${t}@2x.png" >/dev/null
  done
  iconutil -c icns "$SAIDA/AppIcon.iconset" -o "$SAIDA/AppIcon.icns"
fi
# chave pública das atualizações (só com site configurado e chave criada)
CHAVE_PUB=""
if [ -n "$SITE" ] && [ -f "$SEGREDOS/atualizacao-ed25519.key" ]; then
  [ -x "$SAIDA/assinar" ] && [ "$SAIDA/assinar" -nt ferramentas/assinar.swift ] || swiftc -O ferramentas/assinar.swift -o "$SAIDA/assinar" 2>/dev/null
  CHAVE_PUB=$("$SAIDA/assinar" publica "$SEGREDOS/atualizacao-ed25519.key")
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# shellcheck disable=SC2086
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 $EXTRA \
  macos/*.swift -o "$APP/Contents/MacOS/ControleTV" 2>&1 | grep -E "error" || true
[ -x "$APP/Contents/MacOS/ControleTV" ] || { echo "falhou a compilação"; exit 1; }

cp "$UV" "$APP/Contents/MacOS/uv"
chmod 755 "$APP/Contents/MacOS/uv"
cp servidor/servidor.py servidor/index.html requisitos.txt "$SAIDA/AppIcon.icns" "$APP/Contents/Resources/"

# textos que o próprio macOS mostra (pedido de Rede Local), nos três idiomas
escrever_strings() {
  mkdir -p "$APP/Contents/Resources/$1.lproj"
  printf '"NSLocalNetworkUsageDescription" = "%s";\n' "$2" > "$APP/Contents/Resources/$1.lproj/InfoPlist.strings"
}
escrever_strings pt "Para encontrar e controlar a TV LG na rede de casa."
escrever_strings en "To find and control the LG TV on your home network."
escrever_strings es "Para encontrar y controlar la TV LG en la red de casa."

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
COPY="Código aberto (licença MIT)"
[ -n "$AUTOR" ] && COPY="© $(date +%Y) $AUTOR · código aberto (licença MIT)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$(xml "$BUNDLE_ID")</string>
  <key>CFBundleName</key><string>Controle da TV</string>
  <key>CFBundleDisplayName</key><string>Controle da TV</string>
  <key>CFBundleExecutable</key><string>ControleTV</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSAO</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>pt</string><string>en</string><string>es</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>$(xml "$COPY")</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>Para encontrar e controlar a TV LG na rede de casa.</string>
  <key>ControleTVSite</key><string>$(xml "$SITE")</string>
  <key>ControleTVChavePublica</key><string>$CHAVE_PUB</string>
  <key>ControleTVAjuda</key><string>$(xml "$AJUDA_PT")</string>
  <key>ControleTVAjudaEN</key><string>$(xml "$AJUDA_EN")</string>
  <key>ControleTVAjudaES</key><string>$(xml "$AJUDA_ES")</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

security unlock-keychain -p "$(cat "$SEGREDOS/senha-keychain")" "$KC"
codesign --force --keychain "$KC" --sign "$ID" --identifier "$BUNDLE_ID.uv" --timestamp=none "$APP/Contents/MacOS/uv"
codesign --force --keychain "$KC" --sign "$ID" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict --deep "$APP"
if [ -z "$CHAVE_PUB" ]; then echo "aviso: sem SITE/chave no publicar.conf, este build não procura atualização"; fi
echo "ok: $APP ($VERSAO, build $BUILD)"
