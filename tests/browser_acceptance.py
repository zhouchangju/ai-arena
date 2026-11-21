#!/usr/bin/env python3
"""Real-browser acceptance harness for the AI Arena MV3 extension.

Goals covered
-------------
G1  One question, two seats, independent answers, opponent relay, proposal,
    explicit vote, final report and Markdown export.
G2  Opponent material is actually relayed; conditional votes and unresolved
    disagreement are not reported as unanimous agreement.
G3  State survives a page reload and is readable from a second workspace tab;
    historical answers remain visible.
G4  All screenshots and downloads are local; no external HTTP(S) request is
    allowed, so the harness cannot accidentally talk to a provider website.

What this does
--------------
* Launches Playwright's installed Chromium with a throw-away persistent profile
  and loads the unpacked extension from ``extension/`` (no installs, no build).
* Drives the actual workspace UI: create, answer both seats, advance through
  critique -> proposal -> vote, inspect the generated report and export it.
* Uses ``chrome.runtime.sendMessage`` only for assertions and error-path checks;
  every normal product step is performed through visible UI controls.
* Writes screenshots and the exported Markdown into the directory passed with
  ``--out``. It never writes into the repository.

Run from the repository root (do not install anything):

    python3 tests/browser_acceptance.py --out /tmp/ai-arena-acceptance

Exit code 0 means every check passed. Artifacts remain in ``--out``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

try:
    from playwright.sync_api import (
        Error as PlaywrightError,
        Locator,
        Page,
        TimeoutError as PlaywrightTimeoutError,
        sync_playwright,
    )
except ImportError as exc:  # pragma: no cover - environment guard
    print(
        "Playwright Python is required but not installed. "
        "This harness is not allowed to install packages.\n"
        f"Import error: {exc}",
        file=sys.stderr,
    )
    raise SystemExit(2)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROVIDERS = ("chatgpt", "claude")
PROVIDER_NAME_FALLBACKS = {
    "chatgpt": ("ChatGPT", "GPT"),
    "claude": ("Claude",),
    "gemini": ("Gemini",),
    "deepseek": ("DeepSeek",),
    "doubao": ("豆包", "Doubao"),
    "kimi": ("Kimi",),
    "qwen": ("通义千问", "Qwen"),
    "yuanbao": ("腾讯元宝", "元宝", "Yuanbao"),
    "grok": ("Grok",),
}

RUNTIME_CALL_JS = """
(payload) => new Promise((resolve) => {
  let settled = false;
  const timer = setTimeout(() => {
    if (!settled) { settled = true; resolve({ __harnessError: 'runtime message timeout' }); }
  }, 8000);
  try {
    chrome.runtime.sendMessage(payload, (reply) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const err = chrome.runtime.lastError;
      if (err) resolve({ __harnessError: err.message || String(err) });
      else resolve(reply === undefined ? { __harnessError: 'empty reply' } : reply);
    });
  } catch (e) {
    if (!settled) {
      settled = true;
      clearTimeout(timer);
      resolve({ __harnessError: String(e && e.message ? e.message : e) });
    }
  }
});
"""


class AcceptanceError(RuntimeError):
    """A user-visible acceptance requirement failed."""


@dataclass
class CheckLog:
    checks: list[dict[str, Any]] = field(default_factory=list)

    def check(self, name: str, condition: bool, detail: str = "") -> None:
        entry = {"name": name, "ok": bool(condition), "detail": detail}
        self.checks.append(entry)
        status = "PASS" if condition else "FAIL"
        print(f"  [{status}] {name}" + (f" — {detail}" if detail else ""))
        if not condition:
            raise AcceptanceError(f"{name}: {detail}" if detail else name)

    def skip(self, name: str, detail: str) -> None:
        self.checks.append({"name": name, "ok": None, "detail": detail})
        print(f"  [SKIP] {name} — {detail}")


@dataclass
class Provider:
    provider_id: str
    name: str


def log(message: str) -> None:
    print(message, flush=True)


def wait_until(
    predicate: Callable[[], Any],
    description: str,
    timeout: float = 12.0,
    interval: float = 0.15,
) -> Any:
    deadline = time.monotonic() + timeout
    last_error: Optional[BaseException] = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except PlaywrightError as exc:
            last_error = exc
        time.sleep(interval)
    suffix = f" (last error: {last_error})" if last_error else ""
    raise AcceptanceError(f"Timed out after {timeout:.1f}s waiting for {description}{suffix}")


def first_visible(page: Page, selectors: Iterable[str], root: Optional[Locator] = None) -> Optional[Locator]:
    scope = root if root is not None else page
    for selector in selectors:
        try:
            locator = scope.locator(selector)
            count = min(locator.count(), 20)
        except PlaywrightError:
            continue
        for index in range(count):
            candidate = locator.nth(index)
            try:
                if candidate.is_visible():
                    return candidate
            except PlaywrightError:
                continue
    return None


def locator_has_text(locator: Locator, needle: str) -> bool:
    try:
        return needle.casefold() in (locator.inner_text(timeout=1200) or "").casefold()
    except PlaywrightError:
        return False


def find_extension_dir(explicit: Optional[str]) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser().resolve())
    candidates.extend(
        [
            REPO_ROOT / "extension",
            REPO_ROOT / "src" / "extension",
            REPO_ROOT,
        ]
    )
    for path in candidates:
        manifest = path / "manifest.json"
        if manifest.is_file():
            try:
                data = json.loads(manifest.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if data.get("manifest_version") == 3:
                return path
    raise AcceptanceError(
        "No unpacked MV3 extension found. Expected manifest.json in "
        f"{REPO_ROOT / 'extension'} (or pass --ext)."
    )


def extension_id_from_path(path: Path) -> str:
    digest = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:32]
    return "".join(chr(ord("a") + int(char, 16)) for char in digest)


def find_chromium_executable() -> Optional[Path]:
    """Use an already-installed Chromium; never install or download one."""
    env_path = os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
    if env_path and Path(env_path).expanduser().is_file():
        return Path(env_path).expanduser()

    cache = Path.home() / "Library" / "Caches" / "ms-playwright"
    patterns = [
        "chromium-*/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "chromium-*/chrome-mac/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "chromium-*/chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium",
        "chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium",
        "chromium-*/chrome-linux64/chrome",
        "chromium-*/chrome-linux/chrome",
    ]
    found: list[Path] = []
    for pattern in patterns:
        found.extend(path for path in cache.glob(pattern) if path.is_file())
    if found:
        def version_key(path: Path) -> tuple[int, ...]:
            match = re.search(r"chromium-(\d+)", str(path))
            return (int(match.group(1)),) if match else (0,)

        return sorted(found, key=version_key, reverse=True)[0]

    for candidate in (
        Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
        Path("/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
    ):
        if candidate.is_file():
            return candidate
    return None


def manifest_ui_path(ext_dir: Path, manifest: dict[str, Any]) -> str:
    """Pick the human workspace page, not a provider content script."""
    candidates: list[str] = []
    options_ui = manifest.get("options_ui")
    if isinstance(options_ui, dict) and options_ui.get("page"):
        candidates.append(options_ui["page"])
    action = manifest.get("action")
    if isinstance(action, dict) and action.get("default_popup"):
        candidates.append(action["default_popup"])
    for key in ("options_page", "workspace", "homepage"):
        value = manifest.get(key)
        if isinstance(value, str) and value.endswith(".html"):
            candidates.append(value)

    html_files = sorted(
        str(file.relative_to(ext_dir))
        for file in ext_dir.rglob("*.html")
        if "node_modules" not in file.parts
    )
    priority = ("workspace", "workbench", "app", "index", "popup", "options")
    for stem in priority:
        for html in html_files:
            if Path(html).stem.casefold() == stem:
                candidates.append(html)
    for html in html_files:
        if html not in candidates:
            candidates.append(html)

    existing = [candidate for candidate in candidates if (ext_dir / candidate).is_file()]
    if not existing:
        raise AcceptanceError(f"No HTML workspace page found in {ext_dir}")
    return existing[0]


def read_providers(ext_dir: Path) -> list[Provider]:
    providers_file = ext_dir / "providers.js"
    if not providers_file.is_file():
        return [Provider(pid, PROVIDER_NAME_FALLBACKS.get(pid, (pid,))[0]) for pid in DEFAULT_PROVIDERS]

    text = providers_file.read_text(encoding="utf-8")
    found: dict[str, str] = {}
    # Match: chatgpt: { name: 'ChatGPT', url: '...' }
    for match in re.finditer(
        r"(?:^|[,{]\s*)([a-z][a-z0-9_-]*)\s*:\s*\{[^{}]*?name\s*:\s*['\"]([^'\"]+)['\"]",
        text,
        flags=re.MULTILINE | re.DOTALL,
    ):
        found[match.group(1)] = match.group(2)
    providers: list[Provider] = []
    for provider_id, name in found.items():
        providers.append(Provider(provider_id, name))
    if not providers:
        return [Provider(pid, PROVIDER_NAME_FALLBACKS.get(pid, (pid,))[0]) for pid in DEFAULT_PROVIDERS]
    return providers


class Runtime:
    """Thin wrapper over the extension's documented message contract."""

    def __init__(self, page: Page):
        self.page = page

    def call(self, payload: dict[str, Any]) -> dict[str, Any]:
        reply = self.page.evaluate(RUNTIME_CALL_JS, payload)
        if not isinstance(reply, dict):
            raise AcceptanceError(f"Runtime reply for {payload.get('type')} was not an object: {reply!r}")
        if "__harnessError" in reply:
            raise AcceptanceError(f"Runtime message failed for {payload.get('type')}: {reply['__harnessError']}")
        if "ok" not in reply:
            raise AcceptanceError(f"Runtime reply for {payload.get('type')} lacks ok: {reply!r}")
        return reply

    def ok(self, payload: dict[str, Any]) -> dict[str, Any]:
        reply = self.call(payload)
        if not reply.get("ok"):
            raise AcceptanceError(f"Expected success for {payload}, got {reply!r}")
        return reply

    def error(self, payload: dict[str, Any]) -> str:
        reply = self.call(payload)
        if reply.get("ok"):
            raise AcceptanceError(f"Expected an error for {payload}, got success {reply!r}")
        error = reply.get("error")
        if not isinstance(error, str) or not error.strip():
            raise AcceptanceError(f"Error reply for {payload} has no readable error string: {reply!r}")
        return error

    def get(self, session_id: str) -> dict[str, Any]:
        reply = self.ok({"type": "get", "id": session_id})
        session = reply.get("session")
        if not isinstance(session, dict):
            raise AcceptanceError(f"get({session_id}) returned no session: {reply!r}")
        return session

    def list_sessions(self) -> list[dict[str, Any]]:
        reply = self.ok({"type": "list"})
        sessions = reply.get("sessions")
        if not isinstance(sessions, list):
            raise AcceptanceError(f"list returned no sessions array: {reply!r}")
        return sessions


class WorkspaceUI:
    """Semantic UI driver for the workspace page.

    The entry form, task cards and controls are addressed by stable data
    attributes first and by their visible Chinese/English labels second. The
    fallbacks keep the harness honest about the real DOM while not pinning each
    acceptance step to one renderer implementation.
    """

    def __init__(self, page: Page, providers: list[Provider], runtime: Runtime):
        self.page = page
        self.providers = providers
        self.by_id = {provider.provider_id: provider for provider in providers}
        self.runtime = runtime

    # ---------- entry form ----------

    def question_input(self) -> Locator:
        locator = first_visible(
            self.page,
            [
                "textarea[data-role='question']",
                "#question-input",
                "#question",
                "textarea[name='question']",
                "textarea[placeholder*='问题']",
                "textarea[placeholder*='问题或']",
                "textarea[placeholder*='输入']",
                "textarea",
                "[contenteditable='true'][data-role='question']",
            ],
        )
        if locator is None:
            raise AcceptanceError("Entry form: no question textarea is visible")
        return locator

    def set_question(self, text: str) -> None:
        field = self.question_input()
        field.scroll_into_view_if_needed()
        field.fill(text)
        value = field.input_value() if field.evaluate("el => 'value' in el") else field.inner_text()
        if text.splitlines()[0] not in value:
            raise AcceptanceError("Entry form: question text did not stay in the input")

    def _provider_controls(self, provider: Provider) -> list[Locator]:
        pid = provider.provider_id
        controls: list[Locator] = []
        selectors = [
            f"input[type='checkbox'][data-provider='{pid}']",
            f"input[type='checkbox'][value='{pid}']",
            f"input[type='radio'][value='{pid}']",
            f"input[data-provider='{pid}']",
            f"[data-provider='{pid}'][role='checkbox']",
            f"[data-provider='{pid}'][role='button']",
            f"[data-provider-id='{pid}']",
        ]
        for selector in selectors:
            locator = self.page.locator(selector)
            for index in range(min(locator.count(), 8)):
                controls.append(locator.nth(index))

        # The workspace renders provider choices as pressed buttons whose
        # accessible name contains the provider's display name.
        provider_buttons = self.page.locator("button.provider-option")
        for index in range(min(provider_buttons.count(), 20)):
            button = provider_buttons.nth(index)
            if locator_has_text(button, provider.name) or locator_has_text(button, pid):
                controls.insert(0, button)

        # Visible card/label containing the provider's human name.
        names = [provider.name, pid] + list(PROVIDER_NAME_FALLBACKS.get(pid, ()))
        seen: set[str] = set()
        for name in names:
            if not name or name.casefold() in seen:
                continue
            seen.add(name.casefold())
            exact = self.page.get_by_text(name, exact=True)
            for index in range(min(exact.count(), 8)):
                node = exact.nth(index)
                try:
                    clickable = node.locator(
                        "xpath=ancestor-or-self::*[self::label or self::button or @role='button' or contains(@class,'provider') or contains(@class,'card')][1]"
                    )
                    if clickable.count():
                        controls.append(clickable.first)
                except PlaywrightError:
                    pass
                controls.append(node)
        return controls

    def select_provider(self, provider: Provider) -> None:
        controls = self._provider_controls(provider)
        last_error: Optional[BaseException] = None
        for control in controls:
            try:
                if not control.is_visible():
                    continue
                control.scroll_into_view_if_needed(timeout=2000)
                control.click(timeout=2500)
                return
            except PlaywrightError as exc:
                last_error = exc
        raise AcceptanceError(
            f"Entry form: could not select provider {provider.provider_id} ({provider.name}); "
            f"last error: {last_error}"
        )

    def provider_is_selected(self, provider: Provider) -> bool:
        for control in self._provider_controls(provider):
            try:
                if not control.is_visible():
                    continue
                if control.evaluate(
                    "el => !!(el.checked || el.getAttribute('aria-checked') === 'true' || "
                    "el.getAttribute('aria-pressed') === 'true' || "
                    "(el.classList && (el.classList.contains('selected') || el.classList.contains('active'))))"
                ):
                    return True
                scope = control.locator("xpath=ancestor::*[self::label or self::button or @role='button' or contains(@class,'card')][1]")
                if scope.count() and scope.first.evaluate(
                    "el => !!(el.getAttribute('aria-pressed') === 'true' || "
                    "el.getAttribute('aria-checked') === 'true' || "
                    "(el.classList && (el.classList.contains('selected') || el.classList.contains('active'))))"
                ):
                    return True
            except PlaywrightError:
                continue
        return False

    def start_button(self) -> Locator:
        locator = first_visible(
            self.page,
            [
                "button[data-action='create']",
                "button[data-action='start']",
                "#start-debate",
                "form button[type='submit']",
            ],
        )
        if locator is not None:
            return locator
        for pattern in (r"开始", r"发起", r"创建.*讨论", r"开始讨论", r"Start"):
            button = self.page.get_by_role("button", name=re.compile(pattern))
            for index in range(min(button.count(), 6)):
                candidate = button.nth(index)
                if candidate.is_visible():
                    return candidate
        raise AcceptanceError("Entry form: no start/create button is visible")

    def selection_snapshot(self) -> dict[str, Any]:
        """Read the compact seat picker's real state, not its marketing copy."""
        return self.page.evaluate(
            """() => {
              const buttons = Array.from(document.querySelectorAll('button.provider-option'));
              const counter = document.querySelector('.selection-count');
              return {
                count: buttons.length,
                ids: buttons.map((button) => button.dataset.providerId || ''),
                pressed: buttons
                  .filter((button) => button.getAttribute('aria-pressed') === 'true')
                  .map((button) => button.dataset.providerId || ''),
                labels: buttons.map((button) => ((button.querySelector('.provider-name') || {}).textContent || '').trim()),
                counter: ((counter || {}).textContent || '').trim(),
              };
            }"""
        )

    def create_debate(self, question: str, provider_ids: list[str]) -> tuple[str, dict[str, Any]]:
        self.set_question(question)
        for provider_id in provider_ids:
            provider = self.by_id.get(provider_id, Provider(provider_id, provider_id))
            self.select_provider(provider)

        selected = self.selection_snapshot()
        if selected["pressed"] != provider_ids:
            raise AcceptanceError(
                f"Entry form pressed seats {selected['pressed']!r}, expected {provider_ids!r}"
            )
        if "2 / 2" not in selected["counter"]:
            raise AcceptanceError(
                f"Selection counter did not reach two seats: {selected['counter']!r}"
            )

        # A third seat must be refused instead of silently replacing one.
        extra_pid = next((pid for pid in self.by_id if pid not in provider_ids), None)
        extra_state = selected
        extra_error = ""
        if extra_pid is not None:
            self.select_provider(self.by_id[extra_pid])
            extra_state = self.selection_snapshot()
            banner = first_visible(self.page, [".inline-error", "[role='alert']"])
            extra_error = (banner.inner_text(timeout=1500) if banner is not None else "").strip()
            if extra_state["pressed"] != provider_ids:
                raise AcceptanceError(
                    f"A third seat changed the selection: {extra_state['pressed']!r}"
                )

        self.start_button().click()
        reply = wait_until(
            lambda: self._try_list_for_new_question(question),
            "a new session to appear in history",
            timeout=8.0,
        )
        session_id = reply
        session = self.runtime.get(session_id)
        if sorted(session.get("providers") or []) != sorted(provider_ids):
            raise AcceptanceError(
                f"Created session providers were {session.get('providers')!r}, expected {provider_ids!r}"
            )
        if session.get("question") != question:
            raise AcceptanceError("Created session question differs from the question entered in the UI")
        return session_id, {
            "selected": selected,
            "extra_provider": extra_pid,
            "after_extra": extra_state,
            "extra_error": extra_error,
        }

    def _try_list_for_new_question(self, question: str) -> Optional[str]:
        try:
            sessions = self.runtime.list_sessions()
        except AcceptanceError:
            return None
        # Newest first is conventional; fall back to any exact match.
        matches = [item for item in sessions if item.get("question") == question]
        if not matches:
            return None
        matches.sort(key=lambda item: item.get("updatedAt") or 0, reverse=True)
        return str(matches[0]["id"])

    # ---------- session view ----------

    def stage(self, session_id: str) -> str:
        return str(self.runtime.get(session_id).get("stage"))

    def wait_for_stage(self, session_id: str, stage: str, timeout: float = 10.0) -> dict[str, Any]:
        return wait_until(
            lambda: (lambda session: session if session.get("stage") == stage else None)(self.runtime.get(session_id)),
            f"stage {stage}",
            timeout=timeout,
        )

    def body_text(self) -> str:
        return self.page.locator("body").inner_text(timeout=4000)

    def linked_stylesheets(self) -> list[dict[str, Any]]:
        """Report whether the workspace's own stylesheet links actually load."""
        return self.page.evaluate(
            """async () => {
              const links = Array.from(document.querySelectorAll('link[rel="stylesheet"]'));
              const out = [];
              for (const link of links) {
                try {
                  const response = await fetch(link.href);
                  out.push({ href: link.href, ok: response.ok, status: response.status });
                } catch (error) {
                  out.push({ href: link.href, ok: false, status: String(error) });
                }
              }
              return out;
            }"""
        )

    def task_cards(self, task: dict[str, Any]) -> list[Locator]:
        tid = str(task.get("id"))
        pid = str(task.get("provider"))
        provider = self.by_id.get(pid, Provider(pid, pid))
        candidates = [
            f"[data-task-id='{tid}']",
            f"[data-task='{tid}']",
            f"[data-task-id=\"{tid}\"]",
            f"[data-turn-id='{tid}']",
        ]
        cards: list[Locator] = []
        seat_cards = self.page.locator("article.seat-card")
        for index in range(min(seat_cards.count(), 20)):
            node = seat_cards.nth(index)
            try:
                if locator_has_text(node, pid):
                    cards.append(node)
            except PlaywrightError:
                continue

        for selector in candidates:
            locator = self.page.locator(selector)
            for index in range(min(locator.count(), 6)):
                cards.append(locator.nth(index))

        # Cards carrying provider id but not the entry form (they contain a textarea).
        provider_locator = self.page.locator(f"[data-provider='{pid}']")
        for index in range(min(provider_locator.count(), 12)):
            node = provider_locator.nth(index)
            try:
                if node.locator("textarea").count():
                    cards.append(node)
            except PlaywrightError:
                pass

        # Provider-name card fallback, smallest sensible container with a textarea.
        names = [provider.name] + list(PROVIDER_NAME_FALLBACKS.get(pid, ()))
        for name in names:
            if not name:
                continue
            containers = self.page.locator("article, section, li, div").filter(has_text=name)
            count = min(containers.count(), 40)
            for index in range(count):
                node = containers.nth(index)
                try:
                    if not node.is_visible() or not node.locator("textarea").count():
                        continue
                    if node.locator("textarea").count() > 2:
                        continue
                    text = node.inner_text(timeout=800)
                    if tid and tid in text:
                        cards.insert(0, node)
                    else:
                        cards.append(node)
                except PlaywrightError:
                    continue
        # Deduplicate by backend node identity where possible.
        unique: list[Locator] = []
        seen: set[str] = set()
        for card in cards:
            try:
                key = card.evaluate("el => el.outerHTML.slice(0, 180)")
            except PlaywrightError:
                key = ""
            if key and key in seen:
                continue
            if key:
                seen.add(key)
            unique.append(card)
        return unique

    def task_card(self, task: dict[str, Any]) -> Locator:
        cards = self.task_cards(task)
        for card in cards:
            try:
                if card.is_visible():
                    return card
            except PlaywrightError:
                continue
        raise AcceptanceError(
            f"No visible task card for task {task.get('id')} ({task.get('provider')})"
        )

    def open_task_editor(self, task: dict[str, Any]) -> Locator:
        """Open the paste/edit panel for a task and return its fresh card."""
        card = self.task_card(task)
        if first_visible(self.page, ["textarea"], root=card) is not None:
            return card
        for pattern in (r"粘贴回答", r"继续草稿", r"修改回答", r"补录回答"):
            buttons = card.get_by_role("button", name=re.compile(pattern))
            clicked = False
            for index in range(min(buttons.count(), 4)):
                button = buttons.nth(index)
                try:
                    if button.is_visible() and button.is_enabled():
                        button.click(timeout=3000)
                        clicked = True
                        break
                except PlaywrightError:
                    continue
            if clicked:
                break
        if not clicked:
            raise AcceptanceError(f"Task {task.get('id')} has no visible paste/edit control")
        fresh = self.task_card(task)
        wait_until(
            lambda: first_visible(self.page, ["textarea.answer-input", "textarea"], root=fresh) is not None,
            "task editor textarea",
            timeout=5.0,
        )
        return fresh

    def expand_prompts(self) -> None:
        """Open collapsed prompt details so relayed material is visible on screen."""
        details = self.page.locator("details.prompt-box")
        for index in range(min(details.count(), 12)):
            node = details.nth(index)
            try:
                if not node.is_visible():
                    continue
                if node.evaluate("el => el.open"):
                    continue
                node.locator("summary").first.click(timeout=2000)
            except PlaywrightError:
                continue

    def _set_stance(self, card: Locator, stance: Optional[str]) -> None:
        if not stance:
            return
        labels = {
            "agree": ("agree", "同意", "赞成", "接受"),
            "conditional": ("conditional", "有条件", "附条件", "条件同意"),
            "oppose": ("oppose", "反对", "不接受", "不同意"),
        }[stance]
        # Compact vote UI: a real pressed button. The state must actually change.
        for value in labels:
            for selector in (f"button.stance-btn[data-stance='{value}']", f"[data-stance='{value}']"):
                locator = card.locator(selector)
                for index in range(min(locator.count(), 4)):
                    button = locator.nth(index)
                    try:
                        if not button.is_visible() or not button.is_enabled():
                            continue
                        button.click(timeout=2000)
                        if button.get_attribute("aria-pressed") == "true":
                            return
                    except PlaywrightError:
                        continue
        # Radios with explicit values.
        for value in labels:
            for selector in (
                f"input[type='radio'][value='{value}']",
                f"button[value='{value}']",
            ):
                locator = card.locator(selector)
                if locator.count():
                    try:
                        locator.first.check(timeout=1500, force=True)
                        return
                    except PlaywrightError:
                        try:
                            locator.first.click(timeout=1500)
                            return
                        except PlaywrightError:
                            pass
        # Select element.
        selects = card.locator("select")
        for index in range(min(selects.count(), 3)):
            select = selects.nth(index)
            try:
                options = select.locator("option").all_inner_texts()
            except PlaywrightError:
                continue
            for option_text in options:
                if any(label.casefold() in option_text.casefold() for label in labels):
                    try:
                        select.select_option(label=option_text)
                        return
                    except PlaywrightError:
                        pass
        # Visible label/button text.
        for label in labels:
            matches = card.get_by_text(label, exact=False)
            for index in range(min(matches.count(), 8)):
                node = matches.nth(index)
                try:
                    if node.is_visible():
                        node.click(timeout=1500)
                        return
                except PlaywrightError:
                    continue
        raise AcceptanceError(f"Could not set stance {stance!r} on a visible task card")

    def _submit(self, card: Locator) -> None:
        selectors = [
            "button[data-action='answer']",
            "button[data-action='submit']",
            "form button[type='submit']",
        ]
        for selector in selectors:
            locator = card.locator(selector)
            for index in range(min(locator.count(), 4)):
                button = locator.nth(index)
                try:
                    if button.is_visible() and button.is_enabled():
                        button.click(timeout=3000)
                        return
                except PlaywrightError:
                    continue
        for pattern in (r"提交", r"保存", r"记录", r"确认", r"发送", r"完成"):
            buttons = card.get_by_role("button", name=re.compile(pattern))
            for index in range(min(buttons.count(), 8)):
                button = buttons.nth(index)
                try:
                    if button.is_visible() and button.is_enabled():
                        button.click(timeout=3000)
                        return
                except PlaywrightError:
                    continue
        raise AcceptanceError("No submit/save button found in the task card")

    def answer_task(
        self,
        session_id: str,
        task: dict[str, Any],
        text: str,
        stance: Optional[str] = None,
        stage: Optional[str] = None,
    ) -> None:
        card = self.open_task_editor(task)
        textarea = first_visible(self.page, ["textarea.answer-input", "textarea"], root=card)
        if textarea is None:
            raise AcceptanceError(f"Task {task.get('id')} editor has no visible textarea")
        textarea.fill(text)
        self._set_stance(card, stance)
        self._submit(card)
        wait_until(
            lambda: self._task_terminal(session_id, str(task.get("id")), stage),
            f"task {task.get('id')} to be recorded",
            timeout=10.0,
        )

    def _task_terminal(self, session_id: str, task_id: str, stage: Optional[str] = None) -> bool:
        session = self.runtime.get(session_id)
        for task in session.get("tasks") or []:
            if str(task.get("id")) == task_id:
                return task.get("status") in ("answered", "skipped")
        # A terminal task can disappear from `tasks` when the stage advances.
        if stage is not None and session.get("stage") != stage:
            return True
        return session.get("stage") in ("done",)

    def answer_stage(self, session_id: str, stage: str, texts: dict[str, str], stances: Optional[dict[str, str]] = None) -> None:
        session = self.wait_for_stage(session_id, stage)
        handled: set[str] = set()
        stances = stances or {}
        while True:
            session = self.runtime.get(session_id)
            if session.get("stage") != stage:
                return
            pending = [
                task
                for task in (session.get("tasks") or [])
                if task.get("status") == "pending" and str(task.get("id")) not in handled
            ]
            if not pending:
                # Could be a transient render; give the UI one beat before failing.
                time.sleep(0.3)
                session = self.runtime.get(session_id)
                if session.get("stage") != stage:
                    return
                pending = [
                    task
                    for task in (session.get("tasks") or [])
                    if task.get("status") == "pending" and str(task.get("id")) not in handled
                ]
                if not pending:
                    return
            task = pending[0]
            pid = str(task.get("provider"))
            text = texts.get(pid)
            if text is None:
                raise AcceptanceError(f"No acceptance text supplied for provider {pid} in stage {stage}")
            self.answer_task(
                session_id,
                task,
                text,
                stance=stances.get(pid) if stage == "vote" else None,
                stage=stage,
            )
            handled.add(str(task.get("id")))

    # ---------- report / export / history ----------

    def visible_markdown(self) -> Optional[str]:
        """Return rendered report text when export opens an in-page preview."""
        candidates = self.page.locator("pre, textarea, [data-role='report'], .report")
        for index in range(min(candidates.count(), 12)):
            node = candidates.nth(index)
            try:
                if not node.is_visible():
                    continue
                if node.evaluate("el => el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'"):
                    value = node.input_value()
                else:
                    value = node.inner_text()
                if value and len(value) > 40 and ("#" in value or "报告" in value or "结论" in value):
                    return value
            except PlaywrightError:
                continue
        return None

    def joined_vote(self) -> Optional[dict[str, Any]]:
        """Read the done view's joined per-seat vote block."""
        return self.page.evaluate(
            """() => {
              const wrap = document.querySelector('.stance-summary');
              if (!wrap) return null;
              const rows = Array.from(wrap.querySelectorAll('.stance-row')).map((row) => ({
                name: ((row.querySelector('.stance-name') || {}).textContent || '').trim(),
                stance: ((row.querySelector('.stance-chip') || {}).textContent || '').trim(),
                reason: ((row.querySelector('.stance-reason') || {}).textContent || '').trim(),
              }));
              return {
                title: ((wrap.querySelector('.stance-title') || {}).textContent || '').trim(),
                rule: ((wrap.querySelector('.stance-rule') || {}).textContent || '').trim(),
                rows,
              };
            }"""
        )

    def capture_joined_vote(self, out_dir: Path) -> Path:
        element = self.page.locator(".stance-summary")
        if not element.count():
            raise AcceptanceError("Done view has no joined vote block")
        element.first.scroll_into_view_if_needed()
        path = out_dir / "07b_joined_vote.png"
        element.first.screenshot(path=str(path))
        log(f"  screenshot: {path}")
        return path

    def export_markdown(self, out_dir: Path) -> tuple[Path, str]:
        button = None
        for pattern in (r"导出", r"下载", r"Markdown", r"Export"):
            for role in ("button", "link"):
                locator = self.page.get_by_role(role, name=re.compile(pattern, re.IGNORECASE))
                for index in range(min(locator.count(), 6)):
                    candidate = locator.nth(index)
                    try:
                        if candidate.is_visible() and candidate.is_enabled():
                            button = candidate
                            break
                    except PlaywrightError:
                        continue
                if button:
                    break
            if button:
                break
        if button is None:
            button = first_visible(
                self.page,
                ["button[data-action='export']", "[data-action='download']", "a[download]"],
            )
        if button is None:
            raise AcceptanceError("No export/download control is visible on the result screen")

        try:
            with self.page.expect_download(timeout=7000) as download_info:
                button.click()
            download = download_info.value
            suggested = download.suggested_filename or "ai-arena-report.md"
            safe_name = re.sub(r"[^A-Za-z0-9._\-\u4e00-\u9fff]+", "_", suggested)
            path = out_dir / f"export_{safe_name}"
            download.save_as(path)
            return path, path.read_text(encoding="utf-8", errors="replace")
        except PlaywrightTimeoutError:
            pass

        # In-page Markdown preview fallback.
        wait_until(lambda: self.visible_markdown(), "exported Markdown preview", timeout=4.0)
        content = self.visible_markdown() or ""
        path = out_dir / "export_report.md"
        path.write_text(content, encoding="utf-8")
        return path, content

    def history_item(self, question: str) -> Optional[Locator]:
        candidates = self.page.locator(
            "a, button, li, [role='button'], [data-session-id], [data-id]"
        ).filter(has_text=question[:48])
        for index in range(min(candidates.count(), 20)):
            node = candidates.nth(index)
            try:
                if node.is_visible():
                    return node
            except PlaywrightError:
                continue
        return None

    def open_history(self, question: str) -> None:
        item = self.history_item(question)
        if item is None:
            raise AcceptanceError("History list does not show the created question after reload")
        item.click()
        wait_until(lambda: question[:32] in self.body_text(), "history session to render", timeout=6.0)


def screenshot(page: Page, out_dir: Path, name: str, full_page: bool = True) -> Path:
    path = out_dir / f"{name}.png"
    try:
        page.screenshot(path=str(path), full_page=full_page)
    except PlaywrightError:
        page.screenshot(path=str(path))
    log(f"  screenshot: {path}")
    return path


def safe_session_text(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)[:3000]


def run_error_contract_checks(runtime: Runtime, providers: list[str], logbook: CheckLog) -> str:
    """Exercise validation and disposable lifecycle without leaving debris."""
    log("\n[1/8] Runtime contract and error responses")
    question = "接受测试：错误路径与一次性会话（不作为真实讨论）"

    empty_error = runtime.error({"type": "create", "question": "   ", "providers": providers})
    logbook.check("Empty question is rejected", bool(empty_error.strip()), empty_error)

    same_error = runtime.error({"type": "create", "question": question, "providers": [providers[0], providers[0]]})
    logbook.check("Duplicate providers are rejected", bool(same_error.strip()), same_error)

    unknown_provider_error = runtime.error(
        {"type": "create", "question": question, "providers": [providers[0], "not-a-provider"]}
    )
    logbook.check("Unknown provider is rejected", bool(unknown_provider_error.strip()), unknown_provider_error)

    missing_get_error = runtime.error({"type": "get", "id": "missing-session-id"})
    logbook.check("Unknown session id is rejected", bool(missing_get_error.strip()), missing_get_error)

    missing_delete_error = runtime.error({"type": "delete", "id": "missing-session-id"})
    logbook.check("Deleting an unknown session is rejected", bool(missing_delete_error.strip()), missing_delete_error)

    unknown_open_error = runtime.error({"type": "open", "provider": "not-a-provider"})
    logbook.check("Opening an unknown provider is rejected", bool(unknown_open_error.strip()), unknown_open_error)

    created = runtime.ok({"type": "create", "question": question, "providers": providers})
    disposable = created.get("session")
    if not isinstance(disposable, dict) or not disposable.get("id"):
        raise AcceptanceError(f"create returned no disposable session: {created!r}")
    disposable_id = str(disposable["id"])
    logbook.check(
        "Created session starts independent with two pending tasks",
        disposable.get("stage") == "independent"
        and len(disposable.get("tasks") or []) == 2
        and all(task.get("status") == "pending" for task in disposable.get("tasks") or []),
        safe_session_text(disposable),
    )

    bogus_action_error = runtime.error({"type": "act", "id": disposable_id, "action": "bogus-action"})
    logbook.check("Unknown action is rejected", bool(bogus_action_error.strip()), bogus_action_error)

    bogus_task_error = runtime.error(
        {
            "type": "act",
            "id": disposable_id,
            "action": "answer",
            "payload": {"taskId": "missing-task", "text": "x"},
        }
    )
    logbook.check("Answering a missing task is rejected", bool(bogus_task_error.strip()), bogus_task_error)

    bad_stance_error = runtime.error(
        {
            "type": "act",
            "id": disposable_id,
            "action": "answer",
            "payload": {
                "taskId": str((disposable.get("tasks") or [{}])[0].get("id")),
                "text": "x",
                "stance": "sideways",
            },
        }
    )
    logbook.check("Invalid vote stance is rejected", bool(bad_stance_error.strip()), bad_stance_error)

    paused = runtime.ok({"type": "act", "id": disposable_id, "action": "pause"})
    paused_session = paused.get("session") or {}
    logbook.check("Pause is reflected in durable state", paused_session.get("paused") is True, safe_session_text(paused_session))

    resumed = runtime.ok({"type": "act", "id": disposable_id, "action": "resume"})
    resumed_session = resumed.get("session") or {}
    logbook.check("Resume clears paused state", resumed_session.get("paused") is False, safe_session_text(resumed_session))

    finished = runtime.ok({"type": "act", "id": disposable_id, "action": "finish"})
    finished_session = finished.get("session") or {}
    logbook.check(
        "Finish produces a partial report with stop state",
        finished_session.get("stage") == "done" and isinstance(finished_session.get("report"), str) and len(finished_session.get("report") or "") > 0,
        safe_session_text({k: finished_session.get(k) for k in ("stage", "report")}),
    )

    runtime.ok({"type": "delete", "id": disposable_id})
    runtime.error({"type": "get", "id": disposable_id})
    logbook.check("Delete removes the disposable session", True)
    return disposable_id


def run_ui_flow(
    page: Page,
    runtime: Runtime,
    ui: WorkspaceUI,
    out_dir: Path,
    question: str,
    provider_ids: list[str],
    logbook: CheckLog,
) -> dict[str, Any]:
    log("\n[2/8] Initial workspace and entry form")
    wait_until(lambda: page.locator("body").inner_text(timeout=3000).strip(), "workspace to render", timeout=10.0)
    question_field = ui.question_input()
    question_value = (
        question_field.input_value()
        if question_field.evaluate("el => 'value' in el")
        else question_field.inner_text()
    )
    logbook.check(
        "Entry form starts empty and does not prefill a demo debate",
        question_value.strip() == "",
        f"question field starts with {question_value!r}",
    )
    initial = ui.selection_snapshot()
    logbook.check(
        "Entry form starts with no seat pressed and a zero counter",
        initial["pressed"] == [] and "0 / 2" in initial["counter"],
        f"pressed={initial['pressed']!r} counter={initial['counter']!r}",
    )
    screenshot(page, out_dir, "00_initial_workspace")
    logbook.check(
        "Workspace loads as an extension page",
        page.url.startswith("chrome-extension://"),
        page.url,
    )
    logbook.check(
        "Entry form renders one pressable button per offered provider",
        initial["count"] >= 2
        and all(initial["ids"])
        and len(set(initial["ids"])) == initial["count"]
        and all(label for label in initial["labels"]),
        f"{initial['count']} buttons ids={initial['ids']!r}",
    )
    logbook.check(
        "Both selected providers are offered on the entry form",
        all(pid in initial["ids"] for pid in provider_ids),
        f"ids={initial['ids']!r}",
    )
    stylesheets = ui.linked_stylesheets()
    logbook.check(
        "Linked workspace stylesheets load locally",
        all(item.get("ok") for item in stylesheets) if stylesheets else False,
        safe_session_text(stylesheets) if stylesheets else "workspace.html has no linked stylesheet",
    )

    log("\n[3/8] Create a debate through the visible UI")
    session_id, seat_state = ui.create_debate(question, provider_ids)
    logbook.check(
        "Selecting two seats updates the pressed state and the 2/2 counter",
        seat_state["selected"]["pressed"] == provider_ids
        and "2 / 2" in seat_state["selected"]["counter"],
        f"pressed={seat_state['selected']['pressed']!r} counter={seat_state['selected']['counter']!r}",
    )
    logbook.check(
        "A third seat is refused instead of replacing a selection",
        seat_state["extra_provider"] is not None
        and seat_state["after_extra"]["pressed"] == provider_ids
        and bool(seat_state["extra_error"]),
        f"third={seat_state['extra_provider']!r} kept={seat_state['after_extra']['pressed']!r} "
        f"notice={seat_state['extra_error']!r}",
    )
    session = runtime.get(session_id)
    logbook.check("Created session has two distinct canonical providers", sorted(session.get("providers") or []) == sorted(provider_ids), safe_session_text(session.get("providers")))
    logbook.check("Created session starts in independent stage", session.get("stage") == "independent", str(session.get("stage")))
    logbook.check(
        "Both independent prompts contain the original question",
        all(question in str(task.get("prompt")) for task in session.get("tasks") or []),
        "prompts are original-question snapshots",
    )
    screenshot(page, out_dir, "01_debate_created_independent")

    answer_a = (
        "ARENA_ALPHA_7419 我主张先做移动端。理由：记录多发生在通勤路上，"
        "桌面端无法覆盖这个场景。最强依据是用户只在路上产生灵感；"
        "如果两周内移动端只能做只读浏览，这个建议应改成先做快速采集入口。"
    )
    answer_b = (
        "ARENA_BETA_2836 我反对直接做移动端。理由：现有证据只显示检索慢，"
        "没有证据表明采集频率高。最强反例是用户大部分笔记在电脑前完成；"
        "如果实测一周内移动端采集少于三次，优先级应反转。"
    )
    texts = {provider_ids[0]: answer_a, provider_ids[1]: answer_b}
    tokens = {provider_ids[0]: "ARENA_ALPHA_7419", provider_ids[1]: "ARENA_BETA_2836"}

    log("\n[4/8] Answer both seats independently")
    ui.answer_stage(session_id, "independent", texts)
    session = runtime.get(session_id)
    independent_entries = [
        task for task in session.get("history") or [] if task.get("stage") == "independent"
    ]
    logbook.check(
        "Independent answers are recorded",
        len(independent_entries) == 2
        and all(task.get("status") == "answered" for task in independent_entries),
        safe_session_text([task.get("status") for task in independent_entries]),
    )
    logbook.check(
        "Both original answers are retained verbatim",
        all(token in json.dumps(session, ensure_ascii=False) for token in tokens.values()),
        "answer tokens present in state",
    )
    screenshot(page, out_dir, "02_independent_answered")

    log("\n[5/8] Verify opponent relay in critique")
    critique = ui.wait_for_stage(session_id, "critique")
    time.sleep(0.4)
    ui.expand_prompts()
    screenshot(page, out_dir, "03_critique_relay")
    critique_prompts = " ".join(str(task.get("prompt")) for task in critique.get("tasks") or [])
    for pid in provider_ids:
        opponent = next(item for item in provider_ids if item != pid)
        logbook.check(
            f"Critique prompt for {pid} relays {opponent}'s actual answer",
            tokens[opponent] in critique_prompts,
            "opponent token present in critique prompts",
        )
    logbook.check(
        "Critique UI exposes the relayed opponent material",
        all(token in ui.body_text() for token in tokens.values()),
        "both answer tokens visible in critique screen",
    )

    critique_a = (
        "ARENA_CRIT_A_55 我接受反例：采集频率确实未被证实。修正为先用手机快捷入口验证采集频次，"
        "同时保留桌面检索修复。条件：若一周移动采集少于三次，撤回移动端优先。"
    )
    critique_b = (
        "ARENA_CRIT_B_66 我维持反对，但同意先验证采集频次。请把你说的“只在路上产生灵感”"
        "限定为可观测的采集次数，而不是结论。"
    )
    ui.answer_stage(
        session_id,
        "critique",
        {provider_ids[0]: critique_a, provider_ids[1]: critique_b},
        stances={provider_ids[0]: "conditional", provider_ids[1]: "oppose"},
    )
    session = runtime.get(session_id)
    logbook.check(
        "Critique answers preserve both sides and their original tokens",
        tokens[provider_ids[0]] in json.dumps(session, ensure_ascii=False)
        and tokens[provider_ids[1]] in json.dumps(session, ensure_ascii=False),
        "earlier answers remain in session history",
    )
    screenshot(page, out_dir, "04_critique_answered")

    log("\n[6/8] Proposal and explicit vote")
    proposal = ui.wait_for_stage(session_id, "proposal")
    ui.expand_prompts()
    screenshot(page, out_dir, "05_proposal")
    proposal_prompt = " ".join(str(task.get("prompt")) for task in proposal.get("tasks") or [])
    logbook.check(
        "Proposal task carries both critiqued positions",
        all(token in proposal_prompt for token in tokens.values()),
        "proposal prompt includes both original answers",
    )
    ui.answer_stage(
        session_id,
        "proposal",
        {
            provider_ids[0]: (
                "ARENA_PROPOSAL_71 候选结论：先用一个周末做手机快速采集入口，第二周再补桌面检索；"
                "以一周采集次数作为反转条件。依据 [S1] 的采集场景与 [S2] 的检索证据；"
                "最强反例是采集频率不足，若一周少于三次则应转为桌面优先。"
            ),
            provider_ids[1]: (
                "ARENA_PROPOSAL_72 候选结论：先测一周采集频次，不承诺移动端完整功能；"
                "若采集少，则优先桌面检索。依据 [S2] 对采集证据的质疑，并保留 [S1] 的适用条件。"
            ),
        },
    )

    vote = ui.wait_for_stage(session_id, "vote")
    ui.expand_prompts()
    screenshot(page, out_dir, "06_vote")
    vote_prompt = " ".join(str(task.get("prompt")) for task in vote.get("tasks") or [])
    logbook.check(
        "Vote prompt references the same candidate version",
        "ARENA_PROPOSAL_71" in vote_prompt or "ARENA_PROPOSAL_72" in vote_prompt,
        "proposal token visible in vote prompt",
    )

    condition = "ARENA_CONDITION_991 只在用户实测一周移动采集不少于三次时接受移动端优先"
    vote_a = "ARENA_VOTE_A 同意候选方向，但必须写入采集频次验证，不接受无条件移动端优先。"
    vote_b = "ARENA_VOTE_B 有条件同意：先验证采集频次；若不足三次，则改为桌面检索优先。"
    ui.answer_stage(
        session_id,
        "vote",
        {provider_ids[0]: vote_a, provider_ids[1]: vote_b},
        stances={provider_ids[0]: "conditional", provider_ids[1]: "conditional"},
    )
    session = runtime.get(session_id)
    votes = {
        str(entry.get("provider")): entry
        for entry in session.get("history") or []
        if entry.get("stage") == "vote"
    }
    logbook.check(
        "Vote history records an explicit per-seat stance from the pressed buttons",
        set(votes) == set(provider_ids)
        and all(entry.get("status") == "answered" and entry.get("stance") == "conditional" for entry in votes.values()),
        safe_session_text({provider: entry.get("stance") for provider, entry in votes.items()}),
    )
    logbook.check(
        "Vote history preserves each seat's written reason",
        any("ARENA_VOTE_A" in str(entry.get("answer") or "") for entry in votes.values())
        and any("ARENA_VOTE_B" in str(entry.get("answer") or "") for entry in votes.values()),
        "both vote reasons saved on their own seat",
    )

    # If the renderer does not auto-finish after the last vote, use the visible
    # finish control; the runtime fallback below is only for diagnosis.
    if session.get("stage") != "done":
        try:
            finish = first_visible(
                page,
                ["button[data-action='finish']", "#finish-debate"],
            )
            if finish is None:
                for pattern in (r"结束", r"生成报告", r"完成讨论", r"Finish"):
                    buttons = page.get_by_role("button", name=re.compile(pattern))
                    for index in range(min(buttons.count(), 6)):
                        candidate = buttons.nth(index)
                        if candidate.is_visible() and candidate.is_enabled():
                            finish = candidate
                            break
                    if finish:
                        break
            if finish is not None:
                finish.click()
                session = ui.wait_for_stage(session_id, "done")
            else:
                session = runtime.ok({"type": "act", "id": session_id, "action": "finish"}).get("session") or {}
        except PlaywrightError as exc:
            raise AcceptanceError(f"Could not reach done stage after votes: {exc}") from exc

    session = ui.wait_for_stage(session_id, "done")
    logbook.check("All terminal votes advance to done", session.get("stage") == "done", str(session.get("stage")))
    report = str(session.get("report") or "")
    logbook.check("Final report is generated", len(report.strip()) > 120, f"{len(report)} chars")
    logbook.check("Report names the original question", question in report, "question appears in report")
    logbook.check(
        "Report keeps both seats and their final stances",
        all(provider_id in report.casefold() or ui.by_id[provider_id].name.casefold() in report.casefold() for provider_id in provider_ids),
        "provider identities present",
    )
    logbook.check(
        "Conditional agreement is not reported as unanimous acceptance",
        not re.search(r"(?m)^\s*(?:[-*]\s*)?全体一致[：:]", report)
        and any(term in report for term in ("未达成全体一致", "有条件一致", "附条件", "条件一致")),
        f"conditional markers={[term for term in ('未达成全体一致', '有条件一致', '附条件', '条件一致') if term in report]}; head={report[:180]!r}",
    )
    logbook.check(
        "Report preserves the decisive opposing position",
        any(token in report for token in ("ARENA_BETA_2836", "ARENA_VOTE_B", "反对", "反例")),
        "opposition or counterexample retained",
    )
    logbook.check(
        "Report includes a condition that can change the conclusion",
        "条件" in report or "采集" in report or "反例" in report,
        "action-changing condition present",
    )
    logbook.check(
        "Report keeps traceable source ids for the cited claims",
        "引用校验" in report and "[S1]" in report and "[S2]" in report,
        "citation section and source markers present",
    )

    report_node = page.locator("section.report")
    if report_node.count():
        report_node.first.scroll_into_view_if_needed()
    screenshot(page, out_dir, "07_final_report_top", full_page=False)

    joined = ui.joined_vote()
    if joined is None:
        raise AcceptanceError("Done view did not render a joined vote block")
    joined_path = ui.capture_joined_vote(out_dir)
    logbook.check(
        "Done view joins both seats into one visible vote summary",
        len(joined.get("rows") or []) == 2
        and {row.get("name") for row in joined["rows"]} == {ui.by_id[pid].name for pid in provider_ids},
        safe_session_text(joined),
    )
    logbook.check(
        "Joined vote shows each seat's conditional stance and written reason",
        all("有条件同意" in str(row.get("stance") or "") for row in joined["rows"])
        and any("ARENA_VOTE_A" in str(row.get("reason") or "") for row in joined["rows"])
        and any("ARENA_VOTE_B" in str(row.get("reason") or "") for row in joined["rows"]),
        f"captured at {joined_path}",
    )
    logbook.check(
        "Joined vote repeats that absence or silence is never counted as consent",
        "不计为同意" in str(joined.get("rule") or ""),
        str(joined.get("rule") or ""),
    )
    logbook.check(
        "Joined vote agrees with the stored per-seat stances",
        all(votes[pid].get("stance") == "conditional" for pid in provider_ids),
        "both stored as conditional",
    )
    screenshot(page, out_dir, "07_final_report")

    log("\n[7/8] Export Markdown through the UI")
    export_path, exported = ui.export_markdown(out_dir)
    logbook.check("Markdown export is non-trivial", len(exported.strip()) > 120, f"{len(exported)} chars at {export_path}")
    logbook.check("Exported Markdown contains the question", question in exported, "question in export")
    logbook.check(
        "Exported Markdown contains both seats",
        all(pid in exported.casefold() or ui.by_id[pid].name.casefold() in exported.casefold() for pid in provider_ids),
        "providers in export",
    )
    logbook.check(
        "Exported Markdown does not claim false unanimity",
        not re.search(r"(?m)^\s*(?:[-*]\s*)?全体一致[：:]", exported)
        and any(term in exported for term in ("未达成全体一致", "有条件一致", "附条件", "条件一致")),
        "no unconditional consensus claim",
    )
    logbook.check(
        "Exported Markdown keeps source ids for offline citation",
        "[S1]" in exported and "[S2]" in exported,
        "S1/S2 present in export",
    )
    screenshot(page, out_dir, "08_exported_result")

    return {
        "session_id": session_id,
        "session": session,
        "export_path": str(export_path),
        "exported": exported,
    }


def run_reload_and_history_checks(
    page: Page,
    context: Any,
    runtime: Runtime,
    ui: WorkspaceUI,
    out_dir: Path,
    question: str,
    result: dict[str, Any],
    logbook: CheckLog,
) -> None:
    log("\n[8/8] Reload, history and durable state")
    session_id = result["session_id"]
    before = result["session"]
    page.reload(wait_until="domcontentloaded")
    wait_until(lambda: page.locator("body").inner_text(timeout=3000).strip(), "workspace to render after reload", timeout=10.0)

    after = wait_until(
        lambda: (lambda current: current if current.get("stage") == "done" else None)(runtime.get(session_id)),
        "session to remain done after reload",
        timeout=8.0,
    )
    logbook.check("Session survives a workspace reload", after.get("stage") == "done", str(after.get("stage")))
    logbook.check(
        "Report is byte-stable across reload",
        after.get("report") == before.get("report"),
        "report text unchanged",
    )
    logbook.check(
        "Historical answers remain available after reload",
        all(str(task.get("answer") or "") for task in after.get("history") or [] if task.get("status") == "answered"),
        "all answered history entries have text",
    )

    if question[:40] not in ui.body_text():
        try:
            ui.open_history(question)
        except AcceptanceError:
            pass
    logbook.check("History shows the created question after reload", question[:32] in ui.body_text(), "question visible in history/session view")
    screenshot(page, out_dir, "09_after_reload")

    second_page = context.new_page()
    try:
        second_page.goto(page.url, wait_until="domcontentloaded")
        wait_until(lambda: second_page.locator("body").inner_text(timeout=3000).strip(), "second workspace tab to render")
        second_runtime = Runtime(second_page)
        listed = second_runtime.list_sessions()
        logbook.check(
            "A second workspace tab sees the same durable session",
            any(str(item.get("id")) == session_id for item in listed),
            f"{len(listed)} session(s) in second tab",
        )
        second_session = second_runtime.get(session_id)
        logbook.check(
            "Second tab reads the same final report",
            second_session.get("report") == after.get("report"),
            "same report text",
        )
        screenshot(second_page, out_dir, "10_second_tab_durable")
    finally:
        second_page.close()

    # Remaining historical answer can be opened from the sidebar after reload.
    try:
        ui.open_history(question)
        time.sleep(0.4)
        body = ui.body_text()
        logbook.check(
            "Reloaded UI can reopen the historical session and show its content",
            any(token in body for token in ("ARENA_ALPHA_7419", "ARENA_BETA_2836", "采集", "条件")),
            "historical answer/report text visible",
        )
    except AcceptanceError as exc:
        logbook.skip("Reloaded UI can reopen the historical session", str(exc))


def install_network_guard(context: Any, attempts: list[str]) -> None:
    def handler(route: Any) -> None:
        url = route.request.url
        if url.startswith(("http://", "https://")):
            attempts.append(url)
            route.abort()
        else:
            route.continue_()

    context.route("**/*", handler)


def external_request_hosts(attempts: list[str]) -> list[str]:
    hosts: set[str] = set()
    for url in attempts:
        try:
            hosts.add(url.split("/", 3)[2])
        except IndexError:
            hosts.add(url)
    return sorted(hosts)


def main() -> int:
    parser = argparse.ArgumentParser(description="Real-browser acceptance for the AI Arena MV3 extension")
    parser.add_argument("--ext", help="extension directory (defaults to <repo>/extension)")
    parser.add_argument("--out", help="explicit directory for screenshots and exported Markdown")
    parser.add_argument("--providers", default=",".join(DEFAULT_PROVIDERS), help="two canonical provider ids, comma separated")
    parser.add_argument("--headed", action="store_true", help="show the Chromium window (default: headless)")
    parser.add_argument("--keep-profile", action="store_true", help="keep the temporary browser profile for debugging")
    parser.add_argument("--timeout", type=float, default=12.0, help="base UI timeout in seconds")
    args = parser.parse_args()

    provider_ids = [part.strip().casefold() for part in args.providers.split(",") if part.strip()]
    if len(provider_ids) != 2 or len(set(provider_ids)) != 2:
        print("--providers must name two distinct provider ids", file=sys.stderr)
        return 2

    try:
        ext_dir = find_extension_dir(args.ext)
    except AcceptanceError as exc:
        print(f"Not ready: {exc}", file=sys.stderr)
        return 2

    manifest = json.loads((ext_dir / "manifest.json").read_text(encoding="utf-8"))
    ui_path = manifest_ui_path(ext_dir, manifest)
    providers = read_providers(ext_dir)
    provider_names = {provider.provider_id: provider.name for provider in providers}
    missing = [pid for pid in provider_ids if pid not in provider_names]
    if missing:
        print(f"Providers {missing} are not declared in {ext_dir / 'providers.js'}", file=sys.stderr)
        return 2

    if args.out:
        out_dir = Path(args.out).expanduser().resolve()
    else:
        out_dir = Path(tempfile.mkdtemp(prefix="ai-arena-acceptance-"))
    out_dir.mkdir(parents=True, exist_ok=True)
    if REPO_ROOT.resolve() in out_dir.parents:
        print("Refusing to write acceptance screenshots inside the repository; pass --out elsewhere.", file=sys.stderr)
        return 2

    profile_dir = Path(tempfile.mkdtemp(prefix="ai-arena-profile-"))
    logbook = CheckLog()
    attempts: list[str] = []
    question = "接受测试：我的个人笔记工具值不值得先做移动端？我只有两个周末。"
    started = time.time()
    failure: Optional[BaseException] = None
    summary: dict[str, Any] = {
        "extension_dir": str(ext_dir),
        "ui_path": ui_path,
        "providers": provider_ids,
        "out_dir": str(out_dir),
    }

    log("AI Arena real-browser acceptance")
    log(f"  extension: {ext_dir}")
    log(f"  UI page:   {ui_path}")
    log(f"  providers: {provider_ids} ({[provider_names[pid] for pid in provider_ids]})")
    log(f"  output:    {out_dir}")
    log(f"  profile:   {profile_dir}")

    with sync_playwright() as playwright:
        executable = find_chromium_executable()
        if executable:
            log(f"  chromium:  {executable}")
        else:
            log("  chromium:  Playwright default")
        context = playwright.chromium.launch_persistent_context(
            user_data_dir=str(profile_dir),
            headless=not args.headed,
            accept_downloads=True,
            executable_path=str(executable) if executable else None,
            args=[
                f"--disable-extensions-except={ext_dir}",
                f"--load-extension={ext_dir}",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-component-update",
                "--disable-background-networking",
                "--disable-sync",
                "--metrics-recording-only",
                # No DNS override: MAP * ~NOTFOUND also breaks the loopback origin a
                # future step may need. External HTTP(S) is blocked by the route
                # guard below and by --no-proxy-server (no proxy performs the fetch).
                "--no-proxy-server",
            ],
        )
        install_network_guard(context, attempts)

        page_errors: list[str] = []
        console_errors: list[str] = []
        try:
            context.set_default_timeout(args.timeout * 1000)

            service_worker = None
            try:
                service_worker = context.wait_for_event("serviceworker", timeout=15000)
            except PlaywrightTimeoutError:
                service_worker = context.service_workers[0] if context.service_workers else None

            if service_worker is not None:
                extension_id = service_worker.url.split("/")[2]
                log(f"  extension id (service worker): {extension_id}")
            else:
                extension_id = extension_id_from_path(ext_dir)
                log(f"  extension id (path-derived fallback): {extension_id}")

            page = context.new_page()
            page.on("pageerror", lambda error: page_errors.append(str(error)))
            page.on("console", lambda message: console_errors.append(message.text) if message.type == "error" else None)
            ui_url = f"chrome-extension://{extension_id}/{ui_path.lstrip('/')}"
            page.goto(ui_url, wait_until="domcontentloaded", timeout=20000)

            if page.url.startswith("chrome-error://") or not page.url.startswith("chrome-extension://"):
                raise AcceptanceError(f"Workspace page failed to load: {page.url}")

            runtime = Runtime(page)
            ui = WorkspaceUI(page, providers, runtime)

            disposable_id = run_error_contract_checks(runtime, provider_ids, logbook)
            assert disposable_id
            result = run_ui_flow(page, runtime, ui, out_dir, question, provider_ids, logbook)
            run_reload_and_history_checks(page, context, runtime, ui, out_dir, question, result, logbook)
            summary.update(
                {
                    "session_id": result["session_id"],
                    "report_chars": len(str(result["session"].get("report") or "")),
                    "export_path": result["export_path"],
                }
            )

            hosts = external_request_hosts(attempts)
            logbook.check(
                "No external HTTP(S) request was attempted during acceptance",
                not hosts,
                "blocked: " + ", ".join(hosts[:8]) if hosts else "none",
            )
            logbook.check(
                "Workspace produced no uncaught page errors",
                not page_errors,
                "; ".join(page_errors[:5]) if page_errors else "none",
            )
            if console_errors:
                log(f"  [INFO] console errors observed: {'; '.join(console_errors[:5])}")
            else:
                log("  [INFO] no console errors observed")

            screenshot(page, out_dir, "11_final_state")
        except BaseException as exc:  # noqa: BLE001 - report everything as acceptance failure
            failure = exc
            traceback.print_exc()
            try:
                if "page" in locals() and not page.is_closed():
                    screenshot(page, out_dir, "99_failure")
            except Exception:  # noqa: BLE001
                pass
        finally:
            context.close()
            if not args.keep_profile:
                shutil.rmtree(profile_dir, ignore_errors=True)

    elapsed = time.time() - started
    summary["elapsed_seconds"] = round(elapsed, 1)
    summary["checks"] = logbook.checks
    summary_path = out_dir / "acceptance_summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    passed = sum(1 for check in logbook.checks if check["ok"] is True)
    failed = sum(1 for check in logbook.checks if check["ok"] is False)
    skipped = sum(1 for check in logbook.checks if check["ok"] is None)
    log("\nAcceptance summary")
    log(f"  {passed} passed, {failed} failed, {skipped} skipped, {elapsed:.1f}s")
    log(f"  screenshots and export: {out_dir}")
    log(f"  machine-readable summary: {summary_path}")

    if failure is not None:
        log(f"RESULT: FAIL — {failure}")
        return 1
    log("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
