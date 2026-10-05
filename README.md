<p align="center"><img src="fetelabs/brand/out/lockup-light-ground.svg" alt="FeteLABS" width="360"></p>

# FeteLABS

FeteLABS is the back office for Caribbean businesses: promoters, venues,
restaurants and bars, salons and pros, shops and the people who run them.
It runs the till, events and their tickets, the online shop, stock,
invoices, the team and the customer list in one place.

It is a fork of [Odoo](https://github.com/odoo/odoo) Community 19.0, made by
[Fete Labs](https://fetelabs.ai), the studio behind
[FetePass](https://fetepass.app).

## What is different from Odoo

* **Only what applies in the Caribbean.** Accounting localisations for other
  countries, and payment, card-terminal and shipping integrations that do not
  operate in the region, are removed. 414 of Odoo's 662 modules ship. The
  list, with a reason for every removal, is
  [`fetelabs/modules.json`](fetelabs/modules.json).
* **The FeteLABS name and icon** on the login page, the browser tab, the
  installable app, emails, the customer portal, receipts and the point of
  sale's customer display. Five small addons do it, `fetelabs_branding` and
  its `_mail`, `_portal`, `_website` and `_pos` bridges, and they install
  themselves.
* **No Enterprise upsell.** Apps and settings that only exist in Odoo
  Enterprise are not offered.

### Files changed in place

Everything above is an addon except these, which have to work before any
addon loads (the database manager, the offline page, the installable app's
icons) or are Odoo's default pictures:

* `addons/web/static/img/` — favicon, logos and app icons, drawn by
  `fetelabs/brand/make-logos.mjs`
* `odoo/addons/base/static/img/res_company_logo.png` — a new company's logo
* `addons/web/static/src/public/database_manager.qweb.html` — the page title
  and two sentences
* `addons/payment/data/payment_provider_data.xml` — the records for removed
  payment providers, dropped by `prune.py`

## Which islands have a localisation

| Island | Localisation |
|---|---|
| Dominican Republic | `l10n_do` (ITBIS, NCF) |
| Guadeloupe, Martinique | `l10n_gp`, `l10n_mq`, with the French e-invoicing modules |
| St. Barth, French St. Martin | `l10n_fr_account` |
| Puerto Rico, US Virgin Islands | `l10n_us_account` |
| Bonaire, Saba, St. Eustatius | `l10n_nl` |
| Every other island | the generic chart, with the island's VAT or sales tax set up as taxes |

Odoo publishes no localisation for the English-speaking islands, Aruba,
Curaçao, Sint Maarten or Haiti.

## Installing it

Both installers back up and remove an existing Odoo first (asking before
anything is deleted), then install FeteLABS so it starts with the computer
and shows up with the Fete Labs icon.

**Zorin OS, Ubuntu, Debian** (run as yourself, not root):

```sh
curl -fsSLO https://raw.githubusercontent.com/FetePass/odoo/fetelabs-19.0/fetelabs/install/install-linux.sh
bash install-linux.sh
```

**Mac** (macOS 12 or later, in Terminal):

```sh
curl -fsSLO https://raw.githubusercontent.com/FetePass/odoo/fetelabs-19.0/fetelabs/install/install-mac.sh
bash install-mac.sh
```

**Windows 10 and 11** (PowerShell, "Run as administrator"):

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/FetePass/odoo/fetelabs-19.0/fetelabs/install/install-windows.ps1 -OutFile install-windows.ps1
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

Then open http://localhost:8069, create your company database with the
master password the installer saved (in your home folder on Linux, on the
desktop on Windows), and choose your island as the country.

`--keep-odoo` / `-KeepOdoo` installs without touching Odoo. To run it by
hand instead: `pip install -r requirements.txt phonenumbers`, then
`./odoo-bin -d fetelabs -i base` against Postgres 13 or later.

## Keeping up with Odoo

```sh
git remote add upstream https://github.com/odoo/odoo
git fetch upstream 19.0
git merge upstream/19.0
python3 fetelabs/prune.py --apply   # removes anything new that does not apply
python3 fetelabs/prune.py --check   # exits 1 if anything is left to prune
```

A merge can bring back a module this fork removed, as a conflict on a
deleted file. Resolve it by deleting the file again; `prune.py --apply` does
that. The logos are drawn by
[`fetelabs/brand/make-logos.mjs`](fetelabs/brand/make-logos.mjs); re-run it
if an upstream merge replaces one of the image files.

## Licence

LGPL-3.0, as Odoo. See [LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT).
"Odoo" is a trademark of Odoo S.A. FeteLABS is not affiliated with or
endorsed by Odoo S.A.
