"""Build an isolated package map for a committed shared bridge revision."""
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
from urllib.parse import urljoin

root = Path(__file__).resolve().parents[3]
revision = subprocess.check_output(['git', 'rev-parse', '828955b^{commit}'], cwd=root, text=True).strip()
destination = Path(tempfile.mkdtemp(prefix='zyren-committed-bridge-'))
source = subprocess.check_output(['git', 'archive', revision, 'packages/zyren_agents', 'packages/zyren_devtools'], cwd=root)
with tarfile.open(fileobj=io.BytesIO(source)) as archive:
    archive.extractall(destination, filter='data')
original = root / '.dart_tool/package_config.json'
config = json.loads(original.read_text())
for package in config['packages']:
    package['rootUri'] = urljoin(original.as_uri(), package['rootUri'])
    if package['name'] in {'zyren_agents', 'zyren_devtools'}:
        package['rootUri'] = (destination / 'packages' / package['name']).as_uri() + '/'
(destination / '.dart_tool').mkdir()
path = destination / '.dart_tool/package_config.json'
path.write_text(json.dumps(config, indent=2) + '\n')
(destination / 'source.json').write_text(json.dumps({'revision': revision, 'packages': ['zyren_agents', 'zyren_devtools']}, indent=2) + '\n')
print(json.dumps({'config': str(path), 'cli': str(destination / 'packages/zyren_devtools/bin/zyren.dart'), 'revision': revision}))
