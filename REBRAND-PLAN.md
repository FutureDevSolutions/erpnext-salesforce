# ERPNext Rebrand Plan

**Repo:** `erpnext-salesforce` (fork of `frappe/erpnext`)
**Written:** 2026-08-21
**Audience:** an engineer or agent starting fresh, with no prior conversation context.

---

## 0. Context — read this first

**Goal:** cosmetically rebrand this ERPNext fork (name, logo, colors, domain), deploy it on our own infrastructure, and sell it as a hosted SaaS product with ongoing maintenance and custom features layered on top.

**Licensing position (already researched and settled — do not re-litigate):**

| Component | License | Consequence |
|-----------|---------|-------------|
| ERPNext (this repo) | **GPL-3.0** | Hosting as SaaS triggers **no** source-disclosure duty. GPL has no network clause. |
| Frappe Framework (`frappe/frappe`, separate repo) | **MIT** | Verified 2026-08-21. Clean and compatible. |
| `banking/` subdirectory | **GPL-3.0** via root `license.txt` | Verified upstream (`frappe/erpnext` PR #54720). **Keep it.** |

Selling hosted access is permitted. Rebranding is permitted, and is in fact *required* by Frappe's trademark policy for any commercial operator — the policy explicitly welcomes ERPNext-based businesses but forbids using the ERPNext name or logo in a product, company, service, or domain name.

**When we later ship on-prem builds**, GPL §6 applies: that customer must receive the complete corresponding source of our modified version. That is accepted and priced in.

Full background: `../REBRANDING-ASSESSMENT.md`.

---

## 1. ⛔ HARD RULES — things that must NEVER be renamed

**A naive `sed -i 's/erpnext/ourbrand/g'` across this repo will destroy it and put us in breach of the GPL.** Read this section before touching anything.

### Rule 1 — `app_name` stays `erpnext`. Permanently.

In `erpnext/hooks.py` line 1:

```python
app_name = "erpnext"   # ⛔ NEVER CHANGE
```

This single string is load-bearing across the entire Frappe platform:

| It determines | Example |
|---------------|---------|
| Python import paths | `from erpnext.accounts...`, `erpnext.templates.utils.send_message` |
| Asset URLs | `/assets/erpnext/images/...`, `/assets/erpnext/icons/...` |
| JS/CSS bundle names | `erpnext.bundle.js`, `erpnext-web.bundle.css`, `email_erpnext.bundle.css` |
| Hook callbacks | `has_permission: "erpnext.check_app_permission"` |
| The bench app directory | `apps/erpnext/` |
| **Database records** | `tabModule Def`, and the `module` field on every DocType row |

Renaming it breaks imports, 404s every asset, and orphans live database records. **The app's internal identity and its brand are separate things.** Users never see `app_name`. Leave it alone.

### Rule 2 — Never touch copyright headers

**1,826 files carry a header like:**

```python
# Copyright (c) 2015, Frappe Technologies Pvt. Ltd. and contributors
```

Stripping these is **copyright infringement and a GPL-3.0 violation**, independent of anything else we do. GPLv3 §5(a) requires preserved notices. These are attribution, not branding.

> The rebrand replaces **trademarks**. It never removes **copyright attribution**. These are different things and the distinction is the whole legal basis for what we're doing.

### Rule 3 — Never bulk-replace `ERPNext` in Python

`ERPNext` appears 1,342 times in `.py` files. **~96% are code identifiers, not user-visible text:**

| Identifier | Count | Note |
|------------|------:|------|
| `ERPNextTestSuite` | 1,275 | Test base class — renaming breaks the whole suite |
| `ERPNextDeprecationWarning` | 4 | Exception class |
| `ERPNextDeprecationError` | 3 | Exception class |
| `ERPNextAddress` | 2 | Referenced by string in `hooks.py` → `extend_doctype_class` |
| bare `ERPNext` | ~52 | Comments, docstrings, deprecation messages — **the only real candidates** |

Only **2** translatable user-facing strings in the entire Python codebase contain "ERPNext".

### Rule 4 — Never bulk-replace lowercase `erpnext`

5,507 occurrences in `.py`, 1,898 in `.js`, 120 in `.json`. These are import paths, asset paths, and module references. All internal. All must stay.

### Rule 5 — Do not touch `erpnext/public/images/bank-logos/`

88 files. These are **third-party trademarks** (Chase, HSBC, Citi, Barclays…) used for bank-account identification in the UI. Not ours to restyle, and altering them creates a different trademark problem than the one we're solving.

### Rule 6 — Do not rename modules in `erpnext/modules.txt`

Contains `ERPNext Integrations`. It is user-visible **and** a database record **and** a directory name (`erpnext/erpnext_integrations/`). Changing it desynchronises code from `tabModule Def`. Leave it; the cost of fixing it exceeds the branding benefit.

---

## 2. The real surface is small

The headline numbers are misleading. Once identifiers, imports, and copyright headers are excluded, the genuine user-visible rebrand surface is:

| Layer | Scale | Effort |
|-------|------:|--------|
| `hooks.py` branding config | ~10 lines | 🟢 Trivial |
| Brand image assets | 9 files | 🟢 Small |
| Outbound URLs to erpnext.com / frappe.io | ~16 | 🟢 Small |
| Bare `ERPNext` in messages/docstrings | ~52 | 🟡 Manual review |
| Print formats | 83 JSON | 🟡 Audit needed |
| Translations (`locale/*.po`) | 38 files | 🟡 Scripted |
| Runtime config (not code) | — | 🟢 Post-deploy |

**This is a configuration-and-assets job, not a mass find-and-replace.** Budget accordingly.

---

## 3. Tier 1 — `erpnext/hooks.py` (the 80% win)

Everything user-facing about app identity is concentrated in the first ~25 lines. Change these:

```python
app_name = "erpnext"                                   # ⛔ LEAVE UNCHANGED
app_title = "ERPNext"                                  # ✅ → "<OurBrand>"
app_publisher = "Frappe Technologies Pvt. Ltd."        # ⚠️ see note below
app_description = """ERP made simple"""                # ✅ → our tagline
app_icon = "fa fa-th"                                  # ✅ → our icon class
app_color = "#e74c3c"                                  # ✅ → our brand color
app_email = "hello@frappe.io"                          # ✅ → our support email
app_license = "GNU General Public License (v3)"        # ⛔ LEAVE — still true
source_link = "https://github.com/frappe/erpnext"      # ✅ → OUR source repo
app_logo_url = "/assets/erpnext/images/erpnext-logo.svg"  # ✅ swap FILE CONTENT, keep path
app_home = "/desk/home"                                # ⛔ leave
```

Also update the `add_to_apps_screen` block (lines 13–22) — its `logo` and `title` keys — but **leave its `name` and `has_permission` keys alone** (they reference `app_name`).

**⚠️ On `app_publisher`:** setting this to our company is legitimate — we are the publisher of this modified distribution. But it must be accompanied by preserved upstream copyright headers (Rule 2) and a modification notice (§8). Publisher ≠ copyright holder.

**⚠️ On `app_logo_url`:** change the **file's contents**, not the path. The path contains `/assets/erpnext/` which is derived from `app_name`.

---

## 4. Tier 2 — Brand assets (9 files)

Replace the artwork; **keep every filename and path exactly as-is** (they're referenced from code, hooks, and the database).

| File | Purpose |
|------|---------|
| `erpnext/public/images/erpnext-logo.svg` | Primary logo — referenced by `app_logo_url` |
| `erpnext/public/images/erpnext-logo.png` | Raster fallback |
| `erpnext/public/images/erpnext-logo-blue.png` | Alt colorway |
| `erpnext/public/images/erpnext-favicon.svg` | Favicon |
| `erpnext/public/images/v16/erpnext.svg` | v16 logo (used in README) |
| `erpnext/public/images/v16/hero_image.png` | README hero image |
| `erpnext/public/images/erpnext-video-placeholder.jpg` | Onboarding video placeholder |
| `erpnext/public/desktop_icons/erpnext_settings.svg` | Settings icon |
| `erpnext/public/icons/desktop_icons/{solid,subtle}/erpnext_settings.svg` | Settings icons (2 files) |

**Do not touch:** `bank-logos/` (88 third-party marks), `leaflet/` (map library assets), `illustrations/`.

---

## 5. Tier 3 — User-visible strings and URLs

### 5a. Outbound URLs (~16 occurrences)

These appear in `.py`, `.js`, and `.html` and send our users to the upstream vendor. Repoint to our own docs, or remove:

```
https://frappe.io/erpnext?source=website_footer
https://frappe.io/erpnext?source=via_email_footer
https://frappe.io/school?utm_source=in_app
https://erpnext.com/docs/...            (several)
https://docs.frappe.io/erpnext/...      (several)
https://frappecloud.com/marketplace/apps/payments
```

Find them all with:

```bash
grep -rn --include="*.py" --include="*.js" --include="*.html" \
  -E "https?://[a-z0-9.-]*(erpnext|frappe)[a-z0-9.-]*" erpnext
```

> Leave `https://frappeframework.com/docs/...` links that appear in **developer-facing code comments** — they document the framework API and have no user-visible effect.

### 5b. Translatable strings (2 occurrences)

```
_("Frappe CRM data synchronization is not enabled on ERPNext. Contact System Manager of ERPNext.")
_("[Important] [ERPNext] Auto Reorder Errors")
```

The second is an **email subject line** — genuinely customer-visible. Change both.

### 5c. Bare `ERPNext` in messages (~52)

Review individually. Most are comments and docstrings (zero user impact — leave them; churn creates merge conflicts). The ones that matter are `frappe.msgprint` / `frappe.throw` deprecation warnings under `erpnext/patches/`, which *do* surface in the UI. List candidates:

```bash
grep -rn --include="*.py" "ERPNext" erpnext \
  | grep -v "ERPNextTestSuite\|ERPNextDeprecation\|ERPNextAddress\|Copyright"
```

### 5d. Print formats (83 JSON files)

`find erpnext -path '*print_format*' -name '*.json'` — these generate customer-facing PDFs (invoices, quotes, delivery notes). Audit for embedded logos, footers, or "Powered by" strings. **High visibility to end customers — do not skip.**

### 5e. Translations (38 `locale/*.po` files)

All 38 contain "ERPNext". Script the replacement, but only in `msgstr` (translated output), never in `msgid` (the lookup key — changing it silently breaks translation matching).

---

## 6. Tier 4 — Runtime configuration (no code changes)

Frappe exposes brand controls as **database settings**, configurable post-deploy. Prefer these over code edits wherever both are possible — they survive upstream merges for free.

- **Website Settings** — brand image, favicon, banner, footer, copyright line
- **Navbar Settings** — navbar branding and menu items
- **System Settings** — app name shown in the desk UI

Capture whatever is set here as a versioned fixture or migration so environments stay reproducible.

---

## 7. Recommended approach — a re-appliable patch, not hand edits

Upstream is highly active (commits landing within the last week). **Hand-editing will rot.**

Build the rebrand as a **scripted transform** that runs against a clean upstream checkout:

1. Keep `main` tracking upstream `frappe/erpnext`.
2. Keep the rebrand on a separate branch or as a script in `scripts/rebrand/`.
3. On each upstream release: fetch, merge, re-run the transform, verify.

The transform should be **explicit allow-list, never regex-across-the-tree** — it should touch only the specific files and keys listed in §3–§5.

---

## 8. ⚖️ License compliance — mandatory, not optional

These are obligations, not suggestions:

- [ ] **Preserve all 1,826 upstream copyright headers.** Never strip or rewrite them.
- [ ] **Keep `license.txt`** (GPL-3.0) unmodified at repo root.
- [ ] **Keep `attributions.md`** and add to it rather than replacing it.
- [ ] **Add a modification notice** (GPLv3 §5a): prominent statement that we modified ERPNext, with dates. A `NOTICE.md` at repo root plus a line in the app's About dialog satisfies this.
- [ ] **Keep `app_license = "GNU General Public License (v3)"`** in `hooks.py` — it remains accurate.
- [ ] **Point `source_link` at our own repository**, not upstream's.
- [ ] **No additional restrictions in our ToS** (GPLv3 §7). We cannot forbid customers from redistributing source we give them.
- [ ] **Remove or repoint upstream telemetry** so a rebranded product doesn't phone home to Frappe.
- [ ] **Record the `banking/` provenance note** (code originated in `The-Commit-Company/mint`, AGPLv3, contributed upstream by its own copyright holder) in the compliance file.

---

## 9. Verification checklist

After the transform, confirm:

- [ ] `bench build` succeeds — no missing assets
- [ ] App loads; logo and favicon render
- [ ] `grep -rn "app_name = " erpnext/hooks.py` still reads `"erpnext"`
- [ ] `grep -rc "Frappe Technologies" erpnext --include="*.py" | ...` — header count still **1,826**
- [ ] Test suite passes (`ERPNextTestSuite` intact)
- [ ] No broken `/assets/erpnext/...` URLs in browser console
- [ ] A generated PDF invoice shows our branding, not ERPNext's
- [ ] No outbound links to erpnext.com or frappe.io in user-facing UI
- [ ] Desk UI, login page, and email footers all show our brand

---

## 10. Out of scope

- ❌ Renaming the Frappe app (`app_name`) — see Rule 1
- ❌ Renaming DocTypes or modules — database-coupled
- ❌ Feature development — separate workstream, layered as custom Frappe apps via `hooks.py`
- ❌ The `banking/` directory — resolved as ordinary GPL ERPNext code; treat like any other
- ❌ Frappe Framework itself — separate MIT repo, not forked here

---

## 11. Open questions for the operator

1. **Brand name, color palette, and logo assets** — not yet chosen. Blocks Tiers 1 and 2.
2. **Source-publication URL** — needed for `source_link` and for GPL §6 on-prem compliance.
3. **Support email and docs domain** — needed for `app_email` and §5a URL repointing.
4. **On-prem source delivery mechanism** — source alongside binary, or GPLv3 §6b written offer?

---

*Numbers in this document were measured directly against this checkout on 2026-08-21. Re-measure after any upstream merge before relying on them.*
