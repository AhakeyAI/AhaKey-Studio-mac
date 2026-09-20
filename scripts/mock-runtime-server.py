#!/usr/bin/env python3
"""Loopback-only WebSocket fixture for frontend development. Never accesses hardware.

Prints a private discovery file path on stdout. Stop with Ctrl-C.
Uses only Python's standard library; implements the frontend's current protocol subset.
"""
import base64
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import signal
import struct
import tempfile
import threading

FIXTURES = Path(__file__).resolve().parents[1] / 'contracts/runtime-v1/fixtures'


def fixture(name):
    return json.loads((FIXTURES / f'{name}.json').read_text())


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.Lock()
        self.document = fixture('configuration')
        self.operations = {}
        self.requests = {}
        self.sequence = 9007199254740993
        self.device = fixture('subscription')['snapshot']['devices'][0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() != 'websocket' or self.headers.get('Origin'):
            self.send_error(400)
            return
        key = self.headers.get('Sec-WebSocket-Key', '')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.authenticated = False
        self.subscribed = False
        self.subscription_id = secrets.token_hex(12)
        try:
            while True:
                data = self.read_message()
                if data is None:
                    return
                request = json.loads(data)
                with self.server.lock:
                    self.handle_rpc(request)
        except (ConnectionError, EOFError, OSError, ValueError, KeyError):
            return
        finally:
            self.close_connection = True

    def exact(self, size):
        value = self.rfile.read(size)
        if len(value) != size:
            raise EOFError()
        return value

    def read_message(self):
        message = bytearray()
        while True:
            first, second = self.exact(2)
            opcode = first & 15
            length = second & 127
            if length == 126:
                length = struct.unpack('!H', self.exact(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.exact(8))[0]
            if not second & 128 or length > 1048576 or len(message) + length > 1048576:
                raise ValueError('invalid client frame')
            mask = self.exact(4)
            data = bytes(v ^ mask[i % 4] for i, v in enumerate(self.exact(length)))
            if opcode == 8:
                return None
            if opcode == 9:
                self.frame(data, opcode=10)
                continue
            if opcode not in (0, 1):
                raise ValueError('text only')
            message.extend(data)
            if first & 128:
                return message.decode()

    def frame(self, data, opcode=1):
        length = len(data)
        header = bytes([128 | opcode])
        if length < 126:
            header += bytes([length])
        elif length < 65536:
            header += bytes([126]) + struct.pack('!H', length)
        else:
            header += bytes([127]) + struct.pack('!Q', length)
        self.wfile.write(header + data)
        self.wfile.flush()

    def send(self, value):
        self.frame(json.dumps(value).encode())

    def result(self, request, value):
        self.send({'jsonrpc': '2.0', 'id': request['id'], 'result': value})

    def error(self, request, code):
        self.send({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32000, 'message': code, 'data': {'code': code}}})

    def event(self, kind, data):
        self.server.sequence += 1
        if self.subscribed:
            self.send({'jsonrpc': '2.0', 'method': 'runtime.event', 'params': {
                'subscriptionId': self.subscription_id, 'instanceId': 'fixture-runtime',
                'sequence': str(self.server.sequence), 'type': kind, 'data': data,
            }})

    def handle_rpc(self, request):
        method = request['method']
        params = request.get('params', {})
        if method == 'runtime.hello':
            self.authenticated = secrets.compare_digest(params.get('token', ''), self.server.token)
            if not self.authenticated:
                return self.error(request, 'PERMISSION_DENIED')
            return self.result(request, fixture('hello'))
        if not self.authenticated:
            return self.error(request, 'PERMISSION_DENIED')
        if method == 'runtime.subscribe':
            self.subscribed = True
            subscription = fixture('subscription')
            subscription['subscriptionId'] = self.subscription_id
            subscription['snapshot'].update(sequence=str(self.server.sequence), devices=[self.server.device], operations=list(self.server.operations.values()))
            return self.result(request, subscription)
        if method == 'operation.get':
            operation = self.server.operations.get(params['operationId'])
            return self.result(request, operation) if operation else self.error(request, 'OPERATION_NOT_FOUND')
        if params.get('deviceId') != self.server.device['deviceId']:
            return self.error(request, 'DEVICE_NOT_FOUND')
        if method == 'configuration.get':
            return self.result(request, self.server.document)
        if method in ('device.connect', 'device.disconnect'):
            self.server.device['connectionState'] = 'ready' if method == 'device.connect' else 'disconnected'
            self.result(request, {})
            return self.event('device.changed', self.server.device)
        if method == 'configuration.apply':
            operation_id = params['operationId']
            if operation_id in self.server.requests:
                if self.server.requests[operation_id] != params:
                    return self.error(request, 'OPERATION_ID_CONFLICT')
                return self.result(request, {'operationId': operation_id, 'status': self.server.operations[operation_id]['status']})
            if params['baseToken'] != self.server.document['baseToken']:
                return self.error(request, 'BASE_CONFLICT')
            if self.server.device['connectionState'] != 'ready':
                return self.error(request, 'DEVICE_NOT_READY')
            self.server.requests[operation_id] = copy.deepcopy(params)
            self.result(request, {'operationId': operation_id, 'status': 'accepted'})
            current = self.server.document['configuration']
            for mode in params['changes']['modes']:
                current['modes'] = [m for m in current['modes'] if m['mode'] != mode['mode']] + [mode]
            current['device'] = params['changes']['device']
            self.server.document['baseToken'] = str(int(self.server.document['baseToken']) + 1)
            operation = {'operationId': operation_id, 'deviceId': params['deviceId'], 'status': 'completed', 'progress': 1, 'effect': 'complete'}
            self.server.operations[operation_id] = operation
            self.event('operation.changed', operation)
            return self.event('configuration.changed', {'deviceId': params['deviceId']})
        self.error(request, 'UNSUPPORTED_CAPABILITY')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='ahakey-runtime-fixture-') as directory:
        server = FixtureServer()
        path = Path(directory) / 'discovery.json'
        path.write_text(json.dumps({'endpoint': f'ws://127.0.0.1:{server.server_port}/', 'token': server.token}))
        path.chmod(0o600)
        print(path, flush=True)
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
