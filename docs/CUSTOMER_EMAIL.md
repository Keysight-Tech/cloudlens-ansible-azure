# Customer Email Template: CloudLens Ansible for Azure

> Pre-written email Sales Engineers send to a customer's DevOps / network team
> after a discovery call. Replace `{{ placeholders }}` and send. No edits
> required beyond the placeholders.

---

**To:** `{{ customer_team_email }}`
**Cc:** `{{ se_email }}`, `{{ account_executive_email }}`
**Subject:** CloudLens sensor deployment: automated kit for your Azure environment

---

Hi {{ customer_team_name }},

Following our conversation about deploying CloudLens sensors to your Azure VMs, here is the fully automated kit. It is production-tested against real Azure (Linux and Windows) and scales from a single VM to 5,000+ without changing how you invoke it.

Everything you need is in one GitHub repo. The runbook PDF attached to this email mirrors the README in a printable, executive-friendly format. Same content, same commands, easier to share internally.

**There are 3 ways to deploy. Pick whichever fits how your team works:**

- **Tier 1: one-click from the Azure Portal.** Click "Deploy to Azure" in the README. No local tools and no Service Principal: the portal form asks for the vController address, the project key and your custom tags; the SSH public key field only lets you log in to the runner, so the runner must still be able to reach your VMs with the credentials in customer_input.yaml. An ephemeral runner spins up in your subscription, deploys sensors to every VM tagged cloudlens=yes, and powers itself off an hour later (the `selfDestructMinutes` parameter); the stopped runner VM stays in the group until you delete it.
- **Tier 2: Azure Cloud Shell.** If you are already logged into Azure in your browser, run one `curl` command. Cloud Shell is pre-authenticated, so there is nothing to install.
- **Tier 3: Docker (your laptop or CI/CD).** A pinned container image with Ansible and the Azure collections baked in. Mount your `customer_input.yaml`, pass a Service Principal via env vars, and run. Works identically on macOS, Windows, Linux, GitHub Actions, GitLab CI, and Jenkins.

**Prerequisites**

The dynamic inventory discovers VMs by Azure tag, so before you run the kit, tag every target VM with `cloudlens=yes`, `os=ubuntu|rhel|windows`, and `env=prod|dev`. The default run deploys to the `env=prod` VMs; `env=dev` VMs are reached by passing `-e target_group=ubuntu_dev_vms` (or the `redhat_dev_vms` / `windows_dev_vms` group) to each playbook. There is no `qa` group. The README has copy/paste `az vm update` loops that bulk-tag an entire resource group in one shot.

**What to expect**

A small environment (under 50 VMs) deploys end-to-end in roughly 8 minutes. A few thousand VMs takes 30 to 60 minutes, because the playbook auto-tunes Ansible forks based on inventory size and auto-shards above 2,000 VMs. Every sensor self-registers with vController (formerly CLMS) on first start, so there are no manual UI steps.

**Documentation**

- GitHub repo and README: https://github.com/Keysight-Tech/cloudlens-ansible-azure
- Customer Runbook PDF: attached to this email (also in `docs/` on the repo)

**Support**

If anything blocks you, reply to this thread or reach me directly at `{{ se_email }}` / `{{ se_phone }}`. I will jump on a screen-share within one business day.

Thanks,
{{ se_name }}
Keysight Technologies
