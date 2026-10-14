# Roku TV (Philco, TCL, AOC…): referência para o Controle da TV

Levantado em 14/10/2026 numa Philco Roku TV 40" (PTV40M9GR2CGB, Roku OS 16.0.4, região BR, sintonizador ISDB),
**só com consultas de leitura**: nada apareceu na tela de quem estava assistindo.

Fonte oficial: [External Control Protocol (ECP)](https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md)
(versão em markdown: acrescente `.md` à URL; índice para agentes em `https://developer.roku.com/dev/llms.txt`).

## Como achar a TV

- SSDP: `M-SEARCH` com `ST: roku:ecp` (ou `ssdp:all`) em `239.255.255.250:1900`; a resposta traz
  `LOCATION: http://IP:8060/` e `Server: Roku/<versão>`.
- API em HTTP puro na porta **8060**, sem pareamento, sem token, sem aviso "Permitir" na tela.

## O que é silencioso (não mexe na tela)

Todos `GET`. Servem para conferir estado sem atrapalhar quem está vendo.

| Comando | Devolve | Funciona em modo Limitado? |
|---|---|---|
| `GET /query/device-info` | modelo, versão, `power-mode` (PowerOn / DisplayOff / Ready), rede, `ecp-setting-mode` | sim |
| `GET /query/active-app` | app em primeiro plano (ex.: Globoplay `564736`) ou a entrada/sintonizador | sim |
| `GET /query/media-player` | estado do player (tocando, pausado, posição) | não (403) |
| `GET /query/apps` | apps instalados com id | não (403) |
| `GET /query/tv-active-channel` | canal da TV aberta | não (403) |
| `GET /query/tv-channels` | lista de canais sintonizados | não (403) |
| `GET /query/icon/<appId>` | ícone do app (PNG) | não |

## O que mexe na tela (só com combinação prévia)

Tudo `POST` sem corpo:

- `keypress/<TECLA>` (também `keydown` / `keyup`). Teclas: `Home Back Select Up Down Left Right Play Rev Fwd
  InstantReplay Info Search Enter Backspace`; em Roku TV também `VolumeUp VolumeDown VolumeMute PowerOff` (`PowerOn` existe na prática, mas não está na doc oficial),
  `ChannelUp ChannelDown`, `InputTuner InputHDMI1..4 InputAV1`; texto em teclado na tela com `Lit_<caractere>`.
- `launch/<appId>` abre um app (com `?contentId=…&mediaType=…` faz deep link para um conteúdo);
  `install/<appId>` abre a loja no app.
- `PowerOff` desliga; ligar pela rede depende de `supports-warm-standby` / `supports-wake-on-wlan` (esta Philco
  tem os dois) e de "Início rápido da TV" estar ligado.

## A trava: "Controle por aplicativos móveis"

Desde o Roku OS 14.1 o campo `ecp-setting-mode` diz o nível:

- `enabled`: tudo acima funciona.
- `limited` (padrão de fábrica e o desta TV): só `device-info`, `active-app` e poucos outros; teclas, lista de apps
  e canais devolvem **403 "ECP command not allowed in Limited mode."**
- `disabled`: nada.

Para controlar a TV é preciso, **uma vez, no controle físico**: Configurações › Sistema › Configurações avançadas do
sistema › Controle por aplicativos móveis › Acesso à rede › **Ativado**. Não há como mudar isso pela rede.
Fazer num momento em que ninguém esteja assistindo.

## Diferenças para LG e Samsung

- Sem pareamento nem token: qualquer aparelho na rede manda comando quando o modo está "Ativado".
- Não há print da tela; o estado se confere por `active-app`, `media-player` e `power-mode`.
- Não há leitura de volume (a Roku não expõe o nível atual pelo ECP).

## No Controle da TV (desde 14/10/2026)

- Driver em `servidor/roku.py`. A Roku entra na lista da casa sem pedir "Permitir"; se estiver em "Limitado",
  o assistente mostra o caminho acima e espera (até 10 min, só lendo). O painel e a página mostram o mesmo aviso e
  bloqueiam os botões até a TV ser liberada: nenhuma tecla sai daqui antes disso.
- Várias TVs por casa: `config.json` guarda todas em `tvs` e a escolhida de cada casa em `escolhidas`
  (`{roteador: id}`). Com duas ou mais, `/api/estado` traz `tvs` (nome, marca, ligada, escolhida) e o seletor aparece;
  `POST /api/tv {"id"}` troca, `{"id", "nome"}` renomeia e `{"id", "esquecer": true}` tira da lista.
- "Qual é esta TV?" (`acao: identificar`) deixa a TV muda por 2,5 s e volta ao som de antes (LG, Samsung e Roku).
