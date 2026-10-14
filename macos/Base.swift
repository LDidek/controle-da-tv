// Peças comuns: onde ficam os dados, configuração da casa, registro (log) e leitura da rede.
import AppKit
import Foundation
import Network
import SystemConfiguration

let porta = 8765
let idDoApp = Bundle.main.bundleIdentifier ?? "controle-da-tv"

/// O que muda de uma instalação para outra vem do Info.plist, que o build.sh escreve a partir do
/// publicar.conf (fora do git): endereço do site de atualizações, chave pública e quem chamar se travar.
enum Ajustes {
    private static func texto(_ chave: String) -> String? {
        let v = (Bundle.main.infoDictionary?[chave] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }
    /// Ex.: https://tv.didek.com.br — sem ele (ou sem a chave pública) o app não procura atualização.
    static var site: String? { texto("ControleTVSite").map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } }
    static var chavePublica: String? { texto("ControleTVChavePublica") }
    /// Frase da lateral do assistente, uma por idioma (ex.: "É só chamar o Luiz." / "Just ask Luiz.").
    static var ajuda: String {
        let chave = ["pt": "ControleTVAjuda", "en": "ControleTVAjudaEN", "es": "ControleTVAjudaES"][Idioma.atual.rawValue]!
        return texto(chave) ?? T("Peça ajuda a quem instalou o app para você.")
    }
    /// Página dos termos de uso (no site de atualizações) ou, sem site, no repositório.
    static var termos: URL {
        let sufixo = Idioma.atual == .pt ? "" : "?lang=\(Idioma.atual.rawValue)"
        if let site { return URL(string: site + "/termos" + sufixo)! }
        return URL(string: "https://github.com/LDidek/controle-da-tv/blob/main/TERMOS.md")!
    }
}

enum Caminhos {
    static let casa = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    /// Tudo do app fica aqui: client-key, config.json, estado do assistente e o motor (Python).
    static let dados = casa.appendingPathComponent("Library/Application Support/Controle da TV", isDirectory: true)
    static let chave = dados.appendingPathComponent("client-key")
    static let config = dados.appendingPathComponent("config.json")
    static let marcos = dados.appendingPathComponent("assistente.json")
    static let motor = dados.appendingPathComponent("motor", isDirectory: true)
    static let pythons = dados.appendingPathComponent("python", isDirectory: true)
    static let cacheUV = casa.appendingPathComponent("Library/Caches/Controle da TV/uv", isDirectory: true)
    static let logs = casa.appendingPathComponent("Library/Logs/Controle da TV", isDirectory: true)
    static var recursos: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
    static var uv: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/uv") }
}

enum Versao {
    static var texto: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
}

/// Uma TV de uma casa (reconhecida pelo roteador). Uma casa pode ter várias: a escolhida fica em "escolhidas".
struct TVSalva: Codable, Equatable {
    var marca: String?
    var id: String?
    var tv_ip: String?
    var tv_macs: [String]?
    var tv_modelo: String?
    var nome: String?
    var roteador: String?
    var pareado_em: String?
    var chave: String?

    var ehSamsung: Bool { marca == "samsung" }
    var ehRoku: Bool { marca == "roku" }
    /// A LG pareada antes das várias casas guarda a chave no arquivo client-key. A Roku não pede pareamento.
    var pareada: Bool {
        if ehRoku { return true }
        if let chave, !chave.isEmpty { return true }
        return !ehSamsung && temChave()
    }
}

/// config.json: quem grava é o servidor (no pareamento); o app só lê (e troca o roteador, ver gravarRoteador).
/// Formato antigo: os campos de uma TV LG soltos no topo. Novo: {"tvs": [...]}, uma por casa.
struct ConfigCasa: Equatable {
    var tvs: [TVSalva] = []

    private struct Arquivo: Decodable {
        var tvs: [TVSalva]?
        var tv_ip: String?
        var tv_macs: [String]?
        var tv_modelo: String?
        var roteador: String?
        var pareado_em: String?
    }

    static func ler() -> ConfigCasa {
        guard let dados = try? Data(contentsOf: Caminhos.config),
              let a = try? JSONDecoder().decode(Arquivo.self, from: dados) else { return ConfigCasa() }
        if let tvs = a.tvs { return ConfigCasa(tvs: tvs) }
        guard a.tv_ip != nil || a.roteador != nil || a.tv_macs != nil else { return ConfigCasa() }
        return ConfigCasa(tvs: [TVSalva(marca: "lg", tv_ip: a.tv_ip, tv_macs: a.tv_macs, tv_modelo: a.tv_modelo,
                                        roteador: a.roteador, pareado_em: a.pareado_em)])
    }

    func tv(doRoteador mac: String?) -> TVSalva? {
        guard let mac else { return nil }
        return tvs.first { $0.roteador?.lowercased() == mac.lowercased() }
    }
}

/// O que o assistente já fez e não dá para conferir sozinho (ex.: as opções da TV).
struct Marcos: Codable, Equatable {
    var opcoesTV = false
    var concluido = false

    static func ler() -> Marcos {
        guard let dados = try? Data(contentsOf: Caminhos.marcos),
              let m = try? JSONDecoder().decode(Marcos.self, from: dados) else { return Marcos() }
        return m
    }

    func gravar() {
        try? FileManager.default.createDirectory(at: Caminhos.dados, withIntermediateDirectories: true)
        if let dados = try? JSONEncoder().encode(self) { try? dados.write(to: Caminhos.marcos, options: .atomic) }
    }
}

func temChave() -> Bool {
    guard let dados = FileManager.default.contents(atPath: Caminhos.chave.path) else { return false }
    return !String(decoding: dados, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private let filaDoLog = DispatchQueue(label: "log")
private let formatoDoLog: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func registrar(_ texto: String, arquivo: String = "app.log") {
    let linha = "\(formatoDoLog.string(from: Date())) \(texto)\n"
    filaDoLog.async {
        let fm = FileManager.default
        try? fm.createDirectory(at: Caminhos.logs, withIntermediateDirectories: true)
        let caminho = Caminhos.logs.appendingPathComponent(arquivo).path
        if let h = FileHandle(forWritingAtPath: caminho) {
            h.seekToEndOfFile(); h.write(Data(linha.utf8)); try? h.close()
        } else {
            fm.createFile(atPath: caminho, contents: Data(linha.utf8))
        }
    }
}

/// Log com mais de 2 MB vira .1 (guarda só o anterior).
func girarLog(_ arquivo: String) {
    let url = Caminhos.logs.appendingPathComponent(arquivo)
    guard let tamanho = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
          tamanho > 2_000_000 else { return }
    let velho = Caminhos.logs.appendingPathComponent(arquivo + ".1")
    try? FileManager.default.removeItem(at: velho)
    try? FileManager.default.moveItem(at: url, to: velho)
}

func criarPastaDeDados() {
    try? FileManager.default.createDirectory(at: Caminhos.dados, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    // Registros têm IP da TV e da rede de casa: só o dono do Mac lê.
    try? FileManager.default.createDirectory(at: Caminhos.logs, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Caminhos.logs.path)
}

func executar(_ caminho: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caminho)
    p.arguments = args
    let saida = Pipe()
    p.standardOutput = saida
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let dados = saida.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: dados, as: UTF8.self)
}

// MARK: rede

/// Dados da rede atual, lidos da configuração do sistema (sem permissão nenhuma).
/// SSID e tabela ARP o macOS esconde de apps sem permissão; o endereço físico do roteador não.
struct RedeAtual {
    var roteadorIP: String?
    var roteadorMAC: String?
}

func lerRedeAtual() -> RedeAtual {
    guard let store = SCDynamicStoreCreate(nil, "ControleTV" as CFString, nil, nil),
          let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let servico = global["PrimaryService"] as? String,
          let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(servico)/IPv4" as CFString) as? [String: Any]
    else { return RedeAtual() }
    var r = RedeAtual()
    r.roteadorIP = (ipv4["Router"] as? String) ?? (global["Router"] as? String)
    if let mac = ipv4["ARPResolvedHardwareAddress"] as? String {
        r.roteadorMAC = mac.lowercased()
    } else if let assinatura = ipv4["NetworkSignature"] as? String,
              let faixa = assinatura.range(of: "RouterHardwareAddress=") {
        r.roteadorMAC = String(assinatura[faixa.upperBound...].prefix(17)).lowercased()
    }
    return r
}

func macDoRoteador() -> String? { lerRedeAtual().roteadorMAC }

/// Tem alguém escutando em 127.0.0.1:porta? (responde na hora: aceita ou recusa)
func portaOcupada(_ numero: Int = porta) -> Bool {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return false }
    defer { close(s) }
    var endereco = sockaddr_in()
    endereco.sin_family = sa_family_t(AF_INET)
    endereco.sin_port = in_port_t(UInt16(numero).bigEndian)
    endereco.sin_addr.s_addr = inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &endereco) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return r == 0
}

enum SituacaoRede: Equatable {
    case verificando  // ainda não deu para saber (ou o roteador não respondeu)
    case liberada
    case negada
    case semRede
}

private final class Uma: @unchecked Sendable {
    var feita = false
}

/// Permissão de Rede Local de verdade: tenta uma conexão TCP com o roteador.
/// Conectou ou foi recusada = o Mac deixou sair (liberada). "Sem rota"/política = negada.
/// A primeira tentativa é o que faz o macOS mostrar o pedido "Permitir".
func checarRedeLocal() async -> SituacaoRede {
    guard let ip = lerRedeAtual().roteadorIP else { return .semRede }
    for p: UInt16 in [80, 443, 53] {  // se o roteador ignora uma porta, tenta outra
        let r = await tentarConexao(ip, p, espera: 2.5)
        if r != .verificando { return r }
    }
    return .verificando
}

private func tentarConexao(_ ip: String, _ numero: UInt16, espera: Double) async -> SituacaoRede {
    await withCheckedContinuation { (cont: CheckedContinuation<SituacaoRede, Never>) in
        let fila = DispatchQueue(label: "rede-local")
        let conexao = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: numero)!, using: .tcp)
        let uma = Uma()
        let fim: (SituacaoRede) -> Void = { r in
            if uma.feita { return }
            uma.feita = true
            conexao.cancel()
            cont.resume(returning: r)
        }
        conexao.stateUpdateHandler = { estado in
            switch estado {
            case .ready:
                fim(.liberada)
            case .waiting(let erro), .failed(let erro):
                if conexao.currentPath?.unsatisfiedReason == .localNetworkDenied { fim(.negada); return }
                if case .posix(let codigo) = erro {
                    switch codigo {
                    case .ECONNREFUSED, .ECONNRESET: fim(.liberada)
                    case .EHOSTUNREACH, .ENETUNREACH, .EPERM, .EACCES: fim(.negada)
                    default: break
                    }
                }
            default:
                break
            }
        }
        conexao.start(queue: fila)
        fila.asyncAfter(deadline: .now() + espera) {
            fim(conexao.currentPath?.unsatisfiedReason == .localNetworkDenied ? .negada : .verificando)
        }
    }
}

/// Esta TV responde no IP salvo? (usado para reconhecer a casa se o roteador for trocado)
/// A Samsung e a Roku dizem quem são (o id tem que bater); da LG basta a porta 3000 aberta.
func tvResponde(_ tv: TVSalva) async -> Bool {
    guard let ip = tv.tv_ip else { return false }
    if tv.ehRoku {
        var req = URLRequest(url: URL(string: "http://\(ip):8060/query/device-info")!)
        req.timeoutInterval = 2
        guard let (dados, _) = try? await URLSession.shared.data(for: req) else { return false }
        let texto = String(decoding: dados, as: UTF8.self)
        return texto.contains("<device-info>") && (tv.id == nil || texto.contains(">\(tv.id!)<"))
    }
    guard tv.ehSamsung else { return await tvRespondeEm(ip) }
    var req = URLRequest(url: URL(string: "http://\(ip):8001/api/v2/")!)
    req.timeoutInterval = 2
    guard let (dados, _) = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else { return false }
    let aparelho = json["device"] as? [String: Any]
    let ids = [json["id"] as? String, aparelho?["duid"] as? String]
    return tv.id == nil || ids.contains(tv.id)
}

func tvRespondeEm(_ ip: String, espera: Double = 1.2) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let fila = DispatchQueue(label: "tv-porta")
        let conexao = NWConnection(host: NWEndpoint.Host(ip), port: 3000, using: .tcp)
        let uma = Uma()
        let fim: (Bool) -> Void = { r in
            if uma.feita { return }
            uma.feita = true
            conexao.cancel()
            cont.resume(returning: r)
        }
        conexao.stateUpdateHandler = { estado in
            switch estado {
            case .ready: fim(true)
            case .failed: fim(false)
            default: break
            }
        }
        conexao.start(queue: fila)
        fila.asyncAfter(deadline: .now() + espera) { fim(false) }
    }
}
