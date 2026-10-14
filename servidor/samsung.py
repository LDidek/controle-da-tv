"""TV Samsung (Tizen, 2016 em diante) pela rede de casa, sem conta e sem nuvem.

O que a TV oferece e o que cada coisa usa (testado na QN55QN85BAGXZD, 2022):
- http://IP:8001/api/v2/            quem é a TV e se está ligada ("PowerState": on/standby)
- wss://IP:8002/.../remote.control  teclas do controle; pede "Permitir" na TV uma vez e devolve um token
- http://IP:8001/api/v2/applications/<id>   app aberto (visible) e abrir app (POST)
- http://IP:9197 (UPnP)            volume e mudo exatos
- http://IP:8080/ws/apps/YouTube   abre o YouTube; com ele aberto, a API "lounge" do YouTube toca o vídeo
- https://IP:1516 (JSON-RPC)       só com Configurações Especializadas › Controle Remoto IP ligado (pede outro
                                   "Permitir"): troca de entrada direto (HDMI1…4, TV) e diz qual está na tela
Nos modelos novos a TV não responde à lista de apps nem às teclas de entrada numeradas (KEY_HDMI1…):
os apps saem de um catálogo conferido um a um na TV; sem o Controle Remoto IP, a entrada é a tecla HDMI
(vai para o aparelho ligado). A TV não tem como tirar foto da tela.
"""
import asyncio
import base64
import json
import logging
import re
import socket
import ssl
import time

import aiohttp

NOME_CLIENTE = "Controle da TV"
NOME_B64 = base64.b64encode(NOME_CLIENTE.encode()).decode()
YOUTUBE = "111299001912"
ENTRADA_HDMI = "samsung.hdmi"
LIVE_TV = "com.webos.app.livetv"  # o mesmo ID que o painel usa para "TV ao vivo" na LG
PORTA_IP = 1516
FONTES_IP = ["HDMI1", "HDMI2", "HDMI3", "HDMI4"]
MAC = re.compile(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}")
ID_APP = re.compile(r"[A-Za-z0-9._-]{1,64}")
ID_VIDEO = re.compile(r"[A-Za-z0-9_-]{11}")
SEGREDO = re.compile(r"""(token=|AccessToken["']?\s*[:=]\s*["']?|loungeIdToken=)[^&"'\s)>]+""")
CDN = "https://d1oxlq5h9kq8q5.cloudfront.net/tvstore/contents/"
log = logging.getLogger("samsung")

# (IDs possíveis do app, nome, ícone na loja da Samsung, é do sistema). O mesmo app muda de ID entre
# gerações de TV; vale o primeiro que a TV reconhecer.
CATALOGO = [
    (["3201907018807", "11101200001"], "Netflix", "3201907018807/icon_198x198_20220913014109378.png", False),
    ([YOUTUBE], "YouTube", "111299001912/icon_198x198_20170921013733000.png", False),
    (["3201908019022"], "Globoplay", None, False),
    (["3201910019365", "3201512006785"], "Prime Video", "3201910019365/icon_198x198_20230604091402467.png", False),
    (["3201901017640", "3202009021709", "3202204027038"], "Disney+", "3201901017640/icon_198x198_20240417014647928.png", False),
    (["3202301029760", "3201601007230"], "HBO Max", "3202301029760/icon_198x198_20230504045632984.png", False),
    (["3201807016597"], "Apple TV", "3201807016597/icon_198x198_20210716072735455.png", False),
    (["3201710014981", "3202110025305"], "Paramount+", "3201710014981/icon_198x198_20220110073425813.png", False),
    (["3201611010983"], "YouTube Kids", None, False),
    (["3201604009182"], "Telecine", None, False),
    (["3202302030097"], "Crunchyroll", "3202302030097/icon_198x198_20240729082452564.png", False),
    (["3202306031311"], "Stremio", None, False),
    (["3201808016802"], "Pluto TV", "3201808016802/icon_198x198_20240830071201812.png", False),
    (["3201806016390"], "DAZN", "3201806016390/icon_198x198_20240529034626589.png", False),
    (["3201803015944", "3202006021105"], "Discovery+", "3202006021105/icon_198x198_20210706050608049.png", False),
    (["3201504001965"], "Tubi", "3201504001965/icon_198x198_20240325061652171.png", False),
    (["3201512006963"], "Plex", "3201512006963/icon_198x198_20220526120536805.png", False),
    (["3201606009684"], "Spotify", "3201606009684/icon_198x198_20210901091547082.png", False),
    (["3201608010191"], "Deezer", "3201608010191/icon_198x198_20231211120211353.png", False),
    (["3201710014874"], "Amazon Music", "3201710014874/icon_198x198_20221109064337256.png", False),
    (["3201908019041"], "Apple Music", "3201908019041/icon_198x198_20211111105954759.png", False),
    (["3202203026841"], "Twitch", "3202203026841/icon_198x198_20220406091057005.png", False),
    (["3202008021577"], "TikTok", "3202008021577/icon_198x198_20210723104707466.png", False),
    (["3202203026799"], "Xbox", "3202203026799/icon_198x198_20220609112120450.png", False),
    (["3202102023078"], "GeForce NOW", "3202102023078/icon_198x198_20220906073028108.png", False),
    (["3202405035480"], "Samsung TV Plus", None, False),
    (["3202010022079", "3201907018784", "org.tizen.browser"], "Internet", "3202010022079/icon_198x198_20240104061606698.png", True),
    (["3201710015037"], "Galeria", "3201710015037/icon_198x198_20231115032952000.png", True),
    (["3202311033054", "3201910019378", "3201710015016"], "SmartThings", "3202311033054/icon_198x198_20231201054913082.png", True),
    (["3202004020626"], "Amazon Alexa", "3202004020626/icon_198x198_20210426230531000.png", True),
]
POR_ID = {i: (nome, icone, sistema) for ids, nome, icone, sistema in CATALOGO for i in ids}

TECLAS = {
    "UP": "KEY_UP", "DOWN": "KEY_DOWN", "LEFT": "KEY_LEFT", "RIGHT": "KEY_RIGHT", "ENTER": "KEY_ENTER",
    "BACK": "KEY_RETURN", "HOME": "KEY_HOME", "EXIT": "KEY_EXIT", "MENU": "KEY_MENU", "INFO": "KEY_INFO",
    "SOURCE": "KEY_SOURCE",
}
MIDIA = {"play": "KEY_PLAY", "pause": "KEY_PAUSE", "stop": "KEY_STOP", "rewind": "KEY_REWIND",
         "fast_forward": "KEY_FF", "canal_mais": "KEY_CHUP", "canal_menos": "KEY_CHDOWN",
         "volume_mais": "KEY_VOLUP", "volume_menos": "KEY_VOLDOWN"}


class TVDesligada(Exception):
    pass


def sem_segredo(texto):
    """Erros do aiohttp trazem a URL inteira, com o token: nunca vão assim para log nem para o navegador."""
    return SEGREDO.sub(r"\1***", str(texto))


class ErroIP(Exception):
    def __init__(self, codigo, mensagem):
        super().__init__(f"{codigo} {mensagem}")
        self.codigo = codigo


def _ssl():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # a TV usa certificado próprio
    return ctx


SSL = _ssl()


def energia(info):
    """'on', 'standby' ou None (sem resposta). TVs antigas não informam: se respondeu, está ligada."""
    if not info:
        return None
    return str((info.get("device") or {}).get("PowerState") or "on").lower()


def ssdp_procurar(espera=2.5):
    """IPs que se anunciam como Samsung na rede (pelo DIAL, que toda smart TV da Samsung tem)."""
    pedido = (
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
        "MX: 2\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n"
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
            if "samsung" in dados.decode(errors="ignore").lower() and ip not in achados:
                achados.append(ip)
    except OSError:
        pass
    finally:
        s.close()
    return achados


def acordar_pela_rede(macs, ip):
    """Wake-on-LAN, para quando a TV já desligou a rede (fora do standby curto)."""
    destinos = ["255.255.255.255"] + ([ip.rsplit(".", 1)[0] + ".255", ip] if ip else [])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for mac in macs:
        pacote = bytes.fromhex("ff" * 6 + mac.replace(":", "") * 16)
        for destino in destinos:
            for porta in (9, 7):
                for _ in range(3):
                    try:
                        s.sendto(pacote, (destino, porta))
                    except OSError:
                        pass
    s.close()


async def ler_info(sessao, ip, espera=2.5):
    try:
        async with sessao.get(f"http://{ip}:8001/api/v2/", timeout=aiohttp.ClientTimeout(total=espera)) as r:
            if r.status != 200:
                return None
            dados = json.loads(await r.text())
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError, OSError):
        return None
    if "samsung" not in str(dados.get("type", "")).lower() and "device" not in dados:
        return None
    return dados


async def procurar(sessao, ips_conhecidos=()):
    """Primeira TV Samsung que responder: (ip, info). Os IPs conhecidos vêm antes da procura na rede."""
    for ip in ips_conhecidos:
        if ip:
            info = await ler_info(sessao, ip)
            if info:
                return ip, info
    for ip in await asyncio.get_running_loop().run_in_executor(None, ssdp_procurar):
        if ip not in ips_conhecidos:
            info = await ler_info(sessao, ip)
            if info:
                return ip, info
    return None, None


def dados_da_tv(ip, info):
    d = info.get("device") or {}
    mac = str(d.get("wifiMac") or "").lower()
    return {
        "marca": "samsung",
        "id": d.get("duid") or info.get("id"),
        "tv_ip": ip,
        "tv_macs": [mac] if MAC.fullmatch(mac) else None,
        "tv_modelo": d.get("modelName") or d.get("model"),
        "nome": d.get("name") or info.get("name"),
    }


async def conectar(sessao, ip, token, espera_primeira=6.0, ao_esperar=None, espera_total=100.0):
    """Abre o canal de teclas. Sem token (ou com token velho) a TV mostra "Permitir"; devolve (ws, token)."""
    url = f"wss://{ip}:8002/api/v2/channels/samsung.remote.control?name={NOME_B64}"
    if token:
        url += f"&token={token}"
    ws = await sessao.ws_connect(url, ssl=SSL, heartbeat=None, timeout=aiohttp.ClientWSTimeout(ws_close=3))
    try:
        try:
            msg = await asyncio.wait_for(ws.receive(), espera_primeira)
        except asyncio.TimeoutError:
            if ao_esperar is None:
                raise
            ao_esperar()  # a TV está mostrando o pedido: falta escolher Permitir no controle
            msg = await asyncio.wait_for(ws.receive(), espera_total)
        if msg.type != aiohttp.WSMsgType.TEXT:
            raise ConnectionError("a TV fechou a conexão")
        dados = json.loads(msg.data)
        evento = dados.get("event")
        if evento == "ms.channel.connect":
            return ws, (dados.get("data") or {}).get("token") or token
        if evento == "ms.channel.unauthorized":
            raise PermissionError("a TV recusou")
        if evento == "ms.channel.timeOut":
            raise asyncio.TimeoutError()
        raise ConnectionError(f"resposta inesperada da TV: {evento}")
    except BaseException:
        await ws.close()
        raise


# MARK: Controle Remoto IP (JSON-RPC na porta 1516)


async def porta_ip_aberta(ip, espera=1.5):
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(ip, PORTA_IP), espera)
        w.close()
        return True
    except (OSError, asyncio.TimeoutError):
        return False


async def chamar_ip(sessao, ip, metodo, token=None, espera=5.0, **params):
    corpo = {"jsonrpc": "2.0", "id": str(int(time.time() * 1000)), "method": metodo}
    if token:
        corpo["params"] = {"AccessToken": token, **params}
    async with sessao.post(f"https://{ip}:{PORTA_IP}/", json=corpo, ssl=SSL, headers={"Accept": "application/json"},
                           timeout=aiohttp.ClientTimeout(total=espera)) as r:
        dados = json.loads(await r.text())
    if "error" in dados or "code" in dados:  # token recusado volta sem o envelope jsonrpc
        erro = dados.get("error") or dados
        raise ErroIP(erro.get("code"), erro.get("message"))
    return dados.get("result") or {}


async def parear_ip(sessao, ip):
    """A TV mostra um segundo aviso; quem escolhe Permitir libera. Atenção: recusar duas vezes bloqueia."""
    resultado = await chamar_ip(sessao, ip, "createAccessToken", espera=75)
    return resultado.get("AccessToken")


# MARK: YouTube (o mesmo caminho do "transmitir" do celular)


class Lounge:
    API = "https://www.youtube.com/api/lounge"

    def __init__(self):
        self.tela = None
        self.token = None

    async def tocar(self, sessao, tela, video):
        for tentativa in (1, 2):
            if tentativa == 2 or self.tela != tela or not self.token:
                async with sessao.post(f"{self.API}/pairing/get_lounge_token_batch", data={"screen_ids": tela},
                                       timeout=aiohttp.ClientTimeout(total=10)) as r:
                    telas = (await r.json(content_type=None)).get("screens") or []
                if not telas:
                    return False
                self.tela, self.token = tela, telas[0]["loungeToken"]
            sid, sessao_g, ultimo = await self._ligar(sessao)
            if not sid:
                continue  # token vencido: pede outro
            params = {"name": NOME_CLIENTE, "loungeIdToken": self.token, "SID": sid, "AID": ultimo,
                      "gsessionid": sessao_g, "device": "REMOTE_CONTROL", "app": "youtube-desktop",
                      "VER": "8", "v": "2", "RID": "2"}
            corpo = {"count": "1", "ofs": "1", "req0__sc": "setPlaylist", "req0_videoId": video}
            async with sessao.post(f"{self.API}/bc/bind", params=params, data=corpo,
                                   timeout=aiohttp.ClientTimeout(total=10)) as r:
                if r.status == 200:
                    return True
        return False

    async def _ligar(self, sessao):
        corpo = {
            "app": "web", "mdx-version": "3", "name": NOME_CLIENTE, "id": self.tela, "device": "REMOTE_CONTROL",
            "capabilities": "que,dsdtr,atp,vsp", "magnaKey": "cloudPairedDevice", "ui": "false",
            "deviceContext": "user_agent=dunno&window_width_points=&window_height_points=&os_name=android&ms=",
            "theme": "cl", "loungeIdToken": self.token,
        }
        url = f"{self.API}/bc/bind?RID=1&VER=8&CVER=1&auth_failure_option=send_error"
        async with sessao.post(url, data=corpo, timeout=aiohttp.ClientTimeout(total=10)) as r:
            if r.status != 200:
                return None, None, None
            texto = await r.text()
        sid = sessao_g = ultimo = None
        # A resposta vem em pedaços: uma linha com o tamanho, depois o JSON (que pode ocupar várias linhas).
        restante, pedaco = 0, ""
        for linha in texto.splitlines():
            if restante <= 0:
                try:
                    restante, pedaco = int(linha), ""
                except ValueError:
                    continue
                continue
            pedaco += linha
            restante -= len(linha) + 1
            if restante <= 0:
                for numero, (tipo, *args) in json.loads(pedaco):
                    ultimo = numero
                    if tipo == "c":
                        sid = args[0]
                    elif tipo == "S":
                        sessao_g = args[0]
        return sid, sessao_g, ultimo


# MARK: a TV


class TVSamsung:
    marca = "samsung"

    def __init__(self, salva, atualizar):
        self._salva = salva          # devolve o registro desta TV no config.json
        self._atualizar = atualizar  # grava campos no registro
        self.http = None
        self.trava_http = asyncio.Lock()  # o servidor da TV engasga com pedidos simultâneos
        self.trava_ws = asyncio.Lock()
        self.ws = None
        self.leitor = None
        self.ip = None
        self.ligando_ate = 0.0
        self.ultima_procura = 0.0
        self.foto = None             # último estado lido (o painel recebe na hora, sem esperar a TV)
        self.lida = asyncio.Event()
        self.acordar = asyncio.Event()
        self.vigia = None
        self.pedido_em = 0.0
        self.visivel = None          # app na tela
        self.entrada = None          # sem Controle Remoto IP: entrada escolhida por aqui (a TV não conta)
        self.fonte = None            # com Controle Remoto IP: a entrada que a TV diz estar na tela
        self.varredura_em = 0.0
        self.volume = None
        self.mudo = None
        self.som_mudado_em = 0.0     # a TV demora a contar o volume novo: até lá vale o que mandamos
        self.tarefas = set()
        self.lounge = Lounge()

    # MARK: básico

    def salva(self):
        return self._salva() or {}

    def pareado(self):
        return bool(self.salva().get("chave"))

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
        for t in list(self.tarefas) + [self.vigia, self.leitor]:
            if t is not None and not t.done():
                t.cancel()
        if self.ws is not None:
            try:
                await self.ws.close()
            except Exception:
                pass
            self.ws = None
        if self.http is not None:
            await self.http.close()
            self.http = None

    async def info(self, procurar=False):
        """(ip, info) da TV desta casa, ou (None, None) se ela não responde (desligada de vez ou fora da rede)."""
        s = self.salva()
        conhecidos = [ip for ip in dict.fromkeys([self.ip, s.get("tv_ip")]) if ip]
        async with self.trava_http:
            for ip in conhecidos:
                info = await ler_info(self.sessao(), ip)
                if info and self._mesma(info):
                    return self._achou(ip, info)
            if procurar:
                for ip in await asyncio.get_running_loop().run_in_executor(None, ssdp_procurar):
                    if ip in conhecidos:
                        continue
                    info = await ler_info(self.sessao(), ip)
                    if info and self._mesma(info):
                        return self._achou(ip, info)
        return None, None

    def _mesma(self, info):
        meu = self.salva().get("id")
        d = info.get("device") or {}
        return not meu or meu in (d.get("duid"), info.get("id"), d.get("id"))

    def _achou(self, ip, info):
        self.ip = ip
        if self.salva().get("tv_ip") != ip:
            self._atualizar({"tv_ip": ip})  # a TV pegou outro IP do roteador
        return ip, info

    async def _http(self, metodo, url, espera=3.0, **kw):
        async with self.trava_http:
            try:
                async with self.sessao().request(metodo, url, timeout=aiohttp.ClientTimeout(total=espera), **kw) as r:
                    return r.status, await r.text()
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
                return None, None

    async def status_app(self, app_id):
        if not self.ip:
            return None
        codigo, texto = await self._http("GET", f"http://{self.ip}:8001/api/v2/applications/{app_id}", 2.5)
        if codigo != 200:
            return None
        try:
            return json.loads(texto)
        except ValueError:
            return None

    async def _upnp(self, acao, extra=""):
        corpo = (
            '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{acao} xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">'
            f'<InstanceID>0</InstanceID><Channel>Master</Channel>{extra}</u:{acao}></s:Body></s:Envelope>'
        )
        cabecalhos = {"Content-Type": 'text/xml; charset="utf-8"',
                      "SOAPACTION": f'"urn:schemas-upnp-org:service:RenderingControl:1#{acao}"'}
        codigo, texto = await self._http("POST", f"http://{self.ip}:9197/upnp/control/RenderingControl1",
                                         2.5, data=corpo.encode(), headers=cabecalhos)
        return texto if codigo == 200 else None

    # MARK: teclas

    async def _canal(self):
        if self.ws is not None and not self.ws.closed:
            return self.ws
        ip = self.ip or (await self.info())[0]
        if not ip:
            raise TVDesligada()
        token = self.salva().get("chave")
        ws, novo = await conectar(self.sessao(), ip, token)
        if novo and novo != token:
            self._atualizar({"chave": novo})
        self.ws = ws
        self.leitor = asyncio.create_task(self._ler_canal(ws))
        return ws

    async def _ler_canal(self, ws):
        """Esvazia o que a TV manda (senão a conexão entope) e percebe quando ela cai."""
        try:
            async for _msg in ws:
                pass
        finally:
            if self.ws is ws:
                self.ws = None

    async def enviar(self, mensagem):
        async with self.trava_ws:
            for tentativa in (1, 2):
                try:
                    ws = await self._canal()
                    await ws.send_json(mensagem)
                    return
                except TVDesligada:
                    raise
                except Exception:
                    if self.ws is not None:
                        await self.ws.close()
                    self.ws = None
                    if tentativa == 2:
                        raise

    async def tecla(self, k):
        await self.enviar({"method": "ms.remote.control", "params": {
            "Cmd": "Click", "DataOfCmd": k, "Option": "false", "TypeOfRemote": "SendRemoteKey"}})

    # MARK: estado (lido em segundo plano enquanto alguém olha o painel ou o celular)

    async def estado(self):
        self.pedido_em = time.time()
        if self.vigia is None or self.vigia.done():
            self.lida.clear()
            self.vigia = asyncio.create_task(self._vigiar())
        if self.foto is None:
            try:
                await asyncio.wait_for(self.lida.wait(), 4)
            except asyncio.TimeoutError:
                pass
        return self.foto or self._desligada()

    def _desligada(self):
        return {"online": False, "pareado": self.pareado(), "marca": self.marca,
                "nome": self.salva().get("nome"), "ligando": time.time() < self.ligando_ate}

    async def _vigiar(self):
        while time.time() - self.pedido_em < 30:
            ligada = False
            try:
                self.foto = await self._ler()
                ligada = self.foto.get("online", False)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("leitura falhou: %s", sem_segredo(repr(e)))
            self.lida.set()
            self.acordar.clear()
            try:
                await asyncio.wait_for(self.acordar.wait(), 2 if ligada else 3)
            except asyncio.TimeoutError:
                pass

    async def _ler(self):
        if not self.pareado():
            return self._desligada()
        procurar = time.time() - self.ultima_procura > 30
        if procurar:
            self.ultima_procura = time.time()
        _ip, info = await self.info(procurar=procurar)
        if energia(info) != "on":
            self.visivel = self.entrada = None
            return self._desligada()
        self.ligando_ate = 0.0
        if not await self._ler_estado_ip():
            await self._ler_volume()
        await self._ler_app()
        s = self.salva()
        # A cada 12 h, e logo depois de o catálogo ganhar um app novo (numa atualização do Controle da TV).
        if time.time() - float(s.get("apps_em") or 0) > 12 * 3600 or s.get("apps_catalogo") != len(POR_ID):
            self._atualizar({"apps_em": int(time.time()), "apps_catalogo": len(POR_ID)})
            self.em_segundo_plano(self.conferir_apps())
        return self._montar()

    def _montar(self):
        s = self.salva()
        nomes = s.get("entradas_nomes") or {}
        if s.get("chave_ip"):
            # Com o Controle Remoto IP: todas as entradas; "conectado" = já respondeu a uma troca.
            usadas = set(s.get("entradas_ok") or []) | ({self.fonte} if self.fonte else set())
            entradas = [{"id": f, "nome": nomes.get(f) or f"HDMI {f[-1]}", "conectado": f in usadas,
                         "app": f"samsung.{f.lower()}"} for f in FONTES_IP]
            na_tela = LIVE_TV if self.fonte == "TV" else (f"samsung.{self.fonte.lower()}" if self.fonte else "")
        else:
            entradas = [{"id": "HDMI", "nome": nomes.get("HDMI") or "HDMI", "conectado": True, "app": ENTRADA_HDMI}]
            na_tela = self.entrada or ""
        atual = self.visivel or na_tela
        titulo = POR_ID.get(atual, (None,))[0] or next((e["nome"] for e in entradas if e["app"] == atual), "")
        apps = [{"id": i, "titulo": POR_ID[i][0], "sistema": POR_ID[i][2], "cor": None}
                for i in (s.get("apps") or []) if i in POR_ID]
        apps.sort(key=lambda a: a["titulo"].lower())
        return {
            "online": True, "pareado": True, "ligada": True, "marca": self.marca, "nome": s.get("nome"),
            "app_atual": atual, "app_titulo": titulo, "ao_vivo": bool(s.get("chave_ip")),
            "volume": self.volume, "mudo": bool(self.mudo), "som": None, "canal": None, "canal_nome": None,
            "entradas": entradas, "apps": apps,
        }

    async def _ip(self, metodo, **params):
        token = self.salva().get("chave_ip")
        if not token or not self.ip:
            return None
        try:
            return await chamar_ip(self.sessao(), self.ip, metodo, token, **params)
        except ErroIP as e:
            if e.codigo == -32700:  # token recusado (a TV foi pareada de novo por outro app ou resetada)
                log.warning("Controle Remoto IP recusou o token: volta para a tecla HDMI")
                self._atualizar({"chave_ip": ""})
            raise
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError):
            return None  # opção desligada na TV ou TV ocupada: segue pelo caminho sem ela

    async def _ip_ou_nada(self, metodo, **params):
        try:
            return await self._ip(metodo, **params)
        except ErroIP:
            return None

    async def _ler_estado_ip(self):
        try:
            r = await self._ip("getTVStates")
        except ErroIP:
            return False
        if not r:
            return False
        if time.time() - self.som_mudado_em > 3:
            if isinstance(r.get("volume"), int):
                self.volume = r["volume"]
            if r.get("mute") in ("muteOn", "muteOff"):
                self.mudo = r["mute"] == "muteOn"
        self.fonte = r.get("inputSource") or self.fonte
        return True

    async def _trocar_fonte(self, fonte):
        """Entrada direto pelo Controle Remoto IP. Porta sem nada ligado: a TV recusa."""
        try:
            r = await self._ip("inputSourceControl", inputSource=fonte)
        except ErroIP:
            raise ValueError("Nada conectado nesta entrada")
        if r is None:
            return False
        self.fonte, self.visivel = fonte, None
        usadas = self.salva().get("entradas_ok") or []
        if fonte not in usadas:
            self._atualizar({"entradas_ok": usadas + [fonte]})
        return True

    async def _ler_volume(self):
        if time.time() - self.som_mudado_em < 3:
            return
        texto = await self._upnp("GetVolume")
        m = texto and re.search(r"<CurrentVolume>(\d+)</CurrentVolume>", texto)
        if m:
            self.volume = int(m.group(1))
        texto = await self._upnp("GetMute")
        m = texto and re.search(r"<CurrentMute>(\d)</CurrentMute>", texto)
        if m:
            self.mudo = m.group(1) == "1"

    async def _ler_app(self):
        if self.visivel:
            st = await self.status_app(self.visivel)
            if st and st.get("visible"):
                return
            self.visivel = None
        # Ninguém na tela: confere os apps um por um, mas não a cada leitura (são vários pedidos).
        if time.time() - self.varredura_em < 6:
            return
        self.varredura_em = time.time()
        for app_id in self.salva().get("apps") or []:
            st = await self.status_app(app_id)
            if st and st.get("visible"):
                self.visivel, self.entrada = app_id, None
                return

    async def conferir_apps(self):
        """Quais apps do catálogo esta TV tem (ela não informa a lista nos modelos novos)."""
        if not self.ip:
            await self.info()
        if not self.ip:
            return
        achados = []
        for ids, _nome, _icone, _sistema in CATALOGO:
            for app_id in ids:
                if await self.status_app(app_id):
                    achados.append(app_id)
                    break
        log.info("apps desta TV: %d do catálogo", len(achados))
        self._atualizar({"apps": achados, "apps_em": int(time.time()), "apps_catalogo": len(POR_ID)})

    def _ja_mudou(self, **campos):
        """O painel vê a mudança na hora; a leitura seguinte confirma com a TV."""
        if self.foto and self.foto.get("online"):
            self.foto = {**self.foto, **campos}
        self.acordar.set()

    # MARK: ações

    async def ligar(self):
        self.ligando_ate = time.time() + 40
        if self.foto is not None:
            self.foto = {**self.foto, "ligando": True}
        ip, info = await self.info()
        if energia(info) == "on":
            return
        if energia(info) == "standby":
            await self.tecla("KEY_POWER")  # em standby a TV ainda escuta a rede: a tecla liga
        else:
            s = self.salva()
            macs = [m for m in (s.get("tv_macs") or []) if MAC.fullmatch(str(m).lower())]
            await asyncio.get_running_loop().run_in_executor(None, acordar_pela_rede, macs, ip or s.get("tv_ip"))
            self.em_segundo_plano(self._terminar_de_ligar())
        self.acordar.set()

    async def _terminar_de_ligar(self):
        """Depois do Wake-on-LAN a TV pode voltar só em standby: aí falta a tecla. Nunca aperta duas vezes."""
        fim = time.time() + 25
        while time.time() < fim:
            await asyncio.sleep(2)
            _ip, info = await self.info()
            if energia(info) == "on":
                return
            if energia(info) == "standby":
                await self.tecla("KEY_POWER")
                return

    async def agir(self, acao, valor):
        _ip, info = await self.info()
        if energia(info) != "on":
            raise TVDesligada()
        if acao == "desligar":
            await self.tecla("KEY_POWER")
            self.foto = self._desligada()
            self.visivel = self.entrada = None
        elif acao == "botao":
            if valor not in TECLAS:
                raise ValueError("botão inválido")
            await self.tecla(TECLAS[valor])
            if valor in ("HOME", "SOURCE"):
                self.varredura_em = 0.0
        elif acao in MIDIA:
            await self.tecla(MIDIA[acao])
            if acao.startswith("volume_") and self.volume is not None:
                self.volume = max(0, min(100, self.volume + (1 if acao == "volume_mais" else -1)))
                self.som_mudado_em = time.time()
                self._ja_mudou(volume=self.volume)
        elif acao == "volume":
            v = max(0, min(100, int(valor)))
            # Pelo Controle Remoto IP a leitura já sai certa; pelo UPnP ela demora a acompanhar.
            if await self._ip_ou_nada("directVolumeControl", volume=v) is None \
                    and await self._upnp("SetVolume", f"<DesiredVolume>{v}</DesiredVolume>") is None:
                raise ConnectionError("a TV não aceitou o volume")
            self.volume, self.som_mudado_em = v, time.time()
            self._ja_mudou(volume=v)
        elif acao == "mudo":
            novo = not bool(self.mudo)
            if await self._ip_ou_nada("muteControl", mute="muteOn" if novo else "muteOff") is None \
                    and await self._upnp("SetMute", f"<DesiredMute>{1 if novo else 0}</DesiredMute>") is None:
                await self.tecla("KEY_MUTE")
            self.mudo, self.som_mudado_em = novo, time.time()
            self._ja_mudou(mudo=novo)
        elif acao == "entrada":
            fonte = str(valor)
            if fonte in FONTES_IP and await self._trocar_fonte(fonte):
                self._ja_mudou(app_atual=f"samsung.{fonte.lower()}")
            else:
                await self.tecla("KEY_HDMI")  # vai para o aparelho ligado na TV (e o acorda pelo HDMI-CEC)
                self.visivel, self.entrada = None, ENTRADA_HDMI
                self._ja_mudou(app_atual=ENTRADA_HDMI)
        elif acao == "app" and str(valor) == LIVE_TV:
            if not await self._trocar_fonte("TV"):
                await self.tecla("KEY_TV")
            self._ja_mudou(app_atual=LIVE_TV)
        elif acao == "app":
            app_id = str(valor)
            if not ID_APP.fullmatch(app_id):
                raise ValueError("app inválido")
            for tentativa in (1, 2):  # logo depois de trocar de entrada a TV às vezes não atende de primeira
                codigo, _ = await self._http("POST", f"http://{self.ip}:8001/api/v2/applications/{app_id}", 8)
                if codigo == 200:
                    break
                if tentativa == 1:
                    await asyncio.sleep(1.5)
            else:
                raise ConnectionError("a TV não abriu o app")
            self.visivel, self.entrada = app_id, None
            self._ja_mudou(app_atual=app_id, app_titulo=POR_ID.get(app_id, ("",))[0])
        elif acao == "youtube":
            if not ID_VIDEO.fullmatch(str(valor)):
                raise ValueError("vídeo inválido")
            self.em_segundo_plano(self._youtube(str(valor)))
        elif acao == "texto":
            texto = base64.b64encode(str(valor)[:500].encode()).decode()
            await self.enviar({"method": "ms.remote.control", "params": {
                "Cmd": texto, "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"}})
        elif acao == "enter":
            await self.enviar({"method": "ms.remote.control", "params": {"TypeOfRemote": "SendInputEnd"}})
        elif acao == "apagar":
            pass  # o teclado da Samsung não recebe "apagar" pela rede
        else:
            raise ValueError("ação desconhecida")

    async def identificar(self):
        """Muda o som por um instante e volta ao que era: quem está na frente da TV certa ouve a pausa."""
        _ip, info = await self.info()
        if energia(info) != "on":
            raise TVDesligada()
        if self.mudo is None and not await self._ler_estado_ip():
            await self._ler_volume()
        await self.agir("mudo", None)
        try:
            await asyncio.sleep(2.5)
        finally:
            await self.agir("mudo", None)

    async def _tela_do_youtube(self, dial):
        codigo, texto = await self._http("GET", dial, 3)
        m = codigo == 200 and re.search(r"<screenId>([^<]+)</screenId>", texto or "")
        return m.group(1) if m else None

    async def _youtube(self, video):
        """Abre o YouTube (se preciso) e toca o vídeo como o celular faz ao transmitir."""
        dial = f"http://{self.ip}:8080/ws/apps/YouTube"
        tela = await self._tela_do_youtube(dial)
        if not tela:
            origem = {"Origin": "package:com.google.android.youtube", "Content-Type": "text/plain; charset=utf-8"}
            await self._http("POST", dial, 8, data=f"v={video}".encode(), headers=origem)
            for _ in range(24):
                await asyncio.sleep(0.75)
                tela = await self._tela_do_youtube(dial)
                if tela:
                    break
        if not tela:
            log.warning("YouTube não abriu na TV")
            return
        try:
            ok = await self.lounge.tocar(self.sessao(), tela, video)
        except Exception as e:
            log.warning("YouTube não tocou: %s", sem_segredo(repr(e)))
            return
        if ok:
            self.visivel, self.entrada = YOUTUBE, None
            self._ja_mudou(app_atual=YOUTUBE, app_titulo="YouTube")

    async def icone(self, app_id):
        icone = POR_ID.get(app_id, (None, None))[1]
        if not icone:
            return None
        try:
            async with self.sessao().get(CDN + icone, timeout=aiohttp.ClientTimeout(total=6)) as r:
                return await r.read() if r.status == 200 else None
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            return None
