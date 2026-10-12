// Chave Ed25519 das atualizações do Controle da TV.
//   assinar gerar <arquivo>       cria a chave privada (600) e mostra a pública
//   assinar publica <arquivo>     mostra a pública (base64), que vai embutida no app
//   assinar <arquivo> <texto>     assina o texto e mostra a assinatura (base64)
//   assinar manifesto <arquivo> <versao> <build> <url> <sha256> <tamanho> [notas]
//                                 escreve o versao.json já assinado (o app confere com a chave pública)
import CryptoKit
import Foundation

func sair(_ texto: String) -> Never { FileHandle.standardError.write(Data((texto + "\n").utf8)); exit(1) }
let a = CommandLine.arguments
guard a.count >= 3 else { sair("uso: assinar gerar|publica <arquivo>  |  assinar <arquivo> <texto>") }

func ler(_ caminho: String) -> Curve25519.Signing.PrivateKey {
    guard let texto = try? String(contentsOfFile: caminho, encoding: .utf8),
          let dados = Data(base64Encoded: texto.trimmingCharacters(in: .whitespacesAndNewlines)),
          let chave = try? Curve25519.Signing.PrivateKey(rawRepresentation: dados) else { sair("chave ilegível: \(caminho)") }
    return chave
}

switch a[1] {
case "gerar":
    if FileManager.default.fileExists(atPath: a[2]) { sair("já existe: \(a[2])") }
    let chave = Curve25519.Signing.PrivateKey()
    let ok = FileManager.default.createFile(atPath: a[2], contents: Data(chave.rawRepresentation.base64EncodedString().utf8),
                                            attributes: [.posixPermissions: 0o600])
    if !ok { sair("não consegui gravar \(a[2])") }
    print(chave.publicKey.rawRepresentation.base64EncodedString())
case "publica":
    print(ler(a[2]).publicKey.rawRepresentation.base64EncodedString())
case "manifesto":
    guard a.count >= 8, let build = Int(a[4]), let tamanho = Int(a[7]) else { sair("uso: assinar manifesto <chave> <versao> <build> <url> <sha256> <tamanho> [notas]") }
    let (versao, url, sha) = (a[3], a[5], a[6].lowercased())
    let texto = "controle-tv\n\(build)\n\(versao)\n\(sha)\n\(tamanho)\n\(url)"
    let assinatura = try! ler(a[2]).signature(for: Data(texto.utf8)).base64EncodedString()
    let agora = ISO8601DateFormatter().string(from: Date())
    let json: [String: Any] = ["versao": versao, "build": build, "url": url, "sha256": sha, "tamanho": tamanho,
                               "notas": a.count > 8 ? a[8] : "", "publicado_em": agora, "assinatura": assinatura]
    let dados = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: dados, as: UTF8.self))
default:
    let chave = ler(a[1])
    let assinatura = try! chave.signature(for: Data(a[2].utf8))
    print(assinatura.base64EncodedString())
}
