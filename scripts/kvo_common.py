#!/usr/bin/env python3
"""
KVO GraphQL helpers shared by the Azure KVO scripts: Keycloak auth, the EULA,
change requests (open, clear, commit and poll), and the Visibility Fabric
objects the Kubernetes rail creates (cloud collection, monitoring policy) with
the lookups around them (cluster uid, vController by name, exists by name).

Every function below is copied as-is, comments included, from the AWS repo's
KVO Zone Tapping (VPC Traffic Mirroring) script, cloudlens-ansible-aws/scripts.
That file is where each endpoint was discovered live by introspection and where the
commit-time gotchas were written down; nothing here is in a public manual (see
~/keysight-kb/digests/kvo-clms-adoption-api.md). The helpers live in their own
module on the Azure side because the AWS mirror script never ships in this
tree, and the Kubernetes presence does not need it: the presence is
cloud-agnostic (cloud config type K8s) and only the KVO half of the chain
applies. Keep the two copies identical; a fix found on one cloud belongs on
the other.

Every call goes to /public/graphql with a Keycloak bearer token, and every
write runs inside a change request that must be committed before KVO acts on
it (KVO allows one open change request per user, which is why open_cr clears
stale ones first). Nothing here calls an Azure or AWS API.
"""
from __future__ import annotations
import sys, time
import requests


def log(m): print(f"[kvo-mirror] {m}", file=sys.stderr, flush=True)


# ----- KVO auth (Keycloak) ----------------------------------------------
def kvo_token(base, user, password, verify):
    r = requests.post(f"{base}/auth/realms/keysight/protocol/openid-connect/token",
                      data={"grant_type": "password", "client_id": "vision-orchestrator",
                            "username": user, "password": password}, verify=verify, timeout=20)
    if r.status_code != 200:
        log(f"KVO auth failed (HTTP {r.status_code}): {r.text[:160]}"); return None
    return r.json()["access_token"]

def kvo_accept_eula(base, verify):
    r = requests.get(f"{base}/eula/v1/eula", verify=verify, timeout=20)
    if r.status_code != 200: return False
    for e in [e for e in r.json() if not e.get("accepted")]:
        requests.post(f"{base}/eula/v1/eula/{e['id']}", json={"accepted": True}, verify=verify, timeout=20)
        log(f"accepted KVO EULA {e['id']}")
    return True

def gql(base, token, query, variables, verify):
    r = requests.post(f"{base}/public/graphql", headers={"Authorization": f"Bearer {token}"},
                      json={"query": query, "variables": variables or {}}, verify=verify, timeout=40)
    try: return r.json()
    except ValueError: return {"errors": [{"message": r.text[:200]}]}

# ----- change request helpers (async commit, poll to Committed) ---------
def _open_crs(base, token, verify):
    q = gql(base, token, "{ changeRequests { uid status } }", None, verify)
    return [r for r in (q.get("data", {}).get("changeRequests") or []) if r["status"] != "Committed"]

def clear_open_crs(base, token, verify, timeout=90):
    """KVO allows one open change request per user. A failed create leaves an
    empty CR behind and blocks the next open; delete any non-Committed CR and
    wait for the (async) delete to finalize before returning."""
    open_crs = _open_crs(base, token, verify)
    for r in open_crs:
        gql(base, token, "mutation($u:String!){ deleteChangeRequest(uid:$u){ uid } }", {"u": r["uid"]}, verify)
        log(f"clearing stale open change request {r['uid']} ({r['status']})")
    if not open_crs:
        return
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _open_crs(base, token, verify):
            log("stale change requests cleared"); return
        time.sleep(4)
    log("warning: open change requests still present after cleanup")

def open_cr(base, token, name, verify):
    clear_open_crs(base, token, verify)
    d = gql(base, token, "mutation($n:String){ createChangeRequest(name:$n){ uid } }", {"n": name}, verify)
    if "errors" in d:
        log(f"createChangeRequest failed: {d['errors'][0]['message'][:180]}"); return None
    crs = d.get("data", {}).get("createChangeRequest") or []
    return crs[0]["uid"] if crs else None

def commit_cr(base, token, cr_uid, verify, timeout=600):
    # KVO serializes processing; a prior commit (e.g. collector deploy) may still
    # be running. Retry the commit call until KVO accepts it.
    deadline = time.time() + timeout
    while True:
        c = gql(base, token,
                "mutation($u:String!){ commitChangeRequest(uid:$u, ignoreWarnings:true){ uid state } }",
                {"u": cr_uid}, verify)
        if "errors" not in c:
            break
        msg = c["errors"][0]["message"]
        if "another processing is still running" in msg and time.time() < deadline:
            log("  waiting for the previous processing to finish..."); time.sleep(10); continue
        log(f"commit failed: {msg[:200]}"); return False
    deadline = time.time() + timeout
    start = time.time()
    ticks = 0
    while time.time() < deadline:
        q = gql(base, token, "{ changeRequests { uid status } }", None, verify)
        mine = [r for r in (q.get("data", {}).get("changeRequests") or []) if r["uid"] == cr_uid]
        if not mine or mine[0]["status"] == "Committed":
            log("change request committed"); return True
        if mine[0]["status"] in ("Failed", "Error"):
            log(f"commit ended in {mine[0]['status']}"); return False
        # Heartbeat every ~30s so a long commit (the collector launch can take a
        # few minutes) never looks frozen. Say what KVO is doing and how long.
        ticks += 1
        if ticks % 5 == 0:
            elapsed = int(time.time() - start)
            log(f"  still processing in KVO ({mine[0]['status']}, {elapsed}s so far; "
                f"launching/scaling the collector can take a few minutes, this is normal)")
        time.sleep(6)
    log("timed out waiting for commit"); return False

def clm_info(base, token, name, verify):
    d = gql(base, token, "{ cloudLensManagersFeed { cloudLensManagers { uid name status } } }", None, verify)
    for r in (d.get("data", {}).get("cloudLensManagersFeed", {}) or {}).get("cloudLensManagers", []):
        if r.get("name") == name:
            return r
    return None

# ----- the fabric objects the Kubernetes rail creates -------------------
def create_collection(base, token, cr, name, cluster, cfg_name, selector, verify):
    # selector is the resourceSelector entry list. For the tag form, `field` is
    # the TAG KEY itself (Name, cloudlens, instance-id, aws:cloudformation:*:
    # what the KVO UI's workload-selector dropdown lists) and `tag` is KVO's
    # identifier for that key, `system.tags.<key>` (or
    # `system.cloud_metadata.<key>` for instance-id / interface-id /
    # subnet-id), exactly as cloudPresenceTagsForPresence returns it. Two
    # wrong forms are on record: field="tag" (rendered "tag | yes", matched
    # nothing) and tag=<key> without the system.tags. prefix (KVO 2.13 form,
    # commit b301357): on KVO 3.1.0 that one matched nothing SILENTLY, live
    # 2026-09-28. workload_selection.kvo_selector builds the same shape.
    # The instance-id form ({field:"instance-id", regex:"^(i-..|i-..)$"}) comes
    # from resolve_workloads.py, which resolves ANDed tags / exclusions to
    # literal ids so KVO's undocumented multi-entry combination never matters.
    settings = {"cloudConfig": {"name": cfg_name}, "tapType": "RAW",
                "resourceSelector": selector}
    q = ("mutation($n:String!,$c:String!,$cl:String!,$s:_CloudCollectionInput!){ "
         "createCloudCollection(name:$n, changeID:$c, clusterID:$cl, settings:$s){ uid name } }")
    d = gql(base, token, q, {"n": name, "c": cr, "cl": cluster, "s": settings}, verify)
    if "errors" in d:
        log(f"createCloudCollection failed: {d['errors'][0]['message'][:220]}"); return None
    rows = d.get("data", {}).get("createCloudCollection") or []
    return rows[0] if rows else None

def cluster_uid(base, token, verify):
    d = gql(base, token, "{ clusters { uid name } }", None, verify)
    rows = d.get("data", {}).get("clusters") or []
    for r in rows:
        if r.get("name") == "PredefinedCluster": return r["uid"]
    return rows[0]["uid"] if rows else None

# ----- monitoring policy (complete the path) ----------------------------
# The config and collection define WHAT to tap; nothing moves traffic until
# a Monitoring Policy wires the collection (source) to a destination Tool.
# The tool itself is created by the vPB traffic-path step (vpb_wire_path.py);
# here only the policy that binds a collection to an existing tool is built.
def create_monitoring_policy(base, token, cr, name, cluster, collection_name, tool_name, verify):
    settings = {
        "source": {"name": collection_name},
        "tools": {"name": tool_name},
        "runMode": "CONTINUOUSLY",
        "type": "REGULAR",
    }
    q = ("mutation($n:String!,$c:String!,$cl:String!,$s:_MonitoringPolicyInput!){ "
         "createMonitoringPolicy(name:$n, changeID:$c, clusterID:$cl, settings:$s){ uid name } }")
    d = gql(base, token, q, {"n": name, "c": cr, "cl": cluster, "s": settings}, verify)
    if "errors" in d:
        log(f"createMonitoringPolicy failed: {d['errors'][0]['message'][:220]}"); return None
    rows = d.get("data", {}).get("createMonitoringPolicy") or []
    return rows[0] if rows else None

def exists_named(base, token, collection, name, verify):
    d = gql(base, token, "{ %s { name } }" % collection, None, verify)
    return any(x.get("name") == name for x in (d.get("data", {}).get(collection) or []))
