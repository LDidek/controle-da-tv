// Atualização automática: confere <site>/versao.json ao abrir e a cada 6 h.
// Só instala o que passar em três conferências: assinatura Ed25519 do manifesto (a chave privada fica só
// no Mac de quem publica), sha256 do zip e assinatura de código igual à do app que está rodando.
import AppKit
import CryptoKit
import Foundation
import Security

struct Manifesto: Codable, Equatable {
    let versao: String
    let build: Int
    let url: String
    let sha256: String
    let tamanho: Int
    var notas: String?
    let assinatura: String

    /// Exatamente o texto que o publicar.sh assina.
    var textoAssinado: String { "controle-tv\n\(build)\n\(versao)\n\(sha256)\n\(tamanho)\n\(url)" }
}

enum ErroAtualizacao: Error, CustomStringConvertible {
    case manifesto(String)
    case download(String)
    case conferencia(String)
    case troca(String)

    var description: String {
        switch self {
        case .manifesto(let t): return "manifesto: \(t)"
        case .download(let t): return "download: \(t)"
        case .conferencia(let t): return "conferência: \(t)"
        case .troca(let t): return "troca: \(t)"
        }
    }
}

@MainActor
final class Atualizador: ObservableObject {
    enum Situacao: Equatable {
        case nada
        case emDia             // só depois de uma verificação manual: "já é a mais nova"
        case baixando(String)  // versão
        case pronta(String)
        case instalando
        case erro(String)
    }

    @Published var situacao: Situacao = .nada
    var podeInstalarSozinho: () -> Bool = { false }

    /// Sem site ou sem chave no Info.plist (ex.: quem compila para si), o app não procura atualização.
    static var manifestoURL: URL? { Ajustes.site.flatMap { URL(string: $0 + "/versao.json") } }
    private static let intervalo: Double = 6 * 3600

    private var novoApp: URL?
    private var pastaTemporaria: URL?
    private var manifestoPronto: Manifesto?
    private var laco: Task<Void, Never>?
    private var verificando = false

    func iniciar() {
        guard Atualizador.manifestoURL != nil, Ajustes.chavePublica != nil else {
            registrar("atualização automática desligada (sem site ou chave no Info.plist)")
            return
        }
        laco?.cancel()
        laco = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.verificar()
                // Com uma versão pronta, tenta instalar a cada minuto (quando ninguém está usando o painel).
                var espera = Atualizador.intervalo
                while espera > 0, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    espera -= 60
                    self?.tentarInstalarSozinho()
                }
            }
        }
    }

    func verificar(manual: Bool = false) async {
        guard !verificando, situacao != .instalando else { return }
        if case .baixando = situacao { return }
        verificando = true
        defer { verificando = false }
        do {
            let m = try await buscarManifesto()
            guard m.build > Versao.build else {
                if manual || situacao == .emDia { situacao = .emDia }
                registrar("atualização: em dia (servidor \(m.versao) build \(m.build), aqui \(Versao.texto) build \(Versao.build))")
                return
            }
            if manifestoPronto == m, novoApp != nil { tentarInstalarSozinho(); return }
            registrar("atualização: versão \(m.versao) (build \(m.build)) disponível; baixando")
            situacao = .baixando(m.versao)
            try await baixarEConferir(m)
            situacao = .pronta(m.versao)
            registrar("atualização: \(m.versao) baixada e conferida")
            tentarInstalarSozinho()
        } catch {
            registrar("atualização falhou: \(error)")
            situacao = manual ? .erro(T("Não consegui verificar agora.")) : .nada
        }
    }

    private func buscarManifesto() async throws -> Manifesto {
        guard let endereco = Atualizador.manifestoURL, let site = Ajustes.site else { throw ErroAtualizacao.manifesto("sem site") }
        var req = URLRequest(url: endereco, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        req.timeoutInterval = 20
        let (dados, resposta) = try await URLSession.shared.data(for: req)
        guard (resposta as? HTTPURLResponse)?.statusCode == 200 else { throw ErroAtualizacao.manifesto("status") }
        let m = try JSONDecoder().decode(Manifesto.self, from: dados)
        guard let chave = Data(base64Encoded: Ajustes.chavePublica ?? ""),
              let publica = try? Curve25519.Signing.PublicKey(rawRepresentation: chave),
              let assinatura = Data(base64Encoded: m.assinatura),
              publica.isValidSignature(assinatura, for: Data(m.textoAssinado.utf8))
        else { throw ErroAtualizacao.manifesto("assinatura não confere") }
        guard m.url.hasPrefix(site + "/") else { throw ErroAtualizacao.manifesto("endereço estranho") }
        return m
    }

    private func baixarEConferir(_ m: Manifesto) async throws {
        guard let url = URL(string: m.url) else { throw ErroAtualizacao.download("url") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        req.timeoutInterval = 120
        let (arquivo, resposta) = try await URLSession.shared.download(for: req)
        defer { try? FileManager.default.removeItem(at: arquivo) }
        guard (resposta as? HTTPURLResponse)?.statusCode == 200 else { throw ErroAtualizacao.download("status") }
        let atual = Bundle.main.bundleURL
        let fm = FileManager.default
        // Pasta temporária no mesmo disco do app: a troca vira um simples "renomear".
        let pasta = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: atual, create: true)
        let ok: Bool = try await Task.detached {
            let tamanho = (try fm.attributesOfItem(atPath: arquivo.path)[.size] as? Int) ?? -1
            guard tamanho == m.tamanho else { throw ErroAtualizacao.conferencia("tamanho \(tamanho) ≠ \(m.tamanho)") }
            guard try Atualizador.sha256(de: arquivo) == m.sha256.lowercased() else { throw ErroAtualizacao.conferencia("sha256") }
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", arquivo.path, pasta.path]
            try ditto.run()
            ditto.waitUntilExit()
            return ditto.terminationStatus == 0
        }.value
        guard ok else { throw ErroAtualizacao.conferencia("não abriu o zip") }
        let novo = pasta.appendingPathComponent("Controle da TV.app")
        try Atualizador.conferirCodigo(novo, build: m.build)
        if let anterior = pastaTemporaria, anterior != pasta { try? fm.removeItem(at: anterior) }
        pastaTemporaria = pasta
        novoApp = novo
        manifestoPronto = m
    }

    nonisolated static func sha256(de arquivo: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: arquivo)
        defer { try? h.close() }
        var hash = SHA256()
        while let pedaco = try h.read(upToCount: 1 << 20), !pedaco.isEmpty { hash.update(data: pedaco) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// O app novo tem de ser assinado pelo mesmo certificado e ter o mesmo identificador do que está rodando.
    nonisolated static func conferirCodigo(_ app: URL, build: Int) throws {
        var eu: SecCode?
        var euEstatico: SecStaticCode?
        var requisito: SecRequirement?
        var novo: SecStaticCode?
        guard SecCodeCopySelf([], &eu) == errSecSuccess, let eu,
              SecCodeCopyStaticCode(eu, [], &euEstatico) == errSecSuccess, let euEstatico,
              SecCodeCopyDesignatedRequirement(euEstatico, [], &requisito) == errSecSuccess, let requisito,
              SecStaticCodeCreateWithPath(app as CFURL, [], &novo) == errSecSuccess, let novo
        else { throw ErroAtualizacao.conferencia("não li as assinaturas") }
        let opcoes = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let r = SecStaticCodeCheckValidity(novo, opcoes, requisito)
        guard r == errSecSuccess else { throw ErroAtualizacao.conferencia("assinatura de código (\(r))") }
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == idDoApp,
              Int(info["CFBundleVersion"] as? String ?? "") == build
        else { throw ErroAtualizacao.conferencia("Info.plist não bate com o manifesto") }
    }

    func tentarInstalarSozinho() {
        guard case .pronta = situacao, podeInstalarSozinho() else { return }
        registrar("atualização: instalando sozinho (ninguém usando o painel)")
        instalarAgora()
    }

    /// Troca o .app no lugar (dois "renomear") e abre a versão nova assim que esta fechar.
    func instalarAgora() {
        guard let novo = novoApp, let pasta = pastaTemporaria, case .pronta = situacao else { return }
        situacao = .instalando
        let atual = Bundle.main.bundleURL
        let reserva = pasta.appendingPathComponent("anterior.app")
        let fm = FileManager.default
        do {
            try fm.moveItem(at: atual, to: reserva)
            do {
                try fm.moveItem(at: novo, to: atual)
            } catch {
                try? fm.moveItem(at: reserva, to: atual)  // devolve o antigo
                throw ErroAtualizacao.troca("\(error)")
            }
        } catch {
            registrar("atualização: troca falhou: \(error)")
            situacao = .erro(T("Não consegui instalar a atualização."))
            return
        }
        registrar("atualização: trocado; reabrindo \(atual.path)")
        let pid = ProcessInfo.processInfo.processIdentifier
        let roteiro = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /usr/bin/open "\(atual.path)"
        /bin/sleep 5
        /bin/rm -rf "\(pasta.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", roteiro]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { registrar("atualização: não consegui agendar a reabertura: \(error)") }
        NSApp.terminate(nil)
    }
}
