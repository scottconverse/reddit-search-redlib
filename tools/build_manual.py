"""Render the public manual with local PowerShell 7 Markdown support."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
pwsh = shutil.which('pwsh')
if pwsh:
    script_text = r'''param([Parameter(Mandatory=$true)][string]$MarkdownPath)
$ErrorActionPreference = 'Stop'
$markdown = [IO.File]::ReadAllText($MarkdownPath, [Text.Encoding]::UTF8)
$html = (ConvertFrom-Markdown -InputObject $markdown).Html
ConvertTo-Json -InputObject $html -Compress
'''
    temporary_script = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', suffix='.ps1', delete=False) as handle:
            handle.write(script_text)
            temporary_script = Path(handle.name)
        completed = subprocess.run(
            [pwsh, '-NoLogo', '-NoProfile', '-File', str(temporary_script), str(ROOT / 'USER-MANUAL.md')],
            text=True, encoding='utf-8', capture_output=True,
        )
        if completed.returncode:
            raise SystemExit(f'Local PowerShell Markdown render failed: {completed.stderr.strip()}')
        rendered = json.loads(completed.stdout.strip())
    finally:
        if temporary_script and temporary_script.exists():
            temporary_script.unlink()
else:
    raise SystemExit('Rebuilding the browser manual requires PowerShell 7 with ConvertFrom-Markdown; no network renderer is used.')
rendered = rendered.replace('href="skills/', 'href="https://github.com/scottconverse/reddit-search-redlib/blob/main/skills/')
rendered = rendered.replace('href="CHANGELOG.md"', 'href="https://github.com/scottconverse/reddit-search-redlib/blob/main/CHANGELOG.md"')
rendered = rendered.replace('href="README.md"', 'href="https://github.com/scottconverse/reddit-search-redlib/blob/main/README.md"')
rendered = rendered.replace('href="docs/diagrams/', 'href="diagrams/')
rendered = rendered.replace('src="docs/diagrams/', 'src="diagrams/')
# Stable heading links independent of GitHub's generated anchor markup.
rendered = re.sub(r'<h([1-6])[^>]*>(.*?)</h\1>', lambda m: '<h' + m[1] + ' id="' + re.sub(r'[^a-z0-9 -]', '', re.sub('<[^>]+>', '', m[2]).lower()).replace(' ', '-') + '">' + m[2] + '</h' + m[1] + '>', rendered, flags=re.S)
version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="description" content="Installation, everyday use, Windows Redlib setup, troubleshooting, and removal for the Reddit Search + Redlib agent skill."><title>User manual — Reddit Search + Redlib v{version}</title><link rel="stylesheet" href="style.css"></head><body><header><nav class="wrap" aria-label="Main navigation"><a class="brand" href="./"><span class="mark" aria-hidden="true">r</span>Reddit Search + Redlib</a><div class="navlinks"><a href="./">Home</a><a href="https://github.com/scottconverse/reddit-search-redlib">GitHub ↗</a></div></nav></header><main class="manual">'''
page += rendered
page += f'</main><footer class="wrap"><span>Reddit Search + Redlib v{version}</span><a href="./">← Back to Reddit Search + Redlib</a><a href="https://github.com/scottconverse/reddit-search-redlib/blob/main/USER-MANUAL.md">Read the Markdown source</a></footer></body></html>'
(ROOT / 'docs/manual.html').write_text(page, encoding='utf-8', newline='\n')
print('Updated docs/manual.html')
