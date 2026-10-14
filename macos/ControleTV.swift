// Ícone da TV na barra de menus. Fica rodando em segundo plano; só aparece (e só liga o
// servidor do controle remoto) quando o Mac está na rede de casa — ou enquanto falta configurar.
import AppKit
import Network
import ServiceManagement
import SwiftUI

let liveTV = "com.webos.app.livetv"
// LG e Samsung (IDs da loja de cada uma): Netflix, YouTube, Globoplay, Prime Video, Disney+, HBO Max
let primeiros = ["netflix", "youtube.leanback.v4", "globoplaywebos", "amazon", "com.disney.disneyplus-prod", "com.wbd.stream",
                 "3201907018807", "111299001912", "3201908019022", "3201910019365", "3201901017640", "3202301029760"]

struct AppTV: Decodable, Identifiable, Equatable {
    let id: String
    let titulo: String
    let sistema: Bool
    var cor: String?
    var nomeCurto: String { titulo.components(separatedBy: " : ")[0] }
}
struct EntradaTV: Decodable, Identifiable, Equatable { let id: String; let nome: String; let conectado: Bool; var app: String? }
/// Videogame ligado na TV (o servidor acha o PlayStation na rede e descobre em que entrada ele está).
struct ConsoleTV: Decodable, Equatable {
    let entrada: String
    var nome: String?
    var tipo: String?
    var ligado: Bool?
    var simbolo: String { tipo == "XBOX" ? "xbox.logo" : "playstation.logo" }
}
struct EstadoTV: Decodable, Equatable {
    let online: Bool
    var pareado: Bool?
    var ligada: Bool?
    var app_atual: String?
    var app_titulo: String?
    var volume: Int?
    var mudo: Bool?
    var entradas: [EntradaTV]?
    var apps: [AppTV]?
    var ligando: Bool?
    var marca: String?    // "lg" ou "samsung" (servidor antigo não manda: LG)
    var nome: String?
    var ao_vivo: Bool?    // a TV aceita "TV ao vivo" pela rede (na Samsung, só com o Controle Remoto IP)
    var console: ConsoleTV?

    var ehSamsung: Bool { marca == "samsung" }
}

@MainActor
final class Controle: ObservableObject {
    @Published var emCasa = false
    @Published var iconeVisivel = false
    @Published var configCompleta = false
    @Published var estado: EstadoTV?
    @Published var enviando = 0  // ações a caminho da TV (o rodapé mostra "Enviando…")
    @Published var pendencias: [Passo] = []  // o que falta liberar: o painel mostra "Corrigir"
    @Published var preparandoMotor = false   // componentes sendo atualizados depois de uma atualização
    var congelado = false  // só no teste de imagem: não busca o estado real
    var painelAberto = false
    var ultimaInteracao = Date.distantPast
    let atualizador = Atualizador()
    lazy var assistente = Assistente(c: self)

    private var servidor: Process?
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var tiques = 0
    private var ultimoMac: String?? = .none
    private var macAvisado: String?
    private var avisouPorta = false
    private var iniciando = false
    private var falhas = 0
    private(set) var redeLocal: SituacaoRede = .verificando
    private var ultimaChecagemTV = Date.distantPast

    init() {
        #if TESTE_RENDER
        return  // no teste de imagem, nada de rede nem servidor
        #endif
        girarLog("app.log")
        registrar("app iniciado: versão \(Versao.texto) (\(Versao.build)) em \(Bundle.main.bundlePath)")
        criarPastaDeDados()
        configCompleta = Controle.lerConfigCompleta()
        iconeVisivel = !configCompleta
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.checarRede() }
        }
        monitor.start(queue: DispatchQueue(label: "rede"))
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tique() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pararServidor() }
        }
        if UserDefaults.standard.bool(forKey: "modoTeste") { ouvirComandosDeTeste() }
        atualizador.podeInstalarSozinho = { [weak self] in
            guard let self else { return false }
            return !self.painelAberto && !self.assistente.aberto && Date().timeIntervalSince(self.ultimaInteracao) > 120
        }
        Task { await iniciar() }
        Controle.atual = self
    }

    static weak var atual: Controle?

    /// Alguma TV pareada (em qualquer casa).
    static func lerConfigCompleta() -> Bool { ConfigCasa.ler().tvs.contains { $0.roteador != nil && $0.pareada } }

    /// A TV desta rede já está pareada?
    static func tvDaRedePareada() -> Bool { ConfigCasa.ler().tv(doRoteador: macDoRoteador())?.pareada == true }

    /// Abriram o app de novo (Finder, Dock, Spotlight). Numa rede sem TV, é o jeito de conectar outra TV.
    func reaberto() {
        if assistente.aberto { assistente.abrir(); return }
        if configCompleta && !emCasa {
            assistente.abrir(em: .tv, novaTV: true)
        } else if !configCompleta || !pendencias.isEmpty {
            assistente.abrir()
        }
    }

    private func iniciar() async {
        try? await Task.sleep(for: .milliseconds(600))  // deixa o app terminar de abrir
        await reavaliar()
        let marcos = Marcos.ler()
        if !pendencias.isEmpty || !marcos.concluido {
            // Já configurado e só faltam os componentes novos de uma atualização: prepara sem incomodar.
            if pendencias == [.motor] && configCompleta && marcos.concluido && Motor.existe() {
                await prepararMotorEmSilencio()
            } else {
                assistente.abrir()
            }
        }
        checarRede()
        atualizador.iniciar()
    }

    /// Confere o que falta liberar. A Rede Local só dá para saber tentando (rápido).
    func reavaliar() async {
        let completa = Controle.lerConfigCompleta()
        if completa != configCompleta { configCompleta = completa }  // gravar igual também redesenha a barra
        // Na primeira configuração, o pedido de Rede Local só deve aparecer quando o assistente chegar nele.
        let podeChecar = Marcos.ler().concluido || assistente.passo.rawValue >= Passo.redeLocal.rawValue
        var rede: SituacaoRede = podeChecar ? await checarRedeLocal() : .verificando
        // Logo depois de abrir (e depois de cada atualização) o macOS às vezes nega por alguns segundos
        // antes de reconhecer a permissão: só dá como negada se continuar assim por ~30 s.
        var tentativa = 0
        while rede == .negada && tentativa < 6 {
            tentativa += 1
            try? await Task.sleep(for: .seconds(5))
            rede = await checarRedeLocal()
        }
        if tentativa > 0 { registrar("rede local: \(rede) depois de \(tentativa) nova(s) tentativa(s)") }
        redeLocal = rede
        var lista: [Passo] = []
        if !Assistente.noLugarCerto() { lista.append(.mover) }
        if !Motor.pronto() { lista.append(.motor) }
        if redeLocal == .negada { lista.append(.redeLocal) }
        if !configCompleta { lista.append(.parear) }
        if SMAppService.mainApp.status != .enabled { lista.append(.inicio) }
        if lista != pendencias {
            registrar("pendências: \(lista.map { "\($0)" }.joined(separator: ", "))")
            pendencias = lista
        }
    }

    private func prepararMotorEmSilencio() async {
        preparandoMotor = true
        defer { preparandoMotor = false }
        do {
            try await Motor.preparar { _ in }
            await reavaliar()
            checarRede()
        } catch {
            registrar("motor (atualização) falhou: \(error)")
            assistente.abrir(em: .motor)
        }
    }

    private func tique() {
        tiques += 1
        if tiques % 2 == 0 { checarRede() }  // rede a cada 10 s; estado da TV a cada 5 s
        if tiques % 12 == 0 { Task { await reavaliar() } }  // permissões a cada minuto
        if emCasa && configCompleta { Task { await atualizar() } }
    }

    func checarRede() {
        Task {
            let mac = await Task.detached { macDoRoteador() }.value
            let config = ConfigCasa.ler()
            var casa = config.tv(doRoteador: mac) != nil
            if mac != ultimoMac { registrar("roteador lido: \(mac ?? "nenhum")"); ultimoMac = mac }
            // Roteador trocado (ex.: a operadora mudou o aparelho): se uma TV responde no mesmo IP, é a mesma casa.
            if !casa, configCompleta, let mac, Date().timeIntervalSince(ultimaChecagemTV) > 60 {
                ultimaChecagemTV = Date()
                for tv in config.tvs where tv.tv_ip != nil {
                    if await tvResponde(tv) {
                        registrar("roteador novo (\(mac)), mas a TV responde em \(tv.tv_ip ?? ""): é a mesma casa")
                        Controle.gravarRoteador(mac, tv: tv)
                        casa = true
                        break
                    }
                }
            }
            if casa != emCasa {
                registrar("rede: roteador \(mac ?? "nenhum") → \(casa ? "em casa" : "fora de casa")")
                emCasa = casa
            }
            let visivel = casa || !configCompleta
            if visivel != iconeVisivel { iconeVisivel = visivel }
            if Motor.pronto() && (casa || !configCompleta || assistente.aberto) {
                await iniciarServidor()
                if let mac, mac != macAvisado { await avisarCasa(mac) }
                if casa && configCompleta { await atualizar() }
            } else {
                pararServidor()
                if estado != nil { estado = nil }
            }
        }
    }

    /// O servidor atende a TV da casa onde o Mac está: avisa quando a rede muda.
    private func avisarCasa(_ mac: String) async {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/api/casa")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["roteador": mac])
        req.timeoutInterval = 3
        if let (_, resposta) = try? await URLSession.shared.data(for: req), (resposta as? HTTPURLResponse)?.statusCode == 200 {
            macAvisado = mac
        }
    }

    /// Só quando o servidor está parado (fora de casa): troca o roteador gravado no config.json.
    static func gravarRoteador(_ mac: String, tv: TVSalva) {
        guard let dados = try? Data(contentsOf: Caminhos.config),
              var json = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] else { return }
        if var tvs = json["tvs"] as? [[String: Any]] {
            guard let i = tvs.firstIndex(where: { ($0["roteador"] as? String) == tv.roteador && ($0["tv_ip"] as? String) == tv.tv_ip })
            else { return }
            tvs[i]["roteador"] = mac
            json["tvs"] = tvs
        } else {
            json["roteador"] = mac
        }
        if let novo = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? novo.write(to: Caminhos.config, options: .atomic)
            chmod(Caminhos.config.path, 0o600)
        }
    }

    /// Para o assistente: garante o servidor no ar (procurar e parear a TV passam por ele).
    func garantirServidor() async {
        guard Motor.pronto() else { return }
        await iniciarServidor()
    }

    private func iniciarServidor() async {
        // Trava antes do primeiro await: duas checagens de rede simultâneas abriam dois servidores.
        if iniciando { return }
        if let s = servidor, s.isRunning { return }
        iniciando = true
        defer { iniciando = false }
        // Se já tem um servidor no ar (ex.: aberto pelo Claude ou pela versão anterior), usa ele.
        if await Task.detached(operation: { portaOcupada() }).value {
            if !avisouPorta { registrar("porta \(porta) já está em uso: usando o servidor que já existe"); avisouPorta = true }
            return
        }
        avisouPorta = false
        macAvisado = nil
        girarLog("servidor.log")
        let p = Process()
        p.executableURL = Motor.python
        p.arguments = ["-u", Motor.servidor.path]
        p.currentDirectoryURL = Caminhos.dados
        p.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "pt_BR.UTF-8",
            "CONTROLE_TV_DADOS": Caminhos.dados.path,
            "CONTROLE_TV_PORTA": String(porta),
            "CONTROLE_TV_ROTEADOR": (ultimoMac ?? nil) ?? "",
        ]
        let arquivoLog = Caminhos.logs.appendingPathComponent("servidor.log").path
        try? FileManager.default.createDirectory(at: Caminhos.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: arquivoLog) {
            FileManager.default.createFile(atPath: arquivoLog, contents: nil)
        }
        if let log = FileHandle(forWritingAtPath: arquivoLog) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        do { try p.run(); servidor = p; registrar("servidor iniciado (pid \(p.processIdentifier))") }
        catch { servidor = nil; registrar("servidor falhou ao iniciar: \(error)") }
    }

    func pararServidor() {
        if let s = servidor, s.isRunning { s.terminate(); registrar("servidor parado") }
        servidor = nil
    }

    func atualizar() async {
        if congelado { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/api/estado")!)
        req.timeoutInterval = 4
        if let (dados, _) = try? await URLSession.shared.data(for: req),
           let e = try? JSONDecoder().decode(EstadoTV.self, from: dados) {
            falhas = 0
            if estado != e { estado = e }  // só redesenha quando algo mudou
        } else {
            falhas += 1
            if falhas >= 2 && estado != nil { estado = nil }  // servidor subindo ou fora do ar; uma falha isolada não pisca o painel
        }
    }

    func acao(_ nome: String, _ valor: String? = nil, numero: Int? = nil) {
        ultimaInteracao = Date()
        var corpo: [String: Any] = ["acao": nome]
        if let valor { corpo["valor"] = valor }
        if let numero { corpo["valor"] = numero }
        let dados = try? JSONSerialization.data(withJSONObject: corpo)
        enviando += 1
        Task {
            defer { enviando -= 1 }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/api/acao")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = dados
            req.timeoutInterval = 8
            _ = try? await URLSession.shared.data(for: req)
            try? await Task.sleep(for: .milliseconds(600))
            await atualizar()
        }
    }

    var appsOrdenados: [AppTV] {
        let ordem = { (id: String) in primeiros.firstIndex(of: id) ?? primeiros.count }
        return (estado?.apps ?? [])
            .filter { !$0.sistema && $0.id != liveTV }
            .sorted { (ordem($0.id), $0.titulo.lowercased()) < (ordem($1.id), $1.titulo.lowercased()) }
    }

    var linkCelular: String {
        let ip = executar("/usr/sbin/ipconfig", ["getifaddr", "en0"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "http://\(ip.isEmpty ? "localhost" : ip):\(porta)"
    }

    // MARK: teste automático (só com `defaults write <id do app> modoTeste -bool true`)

    private func ouvirComandosDeTeste() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(idDoApp + ".teste"), object: nil, queue: .main
        ) { [weak self] nota in
            let comando = nota.object as? String ?? ""
            MainActor.assumeIsolated { self?.comandoDeTeste(comando) }
        }
        registrar("modo de teste ligado")
    }

    private func comandoDeTeste(_ comando: String) {
        registrar("teste: \(comando)")
        let partes = comando.split(separator: ":", maxSplits: 1).map(String.init)
        switch partes.first ?? "" {
        case "assistente": assistente.abrir(em: partes.count > 1 ? Passo.porNome(partes[1]) : nil)
        case "passo": if partes.count > 1, let p = Passo.porNome(partes[1]) { assistente.irPara(p) }
        case "principal": assistente.acaoPrincipal()
        case "fechar": assistente.fechar()
        case "verificar": Task { await atualizador.verificar(manual: true) }
        case "instalar": atualizador.instalarAgora()
        default: break
        }
    }
}
