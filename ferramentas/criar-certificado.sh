#!/bin/bash
# Cria (uma vez só) o certificado autoassinado que assina o Controle da TV, num keychain próprio.
# Assinatura estável = o Mac reconhece cada atualização como o mesmo app e mantém as permissões
# (Rede Local, abrir ao iniciar). A senha do keychain fica só neste Mac, em segredos/ (600).
# Pasta e nome vêm do publicar.conf (SEGREDOS, NOME_CERTIFICADO); a pasta nunca deve ficar dentro do repo.
set -euo pipefail
source "$(dirname "$0")/config.sh"
SEG="$SEGREDOS"
NOME="$NOME_CERTIFICADO"
umask 077
mkdir -p "$SEG"; chmod 700 "$SEG"
if [ -f "$KC" ]; then echo "já existe: $KC"; exit 0; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SENHA=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
SENHA_P12=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
printf '%s' "$SENHA" > "$SEG/senha-keychain"; chmod 600 "$SEG/senha-keychain"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NOME
O = Controle da TV
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
  -keyout "$TMP/chave.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/chave.pem" -in "$TMP/cert.pem" \
  -name "$NOME" -out "$TMP/id.p12" -passout "pass:$SENHA_P12" 2>/dev/null
cp "$TMP/cert.pem" "$SEG/certificado.pem"

security create-keychain -p "$SENHA" "$KC"
security set-keychain-settings "$KC"   # sem trava automática por tempo
security unlock-keychain -p "$SENHA" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$SENHA_P12" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SENHA" "$KC" >/dev/null
echo "certificado criado:"
/usr/bin/openssl x509 -in "$SEG/certificado.pem" -noout -subject -fingerprint -sha1
