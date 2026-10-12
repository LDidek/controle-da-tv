// "Motor" do controle: o Python e as bibliotecas que conversam com a TV. O uv vai dentro do app;
// na primeira abertura ele baixa o Python e instala as bibliotecas em Application Support.
import Foundation

enum ErroMotor: Error {
    case semInternet
    case falhou(String)

    var mensagem: String {
        switch self {
        case .semInternet: return T("Sem internet. Confira o Wi-Fi e clique em Tentar de novo.")
        case .falhou(let detalhe): return T("Não deu certo (%@). Clique em Tentar de novo.", detalhe)
        }
    }
}

enum Motor {
    static let versaoPython = "3.13.14"
    static var python: URL { Caminhos.motor.appendingPathComponent("bin/python") }
    static var servidor: URL { Caminhos.recursos.appendingPathComponent("servidor.py") }
    private static var requisitos: URL { Caminhos.recursos.appendingPathComponent("requisitos.txt") }
    private static var carimbo: URL { Caminhos.motor.appendingPathComponent("carimbo-controle-tv.txt") }

    /// Muda quando o app novo pede outro Python ou outras versões das bibliotecas.
    private static var esperado: String {
        let lista = (try? String(contentsOf: requisitos, encoding: .utf8)) ?? ""
        return "python \(versaoPython)\n\(lista)"
    }

    static func pronto() -> Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && (try? String(contentsOf: carimbo, encoding: .utf8)) == esperado
    }

    /// Já existe algum motor (talvez de uma versão anterior do app)?
    static func existe() -> Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// Ambiente limpo para o uv: nada da configuração do usuário, só Python gerenciado pelo uv
    /// (nunca o /usr/bin/python3, que num Mac sem ferramentas de desenvolvedor abre um pedido de instalação).
    static func ambiente() -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "pt_BR.UTF-8",
            "UV_CACHE_DIR": Caminhos.cacheUV.path,
            "UV_PYTHON_INSTALL_DIR": Caminhos.pythons.path,
            "UV_MANAGED_PYTHON": "1",
            "UV_NO_CONFIG": "1",
            "UV_NO_PROGRESS": "1",
            "UV_PYTHON_DOWNLOADS": "automatic",
        ]
    }

    /// etapa: 0 = baixando o Python, 1 = criando o ambiente, 2 = instalando as bibliotecas, 3 = pronto.
    static func preparar(etapa: @escaping @MainActor (Int) -> Void) async throws {
        try? FileManager.default.createDirectory(at: Caminhos.dados, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Caminhos.cacheUV, withIntermediateDirectories: true)
        registrar("motor: preparando (Python \(versaoPython))")
        await etapa(0)
        try await uv(["python", "install", "--no-bin", versaoPython])
        await etapa(1)
        try await uv(["venv", "--clear", "--python", versaoPython, Caminhos.motor.path])
        await etapa(2)
        try await uv(["pip", "install", "--python", python.path, "-r", requisitos.path])
        try esperado.write(to: carimbo, atomically: true, encoding: .utf8)
        registrar("motor: pronto")
        await etapa(3)
    }

    private static func uv(_ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = Caminhos.uv
            p.arguments = args
            p.environment = ambiente()
            p.currentDirectoryURL = Caminhos.dados
            let saida = Pipe()
            p.standardOutput = saida
            p.standardError = saida
            try p.run()
            let dados = saida.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let texto = String(decoding: dados, as: UTF8.self)
            registrar("uv \(args.prefix(2).joined(separator: " ")) → \(p.terminationStatus)\n\(texto.suffix(2000))")
            guard p.terminationStatus == 0 else {
                let t = texto.lowercased()
                let rede = ["dns", "failed to lookup", "error sending request", "network", "could not connect",
                            "connection refused", "timed out", "tcp connect", "offline", "failed to download"]
                if rede.contains(where: { t.contains($0) }) { throw ErroMotor.semInternet }
                let ultima = texto.split(separator: "\n").last.map(String.init) ?? "código \(p.terminationStatus)"
                throw ErroMotor.falhou(String(ultima.prefix(120)))
            }
        }.value
    }
}
