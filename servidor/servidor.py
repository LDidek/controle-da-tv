"""Controle remoto web da TV (LG webOS, Samsung Tizen ou Roku TV). Roda no Mac; abre no Mac ou no celular pelo Wi-Fi de casa.

python servidor.py   →  http://<ip-do-mac>:8765
As chaves de pareamento ficam só aqui no servidor; o navegador nunca as recebe.

Os dados (config.json com as TVs de cada casa, reconhecida pelo roteador) ficam na pasta de
CONTROLE_TV_DADOS. Sem a variável, usa a mesma pasta do app (~/Library/Application Support/Controle da TV).
CONTROLE_TV_ROTEADOR diz em que casa o Mac está; o app também avisa pelo /api/casa quando a rede muda.
"""
import asyncio
import datetime
import ipaddress
import json
import logging
import os
import pathlib
import re
import socket
import time
from urllib.parse import urlsplit

import aiohttp
import yt_dlp
from aiohttp import web
from aiowebostv import WebOsClient
from aiowebostv import webos_client as _wc

import roku
import samsung

PORTA = int(os.environ.get("CONTROLE_TV_PORTA", "8765"))
PASTA = pathlib.Path(__file__).parent
DADOS = pathlib.Path(os.environ.get("CONTROLE_TV_DADOS")
                     or pathlib.Path.home() / "Library/Application Support/Controle da TV")
CHAVE = DADOS / "client-key"
CONFIG = DADOS / "config.json"
HOSTNAME_PADRAO = "LGwebOSTV.local"
SSDP_LG = "urn:lge-com:service:webos-second-screen:1"

BOTOES = {"UP", "DOWN", "LEFT", "RIGHT", "ENTER", "BACK", "HOME", "EXIT", "MENU", "INFO"}
YOUTUBE_APP = "youtube.leanback.v4"
ID_VIDEO = re.compile(r"[A-Za-z0-9_-]{11}")
MAC = re.compile(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}")
# O YouTube da TV tem teclado próprio (não aceita texto pela rede) e ignora link de busca;
# então a busca roda aqui no Mac e a TV só recebe o ID do vídeo escolhido.
OPCOES_YTDLP = {
    "quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True,
    "extractor_args": {"youtube": {"lang": ["pt"]}},
    "http_headers": {"Accept-Language": "pt-BR,pt;q=0.9"},
}
ENTRADAS_COMO_APP = ("com.webos.app.hdmi", "com.webos.app.externalinput")
# Formato antigo do config.json (uma TV LG só, campos soltos): continua valendo até a primeira gravação.
LEGADO = ("tv_ip", "tv_macs", "tv_mac", "tv_modelo", "tv_nome", "roteador", "pareado_em")
roteador_atual = (os.environ.get("CONTROLE_TV_ROTEADOR") or "").strip().lower() or None


# MARK: configuração


def ler_config():
    try:
        return json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return {}


def gravar_privado(caminho, texto):
    """Grava com permissão 600 e troca de uma vez (nunca deixa o arquivo pela metade)."""
    DADOS.mkdir(parents=True, exist_ok=True)
    tmp = caminho.with_name(caminho.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(texto)
    tmp.replace(caminho)


def tvs_salvas():
    """Todas as TVs, de todas as casas: [{marca, id, roteador, tv_ip, tv_macs, tv_modelo, chave, …}]."""
    cfg = ler_config()
    if isinstance(cfg.get("tvs"), list):
        return [t for t in cfg["tvs"] if isinstance(t, dict)]
    if any(cfg.get(k) for k in LEGADO):
        return [{**{k: cfg[k] for k in LEGADO if k in cfg}, "marca": "lg"}]
    return []


def gravar_tvs(tvs):
    gravar_config(tvs=tvs)


def gravar_config(**campos):
    cfg = {k: v for k, v in ler_config().items() if k not in LEGADO}
    cfg.update(campos)
    gravar_privado(CONFIG, json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")


def da_casa(t, roteador):
    return str(t.get("roteador") or "").lower() == str(roteador or "").lower()


def ident(t):
    """Quem é a TV: o id que ela informa ou, na LG pareada antes disso, o endereço físico (ou o IP)."""
    macs = macs_da(t)
    return str((t or {}).get("id") or (macs[0] if macs else None) or (t or {}).get("tv_ip") or "")


def mesma_tv(a, b):
    if a.get("marca", "lg") != b.get("marca", "lg"):
        return False
    if ident(a) == ident(b) or set(macs_da(a)) & set(macs_da(b)):
        return True
    return not a.get("id") and bool(a.get("tv_ip")) and a.get("tv_ip") == b.get("tv_ip")


def tvs_da_casa(roteador=None):
    """As TVs da casa onde o Mac está (várias: sala, quarto…). Sem saber a casa (servidor aberto à mão), todas."""
    r = roteador or roteador_atual
    tvs = tvs_salvas()
    return [t for t in tvs if da_casa(t, r)] if r else tvs


def chave_da_casa(roteador=None):
    r = roteador or roteador_atual
    return str(r or "").lower()


def tv_salva(roteador=None):
    """A TV escolhida na casa onde o Mac está; com uma só, ela. A escolha fica em "escolhidas" no config.json."""
    lista = tvs_da_casa(roteador)
    quero = (ler_config().get("escolhidas") or {}).get(chave_da_casa(roteador))
    return next((t for t in lista if ident(t) == quero), lista[0] if lista else None)


def tv_por_ident(roteador, quem):
    return next((t for t in tvs_da_casa(roteador) if ident(t) == quem), None)


def escolher_tv(roteador, quem):
    escolhidas = dict(ler_config().get("escolhidas") or {})
    escolhidas[chave_da_casa(roteador)] = quem
    gravar_config(escolhidas=escolhidas)


def nome_da_tv(t):
    """Como a TV aparece no seletor: o nome dado aqui, o cômodo que a TV informa ou o nome dela."""
    padrao = {"samsung": "TV Samsung", "roku": "TV Roku"}.get(t.get("marca"), "TV LG")
    return t.get("apelido") or t.get("local") or t.get("nome") or padrao


def pareada(t):
    return bool(t) and (t.get("marca") == "roku" or chave_da(t) is not None)  # a Roku não pede pareamento


def atualizar_tv(roteador, novos, quem=None):
    """Grava campos numa TV da casa (a TV pegou outro IP, token novo…). Sem `quem`, na primeira da casa."""
    tvs = tvs_salvas()
    for t in tvs:
        if da_casa(t, roteador) and (quem is None or ident(t) == quem):
            if not t.get("id"):
                t["id"] = ident(t)  # fixa quem ela é: o IP pode mudar logo abaixo
            t.update({k: v for k, v in novos.items() if v is not None})
            gravar_tvs(tvs)
            return


def guardar_tv_pareada(roteador, nova):
    """Depois do pareamento: a mesma TV mantém o que já tinha (nome da entrada, apps, apelido); outra TV
    entra na lista da casa ao lado das que já existem. A recém-pareada vira a escolhida."""
    tvs = tvs_salvas()
    nova = {k: v for k, v in nova.items() if v is not None}
    nova["id"] = ident(nova)
    for i, t in enumerate(tvs):
        if da_casa(t, roteador) and mesma_tv(t, nova):
            tvs[i] = {**t, **nova}
            break
    else:
        tvs.append(nova)
    gravar_tvs(tvs)
    escolher_tv(roteador, nova["id"])


def chave_da(t):
    """Token de pareamento. A LG pareada antes das várias casas guarda a chave no arquivo client-key."""
    if not t:
        return None
    if t.get("chave"):
        return t["chave"]
    if t.get("marca", "lg") == "lg":
        try:
            return CHAVE.read_text().strip() or None
        except OSError:
            return None
    return None


def macs_da(t):
    macs = (t or {}).get("tv_macs") or ([t["tv_mac"]] if (t or {}).get("tv_mac") else [])
    return [m.lower() for m in macs if isinstance(m, str) and MAC.fullmatch(m.lower())]


# MARK: achar a TV na rede


def resolver(nome):
    try:
        return socket.gethostbyname(nome)
    except OSError:
        return None


def ssdp_procurar(espera=2.5):
    """Pergunta na rede quem é TV LG (o mesmo anúncio que o app da LG usa). Devolve os IPs."""
    pedido = (
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
        f"MX: 2\r\nST: {SSDP_LG}\r\n\r\n"
    ).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(0.4)
    achados = []
    try:
        for _ in range(2):
            s.sendto(pedido, ("239.255.255.250", 1900))
        fim = time.time() + espera
        while time.time() < fim:
            try:
                dados, (ip, _porta) = s.recvfrom(4096)
            except socket.timeout:
                continue
            texto = dados.decode(errors="ignore").lower()
            if "webos" in texto or "lge" in texto or "lg electronics" in texto:
                if ip not in achados:
                    achados.append(ip)
    except OSError:
        pass
    finally:
        s.close()
    return achados


async def porta_aberta(ip, timeout=1.0):
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(ip, 3000), timeout)
        w.close()
        return True
    except (OSError, asyncio.TimeoutError):
        return False


async def candidatos(t):
    lista = []
    nome = (t or {}).get("tv_nome") or HOSTNAME_PADRAO
    try:  # numa rede sem TV LG o nome demora 5 s para dar erro
        ip_nome = await asyncio.wait_for(asyncio.get_running_loop().run_in_executor(None, resolver, nome), 2)
    except asyncio.TimeoutError:
        ip_nome = None
    for ip in (ip_nome, (t or {}).get("tv_ip")):
        if ip and ip not in lista:
            lista.append(ip)
    return lista


async def achar_tv(t, procurar=False):
    """IP da TV LG ligada (porta 3000 respondendo) ou None. Com procurar=True, também pergunta na rede (SSDP)."""
    lista = await candidatos(t)
    for ip in lista:
        if await porta_aberta(ip):
            return ip
    if procurar:
        for ip in await asyncio.get_running_loop().run_in_executor(None, ssdp_procurar):
            if ip not in lista and await porta_aberta(ip):
                return ip
    return None


# MARK: videogame na TV (PlayStation se anuncia na rede como faz para o app Remote Play)

CONSOLES = {"PS5": "PlayStation 5", "PS4": "PlayStation 4"}
EH_CONSOLE = re.compile(r"playstation|\bps ?[345]\b|xbox", re.I)
console_visto = {"em": 0.0, "dados": None}


def procurar_console(espera=1.5):
    """{"tipo": "PS5", "nome": "PS5 da casa", "ligado": True} ou None. Em repouso ele responde 620."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.3)
    try:
        for porta, versao in ((9302, "00030010"), (987, "00020020")):
            pedido = f"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:{versao}\n".encode()
            try:
                s.sendto(pedido, ("255.255.255.255", porta))
            except OSError:
                pass
        fim = time.time() + espera
        while time.time() < fim:
            try:
                dados, _ = s.recvfrom(2048)
            except socket.timeout:
                continue
            linhas = dados.decode(errors="ignore").splitlines()
            campos = dict(l.split(":", 1) for l in linhas[1:] if ":" in l)
            tipo = campos.get("host-type", "").strip().upper()
            if tipo in CONSOLES:
                return {"tipo": tipo, "nome": campos.get("host-name", "").strip() or CONSOLES[tipo],
                        "ligado": " 200 " in f" {linhas[0]} "}
    except OSError:
        pass
    finally:
        s.close()
    return None


def console_da_rede():
    """O que a última procura achou; procura de novo em segundo plano, no máximo uma vez por minuto."""
    if time.time() - console_visto["em"] > 60:
        console_visto["em"] = time.time()

        async def procurar_agora():
            console_visto["dados"] = await asyncio.get_running_loop().run_in_executor(None, procurar_console)

        console_visto["tarefa"] = asyncio.create_task(procurar_agora())
    return console_visto["dados"]


def marcar_console(estado, achado):
    """Em que entrada está o videogame: a que tem o nome dele ou, com um só aparelho ligado, essa.
    O painel ganha o atalho "ir para o videogame"; a entrada passa a se chamar PlayStation 5."""
    entradas = [dict(e) for e in estado.get("entradas") or []]
    alvo = next((e for e in entradas if EH_CONSOLE.search(e.get("nome") or "")), None)
    if alvo is None and achado:
        conectadas = [e for e in entradas if e.get("conectado")]
        if len(conectadas) == 1:
            alvo = conectadas[0]
            alvo["nome"] = CONSOLES[achado["tipo"]]
    if alvo is None:
        return estado
    console = {"entrada": alvo["id"], "nome": alvo["nome"],
               "tipo": (achado or {}).get("tipo") or ("XBOX" if "xbox" in alvo["nome"].lower() else "PS"),
               "ligado": (achado or {}).get("ligado")}
    estado = {**estado, "entradas": entradas, "console": console}
    if estado.get("app_atual") == alvo.get("app"):
        estado["app_titulo"] = alvo["nome"]
    return estado


# MARK: conexão com a TV


class TVLG:
    marca = "lg"

    def __init__(self, salva, atualizar):
        self._salva = salva
        self._atualizar = atualizar
        self.cliente = None
        self.trava = asyncio.Lock()
        self.ip = None
        self.ligando_ate = 0.0
        self.ultima_procura = 0.0

    def salva(self):
        return self._salva() or {}

    def pareado(self):
        return chave_da(self._salva()) is not None

    def conectado(self):
        return self.cliente is not None and self.cliente.is_connected()

    async def obter(self):
        """Devolve um cliente conectado, ou None se a TV estiver desligada (ou ainda sem pareamento)."""
        async with self.trava:
            if self.conectado():
                return self.cliente
            chave = chave_da(self._salva())
            if not chave:
                return None
            # Procura na rede (SSDP) no máximo a cada 30 s, para não pesar com a TV desligada.
            procurar = time.time() - self.ultima_procura > 30
            if procurar:
                self.ultima_procura = time.time()
            ip = await achar_tv(self.salva(), procurar=procurar)
            if ip is None:
                return None
            self.ip = ip
            if self.salva().get("tv_ip") != ip:
                self._atualizar({"tv_ip": ip})  # a TV pegou outro IP do roteador
            await self.descartar()
            cliente = WebOsClient(ip, client_key=chave)
            await asyncio.wait_for(cliente.connect(), 10)
            self.cliente = cliente
            return cliente

    async def descartar(self):
        if self.cliente is not None:
            try:
                await self.cliente.disconnect()
            except Exception:
                pass
            self.cliente = None

    async def ligar(self):
        await asyncio.get_running_loop().run_in_executor(None, self._ligar)

    def _ligar(self):
        ip = self.ip or self.salva().get("tv_ip")
        destinos = ["255.255.255.255"]
        if ip:
            destinos += [ip.rsplit(".", 1)[0] + ".255", ip]
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        # Manda para os dois endereços físicos (Wi-Fi e cabo): serve a placa que a TV estiver usando.
        for mac in macs_da(self.salva()):
            pacote = bytes.fromhex("ff" * 6 + mac.replace(":", "") * 16)
            for destino in destinos:
                for porta in (9, 7):
                    for _ in range(3):
                        try:
                            s.sendto(pacote, (destino, porta))
                        except OSError:
                            pass
        s.close()
        self.ligando_ate = time.time() + 40

    async def estado(self):
        try:
            cliente = await self.obter()
        except Exception:
            await self.descartar()
            cliente = None
        if cliente is None:
            return {"online": False, "pareado": self.pareado(), "ligando": time.time() < self.ligando_ate,
                    "marca": self.marca, "nome": self.salva().get("nome")}
        return {**resumo(cliente), "marca": self.marca, "nome": self.salva().get("nome")}

    async def agir(self, nome, valor):
        for tentativa in (1, 2):
            cliente = await self.obter()
            if cliente is None:
                raise samsung.TVDesligada()
            try:
                await executar(cliente, nome, valor)
                if nome == "desligar":
                    await self.descartar()
                return
            except web.HTTPException:
                raise
            except Exception:
                await self.descartar()
                if tentativa == 2:
                    raise

    async def identificar(self):
        """Muda o som por um instante e volta ao que era: quem está na frente da TV certa ouve a pausa."""
        cliente = await self.obter()
        if cliente is None:
            raise samsung.TVDesligada()
        antes = bool(cliente.tv_state.muted)
        await cliente.set_mute(not antes)
        try:
            await asyncio.sleep(2.5)
        finally:
            await cliente.set_mute(antes)

    async def icone(self, app_id):
        cliente = await self.obter()
        dados = (cliente.tv_state.apps or {}).get(app_id) if cliente else None
        url = dados and (dados.get("largeIcon") or dados.get("icon"))
        if not url:
            return None
        async with aiohttp.ClientSession() as s, s.get(url, timeout=aiohttp.ClientTimeout(total=5)) as r:
            return await r.read() if r.status == 200 else None


class Gerente:
    """Qual TV atender: a escolhida na casa onde o Mac está agora."""

    def __init__(self):
        self.atual = None
        self.chave = None
        # Cada TV da casa fica com a conexão aberta e a última leitura guardada: trocar de TV não recomeça do zero.
        self.guardadas = {}

    def guardar(self, t):
        """A conexão desta TV (cria na primeira vez). Não muda qual TV o controle está usando."""
        roteador, quem = t.get("roteador"), ident(t)
        chave = (t.get("marca", "lg"), str(roteador), quem)
        if chave not in self.guardadas:
            classe = {"samsung": samsung.TVSamsung, "roku": roku.TVRoku}.get(chave[0], TVLG)
            self.guardadas[chave] = classe(lambda: tv_por_ident(roteador, quem),
                                           lambda novos: atualizar_tv(roteador, novos, quem))
        return chave, self.guardadas[chave]

    def tv(self):
        t = tv_salva()
        if t is None:
            return None
        chave, guardada = self.guardar(t)
        if self.atual is None or chave != self.chave:
            if self.atual is not None and self.atual not in self.guardadas.values():
                asyncio.create_task(self.atual.descartar())
            self.atual, self.chave = guardada, chave
        return self.atual

    async def descartar(self):
        for tv in {id(x): x for x in [self.atual, *self.guardadas.values()] if x is not None}.values():
            await tv.descartar()
        self.guardadas.clear()
        self.atual = self.chave = None


gerente = Gerente()
icones = {}


# MARK: pareamento (primeira vez: a TV mostra um pedido e a pessoa aceita no controle remoto)


class Pareamento:
    def __init__(self):
        self.estado = "parado"  # parado, procurando, conferindo, esperando, esperando_ip, liberar, pareado, erro
        self.erro = None
        self.tarefa = None
        self.marca = None

    def json(self):
        return {"estado": self.estado, "erro": self.erro, "marca": self.marca, "pareado": pareada(tv_salva()),
                "liberar": roku.LIBERAR if self.estado == "liberar" else None}


par = Pareamento()


async def achar_qualquer_tv(nova=False):
    """A TV ligada nesta rede, de qualquer marca: (marca, ip, info) ou None. A já escolhida vem primeiro.
    Com nova=True (mais uma TV na mesma casa), só vale uma que ainda não está salva aqui."""
    t = None if nova else tv_salva()
    salvas = tvs_da_casa() if nova else []
    ids = {ident(x) for x in salvas}
    async with aiohttp.ClientSession() as sessao:
        if t is not None and t.get("marca") == "samsung":
            ip, info = await samsung.procurar(sessao, [t.get("tv_ip")])
            if samsung.energia(info) == "on":
                return "samsung", ip, info
        if t is not None and t.get("marca") == "roku" and t.get("tv_ip"):
            info = await roku.ler_info(sessao, t["tv_ip"])
            if info and roku.id_da(info) == ident(t):
                return "roku", t["tv_ip"], info
        lg, (ip_s, info_s), rokus = await asyncio.gather(
            achar_tv(t if (t or {}).get("marca", "lg") == "lg" else None, procurar=True),
            samsung.procurar(sessao, []),
            roku.procurar(sessao, [], ignorar=ids))
        if lg and not any(x.get("marca", "lg") == "lg" and x.get("tv_ip") == lg for x in salvas):
            return "lg", lg, None
        if samsung.energia(info_s) == "on" and samsung.dados_da_tv(ip_s, info_s)["id"] not in ids:
            return "samsung", ip_s, info_s
        # A Roku responde mesmo com a tela apagada ("Início rápido"): a ligada vem antes.
        rokus.sort(key=lambda r: roku.energia(r[1]) != "on")
        if rokus:
            return ("roku",) + rokus[0]
    return None


async def parear(roteador, nova=False):
    global roteador_atual
    par.erro = None
    par.marca = None
    par.estado = "procurando"
    if roteador and MAC.fullmatch(str(roteador).lower()):
        roteador = roteador_atual = str(roteador).lower()  # o pareamento acontece na rede onde o Mac está
    else:
        roteador = roteador_atual
    try:
        achada = None
        for _ in range(4):  # logo depois de abrir, a primeira tentativa na rede às vezes falha
            achada = await achar_qualquer_tv(nova)
            if achada:
                break
            await asyncio.sleep(1.5)
        if achada is None:
            par.estado, par.erro = "erro", ("Não encontrei outra TV ligada na rede. Ligue a TV nova e tente de novo."
                                            if nova else "Não encontrei a TV ligada na rede. Ligue a TV e tente de novo.")
            return
        marca, ip, info = achada
        par.marca = marca
        if marca == "samsung":
            await parear_samsung(ip, info, roteador)
        elif marca == "roku":
            await parear_roku(ip, info, roteador)
        else:
            await parear_lg(ip, roteador)
        await gerente.descartar()
        par.estado = "pareado"
        if marca == "samsung":
            tv = gerente.tv()
            if tv is not None:
                tv.em_segundo_plano(tv.conferir_apps())
    except asyncio.TimeoutError:
        par.estado, par.erro = "erro", ("O tempo acabou antes de permitir na TV. Tente de novo." if par.marca == "samsung"
                                        else "O tempo acabou antes de aceitar na TV. Tente de novo.")
    except PermissionError:
        par.estado, par.erro = "erro", "A TV recusou o pedido. Tente de novo e escolha Permitir."
    except Exception as e:
        texto = str(e).lower()
        if "denied" in texto or "reject" in texto or "cancel" in texto or "403" in texto:
            par.estado, par.erro = "erro", "A TV recusou o pedido. Tente de novo e escolha Aceitar."
        else:
            logging.getLogger("pareamento").warning("falhou: %s", samsung.sem_segredo(repr(e)))
            par.estado, par.erro = "erro", "Não consegui conectar na TV."


async def parear_lg(ip, roteador):
    lgs = [t for t in tvs_da_casa(roteador) if t.get("marca", "lg") == "lg"] if roteador else []
    salva = next((t for t in lgs if t.get("tv_ip") == ip), lgs[0] if len(lgs) == 1 else None)
    chave = chave_da(salva)
    par.estado = "conferindo" if chave else "esperando"
    cliente = None
    espera_original = _wc.RECEIVE_TIMEOUT
    try:
        # A aiowebostv dá só 10 s para aceitar o pedido na TV; para quem vai procurar o controle, 90 s.
        _wc.RECEIVE_TIMEOUT = 90
        cliente = WebOsClient(ip, client_key=chave)
        conexao = asyncio.create_task(cliente.connect())
        try:
            await asyncio.wait_for(asyncio.shield(conexao), 4)
        except asyncio.TimeoutError:
            par.estado = "esperando"  # a TV está mostrando o pedido: falta aceitar no controle
            await asyncio.wait_for(conexao, 100)
        _wc.RECEIVE_TIMEOUT = espera_original
        nova = cliente.client_key
        if not nova:
            raise RuntimeError("a TV não devolveu a chave")
        macs = []
        try:
            info = await cliente.request("com.webos.service.connectionmanager/getinfo")
            for tipo in ("wifiInfo", "wiredInfo"):
                mac = str((info.get(tipo) or {}).get("macAddress") or "").lower()
                if MAC.fullmatch(mac):
                    macs.append(mac)
        except Exception:
            pass
        guardar_tv_pareada(roteador, {
            "marca": "lg",
            "chave": nova,
            "tv_ip": ip,
            "tv_macs": macs or None,
            "tv_modelo": (cliente.tv_info.system or {}).get("modelName"),
            "roteador": roteador,
            "pareado_em": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        })
    finally:
        _wc.RECEIVE_TIMEOUT = espera_original
        if cliente is not None:
            try:
                await cliente.disconnect()
            except Exception:
                pass


async def parear_samsung(ip, info, roteador):
    dados = samsung.dados_da_tv(ip, info)
    salva = next((t for t in tvs_da_casa(roteador) if t.get("marca") == "samsung" and t.get("id") == dados["id"]),
                 None) if roteador else None
    token = chave_da(salva)
    par.estado = "conferindo" if token else "esperando"

    def esperando():
        par.estado = "esperando"

    async with aiohttp.ClientSession() as sessao:
        ws, novo = await samsung.conectar(sessao, ip, token, espera_primeira=4, ao_esperar=esperando)
        await ws.close()
        if not novo:
            raise RuntimeError("a TV não devolveu o token")
        guardar_tv_pareada(roteador, {
            **dados,
            "chave": novo,
            "roteador": roteador,
            "pareado_em": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        })
        # Extra: com o Controle Remoto IP ligado na TV, um segundo "Permitir" libera a troca direta de entrada.
        if await samsung.porta_ip_aberta(ip):
            par.estado = "esperando_ip"
            try:
                token_ip = await samsung.parear_ip(sessao, ip)
                if token_ip:
                    atualizar_tv(roteador, {"chave_ip": token_ip}, dados["id"])
            except Exception as e:
                logging.getLogger("pareamento").warning("Controle Remoto IP não pareou: %s", samsung.sem_segredo(repr(e)))


async def parear_roku(ip, info, roteador):
    """A Roku não pede "Permitir": entra na lista na hora. Se o controle pela rede estiver "Limitado", espera
    (até 10 min, só lendo) alguém liberar no controle físico; o assistente mostra o caminho enquanto isso."""
    guardar_tv_pareada(roteador, {
        **roku.dados_da_tv(ip, info),
        "roteador": roteador,
        "pareado_em": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    })
    if not roku.limitada(info):
        return
    par.estado = "liberar"
    async with aiohttp.ClientSession() as sessao:
        fim = time.time() + 600
        while time.time() < fim:
            await asyncio.sleep(3)
            atual = await roku.ler_info(sessao, ip)
            if atual and not roku.limitada(atual):
                return


async def parear_iniciar(req):
    try:
        dados = await req.json()
    except Exception:
        dados = {}
    if par.tarefa is None or par.tarefa.done():
        par.tarefa = asyncio.create_task(parear(dados.get("roteador"), bool(dados.get("nova"))))
        await asyncio.sleep(0)
    return web.json_response(par.json())


async def parear_estado(_req):
    return web.json_response(par.json())


async def procurar(req):
    achada = await achar_qualquer_tv(req.query.get("nova") == "1")
    return web.json_response({"encontrada": achada is not None, "ip": achada and achada[1],
                              "marca": achada and achada[0], "pareado": pareada(tv_salva())})


async def casa(req):
    """O app avisa em que rede o Mac está (pelo roteador): define qual TV atender."""
    global roteador_atual
    try:
        dados = await req.json()
    except Exception:
        dados = {}
    r = str(dados.get("roteador") or "").lower()
    if MAC.fullmatch(r) and r != roteador_atual:
        logging.getLogger("casa").info("rede: roteador %s", r)
        roteador_atual = r
    return web.json_response({"ok": True, "tv": tv_salva() is not None})


async def saude(_req):
    return web.json_response({"ok": True, "pareado": pareada(tv_salva())})


# MARK: estado e ações


def resumo(cliente):
    t = cliente.tv_state
    apps = []
    for a in (t.apps or {}).values():
        if a["id"].startswith(ENTRADAS_COMO_APP):
            continue
        apps.append({
            "id": a["id"],
            "titulo": a.get("title", a["id"]),
            "sistema": bool(a.get("systemApp")),
            "cor": a.get("iconColor") or a.get("bgColor"),
        })
    apps.sort(key=lambda a: a["titulo"].lower())
    entradas = [{
        "id": i["id"],
        "nome": i.get("label", i["id"]),
        "conectado": bool(i.get("connected")),
        "app": i.get("appId"),
    } for i in (t.inputs or {}).values()]
    entradas.sort(key=lambda e: e["id"])
    atual = t.current_app_id
    titulo = (t.apps or {}).get(atual, {}).get("title") or next(
        (e["nome"] for e in entradas if e["app"] == atual), atual)
    return {
        "online": True,
        "pareado": True,
        "ligada": bool(t.is_on),
        "app_atual": atual,
        "app_titulo": titulo,
        "volume": t.volume,
        "mudo": bool(t.muted),
        "som": t.sound_output,
        "canal": (t.current_channel or {}).get("channelNumber"),
        "canal_nome": (t.current_channel or {}).get("channelName"),
        "entradas": entradas,
        "apps": apps,
    }


vistas = {}  # outras TVs da casa: {ident: {"ligada": bool | None, "em": quando foi conferida}}


async def ligada_agora(t):
    """Pela conexão guardada da TV (a mesma fila de pedidos: a Samsung engasga com pedidos em paralelo).
    A Samsung nunca lida é lida uma vez inteira agora: assim a primeira troca para ela já sai na hora."""
    _chave, tv = gerente.guardar(t)
    if isinstance(tv, samsung.TVSamsung):
        if tv.foto is None:
            return bool((await tv.estado()).get("online"))
        _ip, info = await tv.info()
        return samsung.energia(info) == "on"
    if isinstance(tv, roku.TVRoku):
        _ip, info = await tv.info()
        return roku.energia(info) == "on"
    return await ver_tv(t)


async def ver_tv(t):
    """Se a TV está ligada, só lendo (nada aparece na tela)."""
    ip, marca = t.get("tv_ip"), t.get("marca", "lg")
    if not ip:
        return None
    if marca == "lg":
        return await porta_aberta(ip, 0.8)
    async with aiohttp.ClientSession() as sessao:
        if marca == "samsung":
            return samsung.energia(await samsung.ler_info(sessao, ip, 1.5)) == "on"
        return roku.energia(await roku.ler_info(sessao, ip, 1.5)) == "on"


def lista_de_tvs(escolhida, online):
    """Para o seletor (só com duas TVs ou mais na casa). As outras são conferidas em segundo plano,
    no máximo a cada 15 s cada uma: a escolhida já foi lida agora."""
    lista = tvs_da_casa()
    if len(lista) < 2:
        return None
    agora, minha = time.time(), ident(escolhida)
    saida = []
    for t in lista:
        quem = ident(t)
        if quem == minha:
            ligada = online
        else:
            v = vistas.get(quem)
            if v is None or agora - v["em"] > 15:
                vistas[quem] = {"ligada": (v or {}).get("ligada"), "em": agora}

                async def conferir(quem=quem, t=t):
                    try:
                        vistas[quem]["ligada"] = await ligada_agora(t)
                    except Exception:
                        vistas[quem]["ligada"] = None
                asyncio.create_task(conferir())
            ligada = vistas[quem]["ligada"]
        saida.append({"id": quem, "nome": nome_da_tv(t), "marca": t.get("marca", "lg"),
                      "ligada": ligada, "escolhida": quem == minha})
    return saida


async def estado(_req):
    tv = gerente.tv()
    if tv is None:
        return web.json_response({"online": False, "pareado": False})
    resposta = await tv.estado()
    if resposta.get("online"):
        resposta = marcar_console(resposta, console_da_rede())
    tvs = lista_de_tvs(tv_salva(), bool(resposta.get("online")))
    if tvs:
        resposta["tvs"] = tvs
        resposta["tv_titulo"] = nome_da_tv(tv_salva())
    return web.json_response(resposta)


async def executar(cliente, acao, valor):
    if acao == "desligar":
        await cliente.power_off()
    elif acao == "botao":
        if valor not in BOTOES:
            raise web.HTTPBadRequest(text="botão inválido")
        await cliente.button(valor)
    elif acao == "volume":
        await cliente.set_volume(max(0, min(100, int(valor))))
    elif acao == "volume_mais":
        await cliente.volume_up()
    elif acao == "volume_menos":
        await cliente.volume_down()
    elif acao == "mudo":
        await cliente.set_mute(not cliente.tv_state.muted)
    elif acao == "entrada":
        await cliente.set_input(str(valor))
    elif acao == "app":
        await cliente.launch_app(str(valor))
    elif acao == "canal_mais":
        await cliente.channel_up()
    elif acao == "canal_menos":
        await cliente.channel_down()
    elif acao == "youtube":
        if not ID_VIDEO.fullmatch(str(valor)):
            raise web.HTTPBadRequest(text="vídeo inválido")
        await cliente.request("system.launcher/launch", {"id": YOUTUBE_APP, "contentId": str(valor)})
    elif acao == "texto":
        await cliente.request("com.webos.service.ime/insertText", {"text": str(valor)[:500], "replace": False})
    elif acao == "apagar":
        await cliente.request("com.webos.service.ime/deleteCharacters", {"count": max(1, min(500, int(valor)))})
    elif acao == "enter":
        await cliente.request("com.webos.service.ime/sendEnterKey")
    elif acao in ("play", "pause", "stop", "rewind", "fast_forward"):
        await getattr(cliente, acao)()
    else:
        raise web.HTTPBadRequest(text="ação desconhecida")


async def acao(req):
    dados = await req.json()
    nome, valor = dados.get("acao"), dados.get("valor")
    tv = gerente.tv()
    if tv is None:
        return web.json_response({"ok": False, "erro": "Nenhuma TV configurada nesta casa."}, status=409)
    try:
        if nome == "ligar":
            await tv.ligar()
        elif nome == "identificar":
            await tv.identificar()
        else:
            await tv.agir(nome, valor)
        return web.json_response({"ok": True})
    except samsung.TVDesligada:
        return web.json_response({"ok": False, "erro": "A TV está desligada."}, status=409)
    except roku.Limitada:
        return web.json_response({"ok": False, "limitada": True, "erro": ERRO_LIMITADA}, status=409)
    except web.HTTPException:
        raise
    except (ValueError, TypeError) as e:
        return web.json_response({"ok": False, "erro": samsung.sem_segredo(e)}, status=400)
    except Exception as e:
        # O detalhe (que pode trazer endereço e token) fica só no log, limpo; quem pediu recebe uma frase.
        logging.getLogger("acao").warning("%s falhou: %s", nome, samsung.sem_segredo(repr(e)))
        return web.json_response({"ok": False, "erro": "Não funcionou, tenta de novo"}, status=502)


ERRO_LIMITADA = ("Esta TV ainda não aceita comandos pela rede. Na TV, com o controle: " + roku.LIBERAR + ".")


async def tv_escolher(req):
    """{"id"}: passa a controlar essa TV. Com "nome": renomeia (vazio volta ao nome da TV). Com "esquecer": tira da lista."""
    dados = await req.json()
    quem = str(dados.get("id") or "")
    t = tv_por_ident(None, quem)
    if t is None:
        return web.json_response({"ok": False, "erro": "Essa TV não está nesta casa."}, status=404)
    if dados.get("esquecer"):
        restantes = [x for x in tvs_salvas() if not (da_casa(x, t.get("roteador")) and ident(x) == quem)]
        if not any(da_casa(x, t.get("roteador")) for x in restantes):
            return web.json_response({"ok": False, "erro": "É a única TV desta casa."}, status=409)
        gravar_tvs(restantes)
    elif "nome" in dados:
        nome = str(dados.get("nome") or "").strip()[:30]
        tvs = tvs_salvas()
        for x in tvs:
            if da_casa(x, t.get("roteador")) and ident(x) == quem:
                x["id"] = quem
                if nome:
                    x["apelido"] = nome
                else:
                    x.pop("apelido", None)
        gravar_tvs(tvs)
    else:
        escolher_tv(None, quem)
    return web.json_response({"ok": True})


def buscar_youtube(termo):
    with yt_dlp.YoutubeDL(OPCOES_YTDLP) as ydl:
        resultado = ydl.extract_info(f"ytsearch12:{termo}", download=False)
    videos = []
    for e in resultado.get("entries") or []:
        if not e or not ID_VIDEO.fullmatch(e.get("id") or ""):
            continue
        videos.append({
            "id": e["id"],
            "titulo": e.get("title") or "",
            "canal": e.get("channel") or e.get("uploader") or "",
            "duracao": e.get("duration"),
            "ao_vivo": e.get("live_status") == "is_live",
        })
    return videos


async def youtube_busca(req):
    termo = req.query.get("q", "").strip()[:120]
    if not termo:
        return web.json_response([])
    try:
        videos = await asyncio.get_running_loop().run_in_executor(None, buscar_youtube, termo)
    except Exception as e:
        return web.json_response({"erro": f"Busca falhou: {e}"}, status=502)
    return web.json_response(videos)


async def icone(req):
    app_id = req.match_info["app_id"]
    if app_id not in icones:
        # Primeiro a TV escolhida; logo depois de uma troca o pedido pode ser de um app da outra TV da casa.
        tv = gerente.tv()
        imagem = None
        for candidata in ([tv] if tv is not None else []) + [x for x in gerente.guardadas.values() if x is not tv]:
            imagem = await candidata.icone(app_id)
            if imagem:
                break
        if not imagem:
            raise web.HTTPNotFound()
        icones[app_id] = imagem
    return web.Response(body=icones[app_id], content_type="image/png",
                        headers={"Cache-Control": "max-age=86400"})


async def pagina(_req):
    return web.FileResponse(PASTA / "index.html", headers={"Cache-Control": "no-cache"})


async def vigiar_pai(app):
    """Encerra junto com quem abriu o servidor (app da barra), para não sobrar órfão."""
    pai = os.getppid()

    async def vigia():
        while True:
            await asyncio.sleep(3)
            if os.getppid() != pai:
                os._exit(0)

    app["vigia"] = asyncio.create_task(vigia())


ROTAS_DO_MAC = ("/api/procurar", "/api/parear", "/api/casa")


def host_confiavel(host):
    """DNS rebinding: um site que aponta o próprio nome para este Mac chega com um domínio no Host.
    Aqui só vale endereço IP, localhost ou o nome .local do Mac (o celular abre por um desses)."""
    nome = urlsplit("//" + (host or "")).hostname or ""
    if nome == "localhost" or nome.endswith(".local"):
        return True
    try:
        ipaddress.ip_address(nome)
        return True
    except ValueError:
        return False


@web.middleware
async def protecao(req, handler):
    if not host_confiavel(req.host):
        raise web.HTTPForbidden(text="endereço não permitido")
    if req.method != "GET" or req.path in ROTAS_DO_MAC:
        # CSRF: o navegador manda Origin quando outro site tenta postar aqui; tem de ser esta mesma página.
        origem = req.headers.get("Origin")
        if origem is not None and urlsplit(origem).netloc.lower() != req.host.lower():
            raise web.HTTPForbidden(text="origem não permitida")
        if req.headers.get("Sec-Fetch-Site") == "cross-site":
            raise web.HTTPForbidden(text="origem não permitida")
    if req.method == "POST" and not req.content_type.startswith("application/json"):
        raise web.HTTPUnsupportedMediaType(text="só JSON")  # JSON obriga o navegador a pedir licença antes (CORS)
    return await handler(req)


def so_local(handler):
    """Pareamento e busca só pelo próprio Mac (o celular não precisa disso)."""
    async def interno(req):
        if req.remote not in ("127.0.0.1", "::1"):
            raise web.HTTPForbidden()
        return await handler(req)
    return interno


def criar_app():
    app = web.Application(middlewares=[protecao])
    app.on_startup.append(vigiar_pai)
    app.add_routes([
        web.get("/", pagina),
        web.get("/api/estado", estado),
        web.post("/api/acao", acao),
        web.post("/api/tv", tv_escolher),
        web.get("/icone/{app_id}", icone),
        web.get("/api/youtube", youtube_busca),
        web.get("/api/saude", saude),
        web.get("/api/procurar", so_local(procurar)),
        web.get("/api/parear", so_local(parear_estado)),
        web.post("/api/parear", so_local(parear_iniciar)),
        web.post("/api/casa", so_local(casa)),
    ])
    app.on_cleanup.append(lambda _a: gerente.descartar())
    return app


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("aiohttp.access").addFilter(
        lambda r: not any(p in r.getMessage() for p in ("/api/estado", "/api/saude", "/api/parear", "/api/procurar", "/api/casa"))
        or "127.0.0.1" not in r.getMessage())
    web.run_app(criar_app(), host=["0.0.0.0", "::"], port=PORTA, print=lambda *_: None,
                access_log_format='%a "%r" %s')
