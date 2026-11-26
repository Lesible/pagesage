import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import re
import urllib.error
import urllib.request


def fetch_sample(sample, output):
    request = urllib.request.Request(
        sample["url"],
        headers={"User-Agent": "PageSage-extraction-evaluation/0.0.1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read(10 * 1024 * 1024 + 1)
            if len(payload) > 10 * 1024 * 1024:
                raise ValueError("html_budget_exceeded")
            content_type = response.headers.get_content_type()
            if content_type not in ("text/html", "application/xhtml+xml"):
                raise ValueError("unsupported_content_type")
            encoding = response.headers.get_content_charset()
            if encoding is None:
                match = re.search(
                    rb"charset\s*=\s*[\"']?([a-zA-Z0-9_-]+)", payload[:4096]
                )
                encoding = match.group(1).decode("ascii") if match else "utf-8"
            source = payload.decode(encoding)
            filename = sample["id"] + ".html"
            (output / filename).write_text(source, encoding="utf-8")
            return {
                **sample,
                "status": response.status,
                "finalUrl": response.url,
                "encoding": encoding,
                "path": filename,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "bytes": len(payload),
            }
    except urllib.error.HTTPError as error:
        return {**sample, "error": f"http_{error.code}"}
    except (OSError, ValueError, LookupError) as error:
        return {**sample, "error": type(error).__name__}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--refresh", action="store_true")
    arguments = parser.parse_args()
    if (arguments.output / "manifest.json").exists() and not arguments.refresh:
        parser.error("样本已冻结；请使用新目录，或明确指定 --refresh 重新获取")
    arguments.output.mkdir(parents=True, exist_ok=True)
    samples = json.loads(
        (pathlib.Path(__file__).parent / "fixtures/public-sources.json").read_text()
    )
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        results = list(
            executor.map(
                lambda sample: fetch_sample(sample, arguments.output), samples
            )
        )
    (arguments.output / "manifest.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    for result in results:
        print(
            result["id"],
            result.get("error", f"saved {result.get('bytes', 0)} bytes"),
        )
    if any("error" in result for result in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
