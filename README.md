<p align="center"><img src="docs/icone.png" width="128" alt=""></p>

<h1 align="center">Controle da TV</h1>

<p align="center">
Controle remoto da TV LG (webOS) ou Samsung (Tizen) na barra de menus do Mac · Remote control for LG webOS and Samsung Tizen TVs in the Mac menu bar · Control remoto de la TV LG (webOS) o Samsung (Tizen) en la barra de menús del Mac
</p>

<p align="center">
<a href="#português">Português</a> · <a href="#english">English</a> · <a href="#español">Español</a> · <a href="https://tv.didek.com.br">tv.didek.com.br</a>
</p>

> **Sem vínculo com a LG nem com a Samsung · Not affiliated with LG or Samsung · Sin vínculo con LG ni con Samsung.** Projeto independente e de código aberto. "LG" e "webOS" são marcas da LG Electronics Inc.; "Samsung" e "Tizen" são marcas da Samsung Electronics Co., Ltd.; as demais marcas pertencem aos seus donos. Veja os [Termos de Uso](TERMOS.md).

![Assistente de configuração](docs/assistente.png)

---

## Português

### O que é

Um app pequeno para Mac que transforma o computador num controle remoto da TV da casa (LG ou Samsung). Ele fica na barra de menus, perto do relógio, e conversa com a TV pela rede Wi-Fi de casa: sem cabos, sem conta e sem nuvem. Foi feito para uma pessoa idosa e pouco acostumada com tecnologia, então a primeira configuração é um assistente com desenhos, um passo por tela, e depois o app se atualiza sozinho.

O app, a página do celular e o site estão em **português, inglês e espanhol** (seguem o idioma do aparelho).

### O que faz

- Liga e desliga a TV (pela rede ou por Wake-on-LAN).
- Volume e mudo, troca de entrada (HDMI, TV ao vivo), setas, OK, Voltar e Início.
- Abre os apps da TV (Netflix, YouTube, Globoplay, Prime Video, Disney+…).
- Busca no YouTube pelo teclado do Mac e abre o vídeo direto na TV.
- Acha o PlayStation na rede (o mesmo anúncio que o app Remote Play usa), descobre em que entrada ele está e põe no painel um atalho para ir direto para ele.
- Página de controle para o celular, no navegador de qualquer aparelho da mesma rede.
- Assistente de primeira configuração: pasta Aplicativos, componentes, permissão de Rede Local, pareamento com a TV e abrir ao iniciar. Se faltar alguma permissão depois, ele avisa e reabre no passo certo.
- Uma TV por casa: o mesmo Mac controla a TV de casa e, por exemplo, a da casa dos pais; o app reconhece a casa pelo roteador. Para conectar mais uma TV, abra o app de novo (pela pasta Aplicativos) estando na rede da outra casa.
- Atualização automática assinada.

### TVs compatíveis

TVs LG com **webOS** (em geral, as smart TVs da LG desde 2014). Feito e testado com a **LG 50UK6510PSF** (2018, webOS 4.4). Para ligar a TV pela rede, ative no menu da TV: *Rede › LG Connect Apps*, *Geral › Mobile TV On › Ligar via Wi-Fi* e *Geral › Início Rápido+*.

TVs Samsung com **Tizen** (as smart TVs da Samsung desde 2016). Feito e testado com a **Samsung QN55QN85BAGXZD** (Neo QLED QN85B, 2022). Para ligar a TV pela rede, ative *Configurações › Geral › Rede › Configurações Especializadas › Ligar com Dispositivo Móvel*. Na mesma tela, **Controle Remoto IP** é opcional: com ele o app troca de entrada direto (HDMI 1 a 4 e TV ao vivo) e mostra qual está na tela; sem ele, o botão de entrada vai para o aparelho ligado no HDMI e há um atalho para o menu de entradas da TV. Nos modelos novos a TV não informa a lista de apps: o app confere na TV, um por um, os apps mais comuns (Netflix, YouTube, Globoplay, Prime Video, Disney+, HBO Max e outros).

### Instalar

Baixe o DMG em **https://tv.didek.com.br** e siga o passo a passo da página, ou, no Terminal:

```bash
curl -fsSL https://tv.didek.com.br/instalar.sh | bash
```

Requisitos: Mac com chip Apple (M1 ou mais novo), macOS 14 ou mais novo, Mac e TV na mesma rede.

### Como funciona

| Parte | O que faz |
|---|---|
| `macos/` | App SwiftUI de barra de menus (painel, assistente, atualizador). Compila só com as Command Line Tools, sem Xcode. |
| `servidor/` | Servidor local em Python (aiohttp, porta 8765) que fala com a LG pelo protocolo SSAP do webOS ([aiowebostv](https://github.com/home-assistant-libs/aiowebostv)) e com a Samsung pela API local do Tizen (`samsung.py`: teclas por websocket, apps pela API REST, volume por UPnP, Controle Remoto IP e o YouTube pelo mesmo caminho do "transmitir" do celular), liga a TV pela rede ou por Wake-on-LAN, procura a TV por mDNS/SSDP, faz as buscas no YouTube ([yt-dlp](https://github.com/yt-dlp/yt-dlp)) e serve a página do celular. |
| motor | O [uv](https://github.com/astral-sh/uv) vai dentro do app; na primeira abertura ele baixa o Python 3.13 e as bibliotecas para `~/Library/Application Support/Controle da TV/`. |
| `site/` | Página de download, termos de uso e instalador por Terminal. |
| `ferramentas/` | Ícone e fundo do DMG (desenhados em código), assinatura Ed25519, certificado, DMG, conferência de traduções. |

As chaves de pareamento com as TVs ficam só no Mac (arquivos com permissão 600) e nunca vão para o navegador.

**Atualização segura:** o app só instala uma versão nova se (1) o `versao.json` tiver assinatura Ed25519 válida, (2) o zip tiver o sha256 anunciado e (3) o app novo estiver assinado com o mesmo certificado e identificador. Como o certificado é estável, o macOS mantém as permissões (Rede Local, abrir ao iniciar) a cada atualização.

### Compilar

Precisa de macOS 14+ em Apple Silicon, Command Line Tools (`xcode-select --install`) e uv (`brew install uv`).

```bash
cp publicar.conf.exemplo publicar.conf   # opcional: identificador, frase de ajuda, site
./build.sh                               # gera build/Controle da TV.app
```

Na primeira vez, o `build.sh` cria um certificado de assinatura próprio num keychain separado, na pasta `SEGREDOS` (fora do repositório). Sem `SITE` no `publicar.conf`, o app compilado não procura atualizações.

### Publicar a sua própria distribuição

Preencha `SITE`, `CLOUDFLARE_CONTA` e `WORKER` no `publicar.conf`, faça login no [wrangler](https://developers.cloudflare.com/workers/wrangler/) e rode:

```bash
./publicar.sh 1.0.0 "o que mudou"
```

O script sobe a versão, compila, assina, gera zip, DMG, `versao.json` assinado, site e termos, e publica num Worker da Cloudflare com domínio próprio. **Guarde a pasta `SEGREDOS` em lugar seguro**: sem o certificado e a chave Ed25519, os apps já instalados não aceitam mais as suas atualizações.

### Licença e termos

Código sob a [licença MIT](LICENSE). Uso sujeito aos [Termos de Uso](TERMOS.md): sem garantia, sem vínculo com a LG, a Samsung ou outras marcas, sem coleta de dados.

Créditos: [aiowebostv](https://github.com/home-assistant-libs/aiowebostv), [aiohttp](https://github.com/aio-libs/aiohttp), [yt-dlp](https://github.com/yt-dlp/yt-dlp), [uv](https://github.com/astral-sh/uv), [dmgbuild](https://github.com/dmgbuild/dmgbuild). Paleta do painel inspirada no controle de ar-condicionado de [@YuriRDev](https://github.com/YuriRDev).

---

## English

### What it is

A small Mac app that turns your computer into a remote control for the TV at home (LG or Samsung). It lives in the menu bar, next to the clock, and talks to the TV over your home Wi-Fi: no cables, no account and no cloud. It was made for an elderly person who isn't comfortable with technology, so the first setup is a step-by-step assistant with drawings, one step per screen, and afterwards the app updates itself.

The app, the phone page and the website are available in **Portuguese, English and Spanish** (they follow the device language).

![Setup assistant in English and Spanish](docs/idiomas.png)

### What it does

- Turns the TV on and off (over the network or with Wake-on-LAN).
- Volume and mute, input switching (HDMI, live TV), arrows, OK, Back and Home.
- Opens TV apps (Netflix, YouTube, Prime Video, Disney+…).
- Searches YouTube with the Mac keyboard and opens the video right on the TV.
- Finds the PlayStation on the network (the same announcement the Remote Play app uses), works out which input it's on and adds a shortcut to it in the panel.
- Remote control page for your phone, in the browser of any device on the same network.
- First-run setup assistant: Applications folder, components, Local Network permission, TV pairing and open at login. If a permission goes missing later, it tells you and reopens at the right step.
- One TV per home: the same Mac controls the TV at home and, say, the one at your parents' place; the app recognizes each home by its router. To add another TV, open the app again (from the Applications folder) while on that home's network.
- Signed automatic updates.

### Compatible TVs

LG TVs running **webOS** (generally LG smart TVs from 2014 onward). Built and tested with the **LG 50UK6510PSF** (2018, webOS 4.4). To turn the TV on over the network, enable in the TV menu: *Network › LG Connect Apps*, *General › Mobile TV On › Turn on via Wi-Fi* and *General › Quick Start+*.

Samsung TVs running **Tizen** (Samsung smart TVs from 2016 onward). Built and tested with the **Samsung QN55QN85BAGXZD** (Neo QLED QN85B, 2022). To turn the TV on over the network, enable *Settings › General › Network › Expert Settings › Power On with Mobile*. On the same screen, **IP Remote** is optional: with it the app switches inputs directly (HDMI 1 to 4 and live TV) and shows which one is on screen; without it, the input button goes to the device plugged into HDMI and there is a shortcut to the TV's input menu. Newer models don't report the list of installed apps, so the app checks the most common ones on the TV one by one (Netflix, YouTube, Prime Video, Disney+, HBO Max and others).

### Install

Download the DMG at **https://tv.didek.com.br** and follow the steps on the page, or in Terminal:

```bash
curl -fsSL https://tv.didek.com.br/instalar.sh | bash
```

Requirements: a Mac with Apple silicon (M1 or newer), macOS 14 or newer, Mac and TV on the same network.

### How it works

- `macos/`: SwiftUI menu bar app (panel, setup assistant, updater). Builds with the Command Line Tools only, no Xcode.
- `servidor/`: local Python server (aiohttp, port 8765) that talks to LG over webOS SSAP ([aiowebostv](https://github.com/home-assistant-libs/aiowebostv)) and to Samsung over Tizen's local API (`samsung.py`: keys over websocket, apps over the REST API, volume over UPnP, IP Remote, and YouTube through the same path a phone uses to cast), wakes it over the network or with Wake-on-LAN, finds it via mDNS/SSDP, runs YouTube searches ([yt-dlp](https://github.com/yt-dlp/yt-dlp)) and serves the phone page.
- Engine: [uv](https://github.com/astral-sh/uv) ships inside the app; on first launch it downloads Python 3.13 and the libraries into `~/Library/Application Support/Controle da TV/`.
- `site/`: download page, terms of use and Terminal installer. `ferramentas/`: icon and DMG background (drawn in code), Ed25519 signing, certificate, DMG and translation checks.

The TV pairing keys stay on the Mac (files with mode 600) and never reach the browser. An update is installed only if the `versao.json` Ed25519 signature is valid, the zip matches the announced sha256 and the new app is signed with the same certificate and identifier.

### Build

Requires macOS 14+ on Apple silicon, the Command Line Tools (`xcode-select --install`) and uv (`brew install uv`).

```bash
cp publicar.conf.exemplo publicar.conf   # optional: bundle id, help sentence, site
./build.sh                               # creates build/Controle da TV.app
```

To run your own distribution, set `SITE`, `CLOUDFLARE_CONTA` and `WORKER` in `publicar.conf`, log in to [wrangler](https://developers.cloudflare.com/workers/wrangler/) and run `./publicar.sh 1.0.0 "what changed"`. Keep the `SEGREDOS` folder safe: without the certificate and the Ed25519 key, installed apps will no longer accept your updates.

### License and terms

Code under the [MIT License](LICENSE). Use is subject to the [Terms of Use](TERMOS.md): no warranty, no affiliation with LG, Samsung or other brands, no data collection.

---

## Español

### Qué es

Una pequeña app para Mac que convierte la computadora en un control remoto de la TV de la casa (LG o Samsung). Vive en la barra de menús, junto al reloj, y habla con la TV por el Wi-Fi de casa: sin cables, sin cuenta y sin nube. Se hizo para una persona mayor y poco acostumbrada a la tecnología, así que la primera configuración es un asistente con dibujos, un paso por pantalla, y después la app se actualiza sola.

La app, la página del teléfono y el sitio están en **portugués, inglés y español** (siguen el idioma del aparato).

### Qué hace

- Enciende y apaga la TV (por la red o con Wake-on-LAN).
- Volumen y silencio, cambio de entrada (HDMI, TV en vivo), flechas, OK, Atrás e Inicio.
- Abre las apps de la TV (Netflix, YouTube, Prime Video, Disney+…).
- Busca en YouTube con el teclado del Mac y abre el video directo en la TV.
- Encuentra la PlayStation en la red (el mismo anuncio que usa la app Remote Play), descubre en qué entrada está y pone en el panel un atajo para ir directo a ella.
- Página de control para el teléfono, en el navegador de cualquier aparato de la misma red.
- Una TV por casa: el mismo Mac controla la TV de casa y, por ejemplo, la de la casa de los padres; la app reconoce cada casa por el router. Para conectar otra TV, abre la app de nuevo (desde la carpeta Aplicaciones) estando en la red de esa casa.
- Asistente de primera configuración y actualización automática firmada.

### TVs compatibles

TVs LG con **webOS** (en general, las smart TV de LG desde 2014). Hecho y probado con la **LG 50UK6510PSF** (2018, webOS 4.4). Para encender la TV por la red, activa en el menú de la TV: *Red › LG Connect Apps*, *General › Mobile TV On › Encender por Wi-Fi* y *General › Inicio rápido+*.

TVs Samsung con **Tizen** (las smart TV de Samsung desde 2016). Hecho y probado con la **Samsung QN55QN85BAGXZD** (Neo QLED QN85B, 2022). Para encender la TV por la red, activa *Configuración › General › Red › Configuración experta › Encender con dispositivo móvil*. En la misma pantalla, **Control remoto IP** es opcional: con él la app cambia de entrada directamente (HDMI 1 a 4 y TV en vivo) y muestra cuál está en pantalla; sin él, el botón de entrada va al aparato conectado por HDMI y hay un atajo al menú de entradas de la TV. Los modelos nuevos no informan la lista de apps instaladas: la app comprueba en la TV, una por una, las más comunes (Netflix, YouTube, Prime Video, Disney+, HBO Max y otras).

### Instalar

Descarga el DMG en **https://tv.didek.com.br** y sigue los pasos de la página, o en la Terminal:

```bash
curl -fsSL https://tv.didek.com.br/instalar.sh | bash
```

Requisitos: Mac con chip de Apple (M1 o más nuevo), macOS 14 o más nuevo, Mac y TV en la misma red.

### Compilar y publicar

Requiere macOS 14+ en Apple silicon, las Command Line Tools y uv. `./build.sh` genera `build/Controle da TV.app`; `./publicar.sh 1.0.0 "qué cambió"` publica tu propia distribución (configura `publicar.conf` a partir de `publicar.conf.exemplo`). Guarda la carpeta `SEGREDOS` en un lugar seguro.

### Licencia y términos

Código bajo la [licencia MIT](LICENSE). El uso está sujeto a los [Términos de uso](TERMOS.md): sin garantía, sin vínculo con LG, Samsung ni con otras marcas, sin recolección de datos.
