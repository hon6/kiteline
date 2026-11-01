"""HTTP / HTTPS 服务（标准库 ThreadingHTTPServer，一条连接一个线程）。

和 Mac 版 HTTPServer.swift 的约定一样：路由函数拿到 Request，回一个 Response；
实时事件（SSE）回 Stream，连接一直挂着，服务端往里推。
"""

import gzip
import http.server
import json
import socket
import socketserver
import ssl
import threading
import time
import urllib.parse
from http import HTTPStatus

from . import log

MAX_BODY = 40 * 1024 * 1024
PREAUTH_BODY = 1024 * 1024       # 超过 1 MB 的请求体：收之前先核对令牌
HEADER_SECONDS = 15
BODY_SECONDS = 120
READ_SECONDS = 60          # 连接上每次读写的超时（兜底：上面两个计时器之外，单次 recv 卡住也会断）
SSE_WRITE_SECONDS = 10     # 实时流：对方不收数据、写不进去 10 秒就断开（广播是挨个写的，别让一台卡住全部）


class Request:
    def __init__(self, method, raw_path, headers, body, remote):
        parsed = urllib.parse.urlsplit(raw_path)
        self.method = method
        self.path = parsed.path or "/"
        self.query = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()}
        self.headers = {k.lower(): v for k, v in headers.items()}
        self.body = body
        self.remote = remote
        self.cookies = {}
        for part in self.headers.get("cookie", "").split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                self.cookies[k.strip()] = v.strip()
        self._json = None
        self._json_parsed = False

    @property
    def json(self):
        if not self._json_parsed:
            self._json_parsed = True
            try:
                value = json.loads(self.body.decode("utf-8")) if self.body else None
                self._json = value if isinstance(value, dict) else None
            except (ValueError, UnicodeDecodeError):
                self._json = None
        return self._json


class Response:
    def __init__(self, status=200, headers=None, body=b""):
        self.status = status
        self.headers = dict(headers or {})
        self.body = body if isinstance(body, (bytes, bytearray)) else str(body).encode("utf-8")

    @staticmethod
    def json(payload, status=200):
        data = json.dumps(payload, ensure_ascii=False, default=_default).encode("utf-8")
        return Response(status, {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"}, data)

    @staticmethod
    def error(message, status=400):
        return Response.json({"ok": False, "error": message}, status)

    @staticmethod
    def text(message, status=200):
        return Response(status, {"Content-Type": "text/plain; charset=utf-8"}, message)


def _default(value):
    if isinstance(value, (set, tuple)):
        return list(value)
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


class Stream:
    """SSE 连接：send() 线程安全；对方断开后 closed = True，on_close 回调一次"""

    def __init__(self, handler, remote):
        self._handler = handler
        self._lock = threading.Lock()
        self._done = threading.Event()
        self.remote = remote
        self.on_close = None
        self.closed = False

    def send(self, data):
        if self.closed:
            return
        if isinstance(data, str):
            data = data.encode("utf-8")
        with self._lock:
            try:
                self._handler.wfile.write(data)
                self._handler.wfile.flush()
            except (OSError, ValueError):
                self._finish()

    def close(self):
        self._finish()

    def _finish(self):
        if self.closed:
            return
        self.closed = True
        self._done.set()
        callback, self.on_close = self.on_close, None
        if callback:
            try:
                callback()
            except Exception as exc:  # noqa: BLE001
                log.write("SSE 关闭回调出错：%s" % exc)

    def wait(self):
        self._done.wait()


class StreamReply:
    """路由回这个：先写响应头，再把 Stream 交给 attach（attach 返回后连接继续挂着，直到对方断开）"""

    def __init__(self, headers, attach):
        self.headers = headers
        self.attach = attach


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = READ_SECONDS     # StreamRequestHandler.setup 会对连接 settimeout；读请求头 / 请求体超时就断开
    server_version = "Kiteline"
    sys_version = ""

    def log_message(self, fmt, *args):  # 安静：访问日志太多
        pass

    def _abort(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def handle_one_request(self):
        # 请求头 15 秒内没收完就断（一个字节一个字节地发，也占不住线程）
        self._timer = threading.Timer(HEADER_SECONDS, self._abort)
        self._timer.daemon = True
        self._timer.start()
        try:
            super().handle_one_request()
        finally:
            self._timer.cancel()

    def _handle(self):
        self._timer.cancel()
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            self._send(Response.error("请求体过大", 413))
            self.close_connection = True
            return
        remote = self.client_address[0]
        if remote.startswith("::ffff:"):
            remote = remote[7:]
        if length > PREAUTH_BODY:
            probe = Request(self.command, self.path, dict(self.headers.items()), b"", remote)
            if not self.server.preauth(probe.headers, probe.query, probe.cookies):
                self._send(Response.error("未配对或令牌已失效", 401))
                self.close_connection = True
                return
        body = b""
        if length > 0:
            timer = threading.Timer(BODY_SECONDS, self._abort)
            timer.daemon = True
            timer.start()
            try:
                body = self.rfile.read(length)
            finally:
                timer.cancel()
            if len(body) != length:
                self.close_connection = True
                return
        request = Request(self.command, self.path, dict(self.headers.items()), body, remote)
        try:
            reply = self.server.route(request)
        except Exception as exc:  # noqa: BLE001
            log.write("处理 %s %s 出错：%r" % (request.method, request.path, exc))
            reply = Response.error("服务器内部错误：%s" % exc, 500)
        if isinstance(reply, StreamReply):
            self._stream(reply)
        else:
            self._send(reply, "gzip" in (self.headers.get("Accept-Encoding") or ""))

    def _send(self, response, gzip_ok=False):
        try:
            self.send_response(response.status)
            headers = {"Access-Control-Allow-Origin": "*",
                       "Access-Control-Allow-Headers": "Content-Type, X-CCP-Token",
                       "Access-Control-Allow-Methods": "GET, POST, OPTIONS"}
            headers.update(response.headers)
            body = response.body
            kind = headers.get("Content-Type", "")
            # 文字类内容超过 1 KB 就压缩（走中继时省流量、快不少）
            if body and len(body) > 1024 and any(t in kind for t in ("text/", "json", "javascript", "svg")):
                headers["Vary"] = "Accept-Encoding"
                if gzip_ok:
                    body = gzip.compress(body, 6)
                    headers["Content-Encoding"] = "gzip"
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD" and body:
                self.wfile.write(body)
        except (OSError, ValueError):
            self.close_connection = True

    def _stream(self, reply):
        try:
            self.send_response(200)
            for key, value in reply.headers.items():
                self.send_header(key, value)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            self.wfile.flush()
        except (OSError, ValueError):
            self.close_connection = True
            return
        stream = Stream(self, self.client_address[0])
        self.connection.settimeout(SSE_WRITE_SECONDS)

        # 读端：对方断开时 recv 返回空，结束这条流（SSE 里客户端不会再发东西；读超时只是没动静，接着等）
        def watch_close():
            try:
                while not stream.closed:
                    try:
                        data = self.connection.recv(1024)
                    except socket.timeout:
                        continue
                    if not data:
                        break
            except (OSError, ValueError):
                pass
            stream.close()
        threading.Thread(target=watch_close, daemon=True).start()
        reply.attach(stream)
        stream.wait()
        self.close_connection = True

    do_GET = do_POST = do_OPTIONS = do_HEAD = do_PUT = do_DELETE = _handle


class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, address, route, family=socket.AF_INET, preauth=None):
        self.address_family = family
        self.route = route
        self.preauth = preauth or (lambda headers, query, cookies: False)
        super().__init__(address, _Handler)


class HTTPServer:
    """一个监听端口。tls=(证书链, 私钥) 时是 HTTPS"""

    def __init__(self, host, port, route, tls=None, preauth=None):
        self.host, self.port, self.route, self.tls, self.preauth = host, port, route, tls, preauth
        self._server = None
        self.status = "未启动"

    def start(self):
        family = socket.AF_INET6 if ":" in self.host else socket.AF_INET
        server = _Server((self.host, self.port), self.route, family, self.preauth)
        if self.tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(self.tls[0], self.tls[1])
            context.set_alpn_protocols(["http/1.1"])
            # 握手放到每条连接自己的线程里（get_request 里握手会卡住整个 accept 循环）
            server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
            original = server.get_request

            def get_request():
                sock, addr = original()
                sock.settimeout(15)
                return sock, addr
            server.get_request = get_request

            def finish_handshake(request, client_address, _process=server.process_request_thread):
                try:
                    request.do_handshake()
                    request.settimeout(READ_SECONDS)
                except (OSError, ssl.SSLError):
                    server.shutdown_request(request)
                    return
                _process(request, client_address)
            server.process_request_thread = finish_handshake
        self._server = server
        threading.Thread(target=self._serve, args=(server,), daemon=True).start()
        self.status = "监听中 %s:%d" % (self.host, self.port)

    def _serve(self, server):
        """监听循环意外退出（select 出错之类）就隔几秒接着跑，别让手机从此连不上；stop() 之后不再重来"""
        delay = 2
        while self._server is server:
            try:
                server.serve_forever(poll_interval=0.5)
                return   # shutdown() 正常结束
            except Exception as exc:  # noqa: BLE001
                log.write("%s 服务故障：%s，%d 秒后自动恢复" % ("HTTPS" if self.tls else "HTTP", exc, delay))
                self.status = "故障，正在恢复"
                time.sleep(delay)
                delay = min(delay * 2, 60)
                if self._server is server:
                    self.status = "监听中 %s:%d" % (self.host, self.port)

    def stop(self):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        self.status = "已停止"


def status_text(code):
    try:
        return HTTPStatus(code).phrase
    except ValueError:
        return ""
