"""Package complete Windows/macOS bundles or verified Android outputs, using stdlib."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import zipfile

REPO = Path(__file__).resolve().parent.parent
WINDOWS_REQUIRED = (
    "pagesage.exe", "flutter_windows.dll", "sqlite3.dll",
    "file_selector_windows_plugin.dll", "flutter_secure_storage_windows_plugin.dll",
    "url_launcher_windows_plugin.dll", "data/icudtl.dat", "data/app.so",
    "data/flutter_assets/NOTICES.Z",
    "data/flutter_assets/assets/fonts/LXGWWenKaiLite-Regular.ttf",
    "data/flutter_assets/assets/images/brand/app-icon-source.svg",
)
MACOS_REQUIRED = (
    "Contents/MacOS/pagesage",
    "Contents/Info.plist",
    "Contents/Resources/AppIcon.icns",
    "Contents/Frameworks/App.framework/Versions/A/App",
    "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/NOTICES.Z",
    "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/"
    "assets/fonts/LXGWWenKaiLite-Regular.ttf",
    "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/"
    "assets/images/brand/app-icon-source.svg",
    "Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS",
)
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",
}
RELEASE_DOCUMENTS = {
    "LICENSE": "LICENSE",
    "NOTICE": "NOTICE",
    "THIRD_PARTY_LICENSES.md": "docs/generated/third-party-licenses.md",
    "LICENSES/LXGWWenKaiLite-OFL.txt": "assets/fonts/licenses/LXGWWenKaiLite-OFL.txt",
    "LICENSES/AtkinsonHyperlegible-OFL.txt": "assets/fonts/licenses/AtkinsonHyperlegible-OFL.txt",
    "LICENSES/archive-LICENSE-other.txt": "assets/licenses/archive-LICENSE-other.txt",
}


def app_version():
    match = re.search(r"^version:\s*(\S+)\s*$", (REPO / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    if not match or not re.fullmatch(r"[0-9][0-9A-Za-z.+-]*", match[1]):
        raise ValueError("Invalid pubspec version")
    return match[1]


def checksum(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n", encoding="ascii")


def verify(output):
    manifests = list(output.glob("*.sha256"))
    if not manifests:
        raise ValueError("No checksums to verify")
    for manifest in manifests:
        digest, name = manifest.read_text(encoding="ascii").strip().split("  ", 1)
        if Path(name).name != name or "/" in name or "\\" in name:
            raise ValueError("Checksum path must be a filename")
        if hashlib.sha256((output / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Checksum mismatch: {name}")


def windows(bundle, output, version):
    for relative in WINDOWS_REQUIRED:
        if not (bundle / relative).is_file():
            raise ValueError(f"Incomplete Windows bundle: {relative}")
    files = [file for file in bundle.rglob("*") if file.is_file()]
    # A test-generated native asset manifest contains build-host paths.
    if any(file.name == "native_assets.json" for file in files):
        raise ValueError("Windows bundle contains a test native_assets.json; clean and rebuild")
    for source in RELEASE_DOCUMENTS.values():
        if not (REPO / source).is_file():
            raise ValueError(f"Missing release document: {source}")
    destination = output / f"pagesage-{version}-windows-x86_64.zip"
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(files):
            relative = file.relative_to(bundle).as_posix()
            if file.suffix.lower() != ".pdb" and relative not in RELEASE_DOCUMENTS:
                archive.write(file, f"pagesage/{relative}")
        for destination_name, source in RELEASE_DOCUMENTS.items():
            archive.write(REPO / source, f"pagesage/{destination_name}")
    checksum(destination)
    return destination


def mach_o_architectures(path):
    """Returns the CPU architecture names in a thin or fat Mach-O binary."""
    data = Path(path).read_bytes()
    if len(data) < 8:
        raise ValueError("Invalid Mach-O header")
    fat_magic = int.from_bytes(data[:4], "big")
    if fat_magic in (0xCAFEBABE, 0xCAFEBABF):
        count = int.from_bytes(data[4:8], "big")
        entry_size = 20 if fat_magic == 0xCAFEBABE else 32
        archs = set()
        for index in range(count):
            offset = 8 + index * entry_size
            if offset + 4 > len(data):
                raise ValueError("Truncated Mach-O fat header")
            archs.add(_cpu_name(int.from_bytes(data[offset:offset + 4], "big")))
        return archs
    if int.from_bytes(data[:4], "little") in (0xFEEDFACF, 0xFEEDFACE):
        return {_cpu_name(int.from_bytes(data[4:8], "little"))}
    raise ValueError("Unrecognized Mach-O binary")


def _cpu_name(cpu_type):
    return {
        0x0100000C: "arm64",
        0x01000007: "x86_64",
        12: "arm",
        7: "i386",
    }.get(cpu_type, hex(cpu_type))


def _add_symlink(archive, path, name):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = 0o120777 << 16
    info.compress_type = zipfile.ZIP_STORED
    archive.writestr(info, os.readlink(path))


def _write_tree(archive, root, prefix):
    """Adds a directory tree without following symlinks."""
    root = Path(root)
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for directory in list(directories):
            path = current_path / directory
            if path.is_symlink():
                _add_symlink(archive, path, f"{prefix}/{path.relative_to(root).as_posix()}")
                directories.remove(directory)
        for file in files:
            path = current_path / file
            name = f"{prefix}/{path.relative_to(root).as_posix()}"
            if path.is_symlink():
                _add_symlink(archive, path, name)
            else:
                archive.write(path, name)


def _mach_o_files(root):
    """Yields regular files with a Mach-O header, without following symlinks."""
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        directories[:] = [
            name for name in directories if not (current_path / name).is_symlink()
        ]
        for name in files:
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                continue
            with path.open("rb") as handle:
                if handle.read(4) in MACHO_MAGICS:
                    yield path


def macos(app, output, version):
    app = Path(app)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("macOS package requires a .app bundle")
    for relative in MACOS_REQUIRED:
        if not (app / relative).is_file():
            raise ValueError(f"Incomplete macOS bundle: {relative}")
    binaries = list(_mach_o_files(app))
    if not binaries:
        raise ValueError("macOS bundle has no Mach-O binaries")
    for binary in binaries:
        architectures = mach_o_architectures(binary)
        if "arm64" not in architectures:
            raise ValueError(f"macOS binary is not arm64: {binary.relative_to(app)}")
        if "x86_64" in architectures:
            raise ValueError(f"macOS package must be arm64-only: {binary.relative_to(app)}")
    for source in RELEASE_DOCUMENTS.values():
        if not (REPO / source).is_file():
            raise ValueError(f"Missing release document: {source}")
    destination = output / f"pagesage-{version}-macos-arm64.zip"
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        _write_tree(archive, app, f"pagesage/{app.name}")
        for destination_name, source in RELEASE_DOCUMENTS.items():
            archive.write(REPO / source, f"pagesage/{destination_name}")
    checksum(destination)
    return destination


def android(apk, aab, output, version, signed):
    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            for library in ("libapp.so", "libflutter.so", "libsqlite3.so"):
                if f"lib/{abi}/{library}" not in names:
                    raise ValueError(f"APK missing {abi}/{library}")
        for name in (
            "assets/flutter_assets/NOTICES.Z",
            "assets/flutter_assets/assets/fonts/LXGWWenKaiLite-Regular.ttf",
            "assets/flutter_assets/assets/images/brand/app-icon-source.svg",
        ):
            if name not in names:
                raise ValueError(f"APK missing {name}")
        if not any(name.startswith("assets/mlkit-google-ocr-models/") for name in names):
            raise ValueError("APK missing offline OCR models")
    if signed:
        if aab is None:
            raise ValueError("Signed distribution requires an AAB")
        with zipfile.ZipFile(aab) as archive:
            names = set(archive.namelist())
            for name in ("base/manifest/AndroidManifest.xml", "base/assets/flutter_assets/NOTICES.Z"):
                if name not in names:
                    raise ValueError(f"Invalid Android App Bundle: missing {name}")
    suffix = "android" if signed else "android-test"
    for source, extension in [(apk, "apk"), *([(aab, "aab")] if signed else [])]:
        destination = output / f"pagesage-{version}-{suffix}.{extension}"
        shutil.copyfile(source, destination)
        checksum(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["windows", "macos", "android", "verify"])
    parser.add_argument("--bundle", type=Path, default=REPO / "build/windows/x64/runner/Release")
    parser.add_argument("--app", type=Path, default=REPO / "build/macos/Build/Products/Release/pagesage.app")
    parser.add_argument("--apk", type=Path, default=REPO / "build/app/outputs/flutter-apk/app-release.apk")
    parser.add_argument("--aab", type=Path)
    parser.add_argument("--signed", action="store_true", help="Signing has already been checked by apksigner/jarsigner")
    parser.add_argument("--output", type=Path, default=REPO / "dist")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.target == "windows":
        print(windows(args.bundle, args.output, app_version()))
    elif args.target == "macos":
        print(macos(args.app, args.output, app_version()))
    elif args.target == "android":
        android(args.apk, args.aab, args.output, app_version(), args.signed)
    verify(args.output)


if __name__ == "__main__":
    main()
