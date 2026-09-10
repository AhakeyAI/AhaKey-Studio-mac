#!/usr/bin/env python3
"""Real-socket regression checks for the persistent client and server."""
import pathlib
import socket
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_lines(connection, count):
    data = b''
    while data.count(b'\n') < count:
        chunk = connection.recv(65536)
        assert chunk, 'Connection closed before complete messages arrived'
        data += chunk
    return data.decode().splitlines()


with tempfile.TemporaryDirectory(prefix='ahakey-') as directory:
    temp = pathlib.Path(directory)
    path = str(temp / 's.sock')

    def compile_program(source, main, name):
        folder = temp / name
        folder.mkdir()
        (folder / 'main.swift').write_text(main)
        binary = folder / name
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(temp / 'cache'),
                        str(ROOT / source), str(folder / 'main.swift'), '-o', str(binary)], check=True)
        return str(binary)

    client = compile_program('Examples/SocketClient/UnixDomainClient.swift',
        (ROOT / 'Examples/SocketClient/main.swift').read_text().replace('/tmp/ahakey.sock', path), 'client')

    # Verify the actual CLI sends two messages on one connection, receives split UTF-8,
    # and remains alive until the peer closes. Repeat to catch the original timing race.
    for attempt in range(10):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(path)
            listener.listen()
            listener.settimeout(3)
            process = subprocess.Popen([client], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(3)
                    assert read_lines(connection, 2) == ['Hello, world', '第二条消息']
                    reply = 'Server 收到：Hello, world\nServer 收到：第二条消息\n'.encode()
                    for chunk in (reply[:8], reply[8:10], reply[10:]):
                        connection.sendall(chunk)
                        time.sleep(0.02)
                    assert process.poll() is None, 'Client exited instead of keeping the connection open'
                output, errors = process.communicate(timeout=3)
                assert process.returncode == 0, (output, errors)
                assert '收到回复：Server 收到：Hello, world' in output, output
                assert '收到回复：Server 收到：第二条消息' in output, output
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        pathlib.Path(path).unlink()
    print('PASS: 10 persistent exchanges; sends after readiness, split UTF-8, multiple replies, peer closure')

    server = compile_program('Examples/SocketServer/UnixDomainServer.swift',
        f'import Foundation\nlet server = UnixDomainServer(socketPath: "{path}")\n'
        'try server.start()\ndispatchMain()\n', 'server')
    process = subprocess.Popen([server], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        # Connect to the actual Swift server and send fragmented and coalesced requests.
        for attempt in range(100):
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                connection.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                connection.close()
                assert process.poll() is None, 'Swift server exited during startup'
                time.sleep(0.02)
        else:
            raise AssertionError('Swift server did not become ready')
        with connection:
            connection.settimeout(3)
            request = '第一条消息\n第二条消息\n'.encode()
            connection.sendall(request[:2])
            time.sleep(0.03)
            connection.sendall(request[2:])
            assert read_lines(connection, 2) == ['Server 收到：第一条消息', 'Server 收到：第二条消息']
            connection.sendall('第三条消息\n'.encode())
            assert read_lines(connection, 1) == ['Server 收到：第三条消息']
        print('PASS: actual Swift server handles split/coalesced requests and later sends on one connection')

        cli = subprocess.Popen([client], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(0.5)
            assert cli.poll() is None, 'CLI did not keep its connection open'
            process.terminate()
            process.wait(timeout=3)
            output, errors = cli.communicate(timeout=3)
            assert '收到回复：Server 收到：Hello, world' in output, (output, errors)
            assert '收到回复：Server 收到：第二条消息' in output, (output, errors)
            print('PASS: actual CLI and Swift server exchange both messages')
        finally:
            if cli.poll() is None:
                cli.kill()
                cli.communicate()
    finally:
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=3)
