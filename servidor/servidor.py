"""Controle remoto web da TV LG. Roda no Mac; abre no Mac ou no celular pelo Wi-Fi de casa.

python servidor.py   →  http://<ip-do-mac>:8765
A client-key fica só aqui no servidor; o navegador nunca a recebe.

Os dados (client-key e config.json com IP/MAC da TV e o roteador de casa) ficam na pasta de
CONTROLE_TV_DADOS. Sem a variável, usa a mesma pasta do app (~/Library/Application Support/Controle da TV).
"""
import asyncio
import datetime
import json
import logging
import os
import pathlib
import re
import socket
import time

import aiohttp
import yt_dlp
from aiohttp import web
from aiowebostv import WebOsClient
from aiowebostv import webos_client as _wc

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


def gravar_config(novos):
    cfg = ler_config()
    cfg.update({k: v for k, v in novos.items() if v is not None})
    gravar_privado(CONFIG, json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")


def ler_chave():
    try:
        return CHAVE.read_text().strip() or None
    except OSError:
        return None


def macs_da_tv():
    cfg = ler_config()
    macs = cfg.get("tv_macs") or ([cfg["tv_mac"]] if cfg.get("tv_mac") else [])
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


async def candidatos():
    cfg = ler_config()
    lista = []
    nome = cfg.get("tv_nome") or HOSTNAME_PADRAO
    ip_nome = await asyncio.get_running_loop().run_in_executor(None, resolver, nome)
    for ip in (ip_nome, cfg.get("tv_ip")):
        if ip and ip not in lista:
            lista.append(ip)
    return lista


async def achar_tv(procurar=False):
    """IP da TV ligada (porta 3000 respondendo) ou None. Com procurar=True, também pergunta na rede (SSDP)."""
    lista = await candidatos()
    for ip in lista:
        if await porta_aberta(ip):
            return ip
    if procurar:
        for ip in await asyncio.get_running_loop().run_in_executor(None, ssdp_procurar):
            if ip not in lista and await porta_aberta(ip):
                return ip
    return None


# MARK: conexão com a TV


class TV:
    def __init__(self):
        self.cliente = None
        self.trava = asyncio.Lock()
        self.ip = None
        self.ligando_ate = 0.0
        self.ultima_procura = 0.0

    def conectado(self):
        return self.cliente is not None and self.cliente.is_connected()

    async def obter(self):
        """Devolve um cliente conectado, ou None se a TV estiver desligada (ou ainda sem pareamento)."""
        async with self.trava:
            if self.conectado():
                return self.cliente
            chave = ler_chave()
            if not chave:
                return None
            # Procura na rede (SSDP) no máximo a cada 30 s, para não pesar com a TV desligada.
            procurar = time.time() - self.ultima_procura > 30
            if procurar:
                self.ultima_procura = time.time()
            ip = await achar_tv(procurar=procurar)
            if ip is None:
                return None
            self.ip = ip
            if ler_config().get("tv_ip") != ip:
                gravar_config({"tv_ip": ip})  # a TV pegou outro IP do roteador
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

    def ligar(self):
        ip = self.ip or ler_config().get("tv_ip")
        destinos = ["255.255.255.255"]
        if ip:
            destinos += [ip.rsplit(".", 1)[0] + ".255", ip]
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        # Manda para os dois endereços físicos (Wi-Fi e cabo): serve a placa que a TV estiver usando.
        for mac in macs_da_tv():
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


tv = TV()
icones = {}


# MARK: pareamento (primeira vez: a TV mostra um pedido e a pessoa aceita no controle remoto)


class Pareamento:
    def __init__(self):
        self.estado = "parado"  # parado, procurando, conferindo, esperando, pareado, erro
        self.erro = None
        self.tarefa = None

    def json(self):
        return {"estado": self.estado, "erro": self.erro, "pareado": ler_chave() is not None}


par = Pareamento()


async def parear(roteador):
    par.erro = None
    par.estado = "procurando"
    cliente = None
    espera_original = _wc.RECEIVE_TIMEOUT
    try:
        ip = None
        for _ in range(4):  # logo depois de abrir, a primeira tentativa na rede às vezes falha
            ip = await achar_tv(procurar=True)
            if ip:
                break
            await asyncio.sleep(1.5)
        if ip is None:
            par.estado, par.erro = "erro", "Não encontrei a TV ligada na rede. Ligue a TV e tente de novo."
            return
        chave = ler_chave()
        par.estado = "conferindo" if chave else "esperando"
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
        modelo = (cliente.tv_info.system or {}).get("modelName")
        gravar_privado(CHAVE, nova)
        gravar_config({
            "tv_ip": ip,
            "tv_macs": macs or None,
            "tv_modelo": modelo,
            "roteador": roteador if roteador and MAC.fullmatch(str(roteador).lower()) else None,
            "pareado_em": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        })
        await tv.descartar()
        par.estado = "pareado"
    except asyncio.TimeoutError:
        par.estado, par.erro = "erro", "O tempo acabou antes de aceitar na TV. Tente de novo."
    except Exception as e:
        texto = str(e).lower()
        if "denied" in texto or "reject" in texto or "cancel" in texto or "403" in texto:
            par.estado, par.erro = "erro", "A TV recusou o pedido. Tente de novo e escolha Aceitar."
        else:
            logging.getLogger("pareamento").warning("falhou: %r", e)
            par.estado, par.erro = "erro", "Não consegui conectar na TV."
    finally:
        _wc.RECEIVE_TIMEOUT = espera_original
        if cliente is not None:
            try:
                await cliente.disconnect()
            except Exception:
                pass


async def parear_iniciar(req):
    try:
        dados = await req.json()
    except Exception:
        dados = {}
    if par.tarefa is None or par.tarefa.done():
        par.tarefa = asyncio.create_task(parear(dados.get("roteador")))
        await asyncio.sleep(0)
    return web.json_response(par.json())


async def parear_estado(_req):
    return web.json_response(par.json())


async def procurar(_req):
    ip = await achar_tv(procurar=True)
    return web.json_response({"encontrada": ip is not None, "ip": ip, "pareado": ler_chave() is not None})


async def saude(_req):
    return web.json_response({"ok": True, "pareado": ler_chave() is not None})


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


async def estado(_req):
    try:
        cliente = await tv.obter()
    except Exception:
        await tv.descartar()
        cliente = None
    if cliente is None:
        return web.json_response({"online": False, "pareado": ler_chave() is not None,
                                  "ligando": time.time() < tv.ligando_ate})
    return web.json_response(resumo(cliente))


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
    if nome == "ligar":
        await asyncio.get_running_loop().run_in_executor(None, tv.ligar)
        return web.json_response({"ok": True})
    for tentativa in (1, 2):
        cliente = await tv.obter()
        if cliente is None:
            return web.json_response({"ok": False, "erro": "A TV está desligada."}, status=409)
        try:
            await executar(cliente, nome, valor)
            if nome == "desligar":
                await tv.descartar()
            return web.json_response({"ok": True})
        except web.HTTPException:
            raise
        except Exception as e:
            await tv.descartar()
            if tentativa == 2:
                return web.json_response({"ok": False, "erro": str(e)}, status=502)


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
        cliente = await tv.obter()
        dados = (cliente.tv_state.apps or {}).get(app_id) if cliente else None
        url = dados and (dados.get("largeIcon") or dados.get("icon"))
        if not url:
            raise web.HTTPNotFound()
        async with aiohttp.ClientSession() as s, s.get(url, timeout=aiohttp.ClientTimeout(total=5)) as r:
            if r.status != 200:
                raise web.HTTPNotFound()
            icones[app_id] = await r.read()
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


def so_local(handler):
    """Pareamento e busca só pelo próprio Mac (o celular não precisa disso)."""
    async def interno(req):
        if req.remote not in ("127.0.0.1", "::1"):
            raise web.HTTPForbidden()
        return await handler(req)
    return interno


def criar_app():
    app = web.Application()
    app.on_startup.append(vigiar_pai)
    app.add_routes([
        web.get("/", pagina),
        web.get("/api/estado", estado),
        web.post("/api/acao", acao),
        web.get("/icone/{app_id}", icone),
        web.get("/api/youtube", youtube_busca),
        web.get("/api/saude", saude),
        web.get("/api/procurar", so_local(procurar)),
        web.get("/api/parear", so_local(parear_estado)),
        web.post("/api/parear", so_local(parear_iniciar)),
    ])
    app.on_cleanup.append(lambda _a: tv.descartar())
    return app


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("aiohttp.access").addFilter(
        lambda r: not any(p in r.getMessage() for p in ("/api/estado", "/api/saude", "/api/parear", "/api/procurar"))
        or "127.0.0.1" not in r.getMessage())
    web.run_app(criar_app(), host=["0.0.0.0", "::"], port=PORTA, print=lambda *_: None,
                access_log_format='%a "%r" %s')
