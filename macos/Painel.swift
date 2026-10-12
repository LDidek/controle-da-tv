// Painel que abre ao clicar no ícone da TV na barra de menus.
import AppKit
import QuartzCore
import SwiftUI

// Paleta inspirada no painel de ar-condicionado do @YuriRDev: grafite com leve degradê e destaque azul-claro.
let fundo = Color(red: 0.067, green: 0.073, blue: 0.085)
let fundoTopo = Color(red: 0.118, green: 0.128, blue: 0.145)
let bloco = Color(red: 0.13, green: 0.14, blue: 0.157)
let blocoAtivo = Color(red: 0.15, green: 0.19, blue: 0.24)
let borda = Color(red: 0.2, green: 0.215, blue: 0.24)
let destaque = Color(red: 0.36, green: 0.76, blue: 0.98)  // botão de energia, interruptores, OK
let azulForte = Color(red: 0.16, green: 0.45, blue: 0.96)  // início do degradê da barra
let apagado = Color(white: 0.56)
let luzDeTela = Color(red: 0.42, green: 0.58, blue: 0.95)  // brilho de TV ao vivo e entradas
let verdeOk = Color(red: 0.36, green: 0.84, blue: 0.52)
let laranja = Color(red: 1.0, green: 0.68, blue: 0.26)
private let alturaPrincipal: CGFloat = 270   // ilustração ou seção aberta
private let volumeMaximo = 50.0  // a barra vai até 50; os botões − e + passam disso se precisar

enum Secao { case entradas, apps, setas, youtube }

struct VideoYT: Decodable, Identifiable {
    let id: String
    let titulo: String
    let canal: String
    var duracao: Double?
    var ao_vivo: Bool?
}

/// Estado local do painel (fica num objeto porque o @State não compila sem o Xcode completo).
final class EstadoPainel: ObservableObject {
    @Published var volume: Double = 0
    @Published var arrastando = false
    @Published var confirmarDesligar = false
    @Published var secao: Secao?
    @Published var pausado = false
    @Published var busca = ""
    @Published var videos: [VideoYT] = []
    @Published var buscando = false
    @Published var avisoBusca: String?
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

struct PainelTV: View {
    @ObservedObject var c: Controle
    @ObservedObject private var at: Atualizador
    @ObservedObject private var paleta = PaletaDeApps.compartilhada
    @StateObject private var ui: EstadoPainel

    init(c: Controle, ui: EstadoPainel = EstadoPainel()) {
        self.c = c
        _at = ObservedObject(wrappedValue: c.atualizador)
        _ui = StateObject(wrappedValue: ui)
    }  // sem @State: a macro dele não vem nas Command Line Tools
    @FocusState private var focado: Bool
    @FocusState private var campoBusca: Bool

    private var e: EstadoTV? { c.estado }
    private var online: Bool { e?.online == true }
    private var ligada: Bool { online && e?.ligada == true }
    private var appAtual: String { e?.app_atual ?? "" }
    private var entradaAtual: EntradaTV? { e?.entradas?.first { $0.app == appAtual } }
    private var infoApp: AppTV? { e?.apps?.first { $0.id == appAtual } }

    private var tituloTela: String {
        if appAtual == liveTV { return T("TV ao vivo") }
        if let en = entradaAtual { return en.nome }
        return infoApp?.nomeCurto ?? e?.app_titulo ?? ""
    }
    /// Ondas de som: acompanham o volume (o "turbo" da TV); no mudo ou no volume 0, param.
    private var intensidadeOndas: Double {
        if e?.mudo == true { return 0 }
        return min(1, ui.volume / 30)
    }

    /// Luz ambiente: cores do ícone do app; TV ao vivo e entradas usam luz de tela azulada.
    private var coresDaLuz: [NSColor] {
        if simboloTela != nil {
            return [NSColor(luzDeTela), NSColor(deviceRed: 0.3, green: 0.82, blue: 0.86, alpha: 1)]
        }
        if let cores = paleta.cores[appAtual], !cores.isEmpty { return cores }
        if let hex = Color(hex: infoApp?.cor) { return [NSColor(hex)] }
        return [NSColor(deviceRed: 0.62, green: 0.7, blue: 0.95, alpha: 1)]  // ícone sem cor: luz branca-azulada
    }

    private var simboloTela: String? {  // TV ao vivo e entradas não têm ícone de app
        if appAtual == liveTV { return "antenna.radiowaves.left.and.right" }
        if entradaAtual != nil { return "cable.connector" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            cabecalho
            // A janela da barra não cresce direito depois de aberta: a seção escolhida (apps,
            // entradas, setas) ocupa o lugar da ilustração e o painel mantém sempre o mesmo tamanho.
            Group {
                if ligada, let secao = ui.secao {
                    conteudo(secao)
                } else {
                    TelaTV(ligada: ligada, ligando: e?.ligando == true, appId: appAtual, titulo: tituloTela,
                           simbolo: simboloTela, cores: coresDaLuz, intensidade: intensidadeOndas)
                }
            }
            .frame(height: alturaPrincipal, alignment: .top)
            .transition(.opacity)
            // Como no painel de referência: desligada, nada some — tudo fica cinza e o layout não pula.
            VStack(alignment: .leading, spacing: 18) {
                controleVolume
                blocos
            }
            .saturation(ligada ? 1 : 0)
            .opacity(ligada ? 1 : 0.4)
            .allowsHitTesting(ligada)
            .animation(.easeInOut(duration: 0.45), value: ligada)
            rodape
        }
        .padding(20)
        .frame(width: 400)
        .background(LinearGradient(colors: [fundoTopo, fundo], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.18), value: ui.secao)
        .focusable()
        .focusEffectDisabled()
        .focused($focado)
        .onKeyPress { tecla in teclado(tecla) }
        .onAppear {
            ui.volume = Double(e?.volume ?? 0)
            focado = true
            c.painelAberto = true
            c.ultimaInteracao = Date()
        }
        .onDisappear {
            c.painelAberto = false
            c.ultimaInteracao = Date()
        }
        .onChange(of: e?.volume) { _, novo in
            if !ui.arrastando, let novo { ui.volume = Double(novo) }
        }
        .task(id: appAtual) { paleta.carregar(appAtual) }
        .task {
            while !Task.isCancelled {  // com o painel aberto, atualiza a cada 2 s
                await c.atualizar()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: topo

    private var cabecalho: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "tv").foregroundStyle(apagado)
                    Text("TV LG").font(.system(size: 16, weight: .semibold))
                }
                Text(subtitulo)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ui.confirmarDesligar ? Color.red.opacity(0.9) : apagado)
            }
            Spacer()
            Button {
                alternar(.youtube)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    Text("YouTube").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(ui.secao == .youtube ? destaque : Color(white: 0.85))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(ui.secao == .youtube ? blocoAtivo : bloco))
                .overlay(Capsule().stroke(ui.secao == .youtube ? destaque.opacity(0.6) : borda))
            }
            .buttonStyle(.plain)
            .disabled(!ligada)
            .opacity(ligada ? 1 : 0.4)
            .padding(.trailing, 6)
            Button(action: power) {
                Image(systemName: "power")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ui.confirmarDesligar ? .white : (ligada ? fundo : apagado))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(ui.confirmarDesligar ? Color.red : (ligada ? destaque : bloco)))
                    .overlay(Circle().stroke(ui.confirmarDesligar ? Color.red : (ligada ? destaque : borda), lineWidth: 1))
                    .shadow(color: ligada && !ui.confirmarDesligar ? destaque.opacity(0.45) : .clear, radius: 10)
                    .animation(.easeInOut(duration: 0.3), value: ligada)
            }
            .buttonStyle(.plain)
            .help(ligada ? T("Desligar a TV") : T("Ligar a TV"))
        }
    }

    private var subtitulo: String {
        if ui.confirmarDesligar { return T("Toque de novo para desligar") }
        guard let e else { return T("Conectando ao controle…") }
        if ligada { return T("Ligada · %@", tituloTela) }
        return e.ligando == true ? T("Ligando…") : T("Desligada")
    }

    /// Desligar pede dois toques (o segundo em até 3 s) para não apagar a TV sem querer.
    private func power() {
        if ligada {
            if ui.confirmarDesligar {
                ui.confirmarDesligar = false
                c.acao("desligar")
            } else {
                ui.confirmarDesligar = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    ui.confirmarDesligar = false
                }
            }
        } else if e != nil, e?.ligando != true {
            c.acao("ligar")
        }
    }

    // MARK: volume

    private var controleVolume: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(ui.volume))")
                        .font(.system(size: 54, weight: .light))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(T("volume")).font(.system(size: 14)).foregroundStyle(apagado)
                }
                Spacer()
                ChaveMudo(ligado: e?.mudo == true) {
                    c.estado?.mudo = !(e?.mudo ?? false)
                    c.acao("mudo")
                }
            }
            HStack(spacing: 12) {
                BotaoRedondo(simbolo: "minus") {
                    ui.volume = max(0, ui.volume - 1)
                    c.acao("volume_menos")
                }
                SliderVolume(valor: $ui.volume, arrastando: $ui.arrastando, maximo: volumeMaximo) {
                    c.acao("volume", numero: Int(ui.volume))
                }
                BotaoRedondo(simbolo: "plus") {
                    ui.volume = min(100, ui.volume + 1)
                    c.acao("volume_mais")
                }
            }
            HStack {
                Text("0")
                Spacer()
                Text("\(Int(volumeMaximo))")
            }
            .font(.system(size: 11))
            .foregroundStyle(apagado)
            .padding(.horizontal, 58)
        }
    }

    // MARK: blocos

    private var blocos: some View {
        HStack(spacing: 8) {
            Bloco(simbolo: "rectangle.on.rectangle", titulo: T("Entrada"),
                  valor: entradaAtual?.nome ?? (appAtual == liveTV ? T("TV ao vivo") : T("Apps")),
                  aberto: ui.secao == .entradas, seta: true) { alternar(.entradas) }
            Bloco(simbolo: "square.grid.2x2", titulo: "App",
                  valor: (entradaAtual == nil && appAtual != liveTV) ? tituloTela : "—",
                  aberto: ui.secao == .apps, seta: true) { alternar(.apps) }
            Bloco(simbolo: ui.pausado ? "play.fill" : "pause.fill", titulo: T("Mídia"),
                  valor: ui.pausado ? T("Continuar") : T("Pausar"), aberto: false, seta: false) {
                ui.pausado.toggle()
                c.acao(ui.pausado ? "pause" : "play")
            }
            Bloco(simbolo: "dpad", titulo: T("Setas"), valor: ui.secao == .setas ? T("Abertas") : T("Mostrar"),
                  aberto: ui.secao == .setas, seta: true) { alternar(.setas) }
        }
    }

    private func alternar(_ s: Secao) {
        ui.secao = (ui.secao == s) ? nil : s
        if ui.secao != .youtube { focado = true }
    }

    @ViewBuilder private func conteudo(_ s: Secao) -> some View {
        switch s {
        case .entradas: gradeEntradas
        case .apps: gradeApps
        case .setas: direcional
        case .youtube: buscaYouTube
        }
    }

    private var gradeEntradas: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            Chip(titulo: T("TV ao vivo"), ativo: appAtual == liveTV) { c.acao("app", liveTV) }
            ForEach(e?.entradas ?? []) { en in
                Chip(titulo: en.nome, ativo: en.app == appAtual, ponto: en.conectado, fraco: !en.conectado) {
                    c.acao("entrada", en.id)
                }
            }
        }
    }

    private var gradeApps: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(c.appsOrdenados) { app in
                    Button { c.acao("app", app.id) } label: {
                        VStack(spacing: 6) {
                            IconeApp(id: app.id, tamanho: 58)
                                .overlay(RoundedRectangle(cornerRadius: 13)
                                    .stroke(app.id == appAtual ? destaque : .clear, lineWidth: 2))
                            Text(app.nomeCurto)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .foregroundStyle(app.id == appAtual ? destaque : Color(white: 0.85))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var direcional: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(bloco).overlay(Circle().stroke(borda))
                    VStack {
                        seta("chevron.up", "UP")
                        Spacer()
                        seta("chevron.down", "DOWN")
                    }
                    .padding(.vertical, 6)
                    HStack {
                        seta("chevron.left", "LEFT")
                        Spacer()
                        seta("chevron.right", "RIGHT")
                    }
                    .padding(.horizontal, 6)
                    Button { c.acao("botao", "ENTER") } label: {
                        Text("OK")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(fundo)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(destaque))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 164, height: 164)
                VStack(spacing: 8) {
                    Atalho(simbolo: "arrow.uturn.backward", titulo: T("Voltar")) { c.acao("botao", "BACK") }
                    Atalho(simbolo: "house", titulo: T("Início")) { c.acao("botao", "HOME") }
                    Atalho(simbolo: "gearshape", titulo: T("Ajustes")) { c.acao("botao", "MENU") }
                }
            }
            Text(T("Com o painel aberto, as setas, o Enter e o ⌫ do teclado também funcionam."))
                .font(.system(size: 11))
                .foregroundStyle(apagado)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var buscaYouTube: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(apagado)
                TextField(T("Buscar no YouTube"), text: $ui.busca)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($campoBusca)
                    .onSubmit(buscar)
                if ui.buscando {
                    ProgressView().controlSize(.small)
                } else if !ui.busca.isEmpty {
                    Button {
                        ui.busca = ""
                        ui.videos = []
                        ui.avisoBusca = nil
                        campoBusca = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(apagado)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(campoBusca ? destaque.opacity(0.6) : borda))
            if ui.videos.isEmpty {
                Text(ui.avisoBusca ?? T("Digite e aperte Enter. O vídeo escolhido abre direto na TV."))
                    .font(.system(size: 12))
                    .foregroundStyle(apagado)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(ui.videos) { v in linhaVideo(v) }
                    }
                }
            }
        }
        .onAppear { campoBusca = true }
    }

    private func linhaVideo(_ v: VideoYT) -> some View {
        Button {
            c.acao("youtube", v.id)
            ui.secao = nil  // volta para a ilustração, que passa a mostrar o YouTube na tela
            focado = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(v.id)/mqdefault.jpg")) { fase in
                        if let imagem = fase.image { imagem.resizable().scaledToFill() } else { Color(white: 0.2) }
                    }
                    .frame(width: 104, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if v.ao_vivo == true || v.duracao != nil {
                        Text(v.ao_vivo == true ? T("AO VIVO") : duracaoTexto(v.duracao ?? 0))
                            .font(.system(size: 9.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(v.ao_vivo == true ? Color.red : Color.black.opacity(0.85)))
                            .padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.titulo)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(v.canal).font(.system(size: 11)).foregroundStyle(apagado).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func duracaoTexto(_ segundos: Double) -> String {
        let s = Int(segundos.rounded())
        let h = s / 3600, m = (s % 3600) / 60, seg = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, seg) : String(format: "%d:%02d", m, seg)
    }

    private func buscar() {
        let termo = ui.busca.trimmingCharacters(in: .whitespaces)
        guard !termo.isEmpty, !ui.buscando else { return }
        ui.buscando = true
        ui.avisoBusca = nil
        Task {
            defer { ui.buscando = false }
            var comp = URLComponents(string: "http://127.0.0.1:\(porta)/api/youtube")!
            comp.queryItems = [URLQueryItem(name: "q", value: termo)]
            var req = URLRequest(url: comp.url!)
            req.timeoutInterval = 20
            if let (dados, _) = try? await URLSession.shared.data(for: req),
               let lista = try? JSONDecoder().decode([VideoYT].self, from: dados) {
                ui.videos = lista
                if lista.isEmpty { ui.avisoBusca = T("Nada encontrado para “%@”.", termo) }
            } else {
                ui.videos = []
                ui.avisoBusca = T("A busca falhou. Tente de novo.")
            }
        }
    }

    private func seta(_ simbolo: String, _ botao: String) -> some View {
        Button { c.acao("botao", botao) } label: {
            Image(systemName: simbolo)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func teclado(_ t: KeyPress) -> KeyPress.Result {
        guard ligada, ui.secao != .youtube else { return .ignored }  // na busca, as teclas são do campo
        switch t.key {
        case .upArrow: c.acao("botao", "UP")
        case .downArrow: c.acao("botao", "DOWN")
        case .leftArrow: c.acao("botao", "LEFT")
        case .rightArrow: c.acao("botao", "RIGHT")
        case .return: c.acao("botao", "ENTER")
        case .delete: c.acao("botao", "BACK")
        default: return .ignored
        }
        return .handled
    }

    // MARK: rodapé

    private var rodape: some View {
        HStack(spacing: 6) {
            Group {
                if c.preparandoMotor {
                    ProgressView().controlSize(.mini)
                    Text(T("Atualizando componentes…"))
                } else if let pendente = c.pendencias.first {
                    // Falta alguma permissão: um toque reabre o assistente no passo certo.
                    Button { c.assistente.abrir(em: pendente) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(laranja)
                            Text(T("Falta um ajuste")).foregroundStyle(Color(white: 0.9))
                            Text(T("Corrigir")).fontWeight(.semibold).foregroundStyle(destaque)
                        }
                    }
                    .buttonStyle(.plain)
                } else if case .pronta(let versao) = at.situacao {
                    Button { at.instalarAgora() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(destaque)
                            Text(T("Versão %@ pronta", versao)).foregroundStyle(Color(white: 0.9))
                            Text(T("Atualizar")).fontWeight(.semibold).foregroundStyle(destaque)
                        }
                    }
                    .buttonStyle(.plain)
                } else if case .baixando(let versao) = at.situacao {
                    ProgressView().controlSize(.mini)
                    Text(T("Baixando a versão %@…", versao))
                } else if at.situacao == .instalando {
                    ProgressView().controlSize(.mini)
                    Text(T("Atualizando…"))
                } else if c.enviando > 0 {
                    ProgressView().controlSize(.mini)
                    Text(T("Enviando…"))
                } else if ui.arrastando {
                    Image(systemName: "hourglass")
                    Text(T("Aguardando…"))
                } else if e == nil {
                    ProgressView().controlSize(.mini)
                    Text(T("Iniciando…"))
                } else if at.situacao == .emDia {
                    Image(systemName: "checkmark.seal")
                    Text(T("Você já tem a versão mais nova"))
                } else if case .erro(let texto) = at.situacao {
                    Image(systemName: "exclamationmark.circle")
                    Text(T(texto))
                } else {
                    Image(systemName: "checkmark.shield")
                    Text(e?.ligando == true ? T("Ligando…") : T("Atualizado"))
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(apagado)
            .lineLimit(1)
            Spacer()
            Menu {
                Button(T("Abrir controle completo")) {
                    NSWorkspace.shared.open(URL(string: "http://localhost:\(porta)")!)
                }
                Button(T("Copiar link para o celular")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.linkCelular, forType: .string)
                }
                Divider()
                Button(T("Configurar de novo…")) { c.assistente.abrir(em: c.pendencias.first ?? .mover) }
                Button(T("Procurar atualização")) { Task { await at.verificar(manual: true) } }
                Button(T("Termos de uso")) { NSWorkspace.shared.open(Ajustes.termos) }
                Text(T("Versão %@", Versao.texto))
                Divider()
                Button(T("Sair do Controle da TV")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(apagado)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Escolhe o que o ícone mostra. Fica numa view própria para o App não depender de `configCompleta`.
struct PainelRaiz: View {
    @ObservedObject var c: Controle

    var body: some View {
        if c.configCompleta { PainelTV(c: c) } else { PainelConfigurar(c: c) }
    }
}

/// Enquanto a configuração não termina, o ícone mostra só isto: um caminho de volta para o assistente.
struct PainelConfigurar: View {
    @ObservedObject var c: Controle

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text(T("Falta terminar a configuração"))
                .font(.system(size: 16, weight: .semibold))
            Text(T("São poucos passos, com calma. A janela de configuração mostra o que fazer em cada um."))
                .font(.system(size: 13))
                .foregroundStyle(apagado)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(T("Continuar a configuração")) { c.assistente.abrir() }
                .buttonStyle(BotaoPrincipal())
            Button(T("Sair do Controle da TV")) { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(apagado)
        }
        .padding(24)
        .frame(width: 330)
        .background(LinearGradient(colors: [fundoTopo, fundo], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: peças

struct TelaTV: View {
    let ligada: Bool
    let ligando: Bool
    let appId: String
    let titulo: String
    let simbolo: String?
    let cores: [NSColor]       // luz ambiente: cores do app que está passando
    let intensidade: Double    // ondas de som: 0 = mudo ou volume 0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color.black)
                    LinearGradient(colors: [.white.opacity(0.07), .clear, .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    if ligada {
                        conteudoLigada
                            .transition(.asymmetric(
                                insertion: .modifier(active: AberturaDeTela(fracao: 0.015), identity: AberturaDeTela(fracao: 1)),
                                removal: .modifier(active: AberturaDeTela(fracao: 0.015), identity: AberturaDeTela(fracao: 1))
                                    .combined(with: .opacity)))
                    } else if ligando {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(T("Ligando…")).font(.system(size: 11.5)).foregroundStyle(apagado)
                        }
                    } else {
                        Text(T("Toque em ⏻ para ligar"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(white: 0.35))
                    }
                    RoundedRectangle(cornerRadius: 9).stroke(Color(white: 0.3), lineWidth: 2.5)
                }
                .frame(width: 228, height: 130)
                .background {  // luz na parede e ondas de som: no fundo, não empurram o layout
                    EfeitosDaTV(ligada: ligada, cores: cores, intensidade: intensidade)
                        .frame(width: 400, height: 250)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {  // LED de standby, vermelho como o da LG
                    Circle()
                        .fill(ligada ? Color.clear : Color(red: 0.9, green: 0.15, blue: 0.1))
                        .frame(width: 3, height: 3)
                        .shadow(color: ligada ? .clear : .red, radius: 3)
                        .offset(y: -3)
                }
                Rectangle().fill(Color(white: 0.28)).frame(width: 6, height: 12)
                Capsule().fill(Color(white: 0.28)).frame(width: 84, height: 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.45), value: ligada)
        .animation(.easeInOut(duration: 0.35), value: appId)
    }

    private var conteudoLigada: some View {
        let cor = Color(nsColor: cores.first ?? .systemBlue)
        return ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.07))
            RadialGradient(colors: [cor.opacity(0.32), .clear], center: .center, startRadius: 4, endRadius: 140)
            VStack(spacing: 8) {
                if let simbolo {
                    Image(systemName: simbolo)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    IconeApp(id: appId, tamanho: 52)
                }
                Text(titulo)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .id(appId)  // troca de app = troca suave do conteúdo
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Achata a tela na vertical (1 = aberta, perto de 0 = só uma linha), como TV ligando/desligando.
struct AberturaDeTela: ViewModifier {
    let fracao: CGFloat
    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: fracao, anchor: .center)
    }
}

/// Luz ambiente atrás da TV + ondas de som nas laterais. Tudo em Core Animation: o sistema anima
/// na GPU e o app não redesenha nada por quadro (a versão em SwiftUI chegava a 29% de CPU).
struct EfeitosDaTV: NSViewRepresentable {
    let ligada: Bool
    let cores: [NSColor]
    let intensidade: Double

    func makeNSView(context: Context) -> VistaEfeitos { VistaEfeitos() }
    func updateNSView(_ vista: VistaEfeitos, context: Context) {
        vista.atualizar(ligada: ligada, cores: cores, intensidade: intensidade)
    }
}

final class VistaEfeitos: NSView {
    private let luz = CALayer()
    private let brilhos: [CAGradientLayer] = (0..<3).map { _ in CAGradientLayer() }
    private let ondas: [CAReplicatorLayer] = [CAReplicatorLayer(), CAReplicatorLayer()]
    private let arcos: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer()]
    private var nivelAtual = -1
    private var coresAtuais: [CGColor] = []
    private var ligadaAtual: Bool?
    private let meiaLarguraTela: CGFloat = 114  // a tela da TV tem 228 pt

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = false
        luz.opacity = 0
        for brilho in brilhos {
            brilho.type = .radial
            brilho.startPoint = CGPoint(x: 0.5, y: 0.5)
            brilho.endPoint = CGPoint(x: 1, y: 1)
            brilho.locations = [0, 0.45, 1]
            luz.addSublayer(brilho)
        }
        layer?.addSublayer(luz)
        for (i, replicador) in ondas.enumerated() {
            let arco = arcos[i]
            arco.fillColor = nil
            arco.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
            arco.lineWidth = 1.6
            arco.lineCap = .round
            arco.opacity = 0
            replicador.addSublayer(arco)
            replicador.isHidden = true
            layer?.addSublayer(replicador)
        }
        iniciarRespiro()
    }

    required init?(coder: NSCoder) { fatalError("não usado") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)  // centro da tela da TV
        luz.frame = bounds
        brilhos[0].frame = CGRect(x: c.x - 200, y: c.y - 125, width: 400, height: 250)  // halo geral
        brilhos[1].frame = CGRect(x: c.x - 205, y: c.y - 100, width: 220, height: 200)  // lado esquerdo
        brilhos[2].frame = CGRect(x: c.x - 15, y: c.y - 100, width: 220, height: 200)   // lado direito
        for (i, replicador) in ondas.enumerated() {
            replicador.frame = bounds
            let lado: CGFloat = i == 0 ? -1 : 1
            arcos[i].bounds = .zero  // o caminho do arco é desenhado em volta da origem
            arcos[i].position = CGPoint(x: c.x + lado * (meiaLarguraTela - 8), y: c.y - 6)
        }
        CATransaction.commit()
    }

    func atualizar(ligada: Bool, cores: [NSColor], intensidade: Double) {
        let base = cores.isEmpty ? [NSColor.systemBlue] : cores
        let novas = [base[0], base.count > 1 ? base[1] : base[0], base[0]].map { $0.cgColor }
        if novas != coresAtuais {
            aplicarCores(novas, animar: !coresAtuais.isEmpty)
            coresAtuais = novas
        }
        if ligada != ligadaAtual {
            animar(luz, "opacity", ate: ligada ? 1 : 0, duracao: ligadaAtual == nil ? 0 : 0.7)
            ligadaAtual = ligada
        }
        let nivel = ligada ? Int((min(max(intensidade, 0), 1) * 4).rounded()) : 0
        if nivel != nivelAtual {
            configurarOndas(nivel)
            nivelAtual = nivel
        }
    }

    // MARK: luz ambiente

    private func aplicarCores(_ cores: [CGColor], animar: Bool) {
        let fortes: [CGFloat] = [0.42, 0.5, 0.5]
        for (i, brilho) in brilhos.enumerated() {
            let cor = cores[i]
            let novas = [cor.copy(alpha: fortes[i])!, cor.copy(alpha: fortes[i] * 0.35)!, cor.copy(alpha: 0)!]
            if animar {
                let a = CABasicAnimation(keyPath: "colors")
                a.fromValue = brilho.presentation()?.colors ?? brilho.colors
                a.toValue = novas
                a.duration = 0.9
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                brilho.add(a, forKey: "cores")
            }
            brilho.colors = novas
        }
    }

    /// A luz "respira" devagar, com os lados fora de fase, como reflexo de imagem na parede.
    private func iniciarRespiro() {
        let ritmos: [(Double, Float, CGFloat)] = [(4.6, 0.72, 0), (6.2, 0.45, 7), (7.4, 0.45, -7)]
        for (i, brilho) in brilhos.enumerated() {
            let (duracao, minimo, deriva) = ritmos[i]
            let opacidade = CABasicAnimation(keyPath: "opacity")
            opacidade.fromValue = minimo
            opacidade.toValue = 1
            let grupo = CAAnimationGroup()
            var animacoes: [CAAnimation] = [opacidade]
            if deriva != 0 {
                let mover = CABasicAnimation(keyPath: "transform.translation.y")
                mover.fromValue = -deriva
                mover.toValue = deriva
                animacoes.append(mover)
            }
            grupo.animations = animacoes
            grupo.duration = duracao
            grupo.autoreverses = true
            grupo.repeatCount = .infinity
            grupo.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            grupo.timeOffset = Double(i) * 1.3
            brilho.add(grupo, forKey: "respiro")
        }
    }

    // MARK: ondas de som

    /// nível 0 = sem ondas (mudo, volume 0 ou TV desligada); 1 a 4 conforme o volume.
    private func configurarOndas(_ nivel: Int) {
        let quantidade = [0, 2, 3, 3, 4][nivel]
        let duracao = [0, 2.6, 2.1, 1.7, 1.35][nivel]
        let alfa: Float = [0, 0.3, 0.42, 0.55, 0.68][nivel]
        for (i, replicador) in ondas.enumerated() {
            let arco = arcos[i]
            arco.removeAnimation(forKey: "onda")
            guard nivel > 0 else {
                replicador.isHidden = true
                continue
            }
            let lado: CGFloat = i == 0 ? -1 : 1
            replicador.isHidden = false
            replicador.instanceCount = quantidade
            replicador.instanceDelay = duracao / Double(quantidade)
            arco.path = VistaEfeitos.arco(raio: 10, lado: lado)
            let crescer = CABasicAnimation(keyPath: "path")
            crescer.fromValue = VistaEfeitos.arco(raio: 10, lado: lado)
            crescer.toValue = VistaEfeitos.arco(raio: 48, lado: lado)
            crescer.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let sumir = CAKeyframeAnimation(keyPath: "opacity")
            sumir.values = [0, alfa, alfa * 0.55, 0]
            sumir.keyTimes = [0, 0.15, 0.6, 1]
            let grupo = CAAnimationGroup()
            grupo.animations = [crescer, sumir]
            grupo.duration = duracao
            grupo.repeatCount = .infinity
            arco.add(grupo, forKey: "onda")
        }
    }

    /// Arco de ~70° em volta da origem, abrindo para fora da TV (direita ou esquerda).
    private static func arco(raio: CGFloat, lado: CGFloat) -> CGPath {
        let caminho = CGMutablePath()
        let meio: CGFloat = lado > 0 ? 0 : .pi
        caminho.addArc(center: .zero, radius: raio, startAngle: meio - 0.6, endAngle: meio + 0.6, clockwise: false)
        return caminho
    }

    private func animar(_ camada: CALayer, _ chave: String, ate valor: Float, duracao: Double) {
        if duracao > 0 {
            let a = CABasicAnimation(keyPath: chave)
            a.fromValue = camada.presentation()?.value(forKeyPath: chave) ?? camada.value(forKeyPath: chave)
            a.toValue = valor
            a.duration = duracao
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            camada.add(a, forKey: chave)
        }
        camada.setValue(valor, forKeyPath: chave)
    }
}

/// Cores de cada app, tiradas do próprio ícone (a cor dominante e a segunda mais forte).
@MainActor
final class PaletaDeApps: ObservableObject {
    static let compartilhada = PaletaDeApps()
    @Published private(set) var cores: [String: [NSColor]] = [:]
    private var pedidos: Set<String> = []

    func carregar(_ id: String) {
        guard !id.isEmpty, cores[id] == nil, !pedidos.contains(id) else { return }
        pedidos.insert(id)
        Task {
            let caminho = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            guard let url = URL(string: "http://127.0.0.1:\(porta)/icone/\(caminho)"),
                  let (dados, _) = try? await URLSession.shared.data(from: url) else {
                pedidos.remove(id)
                return
            }
            cores[id] = await Task.detached { PaletaDeApps.extrair(dados) }.value  // [] = ícone sem cor
        }
    }

    nonisolated static func extrair(_ dados: Data) -> [NSColor] {
        guard let imagem = NSImage(data: dados),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        imagem.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
        NSGraphicsContext.restoreGraphicsState()
        // agrupa os pixels coloridos em 12 faixas de matiz e soma o peso (saturação) de cada faixa
        var faixas = [Int: (peso: Double, r: Double, g: Double, b: Double, n: Double)]()
        for x in 0..<24 {
            for y in 0..<24 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
                guard sat > 0.35, v > 0.25 else { continue }
                let k = Int(h * 12) % 12
                var f = faixas[k] ?? (0, 0, 0, 0, 0)
                f.peso += Double(sat)
                f.r += Double(c.redComponent); f.g += Double(c.greenComponent); f.b += Double(c.blueComponent); f.n += 1
                faixas[k] = f
            }
        }
        let ordenadas = faixas.values.sorted { $0.peso > $1.peso }
        guard let primeira = ordenadas.first, primeira.n >= 8 else { return [] }
        let escolhidas = ordenadas.prefix(2).filter { $0.peso >= primeira.peso * 0.25 }
        return escolhidas.map { f in
            // realça: luz de TV é viva, nunca apagada
            let media = NSColor(deviceRed: f.r / f.n, green: f.g / f.n, blue: f.b / f.n, alpha: 1)
            var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            media.getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
            return NSColor(deviceHue: h, saturation: max(sat, 0.75), brightness: max(v, 0.85), alpha: 1)
        }
    }
}

struct IconeApp: View {
    let id: String
    let tamanho: CGFloat

    var body: some View {
        let caminho = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        AsyncImage(url: URL(string: "http://127.0.0.1:\(porta)/icone/\(caminho)")) { fase in
            if let imagem = fase.image {
                imagem.resizable().scaledToFill()
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: tamanho, height: tamanho)
        // fundo branco: ícones com transparência (o do AirPlay é um desenho preto) sumiam no painel escuro
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: tamanho * 0.24))
    }
}

struct ChaveMudo: View {
    let ligado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 10) {
                Image(systemName: ligado ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(ligado ? destaque : apagado)
                    .frame(width: 20)
                Text(T("Mudo")).font(.system(size: 14, weight: .medium))
                ZStack(alignment: ligado ? .trailing : .leading) {
                    Capsule().fill(ligado ? destaque : Color(white: 0.25)).frame(width: 44, height: 26)
                    Circle().fill(.white).frame(width: 20, height: 20).padding(3)
                }
                .animation(.easeOut(duration: 0.15), value: ligado)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(bloco))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(borda))
        }
        .buttonStyle(.plain)
    }
}

struct BotaoRedondo: View {
    let simbolo: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: simbolo)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(bloco))
                .overlay(Circle().stroke(borda))
        }
        .buttonStyle(.plain)
    }
}

struct SliderVolume: View {
    @Binding var valor: Double
    @Binding var arrastando: Bool
    let maximo: Double
    let aoSoltar: () -> Void

    var body: some View {
        GeometryReader { g in
            let polegar: CGFloat = 32
            let util = max(g.size.width - polegar, 1)
            let x = CGFloat(min(valor, maximo) / maximo) * util
            ZStack(alignment: .leading) {
                Capsule().fill(bloco).overlay(Capsule().stroke(borda))
                Capsule()
                    .fill(LinearGradient(colors: [azulForte, destaque],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + polegar)
                Circle()
                    .fill(.white)
                    .frame(width: polegar, height: polegar)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: x)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        arrastando = true
                        let fracao = Double((v.location.x - polegar / 2) / util)
                        valor = (min(max(fracao, 0), 1) * maximo).rounded()
                    }
                    .onEnded { _ in
                        arrastando = false
                        aoSoltar()
                    }
            )
        }
        .frame(height: 44)
    }
}

struct Bloco: View {
    let simbolo: String
    let titulo: String
    let valor: String
    let aberto: Bool
    let seta: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: simbolo)
                        .font(.system(size: 19))
                        .foregroundStyle(aberto ? destaque : Color(white: 0.85))
                    Spacer(minLength: 0)
                    if seta {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(apagado)
                            .rotationEffect(.degrees(aberto ? 180 : 0))
                    }
                }
                Spacer(minLength: 12)
                Text(titulo).font(.system(size: 11)).foregroundStyle(apagado)
                Text(valor)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(aberto ? blocoAtivo : bloco))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(aberto ? destaque.opacity(0.6) : borda))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    let titulo: String
    let ativo: Bool
    var ponto = false
    var fraco = false
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 6) {
                if ponto { Circle().fill(Color.green.opacity(0.85)).frame(width: 6, height: 6) }
                Text(titulo).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(ativo ? destaque : (fraco ? apagado : Color(white: 0.9)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ativo ? destaque : borda))
        }
        .buttonStyle(.plain)
    }
}

struct Atalho: View {
    let simbolo: String
    let titulo: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 8) {
                Image(systemName: simbolo).frame(width: 18)
                Text(titulo).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: 128, height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(borda))
        }
        .buttonStyle(.plain)
    }
}

#if !TESTE_RENDER
@main
struct ControleTVApp: App {
    @StateObject private var c = Controle()

    var body: some Scene {
        // O SwiftUI regrava este valor a cada redesenho; gravar no @Published sem checar
        // dispara outro redesenho e trava a thread principal em 100% de CPU.
        MenuBarExtra(isInserted: Binding(get: { c.iconeVisivel }, set: { if c.iconeVisivel != $0 { c.iconeVisivel = $0 } })) {
            PainelRaiz(c: c)
        } label: {
            Image(systemName: c.estado?.online == true && c.estado?.ligada == true ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
