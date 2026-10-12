# Lê o publicar.conf (fora do git, com o que é de cada pessoa) e completa com os padrões.
# Usado pelo build.sh, pelo publicar.sh e pelo criar-certificado.sh. Modelo: publicar.conf.exemplo.
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${CONTROLE_TV_CONF:-$RAIZ/publicar.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"
BUNDLE_ID="${BUNDLE_ID:-io.github.controle-da-tv}"
SEGREDOS="${SEGREDOS:-$HOME/.config/controle-da-tv/segredos}"
NOME_CERTIFICADO="${NOME_CERTIFICADO:-Controle da TV}"
SITE="${SITE:-}"
AJUDA_PT="${AJUDA_PT:-}"
AJUDA_EN="${AJUDA_EN:-}"
AJUDA_ES="${AJUDA_ES:-}"
AUTOR="${AUTOR:-}"
REPO="${REPO:-https://github.com/LDidek/controle-da-tv}"
CLOUDFLARE_CONTA="${CLOUDFLARE_CONTA:-}"
WORKER="${WORKER:-controle-da-tv}"
SAIDA="$RAIZ/build"
KC="$SEGREDOS/assinatura.keychain-db"
DOMINIO="${SITE#https://}"

# Com o Xcode instalado mas sem aceitar a licença, swiftc e git do sistema param de funcionar:
# nesse caso usa as Command Line Tools, que não pedem licença.
if ! swiftc --version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
