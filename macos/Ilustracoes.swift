// Desenhos do assistente: imitações simples do que a pessoa vai ver (aviso do Mac, Ajustes, TV, controle).
import AppKit
import SwiftUI

/// Anel que pulsa em volta do que precisa ser clicado.
struct Pulso: View {
    var cor: Color = destaque
    var raio: CGFloat = 10

    var body: some View {
        PhaseAnimator([false, true]) { fase in
            RoundedRectangle(cornerRadius: raio)
                .stroke(cor, lineWidth: 2.5)
                .scaleEffect(fase ? 1.18 : 1)
                .opacity(fase ? 0 : 0.95)
        } animation: { fase in
            fase ? .easeOut(duration: 1.1) : .linear(duration: 0.01)
        }
        .allowsHitTesting(false)
    }
}

/// TV de frente, com pé. O conteúdo vai na tela.
struct DesenhoTV<Tela: View>: View {
    var largura: CGFloat = 240
    var led = false
    @ViewBuilder var tela: Tela

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                tela
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(5)
                RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.34), lineWidth: 2.5)
            }
            .frame(width: largura, height: largura * 0.57)
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(led ? Color(red: 0.95, green: 0.18, blue: 0.12) : .clear)
                    .frame(width: 4, height: 4)
                    .offset(y: -2)
            }
            Rectangle().fill(Color(white: 0.3)).frame(width: 8, height: 14)
            Capsule().fill(Color(white: 0.3)).frame(width: largura * 0.38, height: 6)
        }
    }
}

/// Controle remoto da LG, com o botão que a pessoa deve apertar em destaque.
struct DesenhoControle: View {
    enum Botao { case nenhum, energia, ok }
    let destacar: Botao

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(white: 0.38)))
                .frame(width: 66, height: 186)
            VStack(spacing: 11) {
                HStack {
                    ZStack {
                        Circle().fill(Color(red: 0.86, green: 0.16, blue: 0.14)).frame(width: 16, height: 16)
                        Image(systemName: "power").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        if destacar == .energia { Pulso(cor: .white, raio: 10).frame(width: 24, height: 24) }
                    }
                    Spacer()
                    Circle().fill(Color(white: 0.4)).frame(width: 9, height: 9)
                }
                .padding(.horizontal, 12)
                VStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 7) {
                            ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(white: 0.36)).frame(width: 8, height: 8) }
                        }
                    }
                }
                ZStack {
                    Circle().fill(Color(white: 0.3)).frame(width: 44, height: 44)
                    Circle().fill(Color(white: 0.5)).frame(width: 20, height: 20)
                    Text("OK").font(.system(size: 7, weight: .bold)).foregroundStyle(Color(white: 0.12))
                    if destacar == .ok { Pulso(cor: .white, raio: 14).frame(width: 28, height: 28) }
                }
                HStack(spacing: 14) {
                    Capsule().fill(Color(white: 0.36)).frame(width: 10, height: 22)
                    Capsule().fill(Color(white: 0.36)).frame(width: 10, height: 22)
                }
            }
            .padding(.top, 16)
        }
        .frame(width: 66, height: 186)
    }
}

struct IlusMover: View {
    let feito: Bool

    var body: some View {
        HStack(spacing: 26) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 92, height: 92)
                Text("Controle da TV").font(.system(size: 12)).foregroundStyle(apagado)
            }
            Image(systemName: feito ? "checkmark.circle.fill" : "arrow.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(feito ? verdeOk : destaque)
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications")).resizable().frame(width: 92, height: 92)
                Text(T("Aplicativos")).font(.system(size: 12)).foregroundStyle(apagado)
            }
        }
    }
}

struct IlusMotor: View {
    let etapa: Int
    let erro: Bool

    var body: some View {
        VStack(spacing: 10) {
            linha(0, "arrow.down.circle", T("Baixar o Python"))
            linha(1, "gearshape.2", T("Montar o motor"))
            linha(2, "tv.and.mediabox", T("Instalar as peças que falam com a TV"))
        }
        .frame(width: 380)
    }

    private func linha(_ n: Int, _ simbolo: String, _ texto: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: simbolo).font(.system(size: 18)).foregroundStyle(destaque).frame(width: 26)
            Text(texto).font(.system(size: 14))
            Spacer()
            Group {
                if etapa > n {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(verdeOk)
                } else if etapa == n && erro {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(laranja)
                } else if etapa == n {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(borda)
                }
            }
            .font(.system(size: 17))
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 12).fill(etapa == n ? blocoAtivo : bloco))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(etapa == n ? destaque.opacity(0.5) : borda))
    }
}

/// Imitação do aviso do Mac ("Permitir que … encontre dispositivos…") ou dos Ajustes, se foi negado.
struct IlusRedeLocal: View {
    let situacao: SituacaoRede

    var body: some View {
        if situacao == .negada {
            AjustesFalsos(caminho: T("Ajustes do Sistema › Privacidade e Segurança › Rede Local"),
                          titulo: T("Rede Local"), linha: "Controle da TV", ligado: false)
        } else {
            avisoDoMac
        }
    }

    private var avisoDoMac: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 46, height: 46)
            Text(T("Permitir que “Controle da TV” encontre dispositivos em redes locais?"))
                .font(.system(size: 12.5, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(white: 0.1))
            Text(T("Para encontrar e controlar a TV na rede de casa."))
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.35))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(T("Não Permitir"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.15))
                    .frame(width: 124, height: 26)
                    .background(Capsule().fill(Color(white: 0.84)))
                ZStack {
                    Text(T("Permitir"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 124, height: 26)
                        .background(Capsule().fill(Color(red: 0.0, green: 0.45, blue: 0.95)))
                    if situacao != .liberada { Pulso(cor: destaque, raio: 13).frame(width: 130, height: 32) }
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.95)))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// Imitação de uma lista dos Ajustes do Sistema com a chave do app.
struct AjustesFalsos: View {
    let caminho: String
    let titulo: String
    let linha: String
    let ligado: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caminho).font(.system(size: 11.5)).foregroundStyle(apagado)
            VStack(alignment: .leading, spacing: 10) {
                Text(titulo).font(.system(size: 15, weight: .bold))
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    Text(linha).font(.system(size: 13.5))
                    Spacer()
                    ZStack {
                        ZStack(alignment: .trailing) {
                            Capsule().fill(Color(red: 0.0, green: 0.48, blue: 1)).frame(width: 40, height: 22)
                            Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                        }
                        if !ligado { Pulso(cor: destaque, raio: 12).frame(width: 46, height: 28) }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.2)))
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.3)).frame(width: 28, height: 28)
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.3)).frame(width: 110, height: 9)
                    Spacer()
                    Capsule().fill(Color(white: 0.32)).frame(width: 40, height: 22)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.17)))
                .opacity(0.6)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.25)))
        }
        .frame(width: 400)
    }
}

struct IlusLigarTV: View {
    let achada: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 34) {
            DesenhoTV(largura: 250, led: !achada) {
                if achada {
                    ZStack {
                        LinearGradient(colors: [azulForte.opacity(0.85), destaque.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(.white)
                    }
                } else {
                    Color.black
                }
            }
            DesenhoControle(destacar: achada ? .nenhum : .energia)
        }
    }
}

struct IlusParear: View {
    let estado: String
    var samsung = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 34) {
            DesenhoTV(largura: 250) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                    if estado == "pareado" {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(verdeOk)
                            Text(T("Conectado")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        }
                    } else {
                        avisoDaTV
                    }
                }
            }
            DesenhoControle(destacar: estado == "pareado" ? .nenhum : .ok)
        }
    }

    private var avisoDaTV: some View {
        VStack(spacing: 7) {
            Text(T("Controle da TV quer se conectar à TV"))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color(white: 0.12))
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Text(samsung ? T("Permitir") : T("Aceitar"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.75, green: 0.1, blue: 0.3)))
                Text(samsung ? T("Negar") : T("Recusar"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(white: 0.2))
                    .frame(width: 58, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.8)))
            }
        }
        .padding(10)
        .frame(width: 168)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.94)))
    }
}

struct IlusInicio: View {
    let ativado: Bool

    var body: some View {
        AjustesFalsos(caminho: T("Ajustes do Sistema › Geral › Itens de Início"),
                      titulo: T("Abrir ao Iniciar a Sessão"), linha: "Controle da TV", ligado: true)
            .overlay(alignment: .topTrailing) {
                if ativado {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(verdeOk)
                        .background(Circle().fill(fundo))
                        .offset(x: 10, y: 14)
                }
            }
    }
}

struct IlusOpcoesTV: View {
    var samsung = false

    var body: some View {
        VStack(spacing: 8) {
            if samsung {
                linha("1", T("Geral › Rede › Configurações Especializadas"), T("Ligar com Dispositivo Móvel"))
                linha("2", T("Na mesma tela (opcional)"), T("Controle Remoto IP"))
            } else {
                linha("1", T("Rede"), "LG Connect Apps")
                linha("2", T("Geral › Mobile TV On"), T("Ligar via Wi-Fi"))
                linha("3", T("Geral"), T("Início Rápido+"))
            }
        }
        .frame(width: 440)
    }

    private func linha(_ n: String, _ caminho: String, _ opcao: String) -> some View {
        HStack(spacing: 12) {
            Text(n)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(fundo)
                .frame(width: 24, height: 24)
                .background(Circle().fill(destaque))
            VStack(alignment: .leading, spacing: 2) {
                Text(caminho).font(.system(size: 11.5)).foregroundStyle(apagado)
                Text(opcao).font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            Text(T("Ligado"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fundo)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(verdeOk))
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(bloco))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borda))
    }
}

/// Barra de menus de mentira, com o ícone da TV em destaque.
struct IlusPronto: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "applelogo").font(.system(size: 13))
                Text("Finder").font(.system(size: 12.5, weight: .bold))
                Text(T("Arquivo")).font(.system(size: 12.5))
                Text(T("Editar")).font(.system(size: 12.5))
                Spacer()
                ZStack {
                    Image(systemName: "tv").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    Circle().stroke(destaque, lineWidth: 2.5).frame(width: 30, height: 30)
                    Pulso(cor: destaque, raio: 15).frame(width: 30, height: 30)
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.up").font(.system(size: 22, weight: .bold))
                        Text(T("Clique aqui")).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(destaque)
                    .fixedSize()
                    .offset(y: 42)
                }
                Image(systemName: "wifi").font(.system(size: 13))
                Image(systemName: "battery.75percent").font(.system(size: 14))
                Text(T("Dom 20:30")).font(.system(size: 12.5))
            }
            .foregroundStyle(Color(white: 0.9))
            .padding(.horizontal, 14)
            .frame(width: 470, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
            Spacer()
        }
        .padding(.top, 30)
    }
}
