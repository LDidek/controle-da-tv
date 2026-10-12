// Idioma do app: segue o idioma do Mac (português, espanhol; qualquer outro vira inglês).
import Foundation

enum Idioma: String {
    case pt, en, es

    static let atual: Idioma = {
        for codigo in Locale.preferredLanguages {
            let c = codigo.lowercased()
            if c.hasPrefix("pt") { return .pt }
            if c.hasPrefix("es") { return .es }
            if c.hasPrefix("en") { return .en }
        }
        return .en
    }()
}

/// Traduz um texto escrito em português no código. Sem tradução (ou texto que já veio traduzido),
/// devolve o próprio texto. Com argumentos, funciona como String(format:).
func T(_ pt: String, _ argumentos: CVarArg...) -> String {
    let texto: String
    switch Idioma.atual {
    case .pt: texto = pt
    case .en: texto = traducoes[pt]?.en ?? pt
    case .es: texto = traducoes[pt]?.es ?? pt
    }
    return argumentos.isEmpty ? texto : String(format: texto, arguments: argumentos)
}
