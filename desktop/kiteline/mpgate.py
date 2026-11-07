"""开源版不含这个入口：替身（Gate.start 直接报错，入口不启动；其余代码照常运行）"""

DEFAULT_PORT = 8768


def remote_allowed():
    return False


class Gate:
    status = "未启用"

    def __init__(self, route, host_name):
        self.relay = None

    def start(self, host, port):
        raise OSError("not included in this build")

    def stop(self):
        pass


class RelayLink:
    def __init__(self, gate, relay):
        pass

    def start(self):
        pass

    def stop(self):
        pass
