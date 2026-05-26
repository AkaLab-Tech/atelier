# atelier

An atelier of AI agents for autonomous software delivery. You describe what you want done; atelier writes the code, runs the tests, opens a pull request, reviews it, and saves the result — without you having to know what a branch is.

## First time?

Read the **[Operator Guide](docs/operator-guide.md)** — a Jr-friendly walkthrough from zero to your first task. It covers prerequisites, the full install, setting up your first project, and writing the first task. About 30 minutes from start to finish.

## Already have Claude Code + GitHub set up?

`atelier` ships through the [AkaLab-Tech plugin catalog](https://github.com/AkaLab-Tech/claude-plugins). The plugin alone (without `install.sh`'s host-OS layer — `git-wt`, the `task`/`atelier` shell functions, the isolated config root) gets you the slash commands but not the full workflow:

```
/plugin marketplace add AkaLab-Tech/claude-plugins
/plugin install atelier@akalab-tech
```

The same `marketplace add` step exposes the other AkaLab-Tech plugins (e.g. install [`claude-roadmap-tools`](https://github.com/AkaLab-Tech/claude-roadmap-tools) with `/plugin install claude-roadmap-tools@akalab-tech`).

For the full setup (recommended), run [`install.sh`](install.sh) per the [Operator Guide](docs/operator-guide.md). Subsequent atelier updates use the plugin manager: `/plugin marketplace update akalab-tech` then `/plugin update atelier@akalab-tech`.

## Other docs

- [PLAN.md](PLAN.md) — full design source of truth (architecture, milestones, decisions).
- [docs/dogfood-guide.md](docs/dogfood-guide.md) — integration-test guide for end-to-end validation on a real machine.
- [ROADMAP.md](ROADMAP.md) — what's queued, what's open, what's blocked.
