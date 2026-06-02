# Customer Experience Design — README + PDF Runbook

**Status:** Approved
**Date:** 2026-06-02
**Owner:** Brine Ketum (Keysight Technologies)
**Repo:** github.com/Keysight-Tech/cloudlens-ansible-azure

---

## Purpose

Polish the customer-facing documentation so any customer or Sales Engineer can fully automate CloudLens sensor deployment to Azure VMs without ambiguity. Two artifacts, one source of truth.

## Audience

- **Primary:** Customer DevOps / network engineers deploying sensors to their Azure VMs
- **Secondary:** Keysight Sales Engineers demoing the solution to enterprise prospects
- **Tertiary:** Customer executives / procurement reviewing the PDF runbook

## Success Criteria

A customer with no prior context can:
1. Land on the GitHub README and identify their deployment path in under 30 seconds
2. Run a single command and have sensors deployed in under 10 minutes for a small (<50 VM) environment
3. Trust the solution because verified results are visible up front
4. Share a polished PDF with their executive team without modification

## Design Principle

**Every page pushes the customer toward the fully-automated path.** No manual steps, no copy-paste loops. Every section ends with a command or button they can execute.

## Artifacts

### 1. README.md (Technical "wow")

Sections in order:

1. **Hero** — 30-second deploy GIF, then 3 deploy buttons (Portal / Cloud Shell / Docker), then status badges
2. **"Which path?" decision tree** — 3 questions → tier recommendation
3. **VM compatibility matrix** — visual grid (OS × Topology × Auth Method)
4. **The 3 deployment paths** — one sentence + one command + expected output each
5. **Scaling table** — VM count → forks → wall time
6. **Verified against Azure** — smoke test results table
7. **Troubleshooting decision tree** — symptom → cause → fix
8. **Footer** — support contacts, related repos, license

### 2. CloudLens_Ansible_Azure_Customer_Runbook.docx (Executive "wow")

Style matches the existing GWLB Word doc (Keysight blue headers, styled tables, Courier code blocks, professional layout).

Sections:
1. Cover page (Keysight branding, version, date)
2. Executive summary (1 page)
3. Solution overview (architecture diagram + traffic flow)
4. Customer decision tree
5. Prerequisites checklist (printable)
6. Deployment — 3 paths with screenshots
7. Verification checklist (printable)
8. Scaling guide
9. Troubleshooting reference
10. Appendix: customer input schema, supported VM matrix, GitHub quick links

Distribution: Both `.docx` (editable) and `.pdf` (final form) in `docs/`.

## Supporting Assets

| File | Format | Purpose |
|---|---|---|
| `docs/assets/deploy-demo.gif` | GIF | 30-sec terminal cast for README hero |
| `docs/assets/decision-tree.svg` | SVG | "Which path?" picker, used in both README and PDF |
| `docs/assets/scenario-matrix.svg` | SVG | Visual VM compatibility grid |
| `docs/assets/architecture-diagram.svg` | SVG | High-level system architecture |
| `docs/CUSTOMER_EMAIL.md` | Markdown | Pre-written email template SEs send to customers |

## Hero Section — Decided Layout

Order on the README:

```
[Logo / title]
[1-line value prop]
[30-second deploy GIF]
[3 big deploy buttons: Portal | Cloud Shell | Docker]
[Status badges: Tests | Verified | Sensors deployed]
```

Rationale: GIF earns attention, buttons convert it to action. (Per smoke-test feedback "A + C".)

## VM Compatibility Coverage

The matrix must visually communicate full coverage. Cells documented as ✓ supported:

| OS / Topology | Public IP direct | Private + Jumpbox | Azure Bastion | Cloud Shell |
|---|---|---|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 | ✓ | ✓ | ✓ | ✓ |
| RHEL 7 / 8 / 9 | ✓ | ✓ | ✓ | ✓ |
| CentOS / Rocky / AlmaLinux | ✓ | ✓ | ✓ | ✓ |
| Windows Server 2019 / 2022 | ✓ | (planned) | (planned) | ✓ |

Anything not yet tested gets "(planned)" — honest, not aspirational.

## Verified Results Table

Real numbers from this session's smoke test:

| Scenario | Result |
|---|---|
| WebServerLB1 (Ubuntu 22.04, private IP via jumpbox) | ✓ Sensor running |
| WebServerLB2 (Ubuntu 22.04, private IP via jumpbox) | ✓ Sensor running |
| brine-winvm (Windows Server 2022, WinRM direct) | ✓ Sensor running |
| CLMS registration | ✓ All 3 sensors registered |
| End-to-end time | 8 minutes |

## Decisions Locked In

- **Format:** README (Markdown) + Word doc + PDF export
- **Hero priority:** GIF first, then 3 deploy buttons (Option A + C combined)
- **PDF style:** Matches existing GWLB customer runbook
- **Audience:** SE-facing AND customer-facing, dual mode
- **Automation emphasis:** Every section ends with an executable command or button
- **No** GitHub Pages site (Option B rejected — adds maintenance burden, README is sufficient entry point)
- **No** onboarding video script (Option D rejected — GIF is enough for now)

## Out of Scope

- Translated versions (English only for v1)
- Customer portal / SaaS deployment runner
- Integration with Keysight customer support portal
- AWX / Tower template export (separate work, mentioned in docs/SCALING.md)

## Implementation Plan

See `docs/plans/2026-06-02-customer-experience-implementation.md` (to be written next via writing-plans skill).
