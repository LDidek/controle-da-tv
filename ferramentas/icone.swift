// Desenha o ícone do app (1024 px) e o fundo do DMG (1x e 2x).
//   icone <saida.png>                     ícone
//   fundo <saida.png> <escala>            fundo da janela do DMG (660 x 440 pontos)
import AppKit

let a = CommandLine.arguments
func gravar(_ rep: NSBitmapImageRep, _ caminho: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: caminho))
}
func tela(_ w: Int, _ h: Int, _ desenho: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    desenho(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func cor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(deviceRed: r, green: g, blue: b, alpha: a) }
let azul = cor(0.36, 0.76, 0.98)
let azulForte = cor(0.16, 0.45, 0.96)

func icone(_ caminho: String) {
    let rep = tela(1024, 1024) { ctx in
        // placa arredondada, como os ícones do macOS (824 px com margem para a sombra)
        let placa = NSRect(x: 100, y: 100, width: 824, height: 824)
        let forma = NSBezierPath(roundedRect: placa, xRadius: 186, yRadius: 186)
        NSGraphicsContext.saveGraphicsState()
        let sombra = NSShadow(); sombra.shadowColor = cor(0, 0, 0, 0.35); sombra.shadowBlurRadius = 24; sombra.shadowOffset = NSSize(width: 0, height: -10)
        sombra.set()
        cor(0.07, 0.08, 0.09).setFill(); forma.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        forma.addClip()
        NSGradient(colors: [cor(0.15, 0.17, 0.21), cor(0.055, 0.06, 0.075)])!.draw(in: placa, angle: -90)
        // luz ambiente atrás da TV
        NSGradient(colors: [azul.withAlphaComponent(0.55), azulForte.withAlphaComponent(0.18), azulForte.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 440, options: [])
        NSGraphicsContext.restoreGraphicsState()
        // TV
        let telaTV = NSRect(x: 232, y: 400, width: 560, height: 330)
        let moldura = NSBezierPath(roundedRect: telaTV, xRadius: 34, yRadius: 34)
        cor(0.02, 0.02, 0.03).setFill(); moldura.fill()
        cor(0.42, 0.45, 0.5).setStroke(); moldura.lineWidth = 14; moldura.stroke()
        let dentro = NSBezierPath(roundedRect: telaTV.insetBy(dx: 24, dy: 24), xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState(); dentro.addClip()
        NSGradient(colors: [azulForte, azul])!.draw(in: telaTV.insetBy(dx: 24, dy: 24), angle: 35)
        NSGraphicsContext.restoreGraphicsState()
        // botão de ligar no meio da tela
        let simbolo = NSImage(systemSymbolName: "power", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 150, weight: .bold))!
        let tinta = NSImage(size: simbolo.size, flipped: false) { r in
            simbolo.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        tinta.draw(in: NSRect(x: 512 - simbolo.size.width / 2, y: 565 - simbolo.size.height / 2, width: simbolo.size.width, height: simbolo.size.height))
        // pé
        cor(0.42, 0.45, 0.5).setFill()
        NSBezierPath(rect: NSRect(x: 492, y: 330, width: 40, height: 64)).fill()
        NSBezierPath(roundedRect: NSRect(x: 382, y: 300, width: 260, height: 34), xRadius: 17, yRadius: 17).fill()
        _ = ctx
    }
    gravar(rep, caminho)
}

func texto(_ s: String, _ tamanho: CGFloat, _ peso: NSFont.Weight, _ c: NSColor, centro: NSPoint, largura: CGFloat, escala: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 3 * escala
    let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tamanho * escala, weight: peso), .foregroundColor: c, .paragraphStyle: p]
    let txt = NSAttributedString(string: s, attributes: attr)
    let caixa = txt.boundingRect(with: NSSize(width: largura * escala, height: 1000), options: [.usesLineFragmentOrigin])
    txt.draw(with: NSRect(x: centro.x * escala - largura * escala / 2, y: centro.y * escala - caixa.height / 2,
                          width: largura * escala, height: caixa.height), options: [.usesLineFragmentOrigin])
}

/// Escreve centralizado a partir de uma linha de topo e devolve onde o texto terminou (para o próximo).
func escreverDoTopo(_ s: String, _ tamanho: CGFloat, _ peso: NSFont.Weight, _ c: NSColor, topo: CGFloat,
                    largura: CGFloat, escala e: CGFloat) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 1.5 * e
    let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tamanho * e, weight: peso), .foregroundColor: c, .paragraphStyle: p]
    let txt = NSAttributedString(string: s, attributes: attr)
    let caixa = txt.boundingRect(with: NSSize(width: largura * e, height: 1000 * e), options: [.usesLineFragmentOrigin])
    let x = (660 * e - largura * e) / 2
    txt.draw(with: NSRect(x: x, y: topo - caixa.height, width: largura * e, height: caixa.height), options: [.usesLineFragmentOrigin])
    return topo - caixa.height
}

/// Fundo do DMG, em português, inglês e espanhol. O Finder desenha os ícones por cima: app em (165, 150) e
/// Aplicativos em (495, 150), em pontos a partir do topo. O rodapé da janela some atrás das barras do Finder.
func fundo(_ caminho: String, _ e: CGFloat) {
    let W: CGFloat = 660, H: CGFloat = 520
    let rep = tela(Int(W * e), Int(H * e)) { _ in
        cor(0.965, 0.972, 0.982).setFill(); NSRect(x: 0, y: 0, width: W * e, height: H * e).fill()
        texto("Arraste para Aplicativos  ·  Drag to Applications  ·  Arrastra a Aplicaciones", 16, .semibold,
              cor(0.1, 0.12, 0.16), centro: NSPoint(x: W / 2, y: H - 36), largura: 620, escala: e)
        let y = (H - 150) * e
        let seta = NSBezierPath()
        seta.move(to: NSPoint(x: 262 * e, y: y)); seta.line(to: NSPoint(x: 388 * e, y: y))
        seta.lineWidth = 7 * e; seta.lineCapStyle = .round; azulForte.setStroke(); seta.stroke()
        let ponta = NSBezierPath()
        ponta.move(to: NSPoint(x: 400 * e, y: y)); ponta.line(to: NSPoint(x: 378 * e, y: y + 16 * e)); ponta.line(to: NSPoint(x: 378 * e, y: y - 16 * e)); ponta.close()
        azulForte.setFill(); ponta.fill()
        let caixa = NSRect(x: 24 * e, y: (H - 408) * e, width: (W - 48) * e, height: 160 * e)
        cor(1, 0.96, 0.86).setFill(); NSBezierPath(roundedRect: caixa, xRadius: 14 * e, yRadius: 14 * e).fill()
        cor(0.93, 0.78, 0.45).setStroke(); let borda = NSBezierPath(roundedRect: caixa, xRadius: 14 * e, yRadius: 14 * e); borda.lineWidth = 1.5 * e; borda.stroke()
        let marrom = cor(0.3, 0.22, 0.05), titulo = cor(0.42, 0.28, 0.02)
        let blocos: [(String, String)] = [
            ("Na primeira vez", "O Mac avisa que não conhece o app: clique em “Concluído”. Depois abra Ajustes do Sistema › Privacidade e Segurança e clique em “Abrir Mesmo Assim”."),
            ("First time", "macOS says it can't verify the app: click “Done”. Then open System Settings › Privacy & Security and click “Open Anyway”."),
            ("Primera vez", "macOS avisa que no puede verificar la app: cierra el aviso. Luego abre Ajustes del Sistema › Privacidad y seguridad y haz clic en “Abrir igualmente”."),
        ]
        // desenha de cima para baixo, cada bloco logo abaixo do anterior
        var topo = (H - 258) * e
        for (cabeca, corpo) in blocos {
            topo = escreverDoTopo(cabeca, 12, .bold, titulo, topo: topo, largura: 590, escala: e) - 1 * e
            topo = escreverDoTopo(corpo, 11, .regular, marrom, topo: topo, largura: 590, escala: e) - 8 * e
        }
    }
    rep.size = NSSize(width: W, height: H)
    gravar(rep, caminho)
}

switch a.count > 1 ? a[1] : "" {
case "icone": icone(a[2])
case "fundo": fundo(a[2], CGFloat(Double(a[3]) ?? 1))
default: print("uso: icone <png> | fundo <png> <escala>")
}
