"""Render the public manual using GitHub Markdown (requires authenticated gh CLI)."""
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
gh = shutil.which('gh')
if not gh:
    raise SystemExit('Install and authenticate GitHub CLI before rebuilding the manual.')
source = (ROOT / 'USER-MANUAL.md').read_text(encoding='utf-8')
rendered = subprocess.run(
    [gh, 'api', 'markdown', '--input', '-'],
    input=json.dumps({'text': source, 'mode': 'markdown'}),
    text=True, encoding='utf-8', capture_output=True, check=True,
).stdout
rendered = rendered.replace('href="skills/', 'href="https://github.com/scottconverse/reddit-search-redlib/blob/main/skills/')
# Stable heading links independent of GitHub's generated anchor markup.
rendered = re.sub(r'<h([1-6])[^>]*>(.*?)</h\1>', lambda m: '<h' + m[1] + ' id="' + re.sub(r'[^a-z0-9 -]', '', re.sub('<[^>]+>', '', m[2]).lower()).replace(' ', '-') + '">' + m[2] + '</h' + m[1] + '>', rendered, flags=re.S)
page = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="description" content="Installation, everyday use, Windows Redlib setup, troubleshooting, and removal for the Reddit Search + Redlib agent skill."><title>User manual — Reddit Search + Redlib</title><link rel="stylesheet" href="style.css"></head><body><header><nav class="wrap" aria-label="Main navigation"><a class="brand" href="./"><span class="mark" aria-hidden="true">r</span>Reddit Search + Redlib</a><div class="navlinks"><a href="./">Home</a><a href="https://github.com/scottconverse/reddit-search-redlib">GitHub ↗</a></div></nav></header><main class="manual">'''
page += rendered
page += '</main><footer class="wrap"><a href="./">← Back to Reddit Search + Redlib</a><a href="https://github.com/scottconverse/reddit-search-redlib/blob/main/USER-MANUAL.md">Read the Markdown source</a></footer></body></html>'
(ROOT / 'docs/manual.html').write_text(page, encoding='utf-8')
print('Updated docs/manual.html')
