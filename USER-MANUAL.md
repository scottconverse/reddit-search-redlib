# Reddit Search + Redlib — user manual

## 1. What you are installing

The skill teaches an AI assistant how to find, read, and summarize Reddit discussions. It includes a Python helper that constructs URLs and converts saved responses into structured records. The helper does not search by itself: your assistant fetches the pages and follows the skill's request limits.

Redlib is an optional separate service. It retrieves Reddit content and presents it as HTML. The skill can use that HTML to recover fuller posts and available comment structure. You can start with RSS and add Redlib later.

## 2. Choose your app

### Codex

1. Download and extract the release ZIP.
2. Copy the complete `reddit-search` directory into your home folder's `.agents/skills` directory. On Windows this is normally `C:\Users\YOUR-NAME\.agents\skills\reddit-search`.
3. Keep `SKILL.md`, `scripts`, and `references` together. Do not nest an extra `reddit-search` folder inside it.
4. Start a new turn and ask: “Use the reddit-search skill to find recent discussions about [topic].”

Check existing skill directories first. An older skill with the same name can cause confusion. Keep any backup outside directories the host scans for skills.

### DeepSeek Harness

DSH can load the same folder through its filesystem skill provider. A project-local installation can live at `.dsh/skills/reddit-search` in the project root. For availability across projects, use the DSH home skills directory or configure the existing `@deepseek-ai/dsh-skill-filesystem` row in your agent preset:

```yaml
- id: skill-filesystem
  name: '@deepseek-ai/dsh-skill-filesystem'
  config:
    customSkillDirs:
      - 'C:/path/to/reddit-search-redlib/skills'
```

Edit the existing row; do not add a duplicate provider. The preset also needs DSH's skill catalog/loader components, normally supplied by its standard composition. Do not put this in an MCP configuration: the package is a skill, not an MCP server.

Verify `reddit-search` appears in the session's skill menu/catalog, then explicitly select it for the first search. Our Halo deployment verified discovery; a model completing research in DSH remains a separate check.

### Claude Code

Copy `reddit-search` into `~/.claude/skills/` for personal use or `.claude/skills/` within a project. Start a new session if needed and ask it to use `reddit-search`. Claude Code needs permission to run Python and fetch the requested URLs.

See [Claude Code's skill documentation](https://code.claude.com/docs/en/skills). Compatibility is based on the skill format; this project has not independently completed a Claude Code live trial.

### Claude Desktop and Cowork

Where your account offers custom skills, upload `reddit-search-redlib.zip` through the Skills UI and enable it. The ZIP has one top-level `reddit-search` folder. See [Claude's custom skill instructions](https://support.claude.com/en/articles/12512198-how-to-create-custom-skills).

Skill availability does not establish access to your local machine. A sandbox's `127.0.0.1` may refer to that sandbox rather than Windows. Start by testing RSS, then verify access to the configured Redlib endpoint from the actual execution environment. Don't assume a desktop window means local execution.

## 3. First search

Use a bounded request with an explicit invocation:

> Use reddit-search to compare owners' experiences with [two products]. Read up to three relevant discussions. Include dates and direct links, separate recurring problems from isolated anecdotes, and report any inaccessible or missing comments.

A useful result should identify the discussions read, their dates, and the limits of coverage. It should not cite a Redlib host as the permanent source. Citations should point to the original `www.reddit.com` discussion or comment.

The skill can be selected automatically when its description matches your request, but host/model selection is not guaranteed. If it uses another provider, explicitly select `reddit-search` and inspect the reported tool activity.

## 4. Optional local Redlib on Windows

The native Windows installer uses no WSL or containers. It builds a pinned Redlib revision rather than shipping a binary. The first build can take time and uses compiler resources.

**Prerequisites:** PowerShell 7, Git for Windows, Rust configured for `x86_64-pc-windows-msvc`, and Visual C++ Build Tools with the C++ workload. The setup script can supply missing CMake, LLVM/Clang, and a hash-verified NASM download. `-SkipPrerequisiteInstall` requires those to be installed already.

You can ask a local coding assistant:

> Using reddit-search's bundled Windows instructions, install local Redlib and start it. Use the default loopback address. Verify a real Reddit-backed request, not just health. Report whether it is installed, running, and usable. Do not add a startup task or service.

For manual use, open PowerShell 7 in the repository and run:

```powershell
pwsh -NoProfile -File skills/reddit-search/scripts/setup_redlib_windows.ps1 -Start
```

Default location: `%LOCALAPPDATA%\RedditSearch\Redlib`.
Default address: `http://127.0.0.1:18080`.

The script pins source revision `a4d36e954cf1bd64f209cd8868c5a29edc81b374`. The displayed version may still say `0.36.0`; compare the commit rather than the version alone. This pin was usable in the Windows trial, but Reddit's upstream behavior can change.

### Start, check, stop

```powershell
pwsh -NoProfile -File skills/reddit-search/scripts/start_redlib_windows.ps1
pwsh -NoProfile -File skills/reddit-search/scripts/test_redlib_windows.ps1
pwsh -NoProfile -File skills/reddit-search/scripts/stop_redlib_windows.ps1
```

You can instead ask your local assistant to perform these actions. The start script launches Redlib without a console window. Closing a browser tab does not stop it. No startup task or Windows service is installed; it must be started again after a reboot.

The test reports three separate states:

| State | Meaning |
|---|---|
| Installed | The executable and installation record exist |
| Running | The expected local process answers health checks |
| Usable | A Reddit-backed content request also succeeds |

Use Redlib only when the last state is true. If it is blocked upstream, fall back to RSS and disclose partial coverage. Advanced endpoint and build details are in [windows-redlib.md](skills/reddit-search/references/windows-redlib.md).

## 5. What the results mean

- **Complete:** For a retrieved Redlib thread, the parser found as many comment bodies as the page reports and no detected “more” placeholders. This is relative to that response, not a guarantee of every Reddit comment ever posted.
- **Partial:** Some content is omitted or the RSS format cannot establish complete coverage.
- **Unknown:** The response does not supply enough information to establish completeness, as with search pages.

Scores are observations at fetch time, not proof that a claim is true. Null means unavailable, not zero. RSS cannot reliably establish nested comment parents, so those fields remain null. Redlib provides nesting where its HTML includes it.

Request pacing and retry limits are instructions followed by the assistant, not a system-wide traffic limiter. Multiple agents sharing an IP need coordination. On rate limits, honor Retry-After and stop within the task budget; do not hammer or rotate through public servers.

## 6. Troubleshooting

| Symptom | What to check |
|---|---|
| Skill is missing | Correct host directory; `reddit-search/SKILL.md` is one level below it; no extra nested folder; new turn/session |
| Assistant uses native search | Explicitly select `reddit-search`; check for older conflicting skills or host instructions |
| Connection refused on 18080 | Redlib is stopped, or your host is inside a different sandbox |
| Health works, content fails | Run the usability check; upstream Reddit may be blocking access |
| HTTP 429 | Stop requests to that host, respect Retry-After, and report partial coverage if the budget expires |
| Thread parse failure | Save the status, content type, Redlib revision, and minimal relevant HTML; the upstream layout may have changed |
| Missing comments | Check retrieved vs reported counts; missing content is not a reason to claim completeness |
| Windows Unicode error | Ensure you are running the updated parser; it configures UTF-8 itself |

When reporting a bug, include the parser command, Python/PowerShell versions, Redlib commit if used, and the error. Remove private queries or credentials. [Open an issue](https://github.com/scottconverse/reddit-search-redlib/issues).

## 7. Update or remove

To update, back up the existing skill outside scanned directories, replace the whole folder with the new release, and start a fresh turn/session. Updating the skill does not automatically rebuild or update Redlib.

To remove, delete the installed `reddit-search` skill folder. If you also want to remove local Redlib, stop it first with its bundled script, then remove its `%LOCALAPPDATA%\RedditSearch\Redlib` installation directory. Redlib installed no automatic startup entry. Shared build tools such as Git, Rust, and Visual Studio are separate and should be retained if other projects use them.

## 8. For developers

The parser uses the Python standard library. It accepts saved content or stdin and emits UTF-8 JSON. It never chooses public instances or silently fetches a URL.

```sh
python skills/reddit-search/scripts/reddit_extract.py url rss-search --query "local LLM memory"
python skills/reddit-search/scripts/reddit_extract.py parse rss --input saved.atom --source-url "https://www.reddit.com/search.rss?q=local"
python -m unittest discover -s skills/reddit-search/scripts/tests -v
python tools/build_package.py
```

The public tests use synthetic content with representative RSS/Redlib markup. Windows live-test results are documented in the README; CI checks parser behavior on Windows and Linux without requesting Reddit pages or building Redlib.
