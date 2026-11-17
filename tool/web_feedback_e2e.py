"""Exercise the example app's feedback loop in Chrome with the real bridge.

Run from a checkout after flutter pub get in example/. The Flutter SDK and a
ChromeDriver matching the installed Chrome must be on PATH. CHROMEWEBDRIVER
can also point to the driver directory (as on GitHub-hosted Ubuntu).
"""

import contextlib
import json
import os
import re
import signal
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from urllib.request import Request, urlopen

EXAMPLE = Path(__file__).resolve().parents[1] / "example"
LOOPBACK = "http://127.0.0.1"


def request(url, *, method="GET", body=None):
    headers = {"Accept": "application/json, text/event-stream"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    with urlopen(Request(url, data, headers, method=method), timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None


def wait_for(description, check, *, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.15)
    raise TimeoutError(f"Timed out waiting for {description}")


@contextlib.contextmanager
def service(command, log, listening, *, timeout=30):
    """Read the bound port from the service, then clean up its process group."""
    with log.open("w") as output:
        process = subprocess.Popen(
            command,
            cwd=EXAMPLE,
            stdin=subprocess.PIPE,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:

            def listening_port():
                if process.poll() is not None:
                    raise RuntimeError(f"{command[0]} exited with {process.returncode}")
                match = re.search(listening, log.read_text(errors="replace"))
                return match[1] if match else None

            port = wait_for(f"{log.stem} startup", listening_port, timeout=timeout)
            yield f"{LOOPBACK}:{port}"
        except Exception:
            print(
                f"\n{log.stem} log:\n{log.read_text(errors='replace')[-12000:]}",
                flush=True,
            )
            raise
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            process.stdin.close()


# CanvasKit renders the pixels. Flutter's accessibility DOM supplies the
# locations, and WebDriver sends normal mouse/keyboard events at those locations.
SEMANTICS_CENTER = r"""
const label = arguments[0];
const matches = [...document.querySelectorAll('flt-semantics')].filter(node =>
  (!arguments[1] || node.getAttribute('role') === arguments[1]) &&
  [node.getAttribute('aria-label'), node.getAttribute('aria-description'), node.textContent]
    .some(value => (value ?? '').split('\n').some(line => line.trim() === label)));
for (const node of matches.reverse()) {
  const box = node.getBoundingClientRect();
  if (box.width && box.height) {
    return [Math.round(box.x + box.width / 2), Math.round(box.y + box.height / 2)];
  }
}
return null;
"""


@contextlib.contextmanager
def chrome(driver):
    options = {
        "args": [
            "--headless",
            "--window-size=1280,900",
            "--force-device-scale-factor=1",
            "--enable-unsafe-swiftshader",
            "--use-angle=swiftshader",
        ],
    }
    if os.environ.get("CHROME_EXECUTABLE"):
        options["binary"] = os.environ["CHROME_EXECUTABLE"]
    session = request(
        f"{driver}/session",
        method="POST",
        body={
            "capabilities": {
                "alwaysMatch": {
                    "browserName": "chrome",
                    "goog:chromeOptions": options,
                    "goog:loggingPrefs": {"browser": "ALL"},
                }
            },
        },
    )["value"]["sessionId"]
    url = f"{driver}/session/{session}"
    try:
        yield Browser(url)
    except Exception:
        with contextlib.suppress(Exception):
            for entry in request(f"{url}/log", method="POST", body={"type": "browser"})[
                "value"
            ]:
                if entry["level"] in {"WARNING", "SEVERE"}:
                    print(entry["message"], flush=True)
        raise
    finally:
        request(url, method="DELETE")


class Browser:
    """The WebDriver commands this scenario needs."""

    def __init__(self, url):
        self.url = url

    def post(self, path, body):
        return request(f"{self.url}/{path}", method="POST", body=body)["value"]

    def script(self, script, *args):
        return self.post("execute/sync", {"script": script, "args": args})

    def center(self, label, *, role=None, settle=False):
        previous = None
        stable_since = 0

        def locate():
            nonlocal previous, stable_since
            center = self.script(SEMANTICS_CENTER, label, role)
            if not settle:
                return center
            now = time.monotonic()
            if center != previous:
                previous, stable_since = center, now
            if now - stable_since >= 0.4:
                return center
            return None

        try:
            return wait_for(repr(label), locate)
        except TimeoutError:
            labels = self.script("""
              return [...new Set([...document.querySelectorAll('flt-semantics')].flatMap(
                node => [node.getAttribute('aria-label'), node.getAttribute('aria-description'),
                         node.textContent.trim()]).filter(Boolean))];
            """)
            print(f"Flutter accessibility labels: {labels!r}", flush=True)
            raise

    def click(self, center):
        x, y = center
        self.post(
            "actions",
            {
                "actions": [
                    {
                        "type": "pointer",
                        "id": "mouse",
                        "parameters": {"pointerType": "mouse"},
                        "actions": [
                            {
                                "type": "pointerMove",
                                "origin": "viewport",
                                "x": x,
                                "y": y,
                            },
                            {"type": "pointerDown", "button": 0},
                            {"type": "pointerUp", "button": 0},
                        ],
                    }
                ]
            },
        )

    def type_comment(self, comment):
        active = request(f"{self.url}/element/active")["value"]
        key = active["element-6066-11e4-a52e-4f735466cecf"]
        self.post(f"element/{key}/value", {"text": comment})


class McpClient:
    def __init__(self, bridge):
        self.url = f"{bridge}/mcp"
        self.next_id = 0
        server = self.rpc(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "pinpoint-web-e2e", "version": "1"},
            },
        )
        assert server["serverInfo"]["name"] == "pinpoint", server
        request(
            self.url,
            method="POST",
            body={"jsonrpc": "2.0", "method": "notifications/initialized"},
        )

    def rpc(self, method, params):
        self.next_id += 1
        answer = request(
            self.url,
            method="POST",
            body={
                "jsonrpc": "2.0",
                "id": self.next_id,
                "method": method,
                "params": params,
            },
        )
        assert answer.get("id") == self.next_id, answer
        assert "error" not in answer, answer
        return answer["result"]

    def call(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), result
        return next(
            block["text"] for block in result["content"] if block["type"] == "text"
        )


def feedback_loop(browser, site, agent):
    browser.post("url", {"url": site})
    # Activate Flutter's accessibility switch so the live page supplies the
    # hit positions even when layout changes move the controls.
    wait_for(
        "Flutter accessibility switch",
        lambda: browser.script("""
      const toggle = document.querySelector('flt-semantics-placeholder');
      if (!toggle) return false;
      toggle.click();
      return true;
    """),
        timeout=60,
    )
    browser.click(browser.center("Counter and spinner"))
    # Wait for the route transition before measuring the target.
    target = browser.center("count: 0", settle=True)
    browser.click(browser.center("Pinpoint"))
    # Picking hides the app's accessibility tree. Use the position observed
    # before entering picking mode, so the click goes through the pointer trap.
    browser.click(target)
    wait_for(
        "focused comment editor",
        lambda: browser.script("""
      const editor = document.activeElement;
      return editor?.matches('textarea, input') ?? false;
    """),
    )
    comment = f"Browser feedback {uuid.uuid4()}"
    browser.type_comment(comment)
    browser.click(browser.center("Send"))
    browser.center("Note 1 (sent)")

    listing = agent.call("list_notes", status="open", detail="compact")
    note = re.search(
        r"^(pp_\S+) \([^\n]*\bsubmitted\b[^\n]*\)\nComment: "
        + re.escape(comment)
        + r"$",
        listing,
        re.MULTILINE,
    )
    assert note, listing
    note_id = note[1]
    details = agent.call("get_note", id=note_id, detail="standard")
    assert f"Comment: {comment}\n" in details, details
    assert 'Target: Text("count: 0")' in details, details
    assert re.search(
        r"^Source: .*lib/screens/counter_screen\.dart:\d+", details, re.MULTILINE
    ), details
    assert "Page: /counter " in details, details
    print(f"Sent and read {note_id} through the bridge.", flush=True)

    # Sending exits picking mode. Turn it back on before resolving so the
    # app's live poll can pick up the change without reloading the page.
    browser.click(browser.center("Pinpoint"))
    reply = f"Resolved by browser test for {note_id}"
    resolved = agent.call("update_note", id=note_id, status="resolved", message=reply)
    assert f"Note {note_id} is resolved." in resolved, resolved
    browser.center("Note 1 (resolved)")
    # Flutter exposes the pin tooltip separately from its small button.
    browser.click(browser.center("1", role="button"))
    browser.center(reply)
    print(f"Observed the resolved pin and agent reply for {note_id}.", flush=True)


def main():
    driver = (
        str(Path(os.environ["CHROMEWEBDRIVER"]) / "chromedriver")
        if "CHROMEWEBDRIVER" in os.environ
        else "chromedriver"
    )
    with tempfile.TemporaryDirectory(prefix="pinpoint-web-e2e-") as scratch:
        root = Path(scratch)
        with contextlib.ExitStack() as stack:
            bridge = stack.enter_context(
                service(
                    [
                        "dart",
                        "run",
                        "pinpoint:bridge",
                        "--port",
                        "0",
                        "--dir",
                        str(root / "notes"),
                    ],
                    root / "bridge.log",
                    r"bridge on http://127\.0\.0\.1:(\d+),",
                )
            )
            site = stack.enter_context(
                service(
                    [
                        "flutter",
                        "run",
                        "--debug",
                        "-d",
                        "web-server",
                        "--no-pub",
                        "--web-hostname=127.0.0.1",
                        "--web-port=0",
                        "--no-web-resources-cdn",
                        "--track-widget-creation",
                        f"--dart-define=PINPOINT_BRIDGE_PORT={bridge.rsplit(':', 1)[1]}",
                        f"--dart-define=PINPOINT_ROOT={EXAMPLE}",
                    ],
                    root / "flutter.log",
                    r"is being served at http://127\.0\.0\.1:(\d+)",
                    timeout=180,
                )
            )
            driver_url = stack.enter_context(
                service(
                    [driver, "--port=0"],
                    root / "chromedriver.log",
                    r"ChromeDriver was started successfully on port (\d+)\b",
                )
            )
            with chrome(driver_url) as browser:
                feedback_loop(browser, site, McpClient(bridge))


if __name__ == "__main__":
    main()
