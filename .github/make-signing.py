#!/usr/bin/env python3
"""
Create an Apple Distribution certificate + an App Store provisioning profile for
app.couchking.ios via the App Store Connect API, then install both so xcodebuild can
sign with them. This is what finally lets the exported IPA carry `aps-environment`:
the App Store profile for a push-enabled App ID includes that entitlement, and MANUAL
signing applies it (Apple's cloud/automatic export was dropping it — fleet-wide zero
APNs tokens, Oct 23).

Hands-off (AJ chose this over exporting a cert himself). SAFE: it never revokes or
touches existing certs — if the account is already at Apple's 2-distribution-cert
limit it STOPS and tells us to free a slot. Pure stdlib (no pip installs on the runner):
ES256 JWT is signed via `openssl`, DER→JOSE done by hand.

Writes SIGN_IDENTITY / PROFILE_NAME / SIGN_KEYCHAIN to $GITHUB_ENV for later steps.
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error, plistlib, re

API = "https://api.appstoreconnect.apple.com"
TEAM = os.environ["TEAM_ID"]
KEY_ID = os.environ["KEY_ID"]
ISSUER = os.environ["ISSUER_ID"]
BUNDLE = "app.couchking.ios"
WORK = "/tmp/cksign"
os.makedirs(WORK, exist_ok=True)

def b64u(b):
    if isinstance(b, str): b = b.encode()
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)

# ---- P8 key on disk (the Install-API-key step already wrote it) ----
p8 = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
if not os.path.exists(p8):
    with open(p8 := f"{WORK}/key.p8", "wb") as f:
        f.write(base64.b64decode(os.environ["APPSTORE_P8"]))

# ---- ASC API JWT (ES256), signed with openssl; DER sig -> raw r||s ----
def jwt():
    now = int(time.time())
    head = b64u(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}, separators=(",", ":")))
    pay = b64u(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1000,
                           "aud": "appstoreconnect-v1"}, separators=(",", ":")))
    signing_input = f"{head}.{pay}".encode()
    der = run(["openssl", "dgst", "-sha256", "-sign", p8], input=signing_input).stdout
    # parse ASN.1 ECDSA-Sig-Value: SEQ { INTEGER r, INTEGER s }
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7f) - 1
    def rdint(i):
        assert der[i] == 0x02
        ln = der[i + 1]; val = der[i + 2:i + 2 + ln]
        return val.lstrip(b"\x00").rjust(32, b"\x00"), i + 2 + ln
    r, i = rdint(i); s, _ = rdint(i)
    return f"{head}.{pay}.{b64u(r + s)}"

def api(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
        headers={"Authorization": "Bearer " + jwt(), "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        print(f"ASC {method} {path} -> {e.code}\n{e.read().decode()}", file=sys.stderr)
        raise

# ---- 1. refuse to blow the 2-cert limit ----
certs = api("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=200").get("data", [])
if len(certs) >= 2:
    print("❌ Apple's 2 Apple-Distribution-cert limit is already used up. Free a slot in the portal "
          "(or export one of the existing certs as a .p12) — I won't revoke one automatically.")
    sys.exit(1)

# ---- 2. key + CSR ----
run(["openssl", "genrsa", "-out", f"{WORK}/dist.key", "2048"])
run(["openssl", "req", "-new", "-key", f"{WORK}/dist.key", "-out", f"{WORK}/dist.csr",
     "-subj", f"/CN=CouchKing CI Distribution/O={TEAM}/C=US"])
csr = open(f"{WORK}/dist.csr").read()

# ---- 3. create the cert ----
cert = api("POST", "/v1/certificates", {"data": {"type": "certificates",
    "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr}}})
cert_id = cert["data"]["id"]
der = base64.b64decode(cert["data"]["attributes"]["certificateContent"])
open(f"{WORK}/dist.cer", "wb").write(der)
run(["openssl", "x509", "-inform", "DER", "-in", f"{WORK}/dist.cer", "-out", f"{WORK}/dist.pem"])
run(["openssl", "pkcs12", "-export", "-inkey", f"{WORK}/dist.key", "-in", f"{WORK}/dist.pem",
     "-out", f"{WORK}/dist.p12", "-passout", "pass:ckci", "-name", "ckci"])

# ---- 4. keychain ----
KC = f"{WORK}/ck.keychain-db"
for c in (["security", "delete-keychain", KC],): subprocess.run(c, capture_output=True)
run(["security", "create-keychain", "-p", "ckci", KC])
run(["security", "set-keychain-settings", "-lut", "21600", KC])
run(["security", "unlock-keychain", "-p", "ckci", KC])
run(["security", "import", f"{WORK}/dist.p12", "-k", KC, "-P", "ckci",
     "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", "ckci", KC])
# make it the default search list (login first so system tools still work)
login = subprocess.run(["security", "default-keychain"], capture_output=True, text=True).stdout.strip().strip('"')
run(["security", "list-keychains", "-d", "user", "-s", KC, login or os.path.expanduser("~/Library/Keychains/login.keychain-db")])

ids = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning", KC],
                     capture_output=True, text=True).stdout
m = re.search(r'"(Apple Distribution:[^"]+)"', ids) or re.search(r'"(iPhone Distribution:[^"]+)"', ids)
if not m:
    print("❌ imported cert but no distribution identity visible:\n" + ids); sys.exit(1)
identity = m.group(1)

# ---- 5. App Store profile linking this cert + the (push-enabled) bundle id ----
bid = api("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE}&limit=1").get("data", [])
if not bid:
    print(f"❌ no bundleId resource for {BUNDLE} in the account"); sys.exit(1)
bid = bid[0]["id"]
# ensure Push Notifications is ON for the App ID — the App Store profile only carries the
# `aps-environment` entitlement if the bundleId has the capability. Best-effort: ignore if it's
# already on (409) or the key role can't set it (we still try the profile; if push really isn't
# enabled the build's aps-environment self-check will fail loudly rather than ship broken).
try:
    api("POST", "/v1/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
        "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
    print("✅ enabled PUSH_NOTIFICATIONS on", BUNDLE)
except Exception as e:
    print("ℹ️ push-capability enable skipped (already on, or key lacks permission):", str(e)[:140])
pname = f"CK CI AppStore {int(time.time())}"
prof = api("POST", "/v1/profiles", {"data": {"type": "profiles",
    "attributes": {"name": pname, "profileType": "IOS_APP_STORE"},
    "relationships": {
        "bundleId": {"data": {"type": "bundleIds", "id": bid}},
        "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
pc = base64.b64decode(prof["data"]["attributes"]["profileContent"])
pdir = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
os.makedirs(pdir, exist_ok=True)
# decode the CMS to read the real UUID/Name, then install under <uuid>.mobileprovision
dec = run(["security", "cms", "-D", "-i", "/dev/stdin"], input=pc).stdout
pl = plistlib.loads(dec)
uuid, real_name = pl["UUID"], pl["Name"]
open(f"{pdir}/{uuid}.mobileprovision", "wb").write(pc)

with open(os.environ["GITHUB_ENV"], "a") as f:
    f.write(f"SIGN_IDENTITY={identity}\n")
    f.write(f"PROFILE_NAME={real_name}\n")
    f.write(f"SIGN_KEYCHAIN={KC}\n")
print(f"✅ signing ready — identity={identity!r} profile={real_name!r} uuid={uuid}")
