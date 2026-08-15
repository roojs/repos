# Setup guide

Step-by-step instructions for getting the roojs APT repository live.

Work through one section at a time. Do not skip ahead.

---

## 1. Create the GPG signing key

The APT repo must be signed. GitHub Actions holds the **private** key as a secret; clients download the **public** key from `KEY.gpg` on GitHub Pages.

### Step 1.1 — Start key generation

On your own machine (not in the browser), open a terminal and run:

```bash
gpg --full-generate-key
```

### Step 1.2 — Key type

When you see:

```
Please select what kind of key you want:
```

Type **`9`** and press **Enter**.

That selects **ECC (sign and encrypt)** — the modern default. Do not pick RSA unless you have a specific reason.

### Step 1.3 — Elliptic curve

When you see:

```
Please select which elliptic curve you want:
```

Press **Enter** to accept the default (**Curve 25519**).

### Step 1.4 — Expiry

When you see:

```
Please specify how long the key should be valid for.
```

Type **`2y`** and press **Enter** (two years). You can renew later.

Confirm with **`y`** if it asks.

### Step 1.5 — Your identity

Fill in the prompts:

| Prompt | What to enter |
|--------|----------------|
| Real name | `roojs apt signing` (or your name) |
| Email address | an email you control |
| Comment | optional — e.g. `repos apt` |

Confirm with **`O`** (for Okay) when the summary looks right.

### Step 1.6 — Passphrase

Choose a passphrase and remember it. You will add it to GitHub as `APT_GPG_PASSPHRASE`.

GnuPG may ask you to move the mouse or type to gather randomness — that is normal.

### Step 1.7 — Export the private key

List your new key:

```bash
gpg --list-secret-keys --keyid-format LONG
```

Look for a line like `sec   ed25519/ABCD1234EF567890  …` — the part after the `/` is your **key ID**.

Export it:

```bash
gpg --armor --export-secret-keys YOUR_KEY_ID > signing-key.asc
```

Replace `YOUR_KEY_ID` with the actual id from the line above.

Keep `signing-key.asc` private. You will paste its contents into GitHub in the next section.

---

## 2. Add GitHub repository secrets

1. Open **https://github.com/roojs/repos/settings/secrets/actions**
2. Click **New repository secret**
3. Add:

| Name | Value |
|------|--------|
| `APT_GPG_PRIVATE_KEY` | entire contents of `signing-key.asc` |
| `APT_GPG_PASSPHRASE` | the passphrase you chose in step 1.6 |

---

## 3. GitHub Actions permissions

1. Open **https://github.com/roojs/repos/settings/actions**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Save

The workflow must be able to push commits to `gh-pages`.

---

## 4. Enable GitHub Pages

1. Open **https://github.com/roojs/repos/settings/pages**
2. **Source:** Deploy from a branch
3. **Branch:** `gh-pages` → `/ (root)`
4. Save

After the first successful workflow run, the site will be at **https://roojs.github.io/repos/**

---

## 5. Publish the repository

**Automatic:** the workflow runs daily at 06:00 UTC and on every push to `main`.

**Manual:** open **Actions → Publish package repositories → Run workflow** on `main`.

Optional manual input: comma-separated `repos` (e.g. `ibus-sherpa-onnx,sherpa-onnx`) to refresh only specific upstream projects.

After a successful run, check **https://github.com/roojs/repos/tree/gh-pages** for `dists/`, `pool/`, and `KEY.gpg`.

### Keeping scheduled runs alive

GitHub **disables scheduled workflows** if the repository has had no commits, issues, PRs, or other activity for **60 days**.

This repository uses three safeguards:

1. **Daily publish** — successful runs commit to `gh-pages`, which counts as activity.
2. **Keepalive workflow** — [`.github/workflows/keepalive.yml`](../.github/workflows/keepalive.yml) commits on the **1st and 15th** of each month.
3. **Dependabot** — [`.github/dependabot.yml`](../.github/dependabot.yml) opens monthly PRs to bump GitHub Actions versions.

**External backup (optional):** trigger a publish from outside GitHub if you ever need to wake the repo up manually:

```bash
gh workflow run publish-repos.yml -R roojs/repos
```

Or send a `repository_dispatch` event (requires a token with `repo` scope):

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/roojs/repos/dispatches \
  -d '{"event_type":"publish-repos"}'
```

Any push, issue, or PR on the repository also re-enables schedules for the next run.

---

## 6. Test on a machine

See [Client installation](../README.md#client-installation) in the README.

On each machine, use only the suite that matches the OS (`trixie`, `questing`, or `resolute`).
