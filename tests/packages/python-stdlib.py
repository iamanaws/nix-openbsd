"""Exercise SQLite and certificate verification through Python's standard library."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sqlite3
import ssl
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
from urllib.error import URLError
from urllib.request import urlopen


def check_sqlite(directory):
    database = directory / "test.sqlite"
    with sqlite3.connect(database) as connection:
        assert connection.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
        connection.execute("CREATE TABLE values_(value INTEGER)")
        connection.execute("INSERT INTO values_ VALUES (?)", (2**60,))
    try:
        with connection:
            connection.execute("INSERT INTO values_ VALUES (42)")
            raise ValueError("roll back this transaction")
    except ValueError:
        pass
    connection.close()
    with sqlite3.connect(database) as reopened:
        assert reopened.execute("SELECT value FROM values_").fetchall() == [(2**60,)]
        assert reopened.execute("SELECT json_extract('{\"answer\":42}', '$.answer')").fetchone() == (42,)
        assert reopened.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    reopened.close()
    print("PASS Python sqlite3: WAL, commit, rollback, persistence, JSON and integrity")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"native Python TLS"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def expect_certificate_error(url, context):
    try:
        with urlopen(url, context=context, timeout=5):
            pass
    except URLError as error:
        assert isinstance(error.reason, ssl.SSLCertVerificationError), error
    else:
        raise AssertionError("TLS accepted an invalid certificate")


def check_tls(directory):
    certificate = directory / "cert.pem"
    key = directory / "key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-noenc",
        "-keyout", str(key), "-out", str(certificate), "-days", "1",
        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign",
        "-addext", "extendedKeyUsage=serverAuth",
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certificate, key)
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        server.socket = server_context.wrap_socket(server.socket, server_side=True)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_port
            trusted = ssl.create_default_context(cafile=certificate)
            with urlopen(f"https://localhost:{port}", context=trusted, timeout=5) as response:
                assert response.read() == b"native Python TLS"
            expect_certificate_error(f"https://localhost:{port}", ssl.create_default_context())
            expect_certificate_error(f"https://127.0.0.1:{port}", trusted)
        finally:
            server.shutdown()
            thread.join(timeout=5)
    print("PASS Python ssl: HTTPS, trusted CA, untrusted CA and hostname verification")


with TemporaryDirectory() as temporary:
    directory = Path(temporary)
    check_sqlite(directory)
    check_tls(directory)
