"""Exercise the compiled service behind Caddy HTTPS using disposable local fixtures."""
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import ssl
import subprocess
import tempfile
import time
import uuid


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()


def main():
    prefix = 'zyren-review-test-' + uuid.uuid4().hex[:10]
    network, data, caddy_data = prefix, prefix + '-data', prefix + '-tls'
    service, proxy = prefix + '-service', prefix + '-proxy'
    writer, reader = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    with tempfile.TemporaryDirectory(prefix='zyren-review-deploy-') as temporary:
        root = Path(temporary)
        access = root / 'access.json'
        access.write_text(json.dumps({'schemaVersion': 1, 'documentId': 'review', 'grants': [
            {'tokenSha256': hashlib.sha256(token.encode()).hexdigest(), 'role': role}
            for token, role in [(writer, 'writer'), (reader, 'reader')]]}))
        caddyfile = root / 'Caddyfile'
        caddyfile.write_text('localhost {\n tls internal\n reverse_proxy review:8080\n}\n')
        try:
            docker('network', 'create', network)
            docker('volume', 'create', data)
            docker('volume', 'create', caddy_data)
            docker('run', '-d', '--name', service, '--network', network, '--network-alias', 'review',
                   '-e', 'ZYREN_REVIEW_BIND=0.0.0.0', '-e', 'ZYREN_REVIEW_PROXY=caddy',
                   '--mount', f'type=bind,src={access},dst=/run/secrets/review_access,readonly',
                   '--mount', f'type=volume,src={data},dst=/data', 'zyren-review:local')
            docker('run', '-d', '--name', proxy, '--network', network, '-p', '127.0.0.1::443',
                   '--mount', f'type=bind,src={caddyfile},dst=/etc/caddy/Caddyfile,readonly',
                   '--mount', f'type=volume,src={caddy_data},dst=/data', 'caddy:2')
            port = int(docker('port', proxy, '443/tcp').rsplit(':', 1)[1])
            cert = root / 'root.crt'
            for attempt in range(40):
                result = subprocess.run(['docker', 'cp', proxy + ':/data/caddy/pki/authorities/local/root.crt', str(cert)], capture_output=True)
                if result.returncode == 0:
                    break
                time.sleep(.25)
            context = ssl.create_default_context(cafile=str(cert))

            def request(method, token, document=None, version=None):
                connection = http.client.HTTPSConnection('localhost', port, context=context, timeout=5)
                headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}
                if version is not None:
                    headers['If-Match'] = version
                try:
                    connection.request(method, '/review', None if document is None else json.dumps(document), headers)
                    response = connection.getresponse()
                    body = response.read()
                    return response.status, response.getheader('etag'), json.loads(body) if body and response.status == 200 else None
                finally:
                    connection.close()

            for attempt in range(40):
                try:
                    status, version, document = request('GET', reader)
                    if status == 200:
                        break
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(.25)
            else:
                raise RuntimeError('HTTPS service did not become ready.')
            assert status == 200
            assert request('PUT', reader, document, version)[0] == 403
            document['objects'] = [{'id': 'cad-part', 'label': 'Housing', 'properties': {}}]
            status, committed, _ = request('PUT', writer, document, version)
            assert status == 200 and committed != version
            assert request('PUT', writer, document, version)[0] == 412
            docker('restart', service)
            for attempt in range(40):
                status, recovered, actual = request('GET', writer)
                if status == 200:
                    break
                time.sleep(.25)
            assert status == 200 and recovered == committed and actual == document
            print('PASS: verified HTTPS, reader/writer grants, stale-write rejection and Linux container restart persistence')
        finally:
            for name in (proxy, service):
                subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
            subprocess.run(['docker', 'network', 'rm', network], capture_output=True)
            for volume in (data, caddy_data):
                subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True)


if __name__ == '__main__':
    main()
