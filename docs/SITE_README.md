# CloudLens Ansible for Azure: Landing Site

This directory contains the static GitHub Pages site published at:

**https://keysight-tech.github.io/cloudlens-ansible-azure/**

## Files

| File | Purpose |
|---|---|
| `index.html` | Single page landing site, all 8 sections |
| `styles.css` | Theming, layout, dark mode, responsive |
| `script.js` | Wizard, scaling slider, theme toggle, smooth scroll |
| `assets/*.svg` | Architecture and demo diagrams (copied from `docs/assets`) |
| `.nojekyll` | Prevents GitHub Pages from running Jekyll on this folder |

## Enable GitHub Pages

1. Open the repo on GitHub: `https://github.com/Keysight-Tech/cloudlens-ansible-azure`
2. Go to **Settings** → **Pages**
3. Under **Build and deployment**, set:
   - **Source:** Deploy from a branch
   - **Branch:** `main`
   - **Folder:** `/docs/site`
4. Click **Save**
5. Wait 60 to 120 seconds. The site goes live at `https://keysight-tech.github.io/cloudlens-ansible-azure/`

The `.nojekyll` file in this folder tells GitHub Pages to serve the HTML directly without Jekyll processing.

## Local preview

Open `index.html` directly in a browser, or run a quick local server:

```bash
cd docs/site
python3 -m http.server 8080
# Visit http://localhost:8080
```

## Updating the site

- Hero copy and tier buttons are in `index.html` near the top
- Brand colors and dark mode tokens are CSS variables at the top of `styles.css`
- The scaling slider bands are defined in `script.js` (`bandFor` function)
- If you regenerate the SVGs in `docs/assets/`, copy them here:
  ```bash
  cp docs/assets/*.svg docs/site/assets/
  ```

## Self contained, no build step

The site is pure HTML, CSS, and vanilla JavaScript. No npm, no bundler, no framework. Total page weight under 60 KB (excluding SVG assets).
