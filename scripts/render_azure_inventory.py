#!/usr/bin/env python3
"""Build the azure_rm inventory the Docker image deploys against.

Inside the image, customer_input.yaml is the only file a customer controls:
inventory/azure_rm.yaml is baked in. customer_input.yaml documents
azure.tag_filters, azure.resource_groups and azure.locations, so they have to
take effect here, or a customer who tags VMs their own way finds 0 VMs.

Usage: render_azure_inventory.py CUSTOMER_INPUT OUT_DIR

Copies inventory/ to OUT_DIR (group_vars/ must sit next to the inventory file
or Ansible never loads it), writes OUT_DIR/generated.azure_rm.yaml when
customer_input.yaml narrows discovery, and prints the inventory path to use.
Without those keys it prints OUT_DIR/azure_rm.yaml: the shipped filter,
cloudlens=yes.
"""
import os
import re
import shutil
import sys

import yaml

# Keys and values are placed inside a Jinja expression in the plugin's
# exclude_host_filters, so only plain tag characters are accepted.
SAFE = re.compile(r"^[A-Za-z0-9_.:/@+=-]+$")


def fail(msg):
    sys.stderr.write("customer_input.yaml: " + msg + "\n")
    sys.exit(2)


def as_tag_value(v):
    # Unquoted yes/no/true in YAML arrives as a bool; Azure tags are strings.
    if isinstance(v, bool):
        return "yes" if v else "no"
    return str(v)


def main():
    if len(sys.argv) != 3:
        fail("usage: render_azure_inventory.py CUSTOMER_INPUT OUT_DIR")
    ci_path, out_dir = sys.argv[1], sys.argv[2]
    with open(ci_path) as f:
        ci = yaml.safe_load(f) or {}
    if not isinstance(ci, dict):
        fail("expected a mapping at the top level")
    az = ci.get("azure") or {}

    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    shutil.copytree("inventory", out_dir,
                    ignore=shutil.ignore_patterns("generated.*"))

    tags = az.get("tag_filters") or {}
    rgs = [str(r) for r in (az.get("resource_groups") or []) if r]
    locs = [str(x) for x in (az.get("locations") or []) if x]
    if not isinstance(tags, dict):
        fail("azure.tag_filters must be a mapping, for example  cloudlens: \"yes\"")

    base = os.path.join(out_dir, "azure_rm.yaml")
    if not (tags or rgs or locs):
        print(base)
        return

    with open(base) as f:
        inv = yaml.safe_load(f)

    for label, items in (("azure.resource_groups", rgs), ("azure.locations", locs)):
        for item in items:
            if not SAFE.match(item):
                fail("%s entry %r has characters an Azure name cannot contain" % (label, item))

    if tags:
        filters = []
        for k, v in tags.items():
            k, v = str(k), as_tag_value(v)
            if not (SAFE.match(k) and SAFE.match(v)):
                fail("azure.tag_filters %r: %r has characters a tag filter cannot use" % (k, v))
            filters.append("tags['%s'] is not defined or tags['%s'] != '%s'" % (k, k, v))
        inv["exclude_host_filters"] = filters
    if locs:
        inv.setdefault("exclude_host_filters", []).append(
            "location not in %r" % [x.lower().replace(" ", "") for x in locs])
    if rgs:
        inv["include_vm_resource_groups"] = rgs

    out = os.path.join(out_dir, "generated.azure_rm.yaml")
    with open(out, "w") as f:
        f.write("# Rendered by scripts/render_azure_inventory.py from customer_input.yaml.\n")
        yaml.safe_dump(inv, f, default_flow_style=False, sort_keys=False)
    print(out)


if __name__ == "__main__":
    main()
