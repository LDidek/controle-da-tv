// Teste de imagem do painel, sem clicar na barra de menus (o clique simulado fecha na hora quando
// alguém está usando o Mac). Desenha o painel fora da tela com o estado real do servidor (porta 8765).
//
//   swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -D TESTE_RENDER \
//     macos/*.swift ferramentas/render-painel.swift -o /tmp/render-painel
//   /tmp/render-painel <pasta de saída> [entrada simulada, ex.: samsung.hdmi4]
//
// Gera painel-principal.png e painel-entradas.png (400 pt de largura, em 2x).
import AppKit
import SwiftUI

@main
struct Render {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let dados = try! Data(contentsOf: URL(string: "http://127.0.0.1:8765/api/estado")!)
        var estado = try! JSONDecoder().decode(EstadoTV.self, from: dados)
        if CommandLine.arguments.count > 2 {  // simula uma entrada na tela, ex.: samsung.hdmi4
            estado.app_atual = CommandLine.arguments[2]
            estado.app_titulo = estado.entradas?.first { $0.app == CommandLine.arguments[2] }?.nome
        }
        let c = Controle()
        c.congelado = true
        c.estado = estado
        let saida = CommandLine.arguments[1]
        for (nome, secao) in [("principal", nil), ("entradas", Secao.entradas)] as [(String, Secao?)] {
            let ui = EstadoPainel()
            ui.volume = Double(estado.volume ?? 0)
            ui.secao = secao
            let vista = NSHostingView(rootView: PainelTV(c: c, ui: ui))
            vista.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
            let janela = NSWindow(contentRect: vista.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            janela.contentView = vista
            vista.frame.size = vista.fittingSize
            try? await Task.sleep(for: .seconds(4))  // deixa os ícones chegarem do servidor
            let rep = vista.bitmapImageRepForCachingDisplay(in: vista.bounds)!
            vista.cacheDisplay(in: vista.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(saida)/painel-\(nome).png"))
            print("ok \(nome) \(vista.bounds.size)")
        }
    }
}
