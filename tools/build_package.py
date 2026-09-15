"""Build matching ZIP / .skill archives; no network or third-party packages."""
import hashlib
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'skills/reddit-search'
OUT = ROOT / 'dist'
OUT.mkdir(exist_ok=True)
archive_path = OUT / 'reddit-search-redlib.zip'
with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
    for source in sorted(SOURCE.rglob('*')):
        if source.is_file() and '__pycache__' not in source.parts and source.suffix != '.pyc':
            name = 'reddit-search/' + source.relative_to(SOURCE).as_posix()
            info = zipfile.ZipInfo(name, date_time=(2026, 9, 14, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, source.read_bytes())
    for name in ['LICENSE', 'THIRD-PARTY-NOTICES.md']:
        info = zipfile.ZipInfo('reddit-search/' + name, date_time=(2026, 9, 14, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, (ROOT / name).read_bytes())
with zipfile.ZipFile(archive_path) as archive:
    assert archive.testzip() is None
shutil.copyfile(archive_path, OUT / 'reddit-search-redlib.skill')
hashes = []
for path in sorted(OUT.glob('reddit-search-redlib.*')):
    hashes.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name)
(OUT / 'SHA256SUMS.txt').write_text('\n'.join(hashes) + '\n', encoding='utf-8')
print('\n'.join(hashes))
