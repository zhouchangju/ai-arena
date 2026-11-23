"""Loopback provider markup and local browser discovery for acceptance tests."""

import functools
import json
import os
import re
from pathlib import Path


PROVIDERS = ("chatgpt", "gemini", "deepseek")
TEMPLATE = r"""<!doctype html><meta charset=utf-8>
<style>textarea,[contenteditable]{display:block;width:700px;min-height:30px}pre,article{display:block;min-height:18px;white-space:pre-wrap}</style>
<main id="log"></main>
CONTENT
<script>
const editor=document.querySelector('#editor');
const send=document.querySelector('#send');
const log=document.querySelector('#log');
const doneMarkup=DONE_MARKUP;
window.turns=[];
const put=(container, html)=>{container.insertAdjacentHTML('beforeend',html);return container.lastElementChild};
send.addEventListener('click',()=>{
 const prompt=editor.tagName==='TEXTAREA'?editor.value:editor.innerText;
 if(!prompt.trim())return;
 editor.value='';editor.replaceChildren();
 const user=put(log,USER);user.textContent=prompt;
 const article=put(log,ANSWER);
 const answer=article.matches(ANSWER_BODY)?article:article.querySelector(ANSWER_BODY);
 const stop=put(document.body,'<button aria-label="Stop generating">Stop</button>');
 const row={prompt,text:'',complete:false};window.turns.push(row);
 const seq=window.turns.length;
 const stage=prompt.includes('STANCE:')?'vote':(prompt.includes('起草候选')?'proposal':'answer');
 const tail=stage==='vote'?'\nSTANCE: agree':(stage==='proposal'?'\n建议先验证检索。[S1]':'\n测试结论。');
 const delay=seq===1&&PROVIDER==='deepseek'&&prompt.includes('隔离接管')?5200:(seq===1?DELAY:650);
 for(let i=1;i<=4;i++)setTimeout(()=>{
   row.text+=(i===1?'':' ')+PROVIDER+' '+seq+' 第'+i+'段的网页原文。';
   if(i===4){row.text+=tail;row.complete=true;stop.remove();if(doneMarkup)article.insertAdjacentHTML('beforeend',doneMarkup)}
   answer.textContent=row.text;
 },delay*i);
});
</script>"""

HTML = (
    (
        '<div id="editor" class="ProseMirror" role="textbox" contenteditable="true"></div><button id="send" data-testid="send-button">发送</button>',
        '<article data-content-search-unit-key="turn:user"></article>',
        "<article><pre data-response-body></pre></article>",
        "[data-response-body]",
        "",
    ),
    (
        '<rich-textarea><div id="editor" class="ql-editor" contenteditable="true"></div></rich-textarea><button id="send" aria-label="Send message">发送</button>',
        '<user-query style="display:block;white-space:pre-wrap"></user-query>',
        '<model-response><message-content style="display:block;white-space:pre-wrap"></message-content></model-response>',
        "message-content",
        # Same structure as the real finished toolbar: a visible native action
        # inside this round's model-response. Gemini only reports completion
        # through it (options.requireDoneMarker); the stop control alone is not
        # enough. Added at the end of the stream, never before.
        '<gem-icon-button data-test-id="regenerate-button" aria-label="重新生成" style="display:inline-block;padding:2px 8px">重新生成</gem-icon-button>',
    ),
    (
        '<textarea id="editor" name="search"></textarea><button id="send" aria-label="发送">发送</button>',
        '<div class="ds-message" style="white-space:pre-wrap"></div>',
        '<div class="ds-message"><pre class="ds-assistant-message-main-content"></pre></div>',
        ".ds-assistant-message-main-content",
        "",
    ),
)


def markup(index):
    content, user, answer, body, done = HTML[index]
    return functools.reduce(
        lambda value, pair: value.replace(*pair),
        [
            ("CONTENT", content),
            ("ANSWER_BODY", json.dumps(body)),
            ("USER", json.dumps(user)),
            ("ANSWER", json.dumps(answer)),
            ("DONE_MARKUP", json.dumps(done)),
            ("DELAY", str((650, 1600, 2700)[index])),
            ("PROVIDER", json.dumps(PROVIDERS[index])),
        ],
        TEMPLATE,
    ).encode()



def find_chromium_executable() -> Path | None:
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
