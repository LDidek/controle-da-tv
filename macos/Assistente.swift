// Assistente de configuração: janela própria que ensina cada passo em linguagem simples.
// Abre sozinho na primeira vez e, enquanto faltar alguma permissão, toda vez que o app abrir.
import AppKit
import ServiceManagement
import SwiftUI

enum Passo: Int, CaseIterable, Identifiable {
    case mover, motor, redeLocal, tv, parear, inicio, opcoesTV, pronto
    var id: Int { rawValue }

    var curto: String {
        switch self {
        case .mover: return T("Pasta Aplicativos")
        case .motor: return T("Preparar")
        case .redeLocal: return T("Encontrar a TV")
        case .tv: return T("Ligar a TV")
        case .parear: return T("Conectar à TV")
        case .inicio: return T("Abrir sozinho")
        case .opcoesTV: return T("Opções da TV")
        case .pronto: return T("Pronto")
        }
    }

    static func porNome(_ nome: String) -> Passo? {
        if let n = Int(nome), let p = Passo(rawValue: n) { return p }
        return allCases.first { "\($0)" == nome }
    }
}

@MainActor
final class Assistente: NSObject, ObservableObject, NSWindowDelegate {
    @Published var passo: Passo = .mover
    @Published private(set) var aberto = false
    @Published var noLugar = Assistente.noLugarCerto()
    @Published var movendo = false
    @Published var moverErro: String?
    @Published var motorPronto = Motor.pronto()
    @Published var motorRodando = false
    @Published var motorEtapa = -1
    @Published var motorErro: String?
    @Published var rede: SituacaoRede = .verificando
    @Published var redeIndefinidaHaMuito = false  // o roteador não respondeu por 25 s: deixa seguir
    private var redeIndefinidaDesde: Date?
    @Published var tvIP: String?
    @Published var tvProcurando = false
    @Published var pareamento = "parado"
    @Published var pareamentoErro: String?
    @Published var inicio: SMAppService.Status = SMAppService.mainApp.status
    @Published var marcos = Marcos.ler()
    @Published var configCompleta = Controle.lerConfigCompleta()
    /// Conectando mais uma TV (de outra casa): os passos da TV valem para a rede atual, não para "alguma TV".
    @Published private(set) var novaTV = false
    @Published var tvDaRede = Controle.tvDaRedePareada()
    /// Mais uma TV na mesma casa (quarto, sala…): só conta como feito quando entra uma TV que ainda não estava.
    @Published private(set) var mesmaCasa = false
    private var tvsAntes: Set<String> = []
    @Published var tvNovaNaCasa = false
    @Published var marcaAchada: String?
    private var opcoesNovaTV = false

    unowned let c: Controle
    private var janela: NSWindow?
    private var vigia: Task<Void, Never>?
    private var feitoAoChegar = false
    /// Quando a tela atual apareceu. Clique duplo (comum em quem tem pouca prática) não pode pular dois passos.
    private var chegouEm = Date.distantPast

    init(c: Controle) {
        self.c = c
        super.init()
    }

    // MARK: situação de cada passo

    func feito(_ p: Passo) -> Bool {
        switch p {
        case .mover: return noLugar
        case .motor: return motorPronto
        case .redeLocal: return rede == .liberada
        case .tv: return (mesmaCasa ? tvNovaNaCasa : novaTV ? tvDaRede : configCompleta) || tvIP != nil
        case .parear: return mesmaCasa ? tvNovaNaCasa : novaTV ? tvDaRede : configCompleta
        case .inicio: return inicio == .enabled
        case .opcoesTV: return novaTV ? opcoesNovaTV : marcos.opcoesTV
        case .pronto: return novaTV ? false : marcos.concluido
        }
    }

    private func primeiroPendente() -> Passo {
        Passo.allCases.first { $0 != .pronto && !feito($0) } ?? .pronto
    }

    private func proximo(depois p: Passo) -> Passo {
        Passo.allCases.first { $0.rawValue > p.rawValue && $0 != .pronto && !feito($0) } ?? .pronto
    }

    static func noLugarCerto() -> Bool {
        let caminho = Bundle.main.bundlePath
        if caminho.contains("/AppTranslocation/") { return false }
        return caminho.hasPrefix("/Applications/") || caminho.hasPrefix(Caminhos.casa.path + "/Applications/")
    }

    // MARK: janela

    /// LG, Samsung ou Roku: a que o assistente achou, a da rede atual ou a que o painel mostra.
    private var marca: String? {
        marcaAchada ?? (mesmaCasa ? nil : ConfigCasa.ler().tv(doRoteador: macDoRoteador())?.marca) ?? c.estado?.marca
    }
    var ehSamsung: Bool { marca == "samsung" }
    var ehRoku: Bool { marca == "roku" }

    /// As TVs salvas na casa onde o Mac está, por quem são.
    private static func tvsDaCasa() -> Set<String> {
        let mac = macDoRoteador()?.lowercased()
        return Set(ConfigCasa.ler().tvs.filter { $0.roteador?.lowercased() == mac }
            .map { $0.id ?? $0.tv_macs?.first ?? $0.tv_ip ?? "" })
    }

    func abrir(em alvo: Passo? = nil, novaTV nova: Bool = false, mesmaCasa outraNaCasa: Bool = false) {
        if outraNaCasa && !mesmaCasa {
            mesmaCasa = true
            tvsAntes = Assistente.tvsDaCasa()
            tvNovaNaCasa = false
        }
        if nova && !novaTV {
            novaTV = true
            opcoesNovaTV = false
            tvIP = nil
            marcaAchada = nil
            pareamento = "parado"
            registrar("assistente: conectar outra TV")
        }
        recarregar()
        // Reabre no primeiro item que realmente falta (a lista do Controle já sabe da Rede Local).
        let falta = c.pendencias.min { $0.rawValue < $1.rawValue }
        if !aberto || alvo != nil { irPara(alvo ?? falta ?? primeiroPendente()) }
        if janela == nil {
            let j = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            j.title = T("Configurar o Controle da TV")
            j.titlebarAppearsTransparent = true
            j.titleVisibility = .hidden
            j.isMovableByWindowBackground = true
            j.isReleasedWhenClosed = false
            j.appearance = NSAppearance(named: .darkAqua)
            j.backgroundColor = NSColor(fundo)
            j.contentView = NSHostingView(rootView: AssistenteView(a: self))
            j.delegate = self
            j.center()
            janela = j
        }
        NSApp.setActivationPolicy(.regular)  // aparece no Dock enquanto o assistente está aberto
        janela?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !aberto {
            aberto = true
            registrar("assistente aberto no passo \(passo)")
            iniciarVigia()
            c.checarRede()  // com o assistente aberto o servidor sobe mesmo fora de casa
        }
    }

    func fechar() { janela?.close() }

    func windowWillClose(_ notification: Notification) {
        aberto = false
        novaTV = false
        mesmaCasa = false
        vigia?.cancel()
        vigia = nil
        // Solta a janela inteira: escondida, ela continuaria animando o anel pulsante e gastando CPU.
        let j = janela
        janela = nil
        DispatchQueue.main.async { j?.contentView = nil }
        NSApp.setActivationPolicy(.accessory)
        registrar("assistente fechado no passo \(passo)")
        Task {
            await c.reavaliar()
            c.checarRede()
        }
    }

    func irPara(_ p: Passo) {
        if p != passo { chegouEm = Date() }
        passo = p
        feitoAoChegar = feito(p)
        switch p {
        case .motor where !motorPronto && !motorRodando && motorErro == nil:
            prepararMotor()
        case .tv where !feito(.tv):
            Task { await procurarTV() }
        default:
            break
        }
    }

    private func recarregar() {
        if rede == .verificando, c.redeLocal != .verificando { rede = c.redeLocal }
        noLugar = Assistente.noLugarCerto()
        motorPronto = Motor.pronto()
        inicio = SMAppService.mainApp.status
        marcos = Marcos.ler()
        configCompleta = Controle.lerConfigCompleta()
        tvDaRede = Controle.tvDaRedePareada()
        if mesmaCasa { tvNovaNaCasa = !Assistente.tvsDaCasa().subtracting(tvsAntes).isEmpty }
    }

    /// Confere o passo da tela a cada 2 s (a pessoa pode estar liberando algo nos Ajustes).
    private func iniciarVigia() {
        vigia?.cancel()
        vigia = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.conferirPassoAtual()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func conferirPassoAtual() async {
        recarregar()
        switch passo {
        case .redeLocal:
            let r = await checarRedeLocal()
            if r != rede { rede = r; registrar("rede local: \(r)") }
            if r == .verificando {
                if redeIndefinidaDesde == nil { redeIndefinidaDesde = Date() }
                redeIndefinidaHaMuito = Date().timeIntervalSince(redeIndefinidaDesde ?? Date()) > 25
            } else {
                redeIndefinidaDesde = nil
                redeIndefinidaHaMuito = false
            }
        case .tv:
            if !feito(.tv) { await procurarTV() }
        case .parear:
            if ["procurando", "conferindo", "esperando", "esperando_ip", "liberar"].contains(pareamento) { await lerPareamento() }
        default:
            break
        }
        avancarSeConcluiu()
    }

    /// Para quem tem pouca familiaridade, a tela nunca muda sozinha: o passo fica verde e espera o "Continuar".
    private func avancarSeConcluiu() {
        guard aberto, !feitoAoChegar, feito(passo) else { return }
        feitoAoChegar = true
        registrar("passo \(passo) concluído")
    }

    func avancar() {
        guard Date().timeIntervalSince(chegouEm) > 1.2 else { return }
        irPara(proximo(depois: passo))
    }

    // MARK: ações

    func acaoPrincipal() {
        guard Date().timeIntervalSince(chegouEm) > 1.2 else { return }
        switch passo {
        case .mover:
            noLugar ? avancar() : moverParaAplicativos()
        case .motor:
            if motorPronto { avancar() } else if !motorRodando { prepararMotor() }
        case .redeLocal:
            if rede == .liberada { avancar() } else if rede == .negada { abrirAjustesRede() }
            else { Task { rede = await checarRedeLocal() } }
        case .tv:
            if feito(.tv) { avancar() } else { Task { await procurarTV() } }
        case .parear:
            if feito(.parear) && pareamento != "erro" { avancar() } else { parear() }
        case .inicio:
            if inicio == .enabled { avancar() } else if inicio == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { ativarInicio() }
        case .opcoesTV:
            if novaTV {
                opcoesNovaTV = true
            } else {
                marcos.opcoesTV = true
                marcos.gravar()
            }
            avancar()
        case .pronto:
            concluir()
        }
    }

    /// Samsung: depois de ligar o Controle Remoto IP na TV, pareia de novo (só ele pede outro "Permitir").
    func conectarDeNovo() {
        irPara(.parear)
        parear()
    }

    func moverParaAplicativos() {
        guard !movendo else { return }
        movendo = true
        moverErro = nil
        let origem = Bundle.main.bundleURL
        Task.detached {
            let fm = FileManager.default
            let sistema = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let pasta = fm.isWritableFile(atPath: sistema.path) ? sistema : Caminhos.casa.appendingPathComponent("Applications")
            try? fm.createDirectory(at: pasta, withIntermediateDirectories: true)
            let destino = pasta.appendingPathComponent("Controle da TV.app")
            if fm.fileExists(atPath: destino.path) {
                if (try? fm.trashItem(at: destino, resultingItemURL: nil)) == nil { try? fm.removeItem(at: destino) }
            }
            let copia = Process()
            copia.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copia.arguments = [origem.path, destino.path]
            try? copia.run()
            copia.waitUntilExit()
            guard copia.terminationStatus == 0, fm.fileExists(atPath: destino.appendingPathComponent("Contents/MacOS/ControleTV").path) else {
                await MainActor.run {
                    self.movendo = false
                    self.moverErro = T("Não consegui copiar. Arraste o Controle da TV para a pasta Aplicativos e abra de lá.")
                }
                return
            }
            _ = executar("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destino.path])
            // Se veio da pasta Downloads, a cópia velha vai para o lixo (no DMG não dá: ele é só leitura).
            let original = Assistente.caminhoOriginal(origem)
            if original.path.hasPrefix(Caminhos.casa.appendingPathComponent("Downloads").path) {
                try? fm.trashItem(at: original, resultingItemURL: nil)
            }
            registrar("app copiado para \(destino.path); abrindo de lá")
            await MainActor.run {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: destino, configuration: cfg) { _, erro in
                    DispatchQueue.main.async {
                        if let erro {
                            registrar("não abriu a cópia: \(erro)")
                            self.movendo = false
                            self.moverErro = T("Copiei, mas não consegui abrir. Abra o Controle da TV pela pasta Aplicativos.")
                        } else {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// App aberto direto do Downloads roda numa cópia escondida (AppTranslocation); aqui volta o caminho real.
    nonisolated static func caminhoOriginal(_ url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let f = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias Funcao = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let funcao = unsafeBitCast(f, to: Funcao.self)
        guard let original = funcao(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }

    func prepararMotor() {
        guard !motorRodando else { return }
        motorRodando = true
        motorErro = nil
        motorEtapa = 0
        Task {
            do {
                try await Motor.preparar { [weak self] etapa in self?.motorEtapa = etapa }
                motorPronto = true
                c.checarRede()
            } catch let erro as ErroMotor {
                motorErro = erro.mensagem
                registrar("motor falhou: \(erro)")
            } catch {
                motorErro = ErroMotor.falhou("\(error)").mensagem
                registrar("motor falhou: \(error)")
            }
            motorRodando = false
        }
    }

    func abrirAjustesRede() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    private struct RespostaProcura: Decodable { let encontrada: Bool; let ip: String?; var marca: String? }
    private struct RespostaPareamento: Decodable { let estado: String; let erro: String?; var marca: String? }

    func procurarTV() async {
        guard motorPronto, !tvProcurando else { return }
        tvProcurando = true
        defer { tvProcurando = false }
        await c.garantirServidor()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/api/procurar\(mesmaCasa ? "?nova=1" : "")")!)
        req.timeoutInterval = 8
        if let (dados, _) = try? await URLSession.shared.data(for: req),
           let r = try? JSONDecoder().decode(RespostaProcura.self, from: dados) {
            let ip = r.encontrada ? r.ip : nil
            if r.encontrada, let marca = r.marca { marcaAchada = marca }
            if ip != tvIP { tvIP = ip; registrar("procura da TV: \(ip ?? "não achou") \(r.marca ?? "")") }
        }
    }

    func parear() {
        pareamentoErro = nil
        pareamento = "procurando"
        let roteador = macDoRoteador()
        Task {
            await c.garantirServidor()
            for _ in 0..<10 {  // o servidor pode estar subindo
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/api/parear")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["roteador": roteador ?? "", "nova": mesmaCasa])
                req.timeoutInterval = 6
                if let (dados, _) = try? await URLSession.shared.data(for: req),
                   let r = try? JSONDecoder().decode(RespostaPareamento.self, from: dados) {
                    pareamento = r.estado
                    pareamentoErro = r.erro
                    if let marca = r.marca { marcaAchada = marca }
                    registrar("pareamento: \(r.estado)")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            pareamento = "erro"
            pareamentoErro = T("O controle não respondeu. Feche esta janela, abra o app de novo e tente outra vez.")
        }
    }

    private func lerPareamento() async {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(porta)/api/parear")!)
        req.timeoutInterval = 4
        guard let (dados, _) = try? await URLSession.shared.data(for: req),
              let r = try? JSONDecoder().decode(RespostaPareamento.self, from: dados) else { return }
        if r.estado != pareamento { registrar("pareamento: \(r.estado) \(r.erro ?? "")") }
        pareamento = r.estado
        pareamentoErro = r.erro
        if let marca = r.marca { marcaAchada = marca }
        if r.estado == "pareado" || r.estado == "liberar" {  // a Roku já entra na lista enquanto espera a liberação
            configCompleta = Controle.lerConfigCompleta()
            tvDaRede = Controle.tvDaRedePareada()
            if mesmaCasa { tvNovaNaCasa = !Assistente.tvsDaCasa().subtracting(tvsAntes).isEmpty }
            c.configCompleta = configCompleta
            c.checarRede()
        }
    }

    func ativarInicio() {
        do { try SMAppService.mainApp.register() } catch { registrar("abrir ao iniciar: \(error)") }
        inicio = SMAppService.mainApp.status
        registrar("abrir ao iniciar: \(inicio.rawValue)")
        if inicio == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func concluir() {
        if novaTV { fechar(); return }
        marcos.concluido = true
        marcos.gravar()
        fechar()
    }
}

// MARK: tela

struct AssistenteView: View {
    @ObservedObject var a: Assistente

    var body: some View {
        HStack(spacing: 0) {
            barraLateral.frame(width: 232)
            Rectangle().fill(borda).frame(width: 1)
            PaginaPasso(a: a)
                .id(a.passo)
                .transition(.opacity)
        }
        .frame(width: 840, height: 640)
        .background(LinearGradient(colors: [fundoTopo, fundo], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: a.passo)
    }

    private var barraLateral: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Controle da TV").font(.system(size: 15, weight: .semibold))
                    Text(T("Configuração")).font(.system(size: 12)).foregroundStyle(apagado)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 18)
            ForEach(Passo.allCases) { p in
                Button { a.irPara(p) } label: { LinhaPasso(p: p, atual: a.passo == p, feito: a.feito(p)) }
                    .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text(T("Ficou com dúvida?")).font(.system(size: 13, weight: .semibold))
                Text(Ajustes.ajuda + " " + T("Pode fechar esta janela a qualquer momento: depois ela volta no mesmo passo."))
                    .font(.system(size: 12))
                    .foregroundStyle(apagado)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
            HStack(spacing: 10) {
                Text(T("Versão %@", Versao.texto))
                Button(T("Termos de uso")) { NSWorkspace.shared.open(Ajustes.termos) }
                    .buttonStyle(.plain)
                    .underline()
            }
            .font(.system(size: 11))
            .foregroundStyle(apagado)
            .padding(.leading, 10)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

struct LinhaPasso: View {
    let p: Passo
    let atual: Bool
    let feito: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(feito ? verdeOk : (atual ? destaque : bloco))
                Circle().stroke(feito ? verdeOk : (atual ? destaque : borda))
                if feito {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(fundo)
                } else {
                    Text("\(p.rawValue + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(atual ? fundo : apagado)
                }
            }
            .frame(width: 22, height: 22)
            Text(p.curto)
                .font(.system(size: 14.5, weight: atual ? .semibold : .regular))
                .foregroundStyle(atual ? Color.white : Color(white: 0.72))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(atual ? blocoAtivo : Color.clear))
        .contentShape(Rectangle())
    }
}

/// O que cada passo mostra: título, explicação, situação e botões.
struct PaginaPasso: View {
    @ObservedObject var a: Assistente

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(T("Passo %d de %d", a.passo.rawValue + 1, Passo.allCases.count))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(destaque)
                .padding(.top, 40)
            Text(titulo)
                .font(.system(size: 29, weight: .semibold))
                .padding(.top, 4)
            ilustracao
                .frame(maxWidth: .infinity)
                .frame(height: 196)
                .padding(.vertical, 12)
            Text(texto)
                .font(.system(size: 17))
                .foregroundStyle(Color(white: 0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let s = situacao { LinhaSituacao(s: s) }
            HStack(spacing: 10) {
                ForEach(Array(secundarios.enumerated()), id: \.offset) { _, b in
                    Button(b.0, action: b.1).buttonStyle(BotaoSecundario()).focusEffectDisabled()
                }
                Spacer()
                Button(principal.0) { a.acaoPrincipal() }
                    .buttonStyle(BotaoPrincipal())
                    .focusEffectDisabled()
                    .disabled(!principal.1)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 26)
    }

    // MARK: textos

    private var titulo: String {
        switch a.passo {
        case .mover: return T("Guardar na pasta Aplicativos")
        case .motor: return T("Baixar as peças do controle")
        case .redeLocal: return T("Deixar o computador achar a TV")
        case .tv: return T("Ligar a TV")
        case .parear: return T("Apresentar o computador à TV")
        case .inicio: return T("Abrir sozinho quando o computador ligar")
        case .opcoesTV: return T("Opções da TV")
        case .pronto: return T("Pronto!")
        }
    }

    private var texto: AttributedString {
        let t: String
        switch a.passo {
        case .mover:
            t = a.noLugar
                ? T("Tudo certo: o Controle da TV já está guardado na pasta Aplicativos, que é o lugar certo.\n\nClique no botão azul **Continuar**.")
                : T("Primeiro, vamos guardar o Controle da TV no lugar certo do computador: a pasta **Aplicativos**.\n\nÉ só clicar no botão azul **Mover para Aplicativos**, aqui embaixo. Eu faço o resto. Esta janela vai fechar e abrir de novo sozinha: isso é normal.")
        case .motor:
            if a.motorPronto {
                t = T("Pronto, as peças foram baixadas.\n\nClique no botão azul **Continuar**.")
            } else if a.motorErro != nil {
                t = T("Não consegui baixar desta vez. Confira se o computador está na internet (no Wi-Fi de casa).\n\nDepois clique em **Tentar de novo**.")
            } else {
                t = T("Agora o computador vai baixar da internet as peças que o controle usa para conversar com a TV.\n\nVocê não precisa fazer nada: só espere, com calma. Leva uns dois minutos. Quando terminar, aparece um sinal verde aqui embaixo.")
            }
        case .redeLocal:
            switch a.rede {
            case .liberada:
                t = T("Muito bem! O computador já pode conversar com a TV.\n\nClique no botão azul **Continuar**.")
            case .negada:
                t = T("A permissão ficou desligada. Acontece, e é fácil de ligar.\n\nClique em **Abrir Ajustes**. Vai abrir uma janela com uma lista: procure **Controle da TV** e clique na chavinha ao lado dele, até ela ficar azul. Depois volte para esta janela.")
            case .semRede:
                t = T("O computador não está ligado ao Wi-Fi agora.\n\nConecte ao Wi-Fi de casa (o mesmo da TV) e espere um pouquinho.")
            case .verificando:
                t = T("O computador vai mostrar uma pergunta numa janelinha: se o Controle da TV pode encontrar aparelhos da casa.\n\nQuando ela aparecer, clique no botão **Permitir**. Se a janelinha demorar, espere alguns segundos.")
            }
        case .tv:
            if a.feito(.tv) {
                t = T("Achei a TV!\n\nClique no botão azul **Continuar**.")
            } else {
                t = T("Agora ligue a TV pelo controle remoto, do jeito de sempre (o botão de ligar, lá em cima no controle).\n\nEspere aparecer a imagem na TV. Eu procuro a TV sozinho e aviso aqui embaixo quando encontrar.")
            }
        case .parear where a.ehRoku:
            switch a.pareamento {
            case "liberar":
                t = T("Achei a TV. Falta só uma coisa, e é uma vez só.\n\nCom o controle da TV, num momento em que ninguém esteja assistindo, abra **Configurações › Sistema › Configurações avançadas do sistema › Controle por aplicativos móveis › Acesso à rede** e escolha **Ativado**.\n\nEu fico esperando aqui e aviso quando der certo.")
            case "erro":
                t = T("Não deu certo desta vez, mas está tudo bem.\n\nVeja se a TV está ligada e clique em **Tentar de novo**.")
            default:
                t = a.feito(.parear)
                    ? T("A TV e o computador já se conhecem.\n\nClique no botão azul **Continuar**.")
                    : T("Esta TV não mostra nenhum aviso: é só clicar no botão azul **Conectar**.")
            }
        case .parear where a.ehSamsung:
            switch a.pareamento {
            case "esperando":
                t = T("Olhe para a TV: apareceu um aviso na tela.\n\nCom as setas do controle remoto, escolha **Permitir** e aperte o botão do meio. Seja rápido: o aviso some em 30 segundos.")
            case "esperando_ip":
                t = T("Apareceu mais um aviso na TV, agora do **Controle Remoto IP**.\n\nEscolha **Permitir** de novo e aperte o botão do meio. Nunca escolha Negar: duas recusas bloqueiam o computador.")
            case "erro":
                t = T("Não deu certo desta vez, mas está tudo bem.\n\nClique em **Tentar de novo**. Quando aparecer o aviso na TV, escolha **Permitir** no controle remoto.")
            default:
                t = a.feito(.parear)
                    ? T("A TV e o computador já se conhecem.\n\nClique no botão azul **Continuar**.")
                    : T("Agora vamos apresentar o computador à TV. Isso só acontece desta vez.\n\n1. Clique no botão azul **Conectar**.\n2. Olhe para a TV: vai aparecer um aviso.\n3. Com as setas do controle, escolha **Permitir** e aperte o botão do meio.")
            }
        case .parear:
            switch a.pareamento {
            case "esperando":
                t = T("Olhe para a TV: apareceu um aviso na tela.\n\nAperte o botão **OK** (o do meio do controle remoto) para **Aceitar**. Sem pressa: você tem mais de um minuto.")
            case "erro":
                t = T("Não deu certo desta vez, mas está tudo bem.\n\nClique em **Tentar de novo**. Quando aparecer o aviso na TV, aperte **OK** no controle remoto.")
            default:
                t = a.feito(.parear)
                    ? T("A TV e o computador já se conhecem.\n\nClique no botão azul **Continuar**.")
                    : T("Agora vamos apresentar o computador à TV. Isso só acontece desta vez.\n\n1. Clique no botão azul **Conectar**.\n2. Olhe para a TV: vai aparecer um aviso.\n3. No controle remoto, aperte o botão **OK** (o do meio) para aceitar.")
            }
        case .inicio:
            switch a.inicio {
            case .enabled:
                t = T("Ativado: o controle vai abrir sozinho toda vez que o computador ligar.\n\nClique no botão azul **Continuar**.")
            case .requiresApproval:
                t = T("O computador pediu uma confirmação.\n\nClique em **Abrir Ajustes**. Na janela que abrir, procure **Controle da TV** e clique na chavinha ao lado dele, até ela ficar azul. Depois volte para esta janela.")
            default:
                t = T("Para o controle estar sempre pronto, ele vai abrir sozinho toda vez que o computador ligar.\n\nClique no botão azul **Ativar**. Pode aparecer um aviso no canto da tela dizendo que um item foi adicionado: é normal.")
            }
        case .opcoesTV where a.ehRoku:
            t = T("Para o computador conseguir **ligar** a TV, a opção **Início rápido da TV** precisa estar ligada no menu da TV, em **Configurações › Sistema › Energia**.\n\nSe ela já estiver ligada, é só clicar em **Já está tudo certo**.")
        case .opcoesTV where a.ehSamsung:
            t = a.c.estado?.ao_vivo == true
                ? T("Para o computador conseguir **ligar** a TV, a opção **Ligar com Dispositivo Móvel** precisa estar ligada no menu da TV, em **Configurações › Geral › Rede › Configurações Especializadas**.\n\nO **Controle Remoto IP** já está conectado: o computador escolhe a entrada (HDMI 1, 2…) direto.")
                : T("Para o computador conseguir **ligar** a TV, a opção **Ligar com Dispositivo Móvel** precisa estar ligada no menu da TV, em **Configurações › Geral › Rede › Configurações Especializadas**.\n\nNa mesma tela, **Controle Remoto IP** é opcional: com ele, o computador escolhe a entrada (HDMI 1, 2…) direto. Se ligar essa opção agora, clique em **Conectar de novo** e escolha Permitir na TV.")
        case .opcoesTV:
            t = T("Para o computador conseguir **ligar** a TV, estas três opções precisam estar ligadas no menu da TV.\n\nNesta TV elas **já estão ligadas**. Você não precisa mexer em nada: é só clicar em **Já está tudo certo**.")
        case .pronto:
            t = T("A configuração terminou.\n\nDe agora em diante, o controle fica lá em cima, no canto direito da tela, perto do relógio: é o **desenho de uma TV**. Clique nele para ligar e desligar a TV, mudar o volume e escolher o aplicativo. Se um dia algo precisar de ajuste, ele mesmo avisa.")
        }
        var atributos = AttributedString.MarkdownParsingOptions()
        atributos.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: t, options: atributos)) ?? AttributedString(t)
    }

    private var situacao: Situacao? {
        switch a.passo {
        case .mover:
            if a.movendo { return .girando(T("Copiando para a pasta Aplicativos…")) }
            if let e = a.moverErro { return .erro(e) }
            return a.noLugar ? .ok(T("Está no lugar certo.")) : nil
        case .motor:
            if let e = a.motorErro { return .erro(e) }
            if a.motorPronto { return .ok(T("Peças baixadas.")) }
            let etapas = [T("Baixando (parte 1 de 3)… pode esperar"), T("Montando (parte 2 de 3)…"), T("Instalando (parte 3 de 3)…"), T("Terminando…")]
            return .girando(etapas[max(0, min(a.motorEtapa, 3))])
        case .redeLocal:
            switch a.rede {
            case .liberada: return .ok(T("Permitido."))
            case .negada: return .erro(T("Ainda não está liberado."))
            case .semRede: return .erro(T("Sem Wi-Fi no momento."))
            case .verificando: return .girando(T("Esperando você clicar em Permitir…"))
            }
        case .tv:
            if !a.motorPronto { return .erro(T("Primeiro termine o passo 2 (Preparar).")) }
            if a.feito(.parear) { return .ok(T("A TV já está configurada.")) }
            if a.tvIP != nil { return .ok(T("TV encontrada.")) }
            return .girando(T("Procurando a TV… (ligue a TV pelo controle remoto)"))
        case .parear:
            if a.feito(.parear) && !["erro", "procurando", "conferindo", "esperando", "esperando_ip", "liberar"].contains(a.pareamento) {
                return .ok(T("Conectado à TV."))
            }
            switch a.pareamento {
            case "procurando", "conferindo": return .girando(T("Falando com a TV…"))
            case "liberar": return .girando(T("Esperando você ativar o controle pela rede na TV…"))
            case "esperando" where a.ehSamsung, "esperando_ip": return .girando(T("Esperando você escolher Permitir na TV…"))
            case "esperando": return .girando(T("Esperando você apertar OK no controle da TV…"))
            case "erro": return .erro(T(a.pareamentoErro ?? "Não deu certo. Tente de novo."))
            default: return nil
            }
        case .inicio:
            switch a.inicio {
            case .enabled: return .ok(T("Ativado."))
            case .requiresApproval: return .erro(T("Falta ligar a chave nos Ajustes."))
            default: return nil
            }
        case .opcoesTV, .pronto:
            return nil
        }
    }

    private var principal: (String, Bool) {
        switch a.passo {
        case .mover: return a.noLugar ? (T("Continuar"), true) : (a.movendo ? T("Copiando…") : T("Mover para Aplicativos"), !a.movendo)
        case .motor: return a.motorPronto ? (T("Continuar"), true) : (a.motorErro != nil ? (T("Tentar de novo"), true) : (T("Aguarde…"), false))
        case .redeLocal:
            switch a.rede {
            case .liberada: return (T("Continuar"), true)
            case .negada: return (T("Abrir Ajustes"), true)
            default: return (T("Verificar de novo"), true)
            }
        case .tv: return a.feito(.tv) ? (T("Continuar"), true) : (T("Procurar de novo"), a.motorPronto && !a.tvProcurando)
        case .parear:
            switch a.pareamento {
            case "procurando", "conferindo", "esperando", "esperando_ip", "liberar": return (T("Aguardando…"), false)
            case "erro": return (T("Tentar de novo"), a.motorPronto)
            case _ where a.feito(.parear): return (T("Continuar"), true)
            default: return (T("Conectar"), a.motorPronto)
            }
        case .inicio:
            switch a.inicio {
            case .enabled: return (T("Continuar"), true)
            case .requiresApproval: return (T("Abrir Ajustes"), true)
            default: return (T("Ativar"), true)
            }
        case .opcoesTV: return (T("Já está tudo certo"), true)
        case .pronto: return (T("Concluir"), true)
        }
    }

    /// Poucos botões: para quem é leigo, uma escolha por tela. Só aparece um extra quando ajuda de verdade.
    private var secundarios: [(String, () -> Void)] {
        switch a.passo {
        case .redeLocal where a.rede == .verificando && a.redeIndefinidaHaMuito:
            return [(T("Continuar mesmo assim"), { a.avancar() })]
        case .redeLocal where a.rede == .verificando:
            return [(T("Abrir Ajustes"), { a.abrirAjustesRede() })]
        case .parear where a.pareamento == "liberar":  // dá para liberar depois: o painel mostra o caminho
            return [(T("Fazer isso depois"), { a.avancar() })]
        case .opcoesTV where a.ehSamsung && a.c.estado?.ao_vivo != true && a.feito(.parear):
            return [(T("Conectar de novo"), { a.conectarDeNovo() })]
        default:
            return []
        }
    }

    // MARK: ilustrações

    @ViewBuilder private var ilustracao: some View {
        switch a.passo {
        case .mover: IlusMover(feito: a.noLugar)
        case .motor: IlusMotor(etapa: a.motorPronto ? 3 : a.motorEtapa, erro: a.motorErro != nil)
        case .redeLocal: IlusRedeLocal(situacao: a.rede)
        case .tv: IlusLigarTV(achada: a.feito(.tv))
        case .parear:
            IlusParear(estado: a.feito(.parear) && ["parado", "pareado"].contains(a.pareamento) ? "pareado" : a.pareamento,
                       samsung: a.ehSamsung)
        case .inicio: IlusInicio(ativado: a.inicio == .enabled)
        case .opcoesTV: IlusOpcoesTV(samsung: a.ehSamsung)
        case .pronto: IlusPronto()
        }
    }
}

enum Situacao {
    case ok(String)
    case erro(String)
    case girando(String)
}

struct LinhaSituacao: View {
    let s: Situacao

    var body: some View {
        HStack(spacing: 8) {
            switch s {
            case .ok(let t):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(verdeOk)
                Text(t)
            case .erro(let t):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(laranja)
                Text(t)
            case .girando(let t):
                ProgressView().controlSize(.small)
                Text(t)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borda))
    }
}

struct BotaoPrincipal: ButtonStyle {
    @Environment(\.isEnabled) private var habilitado

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(habilitado ? fundo : Color(white: 0.6))
            .padding(.horizontal, 26)
            .frame(height: 46)
            .background(Capsule().fill(habilitado ? destaque : bloco))
            .overlay(Capsule().strokeBorder(habilitado ? destaque : borda))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

struct BotaoSecundario: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(white: 0.88))
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(Capsule().fill(bloco))
            .overlay(Capsule().strokeBorder(borda))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
