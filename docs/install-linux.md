# Installing open-pulsar on Linux — Beginner's Guide

This guide walks you through installing open-pulsar on a Linux computer, step by step. No prior programming experience is required. Every command is explained so you know what you're running and why.

---

## What is open-pulsar?

open-pulsar is a tool that lets you give an AI (Claude) a to-do list of programming tasks, and it will work through them automatically — one by one — and track its own progress. You write your tasks in a simple text file, run one command, and the AI does the rest.

---

## What you'll need

- A computer running Linux (Ubuntu, Debian, Fedora, or similar)
- An internet connection
- An **Anthropic account** with an API key (free to create — instructions below)
- About 15 minutes

---

## Step 1 — Open a Terminal

A terminal is a text window where you type commands. Here's how to open one:

- **Ubuntu / Debian**: Press `Ctrl + Alt + T`
- **Fedora**: Press the Super key (⊞ Windows key), type *Terminal*, and press Enter
- **Any Linux**: Right-click the desktop → *Open Terminal*

You'll see a blinking cursor. That's where you type the commands in this guide.

> **Tip:** When you see a line starting with `$`, that's a command for you to type (don't type the `$` itself — it's just showing you the prompt).

---

## Step 2 — Install Required Tools

open-pulsar needs three programs installed on your system. Copy and paste these commands one at a time, pressing Enter after each.

### 2a — Update your package list

```bash
$ sudo apt update
```

> If you're on **Fedora** or **RHEL**, use `sudo dnf update` instead of `sudo apt update`. All `apt` commands below have a `dnf` equivalent.

It will ask for your password. Type it (nothing appears as you type — that's normal) and press Enter.

### 2b — Install `git` (downloads code from the internet)

```bash
$ sudo apt install git
```

Press `Y` and Enter if asked to confirm.

### 2c — Install `jq` (reads data files)

```bash
$ sudo apt install jq
```

### 2d — Verify both installed correctly

```bash
$ git --version
$ jq --version
```

You should see version numbers printed for each. If you see *command not found*, go back and repeat the install step for that tool.

---

## Step 3 — Install Node.js

The Claude Code CLI (which open-pulsar uses to talk to the AI) requires Node.js. Install it with:

```bash
$ sudo apt install nodejs npm
```

Check it worked:

```bash
$ node --version
```

You should see something like `v18.0.0` or higher. If the version shown is below `v18`, run these commands instead to get a newer version:

```bash
$ curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
$ sudo apt install nodejs
```

---

## Step 4 — Install the Claude Code CLI

Claude Code is Anthropic's official command-line tool that open-pulsar uses to talk to the AI. Install it with:

```bash
$ sudo npm install -g @anthropic-ai/claude-code
```

Verify it installed:

```bash
$ claude --version
```

You should see a version number.

---

## Step 5 — Get an Anthropic API Key

The Claude Code CLI needs a key to authenticate with Anthropic's AI servers.

1. Go to **https://console.anthropic.com** in your web browser
2. Sign up for a free account (or log in if you have one)
3. Click your account name in the top-right → **API Keys**
4. Click **Create Key**, give it a name (e.g. `open-pulsar`), and copy the key — it starts with `sk-ant-...`

Now tell your terminal about this key. Replace `your-key-here` with the actual key you copied:

```bash
$ echo 'export ANTHROPIC_API_KEY="your-key-here"' >> ~/.bashrc
$ source ~/.bashrc
```

> This saves the key permanently so you don't have to re-enter it every time you open a terminal.

Verify it's set:

```bash
$ echo $ANTHROPIC_API_KEY
```

You should see your key printed back.

---

## Step 6 — Download open-pulsar

Now download the open-pulsar code to your computer:

```bash
$ git clone https://github.com/open-pulsar/open-pulsar.git
```

Move into the downloaded folder:

```bash
$ cd open-pulsar
```

Make the main script executable (tells Linux it's allowed to run):

```bash
$ chmod +x agent-loop.sh
```

---

## Step 7 — Test the Installation

Run a quick check to make sure everything is working:

```bash
$ ./agent-loop.sh --version
```

You should see the version of open-pulsar printed. If you do — congratulations, it's installed!

---

## Step 8 — Run Your First Task

Create a simple task file to try it out:

```bash
$ nano my-first-tasks.md
```

This opens a text editor in your terminal. Type the following (copy exactly, including the `##` and `-`):

```
## Hello World

- Create a file called hello.txt containing the text "Hello from open-pulsar!"
```

Save and exit: press `Ctrl + O`, then Enter, then `Ctrl + X`.

Now run it:

```bash
$ ./agent-loop.sh my-first-tasks.md
```

open-pulsar will connect to Claude and execute the task. When it finishes, check the result:

```bash
$ cat hello.txt
```

You should see: `Hello from open-pulsar!`

---

## Troubleshooting

| Problem | What to do |
|---|---|
| `command not found: claude` | Re-run Step 4. Make sure npm installed without errors. |
| `command not found: jq` | Re-run Step 2c. |
| `Error: ANTHROPIC_API_KEY not set` | Re-run Step 5. Then close and reopen your terminal. |
| `Permission denied` | Make sure you ran `chmod +x agent-loop.sh` in Step 6. |
| `npm: command not found` | Re-run Step 3. |
| Claude returns an auth error | Double-check your API key at console.anthropic.com — make sure it wasn't accidentally truncated when you pasted it. |

If you're still stuck, open an issue on the project's GitHub page.

---

## What's Next?

- Read `README.md` in the open-pulsar folder to learn about more features like groups, retries, and status tracking.
- Try writing a more complex task file with multiple steps.
- Explore the `--dry-run` flag to preview what will run without actually executing anything:

```bash
$ ./agent-loop.sh --dry-run my-first-tasks.md
```

---

*Guide written for open-pulsar. Linux distributions covered: Ubuntu 22.04+, Debian 12+, Fedora 38+.*
