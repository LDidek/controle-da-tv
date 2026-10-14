"""Roku TV (Philco, TCL, AOC, Semp…) pela rede de casa, sem conta e sem pareamento.

O que a TV oferece (Roku ECP, http://IP:8060, testado na Philco PTV40M9GR2CGB, Roku OS 16.0.4):
- GET  /query/device-info   quem é a TV, se está ligada (power-mode) e o nível de controle (ecp-setting-mode)
- GET  /query/active-app    o que está na tela
- GET  /query/apps          apps e entradas (tvinput.hdmi1, tvinput.dtv…)
- POST /keypress/<tecla>    teclas do controle; POST /launch/<id> abre app ou entrada
Desde o Roku OS 14.1 a TV vem em "Limitado": só as duas primeiras leituras funcionam e o resto dá 403.
Liberar é só no controle físico: Configurações › Sistema › Configurações avançadas do sistema ›
Controle por aplicativos móveis › Acesso à rede › Ativado. Enquanto isso, daqui não sai nenhuma tecla:
ler o estado não aparece na tela, e quem estiver assistindo não percebe nada.
A Roku não informa o volume (só sobe, desce e muda) nem tem print da tela.
"""
import asyncio
import logging
import re
import socket
import time
import xml.etree.ElementTree as ET
from urllib.parse import quote

import aiohttp

from samsung import TVDesligada, acordar_pela_rede

PORTA = 8060
LIVE_TV = "com.webos.app.livetv"  # o mesmo ID que o painel usa para "TV ao vivo"
SINTONIZADOR = "tvinput.dtv"
YOUTUBE = "837"
MAC = re.compile(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}")
ID_APP = re.compile(r"[A-Za-z0-9._-]{1,64}")
ID_VIDEO = re.compile(r"[A-Za-z0-9_-]{11}")
LIBERAR = ("Configurações › Sistema › Configurações avançadas do sistema › "
           "Controle por aplicativos móveis › Acesso à rede › Ativado")
log = logging.getLogger("roku")

TECLAS = {"UP": "Up", "DOWN": "Down", "LEFT": "Left", "RIGHT": "Right", "ENTER": "Select", "BACK": "Back",
          "HOME": "Home", "EXIT": "Home", "MENU": "Info", "INFO": "Info"}
MIDIA = {"play": "Play", "pause": "Play", "stop": "Back", "rewind": "Rev", "fast_forward": "Fwd",
         "canal_mais": "ChannelUp", "canal_menos": "ChannelDown",
         "volume_mais": "VolumeUp", "volume_menos": "VolumeDown"}


class Limitada(Exception):
    """A TV está em "Controle por aplicativos móveis: Limitado": lê o estado, mas recusa comandos."""


def ssdp_procurar(espera=2.5):
    """IPs que se anunciam como Roku na rede."""
    pedido = (
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
        "MX: 2\r\nST: roku:ecp\r\n\r\n"
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
            if "roku" in dados.decode(errors="ignore").lower() and ip not in achados:
                achados.append(ip)
    except OSError:
        pass
    finally:
        s.close()
    return achados


def _xml(texto):
    try:
        return ET.fromstring(texto)
    except ET.ParseError:
        return None


async def ler_info(sessao, ip, espera=2.5):
    """device-info como dicionário, ou None se não é uma Roku (ou não respondeu)."""
    try:
        async with sessao.get(f"http://{ip}:{PORTA}/query/device-info",
                              timeout=aiohttp.ClientTimeout(total=espera)) as r:
            if r.status != 200:
                return None
            raiz = _xml(await r.text())
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
        return None
    if raiz is None or raiz.tag != "device-info":
        return None
    return {filho.tag: (filho.text or "").strip() for filho in raiz}


def energia(info):
    """'on', 'standby' ou None. "Início rápido" deixa a rede de pé com a tela apagada (DisplayOff, Ready…)."""
    if not info:
        return None
    return "on" if info.get("power-mode") == "PowerOn" else "standby"


def limitada(info):
    return bool(info) and info.get("ecp-setting-mode", "enabled") != "enabled"


async def procurar(sessao, ips_conhecidos=(), ignorar=()):
    """Roku TVs que responderem: [(ip, info)]. As que estão em `ignorar` (ids já salvos) ficam de fora."""
    achadas, vistos = [], set()
    ips = [ip for ip in ips_conhecidos if ip]
    ips += [ip for ip in await asyncio.get_running_loop().run_in_executor(None, ssdp_procurar) if ip not in ips]
    for ip in ips:
        if ip in vistos:
            continue
        vistos.add(ip)
        info = await ler_info(sessao, ip)
        if info and info.get("is-tv") == "true" and id_da(info) not in ignorar:
            achadas.append((ip, info))
    return achadas


def id_da(info):
    return info.get("serial-number") or info.get("device-id") or info.get("udn")


def dados_da_tv(ip, info):
    macs = [str(info.get(k) or "").lower() for k in ("wifi-mac", "ethernet-mac")]
    return {
        "marca": "roku",
        "id": id_da(info),
        "tv_ip": ip,
        "tv_macs": [m for m in macs if MAC.fullmatch(m)] or None,
        "tv_modelo": info.get("model-name"),
        "fabricante": info.get("vendor-name"),
        "nome": info.get("user-device-name") or info.get("friendly-device-name"),
        "local": info.get("user-device-location") or None,
    }


class TVRoku:
    marca = "roku"

    def __init__(self, salva, atualizar):
        self._salva = salva          # devolve o registro desta TV no config.json
        self._atualizar = atualizar  # grava campos no registro
        self.http = None
        self.ip = None
        self.ligando_ate = 0.0
        self.ultima_procura = 0.0
        self.mudo = None             # a Roku não conta: só o que mandamos daqui
        self.tarefas = set()

    def salva(self):
        return self._salva() or {}

    def pareado(self):
        return True  # a Roku não pede pareamento

    def sessao(self):
        if self.http is None or self.http.closed:
            self.http = aiohttp.ClientSession()
        return self.http

    def em_segundo_plano(self, coro):
        t = asyncio.create_task(coro)
        self.tarefas.add(t)
        t.add_done_callback(self.tarefas.discard)
        return t

    async def descartar(self):
        for t in list(self.tarefas):
            t.cancel()
        if self.http is not None:
            await self.http.close()
            self.http = None

    async def info(self, procurar=False):
        """(ip, device-info) desta TV, ou (None, None) se ela não responde."""
        meu = self.salva().get("id")
        conhecidos = [ip for ip in dict.fromkeys([self.ip, self.salva().get("tv_ip")]) if ip]
        for ip in conhecidos:
            info = await ler_info(self.sessao(), ip)
            if info and (not meu or id_da(info) == meu):
                return self._achou(ip, info)
        if procurar:
            for ip in await asyncio.get_running_loop().run_in_executor(None, ssdp_procurar):
                if ip in conhecidos:
                    continue
                info = await ler_info(self.sessao(), ip)
                if info and (not meu or id_da(info) == meu):
                    return self._achou(ip, info)
        return None, None

    def _achou(self, ip, info):
        self.ip = ip
        if self.salva().get("tv_ip") != ip:
            self._atualizar({"tv_ip": ip})  # a TV pegou outro IP do roteador
        return ip, info

    async def _get(self, caminho, espera=3.0):
        try:
            async with self.sessao().get(f"http://{self.ip}:{PORTA}{caminho}",
                                         timeout=aiohttp.ClientTimeout(total=espera)) as r:
                return r.status, await r.read()
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            return None, None

    async def _post(self, caminho, espera=4.0):
        try:
            async with self.sessao().post(f"http://{self.ip}:{PORTA}{caminho}", data=b"",
                                          timeout=aiohttp.ClientTimeout(total=espera)) as r:
                codigo = r.status
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            raise ConnectionError("a TV não respondeu")
        if codigo == 403:
            raise Limitada()
        if codigo >= 400:
            raise ConnectionError(f"a TV recusou ({codigo})")

    async def tecla(self, k):
        await self._post(f"/keypress/{quote(k, safe='_%')}")

    # MARK: estado

    def _desligada(self, info=None):
        return {"online": False, "pareado": True, "marca": self.marca, "nome": self.salva().get("nome"),
                "ligando": time.time() < self.ligando_ate, "limitada": limitada(info)}

    async def estado(self):
        procurar = time.time() - self.ultima_procura > 30
        if procurar:
            self.ultima_procura = time.time()
        _ip, info = await self.info(procurar=procurar)
        if energia(info) != "on":
            self.mudo = None
            return self._desligada(info)
        self.ligando_ate = 0.0
        travada = limitada(info)
        if not travada:
            await self._ler_apps()
        s = self.salva()
        atual, titulo = await self._app_atual()
        conhecidos = s.get("apps") or []
        entradas = [{"id": a["id"], "nome": a["titulo"], "conectado": True, "app": a["id"]}
                    for a in conhecidos if a.get("entrada") and a["id"] != SINTONIZADOR]
        apps = [{"id": a["id"], "titulo": a["titulo"], "sistema": False, "cor": None}
                for a in conhecidos if not a.get("entrada")]
        apps.sort(key=lambda a: a["titulo"].lower())
        if atual == SINTONIZADOR:
            atual = LIVE_TV
        return {
            "online": True, "pareado": True, "ligada": True, "marca": self.marca, "nome": s.get("nome"),
            "app_atual": atual, "app_titulo": titulo, "ao_vivo": s.get("tuner", True),
            "volume": None, "mudo": bool(self.mudo), "som": None, "canal": None, "canal_nome": None,
            "entradas": entradas, "apps": apps, "limitada": travada, "liberar": LIBERAR if travada else None,
            "volume_exato": False,
        }

    async def _app_atual(self):
        codigo, corpo = await self._get("/query/active-app")
        raiz = _xml(corpo) if codigo == 200 else None
        app = raiz.find("app") if raiz is not None else None
        if app is None:
            return "", ""
        if app.get("type") == "tvin" or (app.get("id") or "").startswith("tvinput."):
            return app.get("id") or "", (app.text or "").strip()
        if not app.get("id"):  # tela inicial da Roku
            return "", "Início"
        return app.get("id"), (app.text or "").strip()

    async def _ler_apps(self):
        """Lista de apps e entradas: só com o controle liberado; guardada para quando voltar a ficar limitada."""
        s = self.salva()
        if time.time() - float(s.get("apps_em") or 0) < 600:
            return
        codigo, corpo = await self._get("/query/apps", 5)
        raiz = _xml(corpo) if codigo == 200 else None
        if raiz is None:
            return
        apps, tuner = [], False
        for a in raiz.findall("app"):
            app_id, nome = a.get("id") or "", (a.text or "").strip()
            if not ID_APP.fullmatch(app_id):
                continue
            entrada = a.get("type") == "tvin" or app_id.startswith("tvinput.")
            tuner = tuner or app_id == SINTONIZADOR
            apps.append({"id": app_id, "titulo": nome or app_id, "entrada": entrada})
        self._atualizar({"apps": apps, "apps_em": int(time.time()), "tuner": tuner})

    # MARK: ações

    async def _pronta(self):
        _ip, info = await self.info()
        if info is None:
            raise TVDesligada()
        if limitada(info):
            raise Limitada()
        return info

    async def ligar(self):
        self.ligando_ate = time.time() + 40
        ip, info = await self.info()
        if energia(info) == "on":
            return
        if info is not None:  # "Início rápido": a rede segue de pé e a tecla liga
            if limitada(info):
                raise Limitada()
            await self.tecla("PowerOn")
            return
        s = self.salva()
        macs = [m for m in (s.get("tv_macs") or []) if MAC.fullmatch(str(m).lower())]
        await asyncio.get_running_loop().run_in_executor(None, acordar_pela_rede, macs, ip or s.get("tv_ip"))

    async def agir(self, acao, valor):
        info = await self._pronta()
        if energia(info) != "on" and acao != "desligar":
            raise TVDesligada()
        if acao == "desligar":
            await self.tecla("PowerOff")
        elif acao == "botao":
            if valor not in TECLAS:
                raise ValueError("botão inválido")
            await self.tecla(TECLAS[valor])
        elif acao in MIDIA:
            await self.tecla(MIDIA[acao])
        elif acao == "mudo":
            await self.tecla("VolumeMute")
            self.mudo = not bool(self.mudo)
        elif acao == "volume":
            raise ValueError("Esta TV não aceita volume exato: use + e −.")
        elif acao in ("entrada", "app"):
            app_id = SINTONIZADOR if str(valor) == LIVE_TV else str(valor)
            if not ID_APP.fullmatch(app_id):
                raise ValueError("app inválido")
            await self._post(f"/launch/{app_id}", 8)
        elif acao == "youtube":
            if not ID_VIDEO.fullmatch(str(valor)):
                raise ValueError("vídeo inválido")
            await self._post(f"/launch/{YOUTUBE}?contentId={valor}&mediaType=movie", 8)
        elif acao == "texto":
            for letra in str(valor)[:200]:
                await self.tecla("Lit_" + quote(letra, safe=""))
        elif acao == "apagar":
            for _ in range(max(1, min(100, int(valor)))):
                await self.tecla("Backspace")
        elif acao == "enter":
            await self.tecla("Enter")
        else:
            raise ValueError("ação desconhecida")

    async def identificar(self):
        """Muda o som por um instante e volta: quem está na frente da TV certa ouve a pausa."""
        await self._pronta()
        await self.tecla("VolumeMute")
        try:
            await asyncio.sleep(2.5)
        finally:
            await self.tecla("VolumeMute")  # a tecla alterna: volta ao que era, com ou sem mudo antes

    async def icone(self, app_id):
        if not ID_APP.fullmatch(app_id) or not self.ip:
            return None
        codigo, corpo = await self._get(f"/query/icon/{app_id}", 5)
        return corpo if codigo == 200 and corpo else None
