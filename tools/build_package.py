"""Build matching ZIP / .skill archives; no network or third-party packages."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'skills/reddit-search'
OUT = Path(os.environ.get('REDDIT_SEARCH_PACKAGE_OUT', ROOT / 'dist'))
PROJECT_VERSION_PATH = ROOT / 'VERSION'
PACKAGE_DOC_FILES = ('README.md', 'USER-MANUAL.md', 'CHANGELOG.md')
DIAGRAM_FILES = ('reddit-research-flow.svg', 'windows-install-flow.svg')
VERSIONED_DOC_FILES = ('README.md', 'USER-MANUAL.md', 'CHANGELOG.md', 'docs/index.html', 'docs/manual.html', 'docs/diagrams/windows-install-flow.svg')
REQUIRED_SKILL_FILES = {
    'SKILL.md',
    'scripts/reddit_extract.py',
    'scripts/install_windows.ps1',
    'scripts/get_redlib_config.ps1',
    'scripts/redlib_windows_common.ps1',
    'scripts/setup_redlib_windows.ps1',
    'scripts/start_redlib_windows.ps1',
    'scripts/start_redlib_daemon_windows.ps1',
    'scripts/test_redlib_windows.ps1',
    'scripts/tests/test_redlib_start_detach.ps1',
    'scripts/stop_redlib_windows.ps1',
    'references/access-and-schema.md',
    'references/windows-redlib.md',
}
version = PROJECT_VERSION_PATH.read_text(encoding='utf-8').strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit(f'Invalid semantic version in VERSION: {version!r}')
skill_manifest = (SOURCE / 'SKILL.md').read_text(encoding='utf-8')
metadata_version = re.search(r'(?m)^metadata:\s*\n\s+version:\s*["\']?(\d+\.\d+\.\d+)["\']?\s*$', skill_manifest)
if not metadata_version:
    raise SystemExit('skills/reddit-search/SKILL.md must declare metadata.version.')
if metadata_version.group(1) != version:
    raise SystemExit(f'SKILL.md metadata.version {metadata_version.group(1)} does not match VERSION {version}.')
for relative in (*VERSIONED_DOC_FILES, *(f'docs/diagrams/{name}' for name in DIAGRAM_FILES)):
    path = ROOT / relative
    if not path.is_file():
        raise SystemExit(f'Missing release documentation file: {relative}')
for relative in VERSIONED_DOC_FILES:
    path = ROOT / relative
    if version not in path.read_text(encoding='utf-8'):
        raise SystemExit(f'{relative} does not display project version {version}.')
if f'## {version} ' not in (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8'):
    raise SystemExit(f'CHANGELOG.md has no entry for version {version}.')
missing = sorted(name for name in REQUIRED_SKILL_FILES if not (SOURCE / name).is_file())
if missing:
    raise SystemExit('Skill package is incomplete; missing: ' + ', '.join(missing))
OUT.mkdir(parents=True, exist_ok=True)
archive_path = OUT / 'reddit-search-redlib.zip'


def normalized_text(path):
    """Keep every shipped text resource byte-stable across CRLF/LF checkouts."""
    return path.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')


def archive_info(name):
    """Construct ZIP entries with identical creator and file attributes on all OSes."""
    info = zipfile.ZipInfo(name, date_time=(2026, 9, 14, 0, 0, 0))
    info.create_system = 3  # Unix, independent of the host running this build.
    info.create_version = zipfile.DEFAULT_VERSION
    info.extract_version = zipfile.DEFAULT_VERSION
    info.external_attr = 0o100644 << 16
    info.internal_attr = 0
    info.flag_bits = 0
    info.extra = b''
    info.comment = b''
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
    for source in sorted(SOURCE.rglob('*'), key=lambda item: item.relative_to(SOURCE).as_posix()):
        if source.is_file() and '__pycache__' not in source.parts and source.suffix != '.pyc':
            name = 'reddit-search/' + source.relative_to(SOURCE).as_posix()
            info = archive_info(name)
            archive.writestr(info, normalized_text(source))
    for name in ['LICENSE', 'THIRD-PARTY-NOTICES.md']:
        info = archive_info('reddit-search/' + name)
        archive.writestr(info, normalized_text(ROOT / name))
    for name in ('VERSION', *PACKAGE_DOC_FILES):
        info = archive_info('reddit-search/' + name)
        archive.writestr(info, normalized_text(ROOT / name))
    for name in DIAGRAM_FILES:
        relative = 'docs/diagrams/' + name
        info = archive_info('reddit-search/' + relative)
        archive.writestr(info, normalized_text(ROOT / relative))
with zipfile.ZipFile(archive_path) as archive:
    assert archive.testzip() is None
    members = set(archive.namelist())
    missing = sorted('reddit-search/' + name for name in REQUIRED_SKILL_FILES if 'reddit-search/' + name not in members)
    if missing:
        raise SystemExit('Built skill archive is incomplete; missing: ' + ', '.join(missing))
    if any(name.lower().endswith('.exe') for name in members):
        raise SystemExit('Skill archive must not bundle a Redlib executable.')
    required_package_docs = {
        'reddit-search/VERSION',
        *(f'reddit-search/{name}' for name in PACKAGE_DOC_FILES),
        *(f'reddit-search/docs/diagrams/{name}' for name in DIAGRAM_FILES),
    }
    missing_docs = sorted(required_package_docs - members)
    if missing_docs:
        raise SystemExit('Built package is missing documentation files: ' + ', '.join(missing_docs))
    if archive.read('reddit-search/VERSION').decode('utf-8').strip() != version:
        raise SystemExit('Built package version does not match the project VERSION.')
    packaged_manifest = archive.read('reddit-search/SKILL.md').decode('utf-8')
    packaged_version = re.search(r'(?m)^metadata:\s*\n\s+version:\s*["\']?(\d+\.\d+\.\d+)["\']?\s*$', packaged_manifest)
    if not packaged_version or packaged_version.group(1) != version:
        raise SystemExit('Built skill metadata.version does not match the project VERSION.')
    for relative in PACKAGE_DOC_FILES:
        if version not in archive.read('reddit-search/' + relative).decode('utf-8'):
            raise SystemExit(f'Built package documentation {relative} does not show version {version}.')
shutil.copyfile(archive_path, OUT / 'reddit-search-redlib.skill')
hashes = []
for path in sorted(OUT.glob('reddit-search-redlib.*')):
    hashes.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name)
(OUT / 'SHA256SUMS.txt').write_bytes(('\n'.join(hashes) + '\n').encode('utf-8'))
print('\n'.join(hashes))
