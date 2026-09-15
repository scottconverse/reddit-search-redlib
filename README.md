# Reddit Search + Redlib

**Give your AI assistant a repeatable way to research Reddit—with direct citations and honest coverage.**

[Get started](https://scottconverse.github.io/reddit-search-redlib/) · [User manual](USER-MANUAL.md) · [Download](https://github.com/scottconverse/reddit-search-redlib/releases/latest) · [Report an issue](https://github.com/scottconverse/reddit-search-redlib/issues)

This is an **Agent Skill**: research instructions, a small Python parser, and optional native Windows scripts for [Redlib](https://github.com/redlib-org/redlib). Your assistant performs the research using its existing network and execution tools. There is no new model, hosted search subscription, or MCP server to configure.

## What it does

- Finds discussions through Reddit RSS and, when configured, Redlib search.
- Reads full posts and available comments through Redlib, including reply relationships, scores, and dates when exposed.
- Produces structured records with direct `reddit.com` permalinks.
- Preserves text order, code indentation, and table columns.
- Reports missing comments and incomplete coverage rather than pretending it read everything.
- Paces requests and falls back when an access path fails.

Redlib is optional. RSS works independently when Reddit permits access. The parser itself does not make network requests; the assistant controls fetching, pacing, and the research budget.

## Try a prompt

> Use the reddit-search skill to compare real owners' experiences with 128 GB Strix Halo PCs for local coding models. Read the relevant discussions and comments. Separate measured results from opinions, cite dates and direct Reddit links, and tell me what you couldn't retrieve.

For a simpler request: **“Use reddit-search to find recurring complaints about [product].”** Explicit invocation is the clearest first check; automatic selection depends on your host and model.

## Install with your assistant

Download the skill from [Releases](https://github.com/scottconverse/reddit-search-redlib/releases/latest), or give a local coding assistant this prompt:

> Install the reddit-search skill from https://github.com/scottconverse/reddit-search-redlib into this app's supported skill directory. Use the folder skills/reddit-search and preserve its scripts and references. Check for an older copy first. Verify skill discovery and run one small Reddit search. Start with RSS. If local Redlib is already installed, verify both its health and its ability to retrieve Reddit content before using it. Report the installation path and what actually worked.

For manual installation, copy the entire `skills/reddit-search` folder:

| Host | Destination / method | Verification status |
|---|---|---|
| Codex | `~/.agents/skills/reddit-search/` | Live search and parsing verified on Windows |
| DeepSeek Harness | A scanned skill directory or the existing skill provider's `customSkillDirs` | Live skill discovery verified in DSH 0.1.5-rc.2; autonomous DSH research not yet verified |
| Claude Code | `~/.claude/skills/reddit-search/` | Compatible format; not independently tested here |
| Claude Desktop / Cowork | Upload the ZIP through the available Skills UI | Host execution/network access must be verified; local Redlib may not be reachable from its sandbox |

The `.skill` and `.zip` release assets contain the same skill folder. Use `.zip` where the host requires ZIP uploads. A cloud-hosted chat cannot reach a server on your PC just because you upload the skill.

## Requirements

- A host that can load skills, fetch URLs, and run Python.
- **Python 3.10+**; no third-party Python packages.
- **PowerShell 7 on Windows** for the optional Redlib lifecycle scripts.
- For building local Redlib: Git, Rust with the MSVC target, and Visual C++ Build Tools. The setup script can install missing CMake/LLVM and download verified NASM. See the [manual](USER-MANUAL.md#4-optional-local-redlib-on-windows).

## What has been checked

The Windows live trial returned 22 RSS posts, 25 correctly linked Redlib search results, and a discussion with 23 of 23 reported comments. A separate discussion returned 35 of 44 comments and was correctly marked partial. These are observations from one trial, not uptime or completeness guarantees.

Regression tests cover Unicode under Windows legacy encoding, real-layout thread validation, flair-vs-title selection, comment grouping, nested reply metadata, text ordering, and partial coverage. Public fixtures contain synthetic content so the project does not distribute captured user discussions.

```sh
python -m unittest discover -s skills/reddit-search/scripts/tests -v
python tools/build_package.py
```

## Limits that matter

Reddit can rate-limit or block either access path. Redlib may omit comments. Its HTML layout can change. RSS may truncate content and does not establish the full reply tree. A healthy local server is not proof that upstream Reddit access works. The skill documents separate checks for installation, process health, and usable content.

No Reddit login or API key is required by this workflow. A public Redlib operator can see requests sent to their instance. Prefer your own instance; don't send it private information or rotate through volunteer instances to evade blocks.

## Project layout

```text
skills/reddit-search/   Installable skill, parser, references, Windows scripts, tests
docs/                  Public landing page and browser-readable manual
USER-MANUAL.md         Setup, everyday use, troubleshooting, and removal
tools/                 Reproducible release packaging
```

## License and credits

The skill and helper code are MIT licensed. Redlib is a separate upstream project under AGPL-3.0; no Redlib executable or source is bundled in the skill release. Its optional installer retrieves a pinned upstream revision and preserves its license and source. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Created by Scott Converse. Independent project; not affiliated with Reddit, Anthropic, OpenAI, or DeepSeek.
