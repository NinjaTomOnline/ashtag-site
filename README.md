# QuitGentle Public Site

This is the public GitHub Pages site repo for QuitGentle.

The source of truth for the site content lives in the private app repo and is exported here with:

`bash /Users/ninjatom/Documents/CODEX_ASHTAG/Scripts/export_public_site_repo.sh /absolute/path/to/ashtag-site`

The exported repo includes `Scripts/verify_public_site_export.rb` and `docs/PUBLIC_SITE_EXPORT_ASSERTIONS.json` so public CI can fail if page metadata, Open Graph, Twitter, support links, or required launch copy drift.

Do not edit this repo by hand unless you also carry the same change back into the private app repo.
