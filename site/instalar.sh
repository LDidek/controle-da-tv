#!/bin/bash
# Instala (ou atualiza) o Controle da TV no Mac.  ·  Installs (or updates) Controle da TV.
#   curl -fsSL {{SITE}}/instalar.sh | bash
# Baixado pelo curl, o app não ganha a "quarentena" do navegador: abre direto, sem os avisos do Gatekeeper.
set -euo pipefail

principal() {
  local BASE="{{SITE}}"
  local REQUISITO='{{REQUISITO}}'
  echo ""
  echo "Instalando o Controle da TV…"
  if [ "$(uname -m)" != "arm64" ]; then echo "Este app é para Mac com chip Apple (M1 ou mais novo)."; exit 1; fi
  if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then echo "Precisa do macOS 14 (Sonoma) ou mais novo."; exit 1; fi

  TMP=$(mktemp -d)   # global: o trap de saída roda depois que a função termina
  trap 'rm -rf "${TMP:-}"' EXIT
  curl -fsSL "$BASE/versao.json" -o "$TMP/versao.json" </dev/null
  local URL SHA VERSAO
  URL=$(plutil -extract url raw -o - "$TMP/versao.json")
  SHA=$(plutil -extract sha256 raw -o - "$TMP/versao.json")
  VERSAO=$(plutil -extract versao raw -o - "$TMP/versao.json")
  case "$URL" in "$BASE"/*) ;; *) echo "Endereço inesperado no manifesto."; exit 1;; esac

  echo "Baixando a versão $VERSAO…"
  curl -fL --progress-bar "$URL" -o "$TMP/app.zip" </dev/null
  if [ "$(shasum -a 256 "$TMP/app.zip" | cut -d' ' -f1)" != "$SHA" ]; then
    echo "O arquivo veio corrompido. Rode o comando de novo."; exit 1
  fi
  ditto -x -k "$TMP/app.zip" "$TMP/x" </dev/null
  local APP="$TMP/x/Controle da TV.app"
  if ! codesign --verify --strict "$APP" </dev/null 2>/dev/null || ! codesign -d -r- "$APP" 2>&1 </dev/null | grep -q "$REQUISITO"; then
    echo "A assinatura do app não confere. Nada foi instalado."; exit 1
  fi

  local DESTINO="/Applications"
  if [ ! -w "$DESTINO" ]; then DESTINO="$HOME/Applications"; mkdir -p "$DESTINO"; fi
  if pgrep -f "Controle da TV.app/Contents/MacOS/ControleTV" >/dev/null 2>&1; then
    osascript -e 'quit app "Controle da TV"' </dev/null >/dev/null 2>&1 || true
    sleep 2
  fi
  rm -rf "$DESTINO/Controle da TV.app"
  ditto "$APP" "$DESTINO/Controle da TV.app" </dev/null
  xattr -dr com.apple.quarantine "$DESTINO/Controle da TV.app" 2>/dev/null || true
  open "$DESTINO/Controle da TV.app" </dev/null
  echo ""
  echo "Pronto! O Controle da TV $VERSAO está em $DESTINO e já abriu."
  echo "Siga a janela de configuração, com calma."
}

principal "$@"
