"""Reports whether App Store Connect will accept an upload right now.

Run through `make asc-status`. It answers three questions in the order they
block each other: are the credentials good, is the account's agreement in
effect, and does a record exist for this bundle identifier. `altool` collapses
all three into "No applications found", which sends you looking in the wrong
place -- the first time this ran, the real answer was an unsigned agreement and
altool said the app was missing.
"""

import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

try:
    import jwt
except ImportError:
    sys.exit("asc-status: PyJWT is not installed — pip3 install pyjwt")

key_id, issuer, bundle_id = sys.argv[1], sys.argv[2], sys.argv[3]
key_path = pathlib.Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{key_id}.p8"
if not key_path.exists():
    sys.exit(f"asc-status: no private key at {key_path}")

now = int(time.time())
token = jwt.encode(
    {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
    key_path.read_text(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def get(path):
    request = urllib.request.Request(
        "https://api.appstoreconnect.apple.com/v1/" + path,
        headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except ValueError:
            return error.code, {}


status, body = get(f"apps?filter[bundleId]={bundle_id}&limit=10")

if status == 401:
    sys.exit("  credentials: REJECTED — the key or issuer is wrong")
if status == 403:
    for error in body.get("errors", []):
        print(f"  blocked: {error.get('title')}")
        print(f"           {error.get('detail')}")
    print("  → the credentials are good; the account is not cleared to use the API yet")
    sys.exit(1)
if status != 200:
    sys.exit(f"  unexpected HTTP {status}: {json.dumps(body)[:300]}")

print("  credentials: accepted")
print("  agreement  : in effect")
apps = body.get("data", [])
if not apps:
    print(f"  app record : none for {bundle_id}")
    print("  → create it in App Store Connect before uploading")
    sys.exit(1)
for app in apps:
    attributes = app["attributes"]
    print(f"  app record : {attributes.get('name')}  (sku {attributes.get('sku')})")
print("  → ready to upload")
