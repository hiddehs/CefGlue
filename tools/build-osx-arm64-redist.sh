#!/usr/bin/env bash
#
# Repack the upstream CEF macOS ARM64 binary distribution (Spotify CDN)
# into a cef.redist.osx.arm64.<version>.nupkg matching the layout of the
# official cef.redist.osx.arm64 packages on nuget.org (which stopped
# publishing after 134.3.9).
#
# Usage: build-osx-arm64-redist.sh <cef-version> [out-dir]
#   cef-version: e.g. 139.0.28 (must exactly match a build on https://cef-builds.spotifycdn.com)
#   out-dir:     optional, defaults to ./Nuget/output (relative to repo root)
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <cef-version> [out-dir]" >&2
  exit 1
fi

CEF_VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${2:-$REPO_ROOT/Nuget/output}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PKG_NAME="cef.redist.osx.arm64"
echo ">>> Looking up CEF $CEF_VERSION macOS arm64 build on Spotify CDN..."

# Resolve the full build label (e.g. 139.0.28+g55ab8a8+chromium-139.0.7258.139)
# and the corresponding minimal tarball filename.
INDEX_JSON="$WORK_DIR/cef-index.json"
curl -fsSL "https://cef-builds.spotifycdn.com/index.json" -o "$INDEX_JSON"

read -r BUILD_LABEL TARBALL_NAME < <(python3 - "$CEF_VERSION" "$INDEX_JSON" <<'PY'
import json, sys
target, path = sys.argv[1], sys.argv[2]
data = json.load(open(path))
versions = data.get("macosarm64", {}).get("versions", [])
match = None
for v in versions:
    cv = v.get("cef_version", "")
    if cv == target or cv.startswith(target + "+"):
        match = v
        break
if not match:
    sys.exit(f"No macosarm64 build found for CEF {target}")
tarball = next(
    (f["name"] for f in match.get("files", []) if f.get("type") == "minimal"),
    None,
)
if not tarball:
    sys.exit(f"No 'minimal' tarball listed for {match['cef_version']}")
print(match["cef_version"], tarball)
PY
)
echo "    label:   $BUILD_LABEL"
echo "    tarball: $TARBALL_NAME"

# URL-encode '+' for curl
TARBALL_URL_NAME="${TARBALL_NAME//+/%2B}"
TARBALL_PATH="$WORK_DIR/$TARBALL_NAME"
echo ">>> Downloading $TARBALL_NAME..."
curl -fL --progress-bar -o "$TARBALL_PATH" "https://cef-builds.spotifycdn.com/$TARBALL_URL_NAME"

echo ">>> Extracting..."
tar -xjf "$TARBALL_PATH" -C "$WORK_DIR"
EXT_BASE="$WORK_DIR/${TARBALL_NAME%.tar.bz2}"
FRAMEWORK="$EXT_BASE/Release/Chromium Embedded Framework.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Framework not found at: $FRAMEWORK" >&2
  exit 1
fi

# Stage in v134-compatible layout: CEF/ flat dylibs + CEF/Resources/* + build/.props + .nuspec
STAGE="$WORK_DIR/pkg"
mkdir -p "$STAGE/CEF/Resources" "$STAGE/build" "$STAGE/_rels"

cp "$FRAMEWORK/Chromium Embedded Framework"   "$STAGE/CEF/libcef.dylib"
cp "$FRAMEWORK/Libraries/libEGL.dylib"        "$STAGE/CEF/"
cp "$FRAMEWORK/Libraries/libGLESv2.dylib"     "$STAGE/CEF/"
cp "$FRAMEWORK/Libraries/libvk_swiftshader.dylib" "$STAGE/CEF/"
cp "$FRAMEWORK/Libraries/vk_swiftshader_icd.json" "$STAGE/CEF/"

for f in Info.plist chrome_100_percent.pak chrome_200_percent.pak gpu_shader_cache.bin \
         icudtl.dat resources.pak v8_context_snapshot.arm64.bin; do
  if [[ -f "$FRAMEWORK/Resources/$f" ]]; then
    cp "$FRAMEWORK/Resources/$f" "$STAGE/CEF/Resources/"
  fi
done
# English locale only (matches nuget.org's pre-134 layout)
cp "$FRAMEWORK/Resources/en.lproj/locale.pak" "$STAGE/CEF/Resources/locale.pak"

cp "$EXT_BASE/LICENSE.txt" "$STAGE/LICENSE.txt"

cat > "$STAGE/build/$PKG_NAME.props" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
    <CefRedistOSXARM64 Include="$(MSBuildThisFileDirectory)..\CEF\**\*.*" />
  </ItemGroup>
</Project>
EOF

cat > "$STAGE/$PKG_NAME.nuspec" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd">
  <metadata>
    <id>$PKG_NAME</id>
    <version>$CEF_VERSION</version>
    <authors>The Chromium Embedded Framework Authors</authors>
    <owners>hiddehs</owners>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <license type="file">LICENSE.txt</license>
    <description>CEF macOS ARM64 runtime binaries, repacked from cef-builds.spotifycdn.com for $BUILD_LABEL.</description>
    <copyright>Copyright (c) Marshall A. Greenblatt</copyright>
    <tags>chrome chromium native embedded browser CEF nativepackage OSXARM64</tags>
    <repository type="git" url="https://github.com/hiddehs/CefGlue" />
  </metadata>
</package>
EOF

cat > "$STAGE/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="nuspec" ContentType="application/octet" />
  <Default Extension="dylib" ContentType="application/octet" />
  <Default Extension="dll" ContentType="application/octet" />
  <Default Extension="pak" ContentType="application/octet" />
  <Default Extension="dat" ContentType="application/octet" />
  <Default Extension="bin" ContentType="application/octet" />
  <Default Extension="plist" ContentType="application/octet" />
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="props" ContentType="application/xml" />
  <Default Extension="txt" ContentType="text/plain" />
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" />
  <Default Extension="psmdcp" ContentType="application/vnd.openxmlformats-package.core-properties+xml" />
</Types>
EOF

cat > "$STAGE/_rels/.rels" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Type="http://schemas.microsoft.com/packaging/2010/07/manifest" Target="/$PKG_NAME.nuspec" Id="R1" />
</Relationships>
EOF

mkdir -p "$OUT_DIR"
OUTFILE="$OUT_DIR/$PKG_NAME.$CEF_VERSION.nupkg"
rm -f "$OUTFILE"
(cd "$STAGE" && zip -qr "$OUTFILE" .)

echo ">>> Built: $OUTFILE"
ls -lh "$OUTFILE"
