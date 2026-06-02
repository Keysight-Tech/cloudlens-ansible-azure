# Customer Experience Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a world-class polished README + PDF customer runbook so any customer or SE can fully automate CloudLens sensor deployment to Azure VMs.

**Architecture:** Two artifacts, one source of truth. README is the technical entry (3 automated deploy paths, decision tree, compatibility matrix). PDF is the executive deliverable (Keysight-branded, printable). Supporting SVG assets render the visual diagrams in both.

**Tech Stack:** Markdown, SVG (hand-authored), python-docx (Word doc generation), asciinema → terminalizer (GIF), GitHub badges shields.io.

**Design source:** `docs/plans/2026-06-02-customer-experience-design.md`

---

## Pre-flight

**Step 1:** Verify environment
```bash
cd ~/cloudlens-deploy/cloudlens-ansible-azure
git status                                    # expect clean
python3 -c "import docx" 2>&1 || pip install --user --quiet python-docx Pillow
ls docs/plans/2026-06-02-customer-experience-design.md   # expect file
```
Expected: design file exists, python-docx installed.

---

### Task 1: Create assets directory and architecture diagram SVG

**Files:**
- Create: `docs/assets/architecture-diagram.svg`

Hand-author SVG showing: Customer machine → Azure Inventory → 3 OS playbook lanes → CLMS. Use Azure brand blue `#0078D4`, Keysight gold `#D4AF37`. 1200×600 viewport. Show Service Principal auth, tag discovery, OS-conditional connection, CLMS registration.

**Verify:** `open docs/assets/architecture-diagram.svg` — renders cleanly.

**Commit:** `git add docs/assets/architecture-diagram.svg && git commit -m "docs: architecture diagram SVG"`

---

### Task 2: Build the "Which path?" decision tree SVG

**Files:**
- Create: `docs/assets/decision-tree.svg`

Root: "Where will you run this?" → Branch "Azure Portal browser" → Tier 1. Branch "My laptop / CI" → split on "Have Docker?" Yes → Tier 3, No → Tier 2. 900×500 viewport, clear arrows, color-coded paths.

**Verify:** `open docs/assets/decision-tree.svg`

**Commit:** `git add docs/assets/decision-tree.svg && git commit -m "docs: deployment decision tree SVG"`

---

### Task 3: Build the VM compatibility matrix SVG

**Files:**
- Create: `docs/assets/scenario-matrix.svg`

SVG grid. Rows: Ubuntu, RHEL/Rocky/Alma, Windows Server. Columns: Public IP direct, Private + Jumpbox, Azure Bastion, Cloud Shell. ✓ filled cells in Azure blue, "(planned)" cells in gray.

**Verify:** `open docs/assets/scenario-matrix.svg`

**Commit:** `git add docs/assets/scenario-matrix.svg && git commit -m "docs: VM compatibility matrix SVG"`

---

### Task 4: Create the 30-second deploy demo asset

**Files:**
- Create: `docs/assets/deploy-demo.svg` (fallback static terminal screenshot)
- Optional: `docs/assets/deploy-demo.gif` if asciinema/agg available

Try asciinema + agg first. If unavailable, hand-author a styled SVG terminal screenshot showing the curl command, scrolling output, and "Sensors deployed: 3" final line. SVG fallback works on GitHub without binary blobs.

**Verify:** `open docs/assets/deploy-demo.svg`

**Commit:** `git add docs/assets/deploy-demo.* && git commit -m "docs: 30-sec deploy demo asset"`

---

### Task 5: Rewrite README.md — hero section

**Files:** Modify `README.md`

Replace top with: title, 1-line value prop ("Deploy CloudLens sensors to any Azure VM in under 60 seconds."), embedded demo asset, 3 deploy buttons (Portal/Cloud Shell/Docker via shields.io badges), status badges row (tests, last verified, license).

**Commit:** `git add README.md && git commit -m "docs: README hero section with demo + 3 deploy buttons"`

---

### Task 6: Add decision tree + compatibility matrix sections to README

**Files:** Modify `README.md`

Embed `docs/assets/decision-tree.svg` under "Which path?" section. Embed `docs/assets/scenario-matrix.svg` under "Supported VM Scenarios". Add accessible markdown table mirroring the matrix for mobile/screen-readers.

**Commit:** `git add README.md && git commit -m "docs: README decision tree + compatibility matrix"`

---

### Task 7: Rewrite README — 3 deployment paths section

**Files:** Modify `README.md`

Each path: 1 sentence + 1 command + 3-line expected output preview. Link "Full guide →" to corresponding docs section. Keep README scannable.

**Commit:** `git add README.md && git commit -m "docs: README 3-paths section"`

---

### Task 8: Add scaling, verified results, troubleshooting, footer

**Files:** Modify `README.md`

Scaling: single table (VM count / forks / sharded / wall time). Verified: smoke test results from this session (WebServerLB1/LB2/brine-winvm). Troubleshooting: symptom → cause → fix table for top 5. Footer: support, related repos, license.

**Commit:** `git add README.md && git commit -m "docs: README scaling + verified + troubleshooting + footer"`

---

### Task 9: Create CUSTOMER_EMAIL.md template

**Files:** Create `docs/CUSTOMER_EMAIL.md`

Pre-written email SEs send to customer's tech team. Subject + body. Links to GitHub README, PDF runbook, quickstart command. Placeholder fields in `{{ }}` (customer name, CLMS IP). Professional, short, action-oriented tone.

**Commit:** `git add docs/CUSTOMER_EMAIL.md && git commit -m "docs: pre-written customer email template"`

---

### Task 10: Generate Word runbook (.docx) via python-docx script

**Files:**
- Create: `docs/generate_runbook.py`
- Create: `docs/CloudLens_Ansible_Azure_Customer_Runbook.docx`

Python script using python-docx. Style matches existing GWLB Word doc: Keysight blue `#0078D4` headers, styled tables, Courier code blocks. 11 sections per design doc. Cover page with title, version, date.

**Run:** `python3 docs/generate_runbook.py`

**Verify:** `open docs/CloudLens_Ansible_Azure_Customer_Runbook.docx` — all 11 sections render with Keysight branding.

**Commit:** `git add docs/generate_runbook.py docs/CloudLens_Ansible_Azure_Customer_Runbook.docx && git commit -m "docs: Word runbook generator + customer runbook"`

---

### Task 11: Export PDF

**Files:** Create `docs/CloudLens_Ansible_Azure_Customer_Runbook.pdf`

`soffice --headless --convert-to pdf` (LibreOffice) or Microsoft Word automation. Verify visually matches Word doc.

**Commit:** `git add docs/CloudLens_Ansible_Azure_Customer_Runbook.pdf && git commit -m "docs: PDF export of customer runbook"`

---

### Task 12: Push to GitHub + final polish

**Step 1:** `cd ~/cloudlens-deploy/cloudlens-ansible-azure && git log --oneline -15` — expect ~11 doc commits.

**Step 2:** `git push origin main`

**Step 3:** Open https://github.com/Keysight-Tech/cloudlens-ansible-azure — verify GIF/SVG plays, 3 buttons clickable, decision tree visible, mobile-friendly.

**Step 4:** Polish pass: fix any typos, broken links, image scaling on mobile. Commit fixes if any.

---

## Complete

- README has demo + 3 buttons + decision tree + matrix + 3 paths + scaling + verified + troubleshooting
- `docs/CloudLens_Ansible_Azure_Customer_Runbook.docx` + `.pdf` in repo
- `docs/CUSTOMER_EMAIL.md` ready for SE use
- All SVG assets in `docs/assets/`
- Pushed to https://github.com/Keysight-Tech/cloudlens-ansible-azure
